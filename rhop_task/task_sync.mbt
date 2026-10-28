// ============================================================================
// rhop_task · 双方各自持库时的加密同步收敛（TaskSync）
//
// 对照 vools.rhop.task.sync：`sqlite-local` 拓扑下 A/B 各持一份库，
// 通过共享介质交换「加密的任务包」，按 version 收敛成"同样的库"。
//
// 协议（MVP，与 vools 同思路）：
//   export_pending → 取出本端「尚未同步给该 peer」的任务，打成
//                    {"v":1,"peer":…,"exported_at":…,"tasks":[…]}
//                    再用主密钥 `RhopCrypto::encrypt_json` 整包加密成 {"enc": "<信封文本>"}
//   import_pack    → 逐条 apply_task（版本新者胜，幂等：旧/同版本计 ignored）
//   mark_synced    → 把已发送的任务名记进 sync_log（版本水位），下次不再重复发送
//
// 幂等性：import 同一包两次，第二次全部 ignored；export 在 mark_synced 之后为空包。
//
// 目标说明：node:sqlite 仅 js；wasm/native 下所有方法返回可诊断 Err。
// ============================================================================

///|
/// 同步器：绑定一个本地库 + 一把主密钥 + 一个对端标识。
pub(all) struct TaskSync {
  /// 本地存储
  store : SqliteTaskStore
  /// 整包加密用的加解密对象（None 时明文传输，字段里显式标注 encrypted=false）
  crypto : @rp.RhopCrypto?
  /// 对端标识（sync_log 的水位按 peer 记）
  peer : String
}

///|
/// 构造。
pub fn TaskSync::new(
  store : SqliteTaskStore,
  crypto : @rp.RhopCrypto?,
  peer : String,
) -> TaskSync {
  { store, crypto, peer, }
}

///|
/// 对端标识。
pub fn TaskSync::peer(self : TaskSync) -> String {
  self.peer
}

///|
/// 待同步任务数（尚未发给该 peer 的）。
pub fn TaskSync::pending_count(self : TaskSync) -> Result[Int32, String] {
  let table = self.store.spec.table
  let rows = match
    self.store.query_all(
      "SELECT COUNT(*) AS n FROM " +
      table +
      " WHERE task_name NOT IN (SELECT task_name FROM " +
      table +
      "_sync_log WHERE peer = ?)",
      [Json::string(self.peer)],
    ) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  match rows {
    [first, ..] =>
      match first {
        { "n": Number(n, ..), .. } => Ok(n.to_int())
        _ => Ok(0)
      }
    [] => Ok(0)
  }
}

///|
/// 取待同步的任务（尚未发给该 peer 的，按 task_id 升序）。
pub fn TaskSync::pending_tasks(
  self : TaskSync,
  limit : Int32,
) -> Result[Array[TaskRecord], String] {
  let table = self.store.spec.table
  let lim = if limit <= 0 { 100 } else { limit }
  let rows = match
    self.store.query_all(
      "SELECT * FROM " +
      table +
      " WHERE task_name NOT IN (SELECT task_name FROM " +
      table +
      "_sync_log WHERE peer = ?) ORDER BY task_id ASC LIMIT ?",
      [Json::string(self.peer), Json::number(lim.to_double())],
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
/// 导出待同步包。
///
/// 有密钥时整包加密（外层信封 `{"v":1,"enc":"<ciphertext_json_text>"}`）；
/// 无密钥时明文（`{"v":1,"encrypted":false,"tasks":[…]}`），字段显式标注不假装。
pub fn TaskSync::export_pending(
  self : TaskSync,
  limit : Int32,
  now : String,
) -> Result[Json, String] {
  let tasks = match self.pending_tasks(limit) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  let names : Array[Json] = []
  let items : Array[Json] = []
  for t in tasks {
    names.push(Json::string(t.task_name))
    items.push(t.to_dict())
  }
  let inner = Json::object({
    "v": Json::number(1.0),
    "peer": Json::string(self.peer),
    "exported_at": Json::string(now),
    "count": Json::number(items.length().to_double()),
    "tasks": Json::array(items),
  })
  let inner_text = Json::stringify(inner)
  match self.crypto {
    Some(c) => {
      let env = c.encrypt_json(inner)
      if env == "" {
        return Err(
          "rhop_task: 导出包加密失败（RhopCrypto::encrypt_json 返回空）",
        )
      }
      Ok(
        Json::object({
          "v": Json::number(1.0),
          "peer": Json::string(self.peer),
          "encrypted": Json::boolean(true),
          "enc": Json::string(env),
          "task_names": Json::array(names),
          "count": Json::number(items.length().to_double()),
        }),
      )
    }
    None =>
      Ok(
        Json::object({
          "v": Json::number(1.0),
          "peer": Json::string(self.peer),
          "encrypted": Json::boolean(false),
          "plain": Json::string(inner_text),
          "tasks": Json::array(items),
          "task_names": Json::array(names),
          "count": Json::number(items.length().to_double()),
        }),
      )
  }
}

///|
/// 解开导入包，返回 `tasks` 数组。
fn TaskSync::unpack(self : TaskSync, pack : Json) -> Result[JsonRows, String] {
  let obj = match pack {
    Object(m) => m
    _ => return Err("rhop_task: 同步包必须是 JSON 对象")
  }
  let encrypted = match obj.get("encrypted") {
    Some(True) => true
    _ => false
  }
  if encrypted {
    let enc = match obj.get("enc") {
      Some(String(s)) => s
      _ => return Err("rhop_task: 加密同步包缺少 enc 字段")
    }
    let c = match self.crypto {
      Some(c) => c
      None =>
        return Err(
          "rhop_task: 同步包是加密的，但本端没有主密钥",
        )
    }
    let r = c.decrypt_verify(enc)
    if !r.ok {
      return Err(
        "rhop_task: 同步包解密失败（reason=" + r.reason + "）",
      )
    }
    let payload = match r.payload {
      Some(p) => p
      None => return Err("rhop_task: 同步包解密后无内容")
    }
    match payload {
      Object(m) =>
        match m.get("tasks") {
          Some(Array(items)) => Ok(items)
          _ => Ok([])
        }
      _ => Err("rhop_task: 同步包解密后不是对象")
    }
  } else {
    match obj.get("tasks") {
      Some(Array(items)) => Ok(items)
      _ =>
        match obj.get("plain") {
          Some(String(s)) => {
            let j = @json.parse(s) catch {
              _ =>
                return Err("rhop_task: 同步包 plain 字段不是合法 JSON")
            }
            match j {
              Object(m) =>
                match m.get("tasks") {
                  Some(Array(items)) => Ok(items)
                  _ => Ok([])
                }
              _ => Err("rhop_task: 同步包 plain 内容不是对象")
            }
          }
          _ => Ok([])
        }
    }
  }
}

///|
/// 导入同步包：逐条按 version 收敛（新者胜），返回统计。
///
/// 返回 `{"inserted":n,"updated":n,"ignored":n,"total":n}`。
pub fn TaskSync::import_pack(
  self : TaskSync,
  pack : Json,
) -> Result[Json, String] {
  let items = match self.unpack(pack) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  let mut inserted = 0
  let mut updated = 0
  let mut ignored = 0
  for item in items {
    let rec = match TaskRecord::from_dict(item) {
      Ok(v) => v
      Err(e) =>
        return Err("rhop_task: 同步包里有一条记录不合法: " + e)
    }
    match self.store.apply_task(rec) {
      Err(e) => return Err(e)
      Ok(action) =>
        match action {
          "inserted" => inserted = inserted + 1
          "updated" => updated = updated + 1
          _ => ignored = ignored + 1
        }
    }
  }
  Ok(
    Json::object({
      "inserted": Json::number(inserted.to_double()),
      "updated": Json::number(updated.to_double()),
      "ignored": Json::number(ignored.to_double()),
      "total": Json::number(items.length().to_double()),
    }),
  )
}

///|
/// 记录「已同步给该 peer」的任务名与版本（下次 export 不再重复发送）。
pub fn TaskSync::mark_synced(
  self : TaskSync,
  task_names : Array[String],
  now : String,
) -> Result[Int32, String] {
  let table = self.store.spec.table
  let mut n = 0
  for name in task_names {
    let rec = match self.store.get_task(name) {
      Err(e) => return Err(e)
      Ok(None) => continue
      Ok(Some(v)) => v
    }
    let sql = "INSERT OR REPLACE INTO " +
      table +
      "_sync_log (peer, task_name, version, synced_at) VALUES (?, ?, ?, ?)"
    match
      self.store.run(sql, [
        Json::string(self.peer),
        Json::string(name),
        Json::number(v_version(rec).to_double()),
        Json::string(now),
      ]) {
      Err(e) => return Err(e)
      Ok(pair) => n = n + pair.0
    }
  }
  Ok(n)
}

///|
/// 一条记录的版本号（收敛判据）。
fn v_version(rec : TaskRecord) -> Int32 {
  rec.version
}

///|
/// 便捷闭环：导出 → （对端导入） → 标记已同步，返回 (包, 发送条数)。
pub fn TaskSync::export_and_mark(
  self : TaskSync,
  limit : Int32,
  now : String,
) -> Result[(Json, Int32), String] {
  let pack = match self.export_pending(limit, now) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  let names : Array[String] = []
  match pack {
    { "task_names": Array(items), .. } =>
      for it in items {
        match it {
          String(s) => names.push(s)
          _ => ()
        }
      }
    _ => ()
  }
  let marked = match self.mark_synced(names, now) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  Ok((pack, marked))
}
