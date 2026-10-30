// ============================================================================
// rhop · 入口直测：rhop_send / from_filesystem_with（js 目标）
//
// 为什么补这两格：套件 163 格覆盖的是底层件（RhopEnvelope / RhopPacket /
// RhopCipher / Session、签名、完整性、json canonical、digest、actions 等），
// 而 fist-mbt 实际调用的两个**入口**——`rhop_send`（ops_commissar.mbt:171）
// 与 `from_filesystem_with`（ops_commissar.mbt:215）——此前没有直接用例。
//
// 确定性说明：`from_filesystem_with` 底层是 node `fs.watch`（事件驱动），
// 而 MoonBit 测试是同步的（主线程阻塞时回调永远不会来）。为**确定性**驱动
// 观察面，本文件把 `node:fs.watch` 换成可控替身：`rhop_send` 仍是**真实写盘**，
// 替身只在测试要求的时刻同步投递 `WatchEvent`。这样覆盖了
// 「写盘 → 观察 → 解码 → 去重 → 跳过坏文件」全链路，且不引入 sleep。
// 每个用例结束恢复真实 `fs.watch`（另有 process exit 兜底）。
// ============================================================================

// ---------------------------------------------------------------------------
// 测试用 JS 辅助
// ---------------------------------------------------------------------------

///|
/// 建临时目录（os.tmpdir 下，登记到 exit 钩子自动清理；不污染仓库）。
extern "js" fn ffi_ep_mkdtemp(prefix : String) -> String =
  #| (prefix) => { try { const G = globalThis; if (!G.__ep_tmp_reg) { G.__ep_tmp_reg = new Set(); } if (!G.__ep_tmp_hook) { G.__ep_tmp_hook = true; process.on("exit", () => { try { const fsm = process.getBuiltinModule("node:fs"); for (const d of G.__ep_tmp_reg) { try { fsm.rmSync(d, { recursive: true, force: true }); } catch (_e) {} } G.__ep_tmp_reg.clear(); } catch (_e2) {} }); } const fs = process.getBuiltinModule("node:fs"); const os = process.getBuiltinModule("node:os"); const path = process.getBuiltinModule("node:path"); const d = fs.mkdtempSync(path.join(os.tmpdir(), String(prefix) + "-")); G.__ep_tmp_reg.add(d); return d; } catch (_e) { return ""; } }

///|
extern "js" fn ffi_ep_rmrf(p : String) -> Unit =
  #| (p) => { try { process.getBuiltinModule("node:fs").rmSync(String(p), { recursive: true, force: true }); } catch (_e) {} }

///|
/// 把 node:fs.watch 换成可控替身（幂等）。真实写盘不受影响。
/// 替身把 (path, cb) 记进 Map，返回带 close() 的假 watcher。
extern "js" fn ffi_ep_install_fake_watch() -> Unit =
  #| () => { const G = globalThis; if (G.__ep_fake_watch_installed) { return; } G.__ep_fake_watch_installed = true; const fs = process.getBuiltinModule("node:fs"); G.__ep_real_watch = fs.watch; G.__ep_fake_watchers = new Map(); G.__ep_fake_watch_seq = 0; if (!G.__ep_watch_exit_hook) { G.__ep_watch_exit_hook = true; process.on("exit", () => { try { const fsm = process.getBuiltinModule("node:fs"); if (G.__ep_fake_watch_installed) { fsm.watch = G.__ep_real_watch; } } catch (_e) {} }); } fs.watch = function(path, opts, cb) { const id = G.__ep_fake_watch_seq++; const entry = { path: String(path), cb: cb, closed: false }; G.__ep_fake_watchers.set(id, entry); return { close: function() { entry.closed = true; G.__ep_fake_watchers.delete(id); } }; }; }

///|
extern "js" fn ffi_ep_restore_watch() -> Unit =
  #| () => { const G = globalThis; if (!G.__ep_fake_watch_installed) { return; } const fs = process.getBuiltinModule("node:fs"); fs.watch = G.__ep_real_watch; G.__ep_fake_watch_installed = false; }

///|
/// 向替身 watcher 同步投递一次 fs.watch 事件（filename 为空表示目标即 watch 根）。
extern "js" fn ffi_ep_emit(path : String, filename : String) -> Bool =
  #| (path, filename) => { const G = globalThis; if (!G.__ep_fake_watchers) { return false; } for (const entry of G.__ep_fake_watchers.values()) { if (entry.path === String(path) && !entry.closed) { entry.cb("rename", filename); return true; } } return false; }

///|
/// 当前仍未关闭的替身 watcher 数（泄漏检查）。
extern "js" fn ffi_ep_watch_count() -> Int32 =
  #| () => { const G = globalThis; if (!G.__ep_fake_watchers) { return 0; } let n = 0; for (const entry of G.__ep_fake_watchers.values()) { if (!entry.closed) { n++; } } return n; }

// ---------------------------------------------------------------------------
// 测试内小工具
// ---------------------------------------------------------------------------

///|
/// 构造一条测试 packet（载荷用 Json::object 安全构造）。
fn ep_packet(id : String, kind : String, at : Int64) -> @rp.RhopPacket {
  let payload = Json::object({
    "id": Json::string(id),
    "kind": Json::string(kind),
  })
  @rp.RhopPacket::new(id, "ep-src", kind, payload, at)
}

///|
/// 收集 on_next（`id|kind`）与 on_error 的观察者。
fn ep_collector() -> (
  @ref.Ref[Array[String]],
  @ref.Ref[Array[String]],
  @rx.Observer[@rp.RhopPacket, String],
) {
  let got : @ref.Ref[Array[String]] = @ref.Ref::new([])
  let errs : @ref.Ref[Array[String]] = @ref.Ref::new([])
  let obs = @rx.Observer::new(
    fn(pkt : @rp.RhopPacket) {
      got.val = got.val.copy() + [pkt.id + "|" + pkt.kind]
    },
    fn(err : String) { errs.val = errs.val.copy() + [err] },
    fn() { () },
  )
  (got, errs, obs)
}

// ---------------------------------------------------------------------------
// rhop_send
// ---------------------------------------------------------------------------

///|
test "rhop-entry · rhop_send(none) 写信封：v/alg/ct 合法、无 .tmp、同 cipher 解密还原 payload" {
  let dir = ffi_ep_mkdtemp("rhop-entry-send-none")
  assert_true(dir != "")
  let pkt = ep_packet("pkt-1", "cmd", 1700000000000L)
  let cipher = @rp.RhopCipherNone::new()
  @rp.rhop_send(dir, "msg-001", pkt, cipher)
  // 直接读目录：文件在、无 .tmp 残留
  let names = @rp.rhop_fs_list_dir(dir)
  assert_true(names.contains("msg-001.rhop"))
  assert_false(names.contains(".tmp"))
  assert_true(@rp.rhop_fs_exists(dir + "/msg-001.rhop"))
  // 信封解码
  let text = match @rp.rhop_fs_read_text(dir + "/msg-001.rhop") {
    Err(e) => fail("读回信封失败: " + e)
    Ok(v) => v
  }
  assert_true(text != "")
  let env = match @rp.RhopEnvelope::decode(text) {
    Err(e) => fail("信封解码失败: " + e)
    Ok(v) => v
  }
  assert_eq(env.v, 1)
  assert_eq(env.alg, "none")
  assert_true(env.ct != "")
  // 同 cipher 解密还原 payload
  let plain = match @rp.RhopCipher::decrypt(cipher, env.ct) {
    None => fail("RhopCipherNone 解密失败")
    Some(v) => v
  }
  let back = match @rp.RhopPacket::from_json_text(plain) {
    Err(e) => fail("packet 解析失败: " + e)
    Ok(v) => v
  }
  assert_eq(back.id, "pkt-1")
  assert_eq(back.source, "ep-src")
  assert_eq(back.kind, "cmd")
  assert_eq(back.at, 1700000000000L)
  assert_eq(Json::stringify(back.payload), Json::stringify(pkt.payload))
  ffi_ep_rmrf(dir)
}

///|
test "rhop-entry · rhop_send(aes-256-gcm) 写信封：alg 正确、同密码解密还原" {
  let dir = ffi_ep_mkdtemp("rhop-entry-send-aes")
  assert_true(dir != "")
  let pkt = ep_packet("pkt-2", "state", 1700000001000L)
  let cipher = @rp.Aes256GcmCipher::new("ep-pw-123")
  @rp.rhop_send(dir, "aes-1", pkt, cipher)
  let names = @rp.rhop_fs_list_dir(dir)
  assert_true(names.contains("aes-1.rhop"))
  assert_false(names.contains(".tmp"))
  let text = match @rp.rhop_fs_read_text(dir + "/aes-1.rhop") {
    Err(e) => fail("读回信封失败: " + e)
    Ok(v) => v
  }
  let env = match @rp.RhopEnvelope::decode(text) {
    Err(e) => fail("信封解码失败: " + e)
    Ok(v) => v
  }
  assert_eq(env.v, 1)
  assert_eq(env.alg, "aes-256-gcm")
  let plain = match @rp.RhopCipher::decrypt(cipher, env.ct) {
    None => fail("AES 解密失败")
    Some(v) => v
  }
  let back = match @rp.RhopPacket::from_json_text(plain) {
    Err(e) => fail("packet 解析失败: " + e)
    Ok(v) => v
  }
  assert_eq(back.id, "pkt-2")
  assert_eq(Json::stringify(back.payload), Json::stringify(pkt.payload))
  ffi_ep_rmrf(dir)
}

// ---------------------------------------------------------------------------
// from_filesystem_with
// ---------------------------------------------------------------------------

///|
test "rhop-entry · from_filesystem_with 观测新写入信封并解码出 packet（含同路径去重）" {
  let dir = ffi_ep_mkdtemp("rhop-entry-obs")
  assert_true(dir != "")
  let cipher = @rp.RhopCipherNone::new()
  let (got, errs, obs) = ep_collector()
  ffi_ep_install_fake_watch()
  let sub = @rp.from_filesystem_with(dir, cipher, false).subscribe(obs)
  // 订阅后真实写盘
  let pkt = ep_packet("pkt-new", "cmd", 1700000002000L)
  @rp.rhop_send(dir, "fresh-1", pkt, cipher)
  assert_true(@rp.rhop_fs_exists(dir + "/fresh-1.rhop"))
  assert_true(ffi_ep_emit(dir, "fresh-1.rhop"))
  assert_eq(got.val.length(), 1)
  assert_eq(got.val[0], "pkt-new|cmd")
  assert_eq(errs.val.length(), 0)
  // 同路径再来一次事件 → 去重，不重复投递
  assert_true(ffi_ep_emit(dir, "fresh-1.rhop"))
  assert_eq(got.val.length(), 1)
  sub.dispose()
  ffi_ep_restore_watch()
  ffi_ep_rmrf(dir)
}

///|
test "rhop-entry · from_filesystem_with(skip_existing=true) 不重放已存在项" {
  let dir = ffi_ep_mkdtemp("rhop-entry-skip")
  assert_true(dir != "")
  let cipher = @rp.RhopCipherNone::new()
  // 订阅前已存在
  let old_pkt = ep_packet("pkt-old", "cmd", 1700000003000L)
  @rp.rhop_send(dir, "old-1", old_pkt, cipher)
  assert_true(@rp.rhop_fs_exists(dir + "/old-1.rhop"))
  let (got, errs, obs) = ep_collector()
  ffi_ep_install_fake_watch()
  let sub = @rp.from_filesystem_with(dir, cipher, true).subscribe(obs)
  // ① 订阅后的新项仍能收到（正路径先行，即便下面那格因实现 bug 红，本格也已自证）
  let new_pkt = ep_packet("pkt-new", "cmd", 1700000004000L)
  @rp.rhop_send(dir, "new-1", new_pkt, cipher)
  assert_true(ffi_ep_emit(dir, "new-1.rhop"))
  assert_eq(got.val.length(), 1)
  assert_eq(got.val[0], "pkt-new|cmd")
  // ② 已存在项即使再来事件也不重放
  assert_true(ffi_ep_emit(dir, "old-1.rhop"))
  if got.val.length() != 1 {
    fail(
      "skip_existing=true 仍投递了订阅前已存在的文件: " +
      got.val.to_string() +
      "（疑似 Windows 路径分隔符不一致：ffi_list_files 用 path.resolve 产出反斜杠绝对路径，" +
      "watch 事件路径用 monitor/join_path 产出正斜杠 ⇒ seen 集合键不匹配）",
    )
  }
  assert_eq(errs.val.length(), 0)
  sub.dispose()
  ffi_ep_restore_watch()
  ffi_ep_rmrf(dir)
}

///|
test "rhop-entry · from_filesystem_with(skip_existing=false) 会投递已存在项" {
  let dir = ffi_ep_mkdtemp("rhop-entry-noskip")
  assert_true(dir != "")
  let cipher = @rp.RhopCipherNone::new()
  let old_pkt = ep_packet("pkt-old", "cmd", 1700000005000L)
  @rp.rhop_send(dir, "old-1", old_pkt, cipher)
  let (got, errs, obs) = ep_collector()
  ffi_ep_install_fake_watch()
  let sub = @rp.from_filesystem_with(dir, cipher, false).subscribe(obs)
  assert_true(ffi_ep_emit(dir, "old-1.rhop"))
  assert_eq(got.val.length(), 1)
  assert_eq(got.val[0], "pkt-old|cmd")
  assert_eq(errs.val.length(), 0)
  sub.dispose()
  ffi_ep_restore_watch()
  ffi_ep_rmrf(dir)
}

///|
test "rhop-entry · from_filesystem_with 坏信封跳过不中断、不报 error（坏 JSON / v≠1 / 解密失败 / packet 解析失败）" {
  let dir = ffi_ep_mkdtemp("rhop-entry-bad")
  assert_true(dir != "")
  let cipher = @rp.Aes256GcmCipher::new("ep-pw-bad")
  // 1) 非 JSON 信封
  assert_eq(@rp.rhop_fs_write_text(dir + "/bad-json.rhop", "not-json-at-all"), Ok(()))
  // 2) 信封合法但 v != 1
  let bad_v = @rp.RhopEnvelope::encode(2, "aes-256-gcm", "anything")
  assert_eq(@rp.rhop_fs_write_text(dir + "/bad-v.rhop", bad_v), Ok(()))
  // 3) 解密失败（ct 不是合法 GCM token）
  let bad_ct = @rp.RhopEnvelope::encode(1, "aes-256-gcm", "malformed-token")
  assert_eq(@rp.rhop_fs_write_text(dir + "/bad-ct.rhop", bad_ct), Ok(()))
  // 4) packet 解析失败（ct 合法但明文不是 packet JSON）
  let bad_pkt_ct = @rp.RhopEnvelope::encode(
    1,
    "aes-256-gcm",
    @rp.RhopCipher::encrypt(cipher, "this is not a packet"),
  )
  assert_eq(@rp.rhop_fs_write_text(dir + "/bad-packet.rhop", bad_pkt_ct), Ok(()))
  let (got, errs, obs) = ep_collector()
  ffi_ep_install_fake_watch()
  let sub = @rp.from_filesystem_with(dir, cipher, false).subscribe(obs)
  for name in ["bad-json", "bad-v", "bad-ct", "bad-packet"] {
    assert_true(ffi_ep_emit(dir, name + ".rhop"))
  }
  assert_eq(got.val.length(), 0)
  assert_eq(errs.val.length(), 0)
  // 坏文件之后好文件仍能收到（流不中断）
  let good = ep_packet("pkt-good", "cmd", 1700000006000L)
  @rp.rhop_send(dir, "good-1", good, cipher)
  assert_true(ffi_ep_emit(dir, "good-1.rhop"))
  assert_eq(got.val.length(), 1)
  assert_eq(got.val[0], "pkt-good|cmd")
  sub.dispose()
  ffi_ep_restore_watch()
  ffi_ep_rmrf(dir)
}

///|
test "rhop-entry · from_filesystem_with 忽略非 .rhop 与 .rhop.tmp" {
  let dir = ffi_ep_mkdtemp("rhop-entry-filter")
  assert_true(dir != "")
  let cipher = @rp.RhopCipherNone::new()
  // 非 .rhop：即便内容是合法信封也不处理
  let env = @rp.RhopEnvelope::encode(
    1,
    "none",
    @rp.RhopCipher::encrypt(cipher, "{}"),
  )
  assert_eq(@rp.rhop_fs_write_text(dir + "/note.txt", env), Ok(()))
  // .rhop.tmp：原子写中间态
  assert_eq(@rp.rhop_fs_write_text(dir + "/x.rhop.tmp", env), Ok(()))
  let (got, errs, obs) = ep_collector()
  ffi_ep_install_fake_watch()
  let sub = @rp.from_filesystem_with(dir, cipher, false).subscribe(obs)
  assert_true(ffi_ep_emit(dir, "note.txt"))
  assert_true(ffi_ep_emit(dir, "x.rhop.tmp"))
  assert_eq(got.val.length(), 0)
  assert_eq(errs.val.length(), 0)
  sub.dispose()
  ffi_ep_restore_watch()
  ffi_ep_rmrf(dir)
}

///|
test "rhop-entry · dispose 关闭替身 watcher（无句柄泄漏）" {
  let dir = ffi_ep_mkdtemp("rhop-entry-leak")
  assert_true(dir != "")
  let (got, errs, obs) = ep_collector()
  ffi_ep_install_fake_watch()
  let before = ffi_ep_watch_count()
  let sub = @rp.from_filesystem_with(dir, @rp.RhopCipherNone::new(), false).subscribe(obs)
  assert_eq(ffi_ep_watch_count(), before + 1)
  sub.dispose()
  assert_eq(ffi_ep_watch_count(), before)
  ffi_ep_restore_watch()
  ffi_ep_rmrf(dir)
}

///|
test "rhop-entry · from_filesystem_with 监控路径不存在 → on_error（WatchError，可诊断）" {
  let dir = ffi_ep_mkdtemp("rhop-entry-err")
  assert_true(dir != "")
  let ghost = dir + "/no-such-subdir"
  let (got, errs, obs) = ep_collector()
  // 不装替身：走真实 fs.watch，非存在路径在订阅时同步报错
  // （前序用例若中途 fail，替身可能残留 ⇒ 先显式还原）
  ffi_ep_restore_watch()
  let sub = @rp.from_filesystem_with(ghost, @rp.RhopCipherNone::new(), false).subscribe(obs)
  assert_eq(got.val.length(), 0)
  assert_eq(errs.val.length(), 1)
  assert_true(errs.val[0].contains("WatchError"))
  sub.dispose()
  ffi_ep_rmrf(dir)
}
