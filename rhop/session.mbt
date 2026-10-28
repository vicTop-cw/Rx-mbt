// ============================================================================
// rhop · A/B/C 三角拓扑会话模型（Batch C）
//
// 对照 vools.rhop.session：
//   拓扑约束（analysis/rhop-PLAN.md 附录 C）：不存在多跳链；任何交互都可演化为
//   A[发送端]、B[接收端]、C[中转] 三角。A/B 反向传递只需调换角色复用同一套机制。
//
// 角色模型：
//   Role::Send  - 发送端 A：把加密动作包投递到介质/中转
//   Role::Recv  - 接收端 B：从介质/中转取包、解密验证
//   Role::Relay - 中转 C：临时自建 HTTP 中转（RelayServer），A/B 不可直连时暂存/转交
//
// 会话（Session）持有角色 + 介质（在线通道列表 + shared path 视图）+ 中转通道 + 密钥。
// 同一方可多角色：双向交互时 A 同时是 SEND+RECV（reverse() 互换角色复用同一份介质）。
//
// 通道选择链（与 vools 一致，优先级从高到低）：
//   1. 自建中转 RelayChannel（C 在线、地址可达）
//   2. 在线通道（Git / SFTP）
//   3. shared path（多端视图）—— 最终回退
//
// 目标说明：
//   - 结构 / 角色 / 通道链编排 / describe：纯逻辑，三目标（wasm / js / native）通用；
//   - 真正的加密（RhopCrypto）、文件读写（LocalSharedPath）、HTTP（RelayChannel）各自
//     按已有的目标可用性工作：wasm/native 下加密与文件 IO 返回可诊断失败，
//     因此 send_package 在非 js 目标上会以 Err("加密载荷失败…") 结束 —— 这是**预期**的
//     目标差异，不是静默成功。
// ============================================================================

///|
/// 会话角色（对照 vools `Role` 字符串常量 SEND / RECV / RELAY）。
///
/// 与 vools 的差异：vools 用裸字符串常量，这里用 enum（MoonBit 命名惯例 PascalCase，
/// 对齐契约 §2.1）；跨实现的字面量由 `to_string` / `parse` 负责（严格 "SEND"/"RECV"/"RELAY"）。
///
/// `pub(all)` 是必须的：`pub enum` 只暴露类型本身（外部包无法构造构造器，
/// 会报 "Cannot create values of the read-only type: Send"）；rhop 包外
/// （test-suit/* 与 config/session 调用方）需要 `Role::Send` 这样的构造器值。
pub(all) enum Role {
  /// 发送端 A
  Send
  /// 接收端 B
  Recv
  /// 中转 C
  Relay
} derive(Eq, Debug)

///|
/// 角色 → vools 字面量（大写）。
pub fn Role::to_string(self : Role) -> String {
  match self {
    Send => "SEND"
    Recv => "RECV"
    Relay => "RELAY"
  }
}

///|
/// 角色 → 小写短名（用于默认会话名 `session:send` / `session:recv` / `session:relay`）。
pub fn Role::lower(self : Role) -> String {
  match self {
    Send => "send"
    Recv => "recv"
    Relay => "relay"
  }
}

///|
/// 解析角色字面量（大小写不敏感，首尾空白忽略）。
///
/// 未知值返回可诊断 Err（列出可用值），绝不静默回退到默认角色。
pub fn Role::parse(text : String) -> Result[Role, String] {
  let normalized = text.trim().to_owned().to_lower()
  match normalized {
    "send" => Ok(Send)
    "recv" => Ok(Recv)
    "relay" => Ok(Relay)
    _ => Err("未知角色: \{text.trim()}（可用 SEND/RECV/RELAY）")
  }
}

///|
/// 包文件名白名单校验（安全边界：防路径穿越 / 任意路径写入）。
///
/// 规则：长度 1..128；字符集仅 `A-Za-z0-9._-`；禁止 `.` / `..` 及任何连续 `..`。
/// 路径分隔符、盘符、URI 前缀、空白与控制字符都因字符集被拒 ——
/// `send_package` / `recv_package` / `remove_package` 与 `interact` 的缺省包名
/// 统一走这一处校验，介质层因此拿不到可穿越的文件名。
pub fn safe_filename(name : String) -> Result[String, String] {
  if name.length() == 0 {
    return Err("包文件名不能为空")
  }
  if name.length() > 128 {
    return Err("包文件名过长（最多 128 字符）")
  }
  if name.contains("..") {
    return Err(
      "包文件名不允许包含 \"..\"（防路径穿越）: " + name,
    )
  }
  for c in name {
    let code = c.to_int()
    let ok = (code >= 48 && code <= 57) ||
      (code >= 65 && code <= 90) ||
      (code >= 97 && code <= 122) ||
      code == 46 ||
      code == 95 ||
      code == 45
    if not(ok) {
      return Err(
        "包文件名只允许 A-Za-z0-9._-，遇到非法字符（码点 \{code}）: " +
        name,
      )
    }
  }
  Ok(name)
}

///|
/// 一次配置驱动会话：角色 + 介质 + 中转 + 密钥。
///
/// `shared` 用 `SharedPathView`（多端写/读视图）；`online` 是按优先级排列的在线通道；
/// `relay` 是本端作为**投递方**视角的中转通道（中转服务端由 RelayServer 另管）。
pub struct Session {
  /// 会话角色
  role : Role
  /// shared path 多端视图（写入走 write_view、读取走 read_view）
  shared : SharedPathView?
  /// 在线通道（按优先级；空数组表示没有）
  online : Array[&OnlineChannel]
  /// 中转通道（投递方视角）
  relay : RelayChannel?
  /// 本地固定密钥（None 表示未配置，此时 send/recv 直接 Err）
  crypto : RhopCrypto?
  /// 会话名（空串时按角色自动生成 `session:<role>`）
  name : String
}

///|
/// 构造会话。
///
/// `name` 传空串时自动生成 `session:<role.lower()>`（与 vools 同规则）。
pub fn Session::new(
  role : Role,
  shared : SharedPathView?,
  online : Array[&OnlineChannel],
  relay : RelayChannel?,
  crypto : RhopCrypto?,
  name : String,
) -> Session {
  let resolved_name = if name.trim().length() == 0 {
    "session:" + role.lower()
  } else {
    name
  }
  { role, shared, online, relay, crypto, name: resolved_name, }
}

///|
/// 只带角色与会话名的空会话（无介质、无密钥；用于配置装配的骨架与测试）。
pub fn Session::empty(role : Role) -> Session {
  Session::new(role, None, [], None, None, "")
}

///|
/// 当前角色。
pub fn Session::role(self : Session) -> Role {
  self.role
}

///|
/// 会话名。
pub fn Session::name(self : Session) -> String {
  self.name
}

///|
/// 在线通道条数。
pub fn Session::online_count(self : Session) -> Int32 {
  self.online.length()
}

///|
/// 是否配置了密钥。
pub fn Session::has_crypto(self : Session) -> Bool {
  match self.crypto {
    Some(_) => true
    None => false
  }
}

///|
/// 是否配置了 shared path。
pub fn Session::has_shared(self : Session) -> Bool {
  match self.shared {
    Some(_) => true
    None => false
  }
}

///|
/// 是否配置了中转通道。
pub fn Session::has_relay(self : Session) -> Bool {
  match self.relay {
    Some(_) => true
    None => false
  }
}

// ---------------------------------------------------------------------------
// 通道链（relay > online > shared）
// ---------------------------------------------------------------------------

///|
/// 取可用的中转通道（不可用/未配置返回 None）。
fn Session::pick_relay(self : Session) -> RelayChannel? {
  match self.relay {
    None => None
    Some(rc) => {
      let ch : &OnlineChannel = rc
      if OnlineChannel::available(ch) {
        Some(rc)
      } else {
        None
      }
    }
  }
}

///|
/// 取第一条可用的在线通道（按数组顺序探测；都不可用返回 None）。
fn Session::pick_online(self : Session) -> &OnlineChannel? {
  for ch in self.online {
    if OnlineChannel::available(ch) {
      return Some(ch)
    }
  }
  None
}

///|
/// shared path 单侧可用性探测（**无副作用**：不建目录、不写文件）。
///
/// 已知本地根的介质用 `exists(".")` / `exists("..")` 纯探测：
/// - 读侧：根目录已存在（且是目录）；
/// - 写侧：根目录已存在，或其父目录已存在（真正写入时由 write_text 建目录）。
///
/// 未知根的介质（内存 / 远端 / HTTP 抽象实现）没有可探测的本地状态，
/// 回退契约 `available()` —— 这类实现自己保证无副作用。
///
/// 为什么不再直接用 `SharedPath::available`：`LocalSharedPath::available`
/// 的实现是 mkdir -p，探测本身会产生副作用；而 `SharedPathView::available`
/// 又要求写端可建目录，导致「写端只读 + 读端可读」的接收端被判整条不可用。
/// 端点适配器（`EndpointSharedPath`，`root()` 恒 `None`）是否指向本地文件系统。
///
/// 本地端点**不能用** `available()` 探测：`LocalSharedPath::available` 走
/// `fs_ensure_dir`（会建目录），在 `available()/select()` 这类纯探测路径上产生副作用。
fn sp_is_local_endpoint(sp : &SharedPath) -> Bool {
  let n = SharedPath::name(sp)
  n.has_prefix("shared:local:") || n.has_prefix("shared:file-url:")
}

///|
/// 单侧可用性探测（**无副作用**）：不建目录、不写文件。
///
/// - `root()` 已知（`LocalSharedPath` / 测试 mock）：用存在性判定，
///   读侧要求根目录已存在，写侧要求根目录或父目录存在（写入时会自建目录）。
/// - 端点适配器：先做存在性探测（本地/远端都无副作用）；本地端点若连父目录都不存在
///   则直接判不可用（绝不为了探测而建目录）；远端端点退回 `available()` 探活。
fn sp_side_usable(sp : &SharedPath, for_write : Bool) -> Bool {
  let dot = SharedPath::exists(sp, ".")
  if for_write {
    if dot || SharedPath::exists(sp, "..") {
      return true
    }
  } else if dot {
    return true
  }
  match SharedPath::root(sp) {
    Some(_) => false
    None =>
      // 本地端点：存在性已给出答案，不再用 available()（它会建目录）
      if sp_is_local_endpoint(sp) {
        false
      } else {
        SharedPath::available(sp)
      }
  }
}

///|
/// 取读端可用的 shared 视图（未配置 / 读端不可用返回 None）。
fn Session::pick_shared(self : Session) -> SharedPathView? {
  match self.shared {
    None => None
    Some(view) =>
      if sp_side_usable(view.read_view, false) {
        Some(view)
      } else {
        None
      }
  }
}

///|
/// 取写端可用的 shared 视图（发送侧专用：只读介质不参与发送）。
fn Session::pick_shared_write(self : Session) -> SharedPathView? {
  match self.shared {
    None => None
    Some(view) =>
      if sp_side_usable(view.write_view, true) {
        Some(view)
      } else {
        None
      }
  }
}

///|
/// 介质链是否至少有一条可用（中转 > 在线 > shared path）。
///
/// 注意：会**真实探测**（中转 /health、在线通道 available、shared 存在性），
/// 但探测过程**不产生副作用**（不建目录、不写文件），因此可用于配置自检与热路径。
pub fn Session::available(self : Session) -> Bool {
  match self.pick_relay() {
    Some(_) => true
    None =>
      match self.pick_online() {
        Some(_) => true
        None =>
          match self.pick_shared() {
            Some(_) => true
            None =>
              match self.pick_shared_write() {
                Some(_) => true
                None => false
              }
          }
      }
  }
}

///|
/// 按通道选择链描述「此刻会走哪条通道」（不真正收发，但会真实探测）。
///
/// 返回的 `TransportSelection.transport` 用**会话层标签** `"relay"` / `"online"` /
/// `"shared"` / `"none"`（与 vools `_pick_transport` 的 label 语义逐字对齐）；
/// `is_online` 对 relay/online 为 true。这与 transport_selector.mbt 里
/// `select_transport` 的 `"online"/"shared"/"none"` 词汇表不同 —— 后者只描述
/// OnlineChannel 与 shared 的二选一，relay 由会话层先行判定。
pub fn Session::select(self : Session) -> TransportSelection {
  match self.pick_relay() {
    Some(rc) =>
      TransportSelection::new(
        "relay",
        "relay:" + rc.base(),
        true,
        "自建中转可用（通道链最高优先级）: " + rc.base(),
      )
    None =>
      match self.pick_online() {
        Some(ch) =>
          TransportSelection::new(
            "online",
            OnlineChannel::name(ch),
            true,
            "在线通道可用: " + OnlineChannel::name(ch),
          )
        None =>
          match self.pick_shared() {
            Some(view) =>
              TransportSelection::new(
                "shared",
                SharedPath::name(view),
                false,
                "在线通道均不可达，回退 shared path: " +
                SharedPath::name(view),
              )
            None =>
              match self.pick_shared_write() {
                Some(view) =>
                  TransportSelection::new(
                    "shared",
                    SharedPath::name(view),
                    false,
                    "在线通道均不可达，回退 shared path（仅写端可用）: " +
                    SharedPath::name(view),
                  )
                None =>
                  TransportSelection::new(
                    "none", "", false, "无可用的传输介质（relay/online/shared 全不可达）",
                  )
              }
          }
      }
  }
}

// ---------------------------------------------------------------------------
// 发送 / 接收
// ---------------------------------------------------------------------------

///|
/// 发送端：加密 JSON 载荷并投递到选定介质（对照 vools `send_package`）。
///
/// 成功：`{"status": "ok", "transport": <relay|online|shared>, "filename": ..., "role": ...}`
/// 传输层失败：`{"status": "error", "transport": ..., "filename": ..., "reason": ...}`
///
/// `Err` 只用于**参数 / 配置 / 角色类**错误（vools 抛 ValueError/IOError 的等价物）：
/// 文件名非法（`safe_filename` 拒绝）、RELAY 角色不允许发送、未配置密钥、加密失败、
/// 通道链全不可达。
/// 传输层 I/O 失败归一成可序列化的错误结构（调用方必须判 `status`），
/// 这样跨进程回执可以原样转发，而不必让调用方分辨「异常 vs 回执」。
///
/// 分流原则（全包统一，勿再反复）：**调用方传错参数 / 配置不成立 → `Err(String)`；
/// 介质在对侧"尽力了但失败"（读不到、写不进、解密不通过）→ `Ok({status:"error"})` 收据**。
pub fn Session::send_package(
  self : Session,
  filename : String,
  payload : Json,
) -> Result[Json, String] {
  if self.role == Role::Relay {
    return Err("RELAY 角色不发送载荷，仅提供中转")
  }
  // 安全边界：文件名先过白名单，介质层拿不到可穿越路径
  let name = match safe_filename(filename) {
    Ok(n) => n
    Err(e) => return Err("rhop session: " + e)
  }
  let crypto = match self.crypto {
    Some(c) => c
    None => return Err("会话未配置密钥（RhopCrypto）")
  }
  let token_text = match crypto.encrypt_json_result(payload) {
    Ok(text) => text
    Err(e) => return Err("加密载荷失败: " + e)
  }
  let (label, outcome) : (String, Result[Unit, String]) = match
    self.pick_relay() {
    Some(rc) => {
      let ch : &OnlineChannel = rc
      ("relay", OnlineChannel::send(ch, name, token_text))
    }
    None =>
      match self.pick_online() {
        Some(ch) => ("online", OnlineChannel::send(ch, name, token_text))
        None =>
          match self.pick_shared_write() {
            Some(view) =>
              ("shared", SharedPath::write_text(view, name, token_text))
            None =>
              (
                "none",
                Err(
                  "rhop session: 无可用的传输介质（relay/online/shared 全不可达）",
                ),
              )
          }
      }
  }
  if label == "none" {
    // 只读介质：读端可用但写端不可用 —— 给出可诊断原因（不是"全不可达"）
    let only_readable = match self.shared {
      Some(view) => sp_side_usable(view.read_view, false)
      None => false
    }
    if only_readable {
      return Err(
        "rhop session: shared path 写端不可用（介质只读）；如需发送请配置可写 write 视图",
      )
    }
    return Err(
      "rhop session: 无可用的传输介质（relay/online/shared 全不可达）",
    )
  }
  match outcome {
    Err(e) =>
      Ok(
        Json::object({
          "status": Json::string("error"),
          "transport": Json::string(label),
          "filename": Json::string(name),
          "reason": Json::string(e),
        }),
      )
    Ok(_) =>
      Ok(
        Json::object({
          "status": Json::string("ok"),
          "transport": Json::string(label),
          "filename": Json::string(name),
          "role": Json::string(self.role.to_string()),
        }),
      )
  }
}

///|
/// 接收端：从介质取包并解密验证（对照 vools `recv_package`）。
///
/// 成功：`{"status": "ok", "transport": ..., "filename": ..., "payload": <解密后的 JSON>}`
/// 失败：`{"status": "error", "transport": ..., "filename": ..., "reason": ...}`
///   - 传输层读失败：reason 为可诊断中文原因；
///   - 解密验证失败：reason 为四态字面量 `MALFORMED` / `BAD_TOKEN` / `NOT_JSON`。
///
/// `Err` 同样只用于参数/配置/角色类错误：文件名非法（`safe_filename`）、
/// RELAY 角色、未配置密钥、通道链全不可达。介质读失败与解密失败一律走
/// `status:"error"` 收据 —— 见 `send_package` 文档里的分流原则。
pub fn Session::recv_package(
  self : Session,
  filename : String,
) -> Result[Json, String] {
  if self.role == Role::Relay {
    return Err("RELAY 角色不消费载荷，仅提供中转")
  }
  // 安全边界：文件名先过白名单（与发送侧同一规则）
  let name = match safe_filename(filename) {
    Ok(n) => n
    Err(e) => return Err("rhop session: " + e)
  }
  let crypto = match self.crypto {
    Some(c) => c
    None => return Err("会话未配置密钥（RhopCrypto）")
  }
  let (label, read) : (String, Result[String, String]) = match
    self.pick_relay() {
    Some(rc) => {
      let ch : &OnlineChannel = rc
      ("relay", OnlineChannel::receive(ch, name))
    }
    None =>
      match self.pick_online() {
        Some(ch) => ("online", OnlineChannel::receive(ch, name))
        None =>
          match self.pick_shared() {
            Some(view) => ("shared", SharedPath::read_text(view, name))
            None =>
              (
                "none",
                Err(
                  "rhop session: 无可用的传输介质（relay/online/shared 全不可达）",
                ),
              )
          }
      }
  }
  if label == "none" {
    let only_writable = match self.shared {
      Some(view) => sp_side_usable(view.write_view, true)
      None => false
    }
    if only_writable {
      return Err(
        "rhop session: shared path 读端不可用（介质无读取视图）；如需接收请配置可读 read 视图",
      )
    }
    return Err(
      "rhop session: 无可用的传输介质（relay/online/shared 全不可达）",
    )
  }
  let token_text = match read {
    Err(e) => return Ok(recv_error(label, name, e))
    Ok(text) => text
  }
  let verified = crypto.decrypt_verify(token_text)
  if !verified.ok {
    return Ok(recv_error(label, name, verified.reason))
  }
  let payload = match verified.payload {
    Some(p) => p
    None => Json::null()
  }
  Ok(
    Json::object({
      "status": Json::string("ok"),
      "transport": Json::string(label),
      "filename": Json::string(name),
      "payload": payload,
    }),
  )
}

///|
/// 从介质删除一包（**仅 shared path**；在线通道/中转没有删除契约）。
///
/// 用途：roundtrip 的一次性响应包消费 —— 取出 `res_<filename>` 后必须删除，
/// 否则下一轮请求可能读到上一轮的陈旧回执（见 F1）。
/// 删除走**读视图**（响应包从读端取回，就在读端消失）。
pub fn Session::remove_package(
  self : Session,
  filename : String,
) -> Result[Unit, String] {
  let name = match safe_filename(filename) {
    Ok(n) => n
    Err(e) => return Err("rhop session: " + e)
  }
  match self.shared {
    Some(view) => SharedPath::remove(view.read_view, name)
    None => Err("rhop session: 仅 shared path 支持删除包")
  }
}

///|
/// 构造接收侧错误回执（vools 同形：status/transport/filename/reason）。
fn recv_error(label : String, filename : String, reason : String) -> Json {
  Json::object({
    "status": Json::string("error"),
    "transport": Json::string(label),
    "filename": Json::string(filename),
    "reason": Json::string(reason),
  })
}

// ---------------------------------------------------------------------------
// 角色互换 / 描述
// ---------------------------------------------------------------------------

///|
/// 互换角色：SEND <-> RECV；RELAY 保持 RELAY（中转无方向）。
///
/// 介质、密钥、中转通道原样复用（`reverse()` 不重建介质，只换角色标签），
/// 因此 A/B 反向传递不必重新配置 —— 与 vools 同语义。
pub fn Session::reverse(self : Session) -> Session {
  let new_role = match self.role {
    Relay => Relay
    Recv => Send
    Send => Recv
  }
  Session::new(
    new_role,
    self.shared,
    self.online.copy(),
    self.relay,
    self.crypto,
    self.name,
  )
}

///|
/// 会话描述（配置登记/调试用，对照 vools `describe`）。
///
/// 返回 `{"name", "role", "online": [名字...], "shared": 名字|null,
///        "relay": 基地址|null, "has_crypto": bool}`。
///
/// 注意：字段与 vools 逐字同形（vools 用 `getattr(x, "name", None)`，缺失给 null）；
/// 本方法**不做**介质探测，因此可以安全地在热路径反复调用。
pub fn Session::describe(self : Session) -> Json {
  let online_names : Array[Json] = []
  for ch in self.online {
    online_names.push(Json::string(OnlineChannel::name(ch)))
  }
  let shared_name = match self.shared {
    Some(view) => Json::string(SharedPath::name(view))
    None => Json::null()
  }
  let relay_base = match self.relay {
    Some(rc) => Json::string(rc.base())
    None => Json::null()
  }
  Json::object({
    "name": Json::string(self.name),
    "role": Json::string(self.role.to_string()),
    "online": Json::array(online_names),
    "shared": shared_name,
    "relay": relay_base,
    "has_crypto": Json::boolean(self.has_crypto()),
  })
}
