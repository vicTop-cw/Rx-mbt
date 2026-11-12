// ============================================================================
// rhop · 端视图（同一介质在不同方眼中的地址形态）
//
// 对照 vools.rhop.transport.endpoint：
//   A 侧 本地目录      <share_dir>
//   B 侧 file:// URL   file:///<share_dir>（本地介质，不联网）
//   C 侧 http(s)://    本地/局域网文件服务（WebDAV 风格 PUT/GET/DELETE）
//
// 要点：**URL 形态 ≠ 联网**。file:// 与 http(s):// 都属 shared path 兜底层，
// 不参与「在线优先」判定（在线优先只针对 OnlineChannel：Git / SFTP / 自建中转）。
//
// 目标说明：LocalEndpoint / FileUrlEndpoint 走 node:fs，HttpEndpoint 走 node:http；
// 三者都仅 js 目标可用，wasm/native 返回可诊断 Err（available()=false）。
//
// 同步 HTTP 的工程决策（重要）：node 的 http 客户端是纯异步回调制，而本包对外
// API 是同步 `Result`（与 vools 一致）。因此在主进程里 `await` 不可行、
// 用 Atomics.wait 阻塞主线程会让同进程的 HTTP 服务端也停摆（事件循环被占）。
// 故本实现把请求交给**子进程**执行（`node -e <script>` + stdin 传参），
// 子进程用真正的 node:http 发请求并回 JSON —— 对外保持同步语义，内里仍是 node:http。
// ============================================================================

///|
/// 介质的一个端视图：描述某一方如何访问 shared path。
pub(open) trait EndpointView {
  /// 视图形态："local" / "file-url" / "http-url"
  fn kind(Self) -> String
  /// 人类可读的地址描述（本地为绝对路径，URL 形态为原 URL）
  fn name(Self) -> String
  /// 该视图当前是否可达（可写或可读）
  fn available(Self) -> Bool
  /// 判断文件名是否存在
  fn exists(Self, String) -> Bool
  /// 读取文本；不存在抛 Err
  fn read_text(Self, String) -> Result[String, String]
  /// 写入文本，返回定位标识（路径或 URL）
  fn write_text(Self, String, String) -> Result[String, String]
  /// 删除文件；不存在返回 Ok（幂等）
  fn remove(Self, String) -> Result[Unit, String]
}

// ---------------------------------------------------------------------------
// 1) 本地路径视图（普通目录 / UNC / 网络盘符对进程即普通路径）
// ---------------------------------------------------------------------------

///|
/// 本地路径视图。委托 `LocalSharedPath` 完成原子写与读删（同一实现，避免双份）。
pub struct LocalEndpoint {
  sp : LocalSharedPath
}

///|
/// 以本地路径构造（相对路径按进程 cwd 解析成绝对路径）。
pub fn LocalEndpoint::new(path : String) -> LocalEndpoint {
  { sp: LocalSharedPath::new(path), }
}

///|
/// 归一化后的本地绝对路径。
pub fn LocalEndpoint::path(self : LocalEndpoint) -> String {
  self.sp.root
}

///|
///|
pub extend LocalEndpoint with EndpointView::{kind, name, available, exists, read_text, write_text, remove}

pub impl EndpointView for LocalEndpoint with fn kind(self) {
  "local"
}

///|
pub impl EndpointView for LocalEndpoint with fn name(self) {
  self.sp.root
}

///|
pub impl EndpointView for LocalEndpoint with fn available(self) {
  SharedPath::available(self.sp)
}

///|
pub impl EndpointView for LocalEndpoint with fn exists(self, filename) {
  SharedPath::exists(self.sp, filename)
}

///|
pub impl EndpointView for LocalEndpoint with fn read_text(self, filename) {
  SharedPath::read_text(self.sp, filename)
}

///|
pub impl EndpointView for LocalEndpoint with fn write_text(
  self,
  filename,
  content,
) {
  match SharedPath::write_text(self.sp, filename, content) {
    Ok(_) => Ok(join_shared(self.sp.root, filename))
    Err(e) => Err(e)
  }
}

///|
pub impl EndpointView for LocalEndpoint with fn remove(self, filename) {
  SharedPath::remove(self.sp, filename)
}

///|
///|
pub extend LocalEndpoint with SharedPath::{root}

pub impl SharedPath for LocalEndpoint with fn available(self) {
  SharedPath::available(self.sp)
}

///|
pub impl SharedPath for LocalEndpoint with fn write_text(
  self,
  filename,
  content,
) {
  SharedPath::write_text(self.sp, filename, content)
}

///|
pub impl SharedPath for LocalEndpoint with fn read_text(self, filename) {
  SharedPath::read_text(self.sp, filename)
}

///|
pub impl SharedPath for LocalEndpoint with fn exists(self, filename) {
  SharedPath::exists(self.sp, filename)
}

///|
pub impl SharedPath for LocalEndpoint with fn remove(self, filename) {
  SharedPath::remove(self.sp, filename)
}

///|
pub impl SharedPath for LocalEndpoint with fn name(self) {
  "local:" + self.sp.root
}

///|
pub impl SharedPath for LocalEndpoint with fn root(self) {
  Some(self.sp.root)
}

// ---------------------------------------------------------------------------
// 2) file:// URL 视图（解析为本地路径，不联网）
// ---------------------------------------------------------------------------

///|
/// `file://` URL 视图：解析成本地路径后完全按本地介质处理。
pub struct FileUrlEndpoint {
  url : String
  sp : LocalSharedPath
}

///|
/// 解析 `file://` URL（支持 `file:///abs/path`、`file://C:/path`、`file://server/share`）。
///
/// 非 `file://` 前缀返回可诊断 Err。
pub fn FileUrlEndpoint::new(url : String) -> Result[FileUrlEndpoint, String] {
  let u = url.trim().to_owned()
  if !is_file_url(u) {
    return Err("FileUrlEndpoint 仅接受 file:// URL: \{u}")
  }
  let path = match file_url_to_path(u) {
    Ok(p) => p
    Err(e) => return Err(e)
  }
  Ok({ url: u, sp: LocalSharedPath::new(path), })
}

///|
/// 原始 URL。
pub fn FileUrlEndpoint::url(self : FileUrlEndpoint) -> String {
  self.url
}

///|
///|
pub extend FileUrlEndpoint with EndpointView::{kind, name, available, exists, read_text, write_text, remove}

pub impl EndpointView for FileUrlEndpoint with fn kind(self) {
  "file-url"
}

///|
pub impl EndpointView for FileUrlEndpoint with fn name(self) {
  self.url
}

///|
pub impl EndpointView for FileUrlEndpoint with fn available(self) {
  SharedPath::available(self.sp)
}

///|
pub impl EndpointView for FileUrlEndpoint with fn exists(self, filename) {
  SharedPath::exists(self.sp, filename)
}

///|
pub impl EndpointView for FileUrlEndpoint with fn read_text(self, filename) {
  SharedPath::read_text(self.sp, filename)
}

///|
pub impl EndpointView for FileUrlEndpoint with fn write_text(
  self,
  filename,
  content,
) {
  match SharedPath::write_text(self.sp, filename, content) {
    Ok(_) => Ok(join_shared(self.sp.root, filename))
    Err(e) => Err(e)
  }
}

///|
pub impl EndpointView for FileUrlEndpoint with fn remove(self, filename) {
  SharedPath::remove(self.sp, filename)
}

///|
///|
pub extend FileUrlEndpoint with SharedPath::{root}

pub impl SharedPath for FileUrlEndpoint with fn available(self) {
  SharedPath::available(self.sp)
}

///|
pub impl SharedPath for FileUrlEndpoint with fn write_text(
  self,
  filename,
  content,
) {
  SharedPath::write_text(self.sp, filename, content)
}

///|
pub impl SharedPath for FileUrlEndpoint with fn read_text(self, filename) {
  SharedPath::read_text(self.sp, filename)
}

///|
pub impl SharedPath for FileUrlEndpoint with fn exists(self, filename) {
  SharedPath::exists(self.sp, filename)
}

///|
pub impl SharedPath for FileUrlEndpoint with fn remove(self, filename) {
  SharedPath::remove(self.sp, filename)
}

///|
pub impl SharedPath for FileUrlEndpoint with fn name(self) {
  "file-url:" + self.url
}

///|
pub impl SharedPath for FileUrlEndpoint with fn root(self) {
  Some(self.sp.root)
}

// ---------------------------------------------------------------------------
// 3) http(s):// 视图（本地/局域网文件服务；WebDAV 风格）
// ---------------------------------------------------------------------------

///|
/// HTTP(S) 文件服务视图（PUT/GET/DELETE 语义）。
///
/// 仅 js 目标可用：内部经子进程 node:http 发请求（见文件头「同步 HTTP 的工程决策」）。
pub struct HttpEndpoint {
  base_url : String
  token : String?
  timeout_ms : Int32
}

///|
/// 构造 HTTP 端视图。`base_url` 末尾斜杠会被规范成恰好一个。
pub fn HttpEndpoint::new(
  base_url : String,
  token : String?,
  timeout_ms : Int32,
) -> HttpEndpoint {
  let mut u = base_url.trim().to_owned()
  while u.has_suffix("/") && u.length() > 1 {
    u = match u.get_view(start=0, end=u.length() - 1) {
      Some(v) => v.to_owned()
      None => u
    }
  }
  { base_url: u + "/", token, timeout_ms, }
}

///|
/// 规范后的基地址（末尾一个斜杠）。
pub fn HttpEndpoint::base(self : HttpEndpoint) -> String {
  self.base_url
}

///|
///|
pub extend HttpEndpoint with EndpointView::{kind, name, available, exists, read_text, write_text, remove}

pub impl EndpointView for HttpEndpoint with fn kind(self) {
  "http-url"
}

///|
pub impl EndpointView for HttpEndpoint with fn name(self) {
  self.base_url
}

///|
pub impl EndpointView for HttpEndpoint with fn available(self) {
  // 服务可达即视为可用（200 或 404 都算「服务在」）
  match http_request("GET", self.base_url, self.token, "", self.timeout_ms) {
    Ok(resp) => resp.status == 200 || resp.status == 404
    Err(_) => false
  }
}

///|
pub impl EndpointView for HttpEndpoint with fn exists(self, filename) {
  match
    http_request("GET", self.url_of(filename), self.token, "", self.timeout_ms) {
    Ok(resp) => resp.status == 200
    Err(_) => false
  }
}

///|
/// 非破坏性读取（与 vools 一致）：这里是普通 GET，读后不删除远端对象；
/// 删除是独立的 remove()（DELETE）。因此 http 端点不是 relay 那种「取走即删」语义，
/// at-most-once / 去重需要上层自己做幂等（C4 审计结论，vools HttpEndpoint 同此语义）。
pub impl EndpointView for HttpEndpoint with fn read_text(self, filename) {
  let u = self.url_of(filename)
  match http_request("GET", u, self.token, "", self.timeout_ms) {
    Err(e) => Err("rhop: http unreachable: \{u}: \{e}")
    Ok(resp) =>
      if resp.status == 200 {
        Ok(resp.body)
      } else if resp.status == 404 {
        Err("rhop: http endpoint 无文件 \{filename}")
      } else {
        Err("rhop: http GET failed: status=\{resp.status}")
      }
  }
}

///|
pub impl EndpointView for HttpEndpoint with fn write_text(
  self,
  filename,
  content,
) {
  let u = self.url_of(filename)
  match http_request("PUT", u, self.token, content, self.timeout_ms) {
    Err(e) => Err("rhop: http unreachable: \{u}: \{e}")
    Ok(resp) =>
      if resp.status == 200 || resp.status == 201 {
        Ok(u)
      } else {
        Err("rhop: http PUT failed: status=\{resp.status}")
      }
  }
}

///|
pub impl EndpointView for HttpEndpoint with fn remove(self, filename) {
  let u = self.url_of(filename)
  match http_request("DELETE", u, self.token, "", self.timeout_ms) {
    Err(_) => Ok(())
    Ok(resp) =>
      if resp.status == 200 || resp.status == 204 || resp.status == 404 {
        Ok(())
      } else {
        Err("rhop: http DELETE failed: status=\{resp.status}")
      }
  }
}

///|
/// 文件名拼到基地址上（文件名整体 URL 编码，防路径穿越）。
pub fn HttpEndpoint::url_of(self : HttpEndpoint, filename : String) -> String {
  self.base_url + uri_encode(filename)
}

// ---------------------------------------------------------------------------
// 4) 地址形态解析：裸路径 / file:// / http(s):// → 端视图
// ---------------------------------------------------------------------------

///|
/// 把地址形态解析为端视图（对照 vools `parse_endpoint`）。
///
/// - 裸路径 / 相对路径 / UNC / 盘符 → `LocalEndpoint`
/// - `file://` → `FileUrlEndpoint`
/// - `http://` / `https://` → `HttpEndpoint`
/// - 空串、以及带**其它协议**（如 `ftp://`）的 spec → 可诊断 Err
pub fn parse_endpoint(spec : String) -> Result[&EndpointView, String] {
  let s = spec.trim().to_owned()
  if s == "" {
    return Err("rhop: endpoint spec 不能为空")
  }
  if is_file_url(s) {
    let ep = match FileUrlEndpoint::new(s) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let v : &EndpointView = ep
    return Ok(v)
  }
  let lower = s.to_lower()
  if lower.has_prefix("http://") || lower.has_prefix("https://") {
    let ep = HttpEndpoint::new(s, None, 3000)
    let v : &EndpointView = ep
    return Ok(v)
  }
  // 其它协议形态（含 "://"）明确拒绝：静默当本地路径会造成难查的错误
  if s.contains("://") {
    let scheme = match s.find("://") {
      Some(i) =>
        match s.get_view(start=0, end=i) {
          Some(v) => v.to_owned()
          None => "?"
        }
      None => "?"
    }
    return Err(
      "rhop: 不支持的 endpoint 协议 \"\{scheme}\"（支持：裸路径 / file:// / http:// / https://）",
    )
  }
  let ep = LocalEndpoint::new(s)
  let v : &EndpointView = ep
  Ok(v)
}

///|
/// 是否为 `file://` URL（大小写不敏感）。
pub fn is_file_url(s : String) -> Bool {
  let lower = s.to_lower()
  lower.has_prefix("file://")
}

///|
/// `file://` URL → 本地路径。
///
/// 处理三种形态：
/// - `file:///<abs>`  → `/abs`（Windows 下 `/E:/x` → `E:/x`）
/// - `file://C:/x`    → `C:/x`（盘符进了 authority 段）
/// - `file://server/share` → `//server/share`（网络共享/挂载语义）
pub fn file_url_to_path(url : String) -> Result[String, String] {
  let rest = match url.get_view(start=7) {
    Some(v) => v.to_owned()
    None => ""
  }
  if rest == "" {
    return Err("rhop: file:// URL 缺少路径: \{url}")
  }
  // 去掉 query / fragment
  let mut body = rest
  match body.find("?") {
    Some(i) =>
      body = match body.get_view(start=0, end=i) {
        Some(v) => v.to_owned()
        None => body
      }
    None => ()
  }
  match body.find("#") {
    Some(i) =>
      body = match body.get_view(start=0, end=i) {
        Some(v) => v.to_owned()
        None => body
      }
    None => ()
  }
  let decoded = uri_decode(body)
  if decoded == "" {
    return Err("rhop: file:// URL 缺少路径: \{url}")
  }
  let norm = normalize_path(decoded)
  // Windows 盘符形态：/E:/x → E:/x
  if norm.length() >= 3 && norm.has_prefix("/") && norm.get_char(2) == Some(':') {
    return Ok(
      match norm.get_view(start=1) {
        Some(v) => v.to_owned()
        None => norm
      },
    )
  }
  Ok(norm)
}

// ---------------------------------------------------------------------------
// HTTP 同步桥（子进程 node:http / node:https）与 URL 编解码
//
// 为什么走子进程：node 的 http 客户端只有异步回调制，而本包对外是同步 `Result`。
// 若在主线程阻塞等待，同进程的 HTTP 服务端也会跟着停摆（事件循环被占），
// 故把请求交给 `node -e <script>` 子进程：对外保持同步语义，内里仍是真 node:http。
// 注意：`#|` 原始字符串不支持换行，子进程脚本必须写成单行；脚本里统一用双引号，
// 外层用单引号包裹，避免任何转义。
// ---------------------------------------------------------------------------

///|
/// HTTP 响应（同步结果）。
pub struct HttpResp {
  status : Int32
  body : String
}

///|
/// 发一个同步 HTTP 请求（js 目标经子进程 node:http；非 js 返回可诊断 Err）。
pub fn http_request(
  method_name : String,
  url : String,
  token : String?,
  body : String,
  timeout_ms : Int32,
) -> Result[HttpResp, String] {
  let mut headers = Json::object({
    "Content-Type": Json::string("application/octet-stream"),
  })
  match token {
    Some(t) =>
      if t != "" {
        headers = Json::object({
          "Content-Type": Json::string("application/octet-stream"),
          "X-RHOP-Token": Json::string(t),
        })
      }
    None => ()
  }
  let req = Json::object({
    "method": Json::string(method_name),
    "url": Json::string(url),
    "headers": headers,
    "body": Json::string(body),
    "timeout": Json::number(timeout_ms.to_double()),
  })
  match http_bridge(Json::stringify(req), timeout_ms) {
    Err(e) => Err(e)
    Ok(text) => {
      let j = @json.parse(text) catch {
        _ => return Err("rhop: http 桥返回非 JSON: \{text}")
      }
      match j {
        { "ok": True, "status": Number(st, ..), "body": String(b), .. } =>
          Ok({ status: st.to_int(), body: b, })
        { "ok": False, "error": String(e), .. } => Err(e)
        _ => Err("rhop: http 桥返回结构意外: \{text}")
      }
    }
  }
}

///|
/// 子进程 HTTP 客户端：读 stdin 的 JSON 请求，发一次请求，把 JSON 结果写 stdout。
/// 子进程一律 exit 0（异常也以 {ok:false,error} 形式回报），避免父进程拿不到输出。
#cfg(target="js")
extern "js" fn ffi_http_bridge(req_json : String, timeout_ms : Int32) -> String =
  #| (reqJson, timeout) => { const script = 'const fs=process.getBuiltinModule("node:fs");const req=JSON.parse(fs.readFileSync(0,"utf8"));const finish=(o)=>{process.stdout.write(JSON.stringify(o));};const lib=process.getBuiltinModule(String(req.url).startsWith("https:")?"node:https":"node:http");try{const r=lib.request(req.url,{method:req.method,headers:req.headers||{},timeout:req.timeout||3000},(res)=>{const chunks=[];res.on("data",(c)=>chunks.push(c));res.on("end",()=>finish({ok:true,status:res.statusCode,body:Buffer.concat(chunks).toString("utf8")}));});r.on("timeout",()=>{try{r.destroy();}catch(_e){}finish({ok:false,error:"http timeout"});});r.on("error",(e)=>finish({ok:false,error:String((e&&e.message)||e)}));if(req.body){r.write(Buffer.from(String(req.body),"utf8"));}r.end();}catch(e){finish({ok:false,error:String((e&&e.message)||e)});}'; try { const cp = process.getBuiltinModule("node:child_process"); const out = cp.execFileSync(process.execPath, ["-e", script], { input: String(reqJson), encoding: "utf8", timeout: Number(timeout) + 5000, stdio: ["pipe", "pipe", "pipe"] }); return String(out); } catch (e) { const out = (e && e.stdout) ? String(e.stdout) : ""; if (out) { return out; } return JSON.stringify({ ok: false, error: String((e && e.message) || e) }); } }

///|
/// js：调用子进程桥；成功返回其 JSON 文本（失败/超时由子进程回报 {ok:false}）。
#cfg(target="js")
fn http_bridge(req_json : String, timeout_ms : Int32) -> Result[String, String] {
  let out = ffi_http_bridge(req_json, timeout_ms)
  if out == "" {
    Err("rhop: http 桥无输出（子进程异常）")
  } else {
    Ok(out)
  }
}

///|
/// 非 js：无 node:http，返回可诊断 Err（保证包可编译）。
#cfg(not(target="js"))
fn http_bridge(req_json : String, timeout_ms : Int32) -> Result[String, String] {
  Err("rhop: HttpEndpoint 仅 js 目标可用（wasm/native 无 node:http）")
}

///|
/// URL 百分号编码（把文件名安全拼进 URL）。js 用标准 `encodeURIComponent`。
#cfg(target="js")
extern "js" fn ffi_uri_encode(s : String) -> String =
  #| (s) => { try { return encodeURIComponent(String(s)); } catch (_e) { return String(s); } }

///|
/// URL 百分号解码。js 用标准 `decodeURIComponent`。
#cfg(target="js")
extern "js" fn ffi_uri_decode(s : String) -> String =
  #| (s) => { try { return decodeURIComponent(String(s)); } catch (_e) { return String(s); } }

///|
/// URL 百分号编码（js: encodeURIComponent；非 js: 保守直通，仅保留可打印 ASCII）。
pub fn uri_encode(s : String) -> String {
  ffi_uri_encode(s)
}

///|
/// URL 百分号解码（js: decodeURIComponent；非 js: 直通）。
pub fn uri_decode(s : String) -> String {
  ffi_uri_decode(s)
}

///|
/// 非 js：无 URI 编解码依赖，直通返回（HttpEndpoint 在非 js 本就不可用）。
#cfg(not(target="js"))
fn ffi_uri_encode(s : String) -> String {
  s
}

///|
/// 非 js：直通返回。
#cfg(not(target="js"))
fn ffi_uri_decode(s : String) -> String {
  s
}