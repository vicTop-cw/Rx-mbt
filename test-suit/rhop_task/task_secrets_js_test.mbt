// ============================================================================
// rhop_task · 敏感信息层测试（js 专属：需要真加解密）
//
// 覆盖：
//   1. 兄弟键密文解密（*_cipher）
//   2. 秘密节点 cipher + env 解锁
//   3. 单值敏感叶密文自动解密
//   4. 密钥不符 → 可诊断 Err（不静默留空）
// ============================================================================

///|
test "secrets-js · 兄弟键密文解密（明文为空时才用密文）" {
  let crypto = @rp.RhopCrypto::from_key("task-secret-key")
  let cipher = crypto.encrypt_secret("p@ss-from-cipher")
  assert_true(@rp.is_secret(cipher))
  let cfg = @json.parse(
    "{\"sftp\":{\"host\":\"h\",\"password_plain\":\"\",\"password_cipher\":\"" +
    cipher +
    "\"}}",
  ) catch {
    _ => fail("x")
  }
  let resolver = @rt.SecretResolver::new(
    Some(crypto),
    false,
    false,
    @rt.default_skip_paths(),
  )
  let resolved = match resolver.resolve(cfg) {
    Ok(v) => v
    Err(e) => fail("密文解密失败: \{e}")
  }
  match resolved {
    { "sftp": { "password": String(p), .. }, .. } =>
      assert_eq(p, "p@ss-from-cipher")
    _ => fail("兄弟键密文未收敛: " + Json::stringify(resolved))
  }
  // findings 里应有一条 cipher 记录
  let mut has_cipher = false
  for f in resolver.findings() {
    if f.action == "cipher" {
      has_cipher = true
    }
  }
  assert_true(has_cipher)
}

///|
test "secrets-js · 秘密节点 cipher + env 解锁（外层密钥来自环境变量）" {
  let master = @rp.RhopCrypto::from_key("outer-master-key")
  let inner_cipher = master.encrypt_secret("real-inner-key")
  @env.set_env_var("RHOP_TASK_UNLOCK_JS", "outer-master-key")
  let cfg = @json.parse(
    "{\"relay\":{\"token\":{\"plain\":\"\",\"cipher\":\"" +
    inner_cipher +
    "\",\"env\":\"RHOP_TASK_UNLOCK_JS\"}}}",
  ) catch {
    _ => fail("x")
  }
  let resolver = @rt.SecretResolver::new(
    Some(master),
    false,
    false,
    @rt.default_skip_paths(),
  )
  let resolved = match resolver.resolve(cfg) {
    Ok(v) => v
    Err(e) => fail("秘密节点解密失败: \{e}")
  }
  match resolved {
    { "relay": { "token": String(t), .. }, .. } =>
      assert_eq(t, "real-inner-key")
    _ => fail("秘密节点未收敛: " + Json::stringify(resolved))
  }
  @env.unset_env_var("RHOP_TASK_UNLOCK_JS")
}

///|
test "secrets-js · 单值敏感叶密文自动解密" {
  let crypto = @rp.RhopCrypto::from_key("task-secret-key-2")
  let cipher = crypto.encrypt_secret("leaf-secret")
  let cfg = @json.parse(
    "{\"online\":[{\"kind\":\"sftp\",\"host\":\"h\",\"password\":\"" +
    cipher +
    "\"}]}",
  ) catch {
    _ => fail("x")
  }
  let resolver = @rt.SecretResolver::new(
    Some(crypto),
    false,
    false,
    @rt.default_skip_paths(),
  )
  let resolved = match resolver.resolve(cfg) {
    Ok(v) => v
    Err(e) => fail("敏感叶解密失败: \{e}")
  }
  match resolved {
    { "online": Array(items), .. } =>
      match items[0] {
        { "password": String(p), .. } => assert_eq(p, "leaf-secret")
        _ => fail("敏感叶未解密: " + Json::stringify(items[0]))
      }
    _ => fail("online 结构异常")
  }
}

///|
test "secrets-js · 密钥不符 → 可诊断 Err（不静默留空）" {
  let right = @rp.RhopCrypto::from_key("right-key")
  let cipher = right.encrypt_secret("secret-value")
  let cfg = @json.parse("{\"sftp\":{\"password\":\"" + cipher + "\"}}") catch {
    _ => fail("x")
  }
  let wrong = @rp.RhopCrypto::from_key("wrong-key")
  let resolver = @rt.SecretResolver::new(
    Some(wrong),
    false,
    false,
    @rt.default_skip_paths(),
  )
  match resolver.resolve(cfg) {
    Err(e) => {
      assert_true(e.contains("解密失败"))
      assert_true(e.contains("sftp.password"))
    }
    Ok(v) => fail("错密钥应当 Err，实得: " + Json::stringify(v))
  }
}
