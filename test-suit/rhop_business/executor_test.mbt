// ============================================================================
// rhop_business · Executor（任务端业务 API）测试
//
// 覆盖：空队列 claim/execute_next / 缺 action / 未知 action / 合法动作成功 /
//       report_result 与 report_failure 的跳步补齐 / 终态拒绝再推进 /
//       list_pending / 关闭后拒绝操作。
// 目标：js。
// ============================================================================

///|
/// 起一个「只接了镜像库、不落文件」的 executor（队列由测试自己塞进去）。
fn biz_exec_fixture(dir : String) -> (@rp.Executor, @rp.MirrorDB) {
  let db_path = @rp.rhop_join(dir, "mirror.db")
  let cfg = biz_cfg("recv", "")
  let exec = match
    @rp.Executor::from_mirror_path(cfg, db_path, "", worker_id="worker-t") {
    Ok(v) => v
    Err(e) => abort("构造 Executor 失败: \{e}")
  }
  (exec, exec.mirror())
}

///|
/// 往镜像库里塞一个 Pending 任务（payload 由调用方给）。
fn biz_seed_task(
  mirror : @rp.MirrorDB,
  task_id : String,
  payload : Json,
) -> Unit {
  let now = @rp.rhop_now_iso()
  let env = @rp.Envelope::new_full(
    task_id,
    @rp.TaskStatus::Pending,
    payload,
    @rp.Side::Requester,
    version=1,
    created_at=now,
    updated_at=now,
  )
  match mirror.upsert_task(env) {
    Ok(_) => ()
    Err(e) => abort("塞任务失败: \{e}")
  }
}

///|
test "executor: 空队列 —— claim 返回 Ok(None)，execute_next 返回 idle" {
  let dir = biz_temp_workspace()
  let (exec, _mirror) = biz_exec_fixture(dir)
  match exec.claim() {
    Ok(None) => ()
    Ok(Some(_)) => abort("空队列不应领到任务")
    Err(e) => abort("空队列 claim 应 Ok(None): \{e}")
  }
  let next = match exec.execute_next() {
    Ok(v) => v
    Err(e) => abort("execute_next 失败: \{e}")
  }
  assert_eq(jstr(next, "status"), "idle")
  assert_eq(exec.list_pending().length(), 0)
  exec.close()
}

///|
test "executor: 合法动作 jump.probe 执行成功 → done + result 落库" {
  let dir = biz_temp_workspace()
  let (exec, mirror) = biz_exec_fixture(dir)
  biz_seed_task(mirror, "job-e1", biz_action_payload("jump.probe"))
  let next = match exec.execute_next() {
    Ok(v) => v
    Err(e) => abort("execute_next 失败: \{e}")
  }
  assert_eq(jstr(next, "status"), "done")
  assert_eq(jstr(next, "task_id"), "job-e1")
  let data = match next {
    Object(members) =>
      match members.get("data") {
        Some(v) => v
        None => {
          abort("done 回执应带 data")
          Json::null()
        }
      }
    _ => Json::null()
  }
  assert_status(data, "ok")
  // 镜像库：done，且 result 可读回
  let env = match mirror.get_task("job-e1") {
    Some(v) => v
    None => abort("job-e1 应存在")
  }
  assert_eq(env.status, @rp.TaskStatus::Done)
  assert_true(env.result is Some(_))
  assert_eq(jnum(mirror.count_by_status(), "done"), 1.0)
  exec.close()
}

///|
test "executor: payload 缺 action → 可诊断 Err 且任务置 Failed（失败可见）" {
  let dir = biz_temp_workspace()
  let (exec, mirror) = biz_exec_fixture(dir)
  let payload = @json.parse("{\"cmd\":\"echo hi\"}") catch { _ => Json::null() }
  biz_seed_task(mirror, "job-e2", payload)
  let err = match exec.execute_next() {
    Ok(v) => {
      assert_eq(jstr(v, "status"), "failed")
      jstr(v, "error")
    }
    Err(e) => abort("execute_next 不应整笔失败: \{e}")
  }
  assert_true(err.contains("action"))
  let env = match mirror.get_task("job-e2") {
    Some(v) => v
    None => abort("job-e2 应存在")
  }
  assert_eq(env.status, @rp.TaskStatus::Failed)
  match env.error {
    Some(text) => assert_true(text.contains("action"))
    None => abort("Failed 任务应记录 error")
  }
  // 终态再推进 ⇒ 可诊断 Err（terminal）
  match exec.report_result("job-e2", Json::null()) {
    Ok(_) => abort("终态任务不应再推进")
    Err(e) => assert_true(e.has_prefix("terminal:") || e.contains("terminal"))
  }
  exec.close()
}

///|
test "executor: 未知 action（无 handler）→ 可诊断 Err 含可用动作清单" {
  let dir = biz_temp_workspace()
  let (exec, mirror) = biz_exec_fixture(dir)
  biz_seed_task(mirror, "job-e3", biz_action_payload("no.such.action"))
  let next = match exec.execute_next() {
    Ok(v) => v
    Err(e) => abort("execute_next 不应整笔失败: \{e}")
  }
  assert_eq(jstr(next, "status"), "failed")
  let err = jstr(next, "error")
  assert_true(err.contains("no.such.action"))
  assert_true(err.contains("jump.probe"))
  let env = match mirror.get_task("job-e3") {
    Some(v) => v
    None => abort("job-e3 应存在")
  }
  assert_eq(env.status, @rp.TaskStatus::Failed)
  exec.close()
}

///|
test "executor: report_result / report_failure 跳步补齐（Claimed → Running → 终态）" {
  let dir = biz_temp_workspace()
  let (exec, mirror) = biz_exec_fixture(dir)
  let payload = @json.parse("{\"cmd\":\"echo hi\"}") catch { _ => Json::null() }
  biz_seed_task(mirror, "job-r1", payload)
  biz_seed_task(mirror, "job-r2", payload)
  // 手动领一个（不执行）后直接 report_result：应自动补 Running
  let t1 = match mirror.claim_task("job-r1", "worker-t") {
    Ok(v) => v
    Err(e) => abort("claim 失败: \{e}")
  }
  assert_eq(t1.status, @rp.TaskStatus::Claimed)
  let payload_ok = @json.parse("{\"stdout\":\"ok\"}") catch {
    _ => Json::null()
  }
  match exec.report_result("job-r1", payload_ok) {
    Ok(_) => ()
    Err(e) => abort("report_result 失败: \{e}")
  }
  let done = match mirror.get_task("job-r1") {
    Some(v) => v
    None => abort("job-r1 应存在")
  }
  assert_eq(done.status, @rp.TaskStatus::Done)
  assert_true(done.result is Some(_))
  // 另一个直接 report_failure（仍是 Pending）：应补 Claimed → Running → Failed
  match exec.report_failure("job-r2", "手工失败原因") {
    Ok(_) => ()
    Err(e) => abort("report_failure 失败: \{e}")
  }
  let failed = match mirror.get_task("job-r2") {
    Some(v) => v
    None => abort("job-r2 应存在")
  }
  assert_eq(failed.status, @rp.TaskStatus::Failed)
  match failed.error {
    Some(text) => assert_eq(text, "手工失败原因")
    None => abort("Failed 任务应记录 error")
  }
  // 未知任务 → task not found
  match exec.report_result("job-nope", Json::null()) {
    Ok(_) => abort("未知任务应报错")
    Err(e) => assert_true(e.contains("task not found"))
  }
  exec.close()
}

///|
test "executor: 关闭后拒绝操作（不静默成功）" {
  let dir = biz_temp_workspace()
  let (exec, _mirror) = biz_exec_fixture(dir)
  exec.close()
  exec.close() // 幂等
  match exec.claim() {
    Ok(None) => abort("已关闭的库不应返回空队列成功")
    Ok(Some(_)) => abort("已关闭的库不应领到任务")
    Err(e) => assert_true(e.contains("已关闭"))
  }
  match exec.report_failure("job-x", "x") {
    Ok(_) => abort("已关闭的库不应写成功")
    Err(e) => assert_true(e.contains("已关闭"))
  }
}
