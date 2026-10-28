// ============================================================================
// rhop_business · Requester（需求端业务 API）测试
//
// 覆盖：提交（纯镜像库 / 落 inbox 文件两种模式）/ 查结果（在途 → None）/ 等待超时 /
//       列任务（按状态过滤）/ 取消（合法与非法流转）/ 重复 task_id / 空 task_id /
//       未知任务，以及「requester → executor 单机闭环」（同一 mirror 库）。
// 目标：js。
// ============================================================================

///|
test "requester: submit → 在途 get_result=None → cancel → 终态 cancelled" {
  let dir = biz_temp_workspace()
  let db_path = @rp.rhop_join(dir, "mirror.db")
  let cfg = biz_cfg("send", "")
  let req = match @rp.Requester::from_mirror_path(cfg, db_path, "") {
    Ok(v) => v
    Err(e) => abort("构造 Requester 失败: \{e}")
  }
  let payload = @json.parse("{\"cmd\":\"echo hi\"}") catch { _ => Json::null() }
  // 提交
  match req.submit("job-r1", payload) {
    Ok(id) => assert_eq(id, "job-r1")
    Err(e) => abort("submit 失败: \{e}")
  }
  // 在途（pending）→ None（不是 Err，也不是半成品 dict）
  assert_true(req.get_result("job-r1").is_none())
  // 未知任务 → None
  assert_true(req.get_result("job-nope").is_none())
  // 取消（pending 可取消）
  match req.cancel("job-r1") {
    Ok(_) => ()
    Err(e) => abort("cancel 失败: \{e}")
  }
  let result = match req.get_result("job-r1") {
    Some(v) => v
    None => abort("取消后应能读到终态")
  }
  assert_eq(jstr(result, "task_id"), "job-r1")
  assert_eq(jstr(result, "status"), "cancelled")
  // 重复取消 ⇒ 已是终态，可诊断 Err
  match req.cancel("job-r1") {
    Ok(_) => abort("终态任务不应再取消成功")
    Err(e) => assert_true(e.contains("不可取消") || e.contains("terminal"))
  }
  req.close()
}

///|
test "requester: 落 inbox 文件模式（config 的 shared 根当 data_dir）" {
  let dir = biz_temp_workspace()
  // 用 shared 地址字符串让 data_dir 推断到该目录
  let cfg = biz_cfg("send", dir)
  let req = match @rp.Requester::new(cfg) {
    Ok(v) => v
    Err(e) => abort("Requester::new 失败: \{e}")
  }
  // data_dir 应被推断为 shared 根；镜像库落在其下
  assert_eq(req.data_dir(), dir)
  assert_true(@rp.rhop_fs_exists(@rp.rhop_join(dir, "mirror.db")))
  let payload = @json.parse("{\"cmd\":\"echo hi\"}") catch { _ => Json::null() }
  match req.submit("job-r2", payload) {
    Ok(_) => ()
    Err(e) => abort("submit 失败: \{e}")
  }
  // inbox 文件应落地且内容可被 from_rhop_bytes 解析回来（含 checksum 校验）
  let inbox_file = @rp.rhop_join(@rp.rhop_join(dir, "inbox"), "job-r2.rhop")
  assert_true(@rp.rhop_fs_exists(inbox_file))
  let text = match @rp.rhop_fs_read_text(inbox_file) {
    Ok(t) => t
    Err(e) => abort("读 inbox 失败: \{e}")
  }
  match @rp.Envelope::from_rhop_bytes(@rp.bytes_of_utf8(text)) {
    Ok(env) => {
      assert_eq(env.task_id, "job-r2")
      assert_eq(env.status, @rp.TaskStatus::Pending)
      assert_eq(env.side, @rp.Side::Requester)
    }
    Err(e) => abort("inbox 文件不是合法信封: \{e}")
  }
  req.close()
}

///|
test "requester: 边界 —— 空 task_id / 重复 task_id / 空库列表" {
  let dir = biz_temp_workspace()
  let db_path = @rp.rhop_join(dir, "mirror.db")
  let cfg = biz_cfg("send", "")
  let req = match @rp.Requester::from_mirror_path(cfg, db_path, "") {
    Ok(v) => v
    Err(e) => abort("构造 Requester 失败: \{e}")
  }
  let payload = @json.parse("{\"cmd\":\"echo hi\"}") catch { _ => Json::null() }
  // 空库：列任务为空，不报错
  assert_eq(req.list_tasks().length(), 0)
  assert_eq(req.list_tasks(status=@rp.TaskStatus::Pending).length(), 0)
  // 空 task_id → 可诊断 Err
  match req.submit("", payload) {
    Ok(_) => abort("空 task_id 应被拒绝")
    Err(e) => assert_true(e.contains("task_id"))
  }
  // 正常提交后重复同 id → 乐观锁 Err（同 version）
  match req.submit("job-dup", payload) {
    Ok(_) => ()
    Err(e) => abort("首次 submit 失败: \{e}")
  }
  match req.submit("job-dup", payload) {
    Ok(_) => abort("重复 task_id 应被拒绝")
    Err(e) =>
      assert_true(e.contains("stale_version") || e.contains("镜像库"))
  }
  req.close()
}

///|
test "requester: list_tasks 状态过滤 + wait_result 超时返回 None" {
  let dir = biz_temp_workspace()
  let db_path = @rp.rhop_join(dir, "mirror.db")
  let cfg = biz_cfg("send", "")
  let req = match @rp.Requester::from_mirror_path(cfg, db_path, "") {
    Ok(v) => v
    Err(e) => abort("构造 Requester 失败: \{e}")
  }
  let payload = @json.parse("{\"cmd\":\"echo hi\"}") catch { _ => Json::null() }
  for id in ["job-l1", "job-l2", "job-l3"] {
    match req.submit(id, payload) {
      Ok(_) => ()
      Err(e) => abort("submit \{id} 失败: \{e}")
    }
  }
  assert_eq(req.list_tasks().length(), 3)
  assert_eq(req.list_tasks(status=@rp.TaskStatus::Pending).length(), 3)
  assert_eq(req.list_tasks(status=@rp.TaskStatus::Done).length(), 0)
  // 等待超时：pending 任务不可能在 150ms 内变终态 ⇒ None（不抛）
  assert_true(req.wait_result("job-l1", 150, 50).is_none())
  // timeout<=0 ⇒ 只查一次，同样 None
  assert_true(req.wait_result("job-l1", 0, 10).is_none())
  req.close()
}

///|
test "requester→executor 单机闭环（同一 mirror 库）" {
  let dir = biz_temp_workspace()
  let db_path = @rp.rhop_join(dir, "mirror.db")
  let send_cfg = biz_cfg("send", "")
  let recv_cfg = biz_cfg("recv", "")
  let req = match @rp.Requester::from_mirror_path(send_cfg, db_path, "") {
    Ok(v) => v
    Err(e) => abort("构造 Requester 失败: \{e}")
  }
  let exec = match
    @rp.Executor::from_mirror_path(
      recv_cfg,
      db_path,
      "",
      worker_id="worker-test",
    ) {
    Ok(v) => v
    Err(e) => abort("构造 Executor 失败: \{e}")
  }
  // 1. 需求端提交一个 jump.probe 任务
  match req.submit("job-loop", biz_action_payload("jump.probe")) {
    Ok(_) => ()
    Err(e) => abort("submit 失败: \{e}")
  }
  assert_true(req.get_result("job-loop").is_none())
  // 2. 任务端应看到 1 个 pending
  assert_eq(exec.list_pending().length(), 1)
  // 3. 领任务
  let task = match exec.claim() {
    Ok(Some(t)) => t
    Ok(None) => abort("应有可领任务")
    Err(e) => abort("claim 失败: \{e}")
  }
  assert_eq(task.task_id, "job-loop")
  assert_eq(task.status, @rp.TaskStatus::Claimed)
  // 4. 执行（内置动作 jump.probe，离线结构化探测）
  let data = match exec.execute(task) {
    Ok(v) => v
    Err(e) => abort("execute 失败: \{e}")
  }
  assert_status(data, "ok")
  assert_eq(jstr(data, "transport"), "offline")
  // 5. 需求端读到终态 done + result
  let result = match req.get_result("job-loop") {
    Some(v) => v
    None => abort("执行完应能读到终态")
  }
  assert_eq(jstr(result, "status"), "done")
  // result 里应带动作内层 data（status=ok）
  let inner_result = match result {
    Object(members) =>
      match members.get("result") {
        Some(v) => v
        None => {
          abort("done 回执应带 result")
          Json::null()
        }
      }
    _ => Json::null()
  }
  assert_status(inner_result, "ok")
  // 6. 计数：done=1，pending=0
  let mirror = req.mirror()
  assert_eq(jnum(mirror.count_by_status(), "done"), 1.0)
  assert_eq(jnum(mirror.count_by_status(), "pending"), -1.0)
  exec.close()
  req.close()
}
