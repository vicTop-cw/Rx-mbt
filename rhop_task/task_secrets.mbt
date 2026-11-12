// ============================================================================
// rhop_task · 配置敏感信息（明文/密文双支持 + 明文告警 + 脱敏）
//
// 对照 vools.rhop.task.secrets：
//   敏感字段两种写法，优先级统一：
//
//   A) 兄弟键（推荐）：`sftp_password_plain` / `sftp_password_cipher` → 解析出 `sftp_password`
//   B) 秘密节点：      `{"plain": "", "cipher": "RHOP-ENC:…", "path": "", "env": "RHOP_KEY"}`
//                      → 整个节点收敛成一个标量字符串
//
//   取值优先级：**非空明文 > 密文(解密) > path(读文件) > env(读环境变量) > 空串**
//
//   只要用了明文就告警（并通过 findings 留痕）；strict=true 时明文直接 Err（CI 卡口）。
//   根密钥字段 `key` 默认整棵跳过自动解密/告警（它是解其它密文的那把钥匙，
//   由 TaskConfig 的主密钥解析专门处理，否则会出现重复告警与"自己解自己"的循环）。
//
// 目标说明：
//   - 打码 / 敏感叶判定 / 发现清单 / 明文告警 / 密文解密：三目标通用；
//   - `path`（读密钥文件）仅 js 目标可用，其余目标返回可诊断 Err。
// ============================================================================

///|
/// 兄弟键：明文区后缀。
pub let plain_suffix : String = "_plain"

///|
/// 兄弟键：密文区后缀。
pub let cipher_suffix : String = "_cipher"

///|
/// 秘密节点里承载明/密文的键名。
pub fn secret_node_keys() -> Array[String] {
  ["plain", "cipher"]
}

///|
/// 生成密文的命令（告警文案统一引用这一处，改一处即全局生效）。
pub let secret_enc_command : String = "python -m vools.rhop.secret enc \"<你的明文>\""

///|
/// 默认不参与自动解密/自动告警的路径（根密钥）。
pub fn default_skip_paths() -> Array[String] {
  ["key"]
}

///|
/// 敏感叶名集合（与 vools 的 `SENSITIVE_LEAF_RE` 等价：取**最后一段**下划线分段）。
fn sensitive_words() -> Array[String] {
  [
    "password", "passwd", "pwd", "token", "secret", "apikey", "accesskey", "privatekey",
    "key",
  ]
}

///|
/// 叶键名是否属于敏感字段（大小写不敏感；匹配「最后一段下划线分段」）。
///
/// 等价于 vools 的正则 `(^|_)(password|passwd|pwd|token|secret|apikey|accesskey|privatekey|key)$`：
/// 只有完整分段命中才算敏感 —— `mypassword` 不算（不误伤普通字段）。
pub fn is_sensitive_leaf(key : String) -> Bool {
  let lower = key.to_lower()
  // 取最后一段
  let last = match lower.rev_split_once("_") {
    Some(pair) => pair.1.to_owned()
    None => lower
  }
  for w in sensitive_words() {
    if last == w {
      return true
    }
  }
  false
}

///|
/// 取字符串的前 n 个字符（按码点；越界则返回全部）。
fn take_prefix(s : String, n : Int32) -> String {
  if n >= s.length() {
    return s
  }
  match s.get_view(start=0, end=n) {
    Some(v) => v.to_owned()
    None => s
  }
}

///|
/// 取字符串去掉前 n 个字符后的剩余部分（按码点）。
fn drop_prefix(s : String, n : Int32) -> String {
  if n >= s.length() {
    return ""
  }
  match s.get_view(start=n) {
    Some(v) => v.to_owned()
    None => ""
  }
}

///|
/// 把敏感值打码（保留首尾少量字符），用于日志 / `--print` / HTML 回显。
///
/// 与 vools 一致：密文（`RHOP-ENC:` 前缀）打码成 `***CIPHER***` 或
/// 保留 `RHOP-ENC:` 前缀 + `***` + 尾 2 位；短值整体 `***`。
pub fn mask_value(value : String, keep : Int32) -> String {
  if value == "" {
    return ""
  }
  if @rp.is_secret(value) {
    if value.length() <= keep * 2 {
      return "***CIPHER***"
    }
    return take_prefix(value, keep + @rp.secret_prefix.length()) +
      "***" +
      drop_prefix(value, value.length() - keep)
  }
  if value.length() <= keep * 2 {
    return "***"
  }
  take_prefix(value, keep) + "***" + drop_prefix(value, value.length() - keep)
}

///|
/// 打码（默认保留首尾 2 位，与 vools `mask_value` 默认参数一致）。
pub fn mask_value_default(value : String) -> String {
  mask_value(value, 2)
}

///|
/// 拼出「生成密文 + 回填」的操作指引（告警与文档共用）。
pub fn command_hint(
  path : String,
  plain_key : String?,
  cipher_key : String?,
) -> String {
  let has_pair = match (plain_key, cipher_key) {
    (None, None) => false
    _ => true
  }
  // 密文区目标：优先用显式 cipher 键；否则由 *_plain 推导出 *_cipher；再否则 "cipher"
  let target = if has_pair {
    match cipher_key {
      Some(c) => c
      None =>
        match plain_key {
          Some(p) =>
            if p.has_suffix(plain_suffix) {
              take_prefix(p, p.length() - plain_suffix.length()) + cipher_suffix
            } else {
              "cipher"
            }
          None => "cipher"
        }
    }
  } else {
    path + cipher_suffix
  }
  // 明文区待清空的位置
  let clear = if has_pair {
    match plain_key {
      Some(p) => p
      None => "plain"
    }
  } else {
    path + plain_suffix
  }
  "生成密文：" +
  secret_enc_command +
  "\n      然后把输出填到 '" +
  target +
  "'（密文区），并清空 '" +
  clear +
  "'（明文区）。"
}

///|
/// 明文告警文案（与 vools `_plaintext_message` 同形）。
pub fn plaintext_message(
  path : String,
  plain_key : String?,
  cipher_key : String?,
) -> String {
  "⚠ 配置字段 '\{path}' 使用了明文。\n      " +
  command_hint(path, plain_key, cipher_key)
}

// ---------------------------------------------------------------------------
// 解析发现
// ---------------------------------------------------------------------------

///|
/// 一条解析发现（`action` ∈ plaintext / cipher / path / env / kept）。
pub(all) struct SecretFinding {
  /// 配置字段路径（如 `sftp.password`）
  path : String
  /// 动作类别
  action : String
  /// 说明（明文告警时是完整告警文案）
  message : String
}

///|
/// 构造发现条目。
pub fn SecretFinding::new(
  path : String,
  action : String,
  message : String,
) -> SecretFinding {
  { path, action, message, }
}

///|
/// 序列化发现条目。
pub fn SecretFinding::to_json(self : SecretFinding) -> Json {
  Json::object({
    "path": Json::string(self.path),
    "action": Json::string(self.action),
    "message": Json::string(self.message),
  })
}

///|
/// 文本形态（日志/断言用）。
pub fn SecretFinding::to_string(self : SecretFinding) -> String {
  if self.message == "" {
    "SecretFinding(path=\{self.path}, action=\{self.action})"
  } else {
    "SecretFinding(path=\{self.path}, action=\{self.action}, message=\{self.message})"
  }
}

// ---------------------------------------------------------------------------
// 解析器
// ---------------------------------------------------------------------------

///|
/// 配置敏感信息解析器（明文优先 + 告警 + 密文解密）。
pub(all) struct SecretResolver {
  /// 解密密文用的加解密对象（只含明文时可给 None）
  crypto : @rp.RhopCrypto?
  /// true 时遇到明文敏感字段直接 Err（CI / 生产卡口）
  strict : Bool
  /// 是否输出明文告警
  warn_plaintext : Bool
  /// 不参与自动解密/告警的路径（默认 `["key"]`）
  skip_paths : Array[String]
  /// 解析发现（共享引用，跨 walk 累积）
  findings : @ref.Ref[Array[SecretFinding]]
  /// 告警通道（None 时只记录 findings，不打印）
  warner : ((String) -> Unit)?
}

///|
/// 构造解析器。
pub fn SecretResolver::new(
  crypto : @rp.RhopCrypto?,
  strict : Bool,
  warn_plaintext : Bool,
  skip_paths : Array[String],
) -> SecretResolver {
  {
    crypto,
    strict,
    warn_plaintext,
    skip_paths: skip_paths.copy(),
    findings: @ref.Ref([]),
    warner: None,
  }
}

///|
/// 注入告警通道（测试可收集、CLI 可打印到 stderr）。
pub fn SecretResolver::with_warner(
  self : SecretResolver,
  warner : (String) -> Unit,
) -> SecretResolver {
  { ..self, warner: Some(warner), }
}

///|
/// 已累积的发现。
pub fn SecretResolver::findings(self : SecretResolver) -> Array[SecretFinding] {
  self.findings.val.copy()
}

///|
/// 登记一条发现。
fn SecretResolver::record(
  self : SecretResolver,
  path : String,
  action : String,
  message : String,
) -> Unit {
  self.findings.val = self.findings.val.copy() +
    [SecretFinding::new(path, action, message)]
}

///|
/// 登记「用了明文」：记录 finding → 告警 → 严格模式直接 Err。
pub fn SecretResolver::flag_plaintext(
  self : SecretResolver,
  path : String,
  message : String,
) -> Result[Unit, String] {
  self.record(path, "plaintext", message)
  if self.warn_plaintext {
    match self.warner {
      Some(w) => w(message)
      None => ()
    }
  }
  if self.strict {
    Err(message)
  } else {
    Ok(())
  }
}

///|
/// JSON 值 → 字符串（String 原样；Number/Bool 用 JSON 文本；Null 为空串）。
fn json_scalar_text(v : Json) -> String {
  match v {
    String(s) => s
    Null => ""
    _ => Json::stringify(v)
  }
}

///|
/// 该相对路径是否属于「不参与自动解密/自动告警」的路径。
fn SecretResolver::is_skipped(self : SecretResolver, rel_path : String) -> Bool {
  let rel = if rel_path.has_prefix(".") {
    drop_prefix(rel_path, 1)
  } else {
    rel_path
  }
  for pattern in self.skip_paths {
    if rel == pattern || rel.has_prefix(pattern + ".") {
      return true
    }
  }
  false
}

///|
/// 是否是一个「秘密节点」：必须显式出现 `plain` 或 `cipher` 键（值可为空串）。
///
/// 刻意收紧，避免误伤普通配置节点（如 `{"env": {...}}` 这种真·配置），
/// 与 vools `_is_secret_node` 的判定一致。
fn is_secret_node(node : Map[String, Json]) -> Bool {
  node.contains("plain") || node.contains("cipher")
}

///|
/// 解密密文（无密钥/解密失败都给可诊断 Err）。
fn SecretResolver::decrypt(
  self : SecretResolver,
  cipher : Json,
  path : String,
) -> Result[String, String] {
  match self.crypto {
    None =>
      Err(
        "配置字段 '\{path}' 是密文，但当前没有解密密钥：请设置环境变量 RHOP_KEY，或配置 key.path / --key-file。",
      )
    Some(c) =>
      match c.decrypt_secret(json_scalar_text(cipher)) {
        Ok(v) => Ok(v)
        Err(e) => Err("配置字段 '\{path}' 解密失败：\{e}")
      }
  }
}

///|
/// 读密钥文件（js 目标）；非 js 返回可诊断 Err。
fn SecretResolver::read_file(
  self : SecretResolver,
  file_path : String,
  path : String,
) -> Result[String, String] {
  match read_text_file(file_path) {
    Err(e) => Err("配置字段 '\{path}' 读取密钥文件失败: \{e}")
    Ok(t) => Ok(t.trim().to_owned())
  }
}

///|
/// 按「明文 > 密文 > path > env > 空串」取值。
fn SecretResolver::resolve_layers(
  self : SecretResolver,
  plain : Json?,
  cipher : Json?,
  file_path : String?,
  env_name : String?,
  path : String,
  plain_key : String?,
  cipher_key : String?,
) -> Result[String, String] {
  // 1) 非空明文优先
  match plain {
    Some(p) =>
      if json_scalar_text(p) != "" {
        match
          self.flag_plaintext(
            path,
            plaintext_message(path, plain_key, cipher_key),
          ) {
          Err(e) => return Err(e)
          Ok(_) => ()
        }
        return Ok(json_scalar_text(p))
      }
    None => ()
  }
  // 2) 密文
  match cipher {
    Some(c) =>
      if json_scalar_text(c) != "" {
        let v = match self.decrypt(c, path) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        self.record(path, "cipher", "")
        return Ok(v)
      }
    None => ()
  }
  // 3) path（读文件）
  match file_path {
    Some(f) =>
      if f != "" {
        let v = match self.read_file(f, path) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        self.record(path, "path", "")
        return Ok(v)
      }
    None => ()
  }
  // 4) env
  match env_name {
    Some(e) =>
      if e != "" {
        match @env.get_env_var(e) {
          Some(v) =>
            if v == "" {
              return Err(
                "配置字段 '\{path}' 指定了环境变量 \{e}，但该变量为空/未设置。",
              )
            }
          None =>
            return Err(
              "配置字段 '\{path}' 指定了环境变量 \{e}，但该变量为空/未设置。",
            )
        }
        self.record(path, "env", "")
        return Ok(@env.get_env_var(e).unwrap_or(""))
      }
    None => ()
  }
  Ok("")
}

///|
/// 子路径拼接（`parent.child`；parent 为空时就是 child）。
fn child_path(parent : String, key : String) -> String {
  if parent == "" {
    key
  } else {
    parent + "." + key
  }
}

///|
/// 解析整棵配置树，返回**新的** JSON（不改原对象）。
pub fn SecretResolver::resolve(
  self : SecretResolver,
  cfg : Json,
) -> Result[Json, String] {
  match cfg {
    Object(_) => self.walk(cfg, "")
    _ => Err("配置必须是 JSON 对象")
  }
}

///|
/// 递归解析（语义逐条对齐 vools `SecretResolver._walk`）。
fn SecretResolver::walk(
  self : SecretResolver,
  node : Json,
  path : String,
) -> Result[Json, String] {
  // 数组：逐项带下标递归
  if node is Array(items) {
    let out : Array[Json] = []
    for i in 0..<items.length() {
      let v = match self.walk(items[i], path + "[" + i.to_string() + "]") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      out.push(v)
    }
    return Ok(Json::array(out))
  }
  let obj = match node {
    Object(m) => m
    _ => return Ok(node)
  }
  let rel = if path.has_prefix(".") { drop_prefix(path, 1) } else { path }
  if self.is_skipped(rel) {
    return Ok(node)
  }
  // 秘密节点 → 收敛成标量
  if is_secret_node(obj) {
    let resolved = match
      self.resolve_layers(
        obj.get("plain"),
        obj.get("cipher"),
        json_str_opt(obj.get("path")),
        json_str_opt(obj.get("env")),
        if rel == "" {
          "(root)"
        } else {
          rel
        },
        None,
        None,
      ) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    // 其余键保留（记 kept，便于诊断），但主值以解析出的标量为准
    for key, _ in obj {
      if key != "plain" && key != "cipher" && key != "path" && key != "env" {
        self.record(child_path(rel, key), "kept", "")
      }
    }
    return Ok(Json::string(resolved))
  }
  // 兄弟键 * _plain / * _cipher
  let bases : Map[String, Bool] = Map([], capacity=0)
  for key, _ in obj {
    if key.has_suffix(plain_suffix) || key.has_suffix(cipher_suffix) {
      let base = if key.has_suffix(plain_suffix) {
        take_prefix(key, key.length() - plain_suffix.length())
      } else {
        take_prefix(key, key.length() - cipher_suffix.length())
      }
      bases[base] = true
    }
  }
  let out : Map[String, Json] = Map([], capacity=0)
  let node_resolved : Map[String, Bool] = Map([], capacity=0)
  for key, value in obj {
    if key.has_suffix(plain_suffix) || key.has_suffix(cipher_suffix) {
      continue
    }
    let cp = child_path(path, key)
    let is_nested_secret = match value {
      Object(m) => !self.is_skipped(cp) && is_secret_node(m)
      _ => false
    }
    if is_nested_secret {
      let v = match self.walk(value, cp) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      out[key] = v
      node_resolved[key] = true
    } else {
      let v = match self.walk(value, cp) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      out[key] = v
    }
  }
  // 收敛兄弟键
  let from_pairs : Map[String, Bool] = Map([], capacity=0)
  for base, _ in bases {
    let plain_key_name = base + plain_suffix
    let cipher_key_name = base + cipher_suffix
    let plain = obj.get(plain_key_name)
    let cipher = obj.get(cipher_key_name)
    let base_path = child_path(path, base)
    let plain_full = child_path(path, plain_key_name)
    let cipher_full = child_path(path, cipher_key_name)
    let v = match
      self.resolve_layers(
        plain,
        cipher,
        None,
        None,
        base_path,
        Some(plain_full),
        Some(cipher_full),
      ) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    out[base] = Json::string(v)
    from_pairs[base] = true
  }
  // 单值敏感叶：明文告警 / 密文自动解密
  let keys : Array[String] = []
  for key, _ in out {
    keys.push(key)
  }
  for key in keys {
    if from_pairs.contains(key) || node_resolved.contains(key) {
      continue
    }
    let value = out.get(key).unwrap_or(Json::null())
    match value {
      Object(_) | Array(_) => continue
      _ => ()
    }
    if !is_sensitive_leaf(key) {
      continue
    }
    let field_path = child_path(path, key)
    if self.is_skipped(field_path) {
      continue
    }
    let text = json_scalar_text(value)
    if text == "" {
      continue
    }
    if @rp.is_secret(text) {
      let v = match self.decrypt(value, field_path) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      out[key] = Json::string(v)
      self.record(field_path, "cipher", "")
    } else {
      match
        self.flag_plaintext(
          field_path,
          plaintext_message(field_path, None, None),
        ) {
        Err(e) => return Err(e)
        Ok(_) => ()
      }
    }
  }
  Ok(Json::object(out))
}

///|
/// 取 JSON 值的字符串形态（None 保留「键不存在」语义）。
fn json_str_opt(v : Json?) -> String? {
  match v {
    None => None
    Some(j) =>
      match j {
        Null => None
        String(s) => Some(s)
        _ => Some(Json::stringify(j))
      }
  }
}

///|
/// 解析配置里的明文/密文，返回 `(resolved_cfg, findings)`。
///
/// `strict=true` 时遇到明文敏感字段直接 Err（vools 抛 `PlaintextSecretError`）。
/// `skip_paths` 默认 `["key"]`（根密钥由 TaskConfig 专门处理）。
pub fn resolve_config_secrets(
  cfg : Json,
  crypto : @rp.RhopCrypto?,
  strict : Bool,
  warn_plaintext : Bool,
  skip_paths : Array[String],
) -> Result[(Json, Array[SecretFinding]), String] {
  let resolver = SecretResolver::new(crypto, strict, warn_plaintext, skip_paths)
  match resolver.resolve(cfg) {
    Err(e) => Err(e)
    Ok(resolved) => Ok((resolved, resolver.findings()))
  }
}

// ---------------------------------------------------------------------------
// 敏感字段清单（供 HTML 生成器 / CLI 提示）
// ---------------------------------------------------------------------------

///|
/// 一个敏感字段位点（`kind` ∈ leaf / pair / node）。
pub(all) struct SecretField {
  /// 字段路径
  path : String
  /// 位点形态
  kind : String
  /// 明文键路径（leaf/pair 有值）
  plain_key : String?
  /// 密文键路径（leaf/pair 有值）
  cipher_key : String?
}

///|
/// 构造敏感字段位点。
pub fn SecretField::new(
  path : String,
  kind : String,
  plain_key : String?,
  cipher_key : String?,
) -> SecretField {
  { path, kind, plain_key, cipher_key, }
}

///|
/// 序列化。
pub fn SecretField::to_json(self : SecretField) -> Json {
  Json::object({
    "path": Json::string(self.path),
    "kind": Json::string(self.kind),
    "plain_key": match self.plain_key {
      Some(v) => Json::string(v)
      None => Json::null()
    },
    "cipher_key": match self.cipher_key {
      Some(v) => Json::string(v)
      None => Json::null()
    },
  })
}

///|
/// 列出配置里所有敏感字段，返回 `{path, kind, plain_key, cipher_key}` 列表。
///
/// 顺序：先按遍历顺序列出 leaf / node，最后按 base 名字典序列出 pair
/// （与 vools `find_secret_fields` 的分组顺序一致）。
pub fn find_secret_fields(cfg : Json) -> Array[SecretField] {
  let out : Array[SecretField] = []
  find_secret_fields_into(cfg, "", out)
  out
}

///|
/// 递归收集敏感字段位点。
fn find_secret_fields_into(
  cfg : Json,
  prefix : String,
  out : Array[SecretField],
) -> Unit {
  match cfg {
    Array(items) =>
      for i in 0..<items.length() {
        find_secret_fields_into(
          items[i],
          prefix + "[" + i.to_string() + "]",
          out,
        )
      }
    Object(obj) => {
      let bases : Array[String] = []
      for key, _ in obj {
        let base = if key.has_suffix(plain_suffix) {
          take_prefix(key, key.length() - plain_suffix.length())
        } else if key.has_suffix(cipher_suffix) {
          take_prefix(key, key.length() - cipher_suffix.length())
        } else {
          ""
        }
        if base != "" && !bases.contains(base) {
          bases.push(base)
        }
      }
      for key, value in obj {
        let path = child_path(prefix, key)
        if bases.contains(key) ||
          key.has_suffix(plain_suffix) ||
          key.has_suffix(cipher_suffix) {
          continue
        }
        match value {
          Object(m) =>
            if is_secret_node(m) {
              out.push(
                SecretField::new(path, "node", Some("plain"), Some("cipher")),
              )
            } else {
              find_secret_fields_into(value, path, out)
            }
          Array(_) => find_secret_fields_into(value, path, out)
          _ =>
            if is_sensitive_leaf(key) {
              out.push(
                SecretField::new(
                  path,
                  "leaf",
                  Some(path + plain_suffix),
                  Some(path + cipher_suffix),
                ),
              )
            }
        }
      }
      bases.sort()
      for base in bases {
        let path = child_path(prefix, base)
        out.push(
          SecretField::new(
            path,
            "pair",
            Some(path + plain_suffix),
            Some(path + cipher_suffix),
          ),
        )
      }
    }
    _ => ()
  }
}

// ---------------------------------------------------------------------------
// 文件读取（path 分支：js 用 node:fs；其它目标可诊断 Err）
// ---------------------------------------------------------------------------

///|
/// 读 utf8 文本文件（js 目标）。失败返回 "" 并把原因写错误槽。
#cfg(target="js")
extern "js" fn ffi_secrets_read_file(path : String) -> String =
  #| (path) => { const G = globalThis; try { const fs = process.getBuiltinModule("node:fs"); const t = fs.readFileSync(String(path), "utf8"); G.__rxmbt_secrets_err = ""; return t; } catch (e) { G.__rxmbt_secrets_err = String((e && e.message) || e); return ""; } }

///|
/// 取最近一次读失败原因。
#cfg(target="js")
extern "js" fn ffi_secrets_last_error() -> String =
  #| () => { const G = globalThis; return (G.__rxmbt_secrets_err === undefined) ? "" : G.__rxmbt_secrets_err; }

///|
/// js：读文本文件（失败/空内容均返回单一形态，调用方按需判断）。
#cfg(target="js")
fn read_text_file(path : String) -> Result[String, String] {
  let text = ffi_secrets_read_file(path)
  let err = ffi_secrets_last_error()
  if err != "" {
    Err(err)
  } else {
    Ok(text)
  }
}

///|
/// 非 js：无文件系统 API，返回可诊断 Err。
#cfg(not(target="js"))
fn read_text_file(path : String) -> Result[String, String] {
  Err(
    "rhop_task: 读密钥文件仅 js 目标可用（wasm/native 无文件系统 API）",
  )
}
