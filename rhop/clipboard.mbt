// ============================================================================
// rhop · 剪贴板共享（对齐 vools-rhop `clipboard.py`，含文件交换协议）
//
// 两块能力：
//   ① 本机剪贴板读写：探测链降级、零硬依赖（read_clipboard / write_clipboard /
//      last_read_reason / get_clipboard_backend）；
//   ② 文件交换协议：RDP 断开时 p0 ↔ 共享盘 ↔ p1 的无感共享通道
//      （ClipboardFileSync，role 只有 push / pull）。
//
// 与 vools 的差异（🟡，均不改变可观察协议语义）：
//   - `get_clipboard_backend()` 返回 `&ClipboardBackend?`（trait object）而不是
//     `(read_fn, write_fn, name)` 三元组；名字用 `get_clipboard_backend_name()` 取；
//   - 探测方式：vools 用 `shutil.which` / pyperclip；本实现按平台走
//     `which`（Windows powershell / Linux wl-paste|xclip / macOS pbpaste）；
//   - `run_forever` 在 MoonBit 是 **响应式** 的：返回 `@rx.Observable[Json, String]`，
//     订阅即跑首轮、随后按 `poll_interval_ms` 周期推；`Subscription::dispose()` 停止。
//     vools 是阻塞式（stop_event + 线程），语义等价但不是阻塞调用；
//   - 另有同步版 `sync_rounds(n)`（测试与一次性批处理用，返回 `{rounds, changes}`，
//     与 vools `run_forever` 返回值同形）。
//
// 目标可用性：
//   - 协议部分（ClipboardFileSync 状态机 / Json 形状 / role 校验）：三目标可用；
//   - 本机剪贴板后端与文件读写：仅 js 目标有真实实现；wasm / native 下
//     `detect_backend()` 返回 None（note 可诊断），文件读写返回可诊断 Err，
//     因此 `sync_once()` 返回 `{"changed": false, "reason": "无可用剪贴板后端"}`
//     或 `"交换文件不存在或未初始化"` —— API 存在、行为显式失败、不崩溃。
// ============================================================================

///|
/// 交换文件缺省名（vools `CLIP_FILE`）。
pub const CLIP_FILE : String = "clipboard.txt"

///|
/// 剪贴板后端抽象。
///
/// 可注入（测试用内存假后端）；真实实现为 `CommandClipboardBackend`（子进程）。
/// 约定：`read` 永不抛错——读不到返回 `""`，失败原因由 `last_read_reason()` 承载。
pub(open) trait ClipboardBackend {
  /// 后端名（如 `"powershell"` / `"wl-paste"` / `"fake"`）
  fn name(Self) -> String
  /// 读剪贴板文本；失败返回空串
  fn read(Self) -> String
  /// 写剪贴板文本；成功 true
  fn write(Self, String) -> Bool
}

// ---------------------------------------------------------------------------
// 最近一次失败原因（诊断用，vools `_last_read_reason` 等价物）
// ---------------------------------------------------------------------------

///|
let last_read_reason_slot : Ref[String] = Ref::Ref("")

///|
/// 最近一次 `read_clipboard` 的失败原因（诊断用）；成功时为空串。
///
/// 与 vools `last_read_reason()` 同义。
pub fn last_read_reason() -> String {
  last_read_reason_slot.val
}

///|
fn set_last_read_reason(reason : String) -> Unit {
  last_read_reason_slot.val = reason
}

// ---------------------------------------------------------------------------
// 子进程 / 平台 / which —— js 目标实现，非 js 目标可诊断降级
// ---------------------------------------------------------------------------

///|
/// 执行命令：`argv_json` 是 JSON 数组文本，`stdin_text` 走 stdin。
///
/// 返回 `(退出码, stdout, stderr/错误信息)`；永不抛错（失败以 -1 表达）。
#cfg(target="js")
extern "js" fn ffi_exec(argv_json : String, stdin_text : String) -> String =
  #| (argvJson, stdinText) => {
  #|   try {
  #|     const cp = process.getBuiltinModule("node:child_process");
  #|     const argv = JSON.parse(argvJson);
  #|     const r = cp.spawnSync(argv[0], argv.slice(1), {
  #|       input: stdinText === undefined || stdinText === null ? "" : stdinText,
  #|       encoding: "utf8",
  #|       timeout: 15000,
  #|     });
  #|     const code = (r.status === null || r.status === undefined) ? -1 : r.status;
  #|     const errText = (r.error && r.error.message) ? String(r.error.message) : (r.stderr || "");
  #|     return JSON.stringify({ code: code, out: r.stdout || "", err: errText });
  #|   } catch (e) {
  #|     return JSON.stringify({ code: -1, out: "", err: String((e && e.message) || e) });
  #|   }
  #| }

///|
/// 平台标识：`"win32"` / `"linux"` / `"darwin"` / 空串（非 js）。
#cfg(target="js")
extern "js" fn ffi_platform() -> String =
  #| () => { try { return String(process.platform || ""); } catch (_e) { return ""; } }

///|
/// 在 PATH 中查找可执行文件（`shutil.which` 等价物）；找不到返回空串。
#cfg(target="js")
extern "js" fn ffi_which(name : String) -> String =
  #| (name) => {
  #|   try {
  #|     const path = process.getBuiltinModule("node:path");
  #|     const fs = process.getBuiltinModule("node:fs");
  #|     const isWin = process.platform === "win32";
  #|     const exts = isWin
  #|       ? String(process.env.PATHEXT || ".EXE;.CMD;.BAT").split(";").filter(Boolean)
  #|       : [""];
  #|     const dirs = String(process.env.PATH || "").split(isWin ? ";" : ":");
  #|     for (const dir of dirs) {
  #|       if (!dir) continue;
  #|       for (const ext of exts) {
  #|         const candidate = path.join(dir, name + (isWin ? ext.toLowerCase() : ""));
  #|         try { if (fs.existsSync(candidate)) return candidate; } catch (_e) { /* 忽略 */ }
  #|       }
  #|     }
  #|     return "";
  #|   } catch (e) {
  #|     return "";
  #|   }
  #| }

///|
/// 解析 `ffi_exec` 的 JSON 结果为三元组；解析失败按 (-1, "", 原文) 处理。
fn split_exec_result(text : String) -> (Int32, String, String) {
  let parsed = @json.parse(text) catch { _ => return (-1, "", text) }
  match parsed {
    Object(fields) => {
      let code = match fields.get("code") {
        Some(Number(n, ..)) => n.to_int()
        _ => -1
      }
      let out = match fields.get("out") {
        Some(String(s)) => s
        _ => ""
      }
      let err = match fields.get("err") {
        Some(String(s)) => s
        _ => ""
      }
      (code, out, err)
    }
    _ => (-1, "", text)
  }
}

///|
/// 执行命令（统一入口；非 js 返回可诊断失败）。
#cfg(target="js")
fn run_command(
  argv_json : String,
  stdin_text : String,
) -> (Int32, String, String) {
  split_exec_result(ffi_exec(argv_json, stdin_text))
}

///|
#cfg(not(target="js"))
fn run_command(
  argv_json : String,
  stdin_text : String,
) -> (Int32, String, String) {
  ignore(argv_json)
  ignore(stdin_text)
  (-1, "", "非 js 目标无子进程能力")
}

///|
#cfg(target="js")
fn platform_name() -> String {
  ffi_platform()
}

///|
#cfg(not(target="js"))
fn platform_name() -> String {
  ""
}

///|
#cfg(target="js")
fn which(name : String) -> String {
  ffi_which(name)
}

///|
#cfg(not(target="js"))
fn which(name : String) -> String {
  ignore(name)
  ""
}

// ---------------------------------------------------------------------------
// 子进程剪贴板后端
// ---------------------------------------------------------------------------

///|
/// 基于子进程的剪贴板后端（PowerShell / wl-paste / xclip / pbpaste）。
///
/// `read_argv` / `write_argv` 是 JSON 数组文本（如 `["powershell","-NoProfile",…]`）；
/// `strip_trailing_crlf` 用于 PowerShell 的 `Get-Clipboard -Raw` 尾部换行归一化
/// （与 vools 处理一致：只剥最尾部连续 `\r`/`\n`，保留文本内换行）。
pub struct CommandClipboardBackend {
  backend_name : String
  read_argv : String
  write_argv : String
  strip_trailing_crlf : Bool
}

///|
/// 构造命令型后端（argv 用 JSON 数组文本表达，避免跨语言数组编组歧义）。
pub fn CommandClipboardBackend::new(
  name : String,
  read_argv : String,
  write_argv : String,
  strip_trailing_crlf : Bool,
) -> CommandClipboardBackend {
  { backend_name: name, read_argv, write_argv, strip_trailing_crlf, }
}

///|
/// 后端名。
pub fn CommandClipboardBackend::backend_name(
  self : CommandClipboardBackend,
) -> String {
  self.backend_name
}

///|
/// 剥掉最尾部的连续 `\r` / `\n`（vools `rstrip("\r\n")` 等价）。
fn rstrip_crlf(text : String) -> String {
  let mut end = text.length()
  while end > 0 {
    let c = text[end - 1]
    if c == '\r' || c == '\n' {
      end = end - 1
    } else {
      break
    }
  }
  if end == text.length() {
    text
  } else {
    text.substring(start=0, end~)
  }
}

///|
pub impl ClipboardBackend for CommandClipboardBackend with fn name(self) {
  self.backend_name
}

///|
pub impl ClipboardBackend for CommandClipboardBackend with fn read(self) {
  let (code, out, err) = run_command(self.read_argv, "")
  if code != 0 && out == "" {
    ignore(err)
    ""
  } else if self.strip_trailing_crlf {
    rstrip_crlf(out)
  } else {
    out
  }
}

///|
pub impl ClipboardBackend for CommandClipboardBackend with fn write(self, text) {
  let (code, _, _) = run_command(self.write_argv, text)
  code == 0
}

// ---------------------------------------------------------------------------
// 后端探测
// ---------------------------------------------------------------------------

///|
/// 探测结果缓存：空串 = 未探测；"-" = 探测过但无可用后端；其它 = 后端名。
let detect_cache : Ref[String] = Ref::Ref("")

///|
/// 测试注入的探测钩子（`None` 表示走真实探测）。
///
/// 这是**有意增量**：vools 用 monkeypatch，本实现给一个显式钩子，避免测试碰真机剪贴板。
let detect_probe : Ref[(() -> &ClipboardBackend?)?] = Ref::Ref(None)

///|
/// 注入探测钩子（测试用；生产 shouldn't 调用）。
pub fn set_clipboard_backend_probe(probe : () -> &ClipboardBackend?) -> Unit {
  detect_probe.val = Some(probe)
  detect_cache.val = ""
}

///|
/// 清除探测钩子并重置缓存。
pub fn reset_clipboard_backend_probe() -> Unit {
  detect_probe.val = None
  detect_cache.val = ""
}

///|
/// 重置探测缓存（强制下次重新探测）。
pub fn reset_clipboard_backend_cache() -> Unit {
  detect_cache.val = ""
}

///|
/// 按名字构造内置后端；未知名字返回 None。
fn backend_by_name(name : String) -> &ClipboardBackend? {
  match name {
    "powershell" =>
      Some(
        CommandClipboardBackend::new(
          "powershell",
          // 读：显式 UTF-8 输出编码；尾部换行由 strip_trailing_crlf 归一化
           "[\"powershell\",\"-NoProfile\",\"-Command\",\"[Console]::OutputEncoding=[Text.Encoding]::UTF8; Get-Clipboard -Raw\"]",
          // 写：文本走 stdin；PowerShell 5.1 默认按控制台编码读 stdin，
          // 故先显式 InputEncoding=UTF8 再 ReadToEnd（vools 同款处理）
           "[\"powershell\",\"-NoProfile\",\"-Command\",\"[Console]::InputEncoding=[Text.Encoding]::UTF8; $t=[Console]::In.ReadToEnd(); Set-Clipboard -Value $t\"]",
          true,
        ),
      )
    "wl-paste" =>
      Some(
        CommandClipboardBackend::new(
          "wl-paste", "[\"wl-paste\"]", "[\"wl-copy\"]", false,
        ),
      )
    "xclip" =>
      Some(
        CommandClipboardBackend::new(
          "xclip", "[\"xclip\",\"-selection\",\"clipboard\",\"-o\"]", "[\"xclip\",\"-selection\",\"clipboard\",\"-i\"]",
          false,
        ),
      )
    "pbpaste" =>
      Some(
        CommandClipboardBackend::new(
          "pbpaste", "[\"pbpaste\"]", "[\"pbcopy\"]", false,
        ),
      )
    _ => None
  }
}

///|
/// 真实探测：按平台顺序尝试候选后端，返回第一个可用的名字（找不到返回空串）。
fn detect_backend_name() -> String {
  let platform = platform_name()
  if platform == "win32" {
    if which("powershell").length() > 0 {
      return "powershell"
    }
    return ""
  }
  if platform == "darwin" {
    if which("pbpaste").length() > 0 && which("pbcopy").length() > 0 {
      return "pbpaste"
    }
    return ""
  }
  if platform == "linux" {
    if which("wl-paste").length() > 0 {
      return "wl-paste"
    }
    if which("xclip").length() > 0 {
      return "xclip"
    }
    return ""
  }
  ""
}

///|
/// 探测可用的剪贴板后端（带缓存）；全不可用返回 `None`。
///
/// 目标可用性：仅 js 目标可能返回 `Some`；wasm / native 恒 `None`（无子进程能力）。
/// 失败不抛错：探测链路任何一步异常都退化成 `None`。
pub fn get_clipboard_backend() -> &ClipboardBackend? {
  match detect_probe.val {
    Some(probe) => return probe()
    None => ()
  }
  let cached = detect_cache.val
  if cached == "-" {
    return None
  }
  if cached.length() > 0 {
    return backend_by_name(cached)
  }
  let name = detect_backend_name()
  if name.length() == 0 {
    detect_cache.val = "-"
    None
  } else {
    detect_cache.val = name
    backend_by_name(name)
  }
}

///|
/// 当前可用后端名（无则 `None`）。
pub fn get_clipboard_backend_name() -> String? {
  match get_clipboard_backend() {
    Some(backend) => Some(ClipboardBackend::name(backend))
    None => None
  }
}

// ---------------------------------------------------------------------------
// 本机剪贴板读写
// ---------------------------------------------------------------------------

///|
/// 读本机剪贴板；失败返回 `""`，原因记在 `last_read_reason()`。
///
/// `backend` 缺省自动探测（测试可注入假后端）。
/// 目标可用性：js 目标有真实后端；非 js 恒返回 `""` + 原因「无可用剪贴板后端」。
pub fn read_clipboard(backend? : &ClipboardBackend) -> String {
  let resolved = match backend {
    Some(b) => Some(b)
    None => get_clipboard_backend()
  }
  match resolved {
    None => {
      set_last_read_reason("无可用剪贴板后端")
      ""
    }
    Some(b) => {
      let text = ClipboardBackend::read(b)
      set_last_read_reason("")
      text
    }
  }
}

///|
/// 写本机剪贴板；成功 true（后端不可用或写入失败均 false）。
pub fn write_clipboard(text : String, backend? : &ClipboardBackend) -> Bool {
  let resolved = match backend {
    Some(b) => Some(b)
    None => get_clipboard_backend()
  }
  match resolved {
    None => false
    Some(b) => ClipboardBackend::write(b, text)
  }
}

// ---------------------------------------------------------------------------
// 文件交换协议
// ---------------------------------------------------------------------------

///|
/// UTC 时间戳（`YYYY-MM-DDTHH:MM:SSZ`），供交换文件的 `updated_at` 字段。
///
/// 用 `@env.now()`（epoch 毫秒）+ 民用历换算，不依赖平台时间 API。
fn utc_now_iso() -> String {
  let ms = @env.now().reinterpret_as_int64()
  let seconds = ms / 1000L
  let days = seconds / 86400L
  let sod = seconds % 86400L
  let hour = sod / 3600L
  let minute = sod % 3600L / 60L
  let second = sod % 60L
  // Howard Hinnant civil_from_days（1970-01-01 起的天数 → 年月日）
  let z = days + 719468L
  let era = z / 146097L
  let doe = z - era * 146097L
  let yoe = (doe - doe / 1460L + doe / 36524L - doe / 146096L) / 365L
  let mut y = yoe + era * 400L
  let doy = doe - (365L * yoe + yoe / 4L - yoe / 100L)
  let mp = (5L * doy + 2L) / 153L
  let d = doy - (153L * mp + 2L) / 5L + 1L
  let m = if mp < 10L { mp + 3L } else { mp - 9L }
  if m <= 2L {
    y = y + 1L
  }
  pad4(y.to_int()) +
  "-" +
  pad2(m.to_int()) +
  "-" +
  pad2(d.to_int()) +
  "T" +
  pad2(hour.to_int()) +
  ":" +
  pad2(minute.to_int()) +
  ":" +
  pad2(second.to_int()) +
  "Z"
}

///|
fn pad2(n : Int32) -> String {
  if n < 10 {
    "0" + n.to_string()
  } else {
    n.to_string()
  }
}

///|
fn pad4(n : Int32) -> String {
  let s = n.to_string()
  match s.length() {
    1 => "000" + s
    2 => "00" + s
    3 => "0" + s
    _ => s
  }
}

///|
/// 共享盘剪贴板交换（vools `ClipboardFileSync`）。
///
/// - `role="push"`（p0 侧）：本机剪贴板 → 共享盘 `clipboard.txt`（内容变化才写）；
/// - `role="pull"`（p1 侧）：共享盘 `clipboard.txt` → 本机剪贴板（内容变化才设）；
/// - 文件格式：JSON `{"text","updated_at","writer"}`——用 JSON 而不是裸文本，是为了
///   让对端能区分「文件还没人写过」与「写入了空剪贴板」；
/// - 方向只有 push / pull：本机剪贴板没有时间戳，「双向收敛」会震荡（vools 同结论）。
///
/// 目标可用性：状态机 / JSON 形状三目标可用；真实文件与剪贴板操作仅 js 目标可用。
pub struct ClipboardFileSync {
  /// 交换目录（共享盘挂载点 / 本地目录）
  directory : String
  /// `"push"` 或 `"pull"`
  role : String
  /// 交换文件名（缺省 `clipboard.txt`）
  filename : String
  /// 完整路径（`directory + "/" + filename`）
  path : String
  /// 剪贴板后端（`None` 表示走自动探测；`auto_detect=false` 时保持 `None`）
  backend : &ClipboardBackend?
  /// 是否在 backend 缺省时自动探测（测试可关掉，避免碰真机剪贴板）
  auto_detect : Bool
  /// 写入方标识（写进 JSON 的 `writer` 字段）
  writer : String
  /// pull 侧上次已应用的文件文本（用于「内容未变化」判定）
  mut last_text : String?
  /// 已执行轮数 / 变化轮数（`sync_rounds` / `run_forever` 汇总）
  mut rounds_done : Int32
  mut changes_done : Int32
}

///|
/// 构造交换器；`role` 非法（不是 push / pull）返回可诊断 `Err`。
///
/// 会尝试创建交换目录（js 目标；非 js 无文件系统，留待 `sync_once` 返回可诊断原因）。
pub fn ClipboardFileSync::new(
  directory : String,
  role~ : String = "pull",
  filename~ : String = CLIP_FILE,
  backend? : &ClipboardBackend,
  writer~ : String = "rhop",
  auto_detect~ : Bool = true,
) -> Result[ClipboardFileSync, String] {
  let normalized = role.to_lower()
  if normalized != "push" && normalized != "pull" {
    return Err(
      "role 必须是 push 或 pull（双向收敛不可靠，见 vools clipboard 文档）",
    )
  }
  let dir = if directory == "" { "." } else { directory }
  let file = filename
  let path = if dir.has_suffix("/") { dir + file } else { dir + "/" + file }
  // 尽力创建目录（js：复用 LocalSharedPath::available 的建目录语义；非 js 无副作用）
  let dir_path = LocalSharedPath::new(dir)
  ignore(SharedPath::available(dir_path))
  Ok({
    directory: dir,
    role: normalized,
    filename: file,
    path,
    backend,
    auto_detect,
    writer,
    last_text: None,
    rounds_done: 0,
    changes_done: 0,
  })
}

///|
/// 角色（`"push"` / `"pull"`）。
pub fn ClipboardFileSync::role(self : ClipboardFileSync) -> String {
  self.role
}

///|
/// 交换文件完整路径。
pub fn ClipboardFileSync::path(self : ClipboardFileSync) -> String {
  self.path
}

///|
/// 写入方标识。
pub fn ClipboardFileSync::writer(self : ClipboardFileSync) -> String {
  self.writer
}

///|
/// 已执行轮数。
pub fn ClipboardFileSync::rounds(self : ClipboardFileSync) -> Int32 {
  self.rounds_done
}

///|
/// 已产生变化的轮数。
pub fn ClipboardFileSync::changes(self : ClipboardFileSync) -> Int32 {
  self.changes_done
}

///|
/// pull 侧上次应用的文本（诊断用）。
pub fn ClipboardFileSync::last_text(self : ClipboardFileSync) -> String? {
  self.last_text
}

///|
/// 解析剪贴板后端：显式注入优先；否则按 `auto_detect` 决定是否探测。
fn ClipboardFileSync::resolve_backend(
  self : ClipboardFileSync,
) -> &ClipboardBackend? {
  match self.backend {
    Some(b) => Some(b)
    None => if self.auto_detect { get_clipboard_backend() } else { None }
  }
}

///|
/// 读交换文件为对象（不存在 / 坏 JSON / 非对象 ⇒ `None`，与 vools 同）。
fn ClipboardFileSync::read_file_doc(self : ClipboardFileSync) -> Json? {
  let text = match read_text_at(self.directory, self.filename) {
    Ok(t) => t
    Err(_) => return None
  }
  let parsed = @json.parse(text) catch { _ => return None }
  match parsed {
    Object(_) => Some(parsed)
    _ => None
  }
}

///|
/// 原子写交换文件（tmp + rename；`{"text","updated_at","writer"}`，ensure_ascii=False）。
fn ClipboardFileSync::write_file(
  self : ClipboardFileSync,
  text : String,
) -> Result[Unit, String] {
  let body = canonical_object([
    ("text", Json::string(text)),
    ("updated_at", Json::string(utc_now_iso())),
    ("writer", Json::string(self.writer)),
  ])
  write_text_atomic(self.directory, self.filename, canonical_json(body))
}

///|
/// 单次同步（vools `sync_once`）：push 比「剪贴板 vs 文件」，pull 比「文件 vs 上次/剪贴板」。
///
/// 返回 Json（字段与 vools 逐条对齐）：
///   - 变化：`{"changed": true, "text_len": N}`；pull 另带 `"from_writer"`
///   - 未变化：`{"changed": false, "reason": "内容一致" / "内容未变化" / …}`
///   - 失败：`{"changed": false, "reason": "无可用剪贴板后端" / "交换文件不存在或未初始化" / "剪贴板写入失败" / "文件写入失败: …"}`
pub fn ClipboardFileSync::sync_once(self : ClipboardFileSync) -> Json {
  let outcome = if self.role == "push" {
    self.sync_push()
  } else {
    self.sync_pull()
  }
  // 统计（对齐 vools run_forever 的 rounds/changes 累计口径）
  self.rounds_done = self.rounds_done + 1
  let changed = match outcome {
    Object(fields) =>
      match fields.get("changed") {
        Some(True) => true
        _ => false
      }
    _ => false
  }
  if changed {
    self.changes_done = self.changes_done + 1
  }
  outcome
}

///|
fn ClipboardFileSync::sync_push(self : ClipboardFileSync) -> Json {
  let backend = match self.resolve_backend() {
    None => return changed_reason(false, "无可用剪贴板后端")
    Some(b) => b
  }
  let local = read_clipboard(backend~)
  let file_text = match self.read_file_doc() {
    None => ""
    Some(doc) =>
      match doc {
        Object(fields) =>
          match fields.get("text") {
            Some(String(s)) => s
            _ => ""
          }
        _ => ""
      }
  }
  if local == file_text {
    self.last_text = Some(local)
    return changed_reason(false, "内容一致")
  }
  match self.write_file(local) {
    Ok(_) => {
      self.last_text = Some(local)
      changed_with_len(true, local.char_length())
    }
    Err(e) => changed_reason(false, "文件写入失败: " + e)
  }
}

///|
fn ClipboardFileSync::sync_pull(self : ClipboardFileSync) -> Json {
  let doc = match self.read_file_doc() {
    None => return changed_reason(false, "交换文件不存在或未初始化")
    Some(d) => d
  }
  let (text, from_writer) = match doc {
    Object(fields) => {
      let t = match fields.get("text") {
        Some(String(s)) => s
        _ => ""
      }
      let w = match fields.get("writer") {
        Some(String(s)) => s
        _ => ""
      }
      (t, w)
    }
    _ => ("", "")
  }
  if self.last_text is Some(previous) && previous == text {
    return changed_reason(false, "内容未变化")
  }
  let resolved = self.resolve_backend()
  let local = match resolved {
    Some(b) => read_clipboard(backend=b)
    None => ""
  }
  if text == local {
    self.last_text = Some(text)
    return changed_reason(false, "内容一致")
  }
  let wrote = match resolved {
    Some(b) => write_clipboard(text, backend=b)
    None => false
  }
  if !wrote {
    return changed_reason(false, "剪贴板写入失败")
  }
  self.last_text = Some(text)
  canonical_object([
    ("changed", Json::boolean(true)),
    ("text_len", Json::number(text.char_length().to_double())),
    ("from_writer", Json::string(from_writer)),
  ])
}

///|
/// `{"changed": bool, "reason": string}`
fn changed_reason(changed : Bool, reason : String) -> Json {
  canonical_object([
    ("changed", Json::boolean(changed)),
    ("reason", Json::string(reason)),
  ])
}

///|
/// `{"changed": true, "text_len": N}`
fn changed_with_len(changed : Bool, len : Int32) -> Json {
  canonical_object([
    ("changed", Json::boolean(changed)),
    ("text_len", Json::number(len.to_double())),
  ])
}

///|
/// 同步跑 `rounds` 轮并返回汇总 `{"rounds": N, "changes": M}`。
///
/// 这是 `run_forever` 的**同步等价物**（vools `run_forever` 返回同形结构），
/// 供测试与一次性批处理使用；最后一轮的结果可用 `sync_once()` 单独取。
pub fn ClipboardFileSync::sync_rounds(
  self : ClipboardFileSync,
  rounds : Int32,
) -> Json {
  let n = if rounds < 0 { 0 } else { rounds }
  let mut i = 0
  while i < n {
    ignore(self.sync_once())
    i = i + 1
  }
  canonical_object([
    ("rounds", Json::number(self.rounds_done.to_double())),
    ("changes", Json::number(self.changes_done.to_double())),
  ])
}

// ---------------------------------------------------------------------------
// 周期轮询（响应式；vools 阻塞式 run_forever 的等价表达）
// ---------------------------------------------------------------------------

///|
/// 启动周期定时器（js：`setInterval`；非 js：无定时器，返回 0 且从不回调）。
#cfg(target="js")
extern "js" fn ffi_set_interval(ms : Int32, cb : () -> Unit) -> Int32 =
  #| (ms, cb) => {
  #|   try {
  #|     const timers = process.getBuiltinModule("node:timers");
  #|     const id = timers.setInterval(() => { try { cb(); } catch (_e) { /* 不让定时器中断 */ } }, ms);
  #|     return Number(id);
  #|   } catch (_e) { return 0; }
  #| }

///|
/// 清除周期定时器。
#cfg(target="js")
extern "js" fn ffi_clear_interval(id : Int32) -> Unit =
  #| (id) => { try { process.getBuiltinModule("node:timers").clearInterval(id); } catch (_e) { /* 忽略 */ } }

///|
#cfg(target="js")
fn start_interval(ms : Int32, cb : () -> Unit) -> Int32 {
  ffi_set_interval(ms, cb)
}

///|
#cfg(not(target="js"))
fn start_interval(ms : Int32, cb : () -> Unit) -> Int32 {
  ignore(ms)
  ignore(cb)
  0
}

///|
#cfg(target="js")
fn stop_interval(id : Int32) -> Unit {
  ffi_clear_interval(id)
}

///|
#cfg(not(target="js"))
fn stop_interval(id : Int32) -> Unit {
  ignore(id)
}

///|
/// 守护轮询：返回 `@rx.Observable[Json, String]`。
///
/// 语义（对齐 vools `run_forever`）：
///   - **订阅即跑一轮**（vools「至少跑一轮」，保证初始同步），把首轮结果推给订阅方；
///   - 之后每 `poll_interval_ms` 毫秒跑一轮并推送；
///   - `Subscription::dispose()` 停止轮询并 complete 流。
///
/// 与 vools 的差异（🟡）：vools 是阻塞调用（`stop_event` + 线程），本实现是非阻塞的
/// 响应式流；需要阻塞语义时用 `sync_rounds(n)` 或自行 `while` 调用 `sync_once()`。
///
/// 目标可用性：非 js 目标没有定时器，订阅后只会推送首轮（随后不再推进）。
pub fn ClipboardFileSync::run_forever(
  self : ClipboardFileSync,
  poll_interval_ms~ : Int32 = 2000,
) -> @rx.Observable[Json, String] {
  let me = self
  @rx.Observable::new(fn(
    observer : @rx.Observer[Json, String],
  ) -> @rx.Subscription {
    (observer.next)(me.sync_once())
    let timer = start_interval(poll_interval_ms, fn() {
      (observer.next)(me.sync_once())
    })
    @rx.Subscription::new(fn() {
      stop_interval(timer)
      (observer.complete)()
    })
  })
}
