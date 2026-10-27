// ============================================================================
// rhop · 本地固定密钥（key）
//   对照 vools.rhop.crypto：ENV_RHOP_KEY / SECRET_PREFIX / is_secret / load_key
//   加载优先级：source > path > env（与 vools 一致）；三处都没有时返回可诊断 Err。
//   目标说明：
//     - 常量 / is_secret / VerifyResult：三目标（wasm / js / native）全可用；
//     - source 分支：三目标全可用；
//     - path 分支：仅 js 目标可用（node:fs 读文件），非 js 返回可诊断 Err；
//     - env 分支：三目标全可用（@env.get_env_var）。
// ============================================================================

///|
/// 默认环境变量名：存放本地固定密钥的环境变量（与 vools 同名字面量）。
pub let env_rhop_key : String = "RHOP_KEY"

///|
/// 配置密文前缀：以此开头的字符串视为 rhop 密文（与 vools 逐字一致）。
pub let secret_prefix : String = "RHOP-ENC:"

///|
/// 契约字面量别名（vools 侧常量名 ENV_RHOP_KEY），与 `env_rhop_key` 同值。
/// MoonBit 的 `let` 要求小写名，故此处用 `const` 保留原字面量名便于跨实现对照。
pub const ENV_RHOP_KEY : String = "RHOP_KEY"

///|
/// 契约字面量别名（vools 侧常量名 SECRET_PREFIX），与 `secret_prefix` 同值。
pub const SECRET_PREFIX : String = "RHOP-ENC:"

///|
/// 判断字符串是否是 rhop 密文（`RHOP-ENC:` 前缀）。
pub fn is_secret(value : String) -> Bool {
  value.has_prefix(secret_prefix)
}

///|
/// 解密验证结果（对照 vools.rhop.crypto.VerifyResult）。
///
/// - `ok`：是否通过；
/// - `payload`：通过时为解密得到的 JSON（失败为 None）；
/// - `reason`：失败原因字面量，严格用 `OK` / `MALFORMED` / `BAD_TOKEN` / `NOT_JSON`。
pub struct VerifyResult {
  ok : Bool
  /// 通过时解密得到的 JSON 载荷；失败为 None
  payload : Json?
  /// 结果原因（OK / MALFORMED / BAD_TOKEN / NOT_JSON）
  reason : String
}

///|
/// 构造一个解密验证结果（全字段显式给出）。
pub fn VerifyResult::new(
  ok : Bool,
  payload : Json?,
  reason : String,
) -> VerifyResult {
  { ok, payload, reason, }
}

///|
/// 通过：`ok=true`、`reason="OK"`、携带解密出的 JSON。
pub fn VerifyResult::pass(payload : Json) -> VerifyResult {
  { ok: true, payload: Some(payload), reason: "OK", }
}

///|
/// 失败：`ok=false`、`payload=None`、`reason` 为四态之一。
pub fn VerifyResult::fail(reason : String) -> VerifyResult {
  { ok: false, payload: None, reason, }
}

///|
/// 便于日志与测试断言的文本形态：`VerifyResult(ok=.., reason=.., payload=..)`。
pub fn VerifyResult::to_string(self : VerifyResult) -> String {
  let p = match self.payload {
    Some(j) => Json::stringify(j)
    None => "none"
  }
  "VerifyResult(ok=\{self.ok}, reason=\{self.reason}, payload=\{p})"
}

///|
/// 判断字符串是否为空或纯空白（空白串视为「未提供」）。
fn is_blank(s : String) -> Bool {
  s.trim().length() == 0
}

///|
/// 把「可选字符串」里空/纯空白的值归一成 None，便于按优先级往下探。
fn non_blank(v : String?) -> String? {
  match v {
    Some(s) => if is_blank(s) { None } else { Some(s) }
    None => None
  }
}

///|
/// 加载本地固定密钥（对照 vools.rhop.crypto.load_key）。
///
/// 优先级：`source`（调用方显式传入的密钥文本）> `path`（密钥文件，读后 strip）
/// > `env_name`（环境变量）。
///
/// 与 vools 的差异（均为可诊断性改进，已在契约 §3 范围内）：
/// - vools 把 `source=""` 当成合法密钥返回；这里把空/纯空白视为「未提供」继续向下，
///   因为空密钥会让 PBKDF2 派生出可预测的弱密钥；
/// - vools 的密钥文件读到空串也照样返回；这里返回 Err（空密钥文件几乎总是配置事故）。
///
/// 三处都缺失时返回 vools 同文的中文 Err。
pub fn load_key(
  source : String?,
  path : String?,
  env_name : String,
) -> Result[String, String] {
  match non_blank(source) {
    Some(s) => return Ok(s)
    None => ()
  }
  match non_blank(path) {
    Some(p) =>
      match load_key_from_path(p) {
        Ok(k) => return Ok(k)
        Err(e) => return Err(e)
      }
    None => ()
  }
  match load_key_from_env(env_name) {
    Ok(k) => return Ok(k)
    Err(_) => ()
  }
  Err(
    "rhop: 未找到本地固定密钥。请通过 source / path / 环境变量 \{env_name} 提供。",
  )
}

///|
/// 从密钥文件读取密钥（读后 strip 空白与换行）。
///
/// 可用性：**仅 js 目标**可读文件；wasm / native 返回可诊断 Err（无文件系统 API）。
pub fn load_key_from_path(path : String) -> Result[String, String] {
  match read_text_file(path) {
    Err(e) => Err("rhop: 读取密钥文件失败: \{path}: \{e}")
    Ok(text) => {
      let k = text.trim()
      if k.length() == 0 {
        Err("rhop: 密钥文件内容为空: \{path}")
      } else {
        Ok(k.to_owned())
      }
    }
  }
}

///|
/// 从环境变量读取密钥（空/未设置均返回 Err）。
///
/// 可用性：三目标全可用（`@env.get_env_var`）。
pub fn load_key_from_env(env_name : String) -> Result[String, String] {
  match @env.get_env_var(env_name) {
    Some(v) =>
      if is_blank(v) {
        Err("rhop: 环境变量 \{env_name} 为空")
      } else {
        Ok(v)
      }
    None => Err("rhop: 环境变量 \{env_name} 未设置")
  }
}

// ---------------------------------------------------------------------------
// 文件读取 FFI（js 目标用 node:fs；非 js 目标返回可诊断 Err）
// 约定：globalThis.__rxmbt_key_err 记录最近一次读失败原因，成功时清空。
// ---------------------------------------------------------------------------

///|
/// 读取 utf8 文本文件（js 目标，node:fs）。失败返回 "" 并把原因写入错误槽。
#cfg(target="js")
extern "js" fn ffi_key_read_file(path : String) -> String =
  #| (path) => { const G = globalThis; try { const fs = process.getBuiltinModule("node:fs"); const t = fs.readFileSync(path, "utf8"); G.__rxmbt_key_err = ""; return t; } catch (e) { G.__rxmbt_key_err = String((e && e.message) || e); return ""; } }

///|
/// 取最近一次读文件失败原因（空串表示成功）。
#cfg(target="js")
extern "js" fn ffi_key_last_error() -> String =
  #| () => { const G = globalThis; return (G.__rxmbt_key_err === undefined) ? "" : G.__rxmbt_key_err; }

///|
/// 读文本文件：js 走 node:fs；失败/空内容都可由调用方分辨（错误槽非空=失败）。
#cfg(target="js")
fn read_text_file(path : String) -> Result[String, String] {
  let text = ffi_key_read_file(path)
  let err = ffi_key_last_error()
  if err != "" {
    Err(err)
  } else {
    Ok(text)
  }
}

///|
/// 非 js 目标：无文件系统 API，返回可诊断 Err（保证 rhop 包在 wasm/native 可编译）。
#cfg(not(target="js"))
fn read_text_file(path : String) -> Result[String, String] {
  let _ = path
  Err(
    "rhop: 读文件仅 js 目标可用（wasm/native 无文件系统 API），请改用 source 或环境变量",
  )
}
