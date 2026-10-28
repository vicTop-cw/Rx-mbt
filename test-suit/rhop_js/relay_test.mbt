// ============================================================================
// rhop · 中转通道测试（js 目标）
//
// 单机三角回环：A（投递方）→ C（自建中转）→ B（接收方），全程加密不落明文。
// 说明：中转服务跑在子进程里（见 rhop/relay.mbt 文件头），主线程的同步 HTTP
// 客户端因此可以安全阻塞等待 —— 服务端不在同一事件循环里。
//
// 覆盖：
//   1. RelayServer：start/port/url/alive/stop；stop 后不再可达
//   2. RelayChannel：available（/health 探活）、send/receive、取走即删
//   3. A→C→B 加密回环：A 加密 → 中转 → B 解密验证 OK
//   4. 失败路径：错 token → Err；坏文件名（含 "/"）→ Err；无包 → Err
//   5. Git/Sftp 不可用时明确降级（available=false / send 返回可诊断 Err，不崩溃）
// ============================================================================

// ---------------------------------------------------------------------------
// 1+2+3. 中转服务与通道
// ---------------------------------------------------------------------------

///|
test "relay · A→C→B 单机回环（加密包经中转投递并解密验证）" {
  let token = "relay-test-token"
  let server = @rp.RelayServer::new("127.0.0.1", 0, Some(token), 15000)
  match server.start() {
    Err(e) => fail("中转服务启动失败: \{e}")
    Ok(_) => ()
  }
  let port = server.port()
  assert_true(port > 0)
  assert_true(server.alive())
  println(
    "[relay] port=" +
    port.to_string() +
    " process_alive=" +
    server.process_alive().to_string(),
  )
  assert_true(server.url().contains("127.0.0.1:\{port}"))

  // A 侧与 B 侧各自用自己的 RhopCrypto（同一把固定密钥）
  let key = "relay-test-key"
  let ca = @rp.RhopCrypto::from_key(key)
  let cb = @rp.RhopCrypto::from_key(key)
  let chan = @rp.RelayChannel::new("127.0.0.1", port, Some(token), 3000)
  let ch : &@rp.OnlineChannel = chan
  assert_eq(@rp.OnlineChannel::name(ch), "relay:http://127.0.0.1:\{port}")
  assert_true(@rp.OnlineChannel::available(ch))

  // A：加密并 PUT
  let payload = @json.parse(
    "{\"task\": \"demo\", \"n\": 7, \"msg\": \"你好 中转\"}",
  ) catch {
    _ => fail("载荷解析失败")
  }
  let env = ca.encrypt_json(payload)
  assert_eq(@rp.OnlineChannel::send(ch, "pkg-a.rhop", env), Ok(()))
  // B：GET 并解密验证
  match @rp.OnlineChannel::receive(ch, "pkg-a.rhop") {
    Err(e) => fail("B 侧取包失败: \{e}")
    Ok(text) => {
      let r = cb.decrypt_verify(text)
      assert_true(r.ok)
      assert_eq(r.reason, "OK")
      match r.payload {
        Some(p) => assert_eq(Json::stringify(p), Json::stringify(payload))
        None => fail("解密后 payload 缺失")
      }
    }
  }
  // 取走即删：第二次取应当 404 → 可诊断 Err
  match @rp.OnlineChannel::receive(ch, "pkg-a.rhop") {
    Err(e) => assert_true(e.contains("中转无包"))
    Ok(_) => fail("已取走的包不应二次可读")
  }
  server.stop()
  assert_false(server.alive())
  // 停止后健康探测/发送都必须失败而不是崩溃
  assert_false(@rp.OnlineChannel::available(ch))
  match @rp.OnlineChannel::send(ch, "pkg-b.rhop", "x") {
    Err(e) => assert_true(e.contains("中转不可达") || e.contains("token"))
    Ok(_) => fail("服务停止后发送应当 Err")
  }
}

///|
test "relay · token 校验与坏文件名拒绝" {
  let server = @rp.RelayServer::new("127.0.0.1", 0, Some("right-token"), 15000)
  match server.start() {
    Err(e) => fail("中转服务启动失败: \{e}")
    Ok(_) => ()
  }
  let port = server.port()
  // 错 token → send 被 403 拒绝，错误文本点明 token
  let bad = @rp.RelayChannel::new("127.0.0.1", port, Some("wrong-token"), 3000)
  match @rp.OnlineChannel::send(bad, "p.rhop", "data") {
    Err(e) => assert_true(e.contains("token"))
    Ok(_) => fail("错 token 应当被拒")
  }
  match @rp.OnlineChannel::receive(bad, "p.rhop") {
    Err(e) => assert_true(e.contains("token"))
    Ok(_) => fail("错 token 读取应当被拒")
  }
  // token=None 的通道对 /health 仍可用（探活不校验 token，与 vools 一致），但 PUT 被拒
  let none_tok = @rp.RelayChannel::new("127.0.0.1", port, None, 3000)
  assert_true(@rp.OnlineChannel::available(none_tok))
  match @rp.OnlineChannel::send(none_tok, "p.rhop", "data") {
    Err(e) => assert_true(e.contains("token"))
    Ok(_) => fail("无 token 写入应当被拒")
  }
  // 服务端也接受正确 token 写入
  let good = @rp.RelayChannel::new("127.0.0.1", port, Some("right-token"), 3000)
  assert_eq(@rp.OnlineChannel::send(good, "ok.rhop", "hello"), Ok(()))
  // 坏文件名（含 "/"）：URL 编码后被服务端解码还原并拒绝 400
  match @rp.OnlineChannel::send(good, "../evil.rhop", "x") {
    Err(e) => assert_true(e.contains("status=400") || e.contains("PUT 失败"))
    Ok(_) => fail("含路径分隔的文件名应当被拒")
  }
  server.stop()
}

///|
test "relay · 空包与二进制安全（UTF-8 往返）" {
  let server = @rp.RelayServer::new("127.0.0.1", 0, None, 15000)
  match server.start() {
    Err(e) => fail("中转服务启动失败: \{e}")
    Ok(_) => ()
  }
  let ch = @rp.RelayChannel::new("127.0.0.1", server.port(), None, 3000)
  // 空内容
  assert_eq(@rp.OnlineChannel::send(ch, "empty.rhop", ""), Ok(()))
  assert_eq(@rp.OnlineChannel::receive(ch, "empty.rhop"), Ok(""))
  // UTF-8 中文 / emoji / 换行
  let text = "中文 🔑\n第二行\t制表"
  assert_eq(@rp.OnlineChannel::send(ch, "u.rhop", text), Ok(()))
  assert_eq(@rp.OnlineChannel::receive(ch, "u.rhop"), Ok(text))
  server.stop()
}

// ---------------------------------------------------------------------------
// 4. Git / Sftp 降级（不崩溃、可诊断）
// ---------------------------------------------------------------------------

///|
test "online · Git/Sftp 不可用时明确降级不崩溃" {
  // 不可解析的远端 → git ls-remote 失败 → available=false
  let git = @rp.GitChannel::new("https://invalid.invalid.example/nope.git")
  let gch : &@rp.OnlineChannel = git
  assert_eq(
    @rp.OnlineChannel::name(gch),
    "git:https://invalid.invalid.example/nope.git",
  )
  assert_false(@rp.OnlineChannel::available(gch))
  // 空远端也不崩
  let git_empty = @rp.GitChannel::new("")
  assert_false(@rp.OnlineChannel::available((git_empty : &@rp.OnlineChannel)))
  // send/receive 明确 Err（不静默成功）
  match @rp.OnlineChannel::send(gch, "a.rhop", "x") {
    Err(e) => {
      assert_true(e.contains("未在本实现落地"))
      assert_true(e.contains("RelayChannel") || e.contains("shared path"))
    }
    Ok(_) => fail("Git send 未落地必须 Err")
  }
  match @rp.OnlineChannel::receive(gch, "a.rhop") {
    Err(e) => assert_true(e.contains("未在本实现落地"))
    Ok(_) => fail("Git receive 未落地必须 Err")
  }
  // 明确不存在的端口 → TCP 探测 false，不崩
  let sftp = @rp.SftpChannel::new("127.0.0.1", 1, "/share")
  let sch : &@rp.OnlineChannel = sftp
  assert_true(@rp.OnlineChannel::name(sch).contains("sftp:"))
  assert_false(@rp.OnlineChannel::available(sch))
  match @rp.OnlineChannel::send(sch, "a.rhop", "x") {
    Err(e) => assert_true(e.contains("未在本实现落地"))
    Ok(_) => fail("Sftp send 未落地必须 Err")
  }
  // 非法端口/主机也不崩
  assert_false(
    @rp.OnlineChannel::available(
      (@rp.SftpChannel::new("", 0, "/x") : &@rp.OnlineChannel),
    ),
  )
}

///|
test "online · 在线通道参与 select_transport 时按探测结果降级到 shared" {
  let dir = ffi_r_mkdtemp("rhop-r9")
  let sp : &@rp.SharedPath = @rp.LocalSharedPath::new(dir)
  let git : &@rp.OnlineChannel = @rp.GitChannel::new(
    "https://invalid.invalid.example/nope.git",
  )
  let sftp : &@rp.OnlineChannel = @rp.SftpChannel::new("127.0.0.1", 1, "/share")
  let sel = @rp.select_transport([git, sftp], Some(sp))
  assert_false(sel.is_online)
  assert_eq(sel.transport, "shared")
  assert_true(sel.reason.contains("git:"))
  assert_true(sel.reason.contains("sftp:"))
  ffi_r_rmrf(dir)
}

///|
extern "js" fn ffi_r_mkdtemp(prefix : String) -> String =
  #| (prefix) => { try { const fs = process.getBuiltinModule("node:fs"); const os = process.getBuiltinModule("node:os"); const path = process.getBuiltinModule("node:path"); return fs.mkdtempSync(path.join(os.tmpdir(), String(prefix) + "-")); } catch (_e) { return ""; } }

///|
extern "js" fn ffi_r_rmrf(p : String) -> Unit =
  #| (p) => { try { process.getBuiltinModule("node:fs").rmSync(String(p), { recursive: true, force: true }); } catch (_e) {} }

// ---------------------------------------------------------------------------
// 泄漏兜底（防 js 测试进程挂死）
//
// 背景：node 只有在事件循环里没有活跃 handle 时才退出。中转子进程若没被 stop()，
// 或某个用例在 stop() 之前断言失败，就会留下活着的子进程/句柄，表现为
// 「断言全过但 moon 不打印汇总行、进程永久挂住」（qa 2026-10-27 复现过）。
// 正常路径下每个用例都会自己 stop()；本用例是**兜底 + 回归断言**：
// 残留数必须能被清到 0，否则说明有用例漏了 stop。
// ---------------------------------------------------------------------------

///|
/// 当前仍注册着的中转子进程数。
extern "js" fn ffi_r_relay_live_count() -> Int32 =
  #| () => { const G = globalThis; if (!G.__rxmbt_relay) { return 0; } let n = 0; for (const _k of G.__rxmbt_relay.keys()) { n++; } return n; }

///|
/// 杀掉并移除所有已注册的中转子进程（幂等兜底）。
extern "js" fn ffi_r_relay_kill_all() -> Unit =
  #| () => { const G = globalThis; if (!G.__rxmbt_relay) { return; } for (const [k, c] of G.__rxmbt_relay) { try { c.kill(); } catch (_e) {} } G.__rxmbt_relay.clear(); }

///|
/// 有余留 node 句柄的类别（用于定位挂死来源）。
extern "js" fn ffi_r_active_resources() -> String =
  #| () => { try { const f = process.getActiveResourcesInfo; if (!f) { return "[]"; } return JSON.stringify(f.call(process)); } catch (_e) { return "[]"; } }

///|
test "relay · 收尾：无遗留中转子进程（js 挂死兜底 + 回归断言）" {
  // 断言对象：前面用例都走到 stop 之后仍然存活的中转子进程数。
  // 必须先在 kill_all 之前取快照——「先 kill_all 再断言 count==0」是恒真断言（C1-F8）。
  let live = ffi_r_relay_live_count()
  // 兜底清理：即使断言失败，也不把子进程留给后续用例/测试进程
  ffi_r_relay_kill_all()
  if live > 0 {
    println(
      "[relay] 失败现场：收尾前仍有 \{live.to_string()} 个未停止的中转子进程（有用例未走到 stop）",
    )
  }
  assert_eq(live, 0)
  // 句柄快照打印出来，便于下次真的挂死时一眼定位（FSWatcher/Server/Socket/Timer…）
  println("[relay] active resources = " + ffi_r_active_resources())
}
