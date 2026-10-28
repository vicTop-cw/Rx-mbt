// ============================================================================
// rhop_task · 任务队列通用模型（状态机 + 任务记录 + DAG 校验）
//
// 对照 vools.rhop.task.models：
//   - TaskState：7 态状态机（PENDING / LOCKED / RUNNING / COMPLETED / FAILED /
//     RETRY_PENDING / CANCELLED），流转表逐条照抄 models.py 的 _TRANSITIONS；
//   - TaskRecord：与任务表 31 列一一对应的记录（to_dict / from_dict）；
//   - 时间辅助：UTC ISO（秒精度，字符串可直接字典序比较）utcnow_iso /
//     iso_add_seconds / parse_iso / to_iso；
//   - DAG：依赖校验（重复名 / 自依赖 / 缺依赖 / 成环）与拓扑排序。
//
// 与 rhop 协议层的关系（**显式桥接，不重复定义两套语义**）：
//   队列层状态比协议层多 LOCKED（已领取）与 RETRY_PENDING（待重试），
//   少 DONE 之外的东西 —— 两者映射见 TaskState::to_status / TaskState::from_status。
//   桥接的信息差：RETRY_PENDING 在协议层没有对应态，桥接时归入 Pending，
//   故 from_status(to_status(x)) 对 RETRY_PENDING 只能回到 Pending（已在文档与
//   测试中显式标注，不做静默兜底）。
//
// 目标说明：本文件是纯逻辑（无 #cfg），wasm / js / native 三目标通用。
// ============================================================================

// ---------------------------------------------------------------------------
// 1. 状态机
// ---------------------------------------------------------------------------

///|
/// 任务队列状态（vools `TaskState`，7 态；落库/JSON 用大写字面量）。
///
/// 合法流转（逐条照抄 vools `models._TRANSITIONS`）：
///
/// ```text
/// PENDING ──claim──▶ LOCKED ──start──▶ RUNNING ──ok──▶ COMPLETED
///    ▲                  │                 │
///    │               释放/超时           ├─retry(未超限)─▶ RETRY_PENDING ─▶ LOCKED
///    └──────────────────┘                 └─retry 超限──▶ FAILED
/// PENDING / LOCKED / RUNNING ──cancel──▶ CANCELLED
/// ```
pub(all) enum TaskState {
  /// 待领取
  Pending
  /// 已领取（锁定，准备执行）
  Locked
  /// 执行中
  Running
  /// 执行成功（终态）
  Completed
  /// 执行失败（终态）
  Failed
  /// 待重试（回到可领取队列）
  RetryPending
  /// 已取消（终态）
  Cancelled
} derive(Eq, Debug)

///|
/// 序列化为 vools 字面量（大写，落库即此形态）。
pub fn TaskState::to_string(self : TaskState) -> String {
  match self {
    Pending => "PENDING"
    Locked => "LOCKED"
    Running => "RUNNING"
    Completed => "COMPLETED"
    Failed => "FAILED"
    RetryPending => "RETRY_PENDING"
    Cancelled => "CANCELLED"
  }
}

///|
/// 全部合法状态（顺序与 vools `TaskState.ALL` 一致，便于报错文案复现）。
pub fn task_state_all() -> Array[TaskState] {
  [Pending, Locked, Running, Completed, Failed, RetryPending, Cancelled]
}

///|
/// 大小写不敏感地归一状态值；非法值返回可诊断 Err（不做静默回落）。
pub fn TaskState::parse(value : String) -> Result[TaskState, String] {
  let text = value.trim().to_owned().to_upper()
  match text {
    "PENDING" => Ok(Pending)
    "LOCKED" => Ok(Locked)
    "RUNNING" => Ok(Running)
    "COMPLETED" => Ok(Completed)
    "FAILED" => Ok(Failed)
    "RETRY_PENDING" => Ok(RetryPending)
    "CANCELLED" => Ok(Cancelled)
    _ =>
      Err(
        "未知任务状态 \"\{value}\"（可用: PENDING, LOCKED, RUNNING, COMPLETED, FAILED, RETRY_PENDING, CANCELLED）",
      )
  }
}

///|
/// 是否是合法状态值。
pub fn TaskState::is_valid(value : String) -> Bool {
  match TaskState::parse(value) {
    Ok(_) => true
    Err(_) => false
  }
}

///|
/// 是否终态（COMPLETED / FAILED / CANCELLED）。
pub fn TaskState::is_terminal(self : TaskState) -> Bool {
  match self {
    Completed => true
    Failed => true
    Cancelled => true
    _ => false
  }
}

///|
/// 是否「还有事没做完」（驱动整体完成度判断）。
pub fn TaskState::is_active(self : TaskState) -> Bool {
  !self.is_terminal()
}

///|
/// 是否可被 worker 领取（PENDING / RETRY_PENDING）。
pub fn TaskState::is_claimable(self : TaskState) -> Bool {
  match self {
    Pending => true
    RetryPending => true
    _ => false
  }
}

///|
/// 当前状态能否流转到 `next`（vools `TaskState.can_transition`）。
pub fn TaskState::can_transition(self : TaskState, next : TaskState) -> Bool {
  match self {
    Pending => next == Locked || next == Cancelled
    Locked => next == Running || next == Pending || next == Cancelled
    Running =>
      next == Completed ||
      next == Failed ||
      next == RetryPending ||
      next == Cancelled
    RetryPending => next == Locked || next == Cancelled
    // 终态默认不可流转；运维侧重跑由 store 层 force 处理（P2b）
    Completed | Failed | Cancelled => false
  }
}

// ---------------------------------------------------------------------------
// 2. 与 rhop 协议层 TaskStatus 的桥接
// ---------------------------------------------------------------------------

///|
/// 队列状态 → 协议状态（信封里 `status` 字段的取值）。
///
/// 已知信息差：`RetryPending` 在协议层没有对应态，归入 `Pending`（任务确实回到
/// 待领取队列）。反向 `from_status` 无法把它还原成 RetryPending —— 这是显式的
/// 语义损失，不是 bug；需要区分请查记录自身的 `state` 字段。
pub fn TaskState::to_status(self : TaskState) -> @rp.TaskStatus {
  match self {
    Pending => @rp.TaskStatus::Pending
    Locked => @rp.TaskStatus::Claimed
    Running => @rp.TaskStatus::Running
    Completed => @rp.TaskStatus::Done
    Failed => @rp.TaskStatus::Failed
    RetryPending => @rp.TaskStatus::Pending
    Cancelled => @rp.TaskStatus::Cancelled
  }
}

///|
/// 协议状态 → 队列状态（`Claimed` 对应队列层的 `Locked`）。
pub fn TaskState::from_status(status : @rp.TaskStatus) -> TaskState {
  match status {
    @rp.TaskStatus::Pending => Pending
    @rp.TaskStatus::Claimed => Locked
    @rp.TaskStatus::Running => Running
    @rp.TaskStatus::Done => Completed
    @rp.TaskStatus::Failed => Failed
    @rp.TaskStatus::Cancelled => Cancelled
  }
}

///|
/// 桥接是否无损：即 `from_status(to_status(self)) == self`。
/// `RetryPending` 返回 false（协议层无对应态）。
pub fn TaskState::status_roundtrip_exact(self : TaskState) -> Bool {
  TaskState::from_status(self.to_status()) == self
}

// ---------------------------------------------------------------------------
// 3. 时间辅助（UTC ISO，秒精度）
// ---------------------------------------------------------------------------

///|
/// 一天秒数。
const SECS_PER_DAY : Int64 = 86400

///|
/// 数字补零到 2 位。
fn pad2(v : Int64) -> String {
  if v < 10L {
    "0" + v.to_string()
  } else {
    v.to_string()
  }
}

///|
/// 数字补零到 4 位。
fn pad4(v : Int64) -> String {
  let s = v.to_string()
  if s.length() == 1 {
    "000" + s
  } else if s.length() == 2 {
    "00" + s
  } else if s.length() == 3 {
    "0" + s
  } else {
    s
  }
}

///|
/// 公历日期 → 距 1970-01-01 的天数（Howard Hinnant civil_from_days 的逆算法）。
fn days_from_civil(y : Int64, m : Int64, d : Int64) -> Int64 {
  let y2 = if m <= 2L { y - 1L } else { y }
  let era = if y2 >= 0L { y2 / 400L } else { (y2 - 399L) / 400L }
  let yoe = y2 - era * 400L
  let mp = if m > 2L { m - 3L } else { m + 9L }
  let doy = (153L * mp + 2L) / 5L + d - 1L
  let doe = yoe * 365L + yoe / 4L - yoe / 100L + doy
  era * 146097L + doe - 719468L
}

///|
/// 距 1970-01-01 的天数 → 公历 (年, 月, 日)。
fn civil_from_days(z0 : Int64) -> (Int64, Int64, Int64) {
  let z = z0 + 719468L
  let era = if z >= 0L { z / 146097L } else { (z - 146096L) / 146097L }
  let doe = z - era * 146097L
  let yoe = (doe - doe / 1460L + doe / 36524L - doe / 146096L) / 365L
  let y = yoe + era * 400L
  let doy = doe - (365L * yoe + yoe / 4L - yoe / 100L)
  let mp = (5L * doy + 2L) / 153L
  let d = doy - (153L * mp + 2L) / 5L + 1L
  let m = if mp < 10L { mp + 3L } else { mp - 9L }
  let yy = if m <= 2L { y + 1L } else { y }
  (yy, m, d)
}

///|
/// epoch 秒 → `YYYY-MM-DDTHH:MM:SSZ`（UTC，秒精度）。
pub fn format_epoch_seconds(secs : Int64) -> String {
  let mut days = secs / SECS_PER_DAY
  let mut rem = secs % SECS_PER_DAY
  if rem < 0L {
    days = days - 1L
    rem = rem + SECS_PER_DAY
  }
  let (y, m, d) = civil_from_days(days)
  let hh = rem / 3600L
  let mm = rem % 3600L / 60L
  let ss = rem % 60L
  "\{pad4(y)}-\{pad2(m)}-\{pad2(d)}T\{pad2(hh)}:\{pad2(mm)}:\{pad2(ss)}Z"
}

///|
/// 当前 UTC 时间（epoch 秒）。
pub fn utcnow_seconds() -> Int64 {
  @env.now().to_int64() / 1000L
}

///|
/// 当前 UTC 时间的 ISO 文本（形如 `2026-10-21T11:02:50Z`）。
pub fn utcnow_iso() -> String {
  format_epoch_seconds(utcnow_seconds())
}

///|
/// 纯数字串 → Int64（可选前导 `-`；非法返回 None）。
fn parse_int64(text : StringView) -> Int64? {
  let s = text
  if s.length() == 0 {
    return None
  }
  let mut i = 0
  let mut neg = false
  if s.get_char(0) == Some('-') {
    neg = true
    i = 1
  } else if s.get_char(0) == Some('+') {
    i = 1
  }
  if i >= s.length() {
    return None
  }
  let mut acc = 0L
  while i < s.length() {
    match s.get_char(i) {
      Some(c) =>
        if c >= '0' && c <= '9' {
          acc = acc * 10L + (c.to_int().to_int64() - 48L)
        } else {
          return None
        }
      None => return None
    }
    i = i + 1
  }
  if neg {
    Some(-acc)
  } else {
    Some(acc)
  }
}

///|
/// 是否是「epoch 秒」形态的数字文本：`^[+-]?[0-9]+(\.[0-9]+)?$`。
///
/// 必须精确判形，不能只看「含数字和符号」—— 否则 `2026-10-21` 这种日期会被
/// 误当成负数 epoch 秒（静默解析成 1970 附近的错误时间）。
fn is_epoch_number(text : String) -> Bool {
  let n = text.length()
  if n == 0 {
    return false
  }
  let mut i = 0
  if text.get_char(0) == Some('-') || text.get_char(0) == Some('+') {
    i = 1
  }
  let mut digits = 0
  let mut dots = 0
  while i < n {
    match text.get_char(i) {
      Some(c) =>
        if c >= '0' && c <= '9' {
          digits = digits + 1
        } else if c == '.' {
          dots = dots + 1
          if dots > 1 {
            return false
          }
        } else {
          return false
        }
      None => return false
    }
    i = i + 1
  }
  digits > 0
}

///|
/// 把多种时间写法解析为 epoch 秒（UTC），无法识别返回 None。
///
/// 兼容（与 vools `parse_iso` 对齐）：`2026-10-21T11:02:50Z`、带小数秒、
/// 空格分隔、仅日期、以及 epoch 秒的数字文本。
pub fn parse_iso(value : String) -> Int64? {
  let text = value.trim().to_owned()
  if text == "" {
    return None
  }
  // epoch 秒（形如 1700000000 / 1700000000.5 / -100）
  if is_epoch_number(text) {
    let parsed = @json.parse(text) catch { _ => return None }
    match parsed {
      Number(v, ..) => return Some(v.to_int64())
      _ => ()
    }
  }
  // 日期部分 / 时间部分
  let sep_idx = match text.find("T") {
    Some(i) => Some(i)
    None => text.find(" ")
  }
  let (date_part, time_part) = match sep_idx {
    Some(i) => {
      let d = match text.get_view(start=0, end=i) {
        Some(v) => v.to_owned()
        None => ""
      }
      let t = match text.get_view(start=i + 1) {
        Some(v) => v.to_owned()
        None => ""
      }
      (d, t)
    }
    None => (text, "")
  }
  // 去掉末尾 Z
  let date_s = if date_part.has_suffix("Z") {
    match date_part.get_view(start=0, end=date_part.length() - 1) {
      Some(v) => v.to_owned()
      None => date_part
    }
  } else {
    date_part
  }
  let time_s = if time_part.has_suffix("Z") {
    match time_part.get_view(start=0, end=time_part.length() - 1) {
      Some(v) => v.to_owned()
      None => time_part
    }
  } else {
    time_part
  }
  // 日期：YYYY-MM-DD
  let dparts = split_n(date_s, '-')
  if dparts.length() != 3 {
    return None
  }
  let y = match parse_int64(dparts[0]) {
    Some(v) => v
    None => return None
  }
  let mo = match parse_int64(dparts[1]) {
    Some(v) => v
    None => return None
  }
  let dd = match parse_int64(dparts[2]) {
    Some(v) => v
    None => return None
  }
  if mo < 1L || mo > 12L || dd < 1L || dd > 31L {
    return None
  }
  // 时间：HH:MM:SS[.fff]（缺省 0）
  let mut hh = 0L
  let mut mi = 0L
  let mut ss = 0L
  if time_s != "" {
    let tparts = split_n(time_s, ':')
    if tparts.length() < 2 || tparts.length() > 3 {
      return None
    }
    hh = match parse_int64(tparts[0]) {
      Some(v) => v
      None => return None
    }
    mi = match parse_int64(tparts[1]) {
      Some(v) => v
      None => return None
    }
    if tparts.length() == 3 {
      // 秒可能带小数：只取整数部分
      let sec_text = tparts[2]
      let int_part = match sec_text.find(".") {
        Some(i) =>
          match sec_text.get_view(start=0, end=i) {
            Some(v) => v
            None => sec_text
          }
        None => sec_text
      }
      ss = match parse_int64(int_part) {
        Some(v) => v
        None => return None
      }
    }
    if hh > 23L || mi > 59L || ss > 59L || hh < 0L || mi < 0L || ss < 0L {
      return None
    }
  }
  Some(days_from_civil(y, mo, dd) * SECS_PER_DAY + hh * 3600L + mi * 60L + ss)
}

///|
/// 按分隔符切成若干段（保留空段，便于探测非法输入）。
fn split_n(text : StringView, sep : Char) -> Array[String] {
  let out : Array[String] = []
  let sb = StringBuilder::new()
  let n = text.length()
  let mut i = 0
  while i < n {
    match text.get_char(i) {
      Some(c) =>
        if c == sep {
          out.push(sb.to_string())
          sb.reset()
        } else {
          sb.write_char(c)
        }
      None => ()
    }
    i = i + 1
  }
  out.push(sb.to_string())
  out
}

///|
/// 把任意可识别的时间写法归一为 ISO 文本；无法识别返回 None。
pub fn to_iso(value : String) -> String? {
  match parse_iso(value) {
    Some(s) => Some(format_epoch_seconds(s))
    None => None
  }
}

///|
/// 在 ISO 文本上加若干秒（可为负），返回同格式 ISO 文本。
///
/// `base_iso` 为空或无法解析时以当前时间兜底（与 vools 一致）。
pub fn iso_add_seconds(base_iso : String, seconds : Double) -> String {
  let base = match parse_iso(base_iso) {
    Some(s) => s
    None => utcnow_seconds()
  }
  let total = base.to_double() + seconds
  format_epoch_seconds(total.to_int64())
}

// ---------------------------------------------------------------------------
// 4. 任务记录
// ---------------------------------------------------------------------------

///|
/// 任务表列名（store 层与 TaskRecord 共用，保证 INSERT/SELECT 顺序一致）。
pub fn task_columns() -> Array[String] {
  [
    "task_id", "task_name", "task_type", "value", "deps", "state", "priority", "timeout_min",
    "retry_delay_min", "retry_count", "max_retries", "scheduled_at", "worker_id",
    "lock_time", "expire_time", "start_time", "end_time", "cancel_requested", "version",
    "payload_enc", "payload_sha", "back_info", "last_err", "tags", "queue", "owner",
    "team", "group_name", "extra_desc", "created_at", "updated_at",
  ]
}

///|
/// 一条任务记录（与任务表列一一对应，对照 vools `TaskRecord`）。
///
/// `task_name` 是任务身份（唯一键，幂等与依赖引用都用它）；`value` 对齐 vools 的
/// TEXT 语义（数字/布尔落库后读出是文本），结构化参数请放 `payload_enc`。
pub(all) struct TaskRecord {
  /// 自增主键（未落库时为 None）
  task_id : Json?
  /// 任务身份（唯一键；依赖用它的列表表达）
  task_name : String
  /// 任务类型（默认 "CLI"）
  task_type : String
  /// 任务原始参数（TEXT 语义）
  value : Json
  /// 依赖的 task_name 列表
  deps : Array[String]
  /// 任务状态
  state : TaskState
  /// 优先级（大者先）
  priority : Int32
  /// 执行超时（分钟，默认 60）
  timeout_min : Double
  /// 重试间隔（分钟，默认 5）
  retry_delay_min : Double
  /// 已重试次数
  retry_count : Int32
  /// 最大重试次数（默认 3）
  max_retries : Int32
  /// 计划执行时间（ISO）
  scheduled_at : String?
  /// 持有锁的 worker
  worker_id : String?
  /// 加锁时间（ISO）
  lock_time : String?
  /// 锁过期时间（ISO）
  expire_time : String?
  /// 开始执行时间（ISO）
  start_time : String?
  /// 结束时间（ISO）
  end_time : String?
  /// 是否已请求取消
  cancel_requested : Bool
  /// 乐观锁版本
  version : Int32
  /// 加密后的 JSON 载荷（"A 给 B 传的加密 JSON"）
  payload_enc : String?
  /// 明文载荷的 sha256（解密后校验完整性/幂等）
  payload_sha : String?
  /// 执行结果（JSON 文本；encrypt_result=true 时为密文）
  back_info : String?
  /// 最近一次错误
  last_err : String?
  /// 标签
  tags : Array[String]
  /// 队列名
  queue : String
  /// 归属人
  owner : String
  /// 归属团队
  team : String
  /// 分组
  group_name : String
  /// 补充说明
  extra_desc : String?
  /// 创建时间（ISO）
  created_at : String?
  /// 更新时间（ISO）
  updated_at : String?
}

///|
/// 构造一条待领取任务（其余字段取 vools 默认值）。
pub fn TaskRecord::new(task_name : String) -> TaskRecord {
  {
    task_id: None,
    task_name: task_name.trim().to_owned(),
    task_type: "CLI",
    value: Json::null(),
    deps: [],
    state: Pending,
    priority: 0,
    timeout_min: 60.0,
    retry_delay_min: 5.0,
    retry_count: 0,
    max_retries: 3,
    scheduled_at: None,
    worker_id: None,
    lock_time: None,
    expire_time: None,
    start_time: None,
    end_time: None,
    cancel_requested: false,
    version: 1,
    payload_enc: None,
    payload_sha: None,
    back_info: None,
    last_err: None,
    tags: [],
    queue: "",
    owner: "",
    team: "",
    group_name: "",
    extra_desc: None,
    created_at: None,
    updated_at: None,
  }
}

///|
/// 设置任务类型。
pub fn TaskRecord::with_type(
  self : TaskRecord,
  task_type : String,
) -> TaskRecord {
  { ..self, task_type, }
}

///|
/// 设置原始参数。
pub fn TaskRecord::with_value(self : TaskRecord, value : Json) -> TaskRecord {
  { ..self, value, }
}

///|
/// 设置依赖列表（拷贝入结构，避免调用方后续改动影响记录）。
pub fn TaskRecord::with_deps(
  self : TaskRecord,
  deps : Array[String],
) -> TaskRecord {
  { ..self, deps: deps.copy(), }
}

///|
/// 设置优先级。
pub fn TaskRecord::with_priority(
  self : TaskRecord,
  priority : Int32,
) -> TaskRecord {
  { ..self, priority, }
}

///|
/// 设置状态。
pub fn TaskRecord::with_state(
  self : TaskRecord,
  state : TaskState,
) -> TaskRecord {
  { ..self, state, }
}

///|
/// 设置最大重试次数。
pub fn TaskRecord::with_max_retries(
  self : TaskRecord,
  max_retries : Int32,
) -> TaskRecord {
  { ..self, max_retries, }
}

///|
/// 设置执行超时（分钟）。
pub fn TaskRecord::with_timeout_min(
  self : TaskRecord,
  timeout_min : Double,
) -> TaskRecord {
  { ..self, timeout_min, }
}

///|
/// 设置重试间隔（分钟）。
pub fn TaskRecord::with_retry_delay_min(
  self : TaskRecord,
  retry_delay_min : Double,
) -> TaskRecord {
  { ..self, retry_delay_min, }
}

///|
/// 设置加密载荷与明文 sha256。
pub fn TaskRecord::with_payload(
  self : TaskRecord,
  payload_enc : String,
  payload_sha : String,
) -> TaskRecord {
  { ..self, payload_enc: Some(payload_enc), payload_sha: Some(payload_sha), }
}

///|
/// 设置标签。
pub fn TaskRecord::with_tags(
  self : TaskRecord,
  tags : Array[String],
) -> TaskRecord {
  { ..self, tags: tags.copy(), }
}

///|
/// 设置队列名。
pub fn TaskRecord::with_queue(self : TaskRecord, queue : String) -> TaskRecord {
  { ..self, queue, }
}

///|
/// 设置归属人。
pub fn TaskRecord::with_owner(self : TaskRecord, owner : String) -> TaskRecord {
  { ..self, owner, }
}

///|
/// 设置计划执行时间（ISO）。
pub fn TaskRecord::with_scheduled_at(
  self : TaskRecord,
  scheduled_at : String?,
) -> TaskRecord {
  { ..self, scheduled_at, }
}

///|
/// 设置创建时间（ISO）。
pub fn TaskRecord::with_created_at(
  self : TaskRecord,
  created_at : String?,
) -> TaskRecord {
  { ..self, created_at, }
}

///|
/// 是否终态。
pub fn TaskRecord::is_terminal(self : TaskRecord) -> Bool {
  self.state.is_terminal()
}

///|
/// 记录自检：任务身份/参数合法性（空 name、空 type、负超时等都算错）。
///
/// 与 vools 的差异：vools 在 `__post_init__` 里只做 strip 与类型转换，空 name 由
/// 更上层校验；这里把可诊断的校验集中到 `validate()`，调用方按需在写入前调用。
pub fn TaskRecord::validate(self : TaskRecord) -> Result[Unit, String] {
  if self.task_name == "" {
    return Err(
      "TaskRecord: task_name 不能为空（它是任务身份与依赖引用键）",
    )
  }
  if self.task_type == "" {
    return Err(
      "TaskRecord: task_type 不能为空（task_name=\{self.task_name}）",
    )
  }
  if self.timeout_min <= 0.0 {
    return Err(
      "TaskRecord: timeout_min 必须为正（\{self.timeout_min.to_string()}，task_name=\{self.task_name}）",
    )
  }
  if self.retry_delay_min < 0.0 {
    return Err(
      "TaskRecord: retry_delay_min 不能为负（\{self.retry_delay_min.to_string()}）",
    )
  }
  if self.max_retries < 0 {
    return Err(
      "TaskRecord: max_retries 不能为负（\{self.max_retries.to_string()}）",
    )
  }
  if self.retry_count < 0 {
    return Err(
      "TaskRecord: retry_count 不能为负（\{self.retry_count.to_string()}）",
    )
  }
  if self.retry_count > self.max_retries {
    return Err(
      "TaskRecord: retry_count(\{self.retry_count.to_string()}) 不能超过 max_retries(\{self.max_retries.to_string()})",
    )
  }
  if self.version <= 0 {
    return Err(
      "TaskRecord: version 必须为正（\{self.version.to_string()}）",
    )
  }
  for d in self.deps {
    if d.trim().to_owned() == "" {
      return Err(
        "TaskRecord: deps 里含空依赖名（task_name=\{self.task_name}）",
      )
    }
  }
  Ok(())
}

///|
/// 由可选字符串构造 Json 值（None → null）。
fn opt_str_json(v : String?) -> Json {
  match v {
    Some(s) => Json::string(s)
    None => Json::null()
  }
}

///|
/// 由可选字符串构造 `Json?`（保留 None 语义）。
fn json_to_opt_str(v : Json) -> String? {
  match v {
    String(s) => Some(s)
    _ => None
  }
}

///|
/// 导出为 JSON 对象（deps/tags 为数组，字段名与任务表列名一致）。
pub fn TaskRecord::to_dict(self : TaskRecord) -> Json {
  Json::object({
    "task_id": match self.task_id {
      Some(v) => v
      None => Json::null()
    },
    "task_name": Json::string(self.task_name),
    "task_type": Json::string(self.task_type),
    "value": self.value,
    "deps": Json::array(self.deps.map(fn(d) { Json::string(d) })),
    "state": Json::string(self.state.to_string()),
    "priority": Json::number(self.priority.to_double()),
    "timeout_min": Json::number(self.timeout_min),
    "retry_delay_min": Json::number(self.retry_delay_min),
    "retry_count": Json::number(self.retry_count.to_double()),
    "max_retries": Json::number(self.max_retries.to_double()),
    "scheduled_at": opt_str_json(self.scheduled_at),
    "worker_id": opt_str_json(self.worker_id),
    "lock_time": opt_str_json(self.lock_time),
    "expire_time": opt_str_json(self.expire_time),
    "start_time": opt_str_json(self.start_time),
    "end_time": opt_str_json(self.end_time),
    "cancel_requested": Json::boolean(self.cancel_requested),
    "version": Json::number(self.version.to_double()),
    "payload_enc": opt_str_json(self.payload_enc),
    "payload_sha": opt_str_json(self.payload_sha),
    "back_info": opt_str_json(self.back_info),
    "last_err": opt_str_json(self.last_err),
    "tags": Json::array(self.tags.map(fn(t) { Json::string(t) })),
    "queue": Json::string(self.queue),
    "owner": Json::string(self.owner),
    "team": Json::string(self.team),
    "group_name": Json::string(self.group_name),
    "extra_desc": opt_str_json(self.extra_desc),
    "created_at": opt_str_json(self.created_at),
    "updated_at": opt_str_json(self.updated_at),
  })
}

///|
/// 取 JSON 对象里的字符串字段（缺失/null → None；类型不符 → Err）。
fn field_opt_str(
  obj : Map[String, Json],
  key : String,
) -> Result[String?, String] {
  match obj.get(key) {
    None => Ok(None)
    Some(v) =>
      match v {
        Null => Ok(None)
        String(s) => Ok(Some(s))
        _ =>
          Err(
            "TaskRecord: 字段 \{key} 应为字符串，实际 \{Json::stringify(v)}",
          )
      }
  }
}

///|
/// 取 JSON 对象里的整数字段（缺失/null → 默认值；数字的小数部分截断）。
fn field_int(
  obj : Map[String, Json],
  key : String,
  default : Int32,
) -> Result[Int32, String] {
  match obj.get(key) {
    None => Ok(default)
    Some(v) =>
      match v {
        Null => Ok(default)
        Number(n, ..) => Ok(n.to_int())
        String(s) => {
          // 容忍数字被写成字符串（落库 TEXT 列读回的常见形态）
          let parsed = @json.parse(s) catch {
            _ =>
              return Err(
                "TaskRecord: 字段 \{key} 应为数字，实际 \"\{s}\"",
              )
          }
          match parsed {
            Number(n, ..) => Ok(n.to_int())
            _ => Err("TaskRecord: 字段 \{key} 应为数字，实际 \"\{s}\"")
          }
        }
        _ =>
          Err(
            "TaskRecord: 字段 \{key} 应为数字，实际 \{Json::stringify(v)}",
          )
      }
  }
}

///|
/// 取 JSON 对象里的浮点字段（缺失/null → 默认值）。
fn field_double(
  obj : Map[String, Json],
  key : String,
  default : Double,
) -> Result[Double, String] {
  match obj.get(key) {
    None => Ok(default)
    Some(v) =>
      match v {
        Null => Ok(default)
        Number(n, ..) => Ok(n)
        // 容忍数字被写成字符串（落库 TEXT 列读回的常见形态）
        String(s) => {
          let parsed = @json.parse(s) catch {
            _ =>
              return Err(
                "TaskRecord: 字段 \{key} 应为数字，实际 \"\{s}\"",
              )
          }
          match parsed {
            Number(n, ..) => Ok(n)
            _ => Err("TaskRecord: 字段 \{key} 应为数字，实际 \"\{s}\"")
          }
        }
        _ =>
          Err(
            "TaskRecord: 字段 \{key} 应为数字，实际 \{Json::stringify(v)}",
          )
      }
  }
}

///|
/// 取 JSON 对象里的布尔字段（容忍 0/1 与 "true"/"false"）。
fn field_bool(
  obj : Map[String, Json],
  key : String,
  default : Bool,
) -> Result[Bool, String] {
  match obj.get(key) {
    None => Ok(default)
    Some(v) =>
      match v {
        Null => Ok(default)
        True => Ok(true)
        False => Ok(false)
        Number(n, ..) => Ok(n != 0.0)
        String(s) =>
          match s.trim().to_owned().to_lower() {
            "true" | "1" | "yes" => Ok(true)
            "false" | "0" | "no" | "" => Ok(false)
            _ => Err("TaskRecord: 字段 \{key} 应为布尔，实际 \"\{s}\"")
          }
        _ =>
          Err(
            "TaskRecord: 字段 \{key} 应为布尔，实际 \{Json::stringify(v)}",
          )
      }
  }
}

///|
/// 取 JSON 对象里的字符串数组字段（容忍 JSON 文本 / 单值）。
fn field_str_array(
  obj : Map[String, Json],
  key : String,
) -> Result[Array[String], String] {
  let out : Array[String] = []
  match obj.get(key) {
    None => Ok(out)
    Some(v) =>
      match v {
        Null => Ok(out)
        Array(items) => {
          for it in items {
            match it {
              String(s) => out.push(s)
              _ =>
                return Err("TaskRecord: 字段 \{key} 的元素应为字符串")
            }
          }
          Ok(out)
        }
        String(s) => {
          // 落库 TEXT 列读回：JSON 数组文本或单值
          let t = s.trim().to_owned()
          if t == "" {
            return Ok(out)
          }
          let parsed = @json.parse(t) catch {
            _ =>
              return Err(
                "TaskRecord: 字段 \{key} 应为字符串数组，实际 \"\{t}\"",
              )
          }
          match parsed {
            Array(items) => {
              for it in items {
                match it {
                  String(x) => out.push(x)
                  _ =>
                    return Err(
                      "TaskRecord: 字段 \{key} 的元素应为字符串",
                    )
                }
              }
              Ok(out)
            }
            _ => {
              out.push(t)
              Ok(out)
            }
          }
        }
        _ => Err("TaskRecord: 字段 \{key} 应为字符串数组")
      }
  }
}

///|
/// 从 JSON 对象构造记录（缺失字段取默认值；未知状态 / 类型不符返回可诊断 Err）。
pub fn TaskRecord::from_dict(data : Json) -> Result[TaskRecord, String] {
  let obj = match data {
    Object(m) => m
    _ =>
      return Err(
        "TaskRecord: 需要 JSON 对象，实际 \{Json::stringify(data)}",
      )
  }
  let task_name = match field_opt_str(obj, "task_name") {
    Ok(Some(s)) => s.trim().to_owned()
    Ok(None) => ""
    Err(e) => return Err(e)
  }
  let state = match field_opt_str(obj, "state") {
    Ok(Some(s)) =>
      match TaskState::parse(s) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
    Ok(None) => Pending
    Err(e) => return Err(e)
  }
  let deps = match field_str_array(obj, "deps") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let tags = match field_str_array(obj, "tags") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  // 数值/布尔字段（逐个取，任一失败即带字段名报错）
  let priority = match field_int(obj, "priority", 0) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let retry_count = match field_int(obj, "retry_count", 0) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let max_retries = match field_int(obj, "max_retries", 3) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let version = match field_int(obj, "version", 1) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let timeout_min = match field_double(obj, "timeout_min", 60.0) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let retry_delay_min = match field_double(obj, "retry_delay_min", 5.0) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let cancel_requested = match field_bool(obj, "cancel_requested", false) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let task_type = match field_opt_str(obj, "task_type") {
    Ok(Some(s)) => if s == "" { "CLI" } else { s }
    Ok(None) => "CLI"
    Err(e) => return Err(e)
  }
  let task_id = obj.get("task_id")
  let value = match obj.get("value") {
    Some(v) => v
    None => Json::null()
  }
  let mut r = TaskRecord::new(task_name)
  r = r.with_type(task_type)
  r = { ..r, state, deps, tags, priority, retry_count, max_retries, version, }
  r = {
    ..r,
    timeout_min,
    retry_delay_min,
    cancel_requested,
    task_id: match task_id {
      Some(v) =>
        match v {
          Null => None
          _ => Some(v)
        }
      None => None
    },
    value,
  }
  // 可选字符串字段
  for
    key in [
      "scheduled_at", "worker_id", "lock_time", "expire_time", "start_time", "end_time",
      "payload_enc", "payload_sha", "back_info", "last_err", "extra_desc", "created_at",
      "updated_at",
    ] {
    let v = match field_opt_str(obj, key) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    r = match key {
      "scheduled_at" => { ..r, scheduled_at: v, }
      "worker_id" => { ..r, worker_id: v, }
      "lock_time" => { ..r, lock_time: v, }
      "expire_time" => { ..r, expire_time: v, }
      "start_time" => { ..r, start_time: v, }
      "end_time" => { ..r, end_time: v, }
      "payload_enc" => { ..r, payload_enc: v, }
      "payload_sha" => { ..r, payload_sha: v, }
      "back_info" => { ..r, back_info: v, }
      "last_err" => { ..r, last_err: v, }
      "extra_desc" => { ..r, extra_desc: v, }
      "created_at" => { ..r, created_at: v, }
      "updated_at" => { ..r, updated_at: v, }
      _ => r
    }
  }
  for key in ["queue", "owner", "team", "group_name"] {
    let v = match field_opt_str(obj, key) {
      Ok(Some(s)) => s
      Ok(None) => ""
      Err(e) => return Err(e)
    }
    r = match key {
      "queue" => { ..r, queue: v, }
      "owner" => { ..r, owner: v, }
      "team" => { ..r, team: v, }
      "group_name" => { ..r, group_name: v, }
      _ => r
    }
  }
  Ok(r)
}

///|
/// 便捷：从 JSON **文本**构造（解析失败给可诊断 Err）。
pub fn task_record_from_json_text(text : String) -> Result[TaskRecord, String] {
  let j = @json.parse(text) catch {
    _ => return Err("TaskRecord: JSON 解析失败")
  }
  TaskRecord::from_dict(j)
}

///|
/// 便捷：导出为 JSON 文本。
pub fn task_record_to_json_text(record : TaskRecord) -> String {
  Json::stringify(record.to_dict())
}

// ---------------------------------------------------------------------------
// 5. DAG 校验与拓扑排序
// ---------------------------------------------------------------------------

///|
/// 校验一批任务的依赖图：重名 / 自依赖 / 缺依赖 / 成环都返回可诊断 Err。
///
/// 依赖语义与 vools 一致：`deps` 里写的是 **task_name**（不是自增 id）。
pub fn validate_dag(records : Array[TaskRecord]) -> Result[Unit, String] {
  let index : Map[String, TaskRecord] = Map::new()
  for r in records {
    if r.task_name == "" {
      return Err("DAG: 存在 task_name 为空的记录")
    }
    if index.contains(r.task_name) {
      return Err("DAG: 任务名重复: \{r.task_name}")
    }
    index[r.task_name] = r
  }
  for r in records {
    for d in r.deps {
      if d == r.task_name {
        return Err("DAG: 任务 \{r.task_name} 依赖了自己")
      }
      if !index.contains(d) {
        return Err(
          "DAG: 任务 \{r.task_name} 依赖的 \{d} 不在本批次中（缺依赖）",
        )
      }
    }
  }
  // Kahn 拓扑：能排完 = 无环
  match topo_order(records) {
    Ok(_) => Ok(())
    Err(e) => Err(e)
  }
}

///|
/// 拓扑排序（依赖在前）。成环时返回可诊断 Err 并点名环上任务。
///
/// 同层按 task_name 字典序出队，保证结果确定（可复现的测试基线）。
pub fn topo_order(records : Array[TaskRecord]) -> Result[Array[String], String] {
  let index : Map[String, TaskRecord] = Map::new()
  for r in records {
    index[r.task_name] = r
  }
  // 入度 = 未满足的依赖数（只统计本批次内的依赖）
  let indeg : Map[String, Int32] = Map::new()
  for r in records {
    let mut n = 0
    for d in r.deps {
      if index.contains(d) {
        n = n + 1
      }
    }
    indeg[r.task_name] = n
  }
  let out : Array[String] = []
  let done : Map[String, Bool] = Map::new()
  while out.length() < records.length() {
    // 取本层所有入度 0 且未出队的，按名字排序
    let ready : Array[String] = []
    for r in records {
      if !done.contains(r.task_name) &&
        indeg.get_or_default(r.task_name, 0) == 0 {
        ready.push(r.task_name)
      }
    }
    if ready.length() == 0 {
      // 剩下的是环（或依赖了环）
      let left : Array[String] = []
      for r in records {
        if !done.contains(r.task_name) {
          left.push(r.task_name)
        }
      }
      left.sort()
      return Err(
        "DAG: 依赖成环或无解，无法拓扑排序；涉及任务: \{left.join(", ")}",
      )
    }
    ready.sort()
    for name in ready {
      if done.contains(name) {
        continue
      }
      done[name] = true
      out.push(name)
      // 减少依赖它的任务入度
      for r in records {
        if done.contains(r.task_name) {
          continue
        }
        for d in r.deps {
          if d == name {
            indeg[r.task_name] = indeg.get_or_default(r.task_name, 1) - 1
          }
        }
      }
    }
  }
  Ok(out)
}
