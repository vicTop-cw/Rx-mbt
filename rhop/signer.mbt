// ============================================================================
// rhop · 真机签名（对齐 vools-rhop `signer.py`）
//
// AbstractSigner  — 签名抽象（返回 String? ：无硬件时可为 None）
// FileHashSigner  — 通用文件哈希签名（非 NPU 场景兜底），格式 "sha256:<hex>"
// NPUSigner       — NPU 真机签名，格式 "<marker>:<serial>:<md5>"
//
// ⚠ preimage 口径（与 envelope checksum **不同**，照抄 vools 事实）：
//   preimage = json.dumps({"task_id":…, "result":…}, sort_keys=True)
//   vools 没传 ensure_ascii ⇒ Python 默认 **ensure_ascii=True**
//   ⇒ 非 ASCII 一律转义成 `\uXXXX`（故用 `canonical_json_ascii`）。
//   含中文 result 的签名只有按此口径才能与 vools 一致（qa fixture 有硬向量）。
// 纯逻辑（无 FFI / 无子进程），wasm / js / native 三目标可用。
// ============================================================================

///|
/// NPUSigner 的默认 marker 字面量（vools `NPUSigner(marker="NPU_MARKER")`）。
pub const NPU_MARKER_DEFAULT : String = "NPU_MARKER"

///|
/// 签名抽象（vools `AbstractSigner`）。
///
/// `sign` 返回 `None` 表示「当前环境无法签名」（例如没有 NPU 序列号），
/// 调用方应把信封的 `signature` 留空，而不是伪造一个值。
pub trait AbstractSigner {
  /// 对 `result` 签名；返回签名串，无法签名时返回 `None`。
  fn sign(Self, String, Json) -> String?
  /// 验证签名是否与 `(task_id, result)` 匹配；无法签名时恒为 `false`。
  fn verify(Self, String, Json, String) -> Bool
}

///|
/// 构造签名 preimage：`{"result": …, "task_id": …}`（键升序，ensure_ascii=True）。
///
/// 与 vools `json.dumps({"task_id": task_id, "result": result}, sort_keys=True)`
/// 逐字节一致。
fn signer_preimage(task_id : String, result : Json) -> String {
  let fields : Map[String, Json] = Map::new()
  fields["task_id"] = Json::string(task_id)
  fields["result"] = result
  canonical_json_ascii(Json::object(fields))
}

///|
/// 通用文件哈希签名（vools `FileHashSigner`）。
///
/// 签名 = `"sha256:" + hex(sha256(preimage))`，preimage 见 `signer_preimage`。
/// 确定性：同一 `(task_id, result)` 恒得同一签名；无需任何外部依赖。
pub struct FileHashSigner {}

///|
/// 构造无状态的文件哈希签名器。
pub fn FileHashSigner::new() -> FileHashSigner {
  FileHashSigner::{ }
}

///|
/// 计算签名（`"sha256:" + 64 位小写 hex`）。
pub fn FileHashSigner::signature(
  self : FileHashSigner,
  task_id : String,
  result : Json,
) -> String {
  "sha256:" + sha256_hex_of_utf8(signer_preimage(task_id, result))
}

///|
pub impl AbstractSigner for FileHashSigner with fn sign(self, task_id, result) {
  Some(self.signature(task_id, result))
}

///|
pub impl AbstractSigner for FileHashSigner with fn verify(
  self,
  task_id,
  result,
  signature,
) {
  signature == self.signature(task_id, result)
}

///|
/// NPU 真机签名（vools `NPUSigner`）。
///
/// 签名格式 `"<marker>:<serial>:<md5(preimage)>"`，其中 `serial` 由
/// `serial_provider` 注入；**provider 返回 `None` 时按 vools 的 `UNKNOWN_NPU`
/// 兜底**（`signer.py:52-74`：npu-smi 可执行但解析不到序列号 ⇒ 仍以
/// `"UNKNOWN_NPU"` 签名）。
///
/// 因此 `NPUSigner::sign` **恒不为 `None`**：本库不 spawn 子进程、无法区分
/// 「npu-smi 不存在」与「工具在但无序列号」，统一按可签名的 `UNKNOWN_NPU`
/// 处理（vools 在『工具不存在』时返回 `None`，该分支无法在本抽象中表达，
/// 见矩阵 §7 差异 17）。测试/真机由调用方注入 provider，三目标一致。
pub struct NPUSigner {
  /// 签名前缀标记（默认 `NPU_MARKER`）
  marker : String
  /// 序列号来源；返回 None ⇒ 使用 `UNKNOWN_NPU` 兜底
  serial_provider : () -> String?
}

///|
/// NPUSigner 解析不到序列号时的兜底字面量（vools `_get_npu_serial` 的
/// `return "UNKNOWN_NPU"`）。
pub const NPU_UNKNOWN_SERIAL : String = "UNKNOWN_NPU"

///|
/// 以指定 marker 构造 NPU 签名器（默认 provider 返回 None ⇒ `UNKNOWN_NPU` 兜底）。
pub fn NPUSigner::new(marker : String) -> NPUSigner {
  { marker, serial_provider: fn() { None }, }
}

///|
/// 以默认 marker（`NPU_MARKER`）构造 NPU 签名器。
pub fn NPUSigner::with_default_marker() -> NPUSigner {
  NPUSigner::new(NPU_MARKER_DEFAULT)
}

///|
/// 注入序列号来源（返回新对象，原对象不变）。
///
/// provider 返回 `Some(serial)` 时 `sign` 产出 `"<marker>:<serial>:<md5>"`；
/// 返回 `None` 时按 vools 语义用 `UNKNOWN_NPU` 兜底，仍可签名。
pub fn NPUSigner::with_serial_provider(
  self : NPUSigner,
  provider : () -> String?,
) -> NPUSigner {
  { marker: self.marker, serial_provider: provider, }
}

///|
/// 当前 marker。
pub fn NPUSigner::marker(self : NPUSigner) -> String {
  self.marker
}

///|
/// provider 是否提供了**真实**序列号（precheck，不产生签名）。
///
/// `false` 不代表不能签名——此时 `sign` 会走 `UNKNOWN_NPU` 兜底。
pub fn NPUSigner::has_serial(self : NPUSigner) -> Bool {
  match (self.serial_provider)() {
    Some(_) => true
    None => false
  }
}

///|
/// 解析实际参与签名的序列号：provider 的值，或 `UNKNOWN_NPU` 兜底。
fn NPUSigner::resolved_serial(self : NPUSigner) -> String {
  match (self.serial_provider)() {
    Some(serial) => serial
    None => NPU_UNKNOWN_SERIAL
  }
}

///|
pub impl AbstractSigner for NPUSigner with fn sign(self, task_id, result) {
  Some(
    self.marker +
    ":" +
    self.resolved_serial() +
    ":" +
    md5_hex_of_utf8(signer_preimage(task_id, result)),
  )
}

///|
pub impl AbstractSigner for NPUSigner with fn verify(
  self,
  task_id,
  result,
  signature,
) {
  match self.sign(task_id, result) {
    None => false
    Some(expected) => signature == expected
  }
}
