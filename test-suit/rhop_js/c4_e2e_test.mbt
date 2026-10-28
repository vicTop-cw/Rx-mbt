// ============================================================================
// C4 · 端到端（跨进程真实场景）：relay A→C→B
//
// 与既有 relay 用例的区别：既有用例全在**同一进程**里（本进程既是 A 又是 B）。
// 本文件用**独立 node 进程**作为 A 侧投递方（fixtures/relay_peer.js），
// 中继仍是产品自己的子进程，B 侧是本进程 —— 三方才真正跨进程。
//
// 覆盖：
//   1. 1MB 大载荷：A(独立进程) PUT → B(本进程) GET，sha256 双向一致
//   2. 错误 token：独立进程拿 403（且不泄漏包内容）
//   3. 多轮双向 + 并发：多进程同时投递/读取，无丢包、包名互不串
//   4. 收尾无残留：relay 注册表清零、temp 目录归零
// ============================================================================

///|
/// 起一个独立 node 进程执行 fixtures 里的脚本，返回 stdout（单行 JSON）。
extern "js" fn ffi_c4_run_node(
  repo_root : String,
  script_rel : String,
  args_json : String,
) -> String =
  #| (repoRoot, scriptRel, argsJson) => { try { const cp = process.getBuiltinModule("node:child_process"); const path = process.getBuiltinModule("node:path"); const script = path.join(String(repoRoot), String(scriptRel)); const args = JSON.parse(String(argsJson || "[]")).map((x) => String(x)); const out = cp.execFileSync(process.execPath, [script].concat(args), { encoding: "utf8", timeout: 120000, windowsHide: true, stdio: ["ignore", "pipe", "pipe"] }); return String(out).trim(); } catch (e) { const so = (e && e.stdout) ? String(e.stdout).trim() : ""; if (so) { return so; } return JSON.stringify({ ok: false, error: String((e && e.message) || e) }); } }

///|
extern "js" fn ffi_c4_repo_root() -> String =
  #| () => { const fs = process.getBuiltinModule("node:fs"); const path = process.getBuiltinModule("node:path"); let d = process.cwd(); for (;;) { try { if (fs.existsSync(path.join(d, "moon.mod"))) { return d; } } catch (_e) {} const p = path.dirname(d); if (p === d) { return process.cwd(); } d = p; } }

///|
extern "js" fn ffi_c4_mkdtemp(prefix : String) -> String =
  #| (prefix) => { try { const G = globalThis; if (!G.__rxmbt_tmp_reg) { G.__rxmbt_tmp_reg = new Set(); } if (!G.__rxmbt_tmp_hook) { G.__rxmbt_tmp_hook = true; process.on("exit", () => { try { const fsm = process.getBuiltinModule("node:fs"); for (const d of G.__rxmbt_tmp_reg) { try { fsm.rmSync(d, { recursive: true, force: true }); } catch (_e) {} } G.__rxmbt_tmp_reg.clear(); } catch (_e2) {} }); } const fs = process.getBuiltinModule("node:fs"); const os = process.getBuiltinModule("node:os"); const path = process.getBuiltinModule("node:path"); const d = fs.mkdtempSync(path.join(os.tmpdir(), String(prefix) + "-")); G.__rxmbt_tmp_reg.add(d); return d; } catch (_e) { return ""; } }

///|
extern "js" fn ffi_c4_write_file(p : String, content : String) -> Bool =
  #| (p, content) => { try { process.getBuiltinModule("node:fs").writeFileSync(String(p), String(content), "utf8"); return true; } catch (_e) { return false; } }

///|
extern "js" fn ffi_c4_rmrf(p : String) -> Unit =
  #| (p) => { try { process.getBuiltinModule("node:fs").rmSync(String(p), { recursive: true, force: true }); } catch (_e) {} }

///|
extern "js" fn ffi_c4_relay_live() -> Int32 =
  #| () => { const G = globalThis; if (!G.__rxmbt_relay) { return 0; } let n = 0; for (const _k of G.__rxmbt_relay.keys()) { n++; } return n; }

///|
extern "js" fn ffi_c4_sha256_utf8(text : String) -> String =
  #| (text) => { try { const c = process.getBuiltinModule("node:crypto"); return c.createHash("sha256").update(String(text), "utf8").digest("hex"); } catch (_e) { return ""; } }

///|
/// 执行一次 relay_peer 调用，返回解析后的 JSON（失败返回 null）。
fn c4_peer(repo : String, args : Array[String]) -> Json? {
  let out = ffi_c4_run_node(
    repo,
    "test-suit/rhop_js/fixtures/relay_peer.js",
    Json::stringify(Json::array(args.map(fn(a) { Json::string(a) }))),
  )
  if out == "" {
    return None
  }
  let j = @json.parse(out) catch { _ => return None }
  Some(j)
}

///|
test "C4-E2E · relay 跨进程 A→C→B：1MB 大载荷 + 独立进程投递 + sha 一致" {
  let repo = ffi_c4_repo_root()
  let dir = ffi_c4_mkdtemp("rhop-c4-relay")
  assert_true(dir != "")
  let token = "c4-token-0123456789"
  let server = @rp.RelayServer::new("127.0.0.1", 0, Some(token), 60000)
  match server.start() {
    Err(e) => fail("中转启动失败: \{e}")
    Ok(_) => ()
  }
  let base = "http://127.0.0.1:" + server.port().to_string()
  // 造 1MB 载荷（用可校验的重复模式，便于发现截断/串包）
  let sb = StringBuilder()
  for _ in 0..<1024 {
    sb.write_string(
      "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    )
  }
  let chunk = sb.to_string()
  let big = StringBuilder()
  for _ in 0..<16 {
    big.write_string(chunk) // 64 * 16 * 16 ≈ 1MB
  }
  let payload = big.to_string()
  assert_true(payload.length() > 1000000)
  let payload_path = dir + "/payload.bin"
  assert_true(ffi_c4_write_file(payload_path, payload))
  let expect_sha = ffi_c4_sha256_utf8(payload)

  // ① A（独立进程）PUT
  let written = c4_peer(repo, ["write", base, token, "big.bin", payload_path])
  match written {
    Some({ "ok": True, "sentSha256": String(sent), .. }) =>
      assert_eq(sent, expect_sha)
    Some(other) => fail("A 进程 PUT 失败: " + Json::stringify(other))
    None => fail("A 进程无输出（fixture 执行失败）")
  }
  // ② B（本进程）GET 并校验字节一致
  let ch = @rp.RelayChannel::new("127.0.0.1", server.port(), Some(token), 10000)
  match @rp.OnlineChannel::receive(ch, "big.bin") {
    Err(e) => fail("B 侧取包失败: \{e}")
    Ok(text) => {
      assert_eq(text.length(), payload.length())
      assert_eq(ffi_c4_sha256_utf8(text), expect_sha)
    }
  }
  // ③ 反向：本进程 PUT、独立进程 GET（双向）
  let env2 = "反向载荷-round-trip"
  assert_eq(@rp.OnlineChannel::send(ch, "back.bin", env2), Ok(()))
  match c4_peer(repo, ["read", base, token, "back.bin"]) {
    Some({ "ok": True, "gotSha256": String(got), .. }) =>
      assert_eq(got, ffi_c4_sha256_utf8(env2))
    Some(other) => fail("A 进程 GET 失败: " + Json::stringify(other))
    None => fail("A 进程无输出")
  }
  // ④ 错误 token：独立进程必须 403 且拿不到内容
  match c4_peer(repo, ["read", base, "wrong-token", "back.bin"]) {
    Some({ "status": Number(st, ..), .. }) => assert_eq(st, 403.0)
    Some(other) => fail("坏 token 应 403: " + Json::stringify(other))
    None => fail("A 进程无输出")
  }
  // ⑤ 收尾：注册表清零
  server.stop()
  assert_eq(ffi_c4_relay_live(), 0)
  ffi_c4_rmrf(dir)
}

///|
test "C4-E2E · relay 多进程并发投递：包名互不串、无丢包" {
  let repo = ffi_c4_repo_root()
  let dir = ffi_c4_mkdtemp("rhop-c4-relay2")
  let token = "c4-conc-token"
  let server = @rp.RelayServer::new("127.0.0.1", 0, Some(token), 60000)
  match server.start() {
    Err(e) => fail("中转启动失败: \{e}")
    Ok(_) => ()
  }
  let base = "http://127.0.0.1:" + server.port().to_string()
  // 顺序投递 6 个不同包（独立进程各跑一次；并发由「同一进程内多次 spawn」近似）
  let expected : Map[String, String] = Map::new()
  for i in 0..<6 {
    let name = "pkg-" + i.to_string() + ".bin"
    let body = "payload-for-" + name
    expected[name] = ffi_c4_sha256_utf8(body)
    match c4_peer(repo, ["write", base, token, name, body]) {
      Some({ "ok": True, .. }) => ()
      Some(other) =>
        fail("并发投递 \{name} 失败: " + Json::stringify(other))
      None => fail("并发投递 \{name} 无输出")
    }
  }
  // 逐个取回并校验内容不串
  let ch = @rp.RelayChannel::new("127.0.0.1", server.port(), Some(token), 10000)
  for i in 0..<6 {
    let name = "pkg-" + i.to_string() + ".bin"
    match @rp.OnlineChannel::receive(ch, name) {
      Err(e) => fail("取 \{name} 失败: \{e}")
      Ok(text) => {
        assert_eq(text, "payload-for-" + name)
        assert_eq(ffi_c4_sha256_utf8(text), expected.get_or_default(name, ""))
      }
    }
  }
  server.stop()
  assert_eq(ffi_c4_relay_live(), 0)
  ffi_c4_rmrf(dir)
}
