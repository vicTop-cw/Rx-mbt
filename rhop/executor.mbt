// ============================================================================
// rhop · 任务端业务 API（Batch D · P1）
//
// 对照 vools.rhop.executor：任务端封装 = 领任务 / 执行 / 回结果 / 回失败 / 列待办。
// 正常路径由 daemon 自动驱动；本类提供**手动 API**（调试、特殊场景、测试单机闭环）。
//
// 执行语义（vools Q2 默认决策的 MoonBit 版）：
//   - payload 里带 `action` 字段 ⇒ 走 `actions` 注册表（`run_action`）；
//   - 结果再经 `omega_unwrap` 判成功（内层 status 必须是 ok/partial）；
//   - **无 action 字段 / 无对应 handler / 内层失败** ⇒ 一律报**可诊断 Err** 并把任务
//     置为 Failed（绝不静默成功、不吞掉失败原因）；
//   - 状态推进一律走合法流转链（pending→claimed→running→done/failed），
//     跳步由内部 `advance_to` 补齐，非法目标返回 Err。
//
// 目标可用性：js（node:sqlite + node:fs）真跑；wasm/native 构造期即返回可诊断 Err。
// ============================================================================

///|
/// 任务端封装：领任务 → 执行 → 回结果。
pub struct Executor {
  config : RhopConfig
  mirror : MirrorDB
  data_dir : String
  worker_id : String
}

///|
/// 由 `RhopConfig` 构造任务端（`data_dir` 推断规则同 `Requester::new`）。
pub fn Executor::new(config : RhopConfig) -> Result[Executor, String] {
  let base = match rhop_config_data_dir(config) {
    Some(dir) => dir
    None => rhop_default_data_dir()
  }
  Executor::from_config_dir(config, base, worker_id="manual")
}

///|
/// 由 `RhopConfig` + 显式 `data_dir` + 工人名构造。
pub fn Executor::from_config_dir(
  config : RhopConfig,
  data_dir : String,
  worker_id? : String,
) -> Result[Executor, String] {
  let db_path = rhop_join(data_dir, "mirror.db")
  Executor::from_mirror_path(config, db_path, data_dir, worker_id?)
}

///|
/// 由镜像库路径直接构造（测试 / 运维 / 单机闭环用；`data_dir` 空串 = 不落文件）。
pub fn Executor::from_mirror_path(
  config : RhopConfig,
  db_path : String,
  data_dir : String,
  worker_id? : String,
) -> Result[Executor, String] {
  let mirror = match MirrorDB::open(db_path) {
    Ok(db) => db
    Err(msg) => return Err("Executor 建库失败: \{msg}")
  }
  if data_dir != "" {
    match rhop_ensure_data_dirs(data_dir) {
      Ok(_) => ()
      Err(msg) => {
        mirror.close()
        return Err("Executor 准备数据目录失败: \{msg}")
      }
    }
  }
  let worker = match worker_id {
    Some(name) => name
    None => "manual"
  }
  Ok({ config, mirror, data_dir, worker_id: worker, })
}

///|
/// 底层镜像库（只读用途）。**不要**在外部 close 它。
pub fn Executor::mirror(self : Executor) -> MirrorDB {
  self.mirror
}

///|
/// 当前工人名（写进 `claimed_by` 与事件 detail）。
pub fn Executor::worker_id(self : Executor) -> String {
  self.worker_id
}

///|
/// 领一个 Pending 任务（最早的一个）；队列为空返回 `Ok(None)`（不是错误）。
pub fn Executor::claim(self : Executor) -> Result[Envelope?, String] {
  self.mirror.claim_next(self.worker_id)
}

///|
/// 执行一个任务并回写结果（对照 vools `execute`）。
///
/// 步骤：
///   1. 状态推进到 Running（Pending 先 claim，Claimed 直接推进）；
///   2. 取 payload 的 `action` 名 + `cfg`（缺省用配置的 `action_cfg()`）执行；
///   3. `omega_unwrap` 判成功 → 置 Done 并回写 data；否则置 Failed 并返回 Err。
///
/// 返回值 = 动作内层 data（成功）或可诊断 Err（失败/无 handler/非法状态）。
pub fn Executor::execute(
  self : Executor,
  task : Envelope,
) -> Result[Json, String] {
  let task_id = task.task_id
  // 1. 推进到 Running
  match advance_to(self, task_id, TaskStatus::Running, None, None) {
    Ok(_) => ()
    Err(msg) => return Err(msg)
  }
  // 2. 取 action 名
  let action = match json_field_str(task.payload, "action") {
    Some(name) => name
    None =>
      return self.fail_and_report(
        task_id, "payload 缺少 action 字段（无法确定要执行的已注册动作）",
      )
  }
  // 未知动作前置判定：给出「无 handler」的可诊断错误（而不是让 run_action 静默）
  let known = list_actions()
  if !action_in_list(known, action) {
    return self.fail_and_report(
      task_id,
      "无已注册的 action handler: \{action}（可用: \{known.join(", ")}）",
    )
  }
  let cfg = match task.payload {
    Object(members) =>
      match members.get("cfg") {
        Some(v) => v
        None => self.config.action_cfg()
      }
    _ => self.config.action_cfg()
  }
  // 3. 执行 + Ω-gate 解包
  let raw = run_action(action, cfg, Some(task.payload))
  let data = omega_unwrap(raw)
  let inner_status = match json_field_str(data, "status") {
    Some(text) => text
    None => "error"
  }
  if inner_status != "ok" && inner_status != "partial" {
    let reason = match json_field(data, "omega_gate") {
      Some(gate) =>
        match json_field_str(gate, "error") {
          Some(text) => text
          None => "动作执行失败（omega_gate 无 error 字段）"
        }
      None =>
        match json_field_str(data, "error") {
          Some(text) => text
          None => "动作执行失败（内层 status=\{inner_status}）"
        }
    }
    return self.fail_and_report(task_id, reason)
  }
  // 4. 回写 Done
  match advance_to(self, task_id, TaskStatus::Done, Some(data), None) {
    Ok(_) => Ok(data)
    Err(msg) => Err("回写结果失败: \{msg}")
  }
}

///|
/// 便捷闭环：领一个任务并立即执行（队列空时返回 `{"status":"idle"}`）。
///
/// 返回 `{"status":"idle"|"done"|"failed","task_id"?, "action"?, "data"?, "error"?}`。
pub fn Executor::execute_next(self : Executor) -> Result[Json, String] {
  let claimed = match self.claim() {
    Ok(v) => v
    Err(msg) => return Err(msg)
  }
  match claimed {
    None =>
      Ok(
        Json::object({ "status": Json::string("idle"), "task_id": Json::null() }),
      )
    Some(task) =>
      match self.execute(task) {
        Ok(data) =>
          Ok(
            Json::object({
              "status": Json::string("done"),
              "task_id": Json::string(task.task_id),
              "data": data,
            }),
          )
        Err(msg) =>
          Ok(
            Json::object({
              "status": Json::string("failed"),
              "task_id": Json::string(task.task_id),
              "error": Json::string(msg),
            }),
          )
      }
  }
}

///|
/// 手动报告结果（把任务推到 Done；跳步由内部补齐）。
pub fn Executor::report_result(
  self : Executor,
  task_id : String,
  result : Json,
) -> Result[Unit, String] {
  advance_to(self, task_id, TaskStatus::Done, Some(result), None)
}

///|
/// 手动报告失败（把任务推到 Failed 并记录错误文本）。
pub fn Executor::report_failure(
  self : Executor,
  task_id : String,
  error : String,
) -> Result[Unit, String] {
  advance_to(self, task_id, TaskStatus::Failed, None, Some(error))
}

///|
/// 列出 Pending 任务（`to_dict()` 数组，对照 vools `list_pending`）。
pub fn Executor::list_pending(self : Executor) -> Array[Json] {
  let envs = self.mirror.list_tasks(status=TaskStatus::Pending)
  let out : Array[Json] = []
  for env in envs {
    out.push(env.to_dict())
  }
  out
}

///|
/// 关闭任务端（释放镜像库句柄；幂等）。
pub fn Executor::close(self : Executor) -> Unit {
  self.mirror.close()
}

///|
/// 内部：置 Failed 并回写错误，返回可诊断 Err（保证「失败可见」）。
fn Executor::fail_and_report(
  self : Executor,
  task_id : String,
  reason : String,
) -> Result[Json, String] {
  match advance_to(self, task_id, TaskStatus::Failed, None, Some(reason)) {
    Ok(_) => ()
    Err(msg) =>
      // 连失败都写不进去时，把两个原因都带上（不让原始失败原因丢失）
      return Err(
        "任务失败且回写失败: \{reason}（回写错误: \{msg}）",
      )
  }
  Err(reason)
}

///|
/// 内部：把任务推进到目标状态，必要时补齐合法中转状态。
///
/// 支持的补齐链（其余组合一律 Err）：
///   - → Running：Pending→Claimed→Running / Claimed→Running / Running 原样
///   - → Done / Failed：Pending→Claimed→Running→target / Claimed→Running→target / Running→target
///   - → Cancelled：Pending→Cancelled / Claimed→Cancelled
///
/// 终态任务再推 → Err（`terminal:` 前缀），避免对已完成任务重复执行。
fn advance_to(
  exec : Executor,
  task_id : String,
  target : TaskStatus,
  result : Json?,
  error : String?,
) -> Result[Unit, String] {
  let mut steps = 0
  while steps < 5 {
    steps = steps + 1
    let env = match exec.mirror.try_get_task(task_id) {
      Ok(found) =>
        match found {
          Some(v) => v
          None => return Err("task not found: \{task_id}")
        }
      Err(msg) => return Err(msg)
    }
    if env.status == target {
      return Ok(())
    }
    if env.status.is_terminal() {
      return Err(
        "terminal: task \{task_id} 已处于终态 \{env.status.to_string()}，无法推进到 " +
        "\{target.to_string()}",
      )
    }
    // 计算下一步
    let next_step = next_hop(env.status, target)
    match next_step {
      None =>
        return Err(
          "illegal_advance: \{env.status.to_string()} -> \{target.to_string()} for task " +
          "\{task_id}",
        )
      Some(hop) =>
        if hop == TaskStatus::Claimed {
          match exec.mirror.claim_task(task_id, exec.worker_id) {
            Ok(_) => ()
            Err(msg) => return Err(msg)
          }
        } else {
          // 只有最后一步带 result/error，中转步骤不带（避免半成品写进库里）
          let final_step = hop == target
          let step_result = if final_step { result } else { None }
          let step_error = if final_step { error } else { None }
          match
            exec.mirror.update_status(
              task_id,
              hop,
              env.version,
              result?=step_result,
              error?=step_error,
            ) {
            Ok(_) => ()
            Err(msg) => return Err(msg)
          }
        }
    }
  }
  Err("advance_to 超过最大步数（\{task_id} → \{target.to_string()}）")
}

///|
/// 内部：给定当前状态与目标状态，求下一步应走的合法状态（None = 走不通）。
fn next_hop(from : TaskStatus, target : TaskStatus) -> TaskStatus? {
  match (from, target) {
    (Pending, Claimed) => Some(TaskStatus::Claimed)
    (Pending, Running) => Some(TaskStatus::Claimed)
    (Pending, Done) => Some(TaskStatus::Claimed)
    (Pending, Failed) => Some(TaskStatus::Claimed)
    (Pending, Cancelled) => Some(TaskStatus::Cancelled)
    (Claimed, Claimed) => None
    (Claimed, Running) => Some(TaskStatus::Running)
    (Claimed, Done) => Some(TaskStatus::Running)
    (Claimed, Failed) => Some(TaskStatus::Running)
    (Claimed, Cancelled) => Some(TaskStatus::Cancelled)
    (Running, Done) => Some(TaskStatus::Done)
    (Running, Failed) => Some(TaskStatus::Failed)
    _ => None
  }
}

///|
/// 内部：JSON 对象取字段。
fn json_field(value : Json, key : String) -> Json? {
  match value {
    Object(members) => members.get(key)
    _ => None
  }
}

///|
/// 内部：JSON 对象取字符串字段。
fn json_field_str(value : Json, key : String) -> String? {
  match json_field(value, key) {
    Some(String(text)) => Some(text)
    _ => None
  }
}

///|
/// 内部：动作名是否在可用清单里（精确匹配）。
fn action_in_list(known : Array[String], name : String) -> Bool {
  for item in known {
    if item == name {
      return true
    }
  }
  false
}
