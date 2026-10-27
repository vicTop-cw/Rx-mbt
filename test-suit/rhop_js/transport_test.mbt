// ============================================================================
// rhop · 介质层测试（js 目标）
//
// 覆盖：
//   1. LocalSharedPath：写读往返 / 覆盖写 / 缺失读 Err / exists / remove 幂等 /
//      原子写不留 .tmp / 路径统一 "/"
//   2. 路径工具：normalize_path / join_shared
//   3. make_shared_path：单 spec（读=写）、双 spec（写本地、读 file://）、非法 spec Err
//   4. parse_endpoint：裸路径 / file:// / http(s):// 三态 + 空串/未知协议 Err
//   5. file_url_to_path：三种 URL 形态
//   6. select_transport：在线优先 / 离线回退 / 全不可达（可诊断 reason）矩阵
//   7. HttpEndpoint：不可达时 available=false、URL 编码、parse 分类
// ============================================================================

// ---------------------------------------------------------------------------
// 测试用 JS 辅助
// ---------------------------------------------------------------------------

///|
extern "js" fn ffi_t_mkdtemp(prefix : String) -> String =
  #| (prefix) => { try { const fs = process.getBuiltinModule("node:fs"); const os = process.getBuiltinModule("node:os"); const path = process.getBuiltinModule("node:path"); return fs.mkdtempSync(path.join(os.tmpdir(), String(prefix) + "-")); } catch (_e) { return ""; } }

///|
extern "js" fn ffi_t_exists(p : String) -> Bool =
  #| (p) => { try { return process.getBuiltinModule("node:fs").existsSync(String(p)); } catch (_e) { return false; } }

///|
extern "js" fn ffi_t_list(p : String) -> String =
  #| (p) => { try { const fs = process.getBuiltinModule("node:fs"); return JSON.stringify(fs.readdirSync(String(p))); } catch (_e) { return "[]"; } }

// ---------------------------------------------------------------------------
// 测试用 mock（实现本包 trait，验证选择逻辑与降级）
// ---------------------------------------------------------------------------

///|
/// mock 在线通道：up=true 表示可用。MoonBit 不支持分组 impl 体，
/// 每个 trait 方法单独一条 `impl ... with fn`。
struct MockChannel {
  up : Bool
  id : String
}

///|
/// 构造 mock 通道。
fn MockChannel::new(up : Bool, id : String) -> MockChannel {
  { up, id, }
}

///|
/// mock 通道：可用性由 up 决定。
impl @rp.OnlineChannel for MockChannel with fn available(self) {
  self.up
}

///|
/// mock 通道：只在 up 时"发送成功"。
impl @rp.OnlineChannel for MockChannel with fn send(self, filename, content) {
  if self.up {
    Ok(())
  } else {
    Err("mock down")
  }
}

///|
/// mock 通道：只在 up 时"收到"。
impl @rp.OnlineChannel for MockChannel with fn receive(self, filename) {
  if self.up {
    Ok("payload-of-" + filename)
  } else {
    Err("mock down")
  }
}

///|
/// mock 通道名字。
impl @rp.OnlineChannel for MockChannel with fn name(self) {
  self.id
}

///|
/// 恒不可达的 shared path（验证「全不可达」分支）。
struct DeadPath {
  tag : String
}

///|
/// 构造（无可达介质）。
fn DeadPath::new() -> DeadPath {
  { tag: "dead", }
}

///|
/// 恒不可达。
impl @rp.SharedPath for DeadPath with fn available(self) {
  false
}

///|
/// 恒失败。
impl @rp.SharedPath for DeadPath with fn write_text(self, filename, content) {
  Err("dead path")
}

///|
/// 恒失败。
impl @rp.SharedPath for DeadPath with fn read_text(self, filename) {
  Err("dead path")
}

///|
/// 恒不存在。
impl @rp.SharedPath for DeadPath with fn exists(self, filename) {
  false
}

///|
/// 删除视为幂等成功。
impl @rp.SharedPath for DeadPath with fn remove(self, filename) {
  Ok(())
}

///|
/// 名字里带上不可达标记，便于断言 reason。
impl @rp.SharedPath for DeadPath with fn name(self) {
  "dead:/nonexistent-mount"
}

///|
/// 无本地根。
impl @rp.SharedPath for DeadPath with fn root(self) {
  None
}

// ---------------------------------------------------------------------------
// 1. LocalSharedPath
// ---------------------------------------------------------------------------

///|
test "transport · LocalSharedPath 写读往返与覆盖写" {
  let dir = ffi_t_mkdtemp("rhop-t1")
  assert_true(dir != "")
  let sp : &@rp.SharedPath = @rp.LocalSharedPath::new(dir)
  assert_true(@rp.SharedPath::available(sp))
  // 写 → 读
  assert_eq(@rp.SharedPath::write_text(sp, "a.rhop", "hello 你好"), Ok(()))
  assert_eq(@rp.SharedPath::read_text(sp, "a.rhop"), Ok("hello 你好"))
  assert_true(@rp.SharedPath::exists(sp, "a.rhop"))
  // 覆盖写
  assert_eq(@rp.SharedPath::write_text(sp, "a.rhop", "second"), Ok(()))
  assert_eq(@rp.SharedPath::read_text(sp, "a.rhop"), Ok("second"))
  // name / root
  assert_true(@rp.SharedPath::name(sp).has_prefix("local:"))
  assert_true(@rp.SharedPath::root(sp) is Some(_))
  assert_eq(@rp.SharedPath::remove(sp, "a.rhop"), Ok(()))
  assert_false(@rp.SharedPath::exists(sp, "a.rhop"))
}

///|
test "transport · 原子写不留 .tmp；缺失读返回可诊断 Err；remove 幂等" {
  let dir = ffi_t_mkdtemp("rhop-t2")
  let sp : &@rp.SharedPath = @rp.LocalSharedPath::new(dir)
  assert_eq(@rp.SharedPath::write_text(sp, "b.rhop", "x"), Ok(()))
  // 目录里只应有 b.rhop，不应残留 b.rhop.tmp
  let names = ffi_t_list(dir)
  assert_true(names.contains("b.rhop"))
  assert_false(names.contains(".tmp"))
  // 缺失读
  match @rp.SharedPath::read_text(sp, "missing.rhop") {
    Err(e) => {
      assert_true(e.contains("读取失败"))
      assert_true(e.contains("missing.rhop"))
    }
    Ok(_) => fail("缺失文件应当返回 Err")
  }
  // remove 不存在 = 幂等成功
  assert_eq(@rp.SharedPath::remove(sp, "never-existed.rhop"), Ok(()))
}

///|
test "transport · 路径工具：normalize_path 与 join_shared 统一 \"/\"" {
  assert_eq(@rp.normalize_path("a\\b\\c"), "a/b/c")
  assert_eq(@rp.normalize_path("a//b///c"), "a/b/c")
  assert_eq(@rp.normalize_path("E:\\x\\y\\"), "E:/x/y")
  assert_eq(@rp.join_shared("/root", "f.rhop"), "/root/f.rhop")
  assert_eq(@rp.join_shared("/root/", "f.rhop"), "/root/f.rhop")
  assert_eq(@rp.join_shared("/root", "/f.rhop"), "/root/f.rhop")
  assert_eq(@rp.join_shared("", "f.rhop"), "f.rhop")
}

///|
test "transport · 子目录文件名也能原子写（自动建目录）" {
  let dir = ffi_t_mkdtemp("rhop-t3")
  let sp : &@rp.SharedPath = @rp.LocalSharedPath::new(dir)
  assert_eq(@rp.SharedPath::write_text(sp, "sub/c.rhop", "nested"), Ok(()))
  assert_eq(@rp.SharedPath::read_text(sp, "sub/c.rhop"), Ok("nested"))
}

// ---------------------------------------------------------------------------
// 2. make_shared_path / parse_endpoint
// ---------------------------------------------------------------------------

///|
test "transport · make_shared_path 单 spec（读=写）" {
  let dir = ffi_t_mkdtemp("rhop-t4")
  match @rp.make_shared_path(dir, None) {
    Ok(view) => {
      let sp : &@rp.SharedPath = view
      assert_eq(@rp.SharedPath::write_text(sp, "d.rhop", "single"), Ok(()))
      assert_eq(@rp.SharedPath::read_text(sp, "d.rhop"), Ok("single"))
      assert_true(@rp.SharedPath::available(sp))
      // 读视图名字应与写视图一致（单 spec 语义）
      assert_eq(view.write_name(), view.read_name())
      assert_true(@rp.SharedPath::name(sp).contains("->"))
    }
    Err(e) => fail("make_shared_path 单 spec 失败: \{e}")
  }
}

///|
test "transport · make_shared_path 双 spec（A 写本地、B 读 file:// 同一介质）" {
  let dir = ffi_t_mkdtemp("rhop-t5")
  let file_url = "file:///" + @rp.normalize_path(dir)
  match @rp.make_shared_path(dir, Some(file_url)) {
    Ok(view) => {
      let sp : &@rp.SharedPath = view
      // 写走本地视图
      assert_eq(@rp.SharedPath::write_text(sp, "e.rhop", "cross-view"), Ok(()))
      // 读走 file:// 视图（同一物理目录）
      assert_eq(@rp.SharedPath::read_text(sp, "e.rhop"), Ok("cross-view"))
      assert_true(@rp.SharedPath::exists(sp, "e.rhop"))
      // 两个视图名字不同（写 local:、读 file-url:）
      assert_true(view.write_name().has_prefix("shared:local:"))
      assert_true(view.read_name().contains("file-url"))
    }
    Err(e) => fail("make_shared_path 双 spec 失败: \{e}")
  }
}

///|
test "transport · make_shared_path 非法 spec 返回可诊断 Err" {
  match @rp.make_shared_path("", None) {
    Err(e) => assert_true(e.contains("不能为空"))
    Ok(_) => fail("空 spec 应当 Err")
  }
  match @rp.make_shared_path("/ok", Some("ftp://host/share")) {
    Err(e) => assert_true(e.contains("不支持的 endpoint 协议"))
    Ok(_) => fail("未知协议应当 Err")
  }
}

///|
test "transport · parse_endpoint 三态分类" {
  // 裸路径 → local
  match @rp.parse_endpoint("./some/relative/dir") {
    Ok(v) => {
      assert_eq(@rp.EndpointView::kind(v), "local")
      assert_true(@rp.EndpointView::name(v).contains("some/relative/dir"))
    }
    Err(e) => fail("裸路径解析失败: \{e}")
  }
  // file:// → file-url
  match @rp.parse_endpoint("file:///tmp/rhop-share") {
    Ok(v) => assert_eq(@rp.EndpointView::kind(v), "file-url")
    Err(e) => fail("file:// 解析失败: \{e}")
  }
  // http:// → http-url
  match @rp.parse_endpoint("http://127.0.0.1:9/share") {
    Ok(v) => {
      assert_eq(@rp.EndpointView::kind(v), "http-url")
      assert_true(@rp.EndpointView::name(v).has_suffix("/"))
    }
    Err(e) => fail("http:// 解析失败: \{e}")
  }
  // https:// → http-url
  match @rp.parse_endpoint("https://example.invalid/share") {
    Ok(v) => assert_eq(@rp.EndpointView::kind(v), "http-url")
    Err(e) => fail("https:// 解析失败: \{e}")
  }
  // 空 / 未知协议 → Err
  match @rp.parse_endpoint("   ") {
    Err(e) => assert_true(e.contains("不能为空"))
    Ok(_) => fail("空白 spec 应当 Err")
  }
  match @rp.parse_endpoint("ftp://h/s") {
    Err(e) => assert_true(e.contains("不支持的 endpoint 协议"))
    Ok(_) => fail("ftp 应当 Err")
  }
}

///|
test "transport · file_url_to_path 三种形态" {
  // file:///abs/path（Windows 下 /E:/x → E:/x）
  assert_eq(@rp.file_url_to_path("file:///tmp/rhop"), Ok("/tmp/rhop"))
  assert_eq(@rp.file_url_to_path("file:///E:/tmp/rhop"), Ok("E:/tmp/rhop"))
  // file://C:/path（盘符进了 authority 段）
  assert_eq(@rp.file_url_to_path("file://C:/tmp/rhop"), Ok("C:/tmp/rhop"))
  // 百分号编码
  assert_eq(@rp.file_url_to_path("file:///tmp/a%20b"), Ok("/tmp/a b"))
  // 缺路径 → Err
  match @rp.file_url_to_path("file://") {
    Err(e) => assert_true(e.contains("缺少路径"))
    Ok(_) => fail("file:// 无路径应当 Err")
  }
}

// ---------------------------------------------------------------------------
// 3. select_transport 矩阵
// ---------------------------------------------------------------------------

///|
test "transport · select_transport：在线可用则优先选在线" {
  let up : &@rp.OnlineChannel = MockChannel::new(true, "mock-git")
  let down : &@rp.OnlineChannel = MockChannel::new(false, "mock-sftp")
  let dir = ffi_t_mkdtemp("rhop-t6")
  let sp : &@rp.SharedPath = @rp.LocalSharedPath::new(dir)
  let sel = @rp.select_transport([down, up], Some(sp))
  assert_true(sel.is_online)
  assert_eq(sel.transport, "online")
  assert_eq(sel.label, "mock-git")
  assert_true(sel.reason.contains("在线通道可用"))
}

///|
test "transport · select_transport：在线全不可用则回退 shared path" {
  let down1 : &@rp.OnlineChannel = MockChannel::new(false, "mock-git")
  let down2 : &@rp.OnlineChannel = MockChannel::new(false, "mock-sftp")
  let dir = ffi_t_mkdtemp("rhop-t7")
  let sp : &@rp.SharedPath = @rp.LocalSharedPath::new(dir)
  let sel = @rp.select_transport([down1, down2], Some(sp))
  assert_false(sel.is_online)
  assert_eq(sel.transport, "shared")
  assert_true(sel.label.has_prefix("local:"))
  assert_true(sel.reason.contains("回退 shared path"))
  // 探测记录里两条通道都应有痕迹
  assert_true(sel.reason.contains("mock-git=down"))
  assert_true(sel.reason.contains("mock-sftp=down"))
}

///|
test "transport · select_transport：全不可达时给出可诊断 reason" {
  let down : &@rp.OnlineChannel = MockChannel::new(false, "mock-git")
  let dead : &@rp.SharedPath = DeadPath::new()
  let sel = @rp.select_transport([down], Some(dead))
  assert_false(sel.is_online)
  assert_eq(sel.transport, "none")
  assert_true(sel.reason.contains("不可达"))
  assert_true(sel.reason.contains("dead:/nonexistent-mount"))
}

///|
test "transport · select_transport：没有在线通道也没有 shared path" {
  let sel = @rp.select_transport([], None)
  assert_eq(sel.transport, "none")
  assert_true(sel.reason.contains("没有在线通道"))
  // 零通道数组时的探测记录文案
  assert_true(sel.reason.contains("(无在线通道)"))
}

///|
test "transport · select_transport 结果可序列化为 JSON" {
  let up : &@rp.OnlineChannel = MockChannel::new(true, "mock-x")
  let sel = @rp.select_transport([up], None)
  let j = @rp.TransportSelection::to_json(sel)
  assert_eq(
    Json::stringify(j),
    "{\"transport\":\"online\",\"label\":\"mock-x\",\"is_online\":true,\"reason\":\"在线通道可用: mock-x\"}",
  )
}

// ---------------------------------------------------------------------------
// 4. HttpEndpoint（不可达降级 + URL 构造）
// ---------------------------------------------------------------------------

///|
test "transport · HttpEndpoint 不可达时 available=false（不崩溃）" {
  // 端口 1 基本不会有人监听；短超时保证测试快
  let ep = @rp.HttpEndpoint::new("http://127.0.0.1:1/share", None, 500)
  assert_false(@rp.EndpointView::available(ep))
  assert_eq(@rp.EndpointView::kind(ep), "http-url")
  assert_false(@rp.EndpointView::exists(ep, "x.rhop"))
  match @rp.EndpointView::read_text(ep, "x.rhop") {
    Err(e) => assert_true(e.contains("http"))
    Ok(_) => fail("不可达服务读应当 Err")
  }
}

///|
test "transport · HttpEndpoint URL 构造与文件名编码" {
  let ep = @rp.HttpEndpoint::new("http://host:8080/share/", None, 1000)
  assert_eq(ep.base(), "http://host:8080/share/")
  // 文件名整体 URL 编码（防路径穿越 / 空格）
  assert_eq(ep.url_of("a b.rhop"), "http://host:8080/share/a%20b.rhop")
  assert_eq(ep.url_of("pkg-1.rhop"), "http://host:8080/share/pkg-1.rhop")
  // 斜杠与点都被编码，不再是路径分隔
  let evil = ep.url_of("../evil")
  assert_false(evil.has_suffix("../evil"))
  assert_true(evil.contains("%2F"))
  // 编解码可逆
  assert_eq(
    @rp.uri_decode(@rp.uri_encode("中文 文件.rhop")),
    "中文 文件.rhop",
  )
}
