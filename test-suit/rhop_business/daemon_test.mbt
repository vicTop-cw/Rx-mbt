// ============================================================================
// rhop_business · RelayDaemon 测试（js）
//
// 覆盖边界四问里的「daemon 重复 run_once」：
//   ① 空目录 run_once 两轮全 0（幂等、无假错误）；
//   ② requester 侧提交 → run_once 把信封投到共享介质 `<shared>/inbox/executor/`；
//   ③ executor 侧 run_once：收包 → 解码 → 入库 → 执行 → 把**结果信封**写 outbox → 投回
//      `<shared>/inbox/requester/`（两端真正的单机中继闭环）；
//   ④ requester 侧再 run_once：读回终态 → 入库（get_result 看得到 done），且**不回推**；
//   ⑤ 坏信封 → 移入 failed/ 并计数，不中断同轮其它信封；
//   ⑥ 加密收包：`RhopCrypto::encrypt_json(env.to_dict())` 投进去，daemon 解密后照常执行。
// 目标：js。
// ============================================================================

///|
/// 起一对（requester daemon, executor daemon），共享同一临时 shared 目录。
fn daemon_pair(
  dir : String,
) -> (@rp.RelayDaemon, @rp.RelayDaemon, String, String, String) {
  let shared = @rp.rhop_join(dir, "shared")
  match @rp.rhop_fs_mkdir_p(shared) {
    Ok(_) => ()
    Err(e) => abort("建共享目录失败: \{e}")
  }
  let req_data = @rp.rhop_join(dir, "req-data")
  let exec_data = @rp.rhop_join(dir, "exec-data")
  let req_daemon = match
    @rp.RelayDaemon::from_config_dir(
      biz_cfg("send", shared),
      req_data,
      poll_interval_ms=0,
    ) {
    Ok(v) => v
    Err(e) => abort("构造 requester daemon 失败: \{e}")
  }
  let exec_daemon = match
    @rp.RelayDaemon::from_config_dir(
      biz_cfg("recv", shared),
      exec_data,
      poll_interval_ms=0,
    ) {
    Ok(v) => v
    Err(e) => abort("构造 executor daemon 失败: \{e}")
  }
  (req_daemon, exec_daemon, shared, req_data, exec_data)
}

///|
test "daemon: 空目录 run_once 两轮全 0（幂等）" {
  let dir = biz_temp_workspace()
  let (req_daemon, exec_daemon, _shared, _rd, _ed) = daemon_pair(dir)
  assert_eq(req_daemon.side(), @rp.Side::Requester)
  assert_eq(exec_daemon.side(), @rp.Side::Executor)
  for _ in 0..<2 {
    let one = match req_daemon.run_once() {
      Ok(v) => v
      Err(e) => abort("run_once 失败: \{e}")
    }
    assert_eq(jstr(one, "status"), "ok")
    assert_eq(jnum(one, "pulled"), 0.0)
    assert_eq(jnum(one, "processed"), 0.0)
    assert_eq(jnum(one, "failed"), 0.0)
    assert_eq(jnum(one, "pushed"), 0.0)
    assert_eq(jstr_array(one, "errors").length(), 0)
  }
  req_daemon.close()
  exec_daemon.close()
}

///|
test "daemon: 两 daemon 单机中继闭环（提交 → 执行 → 结果回流）" {
  let dir = biz_temp_workspace()
  let (req_daemon, exec_daemon, shared, req_data, _exec_data) = daemon_pair(dir)
  // 1. 需求端提交（落 req-data/inbox/*.rhop）
  match biz_cfg("send", shared).build_shared() {
    Ok(_) => ()
    Err(e) => abort("shared 构造失败: \{e}")
  }
  let req = match
    @rp.Requester::from_mirror_path(
      biz_cfg("send", shared),
      @rp.rhop_join(req_data, "mirror.db"),
      req_data,
    ) {
    Ok(v) => v
    Err(e) => abort("构造 Requester 失败: \{e}")
  }
  match req.submit("job-d1", biz_action_payload("jump.probe")) {
    Ok(_) => ()
    Err(e) => abort("submit 失败: \{e}")
  }
  // 2. requester daemon 一轮：inbox → outbox → 共享介质（对端收件箱）
  let r1 = match req_daemon.run_once() {
    Ok(v) => v
    Err(e) => abort("requester run_once 失败: \{e}")
  }
  assert_eq(jstr(r1, "status"), "ok")
  assert_eq(jnum(r1, "processed"), 1.0)
  assert_eq(jnum(r1, "pushed"), 1.0)
  let remote_for_exec = @rp.rhop_join(
    @rp.rhop_join(@rp.rhop_join(shared, "inbox"), "executor"),
    "job-d1.rhop",
  )
  assert_true(@rp.rhop_fs_exists(remote_for_exec))
  // 3. executor daemon 一轮：收包 → 入库 → 执行 → 结果信封投回 requester 收件箱
  let r2 = match exec_daemon.run_once() {
    Ok(v) => v
    Err(e) => abort("executor run_once 失败: \{e}")
  }
  assert_eq(jstr(r2, "status"), "ok")
  assert_eq(jnum(r2, "pulled"), 1.0)
  assert_eq(jnum(r2, "processed"), 1.0)
  assert_eq(jnum(r2, "failed"), 0.0)
  assert_eq(jnum(r2, "pushed"), 1.0)
  // executor 侧镜像库里任务应已 done
  let exec_env = match exec_daemon.mirror().get_task("job-d1") {
    Some(v) => v
    None => abort("executor 镜像库应有 job-d1")
  }
  assert_eq(exec_env.status, @rp.TaskStatus::Done)
  let remote_for_req = @rp.rhop_join(
    @rp.rhop_join(@rp.rhop_join(shared, "inbox"), "requester"),
    "job-d1.rhop",
  )
  assert_true(@rp.rhop_fs_exists(remote_for_req))
  // 4. requester daemon 再一轮：读回终态入库（不回声），get_result 可见 done
  let r3 = match req_daemon.run_once() {
    Ok(v) => v
    Err(e) => abort("requester 第二轮失败: \{e}")
  }
  assert_eq(jnum(r3, "pulled"), 1.0)
  assert_eq(jnum(r3, "processed"), 1.0)
  // 终态不回推（否则两端无限回声）
  assert_eq(jnum(r3, "pushed"), 0.0)
  let result = match req.get_result("job-d1") {
    Some(v) => v
    None => abort("结果回流后应能读到终态")
  }
  assert_eq(jstr(result, "status"), "done")
  // 5. 幂等：再来一轮，全 0
  let again = match req_daemon.run_once() {
    Ok(v) => v
    Err(e) => abort("run_once 失败: \{e}")
  }
  assert_eq(jnum(again, "pulled"), 0.0)
  assert_eq(jnum(again, "processed"), 0.0)
  req.close()
  req_daemon.close()
  exec_daemon.close()
}

///|
test "daemon: 坏信封 → 移入 failed/ 并计数，不中断其它信封" {
  let dir = biz_temp_workspace()
  let (req_daemon, _exec_daemon, shared, req_data, _ed) = daemon_pair(dir)
  let inbox = @rp.rhop_join(req_data, "inbox")
  // 坏信封（不是 JSON）
  match @rp.rhop_fs_write_text(@rp.rhop_join(inbox, "bad.rhop"), "not-a-json") {
    Ok(_) => ()
    Err(e) => abort("造坏信封失败: \{e}")
  }
  // 好信封（Requester 侧合法信封）
  let good = mk_env("job-ok", @rp.TaskStatus::Pending, @rp.Side::Requester, 1)
  match
    @rp.rhop_fs_write_text(
      @rp.rhop_join(inbox, "job-ok.rhop"),
      @rp.utf8_text(good.to_rhop_bytes()),
    ) {
    Ok(_) => ()
    Err(e) => abort("造好信封失败: \{e}")
  }
  let one = match req_daemon.run_once() {
    Ok(v) => v
    Err(e) => abort("run_once 失败: \{e}")
  }
  // 状态降为 partial（有错误），但好信封仍被处理并投出
  assert_eq(jstr(one, "status"), "partial")
  assert_eq(jnum(one, "failed"), 1.0)
  assert_eq(jnum(one, "processed"), 1.0)
  assert_eq(jnum(one, "pushed"), 1.0)
  // 坏信封进了 failed/
  assert_true(
    @rp.rhop_fs_exists(
      @rp.rhop_join(@rp.rhop_join(req_data, "failed"), "bad.rhop"),
    ),
  )
  // 好信封进了共享介质
  assert_true(
    @rp.rhop_fs_exists(
      @rp.rhop_join(
        @rp.rhop_join(@rp.rhop_join(shared, "inbox"), "executor"),
        "job-ok.rhop",
      ),
    ),
  )
  // 第二轮：无残留，全部 0（幂等）
  let two = match req_daemon.run_once() {
    Ok(v) => v
    Err(e) => abort("第二轮失败: \{e}")
  }
  assert_eq(jnum(two, "processed"), 0.0)
  assert_eq(jnum(two, "failed"), 0.0)
  req_daemon.close()
}

///|
test "daemon: 加密信封收包（decrypt_verify 降级路径）→ 解密后照常执行" {
  let dir = biz_temp_workspace()
  let (_req_daemon, exec_daemon, shared, _rd, _ed) = daemon_pair(dir)
  // 用与 config 一致的 key 加密一个 Pending 信封
  let crypto = @rp.RhopCrypto::from_key("biz-test-key")
  let env = mk_env("job-enc", @rp.TaskStatus::Pending, @rp.Side::Requester, 1)
  let payload = biz_action_payload("jump.probe")
  let now = @rp.rhop_now_iso()
  let real_env = @rp.Envelope::new_full(
    "job-enc",
    @rp.TaskStatus::Pending,
    payload,
    @rp.Side::Requester,
    version=1,
    created_at=now,
    updated_at=now,
  )
  let _ = env
  let cipher_text = crypto.encrypt_json(real_env.to_dict())
  // 投到 executor 的共享收件箱（模拟对端送来的密文包）
  match
    @rp.rhop_fs_write_text(
      @rp.rhop_join(
        @rp.rhop_join(@rp.rhop_join(shared, "inbox"), "executor"),
        "job-enc.rhop",
      ),
      cipher_text,
    ) {
    Ok(_) => ()
    Err(e) => abort("投递密文失败: \{e}")
  }
  let one = match exec_daemon.run_once() {
    Ok(v) => v
    Err(e) => abort("run_once 失败: \{e}")
  }
  assert_eq(jnum(one, "pulled"), 1.0)
  assert_eq(jnum(one, "failed"), 0.0)
  let got = match exec_daemon.mirror().get_task("job-enc") {
    Some(v) => v
    None => abort("解密后应入库 job-enc")
  }
  assert_eq(got.status, @rp.TaskStatus::Done)
  exec_daemon.close()
}

///|
test "daemon: 无共享介质时 push_local 不报错但把情况写清（pending 保留）" {
  let dir = biz_temp_workspace()
  let cfg = biz_cfg("send", "")
  let daemon = match
    @rp.RelayDaemon::from_config_dir(
      cfg,
      @rp.rhop_join(dir, "data"),
      poll_interval_ms=0,
    ) {
    Ok(v) => v
    Err(e) => abort("构造 daemon 失败: \{e}")
  }
  // 造一个 outbox 文件
  match
    @rp.rhop_fs_write_text(
      @rp.rhop_join(
        @rp.rhop_join(@rp.rhop_join(dir, "data"), "outbox"),
        "x.rhop",
      ),
      "content",
    ) {
    Ok(_) => ()
    Err(e) => abort("造 outbox 失败: \{e}")
  }
  let one = match daemon.run_once() {
    Ok(v) => v
    Err(e) => abort("run_once 失败: \{e}")
  }
  assert_eq(jnum(one, "pushed"), 0.0)
  assert_true(jstr_array(one, "errors").length() > 0)
  // outbox 文件保留（等后续介质恢复再投）
  assert_true(
    @rp.rhop_fs_exists(
      @rp.rhop_join(
        @rp.rhop_join(@rp.rhop_join(dir, "data"), "outbox"),
        "x.rhop",
      ),
    ),
  )
  daemon.close()
}

///|
test "daemon: start(max_rounds=2) 跑满即退（不阻塞）" {
  let dir = biz_temp_workspace()
  let (req_daemon, _exec_daemon, _shared, _rd, _ed) = daemon_pair(dir)
  let summary = match req_daemon.start(2) {
    Ok(v) => v
    Err(e) => abort("start 失败: \{e}")
  }
  assert_eq(jnum(summary, "rounds"), 2.0)
  assert_eq(req_daemon.rounds(), 2)
  assert_true(!req_daemon.is_running())
  req_daemon.close()
}
