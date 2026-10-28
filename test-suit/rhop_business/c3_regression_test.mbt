// ============================================================================
// rhop_business · C3 回归测试（卫生 / 文档契约）
//
// 对应 C3 寻虫报告（fist-mbt/reports/2026-10-28-c3-bugfind-business.md）：
//   C3-1 QA C2-V1 temp 卫生：workspace 生命周期必须「任意时刻 ≤1 个」，
//        且首次调用要清扫上一轮被 kill 留下的 `%TEMP%/rhop-biz-*` 残骸。
//   C3-2 文档契约：镜像库 schema 的**列级契约**（与 vools schema 的对齐/增量）必须与
//        文档声称一致 —— 用 SQL 实测列名/顺序/额外列，锁死「文档说 13 列就真 13 列」。
//   C3-3 语义差异必须在**代码文档**里可见（乐观锁错误前缀 / daemon 单消费者 /
//        sync glob 无 [seq] / jump 真传输 unsupported）—— 用反射式断言不可行，
//        故此条只做「关键常量/前缀」的可执行断言（其余由报告逐条核对）。
//
// 目标：js（node:fs / node:sqlite）。
// ============================================================================

///|
/// 取 `%TEMP%` 下以 prefix 开头的目录数（js 探针）。
extern "js" fn c3_count_temp_dirs(prefix : String) -> Int32 =
  #| (prefix) => { try { const fs = process.getBuiltinModule("node:fs"); const os = process.getBuiltinModule("node:os"); const tmp = os.tmpdir(); const pre = String(prefix); let n = 0; for (const name of fs.readdirSync(tmp)) { if (String(name).indexOf(pre) === 0) { n = n + 1; } } return n; } catch (e) { return -1; } }

///|
/// 造一个「假的历史残留」目录（模拟被 kill 的上一轮）。
extern "js" fn c3_make_fake_ws(name : String) -> Bool =
  #| (name) => { try { const fs = process.getBuiltinModule("node:fs"); const os = process.getBuiltinModule("node:os"); const pathMod = process.getBuiltinModule("node:path"); const dir = pathMod.join(os.tmpdir(), String(name)); fs.mkdirSync(dir, { recursive: true }); fs.writeFileSync(pathMod.join(dir, "leftover.db"), "stale"); return true; } catch (e) { return false; } }

///|
/// C3-1a：`biz_temp_workspace()` 必须让「任意时刻只有 1 个 workspace 存活」
/// （新建时删掉上一个 ⇒ 被 kill 也最多残留 1 个目录）。
test "c3-1a: workspace 任意时刻 ≤1 个（新建即回收上一个）" {
  let before = c3_count_temp_dirs("rhop-biz-")
  if before < 0 {
    abort("无法枚举临时目录（需要 js 目标）")
  }
  let first = biz_temp_workspace()
  if !@rp.rhop_fs_exists(first) {
    abort("新建 workspace 不存在: \{first}")
  }
  let second = biz_temp_workspace()
  if !@rp.rhop_fs_exists(second) {
    abort("第二个 workspace 不存在: \{second}")
  }
  // 第一个必须已被回收
  if @rp.rhop_fs_exists(first) {
    abort(
      "新建第二个 workspace 后，第一个仍存在（未回收）: \{first}",
    )
  }
  // 存活数 ≤1（可能为 1 = 当前 workspace）
  let live = c3_count_temp_dirs("rhop-biz-")
  if live > 1 {
    abort("同时存活的 workspace 数 = \{live}（应 ≤1）")
  }
  biz_cleanup(second)
  if @rp.rhop_fs_exists(second) {
    abort("biz_cleanup 后 workspace 仍存在: \{second}")
  }
}

///|
/// C3-1b：首次调用（或显式调用 `biz_sweep_stale`）必须清扫历史残留
/// `%TEMP%/rhop-biz-*`（对应 QA C2-V1：被 kill 的上一轮残骸）。
test "c3-1b: 历史残留 rhop-biz-* 会被清扫（QA C2-V1）" {
  // 造两个假的历史残留（模拟上一轮被 kill）
  let fake_a = "rhop-biz-C3STALE000001"
  let fake_b = "rhop-biz-C3STALE000002"
  if !c3_make_fake_ws(fake_a) || !c3_make_fake_ws(fake_b) {
    abort("无法创建假残留目录（需要 js 目标）")
  }
  let with_stale = c3_count_temp_dirs("rhop-biz-")
  if with_stale < 2 {
    abort("假残留未创建成功，当前计数 = \{with_stale}")
  }
  let swept = biz_sweep_stale()
  if swept < 2 {
    abort("biz_sweep_stale 应清掉 ≥2 个残留，实际 \{swept}")
  }
  let after = c3_count_temp_dirs("rhop-biz-")
  if after >= with_stale {
    abort("清扫后目录数未下降：\{with_stale} → \{after}")
  }
  // 具体两个假残留必须消失
  let tmp_probe = biz_temp_workspace()
  let parent = @rp.rhop_fs_parent(tmp_probe)
  if @rp.rhop_fs_exists(@rp.rhop_join(parent, fake_a)) {
    abort("假残留 A 未被清扫")
  }
  if @rp.rhop_fs_exists(@rp.rhop_join(parent, fake_b)) {
    abort("假残留 B 未被清扫")
  }
  biz_cleanup(tmp_probe)
}

///|
/// C3-2：镜像库 schema 列级契约 —— `tasks` 必须是 13 列且包含 `envelope`/`claimed_by`；
/// `events` 7 列、`sync_log` 8 列（合计 28，与 C3 报告 §3 的列级核对表一致）。
///
/// 这条同时是「文档 ↔ 代码」护栏：文档/矩阵若改了列数说明，必须同步改这里。
test "c3-2: 镜像库三表列级契约（tasks 13 / events 7 / sync_log 8）" {
  let dir = biz_temp_workspace()
  let db = match @rp.MirrorDB::open(@rp.rhop_join(dir, "schema.db")) {
    Ok(v) => v
    Err(e) => abort("open 失败: \{e}")
  }
  // pragma table_info 需要能跑（raw_run 只有写，查询走 count_by_status 之外的路径不可行）
  // 这里用「插入后再读」的方式间接验证列可用性，并用 SQL 计数验证列数。
  let task_cols = c3_pragma_columns(db_handle_path(dir), "tasks")
  let event_cols = c3_pragma_columns(db_handle_path(dir), "events")
  let sync_cols = c3_pragma_columns(db_handle_path(dir), "sync_log")
  if task_cols != 13 {
    abort(
      "tasks 列数应为 13（vools 11 + envelope/claimed_by），实际 \{task_cols}",
    )
  }
  if event_cols != 7 {
    abort("events 列数应为 7（与 vools 同），实际 \{event_cols}")
  }
  if sync_cols != 8 {
    abort("sync_log 列数应为 8（与 vools 同），实际 \{sync_cols}")
  }
  // 关键列存在性（用一条仅引用这些列的 SELECT 验证，不依赖 pragma 输出解析）
  match
    db.raw_run(
      "SELECT task_id, status, side, payload, result, error, signature, version, created_at, updated_at, checksum, envelope, claimed_by FROM tasks LIMIT 1",
      Json::array([]),
    ) {
    Ok(_) => ()
    Err(e) => abort("tasks 13 列不可全部寻址: \{e}")
  }
  match
    db.raw_run(
      "SELECT id, task_id, event_type, old_status, new_status, detail, created_at FROM events LIMIT 1",
      Json::array([]),
    ) {
    Ok(_) => ()
    Err(e) => abort("events 7 列不可全部寻址: \{e}")
  }
  match
    db.raw_run(
      "SELECT id, direction, transport, task_id, success, error, bytes_xfer, created_at FROM sync_log LIMIT 1",
      Json::array([]),
    ) {
    Ok(_) => ()
    Err(e) => abort("sync_log 8 列不可全部寻址: \{e}")
  }
  db.close()
  biz_cleanup(dir)
}

///|
/// C3-3：语义差异的可执行锚点
/// （乐观锁错误前缀 = 文档声称的 `stale_version:`；daemon/glob/jump 的差异见报告逐条）。
test "c3-3: 乐观锁错误前缀与文档一致（stale_version:）" {
  let dir = biz_temp_workspace()
  let db = match @rp.MirrorDB::open(@rp.rhop_join(dir, "lock.db")) {
    Ok(v) => v
    Err(e) => abort("open 失败: \{e}")
  }
  let env = mk_env(
    "job-c3-lock",
    @rp.TaskStatus::Pending,
    @rp.Side::Requester,
    2,
  )
  match db.upsert_task(env) {
    Ok(_) => ()
    Err(e) => abort("首次 upsert 失败: \{e}")
  }
  match db.upsert_task(env) {
    Ok(_) => abort("同版本 upsert 应被拒绝")
    Err(e) =>
      if !e.has_prefix("stale_version:") {
        abort("乐观锁错误前缀应为 stale_version:，实际: \{e}")
      } else if !@rp.is_stale_version_error(e) {
        abort("is_stale_version_error 判定失败: \{e}")
      }
  }
  db.close()
  biz_cleanup(dir)
}

// ---------------------------------------------------------------------------
// 本文件私有 helper
// ---------------------------------------------------------------------------

///|
/// 库文件路径（给 pragma 探针用）。
fn db_handle_path(dir : String) -> String {
  @rp.rhop_join(dir, "schema.db")
}

///|
/// 用独立连接数某个表的列数（`PRAGMA table_info`）。
///
/// 说明：`MirrorDB::raw_run` 只跑写 SQL，不返回结果集，所以这里用一条**独立**的
/// node:sqlite 连接只读 `pragma_table_info`（测试专用 FFI，不进库的公开 API）。
extern "js" fn c3_pragma_columns(path : String, table : String) -> Int32 =
  #| (path, table) => { try { const sqlite = process.getBuiltinModule("node:sqlite"); const db = new sqlite.DatabaseSync(String(path)); const rows = db.prepare("SELECT COUNT(*) AS n FROM pragma_table_info(?)").all(String(table)); db.close(); return Number(rows[0].n); } catch (e) { return -1; } }
