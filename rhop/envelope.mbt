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
/// 信封反序列化允许的最大 JSON 嵌套深度。
///
/// 显式取值（而非依赖 `@json.parse` 的默认值）以免核心库默认值变化导致行为漂移；
/// 与写入侧的**不对称**是已知限制：`to_rhop_bytes` 走迭代序列化、深度只受内存限制，
/// 而读入受此上限约束。超过该深度的 payload 属 out-of-contract（应拆层或改为外部引用）。
pub const MAX_ENVELOPE_NESTING_DEPTH : Int32 = 1000

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
  ///
  /// **契约**：按不可变值使用。构造/接收后不得原地修改其内层 `Array`/`Map`
  /// （`Json` 内部容器可变，多个信封会共享同一 `payload` 引用；原地改数会
  /// 让所有持有方的 `checksum` 与实际内容脱钩）。需要变更时请构造新的 `Json`
  /// 并通过 wither 替换，而不是就地改。
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
    // 防御性复制：调用方后续 push 不得影响「已封信封」的内容与 checksum
    //（C2 审计：旧实现直接持有入参数组，构造后 append 会让 checksum 静默失效、
    // 且两个信封共享数组时互相串扰）。
    hops_seen: hops_seen.copy(),
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
/// **每次序列化都按当前字段重算 checksum**（照抄 vools `to_rhop_bytes`，见
/// `envelope.py:79-83`）：这样「读入时补过默认值 / 调用方原地改过字段 /
/// 含未知字段被丢弃」的信封也能写出**自身可读回**的字节，而不是把已经失效的
/// 旧 `self.checksum` 原样写出去。
///
/// 与 Python `Envelope.to_rhop_bytes()` 逐字节一致的**前提**：对象构造后未被
/// 改动（`self.checksum == compute_checksum()`），且语料不含浮点（见
/// `json_canonical.mbt` 的已知限制）。构造时 `self.checksum` 原样保留
/// （`from_dict` 不校验 checksum，vools 语义），只有写出/校验时才重算。
pub fn Envelope::to_rhop_bytes(self : Envelope) -> Bytes {
  let fields = self.body_fields()
  fields["checksum"] = Json::string(self.compute_checksum())
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
  let parsed = @json.parse(
    text,
    preserve_number_repr=true,
    max_nesting_depth=MAX_ENVELOPE_NESTING_DEPTH,
  ) catch {
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
/// 取可选字符串字段：**缺键 ⇒ `default`；显式 `null` ⇒ 字段值非法**。
///
/// 与缺键给默认值的字段（created_at/updated_at）共用。vools 会保留 `None`，
/// 但本项目用 `String` 表示、无法无损表达 `null`；静默改写成 `""` 会与
/// checksum 脱钩且不可排障，故显式拒绝（见矩阵 §7 的取舍记录）。
fn optional_string_or(
  fields : Map[String, Json],
  key : String,
  default : String,
) -> String raise EnvelopeError {
  match fields.get(key) {
    None => default
    Some(String(text)) => text
    Some(Null) =>
      raise EnvelopeError(
        "envelope 字段值非法: \{key} 不能为 null（vools 保留 None，本实现用 String 表示、无法无损表达）",
      )
    Some(_) =>
      raise EnvelopeError("envelope 字段值非法: \{key} 必须是字符串")
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
/// 取可选整数字段：缺键 ⇒ `default`；**显式 `null` / 浮点 / 非数字 ⇒ 字段值非法**。
///
/// vools 对 `version: null` 会保留 `None`、对 `version: 2.7` 会保留 `2.7`；
/// 本项目用 `Int` 表示，无法无损表达 ⇒ 显式拒绝，**绝不静默截断/改值**
/// （见矩阵 §7 的取舍记录与 C1 报告 PROTO-02）。
fn optional_int(
  fields : Map[String, Json],
  key : String,
  default : Int32,
) -> Int32 raise EnvelopeError {
  match fields.get(key) {
    None => default
    Some(Number(value, ..)) => {
      // 先排除 NaN/Inf/超大数：直接 to_int() 在 wasm 上会 trap
      if value != value || value > 1.0e18 || value < -1.0e18 {
        raise EnvelopeError(
          "envelope 字段值非法: \{key} 必须是整数（收到 \{canonical_number(value, None)}）",
        )
      }
      let as_int = value.to_int()
      if as_int.to_double() != value {
        raise EnvelopeError(
          "envelope 字段值非法: \{key} 必须是整数（收到 \{canonical_number(value, None)}，vools 会保留浮点，本实现用 Int 无法无损表达）",
        )
      }
      as_int
    }
    Some(Null) =>
      raise EnvelopeError(
        "envelope 字段值非法: \{key} 不能为 null（vools 保留 None，本实现用 Int 无法无损表达）",
      )
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
/// 解析 `side` 字段：**缺键 ⇒ 默认 requester**（与 Python `data.get("side","requester")`
/// 一致）；显式 `null` ⇒ 与 vools 相同的拒绝（`None is not a valid Side`）。
fn parse_side(fields : Map[String, Json]) -> Side raise EnvelopeError {
  match fields.get("side") {
    None => Requester
    Some(String(raw)) =>
      match Side::parse(raw) {
        Ok(side) => side
        Err(reason) =>
          raise EnvelopeError("envelope 字段值非法: \{reason}")
      }
    Some(Null) =>
      raise EnvelopeError("envelope 字段值非法: None is not a valid Side")
    Some(_) =>
      raise EnvelopeError("envelope 字段值非法: side 必须是字符串")
  }
}

///|
/// 解析 `hops_seen`：**缺键 ⇒ 空数组**；显式 `null` ⇒ 字段值非法；元素必须是字符串。
fn parse_hops_seen(
  fields : Map[String, Json],
) -> Array[String] raise EnvelopeError {
  match fields.get("hops_seen") {
    None => []
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
    Some(Null) =>
      raise EnvelopeError(
        "envelope 字段值非法: hops_seen 不能为 null（vools 保留 None，本实现用数组无法无损表达）",
      )
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
