// ============================================================================
// rhop · 传输抽象（SharedPath / OnlineChannel / TransportSelection / 多端视图）
//
// 对照 vools.rhop.transport.base + transport.shared：
//   SharedPath     —— 双方共同可达的介质（本地目录 / 挂载盘 / 中间方共享区）
//   OnlineChannel  —— 有网时的首选通道（Git / SFTP / 自建中转）
//   在线优先、离线回退 shared path 的选择逻辑见 transport_selector.mbt
//
// MoonBit 用 `&Trait` 对象表达（参考 core 的 `let logger : &Logger = sb`）：
//   let p : &SharedPath = LocalSharedPath::new(root)
//   调用用 `SharedPath::write_text(p, name, content)` 显式形态（避免多 trait 同名歧义）。
//
// 目标说明：抽象层本身三目标通用；具体实现的可达性由各自 available() 表达。
// ============================================================================

///|
/// shared path 介质抽象：发送方写、接收方读的共同可达位置。
///
/// 实现要求：`write_text` 建议原子写（先写 <name>.tmp 再 rename），
/// `read_text` 在文件不存在时返回可诊断 Err。
pub(open) trait SharedPath {
  /// 介质当前是否可达（必要时可自行创建目录）
  fn available(Self) -> Bool
  /// 写入文本（filename, content）；建议原子写
  fn write_text(Self, String, String) -> Result[Unit, String]
  /// 读取文本；不存在时返回 Err
  fn read_text(Self, String) -> Result[String, String]
  /// 判断文件名是否存在
  fn exists(Self, String) -> Bool
  /// 删除文件（不存在视为成功，幂等）
  fn remove(Self, String) -> Result[Unit, String]
  /// 介质名（如 "local:<dir>"），用于选择理由与日志
  fn name(Self) -> String
  /// 介质根（本地形态给目录；远端/HTTP 形态可给 None）
  fn root(Self) -> String?
}

///|
/// 在线通道抽象：有网时的首选传输方式。
pub(open) trait OnlineChannel {
  /// 探测通道是否可用（如远端可达）
  fn available(Self) -> Bool
  /// 把一包内容发到远端（filename, content）
  fn send(Self, String, String) -> Result[Unit, String]
  /// 从远端取一包内容；不存在时返回可诊断 Err
  fn receive(Self, String) -> Result[String, String]
  /// 通道名（如 "relay:http://127.0.0.1:8080"）
  fn name(Self) -> String
}

///|
/// 通道选择结果（对照 vools TransportSelection；transport 用字符串标签而非裸对象，
/// 便于跨目标序列化与日志）。
pub struct TransportSelection {
  /// 实际使用的通道类别："online" / "shared" / "none"
  transport : String
  /// 被选中对象的名字（OnlineChannel::name 或 SharedPath::name）
  label : String
  /// true=在线通道 / false=回退 shared path
  is_online : Bool
  /// 选择说明（可诊断）
  reason : String
}

///|
/// 构造选择结果。
pub fn TransportSelection::new(
  transport : String,
  label : String,
  is_online : Bool,
  reason : String,
) -> TransportSelection {
  { transport, label, is_online, reason, }
}

///|
/// 序列化为 JSON（session / config 层要把它写进回执）。
pub fn TransportSelection::to_json(self : TransportSelection) -> Json {
  Json::object({
    "transport": Json::string(self.transport),
    "label": Json::string(self.label),
    "is_online": Json::boolean(self.is_online),
    "reason": Json::string(self.reason),
  })
}

///|
/// 便于日志与断言的文本形态。
pub fn TransportSelection::to_string(self : TransportSelection) -> String {
  "TransportSelection(transport=\{self.transport}, label=\{self.label}, is_online=\{self.is_online}, reason=\{self.reason})"
}

///|
/// 把端视图（EndpointView）适配成 SharedPath，使 `make_shared_path` 能返回统一的
/// 读写双视图。
pub struct EndpointSharedPath {
  view : &EndpointView
}

///|
/// 用端视图构造适配器。
pub fn EndpointSharedPath::new(view : &EndpointView) -> EndpointSharedPath {
  { view, }
}

///|
pub impl SharedPath for EndpointSharedPath with fn available(self) {
  EndpointView::available(self.view)
}

///|
pub impl SharedPath for EndpointSharedPath with fn write_text(
  self,
  filename,
  content,
) {
  match EndpointView::write_text(self.view, filename, content) {
    Ok(_) => Ok(())
    Err(e) => Err(e)
  }
}

///|
pub impl SharedPath for EndpointSharedPath with fn read_text(self, filename) {
  EndpointView::read_text(self.view, filename)
}

///|
pub impl SharedPath for EndpointSharedPath with fn exists(self, filename) {
  EndpointView::exists(self.view, filename)
}

///|
pub impl SharedPath for EndpointSharedPath with fn remove(self, filename) {
  EndpointView::remove(self.view, filename)
}

///|
pub impl SharedPath for EndpointSharedPath with fn name(self) {
  "shared:" +
  EndpointView::kind(self.view) +
  ":" +
  EndpointView::name(self.view)
}

///|
pub impl SharedPath for EndpointSharedPath with fn root(self) {
  None
}

///|
/// 多端视图 shared path：同一介质在「写方」与「读方」眼里地址形态不同。
///
/// 典型：A 侧写本地目录 `<share_dir>`，B 侧读 `file:///<share_dir>`；
/// 或 A 侧写盘符 `X:/share`，B 侧读 UNC `//NAS/share`。
///
/// 与契约草案的差异（已回报）：草案写 `write_view/read_view : &SharedPath?`，
/// 这里改成非 Option —— 解析失败在 `make_shared_path` 里已经返回 Err，
/// 结构体内再留一个永不为 None 的可选值是噪音。
pub struct SharedPathView {
  write_view : &SharedPath
  read_view : &SharedPath
}

///|
/// 写视图 / 读视图各自的名字（便于日志）。
pub fn SharedPathView::write_name(self : SharedPathView) -> String {
  SharedPath::name(self.write_view)
}

///|
/// 读视图名字。
pub fn SharedPathView::read_name(self : SharedPathView) -> String {
  SharedPath::name(self.read_view)
}

///|
pub impl SharedPath for SharedPathView with fn available(self) {
  SharedPath::available(self.write_view) &&
  SharedPath::available(self.read_view)
}

///|
pub impl SharedPath for SharedPathView with fn write_text(
  self,
  filename,
  content,
) {
  SharedPath::write_text(self.write_view, filename, content)
}

///|
pub impl SharedPath for SharedPathView with fn read_text(self, filename) {
  SharedPath::read_text(self.read_view, filename)
}

///|
pub impl SharedPath for SharedPathView with fn exists(self, filename) {
  SharedPath::exists(self.read_view, filename)
}

///|
pub impl SharedPath for SharedPathView with fn remove(self, filename) {
  SharedPath::remove(self.read_view, filename)
}

///|
pub impl SharedPath for SharedPathView with fn name(self) {
  "shared:\{SharedPath::name(self.write_view)}->\{SharedPath::name(self.read_view)}"
}

///|
pub impl SharedPath for SharedPathView with fn root(self) {
  // 兼容旧 API：读端视图的本地根（供 monitor 监控用）
  match SharedPath::root(self.read_view) {
    Some(r) => Some(r)
    None => SharedPath::root(self.write_view)
  }
}

///|
/// 由「写端地址 + 读端地址」构造 shared path（对照 vools `make_shared_path`）。
///
/// - 地址形态：裸路径 / 相对路径 / `file://` URL / `http(s)://` URL；
/// - `read_spec` 为空或与 `write_spec` 相同 ⇒ 读写同视图（单 spec 语义）；
/// - 任一 spec 非法 ⇒ Err（中文可诊断）。
pub fn make_shared_path(
  write_spec : String,
  read_spec : String?,
) -> Result[SharedPathView, String] {
  let w = match parse_endpoint(write_spec) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let r = match read_spec {
    None => w
    Some(spec) =>
      if spec.trim().to_owned() == "" ||
        spec.trim().to_owned() == write_spec.trim().to_owned() {
        w
      } else {
        match parse_endpoint(spec) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
      }
  }
  let w_sp : &SharedPath = EndpointSharedPath::new(w)
  let r_sp : &SharedPath = EndpointSharedPath::new(r)
  Ok({ write_view: w_sp, read_view: r_sp, })
}

///|
/// 由已有的 SharedPath 对象直接构造多端视图（测试与上层复用更方便）。
/// `read` 为 None 时读=写。
pub fn make_shared_path_from_views(
  write : &SharedPath,
  read : &SharedPath?,
) -> SharedPathView {
  let r = match read {
    Some(r) => r
    None => write
  }
  { write_view: write, read_view: r, }
}
