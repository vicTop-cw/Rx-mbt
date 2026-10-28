// ============================================================================
// rhop · 镜像数据库（Batch D · P1）
//
// 对照 vools.rhop.mirror（Python sqlite3）：双方各持一份本地 SQLite，schema 完全一致；
// daemon 负责同步——本类**只提供本地读写，不做网络操作**。
//
// 表结构（与 vools 对齐 + 两列 `envelope`/`claimed_by` 便于整信封往返与领取审计）：
//   tasks    — task_id 主键；status/side/payload/result/error/signature/version/
//              created_at/updated_at/checksum/envelope/claimed_by
//   events   — 状态变更事件流水（pending_sync 的数据源）
//   sync_log — 同步审计日志（push/pull 结果、字节数）
//
// 乐观锁（对齐 vools `StaleVersionError` 语义）：
//   upsert_task 要求传入信封的 version **严格大于** 库内 version，否则 Err
//   （错误文本以 `stale_version:` 开头，可用 `is_stale_version_error` 判别）；
//   update_status 要求调用方给出**已知版本**，与库内不一致同样 Err（防覆盖写）。
//
// 序列化（复用 Batch A 的 Envelope）：
//   行内 `envelope` 列 = `Envelope::to_rhop_bytes()` 的 UTF-8 文本（规范 JSON，含 checksum），
//   读回时走 `Envelope::from_rhop_bytes()`（**含 checksum 校验**），因此镜像库里的
//   每一行都自证完整性 —— 坏行会以可诊断 Err 暴露，而不是静默返回半个信封。
//
// 目标可用性：
//   - js：node:sqlite（`process.getBuiltinModule("node:sqlite")` 的 DatabaseSync）真实建库；
//   - wasm / native：无内建 SQLite，`MirrorDB::open` 返回**可诊断 Err**
//     （不静默成功、不假装有库），因此三目标均可 `moon check` 通过。
//
// 本文件同时是 Batch D 的**低层基础设施**层：sqlite 句柄表、文件系统（fs）、
// 时间戳（UTC ISO）三组 FFI 集中在此，供 requester/executor/daemon/sync_folder 复用，
// 避免每个业务文件各写一套 node FFI（也避免多人文件互相 extern 撞名）。
// ============================================================================

// ---------------------------------------------------------------------------
// 低层基础设施 · 时间戳
// ---------------------------------------------------------------------------

///|
/// 当前 UTC ISO 时间戳（`YYYY-MM-DDTHH:MM:SSZ`，与 vools `_now_iso()` 同形）。
///
/// js 用 `Date.toISOString()` 去掉毫秒；wasm/native 无时钟 API，返回固定占位
/// `1970-01-01T00:00:00Z`（仅用于可编译与纯逻辑测试，真实业务在 js 侧跑）。
pub fn rhop_now_iso() -> String {
  rhop_ffi_now_iso()
}

///|
/// js：取 UTC ISO 时间戳（秒精度）。
#cfg(target="js")
extern "js" fn rhop_ffi_now_iso() -> String =
  #| () => { try { return new Date().toISOString().replace(/\.\d{3}Z$/, "Z"); } catch (e) { return "1970-01-01T00:00:00Z"; } }

///|
/// 非 js：无时钟 API，返回固定占位（调用方需自备时间戳时请显式传参）。
#cfg(not(target="js"))
fn rhop_ffi_now_iso() -> String {
  "1970-01-01T00:00:00Z"
}

// ---------------------------------------------------------------------------
// 低层基础设施 · 默认数据目录（**不落仓库根**）
// ---------------------------------------------------------------------------

///|
/// 默认数据目录：js 目标取 `<系统临时目录>/rhop-data`（**不写仓库根**）。
///
/// 业务层 `Requester::new` / `Executor::new` / `RelayDaemon::new` 在配置里推断不出
/// data_dir 时用它；要固定位置请显式用 `from_config_dir(data_dir=...)`。
/// 非 js 目标无文件系统，返回占位（构造期会先因 sqlite 不可用而 Err，不会真建目录）。
pub fn rhop_default_data_dir() -> String {
  rhop_default_data_dir_impl()
}

///|
/// js：`os.tmpdir()/rhop-data`；取不到临时目录时退化为 `./rhop-data`。
#cfg(target="js")
fn rhop_default_data_dir_impl() -> String {
  let dir = rhop_ffi_temp_data_dir()
  if dir == "" {
    "./rhop-data"
  } else {
    dir
  }
}

///|
/// 非 js：占位（sqlite 不可用，业务层构造会先 Err）。
#cfg(not(target="js"))
fn rhop_default_data_dir_impl() -> String {
  "./rhop-data"
}

// ---------------------------------------------------------------------------
// 低层基础设施 · sqlite 句柄表（js）
// ---------------------------------------------------------------------------

///|
/// 打开数据库文件并登记句柄，返回句柄 id；失败返回 Err（含 node 侧原因）。
///
/// 父目录不存在时先递归创建（vools 由调用方 `_ensure_dirs` 保证，这里兜底）。
pub fn rhop_db_open(path : String) -> Result[Int32, String] {
  rhop_db_open_impl(path)
}

///|
/// js：建/开库。
#cfg(target="js")
fn rhop_db_open_impl(path : String) -> Result[Int32, String] {
  ignore(rhop_ffi_mkdir_p_parent(path))
  let id = rhop_ffi_db_open(path)
  if id < 0 {
    Err(rhop_ffi_db_error())
  } else {
    Ok(id)
  }
}

///|
/// 非 js：无内建 SQLite，显式报不可用（不伪造文件）。
#cfg(not(target="js"))
fn rhop_db_open_impl(path : String) -> Result[Int32, String] {
  let _ = path
  Err(
    "MirrorDB 仅 js 目标可用：wasm/native 无内建 SQLite（node:sqlite）",
  )
}

///|
/// 关闭数据库句柄（幂等；未知句柄静默忽略）。
pub fn rhop_db_close(id : Int32) -> Unit {
  rhop_db_close_impl(id)
}

///|
/// js：关库。
#cfg(target="js")
fn rhop_db_close_impl(id : Int32) -> Unit {
  rhop_ffi_db_close(id)
}

///|
/// 非 js：空操作。
#cfg(not(target="js"))
fn rhop_db_close_impl(id : Int32) -> Unit {
  let _ = id
  ()
}

///|
/// 执行一条不带结果集的 SQL（参数用 JSON 数组传入）；失败返回可诊断 Err。
///
/// 只要「成功/失败」时用它；需要**影响行数**（乐观锁、零行更新检测）请用
/// `rhop_db_run_changes`——零行更新不再被当成成功。
pub fn rhop_db_run(
  id : Int32,
  sql : String,
  params : Json,
) -> Result[Unit, String] {
  match rhop_db_run_changes_impl(id, sql, params) {
    Ok(_) => Ok(())
    Err(msg) => Err(msg)
  }
}

///|
/// 执行一条写 SQL，返回 `(changes, lastInsertRowid)`；失败返回可诊断 Err。
///
/// 对齐 `rhop_task/task_store.mbt` 的 `{changes,lastInsertRowid}` 范式：
/// 调用方据 `changes` 判定「SQL 谓词没命中」，**不得把零行更新当成功**。
pub fn rhop_db_run_changes(
  id : Int32,
  sql : String,
  params : Json,
) -> Result[(Int32, Int64), String] {
  rhop_db_run_changes_impl(id, sql, params)
}

///|
/// 执行一条无参数 SQL（事务控制 / 多语句）；失败返回可诊断 Err。
pub fn rhop_db_exec(id : Int32, sql : String) -> Result[Unit, String] {
  rhop_db_exec_impl(id, sql)
}

///|
/// js：`prepare(...).run(...)` → 解析 `{changes,lastInsertRowid}`。
#cfg(target="js")
fn rhop_db_run_changes_impl(
  id : Int32,
  sql : String,
  params : Json,
) -> Result[(Int32, Int64), String] {
  let text = rhop_ffi_db_run(id, sql, canonical_json(params))
  // 空串 = 调用失败（成功时至少是 {"changes":0,...}）
  if text == "" {
    return Err(rhop_ffi_db_error())
  }
  let parsed = @json.parse(text) catch {
    err => return Err("镜像库写结果解析失败: \{err.to_string()}")
  }
  match parsed {
    { "changes": Number(c, ..), "lastInsertRowid": Number(r, ..), .. } =>
      Ok((c.to_int(), r.to_int64()))
    _ => Err("镜像库写结果结构意外: \{text}")
  }
}

///|
/// 非 js：不可用。
#cfg(not(target="js"))
fn rhop_db_run_changes_impl(
  id : Int32,
  sql : String,
  params : Json,
) -> Result[(Int32, Int64), String] {
  let _ = (id, sql, params)
  Err(
    "MirrorDB 仅 js 目标可用：wasm/native 无内建 SQLite（node:sqlite）",
  )
}

///|
/// js：`db.exec(sql)`（事务控制语句专用）。
#cfg(target="js")
fn rhop_db_exec_impl(id : Int32, sql : String) -> Result[Unit, String] {
  if rhop_ffi_db_exec(id, sql) {
    Ok(())
  } else {
    Err(rhop_ffi_db_error())
  }
}

///|
/// 非 js：不可用。
#cfg(not(target="js"))
fn rhop_db_exec_impl(id : Int32, sql : String) -> Result[Unit, String] {
  let _ = (id, sql)
  Err(
    "MirrorDB 仅 js 目标可用：wasm/native 无内建 SQLite（node:sqlite）",
  )
}

///|
/// 执行一条查询并返回行对象数组；失败返回可诊断 Err。
pub fn rhop_db_all(
  id : Int32,
  sql : String,
  params : Json,
) -> Result[Array[Json], String] {
  rhop_db_all_impl(id, sql, params)
}

///|
/// js：prepare(...).all(...params) → JSON 数组文本 → 解析为 `Array[Json]`。
#cfg(target="js")
fn rhop_db_all_impl(
  id : Int32,
  sql : String,
  params : Json,
) -> Result[Array[Json], String] {
  let text = rhop_ffi_db_all(id, sql, canonical_json(params))
  // 空串 = 调用失败（成功时至少是 "[]"）
  if text == "" {
    return Err(rhop_ffi_db_error())
  }
  let parsed = @json.parse(text) catch {
    err => return Err("镜像库查询结果解析失败: \{err.to_string()}")
  }
  match parsed {
    Array(rows) => Ok(rows)
    _ => Err("镜像库查询结果解析失败: 顶层必须是 JSON 数组")
  }
}

///|
/// 非 js：不可用。
#cfg(not(target="js"))
fn rhop_db_all_impl(
  id : Int32,
  sql : String,
  params : Json,
) -> Result[Array[Json], String] {
  let _ = (id, sql, params)
  Err(
    "MirrorDB 仅 js 目标可用：wasm/native 无内建 SQLite（node:sqlite）",
  )
}

// ---------------------------------------------------------------------------
// 低层基础设施 · 文件系统（信封投递、目录同步都用它）
// ---------------------------------------------------------------------------

///|
/// 递归创建目录（已存在视为成功）。
pub fn rhop_fs_mkdir_p(dir : String) -> Result[Unit, String] {
  rhop_fs_mkdir_p_impl(dir)
}

///|
/// js：fs.mkdirSync(recursive)。
#cfg(target="js")
fn rhop_fs_mkdir_p_impl(dir : String) -> Result[Unit, String] {
  if rhop_ffi_mkdir_p(dir) {
    Ok(())
  } else {
    Err(rhop_ffi_fs_error())
  }
}

///|
/// 非 js：无文件系统 API。
#cfg(not(target="js"))
fn rhop_fs_mkdir_p_impl(dir : String) -> Result[Unit, String] {
  let _ = dir
  Err("文件系统操作仅 js 目标可用（wasm/native 无 node:fs）")
}

///|
/// 写 UTF-8 文本文件（先写 `*.tmp` 再 rename，读方只会看到完整文件）。
pub fn rhop_fs_write_text(path : String, text : String) -> Result[Unit, String] {
  rhop_fs_write_text_impl(path, text)
}

///|
/// js：原子写。
#cfg(target="js")
fn rhop_fs_write_text_impl(
  path : String,
  text : String,
) -> Result[Unit, String] {
  ignore(rhop_ffi_mkdir_p_parent(path))
  if rhop_ffi_write_atomic(path, text) {
    Ok(())
  } else {
    Err(rhop_ffi_fs_error())
  }
}

///|
/// 非 js：不可用。
#cfg(not(target="js"))
fn rhop_fs_write_text_impl(
  path : String,
  text : String,
) -> Result[Unit, String] {
  let _ = (path, text)
  Err("文件系统操作仅 js 目标可用（wasm/native 无 node:fs）")
}

///|
/// 读 UTF-8 文本文件。
pub fn rhop_fs_read_text(path : String) -> Result[String, String] {
  rhop_fs_read_text_impl(path)
}

///|
/// js：readFileSync。
#cfg(target="js")
fn rhop_fs_read_text_impl(path : String) -> Result[String, String] {
  let text = rhop_ffi_read_text(path)
  if rhop_ffi_fs_ok() {
    Ok(text)
  } else {
    Err(rhop_ffi_fs_error())
  }
}

///|
/// 非 js：不可用。
#cfg(not(target="js"))
fn rhop_fs_read_text_impl(path : String) -> Result[String, String] {
  let _ = path
  Err("文件系统操作仅 js 目标可用（wasm/native 无 node:fs）")
}

///|
/// 路径是否存在（文件或目录）。
pub fn rhop_fs_exists(path : String) -> Bool {
  rhop_ffi_exists(path)
}

///|
/// 列目录下的文件名（**非递归**，仅普通文件，按字典序）；目录不存在返回空数组。
pub fn rhop_fs_list_dir(dir : String) -> Array[String] {
  let text = rhop_ffi_list_dir(dir)
  let out : Array[String] = []
  if text == "" {
    return out
  }
  let parsed = @json.parse(text) catch { _ => return out }
  match parsed {
    Array(items) =>
      for item in items {
        match item {
          String(name) => out.push(name)
          _ => ()
        }
      }
    _ => ()
  }
  out
}

///|
/// 移动/重命名文件（目标父目录自动创建；源不存在返回 Err）。
pub fn rhop_fs_move(src : String, dst : String) -> Result[Unit, String] {
  rhop_fs_move_impl(src, dst)
}

///|
/// js：rename（跨盘失败回退 copy+unlink）。
#cfg(target="js")
fn rhop_fs_move_impl(src : String, dst : String) -> Result[Unit, String] {
  ignore(rhop_ffi_mkdir_p_parent(dst))
  if rhop_ffi_move(src, dst) {
    Ok(())
  } else {
    Err(rhop_ffi_fs_error())
  }
}

///|
/// 非 js：不可用。
#cfg(not(target="js"))
fn rhop_fs_move_impl(src : String, dst : String) -> Result[Unit, String] {
  let _ = (src, dst)
  Err("文件系统操作仅 js 目标可用（wasm/native 无 node:fs）")
}

///|
/// 删除文件（不存在视为成功，幂等）。
pub fn rhop_fs_remove(path : String) -> Result[Unit, String] {
  rhop_fs_remove_impl(path)
}

///|
/// js：unlink。
#cfg(target="js")
fn rhop_fs_remove_impl(path : String) -> Result[Unit, String] {
  if rhop_ffi_remove(path) {
    Ok(())
  } else {
    Err(rhop_ffi_fs_error())
  }
}

///|
/// 非 js：不可用。
#cfg(not(target="js"))
fn rhop_fs_remove_impl(path : String) -> Result[Unit, String] {
  let _ = path
  Err("文件系统操作仅 js 目标可用（wasm/native 无 node:fs）")
}

///|
/// 计算文件的 sha256 + 字节数，返回 `{"sha256": "...", "size": <n>}`。
///
/// 二进制安全（在 js 侧直接算摘要，不把整文件搬进 MoonBit），
/// 供目录同步（`sync_folder`）做「内容是否变化」判据。
pub fn rhop_fs_digest_file(path : String) -> Result[Json, String] {
  rhop_fs_digest_file_impl(path)
}

///|
/// js：readFileSync + createHash。
#cfg(target="js")
fn rhop_fs_digest_file_impl(path : String) -> Result[Json, String] {
  let text = rhop_ffi_file_digest(path)
  if text == "" {
    return Err(rhop_ffi_fs_error())
  }
  let parsed = @json.parse(text) catch {
    err => return Err("文件摘要结果解析失败: \{err.to_string()}")
  }
  Ok(parsed)
}

///|
/// 非 js：不可用。
#cfg(not(target="js"))
fn rhop_fs_digest_file_impl(path : String) -> Result[Json, String] {
  let _ = path
  Err("文件系统操作仅 js 目标可用（wasm/native 无 node:fs）")
}

///|
/// 复制文件（二进制安全，目标父目录自动创建）。
pub fn rhop_fs_copy(src : String, dst : String) -> Result[Unit, String] {
  rhop_fs_copy_impl(src, dst)
}

///|
/// js：copyFileSync。
#cfg(target="js")
fn rhop_fs_copy_impl(src : String, dst : String) -> Result[Unit, String] {
  ignore(rhop_ffi_mkdir_p_parent(dst))
  if rhop_ffi_copy(src, dst) {
    Ok(())
  } else {
    Err(rhop_ffi_fs_error())
  }
}

///|
/// 非 js：不可用。
#cfg(not(target="js"))
fn rhop_fs_copy_impl(src : String, dst : String) -> Result[Unit, String] {
  let _ = (src, dst)
  Err("文件系统操作仅 js 目标可用（wasm/native 无 node:fs）")
}

///|
/// 递归列出目录下全部**普通文件**的相对路径（`/` 分隔，按字典序）；
/// 目录不存在返回空数组。
pub fn rhop_fs_list_files_recursive(dir : String) -> Array[String] {
  let text = rhop_ffi_list_files_recursive(dir)
  let out : Array[String] = []
  if text == "" {
    return out
  }
  let parsed = @json.parse(text) catch { _ => return out }
  match parsed {
    Array(items) =>
      for item in items {
        match item {
          String(name) => out.push(name)
          _ => ()
        }
      }
    _ => ()
  }
  out
}

///|
/// 取路径的父目录（无分隔符 ⇒ `"."`；以分隔符开头且无其它层级 ⇒ `"/"`）。
///
/// 本版本无 `dirname`，逐字符扫描最后一个 `/` 或 `\`。
pub fn rhop_fs_parent(path : String) -> String {
  let n = path.length()
  let mut cut = -1
  let mut i = 0
  while i < n {
    let ch = match path.get_view(start=i, end=i + 1) {
      Some(v) => v.to_owned()
      None => ""
    }
    if ch == "/" || ch == "\\" {
      cut = i
    }
    i = i + 1
  }
  if cut < 0 {
    return "."
  }
  if cut == 0 {
    return "/"
  }
  match path.get_view(start=0, end=cut) {
    Some(v) => v.to_owned()
    None => "."
  }
}

///|
/// 路径拼接（统一 `/`；左串已以 `/` 或 `\` 结尾时不重复加分隔符）。
pub fn rhop_join(a : String, b : String) -> String {
  if a == "" {
    return b
  }
  if a.has_suffix("/") || a.has_suffix("\\") {
    a + b
  } else {
    a + "/" + b
  }
}

///|
/// 路径规范化：`\` → `/`、折叠连续分隔符、消解 `.` 与 `..`（`..` 弹栈，栈空则丢弃）。
///
/// 不解析符号链接（node 侧也不会），目的是**纯词法**上的前缀比较。
pub fn rhop_normalize_path(path : String) -> String {
  let unified = path.replace_all(old="\\", new="/")
  let absolute = unified.has_prefix("/")
  let parts : Array[String] = []
  for raw in unified.split("/") {
    let seg = raw.to_owned()
    if seg == "" || seg == "." {
      continue
    } else if seg == ".." {
      if parts.length() > 0 {
        ignore(parts.pop())
      }
    } else {
      parts.push(seg)
    }
  }
  let joined = parts.join("/")
  if absolute {
    "/" + joined
  } else {
    joined
  }
}

///|
/// 任务 ID 白名单校验：`^[A-Za-z0-9._-]{1,128}$`，且拒绝任何含 `..` 的串。
///
/// 为什么必须有：`task_id` 会被拼进文件名（`inbox/<task_id>.rhop`），
/// 而它来自**对端信封**（不可信输入）；不校验即可 `../../evil` 逃出数据目录。
pub fn validate_task_id(task_id : String) -> Result[Unit, String] {
  let n = task_id.length()
  if n == 0 {
    return Err("task_id 非法：不能为空")
  }
  if n > 128 {
    return Err("task_id 非法：长度 \{n} 超过上限 128（\{task_id}）")
  }
  for ch in task_id.to_array() {
    let code = ch.to_int()
    let ok = (code >= 48 && code <= 57) ||
      (code >= 65 && code <= 90) ||
      (code >= 97 && code <= 122) ||
      code == 45 ||
      code == 46 ||
      code == 95
    if not(ok) {
      return Err(
        "task_id 非法：仅允许 [A-Za-z0-9._-]，实际含 \{ch}（\{task_id}）",
      )
    }
  }
  if task_id == "." || task_id == ".." || task_id.contains("..") {
    return Err(
      "task_id 非法：含路径穿越片段 `.`/`..`（\{task_id}）",
    )
  }
  Ok(())
}

///|
/// 安全拼接：`b` 必须是**单层文件名**（非空、无分隔符、无 `..`、非 `.`），
/// 且拼接结果**规范化后仍以 `a` 为前缀**（防御 `..` / 盘符 / UNC 逃逸）。
///
/// 与裸 `rhop_join` 的区别：`rhop_join` 只拼字符串，本函数额外做词法前缀断言。
pub fn rhop_join_checked(a : String, b : String) -> Result[String, String] {
  if b == "" {
    return Err("路径拼接被拒绝：子路径为空")
  }
  if b.contains("/") || b.contains("\\") {
    return Err("路径拼接被拒绝：子路径含分隔符（\{b}）")
  }
  if b == "." || b.contains("..") {
    return Err("路径拼接被拒绝：子路径含 `.`/`..`（\{b}）")
  }
  let joined = rhop_join(a, b)
  let base = rhop_normalize_path(a)
  let full = rhop_normalize_path(joined)
  if not(full == base || full.has_prefix(base + "/")) {
    return Err(
      "路径拼接被拒绝：规范化后逃出基准目录（base=\{base} → result=\{full}）",
    )
  }
  Ok(joined)
}

///|
/// 阻塞休眠（毫秒）。js 用 `Atomics.wait`（主线程可安全阻塞），非 js 为空操作。
///
/// 业务层（requester 轮询 / daemon 主循环 / sync_folder 守护）统一用它，
/// 避免各处各写一套忙等。
pub fn rhop_sleep_ms(ms : Int32) -> Unit {
  rhop_sleep_ms_impl(ms)
}

///|
/// js：Atomics.wait；不可用时退化为忙等。
#cfg(target="js")
extern "js" fn rhop_sleep_ms_impl(ms : Int32) -> Unit =
  #| (ms) => { const n = Number(ms); if (!(n > 0)) { return; } try { const sab = new SharedArrayBuffer(4); Atomics.wait(new Int32Array(sab), 0, 0, n); } catch (e) { const t0 = Date.now(); while (Date.now() - t0 < n) {} } }

///|
/// 非 js：空操作（无阻塞原语；纯逻辑测试不依赖真实等待）。
#cfg(not(target="js"))
fn rhop_sleep_ms_impl(ms : Int32) -> Unit {
  let _ = ms
  ()
}

// ---------------------------------------------------------------------------
// MirrorDB
// ---------------------------------------------------------------------------

///|
/// 乐观锁冲突（vools `StaleVersionError` 的 MoonBit 对应物）。
///
/// 所有 `MirrorDB` 方法统一用 `Result[_, String]` 报错（契约 §2.2），因此本结构体
/// 主要作**语义标记**：它渲染出的错误文本恒以 `stale_version:` 开头，
/// 调用方用 `is_stale_version_error(msg)` 判别，而不是靠字符串细节匹配整句。
pub struct StaleVersionError {
  task_id : String
  local_version : Int32
  incoming_version : Int32
}

///|
/// 构造一条版本冲突错误。
pub fn StaleVersionError::new(
  task_id : String,
  local_version : Int32,
  incoming_version : Int32,
) -> StaleVersionError {
  { task_id, local_version, incoming_version, }
}

///|
/// 冲突涉及的 task_id。
pub fn StaleVersionError::task_id(self : StaleVersionError) -> String {
  self.task_id
}

///|
/// 渲染为可诊断错误文本（带 `stale_version:` 前缀）。
pub fn StaleVersionError::to_string(self : StaleVersionError) -> String {
  "stale_version: task \{self.task_id} 本地 version=\{self.local_version}，" +
  "写入方 version=\{self.incoming_version}（乐观锁拒绝覆盖）"
}

///|
/// 判断一条错误文本是否属于乐观锁冲突（`stale_version:` 前缀）。
pub fn is_stale_version_error(message : String) -> Bool {
  message.has_prefix("stale_version:")
}

///|
/// 镜像数据库句柄。
///
/// 生命周期：`MirrorDB::open(path)` 建/开库并初始化 schema（幂等），
/// `close()` 释放。**句柄关闭后继续调用**返回可诊断 Err（不 panic、不静默成功）。
pub struct MirrorDB {
  path : String
  handle : Int32
  mut closed : Bool
  // 若本库由 `open_temp()` 创建：临时目录（`close()` 时递归删除）；否则 `""`。
  mut temp_root : String
}

///|
/// 打开（或新建）指定路径的镜像库，并幂等初始化 schema。
///
/// js：node:sqlite 真建库；wasm/native：返回可诊断 Err（详见文件头）。
pub fn MirrorDB::open(path : String) -> Result[MirrorDB, String] {
  if path == "" {
    return Err("MirrorDB::open 需要非空数据库路径")
  }
  let handle = match rhop_db_open(path) {
    Ok(id) => id
    Err(msg) => return Err(msg)
  }
  let db : MirrorDB = { path, handle, closed: false, temp_root: "", }
  match db.init_schema() {
    Ok(_) => Ok(db)
    Err(msg) => {
      rhop_db_close(handle)
      Err(msg)
    }
  }
}

///|
/// 打开一个**临时**库（同一进程内唯一路径，供测试/单机闭环快速起库）。
///
/// 落地位置：`<tmpdir>/rhop-mirror-<rand>/mirror-<seq>.db`（js 的 os.tmpdir()），
/// 调用方负责 `close()`；文件本身不在本方法里删除（便于事后取证）。
pub fn MirrorDB::open_temp() -> Result[MirrorDB, String] {
  let dir = match rhop_temp_workspace("rhop-mirror-") {
    Ok(d) => d
    Err(e) =>
      return Err(
        "MirrorDB::open_temp 失败：\{e}（临时库仅 js 目标可用）",
      )
  }
  let path = rhop_join(dir, "mirror.db")
  match MirrorDB::open(path) {
    Ok(db) => {
      db.temp_root = dir
      Ok(db)
    }
    Err(msg) => {
      ignore(rhop_remove_dir_all(dir))
      Err(msg)
    }
  }
}

///|
/// 数据库文件路径。
pub fn MirrorDB::path(self : MirrorDB) -> String {
  self.path
}

///|
/// 是否仍处于打开状态。
pub fn MirrorDB::is_open(self : MirrorDB) -> Bool {
  !self.closed
}

///|
/// 幂等建表（对齐 vools SCHEMA_SQL；额外两列 `envelope`/`claimed_by`）。
fn MirrorDB::init_schema(self : MirrorDB) -> Result[Unit, String] {
  let stmts : Array[String] = [
    // P2-2：多进程（CLI + daemon）同库时，重叠写会立刻 SQLITE_BUSY 失败。
    // 设 5s 忙等，让短事务自然串行化（对齐 rhop_task/task_store.mbt 的 busy_timeout_sec=5.0）。
    "PRAGMA busy_timeout = 5000", "CREATE TABLE IF NOT EXISTS tasks (task_id TEXT PRIMARY KEY, status TEXT NOT NULL, side TEXT NOT NULL, payload TEXT NOT NULL, result TEXT, error TEXT, signature TEXT, version INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, checksum TEXT NOT NULL, envelope TEXT NOT NULL, claimed_by TEXT)",
    "CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY AUTOINCREMENT, task_id TEXT NOT NULL, event_type TEXT NOT NULL, old_status TEXT, new_status TEXT, detail TEXT, created_at TEXT NOT NULL)",
    "CREATE TABLE IF NOT EXISTS sync_log (id INTEGER PRIMARY KEY AUTOINCREMENT, direction TEXT NOT NULL, transport TEXT NOT NULL, task_id TEXT, success INTEGER NOT NULL, error TEXT, bytes_xfer INTEGER DEFAULT 0, created_at TEXT NOT NULL)",
    "CREATE INDEX IF NOT EXISTS idx_events_task ON events(task_id)", "CREATE INDEX IF NOT EXISTS idx_sync_task ON sync_log(task_id)",
    "CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status)",
  ]
  for sql in stmts {
    match self.run(sql, Json::array([])) {
      Ok(_) => ()
      Err(msg) => return Err(msg)
    }
  }
  Ok(())
}

///|
/// 内部：执行 SQL（自动附加「已关闭」检查）；不在乎影响行数（保留旧签名）。
fn MirrorDB::run(
  self : MirrorDB,
  sql : String,
  params : Json,
) -> Result[Unit, String] {
  match self.run_changes(sql, params) {
    Ok(_) => Ok(())
    Err(msg) => Err(msg)
  }
}

///|
/// 内部：执行写 SQL 并返回 `(changes, lastInsertRowid)`（含「已关闭」检查）。
///
/// 所有写路径的唯一入口：**上层必须自己校验 `changes`**，否则「谓词没命中的
/// 零行更新」会伪装成成功（这正是 Batch D 里丢失更新/双领的根因）。
fn MirrorDB::run_changes(
  self : MirrorDB,
  sql : String,
  params : Json,
) -> Result[(Int32, Int64), String] {
  if self.closed {
    return Err("MirrorDB 已关闭（\{self.path}）：拒绝继续操作")
  }
  rhop_db_run_changes(self.handle, sql, params)
}

///|
/// 内部：执行无参数 SQL（事务控制用；同样带「已关闭」检查）。
fn MirrorDB::exec(self : MirrorDB, sql : String) -> Result[Unit, String] {
  if self.closed {
    return Err("MirrorDB 已关闭（\{self.path}）：拒绝继续操作")
  }
  rhop_db_exec(self.handle, sql)
}

///|
/// 在一个 `BEGIN IMMEDIATE` 写事务里跑 `body`。
///
/// 语义（保证「主表 + 事件流水」要么都落、要么都不落）：
///   - BEGIN 失败 → 直接 Err（不执行 body）；
///   - body Err → ROLLBACK（尽力）后原样上抛；
///   - body Ok → COMMIT；COMMIT 失败 → ROLLBACK（尽力）+ 可诊断 Err（不假装成功）。
///
/// 注意：**不可嵌套**（body 内部不要再调本方法，否则 sqlite 报
/// "cannot start a transaction within a transaction"）。
fn[T] MirrorDB::write_tx(
  self : MirrorDB,
  body : () -> Result[T, String],
) -> Result[T, String] {
  match self.exec("BEGIN IMMEDIATE") {
    Ok(_) => ()
    Err(msg) => return Err("开启写事务失败: \{msg}")
  }
  match body() {
    Ok(value) =>
      match self.exec("COMMIT") {
        Ok(_) => Ok(value)
        Err(msg) => {
          ignore(self.exec("ROLLBACK"))
          Err("提交写事务失败: \{msg}")
        }
      }
    Err(msg) => {
      ignore(self.exec("ROLLBACK"))
      Err(msg)
    }
  }
}

///|
/// 内部：查询（自动附加「已关闭」检查）。
fn MirrorDB::all(
  self : MirrorDB,
  sql : String,
  params : Json,
) -> Result[Array[Json], String] {
  if self.closed {
    return Err("MirrorDB 已关闭（\{self.path}）：拒绝继续操作")
  }
  rhop_db_all(self.handle, sql, params)
}

///|
/// 写入/更新任务（对照 vools `upsert_task`）。
///
/// 乐观锁：task_id 已存在且 `env.version <= 库内 version` → Err（`stale_version:`）。
/// 行为对齐 vools：行内 `updated_at` 由**本地盖章**，事件流水追加一条 `updated`。
pub fn MirrorDB::upsert_task(
  self : MirrorDB,
  env : Envelope,
) -> Result[Unit, String] {
  // DB 层同样拒非法 task_id（不只 daemon/requester 层）：白名单 + 禁 `..`。
  match validate_task_id(env.task_id) {
    Err(msg) => return Err("upsert_task 拒绝非法 task_id：\{msg}")
    Ok(_) => ()
  }
  // 单条 UPSERT（不再「先 SELECT 再 INSERT」）：版本守卫下推到 SQL——
  // `excluded.version > tasks.version` 不成立时零行写入 → 显式 stale，
  // 且不像 `INSERT OR REPLACE` 那样把 `claimed_by` 抹成 NULL、不丢 created_at。
  let now = rhop_now_iso()
  let body = fn() {
    // 本地盖章 updated_at 并重算 checksum，保证「行内自洽」（读回时 checksum 校验必过）
    let stamped = env.with_updated_at(now)
    let envelope_text = utf8_text(stamped.to_rhop_bytes())
    let changes = match
      self.run_changes(
        "INSERT INTO tasks (task_id, status, side, payload, result, error, signature, version, created_at, updated_at, checksum, envelope, claimed_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL) ON CONFLICT(task_id) DO UPDATE SET status=excluded.status, side=excluded.side, payload=excluded.payload, result=excluded.result, error=excluded.error, signature=excluded.signature, version=excluded.version, updated_at=excluded.updated_at, checksum=excluded.checksum, envelope=excluded.envelope WHERE excluded.version > tasks.version",
        Json::array([
          Json::string(stamped.task_id),
          Json::string(stamped.status.to_string()),
          Json::string(stamped.side.to_string()),
          Json::string(canonical_json(stamped.payload)),
          mir_json_or_null_text(stamped.result),
          mir_opt_string(stamped.error),
          mir_opt_string(stamped.signature),
          Json::number(stamped.version.to_double()),
          Json::string(stamped.created_at),
          Json::string(stamped.updated_at),
          Json::string(stamped.checksum),
          Json::string(envelope_text),
        ]),
      ) {
      Ok(pair) => pair.0
      Err(msg) => return Err(msg)
    }
    if changes != 1 {
      // 0 行 = 库内版本不比来件小（stale）；>1 不可能（task_id 是主键）
      let latest = match
        self.all(
          "SELECT version FROM tasks WHERE task_id = ?",
          Json::array([Json::string(env.task_id)]),
        ) {
        Ok(rows) => rows
        Err(msg) => return Err(msg)
      }
      if latest.length() == 0 {
        return Err(
          "upsert_task 异常：无版本冲突却零行写入（task_id=\{env.task_id}）",
        )
      }
      return Err(
        StaleVersionError::new(
          env.task_id,
          mir_row_int(latest[0], "version", 0),
          env.version,
        ).to_string(),
      )
    }
    match
      self.append_event(
        env.task_id,
        "updated",
        None,
        Some(stamped.status.to_string()),
        None,
        now,
      ) {
      Ok(_) => ()
      Err(msg) => return Err(msg)
    }
    Ok(())
  }
  self.write_tx(body)
}

///|
/// 读取单个任务；不存在返回 `None`，出错也返回 `None`。
///
/// 需要区分「不存在」与「库坏了」时请用 `try_get_task`（返回 `Result`）。
pub fn MirrorDB::get_task(self : MirrorDB, task_id : String) -> Envelope? {
  match self.try_get_task(task_id) {
    Ok(found) => found
    Err(_) => None
  }
}

///|
/// 读取单个任务（可诊断版本）：`Ok(None)` = 不存在，`Err` = 库/行损坏。
pub fn MirrorDB::try_get_task(
  self : MirrorDB,
  task_id : String,
) -> Result[Envelope?, String] {
  match validate_task_id(task_id) {
    Err(msg) => return Err("try_get_task 拒绝非法 task_id：\{msg}")
    Ok(_) => ()
  }
  let rows = match
    self.all(
      "SELECT * FROM tasks WHERE task_id = ?",
      Json::array([Json::string(task_id)]),
    ) {
    Ok(rows) => rows
    Err(msg) => return Err(msg)
  }
  if rows.length() == 0 {
    return Ok(None)
  }
  match mir_row_to_envelope(rows[0]) {
    Ok(env) => Ok(Some(env))
    Err(msg) => Err(msg)
  }
}

///|
/// 列出任务（对照 vools `list_tasks`），按 `created_at DESC, task_id ASC` 排序。
///
/// `status` 省略 = 全部状态；`limit` 缺省 50（与 vools 一致）。
pub fn MirrorDB::list_tasks(
  self : MirrorDB,
  status? : TaskStatus,
  limit~ : Int32 = 50,
) -> Array[Envelope] {
  let cap = if limit <= 0 { 50 } else { limit }
  match self.try_list_tasks(status, cap) {
    Ok(list) => list
    Err(_) => []
  }
}

///|
/// 列出任务（可诊断版本，语义同 `list_tasks`）。
///
/// `status` 用 `None` 表示不过滤；`limit` 必须显式给出（内部接口，不做缺省推断）。
pub fn MirrorDB::try_list_tasks(
  self : MirrorDB,
  status : TaskStatus?,
  limit : Int32,
) -> Result[Array[Envelope], String] {
  let sql = match status {
    Some(_) =>
      "SELECT * FROM tasks WHERE status = ? ORDER BY created_at DESC, task_id ASC LIMIT ?"
    None => "SELECT * FROM tasks ORDER BY created_at DESC, task_id ASC LIMIT ?"
  }
  let params = match status {
    Some(st) =>
      Json::array([
        Json::string(st.to_string()),
        Json::number(limit.to_double()),
      ])
    None => Json::array([Json::number(limit.to_double())])
  }
  let rows = match self.all(sql, params) {
    Ok(rows) => rows
    Err(msg) => return Err(msg)
  }
  let out : Array[Envelope] = []
  for row in rows {
    match mir_row_to_envelope(row) {
      Ok(env) => out.push(env)
      Err(msg) => return Err(msg)
    }
  }
  Ok(out)
}

///|
/// 更新任务状态（对照 vools `update_status` + 本批新增的乐观锁参数）。
///
/// 判据顺序（任一不满足即 Err，**不写库**）：
///   1. 任务存在（否则 `task not found: <id>`）；
///   2. `version` 与库内一致（否则 `stale_version:`）；
///   3. `old → new` 是合法流转（`TaskStatus::can_transition`，否则 `illegal_transition:`）。
///
/// 成功后 version+1、`updated_at` 重盖章、checksum 重算，并追加 `status_changed` 事件。
/// 返回新的 version。
pub fn MirrorDB::update_status(
  self : MirrorDB,
  task_id : String,
  new_status : TaskStatus,
  version : Int32,
  result? : Json,
  error? : String,
  signature? : String,
) -> Result[Int32, String] {
  match validate_task_id(task_id) {
    Err(msg) => return Err("update_status 拒绝非法 task_id：\{msg}")
    Ok(_) => ()
  }
  let body = fn() {
    let rows = match
      self.all(
        "SELECT * FROM tasks WHERE task_id = ?",
        Json::array([Json::string(task_id)]),
      ) {
      Ok(rows) => rows
      Err(msg) => return Err(msg)
    }
    if rows.length() == 0 {
      return Err("task not found: \{task_id}")
    }
    let row = rows[0]
    let local_version = mir_row_int(row, "version", 0)
    if local_version != version {
      return Err(
        StaleVersionError::new(task_id, local_version, version).to_string(),
      )
    }
    let old_env = match mir_row_to_envelope(row) {
      Ok(env) => env
      Err(msg) => return Err(msg)
    }
    if !old_env.status.can_transition(new_status) {
      return Err(
        "illegal_transition: \{old_env.status.to_string()} -> " +
        "\{new_status.to_string()} for task \{task_id}",
      )
    }
    let now = rhop_now_iso()
    let new_version = local_version + 1
    let new_result = match result {
      Some(value) => Some(value)
      None => old_env.result
    }
    let new_error = match error {
      Some(text) => Some(text)
      None => old_env.error
    }
    let new_signature = match signature {
      Some(text) => Some(text)
      None => old_env.signature
    }
    let next = Envelope::new_full(
      task_id,
      new_status,
      old_env.payload,
      old_env.side,
      result?=new_result,
      error?=new_error,
      version=new_version,
      created_at=old_env.created_at,
      updated_at=now,
      hops_seen=old_env.hops_seen.copy(),
      signature?=new_signature,
    )
    let changes = match
      self.run_changes(
        "UPDATE tasks SET status=?, version=?, updated_at=?, result=?, error=?, signature=?, checksum=?, envelope=? WHERE task_id=? AND version=?",
        Json::array([
          Json::string(new_status.to_string()),
          Json::number(new_version.to_double()),
          Json::string(now),
          mir_json_or_null_text(new_result),
          mir_opt_string(new_error),
          mir_opt_string(new_signature),
          Json::string(next.checksum),
          Json::string(utf8_text(next.to_rhop_bytes())),
          Json::string(task_id),
          Json::number(version.to_double()),
        ]),
      ) {
      Ok(pair) => pair.0
      Err(msg) => return Err(msg)
    }
    if changes != 1 {
      // 谓词零命中：事务内再读一次，区分「任务没了」与「版本被别人推进了」
      let latest = match
        self.all(
          "SELECT version FROM tasks WHERE task_id = ?",
          Json::array([Json::string(task_id)]),
        ) {
        Ok(rows) => rows
        Err(msg) => return Err(msg)
      }
      if latest.length() == 0 {
        return Err(
          "task not found: \{task_id}（更新谓词零命中，任务已被删除）",
        )
      }
      let now_version = mir_row_int(latest[0], "version", 0)
      return Err(
        StaleVersionError::new(task_id, now_version, version).to_string(),
      )
    }
    match
      self.append_event(
        task_id,
        "status_changed",
        Some(old_env.status.to_string()),
        Some(new_status.to_string()),
        None,
        now,
      ) {
      Ok(_) => ()
      Err(msg) => return Err(msg)
    }
    Ok(new_version)
  }
  self.write_tx(body)
}

///|
/// 领取指定任务（对照 vools `claim_task` 的语义，但按 **task_id 点名** 领取）。
///
/// 判据：任务须存在且处于 `Pending`（`Pending → Claimed` 合法流转），否则 Err。
/// 成功后 version+1、`claimed_by` 记名、事件 detail 写 `worker=<claimer>`。
pub fn MirrorDB::claim_task(
  self : MirrorDB,
  task_id : String,
  claimer : String,
) -> Result[Envelope, String] {
  match validate_task_id(task_id) {
    Err(msg) => return Err("claim_task 拒绝非法 task_id：\{msg}")
    Ok(_) => ()
  }
  // 双领防护：`WHERE task_id=? AND status='pending' AND version=?` + changes 校验，
  // 两个 worker 同时领同一任务时**只有一个** changes=1，另一个拿到可诊断 Err。
  let body = fn() {
    let rows = match
      self.all(
        "SELECT * FROM tasks WHERE task_id = ?",
        Json::array([Json::string(task_id)]),
      ) {
      Ok(rows) => rows
      Err(msg) => return Err(msg)
    }
    if rows.length() == 0 {
      return Err("task not found: \{task_id}")
    }
    let row = rows[0]
    let env = match mir_row_to_envelope(row) {
      Ok(env) => env
      Err(msg) => return Err(msg)
    }
    if !env.status.can_transition(TaskStatus::Claimed) {
      return Err(
        "claim_rejected: task \{task_id} 当前状态 \{env.status.to_string()} " +
        "不可领取（仅 Pending 可 Claimed）",
      )
    }
    let local_v = mir_row_int(row, "version", 0)
    let new_version = local_v + 1
    let now = rhop_now_iso()
    let next = Envelope::new_full(
      task_id,
      TaskStatus::Claimed,
      env.payload,
      env.side,
      result?=env.result,
      error?=env.error,
      version=new_version,
      created_at=env.created_at,
      updated_at=now,
      hops_seen=env.hops_seen.copy(),
      signature?=env.signature,
    )
    let changes = match
      self.run_changes(
        "UPDATE tasks SET status=?, version=?, updated_at=?, claimed_by=?, checksum=?, envelope=? WHERE task_id=? AND status=? AND version=?",
        Json::array([
          Json::string(TaskStatus::Claimed.to_string()),
          Json::number(new_version.to_double()),
          Json::string(now),
          Json::string(claimer),
          Json::string(next.checksum),
          Json::string(utf8_text(next.to_rhop_bytes())),
          Json::string(task_id),
          Json::string(TaskStatus::Pending.to_string()),
          Json::number(local_v.to_double()),
        ]),
      ) {
      Ok(pair) => pair.0
      Err(msg) => return Err(msg)
    }
    if changes != 1 {
      // 谓词零命中：事务内再读一次，给出「被谁先领走 / 状态已变」的可诊断原因
      let latest = match
        self.all(
          "SELECT status, version, claimed_by FROM tasks WHERE task_id = ?",
          Json::array([Json::string(task_id)]),
        ) {
        Ok(rows) => rows
        Err(msg) => return Err(msg)
      }
      if latest.length() == 0 {
        return Err(
          "task not found: \{task_id}（领取谓词零命中，任务已被删除）",
        )
      }
      let now_status = match mir_row_str(latest[0], "status") {
        Some(text) => text
        None => "?"
      }
      let now_version = mir_row_int(latest[0], "version", 0)
      let holder = match mir_row_str(latest[0], "claimed_by") {
        Some(text) => text
        None => ""
      }
      return Err(
        "claim_rejected: task \{task_id} 已被并发领取（库内 status=\{now_status} " +
        "version=\{now_version} claimed_by=\{holder}，本端期望 status=pending " +
        "version=\{local_v}）",
      )
    }
    match
      self.append_event(
        task_id,
        "status_changed",
        Some(TaskStatus::Pending.to_string()),
        Some(TaskStatus::Claimed.to_string()),
        Some("worker=" + claimer),
        now,
      ) {
      Ok(_) => ()
      Err(msg) => return Err(msg)
    }
    Ok(next)
  }
  self.write_tx(body)
}

///|
/// 领取**最早**的一个 Pending 任务（对照 vools `claim_task(worker_id)` 的「领一个」语义）。
///
/// 无 Pending 任务返回 `Ok(None)`（不报错——空队列是正常状态）。
pub fn MirrorDB::claim_next(
  self : MirrorDB,
  claimer : String,
) -> Result[Envelope?, String] {
  // 并发下「选中 → 领取」之间可能被别的 worker 抢走；被抢就换下一个，
  // 最多重试 5 次（不无限自旋，也不把正常的竞争写成错误）。
  let mut attempts = 0
  let mut last_error = ""
  while attempts < 5 {
    attempts = attempts + 1
    let rows = match
      self.all(
        "SELECT task_id FROM tasks WHERE status = ? ORDER BY created_at ASC, task_id ASC LIMIT 1",
        Json::array([Json::string(TaskStatus::Pending.to_string())]),
      ) {
      Ok(rows) => rows
      Err(msg) => return Err(msg)
    }
    if rows.length() == 0 {
      return Ok(None)
    }
    let id = match mir_row_str(rows[0], "task_id") {
      Some(text) => text
      None => return Err("镜像行缺少 task_id 列（schema 不匹配）")
    }
    match self.claim_task(id, claimer) {
      Ok(env) => return Ok(Some(env))
      Err(msg) =>
        if msg.has_prefix("claim_rejected:") {
          last_error = msg
        } else {
          return Err(msg)
        }
    }
  }
  Err("claim_next 连续 \{attempts} 次都被并发抢走（\{last_error}）")
}

///|
/// 按状态统计任务数（对照 vools `count_by_status`）。
///
/// 返回 JSON 对象 `{"pending": 2, "done": 1, ...}`，**只含出现过的状态**
/// （与 vools 一致；要「六个状态都列、缺的写 0」请用 `count_by_status_full`）。
pub fn MirrorDB::count_by_status(self : MirrorDB) -> Json {
  match self.try_count_by_status() {
    Ok(value) => value
    Err(_) => Json::object(Map([]))
  }
}

///|
/// 按状态统计（可诊断版本）。
pub fn MirrorDB::try_count_by_status(self : MirrorDB) -> Result[Json, String] {
  let rows = match
    self.all(
      "SELECT status, COUNT(*) AS n FROM tasks GROUP BY status",
      Json::array([]),
    ) {
    Ok(rows) => rows
    Err(msg) => return Err(msg)
  }
  let fields : Map[String, Json] = Map([])
  for row in rows {
    let status = match mir_row_str(row, "status") {
      Some(text) => text
      None => continue
    }
    fields[status] = Json::number(mir_row_int(row, "n", 0).to_double())
  }
  Ok(Json::object(fields))
}

///|
/// 六个状态全列版计数（缺的写 0），便于看板与断言。
pub fn MirrorDB::count_by_status_full(self : MirrorDB) -> Json {
  let base = match self.try_count_by_status() {
    Ok(value) => value
    Err(_) => Json::object(Map([]))
  }
  let fields : Map[String, Json] = Map([])
  for st in TaskStatus::all() {
    let key = st.to_string()
    let value = match base {
      Object(members) =>
        match members.get(key) {
          Some(v) => v
          None => Json::number(0.0)
        }
      _ => Json::number(0.0)
    }
    fields[key] = value
  }
  Json::object(fields)
}

///|
/// 记录一条同步日志（对照 vools `log_sync`）。
pub fn MirrorDB::log_sync(
  self : MirrorDB,
  direction : String,
  transport : String,
  task_id : String,
  success : Bool,
  error? : String,
  bytes_xfer? : Int32,
) -> Result[Unit, String] {
  let bytes = match bytes_xfer {
    Some(n) => n
    None => 0
  }
  self.run(
    "INSERT INTO sync_log (direction, transport, task_id, success, error, bytes_xfer, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
    Json::array([
      Json::string(direction),
      Json::string(transport),
      Json::string(task_id),
      Json::number(if success { 1.0 } else { 0.0 }),
      mir_opt_string(error),
      Json::number(bytes.to_double()),
      Json::string(rhop_now_iso()),
    ]),
  )
}

///|
/// 低层逃生口：直接对镜像库执行一条写 SQL（**仅供诊断 / 迁移脚本 / 造坏库测试**）。
///
/// 走的仍是内部 `run`（含「已关闭」检查与可诊断 Err），但不做任何业务校验，
/// 调用方自负 SQL 正确性。
pub fn MirrorDB::raw_run(
  self : MirrorDB,
  sql : String,
  params : Json,
) -> Result[Unit, String] {
  self.run(sql, params)
}

///|
/// 列出待同步事件（对照 vools `pending_sync`；`since` 为 ISO 时间戳下界，**不含等于**）。
///
/// 返回事件行对象数组（`id/task_id/event_type/old_status/new_status/detail/created_at`）。
pub fn MirrorDB::pending_sync(self : MirrorDB, since? : String) -> Array[Json] {
  let since_ts = match since {
    Some(ts) => ts
    None => ""
  }
  let rows = if since_ts == "" {
    self.all("SELECT * FROM events ORDER BY id ASC", Json::array([]))
  } else {
    self.all(
      "SELECT * FROM events WHERE created_at > ? ORDER BY id ASC",
      Json::array([Json::string(since_ts)]),
    )
  }
  match rows {
    Ok(rows) => rows
    Err(_) => []
  }
}

///|
/// 待同步事件条数（`pending_sync()` 的长度，无需拉全量行）。
pub fn MirrorDB::pending_count(self : MirrorDB) -> Int32 {
  match self.all("SELECT COUNT(*) AS n FROM events", Json::array([])) {
    Ok(rows) =>
      if rows.length() == 0 {
        0
      } else {
        mir_row_int(rows[0], "n", 0)
      }
    Err(_) => 0
  }
}

///|
/// 同步日志条数（审计用；同步失败的可见性）。
pub fn MirrorDB::sync_log_count(self : MirrorDB) -> Int32 {
  let rows = match
    self.all("SELECT COUNT(*) AS n FROM sync_log", Json::array([])) {
    Ok(rows) => rows
    Err(_) => return 0
  }
  if rows.length() == 0 {
    return 0
  }
  mir_row_int(rows[0], "n", 0)
}

///|
/// 关闭镜像库（幂等；重复 close 不报错）。
pub fn MirrorDB::close(self : MirrorDB) -> Unit {
  if self.closed {
    return
  }
  rhop_db_close(self.handle)
  self.closed = true
  // 临时库：连成功关闭后递归删除自己的目录（Windows 上句柄未释放会 EPERM，
  // 因此失败时保留进程退出兜底清理，不报错——close 语义保持不限错）。
  if self.temp_root != "" {
    ignore(rhop_remove_dir_all(self.temp_root))
    self.temp_root = ""
  }
}

///|
/// 内部：追加一条事件流水（失败上抛，由调用方决定是否致命）。
fn MirrorDB::append_event(
  self : MirrorDB,
  task_id : String,
  event_type : String,
  old_status : String?,
  new_status : String?,
  detail : String?,
  created_at : String,
) -> Result[Unit, String] {
  self.run(
    "INSERT INTO events (task_id, event_type, old_status, new_status, detail, created_at) VALUES (?, ?, ?, ?, ?, ?)",
    Json::array([
      Json::string(task_id),
      Json::string(event_type),
      mir_opt_string(old_status),
      mir_opt_string(new_status),
      mir_opt_string(detail),
      Json::string(created_at),
    ]),
  )
}

// ---------------------------------------------------------------------------
// MirrorDB 私有 JSON 取值/转换 helper
// ---------------------------------------------------------------------------

///|
/// 行对象取字符串字段（缺失/类型不符返回 None）。
fn mir_row_str(row : Json, key : String) -> String? {
  match row {
    Object(members) =>
      match members.get(key) {
        Some(String(text)) => Some(text)
        _ => None
      }
    _ => None
  }
}

///|
/// 行对象取整数字段（缺失/非法回退 `fallback`）。
fn mir_row_int(row : Json, key : String, fallback : Int32) -> Int32 {
  let value = match row {
    Object(members) => members.get(key)
    _ => None
  }
  match value {
    Some(Number(n, ..)) => n.to_int()
    Some(String(text)) => {
      let parsed = @json.parse(text) catch { _ => return fallback }
      match parsed {
        Number(n, ..) => n.to_int()
        _ => fallback
      }
    }
    _ => fallback
  }
}

///|
/// 行对象 → Envelope：走 `envelope` 序列化列 + `from_rhop_bytes`（含 checksum 校验）。
///
/// 缺列（老库/坏库）返回可诊断 Err，而不是伪造一个空信封。
fn mir_row_to_envelope(row : Json) -> Result[Envelope, String] {
  let text = match mir_row_str(row, "envelope") {
    Some(t) => t
    None =>
      return Err(
        "镜像行缺少 envelope 序列化列（schema 不匹配或行已损坏）",
      )
  }
  if text == "" {
    return Err("镜像行 envelope 列为空（行已损坏）")
  }
  Envelope::from_rhop_bytes(bytes_of_utf8(text))
}

///|
/// `Json?` → 可入 SQL 的参数：`Some(v)` 的内联 JSON 文本，`None` → SQL NULL。
fn mir_json_or_null_text(value : Json?) -> Json {
  match value {
    Some(v) => Json::string(canonical_json(v))
    None => Json::null()
  }
}

///|
/// `String?` → 可入 SQL 的参数（`None` → SQL NULL）。
fn mir_opt_string(value : String?) -> Json {
  match value {
    Some(text) => Json::string(text)
    None => Json::null()
  }
}

// ---------------------------------------------------------------------------
// 低层 FFI · node:sqlite（js 目标）
//
// 句柄不打进 MoonBit 侧（JS 对象无法跨 FFI 传递），统一登记在
// `globalThis.__rhop_db`（id → DatabaseSync 实例），MoonBit 侧只持 Int32 id。
// 失败原因写入 `globalThis.__rhop_db_err` / `__rhop_fs_err`，由 FFI 读回。
// ---------------------------------------------------------------------------

///|
/// js：建/开库，返回句柄 id；失败 -1（原因见 `__rhop_db_err`）。
#cfg(target="js")
extern "js" fn rhop_ffi_db_open(path : String) -> Int32 =
  #| (path) => { const G = globalThis; try { if (G.__rhop_db === undefined) { G.__rhop_db = new Map(); G.__rhop_db_seq = 1; } const sqlite = process.getBuiltinModule("node:sqlite"); const db = new sqlite.DatabaseSync(String(path)); const id = G.__rhop_db_seq++; G.__rhop_db.set(id, db); G.__rhop_db_err = ""; return id; } catch (e) { if (G.__rhop_db === undefined) { G.__rhop_db = new Map(); G.__rhop_db_seq = 1; } G.__rhop_db_err = String((e && e.message) || e); return -1; } }

///|
/// js：关库（未知 id 静默忽略）。
#cfg(target="js")
extern "js" fn rhop_ffi_db_close(id : Int32) -> Unit =
  #| (id) => { const G = globalThis; if (G.__rhop_db === undefined) { return; } const db = G.__rhop_db.get(Number(id)); if (db === undefined) { return; } if (G.__rhop_stmt !== undefined) { const pre = Number(id) + "|"; for (const k of Array.from(G.__rhop_stmt.keys())) { if (String(k).indexOf(pre) === 0) { G.__rhop_stmt.delete(k); } } } try { db.close(); G.__rhop_db_err = ""; G.__rhop_db.delete(Number(id)); } catch (e) { G.__rhop_db_err = String((e && e.message) || e); } }

///|
/// js：执行一条非查询 SQL（params 为 JSON 数组文本）；成功 true。
#cfg(target="js")
extern "js" fn rhop_ffi_db_run(
  id : Int32,
  sql : String,
  params_json : String,
) -> String =
  #| (id, sql, paramsJson) => { const G = globalThis; const stmtOf = (db, id, sql) => { const key = Number(id) + "|" + String(sql); if (G.__rhop_stmt === undefined) { G.__rhop_stmt = new Map(); G.__rhop_stmt_prepared = 0; } let st = G.__rhop_stmt.get(key); if (st === undefined) { st = db.prepare(String(sql)); G.__rhop_stmt_prepared = (G.__rhop_stmt_prepared || 0) + 1; if (G.__rhop_stmt.size >= 64) { const w = G.__rhop_stmt.keys().next().value; G.__rhop_stmt.delete(w); } G.__rhop_stmt.set(key, st); } return st; }; const busy = (msg) => { const m = String(msg || ""); return (m.indexOf("database is locked") >= 0 || m.indexOf("SQLITE_BUSY") >= 0) ? ("DB_BUSY: busy_timeout(5000ms) exceeded, please retry: " + m) : m; }; try { const db = (G.__rhop_db || new Map()).get(Number(id)); if (db === undefined) { G.__rhop_db_err = "invalid db handle (closed?)"; return ""; } const params = JSON.parse(String(paramsJson)); const info = stmtOf(db, id, String(sql)).run(...params); const changes = (info && info.changes !== undefined) ? Number(info.changes) : 0; const lastId = (info && info.lastInsertRowid !== undefined) ? Number(info.lastInsertRowid) : 0; G.__rhop_db_err = ""; return JSON.stringify({ changes: changes, lastInsertRowid: lastId }); } catch (e) { G.__rhop_db_err = busy((e && e.message) || e); return ""; } }

///|
/// js：执行一条**不带参数**的 SQL（事务控制语句 `BEGIN IMMEDIATE`/`COMMIT`/
/// `ROLLBACK` 与多语句 DDL）；成功 true，失败把原因写进 `__rhop_db_err`。
#cfg(target="js")
extern "js" fn rhop_ffi_db_exec(id : Int32, sql : String) -> Bool =
  #| (id, sql) => { const G = globalThis; try { const db = (G.__rhop_db || new Map()).get(Number(id)); if (db === undefined) { G.__rhop_db_err = "数据库句柄无效（可能已 close）"; return false; } db.exec(String(sql)); G.__rhop_db_err = ""; return true; } catch (e) { G.__rhop_db_err = String((e && e.message) || e); return false; } }

///|
/// js：查询并返回行对象 JSON 数组文本；失败返回 ""。
#cfg(target="js")
extern "js" fn rhop_ffi_db_all(
  id : Int32,
  sql : String,
  params_json : String,
) -> String =
  #| (id, sql, paramsJson) => { const G = globalThis; const stmtOf = (db, id, sql) => { const key = Number(id) + "|" + String(sql); if (G.__rhop_stmt === undefined) { G.__rhop_stmt = new Map(); G.__rhop_stmt_prepared = 0; } let st = G.__rhop_stmt.get(key); if (st === undefined) { st = db.prepare(String(sql)); G.__rhop_stmt_prepared = (G.__rhop_stmt_prepared || 0) + 1; if (G.__rhop_stmt.size >= 64) { const w = G.__rhop_stmt.keys().next().value; G.__rhop_stmt.delete(w); } G.__rhop_stmt.set(key, st); } return st; }; const busy = (msg) => { const m = String(msg || ""); return (m.indexOf("database is locked") >= 0 || m.indexOf("SQLITE_BUSY") >= 0) ? ("DB_BUSY: busy_timeout(5000ms) exceeded, please retry: " + m) : m; }; try { const db = (G.__rhop_db || new Map()).get(Number(id)); if (db === undefined) { G.__rhop_db_err = "invalid db handle (closed?)"; return ""; } const rows = stmtOf(db, id, String(sql)).all(...JSON.parse(String(paramsJson))); G.__rhop_db_err = ""; return JSON.stringify(rows.map((r) => { const o = {}; for (const k of Object.keys(r)) { o[k] = r[k]; } return o; })); } catch (e) { G.__rhop_db_err = busy((e && e.message) || e); return ""; } }

///|
/// js：取最近一次 sqlite 失败原因（空串表示成功）。
#cfg(target="js")
extern "js" fn rhop_ffi_db_error() -> String =
  #| () => { const G = globalThis; return (G.__rhop_db_err === undefined) ? "" : String(G.__rhop_db_err); }

///|
/// 非 js：无句柄（sqlite FFI 只编进 js 目标）。
#cfg(not(target="js"))
fn rhop_ffi_db_error() -> String {
  "MirrorDB 仅 js 目标可用（node:sqlite）"
}

// ---------------------------------------------------------------------------
// 低层 FFI · node:fs（js 目标）
// ---------------------------------------------------------------------------

///|
/// js：递归建目录；成功 true。
#cfg(target="js")
extern "js" fn rhop_ffi_mkdir_p(dir : String) -> Bool =
  #| (dir) => { const G = globalThis; try { const fs = process.getBuiltinModule("node:fs"); fs.mkdirSync(String(dir), { recursive: true }); G.__rhop_fs_err = ""; return true; } catch (e) { G.__rhop_fs_err = String((e && e.message) || e); return false; } }

///|
/// js：建**文件**的父目录（空父目录/根目录静默跳过）；成功 true。
#cfg(target="js")
extern "js" fn rhop_ffi_mkdir_p_parent(path : String) -> Bool =
  #| (path) => { const G = globalThis; try { const fs = process.getBuiltinModule("node:fs"); const pathMod = process.getBuiltinModule("node:path"); const parent = pathMod.dirname(String(path)); if (parent && parent !== "." && parent !== "/") { fs.mkdirSync(parent, { recursive: true }); } G.__rhop_fs_err = ""; return true; } catch (e) { G.__rhop_fs_err = String((e && e.message) || e); return false; } }

///|
/// js：原子写文本（tmp + rename）；成功 true。
#cfg(target="js")
extern "js" fn rhop_ffi_write_atomic(path : String, text : String) -> Bool =
  #| (path, text) => { const G = globalThis; const fs = process.getBuiltinModule("node:fs"); const p = String(path); const tmp = p + ".tmp"; try { fs.writeFileSync(tmp, String(text), "utf8"); fs.renameSync(tmp, p); G.__rhop_fs_err = ""; return true; } catch (e) { try { fs.unlinkSync(tmp); } catch (_e) {} G.__rhop_fs_err = String((e && e.message) || e); return false; } }

///|
/// js：读 utf8 文本（成功与否由 `rhop_ffi_fs_ok` 给出，空文件也是成功）。
#cfg(target="js")
extern "js" fn rhop_ffi_read_text(path : String) -> String =
  #| (path) => { const G = globalThis; try { const fs = process.getBuiltinModule("node:fs"); const t = fs.readFileSync(String(path), "utf8"); G.__rhop_fs_ok = true; G.__rhop_fs_err = ""; return t; } catch (e) { G.__rhop_fs_ok = false; G.__rhop_fs_err = String((e && e.message) || e); return ""; } }

///|
/// js：最近一次读文本是否成功（区分「空文件」与「读失败」）。
#cfg(target="js")
extern "js" fn rhop_ffi_fs_ok() -> Bool =
  #| () => { const G = globalThis; return G.__rhop_fs_ok === true; }

///|
/// 非 js：恒 false（非 js 读文件一律走可诊断 Err）。
#cfg(not(target="js"))
fn rhop_ffi_fs_ok() -> Bool {
  false
}

///|
/// js：路径是否存在。
#cfg(target="js")
extern "js" fn rhop_ffi_exists(path : String) -> Bool =
  #| (path) => { try { const fs = process.getBuiltinModule("node:fs"); return fs.existsSync(String(path)); } catch (e) { return false; } }

///|
/// 非 js：恒 false。
#cfg(not(target="js"))
fn rhop_ffi_exists(path : String) -> Bool {
  let _ = path
  false
}

///|
/// js：列目录下普通文件名 JSON 数组文本（非递归，按字典序）；失败返回 ""。
#cfg(target="js")
extern "js" fn rhop_ffi_list_dir(dir : String) -> String =
  #| (dir) => { const G = globalThis; try { const fs = process.getBuiltinModule("node:fs"); const out = []; for (const ent of fs.readdirSync(String(dir), { withFileTypes: true })) { if (ent.isSymbolicLink()) { continue; } if (ent.isFile()) { out.push(ent.name); } } out.sort(); G.__rhop_fs_err = ""; return JSON.stringify(out); } catch (e) { G.__rhop_fs_err = String((e && e.message) || e); return ""; } }

///|
/// 非 js：无文件系统，返回 ""（调用方据此得到空列表 + 可诊断 Err 路径）。
#cfg(not(target="js"))
fn rhop_ffi_list_dir(dir : String) -> String {
  let _ = dir
  ""
}

///|
/// js：移动文件（rename 失败则 copy+unlink，兼容跨盘）；成功 true。
#cfg(target="js")
extern "js" fn rhop_ffi_move(src : String, dst : String) -> Bool =
  #| (src, dst) => { const G = globalThis; try { const fs = process.getBuiltinModule("node:fs"); try { fs.renameSync(String(src), String(dst)); } catch (e) { fs.copyFileSync(String(src), String(dst)); fs.unlinkSync(String(src)); } G.__rhop_fs_err = ""; return true; } catch (e) { G.__rhop_fs_err = String((e && e.message) || e); return false; } }

///|
/// js：删除文件（不存在视为成功）；成功 true。
#cfg(target="js")
extern "js" fn rhop_ffi_remove(path : String) -> Bool =
  #| (path) => { const G = globalThis; try { const fs = process.getBuiltinModule("node:fs"); try { fs.unlinkSync(String(path)); } catch (e) { if (e && e.code !== "ENOENT") { throw e; } } G.__rhop_fs_err = ""; return true; } catch (e) { G.__rhop_fs_err = String((e && e.message) || e); return false; } }

///|
/// js：取最近一次 fs 失败原因（空串表示成功）。
#cfg(target="js")
extern "js" fn rhop_ffi_fs_error() -> String =
  #| () => { const G = globalThis; return (G.__rhop_fs_err === undefined) ? "" : String(G.__rhop_fs_err); }

///|
/// 非 js：无文件系统。
#cfg(not(target="js"))
fn rhop_ffi_fs_error() -> String {
  "文件系统操作仅 js 目标可用（wasm/native 无 node:fs）"
}

///|
/// js：取文件 sha256 + size（JSON 文本）；失败返回 ""。
#cfg(target="js")
extern "js" fn rhop_ffi_file_digest(path : String) -> String =
  #| (path) => { const G = globalThis; let fd = -1; try { const fs = process.getBuiltinModule("node:fs"); const crypto = process.getBuiltinModule("node:crypto"); const h = crypto.createHash("sha256"); const CH = 1 << 20; const buf = Buffer.allocUnsafe(CH); let size = 0; fd = fs.openSync(String(path), "r"); let n = 0; while ((n = fs.readSync(fd, buf, 0, CH, null)) > 0) { h.update(buf.subarray(0, n)); size += n; } fs.closeSync(fd); fd = -1; G.__rhop_fs_err = ""; return JSON.stringify({ sha256: h.digest("hex"), size: size }); } catch (e) { if (fd >= 0) { try { process.getBuiltinModule("node:fs").closeSync(fd); } catch (_e) {} } G.__rhop_fs_err = String((e && e.message) || e); return ""; } }

///|
/// js：复制文件；成功 true。
#cfg(target="js")
extern "js" fn rhop_ffi_copy(src : String, dst : String) -> Bool =
  #| (src, dst) => { const G = globalThis; try { const fs = process.getBuiltinModule("node:fs"); fs.copyFileSync(String(src), String(dst)); G.__rhop_fs_err = ""; return true; } catch (e) { G.__rhop_fs_err = String((e && e.message) || e); return false; } }

///|
/// js：递归列出普通文件相对路径（`/` 分隔）JSON 数组文本；失败返回 ""。
#cfg(target="js")
extern "js" fn rhop_ffi_list_files_recursive(dir : String) -> String =
  #| (dir) => { const G = globalThis; try { const fs = process.getBuiltinModule("node:fs"); const pathMod = process.getBuiltinModule("node:path"); const root = String(dir); const out = []; const walk = (cur, rel, depth) => { if (depth > 64) { return; } for (const ent of fs.readdirSync(cur, { withFileTypes: true })) { const abs = pathMod.join(cur, ent.name); const r = rel === "" ? ent.name : rel + "/" + ent.name; if (ent.isSymbolicLink()) { continue; } if (ent.isDirectory()) { walk(abs, r, depth + 1); } else if (ent.isFile()) { out.push(r); } } }; walk(root, "", 0); out.sort(); G.__rhop_fs_err = ""; return JSON.stringify(out); } catch (e) { G.__rhop_fs_err = String((e && e.message) || e); return ""; } }

///|
/// 非 js：无文件系统，返回 ""（调用方得到空列表）。
#cfg(not(target="js"))
fn rhop_ffi_list_files_recursive(dir : String) -> String {
  let _ = dir
  ""
}

///|
/// js：`<os.tmpdir()>/rhop-data`（稳定路径，供默认 data_dir 用）；失败返回 ""。
#cfg(target="js")
extern "js" fn rhop_ffi_temp_data_dir() -> String =
  #| () => { try { const os = process.getBuiltinModule("node:os"); const pathMod = process.getBuiltinModule("node:path"); return pathMod.join(os.tmpdir(), "rhop-data"); } catch (e) { return ""; } }

///|
/// 非 js：无临时目录能力，返回 ""。
#cfg(not(target="js"))
fn rhop_ffi_temp_data_dir() -> String {
  ""
}

///|
/// 在系统临时目录下创建一个**唯一**目录并返回其绝对路径。
///
/// 该目录会登记到进程退出钩子：即使调用方忘记删除，进程结束时也递归清理
/// （避免 `rhop-mirror-*` 目录在 `%TEMP%` 里无界堆积）。
pub fn rhop_temp_workspace(prefix : String) -> Result[String, String] {
  let p = if prefix == "" { "rhop-" } else { prefix }
  let dir = rhop_ffi_temp_dir(p)
  if dir == "" {
    return Err("无法创建临时目录：\{rhop_ffi_fs_error()}")
  }
  Ok(dir)
}

///|
/// 递归删除目录（不存在视为成功）。js：`fs.rmSync(recursive,force,maxRetries)`。
pub fn rhop_remove_dir_all(dir : String) -> Result[Unit, String] {
  if dir == "" {
    return Ok(())
  }
  if rhop_ffi_rm_rf(dir) {
    Ok(())
  } else {
    Err("rhop_remove_dir_all 失败：\{rhop_ffi_fs_error()}（\{dir}）")
  }
}

///|
/// js：`fs.mkdtempSync(tmpdir()/prefix)`，并把目录登记到退出钩子。
#cfg(target="js")
extern "js" fn rhop_ffi_temp_dir(prefix : String) -> String =
  #| (prefix) => { const G = globalThis; try { const fs = process.getBuiltinModule("node:fs"); const os = process.getBuiltinModule("node:os"); const pathMod = process.getBuiltinModule("node:path"); const dir = fs.mkdtempSync(pathMod.join(os.tmpdir(), prefix || "rhop-")); if (!G.__rhop_tmp_dirs) { G.__rhop_tmp_dirs = []; if (typeof process.on === "function") { process.on("exit", () => { if (G.__rhop_db !== undefined) { for (const db of G.__rhop_db.values()) { try { db.close(); } catch (e) {} } G.__rhop_db.clear(); } if (G.__rhop_stmt !== undefined) { G.__rhop_stmt.clear(); } for (const d of G.__rhop_tmp_dirs) { for (let a = 0; a < 3; a++) { try { fs.rmSync(d, { recursive: true, force: true, maxRetries: 5, retryDelay: 20 }); break; } catch (e) {} } } }); } } G.__rhop_tmp_dirs.push(dir); G.__rhop_fs_err = ""; return dir; } catch (e) { G.__rhop_fs_err = String((e && e.message) || e); return ""; } }

///|
/// js：递归强删目录（带重试，容忍 Windows 句柄尚未释放）。
#cfg(target="js")
extern "js" fn rhop_ffi_rm_rf(dir : String) -> Bool =
  #| (dir) => { const G = globalThis; try { const fs = process.getBuiltinModule("node:fs"); fs.rmSync(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 }); G.__rhop_fs_err = ""; return true; } catch (e) { G.__rhop_fs_err = String((e && e.message) || e); return false; } }

///|
/// 非 js：无临时目录能力，返回 ""（`rhop_temp_workspace` 据此返回可诊断 Err）。
#cfg(not(target="js"))
fn rhop_ffi_temp_dir(prefix : String) -> String {
  let _ = prefix
  ""
}

///|
/// 非 js：无文件系统。
#cfg(not(target="js"))
fn rhop_ffi_rm_rf(dir : String) -> Bool {
  let _ = dir
  false
}
