// ============================================================================
// rhop_task · 任务存储（node:sqlite 真实建库）
//
// 对照 vools.rhop.task.store.sqlite_store.SqliteTaskStore。两种拓扑共用同一实现：
//
// | 拓扑           | kind            | journal_mode | synchronous | 语义 |
// |----------------|-----------------|--------------|-------------|------|
// | 单一共享库     | sqlite-shared   | DELETE       | FULL        | A/B 读写同一文件，状态天然一致 |
// | 双方各自持库   | sqlite-local    | WAL          | NORMAL      | 靠 TaskSync 加密包收敛 |
//
// 共享库禁用 WAL：WAL 依赖共享内存映射与可靠文件锁，在网络盘（SMB/NFS）上不可靠。
//
// 并发正确性：claim_next 在 `BEGIN IMMEDIATE` 事务内「选行 + 带状态守卫的 UPDATE（校验
// changes）」——多个 worker（甚至跨机）不会领到同一条任务；锁租约取
// `max(全局 lock_ttl, 该任务 timeout_min*60)`，避免长任务被别的 worker 误判失效而重复执行。
//
// 目标说明：node:sqlite 仅 js 可用；wasm/native 下所有方法返回可诊断 Err（同签名），
// 保证 rhop_task 包在三目标可编译。
// ============================================================================

///|
/// 行数组别名（避免签名里出现 `Result[Array[Json], String]` 这种嵌套方括号，
/// 当前 moon 版本对该形态会解析成比较运算）。
pub type JsonRows = Array[Json]

///|
/// 存储配置（对照 vools TaskStoreSpec 的可配置项）。
pub(all) struct TaskStoreSpec {
  /// 拓扑种类："sqlite-shared" | "sqlite-local"
  kind : String
  /// 数据库文件路径
  path : String
  /// 表名（默认 tasks）
  table : String
  /// journal_mode（shared=DELETE / local=WAL）
  journal_mode : String
  /// synchronous（shared=FULL / local=NORMAL）
  synchronous : String
  /// busy_timeout（秒）
  busy_timeout_sec : Double
  /// 全局锁租约（秒）
  lock_ttl_sec : Double
  /// 一次 claim 的扫描行数上限
  claim_scan_limit : Int
  /// 写重试次数（"database is locked" 退避重试）
  write_retries : Int
  /// 重试退避基数（秒）
  retry_backoff_sec : Double
}

///|
/// 按拓扑构造默认 spec（shared → DELETE/FULL，local → WAL/NORMAL）。
pub fn TaskStoreSpec::for_kind(
  kind : String,
  path : String,
) -> Result[TaskStoreSpec, String] {
  let (journal, synch) = match kind {
    "sqlite-shared" => ("DELETE", "FULL")
    "sqlite-local" => ("WAL", "NORMAL")
    _ =>
      return Err(
        "未知存储拓扑 kind=\"{kind}\"（可用: sqlite-shared / sqlite-local）",
      )
  }
  if path.trim().to_owned() == "" {
    return Err("sqlite 存储必须给 path（数据库文件路径）")
  }
  Ok({
    kind,
    path,
    table: "tasks",
    journal_mode: journal,
    synchronous: synch,
    busy_timeout_sec: 5.0,
    lock_ttl_sec: 900.0,
    claim_scan_limit: 50,
    write_retries: 3,
    retry_backoff_sec: 0.2,
  })
}

///|
/// 表名合法性（防注入：只允许字母数字下划线，且不以数字开头）。
fn validate_identifier(name : String, what : String) -> Result[Unit, String] {
  if name == "" {
    return Err("\{what} 不能为空")
  }
  let n = name.length()
  for i in 0..<n {
    let c = name.get_char(i).unwrap_or(' ')
    let ok = (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c == '_'
    if !ok {
      return Err(
        "\{what} 不合法: \"\{name}\"（只允许字母/数字/下划线）",
      )
    }
  }
  let first = name.get_char(0).unwrap_or(' ')
  if first >= '0' && first <= '9' {
    return Err("\{what} 不合法: \"\{name}\"（不能以数字开头）")
  }
  Ok(())
}

///|
/// 建表 + 索引 SQL（与 vools `schema_sql` 逐列一致；另建 executions/sync_log 两表）。
///
/// 说明：MoonBit 字符串不支持跨行字面量，这里用「行数组 + join 换行符」拼 SQL，
/// 保证一列一行、便于与 vools 的 schema 逐行对照。
pub fn schema_sql(table : String) -> String {
  let idx = "idx_" + table
  let tasks : Array[String] = [
    "CREATE TABLE IF NOT EXISTS " + table + " (",
    "    task_id INTEGER PRIMARY KEY AUTOINCREMENT,",
    "    task_name TEXT NOT NULL UNIQUE,",
    "    task_type TEXT NOT NULL DEFAULT 'CLI',",
    "    value TEXT,",
    "    deps TEXT NOT NULL DEFAULT '[]',",
    "    state TEXT NOT NULL DEFAULT 'PENDING'",
    "      CHECK (state IN ('PENDING','LOCKED','RUNNING','COMPLETED','FAILED','RETRY_PENDING','CANCELLED')),",
    "    priority INTEGER NOT NULL DEFAULT 0,",
    "    timeout_min REAL NOT NULL DEFAULT 60,",
    "    retry_delay_min REAL NOT NULL DEFAULT 5,",
    "    retry_count INTEGER NOT NULL DEFAULT 0,",
    "    max_retries INTEGER NOT NULL DEFAULT 3,",
    "    scheduled_at TEXT,",
    "    worker_id TEXT,",
    "    lock_time TEXT,",
    "    expire_time TEXT,",
    "    start_time TEXT,",
    "    end_time TEXT,",
    "    cancel_requested INTEGER NOT NULL DEFAULT 0,",
    "    version INTEGER NOT NULL DEFAULT 1,",
    "    payload_enc TEXT,",
    "    payload_sha TEXT,",
    "    back_info TEXT,",
    "    last_err TEXT,",
    "    tags TEXT NOT NULL DEFAULT '[]',",
    "    queue TEXT NOT NULL DEFAULT '',",
    "    owner TEXT NOT NULL DEFAULT '',",
    "    team TEXT NOT NULL DEFAULT '',",
    "    group_name TEXT NOT NULL DEFAULT '',",
    "    extra_desc TEXT,",
    "    created_at TEXT NOT NULL,",
    "    updated_at TEXT NOT NULL",
    "  );",
    "CREATE INDEX IF NOT EXISTS " + idx + "_state ON " + table + "(state);",
    "CREATE INDEX IF NOT EXISTS " + idx + "_priority ON " + table + "(priority);",
    "CREATE INDEX IF NOT EXISTS " + idx + "_lock_time ON " + table + "(lock_time);",
    "CREATE INDEX IF NOT EXISTS " + idx + "_scheduled ON " + table + "(scheduled_at);",
    "CREATE INDEX IF NOT EXISTS " + idx + "_worker ON " + table + "(worker_id);",
    "CREATE INDEX IF NOT EXISTS " + idx + "_type ON " + table + "(task_type);",
    "CREATE INDEX IF NOT EXISTS " + idx + "_queue ON " + table + "(queue);",
  ]
  // 执行流水（每次 worker 执行一条）与同步日志（TaskSync 版本水位）
  let aux : Array[String] = [
    "CREATE TABLE IF NOT EXISTS " + table + "_executions (",
    "    exec_id INTEGER PRIMARY KEY AUTOINCREMENT,",
    "    task_name TEXT NOT NULL,",
    "    worker_id TEXT,",
    "    started_at TEXT,",
    "    finished_at TEXT,",
    "    ok INTEGER NOT NULL DEFAULT 0,",
    "    detail TEXT",
    "  );",
    "CREATE TABLE IF NOT EXISTS " + table + "_sync_log (",
    "    peer TEXT NOT NULL,",
    "    task_name TEXT NOT NULL,",
    "    version INTEGER NOT NULL,",
    "    synced_at TEXT NOT NULL,",
    "    PRIMARY KEY (peer, task_name)",
    "  );",
  ]
  let nl = "\n"
  tasks.join(nl) + nl + aux.join(nl)
}

// ---------------------------------------------------------------------------
// 存储对象
// ---------------------------------------------------------------------------

///|
/// SQLite 任务存储（js 目标真实建库；非 js 全部方法可诊断失败）。
pub struct SqliteTaskStore {
  /// 存储配置
  spec : TaskStoreSpec
  /// 打开的数据库句柄 id（0 = 未打开）
  mut db : Int64
  /// 是否已关闭
  mut closed : Bool
}

///|
/// 打开数据库并建表（幂等）。
pub fn SqliteTaskStore::open(
  spec : TaskStoreSpec,
) -> Result[SqliteTaskStore, String] {
  match validate_identifier(spec.table, "表名") {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  let id = sqlite_open(
    spec.path,
    spec.journal_mode,
    spec.synchronous,
    (spec.busy_timeout_sec * 1000.0).to_int(),
  )
  if id < 0L {
    return Err(
      "打开数据库失败 \{spec.path}: \{sqlite_last_error()}",
    )
  }
  let store = { spec, db: id, closed: false }
  match store.init_schema() {
    Err(e) => {
      store.close()
      return Err(e)
    }
    Ok(_) => ()
  }
  Ok(store)
}

///|
/// 建表 + 索引（幂等；与 vools 一样把 user_version 置 1）。
pub fn SqliteTaskStore::init_schema(self : SqliteTaskStore) -> Result[Unit, String] {
  match self.exec(schema_sql(self.spec.table)) {
    Err(e) => return Err("初始化表 \{self.spec.table} 失败: \{e}")
    Ok(_) => ()
  }
  let _ = self.exec("PRAGMA user_version = 1")
  Ok(())
}

///|
/// 关闭数据库（幂等）。
pub fn SqliteTaskStore::close(self : SqliteTaskStore) -> Unit {
  if self.db != 0L {
    sqlite_close(self.db)
    self.db = 0L
  }
  self.closed = true
}

///|
/// 是否已关闭。
pub fn SqliteTaskStore::is_closed(self : SqliteTaskStore) -> Bool {
  self.closed || self.db == 0L
}

///|
/// 表名。
pub fn SqliteTaskStore::table(self : SqliteTaskStore) -> String {
  self.spec.table
}

///|
/// 数据库路径。
pub fn SqliteTaskStore::path(self : SqliteTaskStore) -> String {
  self.spec.path
}

///|
/// 后端自描述（含实际生效的 journal_mode，便于诊断共享盘问题）。
pub fn SqliteTaskStore::describe(self : SqliteTaskStore) -> Json {
  Json::object({
    "kind": Json::string("sqlite"),
    "topology": Json::string(self.spec.kind),
    "path": Json::string(self.spec.path),
    "table": Json::string(self.spec.table),
    "journal_mode": Json::string(self.spec.journal_mode),
    "synchronous": Json::string(self.spec.synchronous),
    "busy_timeout_sec": Json::number(self.spec.busy_timeout_sec),
    "lock_ttl_sec": Json::number(self.spec.lock_ttl_sec),
  })
}

// ---------------------------------------------------------------------------
// 低层 SQL 封装（带 closed 守卫与可诊断 Err）
// ---------------------------------------------------------------------------

///|
/// 执行一条无参数 SQL（DDL / PRAGMA / BEGIN-COMMIT）。
fn SqliteTaskStore::exec(self : SqliteTaskStore, sql : String) -> Result[Unit, String] {
  if self.is_closed() {
    return Err("rhop_task: 数据库已关闭")
  }
  if sqlite_exec(self.db, sql) {
    Ok(())
  } else {
    Err(sqlite_last_error())
  }
}

///|
/// 执行带参数的写语句，返回受影响行数与自增 id。
fn SqliteTaskStore::run(
  self : SqliteTaskStore,
  sql : String,
  params : Array[Json],
) -> Result[(Int, Int64), String] {
  if self.is_closed() {
    return Err("rhop_task: 数据库已关闭")
  }
  let out = sqlite_run(self.db, sql, Json::stringify(Json::array(params)))
  let err = sqlite_last_error()
  if err != "" {
    return Err(err)
  }
  let j = @json.parse(out) catch {
    _ => return Err("rhop_task: sqlite 返回非 JSON: \{out}")
  }
  match j {
    { "changes": Number(c, ..), "lastInsertRowid": Number(r, ..), .. } =>
      Ok((c.to_int(), r.to_int64()))
    _ => Err("rhop_task: sqlite 返回结构意外: \{out}")
  }
}

///|
/// 查询多行（返回 JSON 对象数组；行字段可直接喂 `TaskRecord::from_dict`）。
fn SqliteTaskStore::query_all(
  self : SqliteTaskStore,
  sql : String,
  params : Array[Json],
) -> Result[JsonRows, String] {
  if self.is_closed() {
    return Err("rhop_task: 数据库已关闭")
  }
  let out = sqlite_all(self.db, sql, Json::stringify(Json::array(params)))
  let err = sqlite_last_error()
  if err != "" {
    return Err(err)
  }
  let j = @json.parse(out) catch {
    _ => return Err("rhop_task: sqlite 返回非 JSON: \{out}")
  }
  match j {
    Array(items) => Ok(items)
    _ => Err("rhop_task: sqlite all 应返回数组，实际 \{out}")
  }
}

///|
/// 查询单行。
fn SqliteTaskStore::query_one(
  self : SqliteTaskStore,
  sql : String,
  params : Array[Json],
) -> Result[Json?, String] {
  if self.is_closed() {
    return Err("rhop_task: 数据库已关闭")
  }
  let out = sqlite_get(self.db, sql, Json::stringify(Json::array(params)))
  let err = sqlite_last_error()
  if err != "" {
    return Err(err)
  }
  if out == "" {
    return Ok(None)
  }
  let j = @json.parse(out) catch {
    _ => return Err("rhop_task: sqlite 返回非 JSON: \{out}")
  }
  match j {
    Null => Ok(None)
    other => Ok(Some(other))
  }
}

// ---------------------------------------------------------------------------
// 值转换（与 vools `_to_db_value` 对齐）
// ---------------------------------------------------------------------------

///|
/// 把 TaskRecord 字段值转成 SQLite 可写值：deps/tags → JSON 文本、
/// cancel_requested → 0/1、value → JSON 文本（Null 则 null）、bool → 0/1。
fn to_db_value(column : String, v : Json) -> Json {
  match column {
    "deps" | "tags" =>
      match v {
        Null => Json::string("[]")
        Array(_) => Json::string(Json::stringify(v))
        String(s) => Json::string(s)
        _ => Json::string("[]")
      }
    "cancel_requested" =>
      match v {
        True => Json::number(1.0)
        False => Json::number(0.0)
        Number(n, ..) => Json::number(n)
        _ => Json::number(0.0)
      }
    "value" =>
      match v {
        Null => Json::null()
        String(s) => Json::string(s)
        other => Json::string(Json::stringify(other))
      }
    _ =>
      match v {
        True => Json::number(1.0)
        False => Json::number(0.0)
        other => other
      }
  }
}

// ---------------------------------------------------------------------------
// 写入
// ---------------------------------------------------------------------------

///|
/// 批量幂等写入（INSERT OR IGNORE，按 task_name 去重），返回真正插入的条数。
pub fn SqliteTaskStore::insert_tasks(
  self : SqliteTaskStore,
  records : Array[TaskRecord],
) -> Result[Int, String] {
  if records.length() == 0 {
    return Ok(0)
  }
  // 先校验（空 task_name 直接拒绝，不要让 DB 的 NOT NULL 报难懂的错）
  for r in records {
    if r.task_name == "" {
      return Err("任务缺少 task_name，无法写入")
    }
  }
  let cols = task_columns().filter(fn(c) { c != "task_id" })
  let placeholders = cols.map(fn(_c) { "?" }).join(",")
  let sql = "INSERT OR IGNORE INTO " +
    self.spec.table +
    " (" +
    cols.join(",") +
    ") VALUES (" +
    placeholders +
    ")"
  let now = utcnow_iso()
  let mut inserted = 0
  match self.exec("BEGIN IMMEDIATE") {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  let mut failure : String? = None
  for r in records {
    let d = r.to_dict()
    let created = match r.created_at {
      Some(v) => v
      None => now
    }
    let updated = match r.updated_at {
      Some(v) => v
      None => now
    }
    let params : Array[Json] = []
    for c in cols {
      params.push(
        to_db_value(
          c,
          match c {
            "created_at" => Json::string(created)
            "updated_at" => Json::string(updated)
            _ => jget_or_null(d, c)
          },
        ),
      )
    }
    match self.run(sql, params) {
      Ok(pair) => inserted = inserted + pair.0
      Err(e) => {
        failure = Some(e)
        break
      }
    }
  }
  match failure {
    Some(e) => {
      let _ = self.exec("ROLLBACK")
      Err("写入任务失败: " + e)
    }
    None =>
      match self.exec("COMMIT") {
        Err(e) => Err("写入任务提交失败: " + e)
        Ok(_) => Ok(inserted)
      }
  }
}

///|
/// 从 JSON 对象取字段（缺失 → null）。
fn jget_or_null(obj : Json, key : String) -> Json {
  match obj {
    Object(m) =>
      match m.get(key) {
        Some(v) => v
        None => Json::null()
      }
    _ => Json::null()
  }
}

///|
/// 可写附加列白名单（防止把 task_name 等身份列改掉）。
fn mutable_fields() -> Array[String] {
  [
    "task_type", "value", "deps", "priority", "timeout_min", "retry_delay_min",
    "retry_count", "max_retries", "scheduled_at", "worker_id", "lock_time",
    "expire_time", "start_time", "end_time", "cancel_requested", "payload_enc",
    "payload_sha", "back_info", "last_err", "tags", "queue", "owner", "team",
    "group_name", "extra_desc",
  ]
}

///|
/// 更新状态 + 附加字段（含流转合法性校验与乐观锁）。
///
/// `expect_version`：非 None 时，若库里 version 已经更大则返回 Ok(false)（不覆盖新数据）。
/// `force=true` 跳过流转合法性校验（运维侧重跑）。
pub fn SqliteTaskStore::set_state(
  self : SqliteTaskStore,
  task_name : String,
  state : TaskState,
  expect_version : Int?,
  force : Bool,
  extra : Json,
  now : String,
) -> Result[Bool, String] {
  match self.exec("BEGIN IMMEDIATE") {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  let rows = match self.query_all(
    "SELECT * FROM " + self.spec.table + " WHERE task_name = ?",
    [Json::string(task_name)],
  ) {
    Err(e) => {
      let _ = self.exec("ROLLBACK")
      return Err(e)
    }
    Ok(v) => v
  }
  if rows.length() == 0 {
    let _ = self.exec("ROLLBACK")
    return Err("任务不存在: " + task_name)
  }
  let current = match TaskRecord::from_dict(rows[0]) {
    Ok(v) => v
    Err(e) => {
      let _ = self.exec("ROLLBACK")
      return Err(e)
    }
  }
  match expect_version {
    Some(ev) =>
      if current.version > ev {
        let _ = self.exec("ROLLBACK")
        return Ok(false)
      }
    None => ()
  }
  if !force && current.state != state && !current.state.can_transition(state) {
    let _ = self.exec("ROLLBACK")
    return Err(
      "非法状态流转: \{current.state.to_string()} -> \{state.to_string()} (task \{task_name})",
    )
  }
  // 组装 SET 子句
  let sets : Array[String] = ["state = ?", "version = version + 1", "updated_at = ?"]
  let params : Array[Json] = [Json::string(state.to_string()), Json::string(now)]
  for key in mutable_fields() {
    match extra {
      Object(m) =>
        match m.get(key) {
          Some(v) => {
            sets.push(key + " = ?")
            params.push(to_db_value(key, v))
          }
          None => ()
        }
      _ => ()
    }
  }
  params.push(Json::string(task_name))
  let sql = "UPDATE " +
    self.spec.table +
    " SET " +
    sets.join(", ") +
    " WHERE task_name = ?"
  match self.run(sql, params) {
    Err(e) => {
      let _ = self.exec("ROLLBACK")
      Err("更新任务状态(\{task_name})失败: " + e)
    }
    Ok(pair) =>
      match self.exec("COMMIT") {
        Err(e) => Err("提交失败: " + e)
        Ok(_) => Ok(pair.0 == 1)
      }
  }
}

///|
/// 只改字段不改状态（worker 心跳式刷新用）。
pub fn SqliteTaskStore::update_fields(
  self : SqliteTaskStore,
  task_name : String,
  fields : Json,
  now : String,
) -> Result[Bool, String] {
  match self.exec("BEGIN IMMEDIATE") {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  let exists = match self.query_one(
    "SELECT 1 FROM " + self.spec.table + " WHERE task_name = ?",
    [Json::string(task_name)],
  ) {
    Err(e) => {
      let _ = self.exec("ROLLBACK")
      return Err(e)
    }
    Ok(v) => v
  }
  if exists is None {
    let _ = self.exec("ROLLBACK")
    return Err("任务不存在: " + task_name)
  }
  let sets : Array[String] = ["updated_at = ?", "version = version + 1"]
  let params : Array[Json] = [Json::string(now)]
  for key in mutable_fields() {
    match fields {
      Object(m) =>
        match m.get(key) {
          Some(v) => {
            sets.push(key + " = ?")
            params.push(to_db_value(key, v))
          }
          None => ()
        }
      _ => ()
    }
  }
  params.push(Json::string(task_name))
  let sql = "UPDATE " +
    self.spec.table +
    " SET " +
    sets.join(", ") +
    " WHERE task_name = ?"
  match self.run(sql, params) {
    Err(e) => {
      let _ = self.exec("ROLLBACK")
      Err("更新任务字段(\{task_name})失败: " + e)
    }
    Ok(pair) =>
      match self.exec("COMMIT") {
        Err(e) => Err("提交失败: " + e)
        Ok(_) => Ok(pair.0 == 1)
      }
  }
}

///|
/// 原子领取一条可做的任务（返回 None 表示暂时没活）。
///
/// 语义（对齐 vools）：候选 = state ∈ {PENDING, RETRY_PENDING} 且未请求取消、
/// scheduled_at 已到（或为空），按 priority DESC, task_id ASC 排序；
/// 依赖必须全部 COMPLETED 才可领；领到即置 LOCKED 并写 worker/lock_time/expire_time。
pub fn SqliteTaskStore::claim_next(
  self : SqliteTaskStore,
  worker_id : String,
  now : String,
  lock_ttl_sec : Double?,
) -> Result[TaskRecord?, String] {
  let ttl = match lock_ttl_sec {
    Some(v) => v
    None => self.spec.lock_ttl_sec
  }
  match self.exec("BEGIN IMMEDIATE") {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  // 已完成任务名集合（依赖门控在 MoonBit 侧做，兼容无 JSON1 的 SQLite）
  let done_rows = match self.query_all(
    "SELECT task_name FROM " + self.spec.table + " WHERE state = ?",
    [Json::string("COMPLETED")],
  ) {
    Err(e) => {
      let _ = self.exec("ROLLBACK")
      return Err(e)
    }
    Ok(v) => v
  }
  let done : Map[String, Bool] = Map::new()
  for row in done_rows {
    match row {
      { "task_name": String(n), .. } => done[n] = true
      _ => ()
    }
  }
  let sql = "SELECT * FROM " +
    self.spec.table +
    " WHERE state IN (?, ?) AND cancel_requested = 0 " +
    "AND (scheduled_at IS NULL OR scheduled_at <= ?) " +
    "ORDER BY priority DESC, task_id ASC LIMIT ?"
  let rows = match self.query_all(sql, [
    Json::string("PENDING"),
    Json::string("RETRY_PENDING"),
    Json::string(now),
    Json::number(self.spec.claim_scan_limit.to_double()),
  ]) {
    Err(e) => {
      let _ = self.exec("ROLLBACK")
      return Err(e)
    }
    Ok(v) => v
  }
  let mut picked : TaskRecord? = None
  for row in rows {
    let rec = match TaskRecord::from_dict(row) {
      Ok(v) => v
      Err(_) => continue
    }
    // 依赖门控
    let mut deps_ok = true
    for d in rec.deps {
      if !done.contains(d) {
        deps_ok = false
      }
    }
    if !deps_ok {
      continue
    }
    // 该行的租约：取全局 ttl 与自身 timeout_min 的较大者
    let row_ttl = if ttl > rec.timeout_min * 60.0 {
      ttl
    } else {
      rec.timeout_min * 60.0
    }
    let row_expire = iso_add_seconds(now, row_ttl)
    let upd = "UPDATE " +
      self.spec.table +
      " SET state = ?, worker_id = ?, lock_time = ?, expire_time = ?, " +
      "version = version + 1, updated_at = ? " +
      "WHERE task_id = ? AND state IN (?, ?) AND cancel_requested = 0"
    let params : Array[Json] = [
      Json::string("LOCKED"),
      Json::string(worker_id),
      Json::string(now),
      Json::string(row_expire),
      Json::string(now),
      match rec.task_id {
        Some(v) => v
        None => Json::null()
      },
      Json::string("PENDING"),
      Json::string("RETRY_PENDING"),
    ]
    match self.run(upd, params) {
      Err(e) => {
        let _ = self.exec("ROLLBACK")
        return Err("领取任务失败: " + e)
      }
      Ok(pair) =>
        if pair.0 == 1 {
          picked = Some({
            ..rec,
            state: TaskState::Locked,
            worker_id: Some(worker_id),
            lock_time: Some(now),
            expire_time: Some(row_expire),
            version: rec.version + 1,
            updated_at: Some(now),
          })
          break
        }
    }
  }
  match self.exec("COMMIT") {
    Err(e) => Err("领取任务提交失败: " + e)
    Ok(_) => Ok(picked)
  }
}

///|
/// 回收失效锁：LOCKED/RUNNING 且 expire_time < now 的任务回到 RETRY_PENDING 或 PENDING。
///
/// 与 vools 一致：未超重试上限 → RETRY_PENDING（可再被领），否则 FAILED。
pub fn SqliteTaskStore::clean_stale_locks(
  self : SqliteTaskStore,
  now : String,
) -> Result[Int, String] {
  let sql = "SELECT * FROM " +
    self.spec.table +
    " WHERE state IN (?, ?) AND expire_time IS NOT NULL AND expire_time < ?"
  let rows = match self.query_all(sql, [
    Json::string("LOCKED"),
    Json::string("RUNNING"),
    Json::string(now),
  ]) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  let mut n = 0
  for row in rows {
    let rec = match TaskRecord::from_dict(row) {
      Ok(v) => v
      Err(_) => continue
    }
    let next = if rec.retry_count < rec.max_retries {
      TaskState::RetryPending
    } else {
      TaskState::Failed
    }
    let extra = Json::object({
      "worker_id": Json::null(),
      "lock_time": Json::null(),
      "expire_time": Json::null(),
      "last_err": Json::string("锁过期回收（expire_time 已过）"),
    })
    match self.set_state(rec.task_name, next, None, true, extra, now) {
      Err(_) => ()
      Ok(true) => n = n + 1
      Ok(false) => ()
    }
  }
  Ok(n)
}

///|
/// 重新入队（任意非归档状态 → PENDING，清锁）。
pub fn SqliteTaskStore::requeue(
  self : SqliteTaskStore,
  task_name : String,
  now : String,
) -> Result[Bool, String] {
  let extra = Json::object({
    "worker_id": Json::null(),
    "lock_time": Json::null(),
    "expire_time": Json::null(),
  })
  self.set_state(task_name, TaskState::Pending, None, true, extra, now)
}

///|
/// 置/清「请求取消」标记（真正取消由 worker 在安全点执行）。
pub fn SqliteTaskStore::set_cancel_requested(
  self : SqliteTaskStore,
  task_name : String,
  flag : Bool,
  now : String,
) -> Result[Bool, String] {
  self.update_fields(
    task_name,
    Json::object({ "cancel_requested": Json::boolean(flag) }),
    now,
  )
}

// ---------------------------------------------------------------------------
// 读取
// ---------------------------------------------------------------------------

///|
/// 按 task_name 取一条任务（不存在返回 None）。
pub fn SqliteTaskStore::get_task(
  self : SqliteTaskStore,
  task_name : String,
) -> Result[TaskRecord?, String] {
  let row = match self.query_one(
    "SELECT * FROM " + self.spec.table + " WHERE task_name = ?",
    [Json::string(task_name)],
  ) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  match row {
    None => Ok(None)
    Some(j) =>
      match TaskRecord::from_dict(j) {
        Ok(v) => Ok(Some(v))
        Err(e) => Err(e)
      }
  }
}

///|
/// 取一条任务，不存在直接 Err（便于链式调用）。
pub fn SqliteTaskStore::require_task(
  self : SqliteTaskStore,
  task_name : String,
) -> Result[TaskRecord, String] {
  match self.get_task(task_name) {
    Err(e) => Err(e)
    Ok(None) => Err("任务不存在: " + task_name)
    Ok(Some(v)) => Ok(v)
  }
}

///|
/// 列表查询（state 为 None 时查全部；按优先级降序、id 升序）。
pub fn SqliteTaskStore::list_tasks(
  self : SqliteTaskStore,
  state : TaskState?,
  limit : Int,
) -> Result[Array[TaskRecord], String] {
  let lim = if limit <= 0 { 200 } else { limit }
  let (sql, params) = match state {
    Some(s) => (
      "SELECT * FROM " +
      self.spec.table +
      " WHERE state = ? ORDER BY priority DESC, task_id ASC LIMIT ?",
      [Json::string(s.to_string()), Json::number(lim.to_double())],
    )
    None => (
      "SELECT * FROM " +
      self.spec.table +
      " ORDER BY priority DESC, task_id ASC LIMIT ?",
      [Json::number(lim.to_double())],
    )
  }
  let rows = match self.query_all(sql, params) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  let out : Array[TaskRecord] = []
  for row in rows {
    match TaskRecord::from_dict(row) {
      Ok(v) => out.push(v)
      Err(e) => return Err(e)
    }
  }
  Ok(out)
}

///|
/// 全部任务名。
pub fn SqliteTaskStore::all_task_names(
  self : SqliteTaskStore,
) -> Result[Array[String], String] {
  let rows = match self.query_all(
    "SELECT task_name FROM " +
    self.spec.table +
    " ORDER BY task_id ASC",
    [],
  ) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  let out : Array[String] = []
  for row in rows {
    match row {
      { "task_name": String(n), .. } => out.push(n)
      _ => ()
    }
  }
  Ok(out)
}

///|
/// 各状态任务数（只返回出现过的状态）。
pub fn SqliteTaskStore::count_by_state(
  self : SqliteTaskStore,
) -> Result[Map[String, Int], String] {
  let rows = match self.query_all(
    "SELECT state, COUNT(*) AS n FROM " +
    self.spec.table +
    " GROUP BY state",
    [],
  ) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  let out : Map[String, Int] = Map::new()
  for row in rows {
    match row {
      { "state": String(s), "n": Number(n, ..), .. } => out[s] = n.to_int()
      _ => ()
    }
  }
  Ok(out)
}

///|
/// 活跃任务（非终态）。
pub fn SqliteTaskStore::active_tasks(
  self : SqliteTaskStore,
) -> Result[Array[TaskRecord], String] {
  let rows = match self.query_all(
    "SELECT * FROM " +
    self.spec.table +
    " WHERE state IN (?, ?, ?, ?) ORDER BY priority DESC, task_id ASC",
    [
      Json::string("PENDING"),
      Json::string("LOCKED"),
      Json::string("RUNNING"),
      Json::string("RETRY_PENDING"),
    ],
  ) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  let out : Array[TaskRecord] = []
  for row in rows {
    match TaskRecord::from_dict(row) {
      Ok(v) => out.push(v)
      Err(e) => return Err(e)
    }
  }
  Ok(out)
}

///|
/// 是否全部完成（无活跃任务且有任务）。
pub fn SqliteTaskStore::is_all_done(
  self : SqliteTaskStore,
) -> Result[Bool, String] {
  let active = match self.active_tasks() {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  if active.length() > 0 {
    return Ok(false)
  }
  let total = match self.query_all(
    "SELECT COUNT(*) AS n FROM " + self.spec.table,
    [],
  ) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  match total {
    [first, ..] =>
      match first {
        { "n": Number(n, ..), .. } => Ok(n > 0.0)
        _ => Ok(false)
      }
    [] => Ok(false)
  }
}

///|
/// 汇总快照（CLI `status` 用）。
pub fn SqliteTaskStore::summary(self : SqliteTaskStore) -> Result[Json, String] {
  let counts = match self.count_by_state() {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  let obj : Map[String, Json] = Map::new()
  for s in task_state_all() {
    let key = s.to_string()
    obj[key] = Json::number(counts.get_or_default(key, 0).to_double())
  }
  let all_done = match self.is_all_done() {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  Ok(Json::object({
    "counts": Json::object(obj),
    "is_all_done": Json::boolean(all_done),
    "backend": self.describe(),
  }))
}

///|
/// 应用一条来自同步通道的记录：按 version 收敛（新者胜），幂等。
///
/// 返回 "inserted" / "updated" / "ignored"。
pub fn SqliteTaskStore::apply_task(
  self : SqliteTaskStore,
  rec : TaskRecord,
) -> Result[String, String] {
  match self.get_task(rec.task_name) {
    Err(e) => Err(e)
    Ok(None) => {
      // 新任务：直接插入（insert_tasks 是 INSERT OR IGNORE）
      match self.insert_tasks([rec]) {
        Err(e) => Err(e)
        Ok(n) =>
          if n > 0 {
            Ok("inserted")
          } else {
            Ok("ignored")
          }
      }
    }
    Ok(Some(cur)) =>
      if rec.version <= cur.version {
        // 版本不新：不覆盖（幂等）
        Ok("ignored")
      } else {
        // 新版本：按列覆盖（保持当前状态流转仍走校验，同步场景 force）
        let d = rec.to_dict()
        let extra : Map[String, Json] = Map::new()
        for key in mutable_fields() {
          extra[key] = jget_or_null(d, key)
        }
        // 终态/任意态都可能来自对端，同步路径 force=true
        match self.set_state(
          rec.task_name,
          rec.state,
          None,
          true,
          Json::object(extra),
          match rec.updated_at {
            Some(v) => v
            None => utcnow_iso()
          },
        ) {
          Err(e) => Err(e)
          Ok(true) => Ok("updated")
          Ok(false) => Ok("ignored")
        }
      }
  }
}

// ---------------------------------------------------------------------------
// node:sqlite FFI（js 目标；句柄注册表 + 错误槽）
//
// 约定：
//   - globalThis.__rxmbt_sqlite_reg : Map<number, DatabaseSync>
//   - globalThis.__rxmbt_sqlite_seq : 自增 id（从 1 起；0 是"未打开"哨兵）
//   - globalThis.__rxmbt_sqlite_err : 最近一次失败原因（成功时清空）
//   - 参数统一以 JSON 数组传入，JS 侧展开绑定（只支持 string/number/null/bool）
// ---------------------------------------------------------------------------

///|
/// 打开数据库（返回句柄 id；失败 -1）。
#cfg(target="js")
extern "js" fn ffi_sqlite_open(
  path : String,
  journal_mode : String,
  synchronous : String,
  busy_timeout_ms : Int,
) -> Int64 =
  #| (path, journal, synch, busy) => { const G = globalThis; try { if (!G.__rxmbt_sqlite_reg) { G.__rxmbt_sqlite_reg = new Map(); G.__rxmbt_sqlite_seq = 1; } const sqlite = process.getBuiltinModule("node:sqlite"); const db = new sqlite.DatabaseSync(String(path)); db.exec("PRAGMA busy_timeout = " + Number(busy)); db.exec("PRAGMA journal_mode = " + String(journal)); db.exec("PRAGMA synchronous = " + String(synch)); const id = G.__rxmbt_sqlite_seq++; G.__rxmbt_sqlite_reg.set(id, db); G.__rxmbt_sqlite_err = ""; return BigInt(id); } catch (e) { G.__rxmbt_sqlite_err = String((e && e.message) || e); return BigInt(-1); } }

///|
/// 执行无参数 SQL。
#cfg(target="js")
extern "js" fn ffi_sqlite_exec(id : Int64, sql : String) -> Bool =
  #| (id, sql) => { const G = globalThis; try { const db = G.__rxmbt_sqlite_reg.get(Number(id)); if (!db) { G.__rxmbt_sqlite_err = "database handle not found"; return false; } db.exec(String(sql)); G.__rxmbt_sqlite_err = ""; return true; } catch (e) { G.__rxmbt_sqlite_err = String((e && e.message) || e); return false; } }

///|
/// 执行带参数的写语句，返回 `{"changes":n,"lastInsertRowid":n}`。
#cfg(target="js")
extern "js" fn ffi_sqlite_run(id : Int64, sql : String, params_json : String) -> String =
  #| (id, sql, paramsJson) => { const G = globalThis; try { const db = G.__rxmbt_sqlite_reg.get(Number(id)); if (!db) { G.__rxmbt_sqlite_err = "database handle not found"; return ""; } const params = JSON.parse(String(paramsJson || "[]")).map((v) => (v === undefined ? null : v)); const st = db.prepare(String(sql)); const r = st.run(...params); G.__rxmbt_sqlite_err = ""; return JSON.stringify({ changes: Number(r.changes), lastInsertRowid: Number(r.lastInsertRowid) }); } catch (e) { G.__rxmbt_sqlite_err = String((e && e.message) || e); return ""; } }

///|
/// 查询多行，返回 JSON 数组文本。
#cfg(target="js")
extern "js" fn ffi_sqlite_all(id : Int64, sql : String, params_json : String) -> String =
  #| (id, sql, paramsJson) => { const G = globalThis; try { const db = G.__rxmbt_sqlite_reg.get(Number(id)); if (!db) { G.__rxmbt_sqlite_err = "database handle not found"; return ""; } const params = JSON.parse(String(paramsJson || "[]")).map((v) => (v === undefined ? null : v)); const st = db.prepare(String(sql)); const rows = st.all(...params); G.__rxmbt_sqlite_err = ""; return JSON.stringify(rows); } catch (e) { G.__rxmbt_sqlite_err = String((e && e.message) || e); return ""; } }

///|
/// 查询单行，返回 JSON 对象文本（无行返回空串）。
#cfg(target="js")
extern "js" fn ffi_sqlite_get(id : Int64, sql : String, params_json : String) -> String =
  #| (id, sql, paramsJson) => { const G = globalThis; try { const db = G.__rxmbt_sqlite_reg.get(Number(id)); if (!db) { G.__rxmbt_sqlite_err = "database handle not found"; return ""; } const params = JSON.parse(String(paramsJson || "[]")).map((v) => (v === undefined ? null : v)); const st = db.prepare(String(sql)); const row = st.get(...params); G.__rxmbt_sqlite_err = ""; return (row === undefined || row === null) ? "" : JSON.stringify(row); } catch (e) { G.__rxmbt_sqlite_err = String((e && e.message) || e); return ""; } }

///|
/// 关闭数据库并从注册表移除（幂等）。
#cfg(target="js")
extern "js" fn ffi_sqlite_close(id : Int64) -> Unit =
  #| (id) => { const G = globalThis; if (!G.__rxmbt_sqlite_reg) { return; } const key = Number(id); const db = G.__rxmbt_sqlite_reg.get(key); if (db) { try { db.close(); } catch (_e) {} G.__rxmbt_sqlite_reg.delete(key); } }

///|
/// 取最近一次失败原因。
#cfg(target="js")
extern "js" fn ffi_sqlite_last_error() -> String =
  #| () => { const G = globalThis; if (G.__rxmbt_sqlite_err === undefined) { return ""; } const e = G.__rxmbt_sqlite_err; return String(e); }

///|
/// js：打开数据库。
#cfg(target="js")
fn sqlite_open(
  path : String,
  journal_mode : String,
  synchronous : String,
  busy_timeout_ms : Int,
) -> Int64 {
  ffi_sqlite_open(path, journal_mode, synchronous, busy_timeout_ms)
}

///|
/// 非 js：无 node:sqlite，恒失败（调用方据此返回可诊断 Err）。
#cfg(not(target="js"))
fn sqlite_open(
  path : String,
  journal_mode : String,
  synchronous : String,
  busy_timeout_ms : Int,
) -> Int64 {
  -1L
}

///|
/// js：执行 SQL。
#cfg(target="js")
fn sqlite_exec(id : Int64, sql : String) -> Bool {
  ffi_sqlite_exec(id, sql)
}

///|
/// 非 js：恒失败。
#cfg(not(target="js"))
fn sqlite_exec(id : Int64, sql : String) -> Bool {
  false
}

///|
/// js：写语句。
#cfg(target="js")
fn sqlite_run(id : Int64, sql : String, params_json : String) -> String {
  ffi_sqlite_run(id, sql, params_json)
}

///|
/// 非 js：返回空串（调用方当成错误）。
#cfg(not(target="js"))
fn sqlite_run(id : Int64, sql : String, params_json : String) -> String {
  ""
}

///|
/// js：多行查询。
#cfg(target="js")
fn sqlite_all(id : Int64, sql : String, params_json : String) -> String {
  ffi_sqlite_all(id, sql, params_json)
}

///|
/// 非 js：返回空串。
#cfg(not(target="js"))
fn sqlite_all(id : Int64, sql : String, params_json : String) -> String {
  ""
}

///|
/// js：单行查询。
#cfg(target="js")
fn sqlite_get(id : Int64, sql : String, params_json : String) -> String {
  ffi_sqlite_get(id, sql, params_json)
}

///|
/// 非 js：返回空串。
#cfg(not(target="js"))
fn sqlite_get(id : Int64, sql : String, params_json : String) -> String {
  ""
}

///|
/// js：关闭句柄。
#cfg(target="js")
fn sqlite_close(id : Int64) -> Unit {
  ffi_sqlite_close(id)
}

///|
/// 非 js：空操作。
#cfg(not(target="js"))
fn sqlite_close(id : Int64) -> Unit {
  ()
}

///|
/// js：最近错误。
#cfg(target="js")
fn sqlite_last_error() -> String {
  ffi_sqlite_last_error()
}

///|
/// 非 js：固定错误文案（保证同签名可诊断）。
#cfg(not(target="js"))
fn sqlite_last_error() -> String {
  "rhop_task: node:sqlite 仅 js 目标可用（wasm/native 无数据库能力）"
}
