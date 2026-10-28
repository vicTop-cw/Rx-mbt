// ============================================================================
// rhop_task · 存储层测试（js 目标，临时目录真实建库）
//
// 覆盖：建库/建表、CRUD、状态流转（合法/非法）、乐观锁、并发领取唯一性、
//       依赖门控、失效锁回收、取消标记、apply_task 版本收敛、坏库错误路径。
// ============================================================================

///|
extern "js" fn ffi_st_mkdtemp(prefix : String) -> String =
  #| (prefix) => { try { const fs = process.getBuiltinModule("node:fs"); const os = process.getBuiltinModule("node:os"); const path = process.getBuiltinModule("node:path"); return fs.mkdtempSync(path.join(os.tmpdir(), String(prefix) + "-")); } catch (_e) { return ""; } }

///|
extern "js" fn ffi_st_join(dir : String, name : String) -> String =
  #| (dir, name) => { try { return process.getBuiltinModule("node:path").join(String(dir), String(name)); } catch (_e) { return String(dir) + "/" + String(name); } }

///|
extern "js" fn ffi_st_rmrf(p : String) -> Unit =
  #| (p) => { try { process.getBuiltinModule("node:fs").rmSync(String(p), { recursive: true, force: true }); } catch (_e) {} }

///|
/// 在临时目录开一个 newest 的 store。
fn open_store(kind : String) -> (@rt.SqliteTaskStore, String) raise {
  let dir = ffi_st_mkdtemp("rhop-store")
  assert_true(dir != "")
  let db = ffi_st_join(dir, "tasks.db")
  let spec = match @rt.TaskStoreSpec::for_kind(kind, db) {
    Ok(v) => v
    Err(e) => fail("spec 构造失败: \{e}")
  }
  let store = match @rt.SqliteTaskStore::open(spec) {
    Ok(v) => v
    Err(e) => fail("打开数据库失败: \{e}")
  }
  (store, dir)
}

///|
test "store · 建库建表 + 描述信息（两种拓扑的 PRAGMA 不同）" {
  let (store, dir) = open_store("sqlite-shared")
  assert_false(store.is_closed())
  let d = @rt.SqliteTaskStore::describe(store)
  match d {
    {
      "kind": String(k),
      "topology": String(top),
      "journal_mode": String(jm),
      ..
    } => {
      assert_eq(k, "sqlite")
      assert_eq(top, "sqlite-shared")
      // 共享库禁用 WAL（网络盘不可靠）
      assert_eq(jm, "DELETE")
    }
    _ => fail("describe 结构不符")
  }
  @rt.SqliteTaskStore::close(store)
  assert_true(store.is_closed())
  // close 幂等
  @rt.SqliteTaskStore::close(store)
  // local 拓扑用 WAL
  let (store2, dir2) = open_store("sqlite-local")
  match @rt.SqliteTaskStore::describe(store2) {
    { "journal_mode": String(jm), .. } => assert_eq(jm, "WAL")
    _ => fail("local describe 异常")
  }
  @rt.SqliteTaskStore::close(store2)
  ffi_st_rmrf(dir)
  ffi_st_rmrf(dir2)
}

///|
test "store · 非法拓扑 / 空路径 / 坏表名 → 可诊断 Err" {
  match @rt.TaskStoreSpec::for_kind("postgres", "x.db") {
    Err(e) => assert_true(e.contains("未知存储拓扑"))
    Ok(_) => fail("未知拓扑应当 Err")
  }
  match @rt.TaskStoreSpec::for_kind("sqlite-shared", "   ") {
    Err(e) => assert_true(e.contains("必须给 path"))
    Ok(_) => fail("空路径应当 Err")
  }
  let spec = match @rt.TaskStoreSpec::for_kind("sqlite-shared", "x.db") {
    Ok(v) => v
    Err(e) => fail("x: \{e}")
  }
  // 坏表名（注入尝试）
  let bad = { ..spec, table: "tasks; DROP TABLE tasks", }
  match @rt.SqliteTaskStore::open(bad) {
    Err(e) => assert_true(e.contains("表名 不合法"))
    Ok(_) => fail("非法表名应当 Err")
  }
}

///|
test "store · 写入幂等 + 查询 + 计数" {
  let (store, dir) = open_store("sqlite-local")
  let now = @rt.utcnow_iso()
  let r1 = @rt.TaskRecord::new("t1").with_priority(5)
  let r2 = @rt.TaskRecord::new("t2")
  // 首次插入 2 条
  assert_eq(@rt.SqliteTaskStore::insert_tasks(store, [r1, r2]), Ok(2))
  // 同名再插：幂等（0 条）
  assert_eq(@rt.SqliteTaskStore::insert_tasks(store, [r1]), Ok(0))
  // 查询
  match @rt.SqliteTaskStore::get_task(store, "t1") {
    Ok(Some(rec)) => {
      assert_eq(rec.task_name, "t1")
      assert_eq(rec.priority, 5)
      assert_eq(rec.state, @rt.TaskState::Pending)
      assert_true(rec.created_at is Some(_))
    }
    Ok(None) => fail("t1 应存在")
    Err(e) => fail("查询失败: \{e}")
  }
  match @rt.SqliteTaskStore::get_task(store, "ghost") {
    Ok(None) => ()
    Ok(Some(_)) => fail("ghost 不应存在")
    Err(e) => fail("查询失败: \{e}")
  }
  // 列表按 priority DESC
  let list = match @rt.SqliteTaskStore::list_tasks(store, None, 10) {
    Ok(v) => v
    Err(e) => fail("列表失败: \{e}")
  }
  assert_eq(list.length(), 2)
  assert_eq(list[0].task_name, "t1")
  // 计数
  let counts = match @rt.SqliteTaskStore::count_by_state(store) {
    Ok(v) => v
    Err(e) => fail("计数失败: \{e}")
  }
  assert_eq(counts.get_or_default("PENDING", 0), 2)
  // 全部名字
  match @rt.SqliteTaskStore::all_task_names(store) {
    Ok(names) => assert_eq(names, ["t1", "t2"])
    Err(e) => fail("names 失败: \{e}")
  }
  // 空 task_name 拒绝
  match @rt.SqliteTaskStore::insert_tasks(store, [@rt.TaskRecord::new("")]) {
    Err(e) => assert_true(e.contains("缺少 task_name"))
    Ok(_) => fail("空 task_name 应当 Err")
  }
  let _ = now
  @rt.SqliteTaskStore::close(store)
  ffi_st_rmrf(dir)
}

///|
test "store · 状态流转：合法推进 / 非法拒绝 / 强制放行 / 乐观锁" {
  let (store, dir) = open_store("sqlite-local")
  let now = @rt.utcnow_iso()
  assert_eq(
    @rt.SqliteTaskStore::insert_tasks(store, [@rt.TaskRecord::new("s1")]),
    Ok(1),
  )
  let empty = Json::object(Map::new())
  // PENDING → LOCKED 合法
  assert_eq(
    @rt.SqliteTaskStore::set_state(
      store,
      "s1",
      @rt.TaskState::Locked,
      None,
      false,
      empty,
      now,
    ),
    Ok(true),
  )
  // LOCKED → COMPLETED 非法（必须先 RUNNING）
  match
    @rt.SqliteTaskStore::set_state(
      store,
      "s1",
      @rt.TaskState::Completed,
      None,
      false,
      empty,
      now,
    ) {
    Err(e) => assert_true(e.contains("非法状态流转"))
    Ok(_) => fail("非法流转应当 Err")
  }
  // force 放行
  assert_eq(
    @rt.SqliteTaskStore::set_state(
      store,
      "s1",
      @rt.TaskState::Completed,
      None,
      true,
      empty,
      now,
    ),
    Ok(true),
  )
  // 终态不可再流转（非 force）
  match
    @rt.SqliteTaskStore::set_state(
      store,
      "s1",
      @rt.TaskState::Running,
      None,
      false,
      empty,
      now,
    ) {
    Err(e) => assert_true(e.contains("非法状态流转"))
    Ok(_) => fail("终态流转应当 Err")
  }
  // 不存在
  match
    @rt.SqliteTaskStore::set_state(
      store,
      "ghost",
      @rt.TaskState::Running,
      None,
      false,
      empty,
      now,
    ) {
    Err(e) => assert_true(e.contains("任务不存在"))
    Ok(_) => fail("不存在应当 Err")
  }
  // 乐观锁：expect_version 落后 → Ok(false)
  match @rt.SqliteTaskStore::get_task(store, "s1") {
    Ok(Some(rec)) => {
      let stale = rec.version - 1
      assert_eq(
        @rt.SqliteTaskStore::set_state(
          store,
          "s1",
          @rt.TaskState::Failed,
          Some(stale),
          true,
          empty,
          now,
        ),
        Ok(false),
      )
    }
    _ => fail("取 s1 失败")
  }
  @rt.SqliteTaskStore::close(store)
  ffi_st_rmrf(dir)
}

///|
test "store · 并发领取唯一性 + 优先级 + 取消/依赖门控" {
  let (store, dir) = open_store("sqlite-local")
  let now = @rt.utcnow_iso()
  // 三条任务：hi(优先级 9)、dep(依赖 hi)、low(优先级 0，已请求取消)
  let hi = @rt.TaskRecord::new("hi").with_priority(9)
  let dep = @rt.TaskRecord::new("dep").with_deps(["hi"])
  let low = @rt.TaskRecord::new("low")
  assert_eq(@rt.SqliteTaskStore::insert_tasks(store, [hi, dep, low]), Ok(3))
  assert_eq(
    @rt.SqliteTaskStore::set_cancel_requested(store, "low", true, now),
    Ok(true),
  )
  // 第一次领取：应拿到 hi（优先级最高且无依赖）
  let c1 = match @rt.SqliteTaskStore::claim_next(store, "w1", now, None) {
    Ok(v) => v
    Err(e) => fail("claim 失败: \{e}")
  }
  match c1 {
    Some(rec) => {
      assert_eq(rec.task_name, "hi")
      assert_eq(rec.state, @rt.TaskState::Locked)
      assert_eq(rec.worker_id, Some("w1"))
      assert_true(rec.expire_time is Some(_))
    }
    None => fail("应领到 hi")
  }
  // 第二次领取：low 被取消、dep 依赖未完成 → 没有可领的
  match @rt.SqliteTaskStore::claim_next(store, "w2", now, None) {
    Ok(Some(rec)) => fail("不应领到任务，却领到 \{rec.task_name}")
    Ok(None) => ()
    Err(e) => fail("claim 失败: \{e}")
  }
  // hi 完成 → dep 可领
  let empty = Json::object(Map::new())
  assert_eq(
    @rt.SqliteTaskStore::set_state(
      store,
      "hi",
      @rt.TaskState::Completed,
      None,
      true,
      empty,
      now,
    ),
    Ok(true),
  )
  match @rt.SqliteTaskStore::claim_next(store, "w2", now, None) {
    Ok(Some(rec)) => assert_eq(rec.task_name, "dep")
    Ok(None) => fail("hi 完成后 dep 应可领")
    Err(e) => fail("claim 失败: \{e}")
  }
  // 现在的可领为空（low 已取消、hi/dep 已处理）
  match @rt.SqliteTaskStore::claim_next(store, "w3", now, None) {
    Ok(Some(rec)) => fail("不应再领到 \{rec.task_name}")
    Ok(None) => ()
    Err(e) => fail("claim 失败: \{e}")
  }
  @rt.SqliteTaskStore::close(store)
  ffi_st_rmrf(dir)
}

///|
test "store · 失效锁回收：未超重试 → RETRY_PENDING，超限 → FAILED" {
  let (store, dir) = open_store("sqlite-local")
  let now = @rt.utcnow_iso()
  let a = @rt.TaskRecord::new("a").with_max_retries(3)
  let b = @rt.TaskRecord::new("b").with_max_retries(0)
  assert_eq(@rt.SqliteTaskStore::insert_tasks(store, [a, b]), Ok(2))
  // 都领掉（租约给 1 秒，便于用「未来时间」让它过期）
  let _ = @rt.SqliteTaskStore::claim_next(store, "w1", now, Some(1.0))
  let _ = @rt.SqliteTaskStore::claim_next(store, "w1", now, Some(1.0))
  // 注意：租约按 vools 取 max(lock_ttl, timeout_min*60)，默认 timeout_min=60 → 3600s，
  // 所以「过期」要跳到 3600s 之后，否则锁还没到期（这不是 bug，是设计）。
  let future = @rt.iso_add_seconds(now, 7200.0)
  let n = match @rt.SqliteTaskStore::clean_stale_locks(store, future) {
    Ok(v) => v
    Err(e) => fail("回收失败: \{e}")
  }
  assert_eq(n, 2)
  match @rt.SqliteTaskStore::get_task(store, "a") {
    Ok(Some(rec)) => {
      // 未超重试上限 → RETRY_PENDING
      assert_eq(rec.state, @rt.TaskState::RetryPending)
      assert_true(rec.worker_id is None)
      assert_true(rec.last_err is Some(_))
    }
    _ => fail("取 a 失败")
  }
  match @rt.SqliteTaskStore::get_task(store, "b") {
    Ok(Some(rec)) => assert_eq(rec.state, @rt.TaskState::Failed)
    _ => fail("取 b 失败")
  }
  @rt.SqliteTaskStore::close(store)
  ffi_st_rmrf(dir)
}

///|
test "store · apply_task 版本收敛（inserted / updated / ignored）" {
  let (store, dir) = open_store("sqlite-local")
  let base = @rt.TaskRecord::new("v1")
  assert_eq(@rt.SqliteTaskStore::apply_task(store, base), Ok("inserted"))
  // 同版本 → ignored（幂等）
  assert_eq(@rt.SqliteTaskStore::apply_task(store, base), Ok("ignored"))
  // 更高版本 → updated
  let higher = { ..base, version: 3, state: @rt.TaskState::Completed, }
  assert_eq(@rt.SqliteTaskStore::apply_task(store, higher), Ok("updated"))
  match @rt.SqliteTaskStore::get_task(store, "v1") {
    Ok(Some(rec)) => assert_eq(rec.state, @rt.TaskState::Completed)
    _ => fail("取 v1 失败")
  }
  // 低版本 → ignored（不覆盖）
  let lower = { ..base, version: 1, state: @rt.TaskState::Failed, }
  assert_eq(@rt.SqliteTaskStore::apply_task(store, lower), Ok("ignored"))
  match @rt.SqliteTaskStore::get_task(store, "v1") {
    Ok(Some(rec)) => assert_eq(rec.state, @rt.TaskState::Completed)
    _ => fail("取 v1 失败")
  }
  @rt.SqliteTaskStore::close(store)
  ffi_st_rmrf(dir)
}

///|
test "store · 关闭后再操作 → 可诊断 Err（不静默）" {
  let (store, dir) = open_store("sqlite-local")
  @rt.SqliteTaskStore::close(store)
  match @rt.SqliteTaskStore::get_task(store, "x") {
    Err(e) => assert_true(e.contains("已关闭"))
    Ok(_) => fail("关闭后查询应当 Err")
  }
  match @rt.SqliteTaskStore::list_tasks(store, None, 10) {
    Err(e) => assert_true(e.contains("已关闭"))
    Ok(_) => fail("关闭后列表应当 Err")
  }
  ffi_st_rmrf(dir)
}
