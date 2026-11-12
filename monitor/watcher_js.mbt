// ============================================================================
// monitor · js 后端 —— 事件驱动实现（node fs.watch）
// 底层：Windows ReadDirectoryChangesW / Linux inotify / macOS FSEvents。
// 每个订阅独立启动一个 watcher；dispose 时关闭句柄。
// ============================================================================

///|
/// 监控单个文件（事件驱动）。
/// 注意：node fs.watch 对单文件监控需要绑定其父目录句柄 + filename 过滤，
/// 这里直接 watch 目标路径本身（fs.watch 支持直接 watch 文件路径）。
pub fn watch_file(path : String) -> @rx.Observable[WatchEvent, WatchError] {
  watch_path(path)
}

///|
/// 监控整个文件夹（事件驱动），该目录下的任何文件/子目录变更都会触发。
pub fn watch_folder(path : String) -> @rx.Observable[WatchEvent, WatchError] {
  watch_path(path)
}

///|
fn watch_path(path : String) -> @rx.Observable[WatchEvent, WatchError] {
  @rx.Observable::new(fn(
    observer : @rx.Observer[WatchEvent, WatchError],
  ) -> @rx.Subscription {
    let id = ffi_watch_start(path, fn(id, kind_tag, ts, raw, fname) {
      let full = if fname == "" { path } else { join_path(path, fname) }
      let kind = match kind_tag {
        0 => WatchKind::Created
        1 => WatchKind::Modified
        2 => WatchKind::Removed
        _ => WatchKind::Other
      }
      observer.on_next({ path: full, kind, timestamp: ts, raw, })
    })
    if id < 0L {
      let err = ffi_watch_last_error()
      observer.on_error(WatchError::NotFound(err))
      return @rx.Subscription::empty()
    }
    @rx.Subscription::new(fn() { ffi_watch_stop(id) })
  })
}

///|
/// 拼接监控根路径与 fs.watch 回调给出的相对文件名。
/// 统一使用 "/" 分隔：node fs 在 Windows 下同样接受 "/"，可跨平台。
fn join_path(root : String, fname : String) -> String {
  if root.has_suffix("/") || root.has_suffix("\\") {
    root + fname
  } else {
    root + "/" + fname
  }
}

// ---------------------------------------------------------------------------
// FFI：node fs.watch 封装
// 约定：
//   - globalThis.__rxmbt_watch_reg : Map[Int64, FSWatcher]  句柄注册表
//   - globalThis.__rxmbt_watch_seq : 单调递增 id
//   - globalThis.__rxmbt_watch_err : 最近一次启动失败的错误信息
// 回调签名：(watcherId, kindTag, timestampMs, rawEventType, filename)
//   kindTag: 0=Created 1=Modified 2=Removed 3=Other（与 WatchKind 顺序一致）
// ---------------------------------------------------------------------------

///|
extern "js" fn ffi_watch_start(
  path : String,
  cb : (Int64, Int64, Int64, String, String) -> Unit,
) -> Int64 =
  #| (path, cb) => { const G = globalThis; if (G.__rxmbt_watch_err === undefined) { G.__rxmbt_watch_err = ""; } if (G.__rxmbt_watch_reg === undefined) { G.__rxmbt_watch_reg = new Map(); G.__rxmbt_watch_seq = 0; } try { const id = G.__rxmbt_watch_seq++; const fs = process.getBuiltinModule("node:fs"); const pathMod = process.getBuiltinModule("node:path"); const sep = pathMod.sep; const watcher = fs.watch(path, { persistent: true }, (et, fn) => { let target = path; if (fn !== null) { target = (path.endsWith("/") || path.endsWith("\\")) ? (path + fn) : (path + sep + fn); } let kind = 3; if (et === "change") { kind = 1; } else if (fs.existsSync(target)) { kind = 0; } else { kind = 2; } cb(BigInt(id), BigInt(kind), BigInt(Date.now()), et, fn === null ? "" : fn); }); G.__rxmbt_watch_reg.set(id, watcher); return BigInt(id); } catch (e) { G.__rxmbt_watch_err = String(e && e.message || e); return BigInt(-1); } }

///|
/// 停止并释放某个 watcher 句柄。
///
/// **键类型必须与 start 侧一致**：`__rxmbt_watch_reg` 的 key 是 `ffi_watch_start` 里
/// `G.__rxmbt_watch_seq++` 产生的 **JS number**，而这里的形参 `id : Int64` 进到 JS 是
/// **BigInt**。若直接 `reg.get(id)` 会因 `BigInt(0) !== 0` 恒得 undefined，
/// `close()` 永远不执行 —— 表现是 fs.watch 句柄泄漏 + node 进程无法自然退出
/// （rhop watch/relay js 测试曾因此挂住且不打印汇总行）。故统一 `Number(id)` 归一。
extern "js" fn ffi_watch_stop(id : Int64) -> Unit =
  #| (id) => { const G = globalThis; if (G.__rxmbt_watch_reg === undefined) { return; } const key = Number(id); const w = G.__rxmbt_watch_reg.get(key); if (w !== undefined) { try { w.close(); } catch (_e) {} G.__rxmbt_watch_reg.delete(key); } }

///|
extern "js" fn ffi_watch_last_error() -> String =
  #| () => { const G = globalThis; return (G.__rxmbt_watch_err === undefined) ? "" : G.__rxmbt_watch_err; }
