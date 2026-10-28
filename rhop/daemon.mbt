// ============================================================================
// rhop · 常驻 relay daemon（Batch D · P1）
//
// 对照 vools.rhop.daemon：双方各跑一个 daemon，用 `side` 区分行为
//   - Requester（配置 role=send）：提交任务，等结果 → 把本地 inbox 的信封投出去；
//   - Executor （配置 role=recv / relay）：领任务、执行、回结果。
//
// 单轮循环（`run_once`，幂等）：pull_remote → process_inbox → push_local。
//   - pull_remote：从共享介质 `<root>/inbox/<我的 side>/` 收包（解密降级）→ 落到本地 inbox；
//   - process_inbox：读本地 `data_dir/inbox/*.rhop` → `Envelope::from_rhop_bytes`（含 checksum
//     校验）→ 写镜像库 → executor 侧接力执行 → 信封移入 `data_dir/outbox/`；
//   - push_local：把 `data_dir/outbox/*.rhop` 投到 `<root>/inbox/<对端 side>/` 并移除本地副本。
//
// 幂等性：文件一旦移出 inbox/outbox 就不会被第二次处理；同一批文件重复 `run_once`
// 只会在第一轮被处理，第二轮全 0（此性质由测试锁定）。坏信封移入 `failed/` 并计数，
// 不会卡住整个循环。
//
// 与 vools 的差异（明说）：
//   - vools 的 `_pull_remote` / `_push_local` 读写目录不对称（且在 Python 侧用 hasattr
//     猜协议）；这里统一为「共享介质 + inbox/<side> 收件箱」的对称布局，且**消费即删除**
//     （单消费者 MVP 语义，多消费者需要 ack 协议，明确不做）；
//   - HTTP relay 通道（Batch B 的 `RelayChannel`）不在这里驱动：daemon 只走 SharedPath；
//   - 清理 `_cleanup` 在 vools 里就是 no-op，这里同样保留全部信封供审计。
//
// 目标可用性：js 真跑；wasm/native `new` 期即返回可诊断 Err（无 sqlite / 无 fs）。
// ============================================================================

///|
/// 常驻 daemon（双方共用，`side` 区分行为）。
pub struct RelayDaemon {
  config : RhopConfig
  side : Side
  data_dir : String
  poll_interval_ms : Int32
  worker_id : String
  executor : Executor
  shared_root : String?
  mut running : Bool
  mut rounds : Int32
}

///|
/// 由 `RhopConfig` 构造 daemon。
///
/// side 映射：`role=send` ⇒ Requester；`role=recv` / `role=relay` ⇒ Executor
/// （relay 侧重在替执行端收发，故按执行端处理，可用 `from_config_dir(side=)` 覆盖）。
pub fn RelayDaemon::new(config : RhopConfig) -> Result[RelayDaemon, String] {
  let base = match rhop_config_data_dir(config) {
    Some(dir) => dir
    None => rhop_default_data_dir()
  }
  RelayDaemon::from_config_dir(config, base, worker_id="daemon")
}

///|
/// 由 `RhopConfig` + 显式 `data_dir` 构造（`side` 可覆盖推断结果）。
pub fn RelayDaemon::from_config_dir(
  config : RhopConfig,
  data_dir : String,
  side? : Side,
  worker_id? : String,
  poll_interval_ms~ : Int32 = 200,
) -> Result[RelayDaemon, String] {
  let resolved = match side {
    Some(s) => s
    None =>
      match config.role() {
        Role::Send => Side::Requester
        Role::Recv => Side::Executor
        Role::Relay => Side::Executor
      }
  }
  let worker = match worker_id {
    Some(name) => name
    None => "daemon"
  }
  let executor = match
    Executor::from_config_dir(config, data_dir, worker_id=worker) {
    Ok(e) => e
    Err(msg) => return Err("RelayDaemon 初始化执行端失败: \{msg}")
  }
  // 共享介质只走**本地目录**（映射盘 / UNC / 本地目录）；在线端点由 Batch B 的
  // RelayChannel 负责，daemon 侧不驱动（明确不做，见文件头差异说明）
  let shared_root = rhop_shared_local_root(config)
  Ok({
    config,
    side: resolved,
    data_dir,
    poll_interval_ms,
    worker_id: worker,
    executor,
    shared_root,
    running: false,
    rounds: 0,
  })
}

///|
/// 当前 side（requester / executor）。
pub fn RelayDaemon::side(self : RelayDaemon) -> Side {
  self.side
}

///|
/// 数据目录。
pub fn RelayDaemon::data_dir(self : RelayDaemon) -> String {
  self.data_dir
}

///|
/// 已跑轮数。
pub fn RelayDaemon::rounds(self : RelayDaemon) -> Int32 {
  self.rounds
}

///|
/// 是否处于运行态（`start` 期间为 true）。
pub fn RelayDaemon::is_running(self : RelayDaemon) -> Bool {
  self.running
}

///|
/// 底层镜像库（只读用途）。**不要**在外部 close 它。
pub fn RelayDaemon::mirror(self : RelayDaemon) -> MirrorDB {
  self.executor.mirror()
}

///|
/// 阻塞启动守护循环（对照 vools `start`）。
///
/// `max_rounds > 0` ⇒ 跑满即退（测试 / 一次性批处理）；`<= 0` ⇒ 无限循环直到 `stop()`。
/// 返回累计 `{"rounds","pulled","processed","failed","pushed","errors"}`。
pub fn RelayDaemon::start(
  self : RelayDaemon,
  max_rounds : Int32,
) -> Result[Json, String] {
  self.running = true
  let pulled_total = Ref::new(0)
  let processed_total = Ref::new(0)
  let failed_total = Ref::new(0)
  let pushed_total = Ref::new(0)
  let errors : Array[String] = []
  while self.running {
    let one = match self.run_once() {
      Ok(v) => v
      Err(msg) => {
        errors.push(msg)
        Json::object(Map([]))
      }
    }
    self.rounds = self.rounds + 1
    accumulate_counters(
      one, pulled_total, processed_total, failed_total, pushed_total, errors,
    )
    if max_rounds > 0 && self.rounds >= max_rounds {
      self.running = false
    }
    if self.running && self.poll_interval_ms > 0 {
      rhop_sleep_ms(self.poll_interval_ms)
    }
  }
  Ok(
    Json::object({
      "rounds": Json::number(self.rounds.to_double()),
      "pulled": Json::number(pulled_total.val.to_double()),
      "processed": Json::number(processed_total.val.to_double()),
      "failed": Json::number(failed_total.val.to_double()),
      "pushed": Json::number(pushed_total.val.to_double()),
      "errors": json_str_array(errors),
    }),
  )
}

///|
/// 置停止标记（优雅停止：当前轮跑完即退出）。
pub fn RelayDaemon::stop(self : RelayDaemon) -> Unit {
  self.running = false
}

///|
/// 单轮迭代（幂等）：pull_remote → process_inbox → push_local。
///
/// 返回 `{"status": "ok"|"partial", "rounds", "pulled", "processed", "failed",
///   "pushed", "errors": [...]}`；单步失败不抛，收进 `errors` 并把 status 降为 partial。
pub fn RelayDaemon::run_once(self : RelayDaemon) -> Result[Json, String] {
  let errors : Array[String] = []
  let pulled_ref = Ref::new(0)
  let processed_ref = Ref::new(0)
  let failed_ref = Ref::new(0)
  let pushed_ref = Ref::new(0)
  // 1. 收包
  match self.pull_remote() {
    Ok(v) => pulled_ref.val = pulled_ref.val + json_int(v, "pulled")
    Err(msg) => errors.push("pull_remote: " + msg)
  }
  // 2. 处理本地 inbox
  match self.process_inbox() {
    Ok(v) => {
      processed_ref.val = processed_ref.val + json_int(v, "processed")
      failed_ref.val = failed_ref.val + json_int(v, "failed")
      collect_errors(v, errors)
    }
    Err(msg) => errors.push("process_inbox: " + msg)
  }
  // 3. 推送本地 outbox
  match self.push_local() {
    Ok(v) => {
      pushed_ref.val = pushed_ref.val + json_int(v, "pushed")
      collect_errors(v, errors)
    }
    Err(msg) => errors.push("push_local: " + msg)
  }
  self.rounds = self.rounds + 0 // 轮数由 start/调用方推进（run_once 自身不重复计数）
  Ok(
    Json::object({
      "status": Json::string(
        if errors.length() == 0 {
          "ok"
        } else {
          "partial"
        },
      ),
      "rounds": Json::number(self.rounds.to_double()),
      "pulled": Json::number(pulled_ref.val.to_double()),
      "processed": Json::number(processed_ref.val.to_double()),
      "failed": Json::number(failed_ref.val.to_double()),
      "pushed": Json::number(pushed_ref.val.to_double()),
      "errors": json_str_array(errors),
    }),
  )
}

///|
/// 收包：从共享介质 `<root>/inbox/<我的 side>/` 把 `.rhop` 信封搬到本地 inbox。
///
/// 消费即从共享介质删除（单消费者 MVP）；无共享介质 / 介质无本地根时返回 0 + note。
pub fn RelayDaemon::pull_remote(self : RelayDaemon) -> Result[Json, String] {
  let root = match self.shared_root {
    Some(v) => v
    None =>
      return Ok(
        Json::object({
          "pulled": Json::number(0.0),
          "transport": Json::string("none"),
          "note": Json::string(
            "未配置本地共享介质（shared 需为本地目录/映射盘；在线端点请用 RelayChannel）",
          ),
        }),
      )
  }
  let inbox_rel = "inbox/" + self.side.to_string()
  let inbox_dir = rhop_join(root, inbox_rel)
  let names = rhop_fs_list_dir(inbox_dir)
  let mut pulled = 0
  let errors : Array[String] = []
  for fname in names {
    if !fname.has_suffix(".rhop") {
      continue
    }
    let rel = inbox_rel + "/" + fname
    let text = match rhop_fs_read_text(rhop_join(root, rel)) {
      Ok(t) => t
      Err(msg) => {
        errors.push("读取共享介质失败 \{fname}: \{msg}")
        continue
      }
    }
    let local_path = rhop_join(rhop_join(self.data_dir, "inbox"), fname)
    match rhop_fs_write_text(local_path, text) {
      Ok(_) => ()
      Err(msg) => {
        errors.push("落本地 inbox 失败 \{fname}: \{msg}")
        continue
      }
    }
    // 消费即删除（MVP 单消费者语义）
    match rhop_fs_remove(rhop_join(root, rel)) {
      Ok(_) => ()
      Err(msg) => errors.push("清理共享介质失败 \{fname}: \{msg}")
    }
    pulled = pulled + 1
  }
  Ok(
    Json::object({
      "pulled": Json::number(pulled.to_double()),
      "transport": Json::string("shared"),
      "errors": json_str_array(errors),
    }),
  )
}

///|
/// 把镜像库里某个任务的**当前**行信封写进 outbox（成功/失败共用同一条路径）。
///
/// 返回值带上下文，调用方直接 push 进 `errors` 即可。
fn RelayDaemon::write_outbox_result(
  self : RelayDaemon,
  task_id : String,
) -> Result[Unit, String] {
  let mirror = self.executor.mirror()
  let after = match mirror.get_task(task_id) {
    Some(v) => v
    None =>
      return Err("写结果信封失败 \{task_id}: 执行后读不回任务")
  }
  // P1-6 防御：outbox 文件名由 task_id 拼成，必须过「单层文件名 + 前缀断言」
  let path = match
    rhop_join_checked(rhop_join(self.data_dir, "outbox"), task_id + ".rhop") {
    Ok(p) => p
    Err(msg) => return Err("写结果信封失败 \{task_id}: \{msg}")
  }
  match rhop_fs_write_text(path, utf8_text(after.to_rhop_bytes())) {
    Ok(_) => Ok(())
    Err(msg) => Err("写结果信封失败 \{task_id}: \{msg}")
  }
}

///|
/// 处理本地 `inbox/*.rhop`：解码（明文优先，失败再尝试解密）→ 写镜像库 → executor 侧执行
/// → 信封移入 `outbox/`。坏信封移入 `failed/` 并计入 `failed`（不中断循环）。
pub fn RelayDaemon::process_inbox(self : RelayDaemon) -> Result[Json, String] {
  let inbox_dir = rhop_join(self.data_dir, "inbox")
  let names = rhop_fs_list_dir(inbox_dir)
  let mut processed = 0
  let mut failed = 0
  let errors : Array[String] = []
  for fname in names {
    if !fname.has_suffix(".rhop") {
      continue
    }
    let path = rhop_join(inbox_dir, fname)
    let text = match rhop_fs_read_text(path) {
      Ok(t) => t
      Err(msg) => {
        errors.push("读信封失败 \{fname}: \{msg}")
        move_to(self.data_dir, "inbox", fname, "failed")
        failed = failed + 1
        continue
      }
    }
    let env = match decode_envelope(self.config, text) {
      Ok(v) => v
      Err(msg) => {
        errors.push("解码信封失败 \{fname}: \{msg}")
        move_to(self.data_dir, "inbox", fname, "failed")
        failed = failed + 1
        continue
      }
    }
    // 写镜像库：只在「比本地新」时合并（同版本/更旧 = 已同步过，静默跳过，不算错误）
    let mirror = self.executor.mirror()
    let local_version = match mirror.get_task(env.task_id) {
      Some(local) => local.version
      None => 0
    }
    if env.version > local_version {
      match mirror.upsert_task(env_with_side(env, self.side.other())) {
        Ok(_) => ()
        Err(msg) => {
          errors.push("信封入库失败 \{env.task_id}: \{msg}")
          ignore(
            mirror.log_sync("pull", "inbox", env.task_id, false, error=msg),
          )
        }
      }
    }
    // executor 侧 + Pending ⇒ 接力执行；执行后把**结果信封**写进 outbox（回传给对端）
    if self.side == Side::Executor && env.status == TaskStatus::Pending {
      match self.executor.execute(env) {
        Ok(_) => {
          processed = processed + 1
          match self.write_outbox_result(env.task_id) {
            Ok(_) => ()
            Err(msg) => errors.push(msg)
          }
        }
        Err(msg) => {
          errors.push("执行失败 \{env.task_id}: \{msg}")
          failed = failed + 1
          // P1-5：失败也**必须**回传结果信封（Failed），否则需求端 `wait_result` 永久超时
          // （vools `daemon.py:218-222` 是无条件把信封移入 outbox，只是它不带错误原因）。
          // `execute` 在 Running 阶段就失败时行还没到终态 → 先显式落 Failed 再回传。
          match mirror.get_task(env.task_id) {
            Some(after) =>
              if !after.status.is_terminal() {
                match self.executor.report_failure(env.task_id, msg) {
                  Ok(_) => ()
                  Err(fmsg) =>
                    errors.push(
                      "失败状态落库失败 \{env.task_id}: \{fmsg}",
                    )
                }
              }
            None => errors.push("执行失败后读不回任务 \{env.task_id}")
          }
          match self.write_outbox_result(env.task_id) {
            Ok(_) => ()
            Err(wmsg) => errors.push(wmsg)
          }
        }
      }
      // 原始（Pending）信封入 processed 留档，避免回环重复投递
      move_to(self.data_dir, "inbox", fname, "processed")
    } else if self.side == Side::Requester && env.status.is_terminal() {
      // 需求端收到终态结果：入库留档即可，**不再回推**（否则两端会无限回声）
      processed = processed + 1
      move_to(self.data_dir, "inbox", fname, "processed")
    } else {
      // 其它：转 outbox，由 push_local 投给对端
      processed = processed + 1
      move_to(self.data_dir, "inbox", fname, "outbox")
    }
  }
  Ok(
    Json::object({
      "processed": Json::number(processed.to_double()),
      "failed": Json::number(failed.to_double()),
      "errors": json_str_array(errors),
    }),
  )
}

///|
/// 推送 `outbox/*.rhop` 到共享介质 `<root>/inbox/<对端 side>/`，成功后移除本地副本。
///
/// 无共享介质时不报错（`transport: "none"`），只把情况写进 note / errors。
pub fn RelayDaemon::push_local(self : RelayDaemon) -> Result[Json, String] {
  let outbox_dir = rhop_join(self.data_dir, "outbox")
  let names = rhop_fs_list_dir(outbox_dir)
  let root = match self.shared_root {
    Some(v) => v
    None =>
      return Ok(
        Json::object({
          "pushed": Json::number(0.0),
          "pending": Json::number(names.length().to_double()),
          "transport": Json::string("none"),
          "errors": json_str_array([
            "未配置本地共享介质（shared）：outbox 保留待后续投递",
          ]),
        }),
      )
  }
  let other = self.side.other()
  let remote_dir = "inbox/" + other.to_string()
  let mut pushed = 0
  let errors : Array[String] = []
  for fname in names {
    if !fname.has_suffix(".rhop") {
      continue
    }
    let path = rhop_join(outbox_dir, fname)
    let text = match rhop_fs_read_text(path) {
      Ok(t) => t
      Err(msg) => {
        errors.push("读 outbox 失败 \{fname}: \{msg}")
        continue
      }
    }
    let rel = remote_dir + "/" + fname
    match rhop_fs_write_text(rhop_join(root, rel), text) {
      Ok(_) => {
        ignore(rhop_fs_remove(path))
        pushed = pushed + 1
        ignore(
          self.executor
          .mirror()
          .log_sync(
            "push",
            "shared",
            strip_rhop_suffix(fname),
            true,
            bytes_xfer=text.length(),
          ),
        )
      }
      Err(msg) => errors.push("投递失败 \{fname}: \{msg}")
    }
  }
  Ok(
    Json::object({
      "pushed": Json::number(pushed.to_double()),
      "transport": Json::string("shared"),
      "errors": json_str_array(errors),
    }),
  )
}

///|
/// 关闭 daemon（停循环 + 释放镜像库；幂等）。
pub fn RelayDaemon::close(self : RelayDaemon) -> Unit {
  self.running = false
  self.executor.close()
}

// ---------------------------------------------------------------------------
// 本文件私有 helper
// ---------------------------------------------------------------------------

///|
/// 解码信封：优先按明文 `.rhop`（`Envelope::from_rhop_bytes`，含 checksum 校验）；
/// 失败且配置有 key 时尝试 `decrypt_verify`（`{"v":1,"alg":"fernet","ct":…}` 形态），
/// 解密成功再把 payload 当信封字典解析。
fn decode_envelope(
  config : RhopConfig,
  text : String,
) -> Result[Envelope, String] {
  let env = match decode_envelope_raw(config, text) {
    Ok(v) => v
    Err(msg) => return Err(msg)
  }
  // P1-6：`task_id` 来自**对端**（不可信），解码成功的第一时间统一收敛为白名单形态；
  // 非法 id 走「坏信封」通道（调用方 move 到 failed/ 并计数），绝不允许进入落盘路径。
  match validate_task_id(env.task_id) {
    Err(msg) => Err("信封 task_id 非法: " + msg)
    Ok(_) => Ok(env)
  }
}

///|
/// 原始解码（不做 `task_id` 校验）：优先按明文 `.rhop`（`Envelope::from_rhop_bytes`，
/// 含 checksum 校验）；失败且配置有 key 时尝试 `decrypt_verify`
/// （`{"v":1,"alg":"fernet","ct":…}` 形态），解密成功再把 payload 当信封字典解析。
fn decode_envelope_raw(
  config : RhopConfig,
  text : String,
) -> Result[Envelope, String] {
  let plain_err = match Envelope::from_rhop_bytes(bytes_of_utf8(text)) {
    Ok(env) => return Ok(env)
    Err(msg) => msg
  }
  let crypto = config.build_crypto()
  let verified = crypto.decrypt_verify(text)
  if !verified.ok {
    return Err(plain_err + "；解密也未通过: " + verified.reason)
  }
  match verified.payload {
    Some(payload) =>
      match Envelope::from_dict(payload) {
        Ok(env) => Ok(env)
        Err(msg) => Err("解密成功但信封字段非法: " + msg)
      }
    None => Err("解密成功但 payload 为空: " + plain_err)
  }
}

///|
/// 把配置推断出的某个信封的 side 改成「对端」（入本地库时保留来源信息）。
fn env_with_side(env : Envelope, side : Side) -> Envelope {
  if env.side == side {
    env
  } else {
    Envelope::new_full(
      env.task_id,
      env.status,
      env.payload,
      side,
      result?=env.result,
      error?=env.error,
      version=env.version,
      created_at=env.created_at,
      updated_at=env.updated_at,
      hops_seen=env.hops_seen.copy(),
      signature?=env.signature,
    )
  }
}

///|
/// 把 `data_dir/<from>/<fname>` 移到 `data_dir/<to>/<fname>`（失败静默，由计数体现）。
fn move_to(
  data_dir : String,
  from : String,
  fname : String,
  to : String,
) -> Unit {
  let src = rhop_join(rhop_join(data_dir, from), fname)
  let dst = rhop_join(rhop_join(data_dir, to), fname)
  ignore(rhop_fs_move(src, dst))
}

///|
/// 去掉 `.rhop` 后缀（同步日志里记 task_id）。
fn strip_rhop_suffix(fname : String) -> String {
  if fname.has_suffix(".rhop") {
    match fname.get_view(start=0, end=fname.length() - 5) {
      Some(v) => v.to_owned()
      None => fname
    }
  } else {
    fname
  }
}

///|
/// 取 JSON 对象的整数字段（缺失/非法回退 0）。
fn json_int(value : Json, key : String) -> Int32 {
  match value {
    Object(members) =>
      match members.get(key) {
        Some(Number(n, ..)) => n.to_int()
        _ => 0
      }
    _ => 0
  }
}

///|
/// 把某个步骤回执里的 `errors` 数组累加进总错误表。
fn collect_errors(value : Json, sink : Array[String]) -> Unit {
  match value {
    Object(members) =>
      match members.get("errors") {
        Some(Array(items)) =>
          for item in items {
            match item {
              String(msg) => sink.push(msg)
              _ => ()
            }
          }
        _ => ()
      }
    _ => ()
  }
}

///|
/// `start` 的累计器（把单轮回执的计数加进总账，并收集错误）。
fn accumulate_counters(
  one : Json,
  pulled : Ref[Int32],
  processed : Ref[Int32],
  failed : Ref[Int32],
  pushed : Ref[Int32],
  errors : Array[String],
) -> Unit {
  pulled.val = pulled.val + json_int(one, "pulled")
  processed.val = processed.val + json_int(one, "processed")
  failed.val = failed.val + json_int(one, "failed")
  pushed.val = pushed.val + json_int(one, "pushed")
  collect_errors(one, errors)
}

///|
/// `Array[String]` → Json 数组。
fn json_str_array(items : Array[String]) -> Json {
  let out : Array[Json] = []
  for item in items {
    out.push(Json::string(item))
  }
  Json::array(out)
}
