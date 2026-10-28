// ============================================================================
// rhop_task · 配置层测试（纯逻辑部分，三目标通用）
//
// 需要真解密（key.cipher 解锁）/ 读文件（from_file）的用例在 task_config_js_test.mbt。
//
// 覆盖：
//   1. 最小配置 → 默认值逐项（queue / heartbeat / exec / 各类超时）
//   2. role 别名全表 + 未知/缺省 role 的 Err
//   3. shared 字符串简写 / {write,read} 对象
//   4. queue 深合并（自定义覆盖默认、未提到的键保留默认）
//   5. 心跳判死阈值校验（stale < interval+1 → Err）
//   6. store kind 校验（sqlite-shared / sqlite-local / 非法）
//   7. 明文主密钥告警 + to_dict 脱敏 + describe
//   8. 缺 key 但配置含密文 → Err
// ============================================================================

///|
/// 解析一段配置 JSON 文本（warner 计数）。
fn parse_cfg(text : String, strict : Bool) -> Result[@rt.TaskConfig, String] {
  @rt.TaskConfig::from_json_text(text, None, strict, false, None)
}

///|
test "config · 最小配置的默认值全项" {
  let cfg = match parse_cfg("{\"role\":\"A\",\"name\":\"demo\"}", false) {
    Ok(c) => c
    Err(e) => fail("最小配置解析失败: \{e}")
  }
  assert_eq(cfg.name(), "demo")
  assert_eq(cfg.role_short(), "A")
  assert_eq(cfg.role_long(), "SEND")
  assert_false(cfg.has_key())
  assert_eq(cfg.store_kind, "sqlite-shared")
  // 心跳文件名缺省 <name>.heartbeat
  assert_eq(cfg.heartbeat_file, "demo.heartbeat")
  assert_eq(cfg.heartbeat_interval_sec, 5.0)
  assert_eq(cfg.heartbeat_stale_after_sec, 15.0)
  assert_eq(cfg.poll_interval_sec, 2.0)
  assert_eq(cfg.max_retries, 3)
  assert_eq(cfg.retry_delay_min, 5.0)
  assert_eq(cfg.timeout_min, 60.0)
  assert_true(cfg.encrypt_result)
  assert_eq(cfg.result_max_bytes, 65536)
  assert_eq(cfg.lock_ttl_sec, 900.0)
  // exec 默认白名单两条
  assert_eq(cfg.exec_allow, ["action:*", "handler:*"])
  assert_false(cfg.exec_allow_any)
  assert_eq(cfg.exec_timeout_sec, 3600.0)
  // 未配置 shared
  assert_true(cfg.shared_write is None)
  assert_true(cfg.shared_read is None)
  // worker_id 缺省 <name>-<方向小写>
  assert_eq(cfg.worker_id(), "demo-a")
}

///|
test "config · role 别名全表（大小写/连字符/空白容忍）" {
  let cases : Array[(String, String, String)] = [
    ("A", "A", "SEND"),
    ("a", "A", "SEND"),
    ("send", "A", "SEND"),
    ("REQUESTER", "A", "SEND"),
    ("submit", "A", "SEND"),
    ("B", "B", "RECV"),
    ("recv", "B", "RECV"),
    ("RECEIVE", "B", "RECV"),
    ("EXECUTOR", "B", "RECV"),
    ("server", "B", "RECV"),
    ("worker", "B", "RECV"),
    ("C", "C", "RELAY"),
    ("relay", "C", "RELAY"),
    ("RELAY-SERVER", "C", "RELAY"),
    ("relay server", "C", "RELAY"),
  ]
  for case in cases {
    let text = "{\"role\":\"" + case.0 + "\"}"
    let cfg = match parse_cfg(text, false) {
      Ok(c) => c
      Err(e) => fail("role=\{case.0} 解析失败: \{e}")
    }
    assert_eq(cfg.role_short(), case.1)
    assert_eq(cfg.role_long(), case.2)
  }
}

///|
test "config · role 缺省 / 未知 → 可诊断 Err" {
  match parse_cfg("{\"name\":\"x\"}", false) {
    Err(e) => {
      assert_true(e.contains("缺少 role"))
      assert_true(e.contains("A=提交方"))
    }
    Ok(_) => fail("缺 role 应当 Err")
  }
  match parse_cfg("{\"role\":\"Z\"}", false) {
    Err(e) => assert_true(e.contains("未知方向"))
    Ok(_) => fail("未知 role 应当 Err")
  }
  // direction / rhop_role 也能作为方向来源
  let c = match parse_cfg("{\"direction\":\"B\"}", false) {
    Ok(c) => c
    Err(e) => fail("direction 分支失败: \{e}")
  }
  assert_eq(c.role_short(), "B")
  let c2 = match parse_cfg("{\"rhop_role\":\"C\"}", false) {
    Ok(c) => c
    Err(e) => fail("rhop_role 分支失败: \{e}")
  }
  assert_eq(c2.role_short(), "C")
}

///|
test "config · shared：字符串简写 = 写读同址；对象可分离读写" {
  let c1 = match
    parse_cfg("{\"role\":\"A\",\"shared\":\"E:/share/rhop\"}", false) {
    Ok(c) => c
    Err(e) => fail("shared 字符串失败: \{e}")
  }
  assert_eq(c1.shared_write, Some("E:/share/rhop"))
  assert_eq(c1.shared_read, Some("E:/share/rhop"))
  let c2 = match
    parse_cfg(
      "{\"role\":\"A\",\"shared\":{\"write\":\"E:/a\",\"read\":\"//nas/b\"}}", false,
    ) {
    Ok(c) => c
    Err(e) => fail("shared 对象失败: \{e}")
  }
  assert_eq(c2.shared_write, Some("E:/a"))
  assert_eq(c2.shared_read, Some("//nas/b"))
  // 只给 read：写端跟随读端
  let c3 = match
    parse_cfg("{\"role\":\"A\",\"shared\":{\"read\":\"//nas/b\"}}", false) {
    Ok(c) => c
    Err(e) => fail("shared 只给 read 失败: \{e}")
  }
  assert_eq(c3.shared_write, Some("//nas/b"))
}

///|
test "config · queue 深合并：自定义覆盖默认、未提及的键保留默认" {
  let c = match
    parse_cfg(
      "{\"role\":\"B\",\"name\":\"n1\",\"queue\":{\"max_retries\":9,\"heartbeat\":{\"file\":\"hb.txt\"},\"file_channel\":{\"enabled\":true}}}",
      false,
    ) {
    Ok(c) => c
    Err(e) => fail("深合并失败: \{e}")
  }
  // 覆盖生效
  assert_eq(c.max_retries, 9)
  assert_eq(c.heartbeat_file, "hb.txt")
  // 未提到的默认保留
  assert_eq(c.heartbeat_interval_sec, 5.0)
  assert_eq(c.heartbeat_stale_after_sec, 15.0)
  assert_eq(c.poll_interval_sec, 2.0)
  assert_eq(c.timeout_min, 60.0)
  // file_channel 部分覆盖：enabled 改 true，max_bytes 保持默认
  match @rt.TaskConfig::describe(c) {
    Object(_) => ()
    _ => fail("describe 应返回对象")
  }
  match c.queue {
    { "file_channel": { "enabled": True, "max_bytes": Number(mb, ..), .. }, .. } =>
      assert_eq(mb, 1048576.0)
    _ => fail("file_channel 深合并异常: " + Json::stringify(c.queue))
  }
}

///|
test "config · heartbeat 判死阈值校验（stale < interval+1 → Err）" {
  match
    parse_cfg(
      "{\"role\":\"B\",\"queue\":{\"heartbeat\":{\"interval_sec\":10,\"stale_after_sec\":10}}}",
      false,
    ) {
    Err(e) => {
      assert_true(e.contains("心跳判死阈值过小"))
      assert_true(e.contains("BUG-282"))
    }
    Ok(_) => fail("stale == interval 应当 Err")
  }
  // 刚好 interval+1 合法（边界）
  let ok = match
    parse_cfg(
      "{\"role\":\"B\",\"queue\":{\"heartbeat\":{\"interval_sec\":10,\"stale_after_sec\":11}}}",
      false,
    ) {
    Ok(c) => c
    Err(e) => fail("stale = interval+1 应当合法: \{e}")
  }
  assert_eq(ok.heartbeat_stale_after_sec, 11.0)
  // heartbeat 字符串简写 = 文件名
  let c2 = match
    parse_cfg("{\"role\":\"B\",\"queue\":{\"heartbeat\":\"my.hb\"}}", false) {
    Ok(c) => c
    Err(e) => fail("heartbeat 字符串简写失败: \{e}")
  }
  assert_eq(c2.heartbeat_file, "my.hb")
}

///|
test "config · store kind 三态（默认 / sqlite-local / 非法 Err）" {
  let c1 = match
    parse_cfg(
      "{\"role\":\"A\",\"queue\":{\"store\":{\"kind\":\"sqlite-local\"}}}", false,
    ) {
    Ok(c) => c
    Err(e) => fail("sqlite-local 失败: \{e}")
  }
  assert_eq(c1.store_kind, "sqlite-local")
  // store 字符串简写
  let c2 = match
    parse_cfg("{\"role\":\"A\",\"queue\":{\"store\":\"sqlite-shared\"}}", false) {
    Ok(c) => c
    Err(e) => fail("store 字符串简写失败: \{e}")
  }
  assert_eq(c2.store_kind, "sqlite-shared")
  // store_kind 兼容写法
  let c3 = match
    parse_cfg(
      "{\"role\":\"A\",\"queue\":{\"store_kind\":\"sqlite-local\"}}", false,
    ) {
    Ok(c) => c
    Err(e) => fail("store_kind 兼容写法失败: \{e}")
  }
  assert_eq(c3.store_kind, "sqlite-local")
  // 非法
  match
    parse_cfg(
      "{\"role\":\"A\",\"queue\":{\"store\":{\"kind\":\"postgres\"}}}", false,
    ) {
    Err(e) => {
      assert_true(e.contains("未知存储后端"))
      if !e.contains("postgres") {
        fail("存储后端错误文案未点明非法值，实际: " + e)
      }
    }
    Ok(_) => fail("非法 store kind 应当 Err")
  }
}

///|
test "config · 明文主密钥：告警 + findings + to_dict 脱敏" {
  let c = match
    parse_cfg(
      "{\"role\":\"A\",\"name\":\"sec\",\"key\":\"master-key-plain\"}", false,
    ) {
    Ok(c) => c
    Err(e) => fail("明文 key 配置失败: \{e}")
  }
  assert_true(c.has_key())
  assert_eq(c.key, "master-key-plain")
  assert_eq(c.key_source, "plain")
  // 明文发现至少一条，路径为 key
  let pf = c.plaintext_findings()
  assert_true(pf.length() >= 1)
  assert_true(pf[0].path.contains("key"))
  // to_dict(mask=true)：key 打码成 ***，且不泄漏明文
  let masked = Json::stringify(c.to_dict(true))
  assert_false(masked.contains("master-key-plain"))
  assert_true(masked.contains("\"key\":\"***\""))
  // to_dict(mask=false)：保留明文（供内部使用）
  let raw = Json::stringify(c.to_dict(false))
  assert_true(raw.contains("master-key-plain"))
}

///|
test "config · to_dict 脱敏覆盖 sftp/relay/online/heartbeat 的敏感键" {
  let c = match
    parse_cfg(
      "{\"role\":\"A\",\"sftp\":{\"host\":\"h\",\"password\":\"p@ss\"},\"relay\":{\"host\":\"r\",\"token\":\"tok\"},\"online\":[{\"kind\":\"sftp\",\"password\":\"p2\"}]}",
      false,
    ) {
    Ok(c) => c
    Err(e) => fail("配置解析失败: \{e}")
  }
  let masked = Json::stringify(c.to_dict(true))
  assert_false(masked.contains("p@ss"))
  assert_false(masked.contains("\"tok\""))
  assert_false(masked.contains("p2"))
  // 非敏感键保留
  assert_true(masked.contains("\"host\":\"h\""))
  // mask=false 时是明文
  let raw = Json::stringify(c.to_dict(false))
  assert_true(raw.contains("p@ss"))
}

///|
test "config · describe() 结构与 plaintext_fields" {
  let c = match
    parse_cfg(
      "{\"role\":\"B\",\"name\":\"doc\",\"key\":\"k\",\"shared\":{\"write\":\"E:/w\",\"read\":\"E:/r\"},\"exec\":{\"allow\":[\"action:x\"],\"allow_any\":true,\"timeout_sec\":30}}",
      false,
    ) {
    Ok(c) => c
    Err(e) => fail("配置解析失败: \{e}")
  }
  let d = c.describe()
  match d {
    {
      "name": String(name),
      "role": String(role),
      "role_long": String(role_long),
      "has_key": True,
      "shared": { "write": String(w), "read": String(r), .. },
      "store": { "kind": String(kind), .. },
      "heartbeat": { "file": String(hb), .. },
      "worker_id": String(wid),
      "exec": { "allow_any": True, "timeout_sec": Number(ts, ..), .. },
      "plaintext_fields": Array(pf),
      ..
    } => {
      assert_eq(name, "doc")
      assert_eq(role, "B")
      assert_eq(role_long, "RECV")
      assert_eq(w, "E:/w")
      assert_eq(r, "E:/r")
      assert_eq(kind, "sqlite-shared")
      assert_eq(hb, "doc.heartbeat")
      assert_eq(wid, "doc-b")
      assert_eq(ts, 30.0)
      // 明文主密钥 → plaintext_fields 含 key
      assert_true(pf.length() >= 1)
    }
    _ => fail("describe 结构不符: " + Json::stringify(d))
  }
}

///|
test "config · 缺 key 但配置含密文 → 可诊断 Err" {
  match
    parse_cfg(
      "{\"role\":\"A\",\"sftp\":{\"password\":\"RHOP-ENC:Zm9v\"}}", false,
    ) {
    Err(e) => {
      assert_true(e.contains("没有解密密钥"))
      assert_true(e.contains("RHOP_KEY"))
    }
    Ok(_) => fail("无 key 解不开密文应当 Err")
  }
}

///|
test "config · 非对象配置 / 非法 JSON 文本 → Err" {
  match @rt.TaskConfig::from_json_text("not-json", None, false, false, None) {
    Err(e) => assert_true(e.contains("JSON 解析失败"))
    Ok(_) => fail("非法 JSON 应当 Err")
  }
  // JSON 数组不是对象
  match @rt.TaskConfig::from_json_text("[]", None, false, false, None) {
    Err(e) => assert_true(e.contains("必须是 JSON 对象"))
    Ok(_) => fail("数组配置应当 Err")
  }
}

///|
test "config · build_crypto：有 key 才有对象" {
  let no_key = match parse_cfg("{\"role\":\"A\"}", false) {
    Ok(c) => c
    Err(e) => fail("x: \{e}")
  }
  assert_true(no_key.build_crypto() is None)
  let with_key = match parse_cfg("{\"role\":\"A\",\"key\":\"k1\"}", false) {
    Ok(c) => c
    Err(e) => fail("x: \{e}")
  }
  assert_true(with_key.build_crypto() is Some(_))
}
