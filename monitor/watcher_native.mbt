// ============================================================================
// monitor · native 后端 —— 占位实现
// 当前状态：MoonBit core 尚无文件系统访问 API（无 core/fs），native 目标的
// 事件驱动（inotify）与轮询（polling）均需 C FFI 或等待 core/fs 支持。
// 为保证 API 跨目标一致，这里返回 Unsupported Observable，文档说明扩展点。
// 后续扩展：native polling（C FFI readdir + 快照 diff）或 core/fs 接入后，
// 直接替换本文件实现即可，公共 API 签名不变。
// ============================================================================

///|
/// 监控单个文件。native 目标当前不可用，返回 Unsupported 错误流。
pub fn watch_file(path : String) -> @rx.Observable[WatchEvent, WatchError] {
  @rx.Observable::new(fn(
    observer : @rx.Observer[WatchEvent, WatchError],
  ) -> @rx.Subscription {
    observer.on_error(
      WatchError::Unsupported(
        "native target 暂不支持文件监控：MoonBit core 无文件系统 API，js 目标为完整实现（node fs.watch）",
      ),
    )
    @rx.Subscription::empty()
  })
}

///|
/// 监控整个文件夹。native 目标当前不可用，返回 Unsupported 错误流。
pub fn watch_folder(path : String) -> @rx.Observable[WatchEvent, WatchError] {
  @rx.Observable::new(fn(
    observer : @rx.Observer[WatchEvent, WatchError],
  ) -> @rx.Subscription {
    observer.on_error(
      WatchError::Unsupported(
        "native target 暂不支持文件监控：MoonBit core 无文件系统 API，js 目标为完整实现（node fs.watch）",
      ),
    )
    @rx.Subscription::empty()
  })
}
