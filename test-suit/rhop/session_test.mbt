// ============================================================================
// rhop · 会话模型测试（三目标通用：wasm / js / native）
//
// 覆盖（对照 vools tests/test_session.py + 契约 §3 Batch C / §4.1）：
//   1. Role：to_string / lower / parse（大小写不敏感 + 未知值可诊断 Err）
//   2. Session 装配：默认会话名、访问器、空会话
//   3. 通道链：relay > online > shared 的三级选择（用 mock 通道/介质驱动）
//   4. available()：任一级可用即为 true；全不可达为 false
//   5. send_package / recv_package 的**配置/角色类**错误（RELAY、缺密钥、全不可达）
//   6. recv_package 的「坏包」路径：MALFORMED / BAD_TOKEN 四态 reason（不依赖 node:crypto）
//   7. reverse()：SEND<->RECV 互换、RELAY 不变、介质与密钥原样复用
//   8. describe()：vools 同形字段（name/role/online/shared/relay/has_crypto）
//
// 说明：真实加密闭环（Fernet）只在 js 目标可用，故加密往返测试在
// test-suit/rhop_interact/interact_test.mbt；本文件用 mock 介质覆盖**编排与选择逻辑**，
// 这正是契约 §4.1 给 test-suit/rhop 的「session 纯逻辑部分」。
// ============================================================================

// ---------------------------------------------------------------------------
// mock 介质（内存实现；用于驱动通道链，不碰文件系统）
// ---------------------------------------------------------------------------

///|
/// 内存 shared path：files 是文件名→内容，reachable 模拟介质可达性。
struct MemPath {
  files : Map[String, String]
  reachable : Bool
  label : String
}

///|
/// 构造内存介质（`reachable=false` 模拟不可达挂载）。
fn MemPath::new(label : String, reachable : Bool) -> MemPath {
  { files: Map([]), reachable, label, }
}

///|
/// 是否可达由 reachable 决定。
impl @rp.SharedPath for MemPath with fn available(self) {
  self.reachable
}

///|
/// 写入内存表（不可达时 Err）。
impl @rp.SharedPath for MemPath with fn write_text(self, filename, content) {
  if !self.reachable {
    return Err("mem path 不可达: " + self.label)
  }
  self.files[filename] = content
  Ok(())
}

///|
/// 读取内存表（缺失时 Err，文案与 LocalSharedPath 同形以便上层统一处理）。
impl @rp.SharedPath for MemPath with fn read_text(self, filename) {
  match self.files.get(filename) {
    Some(v) => Ok(v)
    None =>
      Err(
        "rhop: 读取失败: " + self.label + "/" + filename + ": no such file",
      )
  }
}

///|
/// 是否已写入。
impl @rp.SharedPath for MemPath with fn exists(self, filename) {
  self.files.contains(filename)
}

///|
/// 删除（幂等）。
impl @rp.SharedPath for MemPath with fn remove(self, filename) {
  self.files.remove(filename)
  Ok(())
}

///|
/// 介质名（断言用）。
impl @rp.SharedPath for MemPath with fn name(self) {
  "mem:" + self.label
}

///|
/// 内存介质没有本地根。
impl @rp.SharedPath for MemPath with fn root(self) {
  None
}

///|
/// 内存在线通道：up 控制可用性，store 保存「远端」包。
struct MemChannel {
  store : Map[String, String]
  up : Bool
  label : String
}

///|
/// 构造内存通道。
fn MemChannel::new(label : String, up : Bool) -> MemChannel {
  { store: Map([]), up, label, }
}

///|
/// 可用性由 up 决定。
impl @rp.OnlineChannel for MemChannel with fn available(self) {
  self.up
}

///|
/// 发送到内存「远端」。
impl @rp.OnlineChannel for MemChannel with fn send(self, filename, content) {
  if !self.up {
    return Err("mock channel down: " + self.label)
  }
  self.store[filename] = content
  Ok(())
}

///|
/// 从内存「远端」取包（取走即删，与 relay 语义一致）。
impl @rp.OnlineChannel for MemChannel with fn receive(self, filename) {
  if !self.up {
    return Err("mock channel down: " + self.label)
  }
  match self.store.get(filename) {
    Some(v) => {
      self.store.remove(filename)
      Ok(v)
    }
    None => Err("mock channel 无包: " + filename)
  }
}

///|
/// 通道名（断言用）。
impl @rp.OnlineChannel for MemChannel with fn name(self) {
  "mem-channel:" + self.label
}

// ---------------------------------------------------------------------------
// 测试辅助
// ---------------------------------------------------------------------------

///|
/// 由内存介质构造单视图（读=写）。
fn mem_view(mem : MemPath) -> @rp.SharedPathView {
  let sp : &@rp.SharedPath = mem
  @rp.make_shared_path_from_views(sp, None)
}

///|
/// 取 JSON 对象字段的字符串值（断言用）。
fn json_str_of(j : Json, key : String) -> String {
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
/// 取 JSON 对象字段（断言用）。
fn json_field_of(j : Json, key : String) -> Json? {
  match j {
    Object(fields) => fields.get(key)
    _ => None
  }
}

// ---------------------------------------------------------------------------
// 1. Role
// ---------------------------------------------------------------------------

///|
test "session · Role：to_string / lower / parse 往返（大小写不敏感）" {
  let send : @rp.Role = @rp.Role::Send
  let recv : @rp.Role = @rp.Role::Recv
  let relay : @rp.Role = @rp.Role::Relay
  assert_eq(send.to_string(), "SEND")
  assert_eq(recv.to_string(), "RECV")
  assert_eq(relay.to_string(), "RELAY")
  assert_eq(send.lower(), "send")
  assert_eq(recv.lower(), "recv")
  assert_eq(relay.lower(), "relay")
  // 解析：大小写不敏感 + 忽略首尾空白
  assert_eq(@rp.Role::parse("SEND"), Ok(send))
  assert_eq(@rp.Role::parse("send"), Ok(send))
  assert_eq(@rp.Role::parse("  Recv "), Ok(recv))
  assert_eq(@rp.Role::parse("ReLaY"), Ok(relay))
}

///|
test "session · Role::parse 未知值返回可诊断 Err（不静默回退默认角色）" {
  match @rp.Role::parse("bogus") {
    Err(e) => {
      assert_true(e.contains("未知角色"))
      assert_true(e.contains("SEND/RECV/RELAY"))
    }
    Ok(_) => fail("未知角色应当 Err")
  }
  // 边界：空串
  match @rp.Role::parse("") {
    Err(e) => assert_true(e.contains("未知角色"))
    Ok(_) => fail("空角色应当 Err")
  }
}

// ---------------------------------------------------------------------------
// 2. Session 装配
// ---------------------------------------------------------------------------

///|
test "session · 默认会话名与访问器；空会话无介质无密钥" {
  let empty = @rp.Session::empty(@rp.Role::Recv)
  assert_eq(empty.name(), "session:recv")
  assert_eq(empty.role(), @rp.Role::Recv)
  assert_eq(empty.online_count(), 0)
  assert_false(empty.has_crypto())
  assert_false(empty.has_shared())
  assert_false(empty.has_relay())
  // 显式名字不被覆盖
  let named = @rp.Session::new(@rp.Role::Relay, None, [], None, None, "dev-A")
  assert_eq(named.name(), "dev-A")
  // 空白名字回退默认
  let blank = @rp.Session::new(@rp.Role::Send, None, [], None, None, "   ")
  assert_eq(blank.name(), "session:send")
}

// ---------------------------------------------------------------------------
// 3. 通道链：relay > online > shared
// ---------------------------------------------------------------------------

///|
test "session · 通道链：online 可用时优先选 online（relay 未配置）" {
  let mem = MemPath::new("share", true)
  let up = MemChannel::new("git-primary", true)
  let ch : &@rp.OnlineChannel = up
  let s = @rp.Session::new(
    @rp.Role::Send,
    Some(mem_view(mem)),
    [ch],
    None,
    None,
    "",
  )
  assert_true(s.available())
  let sel = s.select()
  assert_eq(sel.transport, "online")
  assert_eq(sel.label, "mem-channel:git-primary")
  assert_true(sel.is_online)
  assert_true(sel.reason.contains("在线通道可用"))
}

///|
test "session · 通道链：在线全不可用则回退 shared path" {
  let mem = MemPath::new("share", true)
  let down = MemChannel::new("sftp-down", false)
  let ch : &@rp.OnlineChannel = down
  let s = @rp.Session::new(
    @rp.Role::Send,
    Some(mem_view(mem)),
    [ch],
    None,
    None,
    "",
  )
  assert_true(s.available())
  let sel = s.select()
  assert_eq(sel.transport, "shared")
  assert_false(sel.is_online)
  assert_true(sel.label.contains("mem:share"))
  assert_true(sel.reason.contains("回退 shared path"))
}

///|
test "session · 通道链：多条在线通道按顺序取第一条可用的" {
  let down1 = MemChannel::new("first-down", false)
  let down2 = MemChannel::new("second-down", false)
  let up3 = MemChannel::new("third-up", true)
  let c1 : &@rp.OnlineChannel = down1
  let c2 : &@rp.OnlineChannel = down2
  let c3 : &@rp.OnlineChannel = up3
  let s = @rp.Session::new(@rp.Role::Send, None, [c1, c2, c3], None, None, "")
  let sel = s.select()
  assert_eq(sel.transport, "online")
  assert_eq(sel.label, "mem-channel:third-up")
}

///|
test "session · 通道链：全部不可达 → available=false 且 recv 返回可诊断 Err" {
  let dead = MemPath::new("dead-mount", false)
  let down = MemChannel::new("dead-channel", false)
  let ch : &@rp.OnlineChannel = down
  let s = @rp.Session::new(
    @rp.Role::Recv,
    Some(mem_view(dead)),
    [ch],
    None,
    Some(@rp.RhopCrypto::from_key("k1")),
    "",
  )
  assert_false(s.available())
  assert_eq(s.select().transport, "none")
  assert_true(s.select().reason.contains("全不可达"))
  match s.recv_package("x.rhop") {
    Err(e) => {
      assert_true(e.contains("无可用的传输介质"))
      assert_true(e.contains("relay/online/shared"))
    }
    Ok(_) => fail("通道链全不可达时 recv 应当 Err")
  }
}

///|
test "session · 通道链：无任何介质时 select 给出 none + 可诊断 reason" {
  let s = @rp.Session::empty(@rp.Role::Send)
  let sel = s.select()
  assert_eq(sel.transport, "none")
  assert_eq(sel.label, "")
  assert_false(sel.is_online)
  assert_true(sel.reason.contains("无可用的传输介质"))
}

// ---------------------------------------------------------------------------
// 4. send_package / recv_package 的配置/角色类错误
// ---------------------------------------------------------------------------

///|
test "session · RELAY 角色不发送也不消费载荷（与 vools 同语义）" {
  let mem = MemPath::new("share", true)
  let s = @rp.Session::new(
    @rp.Role::Relay,
    Some(mem_view(mem)),
    [],
    None,
    Some(@rp.RhopCrypto::from_key("k1")),
    "",
  )
  match s.send_package("a.rhop", Json::object(Map([]))) {
    Err(e) => assert_true(e.contains("RELAY 角色不发送载荷"))
    Ok(_) => fail("RELAY 发送应当 Err")
  }
  match s.recv_package("a.rhop") {
    Err(e) => assert_true(e.contains("RELAY 角色不消费载荷"))
    Ok(_) => fail("RELAY 接收应当 Err")
  }
}

///|
test "session · 未配置密钥时 send/recv 均返回可诊断 Err" {
  let mem = MemPath::new("share", true)
  let s = @rp.Session::new(
    @rp.Role::Send,
    Some(mem_view(mem)),
    [],
    None,
    None,
    "",
  )
  match s.send_package("a.rhop", Json::object(Map([]))) {
    Err(e) => assert_true(e.contains("未配置密钥"))
    Ok(_) => fail("缺密钥发送应当 Err")
  }
  match s.recv_package("a.rhop") {
    Err(e) => assert_true(e.contains("未配置密钥"))
    Ok(_) => fail("缺密钥接收应当 Err")
  }
}

// ---------------------------------------------------------------------------
// 5. recv_package 的坏包路径（四态 reason；不依赖 node:crypto）
// ---------------------------------------------------------------------------

///|
test "session · recv_package：坏包返回 vools 同形 error 回执（reason 四态之一）" {
  let mem = MemPath::new("share", true)
  let s = @rp.Session::new(
    @rp.Role::Recv,
    Some(mem_view(mem)),
    [],
    None,
    Some(@rp.RhopCrypto::from_key("k1")),
    "",
  )
  // 情形 1：不是 JSON → MALFORMED
  mem.files["bad1.rhop"] = "这不是 JSON"
  match s.recv_package("bad1.rhop") {
    Ok(j) => {
      assert_eq(json_str_of(j, "status"), "error")
      assert_eq(json_str_of(j, "transport"), "shared")
      assert_eq(json_str_of(j, "filename"), "bad1.rhop")
      assert_eq(json_str_of(j, "reason"), "MALFORMED")
    }
    Err(e) => fail("坏包应走 status:error 回执而非 Err: \{e}")
  }
  // 情形 2：合法信封但 ct 坏 → BAD_TOKEN（wasm/native 上 fernet 不可用同样判 BAD_TOKEN）
  mem.files["bad2.rhop"] = "{\"v\":1,\"alg\":\"fernet\",\"ct\":\"AAAA\"}"
  match s.recv_package("bad2.rhop") {
    Ok(j) => {
      assert_eq(json_str_of(j, "status"), "error")
      assert_eq(json_str_of(j, "reason"), "BAD_TOKEN")
    }
    Err(e) => fail("坏包应走 status:error 回执而非 Err: \{e}")
  }
  // 情形 3：信封版本非法（v=2）→ MALFORMED
  mem.files["bad3.rhop"] = "{\"v\":2,\"alg\":\"fernet\",\"ct\":\"AAAA\"}"
  match s.recv_package("bad3.rhop") {
    Ok(j) => assert_eq(json_str_of(j, "reason"), "MALFORMED")
    Err(e) => fail("坏包应走 status:error 回执而非 Err: \{e}")
  }
}

///|
test "session · recv_package：介质缺文件 → status:error + 传输层原因（不是 Err）" {
  let mem = MemPath::new("share", true)
  let s = @rp.Session::new(
    @rp.Role::Recv,
    Some(mem_view(mem)),
    [],
    None,
    Some(@rp.RhopCrypto::from_key("k1")),
    "",
  )
  match s.recv_package("missing.rhop") {
    Ok(j) => {
      assert_eq(json_str_of(j, "status"), "error")
      assert_eq(json_str_of(j, "transport"), "shared")
      assert_true(json_str_of(j, "reason").contains("读取失败"))
    }
    Err(e) => fail("介质缺文件应走 status:error 回执而非 Err: \{e}")
  }
  // 边界：空文件名属**调用方参数错误** → Err（分流原则：参数/配置错误走 Err，
  // 传输层 I/O 失败才走 status:error 收据）
  match s.recv_package("") {
    Ok(j) =>
      fail(
        "空文件名应为参数错误 Err，实际回执: " +
        Json::stringify(j),
      )
    Err(e) => assert_true(e.contains("包文件名不能为空"))
  }
}

///|
test "session · recv_package 走在线通道时 transport 标签为 online" {
  let up = MemChannel::new("git-a", true)
  up.store["pkg.rhop"] = "{\"v\":1,\"alg\":\"fernet\",\"ct\":\"AAAA\"}"
  let ch : &@rp.OnlineChannel = up
  let s = @rp.Session::new(
    @rp.Role::Recv,
    None,
    [ch],
    None,
    Some(@rp.RhopCrypto::from_key("k1")),
    "",
  )
  match s.recv_package("pkg.rhop") {
    Ok(j) => {
      assert_eq(json_str_of(j, "transport"), "online")
      assert_eq(json_str_of(j, "status"), "error")
      assert_eq(json_str_of(j, "reason"), "BAD_TOKEN")
    }
    Err(e) => fail("坏包应走 status:error 回执而非 Err: \{e}")
  }
  // 在线通道「取走即删」：第二次应当读不到（错误回执，reason 带无包提示）
  match s.recv_package("pkg.rhop") {
    Ok(j) => assert_true(json_str_of(j, "reason").contains("无包"))
    Err(e) => fail("坏包应走 status:error 回执而非 Err: \{e}")
  }
}

// ---------------------------------------------------------------------------
// 6. reverse()
// ---------------------------------------------------------------------------

///|
test "session · reverse：SEND<->RECV 互换、RELAY 不变、介质与密钥复用" {
  let mem = MemPath::new("share", true)
  let up = MemChannel::new("git-a", true)
  let ch : &@rp.OnlineChannel = up
  let crypto = @rp.RhopCrypto::from_key("k1")
  let sender = @rp.Session::new(
    @rp.Role::Send,
    Some(mem_view(mem)),
    [ch],
    None,
    Some(crypto),
    "dev-A",
  )
  let receiver = sender.reverse()
  assert_eq(receiver.role(), @rp.Role::Recv)
  assert_eq(receiver.name(), "dev-A")
  assert_true(receiver.has_crypto())
  assert_true(receiver.has_shared())
  assert_eq(receiver.online_count(), 1)
  // 再反一次回到发送端（同一个介质视图仍然可用）
  assert_eq(receiver.reverse().role(), @rp.Role::Send)
  // RELAY 无方向：reverse 后仍是 RELAY
  let relay = @rp.Session::new(@rp.Role::Relay, None, [], None, None, "")
  assert_eq(relay.reverse().role(), @rp.Role::Relay)
}

// ---------------------------------------------------------------------------
// 7. describe()
// ---------------------------------------------------------------------------

///|
test "session · describe 输出 vools 同形字段（不做介质探测）" {
  let mem = MemPath::new("share", true)
  let up = MemChannel::new("git-a", true)
  let down = MemChannel::new("sftp-b", false)
  let c1 : &@rp.OnlineChannel = up
  let c2 : &@rp.OnlineChannel = down
  let s = @rp.Session::new(
    @rp.Role::Recv,
    Some(mem_view(mem)),
    [c1, c2],
    Some(@rp.RelayChannel::new("127.0.0.1", 4321, None, 1000)),
    Some(@rp.RhopCrypto::from_key("k1")),
    "dev-B",
  )
  let d = s.describe()
  assert_eq(json_str_of(d, "name"), "dev-B")
  assert_eq(json_str_of(d, "role"), "RECV")
  assert_eq(json_str_of(d, "relay"), "http://127.0.0.1:4321")
  match json_field_of(d, "has_crypto") {
    Some(v) => assert_eq(Json::stringify(v), "true")
    None => fail("describe 缺 has_crypto")
  }
  match json_field_of(d, "online") {
    Some(Array(names)) => {
      assert_eq(names.length(), 2)
      assert_eq(Json::stringify(names[0]), "\"mem-channel:git-a\"")
      assert_eq(Json::stringify(names[1]), "\"mem-channel:sftp-b\"")
    }
    _ => fail("describe.online 应为字符串数组")
  }
  match json_field_of(d, "shared") {
    Some(String(name)) => assert_true(name.contains("mem:share"))
    _ => fail("describe.shared 应为字符串（单视图）")
  }
  // 空会话：shared/relay 为 null（对应 vools 的 None）
  let empty = @rp.Session::empty(@rp.Role::Send).describe()
  assert_eq(
    Json::stringify(empty),
    "{\"name\":\"session:send\",\"role\":\"SEND\",\"online\":[],\"shared\":null,\"relay\":null,\"has_crypto\":false}",
  )
}

// ---------------------------------------------------------------------------
// 10. 文件名白名单（C1-F2：防路径穿越）
// ---------------------------------------------------------------------------

///|
/// 带本地根的单侧介质：按 `exists(".") / exists("..")` 回答「根/父目录是否存在」。
///
/// 产品侧对已知根的介质用 `exists` 做**无副作用**探测（`available()` 会建目录，
/// 所以这里让 `available()` 恒 false —— 若产品仍依赖它，用例必然失败）。
struct RootedPath {
  files : Map[String, String]
  dot : Bool
  parent : Bool
  label : String
}

///|
fn RootedPath::new(label : String, dot : Bool, parent : Bool) -> RootedPath {
  { files: Map([]), dot, parent, label, }
}

///|
/// 故意恒 false：证明产品已不再用 available() 判本地根介质。
impl @rp.SharedPath for RootedPath with fn available(self) {
  false
}

///|
impl @rp.SharedPath for RootedPath with fn write_text(self, filename, content) {
  self.files[filename] = content
  Ok(())
}

///|
impl @rp.SharedPath for RootedPath with fn read_text(self, filename) {
  match self.files.get(filename) {
    Some(v) => Ok(v)
    None => Err("rhop: 读取失败: " + self.label + ": no such file")
  }
}

///|
impl @rp.SharedPath for RootedPath with fn exists(self, filename) {
  if filename == "." {
    self.dot
  } else if filename == ".." {
    self.parent
  } else {
    self.files.contains(filename)
  }
}

///|
impl @rp.SharedPath for RootedPath with fn remove(self, filename) {
  self.files.remove(filename)
  Ok(())
}

///|
impl @rp.SharedPath for RootedPath with fn name(self) {
  "rooted:" + self.label
}

///|
impl @rp.SharedPath for RootedPath with fn root(self) {
  Some("/mem/" + self.label)
}

///|
test "session · safe_filename：白名单放行，穿越/分隔符/空白/超长全部 Err" {
  assert_eq(@rp.safe_filename("req_jump_probe.rhop"), Ok("req_jump_probe.rhop"))
  assert_eq(@rp.safe_filename("a-b_c.9"), Ok("a-b_c.9"))
  for
    bad in [
      "../escaped.rhop", "..", "./x.rhop", "a/b.rhop", "a\\b.rhop", "C:\\x.rhop",
      "sub/../../x.rhop", "req a.rhop", "包.rhop",
    ] {
    match @rp.safe_filename(bad) {
      Ok(v) => abort("非法文件名不应通过: " + v)
      Err(e) => assert_true(e.length() > 0)
    }
  }
  match @rp.safe_filename("") {
    Ok(_) => abort("空文件名应当 Err")
    Err(e) => assert_true(e.contains("不能为空"))
  }
  // 长度边界：128 通过，129 拒绝
  let sb = StringBuilder()
  for i in 0..<128 {
    let _ = i
    sb.write_char('a')
  }
  let s128 = sb.to_string()
  assert_eq(@rp.safe_filename(s128), Ok(s128))
  match @rp.safe_filename(s128 + "a") {
    Ok(_) => abort("129 字符应当 Err")
    Err(e) => assert_true(e.contains("过长"))
  }
}

///|
test "session · send/recv 拒绝非法文件名且不触碰介质（C1-F2）" {
  let mem = MemPath::new("share", true)
  let s = @rp.Session::new(
    @rp.Role::Send,
    Some(mem_view(mem)),
    [],
    None,
    Some(@rp.RhopCrypto::from_key("k1")),
    "",
  )
  match s.send_package("../escaped.rhop", Json::object(Map([]))) {
    Ok(j) => abort("穿越文件名不应发送成功: " + Json::stringify(j))
    Err(e) => assert_true(e.contains("包文件名"))
  }
  match s.send_package("sub/dir.rhop", Json::object(Map([]))) {
    Ok(_) => abort("带分隔符的文件名不应发送成功")
    Err(e) => assert_true(e.contains("包文件名"))
  }
  // 介质上没有任何写入（连临时键都没落）
  let mut written = 0
  for k in mem.files.keys() {
    let _ = k
    written = written + 1
  }
  assert_eq(written, 0)
  // 接收侧同一规则
  match s.recv_package("../escaped.rhop") {
    Ok(_) => abort("穿越文件名不应读取成功")
    Err(e) => assert_true(e.contains("包文件名"))
  }
}

///|
test "session · shared 读/写分开判定：只读介质不被判全不可达，发给出专门 Err（C1-F5）" {
  let w = RootedPath::new("w", false, false)
  let r = RootedPath::new("r", true, false)
  let wp : &@rp.SharedPath = w
  let rp : &@rp.SharedPath = r
  let view = @rp.make_shared_path_from_views(wp, Some(rp))
  // 读端预置一个包（模拟对端写入）；本用例只验证「读端通路」，不验证解密结果，
  // 因此密文可以是任意串——wasm/native 下 RhopCrypto 无法解密，回执必然是
  // status:error，但**不能**是「读端不可用」的 Err。
  r.files["in.rhop"] = "dummy-token"
  let recv = @rp.Session::new(
    @rp.Role::Recv,
    Some(view),
    [],
    None,
    Some(@rp.RhopCrypto::from_key("k1")),
    "",
  )
  // 读端可用 → 会真的去读介质（旧实现要求写端可建目录，整条通道被判全不可达）
  match recv.recv_package("in.rhop") {
    Ok(j) => assert_true(!Json::stringify(j).contains("读端不可用"))
    Err(e) => abort("只读介质的读端应当可用，实际 Err: " + e)
  }
  // 读端可用 → 会话整体可用、并且选中 shared（旧实现会因写端建不了目录而判全不可达）
  assert_true(recv.available())
  assert_eq(recv.select().transport, "shared")
  // 写端不可用时的发送错误（含「写端不可用」专门文案）需要先过加密，
  // 非 js 目标 RhopCrypto 无法加密，因此该断言放在 js 端到端包 test-suit/rhop_interact。
}

///|
test "session · remove_package：删除读视图包；空名/无介质可诊断 Err（C1-F1）" {
  let mem = MemPath::new("share", true)
  let s = @rp.Session::new(
    @rp.Role::Send,
    Some(mem_view(mem)),
    [],
    None,
    Some(@rp.RhopCrypto::from_key("k1")),
    "",
  )
  mem.files["pkg.rhop"] = "cipher"
  assert_eq(s.remove_package("pkg.rhop"), Ok(()))
  assert_true(!mem.files.contains("pkg.rhop"))
  assert_eq(s.remove_package("pkg.rhop"), Ok(())) // 幂等
  match s.remove_package("") {
    Ok(_) => abort("空文件名应当 Err")
    Err(e) => assert_true(e.contains("包文件名不能为空"))
  }
  match s.remove_package("../x.rhop") {
    Ok(_) => abort("穿越名应当 Err")
    Err(e) => assert_true(e.contains("包文件名"))
  }
  let no_shared = @rp.Session::empty(@rp.Role::Send)
  match no_shared.remove_package("a.rhop") {
    Ok(_) => abort("无介质应当 Err")
    Err(e) => assert_true(e.contains("仅 shared path"))
  }
}
