// ============================================================================
// watcher_native.mbt —— monitor 包 native 文件系统监控实现
//
// watch_folder_native：事件驱动（C 侧后台线程 ReadDirectoryChangesW 内核事件，
//   MoonBit 侧低频拉取，非轮询全量扫描；CPU 占用极低，内核事件真实）。
// watch_file_native：单文件轮询（stat 快照 diff，C FFI 真实睡眠）。
//
// 订阅闭包同步阻塞（调用方须在后台 async 任务 / 独立进程上下文中 subscribe）。
// ============================================================================

///|
/// 本地虚拟时钟（用于事件时间戳）
let watch_clock : @rx.Clock = @rx.Clock::new()

///|
/// 拉取间隔（毫秒，事件驱动的 MoonBit 侧拉取频率）
let poll_interval_ms : Ref[Int64] = Ref::Ref(50L)

///|
/// 设置拉取间隔（毫秒）。新增 API（.mbti 只增不改）。
pub fn set_poll_interval_ms(ms : Int64) -> Unit {
  poll_interval_ms.val = ms
}

///|
/// native 真实毫秒睡眠（C FFI，CPU 让出）
#cfg(target="native")
extern "c" fn moonbit_sleep_ms(ms : Int32) = "moonbit_sleep_ms"

///|
/// 事件驱动：启动 C 侧后台线程（ReadDirectoryChangesW）
#cfg(target="native")
#owned(path)
extern "c" fn moonbit_watch_start(path : Bytes, recursive : Int32) = "moonbit_watch_start"

///|
/// 事件驱动：拉取一批事件（编码字节流写入 out，返回总字节数）
/// 编码：每条 = kind(1) + path_len(4 大端) + path
#cfg(target="native")
#borrow(out)
extern "c" fn moonbit_watch_poll(out : Bytes, cap : Int32) -> Int32 = "moonbit_watch_poll"

///|
/// 事件驱动：停止后台线程
#cfg(target="native")
extern "c" fn moonbit_watch_stop() = "moonbit_watch_stop"

// ---------------------------------------------------------------------------
// 目录监控（事件驱动）
// ---------------------------------------------------------------------------

///|
/// 原生文件监控：监听目录，产出热 Observable（事件驱动）。
/// 参数：
///   path - 监控目录路径（绝对路径）
///   recursive - 是否递归监控子目录（默认 true）
/// 返回：@rx.Observable[WatchEvent, WatchError]
/// 注意：订阅闭包同步阻塞（拉取循环），调用方须在后台 async 任务中 subscribe
pub fn watch_folder_native(
  path : String,
  recursive~ : Bool = true,
) -> @rx.Observable[WatchEvent, WatchError] {
  @rx.Observable::new(fn(
    observer : @rx.Observer[WatchEvent, WatchError],
  ) -> @rx.Subscription {
    let path_bytes = @utf8.encode(path)
    moonbit_watch_start(path_bytes, if recursive { 1 } else { 0 })

    let stopped = Ref::Ref(false)
    let poll_buf = Bytes::make(8192, 0)

    // 低频拉取循环：C 侧内核事件 → 解析 → on_next
    while !stopped.val {
      moonbit_sleep_ms(poll_interval_ms.val.to_int())
      if stopped.val {
        break
      }
      let n = moonbit_watch_poll(poll_buf, 8192)
      let mut off = 0
      while off < n {
        let kind_b = poll_buf[off]
        off = off + 1
        let plen = (poll_buf[off].to_int() << 24) |
          (poll_buf[off + 1].to_int() << 16) |
          (poll_buf[off + 2].to_int() << 8) |
          poll_buf[off + 3].to_int()
        off = off + 4
        let plen_i = if plen < 0 { 0 } else { plen }
        match poll_buf.get_view(start=off, end=off + plen_i) {
          Some(pv) => {
            let p = @utf8.decode_lossy(pv)
            let kind = match kind_b.to_int() {
              1 => WatchKind::Created
              2 => WatchKind::Modified
              3 => WatchKind::Removed
              _ => WatchKind::Other
            }
            observer.on_next(WatchEvent::{
              path: p,
              kind,
              timestamp: watch_clock.now(),
              raw: "rdcw",
            })
            off = off + plen_i
          }
          None => off = off + plen_i
        }
      }
    }

    moonbit_watch_stop()

    @rx.Subscription::new(fn() { stopped.val = true })
  })
}

///|
/// 原生文件监控：监听目录（与 watcher_js.mbt 同名 API 对齐）
pub fn watch_folder(path : String) -> @rx.Observable[WatchEvent, WatchError] {
  watch_folder_native(path)
}

// ---------------------------------------------------------------------------
// 单文件监控（轮询 stat 快照 diff）
// ---------------------------------------------------------------------------

///|
/// 原生文件监控：单文件监控（轮询 stat diff）
/// 参数：
///   path - 监控文件路径（绝对路径）
/// 返回：@rx.Observable[WatchEvent, WatchError]
pub fn watch_file_native(
  path : String,
) -> @rx.Observable[WatchEvent, WatchError] {
  @rx.Observable::new(fn(
    observer : @rx.Observer[WatchEvent, WatchError],
  ) -> @rx.Subscription {
    let last_stat = Ref::Ref(FileStat::{ mtime_ns: 0L, size: 0L, })
    let stopped = Ref::Ref(false)

    // 初始状态
    match fs_stat(path) {
      Ok(stat) => last_stat.val = stat
      Err(_) => {
        observer.on_error(WatchError::NotFound("文件不存在"))
        return @rx.Subscription::empty()
      }
    }

    // 轮询循环：C FFI 真实睡眠
    while !stopped.val {
      moonbit_sleep_ms(poll_interval_ms.val.to_int())
      if stopped.val {
        break
      }
      watch_clock.advance(poll_interval_ms.val)

      match fs_stat(path) {
        Ok(stat) =>
          if stat.mtime_ns != last_stat.val.mtime_ns ||
            stat.size != last_stat.val.size {
            observer.on_next(WatchEvent::{
              path,
              kind: WatchKind::Modified,
              timestamp: watch_clock.now(),
              raw: "poll_diff",
            })
            last_stat.val = stat
          }
        Err(_) => {
          // 文件被删除
          observer.on_next(WatchEvent::{
            path,
            kind: WatchKind::Removed,
            timestamp: watch_clock.now(),
            raw: "poll_diff",
          })
          stopped.val = true
        }
      }
    }

    @rx.Subscription::new(fn() { stopped.val = true })
  })
}
