// ============================================================================
// rhop_vectors · 五分节互操作产物生产者（js-only）
//
// 目的：rx-mbt 目前没有「五分节」形状的 MoonBit 侧产物，`scripts/verify_interop.py
// --strict` 会因扁平产物把 5 个分节记成 SKIP（rc=1）。本包用真实 rhop API 对
// qa fixture（test-suit/rhop_js/fixtures/vools_vectors.json）的**输入**逐条求值，
// 写出一份分节产物到 fist-mbt/reports/moonbit_vectors_full.json，再交给
// Python vools 反向复核：
//
//   python scripts/verify_interop.py fist-mbt/reports/moonbit_vectors_full.json --strict
//
// 产物形状严格遵循 fixture 的 `moonbit_output_schema` 字段：
//   cases.canonical_json[]            { name, actual }
//   cases.digest.{sha256,md5,hmac_sha256,pbkdf2_hmac_sha256}[] { name, hex }
//   cases.envelope[]                  { name, checksum, to_rhop_bytes_utf8, checksum_match }
//   cases.crypto.encrypt_json[]       { name, ciphertext_json_text, decrypt_payload? }
//   cases.crypto.encrypt_secret[]     { name, secret }
//   cases.signer.file_hash[]          { name, signature }
//
// 注意：本文件只把 fixture 的**输入**喂给 MoonBit API，期望值（expected/hex/checksum/
// signature）一律不读，避免「拿期望值冒充实现」；期望值只由 verify_interop.py
// 用真实 vools 代码复算。
// ============================================================================

///|
/// 仓库根：从 cwd 向上找 `moon.mod`，找不到则退回 cwd（与 rhop_js 测试同款）。
extern "js" fn ffi_module_root() -> String =
  #| () => { const fs = process.getBuiltinModule("node:fs"); const path = process.getBuiltinModule("node:path"); let d = process.cwd(); for (;;) { try { if (fs.existsSync(path.join(d, "moon.mod"))) { return d; } } catch (_e) {} const p = path.dirname(d); if (p === d) { return process.cwd(); } d = p; } }

///|
extern "js" fn ffi_read_text(path : String) -> String =
  #| (path) => { try { return process.getBuiltinModule("node:fs").readFileSync(path, "utf8"); } catch (_e) { return ""; } }

///|
/// 写 utf8 文本（自动建父目录）。成功返回 true，失败把原因写进全局槽并返回 false。
extern "js" fn ffi_write_text(path : String, text : String) -> Bool =
  #| (path, text) => { const G = globalThis; try { const fs = process.getBuiltinModule("node:fs"); const p = process.getBuiltinModule("node:path"); fs.mkdirSync(p.dirname(String(path)), { recursive: true }); fs.writeFileSync(String(path), String(text), "utf8"); G.__rxmbt_vectors_err = ""; return true; } catch (e) { G.__rxmbt_vectors_err = String((e && e.message) || e); return false; } }

///|
extern "js" fn ffi_write_error() -> String =
  #| () => { const G = globalThis; return (G.__rxmbt_vectors_err === undefined) ? "" : G.__rxmbt_vectors_err; }

///|
extern "js" fn ffi_exists(path : String) -> Bool =
  #| (path) => { try { return process.getBuiltinModule("node:fs").existsSync(String(path)); } catch (_e) { return false; } }

///|
fn fixture_path() -> String {
  ffi_module_root() + "/test-suit/rhop_js/fixtures/vools_vectors.json"
}

///|
fn output_path() -> String {
  ffi_module_root() + "/fist-mbt/reports/moonbit_vectors_full.json"
}

///|
/// 读 fixture 并解析成 Json；失败直接 fail（这是生产者的前置条件，不是软跳过）。
fn load_fixture() -> Json {
  let path = fixture_path()
  if !ffi_exists(path) {
    abort("fixture 不存在: \{path}")
  }
  let text = ffi_read_text(path)
  if text == "" {
    abort("fixture 读取失败: \{path}")
  }
  @json.parse(text) catch {
    _ => abort("fixture 不是合法 JSON: \{path}")
  }
}

///|
/// 构造一条 `{ name, value }` 产物条目（键名动态，故用 Map 手工装配）。
fn item(name : String, key : String, value : Json) -> Json {
  let m : Map[String, Json] = Map([])
  m["name"] = Json::string(name)
  m[key] = value
  Json::object(m)
}

///|
/// 从 Json 对象取字符串字段；缺失/类型不符即 abort（fixture 形状固定）。
fn need_str(obj : Json, key : String) -> String {
  match obj {
    Object(m) =>
      match m.get(key) {
        Some(String(s)) => s
        _ => abort("fixture 字段 \{key} 缺失或不是字符串")
      }
    _ => abort("fixture 值不是对象（取字段 \{key}）")
  }
}

///|
/// 从 Json 对象取整数字段。
fn need_int(obj : Json, key : String) -> Int32 {
  match obj {
    Object(m) =>
      match m.get(key) {
        Some(Number(n, ..)) => n.to_int()
        _ => abort("fixture 字段 \{key} 缺失或不是数字")
      }
    _ => abort("fixture 值不是对象（取字段 \{key}）")
  }
}

///|
/// canonical_json 分节：直接拿 fixture 的 `input`（已解析的 JSON 值）喂给实现。
fn build_canonical(fx : Json) -> (Array[Json], Int32) {
  let cases = match fx {
    { "canonical_json": Array(cs), .. } => cs
    _ => abort("fixture 缺 canonical_json 分节")
  }
  let out : Array[Json] = []
  for c in cases {
    let name = need_str(c, "name")
    let input = match c {
      { "input": v, .. } => v
      _ => abort("canonical_json 用例 \{name} 缺 input")
    }
    out.push(item(name, "actual", Json::string(@rp.canonical_json(input))))
  }
  (out, cases.length())
}

///|
/// digest 分节：sha256/md5 用 input_utf8；hmac 用 key_utf8+message_utf8；
/// pbkdf2 用 password/salt/iterations/dk_len。
fn build_digest(fx : Json) -> (Json, Int32) {
  let digest = match fx {
    { "digest": d, .. } => d
    _ => abort("fixture 缺 digest 分节")
  }
  let sha_cases = match digest {
    { "sha256": Array(cs), .. } => cs
    _ => abort("fixture 缺 digest.sha256")
  }
  let sha_out : Array[Json] = []
  for c in sha_cases {
    let name = need_str(c, "name")
    let text = need_str(c, "input_utf8")
    sha_out.push(item(name, "hex", Json::string(@rp.sha256_hex_of_utf8(text))))
  }
  let md5_cases = match digest {
    { "md5": Array(cs), .. } => cs
    _ => abort("fixture 缺 digest.md5")
  }
  let md5_out : Array[Json] = []
  for c in md5_cases {
    let name = need_str(c, "name")
    let text = need_str(c, "input_utf8")
    md5_out.push(item(name, "hex", Json::string(@rp.md5_hex_of_utf8(text))))
  }
  let hmac_cases = match digest {
    { "hmac_sha256": Array(cs), .. } => cs
    _ => abort("fixture 缺 digest.hmac_sha256")
  }
  let hmac_out : Array[Json] = []
  for c in hmac_cases {
    let name = need_str(c, "name")
    let key = need_str(c, "key_utf8")
    let msg = need_str(c, "message_utf8")
    hmac_out.push(
      item(
        name,
        "hex",
        Json::string(
          @rp.hmac_sha256_hex(@rp.bytes_of_utf8(key), @rp.bytes_of_utf8(msg)),
        ),
      ),
    )
  }
  let pbkdf2_cases = match digest {
    { "pbkdf2_hmac_sha256": Array(cs), .. } => cs
    _ => abort("fixture 缺 digest.pbkdf2_hmac_sha256")
  }
  let pbkdf2_out : Array[Json] = []
  for c in pbkdf2_cases {
    let name = need_str(c, "name")
    let password = need_str(c, "password_utf8")
    let salt = need_str(c, "salt_utf8")
    let iterations = need_int(c, "iterations")
    let dk_len = need_int(c, "dk_len")
    pbkdf2_out.push(
      item(
        name,
        "hex",
        Json::string(
          @rp.pbkdf2_hmac_sha256_hex(
            @rp.bytes_of_utf8(password),
            @rp.bytes_of_utf8(salt),
            iterations,
            dk_len,
          ),
        ),
      ),
    )
  }
  let total = sha_cases.length() +
    md5_cases.length() +
    hmac_cases.length() +
    pbkdf2_cases.length()
  (
    Json::object({
      "sha256": Json::array(sha_out),
      "md5": Json::array(md5_out),
      "hmac_sha256": Json::array(hmac_out),
      "pbkdf2_hmac_sha256": Json::array(pbkdf2_out),
    }),
    total,
  )
}

///|
/// envelope 分节：只用带 `fields` 的正常用例（篡改用例没有 fields，且严格模式不要求
/// MoonBit 产出篡改项）。输出 checksum、to_rhop_bytes 的 utf8 文本、checksum_match。
fn build_envelope(fx : Json) -> (Array[Json], Int32) {
  let cases = match fx {
    { "envelope": Array(cs), .. } => cs
    _ => abort("fixture 缺 envelope 分节")
  }
  let out : Array[Json] = []
  let mut expected_count = 0
  for c in cases {
    match c {
      { "fields": fields, .. } => {
        expected_count = expected_count + 1
        let name = need_str(c, "name")
        let env = match @rp.Envelope::from_dict(fields) {
          Ok(e) => e
          Err(msg) => abort("from_dict 失败（\{name}）: \{msg}")
        }
        let raw = env.to_rhop_bytes()
        out.push(
          Json::object({
            "name": Json::string(name),
            "checksum": Json::string(env.checksum),
            "to_rhop_bytes_utf8": Json::string(@rp.utf8_text(raw)),
            "checksum_match": Json::boolean(
              @rp.IntegrityChecker::checksum_match(env),
            ),
          }),
        )
      }
      { "expect_error": True, .. } => {
        // 负向用例（tampered_checksum）：**MoonBit 必须拒绝**被篡改的信封。
        // 这里做本地断言（失败即 abort），并把「拒绝了 + 实际错误文本」写进产物，
        // 供 verify_interop.py 的 --require-negative 门禁消费。
        expected_count = expected_count + 1
        let name = need_str(c, "name")
        let hex = need_str(c, "to_rhop_bytes_utf8_hex")
        let want = need_str(c, "expect_error_contains")
        let raw = match @rp.bytes_from_hex(hex) {
          Ok(b) => b
          Err(e) => abort("tampered hex 解码失败（\{name}）: \{e}")
        }
        let (rejected, actual) = match @rp.Envelope::from_rhop_bytes(raw) {
          Ok(_) => (false, "accepted")
          Err(msg) => (true, msg)
        }
        if !rejected {
          abort(
            "MoonBit 未拒绝被篡改信封（\{name}）⇒ 完整性校验失效",
          )
        }
        if !actual.contains(want) {
          abort(
            "拒绝理由不符（\{name}）：期望含 \{want}，实际 \{actual}",
          )
        }
        out.push(
          Json::object({
            "name": Json::string(name),
            "to_rhop_bytes_utf8_hex": Json::string(hex),
            "rejected": Json::boolean(rejected),
            "actual_error": Json::string(actual),
            "expect_error_contains": Json::string(want),
          }),
        )
      }
      _ => ()
    }
  }
  (out, expected_count)
}

///|
/// crypto 分节：encrypt_json 输出（vools 必须能解开）+ encrypt_secret 输出；
/// 另附 MoonBit 解 fixture 中 vools 密文的 payload（若解得开）。
fn build_crypto(fx : Json) -> (Json, Int32, Int32) {
  let crypto = match fx {
    { "crypto": c, .. } => c
    _ => abort("fixture 缺 crypto 分节")
  }
  let key = match crypto {
    { "key": String(k), .. } => k
    _ => abort("fixture crypto 缺 key")
  }
  let c = @rp.RhopCrypto::from_key(key)
  let json_cases = match crypto {
    { "encrypt_json_cases": Array(cs), .. } => cs
    _ => abort("fixture 缺 crypto.encrypt_json_cases")
  }
  let enc_out : Array[Json] = []
  for case in json_cases {
    let name = need_str(case, "name")
    let payload = match case {
      { "payload": p, .. } => p
      _ => abort("encrypt_json 用例 \{name} 缺 payload")
    }
    let fixture_ct = need_str(case, "ciphertext_json_text")
    let ct = c.encrypt_json(payload)
    // 反向能力：MoonBit 解 vools 密文（Fernet 有随机 IV/ts，密文本身不可比）
    let verified = c.decrypt_verify(fixture_ct)
    let item_json = match verified.payload {
      Some(back) if verified.ok =>
        Json::object({
          "name": Json::string(name),
          "ciphertext_json_text": Json::string(ct),
          "decrypt_payload": back,
        })
      _ =>
        Json::object({
          "name": Json::string(name),
          "ciphertext_json_text": Json::string(ct),
        })
    }
    enc_out.push(item_json)
  }
  let secret_cases = match crypto {
    { "encrypt_secret_cases": Array(cs), .. } => cs
    _ => abort("fixture 缺 crypto.encrypt_secret_cases")
  }
  let secret_out : Array[Json] = []
  for case in secret_cases {
    let name = need_str(case, "name")
    let plaintext = need_str(case, "plaintext_utf8")
    secret_out.push(
      item(name, "secret", Json::string(c.encrypt_secret(plaintext))),
    )
  }
  (
    Json::object({
      "encrypt_json": Json::array(enc_out),
      "encrypt_secret": Json::array(secret_out),
    }),
    json_cases.length(),
    secret_cases.length(),
  )
}

///|
/// signer 分节：FileHashSigner 对 fixture 的 task_id/result 签名。
fn build_signer(fx : Json) -> (Json, Int32) {
  let cases = match fx {
    { "signer": { "file_hash": { "cases": Array(cs), .. }, .. }, .. } => cs
    _ => abort("fixture 缺 signer.file_hash.cases")
  }
  let signer = @rp.FileHashSigner::new()
  let out : Array[Json] = []
  for c in cases {
    let name = need_str(c, "name")
    let task_id = need_str(c, "task_id")
    let result = match c {
      { "result": r, .. } => r
      _ => abort("signer 用例 \{name} 缺 result")
    }
    out.push(
      item(name, "signature", Json::string(signer.signature(task_id, result))),
    )
  }
  (Json::object({ "file_hash": Json::array(out) }), cases.length())
}

///|
/// 读回产物并返回 cases 对象；非法 JSON 直接 fail。
fn read_back_cases(path : String) -> Json {
  let text = ffi_read_text(path)
  if text == "" {
    abort("产物读取失败（空文件或不存在）: \{path}")
  }
  let doc = @json.parse(text) catch {
    _ => abort("产物不是合法 JSON: \{path}")
  }
  match doc {
    { "cases": cases, .. } => cases
    _ => abort("产物缺 cases 分节")
  }
}

///|
test "vectors · 用真实 rhop API 生成五分节产物并写盘" {
  let fx = load_fixture()
  let (canonical_json, canonical_n) = build_canonical(fx)
  let (digest, digest_n) = build_digest(fx)
  let (envelope, envelope_n) = build_envelope(fx)
  let (crypto, crypto_json_n, crypto_secret_n) = build_crypto(fx)
  let (signer, signer_n) = build_signer(fx)
  // fixture 条数自证：四类合计 = 各分节条数之和，且非空
  assert_eq(canonical_n, 7)
  assert_eq(digest_n, 5 + 5 + 2 + 1)
  assert_eq(envelope_n, 3)
  assert_eq(crypto_json_n, 3)
  assert_eq(crypto_secret_n, 2)
  assert_eq(signer_n, 3)
  let doc = Json::object({
    "schema": Json::string("rhop-moonbit-output"),
    "schema_version": Json::number(1.0),
    "produced_by": Json::string(
      "moon test --target js (test-suit/rhop_vectors/producer_test.mbt)",
    ),
    "cases": Json::object({
      "canonical_json": Json::array(canonical_json),
      "digest": digest,
      "envelope": Json::array(envelope),
      "crypto": crypto,
      "signer": signer,
    }),
  })
  let path = output_path()
  let ok = ffi_write_text(path, Json::stringify(doc, indent=2))
  if !ok {
    fail("写产物失败（\{path}）: \{ffi_write_error()}")
  }
  assert_true(ffi_exists(path))
  // 写回自证：能解析 + 五节齐全 + 条数与 fixture 一致
  let cases = read_back_cases(path)
  let back_canonical = match cases {
    { "canonical_json": Array(xs), .. } => xs
    _ => fail("产物缺 cases.canonical_json")
  }
  let back_envelope = match cases {
    { "envelope": Array(xs), .. } => xs
    _ => fail("产物缺 cases.envelope")
  }
  assert_eq(back_canonical.length(), canonical_n)
  assert_eq(back_envelope.length(), envelope_n)
  assert_true(back_canonical.length() > 0)
  assert_true(back_envelope.length() > 0)
  println(
    "[vectors] 写出 \{path}：canonical=\{canonical_n} digest=\{digest_n} envelope=\{envelope_n} crypto=\{crypto_json_n}+\{crypto_secret_n} signer=\{signer_n}",
  )
}

///|
test "vectors · 产物文件五节非空且条数 == fixture 对应条数" {
  let path = output_path()
  assert_true(ffi_exists(path))
  let cases = read_back_cases(path)
  let (
    expected_canonical,
    expected_digest,
    expected_envelope,
    expected_crypto_json,
    expected_crypto_secret,
    expected_signer,
  ) = {
    let fx = load_fixture()
    let canonical = match fx {
      { "canonical_json": Array(xs), .. } => xs.length()
      _ => fail("fixture 缺 canonical_json")
    }
    let digest = match fx {
      { "digest": d, .. } =>
        match d {
          {
            "sha256": Array(a),
            "md5": Array(b),
            "hmac_sha256": Array(c),
            "pbkdf2_hmac_sha256": Array(e),
            ..
          } => a.length() + b.length() + c.length() + e.length()
          _ => fail("fixture digest 分节不全")
        }
      _ => fail("fixture 缺 digest")
    }
    let envelope = match fx {
      { "envelope": Array(xs), .. } => xs
      _ => fail("fixture 缺 envelope")
    }
    let mut env_n = 0
    for c in envelope {
      match c {
        // 正向（有 fields）+ 负向（有篡改字节）都计入 envelope 分节条数
        { "to_rhop_bytes_utf8_hex": _, .. } => env_n = env_n + 1
        _ => ()
      }
    }
    let crypto = match fx {
      {
        "crypto": {
          "encrypt_json_cases": Array(a),
          "encrypt_secret_cases": Array(b),
          ..
        },
        ..
      } => (a.length(), b.length())
      _ => fail("fixture crypto 分节不全")
    }
    let signer = match fx {
      { "signer": { "file_hash": { "cases": Array(xs), .. }, .. }, .. } =>
        xs.length()
      _ => fail("fixture 缺 signer")
    }
    (canonical, digest, env_n, crypto.0, crypto.1, signer)
  }
  let (
    back_canonical,
    back_digest_n,
    back_envelope_n,
    back_crypto_json_n,
    back_crypto_secret_n,
    back_signer_n,
  ) = {
    let canonical = match cases {
      { "canonical_json": Array(xs), .. } => xs.length()
      _ => fail("产物缺 canonical_json")
    }
    let digest = match cases {
      { "digest": d, .. } =>
        match d {
          {
            "sha256": Array(a),
            "md5": Array(b),
            "hmac_sha256": Array(c),
            "pbkdf2_hmac_sha256": Array(e),
            ..
          } => a.length() + b.length() + c.length() + e.length()
          _ => fail("产物 digest 分节不全")
        }
      _ => fail("产物缺 digest")
    }
    let envelope = match cases {
      { "envelope": Array(xs), .. } => xs.length()
      _ => fail("产物缺 envelope")
    }
    let crypto = match cases {
      {
        "crypto": { "encrypt_json": Array(a), "encrypt_secret": Array(b), .. },
        ..
      } => (a.length(), b.length())
      _ => fail("产物 crypto 分节不全")
    }
    let signer = match cases {
      { "signer": { "file_hash": Array(xs), .. }, .. } => xs.length()
      _ => fail("产物缺 signer.file_hash")
    }
    (canonical, digest, envelope, crypto.0, crypto.1, signer)
  }
  assert_eq(back_canonical, expected_canonical)
  assert_eq(back_digest_n, expected_digest)
  assert_eq(back_envelope_n, expected_envelope)
  assert_eq(back_crypto_json_n, expected_crypto_json)
  assert_eq(back_crypto_secret_n, expected_crypto_secret)
  assert_eq(back_signer_n, expected_signer)
  assert_true(back_canonical > 0)
  assert_true(back_digest_n > 0)
  assert_true(back_envelope_n > 0)
  assert_true(back_crypto_json_n > 0)
  assert_true(back_crypto_secret_n > 0)
  assert_true(back_signer_n > 0)
  println(
    "[vectors] 读回校验通过：canonical=\{back_canonical}/\{expected_canonical} digest=\{back_digest_n}/\{expected_digest} envelope=\{back_envelope_n}/\{expected_envelope} crypto=\{back_crypto_json_n}+\{back_crypto_secret_n} signer=\{back_signer_n}",
  )
}
