// ============================================================================
// rhop_business · C1 修复回归用例（P1-1 / P1-2 / P1-3 / P1-4 / P1-5 / P1-6）
//
// 每个用例都对应审计报告里一条已实测的缺陷，命名带 P1-x 前缀便于追溯：
//   P1-1 丢失更新（旧 version 的 update_status 必须 Err）
//   P1-2 双领（第二个 claim 必须 Err）
//   P1-3 零行更新被当成成功（同版本 upsert → 可诊断 stale Err）
//   P1-4 upsert 保留 claimed_by / 不丢 created_at（版本守卫下推 SQL）
//   P1-5 执行失败也要回传结果信封（否则需求端永久超时）
//   P1-6 task_id 白名单 + 不落盘目录外（submit / DB / daemon 解码三处）
// 目标：js（node:sqlite 真实建库）。
// ============================================================================

///|
/// 打开临时库；失败直接 abort（测试夹具用）。
fn p1_open_temp_db(what : String) -> @rp.MirrorDB {
  match @rp.MirrorDB::open_temp() {
    Ok(db) => db
    Err(e) => abort("\{what} 打开临时库失败: \{e}")
  }
}

///|
/// 打开指定路径的库；失败直接 abort。
fn p1_open_db(path : String, what : String) -> @rp.MirrorDB {
  match @rp.MirrorDB::open(path) {
    Ok(db) => db
    Err(e) => abort("\{what} 打开库 \{path} 失败: \{e}")
  }
}

///|
test "P1-3: 零行更新不再伪装成功——同版本 upsert 必须 stale Err，更高版本可写" {
  let db = p1_open_temp_db("P1-3")
  let env = mk_env("job-lock", @rp.TaskStatus::Pending, @rp.Side::Requester, 1)
  match db.upsert_task(env) {
    Ok(_) => ()
    Err(e) => abort("首次 upsert 不应失败: \{e}")
  }
  // 同一个 version 再写一次：SQL 的 `WHERE excluded.version > tasks.version` 不成立
  // → changes=0；修复后必须被识别为 stale，而不是「changes 被丢弃、静默成功」。
  match db.upsert_task(env) {
    Ok(_) =>
      abort(
        "同版本 upsert 应被乐观锁拒绝（P1-3 零行更新回归）",
      )
    Err(msg) => assert_true(msg.contains("stale_version"))
  }
  // 更高版本仍然可写（守卫只挡「不更新」，不挡正常推进）
  let v3 = mk_env("job-lock", @rp.TaskStatus::Running, @rp.Side::Requester, 3)
  match db.upsert_task(v3) {
    Ok(_) => ()
    Err(e) => abort("更高版本 upsert 不应失败: \{e}")
  }
  let after = match db.get_task("job-lock") {
    Some(v) => v
    None => abort("应读回 job-lock")
  }
  assert_eq(after.version, 3)
  assert_eq(after.status, @rp.TaskStatus::Running)
  db.close()
}

///|
test "P1-1: 两 MirrorDB 实例交错 → 旧 version 的 update_status 必须 Err（丢失更新回归）" {
  let dir = biz_temp_workspace()
  let path = @rp.rhop_join(dir, "mirror.db")
  let a = p1_open_db(path, "实例 A")
  let b = p1_open_db(path, "实例 B")
  match
    a.upsert_task(
      mk_env("job-race", @rp.TaskStatus::Pending, @rp.Side::Requester, 1),
    ) {
    Ok(_) => ()
    Err(e) => abort("初始化 upsert 失败: \{e}")
  }
  // B 先推进：Pending(v1) → Claimed(v2)（流转表只允许 Pending→Claimed）
  let v2 = match b.claim_task("job-race", "worker-B") {
    Ok(v) => v.version
    Err(e) => abort("B claim 失败: \{e}")
  }
  assert_eq(v2, 2)
  // A 还拿着 v1 想写 Running：Claimed→Running 本身合法，所以这里若成功就**只可能**
  // 是版本守卫失效（P1-1 丢失更新）；修复后必须 stale Err。
  match a.update_status("job-race", @rp.TaskStatus::Running, 1) {
    Ok(_) =>
      abort("旧 version 的更新应被拒绝（P1-1 丢失更新回归）")
    Err(msg) => assert_true(msg.contains("stale_version"))
  }
  // 库里应仍是 B 写的 Claimed v2（A 的过时写入不得落地）
  let after = match a.get_task("job-race") {
    Some(v) => v
    None => abort("应读回 job-race")
  }
  assert_eq(after.status, @rp.TaskStatus::Claimed)
  assert_eq(after.version, 2)
  a.close()
  b.close()
}

///|
test "P1-2: 双 claim 同一任务 → 第二个 Err，状态不被第二个 worker 改写" {
  let dir = biz_temp_workspace()
  let path = @rp.rhop_join(dir, "mirror.db")
  let a = p1_open_db(path, "worker-A")
  let b = p1_open_db(path, "worker-B")
  match
    a.upsert_task(
      mk_env("job-claim", @rp.TaskStatus::Pending, @rp.Side::Executor, 1),
    ) {
    Ok(_) => ()
    Err(e) => abort("初始化 upsert 失败: \{e}")
  }
  let claimed = match a.claim_task("job-claim", "worker-A") {
    Ok(v) => v
    Err(e) => abort("A 首次 claim 失败: \{e}")
  }
  assert_eq(claimed.status, @rp.TaskStatus::Claimed)
  assert_eq(claimed.version, 2)
  // 第二个 worker 同时来领：修复前两条 UPDATE 都 changes=1（双领）；修复后必须 Err
  match b.claim_task("job-claim", "worker-B") {
    Ok(_) => abort("重复领取应被拒绝（P1-2 双领回归）")
    Err(_) => ()
  }
  let after = match b.get_task("job-claim") {
    Some(v) => v
    None => abort("应读回 job-claim")
  }
  assert_eq(after.status, @rp.TaskStatus::Claimed)
  assert_eq(after.version, 2)
  a.close()
  b.close()
}

///|
test "P1-5: executor 执行失败 → outbox 有 Failed 信封，结果能回到需求端并可查 failed" {
  let dir = biz_temp_workspace()
  let (req_daemon, exec_daemon, shared, req_data, _exec_data) = daemon_pair(dir)
  let req = match
    @rp.Requester::from_mirror_path(
      biz_cfg("send", shared),
      @rp.rhop_join(req_data, "mirror.db"),
      req_data,
    ) {
    Ok(v) => v
    Err(e) => abort("构造 Requester 失败: \{e}")
  }
  // 未注册的 action ⇒ Executor::execute 必然失败
  match req.submit("job-bad", biz_action_payload("no.such.action")) {
    Ok(_) => ()
    Err(e) => abort("submit 失败: \{e}")
  }
  match req_daemon.run_once() {
    Ok(_) => ()
    Err(e) => abort("requester run_once 失败: \{e}")
  }
  let r2 = match exec_daemon.run_once() {
    Ok(v) => v
    Err(e) => abort("executor run_once 失败: \{e}")
  }
  assert_eq(jnum(r2, "failed"), 1.0)
  // 关键回归点：失败分支也必须**产出结果信封**（修复前 outbox 为空 → 需求端永久超时）。
  // run_once 末尾会立刻 push_local，所以这里核对落在共享介质的副本，而不是本地 outbox。
  let pushed_to_requester = @rp.rhop_join(
    @rp.rhop_join(@rp.rhop_join(shared, "inbox"), "requester"),
    "job-bad.rhop",
  )
  assert_true(@rp.rhop_fs_exists(pushed_to_requester))
  // 信封内容应是 Failed 状态（不是原样回吐 Pending）
  let pushed_text = match @rp.rhop_fs_read_text(pushed_to_requester) {
    Ok(v) => v
    Err(e) => abort("读失败结果信封失败: \{e}")
  }
  let pushed_env = match
    @rp.Envelope::from_rhop_bytes(@rp.bytes_of_utf8(pushed_text)) {
    Ok(v) => v
    Err(e) => abort("失败结果信封解析失败: \{e}")
  }
  assert_eq(pushed_env.status, @rp.TaskStatus::Failed)
  // executor 侧镜像库里应为 Failed（而不是卡在 Running）
  let exec_env = match exec_daemon.mirror().get_task("job-bad") {
    Some(v) => v
    None => abort("executor 镜像库应有 job-bad")
  }
  assert_eq(exec_env.status, @rp.TaskStatus::Failed)
  // 失败信封在第一轮 run_once 末尾已随 push_local 推出；第二轮 outbox 应空（幂等，不重复推）
  let r3 = match exec_daemon.run_once() {
    Ok(v) => v
    Err(e) => abort("executor 第二轮 run_once 失败: \{e}")
  }
  assert_eq(jnum(r3, "pushed"), 0.0)
  match req_daemon.run_once() {
    Ok(_) => ()
    Err(e) => abort("requester 第二轮 run_once 失败: \{e}")
  }
  // 需求端最终能取到终态 failed（get_result 只在终态返回）
  let result = match req.get_result("job-bad") {
    Some(v) => v
    None =>
      abort("需求端应能取到 job-bad 的终态结果（P1-5 回归）")
  }
  assert_status(result, "failed")
  req.close()
  req_daemon.close()
  exec_daemon.close()
}

///|
test "P1-6: 非法 task_id 在 submit / DB / daemon 解码三处全拒，且不落盘到目录外" {
  let dir = biz_temp_workspace()
  let cfg = biz_cfg("send", "")
  let req = match
    @rp.Requester::from_mirror_path(cfg, @rp.rhop_join(dir, "mirror.db"), dir) {
    Ok(v) => v
    Err(e) => abort("构造 Requester 失败: \{e}")
  }
  let long_id = Array::make(129, "a").join("")
  let bad_ids : Array[String] = [
    "../../evil", "a/b", "a\\b", "", ".", "..", "a..b", long_id,
  ]
  for id in bad_ids {
    match req.submit(id, biz_action_payload("jump.probe")) {
      Ok(_) => abort("submit 应拒绝非法 task_id: \{id}")
      Err(_) => ()
    }
  }
  // 目录外不得出现任何落下物（修复前 `../../evil` 会写到 dir 的上级）
  assert_true(!@rp.rhop_fs_exists(@rp.rhop_join(dir, "evil.rhop")))
  assert_true(
    !@rp.rhop_fs_exists(@rp.rhop_join(@rp.rhop_fs_parent(dir), "evil.rhop")),
  )
  // DB 层同样拒绝（不只在入口层挡）
  match
    req
    .mirror()
    .upsert_task(
      mk_env("../../evil", @rp.TaskStatus::Pending, @rp.Side::Requester, 1),
    ) {
    Ok(_) => abort("DB 层应拒绝非法 task_id")
    Err(msg) => assert_true(msg.contains("task_id"))
  }
  // 合法 id 的边界：仍要能通过
  match @rp.validate_task_id("job.ok_1-2") {
    Ok(_) => ()
    Err(e) => abort("合法 task_id 被误拒: \{e}")
  }
  // 白名单校验本身的边界
  for id in bad_ids {
    assert_true(@rp.validate_task_id(id) is Err(_))
  }
  // daemon 解码处：带非法 task_id 的信封走「坏信封 → failed/」通道，绝不进入落盘路径
  let data_dir = @rp.rhop_join(dir, "exec-data")
  let daemon = match
    @rp.RelayDaemon::from_config_dir(
      biz_cfg("recv", ""),
      data_dir,
      poll_interval_ms=0,
    ) {
    Ok(v) => v
    Err(e) => abort("构造 daemon 失败: \{e}")
  }
  let evil_env = mk_env(
    "../../evil",
    @rp.TaskStatus::Pending,
    @rp.Side::Requester,
    1,
  )
  let inbox_file = @rp.rhop_join(@rp.rhop_join(data_dir, "inbox"), "evil.rhop")
  match
    @rp.rhop_fs_write_text(inbox_file, @rp.utf8_text(evil_env.to_rhop_bytes())) {
    Ok(_) => ()
    Err(e) => abort("写测试信封失败: \{e}")
  }
  let r = match daemon.process_inbox() {
    Ok(v) => v
    Err(e) => abort("process_inbox 失败: \{e}")
  }
  assert_eq(jnum(r, "failed"), 1.0)
  assert_eq(jnum(r, "processed"), 0.0)
  assert_true(
    @rp.rhop_fs_exists(
      @rp.rhop_join(@rp.rhop_join(data_dir, "failed"), "evil.rhop"),
    ),
  )
  assert_true(!@rp.rhop_fs_exists(@rp.rhop_join(data_dir, "evil.rhop")))
  assert_true(!@rp.rhop_fs_exists(@rp.rhop_join(dir, "evil.rhop")))
  daemon.close()
  req.close()
}

///|
test "临时目录：open_temp 的目录在 close 后递归删除（不再往 %TEMP% 无限堆积）" {
  let db = p1_open_temp_db("temp")
  let path = db.path()
  let dir = @rp.rhop_fs_parent(path)
  assert_true(@rp.rhop_fs_exists(path))
  assert_true(@rp.rhop_fs_exists(dir))
  db.close()
  assert_true(!@rp.rhop_fs_exists(path))
  assert_true(!@rp.rhop_fs_exists(dir))
}
