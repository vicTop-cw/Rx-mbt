// ============================================================================
// rhop · 一份配置描述密钥/角色/介质/动作集（Batch C）
//
// 对照 vools.rhop.config：RhopConfig 把 JSON/dict 配置归一为会话构件
// （密钥 + 在线通道 + shared path + 中转），供 interact() 一键交互与动作执行使用。
//
// 配置形态（JSON）：
//   {
//     "name": "dev-A",                       # 可选：会话名（缺省 "rhop-config"）
//     "key": "plain-secret",                 # 密钥：明文 / {"plain"} / {"cipher":…} /
//                                            #       {"path": …} / {"env": "RHOP_KEY"} / {"source": …}
//     "role": "SEND",                        # SEND | RECV | RELAY（缺省 SEND）
//     "sftp": {"host": …, "user": …, "password": …, "dir": …, "key_path": …},
//                                            # 可选：jump 动作的目标跳板机（FTP_connect 形态）
//     "online": [ {"kind":"sftp"|"git"|"relay", …}, … ],   # 可选：在线通道（按优先级）
//     "shared": {"write": "D:/share", "read": "D:/share"},  # 可选：写/读视图（缺省读=写）
//     "relay": {"host": "127.0.0.1", "port": 0, "token": "…", "timeout": 3.0}
//                                            # 可选：A->C->B 中转地址（本端投递视角）
//   }
//
// 目标说明：解析 / 校验 / build_crypto / action_cfg / to_dict 纯逻辑，三目标通用；
// `from_file`（读 JSON 文件）与 `_key_from_cfg` 的 path 分支、cipher 分支（需要 Fernet）
// 仅 js 目标可用，非 js 返回可诊断 Err（保证 rhop 包三目标都能编译）。
// ============================================================================

///|
/// 配置驱动会话的静态描述 + 构件工厂（对照 vools `RhopConfig`）。
pub struct RhopConfig {
  /// 解析后的密钥原文（明文；绝不写进 `to_dict` 回执）
  key : String
  /// 本端默认角色
  role : Role
  /// 跳板机配置（供动作执行；`action_cfg` 原样透出）
  sftp : Json?
  /// 在线通道 spec 数组
  online : Json?
  /// shared path spec（对象 {write, read?} 或地址字符串）
  shared : Json?
  /// 中转 spec（对象 {host, port, token?, timeout?}）
  relay : Json?
  /// 会话/配置名
  name : String
}

///|
/// 显式构造（一般用 `from_dict` / `from_file` / `load_config`）。
pub fn RhopConfig::new(
  key : String,
  role : Role,
  sftp : Json?,
  online : Json?,
  shared : Json?,
  relay : Json?,
  name : String,
) -> RhopConfig {
  let resolved = if name.trim().length() == 0 { "rhop-config" } else { name }
  { key, role, sftp, online, shared, relay, name: resolved, }
}

// ---------------------------------------------------------------------------
// 密钥解析：_key_from_cfg 四分支
// ---------------------------------------------------------------------------

///|
/// 从配置的 `key` 字段解析密钥文本（对照 vools `_key_from_cfg`）。
///
/// 兼容写法（四分支）：
/// 1. **字符串**：直接作为密钥文本（明文，调用方负责告警）；
/// 2. **`{"plain": "…"}`**：明文字段；
/// 3. **`{"cipher": "RHOP-ENC:…", "env"|"path"|"source": …}`**：加密的主密钥，
///    用 env/path/source 提供的**外层密钥**解开（避免"自己解自己"的循环）；
/// 4. **`{"path": …}` / `{"env": …}` / `{"source": …}`**：交给 `load_key`
///    （优先级 source > path > env，env 缺省 `RHOP_KEY`）。
///
/// 其它形态（数组 / null / 布尔）返回可诊断 Err；数字与布尔按 JSON 文本当密钥
/// （vools 走 `str(key_cfg)`，口径近似；这是边界形态，不建议依赖）。
pub fn _key_from_cfg(key_cfg : Json?) -> Result[String, String] {
  let cfg = match key_cfg {
    None =>
      return Err(
        "配置缺少 key（明文、key.cipher、key.path 或 key.env 三者其一）",
      )
    Some(Null) =>
      return Err(
        "配置缺少 key（明文、key.cipher、key.path 或 key.env 三者其一）",
      )
    Some(v) => v
  }
  match cfg {
    String(s) =>
      if s == "" {
        Err(
          "配置 key 为空字符串（明文、key.cipher、key.path 或 key.env 三者其一）",
        )
      } else {
        Ok(s)
      }
    Object(_) => {
      // 分支 2：明文字段
      match cfg_json_str(cfg, "plain") {
        Some(plain) => if plain != "" { return Ok(plain) }
        None => ()
      }
      // 分支 3：密文主密钥 —— 用外层密钥解开
      match cfg_json_str(cfg, "cipher") {
        Some(cipher) =>
          if cipher != "" {
            let unlock = match
              load_key(
                cfg_json_str(cfg, "source"),
                cfg_json_str(cfg, "path"),
                cfg_env_name(cfg),
              ) {
              Ok(k) => k
              Err(e) => return Err("key.cipher 需要外层密钥解锁: " + e)
            }
            let crypto = RhopCrypto::from_key(unlock)
            return match crypto.decrypt_secret(cipher) {
              Ok(plain) => Ok(plain)
              Err(e) => Err("key.cipher 解密失败: " + e)
            }
          }
        None => ()
      }
      // 分支 4：path / env / source → load_key（source > path > env）
      load_key(
        cfg_json_str(cfg, "source"),
        cfg_json_str(cfg, "path"),
        cfg_env_name(cfg),
      )
    }
    Number(_, ..) => Ok(Json::stringify(cfg))
    // 布尔 key 明确拒绝：vools 会 str(True)="True"，与 MoonBit "true" 口径不一致，
    // 静默接受会让同一份配置在两个实现下解出不同密钥（解密全失败且难排查）。
    True | False =>
      return Err(
        "配置字段 key 不接受布尔值（请用字符串，或对象 {plain|cipher|path|env|source}）",
      )
    _ =>
      Err(
        "配置字段 key 形态非法（应为字符串，或对象 {plain|cipher|path|env|source}）",
      )
  }
}

///|
/// 取 key 配置里的外层环境变量名（缺省 `RHOP_KEY`；空串按缺省处理）。
fn cfg_env_name(cfg : Json) -> String {
  match cfg_json_str(cfg, "env") {
    Some(e) =>
      if e.trim().length() == 0 {
        ENV_RHOP_KEY
      } else {
        e.trim().to_owned()
      }
    None => ENV_RHOP_KEY
  }
}

// ---------------------------------------------------------------------------
// 构造 / 序列化
// ---------------------------------------------------------------------------

///|
/// 从 dict/JSON 对象构造并校验（缺关键字段 / 未知角色 → 可诊断 Err）。
pub fn RhopConfig::from_dict(data : Json) -> Result[RhopConfig, String] {
  match data {
    Object(fields) => {
      let key = match _key_from_cfg(fields.get("key")) {
        Ok(k) => k
        Err(e) => return Err(e)
      }
      let role = match fields.get("role") {
        None => Role::Send
        Some(Null) => Role::Send
        Some(String(s)) =>
          // 复刻 vools `str(data.get("role") or Role.SEND)`：空串/纯空白按缺失处理
          if s.trim().length() == 0 {
            Role::Send
          } else {
            match Role::parse(s) {
              Ok(r) => r
              Err(e) => return Err(e)
            }
          }
        Some(_) => return Err("配置字段 role 必须是字符串")
      }
      let name = match fields.get("name") {
        Some(String(s)) =>
          if s.trim().length() == 0 {
            "rhop-config"
          } else {
            s
          }
        _ => "rhop-config"
      }
      Ok({
        key,
        role,
        sftp: fields.get("sftp"),
        online: fields.get("online"),
        shared: fields.get("shared"),
        relay: fields.get("relay"),
        name,
      })
    }
    _ => Err("配置必须是 dict/JSON 对象")
  }
}

///|
/// 从 JSON 文件构造（可用性：**仅 js 目标**；wasm/native 返回可诊断 Err）。
pub fn RhopConfig::from_file(path : String) -> Result[RhopConfig, String] {
  let p = path.trim().to_owned()
  if p.length() == 0 {
    return Err("配置文件路径不能为空")
  }
  // C2-01 加固：超长字符串不交给 OS（避免 ENAMETOOLONG 泄漏），错误串一律截断
  if p.length() > CFG_PATH_MAX_LEN {
    return Err(
      "配置文件路径过长（" +
      p.length().to_string() +
      " 字符，上限 " +
      CFG_PATH_MAX_LEN.to_string() +
      "）: " +
      cfg_snippet(p, 80),
    )
  }
  let text = match cfg_read_text(p) {
    Ok(t) => t
    Err(e) =>
      return Err(
        "读取配置文件失败: " +
        cfg_snippet(p, 200) +
        ": " +
        cfg_snippet(e, 200),
      )
  }
  let data = @json.parse(text) catch {
    _ => return Err("配置文件不是合法 JSON: " + cfg_snippet(p, 200))
  }
  RhopConfig::from_dict(data)
}

///|
/// 导出配置 JSON 对象（密钥不落盘，仅回填存在性标记）。
///
/// 掩码规则（比 vools 更严，安全优先）：`sftp` / `online` / `shared` / `relay`
/// **递归**掩码敏感字段 —— `password` / `passwd` / `key_path` / `private_key` /
/// `token` / `secret` / `api_key` 等一律替换成 `"***"`（大小写不敏感，支持嵌套对象与数组）。
/// 无 sftp 时输出空对象 `{}`（vools 的 `self.sftp` 缺省就是 `{}`）；其余缺省为 null。
pub fn RhopConfig::to_dict(self : RhopConfig) -> Json {
  Json::object({
    "name": Json::string(self.name),
    "role": Json::string(self.role.to_string()),
    "has_key": Json::boolean(self.key != ""),
    "sftp": cfg_mask_secrets(self.sftp),
    "online": cfg_mask_deep_or_null(self.online),
    "shared": cfg_mask_deep_or_null(self.shared),
    "relay": cfg_mask_deep_or_null(self.relay),
  })
}

///|
/// 会话名。
pub fn RhopConfig::name(self : RhopConfig) -> String {
  self.name
}

///|
/// 本端默认角色。
pub fn RhopConfig::role(self : RhopConfig) -> Role {
  self.role
}

///|
/// 是否持有非空密钥（密钥原文不对外暴露 —— 只回答「有没有」）。
pub fn RhopConfig::has_key(self : RhopConfig) -> Bool {
  self.key != ""
}

// ---------------------------------------------------------------------------
// 构件工厂
// ---------------------------------------------------------------------------

///|
/// 用配置里的密钥构造 `RhopCrypto`（对照 vools `build_crypto`）。
pub fn RhopConfig::build_crypto(self : RhopConfig) -> RhopCrypto {
  RhopCrypto::from_key(self.key)
}

///|
/// 按 `online` spec 数组构造在线通道（对照 vools `build_online`）。
///
/// kind 支持 `sftp`（缺省）/ `git` / `relay`（大小写不敏感）；未知 kind 返回可诊断 Err
/// （列出可用值），绝不静默跳过 —— 静默跳过会让「配置了 3 条通道却只探测到 2 条」
/// 变成难查的排障问题。
pub fn RhopConfig::build_online(
  self : RhopConfig,
) -> Result[Array[&OnlineChannel], String] {
  let specs : Array[Json] = match self.online {
    None => []
    Some(Null) => []
    Some(Array(items)) => items
    Some(_) => return Err("配置字段 online 必须是数组")
  }
  let out : Array[&OnlineChannel] = []
  for spec in specs {
    match cfg_channel_from_spec(spec) {
      Ok(ch) => out.push(ch)
      Err(e) => return Err(e)
    }
  }
  Ok(out)
}

///|
/// 按 `shared` spec 构造多端视图（对照 vools `build_shared`）。
///
/// 关键点（与 vools 一致）：**统一走 `make_shared_path`**。单 spec 时读端=写端，
/// 语义与直接用 `LocalSharedPath` 一致；但写端是 `http(s)://` 时必须正确解析成
/// HttpEndpoint，而不是被当成相对路径 abspath 成本地目录。
///
/// 无 shared 配置返回 `Ok(None)`；缺 `write`/`spec` 或地址非法返回 Err。
pub fn RhopConfig::build_shared(
  self : RhopConfig,
) -> Result[SharedPathView?, String] {
  let spec = match self.shared {
    None => return Ok(None)
    Some(Null) => return Ok(None)
    Some(v) => v
  }
  // 允许 shared 直接写地址字符串（单 spec 简写）
  match spec {
    String(s) => {
      let addr = s.trim().to_owned()
      if addr == "" {
        return Ok(None)
      }
      return match make_shared_path(addr, None) {
        Ok(view) => Ok(Some(view))
        Err(e) => Err("shared 配置非法: " + e)
      }
    }
    Object(fields) => {
      // 复刻 vools `if not self.shared: return None`：空对象 {} 等价于未配置
      let count = Ref::Ref(0)
      for key in fields.keys() {
        let _ = key
        count.val = count.val + 1
      }
      if count.val == 0 {
        return Ok(None)
      }
    }
    _ =>
      return Err(
        "配置字段 shared 必须是对象 {write, read?} 或地址字符串",
      )
  }
  let write_spec = match cfg_json_str(spec, "write") {
    Some(w) => w
    None =>
      match cfg_json_str(spec, "spec") {
        Some(sp) => sp
        None => ""
      }
  }
  if write_spec.trim().length() == 0 {
    return Err("shared 配置缺少 write/spec 字段")
  }
  let read_spec = cfg_json_str(spec, "read")
  match make_shared_path(write_spec, read_spec) {
    Ok(view) => Ok(Some(view))
    Err(e) => Err("shared 配置非法: " + e)
  }
}

///|
/// 按 `relay` spec 构造投递方中转通道（对照 vools `build_relay`）。
///
/// 无 relay 配置返回 `Ok(None)`；`timeout` 以**秒**为单位（vools 口径），转成毫秒。
pub fn RhopConfig::build_relay(
  self : RhopConfig,
) -> Result[RelayChannel?, String] {
  let spec = match self.relay {
    None => return Ok(None)
    Some(Null) => return Ok(None)
    Some(v) => v
  }
  match spec {
    Object(_) => ()
    _ =>
      return Err(
        "配置字段 relay 必须是对象 {host, port, token?, timeout?}",
      )
  }
  // Python `or` 语义：host 空串回退 127.0.0.1，port 0 回退 0（仍表示"未定端口"）
  let host = cfg_str_or_nonblank(spec, "host", "127.0.0.1")
  let port = cfg_json_int_pos(spec, "port", 0)
  let token = cfg_json_str(spec, "token")
  Ok(Some(RelayChannel::new(host, port, token, cfg_timeout_ms(spec, 3000))))
}

///|
/// 按配置构造会话（可覆盖角色；对照 vools `build_session`）。
pub fn RhopConfig::build_session(
  self : RhopConfig,
  role? : Role,
) -> Result[Session, String] {
  let shared = match self.build_shared() {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let online = match self.build_online() {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let relay = match self.build_relay() {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let effective_role = match role {
    Some(r) => r
    None => self.role
  }
  Ok(
    Session::new(
      effective_role,
      shared,
      online,
      relay,
      Some(self.build_crypto()),
      self.name,
    ),
  )
}

///|
/// 给动作执行用的 cfg：sftp 配置（FTP_connect 形态）+ 密钥存在性 + 配置名。
///
/// **不含密钥原文**（动作不需要，也不该拿到）。
pub fn RhopConfig::action_cfg(self : RhopConfig) -> Json {
  Json::object({
    "sftp": cfg_json_or_null(self.sftp),
    "has_key": Json::boolean(self.has_key()),
    "config_name": Json::string(self.name),
  })
}

///|
/// 配置文件路径长度上限（C2-01）。
///
/// 为什么要设上限：`load_config` 会把「看起来像路径」的字符串交给 `from_file`，
/// 而 `fs.readFileSync` 会把整段字符串交给 OS —— 12KB 的配置文本因此触发
/// `ENAMETOOLONG`，且错误信息会回显整段输入（日志/内存放大）。4096 覆盖
/// POSIX/PATH_MAX 与 Windows 长路径，超出即判「不是可用路径」。
const CFG_PATH_MAX_LEN : Int32 = 4096

///|
/// 错误信息里的片段截断 + 控制字符归一（C2-01：不让整段用户输入进错误串）。
///
/// 换行/回车/制表符统一换成空格（防日志注入），再从头部截 `max` 个字符，末尾加 `…`。
fn cfg_snippet(raw : String, max : Int32) -> String {
  let sb = StringBuilder::new()
  let limit = if raw.length() < max { raw.length() } else { max }
  for i in 0..<limit {
    match raw.get_char(i) {
      Some('\n') => sb.write_char(' ')
      Some('\r') => sb.write_char(' ')
      Some('\t') => sb.write_char(' ')
      Some(c) => sb.write_char(c)
      None => ()
    }
  }
  if raw.length() > max {
    sb.write_string("…")
  }
  sb.to_string()
}

///|
/// 便捷入口：配置对象 JSON / JSON 文本 / JSON 文件路径 → `RhopConfig`。
///
/// 形态判定（**顺序敏感**，见 C2-01）：
/// 1. JSON 对象 → 直接 `from_dict`；
/// 2. 字符串：
///    - 以 `{` / `[` 开头 ⇒ 当**配置文本**解析。`[` 或非对象结果给「必须是对象」，
///      解析失败给「不是合法 JSON」—— 都不再回落成文件路径（否则整段文本会被当文件名）；
///    - 含换行或长度 > `CFG_PATH_MAX_LEN` ⇒ 判「既不是配置对象也不是可用路径」
///      （这类输入不可能是合法路径，且回显会放大日志）；
///    - 其余才当文件路径交给 `from_file`。
/// 3. 其它类型 → 可诊断 Err。
///
/// 所有错误信息里的用户输入都经 `cfg_snippet` 截断归一（≤120 字符）。
pub fn load_config(item : Json) -> Result[RhopConfig, String] {
  match item {
    Object(_) => RhopConfig::from_dict(item)
    String(raw) => {
      let trimmed = raw.trim().to_owned()
      if trimmed == "" {
        return Err(
          "cfg 不能为空（应为配置对象 JSON 或 JSON 文件路径）",
        )
      }
      let first = trimmed.get_char(0)
      if first == Some('{') || first == Some('[') {
        let parsed = @json.parse(trimmed) catch { _ => Json::null() }
        match parsed {
          Object(_) => return RhopConfig::from_dict(parsed)
          Null =>
            return Err(
              "cfg 不是合法 JSON（片段: " +
              cfg_snippet(trimmed, 120) +
              "）",
            )
          _ =>
            return Err(
              "配置必须是 dict/JSON 对象（收到: " +
              cfg_snippet(trimmed, 60) +
              "）",
            )
        }
      }
      if trimmed.length() > CFG_PATH_MAX_LEN || trimmed.contains("\n") {
        return Err(
          "cfg 既不是配置对象 JSON 也不是可用的文件路径（长度 " +
          trimmed.length().to_string() +
          "，片段: " +
          cfg_snippet(trimmed, 80) +
          "）",
        )
      }
      RhopConfig::from_file(trimmed)
    }
    _ => Err("cfg 必须是配置对象 JSON 或 JSON 文件路径")
  }
}

// ---------------------------------------------------------------------------
// 内部：spec → 通道 / 掩码 / JSON 取值helper
// ---------------------------------------------------------------------------

///|
/// 单条在线通道 spec → 通道对象（kind: sftp / git / relay）。
fn cfg_channel_from_spec(spec : Json) -> Result[&OnlineChannel, String] {
  // 类型不符必须报错：静默造空通道会让「配了 3 条却只探到 2 条」更难查
  match spec {
    Object(_) => ()
    _ =>
      return Err(
        "在线通道配置必须是对象（kind 缺省 sftp）: " +
        Json::stringify(spec),
      )
  }
  let kind = match cfg_json_str(spec, "kind") {
    Some(k) =>
      if k.trim().length() == 0 {
        "sftp"
      } else {
        k.trim().to_owned().to_lower()
      }
    None => "sftp"
  }
  match kind {
    "sftp" => {
      let host = cfg_str_or(spec, "host", "")
      let dir = match cfg_json_str(spec, "dir") {
        Some(d) => d
        None => cfg_str_or(spec, "remote_dir", "")
      }
      let user = match cfg_json_str(spec, "user") {
        Some(u) => u
        None => cfg_str_or(spec, "username", "")
      }
      // Python `or 22`：port 缺失 / 0 / 负数都回退 22
      let port = cfg_json_int_pos(spec, "port", 22)
      let ch : &OnlineChannel = SftpChannel::new(host, port, dir).with_username(
        user,
      )
      Ok(ch)
    }
    "git" => {
      let remote = cfg_str_or(spec, "remote_url", "")
      if remote.trim().length() == 0 {
        return Err("git 在线通道缺少 remote_url")
      }
      let branch = cfg_str_or(spec, "branch", "main")
      let ch : &OnlineChannel = GitChannel::new(remote).with_branch(branch)
      Ok(ch)
    }
    "relay" => {
      let host = cfg_str_or_nonblank(spec, "host", "127.0.0.1")
      let port = cfg_json_int_pos(spec, "port", 0)
      let token = cfg_json_str(spec, "token")
      let ch : &OnlineChannel = RelayChannel::new(
        host,
        port,
        token,
        cfg_timeout_ms(spec, 3000),
      )
      Ok(ch)
    }
    _ =>
      Err("不支持的在线通道 kind: \{kind}（可用 sftp/git/relay）")
  }
}

///|
/// 敏感键名判定（大小写不敏感）：命中即整体替换成 `"***"`，不保留任何片段。
fn cfg_is_secret_key(key : String) -> Bool {
  let k = key.to_lower()
  k == "password" ||
  k == "passwd" ||
  k == "key_path" ||
  k == "private_key" ||
  k == "secret" ||
  k == "token" ||
  k == "api_key" ||
  k == "access_token" ||
  k == "refresh_token"
}

///|
/// 递归掩码：对象里命中敏感键 → `"***"`；对象/数组递归下钻；标量原样透出。
fn cfg_mask_deep(value : Json) -> Json {
  match value {
    Object(fields) => {
      let out : Map[String, Json] = Map([])
      for key in fields.keys() {
        if cfg_is_secret_key(key) {
          out[key] = Json::string("***")
        } else {
          out[key] = match fields.get(key) {
            Some(v) => cfg_mask_deep(v)
            None => Json::null()
          }
        }
      }
      Json::object(out)
    }
    Array(items) => {
      let out : Array[Json] = []
      for item in items {
        out.push(cfg_mask_deep(item))
      }
      Json::array(out)
    }
    _ => value
  }
}

///|
/// `Json?` 版递归掩码：None → null（保持 `to_dict` 的键位形态）。
fn cfg_mask_deep_or_null(value : Json?) -> Json {
  match value {
    Some(v) => cfg_mask_deep(v)
    None => Json::null()
  }
}

///|
/// sftp 专用掩码入口：无值给 `{}`（vools 的 `self.sftp` 缺省即 `{}`）；有值递归掩码。
fn cfg_mask_secrets(sftp : Json?) -> Json {
  let empty = Json::object(Map([]))
  match sftp {
    None => empty
    Some(Null) => empty
    Some(v) => cfg_mask_deep(v)
  }
}

///|
/// `Json?` → `Json`（None 变 null）。
fn cfg_json_or_null(value : Json?) -> Json {
  match value {
    Some(v) => v
    None => Json::null()
  }
}

///|
/// 取对象字段；非对象或字段缺失返回 None。
fn cfg_json_field(j : Json, key : String) -> Json? {
  match j {
    Object(members) => members.get(key)
    _ => None
  }
}

///|
/// 取字符串字段；缺失或类型不符返回 None。
fn cfg_json_str(j : Json, key : String) -> String? {
  match cfg_json_field(j, key) {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
/// 取字符串字段，缺失时回退默认值。
fn cfg_str_or(j : Json, key : String, default : String) -> String {
  match cfg_json_str(j, key) {
    Some(s) => s
    None => default
  }
}

///|
/// 取字符串字段，**缺失 / 空串 / 纯空白**都回退默认值。
///
/// 复刻 Python 的 `spec.get(key) or default` 语义：`relay.host = ""` 与缺省等价，
/// 不能拼出 `http://:9000` 这种没有主机的基地址。
fn cfg_str_or_nonblank(j : Json, key : String, default : String) -> String {
  match cfg_json_str(j, key) {
    Some(s) => if s.trim().length() == 0 { default } else { s }
    None => default
  }
}

///|
/// 取整数字段（数字或数字字符串），缺失/非法时回退 `default`。
fn cfg_json_int(j : Json, key : String, default : Int32) -> Int32 {
  match cfg_json_field(j, key) {
    Some(Number(n, ..)) => n.to_int()
    Some(String(s)) => {
      let parsed = @json.parse(s) catch { _ => Json::null() }
      match parsed {
        Number(n, ..) => n.to_int()
        _ => default
      }
    }
    _ => default
  }
}

///|
/// 取正整数字段：缺失 / 非法 / `<= 0` 一律回退 `default`
/// （复刻 Python `int(spec.get("port", d) or d)` —— `port: 0` 不是合法端口）。
fn cfg_json_int_pos(j : Json, key : String, default : Int32) -> Int32 {
  let v = cfg_json_int(j, key, default)
  if v <= 0 {
    default
  } else {
    v
  }
}

///|
/// 取超时毫秒：`timeout_ms` 优先；`timeout` 按**秒**换算（vools 口径）。
///
/// 复刻 Python `or` 语义：0 / 负数视为未配置，回退 `default`。
fn cfg_timeout_ms(spec : Json, default : Int32) -> Int32 {
  let ms = match cfg_json_field(spec, "timeout_ms") {
    Some(Number(ms, ..)) => ms.to_int()
    _ =>
      match cfg_json_field(spec, "timeout") {
        Some(Number(sec, ..)) => (sec * 1000.0).to_int()
        _ => default
      }
  }
  if ms <= 0 {
    default
  } else {
    ms
  }
}

// ---------------------------------------------------------------------------
// 文件读取（js：node:fs；非 js：可诊断 Err）
// ---------------------------------------------------------------------------

///|
/// 读取 utf8 文本文件（js 目标，node:fs）。失败返回 "" 并把原因写入错误槽。
#cfg(target="js")
extern "js" fn cfg_ffi_read_file(path : String) -> String =
  #| (path) => { const G = globalThis; try { const fs = process.getBuiltinModule("node:fs"); const t = fs.readFileSync(String(path), "utf8"); G.__rxmbt_cfg_err = ""; return t; } catch (e) { G.__rxmbt_cfg_err = String((e && e.message) || e); return ""; } }

///|
/// 取最近一次读文件失败原因（空串表示成功）。
#cfg(target="js")
extern "js" fn cfg_ffi_last_error() -> String =
  #| () => { const G = globalThis; return (G.__rxmbt_cfg_err === undefined) ? "" : G.__rxmbt_cfg_err; }

///|
/// js：读配置文件文本。
#cfg(target="js")
fn cfg_read_text(path : String) -> Result[String, String] {
  let text = cfg_ffi_read_file(path)
  let err = cfg_ffi_last_error()
  if err != "" {
    Err(err)
  } else {
    Ok(text)
  }
}

///|
/// 非 js：无文件系统 API，返回可诊断 Err（配置文件请改用配置对象 JSON 直传）。
#cfg(not(target="js"))
fn cfg_read_text(path : String) -> Result[String, String] {
  let _ = path
  Err(
    "读文件仅 js 目标可用（wasm/native 无文件系统 API）；请直接用配置对象 JSON",
  )
}
