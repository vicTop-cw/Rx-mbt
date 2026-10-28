// ============================================================================
// rhop · 需求端业务 API（Batch D · P1）
//
// 对照 vools.rhop.requester：需求端封装 = 提交任务（写本地 inbox + 镜像库）/
// 查结果 / 列任务 / 取消。
//
// 设计要点：
//   - **不做网络操作**：任务落地为 `<data_dir>/inbox/<task_id>.rhop` 文件
//     （`Envelope::to_rhop_bytes()` 规范 JSON，含 checksum），由 daemon 负责投递；
//   - 镜像库 `<data_dir>/mirror.db` 是需求端的本地真相源（时序、状态、乐观锁都在里面）；
//   - `get_result` 只回**终态**（done/failed/cancelled），在途返回 None，
//     需要等待请用 `wait_result`（轮询，超时即 None，不抛）；
//   - 与 vools 的差异：vools `cancel` 吞异常返回 False，这里返回可诊断
//     `Result[Unit, String]`（非法流转能看见原因）。
//
// 目标可用性：js（node:sqlite + node:fs）真跑；wasm/native 构造期即返回可诊断 Err。
// ============================================================================

///|
/// 需求端封装：提交任务 + 查结果。
///
/// 生命周期：`new`/`from_mirror_path` 建库并准备目录 → 业务调用 → `close()` 释放。
pub struct Requester {
  config : RhopConfig
  mirror : MirrorDB
  data_dir : String
}

///|
/// 由 `RhopConfig` 构造需求端。
///
/// `data_dir` 取值顺序：配置的 shared 本地根 → `<系统临时目录>/rhop-data`
/// （**不落仓库根**；要固定位置请用 `from_config_dir` 显式给 data_dir）。
/// 镜像库落在 `<data_dir>/mirror.db`；`inbox/outbox/processing/failed/tmp` 幂等创建。
pub fn Requester::new(config : RhopConfig) -> Result[Requester, String] {
  let base = match rhop_config_data_dir(config) {
    Some(dir) => dir
    None => rhop_default_data_dir()
  }
  Requester::from_config_dir(config, base)
}

///|
/// 由 `RhopConfig` + 显式 `data_dir` 构造（配置里没有数据目录字段时的逃生口）。
pub fn Requester::from_config_dir(
  config : RhopConfig,
  data_dir : String,
) -> Result[Requester, String] {
  let db_path = rhop_join(data_dir, "mirror.db")
  Requester::from_mirror_path(config, db_path, data_dir)
}

///|
/// 由镜像库路径直接构造（测试 / 运维 / 单机闭环用）。
///
/// `data_dir` 为空串 ⇒ **不落 inbox 文件**（纯镜像库模式，便于单机闭环测试）。
pub fn Requester::from_mirror_path(
  config : RhopConfig,
  db_path : String,
  data_dir : String,
) -> Result[Requester, String] {
  let mirror = match MirrorDB::open(db_path) {
    Ok(db) => db
    Err(msg) => return Err("Requester 建库失败: \{msg}")
  }
  if data_dir != "" {
    match rhop_ensure_data_dirs(data_dir) {
      Ok(_) => ()
      Err(msg) => {
        mirror.close()
        return Err("Requester 准备数据目录失败: \{msg}")
      }
    }
  }
  Ok({ config, mirror, data_dir, })
}

///|
/// 底层镜像库（只读用途：测试断言 / 运维排查）。**不要**在外部 close 它。
pub fn Requester::mirror(self : Requester) -> MirrorDB {
  self.mirror
}

///|
/// 数据目录（空串 = 纯镜像库模式，不落 .rhop 文件）。
pub fn Requester::data_dir(self : Requester) -> String {
  self.data_dir
}

///|
/// 提交任务：写本地 inbox 文件 + 落镜像库，返回 task_id。
///
/// 顺序对齐 vools（先文件、后库）；任一步失败返回可诊断 Err。
/// 重复 task_id 由镜像库乐观锁兜底（同 version 会被 `stale_version:` 拒绝）。
pub fn Requester::submit(
  self : Requester,
  task_id : String,
  payload : Json,
) -> Result[String, String] {
  match validate_task_id(task_id) {
    Err(msg) => return Err("submit 拒绝非法 task_id: \{msg}")
    Ok(_) => ()
  }
  let now = rhop_now_iso()
  let env = Envelope::new_full(
    task_id,
    TaskStatus::Pending,
    payload,
    Side::Requester,
    version=1,
    created_at=now,
    updated_at=now,
  )
  if self.data_dir != "" {
    let inbox_base = rhop_join(self.data_dir, "inbox")
    let inbox_path = match rhop_join_checked(inbox_base, task_id + ".rhop") {
      Ok(p) => p
      Err(msg) => return Err("submit 拒绝非法 inbox 路径: \{msg}")
    }
    match rhop_fs_write_text(inbox_path, utf8_text(env.to_rhop_bytes())) {
      Ok(_) => ()
      Err(msg) => return Err("submit 写 inbox 失败: \{msg}")
    }
  }
  match self.mirror.upsert_task(env) {
    Ok(_) => Ok(task_id)
    Err(msg) => Err("submit 写镜像库失败: \{msg}")
  }
}

///|
/// 查结果：只回终态（done / failed / cancelled）。
///
/// 返回 `{"task_id","status","result","error","signature"}`（对照 vools
/// `get_result` 的 dict 形状）；在途或不存在返回 `None`。
pub fn Requester::get_result(self : Requester, task_id : String) -> Json? {
  let env = match self.mirror.try_get_task(task_id) {
    Ok(found) =>
      match found {
        Some(v) => v
        None => return None
      }
    Err(_) => return None
  }
  if !env.status.is_terminal() {
    return None
  }
  Some(
    Json::object({
      "task_id": Json::string(env.task_id),
      "status": Json::string(env.status.to_string()),
      "result": match env.result {
        Some(v) => v
        None => Json::null()
      },
      "error": match env.error {
        Some(v) => Json::string(v)
        None => Json::null()
      },
      "signature": match env.signature {
        Some(v) => Json::string(v)
        None => Json::null()
      },
    }),
  )
}

///|
/// 轮询等待结果（js：真实 sleep；超时返回 `None`，**不抛**）。
///
/// `timeout_ms <= 0` ⇒ 只查一次（等价 `get_result`）；`poll_ms <= 0` ⇒ 50ms。
/// 语义对照 vools `get_result(timeout=600)`，但这里不做默认长等待（调用方显式给预算）。
pub fn Requester::wait_result(
  self : Requester,
  task_id : String,
  timeout_ms : Int32,
  poll_ms : Int32,
) -> Json? {
  let interval = if poll_ms <= 0 { 50 } else { poll_ms }
  let mut waited = 0
  let mut pending = true
  let mut found : Json? = None
  while pending {
    match self.get_result(task_id) {
      Some(value) => {
        found = Some(value)
        pending = false
      }
      None =>
        if waited >= timeout_ms {
          pending = false
        } else {
          rhop_sleep_ms(interval)
          waited = waited + interval
        }
    }
  }
  found
}

///|
/// 列出任务（`status` 省略 = 全部），返回 `to_dict()` 形状的数组。
pub fn Requester::list_tasks(
  self : Requester,
  status? : TaskStatus,
) -> Array[Json] {
  let envs = match status {
    Some(st) => self.mirror.list_tasks(status=st)
    None => self.mirror.list_tasks()
  }
  let out : Array[Json] = []
  for env in envs {
    out.push(env.to_dict())
  }
  out
}

///|
/// 取消任务（仅 Pending / Claimed 可取消；vools Q3：推送后对端可能已领走，尽力而为）。
///
/// 已进入 Running/终态 ⇒ 可诊断 Err（不静默吞掉失败）。
pub fn Requester::cancel(
  self : Requester,
  task_id : String,
) -> Result[Unit, String] {
  match self.mirror.get_task(task_id) {
    None => return Err("cancel 失败: task not found: \{task_id}")
    Some(env) =>
      if !env.status.can_transition(TaskStatus::Cancelled) {
        return Err(
          "cancel 失败: task \{task_id} 当前状态 \{env.status.to_string()} 不可取消",
        )
      }
  }
  match
    self.mirror.update_status(
      task_id,
      TaskStatus::Cancelled,
      version_of(self, task_id),
    ) {
    Ok(_) => Ok(())
    Err(msg) => Err(msg)
  }
}

///|
/// 关闭需求端（释放镜像库句柄；幂等）。
pub fn Requester::close(self : Requester) -> Unit {
  self.mirror.close()
}

// ---------------------------------------------------------------------------
// 本文件私有 helper
// ---------------------------------------------------------------------------

///|
/// 取任务当前 version（供 cancel 的乐观锁基准；读不到按 0，由 update_status 报 stale）。
fn version_of(req : Requester, task_id : String) -> Int32 {
  match req.mirror.get_task(task_id) {
    Some(env) => env.version
    None => 0
  }
}

///|
/// 从配置推断数据目录：shared 读端（或写端）的本地根。
///
/// 只对本地/文件 URL 端点有意义（HTTP 端点无本地根 ⇒ None）。
fn rhop_config_data_dir(config : RhopConfig) -> String? {
  // 1) shared 是**本地地址字符串**时直接用（最可靠：端点抽象的 `root()` 可能为 None）
  match rhop_shared_local_root(config) {
    Some(root) => return Some(root)
    None => ()
  }
  // 2) 退回端点视图的本地根（兼容 file:// 等形态）
  match config.build_shared() {
    Ok(view) =>
      match view {
        Some(sp) =>
          match SharedPath::root(sp) {
            Some(root) => if root == "" { None } else { Some(root) }
            None => None
          }
        None => None
      }
    Err(_) => None
  }
}

///|
/// 从配置的 `shared` 字段取**本地目录**（无人值守 / 业务层的 data_dir 与共享介质根）。
///
/// 支持两种形态：`shared: "<本地路径>"`（单 spec 简写）与
/// `shared: {"write": "<本地路径>", "read": "..."}`。含 `://` 的在线端点（http/https）
/// 没有本地目录 ⇒ `None`（调用方按「无共享介质」处理，而不是硬猜一个路径）。
pub fn rhop_shared_local_root(config : RhopConfig) -> String? {
  let spec = match config.shared {
    None => return None
    Some(Null) => return None
    Some(v) => v
  }
  let candidate = match spec {
    String(s) => s.trim().to_owned()
    Object(members) =>
      match members.get("write") {
        Some(String(w)) => w.trim().to_owned()
        _ =>
          match members.get("spec") {
            Some(String(w)) => w.trim().to_owned()
            _ => ""
          }
      }
    _ => ""
  }
  if candidate == "" {
    return None
  }
  if candidate.contains("://") {
    return None
  }
  Some(candidate)
}

///|
/// 幂等创建数据目录骨架（inbox/outbox/processing/failed/tmp，对照 vools `_ensure_dirs`）。
pub fn rhop_ensure_data_dirs(data_dir : String) -> Result[Unit, String] {
  for sub in ["inbox", "outbox", "processing", "failed", "tmp"] {
    match rhop_fs_mkdir_p(rhop_join(data_dir, sub)) {
      Ok(_) => ()
      Err(msg) => return Err(msg)
    }
  }
  Ok(())
}
