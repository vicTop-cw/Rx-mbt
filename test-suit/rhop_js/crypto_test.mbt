// ============================================================================
// rhop · 密码学测试（js 目标）
//
// 覆盖：
//   1. key.mbt：常量 / is_secret / load_key 三分支优先级 / 缺失密钥错误文本 / VerifyResult
//   2. crypto.mbt Fernet 加密侧：encrypt_json（信封结构）、encrypt_secret（RHOP-ENC）
//   3. crypto.mbt 解密验证侧：decrypt_verify 四态（OK / MALFORMED / BAD_TOKEN / NOT_JSON）、
//      decrypt_secret 三类可诊断 Err、from_path / from_env
//   4. 跨实现互操作（硬判据）：
//      - Python vools-rhop 产生的密文（KAT 常量）→ MoonBit 解密验证通过；
//      - MoonBit 产生的密文写出 fixtures/moonbit_vectors.json，交 Python 侧复核；
//      - qa-platform 的 fixtures/vools_vectors.json 到位后自动消费（未到位软跳过）。
//   5. 边界四问：空 key / 空 ct / 坏 base64 / 超长 payload / 重复 DEK（不适用的已注明）
// ============================================================================

// ---------------------------------------------------------------------------
// JS 环境辅助（测试包是 js-only，可直接用 node 内置模块）
// ---------------------------------------------------------------------------

///|
/// 仓库根目录：从 process.cwd() 逐级上溯找 moon.mod（不依赖 moon test 的启动 cwd）。
extern "js" fn ffi_module_root() -> String =
  #| () => { const fs = process.getBuiltinModule("node:fs"); const path = process.getBuiltinModule("node:path"); let d = process.cwd(); for (;;) { try { if (fs.existsSync(path.join(d, "moon.mod"))) { return d; } } catch (_e) {} const p = path.dirname(d); if (p === d) { return process.cwd(); } d = p; } }

///|
extern "js" fn ffi_read_text(path : String) -> String =
  #| (path) => { try { return process.getBuiltinModule("node:fs").readFileSync(path, "utf8"); } catch (_e) { return ""; } }

///|
extern "js" fn ffi_write_text(path : String, content : String) -> Bool =
  #| (path, content) => { try { const fs = process.getBuiltinModule("node:fs"); const pathMod = process.getBuiltinModule("node:path"); fs.mkdirSync(pathMod.dirname(path), { recursive: true }); fs.writeFileSync(path, content, "utf8"); return true; } catch (_e) { return false; } }

///|
extern "js" fn ffi_exists(path : String) -> Bool =
  #| (path) => { try { return process.getBuiltinModule("node:fs").existsSync(path); } catch (_e) { return false; } }

///|
extern "js" fn ffi_tmp_dir() -> String =
  #| () => { try { return process.getBuiltinModule("node:os").tmpdir(); } catch (_e) { return "."; } }

///|
extern "js" fn ffi_remove(path : String) -> Unit =
  #| (path) => { try { process.getBuiltinModule("node:fs").unlinkSync(path); } catch (_e) {} }

///|
fn fixtures_path(name : String) -> String {
  ffi_module_root() + "/test-suit/rhop_js/fixtures/" + name
}

///|
/// 取子串（[start, end) 字符区间）；越界返回空串而不 panic。
/// 用 `get_view` 而非已废弃的 `substring`。
fn slice(s : String, start : Int32, end : Int32) -> String {
  match s.get_view(start~, end~) {
    Some(v) => v.to_owned()
    None => ""
  }
}

///|
/// 把 ct 包成 Fernet 信封文本（与 encrypt_json 输出同形）。
fn envelope_of(ct : String) -> String {
  "{\"v\": 1, \"alg\": \"fernet\", \"ct\": \"" + ct + "\"}"
}

///|
/// 把字符串中间第 idx 个字符替换成"另一个"base64url 字符（制造篡改，不动 '=' 补位）。
fn tamper_at(s : String, idx : Int32) -> String {
  let old = slice(s, idx, idx + 1)
  let new = if old == "A" { "B" } else { "A" }
  slice(s, 0, idx) + new + slice(s, idx + 1, s.length())
}

// ---------------------------------------------------------------------------
// 已知答案向量（KAT）——由 Python 参考实现 vools.rhop.crypto 生成
//   key   = rx-mbt-rhop-test-key-v1
//   salt  = sha256(utf8(key))[0..16] = 18d73729bf32e7be14a2f57966d48046
//   key32 = PBKDF2-SHA256(key, salt, 200000, 32)
//         = a8a9ec885bf413f88eddfa55d8590d8cb1f76c01daa2a0f9b143c21b9f172fa6
//   明文  = {"msg": "你好 rhop", "n": 42, "ok": true, "arr": [1, 2, 3], "nested": {"k": "v"}}
// 生成环境：Windows / Python 3.13.14 / cryptography + vools 0.9.0（vools.rhop.crypto）。
// ---------------------------------------------------------------------------

///|
let kat_key : String = "rx-mbt-rhop-test-key-v1"

///|
let kat_payload_json : String = "{\"msg\": \"你好 rhop\", \"n\": 42, \"ok\": true, \"arr\": [1, 2, 3], \"nested\": {\"k\": \"v\"}}"

///|
/// Python `RhopCrypto.encrypt_json(payload)` 的原样输出（信封 JSON 文本）。
let kat_envelope : String = "{\"v\": 1, \"alg\": \"fernet\", \"ct\": \"Z0FBQUFBQnE0SkpCLVJGRWdyclQ1NUdQNzV2WmtrUG5WbGNFeXFocUJHU1g5Yk1mRFFIaG9LdmZWQUFuaWZUc1NjMjluZ25vWko1UTlSTUlmR092SlZGaHdMVUFRcTduTlMxWU9NRE9GcmNIN2dRRkZ6LS01aXo0M1l1N1NoMElQTXo0dnpYMjBmQ01kYzFZTTh3ZEdJUlRXZVlXQnl1aWhQcUpXVXFVWDl4R2FSVS1ZQVY5azNfdU9sQ2VyNjJwLWE4NkxlczI4ajg1\"}"

///|
/// 同一把 Fernet 密钥加密非 JSON 明文 `hello-not-json` 后包成的信封 → 期望 NOT_JSON。
let kat_nonjson_envelope : String = "{\"v\": 1, \"alg\": \"fernet\", \"ct\": \"Z0FBQUFBQnE0SkpCdlhJcks2SE9qaGR6aXhNM3pXbzhQNUFoQmhWUVcxQWtSbmk0SjZOOWVGaDFwSXJuMWdtR0ptdWdUSHlsMWFiRFBHR0dyMzJxT1prQUE2OWZSekk3SFE9PQ==\"}"

///|
/// 上面 kat_envelope 的 ct 末位被改动后的信封 → 期望 BAD_TOKEN。
let kat_tampered_envelope : String = "{\"v\": 1, \"alg\": \"fernet\", \"ct\": \"Z0FBQUFBQnE0SkpCLVJGRWdyclQ1NUdQNzV2WmtrUG5WbGNFeXFocUJHU1g5Yk1mRFFIaG9LdmZWQUFuaWZUc1NjMjluZ25vWko1UTlSTUlmR092SlZGaHdMVUFRcTduTlMxWU9NRE9GcmNIN2dRRkZ6LS01aXo0M1l1N1NoMElQTXo0dnpYMjBmQ01kYzFZTTh3ZEdJUlRXZVlXQnl1aWhQcUpXVXFVWDl4R2FSVS1ZQVY5azNfdU9sQ2VyNjJwLWE4NkxlczI4ajgA\"}"

///|
/// Python `RhopCrypto.encrypt_secret("s3cr3t-token")` 的原样输出。
let kat_secret : String = "RHOP-ENC:Z0FBQUFBQnE0SkpCYlFKQWt4WExvZ3RBam9HNWdvUlBmUVEzbDhYMllRUlNpNUdRSVBJQTR1V05Nd1N0WHRHQ0pyZ0RzX0hia3czX1VmMjBUMDM0Q2dkLU1VYU9xa09Ga1E9PQ=="

///|
let kat_secret_plain : String = "s3cr3t-token"

// ---------------------------------------------------------------------------
// 1. key.mbt
// ---------------------------------------------------------------------------

///|
test "key · 常量与 is_secret（正反例）" {
  assert_eq(@rp.env_rhop_key, "RHOP_KEY")
  assert_eq(@rp.secret_prefix, "RHOP-ENC:")
  // 契约字面量别名与 snake_case 常量同值
  assert_eq(@rp.ENV_RHOP_KEY, @rp.env_rhop_key)
  assert_eq(@rp.SECRET_PREFIX, @rp.secret_prefix)
  assert_true(@rp.is_secret("RHOP-ENC:abc"))
  assert_true(@rp.is_secret("RHOP-ENC:"))
  assert_false(@rp.is_secret(""))
  assert_false(@rp.is_secret("RHOP-ENC"))
  assert_false(@rp.is_secret("plain RHOP-ENC:x"))
  assert_false(@rp.is_secret("rhop-enc:abc"))
}

///|
test "key · VerifyResult 构造与 to_string" {
  let ok = @rp.VerifyResult::pass(Json::object({ "a": Json::number(1.0) }))
  assert_true(ok.ok)
  assert_eq(ok.reason, "OK")
  assert_true(ok.payload is Some(_))
  let bad = @rp.VerifyResult::fail("BAD_TOKEN")
  assert_false(bad.ok)
  assert_eq(bad.reason, "BAD_TOKEN")
  assert_true(bad.payload is None)
  let s = @rp.VerifyResult::to_string(bad)
  assert_true(s.contains("BAD_TOKEN"))
  assert_true(s.contains("ok=false"))
}

///|
test "key · load_key 优先级 source > path > env" {
  @env.set_env_var("RHOP_TEST_KEY_B1", "from-env")
  // 三分支齐给：source 胜出
  let r1 = @rp.load_key(
    Some("from-source"),
    Some("/definitely/not/exists"),
    "RHOP_TEST_KEY_B1",
  )
  assert_eq(r1, Ok("from-source"))
  // 只给 path + env：path 胜出（先落一个密钥文件）
  let keyfile = ffi_tmp_dir() + "/rhop_key_b1.txt"
  assert_true(ffi_write_text(keyfile, "  from-file\n"))
  let r2 = @rp.load_key(None, Some(keyfile), "RHOP_TEST_KEY_B1")
  assert_eq(r2, Ok("from-file"))
  // 只给 env
  let r3 = @rp.load_key(None, None, "RHOP_TEST_KEY_B1")
  assert_eq(r3, Ok("from-env"))
  ffi_remove(keyfile)
  @env.unset_env_var("RHOP_TEST_KEY_B1")
}

///|
test "key · load_key 空 source / 空文件 / 全缺失的错误文本" {
  @env.set_env_var("RHOP_TEST_KEY_B1B", "  ")
  // 空 source 视为未提供（不返回空密钥），继续向下 → env 为空白 → 最终 Err
  let r = @rp.load_key(Some(""), None, "RHOP_TEST_KEY_B1B")
  match r {
    Err(e) => {
      assert_true(e.contains("未找到本地固定密钥"))
      assert_true(e.contains("RHOP_TEST_KEY_B1B"))
    }
    Ok(_) => fail("空 source + 空白 env 应当 Err")
  }
  // 环境变量未设置
  let r2 = @rp.load_key(None, None, "RHOP_TEST_KEY_ABSENT_B1")
  match r2 {
    Err(e) => assert_true(e.contains("未找到本地固定密钥"))
    Ok(_) => fail("全缺失应当 Err")
  }
  // 密钥文件存在但内容为空 → Err（空密钥几乎总是配置事故）
  let empty = ffi_tmp_dir() + "/rhop_key_empty_b1.txt"
  assert_true(ffi_write_text(empty, "   \n\t\n"))
  let r3 = @rp.load_key(None, Some(empty), "RHOP_TEST_KEY_ABSENT_B1")
  match r3 {
    Err(e) => assert_true(e.contains("密钥文件内容为空"))
    Ok(_) => fail("空密钥文件应当 Err")
  }
  // 密钥文件不存在 → Err
  let r4 = @rp.load_key(
    None,
    Some("/no/such/key/file.txt"),
    "RHOP_TEST_KEY_ABSENT_B1",
  )
  match r4 {
    Err(e) => assert_true(e.contains("读取密钥文件失败"))
    Ok(_) => fail("不存在的密钥文件应当 Err")
  }
  ffi_remove(empty)
  @env.unset_env_var("RHOP_TEST_KEY_B1B")
}

///|
test "key · load_key_from_path / load_key_from_env 单独行为" {
  let keyfile = ffi_tmp_dir() + "/rhop_key_b1c.txt"
  assert_true(ffi_write_text(keyfile, "  path-key-1  \n"))
  assert_eq(@rp.load_key_from_path(keyfile), Ok("path-key-1"))
  match @rp.load_key_from_path("/no/such/file") {
    Err(_) => ()
    Ok(_) => fail("不存在的密钥文件应当 Err")
  }
  ffi_remove(keyfile)
  @env.set_env_var("RHOP_TEST_KEY_B1C", "env-key-1")
  assert_eq(@rp.load_key_from_env("RHOP_TEST_KEY_B1C"), Ok("env-key-1"))
  match @rp.load_key_from_env("RHOP_TEST_KEY_B1C_NOPE") {
    Err(_) => ()
    Ok(_) => fail("未设置的 env 应当 Err")
  }
  @env.unset_env_var("RHOP_TEST_KEY_B1C")
}

// ---------------------------------------------------------------------------
// 2. crypto 加密侧
// ---------------------------------------------------------------------------

///|
test "crypto · encrypt_json 信封结构（v / alg / ct）" {
  let c = @rp.RhopCrypto::from_key(kat_key)
  let env = c.encrypt_json(Json::object({ "hello": Json::string("世界") }))
  assert_true(env != "")
  // 与 Python json.dumps 同形：含 ", " / ": " 分隔
  assert_true(env.has_prefix("{\"v\": 1, \"alg\": \"fernet\", \"ct\": \""))
  let j = @json.parse(env) catch { _ => fail("信封不是合法 JSON") }
  match j {
    { "v": Number(v, ..), "alg": String(alg), "ct": String(ct), .. } => {
      assert_eq(v, 1.0)
      assert_eq(alg, "fernet")
      // ct = base64url(utf8(base64url(token_raw)))，只允许 base64url 字母表 + '='
      assert_true(ct.length() > 0)
      for ch in ct {
        let okc = (ch >= 'A' && ch <= 'Z') ||
          (ch >= 'a' && ch <= 'z') ||
          (ch >= '0' && ch <= '9') ||
          ch == '-' ||
          ch == '_' ||
          ch == '='
        if !okc {
          fail("ct 含非 base64url 字符: \{ch}")
        }
      }
    }
    _ => fail("信封字段缺失或类型错误")
  }
}

///|
test "crypto · encrypt_json_text：合法 JSON 原样、非 JSON 包 __text__" {
  let c = @rp.RhopCrypto::from_key(kat_key)
  let text_json = "{\"a\": 1}"
  let env1 = c.encrypt_json_text(text_json)
  let r1 = c.decrypt_verify(env1)
  assert_true(r1.ok)
  match r1.payload {
    // Json::stringify 输出紧凑形态（与 Python json.dumps 默认分隔符不同，但语义等价）
    Some(p) => assert_eq(Json::stringify(p), "{\"a\":1}")
    None => fail("payload 缺失")
  }
  let env2 = c.encrypt_json_text("just a plain string")
  let r2 = c.decrypt_verify(env2)
  assert_true(r2.ok)
  match r2.payload {
    Some(p) =>
      assert_eq(Json::stringify(p), "{\"__text__\":\"just a plain string\"}")
    None => fail("payload 缺失")
  }
}

///|
test "crypto · encrypt_secret 空明文返回空串 / 非空带前缀" {
  let c = @rp.RhopCrypto::from_key(kat_key)
  assert_eq(c.encrypt_secret(""), "")
  let s = c.encrypt_secret("p@ssw0rd")
  assert_true(s.has_prefix(@rp.secret_prefix))
  assert_true(@rp.is_secret(s))
  assert_true(s != "RHOP-ENC:")
}

// ---------------------------------------------------------------------------
// 3. crypto 解密验证侧
// ---------------------------------------------------------------------------

///|
test "crypto · Python KAT：vools 加密 → MoonBit 解密验证 OK" {
  let c = @rp.RhopCrypto::from_key(kat_key)
  // kat_payload_json 是 Python json.dumps(ensure_ascii=False) 的原样输出（含 ", "/": " 分隔），
  // 仅作人工对照；断言用字段级比对（Json::stringify 是紧凑形态）。
  assert_true(kat_payload_json.contains("你好 rhop"))
  let r = c.decrypt_verify(kat_envelope)
  assert_true(r.ok)
  assert_eq(r.reason, "OK")
  match r.payload {
    None => fail("KAT 解密后 payload 缺失")
    Some(p) =>
      match p {
        {
          "msg": String(msg),
          "n": Number(n, ..),
          "ok": True,
          "arr": Array(arr),
          "nested": nested,
          ..
        } => {
          assert_eq(msg, "你好 rhop")
          assert_eq(n, 42.0)
          assert_eq(arr.length(), 3)
          match nested {
            { "k": String(k), .. } => assert_eq(k, "v")
            _ => fail("KAT nested 结构不符")
          }
        }
        _ => fail("KAT payload 结构不符: " + Json::stringify(p))
      }
  }
}

///|
test "crypto · Python KAT：RHOP-ENC 秘密串 → MoonBit decrypt_secret" {
  let c = @rp.RhopCrypto::from_key(kat_key)
  assert_eq(c.decrypt_secret(kat_secret), Ok(kat_secret_plain))
  // 空值返回空串（配置里「没填」的语义）
  assert_eq(c.decrypt_secret(""), Ok(""))
}

///|
test "crypto · encrypt_json → decrypt_verify 本地往返（多种载荷）" {
  let c = @rp.RhopCrypto::from_key(kat_key)
  let payloads : Array[Json] = [
    Json::object({}),
    Json::null(),
    Json::array([Json::number(1.0), Json::string("二"), Json::boolean(true)]),
    Json::object({
      "中文键": Json::string("中文值"),
      "n": Json::number(-1.5),
    }),
    Json::object({
      "deep": Json::object({
        "a": Json::array([Json::object({ "b": Json::string("c") })]),
      }),
    }),
  ]
  for i in 0..<payloads.length() {
    let p = payloads[i]
    let env = c.encrypt_json(p)
    assert_true(env != "")
    let r = c.decrypt_verify(env)
    if !r.ok {
      fail("第 \{i} 个载荷往返失败: reason=\{r.reason}")
    }
    match r.payload {
      Some(back) => assert_eq(Json::stringify(back), Json::stringify(p))
      None => fail("第 \{i} 个载荷 payload 缺失")
    }
  }
}

///|
test "crypto · encrypt_secret → decrypt_secret 往返（含非 JSON 明文）" {
  let c = @rp.RhopCrypto::from_key(kat_key)
  let plains : Array[String] = [
    "p@ssw0rd", "中文密码", "multi\nline\ntoken", "hello-not-json",
  ]
  for p in plains {
    let s = c.encrypt_secret(p)
    assert_true(@rp.is_secret(s))
    assert_eq(c.decrypt_secret(s), Ok(p))
  }
}

///|
test "crypto · MALFORMED 十种坏信封" {
  let c = @rp.RhopCrypto::from_key(kat_key)
  let bads : Array[String] = [
    "", // 空串
     "not json at all", // 非法 JSON
     "[1, 2, 3]", // JSON 但不是对象
     "\"a string\"", // 标量字符串
     "{\"v\": 2, \"alg\": \"fernet\", \"ct\": \"x\"}", // v 版本不符
     "{\"v\": 1, \"alg\": \"aes\", \"ct\": \"x\"}", // alg 不符
     "{\"v\": 1, \"alg\": \"fernet\"}", // 缺 ct
     "{\"v\": 1, \"alg\": \"fernet\", \"ct\": \"\"}", // ct 空串
     "{\"v\": 1, \"alg\": \"fernet\", \"ct\": 123}", // ct 非字符串
     "{\"v\": \"1\", \"alg\": \"fernet\", \"ct\": \"x\"}", // v 类型错
  ]
  for i in 0..<bads.length() {
    let b = bads[i]
    let r = c.decrypt_verify(b)
    if r.reason != "MALFORMED" {
      fail("第 \{i} 个坏信封期望 MALFORMED，实得 \{r.reason}")
    }
    assert_false(r.ok)
    assert_true(r.payload is None)
  }
}

///|
test "crypto · BAD_TOKEN：错密钥 / 篡改 / 坏 base64 / 全零 token" {
  let c = @rp.RhopCrypto::from_key(kat_key)
  // 1) 错密钥
  let other = @rp.RhopCrypto::from_key("another-key")
  assert_eq(other.decrypt_verify(kat_envelope).reason, "BAD_TOKEN")
  // 2) Python KAT 的篡改信封
  assert_eq(c.decrypt_verify(kat_tampered_envelope).reason, "BAD_TOKEN")
  // 3) 本地加密后篡改 ct：改中间一个字符（注意不能追加在 '=' 补位之后——Node/Python
  //    的 base64 解码会忽略补位之后的字节，那样的"篡改"其实不生效）
  let env = c.encrypt_json(Json::object({ "a": Json::number(1.0) }))
  let j = @json.parse(env) catch { _ => fail("本地信封解析失败") }
  let ct = match j {
    { "ct": String(ct), .. } => ct
    _ => fail("取 ct 失败")
  }
  let tampered = envelope_of(tamper_at(ct, 20))
  assert_eq(c.decrypt_verify(tampered).reason, "BAD_TOKEN")
  // 4) 坏 base64
  assert_eq(
    c.decrypt_verify(
      "{\"v\": 1, \"alg\": \"fernet\", \"ct\": \"!!!not-base64!!!\"}",
    ).reason,
    "BAD_TOKEN",
  )
  // 5) 合法 base64 但内容不是 Fernet token
  assert_eq(
    c.decrypt_verify("{\"v\": 1, \"alg\": \"fernet\", \"ct\": \"AAAA\"}").reason,
    "BAD_TOKEN",
  )
  // 6) 信封结构对、算法段全零（版本位不是 0x80）
  assert_eq(
    c.decrypt_verify(
      "{\"v\": 1, \"alg\": \"fernet\", \"ct\": \"Z0FBQUFBQQ==\"}",
    ).reason,
    "BAD_TOKEN",
  )
}

///|
test "crypto · NOT_JSON：Python KAT 非 JSON 明文 + 本地 encrypt_secret 明文" {
  let c = @rp.RhopCrypto::from_key(kat_key)
  assert_eq(c.decrypt_verify(kat_nonjson_envelope).reason, "NOT_JSON")
  // 本地：把 encrypt_secret 的 ct 直接包成信封 → 明文非 JSON
  let s = c.encrypt_secret("hello-not-json-2")
  let ct = s.replace(old=@rp.secret_prefix, new="")
  let env = "{\"v\": 1, \"alg\": \"fernet\", \"ct\": \"" + ct + "\"}"
  assert_eq(c.decrypt_verify(env).reason, "NOT_JSON")
}

///|
test "crypto · decrypt_secret 三类可诊断 Err" {
  let c = @rp.RhopCrypto::from_key(kat_key)
  // 1) 前缀不符
  match c.decrypt_secret("plain-text-password") {
    Err(e) => {
      assert_true(e.contains("不是 rhop 密文"))
      assert_true(e.contains("RHOP-ENC:"))
    }
    Ok(_) => fail("前缀不符应当 Err")
  }
  // 2) 前缀后为空
  match c.decrypt_secret("RHOP-ENC:") {
    Err(e) => assert_true(e.contains("密文为空"))
    Ok(_) => fail("空密文应当 Err")
  }
  // 3) 密钥不符
  let other = @rp.RhopCrypto::from_key("wrong-key")
  match other.decrypt_secret(kat_secret) {
    Err(e) => {
      assert_true(e.contains("密文解密失败"))
      assert_true(e.contains("密钥不符或密文被篡改"))
    }
    Ok(_) => fail("错密钥应当 Err")
  }
  // 4) 篡改密文（改中间一个字符，避开 '=' 补位）
  let tampered = tamper_at(kat_secret, 25)
  match c.decrypt_secret(tampered) {
    Err(e) => assert_true(e.contains("密文解密失败"))
    Ok(_) => fail("篡改密文应当 Err")
  }
}

///|
test "crypto · from_path / from_env 构造路径" {
  let keyfile = ffi_tmp_dir() + "/rhop_crypto_key_b1.txt"
  assert_true(ffi_write_text(keyfile, kat_key + "\n"))
  match @rp.RhopCrypto::from_path(keyfile) {
    Ok(c) => {
      assert_eq(c.decrypt_verify(kat_envelope).reason, "OK")
      assert_eq(c.key_material(), kat_key)
    }
    Err(e) => fail("from_path 失败: \{e}")
  }
  match @rp.RhopCrypto::from_path("/no/such/key.txt") {
    Err(_) => ()
    Ok(_) => fail("from_path 对不存在的文件应当 Err")
  }
  ffi_remove(keyfile)
  @env.set_env_var("RHOP_TEST_KEY_B1D", kat_key)
  match @rp.RhopCrypto::from_env("RHOP_TEST_KEY_B1D") {
    Ok(c) => assert_eq(c.decrypt_verify(kat_envelope).reason, "OK")
    Err(e) => fail("from_env 失败: \{e}")
  }
  match @rp.RhopCrypto::from_env("RHOP_TEST_KEY_B1D_NOPE") {
    Err(_) => ()
    Ok(_) => fail("from_env 对未设置的变量应当 Err")
  }
  @env.unset_env_var("RHOP_TEST_KEY_B1D")
}

// ---------------------------------------------------------------------------
// 4. 边界四问
// ---------------------------------------------------------------------------

///|
test "边界 · 空 key 可用（PBKDF2 派生，往返一致）" {
  let c = @rp.RhopCrypto::from_key("")
  let env = c.encrypt_json(Json::object({ "k": Json::string("v") }))
  assert_true(env != "")
  assert_eq(c.decrypt_verify(env).reason, "OK")
  // 空 key ≠ 非空 key（同一密文用另一把 key 解不开）
  assert_eq(
    @rp.RhopCrypto::from_key("x").decrypt_verify(env).reason,
    "BAD_TOKEN",
  )
}

///|
test "边界 · 空明文加密结果仍非空（空 ct 已在 MALFORMED 覆盖）" {
  let c = @rp.RhopCrypto::from_key(kat_key)
  let env = c.encrypt_json(Json::string(""))
  assert_true(env != "")
  let r = c.decrypt_verify(env)
  assert_true(r.ok)
  match r.payload {
    Some(p) => assert_eq(Json::stringify(p), "\"\"")
    None => fail("payload 缺失")
  }
}

///|
test "边界 · 超长 payload（约 80KB）往返" {
  let sb = StringBuilder()
  for _ in 0..<2000 {
    sb.write_string("0123456789012345678901234567890123456789")
  }
  let blob = sb.to_string()
  assert_true(blob.length() > 79000)
  let c = @rp.RhopCrypto::from_key(kat_key)
  let env = c.encrypt_json(Json::object({ "blob": Json::string(blob) }))
  let r = c.decrypt_verify(env)
  assert_true(r.ok)
  match r.payload {
    Some(p) =>
      match p {
        { "blob": String(back), .. } => assert_eq(back, blob)
        _ => fail("超长 payload 结构不符")
      }
    None => fail("超长 payload payload 缺失")
  }
}

///|
test "边界 · 重复 DEK 不适用（Fernet 无 DEK）；同明文两次加密 ct 必不同" {
  // Fernet 每次随机 16B IV，故同一明文两次加密结果不同、但都能解回同一载荷。
  // vools 侧同样如此（无 DEK 概念，密钥由 PBKDF2 确定性派生）。
  let c = @rp.RhopCrypto::from_key(kat_key)
  let p = Json::object({ "same": Json::string("payload") })
  let e1 = c.encrypt_json(p)
  let e2 = c.encrypt_json(p)
  assert_true(e1 != e2)
  assert_eq(c.decrypt_verify(e1).reason, "OK")
  assert_eq(c.decrypt_verify(e2).reason, "OK")
}

// ---------------------------------------------------------------------------
// 5. 跨实现双向互操作
// ---------------------------------------------------------------------------

///|
test "互操作 · 写出 MoonBit 向量供 Python 复核（fixtures/moonbit_vectors.json）" {
  let c = @rp.RhopCrypto::from_key(kat_key)
  let payload = Json::object({
    "msg": Json::string("你好 rhop（MoonBit 侧生成）"),
    "n": Json::number(7.0),
    "ok": Json::boolean(true),
    "arr": Json::array([Json::number(1.0), Json::number(2.0)]),
    "nested": Json::object({ "k": Json::string("v") }),
  })
  let payload_json = Json::stringify(payload)
  let env = c.encrypt_json(payload)
  assert_true(env != "")
  let secret = c.encrypt_secret("moonbit-s3cr3t")
  assert_true(@rp.is_secret(secret))
  // 非 JSON 明文的信封：Python 侧 decrypt_verify 期望 NOT_JSON
  let nonjson_ct = c.encrypt_secret("hello-from-moonbit-not-json")
  let nonjson_env = "{\"v\": 1, \"alg\": \"fernet\", \"ct\": \"" +
    nonjson_ct.replace(old=@rp.secret_prefix, new="") +
    "\"}"
  let doc = Json::object({
    "generated_by": Json::string("rx-mbt test-suit/rhop_js/crypto_test.mbt"),
    "target": Json::string("js"),
    "alg": Json::string("fernet-vtext-compatible"),
    "key": Json::string(kat_key),
    "payload_json": Json::string(payload_json),
    "envelope_json": Json::string(env),
    "secret": Json::string(secret),
    "secret_plain": Json::string("moonbit-s3cr3t"),
    "envelope_nonjson": Json::string(nonjson_env),
    "expect": Json::object({
      "envelope_json": Json::string("decrypt_verify -> OK"),
      "secret": Json::string("decrypt_secret -> moonbit-s3cr3t"),
      "envelope_nonjson": Json::string("decrypt_verify -> NOT_JSON"),
    }),
  })
  let path = fixtures_path("moonbit_vectors.json")
  let ok = ffi_write_text(path, Json::stringify(doc, indent=2))
  if !ok {
    fail("写 fixtures/moonbit_vectors.json 失败: \{path}")
  }
  // 自证：写出的内容能被自己读回并解密
  let back = ffi_read_text(path)
  assert_true(back != "")
  let bj = @json.parse(back) catch {
    _ => fail("写出的向量不是合法 JSON")
  }
  match bj {
    { "envelope_json": String(e2), .. } =>
      assert_eq(c.decrypt_verify(e2).reason, "OK")
    _ => fail("写出的向量缺 envelope_json")
  }
}

///|
test "互操作 · 消费 qa fixtures/vools_vectors.json（Python vools → MoonBit）" {
  let path = fixtures_path("vools_vectors.json")
  if !ffi_exists(path) {
    println("[crypto_test] fixtures/vools_vectors.json 未就绪 → 软跳过")
    return
  }
  let text = ffi_read_text(path)
  if text == "" {
    println(
      "[crypto_test] fixtures/vools_vectors.json 读取失败 → 软跳过",
    )
    return
  }
  let j = @json.parse(text) catch {
    _ => fail("fixtures/vools_vectors.json 不是合法 JSON")
  }
  let crypto = match j {
    { "crypto": c, .. } => c
    _ => {
      println("[crypto_test] fixture 无 crypto 段 → 软跳过")
      return
    }
  }
  let key = match crypto {
    { "key": String(k), .. } => k
    _ => fail("fixture crypto 段缺 key")
  }
  let c = @rp.RhopCrypto::from_key(key)
  // (1) encrypt_json_cases：vools 加密 → MoonBit decrypt_verify 必须 OK 且载荷逐字段一致
  let mut json_total = 0
  match crypto {
    { "encrypt_json_cases": Array(cases), .. } =>
      for case in cases {
        let name = match case {
          { "name": String(n), .. } => n
          _ => "?"
        }
        let env = match case {
          { "ciphertext_json_text": String(s), .. } => s
          _ => fail("encrypt_json case \{name} 缺 ciphertext_json_text")
        }
        let expect = match case {
          { "payload": p, .. } => p
          _ => fail("encrypt_json case \{name} 缺 payload")
        }
        // fixture 自带 vools 真值，先核对其 reason 是 OK（防止向量本身是负例）
        match case {
          { "vools_decrypt": { "reason": String(vr), .. }, .. } =>
            if vr != "OK" {
              fail("encrypt_json case \{name} 的 vools 真值不是 OK: \{vr}")
            }
          _ => ()
        }
        let r = c.decrypt_verify(env)
        if !r.ok {
          fail("encrypt_json case \{name}：期望 OK，实得 \{r.reason}")
        }
        match r.payload {
          Some(back) =>
            if Json::stringify(back) != Json::stringify(expect) {
              fail(
                "encrypt_json case \{name} 载荷不一致: \{Json::stringify(back)} != \{Json::stringify(expect)}",
              )
            }
          None => fail("encrypt_json case \{name} payload 缺失")
        }
        json_total = json_total + 1
      }
    _ =>
      println("[crypto_test] fixture 无 encrypt_json_cases → 跳过该组")
  }
  // (2) encrypt_secret_cases：RHOP-ENC 密文 → MoonBit decrypt_secret 必须解回明文
  let mut secret_total = 0
  match crypto {
    { "encrypt_secret_cases": Array(cases), .. } =>
      for case in cases {
        let name = match case {
          { "name": String(n), .. } => n
          _ => "?"
        }
        let sec = match case {
          { "secret": String(s), .. } => s
          _ => fail("encrypt_secret case \{name} 缺 secret")
        }
        let plain = match case {
          { "plaintext_utf8": String(p), .. } => p
          _ => fail("encrypt_secret case \{name} 缺 plaintext_utf8")
        }
        match c.decrypt_secret(sec) {
          Ok(got) =>
            if got != plain {
              fail(
                "encrypt_secret case \{name} 明文不一致: \{got} != \{plain}",
              )
            }
          Err(e) => fail("encrypt_secret case \{name} 解密失败: \{e}")
        }
        secret_total = secret_total + 1
      }
    _ =>
      println("[crypto_test] fixture 无 encrypt_secret_cases → 跳过该组")
  }
  // (3) negative_cases：逐条对齐 vools 真实 reason（不是我们自说自话）
  let mut neg_total = 0
  match crypto {
    { "negative_cases": Array(cases), .. } =>
      for case in cases {
        let name = match case {
          { "name": String(n), .. } => n
          _ => "?"
        }
        let input = match case {
          { "input": String(s), .. } => s
          _ => fail("negative case \{name} 缺 input")
        }
        let expect_obj = match case {
          { "expect": e, .. } => e
          _ => fail("negative case \{name} 缺 expect")
        }
        let expect_reason = match expect_obj {
          { "reason": String(r), .. } => r
          _ => fail("negative case \{name} 缺 expect.reason")
        }
        // fixture 里还有 vools 实测 reason，交叉核对（两者不一致说明 fixture 坏了）
        match case {
          { "vools_actual_reason": String(vr), .. } =>
            if vr != expect_reason {
              fail(
                "negative case \{name}: fixture 自身矛盾 expect=\{expect_reason} vools_actual=\{vr}",
              )
            }
          _ => ()
        }
        let r = c.decrypt_verify(input)
        if r.reason != expect_reason {
          fail(
            "negative case \{name}: 期望 \{expect_reason}，实得 \{r.reason}",
          )
        }
        if r.ok {
          fail("negative case \{name}: 期望 ok=false，实得 ok=true")
        }
        neg_total = neg_total + 1
      }
    _ => println("[crypto_test] fixture 无 negative_cases → 跳过该组")
  }
  println(
    "[crypto_test] vools fixture 消费：encrypt_json=\{json_total}, encrypt_secret=\{secret_total}, negative=\{neg_total}, key=\{key}",
  )
  if json_total < 1 || secret_total < 1 || neg_total < 1 {
    fail("vools fixture 消费数量异常：三类应各至少 1 条")
  }
}

///|
test "互操作 · fixture KDF 参数与实现口径一致（salt/PBKDF2 参数自证）" {
  let path = fixtures_path("vools_vectors.json")
  if !ffi_exists(path) {
    println("[crypto_test] fixtures/vools_vectors.json 未就绪 → 软跳过")
    return
  }
  let text = ffi_read_text(path)
  let j = @json.parse(text) catch { _ => fail("fixtures 不是合法 JSON") }
  let crypto = match j {
    { "crypto": c, .. } => c
    _ => {
      println("[crypto_test] fixture 无 crypto 段 → 软跳过")
      return
    }
  }
  let kdf = match crypto {
    { "kdf": k, .. } => k
    _ => {
      println("[crypto_test] fixture 无 kdf 段 → 软跳过")
      return
    }
  }
  // 参数口径必须与 vools VText 一致
  match kdf {
    { "iterations": Number(it, ..), "dk_len": Number(dl, ..), .. } => {
      assert_eq(it, 200000.0)
      assert_eq(dl, 32.0)
    }
    _ => fail("fixture kdf 缺 iterations / dk_len")
  }
  // salt = sha256(key)[:16]：用 fixture 的 salt_hex 反查（解密已隐式证明 KDF 一致，
  // 这里再显式核对 fk_b64url 存在，防止 fixture 换了形状后本用例静默失效）
  match kdf {
    { "fk_b64url": String(fk), "salt_hex": String(_), .. } =>
      assert_true(fk.length() > 0)
    _ => fail("fixture kdf 缺 fk_b64url / salt_hex")
  }
}

// ---------------------------------------------------------------------------
// C4 P1 回归：密钥里的 UTF-8 BOM 必须被剥掉
//
// 背景：Windows 记事本 / PowerShell `Set-Content -Encoding utf8` 会在文件头写 BOM。
// 若把 BOM 当密钥的一部分，PBKDF2 派生出的 key32 与真实密钥不同 ⇒ Fernet HMAC 失败，
// 报错像"密钥不符/密文被篡改"（极难定位）。本用例锁定三种入口都被归一。
// ---------------------------------------------------------------------------

///|
test "key · C4 P1：文件/字符串/环境变量里的 UTF-8 BOM 均被剥掉" {
  let bom = "\u{FEFF}"
  let key = "bom-test-key-42"
  // ① source 字符串带 BOM
  assert_eq(@rp.load_key(Some(bom + key), None, "RHOP_BOM_ABSENT"), Ok(key))
  // ② 真实 BOM 文件
  let f = ffi_tmp_dir() + "/rhop_bom_key.txt"
  assert_true(ffi_write_text(f, bom + key + "\n"))
  assert_eq(@rp.load_key_from_path(f), Ok(key))
  // ③ 换行 + BOM + 前后空白
  assert_true(ffi_write_text(f, "\n" + bom + "  " + key + "  \n"))
  assert_eq(@rp.load_key_from_path(f), Ok(key))
  // ④ 语义级验证：BOM 文件必须能解开"干净 key"加密的信封
  //    （若 BOM 混进密钥，PBKDF2 派生不同 → 这里是 BAD_TOKEN）
  let clean = @rp.RhopCrypto::from_key(key)
  let payload = @json.parse("{\"a\": 1}") catch { _ => fail("x") }
  let env = clean.encrypt_json(payload)
  match @rp.RhopCrypto::from_path(f) {
    Ok(c) => assert_eq(c.decrypt_verify(env).reason, "OK")
    Err(e) => fail("from_path(BOM 文件) 失败: \{e}")
  }
  // ⑤ 环境变量带 BOM
  @env.set_env_var("RHOP_TEST_KEY_BOM", bom + key)
  assert_eq(@rp.load_key_from_env("RHOP_TEST_KEY_BOM"), Ok(key))
  assert_eq(@rp.load_key(None, None, "RHOP_TEST_KEY_BOM"), Ok(key))
  @env.unset_env_var("RHOP_TEST_KEY_BOM")
  ffi_remove(f)
  // ⑥ 纯 BOM 视为空 ⇒ 可诊断 Err（不能派生出"BOM 密钥"）
  let g = ffi_tmp_dir() + "/rhop_bom_only.txt"
  assert_true(ffi_write_text(g, bom))
  match @rp.load_key_from_path(g) {
    Err(e) => assert_true(e.contains("密钥文件内容为空"))
    Ok(_) => fail("纯 BOM 文件应当 Err")
  }
  ffi_remove(g)
}
