---
status: 已定案
decided_by: human_steward
decided_at: 2026-10-27T20:10:00+08:00
decision: approved
---

# 2026-10-27 rhop ← vools-rhop API 复刻执行契约（Batch A–D）

> 用户指令（原文）：「使用 fist-mbt [探索] 模式 迭代开发 rhop，将 vools-rhop 的 api 尽量都复刻到手，
> 善用 fist-mbt 任何能力，你是本项目唯一统帅，忌亲力亲为；尽量复用本项目其它 api 完成目标；
> 测试 wsl 和 windows 均需要通过，自己想办法营造各种测试环境 确保测试通过并有效。」
>
> 本文件是**执行级契约**：把上一份提案
> `plans/2026-10-26-rhop-api-align-proposal.md` 的 P0/P1 清单细化到「文件 / 签名 / 判据 / 作用域」，
> 供各执行体（impl-core / impl-crypto / impl-session / impl-business / qa-platform）按块认领。
> 定案人是 human_steward（人类指挥官），本轮由 Lead 在其书面授权下代行登记。

## 0. 参考实现与实测基线（2026-10-27）

| 项 | 值 |
|---|---|
| 参考实现 | `E:\IDEProjects\AI\vools\rhop\vools\rhop`（vools-rhop 0.9.0，Python） |
| 参考测试 | `E:\IDEProjects\AI\vools\rhop\tests\`（含 test_core/crypto/envelope/signer/integrity/transport/session/interact/config/watch/mirror/daemon/requester/executor/actions/task_* 等） |
| 本项目 | `E:\IDEProjects\AI\rx-mbt`，MoonBit 模块 `vicTop-cw/RX-MBT` |
| Windows 工具链 | moon 0.1.20261016，node v25.2.1 |
| WSL 工具链 | Ubuntu-22.04 / moon 0.1.20261021 / node v25.2.1 / python3.10 + vools 已装 |
| Windows 基线 | `moon test` wasm 407/407；js 411/411；native 407/407；`moon check` 0 error |
| WSL 基线 | `moon test` wasm 407/407；js 411/411；`moon check` 0 error |
| 已知环境坑 | ① Windows PATH 里 `...\.desktop-bin\node.cmd` 先于真 node ⇒ moon 以 cmd 批处理 spawn 长 JSON 参数被截断（`failed to parse args`）。测试脚本必须把 `C:\Program Files\nodejs` 前置。② WSL 里 PATH 含 Windows 路径会让 moon 选到 `node.cmd`（Exec format error），测试脚本必须净化 PATH 只留 `/root/.moon/bin:/usr/local/bin:/usr/bin:/bin`。 |

## 1. 目标与完成判据

1. **API 复刻**：vools-rhop 的公开 API 在 `rhop` 包中有对应实现（命名按 MoonBit 惯例，语义等价），
   覆盖 Batch A/B/C/D 的清单；每个 API 至少一条测试。
2. **三目标编译**：`wasm`（默认）/ `js` / `native` 全部 `moon check` 通过；纯逻辑 API 在三目标都可用。
3. **测试全绿**：Windows 与 WSL 上 `moon test`（wasm）、`moon test --target js`、`moon test --target native`
   均 `failed: 0`（判绿只认 `Total tests: N, passed: N, failed: 0` 汇总行）。
4. **跨实现互操作**（可核验证据）：Python vools-rhop 加密的信封/密文，MoonBit 能解密验证；
   MoonBit 加密的，Python 能解密验证；envelope checksum 两侧逐字节一致。
   证据固化为 fixture JSON（`test-suit/rhop_js/fixtures/vools_vectors.json`）+ 生成脚本。
5. **过程留痕**：fist-mbt 任务树 + reserve_scope 回执 + 执行汇报（`fist-mbt/reports/`）。

## 2. MoonBit 编码约定（全员强制）

1. 命名：类型 PascalCase，函数/方法 snake_case，字段 snake_case；构造器 `Type::new(...)`，
   工厂 `Type::from_xxx(...)`。
2. 错误：`Result[T, String]`，错误文本用中文（与现有 `packet.mbt` 一致）；密码学三态 reason
   保留 vools 原字面量：`OK` / `MALFORMED` / `BAD_TOKEN` / `NOT_JSON`。
3. JSON：一律用 `moonbitlang/core/json` 的 `Json`；序列化严格用 `canonical_json`（见 §3.2）。
4. 目标拆分：**优先 `#cfg(target="js")` / `#cfg(not(target="js"))` 单文件双实现**，
   `moon.pkg` 的 `options.targets` 只用于已有 `rhop_js.mbt`/`rhop_native.mbt`，**新文件不要再动 moon.pkg 的 targets**
   （避免多人写同一文件冲突）。纯逻辑文件天然全目标编译。
5. 依赖方向：`rhop` 包只新增对 `moonbitlang/core/*` 的 import；**不引入第三方 moonbit 包**（保持零外部依赖）。
6. 复用本项目 API：文件监控/异步流一律复用 `@rx.Observable`、`@rx.Subject`、`@monitor.watch_folder`；
   IO 复用现有 `rhop_js.mbt` 的 FFI 风格（`extern "js"` + `process.getBuiltinModule`）。
7. 所有新增公开 API 必须有 `///|` 文档注释（至少一句语义 + 目标可用性）。
8. 提交前 `moon info && moon fmt`；`.mbti` 变化必须是有意的。

### 2.1 JSON 规范化（canonical_json）

与 Python 对齐的精确口径（用于 checksum 跨实现一致）：

- 对象键按 Unicode 码点升序排序；数组保持顺序；
- 分隔符 `", "` 与 `": "`（Python `json.dumps` 默认 separators）；
- 字符串转义：`"`→`\"`、`\`→`\\`、控制字符用 `\n \t \r \b \f`，其余 <0x20 用 `\u00XX`；
  **非 ASCII 字符原样输出（ensure_ascii=False）**；
- `null`→`null`、`true`/`false` 小写；
- 数字：整数值打印为整数形式（无 `.0`）；浮点按最短往返表示，**checksum 测试语料避免浮点**
  （文档化限制，双方测试都以字符串/整数/布尔/null/嵌套对象为主）。

## 3. 模块与 API 清单（vools-rhop → rx-mbt/rhop）

### Batch A（纯协议层，全目标）· owner: impl-core

| 文件 | 公开 API（MoonBit） | vools 对照 |
|---|---|---|
| `rhop/core.mbt` | `enum Side { Requester; Executor }`、`Side::other`、`Side::to_string`、`Side::parse`；`enum TaskStatus { Pending; Claimed; Running; Done; Failed; Cancelled }`、`to_string`/`parse`/`can_transition(self, next)`/`is_terminal` | core.py `Side`/`TaskStatus`（流转表逐条照抄：PENDING→{CLAIMED,CANCELLED}，CLAIMED→{RUNNING,CANCELLED}，RUNNING→{DONE,FAILED}，其余终态） |
| `rhop/digest.mbt` | `sha256(Bytes)->Bytes`、`sha256_hex(Bytes)->String`、`sha256_hex_of_utf8(String)->String`、`md5(Bytes)->Bytes`、`md5_hex(Bytes)->String`、`hmac_sha256(Bytes,Bytes)->Bytes`、`pbkdf2_hmac_sha256(password,salt,iterations,dk_len)->Bytes` | signer.py/envelope.py 的 sha256、NPUSigner 的 md5；纯 MoonBit 实现（native/wasm 可用） |
| `rhop/json_canonical.mbt` | `canonical_json(Json)->String`、`canonical_json_utf8(Json)->Bytes` | envelope.py `json.dumps(..., ensure_ascii=False, sort_keys=True)` |
| `rhop/envelope.mbt` | `struct Envelope { task_id: String; status: TaskStatus; payload: Json; result: Json?; error: String?; side: Side; version: Int; created_at: String; updated_at: String; hops_seen: Array[String]; signature: String?; checksum: String }`；`Envelope::new(task_id,status,payload,side)`（自动算 checksum）、`Envelope::new_full(...)`、`compute_checksum`、`to_rhop_bytes()->Bytes`、`from_rhop_bytes(Bytes)->Result[Envelope,String]`、`to_dict()->Json`、`from_dict(Json)->Result[Envelope,String]`、`with_result(Json?)`、`with_updated_at(String)`、`with_hops_seen(Array[String])`（wither 重算 checksum） | envelope.py（checksum = `sha256:` + hex(canonical_json(除 checksum 外全部字段，含 v=1))；`from_rhop_bytes` 校验 checksum 不匹配返回 Err） |
| `rhop/signer.mbt` | `trait AbstractSigner { sign(Self,String,Json)->String?; verify(Self,String,Json,String)->Bool }`；`struct FileHashSigner {}`（`sha256:` + hex(canonical_json({"task_id":…,"result":…}))）；`struct NPUSigner { marker: String }` + `NPUSigner::new(marker)` + `NPUSigner::with_serial_provider(fn()->String?)`（默认 provider 返回 None ⇒ sign 返回 None；签名格式 `<marker>:<serial>:<md5>`） | signer.py |
| `rhop/integrity.mbt` | `struct IntegrityChecker {}`；`IntegrityChecker::verify(Envelope,Bytes)->(Bool,String)`、`verify_bytes(Bytes)->(Bool,String)`、`checksum_match(Envelope)->Bool`；便捷函数 `integrity_verify_bytes`/`integrity_checksum_match` | integrity.py |

### Batch B（密码学 + 介质，js 为主）· owner: impl-crypto

| 文件 | 公开 API | vools 对照 |
|---|---|---|
| `rhop/key.mbt` | `ENV_RHOP_KEY`、`SECRET_PREFIX`、`is_secret(String)->Bool`、`load_key(source:String?, path:String?, env_name:String)->Result[String,String]`（优先级 source > path > env）、`load_key_from_path`、`load_key_from_env`（js FFI；非 js 目标返回 Err 说明） | crypto.py `load_key`/`is_secret`/常量 |
| `rhop/crypto.mbt` | `struct VerifyResult { ok: Bool; payload: Json?; reason: String }`；`struct RhopCrypto { key: String }`；`from_key`/`from_path`/`from_env`；`encrypt_json(Json)->String`（输出 `{"v":1,"alg":"fernet","ct":…}`）；`decrypt_verify(String)->VerifyResult`；`encrypt_secret(String)->String`（`RHOP-ENC:`+token）；`decrypt_secret(String)->Result[String,String]` | crypto.py `RhopCrypto`／VerifyResult。**算法对齐 VText Fernet**：salt=sha256(key)[:16]；FK=base64url(PBKDF2-SHA256(key,salt,200000,32))；Fernet=AES128-CBC+HMAC-SHA256（token=0x80|ts_be8|iv16|ct|hmac32）；`ct` = base64url(Fernet-token 文本字节)。js 用 node crypto 实现；非 js 目标先给出同签名的 Err 实现（纯运算版本列为 P2 可选） |
| `rhop/watch.mbt` | `struct RhopWatcher { path: String; crypto: RhopCrypto; ... }`；`RhopWatcher::new(path, crypto)`、`with_extensions`、`start()->Result[Unit,String]`、`stop()`、`observe()->@rx.Observable[(String, VerifyResult), String]`、`skip_existing` 语义；复用 `@monitor.watch_folder` | watch.py（默认扩展名 `.rhop`，坏文件跳过，on_packet(filename, VerifyResult)） |
| `rhop/transport_base.mbt` | `trait SharedPath { available(Self)->Bool; write_text(Self,String,String)->Result[Unit,String]; read_text(Self,String)->Result[String,String]; exists(Self,String)->Bool; remove(Self,String)->Result[Unit,String]; name(Self)->String; root(Self)->String? }`；`trait OnlineChannel { available(Self)->Bool; send(Self,String,String)->Result[Unit,String]; receive(Self,String)->Result[String,String]; name(Self)->String }`；`struct TransportSelection { transport: String; label: String; is_online: Bool; reason: String }`；`struct SharedPathView { write_view: &SharedPath?; read_view: &SharedPath? }` + `make_shared_path(write,read?)->Result[SharedPathView,String]` | transport/base.py + transport/shared.py（trait object 用 MoonBit `&Trait`） |
| `rhop/transport_endpoint.mbt` | `trait EndpointView`（`available/write_text/read_text/exists/remove/name`，作为 SharedPath 的 endpoint 实现）；`LocalEndpoint::new(root)`、`FileUrlEndpoint::new(url)`、`HttpEndpoint::new(base_url, token?, timeout_ms?)`（js 用 node:http 实现，非 js 返回不可用）、`parse_endpoint(spec:String)->Result[&EndpointView,String]`（裸路径/file:// → 本地；http(s):// → Http） | transport/endpoint.py |
| `rhop/transport_selector.mbt` | `select_transport(online: Array[&OnlineChannel], shared: &SharedPath?)->TransportSelection` | transport/selector.py（在线可用优先，否则 shared） |
| `rhop/transport_local.mbt` | `LocalSharedPath::new(root)`（原子写 tmp+rename，路径统一 `/`） | transport/local.py |
| `rhop/online.mbt` | `GitChannel`/`SftpChannel` 接口与 js 侧探测（`available` 用 `git ls-remote` / TCP probe）；无外部依赖时以 Err/不可用实现，测试只覆盖接口与降级路径 | transport/online.py |
| `rhop/relay.mbt` | `RelayServer::new(host,port,token,ttl)` + `start/stop/url/alive`；`RelayChannel::new(host,port,token,timeout)` + `send/receive/available`（js node:http） | transport/relay.py（MVP-3） |

### Batch C（会话 / 配置 / 交互）· owner: impl-session

| 文件 | 公开 API | vools 对照 |
|---|---|---|
| `rhop/session.mbt` | `Role`（SEND/RECV/RELAY 常量或 enum + parse/to_string）；`struct Session { role; shared: SharedPathView?; online: Array[&OnlineChannel]; relay: RelayChannel?; crypto: RhopCrypto?; name }`；`available()`、`send_package(filename, payload:Json)->Result[Json,String]`、`recv_package(filename)->Result[Json,String]`、`reverse()->Session`、`describe()->Json` | session.py（通道链：relay > online > shared；失败返回 status/reason 结构） |
| `rhop/config.mbt` | `_key_from_cfg`、`struct RhopConfig { key; role; sftp: Json?; online: Json?; shared: Json?; relay: Json?; name }`；`RhopConfig::from_dict(Json)->Result[RhopConfig,String]`、`from_file(path)`（js）、`to_dict()->Json`（密码字段打 `***`）、`build_crypto`、`build_online`、`build_shared`、`build_relay`、`build_session(role?)`、`action_cfg()->Json`；`load_config(path_or_json)` | config.py |
| `rhop/interact.mbt` | `interact(cfg, action, payload, mode)->Result[Json,String]`（mode: `execute`/`request`/`roundtrip`）、`handle_request(cfg, filename, session?)->Result[Json,String]`；复用 `actions` 注册表 | interact.py |

### Batch D（业务层：镜像库 / 守护 / 需求端 / 执行端 / 动作）· owner: impl-business

| 文件 | 公开 API | vools 对照 |
|---|---|---|
| `rhop/actions.mbt` | `run_action(name, cfg, payload)->Json`、`omega_unwrap(result)->Json`、`register_action(name, handler)`、`list_actions()`；内置 `jump.probe`（读取 sftp 配置返回探测结果）等可离线动作 | actions/（run_action/omega_unwrap、jump.py） |
| `rhop/mirror.mbt` | `struct StaleVersionError` 语义；`struct MirrorDB`；`MirrorDB::open(path)->Result[MirrorDB,String]`、`upsert_task(Envelope)`、`get_task(id)->Envelope?`、`list_tasks(status?)`、`update_status(id, TaskStatus, version)`、`claim_task(id, claimer)`、`count_by_status()`、`log_sync(...)`、`pending_sync()`、`close()`；js 用 `node:sqlite`（`process.getBuiltinModule("node:sqlite")`），悲观锁/乐观锁同 vools | mirror.py（P1） |
| `rhop/requester.mbt` | `Requester::new(config)`、`submit(task_id, payload)`、`get_result(task_id)`、`list_tasks(status?)`、`cancel(task_id)`、`close()` | requester.py（P1） |
| `rhop/executor.mbt` | `Executor::new(config)`、`claim()`、`execute(task)`、`report_result(task_id, result)`、`report_failure(task_id, error)`、`list_pending()`、`close()` | executor.py（P1） |
| `rhop/daemon.mbt` | `RelayDaemon::new(config)`、`start()`、`stop()`、`run_once()`、`process_inbox()`、`push_local()` | daemon.py（P1） |
| `rhop/sync_folder.mbt` | `SyncFolder::new(source,target,pattern)`、`sync_once()`、`run_forever()`；`ClipboardFileSync` 接口（js 可降级） | sync_folder.py / clipboard.py（P1，可缓） |

> P2（时间允许再做）：vools-rhop `task/` 子包（TaskConfig/TaskQueue/store/heartbeat/exec/secrets/sync/CLI）在 MoonBit 侧等价物；
> 不列入本轮验收硬门槛，但任务树中保留。

## 4. 测试与验证策略

### 4.1 测试包划分

| 包 | 目标 | 内容 / owner |
|---|---|---|
| `test-suit/rhop` | wasm + js + native（默认全目标） | core/digest/json_canonical/envelope/signer/integrity（impl-core）；session/config（impl-session，纯逻辑部分）；actions（impl-business，纯逻辑部分）；现有 packet/cipher 测试 |
| `test-suit/rhop_js`（新，impl-crypto） | js | crypto（Fernet）/watch/transport/relay；fixtures 跨实现向量（qa 生成） |
| `test-suit/rhop_interact`（新，impl-session） | js | interact 三模式 / roundtrip 单机闭环（依赖 node fs/crypto 的端到端） |
| `test-suit/rhop_business`（新，impl-business） | js | mirror（node:sqlite）/requester/executor/daemon |
| `test-suit/rhop_native`（可选） | native | 纯摘要/信封在 native 的等价抽查（可与 rhop 包合并，非必需） |

> 包边界按 owner 切分，避免多人写同一个 `moon.pkg`（`test-suit/rhop_js/moon.pkg` 归 impl-crypto，
> 其余新包由各自 owner 新建）。

### 4.2 跨平台测试入口（qa-platform 交付）

- `scripts/test_all.sh`：自动探测平台（`$WSL_DISTRO_NAME` / `uname` / `MSYSTEM`），
  - Windows(Git Bash)：`export PATH="/c/Program Files/nodejs:/c/Users/$USER/.moon/bin:$PATH"`；
  - WSL：`export PATH="$HOME/.moon/bin:/usr/local/bin:/usr/bin:/bin"`；
  依次跑 `moon check`、`moon test`、`moon test --target js`、`moon test --target native`，
  末尾汇总每个目标的 `Total tests/passed/failed`，任一 failed≠0 或缺失汇总行即 exit 1。
- `scripts/test_all.ps1`：Windows 原生入口（pwsh），调用同一组命令并做同样判绿。
- `scripts/gen_conformance_vectors.py`：用 Python vools-rhop 生成
  `test-suit/rhop_js/fixtures/vools_vectors.json`（envelope 字节/checksum、crypto 密文、signer 签名、
  JSON canonical 样例）；`--verify` 模式反向校验 MoonBit 生成的向量（由 js 测试写出产物后 Python 复核）。
- 判绿纪律：只认 `moon test` 的汇总行；脚本必须打印平台、moon 版本、node 路径。

### 4.3 验收清单（每批）

- [ ] `moon check` 0 error（三目标可取并集，以 `moon check --target js` + 默认 + native 为准）
- [ ] 新增 API 均有测试；`moon test` 三目标 failed: 0
- [ ] Windows 与 WSL 各跑一遍 `scripts/test_all.sh` 全绿（贴汇总行）
- [ ] Batch A：checksum 与 Python 逐字节一致（fixture）；Batch B：Python↔MoonBit 双向解密成功
- [ ] `moon fmt` 后无 diff；`.mbti` 变更已复核
- [ ] 执行汇报写入 `fist-mbt/reports/YYYY-MM-DD-<batch>-report.md`

## 5. 执行波次与文件作用域（并行门证据）

| 波次 | 并行路 | owner | 写作用域（reserve_scope） |
|---|---|---|---|
| W1 | A（协议层） | impl-core | `rhop/core.mbt`、`rhop/digest.mbt`、`rhop/json_canonical.mbt`、`rhop/envelope.mbt`、`rhop/signer.mbt`、`rhop/integrity.mbt`、`test-suit/rhop/{core,digest,json_canonical,envelope,signer,integrity}_test.mbt` |
| W1 | B-前段（密钥/密码学） | impl-crypto | `rhop/key.mbt`、`rhop/crypto.mbt`、`test-suit/rhop_js/crypto_test.mbt`、`test-suit/rhop_js/fixtures/` |
| W1 | 测试平台（脚本/向量） | qa-platform | `scripts/`、`test-suit/rhop_js/`（仅 moon.pkg 与平台脚手架，测试文件由 owner 写） |
| W2 | B-后段（介质/监视/中转） | impl-crypto | `rhop/watch.mbt`、`rhop/transport_*.mbt`、`rhop/online.mbt`、`rhop/relay.mbt`、对应测试 |
| W2 | C（会话/配置/交互） | impl-session | `rhop/session.mbt`、`rhop/config.mbt`、`rhop/interact.mbt`、对应测试 |
| W3 | D（业务层） | impl-business | `rhop/actions.mbt`、`rhop/mirror.mbt`、`rhop/requester.mbt`、`rhop/executor.mbt`、`rhop/daemon.mbt`、`rhop/sync_folder.mbt`、对应测试 |

依赖：A 的 `digest`/`envelope` 是 B/C/D 的编译依赖 ⇒ W1 的 A 必须最先落地接口；
B 的 `crypto`/`transport` 是 C 的依赖 ⇒ C 在 W2；D 在 C 之后。
每波开始前由 Lead 写 `reserve_scope` 并回执；结束 `reserve_release`。

## 6. 风险与处置

| 风险 | 处置 |
|---|---|
| Fernet 跨实现细节（双重 base64url、padding、时间戳） | 先用 Python 打印中间值做 fixture；js 单测逐字段对齐；失败先定位到 token 层级 |
| canonical_json 与 Python 数字/转义差异 | 语料只用 int/string/bool/null/对象/数组；浮点限制写入文档；checksum 用 fixture 锁定 |
| MoonBit `&Trait` 对象与泛型组合限制 | 优先 trait object；如遇编译限制，退化为 enum 包装（`SharedPath` enum），由 impl-crypto 在实现中定案并回报 |
| 并行代理互相编译干扰 | 各波作用域不相交；每人在自己批次完成时跑全量测试；Lead 每波合并后跑一次全量 |
| WSL/Windows 环境差异 | qa-platform 的脚本统一 PATH；脚本自身是证据 |
| 任务树膨胀/漂移 | 每个任务描述内嵌本契约 §3 的对应行，验收按 §4.3 逐条勾 |

## 7. 附：旧提案引用

- `fist-mbt/plans/2026-10-26-rhop-api-align-proposal.md`（P0/P1 高阶层清单，已被本文件细化取代；
  其 P0-1..P0-10 与本文 Batch A/B/C 一一对应，P1-1..P1-5 对应 Batch D）。
