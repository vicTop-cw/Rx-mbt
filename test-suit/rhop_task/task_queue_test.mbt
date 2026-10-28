// ============================================================================
// rhop_task · 队列层测试（js 目标）
//
// 覆盖：提交（载荷加密/明文两种）、claim→running→done 全链路、结果加密与截断、
//       失败与重试（含超限）、取消（未开跑 vs 运行中）、状态计数、载荷完整性。
// ============================================================================

///|
extern "js" fn ffi_qt_mkdtemp(prefix : String) -> String =
  #| (prefix) => { try { const G = globalThis; if (!G.__rxmbt_tmp_reg) { G.__rxmbt_tmp_reg = new Set(); } if (!G.__rxmbt_tmp_hook) { G.__rxmbt_tmp_hook = true; process.on("exit", () => { try { const fsm = process.getBuiltinModule("node:fs"); for (const d of G.__rxmbt_tmp_reg) { try { fsm.rmSync(d, { recursive: true, force: true }); } catch (_e) {} } G.__rxmbt_tmp_reg.clear(); } catch (_e2) {} }); } const fs = process.getBuiltinModule("node:fs"); const os = process.getBuiltinModule("node:os"); const path = process.getBuiltinModule("node:path"); const d = fs.mkdtempSync(path.join(os.tmpdir(), String(prefix) + "-")); G.__rxmbt_tmp_reg.add(d); return d; } catch (_e) { return ""; } }

///|
extern "js" fn ffi_qt_join(dir : String, name : String) -> String =
  #| (dir, name) => { try { return process.getBuiltinModule("node:path").join(String(dir), String(name)); } catch (_e) { return String(dir) + "/" + String(name); } }

///|
extern "js" fn ffi_qt_rmrf(p : String) -> Unit =
  #| (p) => { try { process.getBuiltinModule("node:fs").rmSync(String(p), { recursive: true, force: true }); } catch (_e) {} }

///|
/// 开一个队列（可带密钥）。
fn open_queue(
  with_key : Bool,
  max_result_bytes : Int32,
) -> (@rt.TaskQueue, String) raise {
  let dir = ffi_qt_mkdtemp("rhop-queue")
  let db = ffi_qt_join(dir, "q.db")
  let spec = match @rt.TaskStoreSpec::for_kind("sqlite-local", db) {
    Ok(v) => v
    Err(e) => fail("spec: \{e}")
  }
  let store = match @rt.SqliteTaskStore::open(spec) {
    Ok(v) => v
    Err(e) => fail("open: \{e}")
  }
  let crypto = if with_key {
    Some(@rp.RhopCrypto::from_key("queue-test-key"))
  } else {
    None
  }
  (@rt.TaskQueue::new(store, crypto, 900.0, with_key, max_result_bytes), dir)
}

///|
test "queue · 提交时加密载荷 + 解密还原 + sha 完整性" {
  let (q, dir) = open_queue(true, 65536)
  assert_true(@rt.TaskQueue::crypto_enabled(q))
  let now = @rt.utcnow_iso()
  let payload = @json.parse("{\"cmd\": \"jump.probe\", \"n\": 7}") catch {
    _ => fail("x")
  }
  let rec = @rt.TaskRecord::new("p1").with_value(payload)
  assert_eq(@rt.TaskQueue::submit(q, [rec], now), Ok(1))
  let got = match @rt.TaskQueue::store_of(q).get_task("p1") {
    Ok(Some(v)) => v
    _ => fail("p1 未写入")
  }
  // 载荷被加密成 rhop 信封（含 alg=fernet），且 sha 已记
  match got.payload_enc {
    Some(enc) => {
      assert_true(enc.contains("\"alg\""))
      assert_true(enc.contains("\"fernet\""))
    }
    None => fail("payload_enc 应为密文")
  }
  assert_true(got.payload_sha is Some(_))
  assert_true(@rt.TaskQueue::verify_payload_sha(q, got))
  // 解密还原
  match @rt.TaskQueue::decrypt_payload(q, got) {
    Ok(j) => assert_eq(Json::stringify(j), Json::stringify(payload))
    Err(e) => fail("解密失败: \{e}")
  }
  // 篡改密文后 sha 校验失败
  let tampered = {
    ..got,
    payload_enc: Some("{\"v\": 1, \"alg\": \"fernet\", \"ct\": \"AAAA\"}"),
  }
  assert_false(@rt.TaskQueue::verify_payload_sha(q, tampered))
  @rt.TaskQueue::close(q)
  ffi_qt_rmrf(dir)
}

///|
test "queue · 无密钥时载荷以明文存（不假装加密）" {
  let (q, dir) = open_queue(false, 65536)
  assert_false(@rt.TaskQueue::crypto_enabled(q))
  let now = @rt.utcnow_iso()
  let payload = @json.parse("{\"a\": 1}") catch { _ => fail("x") }
  assert_eq(
    @rt.TaskQueue::submit(
      q,
      [@rt.TaskRecord::new("p2").with_value(payload)],
      now,
    ),
    Ok(1),
  )
  let got = match @rt.TaskQueue::store_of(q).get_task("p2") {
    Ok(Some(v)) => v
    _ => fail("p2 未写入")
  }
  match got.payload_enc {
    Some(enc) => {
      // 明文 JSON（可被直接解析），不是信封
      assert_true(enc.contains("\"a\""))
      assert_false(enc.contains("fernet"))
      let back = @json.parse(enc) catch {
        _ => fail("明文载荷应可解析")
      }
      assert_eq(Json::stringify(back), Json::stringify(payload))
    }
    None => fail("payload_enc 应有明文")
  }
  @rt.TaskQueue::close(q)
  ffi_qt_rmrf(dir)
}

///|
test "queue · claim → running → done 全链路（结果加密）" {
  let (q, dir) = open_queue(true, 65536)
  let now = @rt.utcnow_iso()
  assert_eq(
    @rt.TaskQueue::submit(
      q,
      [@rt.TaskRecord::new("run1").with_value(Json::string("x"))],
      now,
    ),
    Ok(1),
  )
  // claim
  let claimed = match @rt.TaskQueue::claim(q, "w1", now) {
    Ok(Some(v)) => v
    Ok(None) => fail("应领到 run1")
    Err(e) => fail("claim: \{e}")
  }
  assert_eq(claimed.task_name, "run1")
  assert_eq(claimed.state, @rt.TaskState::Locked)
  // running
  assert_eq(@rt.TaskQueue::mark_running(q, "run1", now), Ok(true))
  // done（结果加密）
  let result = @json.parse("{\"ok\": true, \"out\": \"你好\"}") catch {
    _ => fail("x")
  }
  assert_eq(@rt.TaskQueue::mark_done(q, "run1", result, now), Ok(true))
  let done = match @rt.TaskQueue::store_of(q).get_task("run1") {
    Ok(Some(v)) => v
    _ => fail("run1 丢失")
  }
  assert_eq(done.state, @rt.TaskState::Completed)
  assert_true(done.start_time is Some(_))
  assert_true(done.end_time is Some(_))
  // 结果是密文，可用同一 crypto 解回
  match done.back_info {
    Some(back) => {
      assert_true(back.contains("fernet"))
      let crypto = @rp.RhopCrypto::from_key("queue-test-key")
      let r = crypto.decrypt_verify(back)
      assert_true(r.ok)
      match r.payload {
        Some(p) => assert_eq(Json::stringify(p), Json::stringify(result))
        None => fail("结果解密无内容")
      }
    }
    None => fail("back_info 应有结果")
  }
  @rt.TaskQueue::close(q)
  ffi_qt_rmrf(dir)
}

///|
test "queue · 结果超限截断（带 __truncated__ 标记）" {
  let (q, dir) = open_queue(false, 40)
  let now = @rt.utcnow_iso()
  assert_eq(@rt.TaskQueue::submit(q, [@rt.TaskRecord::new("big")], now), Ok(1))
  let _ = @rt.TaskQueue::claim(q, "w1", now)
  let _ = @rt.TaskQueue::mark_running(q, "big", now)
  let long = Json::string("x".repeat(500))
  assert_eq(@rt.TaskQueue::mark_done(q, "big", long, now), Ok(true))
  let rec = match @rt.TaskQueue::store_of(q).get_task("big") {
    Ok(Some(v)) => v
    _ => fail("big 丢失")
  }
  match rec.back_info {
    Some(back) => {
      assert_true(back.contains("\"truncated\":true"))
      assert_true(back.contains("truncate_hint"))
      // 截断后的整体长度受控
      assert_true(back.length() < 400)
    }
    None => fail("back_info 应有截断结果")
  }
  @rt.TaskQueue::close(q)
  ffi_qt_rmrf(dir)
}

///|
test "queue · 失败与重试（含超限返回 false）" {
  let (q, dir) = open_queue(false, 65536)
  let now = @rt.utcnow_iso()
  let rec = @rt.TaskRecord::new("f1").with_max_retries(1)
  assert_eq(@rt.TaskQueue::submit(q, [rec], now), Ok(1))
  let _ = @rt.TaskQueue::claim(q, "w1", now)
  let _ = @rt.TaskQueue::mark_running(q, "f1", now)
  assert_eq(@rt.TaskQueue::mark_failed(q, "f1", "模拟失败", now), Ok(true))
  match @rt.TaskQueue::store_of(q).get_task("f1") {
    Ok(Some(r)) => {
      assert_eq(r.state, @rt.TaskState::Failed)
      assert_eq(r.last_err, Some("模拟失败"))
    }
    _ => fail("f1 丢失")
  }
  // 第一次重试：允许（retry_count 0 → 1）
  assert_eq(@rt.TaskQueue::retry_failed(q, "f1", now), Ok(true))
  match @rt.TaskQueue::store_of(q).get_task("f1") {
    Ok(Some(r)) => {
      assert_eq(r.state, @rt.TaskState::RetryPending)
      assert_eq(r.retry_count, 1)
    }
    _ => fail("f1 丢失")
  }
  // 再失败 → 已达上限（max_retries=1）→ retry_failed 返回 false
  let _ = @rt.TaskQueue::claim(q, "w1", now)
  let _ = @rt.TaskQueue::mark_running(q, "f1", now)
  let _ = @rt.TaskQueue::mark_failed(q, "f1", "再失败", now)
  assert_eq(@rt.TaskQueue::retry_failed(q, "f1", now), Ok(false))
  @rt.TaskQueue::close(q)
  ffi_qt_rmrf(dir)
}

///|
test "queue · 取消：未开跑直接 CANCELLED；运行中只打标记" {
  let (q, dir) = open_queue(false, 65536)
  let now = @rt.utcnow_iso()
  assert_eq(
    @rt.TaskQueue::submit(
      q,
      [@rt.TaskRecord::new("c1"), @rt.TaskRecord::new("c2")],
      now,
    ),
    Ok(2),
  )
  // c1 还没被领：直接取消
  assert_eq(@rt.TaskQueue::cancel(q, "c1", now), Ok(true))
  match @rt.TaskQueue::store_of(q).get_task("c1") {
    Ok(Some(r)) => assert_eq(r.state, @rt.TaskState::Cancelled)
    _ => fail("c1 丢失")
  }
  // c2 领走后取消：只打标记，状态不变
  let _ = @rt.TaskQueue::claim(q, "w1", now)
  assert_eq(@rt.TaskQueue::cancel(q, "c2", now), Ok(true))
  match @rt.TaskQueue::store_of(q).get_task("c2") {
    Ok(Some(r)) => {
      assert_eq(r.state, @rt.TaskState::Locked)
      assert_true(r.cancel_requested)
    }
    _ => fail("c2 丢失")
  }
  // 不存在
  match @rt.TaskQueue::cancel(q, "ghost", now) {
    Err(e) => assert_true(e.contains("任务不存在"))
    Ok(_) => fail("不存在应当 Err")
  }
  @rt.TaskQueue::close(q)
  ffi_qt_rmrf(dir)
}

///|
test "queue · 状态计数与列表" {
  let (q, dir) = open_queue(false, 65536)
  let now = @rt.utcnow_iso()
  assert_eq(
    @rt.TaskQueue::submit(
      q,
      [
        @rt.TaskRecord::new("a"),
        @rt.TaskRecord::new("b"),
        @rt.TaskRecord::new("c"),
      ],
      now,
    ),
    Ok(3),
  )
  let _ = @rt.TaskQueue::claim(q, "w1", now)
  let counts = match @rt.TaskQueue::status_counts(q) {
    Ok(v) => v
    Err(e) => fail("counts: \{e}")
  }
  assert_eq(counts.get_or_default("PENDING", 0), 2)
  assert_eq(counts.get_or_default("LOCKED", 0), 1)
  let locked = match
    @rt.TaskQueue::list_tasks(q, Some(@rt.TaskState::Locked), 10) {
    Ok(v) => v
    Err(e) => fail("list: \{e}")
  }
  assert_eq(locked.length(), 1)
  @rt.TaskQueue::close(q)
  ffi_qt_rmrf(dir)
}
