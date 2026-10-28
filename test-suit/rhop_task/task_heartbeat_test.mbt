// ============================================================================
// rhop_task · 心跳测试（js 目标：复用 rhop 的 LocalSharedPath 写文件）
//
// 覆盖：beat/read/is_alive、过期判死、closed 标记、缺失文件、时钟偏差、
//       HeartbeatPump 起停（timer 必须 unref，不能成为挂死源）。
// ============================================================================

///|
extern "js" fn ffi_hb_mkdtemp(prefix : String) -> String =
  #| (prefix) => { try { const fs = process.getBuiltinModule("node:fs"); const os = process.getBuiltinModule("node:os"); const path = process.getBuiltinModule("node:path"); return fs.mkdtempSync(path.join(os.tmpdir(), String(prefix) + "-")); } catch (_e) { return ""; } }

///|
extern "js" fn ffi_hb_rmrf(p : String) -> Unit =
  #| (p) => { try { process.getBuiltinModule("node:fs").rmSync(String(p), { recursive: true, force: true }); } catch (_e) {} }

///|
extern "js" fn ffi_hb_pump_count() -> Int32 =
  #| () => { const G = globalThis; if (!G.__rxmbt_pump_reg) { return 0; } let n = 0; for (const _k of G.__rxmbt_pump_reg.keys()) { n++; } return n; }

///|
/// 造一个绑定临时目录的心跳对象。
fn make_hb(dir : String, stale_after : Double) -> @rt.Heartbeat raise {
  let sp : &@rp.SharedPath = @rp.LocalSharedPath::new(dir)
  @rt.Heartbeat::new(
    Some(sp),
    "hb-test.heartbeat",
    0.05,
    stale_after,
    "closed",
    "w-1",
  )
}

///|
test "heartbeat · beat 写入 → read 解析 → is_alive" {
  let dir = ffi_hb_mkdtemp("rhop-hb")
  let hb = make_hb(dir, 30.0)
  let now = @rt.utcnow_iso()
  assert_eq(hb.beat(Some(now)), Ok(()))
  let snap = match hb.read() {
    Ok(Some(v)) => v
    Ok(None) => fail("心跳文件应存在")
    Err(e) => fail("read: \{e}")
  }
  assert_eq(snap.worker_id, "w-1")
  assert_eq(snap.ts, now)
  assert_false(snap.closed)
  assert_true(snap.epoch > 0L)
  // 刚写完 → 存活
  assert_true(hb.is_alive(Some(snap.epoch + 1L)))
  // 超阈值 → 判死
  assert_false(hb.is_alive(Some(snap.epoch + 31L)))
  // check 给可诊断原因
  match hb.check(Some(snap.epoch + 31L)) {
    Ok(pair) => {
      assert_false(pair.0)
      assert_true(pair.1.contains("心跳过期"))
    }
    Err(e) => fail("check: \{e}")
  }
  match hb.check(Some(snap.epoch + 1L)) {
    Ok(pair) => {
      assert_true(pair.0)
      assert_true(pair.1.contains("存活"))
    }
    Err(e) => fail("check: \{e}")
  }
  ffi_hb_rmrf(dir)
}

///|
test "heartbeat · closed 标记 / 缺失文件 / 时钟偏差" {
  let dir = ffi_hb_mkdtemp("rhop-hb2")
  let hb = make_hb(dir, 30.0)
  // 从未写过：不存在 → 不存活 + 可诊断原因
  assert_false(hb.is_alive(None))
  match hb.check(None) {
    Ok(pair) => {
      assert_false(pair.0)
      assert_true(pair.1.contains("不存在"))
    }
    Err(e) => fail("check: \{e}")
  }
  // 写「已下线」标记
  assert_eq(hb.mark_closed(Some(@rt.utcnow_iso())), Ok(()))
  match hb.read() {
    Ok(Some(snap)) => assert_true(snap.closed)
    _ => fail("closed 未写入")
  }
  assert_false(hb.is_alive(None))
  match hb.check(None) {
    Ok(pair) => assert_true(pair.1.contains("下线"))
    Err(e) => fail("check: \{e}")
  }
  // 时钟偏差：心跳时间戳在未来 → 仍判存活但原因里点明偏差
  let hb2 = make_hb(dir, 30.0)
  let future_iso = @rt.iso_add_seconds(@rt.utcnow_iso(), 120.0)
  assert_eq(hb2.beat(Some(future_iso)), Ok(()))
  let snap2 = match hb2.read() {
    Ok(Some(v)) => v
    _ => fail("读取失败")
  }
  match hb2.check(Some(snap2.epoch - 60L)) {
    Ok(pair) => {
      assert_true(pair.0)
      assert_true(pair.1.contains("时钟偏差"))
    }
    Err(e) => fail("check: \{e}")
  }
  // 清理
  assert_eq(hb2.clear(), Ok(()))
  assert_false(hb2.is_alive(None))
  ffi_hb_rmrf(dir)
}

///|
test "heartbeat · 配置非法（无共享介质）→ 可诊断 Err" {
  let hb = @rt.Heartbeat::new(None, "x.heartbeat", 5.0, 15.0, "closed", "w")
  match hb.beat(None) {
    Err(e) => assert_true(e.contains("缺少共享介质"))
    Ok(_) => fail("无介质应当 Err")
  }
  match hb.read() {
    Err(e) => assert_true(e.contains("缺少共享介质"))
    Ok(_) => fail("无介质读取应当 Err")
  }
}

///|
test "heartbeat · HeartbeatPump 起停（timer 不泄漏）" {
  let dir = ffi_hb_mkdtemp("rhop-hb3")
  let hb = make_hb(dir, 30.0)
  let pump = @rt.HeartbeatPump::new(hb)
  let base = ffi_hb_pump_count()
  assert_false(pump.is_running())
  // start：立刻 beat 一次
  assert_eq(pump.start(), Ok(()))
  assert_true(pump.is_running())
  assert_eq(ffi_hb_pump_count(), base + 1)
  assert_true(hb.is_alive(None))
  // 幂等 start
  assert_eq(pump.start(), Ok(()))
  assert_eq(ffi_hb_pump_count(), base + 1)
  // stop：timer 必须被清掉
  pump.stop()
  assert_false(pump.is_running())
  assert_eq(ffi_hb_pump_count(), base)
  // 再 stop 也安全
  pump.stop()
  assert_eq(ffi_hb_pump_count(), base)
  // shutdown：停表 + 写 closed
  assert_eq(pump.start(), Ok(()))
  assert_eq(pump.shutdown(), Ok(()))
  assert_false(pump.is_running())
  assert_eq(ffi_hb_pump_count(), base)
  match hb.read() {
    Ok(Some(snap)) => assert_true(snap.closed)
    _ => fail("shutdown 应写 closed")
  }
  ffi_hb_rmrf(dir)
}

///|
test "heartbeat · 从 TaskConfig 构造（文件名/间隔/阈值/worker_id 全取配置）" {
  let cfg = match
    @rt.TaskConfig::from_json_text(
      "{\"role\":\"B\",\"name\":\"demo\",\"queue\":{\"heartbeat\":{\"interval_sec\":7,\"stale_after_sec\":20}}}",
      None,
      false,
      false,
      None,
    ) {
    Ok(c) => c
    Err(e) => fail("配置: \{e}")
  }
  let dir = ffi_hb_mkdtemp("rhop-hb4")
  let sp : &@rp.SharedPath = @rp.LocalSharedPath::new(dir)
  let hb = @rt.Heartbeat::from_config(Some(sp), cfg)
  assert_eq(hb.filename(), "demo.heartbeat")
  assert_eq(hb.stale_after_sec(), 20.0)
  assert_eq(hb.beat(None), Ok(()))
  assert_true(hb.is_alive(None))
  ffi_hb_rmrf(dir)
}
