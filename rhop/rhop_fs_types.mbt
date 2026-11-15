// ============================================================================
// rhop_fs_types.mbt —— rhop 包文件系统类型定义（跨目标共享）
// 目标：所有目标（js/native/wasm）
// 提供：FsError、FileStat 类型定义
// ============================================================================

///|
/// 文件系统错误码。
pub enum FsError {
  NotFound
  Io
  OutOfMemory
}

///|
/// 文件状态快照。
pub struct FileStat {
  mtime_ns : Int64
  size : Int64
}
