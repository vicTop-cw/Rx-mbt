// ============================================================================
// rhop_task · 执行策略测试（js 目标）
//
// 覆盖：白名单通配匹配、action 通道（处理器注册表）、cli 通道（argv 数组 =
//       不经 shell，恶意串只是普通实参）、默认拒绝、超时/失败路径、语言识别。
// ============================================================================

///|
test "exec · 白名单通配匹配" {
  let p = @rt.ExecPolicy::default()
  assert_true(p.allows("action:jump.probe"))
  assert_true(p.allows("handler:anything"))
  // 默认不放行任意 cli
  assert_false(p.allows("cli:git"))
  assert_false(p.allows("cli:rm"))
  // allow_any 全放开
  let open = @rt.ExecPolicy::new([], true, 10.0)
  assert_true(open.allows("cli:rm"))
  assert_true(open.allows("anything:at:all"))
  // 精确项 + 显式 cli 项
  let p2 = @rt.ExecPolicy::new(["cli:node", "action:x"], false, 10.0)
  assert_true(p2.allows("cli:node"))
  assert_false(p2.allows("cli:nodejs"))
  assert_true(p2.allows("action:x"))
  assert_false(p2.allows("action:y"))
  // 全通配 *
  let star = @rt.ExecPolicy::new(["*"], false, 10.0)
  assert_true(star.allows("cli:whatever"))
}

///|
test "exec · 处理器注册表：注册/覆盖/查询/列举/清空" {
  @rt.clear_handlers()
  assert_eq(@rt.list_handlers().length(), 0)
  @rt.register_handler("echo", fn(args) { Ok(args) })
  @rt.register_handler("boom", fn(args) {
    let _ = args
    Err("handler 故意失败")
  })
  let names = @rt.list_handlers()
  assert_eq(names, ["boom", "echo"])
  assert_true(@rt.get_handler("echo") is Some(_))
  assert_true(@rt.get_handler("nope") is None)
  // 覆盖：同名再注册即替换
  @rt.register_handler("echo", fn(args) {
    let _ = args
    Ok(Json::string("覆盖后"))
  })
  match @rt.get_handler("echo") {
    Some(h) =>
      match h(Json::null()) {
        Ok(v) => assert_eq(Json::stringify(v), "\"覆盖后\"")
        Err(e) => fail("调用失败: \{e}")
      }
    None => fail("echo 应已注册")
  }
  @rt.clear_handlers()
  assert_eq(@rt.list_handlers().length(), 0)
}

///|
test "exec · detect_language 三态识别" {
  assert_eq(
    @rt.detect_language(parse_json_te("{\"kind\":\"action\",\"name\":\"x\"}")),
    "action",
  )
  assert_eq(
    @rt.detect_language(parse_json_te("{\"kind\":\"handler\",\"name\":\"x\"}")),
    "action",
  )
  assert_eq(
    @rt.detect_language(parse_json_te("{\"kind\":\"cli\",\"argv\":[\"git\"]}")),
    "cli",
  )
  assert_eq(@rt.detect_language(parse_json_te("{\"argv\":[\"git\"]}")), "cli")
  assert_eq(@rt.detect_language(parse_json_te("{\"name\":\"x\"}")), "action")
  assert_eq(@rt.detect_language(parse_json_te("{\"other\":1}")), "unknown")
  assert_eq(@rt.detect_language(Json::string("nope")), "unknown")
}

///|
test "exec · action 通道：成功 / 未注册 / 策略拒绝" {
  @rt.clear_handlers()
  @rt.register_handler("jump.probe", fn(args) {
    Ok(Json::object({ "probed": Json::boolean(true), "echo": args }))
  })
  let policy = @rt.ExecPolicy::default()
  let payload = @json.parse(
    "{\"kind\":\"action\",\"name\":\"jump.probe\",\"args\":{\"host\":\"h\"}}",
  ) catch {
    _ => fail("x")
  }
  let r = @rt.run_payload(policy, payload)
  assert_true(r.ok)
  assert_eq(r.channel, "action")
  assert_true(r.output.contains("probed"))
  assert_true(r.output.contains("\"host\""))
  // 未注册
  let unk = @json.parse("{\"kind\":\"action\",\"name\":\"nope\"}") catch {
    _ => fail("x")
  }
  let r2 = @rt.run_payload(policy, unk)
  assert_false(r2.ok)
  match r2.error {
    Some(e) => assert_true(e.contains("未注册"))
    None => fail("应有错误")
  }
  // 策略拒绝（只放行 action:jump.probe）
  let strict = @rt.ExecPolicy::new(["action:jump.probe"], false, 10.0)
  let other = @json.parse("{\"kind\":\"action\",\"name\":\"other\"}") catch {
    _ => fail("x")
  }
  let r3 = @rt.run_payload(strict, other)
  assert_false(r3.ok)
  match r3.error {
    Some(e) => assert_true(e.contains("执行策略拒绝"))
    None => fail("应有拒绝原因")
  }
  @rt.clear_handlers()
}

///|
test "exec · cli 通道：默认拒绝；显式放行后可执行（argv 不经 shell）" {
  // 默认策略：拒绝 cli
  let def = @rt.ExecPolicy::default()
  let cli = @json.parse("{\"kind\":\"cli\",\"argv\":[\"node\",\"--version\"]}") catch {
    _ => fail("x")
  }
  let denied = @rt.run_payload(def, cli)
  assert_false(denied.ok)
  match denied.error {
    Some(e) => {
      assert_true(e.contains("执行策略拒绝"))
      assert_true(e.contains("cli:node"))
    }
    None => fail("应有拒绝原因")
  }
  // 显式放行 node
  let allowed = @rt.ExecPolicy::new(["cli:node"], false, 10.0)
  let ok = @rt.run_payload(allowed, cli)
  assert_true(ok.ok)
  assert_eq(ok.channel, "cli")
  assert_true(ok.output.contains("v"))
  // 恶意串不是 shell 拼接：`node -e "process.exit(3)"` 里带 & ; 也只是普通实参
  let evil = @json.parse(
    "{\"kind\":\"cli\",\"argv\":[\"node\",\"-e\",\"process.stdout.write('A && B; C')\"]}",
  ) catch {
    _ => fail("x")
  }
  let r = @rt.run_payload(allowed, evil)
  assert_true(r.ok)
  // 原样输出，没有被 shell 解释成命令分隔符
  assert_eq(r.output, "A && B; C")
  // 空 argv → 可诊断 Err
  let empty = @json.parse("{\"kind\":\"cli\",\"argv\":[]}") catch {
    _ => fail("x")
  }
  let r2 = @rt.run_payload(allowed, empty)
  assert_false(r2.ok)
  match r2.error {
    Some(e) => assert_true(e.contains("缺少 argv"))
    None => fail("应有错误")
  }
}

///|
test "exec · cli 退出码非 0 → ok=false 且带退出码与 stderr" {
  let allowed = @rt.ExecPolicy::new(["cli:node"], false, 10.0)
  let payload = @json.parse(
    "{\"kind\":\"cli\",\"argv\":[\"node\",\"-e\",\"process.exit(7)\"]}",
  ) catch {
    _ => fail("x")
  }
  let r = @rt.run_payload(allowed, payload)
  assert_false(r.ok)
  match r.error {
    Some(e) => assert_true(e.contains("退出码 7"))
    None => fail("应有退出码")
  }
}

///|
test "exec · 非对象载荷 / 未知类型 → 可诊断失败" {
  let policy = @rt.ExecPolicy::default()
  let r = @rt.run_payload(policy, Json::string("nope"))
  assert_false(r.ok)
  assert_eq(r.channel, "unknown")
  let r2 = @rt.run_payload(policy, Json::null())
  assert_false(r2.ok)
}

///|
test "exec · 从 TaskConfig 构造策略" {
  let cfg = match
    @rt.TaskConfig::from_json_text(
      "{\"role\":\"B\",\"exec\":{\"allow\":[\"cli:git\"],\"allow_any\":false,\"timeout_sec\":42}}",
      None,
      false,
      false,
      None,
    ) {
    Ok(c) => c
    Err(e) => fail("配置: \{e}")
  }
  let p = @rt.ExecPolicy::from_config(cfg)
  assert_true(p.allows("cli:git"))
  assert_false(p.allows("cli:rm"))
  assert_eq(p.timeout_sec, 42.0)
}

///|
/// 测试用 JSON 解析助手（解析失败直接让用例失败）。
fn parse_json_te(text : String) -> Json raise {
  @json.parse(text) catch {
    _ => fail("测试 JSON 非法: " + text)
  }
}
