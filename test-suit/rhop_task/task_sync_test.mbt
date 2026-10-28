// ============================================================================
// rhop_task · 加密同步测试（js 目标）
//
// 覆盖：A 端导出 → B 端导入（加密包）闭环、幂等（重复导入全 ignored）、
//       mark_synced 水位（导出后 pending 归零）、版本收敛、无密钥明面包。
// ============================================================================

///|
extern "js" fn ffi_sy_mkdtemp(prefix : String) -> String =
  #| (prefix) => { try { const fs = process.getBuiltinModule("node:fs"); const os = process.getBuiltinModule("node:os"); const path = process.getBuiltinModule("node:path"); return fs.mkdtempSync(path.join(os.tmpdir(), String(prefix) + "-")); } catch (_e) { return ""; } }

///|
extern "js" fn ffi_sy_join(dir : String, name : String) -> String =
  #| (dir, name) => { try { return process.getBuiltinModule("node:path").join(String(dir), String(name)); } catch (_e) { return String(dir) + "/" + String(name); } }

///|
extern "js" fn ffi_sy_rmrf(p : String) -> Unit =
  #| (p) => { try { process.getBuiltinModule("node:fs").rmSync(String(p), { recursive: true, force: true }); } catch (_e) {} }

///|
/// 开一个独立本地库。
fn open_local(name : String) -> (@rt.SqliteTaskStore, String) raise {
  let dir = ffi_sy_mkdtemp("rhop-sync-" + name)
  let db = ffi_sy_join(dir, name + ".db")
  let spec = match @rt.TaskStoreSpec::for_kind("sqlite-local", db) {
    Ok(v) => v
    Err(e) => fail("spec: \{e}")
  }
  let store = match @rt.SqliteTaskStore::open(spec) {
    Ok(v) => v
    Err(e) => fail("open: \{e}")
  }
  (store, dir)
}

///|
test "sync · A 导出加密包 → B 导入收敛（幂等）" {
  let (sa, da) = open_local("A")
  let (sb, db) = open_local("B")
  let now = @rt.utcnow_iso()
  let crypto_a = @rp.RhopCrypto::from_key("sync-key")
  let crypto_b = @rp.RhopCrypto::from_key("sync-key")
  let sync_a = @rt.TaskSync::new(sa, Some(crypto_a), "peer-B")
  let sync_b = @rt.TaskSync::new(sb, Some(crypto_b), "peer-A")
  // A 端写两条任务
  assert_eq(
    @rt.SqliteTaskStore::insert_tasks(sa, [
      @rt.TaskRecord::new("t1"),
      @rt.TaskRecord::new("t2").with_priority(3),
    ]),
    Ok(2),
  )
  // 导出：应为加密包
  let pack = match @rt.TaskSync::export_pending(sync_a, 10, now) {
    Err(e) => fail("导出失败: \{e}")
    Ok(v) => v
  }
  match pack {
    { "encrypted": True, "enc": String(enc), "count": Number(c, ..), .. } => {
      assert_eq(c, 2.0)
      assert_true(enc.contains("fernet"))
    }
    _ => fail("导出包应为加密形态: " + Json::stringify(pack))
  }
  // B 导入
  match @rt.TaskSync::import_pack(sync_b, pack) {
    Err(e) => fail("导入失败: \{e}")
    Ok(stats) =>
      match stats {
        { "inserted": Number(i, ..), "total": Number(t, ..), .. } => {
          assert_eq(i, 2.0)
          assert_eq(t, 2.0)
        }
        _ => fail("导入统计异常")
      }
  }
  // B 端应有一模一样的两条
  assert_eq(@rt.SqliteTaskStore::all_task_names(sb), Ok(["t1", "t2"]))
  // 幂等：同一包再导入 → 全 ignored
  match @rt.TaskSync::import_pack(sync_b, pack) {
    Err(e) => fail("重复导入失败: \{e}")
    Ok(stats) =>
      match stats {
        { "ignored": Number(ig, ..), "inserted": Number(i, ..), .. } => {
          assert_eq(ig, 2.0)
          assert_eq(i, 0.0)
        }
        _ => fail("统计异常")
      }
  }
  @rt.SqliteTaskStore::close(sa)
  @rt.SqliteTaskStore::close(sb)
  ffi_sy_rmrf(da)
  ffi_sy_rmrf(db)
}

///|
test "sync · mark_synced 水位：导出后 pending 归零、再导出为空包" {
  let (sa, da) = open_local("A2")
  let now = @rt.utcnow_iso()
  let sync = @rt.TaskSync::new(sa, None, "peer-X")
  assert_eq(
    @rt.SqliteTaskStore::insert_tasks(sa, [@rt.TaskRecord::new("s1")]),
    Ok(1),
  )
  assert_eq(@rt.TaskSync::pending_count(sync), Ok(1))
  // 导出并标记已同步
  match @rt.TaskSync::export_and_mark(sync, 10, now) {
    Err(e) => fail("导出失败: \{e}")
    Ok(pair) => assert_eq(pair.1, 1)
  }
  assert_eq(@rt.TaskSync::pending_count(sync), Ok(0))
  // 再导出：empty
  let pack2 = match @rt.TaskSync::export_pending(sync, 10, now) {
    Err(e) => fail("导出失败: \{e}")
    Ok(v) => v
  }
  match pack2 {
    { "count": Number(c, ..), .. } => assert_eq(c, 0.0)
    _ => fail("空包结构异常")
  }
  @rt.SqliteTaskStore::close(sa)
  ffi_sy_rmrf(da)
}

///|
test "sync · 无密钥时走明面包（字段显式标注 encrypted=false）" {
  let (sa, da) = open_local("A3")
  let (sb, db) = open_local("B3")
  let now = @rt.utcnow_iso()
  let sync_a = @rt.TaskSync::new(sa, None, "peer-B")
  let sync_b = @rt.TaskSync::new(sb, None, "peer-A")
  assert_eq(
    @rt.SqliteTaskStore::insert_tasks(sa, [@rt.TaskRecord::new("plain1")]),
    Ok(1),
  )
  let pack = match @rt.TaskSync::export_pending(sync_a, 10, now) {
    Err(e) => fail("导出失败: \{e}")
    Ok(v) => v
  }
  match pack {
    { "encrypted": False, "tasks": Array(items), .. } =>
      assert_eq(items.length(), 1)
    _ => fail("无密钥时应为明面包: " + Json::stringify(pack))
  }
  match @rt.TaskSync::import_pack(sync_b, pack) {
    Err(e) => fail("导入失败: \{e}")
    Ok(_) => ()
  }
  assert_eq(@rt.SqliteTaskStore::all_task_names(sb), Ok(["plain1"]))
  @rt.SqliteTaskStore::close(sa)
  @rt.SqliteTaskStore::close(sb)
  ffi_sy_rmrf(da)
  ffi_sy_rmrf(db)
}

///|
test "sync · 版本收敛：对端更高版本覆盖本端" {
  let (sa, da) = open_local("A4")
  let (sb, db) = open_local("B4")
  let now = @rt.utcnow_iso()
  let sync_b = @rt.TaskSync::new(sb, None, "peer-A")
  assert_eq(
    @rt.SqliteTaskStore::insert_tasks(sa, [@rt.TaskRecord::new("v")]),
    Ok(1),
  )
  // B 端已有一条同名的更高版本（state=COMPLETED, version=5）
  let higher = {
    ..@rt.TaskRecord::new("v"),
    version: 5,
    state: @rt.TaskState::Completed,
  }
  assert_eq(@rt.SqliteTaskStore::apply_task(sb, higher), Ok("inserted"))
  // A 端导出（version=1）→ B 导入：应 ignored（不覆盖新版本）
  let pack = match
    @rt.TaskSync::export_pending(@rt.TaskSync::new(sa, None, "peer-B"), 10, now) {
    Err(e) => fail("导出: \{e}")
    Ok(v) => v
  }
  match @rt.TaskSync::import_pack(sync_b, pack) {
    Err(e) => fail("导入: \{e}")
    Ok(stats) =>
      match stats {
        { "ignored": Number(ig, ..), .. } => assert_eq(ig, 1.0)
        _ => fail("统计异常")
      }
  }
  match @rt.SqliteTaskStore::get_task(sb, "v") {
    Ok(Some(rec)) => {
      assert_eq(rec.version, 5)
      assert_eq(rec.state, @rt.TaskState::Completed)
    }
    _ => fail("v 丢失")
  }
  @rt.SqliteTaskStore::close(sa)
  @rt.SqliteTaskStore::close(sb)
  ffi_sy_rmrf(da)
  ffi_sy_rmrf(db)
}

///|
test "sync · 加密包无密钥导入 → 可诊断 Err；坏包结构 → Err" {
  let (sb, db) = open_local("B5")
  let sync_b = @rt.TaskSync::new(sb, None, "peer-A")
  // 加密包但本端没有密钥
  let enc_pack = Json::object({
    "v": Json::number(1.0),
    "encrypted": Json::boolean(true),
    "enc": Json::string("{\"v\": 1, \"alg\": \"fernet\", \"ct\": \"AAAA\"}"),
  })
  match @rt.TaskSync::import_pack(sync_b, enc_pack) {
    Err(e) => assert_true(e.contains("没有主密钥"))
    Ok(_) => fail("无密钥应 Err")
  }
  // 非对象包
  match @rt.TaskSync::import_pack(sync_b, Json::string("nope")) {
    Err(e) => assert_true(e.contains("必须是 JSON 对象"))
    Ok(_) => fail("非对象应 Err")
  }
  @rt.SqliteTaskStore::close(sb)
  ffi_sy_rmrf(db)
}
