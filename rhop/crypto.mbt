// ============================================================================
// rhop · 密码学（Fernet 加密 / 解密验证）—— 与 vools VText way="fernet" 互操作
//
// 口径（逐字对齐 vools.data.vtext._encrypt_with_crypto + rhop.crypto）：
//   k      = utf8(key)
//   salt   = sha256(k)[0..16]
//   key32  = PBKDF2-HMAC-SHA256(password=k, salt=salt, iterations=200000, dklen=32)
//   fk     = base64url(key32)                      # crypto 层，本实现无需物化
//   signing_key = key32[0..16]；encryption_key = key32[16..32]
//   fernet_token_raw = 0x80 | ts_be8(秒) | iv16 | AES128-CBC+PKCS7(ct) | HMAC-SHA256(签名段)
//   fernet_token_text = base64url(fernet_token_raw)          # 即 VText 的 "F:" 之后那段
//   ct（信封字段）    = base64url(utf8(fernet_token_text))   # 再套一层 base64url —— 双重编码
//   信封              = {"v": 1, "alg": "fernet", "ct": <ct>}
//
// 目标说明：
//   - 结构 / 信封校验 / reason 分类：三目标（wasm / js / native）全可用；
//   - Fernet 原语（加解密）：仅 js 目标可用（node:crypto）；非 js 目标返回同签名的
//     可诊断 Err，保证 rhop 包在 wasm/native 仍可编译。
// ============================================================================

///|
/// rhop 加密 / 解密验证一体对象（本地固定密钥）。
///
/// 对照 `vools.rhop.crypto.RhopCrypto`：同一把 key 既用于 `encrypt_json` /
/// `decrypt_verify`（包传输），也用于 `encrypt_secret` / `decrypt_secret`（配置敏感项）。
pub struct RhopCrypto {
  /// 密钥原文（utf8 后作为 PBKDF2 的 password）
  key : String
}

///|
/// 构造（等价于 `from_key`，保留 `Type::new` 惯例）。
pub fn RhopCrypto::new(key : String) -> RhopCrypto {
  { key, }
}

///|
/// 用调用方显式传入的密钥文本构造。
pub fn RhopCrypto::from_key(key : String) -> RhopCrypto {
  { key, }
}

///|
/// 从密钥文件构造（读后 strip 空白）。可用性：仅 js 目标（非 js 返回可诊断 Err）。
pub fn RhopCrypto::from_path(path : String) -> Result[RhopCrypto, String] {
  match load_key_from_path(path) {
    Ok(k) => Ok({ key: k, })
    Err(e) => Err(e)
  }
}

///|
/// 从环境变量构造（默认 `RHOP_KEY`）。可用性：三目标全可用。
pub fn RhopCrypto::from_env(env_name : String) -> Result[RhopCrypto, String] {
  match load_key_from_env(env_name) {
    Ok(k) => Ok({ key: k, })
    Err(e) => Err(e)
  }
}

///|
/// 取密钥原文（只读；日志/汇报里不应打印）。
pub fn RhopCrypto::key_material(self : RhopCrypto) -> String {
  self.key
}

///|
/// 对 JSON 载荷加密，返回信封文本（对照 vools `encrypt_json`）。
///
/// 输出形态与 Python `json.dumps({"v":1,"alg":"fernet","ct":...}, ensure_ascii=False)`
/// 逐字同形（含 `", "` / `": "` 分隔），故跨实现可直接字符串比对结构部分。
/// 加密失败（非 js 目标 / node crypto 异常）返回 `""`；需要诊断原因时用
/// `encrypt_json_result`。
pub fn RhopCrypto::encrypt_json(self : RhopCrypto, payload : Json) -> String {
  match self.encrypt_json_result(payload) {
    Ok(text) => text
    Err(_) => ""
  }
}

///|
/// `encrypt_json` 的可诊断版本：失败返回中文 Err 而非空串。
pub fn RhopCrypto::encrypt_json_result(
  self : RhopCrypto,
  payload : Json,
) -> Result[String, String] {
  self.encrypt_body(Json::stringify(payload))
}

///|
/// 对 JSON **文本**加密（对照 vools `encrypt_json` 接受 str 的分支）：
/// 文本已是合法 JSON 则原样作为明文，否则按普通字符串载荷包成 `{"__text__": ...}`。
///
/// 失败返回 `""`（同 `encrypt_json` 的失败语义）。
pub fn RhopCrypto::encrypt_json_text(
  self : RhopCrypto,
  text : String,
) -> String {
  let body = if @json.valid(text) {
    text
  } else {
    Json::stringify(Json::object({ "__text__": Json::string(text) }))
  }
  match self.encrypt_body(body) {
    Ok(t) => t
    Err(_) => ""
  }
}

///|
/// 内部：明文 → 信封文本。
fn RhopCrypto::encrypt_body(
  self : RhopCrypto,
  plain : String,
) -> Result[String, String] {
  match fernet_encrypt_b64(self.key, plain) {
    Err(e) => Err(e)
    Ok(ct) =>
      // 与 Python json.dumps 默认分隔符同形（键序 v / alg / ct 为 dict 插入序）
      Ok("{\"v\": 1, \"alg\": \"fernet\", \"ct\": \"" + ct + "\"}")
  }
}

///|
/// 把一段明文（密码 / token / 密钥）加密成 `RHOP-ENC:<ct>` 密文（对照 vools `encrypt_secret`）。
///
/// 空明文返回 `""`（与 vools 一致：空值保持空值，配置里不出现无意义的密文）。
/// 加密失败返回 `""`。
pub fn RhopCrypto::encrypt_secret(
  self : RhopCrypto,
  plaintext : String,
) -> String {
  if plaintext == "" {
    return ""
  }
  match fernet_encrypt_b64(self.key, plaintext) {
    Ok(ct) => secret_prefix + ct
    Err(_) => ""
  }
}

///|
/// 解密 `RHOP-ENC:` 密文，返回明文（对照 vools `decrypt_secret`）。
///
/// 失败原因逐条可诊断（Err 文本已区分）：
/// 1. 不是 `RHOP-ENC:` 前缀（明文请直接填明文区）；
/// 2. 前缀后密文为空；
/// 3. 解密失败：密钥不符或密文被篡改。
///
/// 与 vools 的差异：vools 对「前缀后为空」返回 `""`，这里返回 Err
/// （空密文几乎总是配置事故，静默返回空串会让下游把它当成「明文就是空」）。
pub fn RhopCrypto::decrypt_secret(
  self : RhopCrypto,
  value : String,
) -> Result[String, String] {
  let text = value.trim().to_owned()
  if text == "" {
    return Ok("")
  }
  if !text.has_prefix(secret_prefix) {
    return Err(
      "不是 rhop 密文（应以 \"\{secret_prefix}\" 开头）；明文请直接填明文区，密文请用 rhop secret 工具生成",
    )
  }
  let token = text.replace(old=secret_prefix, new="").trim()
  if token.length() == 0 {
    return Err(
      "rhop: 密文为空（\"\{secret_prefix}\" 之后没有内容）",
    )
  }
  match fernet_decrypt_b64(self.key, token.to_owned()) {
    Err(e) =>
      Err(
        "密文解密失败：密钥不符或密文被篡改（请确认 RHOP_KEY / 密钥文件与生成密文时一致）: \{e}",
      )
    Ok(plain) =>
      // vools 的兜底检测：VText 解密失败会回退密文原文，这里显式当失败处理
      if plain == "" ||
        plain.has_prefix("F:") ||
        plain.has_prefix("E:") ||
        plain.has_prefix("A:") {
        Err(
          "密文解密失败：密钥不符或密文被篡改（请确认 RHOP_KEY / 密钥文件与生成密文时一致）",
        )
      } else {
        Ok(plain)
      }
  }
}

///|
/// 用本地固定密钥解密并验证（对照 vools `decrypt_verify`）。
///
/// `reason` 严格四态（与 vools 逐字一致）：
/// - `OK`：解密成功且明文是合法 JSON；
/// - `MALFORMED`：信封不是 JSON / 不是对象 / `v`≠1 / `alg`≠"fernet" / `ct` 非非空字符串；
/// - `BAD_TOKEN`：Fernet 解密失败（base64 坏 / 版本位坏 / HMAC 不符 / 密文被篡改），
///   或解出的明文为空串；
/// - `NOT_JSON`：解密成功但明文不是合法 JSON。
///
/// 与 vools 一致：只要解密结果是合法 JSON 就算 OK（不限于对象；标量/数组也接受）。
pub fn RhopCrypto::decrypt_verify(
  self : RhopCrypto,
  token_text : String,
) -> VerifyResult {
  let j = @json.parse(token_text) catch {
    _ => return VerifyResult::fail("MALFORMED")
  }
  let (v, alg, ct) = match j {
    { "v": Number(v, ..), "alg": String(alg), "ct": String(ct), .. } =>
      (v, alg, ct)
    _ => return VerifyResult::fail("MALFORMED")
  }
  if v.to_int() != 1 || alg != "fernet" || ct == "" {
    return VerifyResult::fail("MALFORMED")
  }
  let plain = match fernet_decrypt_b64(self.key, ct) {
    Err(_) => return VerifyResult::fail("BAD_TOKEN")
    Ok(p) => p
  }
  if plain == "" {
    return VerifyResult::fail("BAD_TOKEN")
  }
  let payload = @json.parse(plain) catch {
    _ => return VerifyResult::fail("NOT_JSON")
  }
  VerifyResult::pass(payload)
}

// ---------------------------------------------------------------------------
// Fernet 原语（js：node:crypto；非 js：可诊断 Err）
// 约定：globalThis.__rxmbt_crypto_err 记录最近一次失败原因，成功时清空。
// 输入/输出均为「信封 ct」形态 = base64url(utf8(base64url(token_raw)))，与 vools 一致。
// ---------------------------------------------------------------------------

///|
/// Fernet 加密 → 返回信封 ct（base64url(fernet token 文本字节)）；失败 Err。
#cfg(target="js")
fn fernet_encrypt_b64(key : String, plain : String) -> Result[String, String] {
  let out = ffi_fernet_encrypt(key, plain)
  let err = ffi_crypto_last_error()
  if err != "" {
    Err(err)
  } else if out == "" {
    Err("rhop: Fernet 加密返回空 token")
  } else {
    Ok(out)
  }
}

///|
/// Fernet 解密：入参是信封 ct，成功返回明文；失败 Err（含坏 base64 / HMAC 不符）。
/// 注意：与 vools 一致，**不校验 TTL**（Fernet 时间戳仅作元数据）。
#cfg(target="js")
fn fernet_decrypt_b64(key : String, ct : String) -> Result[String, String] {
  let out = ffi_fernet_decrypt(key, ct)
  let err = ffi_crypto_last_error()
  if err != "" {
    Err(err)
  } else {
    Ok(out)
  }
}

///|
/// 非 js 目标：无 node:crypto，返回可诊断 Err（保证包可编译，行为显式失败）。
#cfg(not(target="js"))
fn fernet_encrypt_b64(key : String, plain : String) -> Result[String, String] {
  Err(
    "rhop: Fernet 加密仅 js 目标可用（wasm/native 无 node:crypto）；本目标下 RhopCrypto 只能做结构校验",
  )
}

///|
/// 非 js 目标：无 node:crypto，解密一律返回可诊断 Err（调用方据此得到 BAD_TOKEN）。
#cfg(not(target="js"))
fn fernet_decrypt_b64(key : String, ct : String) -> Result[String, String] {
  Err(
    "rhop: Fernet 解密仅 js 目标可用（wasm/native 无 node:crypto）；本目标下解密一律判 BAD_TOKEN",
  )
}

// ---------------------------------------------------------------------------
// FFI：node:crypto 实现 Fernet（js 目标）
// ---------------------------------------------------------------------------

///|
/// 带 padding 的 base64url 编码：与 Python `base64.urlsafe_b64encode` 一致（含 `=` 补位）。
#cfg(target="js")
extern "js" fn ffi_fernet_encrypt(key : String, plain : String) -> String =
  #| (key, plain) => { const G = globalThis; try { const crypto = process.getBuiltinModule("node:crypto"); const pad4 = (s) => s + "=".repeat((4 - (s.length % 4)) % 4); const k = Buffer.from(key, "utf8"); const salt = crypto.createHash("sha256").update(k).digest().subarray(0, 16); const key32 = crypto.pbkdf2Sync(k, salt, 200000, 32, "sha256"); const signingKey = key32.subarray(0, 16); const encKey = key32.subarray(16, 32); const iv = crypto.randomBytes(16); const version = Buffer.from([0x80]); const ts = Buffer.alloc(8); ts.writeBigUInt64BE(BigInt(Math.floor(Date.now() / 1000))); const c = crypto.createCipheriv("aes-128-cbc", encKey, iv); const ct = Buffer.concat([c.update(Buffer.from(plain, "utf8")), c.final()]); const basic = Buffer.concat([version, ts, iv, ct]); const mac = crypto.createHmac("sha256", signingKey).update(basic).digest(); const raw = Buffer.concat([basic, mac]); const inner = pad4(raw.toString("base64url")); const outer = pad4(Buffer.from(inner, "utf8").toString("base64url")); G.__rxmbt_crypto_err = ""; return outer; } catch (e) { G.__rxmbt_crypto_err = String((e && e.message) || e); return ""; } }

///|
/// Fernet 解密：先解外层 base64url 得 token 文本，再解内层得原始 token，校验并解密。
#cfg(target="js")
extern "js" fn ffi_fernet_decrypt(key : String, ct : String) -> String =
  #| (key, ct) => { const G = globalThis; try { const crypto = process.getBuiltinModule("node:crypto"); const pad4 = (s) => s + "=".repeat((4 - (s.length % 4)) % 4); const dec = (s) => Buffer.from(pad4(String(s).trim()), "base64url"); const k = Buffer.from(key, "utf8"); const salt = crypto.createHash("sha256").update(k).digest().subarray(0, 16); const key32 = crypto.pbkdf2Sync(k, salt, 200000, 32, "sha256"); const signingKey = key32.subarray(0, 16); const encKey = key32.subarray(16, 32); const tokenText = dec(ct); const raw = dec(tokenText.toString("utf8")); if (raw.length < 1 + 8 + 16 + 32) { throw new Error("fernettoken too short"); } if (raw[0] !== 0x80) { throw new Error("bad fernet version"); } const body = raw.subarray(0, raw.length - 32); const mac = raw.subarray(raw.length - 32); const expect = crypto.createHmac("sha256", signingKey).update(body).digest(); if (!crypto.timingSafeEqual(mac, expect)) { throw new Error("bad fernet hmac"); } const iv = raw.subarray(9, 25); const ciphertext = raw.subarray(25, raw.length - 32); if (ciphertext.length === 0 || ciphertext.length % 16 !== 0) { throw new Error("bad fernet ciphertext length"); } const d = crypto.createDecipheriv("aes-128-cbc", encKey, iv); const plain = Buffer.concat([d.update(ciphertext), d.final()]); G.__rxmbt_crypto_err = ""; return plain.toString("utf8"); } catch (e) { G.__rxmbt_crypto_err = String((e && e.message) || e); return ""; } }

///|
/// 取最近一次 Fernet 操作失败原因（空串表示成功）。
#cfg(target="js")
extern "js" fn ffi_crypto_last_error() -> String =
  #| () => { const G = globalThis; return (G.__rxmbt_crypto_err === undefined) ? "" : G.__rxmbt_crypto_err; }
