// ============================================================================
// rhop_task · 敏感信息层测试（纯逻辑部分，三目标通用）
//
// 需要真加解密的用例（密文解密、主密钥密文解锁）放在 task_secrets_js_test.mbt。
//
// 覆盖：
//   1. mask_value 四种形态 / is_sensitive_leaf 正反例 / command_hint 三形态
//   2. 兄弟键 *_plain 优先 + 明文告警 findings
//   3. 秘密节点收敛成标量 / skip_paths 整棵跳过
//   4. 嵌套敏感叶（online[0].password_plain）
//   5. strict=true 明文直接 Err
//   6. 无密钥但含密文 → 可诊断 Err（这是 js 之外唯一能覆盖的解密路径）
//   7. find_secret_fields 三种 kind
// ============================================================================

// ---------------------------------------------------------------------------
// 1. 打码 / 敏感叶 / 操作指引
// ---------------------------------------------------------------------------

///|
test "secrets · mask_value 四种形态" {
  assert_eq(@rt.mask_value_default(""), "")
  // 短值整体打码
  assert_eq(@rt.mask_value_default("ab"), "***")
  assert_eq(@rt.mask_value_default("abcd"), "***")
  // 长值保留首尾 2 位
  assert_eq(@rt.mask_value_default("abcdef"), "ab***ef")
  assert_eq(@rt.mask_value_default("my-secret-token"), "my***en")
  // 密文：保留 RHOP-ENC: 前缀 + *** + 尾 2 位（长度足够时）
  let cipher = "RHOP-ENC:Z0FBQUFBQnE0SkpCYlFKQWt4WExvZ3RBam9HNWdvUlBmUVEzbDhYMllRUlNpNUdRSVBJQTR1V0"
  assert_eq(@rt.mask_value_default(cipher), "RHOP-ENC:Z0***V0")
  // 密文短值（len <= keep*2）整体标 CIPHER：keep=6 时 2*6=12 >= len("RHOP-ENC:ab")=11
  assert_eq(@rt.mask_value("RHOP-ENC:ab", 6), "***CIPHER***")
  // 默认 keep=2 时 4 < 11，与 vools 一致走「前缀 + *** + 尾2位」
  assert_eq(@rt.mask_value_default("RHOP-ENC:ab"), "RHOP-ENC:ab***ab")
  // keep 参数可控
  assert_eq(@rt.mask_value("abcdef", 1), "a***f")
  // 边界：len == keep*2 时整体打码（与 vools 的 <= 判断一致）
  assert_eq(@rt.mask_value("abcdef", 3), "***")
  // len > keep*2 才保留首尾
  assert_eq(@rt.mask_value("abcdefg", 3), "abc***efg")
}

///|
test "secrets · is_sensitive_leaf 正反例（最后一段下划线语义）" {
  // 敏感
  assert_true(@rt.is_sensitive_leaf("password"))
  assert_true(@rt.is_sensitive_leaf("PASSWORD"))
  assert_true(@rt.is_sensitive_leaf("sftp_password"))
  assert_true(@rt.is_sensitive_leaf("relay_token"))
  assert_true(@rt.is_sensitive_leaf("key"))
  assert_true(@rt.is_sensitive_leaf("api_key"))
  assert_true(@rt.is_sensitive_leaf("accesskey"))
  assert_true(@rt.is_sensitive_leaf("privatekey"))
  assert_true(@rt.is_sensitive_leaf("my_secret"))
  // 非敏感（不能误伤）
  assert_false(@rt.is_sensitive_leaf("mypassword"))
  assert_false(@rt.is_sensitive_leaf("password_len"))
  assert_false(@rt.is_sensitive_leaf("host"))
  assert_false(@rt.is_sensitive_leaf("timeout"))
  assert_false(@rt.is_sensitive_leaf(""))
  assert_false(@rt.is_sensitive_leaf("keywords"))
}

///|
test "secrets · command_hint 三形态（兄弟键 / 秘密节点 / 无键）" {
  // 兄弟键：由 *_plain 推导 *_cipher，并指向明文键要求清空
  let h1 = @rt.command_hint(
    "sftp.password",
    Some("sftp.password_plain"),
    Some("sftp.password_cipher"),
  )
  assert_true(h1.contains("生成密文"))
  assert_true(h1.contains("sftp.password_cipher"))
  assert_true(h1.contains("sftp.password_plain"))
  // 只有 *_plain：目标由 _plain 推导成 _cipher
  let h2 = @rt.command_hint("relay.token", Some("relay.token_plain"), None)
  assert_true(h2.contains("relay.token_cipher"))
  assert_true(h2.contains("relay.token_plain"))
  // 无键：path + 后缀
  let h3 = @rt.command_hint("sftp.password", None, None)
  assert_true(h3.contains("sftp.password_cipher"))
  assert_true(h3.contains("sftp.password_plain"))
  // 指引里应带可复制命令
  assert_true(h3.contains(@rt.secret_enc_command))
}

// ---------------------------------------------------------------------------
// 2. 兄弟键 / 秘密节点 / skip_paths
// ---------------------------------------------------------------------------

///|
/// 解析一段 JSON 配置文本，返回 (resolved, findings, 告警条数)。
fn resolve_text(
  text : String,
  strict : Bool,
) -> (Json, Array[@rt.SecretFinding], Int32) raise {
  let cfg = @json.parse(text) catch {
    _ => fail("测试配置 JSON 非法: " + text)
  }
  let warnings : @ref.Ref[Int32] = @ref.Ref::new(0)
  let resolver = @rt.SecretResolver::new(
    None,
    strict,
    true,
    @rt.default_skip_paths(),
  ).with_warner(fn(_m) { warnings.val = warnings.val + 1 })
  let resolved = match resolver.resolve(cfg) {
    Ok(v) => v
    Err(e) => fail("解析失败: \{e}")
  }
  (resolved, resolver.findings(), warnings.val)
}

///|
test "secrets · 兄弟键 *_plain 优先收敛 + 明文告警" {
  let (resolved, findings, warns) = resolve_text(
    "{\"sftp\":{\"host\":\"h\",\"password_plain\":\"p@ss\",\"password_cipher\":\"RHOP-ENC:x\"}}",
    false,
  )
  // 明文优先，且收敛到 password
  match resolved {
    { "sftp": { "password": String(p), "host": String(h), .. }, .. } => {
      assert_eq(p, "p@ss")
      assert_eq(h, "h")
    }
    _ =>
      fail("兄弟键未收敛到 sftp.password: " + Json::stringify(resolved))
  }
  // 明文告警 1 条 + finding 记录
  assert_eq(warns, 1)
  let plaintext_paths : Array[String] = []
  for f in findings {
    if f.action == "plaintext" {
      plaintext_paths.push(f.path)
    }
  }
  assert_eq(plaintext_paths, ["sftp.password"])
  // *_plain / *_cipher 原键不再出现在结果里
  match resolved {
    Object(m) =>
      match m.get("sftp") {
        Some(Object(s)) => {
          assert_false(s.contains("password_plain"))
          assert_false(s.contains("password_cipher"))
        }
        _ => fail("sftp 段丢失")
      }
    _ => fail("resolved 应为对象")
  }
}

///|
test "secrets · 秘密节点 {\"plain\":…} 收敛成标量" {
  let (resolved, findings, warns) = resolve_text(
    "{\"relay\":{\"host\":\"127.0.0.1\",\"token\":{\"plain\":\"tok\",\"cipher\":\"\",\"env\":\"RHOP_KEY\"}}}",
    false,
  )
  match resolved {
    { "relay": { "token": String(t), "host": String(h), .. }, .. } => {
      assert_eq(t, "tok")
      assert_eq(h, "127.0.0.1")
    }
    _ => fail("秘密节点未收敛成标量: " + Json::stringify(resolved))
  }
  assert_eq(warns, 1)
  let actions : Array[String] = []
  for f in findings {
    if f.action != "kept" {
      actions.push(f.action)
    }
  }
  assert_eq(actions, ["plaintext"])
}

///|
test "secrets · skip_paths：根密钥 key 整棵跳过（不告警不改写）" {
  // key 是明文 + 还带一个 dest 说明字段：都应按原样保留、且不产生明文告警
  let (resolved, findings, warns) = resolve_text(
    "{\"key\":{\"plain\":\"master-secret\",\"env\":\"RHOP_KEY\",\"note\":\"说明\"},\"sftp\":{\"host\":\"h\"}}",
    false,
  )
  assert_eq(warns, 0)
  assert_eq(findings.length(), 0)
  match resolved {
    { "key": Object(k), .. } => {
      // 原样保留（未被收敛成标量、未被改写）
      assert_true(k.contains("plain"))
      assert_eq(
        k.get("plain").unwrap_or(Json::null()).to_string(),
        Json::string("master-secret").to_string(),
      )
    }
    _ => fail("key 节点应保持对象形态: " + Json::stringify(resolved))
  }
}

///|
test "secrets · 嵌套敏感叶：online[*].password_plain 收敛 + 告警" {
  let (resolved, findings, warns) = resolve_text(
    "{\"online\":[{\"kind\":\"sftp\",\"host\":\"h1\",\"password_plain\":\"p1\"},{\"kind\":\"git\",\"host\":\"h2\",\"password_plain\":\"p2\"}]}",
    false,
  )
  assert_eq(warns, 2)
  let paths : Array[String] = []
  for f in findings {
    if f.action == "plaintext" {
      paths.push(f.path)
    }
  }
  paths.sort()
  assert_eq(paths, ["online[0].password", "online[1].password"])
  // 数组元素里的密文对已收敛
  match resolved {
    { "online": Array(items), .. } => {
      assert_eq(items.length(), 2)
      match items[1] {
        { "password": String(p), .. } => assert_eq(p, "p2")
        _ => fail("数组元素未收敛: " + Json::stringify(items[1]))
      }
    }
    _ => fail("online 应为数组")
  }
}

///|
test "secrets · strict=true 时明文直接 Err（CI 卡口）" {
  let cfg = @json.parse("{\"sftp\":{\"password_plain\":\"p\"}}") catch {
    _ => fail("x")
  }
  let resolver = @rt.SecretResolver::new(
    None,
    true,
    false,
    @rt.default_skip_paths(),
  )
  match resolver.resolve(cfg) {
    Err(e) => {
      assert_true(e.contains("使用了明文"))
      assert_true(e.contains("sftp.password"))
    }
    Ok(_) => fail("strict 模式下明文应当 Err")
  }
}

///|
test "secrets · 无密钥但配置含密文 → 可诊断 Err" {
  let cfg = @json.parse("{\"sftp\":{\"password\":\"RHOP-ENC:Zm9v\"}}") catch {
    _ => fail("x")
  }
  // crypto=None ⇒ 必须点明"没有解密密钥"，而不是静默留空
  let resolver = @rt.SecretResolver::new(
    None,
    false,
    false,
    @rt.default_skip_paths(),
  )
  match resolver.resolve(cfg) {
    Err(e) => {
      assert_true(e.contains("没有解密密钥"))
      assert_true(e.contains("RHOP_KEY"))
    }
    Ok(_) => fail("无密钥解密文应当 Err")
  }
}

///|
test "secrets · 非对象配置 / 空配置" {
  let resolver = @rt.SecretResolver::new(
    None,
    false,
    false,
    @rt.default_skip_paths(),
  )
  match resolver.resolve(Json::string("nope")) {
    Err(e) => assert_true(e.contains("必须是 JSON 对象"))
    Ok(_) => fail("非对象应当 Err")
  }
  // 空对象：原样返回，无 finding
  match resolver.resolve(Json::object(Map::new())) {
    Ok(v) => assert_eq(Json::stringify(v), "{}")
    Err(e) => fail("空对象不应失败: \{e}")
  }
}

///|
test "secrets · resolve_config_secrets 便捷入口返回 findings" {
  let cfg = @json.parse(
    "{\"a\":{\"token_plain\":\"t\"},\"b\":{\"host\":\"h\"}}",
  ) catch {
    _ => fail("x")
  }
  match
    @rt.resolve_config_secrets(
      cfg,
      None,
      false,
      false,
      @rt.default_skip_paths(),
    ) {
    Err(e) => fail("解析失败: \{e}")
    Ok(pair) => {
      let findings = pair.1
      assert_eq(findings.length(), 1)
      assert_eq(findings[0].path, "a.token")
      assert_eq(findings[0].action, "plaintext")
    }
  }
}

// ---------------------------------------------------------------------------
// 3. 敏感字段清单
// ---------------------------------------------------------------------------

///|
test "secrets · find_secret_fields 三种 kind（leaf / pair / node）" {
  let cfg = @json.parse(
    "{\"sftp\":{\"password\":\"plain-p\",\"token_cipher\":\"RHOP-ENC:x\"},\"key\":{\"plain\":\"m\"},\"relay\":{\"host\":\"h\",\"token\":\"t\"}}",
  ) catch {
    _ => fail("x")
  }
  let fields = @rt.find_secret_fields(cfg)
  let by_path : Map[String, @rt.SecretField] = Map::new()
  for f in fields {
    by_path[f.path] = f
  }
  // leaf：sftp.password / relay.token
  assert_true(by_path.contains("sftp.password"))
  assert_eq(by_path["sftp.password"].kind, "leaf")
  assert_true(by_path.contains("relay.token"))
  assert_eq(by_path["relay.token"].kind, "leaf")
  // node：key（含 plain/cipher）
  assert_true(by_path.contains("key"))
  assert_eq(by_path["key"].kind, "node")
  // pair：sftp.token（有 token_cipher 兄弟键）
  assert_true(by_path.contains("sftp.token"))
  assert_eq(by_path["sftp.token"].kind, "pair")
  assert_eq(by_path["sftp.token"].plain_key, Some("sftp.token_plain"))
  assert_eq(by_path["sftp.token"].cipher_key, Some("sftp.token_cipher"))
  // 序列化可用
  let j = by_path["sftp.password"].to_json()
  assert_true(Json::stringify(j).contains("sftp.password"))
}

///|
test "secrets · find_secret_fields 对数组下标路径与空配置" {
  let cfg = @json.parse("{\"online\":[{\"password\":\"p\"}]}") catch {
    _ => fail("x")
  }
  let fields = @rt.find_secret_fields(cfg)
  assert_eq(fields.length(), 1)
  assert_eq(fields[0].path, "online[0].password")
  assert_eq(fields[0].kind, "leaf")
  assert_eq(@rt.find_secret_fields(Json::null()).length(), 0)
  assert_eq(@rt.find_secret_fields(Json::object(Map::new())).length(), 0)
}
