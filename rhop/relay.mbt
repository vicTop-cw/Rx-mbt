// ============================================================================
// rhop · 双方自建临时服务器中转（MVP-3）
//
// 对照 vools.rhop.transport.relay：
//   中转方（RelayHost）临时起一个本地 HTTP 服务，投递方（RelayClient）PUT 加密包后即走；
//   TTL 到期自动关闭；地址与 token 由配置侧告知对端。
//   通道选择链：自建中转（双方可达）→ Git/SFTP 在线通道 → shared path 回退。
//
// 实现要点（js 目标）：
//   - 中转服务跑在**子进程**里（`node -e <script>`，spec 走环境变量）：
//     主线程的同步 HTTP 客户端（见 transport_endpoint.mbt 的工程决策）需要阻塞等待，
//     若服务端在同一进程的事件循环里会被一起堵死，故必须跨进程。
//   - 端口：spec.port=0 时由子进程 bind 后把真实端口写进 spec.port_file，父进程轮询该文件。
//   - 协议（与 vools 一致）：PUT /pkg/<name>（201）；GET /pkg/<name>（200，取走即删）；
//     GET /health（200，探活）；token 放 X-RHOP-Token；坏 token 403；坏文件名 400。
//
// 非 js 目标：start/available/send/receive 一律可诊断失败（不崩溃）。
// ============================================================================

///|
/// 临时 HTTP 中转服务器（RelayHost 侧）。
pub struct RelayServer {
  /// 监听地址（默认 127.0.0.1）
  host : String
  /// 监听端口（0=由系统分配，start 后更新为真实端口）
  mut port : Int32
  /// 访问 token（None/空=不校验）
  token : String?
  /// 存活 TTL（毫秒，<=0 表示不过期）
  ttl_ms : Int32
  /// 子进程注册 id（0=未启动哨兵；故注册表序号从 1 开始，不用 0）
  mut child : Int64
  /// 子进程写入真实端口的文件
  mut port_file : String
}

///|
/// 构造（`port=0` 表示由系统分配；`ttl_ms<=0` 表示不自动关闭）。
pub fn RelayServer::new(
  host : String,
  port : Int32,
  token : String?,
  ttl_ms : Int32,
) -> RelayServer {
  { host, port, token, ttl_ms, child: 0L, port_file: "", }
}

///|
/// 服务地址（start 后含真实端口）。
pub fn RelayServer::url(self : RelayServer) -> String {
  "http://\{self.host}:\{self.port}"
}

///|
/// 当前真实端口（未启动时为构造时的值，可能为 0）。
pub fn RelayServer::port(self : RelayServer) -> Int32 {
  self.port
}

///|
/// 是否处于「已启动且未停止」状态。
///
/// 与 vools 同义：Python 的 `RelayServer.alive()` 就是 `self._httpd is not None`
/// （启动标志），并不探测进程。要探子进程真实存活请用 `process_alive()`。
pub fn RelayServer::alive(self : RelayServer) -> Bool {
  self.child != 0L
}

///|
/// 子进程中转服务当前是否真的还活着（诊断用；跨进程不可达时返回 false）。
pub fn RelayServer::process_alive(self : RelayServer) -> Bool {
  self.child != 0L && relay_alive(self.child)
}

///|
/// 启动中转服务并等待就绪（最多约 5 秒）。
///
/// 失败：子进程起不来 / 端口文件迟迟不出现 → 可诊断 Err（并已清理子进程）。
pub fn RelayServer::start(self : RelayServer) -> Result[Unit, String] {
  if self.child != 0L {
    // C2 BUG-5：不能只看「有过 child」。TTL 到期或子进程崩溃后 child 仍是旧 id，
    // 直接返回 Ok 会让调用方以为服务可用，直到 send/receive 才失败。
    // 旧进程还活着才算幂等命中；否则先清理（杀僵尸 + 删端口文件/临时目录）再重新拉起。
    if relay_alive(self.child) {
      return Ok(())
    }
    self.stop()
  }
  let pf = unique_tmp_path("rhop-relay")
  if pf == "" {
    return Err("rhop relay: 无法创建临时端口文件路径")
  }
  let tok = match self.token {
    Some(t) => t
    None => ""
  }
  let spec = Json::object({
    "host": Json::string(self.host),
    "port": Json::number(self.port.to_double()),
    "token": Json::string(tok),
    "ttl_ms": Json::number(self.ttl_ms.to_double()),
    "port_file": Json::string(pf),
  })
  let id = relay_spawn(Json::stringify(spec))
  if id < 0L {
    return Err("rhop relay: 无法启动中转子进程（node 不可用？）")
  }
  self.child = id
  self.port_file = pf
  // 轮询端口文件（子进程 bind 后写入真实端口）
  //
  // C2 BUG-10：这里是**跨进程文件握手**，有两个经典竞态：
  //   ① 文件刚被创建、内容还没落盘 → 读到空串/半截 JSON；
  //   ② 读到的 JSON 缺 port 字段（理论上不会，但防御）。
  // 旧实现遇到 ① 会立刻 `return Err`（WSL/9p 上实测偶发失败：
  // `端口文件内容不是合法 JSON: `），而不是继续等 —— 这是**假失败**。
  // 现在：内容不可解析 == 还没准备好，继续轮询；只有超时才报错，并带上最后观察到的内容便于诊断。
  // 根因侧同步修：子进程改为「tmp + rename」原子写端口文件（见 ffi_relay_spawn 里的脚本）。
  let mut waited = 0
  let mut last_seen = ""
  while waited < 100 {
    if fs_path_exists(pf) {
      match fs_read_text(pf) {
        Ok(t) => {
          let text = t.trim().to_owned()
          if text != "" {
            last_seen = text
            let parsed = @json.parse(text) catch { _ => continue }
            match parsed {
              { "port": Number(p, ..), .. } =>
                if p.to_int() > 0 {
                  self.port = p.to_int()
                  return Ok(())
                }
              _ => ()
            }
          }
        }
        Err(_) => ()
      }
    }
    sleep_ms(50)
    waited = waited + 1
  }
  let _ = self.stop()
  if last_seen == "" {
    Err(
      "rhop relay: 等待中转服务就绪超时（5s 内未拿到监听端口）",
    )
  } else {
    Err(
      "rhop relay: 等待中转服务就绪超时（5s 内未拿到监听端口）；最后一次读到: " +
      last_seen,
    )
  }
}

///|
/// 停止中转服务并清理（幂等）：杀子进程、删端口文件**与临时目录**、清空状态。
pub fn RelayServer::stop(self : RelayServer) -> Unit {
  if self.child != 0L {
    relay_kill(self.child)
    self.child = 0L
  }
  if self.port_file != "" {
    // C2 BUG-1：`unique_tmp_path` 用 mkdtemp 建过一个目录，只删端口文件会留下空目录，
    // 每起停一次就在 os.tmpdir() 积一个 —— 这里连目录一起清掉。
    let dir = parent_dir_of(self.port_file)
    let _ = fs_remove(self.port_file)
    if dir != "" {
      let _ = fs_remove_dir(dir)
    }
    self.port_file = ""
  }
}

///|
/// 取路径的父目录（兼容 "\\" 与 "/"；无分隔符返回 ""）。
fn parent_dir_of(path : String) -> String {
  let p = path.replace_all(old="\\", new="/")
  match p.rev_split_once("/") {
    Some(pair) => if pair.0 == "" { "" } else { pair.0.to_owned() }
    None => ""
  }
}

///|
/// 删目录（仅 js；失败返回 Err，由调用方决定是否忽略）。
#cfg(target="js")
extern "js" fn ffi_remove_dir(path : String) -> Bool =
  #| (path) => { const G = globalThis; try { const fs = process.getBuiltinModule("node:fs"); fs.rmSync(String(path), { recursive: true, force: true }); G.__rxmbt_fs_err = ""; return true; } catch (e) { G.__rxmbt_fs_err = String((e && e.message) || e); return false; } }

///|
/// js：删目录。
#cfg(target="js")
fn fs_remove_dir(path : String) -> Result[Unit, String] {
  if ffi_remove_dir(path) {
    Ok(())
  } else {
    Err("rhop: 删目录失败: " + path)
  }
}

///|
/// 非 js：无文件系统，返回可诊断 Err。
#cfg(not(target="js"))
fn fs_remove_dir(path : String) -> Result[Unit, String] {
  Err("rhop: 删目录仅 js 目标可用（wasm/native 无文件系统 API）")
}

///|
/// 投递方通道：经配置告知的 (host, port, token) 访问中转。
pub struct RelayChannel {
  host : String
  port : Int32
  token : String?
  timeout_ms : Int32
}

///|
/// 构造通道（`timeout_ms` 为单次请求超时）。
pub fn RelayChannel::new(
  host : String,
  port : Int32,
  token : String?,
  timeout_ms : Int32,
) -> RelayChannel {
  { host, port, token, timeout_ms, }
}

///|
/// 基地址 `http://host:port`。
pub fn RelayChannel::base(self : RelayChannel) -> String {
  "http://\{self.host}:\{self.port}"
}

///|
pub impl OnlineChannel for RelayChannel with fn name(self) {
  "relay:" + self.base()
}

///|
pub impl OnlineChannel for RelayChannel with fn available(self) {
  match
    http_request(
      "GET",
      self.base() + "/health",
      self.token,
      "",
      self.timeout_ms,
    ) {
    Ok(resp) => resp.status == 200
    Err(_) => false
  }
}

///|
pub impl OnlineChannel for RelayChannel with fn send(self, filename, content) {
  let u = self.base() + "/pkg/" + uri_encode(filename)
  match http_request("PUT", u, self.token, content, self.timeout_ms) {
    Err(e) => Err("rhop relay: 中转不可达: \{u}: \{e}")
    Ok(resp) =>
      if resp.status == 200 || resp.status == 201 {
        Ok(())
      } else if resp.status == 403 {
        Err("rhop relay: token 不符（中转拒绝 403）")
      } else {
        Err("rhop relay: PUT 失败 status=\{resp.status}")
      }
  }
}

///|
pub impl OnlineChannel for RelayChannel with fn receive(self, filename) {
  let u = self.base() + "/pkg/" + uri_encode(filename)
  match http_request("GET", u, self.token, "", self.timeout_ms) {
    Err(e) => Err("rhop relay: 中转不可达: \{u}: \{e}")
    Ok(resp) =>
      if resp.status == 200 {
        Ok(resp.body)
      } else if resp.status == 404 {
        Err("rhop relay: 中转无包 \{filename}")
      } else if resp.status == 403 {
        Err("rhop relay: token 不符（中转拒绝 403）")
      } else {
        Err("rhop relay: GET 失败 status=\{resp.status}")
      }
  }
}

// ---------------------------------------------------------------------------
// FFI：子进程中转服务 / 阻塞休眠 / 唯一临时目录（js 目标）
// ---------------------------------------------------------------------------

///|
/// 子进程里的中转服务脚本（单行；`#|` 不支持换行）。
/// 读 env.RHOP_RELAY_SPEC（host/port/token/ttl_ms/port_file），bind 后把端口写进 port_file。
#cfg(target="js")
extern "js" fn ffi_relay_spawn(spec_json : String) -> Int64 =
  #| (specJson) => { const G = globalThis; try { const cp = process.getBuiltinModule("node:child_process"); if (G.__rxmbt_relay === undefined) { G.__rxmbt_relay = new Map(); G.__rxmbt_relay_seq = 1; } const script = 'const http=process.getBuiltinModule("node:http");const fs=process.getBuiltinModule("node:fs");const spec=JSON.parse(process.env.RHOP_RELAY_SPEC);const pkgs=new Map();const tok=spec.token;const send=(res,code,body)=>{const b=(body===undefined||body===null)?"":body;res.writeHead(code,{"Content-Length":Buffer.byteLength(b)});res.end(b);};const srv=http.createServer((req,res)=>{try{const u=String(req.url||"/");if(u==="/health"){send(res,200,"ok");return;}if(tok){const got=String(req.headers["x-rhop-token"]||"");const ch=process.getBuiltinModule("node:crypto");const ha=ch.createHash("sha256").update(got).digest();const hb=ch.createHash("sha256").update(tok).digest();if(!ch.timingSafeEqual(ha,hb)){send(res,403,"");return;}}const pre="/pkg/";if(!u.startsWith(pre)){send(res,400,"");return;}const name=decodeURIComponent(u.slice(pre.length));if(!name||name.indexOf("/")>=0||name.indexOf(String.fromCharCode(92))>=0){send(res,400,"");return;}if(req.method==="PUT"){const chunks=[];req.on("data",(c)=>chunks.push(c));req.on("end",()=>{pkgs.set(name,Buffer.concat(chunks));send(res,201,"");});return;}if(req.method==="GET"){const v=pkgs.get(name);if(v===undefined){send(res,404,"");return;}pkgs.delete(name);const s=v.toString("utf8");res.writeHead(200,{"Content-Type":"application/octet-stream","Content-Length":Buffer.byteLength(s)});res.end(s);return;}send(res,405,"");}catch(e){try{send(res,500,"");}catch(_e){}}});srv.listen(spec.port||0,spec.host||"127.0.0.1",()=>{try{const tmpf=spec.port_file+".tmp";fs.writeFileSync(tmpf,JSON.stringify({port:srv.address().port}));fs.renameSync(tmpf,spec.port_file);}catch(_e){}});if(spec.ttl_ms>0){setTimeout(()=>{try{srv.close();}catch(_e){}process.exit(0);},spec.ttl_ms);}'; const child = cp.spawn(process.execPath, ["-e", script], { env: Object.assign({}, process.env, { RHOP_RELAY_SPEC: String(specJson) }), stdio: "ignore", detached: true, windowsHide: true }); try { child.unref(); } catch (_e) {} const id = G.__rxmbt_relay_seq++; G.__rxmbt_relay.set(id, child); return BigInt(id); } catch (e) { return BigInt(-1); } }

///|
/// 杀掉中转子进程并从注册表移除（幂等）。
#cfg(target="js")
extern "js" fn ffi_relay_kill(id : Int64) -> Unit =
  #| (id) => { const G = globalThis; if (G.__rxmbt_relay === undefined) { return; } const c = G.__rxmbt_relay.get(Number(id)); if (c !== undefined) { try { c.kill(); } catch (_e) {} G.__rxmbt_relay.delete(Number(id)); } }

///|
/// 子进程是否仍在运行。
#cfg(target="js")
extern "js" fn ffi_relay_alive(id : Int64) -> Bool =
  #| (id) => { const G = globalThis; if (G.__rxmbt_relay === undefined) { return false; } const c = G.__rxmbt_relay.get(Number(id)); return c !== undefined && c.exitCode === null; }

///|
/// 阻塞休眠（主线程用 Atomics.wait；因服务端在子进程，不会自锁）。
#cfg(target="js")
extern "js" fn ffi_sleep_ms(ms : Int32) -> Unit =
  #| (ms) => { try { const sab = new SharedArrayBuffer(4); Atomics.wait(new Int32Array(sab), 0, 0, Number(ms)); } catch (_e) { const t0 = Date.now(); while (Date.now() - t0 < Number(ms)) {} } }

///|
/// 唯一临时目录里的目标文件名（用于子进程回报真实端口）。
#cfg(target="js")
extern "js" fn ffi_unique_tmp(prefix : String) -> String =
  #| (prefix) => { try { const fs = process.getBuiltinModule("node:fs"); const os = process.getBuiltinModule("node:os"); const path = process.getBuiltinModule("node:path"); const d = fs.mkdtempSync(path.join(os.tmpdir(), String(prefix) + "-")); return path.join(d, "port"); } catch (_e) { return ""; } }

///|
/// js：启动中转子进程；失败返回 -1。
#cfg(target="js")
fn relay_spawn(spec_json : String) -> Int64 {
  ffi_relay_spawn(spec_json)
}

///|
/// 非 js：无子进程能力，返回 -1（调用方据此返回可诊断 Err）。
#cfg(not(target="js"))
fn relay_spawn(spec_json : String) -> Int64 {
  -1L
}

///|
/// js：杀子进程。
#cfg(target="js")
fn relay_kill(id : Int64) -> Unit {
  ffi_relay_kill(id)
}

///|
/// 非 js：无子进程，空操作。
#cfg(not(target="js"))
fn relay_kill(id : Int64) -> Unit {
  ()
}

///|
/// js：子进程是否存活。
#cfg(target="js")
fn relay_alive(id : Int64) -> Bool {
  ffi_relay_alive(id)
}

///|
/// 非 js：恒 false。
#cfg(not(target="js"))
fn relay_alive(id : Int64) -> Bool {
  false
}

///|
/// js：阻塞休眠。
#cfg(target="js")
fn sleep_ms(ms : Int32) -> Unit {
  ffi_sleep_ms(ms)
}

///|
/// 非 js：忙等（保持同签名；非 js 下 relay 本就不可用）。
#cfg(not(target="js"))
fn sleep_ms(ms : Int32) -> Unit {
  let t0 = @env.now()
  while @env.now() < t0 + ms.to_uint64() {
    ()
  }
}

///|
/// js：唯一临时端口文件路径。
#cfg(target="js")
fn unique_tmp_path(prefix : String) -> String {
  ffi_unique_tmp(prefix)
}

///|
/// 非 js：空串（调用方据此返回 Err）。
#cfg(not(target="js"))
fn unique_tmp_path(prefix : String) -> String {
  ""
}
