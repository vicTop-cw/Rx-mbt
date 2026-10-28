// ============================================================================
// rhop · 交互层端到端测试（js 目标：真实文件介质 + 真实 Fernet 加密）
//
// 覆盖（对照 vools tests/test_interact.py / test_actions.py + 契约 §3 Batch C、§4.1）：
//   1. config 的 js-only 正向分支：from_file / load_config(路径) /
//      _key_from_cfg 的 {"cipher"} 用外层密钥解（真 Fernet，正向）
//   2. session 的真实闭环：A(SEND) 写加密包 → 磁盘上无明文 → B(RECV) 解密得到原载荷；
//      错密钥 → BAD_TOKEN；reverse() 复用介质回传
//   3. 中转优先：RelayServer + config.relay → select() 选 relay → 经中转收发解密
//   4. interact 三模式：execute / request / roundtrip
//      （roundtrip = 单机闭环：发请求 → 同进程 handle_request 执行 → res_ 前缀回传 → 取回解密）
//   5. handle_request 的失败面：坏包 / 缺文件 / 空文件名 / 请求包缺 action
//   6. 边界四问：空 payload / 未知 mode / 未知 action / 空 filename
//   7. 动作最小注册表：register_action / list_actions / run_action 未知动作 /
//      omega_unwrap 的 Ω-gate 三态（纯逻辑，在 js 一并跑）
// ============================================================================

// ---------------------------------------------------------------------------
// 测试用 JS 辅助（临时目录 / 读写文件）
// ---------------------------------------------------------------------------

///|
extern "js" fn ffi_tmp(prefix : String) -> String =
  #| (prefix) => { try { const fs = process.getBuiltinModule("node:fs"); const os = process.getBuiltinModule("node:os"); const path = process.getBuiltinModule("node:path"); return fs.mkdtempSync(path.join(os.tmpdir(), String(prefix) + "-")); } catch (_e) { return ""; } }

///|
extern "js" fn ffi_write(p : String, content : String) -> Bool =
  #| (p, content) => { try { process.getBuiltinModule("node:fs").writeFileSync(String(p), String(content), "utf8"); return true; } catch (_e) { return false; } }

///|
extern "js" fn ffi_read(p : String) -> String =
  #| (p) => { try { return process.getBuiltinModule("node:fs").readFileSync(String(p), "utf8"); } catch (_e) { return ""; } }

///|
extern "js" fn ffi_exists(p : String) -> Bool =
  #| (p) => { try { return process.getBuiltinModule("node:fs").existsSync(String(p)); } catch (_e) { return false; } }

// ---------------------------------------------------------------------------
// 测试辅助
// ---------------------------------------------------------------------------

///|
/// 解析 JSON 文本（测试语料固定，解析失败直接 abort）。
fn itj(text : String) -> Json {
  @json.parse(text) catch {
    _ => abort("测试语料不是合法 JSON: \{text}")
  }
}

///|
/// 取 JSON 对象字段的字符串值。
fn it_str(j : Json, key : String) -> String {
  match j {
    Object(fields) =>
      match fields.get(key) {
        Some(String(s)) => s
        _ => "<not-string>"
      }
    _ => "<not-object>"
  }
}

///|
/// 取 JSON 对象字段。
fn it_field(j : Json, key : String) -> Json? {
  match j {
    Object(fields) => fields.get(key)
    _ => None
  }
}

///|
/// 取嵌套对象字段（a.b）。
fn it_str2(j : Json, a : String, b : String) -> String {
  match it_field(j, a) {
    Some(inner) => it_str(inner, b)
    None => "<no-such-field>"
  }
}

///|
/// 临时目录归一化（"/" 分隔，可直接写进 JSON 字符串与 file:// URL）。
fn it_dir(tag : String) -> String {
  let raw = ffi_tmp(tag)
  if raw == "" {
    abort("无法创建临时目录（node:fs 不可用）: " + tag)
  }
  @rp.normalize_path(raw)
}

///|
/// 组一份最小可交互配置：明文密钥 + 本地 shared 目录。
fn it_cfg_json(dir : String, key : String) -> Json {
  itj(
    "{\"name\": \"dev-A\", \"key\": \"" +
    key +
    "\", \"role\": \"SEND\", \"sftp\": {\"host\": \"jump.example\", \"port\": 10022, \"user\": \"ops\", \"dir\": \"/srv\"}, \"shared\": {\"write\": \"" +
    dir +
    "\"}}",
  )
}

///|
/// 解析配置（失败即 abort）。
fn it_cfg(data : Json) -> @rp.RhopConfig {
  match @rp.load_config(data) {
    Ok(c) => c
    Err(e) => abort("配置解析失败: " + e)
  }
}

// ---------------------------------------------------------------------------
// 1. config 的 js-only 正向分支
// ---------------------------------------------------------------------------

///|
test "interact · config.from_file / load_config(路径)：真实 JSON 文件（js）" {
  let dir = it_dir("rhop-it-cfg")
  let path = dir + "/rhop-config.json"
  let text = "{\"name\": \"dev-F\", \"key\": \"file-key\", \"role\": \"recv\", \"shared\": {\"write\": \"" +
    dir +
    "/share\"}}"
  assert_true(ffi_write(path, text))
  // from_file
  match @rp.RhopConfig::from_file(path) {
    Ok(c) => {
      assert_eq(c.name(), "dev-F")
      assert_eq(c.role(), @rp.Role::Recv)
      assert_eq(c.build_crypto().key_material(), "file-key")
    }
    Err(e) => abort("from_file 应当成功: " + e)
  }
  // load_config 接受「路径字符串」
  match @rp.load_config(Json::string(path)) {
    Ok(c) => assert_eq(c.name(), "dev-F")
    Err(e) => abort("load_config(路径) 应当成功: " + e)
  }
  // load_config 也接受「配置正文的字符串形态」
  match @rp.load_config(Json::string(text)) {
    Ok(c) => assert_eq(c.name(), "dev-F")
    Err(e) => abort("load_config(JSON 文本) 应当成功: " + e)
  }
  // 文件不是合法 JSON → 可诊断 Err
  let bad_path = dir + "/bad.json"
  assert_true(ffi_write(bad_path, "{not-json"))
  match @rp.RhopConfig::from_file(bad_path) {
    Ok(_) => abort("坏 JSON 文件应当 Err")
    Err(e) => assert_true(e.contains("不是合法 JSON"))
  }
}

///|
test "interact · _key_from_cfg 分支 3：{\"cipher\"} 用外层密钥解出主密钥（真 Fernet）" {
  let outer_key = "outer-key-for-unlock"
  let inner_key = "inner-main-key-42"
  let cipher = @rp.RhopCrypto::from_key(outer_key).encrypt_secret(inner_key)
  assert_true(cipher.has_prefix("RHOP-ENC:"))
  // 3a) 外层密钥由 source 直接给
  let cfg_text = "{\"key\": {\"cipher\": \"" + cipher + "\", \"source\": \"" + outer_key + "\"}}"
  let c = it_cfg(itj(cfg_text))
  assert_eq(c.build_crypto().key_material(), inner_key)
  // 3b) 外层密钥由密钥文件给（path 分支）
  let dir = it_dir("rhop-it-key")
  let key_path = dir + "/outer.key"
  assert_true(ffi_write(key_path, outer_key + "\n"))
  let cfg_text2 = "{\"key\": {\"cipher\": \"" +
    cipher +
    "\", \"path\": \"" +
    key_path +
    "\"}}"
  let c2 = it_cfg(itj(cfg_text2))
  assert_eq(c2.build_crypto().key_material(), inner_key)
  // 3c) 外层密钥不对 → 可诊断 Err（不是静默返回密文）
  let cfg_text3 = "{\"key\": {\"cipher\": \"" +
    cipher +
    "\", \"source\": \"wrong-outer-key\"}}"
  match @rp.load_config(itj(cfg_text3)) {
    Ok(_) => abort("错外层密钥应当 Err")
    Err(e) => assert_true(e.contains("key.cipher 解密失败"))
  }
  // 3d) 明文 {"plain"} 与纯字符串等价
  let c4 = it_cfg(itj("{\"key\": {\"plain\": \"plain-direct\"}}"))
  assert_eq(c4.build_crypto().key_material(), "plain-direct")
}

// ---------------------------------------------------------------------------
// 2. session 真实闭环（js：LocalSharedPath + Fernet）
// ---------------------------------------------------------------------------

///|
test "interact · session 闭环：A 写加密包（磁盘无明文）→ B 解密还原载荷" {
  let dir = it_dir("rhop-it-session")
  let key = "session-shared-key"
  let payload = itj("{\"task\": \"demo\", \"n\": 7, \"msg\": \"你好 会话\"}")
  // A 端（SEND）
  let a = match
    it_cfg(it_cfg_json(dir, key)).build_session(role=@rp.Role::Send) {
    Ok(s) => s
    Err(e) => abort("A 端会话应当构造成功: " + e)
  }
  // B 端（RECV；独立 crypto 对象但同一把 key）
  let b = match
    it_cfg(it_cfg_json(dir, key)).build_session(role=@rp.Role::Recv) {
    Ok(s) => s
    Err(e) => abort("B 端会话应当构造成功: " + e)
  }
  let sent = match a.send_package("pkg-1.rhop", payload) {
    Ok(v) => v
    Err(e) => abort("A 端发送应当成功: " + e)
  }
  assert_eq(it_str(sent, "status"), "ok")
  assert_eq(it_str(sent, "transport"), "shared")
  assert_eq(it_str(sent, "filename"), "pkg-1.rhop")
  assert_eq(it_str(sent, "role"), "SEND")
  // 磁盘上必须是密文信封，不能出现明文片段
  let on_disk = ffi_read(dir + "/pkg-1.rhop")
  assert_true(on_disk.contains("\"alg\": \"fernet\""))
  assert_false(on_disk.contains("demo"))
  assert_false(on_disk.contains("你好 会话"))
  // B 端取包解密
  let got = match b.recv_package("pkg-1.rhop") {
    Ok(v) => v
    Err(e) => abort("B 端接收应当成功: " + e)
  }
  assert_eq(it_str(got, "status"), "ok")
  assert_eq(it_str(got, "transport"), "shared")
  match it_field(got, "payload") {
    Some(p) => assert_eq(Json::stringify(p), Json::stringify(payload))
    None => abort("B 端回执缺 payload")
  }
  // 错密钥 → BAD_TOKEN 错误回执（不是 Err、也不是静默成功）
  let wrong = match
    it_cfg(it_cfg_json(dir, "another-key")).build_session(role=@rp.Role::Recv) {
    Ok(s) => s
    Err(e) => abort("错误密钥会话应当仍能构造: " + e)
  }
  match wrong.recv_package("pkg-1.rhop") {
    Ok(j) => {
      assert_eq(it_str(j, "status"), "error")
      assert_eq(it_str(j, "reason"), "BAD_TOKEN")
    }
    Err(e) => abort("错密钥应当是 status:error 回执: " + e)
  }
}

///|
test "interact · session.reverse()：B 端换角色复用同一介质回传，A 端取回解密" {
  let dir = it_dir("rhop-it-reverse")
  let key = "reverse-key"
  let cfg = it_cfg(it_cfg_json(dir, key))
  let a = match cfg.build_session(role=@rp.Role::Send) {
    Ok(s) => s
    Err(e) => abort("A 端会话: " + e)
  }
  let b = match cfg.build_session(role=@rp.Role::Recv) {
    Ok(s) => s
    Err(e) => abort("B 端会话: " + e)
  }
  // A → req.rhop
  let req = itj("{\"action\": \"jump.probe\", \"payload\": {}}")
  match a.send_package("req-x.rhop", req) {
    Ok(_) => ()
    Err(e) => abort("A 发送: " + e)
  }
  match b.recv_package("req-x.rhop") {
    Ok(j) => assert_eq(it_str(j, "status"), "ok")
    Err(e) => abort("B 接收: " + e)
  }
  // B reverse 成 SEND 回传（介质/密钥原样复用）
  let b_sender = b.reverse()
  assert_eq(b_sender.role(), @rp.Role::Send)
  match b_sender.send_package("res-x.rhop", itj("{\"result\": \"done\"}")) {
    Ok(v) => assert_eq(it_str(v, "transport"), "shared")
    Err(e) => abort("B 回传: " + e)
  }
  // A reverse 成 RECV 取回
  let a_receiver = a.reverse()
  assert_eq(a_receiver.role(), @rp.Role::Recv)
  match a_receiver.recv_package("res-x.rhop") {
    Ok(j) => {
      assert_eq(it_str(j, "status"), "ok")
      match it_field(j, "payload") {
        Some(p) => assert_eq(it_str(p, "result"), "done")
        None => abort("A 取回缺 payload")
      }
    }
    Err(e) => abort("A 取回: " + e)
  }
}

///|
test "interact · 通道链：配置 relay 后 select() 走 relay，经中转收发并解密" {
  let token = "it-relay-token"
  let server = @rp.RelayServer::new("127.0.0.1", 0, Some(token), 20000)
  match server.start() {
    Err(e) => abort("中转服务启动失败: " + e)
    Ok(_) => ()
  }
  let port = server.port()
  assert_true(port > 0)
  let cfg = it_cfg(
    itj(
      "{\"key\": \"relay-key\", \"shared\": {\"write\": \"" +
      it_dir("rhop-it-relay-share") +
      "\"}, \"relay\": {\"host\": \"127.0.0.1\", \"port\": " +
      port.to_string() +
      ", \"token\": \"" +
      token +
      "\", \"timeout\": 3.0}}",
    ),
  )
  let a = match cfg.build_session(role=@rp.Role::Send) {
    Ok(s) => s
    Err(e) => abort("A 端会话: " + e)
  }
  let b = match cfg.build_session(role=@rp.Role::Recv) {
    Ok(s) => s
    Err(e) => abort("B 端会话: " + e)
  }
  // 通道链最高优先级是 relay（即便 shared 也配置了）
  let sel = a.select()
  assert_eq(sel.transport, "relay")
  assert_true(sel.is_online)
  assert_eq(sel.label, "relay:http://127.0.0.1:\{port}")
  let payload = itj("{\"via\": \"relay\", \"n\": 1}")
  let sent = match a.send_package("relay-pkg.rhop", payload) {
    Ok(v) => v
    Err(e) => abort("A 经中转发送: " + e)
  }
  assert_eq(it_str(sent, "transport"), "relay")
  let got = match b.recv_package("relay-pkg.rhop") {
    Ok(v) => v
    Err(e) => abort("B 经中转接收: " + e)
  }
  assert_eq(it_str(got, "transport"), "relay")
  match it_field(got, "payload") {
    Some(p) => assert_eq(Json::stringify(p), Json::stringify(payload))
    None => abort("中转回执缺 payload")
  }
  server.stop()
}

// ---------------------------------------------------------------------------
// 3. interact 三模式
// ---------------------------------------------------------------------------

///|
test "interact · execute：本端直接执行 jump.probe（离线实现，不真连网）" {
  let dir = it_dir("rhop-it-exec")
  let cfg = it_cfg(it_cfg_json(dir, "k"))
  match @rp.interact(cfg, "jump.probe", None, "execute") {
    Ok(j) => {
      // omega_unwrap 后拿到的就是动作内层出参
      assert_eq(it_str(j, "status"), "ok")
      assert_eq(json_bool_str(j, "reachable"), "false")
      assert_eq(it_str(j, "transport"), "offline")
      assert_eq(it_str(j, "host"), "jump.example")
      assert_eq(json_bool_str(j, "offline"), "true")
      // 端口透出（配置里是数字）
      assert_eq(json_num_str(j, "port"), "10022")
    }
    Err(e) => abort("execute 应当成功: " + e)
  }
  // 大小写不敏感的 mode
  match @rp.interact(cfg, "jump.probe", None, "EXECUTE") {
    Ok(j) => assert_eq(it_str(j, "status"), "ok")
    Err(e) => abort("大写 mode 应当成功: " + e)
  }
  // 边界：缺 sftp.host 时 reachable=false 且 transport=none（不是崩溃）
  let no_sftp = it_cfg(itj("{\"key\": \"k\"}"))
  match @rp.interact(no_sftp, "jump.probe", None, "execute") {
    Ok(j) => {
      assert_eq(json_bool_str(j, "reachable"), "false")
      assert_eq(it_str(j, "transport"), "none")
      assert_true(it_str(j, "detail").contains("缺少 sftp.host"))
    }
    Err(e) => abort("缺 sftp.host 时 execute 应当成功（离线探测）: " + e)
  }
}

///|
test "interact · execute：未知 action 返回可诊断错误结构（omega_gate 分类）" {
  let cfg = it_cfg(itj("{\"key\": \"k\"}"))
  match @rp.interact(cfg, "no.such.action", None, "execute") {
    Ok(j) => {
      assert_eq(it_str(j, "status"), "error")
      match it_field(j, "omega_gate") {
        Some(gate) => {
          let msg = it_str(gate, "error")
          assert_true(msg.contains("未知动作"))
          assert_true(msg.contains("jump.probe")) // 可用动作清单
        }
        None => abort("错误结构应带 omega_gate")
      }
    }
    Err(e) => abort("未知 action 不应抛 Err: " + e)
  }
}

///|
test "interact · request：加密动作包投递到介质（磁盘上是密文）" {
  let dir = it_dir("rhop-it-req")
  let cfg = it_cfg(it_cfg_json(dir, "req-key"))
  match @rp.interact(cfg, "jump.probe", None, "request") {
    Ok(j) => {
      assert_eq(it_str(j, "status"), "ok")
      assert_eq(it_str(j, "transport"), "shared")
      // 缺省请求包名：req_<action 的点换下划线>.rhop
      assert_eq(it_str(j, "filename"), "req_jump_probe.rhop")
      let on_disk = ffi_read(dir + "/req_jump_probe.rhop")
      assert_true(on_disk.contains("\"alg\": \"fernet\""))
      assert_false(on_disk.contains("jump.probe"))
    }
    Err(e) => abort("request 应当成功: " + e)
  }
  // 自定义请求包名
  match @rp.interact(cfg, "jump.probe", None, "request", request_filename="custom-req.rhop") {
    Ok(j) => {
      assert_eq(it_str(j, "filename"), "custom-req.rhop")
      assert_true(ffi_exists(dir + "/custom-req.rhop"))
    }
    Err(e) => abort("自定义文件名 request 应当成功: " + e)
  }
  // 边界：空白 request_filename 回退缺省名
  match @rp.interact(cfg, "jump.probe", None, "request", request_filename="   ") {
    Ok(j) => assert_eq(it_str(j, "filename"), "req_jump_probe.rhop")
    Err(e) => abort("空白文件名应当回退缺省: " + e)
  }
}

///|
test "interact · roundtrip：单机闭环（发请求 → handle_request 执行 → res_ 回传 → 取回解密）" {
  let dir = it_dir("rhop-it-round")
  let cfg = it_cfg(it_cfg_json(dir, "round-key"))
  let payload = itj("{\"probe_target\": \"jump\"}")
  match @rp.interact(cfg, "jump.probe", Some(payload), "roundtrip") {
    Ok(j) => {
      assert_eq(it_str(j, "status"), "ok")
      assert_eq(it_str(j, "transport"), "shared")
      assert_eq(it_str(j, "filename"), "req_jump_probe.rhop")
      // 响应包名固定 res_ 前缀
      assert_eq(it_str(j, "response_filename"), "res_req_jump_probe.rhop")
      assert_eq(it_str(j, "response_transport"), "shared")
      // result 是动作内层 status；action_result 是完整内层出参
      assert_eq(it_str(j, "result"), "ok")
      match it_field(j, "action_result") {
        Some(ar) => {
          assert_eq(it_str(ar, "status"), "ok")
          assert_eq(it_str(ar, "transport"), "offline")
          assert_eq(it_str(ar, "host"), "jump.example")
        }
        None => abort("roundtrip 缺 action_result")
      }
      // 介质上确实留下了请求包与响应包
      assert_true(ffi_exists(dir + "/req_jump_probe.rhop"))
      assert_true(ffi_exists(dir + "/res_req_jump_probe.rhop"))
    }
    Err(e) => abort("roundtrip 应当成功: " + e)
  }
  // 边界：空 payload（None）也能跑通
  match @rp.interact(cfg, "jump.probe", None, "roundtrip") {
    Ok(j) => assert_eq(it_str(j, "status"), "ok")
    Err(e) => abort("空 payload roundtrip 应当成功: " + e)
  }
}

///|
test "interact · 未知 mode / 未知动作在 roundtrip 下的可诊断行为" {
  let dir = it_dir("rhop-it-bad")
  let cfg = it_cfg(it_cfg_json(dir, "k"))
  // 未知 mode → Err（配置/参数类错误）
  match @rp.interact(cfg, "jump.probe", None, "do-something") {
    Ok(_) => abort("未知 mode 应当 Err")
    Err(e) => {
      assert_true(e.contains("未知 mode"))
      assert_true(e.contains("execute/request/roundtrip"))
    }
  }
  // 空 mode 同样 Err（不静默当 execute）
  match @rp.interact(cfg, "jump.probe", None, "") {
    Ok(_) => abort("空 mode 应当 Err")
    Err(e) => assert_true(e.contains("未知 mode"))
  }
  // 未知动作走 roundtrip：请求包发出 → 对端执行为错误 → 本端仍取回可诊断结果
  match @rp.interact(cfg, "no.such.action", None, "roundtrip") {
    Ok(j) => {
      assert_eq(it_str(j, "status"), "ok")
      // 回传的 result 是内层 error 状态，action_result 带 omega_gate
      assert_eq(it_str(j, "result"), "error")
      match it_field(j, "action_result") {
        Some(ar) => match it_field(ar, "omega_gate") {
          Some(gate) => assert_true(it_str(gate, "error").contains("未知动作"))
          None => abort("未知动作的 action_result 应带 omega_gate")
        }
        None => abort("roundtrip 缺 action_result")
      }
    }
    Err(e) => abort("未知动作 roundtrip 不应抛 Err: " + e)
  }
}

// ---------------------------------------------------------------------------
// 4. handle_request 的失败面
// ---------------------------------------------------------------------------

///|
test "interact · handle_request：坏包 / 缺文件 / 空文件名 / 缺 action 均给可诊断回执" {
  let dir = it_dir("rhop-it-handle")
  let cfg = it_cfg(it_cfg_json(dir, "handle-key"))
  // 1) 空文件名
  match @rp.handle_request(cfg, "") {
    Ok(j) => {
      assert_eq(it_str(j, "status"), "error")
      assert_true(it_str(j, "reason").contains("filename 不能为空"))
    }
    Err(e) => abort("空文件名不应抛 Err: " + e)
  }
  // 2) 缺文件
  match @rp.handle_request(cfg, "nope.rhop") {
    Ok(j) => {
      assert_eq(it_str(j, "status"), "error")
      assert_true(it_str(j, "reason").contains("读取失败"))
    }
    Err(e) => abort("缺文件不应抛 Err: " + e)
  }
  // 3) 坏包（不是 JSON 信封）
  assert_true(ffi_write(dir + "/garbage.rhop", "not-a-envelope"))
  match @rp.handle_request(cfg, "garbage.rhop") {
    Ok(j) => {
      assert_eq(it_str(j, "status"), "error")
      assert_eq(it_str(j, "reason"), "MALFORMED")
    }
    Err(e) => abort("坏包不应抛 Err: " + e)
  }
  // 4) 合法加密包但缺 action 字段
  let writer = match cfg.build_session(role=@rp.Role::Send) {
    Ok(s) => s
    Err(e) => abort("写端会话: " + e)
  }
  match writer.send_package("no-action.rhop", itj("{\"payload\": {\"x\": 1}}")) {
    Ok(_) => ()
    Err(e) => abort("写无 action 请求包: " + e)
  }
  match @rp.handle_request(cfg, "no-action.rhop") {
    Ok(j) => {
      assert_eq(it_str(j, "status"), "error")
      assert_true(it_str(j, "reason").contains("请求包缺少 action 字段"))
    }
    Err(e) => abort("缺 action 不应抛 Err: " + e)
  }
  // 5) 显式传入 session 形态（等价于缺省构造）
  let receiver = match cfg.build_session(role=@rp.Role::Recv) {
    Ok(s) => s
    Err(e) => abort("读端会话: " + e)
  }
  match writer.send_package("ok-req.rhop", itj("{\"action\": \"jump.probe\"}")) {
    Ok(_) => ()
    Err(e) => abort("写请求包: " + e)
  }
  match @rp.handle_request(cfg, "ok-req.rhop", session=receiver) {
    Ok(j) => {
      assert_eq(it_str(j, "status"), "ok")
      assert_eq(it_str(j, "action"), "jump.probe")
      assert_eq(it_str(j, "response_filename"), "res_ok-req.rhop")
      assert_eq(it_str(j, "response_sent"), "ok")
    }
    Err(e) => abort("显式 session 的 handle_request 应当成功: " + e)
  }
}

// ---------------------------------------------------------------------------
// 5. 动作最小注册表（纯逻辑，随 js 一并跑）
// ---------------------------------------------------------------------------

///|
/// 测试用动作：把 payload 原样回显，并带上内层 status。
fn echo_action(cfg : Json, payload : Json?) -> Json {
  let _ = cfg
  Json::object({
    "status": Json::string("ok"),
    "echo": match payload {
      Some(p) => p
      None => Json::null()
    },
  })
}

///|
/// 测试用动作：内层报 error（用于 omega_unwrap 的失败分支）。
fn failing_action(cfg : Json, payload : Json?) -> Json {
  let _ = cfg
  let _ = payload
  Json::object({ "status": Json::string("error"), "why": Json::string("boom") })
}

///|
/// 测试用动作：内层报 partial（Ω-gate 把 partial 也算成功）。
fn partial_action(cfg : Json, payload : Json?) -> Json {
  let _ = cfg
  let _ = payload
  Json::object({ "status": Json::string("partial"), "done": Json::number(1.0) })
}

///|
test "interact · 动作注册表：register/list/run + 覆盖内置动作" {
  // 初始可见内置动作
  let names = @rp.list_actions()
  assert_true(names.contains("jump.probe"))
  // 注册新动作
  @rp.register_action("test.echo", echo_action)
  assert_true(@rp.list_actions().contains("test.echo"))
  let r = @rp.run_action("test.echo", itj("{}"), Some(itj("{\"a\": 1}")))
  assert_eq(it_str(r, "status"), "ok")
  assert_eq(it_str(r, "action"), "test.echo")
  // omega_unwrap 直接取内层
  let inner = @rp.omega_unwrap(r)
  assert_eq(it_str(inner, "status"), "ok")
  match it_field(inner, "echo") {
    Some(e) => assert_eq(Json::stringify(e), "{\"a\":1}")
    None => abort("echo 缺字段")
  }
  // 同名重复注册 = 覆盖旧处理器（注册表语义）；这里用自建动作名，不污染内置动作
  @rp.register_action("test.echo", partial_action)
  let overridden = @rp.omega_unwrap(
    @rp.run_action("test.echo", itj("{}"), Some(itj("{\"b\": 2}"))),
  )
  assert_eq(it_str(overridden, "status"), "partial")
  // 恢复成 echo 处理器（幂等覆盖，保持后续测试语义清晰）
  @rp.register_action("test.echo", echo_action)
}

///|
test "interact · omega_unwrap：ok / partial 判成功，error 与结构破损挂 omega_gate" {
  // 1) ok → 内层
  let ok_env = Json::object({
    "status": Json::string("ok"),
    "action": Json::string("a"),
    "data": Json::object({ "status": Json::string("ok"), "v": Json::number(1.0) }),
  })
  assert_eq(it_str(@rp.omega_unwrap(ok_env), "status"), "ok")
  // 2) partial 也算成功（契约 C2.2）
  @rp.register_action("test.partial", partial_action)
  let part = @rp.omega_unwrap(@rp.run_action("test.partial", itj("{}"), None))
  assert_eq(it_str(part, "status"), "partial")
  // 3) 内层 error → 外层 error + omega_gate 带内层数据
  @rp.register_action("test.fail", failing_action)
  let failed = @rp.omega_unwrap(@rp.run_action("test.fail", itj("{}"), None))
  assert_eq(it_str(failed, "status"), "error")
  match it_field(failed, "omega_gate") {
    Some(gate) => {
      assert_eq(it_str(gate, "action"), "test.fail")
      assert_true(it_str(gate, "error").contains("内层 status=error"))
    }
    None => abort("失败结果应带 omega_gate")
  }
  // 4) 外层不是 ok → omega_gate
  let outer_bad = @rp.omega_unwrap(
    Json::object({
      "status": Json::string("error"),
      "omega_gate": Json::object({ "error": Json::string("外层挂了") }),
    }),
  )
  assert_eq(it_str(outer_bad, "status"), "error")
  match it_field(outer_bad, "omega_gate") {
    Some(gate) => assert_eq(it_str(gate, "error"), "外层挂了")
    None => abort("外层错误应带 omega_gate")
  }
  // 5) 结构破损：内层 data 缺失 / 非对象
  let no_data = @rp.omega_unwrap(
    Json::object({
      "status": Json::string("ok"),
      "action": Json::string("x"),
    }),
  )
  assert_eq(it_str(no_data, "status"), "error")
  let scalar = @rp.omega_unwrap(Json::string("nope"))
  assert_eq(it_str(scalar, "status"), "error")
  // 6) run_action 未知动作结构自洽
  let unknown = @rp.run_action("nope", itj("{}"), None)
  assert_eq(it_str(unknown, "status"), "error")
  match it_field(unknown, "data") {
    Some(v) => assert_eq(Json::stringify(v), "null")
    None => abort("未知动作应保留 data:null 键位")
  }
}

// ---------------------------------------------------------------------------
// 小工具：把布尔/数字字段字符串化（避免 Json 相等比较）
// ---------------------------------------------------------------------------

///|
fn json_bool_str(j : Json, key : String) -> String {
  match it_field(j, key) {
    Some(True) => "true"
    Some(False) => "false"
    Some(_) => "<not-bool>"
    None => "<missing>"
  }
}

///|
fn json_num_str(j : Json, key : String) -> String {
  match it_field(j, key) {
    Some(v) =>
      match v {
        Number(_, ..) => Json::stringify(v)
        _ => "<not-number>"
      }
    None => "<missing>"
  }
}
