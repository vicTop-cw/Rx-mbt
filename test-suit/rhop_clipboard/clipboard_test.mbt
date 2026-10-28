// ============================================================================
// rhop · clipboard 单元测试（js-only，注入假后端，不碰真机剪贴板）
//
// 对齐 vools `tests/test_clipboard.py`：后端探测 / push-pull 文件协议 / 守护退出。
// 与 vools 测试的差异：真机读写只做「不崩溃」探测（不断言具体内容），
// 协议状态机全部用注入的 FakeClip，因此可离线、可重复、与机器状态无关。
// ============================================================================

// ---------------------------------------------------------------------------
// 测试基础设施：临时目录 + 假剪贴板后端
// ---------------------------------------------------------------------------

///|
/// 建一个唯一临时目录（node:os.tmpdir + 进程号 + 计数器）。
extern "js" fn fake_mkdtemp(prefix : String) -> String =
  #| (prefix) => {
  #|   const os = process.getBuiltinModule("node:os");
  #|   const path = process.getBuiltinModule("node:path");
  #|   const fs = process.getBuiltinModule("node:fs");
  #|   const base = path.join(os.tmpdir(), prefix + "-" + process.pid + "-" + Date.now() + "-" + Math.floor(Math.random() * 1e6));
  #|   fs.mkdirSync(base, { recursive: true });
  #|   return base;
  #| }

///|
/// 读文本文件（不存在返回空串）。
extern "js" fn fake_read_file(p : String) -> String =
  #| (p) => {
  #|   try { return process.getBuiltinModule("node:fs").readFileSync(p, "utf8"); } catch (_e) { return ""; }
  #| }

///|
/// 写文本文件（父目录不存在时创建）。
extern "js" fn fake_write_file(p : String, content : String) -> Bool =
  #| (p, content) => {
  #|   try {
  #|     const path = process.getBuiltinModule("node:path");
  #|     const fs = process.getBuiltinModule("node:fs");
  #|     fs.mkdirSync(path.dirname(p), { recursive: true });
  #|     fs.writeFileSync(p, content, "utf8");
  #|     return true;
  #|   } catch (_e) { return false; }
  #| }

///|
/// 递归删目录（清理）。
extern "js" fn fake_rmrf(p : String) -> Unit =
  #| (p) => { try { process.getBuiltinModule("node:fs").rmSync(p, { recursive: true, force: true }); } catch (_e) { /* 忽略 */ } }

///|
/// 文件是否存在。
extern "js" fn fake_exists(p : String) -> Bool =
  #| (p) => { try { return process.getBuiltinModule("node:fs").existsSync(p); } catch (_e) { return false; } }

///|
/// 内存假剪贴板（vools `FakeClip` 等价物）。
///
/// 用 `Ref` 存可变状态：trait 方法按值取 `Self`，只有 Ref 内的状态能跨调用保留。
struct FakeClip {
  label : String
  text : Ref[String]
  read_calls : Ref[Int32]
  write_calls : Ref[Int32]
  fail_write : Ref[Bool]
}

///|
fn FakeClip::make(label : String, initial : String) -> FakeClip {
  {
    label,
    text: Ref::Ref(initial),
    read_calls: Ref::Ref(0),
    write_calls: Ref::Ref(0),
    fail_write: Ref::Ref(false),
  }
}

///|
fn FakeClip::value(self : FakeClip) -> String {
  self.text.val
}

///|
fn FakeClip::set(self : FakeClip, text : String) -> Unit {
  self.text.val = text
}

///|
fn FakeClip::as_backend(self : FakeClip) -> &@rp.ClipboardBackend {
  self
}

///|
impl @rp.ClipboardBackend for FakeClip with fn name(self) {
  self.label
}

///|
impl @rp.ClipboardBackend for FakeClip with fn read(self) {
  self.read_calls.val = self.read_calls.val + 1
  self.text.val
}

///|
impl @rp.ClipboardBackend for FakeClip with fn write(self, text) {
  self.write_calls.val = self.write_calls.val + 1
  if self.fail_write.val {
    false
  } else {
    self.text.val = text
    true
  }
}

///|
/// 解析交换文件内容为 Json（便于逐字段断言）。
fn read_doc(path : String) -> Json? {
  let text = fake_read_file(path)
  if text == "" {
    return None
  }
  let parsed = @json.parse(text) catch { _ => return None }
  match parsed {
    Object(_) => Some(parsed)
    _ => None
  }
}

///|
/// 取对象字段的字符串值（缺省空串）。
fn field_text(doc : Json, key : String) -> String {
  match doc {
    Object(fields) =>
      match fields.get(key) {
        Some(String(s)) => s
        _ => ""
      }
    _ => ""
  }
}

///|
/// 构造交换器（测试里构造失败即视为测试环境问题，直接 abort）。
fn must_sync(
  result : Result[@rp.ClipboardFileSync, String],
) -> @rp.ClipboardFileSync {
  match result {
    Ok(s) => s
    Err(e) => abort("构造 ClipboardFileSync 失败: " + e)
  }
}

///|
/// 构造一个「后端不可用」的交换器（`auto_detect=false` + 不注入 backend ⇒ resolve 为 None）。
fn no_backend_sync(dir : String, role : String) -> @rp.ClipboardFileSync {
  must_sync(@rp.ClipboardFileSync::new(dir, role~, auto_detect=false))
}

// ---------------------------------------------------------------------------
// 常量与后端探测
// ---------------------------------------------------------------------------

///|
test "clipboard: CLIP_FILE 常量与 vools 一致" {
  assert_eq(@rp.CLIP_FILE, "clipboard.txt")
}

///|
test "clipboard: 真机后端探测不崩溃（可用/不可用都合法）" {
  @rp.reset_clipboard_backend_probe()
  @rp.reset_clipboard_backend_cache()
  // 探测要么 Some 要么 None，但必须不抛错；名字与后端一致
  let backend = @rp.get_clipboard_backend()
  let name = @rp.get_clipboard_backend_name()
  match backend {
    Some(b) => {
      assert_true(@rp.ClipboardBackend::name(b).length() > 0)
      assert_eq(name, Some(@rp.ClipboardBackend::name(b)))
    }
    None => assert_eq(name, None)
  }
}

///|
test "clipboard: 注入探测钩子 ⇒ 无可用后端（可复现的环境无关路径）" {
  @rp.set_clipboard_backend_probe(fn() { None })
  match @rp.get_clipboard_backend() {
    None => ()
    Some(_) => fail("注入 None 钩子后不应有后端")
  }
  assert_eq(@rp.get_clipboard_backend_name(), None)
  // read_clipboard 无后端：返回空串 + 原因可查
  assert_eq(@rp.read_clipboard(), "")
  assert_true(@rp.last_read_reason().contains("无可用"))
  // write_clipboard 无后端：false
  assert_false(@rp.write_clipboard("x"))
  @rp.reset_clipboard_backend_probe()
  @rp.reset_clipboard_backend_cache()
}

///|
test "clipboard: read/write 注入 fake 后端 + last_read_reason 成功时清空" {
  let clip = FakeClip::make("fake", "初始文本")
  let backend = clip.as_backend()
  assert_eq(@rp.read_clipboard(backend~), "初始文本")
  assert_eq(clip.read_calls.val, 1)
  // 成功后 reason 为空
  assert_eq(@rp.last_read_reason(), "")
  assert_true(@rp.write_clipboard("改后", backend~))
  assert_eq(clip.value(), "改后")
  assert_eq(clip.write_calls.val, 1)
  // 后端名
  assert_eq(@rp.ClipboardBackend::name(backend), "fake")
}

// ---------------------------------------------------------------------------
// push 语义
// ---------------------------------------------------------------------------

///|
test "clipboard push: 内容变化时写交换文件（text/writer/updated_at）" {
  let dir = fake_mkdtemp("rhop-clip-push")
  let clip = FakeClip::make("fake", "hello-local")
  let sync = must_sync(
    @rp.ClipboardFileSync::new(dir, role="push", backend=clip.as_backend()),
  )
  let out = sync.sync_once()
  assert_eq(field_text(out, "reason"), "")
  match out {
    Object(fields) =>
      match fields.get("changed") {
        Some(True) => ()
        _ => fail("首次 push 应 changed=true")
      }
    _ => fail("sync_once 应返回对象")
  }
  // 文件内容
  let doc = match read_doc(sync.path()) {
    None => abort("交换文件应已写入")
    Some(d) => d
  }
  assert_eq(field_text(doc, "text"), "hello-local")
  assert_eq(field_text(doc, "writer"), "rhop")
  // updated_at 形态：YYYY-MM-DDTHH:MM:SSZ（20 字符 + 结尾 Z）
  let updated = field_text(doc, "updated_at")
  assert_eq(updated.length(), 20)
  assert_true(updated.has_suffix("Z"))
  fake_rmrf(dir)
}

///|
test "clipboard push: 内容一致时跳过（changed=false + reason 含一致）" {
  let dir = fake_mkdtemp("rhop-clip-same")
  let clip = FakeClip::make("fake", "same")
  let sync = must_sync(
    @rp.ClipboardFileSync::new(dir, role="push", backend=clip.as_backend()),
  )
  ignore(sync.sync_once())
  let out = sync.sync_once()
  assert_true(field_text(out, "reason").contains("一致"))
  match out {
    Object(fields) =>
      match fields.get("changed") {
        Some(False) => ()
        _ => fail("内容一致应 changed=false")
      }
    _ => fail("应返回对象")
  }
  fake_rmrf(dir)
}

///|
test "clipboard push: 空剪贴板是合法内容（写空串而非跳过）" {
  let dir = fake_mkdtemp("rhop-clip-empty")
  let clip = FakeClip::make("fake", "will-be-cleared")
  let sync = must_sync(
    @rp.ClipboardFileSync::new(dir, role="push", backend=clip.as_backend()),
  )
  ignore(sync.sync_once())
  clip.set("")
  let out = sync.sync_once()
  match out {
    Object(fields) =>
      match fields.get("changed") {
        Some(True) => ()
        _ => fail("空剪贴板也应触发写（与 vools 一致）")
      }
    _ => fail("应返回对象")
  }
  let doc = match read_doc(sync.path()) {
    None => abort("交换文件应存在")
    Some(d) => d
  }
  assert_eq(field_text(doc, "text"), "")
  fake_rmrf(dir)
}

///|
test "clipboard push: 后端不可用 ⇒ 空转且不写坏文件" {
  let dir = fake_mkdtemp("rhop-clip-nobackend")
  let sync = no_backend_sync(dir, "push")
  let out = sync.sync_once()
  assert_true(field_text(out, "reason").contains("无可用剪贴板后端"))
  match out {
    Object(fields) =>
      match fields.get("changed") {
        Some(False) => ()
        _ => fail("无后端应 changed=false")
      }
    _ => fail("应返回对象")
  }
  // 空转：不产生交换文件
  assert_false(fake_exists(sync.path()))
  fake_rmrf(dir)
}

///|
test "clipboard push: 写文件失败 ⇒ 可诊断 reason（不吞错）" {
  // 把目录位置先占成文件，使 mkdir/写入失败
  let base = fake_mkdtemp("rhop-clip-wfail")
  let blocked = base + "/blocked"
  assert_true(fake_write_file(blocked, "i-am-a-file"))
  let sync = must_sync(@rp.ClipboardFileSync::new(blocked, role="push"))
  let clip = FakeClip::make("fake", "text")
  let sync2 = must_sync(
    @rp.ClipboardFileSync::new(blocked, role="push", backend=clip.as_backend()),
  )
  ignore(sync)
  let out = sync2.sync_once()
  assert_true(field_text(out, "reason").contains("文件写入失败"))
  fake_rmrf(base)
}

// ---------------------------------------------------------------------------
// pull 语义
// ---------------------------------------------------------------------------

///|
test "clipboard pull: 文件 → 剪贴板（changed=true + from_writer）" {
  let dir = fake_mkdtemp("rhop-clip-pull")
  let file = dir + "/" + @rp.CLIP_FILE
  ignore(
    fake_write_file(
      file, "{\"text\": \"from-p0\", \"updated_at\": \"t\", \"writer\": \"p0\"}",
    ),
  )
  let clip = FakeClip::make("fake", "")
  let sync = must_sync(
    @rp.ClipboardFileSync::new(dir, role="pull", backend=clip.as_backend()),
  )
  let out = sync.sync_once()
  assert_eq(clip.value(), "from-p0")
  assert_eq(field_text(out, "from_writer"), "p0")
  match out {
    Object(fields) =>
      match fields.get("changed") {
        Some(True) => ()
        _ => fail("pull 首轮应 changed=true")
      }
    _ => fail("应返回对象")
  }
  fake_rmrf(dir)
}

///|
test "clipboard pull: 交换文件不存在 ⇒ reason 含不存在" {
  let dir = fake_mkdtemp("rhop-clip-nofile")
  let clip = FakeClip::make("fake", "")
  let sync = must_sync(
    @rp.ClipboardFileSync::new(dir, role="pull", backend=clip.as_backend()),
  )
  let out = sync.sync_once()
  assert_true(field_text(out, "reason").contains("不存在"))
  assert_eq(clip.value(), "")
  fake_rmrf(dir)
}

///|
test "clipboard pull: 幂等（两次 → 第二次内容未变化）" {
  let dir = fake_mkdtemp("rhop-clip-idem")
  ignore(
    fake_write_file(
      dir + "/" + @rp.CLIP_FILE,
      "{\"text\": \"same\", \"updated_at\": \"t\", \"writer\": \"p0\"}",
    ),
  )
  let clip = FakeClip::make("fake", "")
  let sync = must_sync(
    @rp.ClipboardFileSync::new(dir, role="pull", backend=clip.as_backend()),
  )
  ignore(sync.sync_once())
  let out = sync.sync_once()
  assert_true(field_text(out, "reason").contains("未变化"))
  fake_rmrf(dir)
}

///|
test "clipboard pull: 文件内容与本机一致 ⇒ 不写剪贴板" {
  let dir = fake_mkdtemp("rhop-clip-samelocal")
  ignore(
    fake_write_file(
      dir + "/" + @rp.CLIP_FILE,
      "{\"text\": \"already-here\", \"updated_at\": \"t\", \"writer\": \"p0\"}",
    ),
  )
  let clip = FakeClip::make("fake", "already-here")
  let sync = must_sync(
    @rp.ClipboardFileSync::new(dir, role="pull", backend=clip.as_backend()),
  )
  let out = sync.sync_once()
  assert_true(field_text(out, "reason").contains("一致"))
  assert_eq(clip.write_calls.val, 0)
  fake_rmrf(dir)
}

///|
test "clipboard pull: 文件更新后下一轮感知（v1 → v2）" {
  let dir = fake_mkdtemp("rhop-clip-propagate")
  let file = dir + "/" + @rp.CLIP_FILE
  ignore(
    fake_write_file(
      file, "{\"text\": \"v1\", \"updated_at\": \"t1\", \"writer\": \"p0\"}",
    ),
  )
  let clip = FakeClip::make("fake", "")
  let sync = must_sync(
    @rp.ClipboardFileSync::new(dir, role="pull", backend=clip.as_backend()),
  )
  ignore(sync.sync_once())
  assert_eq(clip.value(), "v1")
  ignore(
    fake_write_file(
      file, "{\"text\": \"v2\", \"updated_at\": \"t2\", \"writer\": \"p0\"}",
    ),
  )
  let out = sync.sync_once()
  assert_eq(clip.value(), "v2")
  match out {
    Object(fields) =>
      match fields.get("changed") {
        Some(True) => ()
        _ => fail("文件更新后应 changed=true")
      }
    _ => fail("应返回对象")
  }
  fake_rmrf(dir)
}

///|
test "clipboard pull: 剪贴板写入失败 ⇒ reason 可诊断" {
  let dir = fake_mkdtemp("rhop-clip-wfail2")
  ignore(
    fake_write_file(
      dir + "/" + @rp.CLIP_FILE,
      "{\"text\": \"target\", \"updated_at\": \"t\", \"writer\": \"p0\"}",
    ),
  )
  let clip = FakeClip::make("fake", "")
  clip.fail_write.val = true
  let sync = must_sync(
    @rp.ClipboardFileSync::new(dir, role="pull", backend=clip.as_backend()),
  )
  let out = sync.sync_once()
  assert_true(field_text(out, "reason").contains("剪贴板写入失败"))
  // 失败后不更新 last_text（下一轮还会重试）
  assert_eq(sync.last_text(), None)
  fake_rmrf(dir)
}

///|
test "clipboard pull: 坏 JSON / 非对象 ⇒ 视为未初始化" {
  let dir = fake_mkdtemp("rhop-clip-badjson")
  let file = dir + "/" + @rp.CLIP_FILE
  ignore(fake_write_file(file, "not-json"))
  let clip = FakeClip::make("fake", "")
  let sync = must_sync(
    @rp.ClipboardFileSync::new(dir, role="pull", backend=clip.as_backend()),
  )
  assert_true(
    field_text(sync.sync_once(), "reason").contains("不存在或未初始化"),
  )
  // 非对象（数组）同样
  ignore(fake_write_file(file, "[1,2,3]"))
  assert_true(
    field_text(sync.sync_once(), "reason").contains("不存在或未初始化"),
  )
  fake_rmrf(dir)
}

// ---------------------------------------------------------------------------
// 构造与角色
// ---------------------------------------------------------------------------

///|
test "clipboard: 非法 role 拒绝（only push/pull）" {
  let dir = fake_mkdtemp("rhop-clip-role")
  match @rp.ClipboardFileSync::new(dir, role="both") {
    Ok(_) => fail("role=both 应被拒绝")
    Err(e) => assert_true(e.contains("push") || e.contains("pull"))
  }
  match @rp.ClipboardFileSync::new(dir, role="") {
    Ok(_) => fail("空 role 应被拒绝")
    Err(_) => ()
  }
  // 大小写归一化
  match @rp.ClipboardFileSync::new(dir, role="PUSH") {
    Ok(s) => assert_eq(s.role(), "push")
    Err(e) => fail("role=PUSH 应被接受（大小写不敏感）: " + e)
  }
  fake_rmrf(dir)
}

///|
test "clipboard: 目录不存在时构造会创建，push 能落盘" {
  let base = fake_mkdtemp("rhop-clip-mkdir")
  let dir = base + "/nested/deep"
  assert_false(fake_exists(dir))
  let clip = FakeClip::make("fake", "deep")
  let sync = must_sync(
    @rp.ClipboardFileSync::new(dir, role="push", backend=clip.as_backend()),
  )
  ignore(sync.sync_once())
  assert_true(fake_exists(sync.path()))
  fake_rmrf(base)
}

// ---------------------------------------------------------------------------
// 端到端 + 轮询
// ---------------------------------------------------------------------------

///|
test "clipboard: 端到端 p0 push → 共享盘 → p1 pull" {
  let shared = fake_mkdtemp("rhop-clip-e2e")
  let clip_p0 = FakeClip::make("p0", "")
  let clip_p1 = FakeClip::make("p1", "")
  let pusher = must_sync(
    @rp.ClipboardFileSync::new(
      shared,
      role="push",
      backend=clip_p0.as_backend(),
      writer="p0",
    ),
  )
  let puller = must_sync(
    @rp.ClipboardFileSync::new(
      shared,
      role="pull",
      backend=clip_p1.as_backend(),
    ),
  )
  clip_p0.set("跨机文本-2026")
  let out_push = pusher.sync_once()
  match out_push {
    Object(fields) =>
      match fields.get("changed") {
        Some(True) => ()
        _ => fail("push 端应 changed=true")
      }
    _ => fail("应返回对象")
  }
  let out_pull = puller.sync_once()
  match out_pull {
    Object(fields) =>
      match fields.get("changed") {
        Some(True) => ()
        _ => fail("pull 端应 changed=true")
      }
    _ => fail("应返回对象")
  }
  assert_eq(clip_p1.value(), "跨机文本-2026")
  // 再各跑一轮：两端都无变化
  assert_true(field_text(pusher.sync_once(), "reason").contains("一致"))
  assert_true(field_text(puller.sync_once(), "reason").contains("未变化"))
  fake_rmrf(shared)
}

///|
test "clipboard: sync_rounds 返回 {rounds, changes} 汇总" {
  let dir = fake_mkdtemp("rhop-clip-rounds")
  let clip = FakeClip::make("fake", "r1")
  let sync = must_sync(
    @rp.ClipboardFileSync::new(dir, role="push", backend=clip.as_backend()),
  )
  let summary = sync.sync_rounds(3)
  match summary {
    Object(fields) => {
      match fields.get("rounds") {
        Some(Number(n, ..)) => assert_eq(n.to_int(), 3)
        _ => fail("rounds 字段缺失")
      }
      match fields.get("changes") {
        Some(Number(n, ..)) => assert_eq(n.to_int(), 1) // 只有首轮变化
        _ => fail("changes 字段缺失")
      }
    }
    _ => fail("应返回对象")
  }
  assert_eq(sync.rounds(), 3)
  assert_eq(sync.changes(), 1)
  fake_rmrf(dir)
}

///|
test "clipboard: run_forever 订阅即推首轮，dispose 后停止" {
  let dir = fake_mkdtemp("rhop-clip-rf")
  let clip = FakeClip::make("fake", "rf-text")
  let sync = must_sync(
    @rp.ClipboardFileSync::new(dir, role="push", backend=clip.as_backend()),
  )
  let events : Array[Json] = []
  let completed : Ref[Bool] = Ref::Ref(false)
  let observable = sync.run_forever(poll_interval_ms=60000)
  let sub = observable.subscribe(
    @rx.Observer::new(
      fn(ev : Json) { events.push(ev) },
      fn(_err : String) { () },
      fn() { completed.val = true },
    ),
  )
  // 首轮同步推送（vools「至少跑一轮」）
  assert_eq(events.length(), 1)
  match events[0] {
    Object(fields) => assert_true(fields.contains("changed"))
    _ => fail("首轮事件应是对象")
  }
  // dispose：停止定时器并 complete
  sub.dispose()
  assert_true(completed.val)
  fake_rmrf(dir)
}

// ---------------------------------------------------------------------------
// 边界四问（空 / 极值 / 非法输入 / 资源）
// ---------------------------------------------------------------------------

///|
test "clipboard 边界: 空文本 push→pull 往返（空也是合法内容）" {
  let shared = fake_mkdtemp("rhop-clip-edge-empty")
  let clip_p0 = FakeClip::make("p0", "有内容")
  let clip_p1 = FakeClip::make("p1", "旧内容")
  let pusher = must_sync(
    @rp.ClipboardFileSync::new(
      shared,
      role="push",
      backend=clip_p0.as_backend(),
    ),
  )
  let puller = must_sync(
    @rp.ClipboardFileSync::new(
      shared,
      role="pull",
      backend=clip_p1.as_backend(),
    ),
  )
  ignore(pusher.sync_once())
  clip_p0.set("")
  ignore(pusher.sync_once())
  ignore(puller.sync_once())
  assert_eq(clip_p1.value(), "")
  fake_rmrf(shared)
}

///|
test "clipboard 边界: 1MB 文本往返（资源上限内的极端输入）" {
  let shared = fake_mkdtemp("rhop-clip-edge-1mb")
  let big = "x".repeat(1000000)
  let clip_p0 = FakeClip::make("p0", big)
  let clip_p1 = FakeClip::make("p1", "")
  let pusher = must_sync(
    @rp.ClipboardFileSync::new(
      shared,
      role="push",
      backend=clip_p0.as_backend(),
    ),
  )
  let puller = must_sync(
    @rp.ClipboardFileSync::new(
      shared,
      role="pull",
      backend=clip_p1.as_backend(),
    ),
  )
  let out = pusher.sync_once()
  match out {
    Object(fields) =>
      match fields.get("text_len") {
        Some(Number(n, ..)) => assert_eq(n.to_int(), 1000000)
        _ => fail("text_len 应为 1000000")
      }
    _ => fail("应返回对象")
  }
  ignore(puller.sync_once())
  assert_eq(clip_p1.value().length(), 1000000)
  fake_rmrf(shared)
}

///|
test "clipboard 边界: 中文 / emoji 的 text_len 按码点计数（对齐 Python len）" {
  let dir = fake_mkdtemp("rhop-clip-edge-unicode")
  let clip = FakeClip::make("fake", "中文😀")
  let sync = must_sync(
    @rp.ClipboardFileSync::new(dir, role="push", backend=clip.as_backend()),
  )
  let out = sync.sync_once()
  // "中文😀" 在 Python len() 下是 3（2 个 BMP + 1 个非 BMP 码点）
  match out {
    Object(fields) =>
      match fields.get("text_len") {
        Some(Number(n, ..)) => assert_eq(n.to_int(), 3)
        _ => fail("text_len 缺失")
      }
    _ => fail("应返回对象")
  }
  fake_rmrf(dir)
}

///|
test "clipboard 边界: fake 后端 read 恒空串 ⇒ push 写空文本（不误判失败）" {
  let dir = fake_mkdtemp("rhop-clip-edge-emptysrc")
  let clip = FakeClip::make("fake", "")
  let sync = must_sync(
    @rp.ClipboardFileSync::new(dir, role="push", backend=clip.as_backend()),
  )
  let out = sync.sync_once()
  // 空剪贴板 vs 不存在的文件（视为 ""）⇒ 内容一致 ⇒ 不写
  assert_true(field_text(out, "reason").contains("一致"))
  fake_rmrf(dir)
}
