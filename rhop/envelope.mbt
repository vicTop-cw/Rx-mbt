// ============================================================================
// rhop · 任务信封（对齐 vools-rhop `envelope.py`，.rhop 文件格式）
//
// 设计要点（照抄 vools 语义）：
//   - `v: 1` 写在序列化结果里（向前兼容），但不进 `to_dict()`；
//   - checksum = "sha256:" + hex(canonical_json(除 checksum 外全部字段 + v=1))，
//     与 Python 逐字节一致（两侧都用 sort_keys + ensure_ascii=False 口径）；
//   - hops_seen 是审计链：每次 daemon 处理后追加自己的 side；
//   - 信封不含密钥——密钥在配置侧管理。
// 纯逻辑，wasm / js / native 三目标可用。
// ============================================================================

///|
/// 信封字段解析错误（内部用 `raise` 传播，出口统一转成 `Result[_, String]`）。
priv suberror EnvelopeError {
  EnvelopeError(String)
}

///|
/// 任务信封：镜像任务中继协议的最小传递单位（vools `Envelope`）。
///
/// 字段顺序与 vools dataclass 声明一致；`result` / `error` / `signature`
/// 用 `Option` 表达「缺省」语义，序列化时显式写成 `null`（与 Python 一致）。
pub struct Envelope {
  /// 任务 id
  task_id : String
  /// 任务状态
  status : TaskStatus
  /// 任务载荷（任意 JSON）
  payload : Json
  /// 执行结果（无则 None ⇒ 序列化为 null）
  result : Json?
  /// 失败原因（无则 None ⇒ null）
  error : String?
  /// 由哪一方产生/处理
  side : Side
  /// 乐观锁版本号（镜像同步防冲突）
  version : Int32
  /// 创建时间（ISO 字符串，空串表示未设置）
  created_at : String
  /// 最后更新时间（ISO 字符串）
  updated_at : String
  /// 审计链：处理过该信封的 side 序列
  hops_seen : Array[String]
  /// 签名（FileHashSigner / NPUSigner 输出；无则 None ⇒ null）
  signature : String?
  /// 内容校验和 `sha256:<64 hex>`（覆盖除自身外的全部字段 + v=1）
  checksum : String
}

///|
/// 按 vools `__post_init__` 语义装配信封：`checksum` 为空时自动计算。
fn assemble(
  task_id : String,
  status : TaskStatus,
  payload : Json,
  result : Json?,
  error : String?,
  side : Side,
  version : Int32,
  created_at : String,
  updated_at : String,
  hops_seen : Array[String],
  signature : String?,
  checksum : String,
) -> Envelope {
  let draft : Envelope = {
    task_id,
    status,
    payload,
    result,
    error,
    side,
    version,
    created_at,
    updated_at,
    hops_seen,
    signature,
    checksum,
  }
  if checksum.is_empty() {
    { ..draft, checksum: draft.compute_checksum(), }
  } else {
    draft
  }
}

///|
/// 最常用构造：新建需求端待领取信封（version=1、时间戳留空、无结果/签名）。
///
/// 构造即计算 checksum，故 `env.checksum` 永不为空。
pub fn Envelope::new(
  task_id : String,
  status : TaskStatus,
  payload : Json,
  side : Side,
) -> Envelope {
  assemble(task_id, status, payload, None, None, side, 1, "", "", [], None, "")
}

///|
/// 全字段构造（可选参数缺省值与 vools dataclass 默认值一致）。
///
/// `checksum` 通常留空由构造自动计算；显式传入时原样保留（供反序列化用）。
pub fn Envelope::new_full(
  task_id : String,
  status : TaskStatus,
  payload : Json,
  side : Side,
  result? : Json,
  error? : String,
  version~ : Int32 = 1,
  created_at~ : String = "",
  updated_at~ : String = "",
  hops_seen~ : Array[String] = [],
  signature? : String,
  checksum~ : String = "",
) -> Envelope {
  assemble(
    task_id, status, payload, result, error, side, version, created_at, updated_at,
    hops_seen, signature, checksum,
  )
}

///|
/// 计算内容校验和：`"sha256:" + hex(sha256(canonical_json({v:1, …除 checksum 外字段})))`。
///
/// 键序、分隔符、转义与 Python `json.dumps(..., sort_keys=True, ensure_ascii=False)`
/// 逐字节一致，故跨实现（Python ↔ MoonBit）可比对。
pub fn Envelope::compute_checksum(self : Envelope) -> String {
  let body = Json::object(self.body_fields())
  "sha256:" + sha256_hex(canonical_json_utf8(body))
}

///|
/// 构造参与 checksum 的字段集合（含 `v=1`，不含 `checksum`）。
///
/// `result` / `error` / `signature` 为 `None` 时写成 JSON `null`，
/// 与 vools 的 `data["result"] = None` 等价。
fn Envelope::body_fields(self : Envelope) -> Map[String, Json] {
  let fields : Map[String, Json] = Map([])
  fields["v"] = Json::number(1.0)
  fields["task_id"] = Json::string(self.task_id)
  fields["status"] = Json::string(self.status.to_string())
  fields["payload"] = self.payload
  fields["result"] = match self.result {
    Some(value) => value
    None => Json::null()
  }
  fields["error"] = match self.error {
    Some(text) => Json::string(text)
    None => Json::null()
  }
  fields["side"] = Json::string(self.side.to_string())
  fields["version"] = Json::number(self.version.to_double())
  fields["created_at"] = Json::string(self.created_at)
  fields["updated_at"] = Json::string(self.updated_at)
  let hops : Array[Json] = []
  for hop in self.hops_seen {
    hops.push(Json::string(hop))
  }
  fields["hops_seen"] = Json::array(hops)
  fields["signature"] = match self.signature {
    Some(text) => Json::string(text)
    None => Json::null()
  }
  fields
}

///|
/// 序列化为 .rhop 文件字节：规范 JSON（含 `checksum` 键）的 UTF-8 编码。
///
/// 与 Python `Envelope.to_rhop_bytes()` 逐字节一致（前提是语料不含浮点，
/// 见 `json_canonical.mbt` 的已知限制）。
pub fn Envelope::to_rhop_bytes(self : Envelope) -> Bytes {
  let fields = self.body_fields()
  fields["checksum"] = Json::string(self.checksum)
  canonical_json_utf8(Json::object(fields))
}

///|
/// 反序列化 + 完整性校验。
///
/// 错误统一为 `Err(中文原因)`：
///   - 非法 UTF-8 / 坏 JSON → `envelope JSON 解析失败: …`
///   - checksum 不匹配 → `checksum mismatch: envelope may be corrupted（期望 …）`
///   - 缺必填字段 → `envelope 缺少必填字段: <字段名>`
///   - 字段类型/取值非法（status/side 无法识别等）→ `envelope 字段值非法: …`
///
/// 校验和按「解析出的对象去掉 checksum 后的全部键」重算，因此**未知字段也参与
/// 校验**（与 Python 先 `pop("checksum")` 再 `dumps` 的口径一致）。
pub fn Envelope::from_rhop_bytes(raw : Bytes) -> Result[Envelope, String] {
  let text = @utf8.decode(raw) catch {
    _ => return Err("envelope JSON 解析失败: 非法 UTF-8 字节")
  }
  let parsed = @json.parse(text, preserve_number_repr=true) catch {
    err => return Err("envelope JSON 解析失败: \{err.to_string()}")
  }
  let fields = match parsed {
    Object(members) => members
    _ => return Err("envelope JSON 解析失败: 顶层必须是 JSON 对象")
  }
  let checksum = match fields.get("checksum") {
    Some(String(text)) => text
    Some(_) =>
      return Err("envelope 字段值非法: checksum 必须是字符串")
    None => ""
  }
  // 重算校验和：去掉 checksum 键、保留其余全部键（含未知键），与 Python 一致
  let body : Map[String, Json] = Map([])
  for key in fields.keys() {
    if key != "checksum" {
      body[key] = fields.at(key)
    }
  }
  let expected = "sha256:" + sha256_hex(canonical_json_utf8(Json::object(body)))
  if checksum != expected {
    return Err(
      "checksum mismatch: envelope may be corrupted（期望 \{expected}，实际 \"\{checksum}\"）",
    )
  }
  Ok(parse_envelope_fields(fields)) catch {
    EnvelopeError(msg) => Err(msg)
  }
}

///|
/// 从字段表构造信封并校验 checksum（vools `from_dict` 语义：不校验，仅保留）。
pub fn Envelope::from_dict(data : Json) -> Result[Envelope, String] {
  let fields = match data {
    Object(members) => members
    _ => return Err("envelope 字段值非法: from_dict 需要 JSON 对象")
  }
  Ok(parse_envelope_fields(fields)) catch {
    EnvelopeError(msg) => Err(msg)
  }
}

///|
/// 字段表 → 信封（`result` / `error` / `signature` 缺省为 None）。
///
/// 必填：`task_id`（字符串）、`status`（可识别字面量）、`payload`（任意 JSON）。
/// `checksum` 缺省为空 ⇒ 由构造自动计算（与 Python `from_dict` 同语义）。
fn parse_envelope_fields(
  fields : Map[String, Json],
) -> Envelope raise EnvelopeError {
  let task_id = require_string(fields, "task_id")
  let status = parse_status(fields)
  let payload = match fields.get("payload") {
    Some(value) => value
    None => raise EnvelopeError("envelope 缺少必填字段: payload")
  }
  let result = optional_json(fields, "result")
  let error = optional_string(fields, "error")
  let side = parse_side(fields)
  let version = optional_int(fields, "version", 1)
  let created_at = optional_string_or(fields, "created_at", "")
  let updated_at = optional_string_or(fields, "updated_at", "")
  let hops_seen = parse_hops_seen(fields)
  let signature = optional_string(fields, "signature")
  let checksum = optional_string(fields, "checksum").unwrap_or("")
  assemble(
    task_id, status, payload, result, error, side, version, created_at, updated_at,
    hops_seen, signature, checksum,
  )
}

///|
/// 取必填字符串字段。
fn require_string(
  fields : Map[String, Json],
  key : String,
) -> String raise EnvelopeError {
  match fields.get(key) {
    Some(String(text)) => text
    Some(_) =>
      raise EnvelopeError("envelope 字段值非法: \{key} 必须是字符串")
    None => raise EnvelopeError("envelope 缺少必填字段: \{key}")
  }
}

///|
/// 取可选字符串字段（缺省 / `null` ⇒ None）。
fn optional_string(
  fields : Map[String, Json],
  key : String,
) -> String? raise EnvelopeError {
  match fields.get(key) {
    None | Some(Null) => None
    Some(String(text)) => Some(text)
    Some(_) =>
      raise EnvelopeError(
        "envelope 字段值非法: \{key} 必须是字符串或 null",
      )
  }
}

///|
/// 取可选字符串字段，缺省 / `null` ⇒ `default`（供 created_at/updated_at 等
/// 带空串默认值的字段用）。
fn optional_string_or(
  fields : Map[String, Json],
  key : String,
  default : String,
) -> String raise EnvelopeError {
  match optional_string(fields, key) {
    Some(text) => text
    None => default
  }
}

///|
/// 取可选 JSON 字段（缺省 / `null` ⇒ None）。
fn optional_json(fields : Map[String, Json], key : String) -> Json? {
  match fields.get(key) {
    None | Some(Null) => None
    Some(value) => Some(value)
  }
}

///|
/// 取可选整数字段（缺省 ⇒ `default`；非数字 ⇒ 错误）。
fn optional_int(
  fields : Map[String, Json],
  key : String,
  default : Int32,
) -> Int32 raise EnvelopeError {
  match fields.get(key) {
    None | Some(Null) => default
    Some(Number(value, ..)) => value.to_int()
    Some(_) =>
      raise EnvelopeError("envelope 字段值非法: \{key} 必须是数字")
  }
}

///|
/// 解析 `status` 字段（缺失 ⇒ 缺字段错误；无法识别 ⇒ 字段值非法）。
fn parse_status(fields : Map[String, Json]) -> TaskStatus raise EnvelopeError {
  let raw = require_string(fields, "status")
  match TaskStatus::parse(raw) {
    Ok(status) => status
    Err(reason) => raise EnvelopeError("envelope 字段值非法: \{reason}")
  }
}

///|
/// 解析 `side` 字段（缺失 ⇒ 默认 requester，与 Python `Side(data.get("side","requester"))` 一致）。
fn parse_side(fields : Map[String, Json]) -> Side raise EnvelopeError {
  match fields.get("side") {
    None | Some(Null) => Requester
    Some(String(raw)) =>
      match Side::parse(raw) {
        Ok(side) => side
        Err(reason) =>
          raise EnvelopeError("envelope 字段值非法: \{reason}")
      }
    Some(_) =>
      raise EnvelopeError("envelope 字段值非法: side 必须是字符串")
  }
}

///|
/// 解析 `hops_seen`（缺省 / null ⇒ 空数组；元素必须是字符串）。
fn parse_hops_seen(
  fields : Map[String, Json],
) -> Array[String] raise EnvelopeError {
  match fields.get("hops_seen") {
    None | Some(Null) => []
    Some(Array(items)) => {
      let hops : Array[String] = []
      for item in items {
        match item {
          String(text) => hops.push(text)
          _ =>
            raise EnvelopeError(
              "envelope 字段值非法: hops_seen 元素必须是字符串",
            )
        }
      }
      hops
    }
    Some(_) =>
      raise EnvelopeError("envelope 字段值非法: hops_seen 必须是数组")
  }
}

///|
/// 转为 JSON 对象（便于序列化存储）。
///
/// 与 `to_rhop_bytes` 的区别：**不含 `v` 字段**（照抄 vools `to_dict`），
/// 但包含 `checksum`；`result` / `error` / `signature` 缺省写 `null`。
pub fn Envelope::to_dict(self : Envelope) -> Json {
  let fields : Map[String, Json] = Map([])
  fields["task_id"] = Json::string(self.task_id)
  fields["status"] = Json::string(self.status.to_string())
  fields["payload"] = self.payload
  fields["result"] = match self.result {
    Some(value) => value
    None => Json::null()
  }
  fields["error"] = match self.error {
    Some(text) => Json::string(text)
    None => Json::null()
  }
  fields["side"] = Json::string(self.side.to_string())
  fields["version"] = Json::number(self.version.to_double())
  fields["created_at"] = Json::string(self.created_at)
  fields["updated_at"] = Json::string(self.updated_at)
  let hops : Array[Json] = []
  for hop in self.hops_seen {
    hops.push(Json::string(hop))
  }
  fields["hops_seen"] = Json::array(hops)
  fields["signature"] = match self.signature {
    Some(text) => Json::string(text)
    None => Json::null()
  }
  fields["checksum"] = Json::string(self.checksum)
  Json::object(fields)
}

///|
/// 替换 `result` 并重算 checksum（返回新对象，原对象不变）。
pub fn Envelope::with_result(self : Envelope, result : Json?) -> Envelope {
  assemble(
    self.task_id,
    self.status,
    self.payload,
    result,
    self.error,
    self.side,
    self.version,
    self.created_at,
    self.updated_at,
    self.hops_seen.copy(),
    self.signature,
    "",
  )
}

///|
/// 替换 `updated_at` 并重算 checksum（返回新对象）。
pub fn Envelope::with_updated_at(
  self : Envelope,
  updated_at : String,
) -> Envelope {
  assemble(
    self.task_id,
    self.status,
    self.payload,
    self.result,
    self.error,
    self.side,
    self.version,
    self.created_at,
    updated_at,
    self.hops_seen.copy(),
    self.signature,
    "",
  )
}

///|
/// 替换 `hops_seen` 并重算 checksum（返回新对象）。
pub fn Envelope::with_hops_seen(
  self : Envelope,
  hops_seen : Array[String],
) -> Envelope {
  assemble(
    self.task_id,
    self.status,
    self.payload,
    self.result,
    self.error,
    self.side,
    self.version,
    self.created_at,
    self.updated_at,
    hops_seen,
    self.signature,
    "",
  )
}

///|
/// 替换 `status` 并重算 checksum（返回新对象）。
///
/// 便捷 wither（vools 侧由状态机调用方直接构造），语义与其它 wither 一致。
pub fn Envelope::with_status(self : Envelope, status : TaskStatus) -> Envelope {
  assemble(
    self.task_id,
    status,
    self.payload,
    self.result,
    self.error,
    self.side,
    self.version,
    self.created_at,
    self.updated_at,
    self.hops_seen.copy(),
    self.signature,
    "",
  )
}

///|
/// 替换 `signature` 并重算 checksum（返回新对象）。
pub fn Envelope::with_signature(
  self : Envelope,
  signature : String?,
) -> Envelope {
  assemble(
    self.task_id,
    self.status,
    self.payload,
    self.result,
    self.error,
    self.side,
    self.version,
    self.created_at,
    self.updated_at,
    self.hops_seen.copy(),
    signature,
    "",
  )
}
