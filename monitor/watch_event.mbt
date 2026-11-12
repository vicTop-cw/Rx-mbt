// ============================================================================
// monitor —— 文件系统监控（watch_file / watch_folder）
// 同机器异进程场景：进程 A 监控 shared path，观察进程 B 的写入变更。
// 目标说明：
//   - js 目标：事件驱动（node fs.watch，Windows 底层 ReadDirectoryChangesW /
//     Linux 底层 inotify），实时、零轮询；
//   - native 目标：受 MoonBit core 无文件系统 API 限制，暂返回 Unsupported，
//     后续可接 C FFI polling 或 core/fs 支持后补齐。
// ============================================================================

///|
/// 文件系统监控事件类别（归一化）
/// 注意：node fs.watch 的 `rename` 事件语义模糊（创建/删除/重命名进入或离开
/// 均可能报 rename），js 后端通过事件后的 exists 探测区分 Created / Removed。
#derive(Eq, Debug)
pub(all) enum WatchKind {
  /// 文件或目录被创建（或重命名进入监控范围）
  Created
  /// 内容被修改
  Modified
  /// 被删除（或重命名离开监控范围）
  Removed
  /// 无法归一化的其他事件
  Other
}

///|
pub extend WatchKind with Eq::{not_equal, equal}
///|
pub extend WatchKind with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// 一次文件系统变更事件
#derive(Eq, Debug)
pub struct WatchEvent {
  /// 触发事件的路径（js 后端为绝对路径；后端无法给出文件名时为监控根路径）
  path : String
  /// 事件类别
  kind : WatchKind
  /// 事件发生时刻（epoch 毫秒）
  timestamp : Int64
  /// 后端透传的原始事件类型字符串（如 "rename" / "change"），便于排查
  raw : String
}

///|
pub extend WatchEvent with Eq::{not_equal, equal}
///|
pub extend WatchEvent with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// 监控错误
#derive(Eq, Debug)
pub(all) enum WatchError {
  /// 路径不存在或无法访问（附后端错误信息）
  NotFound(String)
  /// 当前目标/后端不支持该能力
  Unsupported(String)
  /// 其他 IO 错误
  Io(String)
}

///|
pub extend WatchError with Eq::{not_equal, equal}
///|
pub extend WatchError with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn WatchEvent::to_string(self : WatchEvent) -> String {
  let kind_s = match self.kind {
    WatchKind::Created => "created"
    WatchKind::Modified => "modified"
    WatchKind::Removed => "removed"
    WatchKind::Other => "other"
  }
  "WatchEvent(path=\{self.path}, kind=\{kind_s}, ts=\{self.timestamp}, raw=\{self.raw})"
}

///|
pub fn WatchError::to_string(self : WatchError) -> String {
  match self {
    WatchError::NotFound(msg) => "WatchError::NotFound(\{msg})"
    WatchError::Unsupported(msg) => "WatchError::Unsupported(\{msg})"
    WatchError::Io(msg) => "WatchError::Io(\{msg})"
  }
}
