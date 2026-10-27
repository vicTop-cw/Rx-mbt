// ============================================================================
// rhop · 在线通道（Git 仓库中继 / SFTP 镜像）
//
// 对照 vools.rhop.transport.online：
//   GitChannel  —— 把加密 JSON 作为文件提交并推送/拉取；可用性探测 git ls-remote；
//   SftpChannel —— 把加密 JSON 写到 SFTP 镜像目录；可用性探测 TCP 端口。
//
// 本实现的边界（与契约 §3 一致）：「无外部依赖时以 Err/不可用实现，
// 测试只覆盖接口与降级路径」。因此：
//   - available() 是**真实探测**（git 二进制存在则真跑 ls-remote；SFTP 真做 TCP connect）；
//   - send()/receive() 在没有凭据/paramiko 等价能力时返回**可诊断 Err**，绝不静默成功；
//   - 探测失败一律返回 false，不抛异常、不崩溃。
//
// 目标说明：探测仅 js 目标可用；wasm/native 下 available() 恒 false、send/receive 返回
// 明确 Err（保证包在三目标可编译、上层按「不可用」降级）。
// ============================================================================

///|
/// Git 仓库中继通道。
pub struct GitChannel {
  /// 远端地址（https:// 或 git@ 形态）
  remote_url : String
  /// 分支名（探测用 ls-remote 不区分；保留供配置对齐）
  branch : String
  /// 探测超时（毫秒）
  timeout_ms : Int32
}

///|
/// 构造（默认分支 main、探测超时 5s）。
pub fn GitChannel::new(remote_url : String) -> GitChannel {
  { remote_url, branch: "main", timeout_ms: 5000, }
}

///|
/// 指定分支。
pub fn GitChannel::with_branch(
  self : GitChannel,
  branch : String,
) -> GitChannel {
  { remote_url: self.remote_url, branch, timeout_ms: self.timeout_ms, }
}

///|
/// 指定探测超时。
pub fn GitChannel::with_timeout(
  self : GitChannel,
  timeout_ms : Int32,
) -> GitChannel {
  { remote_url: self.remote_url, branch: self.branch, timeout_ms, }
}

///|
/// 远端地址。
pub fn GitChannel::remote(self : GitChannel) -> String {
  self.remote_url
}

///|
pub impl OnlineChannel for GitChannel with fn name(self) {
  "git:" + self.remote_url
}

///|
pub impl OnlineChannel for GitChannel with fn available(self) {
  git_ls_remote(self.remote_url, self.timeout_ms)
}

///|
pub impl OnlineChannel for GitChannel with fn send(self, filename, content) {
  Err(
    "rhop git: send 未在本实现落地（vools 侧需可写远端 + 推送凭据）。filename=\{filename}, bytes=\{content.length()}；请改用 RelayChannel（自建中转）或 shared path",
  )
}

///|
pub impl OnlineChannel for GitChannel with fn receive(self, filename) {
  Err(
    "rhop git: receive 未在本实现落地（vools 侧需克隆工作区 + 拉取凭据）。filename=\{filename}；请改用 RelayChannel 或 shared path",
  )
}

///|
/// SFTP 镜像通道（可用性探测走 TCP；读写未落地，返回可诊断 Err）。
pub struct SftpChannel {
  host : String
  port : Int32
  username : String
  remote_dir : String
  timeout_ms : Int32
}

///|
/// 构造（默认端口 22、超时 5s）。
pub fn SftpChannel::new(
  host : String,
  port : Int32,
  remote_dir : String,
) -> SftpChannel {
  { host, port, username: "", remote_dir, timeout_ms: 5000, }
}

///|
/// 指定用户名（仅用于 name 展示与配置对齐）。
pub fn SftpChannel::with_username(
  self : SftpChannel,
  username : String,
) -> SftpChannel {
  {
    host: self.host,
    port: self.port,
    username,
    remote_dir: self.remote_dir,
    timeout_ms: self.timeout_ms,
  }
}

///|
/// 指定探测超时。
pub fn SftpChannel::with_timeout(
  self : SftpChannel,
  timeout_ms : Int32,
) -> SftpChannel {
  {
    host: self.host,
    port: self.port,
    username: self.username,
    remote_dir: self.remote_dir,
    timeout_ms,
  }
}

///|
pub impl OnlineChannel for SftpChannel with fn name(self) {
  "sftp:\{if self.username == "" { "*" } else { self.username }}@\{self.host}:\{self.remote_dir}"
}

///|
pub impl OnlineChannel for SftpChannel with fn available(self) {
  tcp_probe(self.host, self.port, self.timeout_ms)
}

///|
pub impl OnlineChannel for SftpChannel with fn send(self, filename, content) {
  Err(
    "rhop sftp: send 未在本实现落地（无 paramiko 等价能力）。host=\{self.host}:\{self.port}, filename=\{filename}, bytes=\{content.length()}；请改用 RelayChannel 或 shared path",
  )
}

///|
pub impl OnlineChannel for SftpChannel with fn receive(self, filename) {
  Err(
    "rhop sftp: receive 未在本实现落地（无 paramiko 等价能力）。host=\{self.host}:\{self.port}, filename=\{filename}；请改用 RelayChannel 或 shared path",
  )
}

// ---------------------------------------------------------------------------
// 探测原语（js：真跑 git / 真做 TCP connect；非 js：恒 false）
// ---------------------------------------------------------------------------

///|
/// `git ls-remote --heads <remote>` 探测远端可达性（js 目标）。
#cfg(target="js")
extern "js" fn ffi_git_ls_remote(remote : String, timeout_ms : Int32) -> Bool =
  #| (remote, timeout) => { try { const cp = process.getBuiltinModule("node:child_process"); cp.execFileSync("git", ["ls-remote", "--heads", String(remote)], { timeout: Number(timeout), stdio: ["ignore", "ignore", "ignore"] }); return true; } catch (_e) { return false; } }

///|
/// TCP 连接探测（js 目标）：子进程里 net.connect，连通打印 1、否则 0。
#cfg(target="js")
extern "js" fn ffi_tcp_probe(
  host : String,
  port : Int32,
  timeout_ms : Int32,
) -> Bool =
  #| (host, port, timeout) => { const script = 'const net=process.getBuiltinModule("node:net");const r=JSON.parse(process.getBuiltinModule("node:fs").readFileSync(0,"utf8"));const done=(v)=>{try{process.stdout.write(v);}catch(_e){}try{s.destroy();}catch(_e){}};const s=net.connect({host:r.host,port:r.port,timeout:r.timeout});s.on("connect",()=>done("1"));s.on("timeout",()=>done("0"));s.on("error",()=>done("0"));'; try { const cp = process.getBuiltinModule("node:child_process"); const input = JSON.stringify({ host: String(host), port: Number(port), timeout: Number(timeout) }); const out = cp.execFileSync(process.execPath, ["-e", script], { input: input, encoding: "utf8", timeout: Number(timeout) + 3000, stdio: ["pipe", "pipe", "pipe"] }); return String(out).trim() === "1"; } catch (e) { const out = (e && e.stdout) ? String(e.stdout) : ""; return out.trim() === "1"; } }

///|
/// js：git 探测。
#cfg(target="js")
fn git_ls_remote(remote : String, timeout_ms : Int32) -> Bool {
  if remote.trim().to_owned() == "" {
    return false
  }
  ffi_git_ls_remote(remote, timeout_ms)
}

///|
/// 非 js：无子进程能力，恒不可用。
#cfg(not(target="js"))
fn git_ls_remote(remote : String, timeout_ms : Int32) -> Bool {
  false
}

///|
/// js：TCP 探测。
#cfg(target="js")
fn tcp_probe(host : String, port : Int32, timeout_ms : Int32) -> Bool {
  if host.trim().to_owned() == "" || port <= 0 || port > 65535 {
    return false
  }
  ffi_tcp_probe(host, port, timeout_ms)
}

///|
/// 非 js：无 TCP 能力，恒不可用。
#cfg(not(target="js"))
fn tcp_probe(host : String, port : Int32, timeout_ms : Int32) -> Bool {
  false
}
