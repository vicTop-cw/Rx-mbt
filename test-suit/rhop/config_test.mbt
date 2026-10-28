// ============================================================================
// rhop · 配置模型测试（三目标通用：wasm / js / native）
//
// 覆盖（对照 vools tests/test_config.py + 契约 §3 Batch C / §4.1）：
//   1. from_dict：最小配置 / 角色缺省与大小写 / 未知角色 / 非对象 / 缺 key
//   2. _key_from_cfg 四分支：字符串明文、{"plain"}、{"cipher"}、{"path"}/{"env"}
//      （cipher 的正向解密需要 node:crypto，故正向在 test-suit/rhop_interact；
//       这里覆盖「四分支的分派与错误文案」）
//   3. to_dict：has_key、sftp 的 password/key_path 掩码、密钥原文不外泄
//   4. build_crypto / build_online（sftp|git|relay，含未知 kind）/ build_relay /
//      build_shared（单 spec、双 spec、http 写端必须正确解析）/ build_session
//   5. action_cfg：sftp 透出 + has_key + config_name（不含密钥原文）
//   6. load_config：对象 / 数字 / 空串 / 不存在的路径
//   7. from_file：非 js 目标的可诊断 Err、js 目标的不存在文件 Err（两目标都是 Err）
// ============================================================================

// ---------------------------------------------------------------------------
// 测试辅助
// ---------------------------------------------------------------------------

///|
/// 解析 JSON 文本（测试用；解析失败直接 fail）。
fn cfgj(text : String) -> Json {
  @json.parse(text) catch {
    _ => abort("测试语料不是合法 JSON: \{text}")
  }
}

///|
/// 取 JSON 对象字段的字符串值。
fn cfg_str_of(j : Json, key : String) -> String {
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
fn cfg_field_of(j : Json, key : String) -> Json? {
  match j {
    Object(fields) => fields.get(key)
    _ => None
  }
}

///|
/// 取字段并字符串化；缺失给 "null"（断言用，避免在内联位置写 match）。
fn cfg_str_json(j : Json, key : String) -> String {
  match cfg_field_of(j, key) {
    Some(v) => Json::stringify(v)
    None => "null"
  }
}

// ---------------------------------------------------------------------------
// 1. from_dict
// ---------------------------------------------------------------------------

///|
test "config · from_dict：最小配置（只有 key）走全部缺省值" {
  let cfg = @rp.RhopConfig::from_dict(cfgj("{\"key\": \"plain-k\"}"))
  match cfg {
    Ok(c) => {
      assert_eq(c.name(), "rhop-config")
      assert_eq(c.role(), @rp.Role::Send)
      assert_true(c.has_key())
      // 构件：crypto 拿得到同一把 key（key_material 只给内部断言用）
      assert_eq(c.build_crypto().key_material(), "plain-k")
    }
    Err(e) => abort("最小配置应当成功: \{e}")
  }
}

///|
test "config · from_dict：role 大小写不敏感；未知 role / 非字符串 role 可诊断 Err" {
  let cfg = @rp.RhopConfig::from_dict(
    cfgj("{\"key\": \"k\", \"role\": \"recv\", \"name\": \"dev-A\"}"),
  )
  match cfg {
    Ok(c) => {
      assert_eq(c.role(), @rp.Role::Recv)
      assert_eq(c.name(), "dev-A")
    }
    Err(e) => abort("recv 角色应当解析成功: \{e}")
  }
  match
    @rp.RhopConfig::from_dict(cfgj("{\"key\": \"k\", \"role\": \"bogus\"}")) {
    Ok(_) => abort("未知 role 应当 Err")
    Err(e) => assert_true(e.contains("未知角色"))
  }
  match @rp.RhopConfig::from_dict(cfgj("{\"key\": \"k\", \"role\": 7}")) {
    Ok(_) => abort("非字符串 role 应当 Err")
    Err(e) => assert_true(e.contains("role 必须是字符串"))
  }
}

///|
test "config · from_dict：非对象 / 缺 key / 空 key 均可诊断 Err" {
  match @rp.RhopConfig::from_dict(Json::array([])) {
    Ok(_) => abort("数组配置应当 Err")
    Err(e) => assert_true(e.contains("必须是 dict/JSON 对象"))
  }
  match @rp.RhopConfig::from_dict(cfgj("{}")) {
    Ok(_) => abort("缺 key 应当 Err")
    Err(e) => assert_true(e.contains("配置缺少 key"))
  }
  match @rp.RhopConfig::from_dict(cfgj("{\"key\": \"\"}")) {
    Ok(_) => abort("空 key 应当 Err")
    Err(e) => assert_true(e.contains("key 为空字符串"))
  }
}

// ---------------------------------------------------------------------------
// 2. _key_from_cfg 四分支
// ---------------------------------------------------------------------------

///|
test "config · _key_from_cfg 分支 1+2：明文串 / {\"plain\"}" {
  assert_eq(@rp._key_from_cfg(Some(Json::string("plain-k"))), Ok("plain-k"))
  assert_eq(
    @rp._key_from_cfg(Some(cfgj("{\"plain\": \"in-plain\"}"))),
    Ok("in-plain"),
  )
  // plain 为空时继续往后面分支探（不把空串当合法密钥）
  // plain 为空 → 继续走 env/path 分支：既不得把空串当密钥，也不得静默成功
  match @rp._key_from_cfg(Some(cfgj("{\"plain\": \"\"}"))) {
    Ok(k) => assert_true(k.length() > 0) // 只可能来自 env / path 分支
    Err(e) => assert_true(e.contains("未找到本地固定密钥"))
  }
}

///|
test "config · _key_from_cfg：None / null / 非法形态均可诊断 Err" {
  match @rp._key_from_cfg(None) {
    Ok(_) => abort("None 应当 Err")
    Err(e) => assert_true(e.contains("配置缺少 key"))
  }
  match @rp._key_from_cfg(Some(Json::null())) {
    Ok(_) => abort("null 应当 Err")
    Err(e) => assert_true(e.contains("配置缺少 key"))
  }
  match @rp._key_from_cfg(Some(Json::array([]))) {
    Ok(_) => abort("数组 key 应当 Err")
    Err(e) => assert_true(e.contains("形态非法"))
  }
  // 边界：数字 key 按 JSON 文本当密钥（vools 走 str()，口径近似）
  match @rp._key_from_cfg(Some(cfgj("12345"))) {
    Ok(k) => assert_true(k.contains("12345"))
    Err(e) => abort("数字 key 应当被接受: \{e}")
  }
}

///|
test "config · _key_from_cfg 分支 4：{\"path\"} / {\"env\"} 走 load_key（两目标都 Err）" {
  // 不存在的密钥文件：js 目标「读取密钥文件失败」，wasm/native「读文件仅 js 可用」，
  // 统一落到 load_key 的「未找到本地固定密钥」或文件错误 —— 断言 Err 即可。
  match
    @rp._key_from_cfg(Some(cfgj("{\"path\": \"/no/such/rhop-key-file\"}"))) {
    Ok(_) => abort("不存在的 path 应当 Err")
    Err(e) => assert_true(e.length() > 0)
  }
  // 未设置的环境变量
  match
    @rp._key_from_cfg(Some(cfgj("{\"env\": \"RX_MBT_NO_SUCH_KEY_ENV_XYZ\"}"))) {
    Ok(_) => abort("未设置的 env 应当 Err")
    Err(e) =>
      assert_true(
        e.contains("未找到本地固定密钥") || e.contains("未设置"),
      )
  }
}

///|
test "config · _key_from_cfg 分支 3：{\"cipher\"} 缺外层密钥 → 可诊断 Err（不自己解自己）" {
  match
    @rp._key_from_cfg(
      Some(
        cfgj(
          "{\"cipher\": \"RHOP-ENC:AAAA\", \"env\": \"RX_MBT_NO_SUCH_UNLOCK_ENV\"}",
        ),
      ),
    ) {
    Ok(_) => abort("缺外层密钥应当 Err")
    Err(e) => assert_true(e.contains("外层密钥"))
  }
}

// ---------------------------------------------------------------------------
// 3. to_dict
// ---------------------------------------------------------------------------

///|
test "config · to_dict：密钥不外泄，sftp 的 password/key_path 打 ***" {
  let cfg = @rp.RhopConfig::from_dict(
    cfgj(
      "{\"key\": \"TOP-SECRET-KEY-MATERIAL\", \"role\": \"SEND\", \"name\": \"dev-A\", \"sftp\": {\"host\": \"h\", \"port\": 22, \"user\": \"u\", \"password\": \"pw\", \"key_path\": \"/k/id_rsa\", \"dir\": \"/srv\"}}",
    ),
  )
  let c = match cfg {
    Ok(v) => v
    Err(e) => abort("配置应当成功: \{e}")
  }
  let d = c.to_dict()
  // 密钥原文不外泄
  assert_false(Json::stringify(d).contains("TOP-SECRET-KEY-MATERIAL"))
  assert_eq(cfg_str_of(d, "name"), "dev-A")
  assert_eq(cfg_str_of(d, "role"), "SEND")
  match cfg_field_of(d, "has_key") {
    Some(v) => assert_eq(Json::stringify(v), "true")
    None => abort("to_dict 缺 has_key")
  }
  // sftp 掩码：password / key_path 变 ***，其余保留
  match cfg_field_of(d, "sftp") {
    Some(sftp) => {
      assert_eq(cfg_str_of(sftp, "password"), "***")
      assert_eq(cfg_str_of(sftp, "key_path"), "***")
      assert_eq(cfg_str_of(sftp, "host"), "h")
      assert_eq(cfg_str_of(sftp, "dir"), "/srv")
      assert_eq(cfg_str_json(sftp, "port"), "22")
    }
    None => abort("to_dict 缺 sftp")
  }
}

///|
test "config · to_dict：无 sftp 时输出空对象 {}（vools 的 sftp or {}）" {
  let c = match @rp.RhopConfig::from_dict(cfgj("{\"key\": \"k\"}")) {
    Ok(v) => v
    Err(e) => abort("配置应当成功: \{e}")
  }
  let d = c.to_dict()
  assert_eq(cfg_str_json(d, "sftp"), "{}")
  // 未配置的介质字段为 null
  assert_eq(cfg_str_json(d, "online"), "null")
  assert_eq(cfg_str_json(d, "relay"), "null")
}

// ---------------------------------------------------------------------------
// 4. 构件工厂
// ---------------------------------------------------------------------------

///|
test "config · build_online：sftp / git / relay 三种 kind 都能构造，名称可诊断" {
  let c = match
    @rp.RhopConfig::from_dict(
      cfgj(
        "{\"key\": \"k\", \"online\": [{\"kind\": \"sftp\", \"host\": \"h1\", \"port\": 2222, \"user\": \"u1\", \"dir\": \"/srv\"}, {\"kind\": \"git\", \"remote_url\": \"https://example.invalid/r.git\", \"branch\": \"dev\"}, {\"kind\": \"relay\", \"host\": \"127.0.0.1\", \"port\": 9, \"token\": \"t\"}]}",
      ),
    ) {
    Ok(v) => v
    Err(e) => abort("配置应当成功: \{e}")
  }
  match c.build_online() {
    Err(e) => abort("build_online 应当成功: \{e}")
    Ok(channels) => {
      assert_eq(channels.length(), 3)
      assert_eq(@rp.OnlineChannel::name(channels[0]), "sftp:u1@h1:/srv")
      assert_eq(
        @rp.OnlineChannel::name(channels[1]),
        "git:https://example.invalid/r.git",
      )
      assert_eq(
        @rp.OnlineChannel::name(channels[2]),
        "relay:http://127.0.0.1:9",
      )
    }
  }
  // 无 online 配置 → 空数组（不是 Err）
  let bare = match @rp.RhopConfig::from_dict(cfgj("{\"key\": \"k\"}")) {
    Ok(v) => v
    Err(e) => abort("配置应当成功: \{e}")
  }
  match bare.build_online() {
    Ok(chs) => assert_eq(chs.length(), 0)
    Err(e) => abort("空 online 应当 Ok([]): \{e}")
  }
}

///|
test "config · build_online：未知 kind / 非数组 / git 缺 remote_url 均可诊断 Err" {
  let mk = fn(text : String) -> @rp.RhopConfig {
    match @rp.RhopConfig::from_dict(cfgj(text)) {
      Ok(v) => v
      Err(e) => abort("配置应当成功: \{e}")
    }
  }
  match
    mk("{\"key\": \"k\", \"online\": [{\"kind\": \"ftp\"}]}").build_online() {
    Ok(_) => abort("未知 kind 应当 Err")
    Err(e) => {
      assert_true(e.contains("不支持的在线通道 kind"))
      assert_true(e.contains("sftp/git/relay"))
    }
  }
  match
    mk("{\"key\": \"k\", \"online\": {\"kind\": \"sftp\"}}").build_online() {
    Ok(_) => abort("online 非数组应当 Err")
    Err(e) => assert_true(e.contains("必须是数组"))
  }
  match
    mk("{\"key\": \"k\", \"online\": [{\"kind\": \"git\"}]}").build_online() {
    Ok(_) => abort("git 缺 remote_url 应当 Err")
    Err(e) => assert_true(e.contains("remote_url"))
  }
}

///|
test "config · build_shared：无配置 Ok(None)；单 spec / 地址字符串简写 / 缺 write Err" {
  let mk = fn(text : String) -> @rp.RhopConfig {
    match @rp.RhopConfig::from_dict(cfgj(text)) {
      Ok(v) => v
      Err(e) => abort("配置应当成功: \{e}")
    }
  }
  match mk("{\"key\": \"k\"}").build_shared() {
    Ok(None) => ()
    Ok(Some(_)) => abort("无 shared 配置应当 Ok(None)")
    Err(e) => abort("无 shared 配置不应 Err: \{e}")
  }
  // 1) 对象单 spec（读=写）
  match
    mk("{\"key\": \"k\", \"shared\": {\"write\": \"/tmp/rhop-share-a\"}}").build_shared() {
    Ok(Some(view)) => {
      assert_eq(view.write_name(), view.read_name())
      assert_true(view.read_name().contains("rhop-share-a"))
    }
    Ok(None) => abort("有 write 时不应为 None")
    Err(e) => abort("单 spec 应当成功: \{e}")
  }
  // 2) 地址字符串简写
  match
    mk("{\"key\": \"k\", \"shared\": \"/tmp/rhop-share-b\"}").build_shared() {
    Ok(Some(view)) => assert_true(view.read_name().contains("rhop-share-b"))
    Ok(None) => abort("字符串简写不应为 None")
    Err(e) => abort("字符串简写应当成功: \{e}")
  }
  // 3) 缺 write/spec
  match
    mk("{\"key\": \"k\", \"shared\": {\"read\": \"/tmp/x\"}}").build_shared() {
    Ok(_) => abort("缺 write/spec 应当 Err")
    Err(e) => assert_true(e.contains("write/spec"))
  }
  // 4) 地址非法（未知协议）
  match
    mk("{\"key\": \"k\", \"shared\": {\"write\": \"ftp://h/s\"}}").build_shared() {
    Ok(_) => abort("未知协议应当 Err")
    Err(e) => assert_true(e.contains("shared 配置非法"))
  }
}

///|
test "config · build_shared：http(s) 写端必须解析成 http-url（不能当本地目录）" {
  let c = match
    @rp.RhopConfig::from_dict(
      cfgj(
        "{\"key\": \"k\", \"shared\": {\"write\": \"http://127.0.0.1:9/share\"}}",
      ),
    ) {
    Ok(v) => v
    Err(e) => abort("配置应当成功: \{e}")
  }
  match c.build_shared() {
    Ok(Some(view)) => {
      // 关键断言：写视图是 http-url 形态（契约 §3 build_shared 的关键点）
      assert_true(view.write_name().contains("http-url"))
      assert_eq(view.write_name(), view.read_name())
    }
    Ok(None) => abort("http 写端不应为 None")
    Err(e) => abort("http 写端应当成功: \{e}")
  }
  // 双 spec：写本地、读 file://，两视图名字不同
  let c2 = match
    @rp.RhopConfig::from_dict(
      cfgj(
        "{\"key\": \"k\", \"shared\": {\"write\": \"/tmp/rhop-share-c\", \"read\": \"file:///tmp/rhop-share-c\"}}",
      ),
    ) {
    Ok(v) => v
    Err(e) => abort("配置应当成功: \{e}")
  }
  match c2.build_shared() {
    Ok(Some(view)) => {
      assert_true(view.write_name().contains("local"))
      assert_true(view.read_name().contains("file-url"))
      assert_true(view.write_name() != view.read_name())
    }
    _ => abort("双 spec 应当成功")
  }
}

///|
test "config · build_relay：无配置 Ok(None)；有配置给通道；非对象 Err" {
  let mk = fn(text : String) -> @rp.RhopConfig {
    match @rp.RhopConfig::from_dict(cfgj(text)) {
      Ok(v) => v
      Err(e) => abort("配置应当成功: \{e}")
    }
  }
  match mk("{\"key\": \"k\"}").build_relay() {
    Ok(None) => ()
    _ => abort("无 relay 配置应当 Ok(None)")
  }
  match
    mk(
      "{\"key\": \"k\", \"relay\": {\"host\": \"10.0.0.2\", \"port\": 7777, \"token\": \"tk\"}}",
    ).build_relay() {
    Ok(Some(rc)) => {
      let ch : &@rp.OnlineChannel = rc
      assert_eq(@rp.OnlineChannel::name(ch), "relay:http://10.0.0.2:7777")
    }
    Ok(None) => abort("有 relay 配置不应为 None")
    Err(e) => abort("relay 配置应当成功: \{e}")
  }
  match mk("{\"key\": \"k\", \"relay\": \"just-a-string\"}").build_relay() {
    Ok(_) => abort("非对象 relay 应当 Err")
    Err(e) => assert_true(e.contains("必须是对象"))
  }
  // host/port 缺省：127.0.0.1:0
  match mk("{\"key\": \"k\", \"relay\": {}}").build_relay() {
    Ok(Some(rc)) => {
      let ch : &@rp.OnlineChannel = rc
      assert_eq(@rp.OnlineChannel::name(ch), "relay:http://127.0.0.1:0")
    }
    _ => abort("空 relay 对象应当给缺省通道")
  }
}

///|
test "config · build_session：角色缺省/覆盖、介质与密钥装配、坏配置向上传染 Err" {
  let c = match
    @rp.RhopConfig::from_dict(
      cfgj(
        "{\"key\": \"k1\", \"role\": \"RECV\", \"name\": \"dev-B\", \"shared\": {\"write\": \"/tmp/rhop-share-d\"}, \"online\": [{\"kind\": \"sftp\", \"host\": \"h\", \"dir\": \"/srv\"}]}",
      ),
    ) {
    Ok(v) => v
    Err(e) => abort("配置应当成功: \{e}")
  }
  match c.build_session() {
    Ok(s) => {
      // 缺省沿用配置里的角色
      assert_eq(s.role(), @rp.Role::Recv)
      assert_eq(s.name(), "dev-B")
      assert_true(s.has_crypto())
      assert_true(s.has_shared())
      assert_eq(s.online_count(), 1)
      assert_false(s.has_relay())
    }
    Err(e) => abort("build_session 应当成功: \{e}")
  }
  // 角色可覆盖（interact 的 SEND/RECV 双端就是这样来的）
  match c.build_session(role=@rp.Role::Send) {
    Ok(s) => assert_eq(s.role(), @rp.Role::Send)
    Err(e) => abort("角色覆盖应当成功: \{e}")
  }
  // 坏 online 配置 → build_session 也 Err（不吞错）
  let bad = match
    @rp.RhopConfig::from_dict(
      cfgj("{\"key\": \"k\", \"online\": [{\"kind\": \"nope\"}]}"),
    ) {
    Ok(v) => v
    Err(e) => abort("配置应当成功: \{e}")
  }
  match bad.build_session() {
    Ok(_) => abort("坏 online 应让 build_session Err")
    Err(e) => assert_true(e.contains("不支持的在线通道 kind"))
  }
}

// ---------------------------------------------------------------------------
// 5. action_cfg
// ---------------------------------------------------------------------------

///|
test "config · action_cfg：透出 sftp + has_key + config_name，且不含密钥原文" {
  let c = match
    @rp.RhopConfig::from_dict(
      cfgj(
        "{\"key\": \"SECRET-XYZ\", \"name\": \"dev-A\", \"sftp\": {\"host\": \"jump.example\", \"port\": 10022, \"user\": \"ops\"}}",
      ),
    ) {
    Ok(v) => v
    Err(e) => abort("配置应当成功: \{e}")
  }
  let ac = c.action_cfg()
  assert_eq(cfg_str_of(ac, "config_name"), "dev-A")
  match cfg_field_of(ac, "has_key") {
    Some(v) => assert_eq(Json::stringify(v), "true")
    None => abort("action_cfg 缺 has_key")
  }
  match cfg_field_of(ac, "sftp") {
    Some(sftp) => {
      assert_eq(cfg_str_of(sftp, "host"), "jump.example")
      assert_eq(cfg_str_of(sftp, "user"), "ops")
    }
    None => abort("action_cfg 缺 sftp")
  }
  // 密钥原文绝不进动作配置
  assert_false(Json::stringify(ac).contains("SECRET-XYZ"))
}

// ---------------------------------------------------------------------------
// 6. load_config / from_file
// ---------------------------------------------------------------------------

///|
test "config · load_config：对象直传 / 数字与空串可诊断 Err" {
  let direct = @rp.load_config(cfgj("{\"key\": \"k\", \"name\": \"dev-C\"}"))
  match direct {
    Ok(c) => assert_eq(c.name(), "dev-C")
    Err(e) => abort("对象直传应当成功: \{e}")
  }
  match @rp.load_config(cfgj("42")) {
    Ok(_) => abort("数字不是合法 cfg")
    Err(e) =>
      assert_true(
        e.contains("必须是配置对象 JSON 或 JSON 文件路径"),
      )
  }
  match @rp.load_config(Json::string("")) {
    Ok(_) => abort("空串应当 Err")
    Err(e) => assert_true(e.contains("cfg 不能为空"))
  }
}

///|
test "config · from_file / load_config(路径)：不存在的文件在两目标都是 Err" {
  match @rp.RhopConfig::from_file("/no/such/rhop-config.json") {
    Ok(_) => abort("不存在的配置文件应当 Err")
    Err(e) => assert_true(e.length() > 0)
  }
  match @rp.load_config(Json::string("/no/such/rhop-config.json")) {
    Ok(_) => abort("路径形态的不存在文件应当 Err")
    Err(e) => assert_true(e.length() > 0)
  }
  // 空路径
  match @rp.RhopConfig::from_file("") {
    Ok(_) => abort("空路径应当 Err")
    Err(e) => assert_true(e.contains("配置文件路径不能为空"))
  }
}

// ---------------------------------------------------------------------------
// 8. C1-F6：to_dict 递归掩码（online / relay / shared 的敏感字段）
// ---------------------------------------------------------------------------

///|
test "config · to_dict 递归掩码：online/relay/shared 的 password/key_path/token 都是 ***" {
  let cfg = @rp.RhopConfig::from_dict(
    cfgj(
      "{\"key\": \"k\", \"sftp\": {\"host\": \"h\", \"password\": \"SFTP-PW-X\", \"key_path\": \"/id-x\"}, \"online\": [{\"kind\": \"sftp\", \"host\": \"h\", \"password\": \"ONLINE-PW-X\", \"key_path\": \"/id-online-x\", \"token\": \"ONLINE-TOKEN-X\"}, {\"kind\": \"relay\", \"host\": \"r\", \"token\": \"INNER-TOKEN-X\"}], \"relay\": {\"host\": \"10.0.0.1\", \"port\": 9000, \"token\": \"RELAY-TOKEN-X\"}, \"shared\": {\"write\": \"/tmp/x\", \"password\": \"SHARED-PW-X\"}}",
    ),
  )
  match cfg {
    Ok(c) => {
      let text = Json::stringify(c.to_dict())
      // 所有敏感明文都不得出现在导出结果里
      assert_true(!text.contains("SFTP-PW-X"))
      assert_true(!text.contains("ONLINE-PW-X"))
      assert_true(!text.contains("/id-online-x"))
      assert_true(!text.contains("ONLINE-TOKEN-X"))
      assert_true(!text.contains("INNER-TOKEN-X"))
      assert_true(!text.contains("RELAY-TOKEN-X"))
      assert_true(!text.contains("SHARED-PW-X"))
      // 结构与非敏感字段仍在（掩码不是删字段）
      let d = c.to_dict()
      assert_eq(cfg_str_json(d, "role"), "\"SEND\"")
      match cfg_field_of(d, "relay") {
        Some(relay) => {
          assert_eq(cfg_str_of(relay, "host"), "10.0.0.1")
          assert_eq(cfg_str_of(relay, "token"), "***")
        }
        None => abort("relay 字段丢失")
      }
      match cfg_field_of(d, "online") {
        Some(Array(items)) => {
          assert_eq(items.length(), 2)
          assert_eq(cfg_str_of(items[0], "password"), "***")
          assert_eq(cfg_str_of(items[1], "token"), "***")
        }
        _ => abort("online 应为数组")
      }
    }
    Err(e) => abort("配置解析失败: " + e)
  }
}

// ---------------------------------------------------------------------------
// 9. C1-F7：Python `or` 语义（空串回退默认、0/负数端口归一）
// ---------------------------------------------------------------------------

///|
test "config · build_relay：host 空串回退 127.0.0.1；port 0/负值归一（C1-F7）" {
  let cfg = @rp.RhopConfig::from_dict(
    cfgj("{\"key\": \"k\", \"relay\": {\"host\": \"\", \"port\": 9000}}"),
  )
  match cfg {
    Ok(c) =>
      match c.build_relay() {
        Ok(Some(rc)) => assert_eq(rc.base(), "http://127.0.0.1:9000")
        Ok(None) => abort("relay 不应为 None")
        Err(e) => abort("build_relay 失败: " + e)
      }
    Err(e) => abort("配置解析失败: " + e)
  }
  // port 0 / 负数 → 回退默认 0（表示「未定端口」，绝不产生非法端口值）
  for
    spec in [
      "{\"key\": \"k\", \"relay\": {\"port\": 0}}", "{\"key\": \"k\", \"relay\": {\"port\": -5}}",
    ] {
    match @rp.RhopConfig::from_dict(cfgj(spec)) {
      Ok(c) =>
        match c.build_relay() {
          Ok(Some(rc)) => assert_eq(rc.base(), "http://127.0.0.1:0")
          Ok(None) => abort("relay 不应为 None")
          Err(e) => abort("build_relay 失败: " + e)
        }
      Err(e) => abort("配置解析失败: " + e)
    }
  }
  // timeout 0 视为未配置（不产生 0 超时探测）
  match
    @rp.RhopConfig::from_dict(
      cfgj(
        "{\"key\": \"k\", \"relay\": {\"host\": \"h\", \"port\": 1, \"timeout\": 0}}",
      ),
    ) {
    Ok(c) =>
      match c.build_relay() {
        Ok(Some(rc)) => assert_eq(rc.base(), "http://h:1")
        Ok(None) => abort("relay 不应为 None")
        Err(e) => abort("build_relay 失败: " + e)
      }
    Err(e) => abort("配置解析失败: " + e)
  }
}

// ---------------------------------------------------------------------------
// 10. C1-F8：低成本语义对齐（role 空串 / shared {} / online 非对象 / 布尔 key）
// ---------------------------------------------------------------------------

///|
test "config · F8 语义对齐：role 空串→SEND、shared {}→None、online 非对象→Err、key 布尔→Err" {
  // vools: role = str(data.get("role") or SEND).upper()
  match @rp.RhopConfig::from_dict(cfgj("{\"key\": \"k\", \"role\": \"\"}")) {
    Ok(c) => assert_eq(c.role(), @rp.Role::Send)
    Err(e) => abort("role 空串应当回退 SEND: " + e)
  }
  match @rp.RhopConfig::from_dict(cfgj("{\"key\": \"k\", \"role\": \"  \"}")) {
    Ok(c) => assert_eq(c.role(), @rp.Role::Send)
    Err(e) => abort("role 纯空白应当回退 SEND: " + e)
  }
  // vools: if not self.shared: return None（{} 是 falsy）
  match @rp.RhopConfig::from_dict(cfgj("{\"key\": \"k\", \"shared\": {}}")) {
    Ok(c) =>
      match c.build_shared() {
        Ok(None) => ()
        Ok(Some(_)) => abort("shared {} 应当等价于未配置（None）")
        Err(e) => abort("shared {} 不应 Err: " + e)
      }
    Err(e) => abort("配置解析失败: " + e)
  }
  // 非对象 online spec：必须 Err，不能静默造空通道
  match
    @rp.RhopConfig::from_dict(
      cfgj("{\"key\": \"k\", \"online\": [\"oops\", 42]}"),
    ) {
    Ok(c) =>
      match c.build_online() {
        Ok(chs) =>
          abort(
            "非对象 online spec 应当 Err，实际构造了 \{chs.length()} 条",
          )
        Err(e) => assert_true(e.contains("必须是对象"))
      }
    Err(e) => abort("配置解析失败: " + e)
  }
  // 布尔 key：明确 Err（vools str(True)="True" 与 MoonBit "true" 口径不同）
  match @rp.RhopConfig::from_dict(cfgj("{\"key\": true}")) {
    Ok(_) => abort("布尔 key 应当 Err")
    Err(e) => assert_true(e.contains("不接受布尔值"))
  }
  match @rp._key_from_cfg(Some(cfgj("false"))) {
    Ok(_) => abort("布尔 key 应当 Err")
    Err(e) => assert_true(e.contains("不接受布尔值"))
  }
}

// ---------------------------------------------------------------------------
// C2-01：load_config 的「配置文本 vs 文件路径」形态判定（防错误信息放大）
// ---------------------------------------------------------------------------

///|
/// 生成 depth 层嵌套的对象文本 `{"a":{"a":…1…}}`（C2-01 复现语料）。
fn deep_json_text(depth : Int32) -> String {
  let sb = StringBuilder::new()
  for _ in 0..<depth {
    sb.write_string("{\"a\":")
  }
  sb.write_string("1")
  for _ in 0..<depth {
    sb.write_string("}")
  }
  sb.to_string()
}

///|
test "config · C2-01：非对象 JSON 文本不再被当成文件路径（数组/标量）" {
  // 数组文本：必须报「必须是对象」，而不是「读取配置文件失败 … ENOENT」
  match @rp.load_config(Json::string("[1, 2, 3]")) {
    Ok(_) => abort("数组文本不应成为配置")
    Err(e) => {
      assert_true(e.contains("必须是 dict/JSON 对象"))
      assert_false(e.contains("读取配置文件失败"))
    }
  }
  // 对象文本仍正常解析（形态判定不能误伤正路）
  match @rp.load_config(Json::string("{\"key\": \"k\", \"name\": \"dev-T\"}")) {
    Ok(c) => assert_eq(c.name(), "dev-T")
    Err(e) => abort("对象文本应当解析成功: " + e)
  }
}

///|
test "config · C2-01：超深/超长 JSON 文本绝不被当成文件路径，错误串有上界" {
  // 1) 以 `{` 开头但内容非法的超长文本：给「不是合法 JSON」+ 片段截断
  let sb = StringBuilder::new()
  sb.write_string("{\"key\": \"k\", \"junk\": ")
  for i in 0..<12000 {
    let _ = i
    sb.write_char('x')
  }
  let invalid = sb.to_string()
  match @rp.load_config(Json::string(invalid)) {
    Ok(_) => abort("非法 JSON 文本不应被接受")
    Err(e) => {
      assert_false(e.contains("读取配置文件失败"))
      assert_false(e.contains("ENAMETOOLONG"))
      assert_true(e.contains("不是合法 JSON"))
      // 错误串远小于输入（输入 12KB+，日志放大被截断）
      assert_true(e.length() < 400)
    }
  }
  // 2) 2048 层深嵌套：解析器可能有深度上限（拒绝）也可能接受，
  //    但**无论如何都不能回落成「读文件」**（这正是 C2-01 的根因）
  let deep = deep_json_text(2048)
  let text = "{\"key\": \"k\", \"junk\": " + deep + "}"
  match @rp.load_config(Json::string(text)) {
    Ok(_) => ()
    Err(e) => {
      assert_false(e.contains("读取配置文件失败"))
      assert_false(e.contains("ENAMETOOLONG"))
      assert_true(e.length() < 400)
    }
  }
}

///|
test "config · C2-01：长纯文本 / 多行文本拒绝，不当路径" {
  // 多行文本
  match @rp.load_config(Json::string("line1\nline2")) {
    Ok(_) => abort("多行文本不应成为配置")
    Err(e) => {
      assert_true(
        e.contains("既不是配置对象 JSON 也不是可用的文件路径"),
      )
      assert_true(e.length() < 400)
    }
  }
  // 超长单行纯文本（> CFG_PATH_MAX_LEN）
  let sb = StringBuilder::new()
  for i in 0..<4200 {
    let _ = i
    sb.write_char('a')
  }
  let huge = sb.to_string()
  match @rp.load_config(Json::string(huge)) {
    Ok(_) => abort("超长文本不应成为配置")
    Err(e) => {
      assert_true(
        e.contains("既不是配置对象 JSON 也不是可用的文件路径"),
      )
      assert_true(e.length() < 400)
    }
  }
}

///|
test "config · C2-01：from_file 超长路径直接判错（不把超长串交给文件系统）" {
  let sb = StringBuilder::new()
  for i in 0..<4200 {
    let _ = i
    sb.write_char('b')
  }
  let huge_path = sb.to_string()
  match @rp.RhopConfig::from_file(huge_path) {
    Ok(_) => abort("超长路径不应成功")
    Err(e) => {
      assert_true(e.contains("路径过长"))
      assert_true(e.contains("4096"))
      assert_true(e.length() < 400)
    }
  }
  // 正常长度的不存在路径：仍给可诊断的读取失败（既有行为不回归）
  match @rp.RhopConfig::from_file("/no/such/rhop-config-c2.json") {
    Ok(_) => abort("不存在的配置应当 Err")
    Err(e) => assert_true(e.contains("读取配置文件失败"))
  }
}
