// ============================================================================
// fs_native.mbt —— monitor 包 native 文件系统 FFI 包装
// 目标：native 后端（由 moon.pkg targets 门控）
// 提供：读文本、原子写、列目录、stat 四原语
// ============================================================================

///|
/// 文件系统错误码。
pub(all) enum FsError {
  NotFound
  Io
  OutOfMemory
}

///|
/// 文件状态快照。
pub(all) struct FileStat {
  mtime_ns : Int64
  size : Int64
}

// ---------------------------------------------------------------------------
// 公共 API
// ---------------------------------------------------------------------------

///|
pub fn fs_read_text(path : String) -> Result[String, FsError] {
  fs_read_text_impl(path)
}

///|
pub fn fs_write_atomic(
  path : String,
  content : String,
) -> Result[Unit, FsError] {
  fs_write_atomic_impl(path, content)
}

///|
pub fn fs_list_rhop(dir : String) -> Result[Array[String], FsError] {
  fs_list_rhop_impl(dir)
}

///|
pub fn fs_stat(path : String) -> Result[FileStat, FsError] {
  fs_stat_impl(path)
}

///|
pub fn fs_remove(path : String) -> Result[Unit, FsError] {
  fs_remove_impl(path)
}

// ---------------------------------------------------------------------------
// Native 实现（使用 C FFI）
// ---------------------------------------------------------------------------

///|
#cfg(target="native")
fn fs_read_text_impl(path : String) -> Result[String, FsError] {
  let path_bytes = @utf8.encode(path)
  let result_bytes = fs_read_text_raw(path_bytes)
  let len = result_bytes.length()
  if len == 0 {
    let mtime_ns_ref = Ref::Ref(0L)
    let size_ref = Ref::Ref(0L)
    let code = fs_stat_raw(path_bytes, mtime_ns_ref, size_ref)
    if code != 0 {
      return Err(error_from_code(code))
    }
    return Ok("")
  }
  Ok(@utf8.decode_lossy(result_bytes))
}

///|
#cfg(target="native")
fn fs_write_atomic_impl(
  path : String,
  content : String,
) -> Result[Unit, FsError] {
  let path_bytes = @utf8.encode(path)
  let content_bytes = @utf8.encode(content)
  let code = fs_write_atomic_raw(path_bytes, content_bytes)
  if code != 0 {
    return Err(error_from_code(code))
  }
  Ok(())
}

///|
#cfg(target="native")
fn fs_list_rhop_impl(dir : String) -> Result[Array[String], FsError] {
  let dir_bytes = @utf8.encode(dir)
  let result_bytes = fs_list_rhop_raw(dir_bytes)
  let len = result_bytes.length()
  if len == 0 {
    let mtime_ns_ref = Ref::Ref(0L)
    let size_ref = Ref::Ref(0L)
    let code = fs_stat_raw(dir_bytes, mtime_ns_ref, size_ref)
    if code != 0 {
      return Err(error_from_code(code))
    }
    return Ok([])
  }
  let result_arr = @json.parse(@utf8.decode_lossy(result_bytes)) catch {
    _ => return Ok([])
  }
  let out : Array[String] = []
  match result_arr {
    @json.Array(items) =>
      for item in items {
        match item {
          @json.String(name) => out.push(name)
          _ => ()
        }
      }
    _ => ()
  }
  Ok(out)
}

///|
#cfg(target="native")
fn fs_stat_impl(path : String) -> Result[FileStat, FsError] {
  let path_bytes = @utf8.encode(path)
  let mtime_ns_ref = Ref::Ref(0L)
  let size_ref = Ref::Ref(0L)
  let code = fs_stat_raw(path_bytes, mtime_ns_ref, size_ref)
  if code != 0 {
    return Err(error_from_code(code))
  }
  Ok(FileStat::{ mtime_ns: mtime_ns_ref.val, size: size_ref.val, })
}

///|
#cfg(target="native")
fn fs_remove_impl(path : String) -> Result[Unit, FsError] {
  let path_bytes = @utf8.encode(path)
  let code = fs_remove_raw(path_bytes)
  if code != 0 {
    return Err(error_from_code(code))
  }
  Ok(())
}

// ---------------------------------------------------------------------------
// 非 native 实现（返回错误）
// ---------------------------------------------------------------------------

///|
#cfg(not(target="native"))
fn fs_read_text_impl(path : String) -> Result[String, FsError] {
  let _ = path
  Err(FsError::Io)
}

///|
#cfg(not(target="native"))
fn fs_write_atomic_impl(
  path : String,
  content : String,
) -> Result[Unit, FsError] {
  let _ = (path, content)
  Err(FsError::Io)
}

///|
#cfg(not(target="native"))
fn fs_list_rhop_impl(dir : String) -> Result[Array[String], FsError] {
  let _ = dir
  Err(FsError::Io)
}

///|
#cfg(not(target="native"))
fn fs_stat_impl(path : String) -> Result[FileStat, FsError] {
  let _ = path
  Err(FsError::Io)
}

///|
#cfg(not(target="native"))
fn fs_remove_impl(path : String) -> Result[Unit, FsError] {
  let _ = path
  Err(FsError::Io)
}

// ---------------------------------------------------------------------------
// FFI 声明（native 后端）
// 使用 Bytes 类型，由运行时自动处理
// #owned 表示所有权转移给 C，C 必须 decref
// #borrow 表示 C 只读/写，不存储引用
// ---------------------------------------------------------------------------

///|
#cfg(target="native")
#owned(path)
extern "c" fn fs_read_text_raw(path : Bytes) -> Bytes = "moonbit_fs_read_text"

///|
#cfg(target="native")
#owned(path)
#owned(content)
extern "c" fn fs_write_atomic_raw(path : Bytes, content : Bytes) -> Int32 = "moonbit_fs_write_atomic"

///|
#cfg(target="native")
#owned(dir)
extern "c" fn fs_list_rhop_raw(dir : Bytes) -> Bytes = "moonbit_fs_list_rhop"

///|
#cfg(target="native")
#owned(path)
#borrow(mtime_ns)
#borrow(size)
extern "c" fn fs_stat_raw(
  path : Bytes,
  mtime_ns : Ref[Int64],
  size : Ref[Int64],
) -> Int32 = "moonbit_fs_stat"

///|
#cfg(target="native")
#owned(path)
extern "c" fn fs_remove_raw(path : Bytes) -> Int32 = "moonbit_fs_remove"

// ---------------------------------------------------------------------------
// 错误码映射
// ---------------------------------------------------------------------------

///|
fn error_from_code(code : Int32) -> FsError {
  match code {
    1 => FsError::NotFound
    2 => FsError::Io
    3 => FsError::OutOfMemory
    _ => FsError::Io
  }
}
