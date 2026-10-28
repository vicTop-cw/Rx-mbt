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
  // 默认 include_worker=false：只写时间戳（vools 默认形态）
  assert_eq(hb.beat(Some(now)), Ok(()))
  let snap = match hb.read() {
    Ok(Some(v)) => v
    Ok(None) => fail("心跳文件应存在")
    Err(e) => fail("read: \{e}")
  }
  // 默认不带 worker
  assert_eq(snap.worker_id, "")
  // ts 是 vools 同形（带 6 位微秒），秒部分应与传入值一致
  assert_true(snap.ts.contains("."))
  assert_true(snap.ts.has_suffix("Z"))
  assert_eq(snap.epoch, @rt.parse_iso(now).unwrap_or(0L))
  assert_false(snap.closed)
  assert_true(snap.epoch > 0L)
  // include_worker=true 时才带上 worker
  assert_eq(hb.beat(Some(now), include_worker=true), Ok(()))
  let snap_w = match hb.read() {
    Ok(Some(v)) => v
    _ => fail("read 失败")
  }
  assert_eq(snap_w.worker_id, "w-1")
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

// ---------------------------------------------------------------------------
// B1 · 心跳文件格式互通（vools 纯文本 <-> MoonBit）
//
// vools heartbeat.py 的写盘格式（实测源码）：
//   beat       : "<ISO> <worker_id>"（include_worker=True）或 "<ISO>"（默认）
//   mark_closed: 字面量 closed_token（默认 "closed"）
// 本实现改为写同一格式，且 read() 三级兼容（closed_token / JSON 存量 / 纯文本）。
// ---------------------------------------------------------------------------

///|
extern "js" fn ffi_hb_write_raw(p : String, c : String) -> Bool =
  #| (p, c) => { try { process.getBuiltinModule("node:fs").writeFileSync(String(p), String(c), "utf8"); return true; } catch (_e) { return false; } }

///|
extern "js" fn ffi_hb_read_raw(p : String) -> String =
  #| (p) => { try { return process.getBuiltinModule("node:fs").readFileSync(String(p), "utf8"); } catch (_e) { return ""; } }

///|
/// 心跳文件在测试目录里的绝对路径（node 在 Windows 下同样接受 "/"）。
fn hb_path(dir : String) -> String {
  dir + "/hb-test.heartbeat"
}

///|
test "B1 · 能读 vools 写的纯文本（含 worker_id）" {
  let dir = ffi_hb_mkdtemp("rhop-hb-b1a")
  let hb = make_hb(dir, 30.0)
  // 模拟 Python vools beat(include_worker=True) 写出的一行
  let vools_text = "2026-10-28T03:00:00Z w-worker-7"
  assert_true(ffi_hb_write_raw(hb_path(dir), vools_text))
  let snap = match hb.read() {
    Ok(Some(v)) => v
    Ok(None) => fail("vools 纯文本应可读")
    Err(e) => fail("read: \{e}")
  }
  assert_eq(snap.worker_id, "w-worker-7")
  assert_eq(snap.ts, "2026-10-28T03:00:00Z")
  assert_false(snap.closed)
  // epoch 由 ts 解析而来（应为 2026-10-28T03:00:00Z 的秒）
  assert_eq(snap.epoch, @rt.parse_iso("2026-10-28T03:00:00Z").unwrap_or(0L))
  ffi_hb_rmrf(dir)
}

///|
test "B1 · 能读 vools 写的纯文本（仅 ISO，无 worker）与带微秒写法" {
  let dir = ffi_hb_mkdtemp("rhop-hb-b1b")
  let hb = make_hb(dir, 30.0)
  // include_worker=False 时的形态：只有 ISO
  assert_true(ffi_hb_write_raw(hb_path(dir), "2026-10-28T03:00:05Z"))
  match hb.read() {
    Ok(Some(snap)) => {
      assert_eq(snap.worker_id, "")
      assert_eq(snap.ts, "2026-10-28T03:00:05Z")
      assert_false(snap.closed)
    }
    _ => fail("仅 ISO 的纯文本应可读")
  }
  // vools 默认 TIMESTAMP_FORMAT 带微秒（%f）—— 解析器必须容忍
  assert_true(ffi_hb_write_raw(hb_path(dir), "2026-10-28T03:00:07.123456Z"))
  match hb.read() {
    Ok(Some(snap)) => {
      assert_true(snap.ts.contains(".123456"))
      // 微秒被截断到秒但必须解析成功（不是 0）
      assert_eq(snap.epoch, @rt.parse_iso("2026-10-28T03:00:07Z").unwrap_or(0L))
    }
    _ => fail("带微秒的纯文本应可读")
  }
  ffi_hb_rmrf(dir)
}

///|
test "B1 · 能读 vools 的 closed_token 停机哨兵" {
  let dir = ffi_hb_mkdtemp("rhop-hb-b1c")
  let hb = make_hb(dir, 30.0)
  // vools mark_closed 写的就是字面量 closed_token
  assert_true(ffi_hb_write_raw(hb_path(dir), "closed"))
  match hb.read() {
    Ok(Some(snap)) => {
      assert_true(snap.closed)
      assert_eq(snap.worker_id, "")
    }
    Ok(None) => fail("closed_token 应被识别为停机")
    Err(e) => fail("read: \{e}")
  }
  assert_false(hb.is_alive(None))
  // 换一个自定义 closed_token 也要认
  let hb2 = @rt.Heartbeat::new(
    Some(@rp.LocalSharedPath::new(dir)),
    "hb-test.heartbeat",
    0.05,
    30.0,
    "STOP",
    "w-1",
  )
  assert_true(ffi_hb_write_raw(hb_path(dir), "STOP"))
  match hb2.read() {
    Ok(Some(snap)) => assert_true(snap.closed)
    _ => fail("自定义 closed_token 应被识别")
  }
  ffi_hb_rmrf(dir)
}

///|
test "B1 · JSON 存量格式仍可读（向后兼容自己早期写出的文件）" {
  let dir = ffi_hb_mkdtemp("rhop-hb-b1d")
  let hb = make_hb(dir, 30.0)
  let legacy = "{\"worker_id\":\"legacy-w\",\"ts\":\"2026-10-28T03:00:09Z\",\"epoch\":1793156409,\"closed\":false,\"closed_token\":\"closed\"}"
  assert_true(ffi_hb_write_raw(hb_path(dir), legacy))
  match hb.read() {
    Ok(Some(snap)) => {
      assert_eq(snap.worker_id, "legacy-w")
      assert_eq(snap.ts, "2026-10-28T03:00:09Z")
      assert_eq(snap.epoch, 1793156409L)
      assert_false(snap.closed)
    }
    _ => fail("JSON 存量应可读")
  }
  ffi_hb_rmrf(dir)
}

///|
test "B1 · beat 写出的文本逐字节符合 vools 格式（默认仅时间戳带微秒）" {
  let dir = ffi_hb_mkdtemp("rhop-hb-b1e")
  let hb = make_hb(dir, 30.0)
  // ① vools 默认形态（include_worker=False）：只有时间戳，且带 6 位微秒
  assert_eq(hb.beat(Some("2026-10-28T03:00:11Z")), Ok(()))
  let raw = ffi_hb_read_raw(hb_path(dir)).trim().to_owned()
  assert_eq(raw, "2026-10-28T03:00:11.000000Z")
  // 微秒必须是 6 位（vools TIMESTAMP_FORMAT = %f 的字节形态）
  let dot = match raw.find(".") {
    Some(i) => i
    None => fail("时间戳应带微秒")
  }
  assert_eq(raw.length() - dot - 2, 6)
  assert_true(@rt.parse_iso(raw) is Some(_))
  // ② include_worker=true：`<ts> <worker_id>`
  assert_eq(hb.beat(Some("2026-10-28T03:00:11Z"), include_worker=true), Ok(()))
  let raw2 = ffi_hb_read_raw(hb_path(dir))
  let parts = raw2.trim().split(" ").collect()
  assert_eq(parts.length(), 2)
  assert_eq(parts[0].to_string(), "2026-10-28T03:00:11.000000Z")
  assert_eq(parts[1].to_string(), "w-1")
  // ③ 传入带微秒的时间串：保留并规整到 6 位
  assert_eq(hb.beat(Some("2026-10-28T03:00:13.987Z")), Ok(()))
  assert_eq(ffi_hb_read_raw(hb_path(dir)).trim(), "2026-10-28T03:00:13.987000Z")
  // ④ worker_id 为空 + include_worker=true：仍只写时间戳
  let hb_no_worker = @rt.Heartbeat::new(
    Some(@rp.LocalSharedPath::new(dir)),
    "hb-test.heartbeat",
    0.05,
    30.0,
    "closed",
    "",
  )
  assert_eq(
    hb_no_worker.beat(Some("2026-10-28T03:00:12Z"), include_worker=true),
    Ok(()),
  )
  assert_eq(ffi_hb_read_raw(hb_path(dir)).trim(), "2026-10-28T03:00:12.000000Z")
  // ⑤ mark_closed 写字面量 closed_token（不是 JSON）
  assert_eq(hb.mark_closed(None), Ok(()))
  assert_eq(ffi_hb_read_raw(hb_path(dir)).trim(), "closed")
  ffi_hb_rmrf(dir)
}

// ---------------------------------------------------------------------------
// B2 · 未来时间戳 fail-closed
// ---------------------------------------------------------------------------

///|
test "B2 · 未来时间戳超容差判 dead（fail-closed）" {
  let dir = ffi_hb_mkdtemp("rhop-hb-b2a")
  let hb = make_hb(dir, 30.0)
  assert_eq(hb.max_future_skew_sec(), 60.0)
  // 心跳时间戳比「现在」晚 200s，容差 60s → 判死
  let future = @rt.iso_add_seconds(@rt.utcnow_iso(), 200.0)
  assert_eq(hb.beat(Some(future)), Ok(()))
  let snap = match hb.read() {
    Ok(Some(v)) => v
    _ => fail("read 失败")
  }
  assert_false(hb.is_alive(Some(snap.epoch - 200L)))
  match hb.check(Some(snap.epoch - 200L)) {
    Ok(pair) => {
      assert_false(pair.0)
      assert_true(pair.1.contains("在未来"))
      assert_true(pair.1.contains("容差"))
      assert_true(pair.1.contains("时钟超前"))
    }
    Err(e) => fail("check: \{e}")
  }
  ffi_hb_rmrf(dir)
}

///|
test "B2 · 容差内的轻微超前仍判 alive（但原因里说明）" {
  let dir = ffi_hb_mkdtemp("rhop-hb-b2b")
  let hb = make_hb(dir, 30.0)
  let future = @rt.iso_add_seconds(@rt.utcnow_iso(), 30.0)
  assert_eq(hb.beat(Some(future)), Ok(()))
  let snap = match hb.read() {
    Ok(Some(v)) => v
    _ => fail("read 失败")
  }
  // 观察时刻比心跳晚 30s ⇒ age = -30s，在 60s 容差内
  assert_true(hb.is_alive(Some(snap.epoch - 30L)))
  match hb.check(Some(snap.epoch - 30L)) {
    Ok(pair) => {
      assert_true(pair.0)
      assert_true(pair.1.contains("超前"))
    }
    Err(e) => fail("check: \{e}")
  }
  ffi_hb_rmrf(dir)
}

///|
test "B2 · with_max_future_skew 可收紧容差（10s 内不揪，30s 就判死）" {
  let dir = ffi_hb_mkdtemp("rhop-hb-b2c")
  let hb = make_hb(dir, 30.0).with_max_future_skew(10.0)
  assert_eq(hb.max_future_skew_sec(), 10.0)
  let future = @rt.iso_add_seconds(@rt.utcnow_iso(), 30.0)
  assert_eq(hb.beat(Some(future)), Ok(()))
  let snap = match hb.read() {
    Ok(Some(v)) => v
    _ => fail("read 失败")
  }
  // age = -30s < -10s ⇒ dead
  assert_false(hb.is_alive(Some(snap.epoch - 30L)))
  // 重写一个只超前 5s 的心跳 ⇒ 在 10s 容差内 ⇒ alive
  let slight = @rt.iso_add_seconds(@rt.utcnow_iso(), 5.0)
  assert_eq(hb.beat(Some(slight)), Ok(()))
  let snap2 = match hb.read() {
    Ok(Some(v)) => v
    _ => fail("read 失败")
  }
  assert_true(hb.is_alive(Some(snap2.epoch - 5L)))
  ffi_hb_rmrf(dir)
}

///|
test "B2 · from_config 从 queue.heartbeat 读 closed_token 与 max_future_skew_sec" {
  let cfg = match
    @rt.TaskConfig::from_json_text(
      "{\"role\":\"B\",\"name\":\"demo\",\"queue\":{\"heartbeat\":{\"interval_sec\":5,\"stale_after_sec\":20,\"closed_token\":\"BYE\",\"max_future_skew_sec\":15}}}",
      None,
      false,
      false,
      None,
    ) {
    Ok(c) => c
    Err(e) => fail("配置: \{e}")
  }
  let dir = ffi_hb_mkdtemp("rhop-hb-b2d")
  let sp : &@rp.SharedPath = @rp.LocalSharedPath::new(dir)
  let hb = @rt.Heartbeat::from_config(Some(sp), cfg)
  assert_eq(hb.max_future_skew_sec(), 15.0)
  // 配置里的 closed_token 生效：写到**配置指定的文件名**（demo.heartbeat），
  // 写 "BYE" 应被判停机
  let cfg_hb_path = dir + "/" + hb.filename()
  assert_eq(hb.filename(), "demo.heartbeat")
  assert_true(ffi_hb_write_raw(cfg_hb_path, "BYE"))
  match hb.read() {
    Ok(Some(snap)) => assert_true(snap.closed)
    _ => fail("配置里的 closed_token 未生效")
  }
  ffi_hb_rmrf(dir)
}
