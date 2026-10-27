// ============================================================================
// rhop · 信封完整性校验（对齐 vools-rhop `integrity.py`）
//
// 语义严格照抄 vools：
//   - `verify(env, raw)` 与 `verify_bytes(raw)` 都**只校验 raw 字节**能否
//     通过 `Envelope::from_rhop_bytes`（checksum + 必填字段）；`env` 参数
//     保留为 vools 同签名，当前实现不参与判定（vools 也是如此）；
//   - `checksum_match(env)` 走「序列化再反序列化」比对：先 `to_rhop_bytes()`
//     再 `from_rhop_bytes()`，仅当两者 checksum 相同才算匹配（篡改 checksum
//     字段的信封会在这里返回 false）。
// 纯逻辑，wasm / js / native 三目标可用。
// ============================================================================

///|
/// 信封完整性校验器（vools `IntegrityChecker`，无状态）。
///
/// 用于 SFTP / Git 等介质传输中断检测：收到的字节必须能通过 checksum 校验。
pub struct IntegrityChecker {}

///|
/// 构造无状态校验器。
pub fn IntegrityChecker::new() -> IntegrityChecker {
  IntegrityChecker::{ }
}

///|
/// 校验信封字节是否完整（对应 vools `IntegrityChecker.verify`）。
///
/// 返回 `(true, "")` 表示通过；`(false, reason)` 的 `reason` 是可诊断中文/原文
/// （`checksum mismatch: …` / `envelope JSON 解析失败: …` / `envelope 缺少必填字段: …`）。
///
/// 注：`env` 参数与 vools 同签名，当前实现只校验 `raw`（vools 亦然；保留它是
/// 为了让调用点与 Python 侧逐字对应）。
pub fn IntegrityChecker::verify(env : Envelope, raw : Bytes) -> (Bool, String) {
  ignore(env)
  IntegrityChecker::verify_bytes(raw)
}

///|
/// 直接校验 .rhop 字节（不依赖 `Envelope` 对象）。
pub fn IntegrityChecker::verify_bytes(raw : Bytes) -> (Bool, String) {
  match Envelope::from_rhop_bytes(raw) {
    Ok(_) => (true, "")
    Err(reason) => (false, reason)
  }
}

///|
/// 校验 `Envelope` 对象的 checksum 是否与自身内容匹配。
///
/// 实现方式与 vools 一致：`to_rhop_bytes()` → `from_rhop_bytes()` → 比对
/// checksum；任何一步失败都返回 `false`（不抛错）。
pub fn IntegrityChecker::checksum_match(env : Envelope) -> Bool {
  match Envelope::from_rhop_bytes(env.to_rhop_bytes()) {
    Ok(restored) => restored.checksum == env.checksum
    Err(_) => false
  }
}

///|
/// 便捷函数：等价 `IntegrityChecker::verify(env, raw)`。
pub fn integrity_verify(env : Envelope, raw : Bytes) -> (Bool, String) {
  IntegrityChecker::verify(env, raw)
}

///|
/// 便捷函数：等价 `IntegrityChecker::verify_bytes(raw)`。
pub fn integrity_verify_bytes(raw : Bytes) -> (Bool, String) {
  IntegrityChecker::verify_bytes(raw)
}

///|
/// 便捷函数：等价 `IntegrityChecker::checksum_match(env)`。
pub fn integrity_checksum_match(env : Envelope) -> Bool {
  IntegrityChecker::checksum_match(env)
}
