// ---------------------------------------------------------------------------
// fs_stubs_wasm.mbt —— wasm / wasm-gc 后端的 fs 占位实现。
// watcher 与 fs 的产品面只有 js/native 双实现；wasm 仅保持依赖图可编译
// （moon publish 会按全目标做 check），运行语义同旧 stub：一律 Err(Io)。
// ---------------------------------------------------------------------------

///|
fn fs_read_text_impl(path : String) -> Result[String, FsError] {
  let _ = path
  Err(FsError::Io)
}

///|
fn fs_write_atomic_impl(
  path : String,
  content : String,
) -> Result[Unit, FsError] {
  let _ = (path, content)
  Err(FsError::Io)
}

///|
fn fs_list_rhop_impl(dir : String) -> Result[Array[String], FsError] {
  let _ = dir
  Err(FsError::Io)
}

///|
fn fs_stat_impl(path : String) -> Result[FileStat, FsError] {
  let _ = path
  Err(FsError::Io)
}

///|
fn fs_remove_impl(path : String) -> Result[Unit, FsError] {
  let _ = path
  Err(FsError::Io)
}
