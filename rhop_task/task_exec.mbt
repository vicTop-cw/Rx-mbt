// ============================================================================
// rhop_task · 执行策略与载荷执行（白名单 + 处理器注册表 + 安全 CLI）
//
// 对照 vools.rhop.task.exec：
//   - ExecPolicy：默认白名单只放行"代码内注册的动作/处理器"（action:* / handler:*），
//     任意命令行必须显式列出（cli:<prog>）或 allow_any=true 才放行；
//   - 处理器注册表：register_handler/get_handler/list_handlers，action 通道优先；
//   - CLI 通道**绝不 shell 拼接**：一律 argv 数组 + spawnSync(shell=false)，
//     并且只允许 policy 放行的程序名（防注入）。
//
// 载荷形态（与 vools 的 task payload 约定一致）：
//   {"kind":"action","name":"jump.probe","args":{...}}   → 走处理器
//   {"kind":"cli","argv":["git","--version"]}            → 走 CLI 白名单
//   省略 kind 时按字段推断（有 argv → cli；有 name/action → action）。
//
// 目标说明：CLI 执行仅 js 可用；wasm/native 下 run_payload 的 cli 通道返回可诊断失败，
// action 通道（纯 MoonBit 处理器）三目标都可用。
// ============================================================================

///|
/// 执行策略（白名单）。
pub(all) struct ExecPolicy {
  /// 允许的条目：`action:<name>` / `handler:<name>` / `cli:<prog>` / `*`
  allow : Array[String]
  /// 放开任意命令（慎用）
  allow_any : Bool
  /// 单次执行超时（秒）
  timeout_sec : Double
}

///|
/// 构造策略。
pub fn ExecPolicy::new(
  allow : Array[String],
  allow_any : Bool,
  timeout_sec : Double,
) -> ExecPolicy {
  { allow: allow.copy(), allow_any, timeout_sec, }
}

///|
/// 默认策略（与 vools DEFAULT_EXEC 一致：只放行 action:/handler:）。
pub fn ExecPolicy::default() -> ExecPolicy {
  { allow: ["action:*", "handler:*"], allow_any: false, timeout_sec: 3600.0, }
}

///|
/// 从 TaskConfig 构造。
pub fn ExecPolicy::from_config(config : TaskConfig) -> ExecPolicy {
  ExecPolicy::new(
    config.exec_allow,
    config.exec_allow_any,
    config.exec_timeout_sec,
  )
}

///|
/// 通配匹配：`pattern` 支持尾部 `*`（如 `action:*` 匹配 `action:jump.probe`），
/// 以及全通配 `*`。
fn wildcard_match(pattern : String, need : String) -> Bool {
  if pattern == "*" {
    return true
  }
  if pattern.has_suffix("*") {
    let head = match pattern.get_view(end=pattern.length() - 1) {
      Some(v) => v.to_owned()
      None => pattern
    }
    return need.has_prefix(head)
  }
  pattern == need
}

///|
/// 是否允许某个需求（need 形如 `action:jump.probe` / `cli:git`）。
pub fn ExecPolicy::allows(self : ExecPolicy, need : String) -> Bool {
  if self.allow_any {
    return true
  }
  for p in self.allow {
    if wildcard_match(p, need) {
      return true
    }
  }
  false
}

// ---------------------------------------------------------------------------
// 处理器注册表
// ---------------------------------------------------------------------------

///|
/// 处理器签名：入参为 args 对象，返回结果 JSON 或可诊断 Err。
pub type Handler = (Json) -> Result[Json, String]

///|
/// 全局处理器注册表（进程内）。
let handlers : @ref.Ref[Map[String, Handler]] = @ref.Ref::new(Map::new())

///|
/// 注册（或覆盖）一个处理器。
pub fn register_handler(name : String, handler : Handler) -> Unit {
  let m = handlers.val.copy()
  m[name] = handler
  handlers.val = m
}

///|
/// 取处理器。
pub fn get_handler(name : String) -> Handler? {
  handlers.val.get(name)
}

///|
/// 列出已注册处理器名（字典序，便于断言）。
pub fn list_handlers() -> Array[String] {
  let out : Array[String] = []
  for k, _ in handlers.val {
    out.push(k)
  }
  out.sort()
  out
}

///|
/// 清空注册表（测试隔离用）。
pub fn clear_handlers() -> Unit {
  handlers.val = Map::new()
}

// ---------------------------------------------------------------------------
// 载荷解析与执行
// ---------------------------------------------------------------------------

///|
/// 执行结果。
pub(all) struct ExecResult {
  /// 是否成功
  ok : Bool
  /// 走的通道：action / cli / unknown
  channel : String
  /// 成功输出（JSON 文本或进程 stdout）
  output : String
  /// 失败原因
  error : String?
  /// 耗时（毫秒）
  duration_ms : Int64
}

///|
/// 构造结果。
fn exec_ok(
  channel : String,
  output : String,
  duration_ms : Int64,
) -> ExecResult {
  { ok: true, channel, output, error: None, duration_ms, }
}

///|
/// 构造失败。
fn exec_err(
  channel : String,
  error : String,
  duration_ms : Int64,
) -> ExecResult {
  { ok: false, channel, output: "", error: Some(error), duration_ms, }
}

///|
/// 识别载荷类型：`action` / `cli` / `unknown`。
pub fn detect_language(payload : Json) -> String {
  match payload {
    Object(m) =>
      match m.get("kind") {
        Some(String(k)) =>
          match k {
            "action" | "handler" => "action"
            "cli" | "cmd" | "command" => "cli"
            _ => "unknown"
          }
        _ =>
          if m.contains("argv") || m.contains("cmd") {
            "cli"
          } else if m.contains("name") || m.contains("action") {
            "action"
          } else {
            "unknown"
          }
      }
    _ => "unknown"
  }
}

///|
/// 取载荷里的字符串字段。
fn payload_str(m : Map[String, Json], key : String) -> String? {
  match m.get(key) {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
/// 取载荷里的 argv（字符串数组）。
fn payload_argv(m : Map[String, Json]) -> Array[String] {
  let out : Array[String] = []
  match m.get("argv") {
    Some(Array(items)) =>
      for it in items {
        match it {
          String(s) => out.push(s)
          _ => ()
        }
      }
    Some(String(s)) => out.push(s)
    _ => ()
  }
  out
}

///|
/// 执行一个载荷（action 通道优先；cli 通道受白名单与超时约束，绝不经 shell）。
pub fn run_payload(policy : ExecPolicy, payload : Json) -> ExecResult {
  let started = @env.now()
  let finish = fn(r : ExecResult) -> ExecResult {
    { ..r, duration_ms: @env.now().to_int64() - started.to_int64(), }
  }
  let lang = detect_language(payload)
  let obj = match payload {
    Object(m) => m
    _ =>
      return finish(
        exec_err("unknown", "rhop_task: 载荷必须是 JSON 对象", 0L),
      )
  }
  match lang {
    "action" => {
      let name = match payload_str(obj, "name") {
        Some(n) => n
        None =>
          match payload_str(obj, "action") {
            Some(n) => n
            None => ""
          }
      }
      if name == "" {
        return finish(
          exec_err("action", "rhop_task: action 载荷缺少 name", 0L),
        )
      }
      let need = "action:" + name
      if !policy.allows(need) && !policy.allows("handler:" + name) {
        return finish(
          exec_err(
            "action",
            "rhop_task: 执行策略拒绝 " +
            need +
            "（allow=[" +
            policy.allow.join(", ") +
            "], allow_any=" +
            policy.allow_any.to_string() +
            "）",
            0L,
          ),
        )
      }
      let args = match obj.get("args") {
        Some(v) => v
        None => Json::null()
      }
      match get_handler(name) {
        None =>
          finish(
            exec_err(
              "action",
              "rhop_task: 未注册的处理器 action:" + name,
              0L,
            ),
          )
        Some(h) =>
          match h(args) {
            Ok(out) => finish(exec_ok("action", Json::stringify(out), 0L))
            Err(e) => finish(exec_err("action", e, 0L))
          }
      }
    }
    "cli" => {
      let argv = payload_argv(obj)
      if argv.length() == 0 {
        return finish(exec_err("cli", "rhop_task: cli 载荷缺少 argv", 0L))
      }
      let prog = argv[0]
      let need = "cli:" + prog
      if !policy.allows(need) {
        return finish(
          exec_err(
            "cli",
            "rhop_task: 执行策略拒绝 " +
            need +
            "（默认只放行 action:/handler:；任意命令需显式加入 allow 或 allow_any=true）",
            0L,
          ),
        )
      }
      let args : Array[String] = []
      for i in 1..<argv.length() {
        args.push(argv[i])
      }
      let timeout_ms = (policy.timeout_sec * 1000.0).to_int()
      match run_cli(prog, args, timeout_ms) {
        Err(e) => finish(exec_err("cli", e, 0L))
        Ok(pair) => {
          let (status, stdout, stderr) = pair
          if status == 0 {
            finish(exec_ok("cli", stdout, 0L))
          } else {
            finish({
              ok: false,
              channel: "cli",
              output: stdout,
              error: Some(
                "退出码 " +
                status.to_string() +
                (if stderr == "" { "" } else { "；stderr: " + stderr }),
              ),
              duration_ms: @env.now().to_int64() - started.to_int64(),
            })
          }
        }
      }
    }
    _ =>
      finish(exec_err("unknown", "rhop_task: 无法识别的载荷类型", 0L))
  }
}

// ---------------------------------------------------------------------------
// CLI 执行（argv 数组 + shell=false；非 js 可诊断 Err）
// ---------------------------------------------------------------------------

///|
/// 同步执行一个程序（argv 数组，**不经 shell**），返回 (退出码, stdout, stderr)。
///
/// 仅 js 目标；返回的退出码 -1 表示无法启动（错误文本在 stderr 里）。
#cfg(target="js")
extern "js" fn ffi_run_cli(
  prog : String,
  args_json : String,
  timeout_ms : Int32,
) -> String =
  #| (prog, argsJson, timeout) => { try { const cp = process.getBuiltinModule("node:child_process"); const args = JSON.parse(String(argsJson || "[]")).map((x) => String(x)); const r = cp.spawnSync(String(prog), args, { encoding: "utf8", timeout: Number(timeout), shell: false, windowsHide: true, maxBuffer: 8 * 1024 * 1024 }); if (r.error) { return JSON.stringify({ status: -1, stdout: "", stderr: String((r.error && r.error.message) || r.error) }); } return JSON.stringify({ status: (r.status === null ? -1 : Number(r.status)), stdout: String(r.stdout || ""), stderr: String(r.stderr || "") }); } catch (e) { return JSON.stringify({ status: -1, stdout: "", stderr: String((e && e.message) || e) }); } }

///|
/// js：解析上面的 JSON 结果。
#cfg(target="js")
fn run_cli(
  prog : String,
  args : Array[String],
  timeout_ms : Int32,
) -> Result[(Int32, String, String), String] {
  let args_json = Json::stringify(
    Json::array(args.map(fn(a) { Json::string(a) })),
  )
  let out = ffi_run_cli(prog, args_json, timeout_ms)
  let j = @json.parse(out) catch {
    _ => return Err("rhop_task: cli 返回非 JSON: " + out)
  }
  match j {
    { "status": Number(st, ..), "stdout": String(so), "stderr": String(se), .. } =>
      Ok((st.to_int(), so, se))
    _ => Err("rhop_task: cli 返回结构意外: " + out)
  }
}

///|
/// 非 js：无子进程能力，返回可诊断 Err。
#cfg(not(target="js"))
fn run_cli(
  prog : String,
  args : Array[String],
  timeout_ms : Int32,
) -> Result[(Int32, String, String), String] {
  Err(
    "rhop_task: CLI 执行仅 js 目标可用（wasm/native 无子进程能力）",
  )
}
