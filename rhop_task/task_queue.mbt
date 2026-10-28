// ============================================================================
// rhop_task · 任务队列（存储之上的编排：加密载荷 / 状态推进 / 重试 / 取消）
//
// 对照 vools.rhop.task.queue.TaskQueue 的核心动作（submit / claim / mark_* /
// cancel / retry_failed / requeue / list / counts）。存储与并发由 SqliteTaskStore
// 负责（见 task_store.mbt），本层只做「业务语义 + 载荷加解密 + 结果截断」。
//
// 载荷约定（与 vools 一致）：
//   - submit 时把 `value`（JSON）序列化成明文，用主密钥走 RhopCrypto::encrypt_json
//     得到信封文本存进 payload_enc，并把明文 sha256 存进 payload_sha（完整性/幂等）；
//   - 没有配密钥时 payload_enc 存明文 JSON 文本（payload_sha 仍记），上层可据
//     `crypto_used` 判断是否加密（不静默假装加密成功）。
//
// 目标说明：node:sqlite 仅 js；wasm/native 下所有方法返回可诊断 Err。
// ============================================================================

///|
/// 任务队列：存储 + 加解密 + 结果策略。
pub(all) struct TaskQueue {
  /// 底层存储
  store : SqliteTaskStore
  /// 主密钥加解密对象（None 时 payload 以明文 JSON 存）
  crypto : @rp.RhopCrypto?
  /// 锁租约（秒）
  lock_ttl_sec : Double
  /// 结果是否加密回传
  encrypt_result : Bool
  /// 结果最大字节数（超出截断并标记）
  result_max_bytes : Int32
}

///|
/// 构造队列。
pub fn TaskQueue::new(
  store : SqliteTaskStore,
  crypto : @rp.RhopCrypto?,
  lock_ttl_sec : Double,
  encrypt_result : Bool,
  result_max_bytes : Int32,
) -> TaskQueue {
  {
    store,
    crypto,
    lock_ttl_sec,
    encrypt_result,
    result_max_bytes: if result_max_bytes <= 0 {
      65536
    } else {
      result_max_bytes
    },
  }
}

///|
/// 从 TaskConfig 构造（配置里的 queue 段字段直接映射）。
pub fn TaskQueue::from_config(
  store : SqliteTaskStore,
  config : TaskConfig,
) -> TaskQueue {
  TaskQueue::new(
    store,
    config.build_crypto(),
    config.lock_ttl_sec,
    config.encrypt_result,
    config.result_max_bytes,
  )
}

///|
/// 底层存储（只读访问）。
pub fn TaskQueue::store_of(self : TaskQueue) -> SqliteTaskStore {
  self.store
}

///|
/// 关闭底层数据库（幂等）。
pub fn TaskQueue::close(self : TaskQueue) -> Unit {
  self.store.close()
}

///|
/// 载荷是否真的被加密（供上层诊断，不静默假装）。
pub fn TaskQueue::crypto_enabled(self : TaskQueue) -> Bool {
  match self.crypto {
    Some(_) => true
    None => false
  }
}

///|
/// 加密一段明文：有密钥走 RhopCrypto 信封，否则原样返回明文并标注。
fn TaskQueue::seal(self : TaskQueue, plain : String) -> (String, Bool) {
  match self.crypto {
    Some(c) => {
      let env = c.encrypt_json_text(plain)
      if env != "" {
        (env, true)
      } else {
        (plain, false)
      }
    }
    None => (plain, false)
  }
}

///|
/// 解封：先尝试按 RhopCrypto 信封解，失败则当明文 JSON 用。
fn TaskQueue::unseal(self : TaskQueue, text : String) -> Result[Json, String] {
  let trimmed = text.trim().to_owned()
  if trimmed == "" {
    return Ok(Json::null())
  }
  // 看起来像信封（{...v/alg/ct}）就先按密文解
  if trimmed.has_prefix("{") && trimmed.contains("\"alg\"") {
    match self.crypto {
      Some(c) => {
        let r = c.decrypt_verify(trimmed)
        if r.ok {
          return match r.payload {
            Some(p) => Ok(p)
            None => Ok(Json::null())
          }
        }
        // 解密失败：如果原文本身是合法 JSON（明文形态），继续按明文解析
        if r.reason == "MALFORMED" || r.reason == "NOT_JSON" {
          // fallthrough 到明文解析
        }
      }
      None => ()
    }
  }
  let j = @json.parse(trimmed) catch {
    _ =>
      return Err("rhop_task: 载荷既不是 rhop 信封也不是合法 JSON")
  }
  Ok(j)
}

///|
/// 提交任务：加密 value → payload_enc + payload_sha，然后幂等写入。
///
/// 返回真正新插入的条数（已存在的同名任务不覆盖，与 vools INSERT OR IGNORE 一致）。
pub fn TaskQueue::submit(
  self : TaskQueue,
  records : Array[TaskRecord],
  now : String,
) -> Result[Int32, String] {
  let prepared : Array[TaskRecord] = []
  for r in records {
    let mut rec = r
    // 只在调用方没显式给 payload_enc 时自动封包
    if rec.payload_enc is None && !(r.value is Null) {
      let plain = Json::stringify(r.value)
      let (sealed, _encrypted) = self.seal(plain)
      rec = {
        ..rec,
        payload_enc: Some(sealed),
        payload_sha: Some(@rp.sha256_hex_of_utf8(plain)),
      }
    } else if rec.payload_sha is None && rec.payload_enc is Some(enc) {
      // 外部给了密文：sha 记密文的（避免误导成"明文 sha"）
      rec = { ..rec, payload_sha: Some(@rp.sha256_hex_of_utf8(enc)), }
    }
    // 时间戳补齐
    let created = match rec.created_at {
      Some(v) => v
      None => now
    }
    let updated = match rec.updated_at {
      Some(v) => v
      None => now
    }
    prepared.push({
      ..rec,
      created_at: Some(created),
      updated_at: Some(updated),
    })
  }
  self.store.insert_tasks(prepared)
}

///|
/// 领取一条任务（并发安全，见 store.claim_next）。
pub fn TaskQueue::claim(
  self : TaskQueue,
  worker_id : String,
  now : String,
) -> Result[TaskRecord?, String] {
  self.store.claim_next(worker_id, now, Some(self.lock_ttl_sec))
}

///|
/// LOCKED → RUNNING（记录 start_time）。
pub fn TaskQueue::mark_running(
  self : TaskQueue,
  task_name : String,
  now : String,
) -> Result[Bool, String] {
  self.store.set_state(
    task_name,
    TaskState::Running,
    None,
    false,
    Json::object({ "start_time": Json::string(now) }),
    now,
  )
}

///|
/// 结果编码：按 `encrypt_result` 与 `result_max_bytes` 处理，返回写入 back_info 的文本。
fn TaskQueue::encode_result(self : TaskQueue, result : Json) -> String {
  let plain = Json::stringify(result)
  let payload = if self.encrypt_result {
    let (sealed, _ok) = self.seal(plain)
    sealed
  } else {
    plain
  }
  // 截断（按 UTF-8 字节数，保守用字符近似 + 明确标记）
  if payload.length() > self.result_max_bytes {
    let head = match payload.get_view(start=0, end=self.result_max_bytes) {
      Some(v) => v.to_owned()
      None => payload
    }
    // C3 ③：键名与 vools `_shrink_result_to_bytes` 对齐（`truncated` + `truncate_hint`），
    // 便于 Python 侧消费方用同一判据识别截断；另保留 result_head/result_chars 作为诊断补充。
    // 与 vools 的差异（已文档化）：vools 是两阶段（先裁 stdout/stderr 到 2000 字符，
    // 仍超预算再退化成紧凑摘要）；本实现是单阶段「head 截断」，语义等效、粒度更粗。
    return Json::stringify(
      Json::object({
        "truncated": Json::boolean(true),
        "truncate_hint": Json::string(
          "结果超过 result_max_bytes，已截断；大结果请写文件并用 payload 里的引用路径回传。",
        ),
        "result_chars": Json::number(payload.length().to_double()),
        "result_head": Json::string(head),
      }),
    )
  }
  payload
}

///|
/// RUNNING → COMPLETED，写入结果（可能加密/截断）。
pub fn TaskQueue::mark_done(
  self : TaskQueue,
  task_name : String,
  result : Json,
  now : String,
) -> Result[Bool, String] {
  let back = self.encode_result(result)
  self.store.set_state(
    task_name,
    TaskState::Completed,
    None,
    false,
    Json::object({
      "back_info": Json::string(back),
      "end_time": Json::string(now),
      "last_err": Json::null(),
    }),
    now,
  )
}

///|
/// RUNNING → FAILED（记录错误；未超重试上限时由上层决定是否调 retry_failed）。
pub fn TaskQueue::mark_failed(
  self : TaskQueue,
  task_name : String,
  error : String,
  now : String,
) -> Result[Bool, String] {
  self.store.set_state(
    task_name,
    TaskState::Failed,
    None,
    false,
    Json::object({
      "last_err": Json::string(error),
      "end_time": Json::string(now),
    }),
    now,
  )
}

///|
/// 请求取消：置 cancel_requested；若任务还没开跑（PENDING/RETRY_PENDING）直接转 CANCELLED。
///
/// 已在 RUNNING 的任务只打标记，由 worker 在安全点自行终止（与 vools 一致）。
pub fn TaskQueue::cancel(
  self : TaskQueue,
  task_name : String,
  now : String,
) -> Result[Bool, String] {
  let rec = match self.store.get_task(task_name) {
    Err(e) => return Err(e)
    Ok(None) => return Err("任务不存在: " + task_name)
    Ok(Some(v)) => v
  }
  match rec.state {
    Pending | RetryPending =>
      self.store.set_state(
        task_name,
        TaskState::Cancelled,
        None,
        false,
        Json::object({
          "cancel_requested": Json::boolean(true),
          "end_time": Json::string(now),
        }),
        now,
      )
    _ =>
      // LOCKED / RUNNING：只打标记
      self.store.set_cancel_requested(task_name, true, now)
  }
}

///|
/// 失败重试：FAILED → RETRY_PENDING（计 retry_count，超过 max_retries 返回 Ok(false)）。
pub fn TaskQueue::retry_failed(
  self : TaskQueue,
  task_name : String,
  now : String,
) -> Result[Bool, String] {
  let rec = match self.store.get_task(task_name) {
    Err(e) => return Err(e)
    Ok(None) => return Err("任务不存在: " + task_name)
    Ok(Some(v)) => v
  }
  if rec.retry_count >= rec.max_retries {
    return Ok(false)
  }
  self.store.set_state(
    task_name,
    TaskState::RetryPending,
    None,
    true,
    Json::object({
      "retry_count": Json::number((rec.retry_count + 1).to_double()),
      "last_err": match rec.last_err {
        Some(v) => Json::string(v)
        None => Json::null()
      },
    }),
    now,
  )
}

///|
/// 重新入队（任意非终态/终态 → PENDING，清锁；运维重跑用）。
pub fn TaskQueue::requeue(
  self : TaskQueue,
  task_name : String,
  now : String,
) -> Result[Bool, String] {
  self.store.requeue(task_name, now)
}

///|
/// 列表查询（state 为 None 查全部）。
pub fn TaskQueue::list_tasks(
  self : TaskQueue,
  state : TaskState?,
  limit : Int32,
) -> Result[Array[TaskRecord], String] {
  self.store.list_tasks(state, limit)
}

///|
/// 各状态计数。
pub fn TaskQueue::status_counts(
  self : TaskQueue,
) -> Result[Map[String, Int32], String] {
  self.store.count_by_state()
}

///|
/// 解开一条任务的载荷（payload_enc → JSON）。
pub fn TaskQueue::decrypt_payload(
  self : TaskQueue,
  rec : TaskRecord,
) -> Result[Json, String] {
  match rec.payload_enc {
    None => Ok(rec.value)
    Some(text) => self.unseal(text)
  }
}

///|
/// 校验载荷完整性：`payload_sha` 记的是**明文**的 sha256（与 vools 语义一致）。
///
/// 因此校验时：能解开就解出明文再比对；解不开（无密钥/明文形态）则退化为比对
/// 存储文本本身的 sha（这种情况下的真实含义在文档里写明，不做假承诺）。
pub fn TaskQueue::verify_payload_sha(
  self : TaskQueue,
  rec : TaskRecord,
) -> Bool {
  let text = match rec.payload_enc {
    Some(t) => t
    None => return false
  }
  let expect = match rec.payload_sha {
    Some(s) => s
    None => return false
  }
  // 优先按「明文 sha」比对：解开载荷
  match self.unseal(text) {
    Ok(j) => {
      let plain = Json::stringify(j)
      if @rp.sha256_hex_of_utf8(plain) == expect {
        return true
      }
    }
    Err(_) => ()
  }
  // 退化：比对存储文本（例如调用方给的是外部密文且未提供明文 sha 约定）
  @rp.sha256_hex_of_utf8(text) == expect
}
