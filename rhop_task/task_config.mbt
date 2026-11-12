// ============================================================================
// rhop_task · 任务队列配置（方向驱动 + 存储后端 + 明文/密文）
//
// 对照 vools.rhop.task.config。配置形态（JSON 对象）：
//
// {
//   "name": "rhop-link",
//   "role": "A",                                  // A=提交方 | B=执行方 | C=中转
//   "key":  {"plain": "", "cipher": "RHOP-ENC:…", "path": "", "env": "RHOP_KEY"},
//   "shared": {"write": "E:/share/rhop", "read": "//nas/share/rhop"},
//   "online": [{"kind": "sftp", "host": "…", "password_cipher": "…"}],
//   "relay":  {"host": "127.0.0.1", "port": 0, "token_cipher": ""},
//   "queue": {
//     "store": {"kind": "sqlite-shared"},         // sqlite-shared(默认) | sqlite-local
//     "heartbeat": {"file": "rhop-link.heartbeat", "interval_sec": 5, "stale_after_sec": 15},
//     "poll_interval_sec": 2, "max_retries": 3, "retry_delay_min": 5,
//     "timeout_min": 60, "encrypt_result": true, "result_max_bytes": 65536
//   },
//   "exec": {"allow": ["action:*"], "allow_any": false, "timeout_sec": 3600}
// }
//
// 职责：方向归一（A/B/C ↔ SEND/RECV/RELAY）→ 敏感信息解析（明文告警 + 密文解密）
// → 默认值合并与校验 → 暴露只读访问器。
//
// 与 vools 的差异（均为解耦需要，已回报）：
//   - vools 的 `TaskConfig` 内嵌一个 `RhopConfig`（Batch C 的产物）并从中取
//     shared/session/crypto；这里**不依赖** rhop/config.mbt，自带 shared/online/relay
//     的原始配置与解析后的密钥，P2b 的 store/heartbeat 直接吃这里的字段。
//   - `_validate_shared_root`（vools BUG-302 的落点校验）留给 P2b 真正开库时做：
//     本层只做「形态解析」，不触碰文件系统，保持 `config --print` 零副作用。
//
// 目标说明：纯逻辑三目标通用；`from_file` 需读文件，仅 js 可用，其余目标 Err。
// ============================================================================

///|
/// 会话/队列方向（vools `session.Role`：SEND / RECV / RELAY）。
#derive(Eq, Debug)
pub(all) enum TaskRole {
  /// A 侧：提交方
  Send
  /// B 侧：执行方
  Recv
  /// C 侧：中转
  Relay
}

///|
pub extend TaskRole with Eq::{not_equal, equal}
///|
pub extend TaskRole with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// 序列化为 vools 字面量（大写）。
pub fn TaskRole::to_string(self : TaskRole) -> String {
  match self {
    Send => "SEND"
    Recv => "RECV"
    Relay => "RELAY"
  }
}

///|
/// 短方向（显示/日志用：A / B / C）。
pub fn TaskRole::short(self : TaskRole) -> String {
  match self {
    Send => "A"
    Recv => "B"
    Relay => "C"
  }
}

///|
/// 方向别名表（与 vools `ROLE_ALIASES` 一致）。
///
/// A → SEND；B → RECV；C → RELAY，另接受 REQUESTER/SUBMIT/EXECUTOR/SERVER/WORKER 等写法。
pub fn normalize_role(value : String) -> Result[TaskRole, String] {
  let text = value
    .trim()
    .to_owned()
    .to_upper()
    .replace_all(old="-", new="_")
    .replace_all(old=" ", new="_")
  if text == "" {
    return Err(
      "配置缺少 role/direction（A=提交方 / B=执行方 / C=中转）",
    )
  }
  match text {
    "A" | "SEND" | "REQUESTER" | "SUBMIT" => Ok(Send)
    "B" | "RECV" | "RECEIVE" | "EXECUTOR" | "SERVER" | "WORKER" => Ok(Recv)
    "C" | "RELAY" | "RELAY_SERVER" => Ok(Relay)
    _ =>
      Err(
        "未知方向 role=\"" +
        value +
        "\"（可用 A / B / C，也接受 SEND / RECV / RELAY）",
      )
  }
}

// ---------------------------------------------------------------------------
// JSON 小工具
// ---------------------------------------------------------------------------

///|
/// 取 JSON 对象里的值（非对象 → None）。
fn jget(v : Json, key : String) -> Json? {
  match v {
    Object(m) => m.get(key)
    _ => None
  }
}

///|
/// JSON 值 → 字符串（仅 String 命中）。
fn jstr(v : Json?) -> String? {
  match v {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
/// JSON 值 → Double（仅 Number 命中；字符串形态也容忍）。
fn jdouble(v : Json?) -> Double? {
  match v {
    Some(Number(n, ..)) => Some(n)
    Some(String(s)) => {
      let parsed = @json.parse(s) catch { _ => return None }
      match parsed {
        Number(n, ..) => Some(n)
        _ => None
      }
    }
    _ => None
  }
}

///|
/// JSON 值 → Int。
fn jint(v : Json?) -> Int32? {
  match jdouble(v) {
    Some(n) => Some(n.to_int())
    None => None
  }
}

///|
/// JSON 值 → Bool（容忍 0/1 与 "true"/"false"）。
fn jbool(v : Json?) -> Bool? {
  match v {
    Some(True) => Some(true)
    Some(False) => Some(false)
    Some(Number(n, ..)) => Some(n != 0.0)
    Some(String(s)) =>
      match s.trim().to_owned().to_lower() {
        "true" | "1" | "yes" => Some(true)
        "false" | "0" | "no" => Some(false)
        _ => None
      }
    _ => None
  }
}

///|
/// JSON 值 → 字符串数组（容忍单值）。
fn jstr_array(v : Json?) -> Array[String] {
  let out : Array[String] = []
  match v {
    Some(Array(items)) =>
      for it in items {
        match it {
          String(s) => out.push(s)
          _ => ()
        }
      }
    Some(String(s)) => if s.trim().to_owned() != "" { out.push(s) }
    _ => ()
  }
  out
}

///|
/// 深度合并两个 JSON 对象（override 优先；嵌套对象递归合并，数组/标量直接覆盖）。
fn deep_merge(base : Json, overrides : Json) -> Json {
  match (base, overrides) {
    (Object(b), Object(o)) => {
      let out : Map[String, Json] = Map([], capacity=0)
      for k, v in b {
        out[k] = v
      }
      for k, v in o {
        match out.get(k) {
          Some(existing) => out[k] = deep_merge(existing, v)
          None => out[k] = v
        }
      }
      Json::object(out)
    }
    (_, o) => o
  }
}

///|
/// 把「字符串简写」或对象统一成对象（`{key_name: 字符串}`）。
fn as_dict(value : Json?, key_name : String) -> Result[Json, String] {
  match value {
    None => Ok(Json::object(Map([], capacity=0)))
    Some(Object(_)) =>
      match value {
        Some(v) => Ok(v)
        None => Ok(Json::object(Map([], capacity=0)))
      }
    Some(String(s)) => {
      let m : Map[String, Json] = Map([], capacity=0)
      m[key_name] = Json::string(s)
      Ok(Json::object(m))
    }
    Some(other) =>
      Err(
        "配置 \{key_name} 必须是 JSON 对象或字符串简写，实际 \{Json::stringify(other)}",
      )
  }
}

// ---------------------------------------------------------------------------
// 默认值
// ---------------------------------------------------------------------------

///|
/// queue 段默认值（与 vools `DEFAULT_QUEUE` 对齐，含 P2b 会用到的 file_channel）。
pub fn default_queue() -> Json {
  Json::object({
    "store": Json::object({ "kind": Json::string("sqlite-shared") }),
    "heartbeat": Json::object({
      "file": Json::string(""),
      "interval_sec": Json::number(5.0),
      "stale_after_sec": Json::number(15.0),
      "closed_token": Json::string("closed"),
    }),
    "poll_interval_sec": Json::number(2.0),
    "max_retries": Json::number(3.0),
    "retry_delay_min": Json::number(5.0),
    "timeout_min": Json::number(60.0),
    "encrypt_result": Json::boolean(true),
    "result_max_bytes": Json::number(65536.0),
    "lock_ttl_sec": Json::number(900.0),
    "file_channel": Json::object({
      "enabled": Json::boolean(false),
      "dir": Json::string(""),
      "max_bytes": Json::number(1048576.0),
      "keep_days": Json::number(7.0),
      "payload_max_bytes": Json::number(0.0),
    }),
  })
}

///|
/// exec 段默认值（默认白名单：只放行代码内注册的 rhop 动作与处理器）。
pub fn default_exec() -> Json {
  Json::object({
    "allow": Json::array([Json::string("action:*"), Json::string("handler:*")]),
    "allow_any": Json::boolean(false),
    "workdir": Json::string(""),
    "env": Json::object(Map([], capacity=0)),
    "timeout_sec": Json::number(3600.0),
    "shell": Json::boolean(false),
  })
}

// ---------------------------------------------------------------------------
// TaskConfig
// ---------------------------------------------------------------------------

///|
/// 任务队列配置（读配置 + 只读访问器；不直接开库/开心跳，保持 `--print` 零副作用）。
pub(all) struct TaskConfig {
  /// 配置名（缺省 "rhop"）
  name : String
  /// 方向
  role : TaskRole
  /// 基准目录（相对路径解析基准）
  base_dir : String
  /// 已解析的主密钥（明文；空串表示没有配密钥）
  key : String
  /// 主密钥来源：plain / cipher / path / env / none
  key_source : String
  /// 敏感信息已解析后的整棵配置（密文已解密、明文已告警）
  resolved : Json
  /// 解析发现（明文/密文/path/env/kept）
  findings : Array[SecretFinding]
  /// shared 写端地址（未配置为 None）
  shared_write : String?
  /// shared 读端地址（未配置为 None）
  shared_read : String?
  /// online 通道原始配置
  online : Array[Json]
  /// relay 原始配置
  relay : Json?
  /// 存储后端种类：sqlite-shared / sqlite-local
  store_kind : String
  /// 心跳文件名
  heartbeat_file : String
  /// 心跳写间隔（秒）
  heartbeat_interval_sec : Double
  /// 心跳判死阈值（秒）
  heartbeat_stale_after_sec : Double
  /// 轮询间隔（秒）
  poll_interval_sec : Double
  /// 默认最大重试次数
  max_retries : Int32
  /// 默认重试间隔（分钟）
  retry_delay_min : Double
  /// 默认执行超时（分钟）
  timeout_min : Double
  /// 结果是否加密回传
  encrypt_result : Bool
  /// 结果最大字节数
  result_max_bytes : Int32
  /// 锁 TTL（秒）
  lock_ttl_sec : Double
  /// 执行白名单
  exec_allow : Array[String]
  /// 是否放开任意命令
  exec_allow_any : Bool
  /// 单任务执行超时（秒）
  exec_timeout_sec : Double
  /// 合并默认值后的 queue 段（P2b 直接消费）
  queue : Json
  /// 合并默认值后的 exec 段
  exec : Json
}

///|
/// 配置名（缺省 "rhop"）。
pub fn TaskConfig::name(self : TaskConfig) -> String {
  self.name
}

///|
/// 短方向（A / B / C）。
pub fn TaskConfig::role_short(self : TaskConfig) -> String {
  self.role.short()
}

///|
/// 长方向（SEND / RECV / RELAY）。
pub fn TaskConfig::role_long(self : TaskConfig) -> String {
  self.role.to_string()
}

///|
/// 是否配置了主密钥。
pub fn TaskConfig::has_key(self : TaskConfig) -> Bool {
  self.key != ""
}

///|
/// 构造加解密对象（未配密钥时 None）。
pub fn TaskConfig::build_crypto(self : TaskConfig) -> @rp.RhopCrypto? {
  if self.key == "" {
    None
  } else {
    Some(@rp.RhopCrypto::from_key(self.key))
  }
}

///|
/// worker 标识（配置优先，缺省 `<name>-<方向小写>`）。
pub fn TaskConfig::worker_id(self : TaskConfig) -> String {
  match jstr(jget(self.queue, "worker_id")) {
    Some(w) =>
      if w.trim().to_owned() != "" {
        w
      } else {
        self.name + "-" + self.role.short().to_lower()
      }
    None => self.name + "-" + self.role.short().to_lower()
  }
}

///|
/// 只挑出「用了明文」的发现（CI 卡口 / CLI 汇总用）。
pub fn TaskConfig::plaintext_findings(
  self : TaskConfig,
) -> Array[SecretFinding] {
  let out : Array[SecretFinding] = []
  for f in self.findings {
    if f.action == "plaintext" {
      out.push(f)
    }
  }
  out
}

///|
/// 解析主密钥：明文 / 密文（用 path|env 提供的外层密钥解）/ path / env。
///
/// 返回 `(密钥文本, 来源标记)`。来源标记用于诊断与 `describe()`。
fn resolve_master_key(
  key_cfg : Json?,
  resolver : SecretResolver,
) -> Result[(String, String), String] {
  match key_cfg {
    None =>
      // 无 key 字段：退到环境变量；仍没有则空串（允许"只跑本地命令"的配置）
      match @env.get_env_var(@rp.ENV_RHOP_KEY) {
        Some(v) => if v != "" { Ok((v, "env")) } else { Ok(("", "none")) }
        None => Ok(("", "none"))
      }
    Some(Json::Null) => Ok(("", "none"))
    Some(String(s)) =>
      if s == "" {
        Ok(("", "none"))
      } else {
        // 字符串写法 = 明文主密钥（必须告警）
        match
          resolver.flag_plaintext(
            "key",
            "⚠ 配置字段 'key' 使用了明文主密钥。\n      " +
            command_hint("key", None, None),
          ) {
          Err(e) => Err(e)
          Ok(_) => Ok((s, "plain"))
        }
      }
    Some(Object(m)) => {
      let plain = jstr(m.get("plain"))
      let cipher = jstr(m.get("cipher"))
      let path = jstr(m.get("path"))
      let env_name = jstr(m.get("env"))
      match plain {
        Some(p) =>
          if p != "" {
            // 明文主密钥：告警后采用
            match
              resolver.flag_plaintext(
                "key.plain",
                "⚠ 配置字段 'key.plain' 使用了明文主密钥。\n      " +
                command_hint("key", None, Some("key.cipher")),
              ) {
              Err(e) => return Err(e)
              Ok(_) => return Ok((p, "plain"))
            }
          }
        None => ()
      }
      match cipher {
        Some(c) =>
          if c != "" {
            // 密文主密钥：用 path/env 提供的外层密钥解开（避免"自己解自己"）
            let env_eff = match env_name {
              Some(e) => e
              None => @rp.ENV_RHOP_KEY
            }
            let unlock = match @rp.load_key(None, path, env_eff) {
              Ok(k) => k
              Err(e) =>
                return Err(
                  "配置 key.cipher 是密文，但缺少解开它的外层密钥：请设置 \{env_eff} 环境变量或 key.path（\{e}）",
                )
            }
            let crypto = @rp.RhopCrypto::from_key(unlock)
            return match crypto.decrypt_secret(c) {
              Ok(k) => Ok((k, "cipher"))
              Err(e) => Err("配置 key.cipher 解密失败：\{e}")
            }
          }
        None => ()
      }
      // 只有 path / env
      let env_eff = match env_name {
        Some(e) => e
        None => @rp.ENV_RHOP_KEY
      }
      match @rp.load_key(None, path, env_eff) {
        Ok(k) => if path is Some(_) { Ok((k, "path")) } else { Ok((k, "env")) }
        Err(e) =>
          Err("配置 key 无法解析（path/env 均不可用）：\{e}")
      }
    }
    Some(other) =>
      Err(
        "配置 key 必须是字符串或对象，实际 \{Json::stringify(other)}",
      )
  }
}

///|
/// 从 JSON 对象构造配置。
///
/// - `base_dir`：基准目录（None 时取 `data.base_dir`，再退到当前工作目录）
/// - `strict_secrets`：true 时明文敏感字段直接 Err（CI 卡口）
/// - `warn_plaintext`：是否输出明文告警
/// - `warner`：告警通道（None 时只记 findings）
pub fn TaskConfig::from_dict(
  data : Json,
  base_dir : String?,
  strict_secrets : Bool,
  warn_plaintext : Bool,
  warner : ((String) -> Unit)?,
) -> Result[TaskConfig, String] {
  match data {
    Object(_) => ()
    _ => return Err("配置必须是 JSON 对象（dict）")
  }
  // 1) 方向：role > direction > rhop_role
  let role_text = match jstr(jget(data, "role")) {
    Some(v) => v
    None =>
      match jstr(jget(data, "direction")) {
        Some(v) => v
        None =>
          match jstr(jget(data, "rhop_role")) {
            Some(v) => v
            None => ""
          }
      }
  }
  let role = match normalize_role(role_text) {
    Ok(r) => r
    Err(e) => return Err(e)
  }
  // 2) base_dir：参数 > data.base_dir > 当前工作目录 > "."
  let base = match base_dir {
    Some(b) => if b != "" { b } else { "" }
    None => ""
  }
  let base = if base != "" {
    base
  } else {
    match jstr(jget(data, "base_dir")) {
      Some(b) =>
        if b != "" {
          b
        } else {
          match @env.current_dir() {
            Some(d) => d
            None => "."
          }
        }
      None =>
        match @env.current_dir() {
          Some(d) => d
          None => "."
        }
    }
  }
  // 3) 主密钥（最先确定：它是解其它密文的钥匙）
  let mut master = SecretResolver::new(None, strict_secrets, warn_plaintext, [])
  match warner {
    Some(w) => master = master.with_warner(w)
    None => ()
  }
  let (key_text, key_source) = match
    resolve_master_key(jget(data, "key"), master) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let crypto = if key_text == "" {
    None
  } else {
    Some(@rp.RhopCrypto::from_key(key_text))
  }
  // 4) 整棵配置的敏感信息解析（key 整棵跳过，由上面专门处理）
  let resolved_pair = match
    resolve_config_secrets(
      data,
      crypto,
      strict_secrets,
      warn_plaintext,
      default_skip_paths(),
    ) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let mut resolved = resolved_pair.0
  let mut findings = resolved_pair.1
  findings = master.findings() + findings
  // 主密钥回写进 resolved（key 节点被 skip 过，保持原样；字符串写法归一为密文持有者形态）
  resolved = match resolved {
    Object(m) => {
      let out : Map[String, Json] = Map([], capacity=0)
      for k, v in m {
        out[k] = v
      }
      out["role"] = Json::string(role.to_string())
      out["key"] = Json::string(key_text)
      Json::object(out)
    }
    other => other
  }
  // 5) 名称
  let name = match jstr(jget(resolved, "name")) {
    Some(n) => if n.trim().to_owned() == "" { "rhop" } else { n }
    None => "rhop"
  }
  // 6) shared：字符串简写（写读同址）或 {write, read}
  let (shared_write, shared_read) = match jget(resolved, "shared") {
    Some(String(s)) => if s == "" { (None, None) } else { (Some(s), Some(s)) }
    Some(Object(m)) => {
      let w = jstr(m.get("write"))
      let r = jstr(m.get("read"))
      match w {
        Some(wv) =>
          match r {
            Some(rv) => (Some(wv), Some(rv))
            None => (Some(wv), Some(wv))
          }
        None =>
          match r {
            Some(rv) => (Some(rv), Some(rv))
            None => (None, None)
          }
      }
    }
    _ => (None, None)
  }
  // 7) queue 段：深合并默认值
  let queue_raw = match as_dict(jget(resolved, "queue"), "queue") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let queue = deep_merge(default_queue(), queue_raw)
  // store：兼容 queue.store = {kind} / 字符串，或 queue.store_kind
  let store_raw = match jget(queue_raw, "store") {
    Some(v) => v
    None =>
      match jget(queue_raw, "store_kind") {
        Some(v) => v
        None => Json::object(Map([], capacity=0))
      }
  }
  let store_spec = match as_dict(Some(store_raw), "kind") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let default_store = Json::object({ "kind": Json::string("sqlite-shared") })
  let store = deep_merge(default_store, store_spec)
  let store_kind = match jstr(jget(store, "kind")) {
    Some(k) => k
    None => "sqlite-shared"
  }
  if store_kind != "sqlite-shared" && store_kind != "sqlite-local" {
    return Err(
      "未知存储后端 queue.store.kind=\"" +
      store_kind +
      "\"（可用: sqlite-shared / sqlite-local）",
    )
  }
  // heartbeat
  let hb_raw_in = jget(queue_raw, "heartbeat")
  let hb_raw = match hb_raw_in {
    Some(String(s)) => Json::object({ "file": Json::string(s) })
    Some(Object(_)) =>
      match hb_raw_in {
        Some(v) => v
        None => Json::object(Map([], capacity=0))
      }
    Some(other) =>
      return Err(
        "配置 queue.heartbeat 必须是对象或文件名字符串，实际 \{Json::stringify(other)}",
      )
    None => Json::object(Map([], capacity=0))
  }
  let default_hb = Json::object({
    "file": Json::string(""),
    "interval_sec": Json::number(5.0),
    "stale_after_sec": Json::number(15.0),
    "closed_token": Json::string("closed"),
  })
  let hb = deep_merge(default_hb, hb_raw)
  let hb_file = match jstr(jget(hb, "file")) {
    Some(f) => if f == "" { name + ".heartbeat" } else { f }
    None => name + ".heartbeat"
  }
  let hb_interval = jdouble(jget(hb, "interval_sec")).unwrap_or(5.0)
  let hb_stale = jdouble(jget(hb, "stale_after_sec")).unwrap_or(15.0)
  if hb_stale < hb_interval + 1.0 {
    return Err(
      "心跳判死阈值过小：stale_after_sec=\{hb_stale.to_string()} 必须 ≥ interval_sec=\{hb_interval.to_string()} + 1s（历史缺陷 BUG-282：秒精度截断误差会把刚写完心跳的一方判成 stale）",
    )
  }
  // 8) exec 段
  let exec_raw = match as_dict(jget(resolved, "exec"), "exec") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let exec = deep_merge(default_exec(), exec_raw)
  let exec_allow = jstr_array(jget(exec, "allow"))
  let exec_allow_any = jbool(jget(exec, "allow_any")).unwrap_or(false)
  let exec_timeout_sec = jdouble(jget(exec, "timeout_sec")).unwrap_or(3600.0)
  // 9) 其余标量
  let poll_interval_sec = jdouble(jget(queue, "poll_interval_sec")).unwrap_or(
    2.0,
  )
  let max_retries = jint(jget(queue, "max_retries")).unwrap_or(3)
  let retry_delay_min = jdouble(jget(queue, "retry_delay_min")).unwrap_or(5.0)
  let timeout_min = jdouble(jget(queue, "timeout_min")).unwrap_or(60.0)
  let encrypt_result = jbool(jget(queue, "encrypt_result")).unwrap_or(true)
  let result_max_bytes = jint(jget(queue, "result_max_bytes")).unwrap_or(65536)
  let lock_ttl_sec = jdouble(jget(queue, "lock_ttl_sec")).unwrap_or(900.0)
  // online / relay 原样保留给 P2b
  let online : Array[Json] = match jget(resolved, "online") {
    Some(Array(items)) => items.copy()
    _ => []
  }
  let relay = jget(resolved, "relay")
  Ok({
    name,
    role,
    base_dir: base,
    key: key_text,
    key_source,
    resolved,
    findings,
    shared_write,
    shared_read,
    online,
    relay,
    store_kind,
    heartbeat_file: hb_file,
    heartbeat_interval_sec: hb_interval,
    heartbeat_stale_after_sec: hb_stale,
    poll_interval_sec,
    max_retries,
    retry_delay_min,
    timeout_min,
    encrypt_result,
    result_max_bytes,
    lock_ttl_sec,
    exec_allow,
    exec_allow_any,
    exec_timeout_sec,
    queue,
    exec,
  })
}

///|
/// 从 JSON **文本**构造（base_dir 缺省取当前工作目录）。
pub fn TaskConfig::from_json_text(
  text : String,
  base_dir : String?,
  strict_secrets : Bool,
  warn_plaintext : Bool,
  warner : ((String) -> Unit)?,
) -> Result[TaskConfig, String] {
  let data = @json.parse(text) catch {
    _ => return Err("配置 JSON 解析失败")
  }
  TaskConfig::from_dict(data, base_dir, strict_secrets, warn_plaintext, warner)
}

///|
/// 明文脱敏：把 JSON 里指定键的值替换成打码值（逐层重建，不改原对象）。
fn mask_keys(node : Json, keys : Array[String]) -> Json {
  match node {
    Object(m) => {
      let out : Map[String, Json] = Map([], capacity=0)
      for k, v in m {
        let hit = keys.contains(k)
        if hit {
          match v {
            String(s) => out[k] = Json::string(mask_value_default(s))
            Null => out[k] = v
            other =>
              out[k] = Json::string(mask_value_default(Json::stringify(other)))
          }
        } else {
          out[k] = mask_keys(v, keys)
        }
      }
      Json::object(out)
    }
    Array(items) => {
      let out : Array[Json] = []
      for it in items {
        out.push(mask_keys(it, keys))
      }
      Json::array(out)
    }
    other => other
  }
}

///|
/// 导出配置（`mask=true` 时敏感值打码，绝不回显明文）。
pub fn TaskConfig::to_dict(self : TaskConfig, mask : Bool) -> Json {
  let base = match self.resolved {
    Object(m) => {
      let out : Map[String, Json] = Map([], capacity=0)
      for k, v in m {
        out[k] = v
      }
      Json::object(out)
    }
    other => other
  }
  // 覆盖派生字段
  let with_derived = deep_merge(
    base,
    Json::object({
      "role": Json::string(self.role.to_string()),
      "name": Json::string(self.name),
      "base_dir": Json::string(self.base_dir),
      "key": Json::string(self.key),
    }),
  )
  if !mask {
    return with_derived
  }
  // 打码：key / sftp|relay 的 password,token,key_path / online[*] 的 password,token /
  // queue.heartbeat.token
  let masked_all = mask_keys(with_derived, [
    "password", "token", "key_path", "password_cipher", "token_cipher",
  ])
  match masked_all {
    Object(m) => {
      let out : Map[String, Json] = Map([], capacity=0)
      for k, v in m {
        out[k] = v
      }
      out["key"] = Json::string(if self.key == "" { "" } else { "***" })
      Json::object(out)
    }
    other => other
  }
}

///|
/// 自描述（CLI `config --print` 的结构化输出）。
pub fn TaskConfig::describe(self : TaskConfig) -> Json {
  let plaintext_fields : Array[Json] = []
  for f in self.plaintext_findings() {
    plaintext_fields.push(Json::string(f.path))
  }
  Json::object({
    "name": Json::string(self.name),
    "role": Json::string(self.role.short()),
    "role_long": Json::string(self.role.to_string()),
    "base_dir": Json::string(self.base_dir),
    "has_key": Json::boolean(self.has_key()),
    "key_source": Json::string(self.key_source),
    "shared": Json::object({
      "write": match self.shared_write {
        Some(v) => Json::string(v)
        None => Json::null()
      },
      "read": match self.shared_read {
        Some(v) => Json::string(v)
        None => Json::null()
      },
    }),
    "store": Json::object({ "kind": Json::string(self.store_kind) }),
    "heartbeat": Json::object({
      "file": Json::string(self.heartbeat_file),
      "interval_sec": Json::number(self.heartbeat_interval_sec),
      "stale_after_sec": Json::number(self.heartbeat_stale_after_sec),
    }),
    "worker_id": Json::string(self.worker_id()),
    "poll_interval_sec": Json::number(self.poll_interval_sec),
    "exec": Json::object({
      "allow": Json::array(self.exec_allow.map(fn(x) { Json::string(x) })),
      "allow_any": Json::boolean(self.exec_allow_any),
      "timeout_sec": Json::number(self.exec_timeout_sec),
    }),
    "plaintext_fields": Json::array(plaintext_fields),
  })
}

// ---------------------------------------------------------------------------
// 文件入口（仅 js 可读文件；其它目标可诊断 Err）
// ---------------------------------------------------------------------------

///|
/// 从配置文件构造（base_dir 缺省取配置文件所在目录）。可用性：仅 js 目标。
pub fn TaskConfig::from_file(
  path : String,
  strict_secrets : Bool,
  warn_plaintext : Bool,
  warner : ((String) -> Unit)?,
) -> Result[TaskConfig, String] {
  let text = match read_config_file(path) {
    Ok(t) => t
    Err(e) => return Err("读取配置文件失败: \{path}: \{e}")
  }
  let dir = parent_dir(path)
  TaskConfig::from_json_text(
    text,
    Some(dir),
    strict_secrets,
    warn_plaintext,
    warner,
  )
}

///|
/// 便捷入口：配置文件路径或 JSON 文本 → TaskConfig（以首个非空白字符区分）。
pub fn load_task_config(
  path_or_json : String,
  strict_secrets : Bool,
  warn_plaintext : Bool,
  warner : ((String) -> Unit)?,
) -> Result[TaskConfig, String] {
  let t = path_or_json.trim().to_owned()
  if t.has_prefix("{") {
    TaskConfig::from_json_text(t, None, strict_secrets, warn_plaintext, warner)
  } else {
    TaskConfig::from_file(t, strict_secrets, warn_plaintext, warner)
  }
}

///|
/// 取路径的父目录（"E:/a/b.json" → "E:/a"；无分隔符 → "."）。
fn parent_dir(path : String) -> String {
  let p = path.replace_all(old="\\", new="/")
  match p.rev_split_once("/") {
    Some(pair) => if pair.0 == "" { "/" } else { pair.0.to_owned() }
    None => "."
  }
}

///|
/// 读配置文件（js：node:fs）。失败返回可诊断 Err。
#cfg(target="js")
extern "js" fn ffi_config_read_file(path : String) -> String =
  #| (path) => { const G = globalThis; try { const fs = process.getBuiltinModule("node:fs"); const t = fs.readFileSync(String(path), "utf8"); G.__rxmbt_cfg_err = ""; return t; } catch (e) { G.__rxmbt_cfg_err = String((e && e.message) || e); return ""; } }

///|
/// 取最近一次读配置的失败原因。
#cfg(target="js")
extern "js" fn ffi_config_last_error() -> String =
  #| () => { const G = globalThis; return (G.__rxmbt_cfg_err === undefined) ? "" : G.__rxmbt_cfg_err; }

///|
/// js：读文本文件。
#cfg(target="js")
fn read_config_file(path : String) -> Result[String, String] {
  let text = ffi_config_read_file(path)
  let err = ffi_config_last_error()
  if err != "" {
    Err(err)
  } else {
    Ok(text)
  }
}

///|
/// 非 js：无文件系统 API，返回可诊断 Err。
#cfg(not(target="js"))
fn read_config_file(path : String) -> Result[String, String] {
  Err(
    "rhop_task: 读配置文件仅 js 目标可用（wasm/native 无文件系统 API）",
  )
}