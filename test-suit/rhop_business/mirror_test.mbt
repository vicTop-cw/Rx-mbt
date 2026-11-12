// ============================================================================
// rhop_business · MirrorDB（node:sqlite 真实建库）测试
//
// 覆盖：建库/持久化（重开库）/CRUD/乐观锁（StaleVersionError）/合法与非法流转/
//       领取（重复领取拒绝）/状态计数/同步日志/事件流水/坏库与已关闭句柄的可诊断报错。
// 目标：js（node:sqlite 仅 js 可用；非 js 的「可诊断 Err」由 mirror_nonjs_test.mbt 覆盖）。
// ============================================================================

///|
test "mirror: 建库 → upsert → get_task 往返（含 checksum 校验）" {
  let db = match @rp.MirrorDB::open_temp() {
    Ok(db) => db
    Err(e) => abort("open_temp 失败: \{e}")
  }
  let env = mk_env("job-001", @rp.TaskStatus::Pending, @rp.Side::Requester, 1)
  match db.upsert_task(env) {
    Ok(_) => ()
    Err(e) => abort("upsert_task 失败: \{e}")
  }
  let got = match db.get_task("job-001") {
    Some(v) => v
    None => abort("get_task 应读回 job-001")
  }
  assert_eq(got.task_id, "job-001")
  assert_eq(got.status, @rp.TaskStatus::Pending)
  assert_eq(got.version, 1)
  // 读回的信封应自证完整性（envelope 列 → from_rhop_bytes 已校验 checksum）
  assert_eq(got.checksum, got.compute_checksum())
  // 不存在的任务 → None（不是 Err）
  assert_true(db.get_task("job-missing") is None)
  db.close()
}

///|
test "mirror: 重开同一库文件 → 数据持久化（同一路径再 open）" {
  // 用 open_temp 拿一条真实唯一路径（同一进程内不会与历史运行残留撞库）
  let probe = match @rp.MirrorDB::open_temp() {
    Ok(db) => db
    Err(e) => abort("open_temp 失败: \{e}")
  }
  let path = probe.path()
  probe.close()
  let db1 = match @rp.MirrorDB::open(path) {
    Ok(db) => db
    Err(e) => abort("open 失败: \{e}")
  }
  let env = mk_env("job-p1", @rp.TaskStatus::Pending, @rp.Side::Requester, 1)
  match db1.upsert_task(env) {
    Ok(_) => ()
    Err(e) => abort("upsert 失败: \{e}")
  }
  db1.close()
  assert_true(!db1.is_open())
  let db2 = match @rp.MirrorDB::open(path) {
    Ok(db) => db
    Err(e) => abort("重开库失败: \{e}")
  }
  let got = match db2.get_task("job-p1") {
    Some(v) => v
    None => abort("重开库后应读到 job-p1（持久化失效）")
  }
  assert_eq(got.task_id, "job-p1")
  // schema 幂等：重开后计数与事件流水都应保留
  assert_eq(db2.pending_count(), 1)
  db2.close()
}

///|
test "mirror: 乐观锁 —— upsert 同/低 version 报 stale_version" {
  let db = match @rp.MirrorDB::open_temp() {
    Ok(db) => db
    Err(e) => abort("open_temp 失败: \{e}")
  }
  let env = mk_env("job-lock", @rp.TaskStatus::Pending, @rp.Side::Requester, 2)
  match db.upsert_task(env) {
    Ok(_) => ()
    Err(e) => abort("首次 upsert 失败: \{e}")
  }
  // 同 version 再来一次 → StaleVersionError（vools 语义：必须严格递增）
  match db.upsert_task(env) {
    Ok(_) => abort("同 version 的 upsert 应被乐观锁拒绝")
    Err(e) => {
      assert_true(@rp.is_stale_version_error(e))
      assert_true(e.contains("job-lock"))
    }
  }
  // 更低 version 同样拒绝
  let lower = mk_env(
    "job-lock",
    @rp.TaskStatus::Pending,
    @rp.Side::Requester,
    1,
  )
  match db.upsert_task(lower) {
    Ok(_) => abort("低 version 的 upsert 应被拒绝")
    Err(e) => assert_true(@rp.is_stale_version_error(e))
  }
  // 更高 version 通过
  let higher = mk_env(
    "job-lock",
    @rp.TaskStatus::Claimed,
    @rp.Side::Requester,
    3,
  )
  match db.upsert_task(higher) {
    Ok(_) => ()
    Err(e) => abort("高 version 的 upsert 应通过: \{e}")
  }
  let got = match db.get_task("job-lock") {
    Some(v) => v
    None => abort("job-lock 应存在")
  }
  assert_eq(got.version, 3)
  db.close()
}

///|
test "mirror: update_status —— 版本冲突 / 非法流转 / 合法流转" {
  let db = match @rp.MirrorDB::open_temp() {
    Ok(db) => db
    Err(e) => abort("open_temp 失败: \{e}")
  }
  let env = mk_env("job-st", @rp.TaskStatus::Pending, @rp.Side::Requester, 1)
  match db.upsert_task(env) {
    Ok(_) => ()
    Err(e) => abort("upsert 失败: \{e}")
  }
  // 版本不符 → stale
  match db.update_status("job-st", @rp.TaskStatus::Claimed, 99) {
    Ok(_) => abort("版本不符应报 stale_version")
    Err(e) => assert_true(@rp.is_stale_version_error(e))
  }
  // 非法流转 pending -> done → illegal_transition
  match db.update_status("job-st", @rp.TaskStatus::Done, 1) {
    Ok(_) => abort("pending -> done 应判非法流转")
    Err(e) => assert_true(e.has_prefix("illegal_transition:"))
  }
  // 未知任务 → task not found
  match db.update_status("job-nope", @rp.TaskStatus::Claimed, 1) {
    Ok(_) => abort("未知任务应报错")
    Err(e) => assert_true(e.contains("task not found"))
  }
  // 合法流转 pending -> claimed，version 递增
  let v2 = match db.update_status("job-st", @rp.TaskStatus::Claimed, 1) {
    Ok(v) => v
    Err(e) => abort("合法流转失败: \{e}")
  }
  assert_eq(v2, 2)
  let after = match db.get_task("job-st") {
    Some(v) => v
    None => abort("job-st 应存在")
  }
  assert_eq(after.status, @rp.TaskStatus::Claimed)
  assert_eq(after.version, 2)
  // claimed -> running -> done（带 result）
  let _ = match db.update_status("job-st", @rp.TaskStatus::Running, 2) {
    Ok(v) => v
    Err(e) => abort("running 失败: \{e}")
  }
  let result_json = @json.parse("{\"stdout\":\"hi\"}") catch {
    _ => Json::null()
  }
  let _ = match
    db.update_status("job-st", @rp.TaskStatus::Done, 3, result=result_json) {
    Ok(v) => v
    Err(e) => abort("done 失败: \{e}")
  }
  let done = match db.get_task("job-st") {
    Some(v) => v
    None => abort("job-st 应存在")
  }
  assert_eq(done.status, @rp.TaskStatus::Done)
  assert_eq(done.version, 4)
  match done.result {
    Some(v) => assert_eq(v, result_json)
    None => abort("done 任务应带 result")
  }
  db.close()
}

///|
test "mirror: claim_task —— 点名称领取 / 重复领取拒绝 / 未知任务" {
  let db = match @rp.MirrorDB::open_temp() {
    Ok(db) => db
    Err(e) => abort("open_temp 失败: \{e}")
  }
  let env = mk_env("job-c1", @rp.TaskStatus::Pending, @rp.Side::Requester, 1)
  match db.upsert_task(env) {
    Ok(_) => ()
    Err(e) => abort("upsert 失败: \{e}")
  }
  let claimed = match db.claim_task("job-c1", "worker-a") {
    Ok(v) => v
    Err(e) => abort("claim_task 失败: \{e}")
  }
  assert_eq(claimed.status, @rp.TaskStatus::Claimed)
  assert_eq(claimed.version, 2)
  // 重复领取 → claim_rejected（可诊断，含当前状态）
  match db.claim_task("job-c1", "worker-b") {
    Ok(_) => abort("重复领取应被拒绝")
    Err(e) => {
      assert_true(e.has_prefix("claim_rejected:"))
      assert_true(e.contains("claimed"))
    }
  }
  // 未知任务 → task not found
  match db.claim_task("job-nope", "worker-a") {
    Ok(_) => abort("未知任务应报错")
    Err(e) => assert_true(e.contains("task not found"))
  }
  // 事件流水里应能查到 worker=worker-a
  let events = db.pending_sync()
  let mut found_worker = false
  for ev in events {
    match ev {
      Object(members) =>
        match members.get("detail") {
          Some(String(d)) => if d == "worker=worker-a" { found_worker = true }
          _ => ()
        }
      _ => ()
    }
  }
  assert_true(found_worker)
  db.close()
}

///|
test "mirror: claim_next —— 空库返回 Ok(None)，有 Pending 领最早一个" {
  let db = match @rp.MirrorDB::open_temp() {
    Ok(db) => db
    Err(e) => abort("open_temp 失败: \{e}")
  }
  // 空库：不报错
  match db.claim_next("w0") {
    Ok(None) => ()
    Ok(Some(_)) => abort("空库不应领到任务")
    Err(e) => abort("空库 claim_next 应 Ok(None): \{e}")
  }
  let env = mk_env("job-n1", @rp.TaskStatus::Pending, @rp.Side::Requester, 1)
  match db.upsert_task(env) {
    Ok(_) => ()
    Err(e) => abort("upsert 失败: \{e}")
  }
  match db.claim_next("w1") {
    Ok(Some(v)) => assert_eq(v.task_id, "job-n1")
    Ok(None) => abort("有 Pending 时不应返回 None")
    Err(e) => abort("claim_next 失败: \{e}")
  }
  // 领完后再领 → None（幂等，不重复领）
  match db.claim_next("w1") {
    Ok(None) => ()
    Ok(Some(_)) => abort("已无 Pending，不应重复领取")
    Err(e) => abort("claim_next 失败: \{e}")
  }
  db.close()
}

///|
test "mirror: count_by_status / count_by_status_full / list_tasks 过滤" {
  let db = match @rp.MirrorDB::open_temp() {
    Ok(db) => db
    Err(e) => abort("open_temp 失败: \{e}")
  }
  // 3 个 Pending + 1 个 Done（Done 用 claim+流转走到终态）
  for i in 0..<3 {
    let env = mk_env(
      "job-cnt-\{i}",
      @rp.TaskStatus::Pending,
      @rp.Side::Requester,
      1,
    )
    match db.upsert_task(env) {
      Ok(_) => ()
      Err(e) => abort("upsert 失败: \{e}")
    }
  }
  let done_env = mk_env(
    "job-cnt-done",
    @rp.TaskStatus::Pending,
    @rp.Side::Executor,
    1,
  )
  match db.upsert_task(done_env) {
    Ok(_) => ()
    Err(e) => abort("upsert 失败: \{e}")
  }
  let _ = match db.claim_task("job-cnt-done", "w") {
    Ok(_) => ()
    Err(e) => abort("claim 失败: \{e}")
  }
  let _ = match db.update_status("job-cnt-done", @rp.TaskStatus::Running, 2) {
    Ok(_) => ()
    Err(e) => abort("running 失败: \{e}")
  }
  let _ = match db.update_status("job-cnt-done", @rp.TaskStatus::Done, 3) {
    Ok(_) => ()
    Err(e) => abort("done 失败: \{e}")
  }
  let counts = db.count_by_status()
  assert_eq(jnum(counts, "pending"), 3.0)
  assert_eq(jnum(counts, "done"), 1.0)
  // 未出现的状态不出现在 vools 同形结果里
  assert_eq(jnum(counts, "failed"), -1.0)
  // full 版：六个状态全列，缺的 0
  let full = db.count_by_status_full()
  assert_eq(jnum(full, "pending"), 3.0)
  assert_eq(jnum(full, "claimed"), 0.0)
  assert_eq(jnum(full, "failed"), 0.0)
  // list_tasks 过滤
  assert_eq(db.list_tasks(status=@rp.TaskStatus::Pending).length(), 3)
  assert_eq(db.list_tasks().length(), 4)
  assert_eq(db.list_tasks(status=@rp.TaskStatus::Failed).length(), 0)
  // limit 生效（limit<=0 回退缺省 50）
  assert_eq(db.list_tasks(status=@rp.TaskStatus::Pending, limit=2).length(), 2)
  db.close()
}

///|
test "mirror: log_sync / sync_log_count / pending_count" {
  let db = match @rp.MirrorDB::open_temp() {
    Ok(db) => db
    Err(e) => abort("open_temp 失败: \{e}")
  }
  let env = mk_env("job-sync", @rp.TaskStatus::Pending, @rp.Side::Requester, 1)
  match db.upsert_task(env) {
    Ok(_) => ()
    Err(e) => abort("upsert 失败: \{e}")
  }
  // upsert 产生 1 条 updated 事件
  assert_eq(db.pending_count(), 1)
  match db.log_sync("push", "shared", "job-sync", true, bytes_xfer=42) {
    Ok(_) => ()
    Err(e) => abort("log_sync 失败: \{e}")
  }
  match db.log_sync("pull", "shared", "job-sync", false, error="连接超时") {
    Ok(_) => ()
    Err(e) => abort("log_sync(失败) 失败: \{e}")
  }
  assert_eq(db.sync_log_count(), 2)
  // pending_sync 返回事件行（含事件类型）
  let events = db.pending_sync()
  assert_eq(events.length(), 1)
  // since 下界：未来时间戳 → 空
  let future = db.pending_sync(since="2999-01-01T00:00:00Z")
  assert_eq(future.length(), 0)
  db.close()
}

///|
test "mirror: 关闭后继续操作 → 可诊断 Err；重复 close 幂等" {
  let db = match @rp.MirrorDB::open_temp() {
    Ok(db) => db
    Err(e) => abort("open_temp 失败: \{e}")
  }
  db.close()
  db.close() // 幂等
  assert_true(!db.is_open())
  let env = mk_env("job-x", @rp.TaskStatus::Pending, @rp.Side::Requester, 1)
  match db.upsert_task(env) {
    Ok(_) => abort("已关闭的库不应写入成功")
    Err(e) => assert_true(e.contains("已关闭"))
  }
  match db.try_list_tasks(None, 10) {
    Ok(_) => abort("已关闭的库不应查询成功")
    Err(e) => assert_true(e.contains("已关闭"))
  }
  // 读路径：None / 空数组（不 panic）
  assert_true(db.get_task("job-x") is None)
  assert_eq(db.list_tasks().length(), 0)
  assert_eq(db.pending_count(), 0)
  assert_eq(db.sync_log_count(), 0)
}

///|
test "mirror: 坏库路径 → 可诊断 Err（不静默成功）" {
  // 空路径：显式拒绝
  match @rp.MirrorDB::open("") {
    Ok(_) => abort("空路径不应建库成功")
    Err(e) => assert_true(e.contains("非空"))
  }
  // 指向一个已存在的**目录** → node:sqlite 打开失败
  let probe = match @rp.MirrorDB::open_temp() {
    Ok(db) => db
    Err(e) => abort("open_temp 失败: \{e}")
  }
  let dir = @rp.rhop_join(@rp.rhop_fs_parent(probe.path()), "not-a-db-dir")
  probe.close()
  match @rp.rhop_fs_mkdir_p(dir) {
    Ok(_) => ()
    Err(e) => abort("建目录失败: \{e}")
  }
  match @rp.MirrorDB::open(dir) {
    Ok(_) => abort("用目录当数据库文件不应成功")
    Err(e) => assert_true(e.length() > 0)
  }
}

///|
test "mirror: 行损坏（envelope 列被篡改）→ try_get_task 可诊断 Err" {
  let db = match @rp.MirrorDB::open_temp() {
    Ok(db) => db
    Err(e) => abort("open_temp 失败: \{e}")
  }
  let env = mk_env("job-bad", @rp.TaskStatus::Pending, @rp.Side::Requester, 1)
  match db.upsert_task(env) {
    Ok(_) => ()
    Err(e) => abort("upsert 失败: \{e}")
  }
  // 用底层 SQL 直接篡改 envelope 列（模拟坏库）
  match
    db.raw_run(
      "UPDATE tasks SET envelope = ? WHERE task_id = ?",
      @json.parse("[\"{not-json\", \"job-bad\"]") catch {
        _ => Json::null()
      },
    ) {
    Ok(_) => ()
    Err(e) => abort("篡改失败: \{e}")
  }
  match db.try_get_task("job-bad") {
    Ok(_) => abort("坏行不应被读回成功")
    Err(e) => assert_true(e.length() > 0)
  }
  // get_task 的便捷形态不 panic，退化为 None
  assert_true(db.get_task("job-bad") is None)
  db.close()
}
