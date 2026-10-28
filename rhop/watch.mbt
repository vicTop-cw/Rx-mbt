// ============================================================================
// rhop · 接收方触发器监控（shared path 新文件 → 解密验证）
//
// 对照 vools.rhop.watch.RhopWatcher：
//   - 默认只关心 `.rhop` 扩展名（可用 with_extensions 覆盖）；
//   - 出现新文件 → 读取 → crypto.decrypt_verify → 通过则推给订阅方；
//   - **坏文件（读失败 / 解析失败 / 解密失败）跳过并计数，绝不中断监控**；
//   - skip_existing=true 时，把启动瞬间已存在的目标文件视为已消费（只关心新消息）。
//
// 强制复用（契约 §2.6）：文件事件来自 `@monitor.watch_folder`（node fs.watch 事件驱动），
// 流语义来自 `@rx.Observable` / `@rx.PublishSubject` / `@rx.Observer` —— 不自造轮询。
//
// 目标说明：可用性取决于 @monitor 后端；js 为事件驱动，native/wasm 下 watch_folder
// 返回 Unsupported（本包装转发 on_error，不崩溃）。
// ============================================================================

///|
/// shared path 新文件监控 + 解密验证。订阅模型：
///
/// ```moonbit nocheck
/// let w = RhopWatcher::new(dir, crypto).skip_existing(true)
/// let sub = w.observe().subscribe(observer)   // 先订阅
/// let _ = w.start()                            // 再启动（幂等）
/// ...  w.stop()
/// ```
pub struct RhopWatcher {
  /// 监控根目录（"/" 分隔）
  path : String
  /// 本地固定密钥的加密/解密验证对象
  crypto : RhopCrypto
  /// 关心的扩展名（默认 [".rhop"]，大小写不敏感比较）
  mut exts : Array[String]
  /// 启动时是否把已存在文件视为已消费
  mut skip_existing_files : Bool
  /// 事件流（始终存在，start 前订阅也不会丢配置）
  subject : @rx.PublishSubject[(String, VerifyResult), String]
  /// 已见路径（避免同一文件重复推送）
  seen : @ref.Ref[@hashset.HashSet[String]]
  /// 坏文件计数（读/解析/解密失败都算）
  bad : @ref.Ref[Int32]
  /// 是否已启动
  mut started : Bool
  /// 监控订阅句柄（stop 时释放）
  mut sub : @rx.Subscription?
}

///|
/// 构造：监控 `path`，用 `crypto` 解密验证；默认只关心 `.rhop`。
pub fn RhopWatcher::new(path : String, crypto : RhopCrypto) -> RhopWatcher {
  {
    path,
    crypto,
    exts: [".rhop"],
    skip_existing_files: false,
    subject: @rx.PublishSubject::new(),
    seen: @ref.Ref::new(@hashset.HashSet::new()),
    bad: @ref.Ref::new(0),
    started: false,
    sub: None,
  }
}

///|
/// 覆盖关心的扩展名（规范化：补前导点、小写）。返回自身，便于链式配置。
pub fn RhopWatcher::with_extensions(
  self : RhopWatcher,
  exts : Array[String],
) -> RhopWatcher {
  self.exts = normalize_exts(exts)
  self
}

///|
/// 设置 skip_existing 语义（启动瞬间已存在的目标文件视为已消费）。返回自身。
pub fn RhopWatcher::skip_existing(self : RhopWatcher, v : Bool) -> RhopWatcher {
  self.skip_existing_files = v
  self
}

///|
/// 当前关心的扩展名。
pub fn RhopWatcher::extensions(self : RhopWatcher) -> Array[String] {
  self.exts.copy()
}

///|
/// 坏文件计数（读失败 / 解析失败 / 解密失败）。
pub fn RhopWatcher::bad_files(self : RhopWatcher) -> Int32 {
  self.bad.val
}

///|
/// 是否已启动。
pub fn RhopWatcher::is_started(self : RhopWatcher) -> Bool {
  self.started
}

///|
/// 事件流：每次成功解密验证推一个 `(filename, VerifyResult)`。
///
/// 只推 `ok=true` 的结果；坏文件计入 `bad_files()` 后被跳过（不中断流）。
pub fn RhopWatcher::observe(
  self : RhopWatcher,
) -> @rx.Observable[(String, VerifyResult), String] {
  self.subject.as_observable()
}

///|
/// 启动监控（幂等）。
///
/// 失败情形：路径不存在 / 不能作为目录监控 → 可诊断 Err。
/// 注意：native/wasm 的 @monitor 后端不支持时不会让 start 失败，而是通过事件流的
/// on_error 上报（`WatchError::Unsupported`），这样上层可以统一按流处理。
pub fn RhopWatcher::start(self : RhopWatcher) -> Result[Unit, String] {
  if self.started {
    return Ok(())
  }
  if !watch_supported() {
    // wasm-gc 下 monitor 没有文件监控实现（只有 js / native 两个后端）
    return Err(
      "rhop watch: 当前目标无文件监控实现（仅 js / native 有 monitor 后端）；可用 process_file 按名处理，或改用 js/native 目标",
    )
  }
  if !fs_path_exists(self.path) {
    return Err("rhop watch: 监控路径不存在: \{self.path}")
  }
  if self.skip_existing_files {
    seed_seen(self.path, self.exts, self.seen)
  }
  let me = self
  let sub = watch_folder_impl(self.path).subscribe(
    @rx.Observer::new(
      fn(ev : @monitor.WatchEvent) { me.handle_event(ev) },
      fn(err : @monitor.WatchError) {
        self.subject.on_error(@monitor.WatchError::to_string(err))
      },
      fn() { self.subject.on_completed() },
    ),
  )
  self.sub = Some(sub)
  self.started = true
  Ok(())
}

///|
/// 停止监控（幂等）：释放 @monitor 订阅，事件流保持可再订阅。
///
/// C2 BUG-3：同时清空 `seen` —— 每次 start 都是新的观察窗口；不清会让「stop 后
/// 重新 start」时同名文件的新事件被永久压制（与 skip_existing 的 start 侧 seed 语义对齐）。
/// `bad_files()` 是累计诊断计数，跨 restart 保留。
pub fn RhopWatcher::stop(self : RhopWatcher) -> Unit {
  match self.sub {
    Some(s) => s.dispose()
    None => ()
  }
  self.sub = None
  self.started = false
  self.seen.val = @hashset.HashSet::new()
}

///|
/// 按「一个新到的包文件」处理指定路径（同步入口，也是事件处理的实际实现）。
///
/// 顺序：过滤临时文件/扩展名/重复 → 读文件 → `decrypt_verify` →
/// 通过则推给订阅方并返回 Some(result)；坏文件累加 `bad_files()` 并返回 None。
///
/// 之所以公开：`@monitor` 的 fs.watch 事件只能由事件循环推动，而 MoonBit 测试是
/// 同步的（主线程一阻塞，回调就永远不来）。把这个「处理一个文件」的语义单独暴露，
/// 既给上层提供「按名处理 / 补扫」能力，也让 verify 路径可被确定性测试。
pub fn RhopWatcher::process_file(
  self : RhopWatcher,
  path : String,
) -> VerifyResult? {
  // 原子写的中间态（<name>.rhop.tmp）不处理
  if path.has_suffix(".tmp") {
    return None
  }
  if !matches_ext(path, self.exts) {
    return None
  }
  if self.seen.val.contains(path) {
    return None
  }
  match fs_read_text(path) {
    Err(_) => {
      // 读不到（可能被删/半写）：跳过并计数，不中断监控。
      // C2 BUG-2：这里**不登记 seen** —— 否则一次瞬时读失败（半写/杀软占用/网络盘抖动）
      // 会让该路径被永久压制，写完后的新事件全被 contains 挡掉（静默丢消息）。
      self.bad.val = self.bad.val + 1
      None
    }
    Ok(text) => {
      let r = self.crypto.decrypt_verify(text)
      if !r.ok {
        // 坏文件（解析/解密失败）：跳过并计数，同样不登记 seen（可能是写到一半的内容，
        // 写完后应被重新处理；重复告警由「事件仅在文件变化时才触发」自然收敛）
        self.bad.val = self.bad.val + 1
        None
      } else {
        // 只在**成功推送**后登记：保证「已消费」与「已投递」语义一致
        self.seen.val.add(path)
        self.subject.on_next((basename(path), r))
        Some(r)
      }
    }
  }
}

// ---------------------------------------------------------------------------
// @monitor.watch_folder 的目标可用性包装
//
// monitor 包只有两个后端文件：watcher_js.mbt [js] 与 watcher_native.mbt [native]，
// **wasm-gc 没有实现**。watch.mbt 是普通（全目标）文件，直接调 @monitor.watch_folder
// 会让 wasm 编译失败，故用 #cfg 包一层：
//   - js / native：转发到真实实现；
//   - 其它目标：返回一个立即 on_error 的流（并且 start() 会先返回可诊断 Err）。
// ---------------------------------------------------------------------------

///|
/// js / native：转发到 @monitor.watch_folder（事件驱动的真实实现）。
#cfg(any(target="js", target="native"))
fn watch_folder_impl(
  path : String,
) -> @rx.Observable[@monitor.WatchEvent, @monitor.WatchError] {
  @monitor.watch_folder(path)
}

///|
/// 其它目标（wasm-gc）：立即以 Unsupported 报错的空实现，保证可编译、可诊断。
#cfg(not(any(target="js", target="native")))
fn watch_folder_impl(
  path : String,
) -> @rx.Observable[@monitor.WatchEvent, @monitor.WatchError] {
  @rx.Observable::new(fn(
    observer : @rx.Observer[@monitor.WatchEvent, @monitor.WatchError],
  ) -> @rx.Subscription {
    observer.on_error(
      @monitor.WatchError::Unsupported(
        "rhop watch: 当前目标无文件监控实现（仅 js / native 可用）",
      ),
    )
    @rx.Subscription::empty()
  })
}

///|
/// 当前目标是否有文件监控后端（js / native 为 true）。
#cfg(any(target="js", target="native"))
fn watch_supported() -> Bool {
  true
}

///|
/// 其它目标：没有后端，start() 据此返回可诊断 Err。
#cfg(not(any(target="js", target="native")))
fn watch_supported() -> Bool {
  false
}

///|
/// 处理单个文件系统事件：删除事件忽略，其余交给 `process_file`。
fn RhopWatcher::handle_event(
  self : RhopWatcher,
  ev : @monitor.WatchEvent,
) -> Unit {
  if ev.kind == @monitor.WatchKind::Removed {
    return
  }
  let _ = self.process_file(ev.path)
}

///|
/// 规范化扩展名列表：空 ⇒ 默认 [".rhop"]；缺前导点补点；统一小写。
fn normalize_exts(exts : Array[String]) -> Array[String] {
  let out : Array[String] = []
  for e in exts {
    let t = e.trim().to_owned().to_lower()
    if t != "" {
      out.push(if t.has_prefix(".") { t } else { "." + t })
    }
  }
  if out.length() == 0 {
    [".rhop"]
  } else {
    out
  }
}

///|
/// 文件路径是否匹配任一扩展名（大小写不敏感）。
fn matches_ext(path : String, exts : Array[String]) -> Bool {
  let lower = path.to_lower()
  for e in exts {
    if lower.has_suffix(e) {
      return true
    }
  }
  false
}

///|
/// 取路径末段文件名（兼容 "/" 与 "\\"）。
fn basename(path : String) -> String {
  let p = path.replace_all(old="\\", new="/")
  match p.rev_split_once("/") {
    Some(pair) => pair.1.to_owned()
    None => p
  }
}

///|
/// 把目录下已存在的目标扩展名文件预填进 seen（skip_existing 语义）。
fn seed_seen(
  dir : String,
  exts : Array[String],
  seen : @ref.Ref[@hashset.HashSet[String]],
) -> Unit {
  for name in fs_list_dir(dir) {
    if matches_ext(name, exts) {
      seen.val.add(join_shared(dir, name))
    }
  }
}

// ---------------------------------------------------------------------------
// 目录列举 FFI（js: node:fs；非 js：空数组）
// ---------------------------------------------------------------------------

///|
/// 列出目录下的文件名（不含子目录递归）；失败返回 "" 并把原因写错误槽。
#cfg(target="js")
extern "js" fn ffi_list_dir(dir : String) -> String =
  #| (dir) => { const G = globalThis; try { const fs = process.getBuiltinModule("node:fs"); const names = fs.readdirSync(dir, { withFileTypes: true }).filter((d) => d.isFile()).map((d) => d.name); G.__rxmbt_fs_err = ""; return JSON.stringify(names); } catch (e) { G.__rxmbt_fs_err = String((e && e.message) || e); return ""; } }

///|
/// 列出目录下的文件名（解析上面的 JSON 数组；失败返回空数组）。
#cfg(target="js")
fn fs_list_dir(dir : String) -> Array[String] {
  let out : Array[String] = []
  let text = ffi_list_dir(dir)
  if text == "" {
    return out
  }
  let j = @json.parse(text) catch { _ => return out }
  if j is Array(arr) {
    for x in arr {
      if x is String(s) {
        out.push(s)
      }
    }
  }
  out
}

///|
/// 非 js：无文件系统 API，返回空数组。
#cfg(not(target="js"))
fn fs_list_dir(dir : String) -> Array[String] {
  []
}

///|
/// 路径（文件或目录）是否存在。
#cfg(target="js")
extern "js" fn ffi_path_exists(p : String) -> Bool =
  #| (p) => { try { return process.getBuiltinModule("node:fs").existsSync(p); } catch (_e) { return false; } }

///|
/// js：调 existsSync。
#cfg(target="js")
fn fs_path_exists(p : String) -> Bool {
  ffi_path_exists(p)
}

///|
/// 非 js：无法判断，交由 @monitor 后端在订阅时上报 Unsupported。
#cfg(not(target="js"))
fn fs_path_exists(p : String) -> Bool {
  true
}
