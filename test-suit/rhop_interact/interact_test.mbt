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
  let cfg_text = "{\"key\": {\"cipher\": \"" +
    cipher +
    "\", \"source\": \"" +
    outer_key +
    "\"}}"
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
  let payload = itj(
    "{\"task\": \"demo\", \"n\": 7, \"msg\": \"你好 会话\"}",
  )
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
    Err(e) =>
      abort("缺 sftp.host 时 execute 应当成功（离线探测）: " + e)
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
  match
    @rp.interact(
      cfg,
      "jump.probe",
      None,
      "request",
      request_filename="custom-req.rhop",
    ) {
    Ok(j) => {
      assert_eq(it_str(j, "filename"), "custom-req.rhop")
      assert_true(ffi_exists(dir + "/custom-req.rhop"))
    }
    Err(e) => abort("自定义文件名 request 应当成功: " + e)
  }
  // 边界：空白 request_filename 回退缺省名
  match
    @rp.interact(cfg, "jump.probe", None, "request", request_filename="   ") {
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
      // 请求包留在介质上；响应包已被一次性消费（C1-F1：取回后删除，防陈旧回放）
      assert_true(ffi_exists(dir + "/req_jump_probe.rhop"))
      assert_true(!ffi_exists(dir + "/res_req_jump_probe.rhop"))
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
        Some(ar) =>
          match it_field(ar, "omega_gate") {
            Some(gate) =>
              assert_true(it_str(gate, "error").contains("未知动作"))
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
  match
    writer.send_package("no-action.rhop", itj("{\"payload\": {\"x\": 1}}")) {
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
  match
    writer.send_package("ok-req.rhop", itj("{\"action\": \"jump.probe\"}")) {
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
    "data": Json::object({
      "status": Json::string("ok"),
      "v": Json::number(1.0),
    }),
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
    Json::object({ "status": Json::string("ok"), "action": Json::string("x") }),
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

// ---------------------------------------------------------------------------
// 14. C1-F2：包名白名单（穿越不可达）
// ---------------------------------------------------------------------------

///|
test "interact · 包名白名单：穿越名 Err 不落盘、缺省名按 action 净化（C1-F2）" {
  let dir = it_dir("rhop-it-fname")
  let cfg = it_cfg(it_cfg_json(dir, "k"))
  for bad in ["../escaped.rhop", "sub/dir.rhop", "..\\up.rhop"] {
    match
      @rp.interact(cfg, "jump.probe", None, "request", request_filename=bad) {
      Ok(j) => abort("非法包名不应发送成功: " + Json::stringify(j))
      Err(e) => assert_true(e.contains("包文件名"))
    }
  }
  // 根目录外没有落下任何东西
  assert_true(!ffi_exists(dir + "/../escaped.rhop"))
  // 缺省名：动作名里的分隔符被净化成 _
  match @rp.interact(cfg, "jump/probe", None, "request") {
    Ok(j) => {
      assert_eq(it_str(j, "status"), "ok")
      assert_eq(it_str(j, "filename"), "req_jump_probe.rhop")
      assert_true(ffi_exists(dir + "/req_jump_probe.rhop"))
    }
    Err(e) => abort("带分隔符的动作名应净化后成功: " + e)
  }
}

// ---------------------------------------------------------------------------
// 15. C1-F1：roundtrip 一次性语义（陈旧 res_ 不采信、取回即删）
// ---------------------------------------------------------------------------

///|
test "interact · roundtrip：预置陈旧 res_ 不被采信，取回后删除（C1-F1）" {
  let dir = it_dir("rhop-it-once")
  let cfg = it_cfg(it_cfg_json(dir, "once-key"))
  let crypto = @rp.RhopCrypto::from_key("once-key")
  // 预置「上一轮」的合法密文响应（token 是旧的）
  let stale_body = itj(
    "{\"action\": \"rhop.echo\", \"result\": \"ok\", \"action_result\": {\"status\": \"ok\", \"marker\": \"stale-run\"}, \"token\": \"tok:0:req_rhop_echo.rhop:rhop.echo\"}",
  )
  let stale_cipher = match crypto.encrypt_json_result(stale_body) {
    Ok(t) => t
    Err(e) => abort("预置密文失败: " + e)
  }
  assert_true(ffi_write(dir + "/res_req_rhop_echo.rhop", stale_cipher))
  // 连续两轮同文件名：每轮都必须拿到自己的 payload
  for marker in ["fresh-run-1", "fresh-run-2"] {
    let payload = itj("{\"marker\": \"" + marker + "\"}")
    match @rp.interact(cfg, "rhop.echo", Some(payload), "roundtrip") {
      Ok(j) => {
        assert_eq(it_str(j, "status"), "ok")
        match it_field(j, "action_result") {
          Some(ar) =>
            match it_field(ar, "payload") {
              Some(p) => assert_eq(it_str(p, "marker"), marker)
              None => abort("action_result 缺 payload")
            }
          None => abort("roundtrip 缺 action_result")
        }
        // 一次性消费：响应包不留存
        assert_true(!ffi_exists(dir + "/res_req_rhop_echo.rhop"))
      }
      Err(e) => abort("roundtrip 应当成功: " + e)
    }
  }
}

///|
test "interact · roundtrip：发送失败立即 error(phase=send)，不返回上一轮结果（C1-F1）" {
  let dir = it_dir("rhop-it-sendfail")
  // 用普通文件挡住写端：shared.write 的父路径是文件 → 写入必失败。
  //
  // 平台无关性（WSL/Linux 回归）：探测判「写端可用」的依据是**父路径存在**，
  // 不是「父路径是目录」—— Windows(Win32 词法归一的 `x/..`) 与 POSIX
  // （字符串求父路径 + existsSync，见 rhop/session.mbt 的 sp_write_parent_exists）
  // 都得到「父存在 → 可写」，于是真正写入时才失败 → 走 status:error 收据。
  assert_true(ffi_write(dir + "/blocker", "not-a-dir"))
  let cfg = it_cfg(
    itj(
      "{\"key\": \"k\", \"role\": \"SEND\", \"shared\": {\"write\": \"" +
      dir +
      "/blocker/sub\"}}",
    ),
  )
  let payload = itj("{\"marker\": \"run1\"}")
  match @rp.interact(cfg, "rhop.echo", Some(payload), "roundtrip") {
    Ok(j) => {
      assert_eq(it_str(j, "status"), "error")
      assert_eq(it_str(j, "phase"), "send")
      // 绝不能把上一轮（或预置）结果当本轮结果
      assert_true(!Json::stringify(j).contains("run1"))
      assert_eq(it_str2(j, "detail", "status"), "error")
    }
    Err(e) => abort("发送失败应走 status:error 收据而非 Err: " + e)
  }
}

// ---------------------------------------------------------------------------
// 16. C1-F4：handle_request 回执写失败不得 status:ok
// ---------------------------------------------------------------------------

///|
test "interact · handle_request：回执写失败 → status:error + phase=response（C1-F4）" {
  let dir = it_dir("rhop-it-resfail")
  let cfg = it_cfg(it_cfg_json(dir, "k"))
  // 用正常写端准备请求包
  let producer = match cfg.build_session(role=@rp.Role::Send) {
    Ok(s) => s
    Err(e) => abort("构造发送会话失败: " + e)
  }
  let request = itj("{\"action\": \"jump.probe\", \"payload\": {}}")
  match producer.send_package("req_x.rhop", request) {
    Ok(j) => assert_eq(it_str(j, "status"), "ok")
    Err(e) => abort("请求包写入失败: " + e)
  }
  // 接收端：读端正常、写端落在「父路径是文件」的位置 → 回执写必然失败。
  // 同 F1 用例：两平台都先判「父存在 → 写端可用」，再在真正写回执时失败，
  // 因此 handle_request 必须回 status:error + phase=response（而不是 Err）。
  assert_true(ffi_write(dir + "/blocker", "x"))
  let read_sp : &@rp.SharedPath = @rp.LocalSharedPath::new(dir)
  let write_sp : &@rp.SharedPath = @rp.LocalSharedPath::new(
    dir + "/blocker/sub",
  )
  let view = @rp.make_shared_path_from_views(write_sp, Some(read_sp))
  let receiver = @rp.Session::new(
    @rp.Role::Recv,
    Some(view),
    [],
    None,
    Some(@rp.RhopCrypto::from_key("k")),
    "b",
  )
  match @rp.handle_request(cfg, "req_x.rhop", session=receiver) {
    Ok(j) => {
      assert_eq(it_str(j, "status"), "error")
      assert_eq(it_str(j, "phase"), "response")
      assert_eq(it_str2(j, "detail", "status"), "error")
    }
    Err(e) => abort("回执写失败应走 status:error 收据而非 Err: " + e)
  }
}

// ---------------------------------------------------------------------------
// 17. C1-F5：探测无副作用 + 只读接收端可收
// ---------------------------------------------------------------------------

///|
test "interact · available()/select() 不建目录；只读接收端可收（C1-F5）" {
  let dir = it_dir("rhop-it-noside")
  let fresh = dir + "/fresh"
  let cfg = it_cfg(
    itj(
      "{\"key\": \"k\", \"role\": \"SEND\", \"shared\": {\"write\": \"" +
      fresh +
      "\"}}",
    ),
  )
  let s = match cfg.build_session(role=@rp.Role::Send) {
    Ok(s) => s
    Err(e) => abort("构造会话失败: " + e)
  }
  assert_true(!ffi_exists(fresh))
  // 父目录存在 → 写端可用；但探测本身不能建目录。
  //
  // 平台无关性（WSL/Linux 回归）：`fresh/..` 在 POSIX 下是 ENOENT（不做词法归一），
  // 只靠 exists("..") 会在 Linux/WSL 上误判不可用；产品侧已改为
  // 「exists(".") || exists("..") || 本地根父路径 existsSync」，两平台一致为 true。
  assert_true(s.available())
  assert_true(!ffi_exists(fresh))
  assert_eq(s.select().transport, "shared")
  assert_true(!ffi_exists(fresh))
  // 真正发送时才创建目录
  match s.send_package("pkg.rhop", Json::object(Map([]))) {
    Ok(j) => assert_eq(it_str(j, "status"), "ok")
    Err(e) => abort("发送失败: " + e)
  }
  assert_true(ffi_exists(fresh + "/pkg.rhop"))
  // 只读接收端：read=dir 可读、write 指向「父路径是文件」的不可写位置
  let producer = match
    it_cfg(it_cfg_json(dir, "k")).build_session(role=@rp.Role::Send) {
    Ok(s) => s
    Err(e) => abort("构造发送会话失败: " + e)
  }
  match producer.send_package("ro.rhop", Json::object(Map([]))) {
    Ok(j) => assert_eq(it_str(j, "status"), "ok")
    Err(e) => abort("只读用例的请求包写入失败: " + e)
  }
  assert_true(ffi_write(dir + "/blocker2", "x"))
  let ro_cfg = it_cfg(
    itj(
      "{\"key\": \"k\", \"role\": \"RECV\", \"shared\": {\"write\": \"" +
      dir +
      "/blocker2/sub\", \"read\": \"" +
      dir +
      "\"}}",
    ),
  )
  let receiver = match ro_cfg.build_session(role=@rp.Role::Recv) {
    Ok(s) => s
    Err(e) => abort("构造接收会话失败: " + e)
  }
  match receiver.recv_package("ro.rhop") {
    Ok(j) => assert_eq(it_str(j, "status"), "ok")
    Err(e) => abort("只读介质应当能接收: " + e)
  }
}

///|
test "interact · 只读介质：接收端能收、发送端给出「写端不可用」专门 Err（C1-F5）" {
  let dir = it_dir("rhop-it-readonly")
  assert_true(ffi_write(dir + "/blocker3", "x"))
  // read=dir 可读；write 落在「父路径是文件」的位置 → 写端不可用
  let cfg = it_cfg(
    itj(
      "{\"key\": \"k\", \"role\": \"SEND\", \"shared\": {\"write\": \"" +
      dir +
      "/blocker3/sub\", \"read\": \"" +
      dir +
      "\"}}",
    ),
  )
  // 先由正常写端投递一个包，再让只读接收端取
  let producer = match
    it_cfg(it_cfg_json(dir, "k")).build_session(role=@rp.Role::Send) {
    Ok(s) => s
    Err(e) => abort("构造发送会话失败: " + e)
  }
  match producer.send_package("ro2.rhop", Json::object(Map([]))) {
    Ok(j) => assert_eq(it_str(j, "status"), "ok")
    Err(e) => abort("请求包写入失败: " + e)
  }
  let recv = match cfg.build_session(role=@rp.Role::Recv) {
    Ok(s) => s
    Err(e) => abort("构造接收会话失败: " + e)
  }
  match recv.recv_package("ro2.rhop") {
    Ok(j) => assert_eq(it_str(j, "status"), "ok")
    Err(e) => abort("只读介质的接收端应当可用: " + e)
  }
  // 发送端：写端不可用 → 专门 Err（不是笼统的「全不可达」）
  let send = match cfg.build_session(role=@rp.Role::Send) {
    Ok(s) => s
    Err(e) => abort("构造发送会话失败: " + e)
  }
  // 写端父路径是文件：探测判「可写」，实际写入失败 → status:error 收据（不是 Err）
  match send.send_package("out2.rhop", Json::object(Map([]))) {
    Ok(j) => assert_eq(it_str(j, "status"), "error")
    Err(e) => assert_true(!e.contains("全不可达")) // 不得笼统判全不可达
  }
  // 写端连父目录都不存在（且是本地端点）→ 专门 Err，且探测过程不建目录
  let nodir_cfg = it_cfg(
    itj(
      "{\"key\": \"k\", \"role\": \"SEND\", \"shared\": {\"write\": \"" +
      dir +
      "/nodir/sub\", \"read\": \"" +
      dir +
      "\"}}",
    ),
  )
  let send2 = match nodir_cfg.build_session(role=@rp.Role::Send) {
    Ok(s) => s
    Err(e) => abort("构造发送会话失败: " + e)
  }
  match send2.send_package("out3.rhop", Json::object(Map([]))) {
    Ok(j) =>
      abort(
        "写端不可用（父目录缺失）时不应发送成功: " +
        Json::stringify(j),
      )
    Err(e) => assert_true(e.contains("写端不可用"))
  }
  assert_true(!ffi_exists(dir + "/nodir"))
}

// ---------------------------------------------------------------------------
// C2 轮回归：回执掩码（C2-02）、原子写残留（C2-08）、同名覆盖语义（C2-05）
// ---------------------------------------------------------------------------

///|
extern "js" fn ffi_mkdir(p : String) -> Bool =
  #| (p) => { try { process.getBuiltinModule("node:fs").mkdirSync(String(p), { recursive: true }); return true; } catch (_e) { return false; } }

///|
extern "js" fn ffi_ls(p : String) -> String =
  #| (p) => { try { const fs = process.getBuiltinModule("node:fs"); return JSON.stringify(fs.readdirSync(String(p))); } catch (e) { return "ERR:" + String((e && e.message) || e); } }

///|
test "interact · C2-02：rhop.echo 回执不再泄漏 sftp 口令 / key_path" {
  let cfg = it_cfg(
    itj(
      "{\"key\": \"k\", \"sftp\": {\"host\": \"jump.example\", \"user\": \"ops\", \"password\": \"SFTP-PW-C2\", \"key_path\": \"/secret/id_c2\", \"dir\": \"/srv\"}}",
    ),
  )
  let r = match
    @rp.interact(cfg, "rhop.echo", Some(itj("{\"marker\": \"m1\"}")), "execute") {
    Ok(j) => j
    Err(e) => abort("rhop.echo execute 失败: " + e)
  }
  let text = Json::stringify(r)
  // 口令与私钥路径绝不出现在回执里（rhop.echo 常被链路自检直接打日志）
  assert_false(text.contains("SFTP-PW-C2"))
  assert_false(text.contains("/secret/id_c2"))
  // 掩码占位存在，非敏感字段与 payload 仍完整（自检能力不回退）
  assert_true(text.contains("***"))
  assert_eq(it_str(r, "action"), "rhop.echo")
  match it_field(r, "cfg") {
    Some(c) => {
      assert_eq(it_str(c, "config_name"), "rhop-config")
      match it_field(c, "sftp") {
        Some(sftp) => {
          assert_eq(it_str(sftp, "password"), "***")
          assert_eq(it_str(sftp, "key_path"), "***")
          assert_eq(it_str(sftp, "host"), "jump.example")
          assert_eq(it_str(sftp, "dir"), "/srv")
        }
        None => abort("echo 回执缺 cfg.sftp")
      }
    }
    None => abort("echo 回执缺 cfg")
  }
  match it_field(r, "payload") {
    Some(p) => assert_eq(it_str(p, "marker"), "m1")
    None => abort("echo 回执缺 payload")
  }
}

///|
test "interact · C2-08：rename 失败不留 .tmp；phase=send 失败不产生 res_" {
  let dir = it_dir("rhop-c2-tmp")
  // 目标名被目录占用 → 原子写的 rename 必然失败
  assert_true(ffi_mkdir(dir + "/blocked.rhop"))
  let cfg = it_cfg(it_cfg_json(dir, "k"))
  let sender = match cfg.build_session(role=@rp.Role::Send) {
    Ok(s) => s
    Err(e) => abort("构造发送会话失败: " + e)
  }
  match sender.send_package("blocked.rhop", Json::object(Map([]))) {
    Ok(j) => {
      assert_eq(it_str(j, "status"), "error")
      assert_eq(it_str(j, "transport"), "shared")
    }
    Err(e) => abort("写失败应走 status:error 收据而非 Err: " + e)
  }
  // 临时文件必须被清掉（write_text_atomic 的失败分支）
  let listing = ffi_ls(dir)
  assert_false(listing.contains(".tmp"))
  assert_false(ffi_exists(dir + "/blocked.rhop.tmp"))
  // roundtrip：请求包写失败 → phase=send 收据，且绝不产生 res_ 半成品
  match
    @rp.interact(
      cfg,
      "rhop.echo",
      None,
      "roundtrip",
      request_filename="blocked.rhop",
    ) {
    Ok(j) => {
      assert_eq(it_str(j, "status"), "error")
      assert_eq(it_str(j, "phase"), "send")
      assert_false(ffi_exists(dir + "/res_blocked.rhop"))
    }
    Err(e) => abort("发送失败应走 phase=send 收据而非 Err: " + e)
  }
}

///|
test "interact · C2-05：同名缺省请求包「后写者胜」（并发方必须自带唯一名）" {
  let dir = it_dir("rhop-c2-race")
  let cfg = it_cfg(it_cfg_json(dir, "k"))
  let a = match cfg.build_session(role=@rp.Role::Send) {
    Ok(s) => s
    Err(e) => abort("A 会话: " + e)
  }
  let b = match cfg.build_session(role=@rp.Role::Send) {
    Ok(s) => s
    Err(e) => abort("B 会话: " + e)
  }
  match
    a.send_package(
      "req_race.rhop",
      itj("{\"action\": \"jump.probe\", \"payload\": {\"who\": \"AAA\"}}"),
    ) {
    Ok(j) => assert_eq(it_str(j, "status"), "ok")
    Err(e) => abort("A 发送: " + e)
  }
  match
    b.send_package(
      "req_race.rhop",
      itj("{\"action\": \"jump.probe\", \"payload\": {\"who\": \"BBB\"}}"),
    ) {
    Ok(j) => assert_eq(it_str(j, "status"), "ok")
    Err(e) => abort("B 发送: " + e)
  }
  // 介质上只留一个包（原子覆盖写）——这既是资源上界，也是并发语义的坑
  let listing = ffi_ls(dir)
  assert_true(listing.contains("req_race.rhop"))
  // 残留的是后写者：用接收会话解密确认（这正是「同名并发会丢前一个请求」的证据）
  let recv = match cfg.build_session(role=@rp.Role::Recv) {
    Ok(s) => s
    Err(e) => abort("接收会话: " + e)
  }
  let got = match recv.recv_package("req_race.rhop") {
    Ok(j) => j
    Err(e) => abort("取包: " + e)
  }
  assert_eq(it_str(got, "status"), "ok")
  let body = Json::stringify(
    match it_field(got, "payload") {
      Some(p) => p
      None => abort("回执缺 payload")
    },
  )
  assert_true(body.contains("BBB"))
  assert_false(body.contains("AAA"))
}
