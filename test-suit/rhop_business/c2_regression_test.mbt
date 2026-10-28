// ============================================================================
// rhop_business · C2 轮（资源与并发）回归测试
//
// 每个用例对应 C2 寻虫报告里的一条发现（见
// fist-mbt/reports/2026-10-28-c2-bugfind-business.md），锁死修法不回归：
//   C2-1 daemon 消费幂等：本地已是 Claimed/Running/Done 的信封**不得再次执行**
//   C2-2 daemon 对已终态任务的残留信封不产生虚假失败计数
//   C2-3 递归列举跳过符号链接（防巨型路径爆炸 / 越出源根遍历）
//   C2-4 大文件摘要分块读取后结果仍与整体 sha256 一致（>1MB，跨块）
//   C2-5 关闭全部句柄后临时目录必须可递归删除（Windows 句柄泄漏探测器）
//   C2-6 prepared statement 数量有界（复用缓存，不随调用次数增长）
//
// 目标：js（node:sqlite / node:fs）。
// ============================================================================

///|
/// 测试用计数器（动作被执行的次数）。
let c2_counter : Ref[Int32] = Ref::new(0)

///|
/// 注册一个「每执行一次 +1」的动作，返回其名字（用真实 run_action 链路）。
fn c2_register_counting_action(name : String) -> Unit {
  c2_counter.val = 0
  @rp.register_action(name, fn(cfg, payload) {
    let _ = (cfg, payload)
    c2_counter.val = c2_counter.val + 1
    Json::object({
      "status": Json::string("ok"),
      "count": Json::number(c2_counter.val.to_double()),
    })
  })
}

///|
/// 造一个 payload：指定动作名。
fn c2_payload(action : String) -> Json {
  let fields : Map[String, Json] = Map([])
  fields["action"] = Json::string(action)
  Json::object(fields)
}

///|
/// 把一个信封写进 `data_dir/inbox/`（模拟对端投递 / 上次运行残留）。
fn c2_drop_envelope(data_dir : String, env : @rp.Envelope) -> Unit {
  let path = @rp.rhop_join(
    @rp.rhop_join(data_dir, "inbox"),
    env.task_id + ".rhop",
  )
  match @rp.rhop_fs_write_text(path, @rp.utf8_text(env.to_rhop_bytes())) {
    Ok(_) => ()
    Err(e) => abort("写 inbox 信封失败: \{e}")
  }
}

///|
/// 起一个「只接了镜像库 + 独立数据目录」的 executor daemon。
fn c2_exec_daemon(dir : String) -> @rp.RelayDaemon {
  match
    @rp.RelayDaemon::from_config_dir(
      biz_cfg("recv", ""),
      @rp.rhop_join(dir, "exec-data"),
      poll_interval_ms=0,
    ) {
    Ok(d) => d
    Err(e) => abort("构造 executor daemon 失败: \{e}")
  }
}

///|
/// C2-1：本地任务已被别的执行体推进到 Running（例如上个进程执行中崩溃），
/// 再次读到同一枚 **Pending v1** 信封时**不得再次执行动作**（at-most-once 语义）。
test "c2-1: daemon 不重复执行本地已在 Running 的任务（消费幂等）" {
  let dir = biz_temp_workspace()
  let daemon = c2_exec_daemon(dir)
  c2_register_counting_action("c2.count.run")
  // 1. 先在镜像库里造一个「已被领走并正在执行」的任务（Pending v1 → Claimed v2 → Running v3）
  let now = @rp.rhop_now_iso()
  let env = @rp.Envelope::new_full(
    "job-c2-run",
    @rp.TaskStatus::Pending,
    c2_payload("c2.count.run"),
    @rp.Side::Requester,
    version=1,
    created_at=now,
    updated_at=now,
  )
  let mirror = daemon.mirror()
  match mirror.upsert_task(env) {
    Ok(_) => ()
    Err(e) => abort("upsert 失败: \{e}")
  }
  let _ = match mirror.update_status("job-c2-run", @rp.TaskStatus::Claimed, 1) {
    Ok(v) => v
    Err(e) => abort("claim 失败: \{e}")
  }
  let _ = match mirror.update_status("job-c2-run", @rp.TaskStatus::Running, 2) {
    Ok(v) => v
    Err(e) => abort("running 失败: \{e}")
  }
  // 2. 把**旧的 Pending v1** 信封重新放回 inbox（模拟上次搬运失败/进程崩溃残留）
  c2_drop_envelope(daemon.data_dir(), env)
  // 3. 跑一轮
  let one = match daemon.process_inbox() {
    Ok(v) => v
    Err(e) => abort("process_inbox 失败: \{e}")
  }
  // 断言：动作**一次都没执行**（本地不是 Pending，不能重放副作用）
  if c2_counter.val != 0 {
    abort(
      "重复执行了动作 \{c2_counter.val} 次（应 0 次）：本地任务状态为 Running 时必须跳过",
    )
  }
  // 本地状态不被破坏（仍是 Running，不被人为改成 Done/Failed）
  match mirror.get_task("job-c2-run") {
    Some(t) =>
      if t.status != @rp.TaskStatus::Running {
        abort(
          "本地状态被改成 \{t.status.to_string()}（应保持 running）",
        )
      }
    None => abort("本地任务不应消失")
  }
  // 不应被计成失败
  if jnum(one, "failed") != 0.0 {
    abort("不应计失败，实际 failed=\{jnum(one, "failed")}")
  }
  daemon.close()
  ignore(@rp.rhop_remove_dir_all(dir))
}

///|
/// C2-2：本地任务已 Done，inbox 里残留同一枚 Pending 信封 ⇒ 不得重复执行、
/// 不得产生虚假 failed 计数（搬运失败后的下一轮不应污染错误面）。
test "c2-2: daemon 对已 Done 任务的残留信封不重复执行 / 不计虚假失败" {
  let dir = biz_temp_workspace()
  let daemon = c2_exec_daemon(dir)
  c2_register_counting_action("c2.count.done")
  let now = @rp.rhop_now_iso()
  let env = @rp.Envelope::new_full(
    "job-c2-done",
    @rp.TaskStatus::Pending,
    c2_payload("c2.count.done"),
    @rp.Side::Requester,
    version=1,
    created_at=now,
    updated_at=now,
  )
  let mirror = daemon.mirror()
  match mirror.upsert_task(env) {
    Ok(_) => ()
    Err(e) => abort("upsert 失败: \{e}")
  }
  // 走完完整链路到 Done（同时会真实执行一次动作）；用同库的独立 Executor（公开 API）
  let exec = match
    @rp.Executor::from_mirror_path(
      biz_cfg("recv", ""),
      @rp.rhop_join(daemon.data_dir(), "mirror.db"),
      "",
      worker_id="w",
    ) {
    Ok(v) => v
    Err(e) => abort("构造 Executor 失败: \{e}")
  }
  let decided = match exec.execute_next() {
    Ok(v) => v
    Err(e) => abort("execute_next 失败: \{e}")
  }
  if jstr(decided, "status") != "done" {
    abort("首次执行应 done，实际 \{jstr(decided, "status")}")
  }
  exec.close()
  if c2_counter.val != 1 {
    abort("首次执行应计数 1，实际 \{c2_counter.val}")
  }
  // 残留旧信封
  c2_drop_envelope(daemon.data_dir(), env)
  let one = match daemon.process_inbox() {
    Ok(v) => v
    Err(e) => abort("process_inbox 失败: \{e}")
  }
  if c2_counter.val != 1 {
    abort(
      "已 Done 的任务被重复执行（计数 \{c2_counter.val}，应保持 1）：残留信封必须跳过",
    )
  }
  if jnum(one, "failed") != 0.0 {
    abort("不应产生虚假失败，实际 failed=\{jnum(one, "failed")}")
  }
  match mirror.get_task("job-c2-done") {
    Some(t) =>
      if t.status != @rp.TaskStatus::Done {
        abort("状态被改成 \{t.status.to_string()}（应保持 done）")
      }
    None => abort("任务不应消失")
  }
  daemon.close()
  ignore(@rp.rhop_remove_dir_all(dir))
}

///|
/// C2-3：递归列举必须**跳过符号链接**。
///
/// Windows 无权限建符号链接时退化为「只验证基础列举正确」并注明；
/// WSL/Linux 上则真造一个自指环 + 一个指向源根之外的链接，断言：
/// 不出现 `loop/`、不出现 `outside/` 条目（防路径爆炸与越根遍历）。
test "c2-3: 递归列举跳过符号链接（防路径爆炸/越根遍历）" {
  let dir = biz_temp_workspace()
  let src = @rp.rhop_join(dir, "src")
  match @rp.rhop_fs_write_text(@rp.rhop_join(src, "a.txt"), "x") {
    Ok(_) => ()
    Err(e) => abort("造文件失败: \{e}")
  }
  let outside = @rp.rhop_join(dir, "outside")
  match @rp.rhop_fs_write_text(@rp.rhop_join(outside, "secret.txt"), "s") {
    Ok(_) => ()
    Err(e) => abort("造外部目录失败: \{e}")
  }
  let made_loop = c2_try_symlink(src, @rp.rhop_join(src, "loop"))
  let made_out = c2_try_symlink(outside, @rp.rhop_join(src, "outside"))
  let listed = @rp.rhop_fs_list_files_recursive(src)
  // 基础正确性：a.txt 必在
  if !listed.contains("a.txt") {
    abort("递归列举应包含 a.txt，实际: \{listed.join(", ")}")
  }
  // 无论有无符号链接权限，都不允许出现穿透符号链接的路径
  for name in listed {
    if name.has_prefix("loop/") || name == "loop" {
      abort("列举穿透了自指符号链接：\{name}（应跳过链接）")
    }
    if name.has_prefix("outside/") || name == "outside" {
      abort(
        "列举越出源根穿过符号链接：\{name}（应跳过链接）",
      )
    }
  }
  // 路径数量必须有界（自指环曾被放大成 6.7 万条）
  if listed.length() > 4 {
    abort(
      "列举条目数异常（\{listed.length()}）：疑似符号链接爆炸",
    )
  }
  let _ = (made_loop, made_out)
  ignore(@rp.rhop_remove_dir_all(dir))
}

///|
/// C2-4：大于分块阈值（1MB）的文件，摘要必须与整体 sha256 一致（分块实现不改变语义）。
test "c2-4: 大文件分块摘要与整体 sha256 一致" {
  let dir = biz_temp_workspace()
  let path = @rp.rhop_join(dir, "big.txt")
  // 2.5MB 文本（跨多个 1MB 分块）
  let mut content = ""
  for _ in 0..<250 {
    content = content + "0123456789abcdef"
  } // 4000 字符
  let block = content
  let mut text = ""
  for _ in 0..<640 {
    text = text + block
  } // ~2.56MB
  match @rp.rhop_fs_write_text(path, text) {
    Ok(_) => ()
    Err(e) => abort("写大文件失败: \{e}")
  }
  let expected = @rp.sha256_hex(@rp.bytes_of_utf8(text))
  let digest = match @rp.rhop_fs_digest_file(path) {
    Ok(v) => v
    Err(e) => abort("摘要失败: \{e}")
  }
  let got = jstr(digest, "sha256")
  if got != expected {
    abort("分块摘要与整体不一致：期望 \{expected}，实际 \{got}")
  }
  if jnum(digest, "size") != text.length().to_double() {
    abort("字节数不对：\{jnum(digest, "size")} vs \{text.length()}")
  }
  ignore(@rp.rhop_remove_dir_all(dir))
}

///|
/// C2-5：把所有句柄都关掉之后，数据目录必须能被递归删除。
///
/// Windows 上 sqlite 句柄未释放会让 `rm -rf` 报 EPERM —— 这条用例因此是
/// 「句柄泄漏探测器」：只要哪个类忘了 close，这里就会红。
test "c2-5: 关闭全部句柄后临时目录可递归删除（句柄泄漏探测）" {
  let dir = biz_temp_workspace()
  let db_path = @rp.rhop_join(dir, "mirror.db")
  let db = match @rp.MirrorDB::open(db_path) {
    Ok(v) => v
    Err(e) => abort("open 失败: \{e}")
  }
  // 制造真实句柄活动
  match
    db.upsert_task(
      mk_env("job-c2-res", @rp.TaskStatus::Pending, @rp.Side::Requester, 1),
    ) {
    Ok(_) => ()
    Err(e) => abort("upsert 失败: \{e}")
  }
  // 未关闭前：Windows 上删除应失败（Linux 允许 → 该断言只在 Windows 有意义，
  // 因此不强制断言「删除失败」，只断言关闭后**必须**成功）
  db.close()
  match @rp.rhop_remove_dir_all(dir) {
    Ok(_) => ()
    Err(e) =>
      abort(
        "关闭全部句柄后临时目录仍无法删除（疑似句柄泄漏）: \{e}",
      )
  }
}

///|
/// C2-6：重复执行同一批 SQL 时，prepared statement 必须复用（数量有界，
/// 不随调用次数线性增长——否则 node:sqlite 的 StatementSync 只能等 GC，
/// 长驻 daemon 的 RSS 会无界上涨）。
test "c2-6: prepared statement 数量有界（复用缓存）" {
  let dir = biz_temp_workspace()
  let db = match @rp.MirrorDB::open(@rp.rhop_join(dir, "mirror.db")) {
    Ok(v) => v
    Err(e) => abort("open 失败: \{e}")
  }
  let before = c2_stmt_prepared_count()
  for i in 0..<300 {
    match
      db.upsert_task(
        mk_env(
          "job-c2-stmt-\{i}",
          @rp.TaskStatus::Pending,
          @rp.Side::Requester,
          1,
        ),
      ) {
      Ok(_) => ()
      Err(e) => abort("upsert 失败: \{e}")
    }
    ignore(db.count_by_status())
  }
  let after = c2_stmt_prepared_count()
  let created = after - before
  // 300 轮 × 多条不同 SQL：若每次调用都新 prepare，会到 ~1200+；
  // 有缓存时应只按「不同 SQL 条数」增长（本库 < 40 条）。
  if created > 60 {
    abort(
      "prepared statement 未复用：300 轮产生了 \{created} 条（应 < 60，按不同 SQL 计）",
    )
  }
  db.close()
  ignore(@rp.rhop_remove_dir_all(dir))
}

// ---------------------------------------------------------------------------
// 测试专用 js 探针（只存在于 js 测试文件里，不进库的公开 API）
// ---------------------------------------------------------------------------

///|
/// 尝试创建目录符号链接；无权限（Windows 默认）返回 false。
extern "js" fn c2_try_symlink_ffi(target : String, link : String) -> Bool =
  #| (target, link) => { try { process.getBuiltinModule("node:fs").symlinkSync(String(target), String(link), "dir"); return true; } catch (e) { return false; } }

///|
/// 读库内累计 prepared 语句数（由 mirror.mbt 的语句缓存自增，仅测试观测用）。
extern "js" fn c2_stmt_prepared_count_ffi() -> Int32 =
  #| () => Number(globalThis.__rhop_stmt_prepared || 0)

///|
/// MoonBit 包装：创建符号链接（失败返回 false）。
fn c2_try_symlink(target : String, link : String) -> Bool {
  c2_try_symlink_ffi(target, link)
}

///|
/// MoonBit 包装：累计 prepared 语句数。
fn c2_stmt_prepared_count() -> Int32 {
  c2_stmt_prepared_count_ffi()
}
