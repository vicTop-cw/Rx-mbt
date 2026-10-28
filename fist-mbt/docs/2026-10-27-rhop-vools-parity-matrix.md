# vools-rhop 0.9.0 → rx-mbt/rhop API 对照矩阵（Batch A/B 已核，Batch C/D 计划）

| 项 | 值 |
|---|---|
| 文档版本 | **v4（2026-10-28 11:3x，T0r15 字节级对齐后收口：B1/B2 已解决、rhop_task js 99、全模块 js 765）**；v1 起稿 / v1.1 actions / v2 C-D+clipboard / v3 P2 入矩阵 |
| 参考实现 | `E:\IDEProjects\AI\vools\rhop\vools\rhop`（vools-rhop **0.9.0**，Python 3.13 实测） |
| 本项目 | `E:\IDEProjects\AI\rx-mbt`，MoonBit 模块 `vicTop-cw/RX-MBT`，包 `rhop/` |
| 执行契约 | `fist-mbt/plans/decisions/2026-10-27-rhop-vools-parity-decision.md` §2/§3/§4 |
| 事实来源 | ① vools 源码 AST 逐模块枚举（脚本见 §9）；② 本项目 `rhop/*.mbt` 源码 + `rhop/pkg.generated.mbti`（生成时 181 行 `pub` 声明：2 enum / 22 struct / 2 trait / 6 const / 135 fn / 14 impl）；③ 实测测试汇总行（§7） |
| 未核实项 | 文中标 ⚠️ 且备注「待复核」者，均为仅凭契约/命名推断、本轮未逐行跑通的点 |

## 0. 判读约定

**状态图例**

| 标记 | 含义 |
|---|---|
| ✅ | 已对齐：vools 有对应符号，语义等价，已落地并有测试 |
| 🟡 | 语义等价但命名/签名调整（MoonBit 惯例或契约 §2 要求的 `Result` 化、`Option` 化） |
| ⚠️ | 部分实现：行为有已知差异，备注列写明差异与边界 |
| ⏳ | 计划对齐：Batch C/D 在途，按契约 §3 列出的目标形态，尚未落地 |
| ⛔ | 未做：说明原因（P1/P2 可缓、CLI 不迁、契约外） |

**目标可用性列**：`三目标` = wasm / js / native 全可用；`js` = 仅 js 目标有真实实现，其余目标返回可诊断 `Err` 或 `available()=false`（不是崩溃，也不是静默成功）。

**计数口径（§8 统计的依据）**：以 vools 的「模块级公开函数/类/公开常量 + 类的公开方法与公开属性」为 1 个符号；枚举**值**不单列（枚举类算 1 个）；私有（`_` 前缀）不计；dataclass 字段算公开属性各 1 个。

## 1. 总览

| vools 模块 | 符号数 | ✅ | 🟡 | ⚠️ | ⏳ | ⛔ | MoonBit 落地文件 |
|---|---:|---:|---:|---:|---:|---:|---|
| `core.py` | 5 | 5 | 0 | 0 | 0 | 0 | `rhop/core.mbt` |
| `envelope.py` | 17 | 17 | 0 | 0 | 0 | 0 | `rhop/envelope.mbt` |
| `signer.py` | 9 | 9 | 0 | 0 | 0 | 0 | `rhop/signer.mbt` |
| `integrity.py` | 4 | 4 | 0 | 0 | 0 | 0 | `rhop/integrity.mbt` |
| `crypto.py`（+key 常量） | 16 | 15 | 1 | 0 | 0 | 0 | `rhop/key.mbt`、`rhop/crypto.mbt` |
| `watch.py` | 4 | 2 | 1 | 1 | 0 | 0 | `rhop/watch.mbt` |
| `transport/base.py` | 14 | 14 | 0 | 0 | 0 | 0 | `rhop/transport_base.mbt` |
| `transport/local.py` | 1 | 1 | 0 | 0 | 0 | 0 | `rhop/transport_local.mbt` |
| `transport/endpoint.py` | 20 | 20 | 0 | 0 | 0 | 0 | `rhop/transport_endpoint.mbt` |
| `transport/online.py` | 16 | 8 | 0 | 0 | 0 | 8 | `rhop/online.mbt` |
| `transport/relay.py` | 9 | 9 | 0 | 0 | 0 | 0 | `rhop/relay.mbt` |
| `transport/selector.py` | 1 | 1 | 0 | 0 | 0 | 0 | `rhop/transport_selector.mbt` |
| `transport/shared.py` | 8 | 8 | 0 | 0 | 0 | 0 | `rhop/transport_base.mbt` |
| `session.py` | 7 | 7 | 0 | 0 | 0 | 0 | `rhop/session.mbt`（15 例） |
| `interact.py` | 2 | 2 | 0 | 0 | 0 | 0 | `rhop/interact.mbt`（13 例） |
| `config.py` | 11 | 11 | 0 | 0 | 0 | 0 | `rhop/config.mbt`（18 例） |
| `mirror.py` | 12 | 12 | 0 | 0 | 0 | 0 | `rhop/mirror.mbt`（11 例） |
| `daemon.py` | 4 | 3 | 0 | 0 | 0 | 1 | `rhop/daemon.mbt`（6 例全绿） |
| `requester.py` | 6 | 6 | 0 | 0 | 0 | 0 | `rhop/requester.mbt`（5 例全绿） |
| `executor.py` | 7 | 7 | 0 | 0 | 0 | 0 | `rhop/executor.mbt`（6 例） |
| `actions/__init__.py` | 2 | 2 | 0 | 0 | 0 | 0 | `rhop/actions.mbt` + `actions_test.mbt`（10 例） |
| `sync_folder.py` | 9 | 9 | 0 | 0 | 0 | 0 | `rhop/sync_folder.mbt`（5 例） |
| `clipboard.py` | 8 | 6 | 2 | 0 | 0 | 0 | `rhop/clipboard.mbt`（25 例，新包 test-suit/rhop_clipboard） |
| **契约范围小计** | **192** | **178** | **4** | **1** | **0** | **9** | — |
| `actions/jump.py` | 14 | 1 | 0 | 0 | 0 | 13 | 仅 `jump.probe` 内建（`actions_test.mbt` 覆盖） |
| `secret.py` | 1 | 0 | 0 | 0 | 0 | 1 | CLI 工具，不迁 |
| `task/` 子包（含 `task/store/`） | 230 | 0 | 21 | 0 | 0 | 209 | P2 已落地 P2a+P2b（8 文件 / **46·99·46** 例，见 §5.9；仅模块级映射，未逐符号） |
| **vools 全量** | **437** | **179** | **4** | **1** | **0** | **253** | — |

## 2. Batch A（协议/摘要层，已验收 · owner impl-core）

### 2.1 `core.py` → `rhop/core.mbt`（5/5 ✅）

| vools 符号 | MoonBit 符号（文件:符号） | 目标 | 测试 | 状态 | 备注 |
|---|---|---|---|---|---|
| `Side`（Enum，值 `"requester"`/`"executor"`） | `rhop/core.mbt: Side`（`pub(all) enum`） | 三目标 | `core_test.mbt`（10 例） | ✅ | 字面量与 vools 逐字一致 |
| `Side.other`（property） | `rhop/core.mbt: Side::other` | 三目标 | `core_test.mbt` | ✅ | 方法而非 property；含对合性用例 |
| `TaskStatus`（Enum，6 值小写） | `rhop/core.mbt: TaskStatus` | 三目标 | `core_test.mbt` | ✅ | 6 态字面量逐字一致 |
| `TaskStatus.can_transition` | `rhop/core.mbt: TaskStatus::can_transition` | 三目标 | `core_test.mbt` | ✅ | 6×6 全矩阵断言（合法边恰 6 条） |
| `TaskStatus.is_terminal`（property） | `rhop/core.mbt: TaskStatus::is_terminal` | 三目标 | `core_test.mbt` | ✅ | 并断言 `is_terminal ⇔ 无出边` |

### 2.2 `envelope.py` → `rhop/envelope.mbt`（17/17 ✅）

| vools 符号 | MoonBit 符号 | 目标 | 测试 | 状态 | 备注 |
|---|---|---|---|---|---|
| `Envelope` | `rhop/envelope.mbt: Envelope`（`pub struct`） | 三目标 | `envelope_test.mbt`（18 例） | ✅ | dataclass → struct；`Option` 表达 result/error/signature |
| `Envelope.task_id` | `Envelope.task_id` | 三目标 | `envelope_test.mbt` | ✅ | — |
| `Envelope.status` | `Envelope.status: TaskStatus` | 三目标 | 同上 | ✅ | — |
| `Envelope.payload` | `Envelope.payload: Json` | 三目标 | 同上 | ✅ | `dict` → `Json` |
| `Envelope.result` | `Envelope.result: Json?` | 三目标 | 同上 | ✅ | `None` ⇒ canon 里写 `null` |
| `Envelope.error` | `Envelope.error: String?` | 三目标 | 同上 | ✅ | — |
| `Envelope.side` | `Envelope.side: Side` | 三目标 | 同上 | ✅ | — |
| `Envelope.version` | `Envelope.version: Int` | 三目标 | 同上 | ✅ | — |
| `Envelope.created_at` | `Envelope.created_at: String` | 三目标 | 同上 | ✅ | — |
| `Envelope.updated_at` | `Envelope.updated_at: String` | 三目标 | 同上 | ✅ | — |
| `Envelope.hops_seen` | `Envelope.hops_seen: Array[String]` | 三目标 | 同上 | ✅ | 顺序保留有专门用例 |
| `Envelope.signature` | `Envelope.signature: String?` | 三目标 | 同上 | ✅ | — |
| `Envelope.checksum` | `Envelope.checksum: String` | 三目标 | 同上 | ✅ | `sha256:<64 hex>` |
| `Envelope.to_rhop_bytes` | `Envelope::to_rhop_bytes` | 三目标 | `envelope_test.mbt` | ✅ | 与 Python 逐字节一致（fixture 两例 + UTF-8 hex 比对） |
| `Envelope.from_rhop_bytes`（raise ValueError） | `Envelope::from_rhop_bytes -> Result[Envelope, String]` | 三目标 | 同上 | ✅ | `Result` 化（契约 §2.2）；错误文本含 `checksum mismatch` / `解析失败` / `缺少必填字段` |
| `Envelope.to_dict` | `Envelope::to_dict -> Json` | 三目标 | 同上 | ✅ | 无 `v` 键、有 `checksum`（与 vools 同） |
| `Envelope.from_dict` | `Envelope::from_dict -> Result[Envelope, String]` | 三目标 | 同上 | ✅ | checksum 缺省自动重算（`__post_init__` 语义） |

### 2.3 `signer.py` → `rhop/signer.mbt`（9/9 ✅）

| vools 符号 | MoonBit 符号 | 目标 | 测试 | 状态 | 备注 |
|---|---|---|---|---|---|
| `AbstractSigner` | `rhop/signer.mbt: AbstractSigner`（`pub trait`） | 三目标 | `signer_test.mbt`（9 例） | ✅ | trait 方法 `sign/verify` |
| `AbstractSigner.sign` | `AbstractSigner::sign -> String?` | 三目标 | 同上 | ✅ | `None` = 无法签名 |
| `AbstractSigner.verify` | `AbstractSigner::verify -> Bool` | 三目标 | 同上 | ✅ | — |
| `FileHashSigner` | `FileHashSigner`（空 struct） | 三目标 | 同上 | ✅ | — |
| `FileHashSigner.sign` | `impl AbstractSigner for FileHashSigner::sign` + 便捷 `FileHashSigner::signature` | 三目标 | 同上 | ✅ | **preimage 走 ensure_ascii=True**（见 §7 差异 2） |
| `FileHashSigner.verify` | `impl ... ::verify` | 三目标 | 同上 | ✅ | 正反例（错 result / 错 task_id / 错签名） |
| `NPUSigner` | `NPUSigner { marker, serial_provider }` | 三目标 | 同上 | ✅ | 不 spawn 子进程，provider 可注入 |
| `NPUSigner.sign` | `impl ... ::sign -> String?` | 三目标 | 同上 | ✅ | `<marker>:<serial>:<md5>`；默认 provider ⇒ `None` |
| `NPUSigner.verify` | `impl ... ::verify` | 三目标 | 同上 | ✅ | 无法签名时恒 `false`（与 vools 一致） |

### 2.4 `integrity.py` → `rhop/integrity.mbt`（4/4 ✅）

| vools 符号 | MoonBit 符号 | 目标 | 测试 | 状态 | 备注 |
|---|---|---|---|---|---|
| `IntegrityChecker` | `rhop/integrity.mbt: IntegrityChecker`（空 struct） | 三目标 | `integrity_test.mbt`（7 例） | ✅ | 无状态 |
| `IntegrityChecker.verify`（static） | `IntegrityChecker::verify(Envelope, Bytes) -> (Bool, String)` | 三目标 | 同上 | ✅ | 与 vools 同：只校验 raw，`env` 参数保留 |
| `IntegrityChecker.verify_bytes` | `IntegrityChecker::verify_bytes` | 三目标 | 同上 | ✅ | 坏 JSON / 错 checksum / 零长度 均有用例 |
| `IntegrityChecker.checksum_match` | `IntegrityChecker::checksum_match` | 三目标 | 同上 | ✅ | 序列化→反序列化比对；篡改 checksum ⇒ false |

## 3. Batch B（密码学 + 介质层，已落地 · owner impl-crypto）

### 3.1 `crypto.py` + key 常量 → `rhop/key.mbt`、`rhop/crypto.mbt`（16：15 ✅ / 1 🟡）

| vools 符号 | MoonBit 符号 | 目标 | 测试 | 状态 | 备注 |
|---|---|---|---|---|---|
| `ENV_RHOP_KEY = "RHOP_KEY"` | `rhop/key.mbt: ENV_RHOP_KEY` | 三目标 | `rhop_js/crypto_test.mbt`（24 例） | ✅ | — |
| `SECRET_PREFIX = "RHOP-ENC:"` | `rhop/key.mbt: SECRET_PREFIX` | 三目标 | 同上 | ✅ | — |
| `VerifyResult`（NamedTuple） | `rhop/key.mbt: VerifyResult`（struct） | 三目标 | 同上 | ✅ | NamedTuple → struct |
| `VerifyResult.ok` | `VerifyResult.ok: Bool` | 三目标 | 同上 | ✅ | — |
| `VerifyResult.payload` | `VerifyResult.payload: Json?` | 三目标 | 同上 | ✅ | — |
| `VerifyResult.reason` | `VerifyResult.reason: String` | 三目标 | 同上 | ✅ | 三态 `OK`/`MALFORMED`/`BAD_TOKEN`/`NOT_JSON` 保留原字面量 |
| `load_key(source, path, env_name)` | `rhop/key.mbt: load_key -> Result[String, String]` | 三目标（path 分支仅 js） | 同上 | ✅ | 优先级 source > path > env |
| `is_secret(value)` | `key.mbt: is_secret` | 三目标 | 同上 | ✅ | — |
| `RhopCrypto` | `rhop/crypto.mbt: RhopCrypto` | 三目标（Fernet 原语仅 js） | 同上 | ✅ | 结构/校验三目标；加解密 js |
| `RhopCrypto.from_key` | `RhopCrypto::from_key` | 三目标 | 同上 | ✅ | — |
| `RhopCrypto.from_path` | `RhopCrypto::from_path -> Result` | js | 同上 | ✅ | 非 js 返回可诊断 `Err` |
| `RhopCrypto.from_env` | `RhopCrypto::from_env -> Result` | 三目标 | 同上 | ✅ | `@env.get_env_var` |
| `RhopCrypto.encrypt_json` | `RhopCrypto::encrypt_json -> String` | js | 同上 | ✅ | 输出 `{"v":1,"alg":"fernet","ct":…}`；失败返回 `""`（另给 `encrypt_json_result` 诊断） |
| `RhopCrypto.decrypt_verify` | `RhopCrypto::decrypt_verify -> VerifyResult` | js | 同上 | ✅ | 非 js 一律 `BAD_TOKEN` |
| `RhopCrypto.encrypt_secret` | `RhopCrypto::encrypt_secret` | js | 同上 | ✅ | `RHOP-ENC:` 前缀 |
| `RhopCrypto.decrypt_secret`（返回 str / 抛错） | `RhopCrypto::decrypt_secret -> Result[String, String]` | js | 同上 | 🟡 | `Result` 化（契约 §2.2）：前缀不符/密钥不符/篡改均为可诊断 `Err` |

### 3.2 `watch.py` → `rhop/watch.mbt`（4：2 ✅ / 1 🟡 / 1 ⚠️）

| vools 符号 | MoonBit 符号 | 目标 | 测试 | 状态 | 备注 |
|---|---|---|---|---|---|
| `RhopWatcher.__init__(shared_path, crypto, on_packet, extensions, backend, interval)` | `rhop/watch.mbt: RhopWatcher::new(path, crypto)` + `with_extensions` + `skip_existing` + `observe` | js / native | `rhop_js/watch_test.mbt`（6 例） | 🟡 | 构造参数拆成 wither + 响应式 `observe()`（契约 §2.6 要求复用 `@monitor`/`@rx`）；wasm 下 `start` 返回可诊断 `Err` |
| `RhopWatcher.start`（抛错） | `RhopWatcher::start -> Result[Unit, String]` | js / native | 同上 | ✅ | `Result` 化；wasm 明确「仅 js/native 有监控后端」 |
| `RhopWatcher.stop` | `RhopWatcher::stop` | js / native | 同上 | ✅ | 幂等 |
| `DEFAULT_EXTENSIONS = (".rhop",)` | 默认值内建，经 `RhopWatcher::extensions()` 读出 | js / native | 同上 | ⚠️ | 无独立公开常量（等价信息可通过访问器获得）；默认为 `.rhop` |

### 3.3 `transport/base.py` → `rhop/transport_base.mbt`（14/14 ✅）

| vools 符号 | MoonBit 符号 | 目标 | 测试 | 状态 | 备注 |
|---|---|---|---|---|---|
| `SharedPath`（ABC） | `transport_base.mbt: SharedPath`（`pub(open) trait`） | 三目标 | `rhop_js/transport_test.mbt`（16 例） | ✅ | 用 `&SharedPath` trait object |
| `SharedPath.available` | `SharedPath::available` | 三目标 | 同上 | ✅ | — |
| `SharedPath.write_text`（返回 str） | `SharedPath::write_text -> Result[Unit, String]` | 三目标 | 同上 | ✅ | `Result` 化 |
| `SharedPath.read_text` | `SharedPath::read_text -> Result[String, String]` | 三目标 | 同上 | ✅ | 不存在 ⇒ 可诊断 `Err` |
| `SharedPath.exists` | `SharedPath::exists` | 三目标 | 同上 | ✅ | — |
| `SharedPath.remove` | `SharedPath::remove -> Result` | 三目标 | 同上 | ✅ | 幂等（不存在视为成功） |
| `OnlineChannel`（ABC） | `OnlineChannel`（`pub(open) trait`） | 三目标 | 同上 | ✅ | — |
| `OnlineChannel.available` | `OnlineChannel::available` | 三目标 | 同上 | ✅ | 真实探测，失败 false 不崩 |
| `OnlineChannel.send` | `OnlineChannel::send -> Result` | 三目标 | 同上 | ✅ | 无凭据时返回可诊断 `Err`，不静默成功 |
| `OnlineChannel.receive` | `OnlineChannel::receive -> Result` | 三目标 | 同上 | ✅ | — |
| `TransportSelection`（NamedTuple） | `TransportSelection`（struct） | 三目标 | 同上 | ✅ | 另有 `to_json`/`to_string` |
| `TransportSelection.transport` | `TransportSelection.transport: String` | 三目标 | 同上 | ✅ | `"online"`/`"shared"`/`"none"` |
| `TransportSelection.is_online` | `TransportSelection.is_online: Bool` | 三目标 | 同上 | ✅ | — |
| `TransportSelection.reason` | `TransportSelection.reason: String` | 三目标 | 同上 | ✅ | — |

### 3.4 `transport/local.py` → `rhop/transport_local.mbt`（1/1 ✅）

| vools 符号 | MoonBit 符号 | 目标 | 测试 | 状态 | 备注 |
|---|---|---|---|---|---|
| `LocalSharedPath` | `transport_local.mbt: LocalSharedPath` + `impl SharedPath` | js（写读）；其他目标 `available()=false`/`Err` | `rhop_js/transport_test.mbt` | ✅ | 原子写（tmp + rename）、路径统一 `/`、无 tmp 残留有用例 |

### 3.5 `transport/endpoint.py` → `rhop/transport_endpoint.mbt`（20/20 ✅，全部 js）

| vools 符号 | MoonBit 符号 | 目标 | 测试 | 状态 | 备注 |
|---|---|---|---|---|---|
| `EndpointView`（ABC） | `transport_endpoint.mbt: EndpointView`（`pub(open) trait`） | js | `rhop_js/transport_test.mbt` | ✅ | 另加 `kind`/`name`（增量） |
| `EndpointView.available` | `EndpointView::available` | js | 同上 | ✅ | — |
| `EndpointView.exists` | `EndpointView::exists` | js | 同上 | ✅ | — |
| `EndpointView.read_text` | `EndpointView::read_text -> Result` | js | 同上 | ✅ | — |
| `EndpointView.write_text` | `EndpointView::write_text -> Result` | js | 同上 | ✅ | — |
| `EndpointView.remove` | `EndpointView::remove -> Result` | js | 同上 | ✅ | — |
| `LocalEndpoint` | `LocalEndpoint`（另 `impl SharedPath`） | js | 同上 | ✅ | — |
| `LocalEndpoint.available` | 经 `impl EndpointView` | js | 同上 | ✅ | — |
| `LocalEndpoint.exists` | 经 `impl EndpointView` | js | 同上 | ✅ | — |
| `LocalEndpoint.read_text` | 经 `impl EndpointView` | js | 同上 | ✅ | — |
| `LocalEndpoint.write_text` | 经 `impl EndpointView` | js | 同上 | ✅ | — |
| `LocalEndpoint.remove` | 经 `impl EndpointView` | js | 同上 | ✅ | — |
| `FileUrlEndpoint` | `FileUrlEndpoint::new -> Result` | js | 同上 | ✅ | 解析 `file://` |
| `HttpEndpoint` | `HttpEndpoint::new(base, token?, timeout_ms)` | js | 同上 | ✅ | WebDAV 风格 PUT/GET/DELETE |
| `HttpEndpoint.available` | 经 `impl EndpointView` | js | 同上 | ✅ | 不可达 ⇒ false |
| `HttpEndpoint.exists` | 经 `impl EndpointView` | js | 同上 | ✅ | — |
| `HttpEndpoint.read_text` | 经 `impl EndpointView` | js | 同上 | ✅ | — |
| `HttpEndpoint.write_text` | 经 `impl EndpointView` | js | 同上 | ✅ | — |
| `HttpEndpoint.remove` | 经 `impl EndpointView` | js | 同上 | ✅ | — |
| `parse_endpoint(spec)` | `parse_endpoint -> Result[&EndpointView, String]` | js | 同上 | ✅ | 裸路径 / `file://` / `http(s)://` 三分支 |

### 3.6 `transport/online.py` → `rhop/online.mbt`（16：8 ✅ / 8 ⛔）

| vools 符号 | MoonBit 符号 | 目标 | 测试 | 状态 | 备注 |
|---|---|---|---|---|---|
| `GitChannel` | `online.mbt: GitChannel` + `with_branch`/`with_timeout` | js | `rhop_js/transport_test.mbt` | ✅ | — |
| `GitChannel.available` | `GitChannel::available` | js | 同上 | ✅ | 真跑 `git ls-remote`；git 不存在 ⇒ false |
| `GitChannel.send` | `GitChannel::send -> Result` | js | 同上 | ✅ | 无凭据 ⇒ 可诊断 `Err` |
| `GitChannel.receive` | `GitChannel::receive -> Result` | js | 同上 | ✅ | — |
| `SftpChannel` | `SftpChannel` + `with_username`/`with_timeout` | js | 同上 | ✅ | — |
| `SftpChannel.available` | `SftpChannel::available` | js | 同上 | ✅ | TCP 端口探测 |
| `SftpChannel.send` | `SftpChannel::send -> Result` | js | 同上 | ✅ | 无 paramiko 等价能力 ⇒ 可诊断 `Err` |
| `SftpChannel.receive` | `SftpChannel::receive -> Result` | js | 同上 | ✅ | — |
| `SftpChannel.put` | — | — | — | ⛔ | 契约 §3 未列入；SFTP 远端文件级操作属 P2（本项目不引入 paramiko） |
| `SftpChannel.get` | — | — | — | ⛔ | 同上 |
| `SftpChannel.read_text` | — | — | — | ⛔ | 同上 |
| `SftpChannel.write_text` | — | — | — | ⛔ | 同上 |
| `SftpChannel.exists` | — | — | — | ⛔ | 同上 |
| `SftpChannel.listdir` | — | — | — | ⛔ | 同上 |
| `SftpChannel.mkdirs` | — | — | — | ⛔ | 同上 |
| `SftpChannel.close` | — | — | — | ⛔ | 同上（无连接对象可关） |

### 3.7 `transport/relay.py` → `rhop/relay.mbt`（9/9 ✅，全部 js）

| vools 符号 | MoonBit 符号 | 目标 | 测试 | 状态 | 备注 |
|---|---|---|---|---|---|
| `RelayServer` | `relay.mbt: RelayServer::new(host, port, token?, ttl_sec)` | js | `rhop_js/relay_test.mbt`（5 例） | ✅ | 服务跑在子进程（避免同进程事件循环互堵） |
| `RelayServer.url`（property） | `RelayServer::url` | js | 同上 | ✅ | — |
| `RelayServer.start` | `RelayServer::start -> Result` | js | 同上 | ✅ | — |
| `RelayServer.stop` | `RelayServer::stop` | js | 同上 | ✅ | 幂等 |
| `RelayServer.alive` | `RelayServer::alive` / `process_alive` | js | 同上 | ✅ | 额外给出进程级判活 |
| `RelayChannel` | `RelayChannel::new(base, timeout_ms, token?, ttl_sec)` | js | `rhop_js/relay_test.mbt` | ✅ | — |
| `RelayChannel.available` | `RelayChannel::available` | js | 同上 | ✅ | — |
| `RelayChannel.send` | `RelayChannel::send -> Result` | js | 同上 | ✅ | — |
| `RelayChannel.receive` | `RelayChannel::receive -> Result` | js | 同上 | ✅ | 单机 A→C→B 回环有用例 |

### 3.8 `transport/selector.py` → `rhop/transport_selector.mbt`（1/1 ✅）

| vools 符号 | MoonBit 符号 | 目标 | 测试 | 状态 | 备注 |
|---|---|---|---|---|---|
| `select_transport(online, shared)` | `transport_selector.mbt: select_transport(Array[&OnlineChannel], &SharedPath?) -> TransportSelection` | 三目标 | `rhop_js/transport_test.mbt` | ✅ | 在线优先 → shared 回退 → 全不可达；另有 `any_online_available`（增量） |

### 3.9 `transport/shared.py` → `rhop/transport_base.mbt`（8/8 ✅）

| vools 符号 | MoonBit 符号 | 目标 | 测试 | 状态 | 备注 |
|---|---|---|---|---|---|
| `SharedPathView` | `transport_base.mbt: SharedPathView` + `impl SharedPath` | 三目标（真实 IO 依赖底层） | `rhop_js/transport_test.mbt` | ✅ | 读写分离视图 |
| `SharedPathView.root`（property） | `SharedPath::root`（impl） | 同上 | 同上 | ✅ | — |
| `SharedPathView.available` | `impl SharedPath::available` | 同上 | 同上 | ✅ | 读写两侧都可用才算可用 |
| `SharedPathView.write_text` | `impl SharedPath::write_text` | 同上 | 同上 | ✅ | — |
| `SharedPathView.read_text` | `impl SharedPath::read_text` | 同上 | 同上 | ✅ | — |
| `SharedPathView.exists` | `impl SharedPath::exists` | 同上 | 同上 | ✅ | — |
| `SharedPathView.remove` | `impl SharedPath::remove` | 同上 | 同上 | ✅ | — |
| `make_shared_path(write_spec, read_spec?)` | `make_shared_path -> Result[SharedPathView, String]`（另有 `make_shared_path_from_views`，增量） | js（解析 endpoint） | 同上 | ✅ | 读写分离视图转换 |

## 4. Batch C（会话／配置／交互）· 已落地 · owner impl-session

> 三个文件均已于 2026-10-28 落地（`rhop/session.mbt` / `rhop/config.mbt` / `rhop/interact.mbt`），
> 测试：`session_test.mbt` 15 例、`config_test.mbt` 18 例（都在 `test-suit/rhop`，wasm/js/native 三目标绿）、
> `interact_test.mbt` 13 例（`test-suit/rhop_interact`，js）。

### 4.1 `session.py` → `rhop/session.mbt`（7/7 ✅）

| vools 符号 | MoonBit 符号（文件:符号） | 目标 | 测试 | 状态 | 备注 |
|---|---|---|---|---|---|
| `Role`（SEND/RECV/RELAY） | `session.mbt: Role`（`pub(all) enum` Send/Recv/Relay）+ `parse`/`to_string`/`lower` | 三目标 | `session_test.mbt` | ✅ | 字面量 `send`/`recv`/`relay`；`lower()` 为增量 |
| `Session` | `Session { role; shared; online; relay; crypto; name }` | 三目标 | 同上 | ✅ | 另有 `new`/`empty` 构造器 |
| `Session.available` | `Session::available` | 三目标 | 同上 | ✅ | 有介质/通道即可用 |
| `Session.send_package` | `Session::send_package -> Result[Json, String]` | 三目标 | 同上 | ✅ | 回执 `{status, transport, filename, payload}` 同形 |
| `Session.recv_package` | `Session::recv_package -> Result[Json, String]` | 三目标 | 同上 | ✅ | — |
| `Session.reverse` | `Session::reverse` | 三目标 | 同上 | ✅ | 复用介质、交换方向 |
| `Session.describe` | `Session::describe -> Json` | 三目标 | 同上 | ✅ | 诊断视图 |

### 4.2 `interact.py` → `rhop/interact.mbt`（2/2 ✅）

| vools 符号 | MoonBit 符号 | 目标 | 测试 | 状态 | 备注 |
|---|---|---|---|---|---|
| `interact(cfg, action, payload, mode)` | `interact.mbt: interact(RhopConfig, String, Json?, String, request_filename?) -> Result[Json, String]` | 三目标 | `rhop_interact/interact_test.mbt`（13 例） | ✅ | mode：`execute`/`request`/`roundtrip` |
| `handle_request(cfg, filename, session?)` | `interact.mbt: handle_request(RhopConfig, String, session? : Session) -> Result[Json, String]` | 三目标 | 同上 | ✅ | 回传 `res_` 前缀文件 |

### 4.3 `config.py` → `rhop/config.mbt`（11/11 ✅）

| vools 符号 | MoonBit 符号 | 目标 | 测试 | 状态 | 备注 |
|---|---|---|---|---|---|
| `RhopConfig` | `config.mbt: RhopConfig`（key/role/sftp/online/shared/relay/name） | 三目标 | `config_test.mbt`（18 例） | ✅ | — |
| `RhopConfig.from_dict` | `RhopConfig::from_dict -> Result` | 三目标 | 同上 | ✅ | 未知 role / 缺 key 都有可诊断 Err |
| `RhopConfig.from_file` | `RhopConfig::from_file -> Result` | js（读文件） | 同上 | ✅ | 非 js 返回可诊断 Err |
| `RhopConfig.to_dict` | `RhopConfig::to_dict -> Json` | 三目标 | 同上 | ✅ | 敏感字段脱敏：`sftp.password` / `sftp.key_path` → `"***"`（与 vools 同） |
| `RhopConfig.build_crypto` | `build_crypto -> RhopCrypto` | 三目标 | 同上 | ✅ | — |
| `RhopConfig.build_online` | `build_online -> Result[Array[&OnlineChannel], String]` | 三目标 | 同上 | ✅ | git/sftp/relay 配置 → 通道数组 |
| `RhopConfig.build_shared` | `build_shared -> Result[SharedPathView?, String]` | js（真实介质） | 同上 | ✅ | — |
| `RhopConfig.build_relay` | `build_relay -> Result[RelayChannel?, String]` | 三目标 | 同上 | ✅ | — |
| `RhopConfig.build_session` | `build_session(role?) -> Result[Session, String]` | 三目标 | 同上 | ✅ | 角色可覆盖 |
| `RhopConfig.action_cfg` | `action_cfg -> Json` | 三目标 | 同上 | ✅ | 动作层视图（脱敏后） |
| `load_config(path_or_dict)` | `config.mbt: load_config(Json) -> Result[RhopConfig, String]` | 三目标 | 同上 | ✅ | vools 接受路径或 dict；本项目路径分支由 `from_file` 承担 |

> 有意增量：`_key_from_cfg`（vools 私有名公开化，供动作层复用）、`RhopConfig::new/has_key/name/role`。

## 5. Batch D（业务层：镜像／守护／需求端／执行端／动作／同步／剪贴板）· 已落地 · owner impl-business

> 六个业务文件 + clipboard 均已落地。测试分布：
> `test-suit/rhop_business`（mirror 11 / executor 6 / requester 5 / daemon 6 / sync_folder 5 / sync_glob 5 / nonjs 5 例）、
> `test-suit/rhop_clipboard`（25 例）、`test-suit/rhop_interact`（13 例）。
> **在途项**：daemon 2 例、requester 2 例当前失败（Batch D 收尾中，见 §11），故对应行标 ⚠️ 备注。

### 5.1 `mirror.py` → `rhop/mirror.mbt`（12/12 ✅）

| vools 符号 | MoonBit 符号 | 目标 | 测试 | 状态 | 备注 |
|---|---|---|---|---|---|
| `SCHEMA_SQL` | 内建建表 SQL（实现细节，不公开） | js | `mirror_test.mbt`（11 例） | ✅ | `node:sqlite` |
| `StaleVersionError` | `mirror.mbt: StaleVersionError` + `is_stale_version_error(String)` | js | 同上 | ✅ | 乐观锁冲突 → Err 中带标记，便于区分 |
| `MirrorDB` | `MirrorDB::open(path)` / `open_temp()` | js | 同上 | ✅ | `open_temp` 为增量（测试用临时库） |
| `MirrorDB.upsert_task` | `MirrorDB::upsert_task(Envelope) -> Result` | js | 同上 | ✅ | 版本冲突走 `StaleVersionError` 语义 |
| `MirrorDB.get_task` | `MirrorDB::get_task -> Envelope?`（另有 `try_get_task`） | js | 同上 | ✅ | — |
| `MirrorDB.list_tasks` | `MirrorDB::list_tasks(status?, limit?)` | js | 同上 | ✅ | — |
| `MirrorDB.update_status` | `MirrorDB::update_status(id, status, version, result?, error?, signature?)` | js | 同上 | ✅ | 乐观锁 version |
| `MirrorDB.claim_task` | `MirrorDB::claim_task(...)` + `claim_next` | js | 同上 | ✅ | `claim_next` 为增量 |
| `MirrorDB.count_by_status` | `MirrorDB::count_by_status -> Json`（+ `count_by_status_full`） | js | 同上 | ✅ | — |
| `MirrorDB.log_sync` | `MirrorDB::log_sync(...)` | js | 同上 | ✅ | — |
| `MirrorDB.pending_sync` | `MirrorDB::pending_sync(since?)` | js | 同上 | ✅ | — |
| `MirrorDB.close` | `MirrorDB::close` / `is_open` | js | 同上 | ✅ | 幂等 |

### 5.2 `daemon.py` → `rhop/daemon.mbt`（4：3 ✅ / 1 ⛔）

| vools 符号 | MoonBit 符号 | 目标 | 测试 | 状态 | 备注 |
|---|---|---|---|---|---|
| `RelayDaemon` | `daemon.mbt: RelayDaemon` | js | `rhop_business/daemon_test.mbt`（6 例） | ✅ | 单机 A→中继→B 闭环用例 |
| `RelayDaemon.start` | `RelayDaemon::start(poll_interval_ms)` | js | 同上 | ✅ | 2026-10-28 复核：6 例全绿 |
| `RelayDaemon.stop` | `RelayDaemon::stop` | js | 同上 | ✅ | 同上 |
| `main()`（CLI） | — | — | — | ⛔ | 不迁 CLI；行为方法 `run_once`/`process_inbox`/`push_local`/`pull_remote` 已作为公开 API 提供 |

### 5.3 `requester.py` → `rhop/requester.mbt`（6/6 ✅）

| vools 符号 | MoonBit 符号 | 目标 | 测试 | 状态 | 备注 |
|---|---|---|---|---|---|
| `Requester` | `requester.mbt: Requester` | js | `requester_test.mbt`（5 例） | ✅ | `from_config_dir` / `from_mirror_path` 为增量 |
| `Requester.submit` | `Requester::submit(task_id, payload)` | js | 同上 | ✅ | — |
| `Requester.get_result` | `Requester::get_result -> Json?`（+ `wait_result`） | js | 同上 | ✅ | `wait_result` 为增量（轮询等待） |
| `Requester.list_tasks` | `Requester::list_tasks(status?)` | js | 同上 | ✅ | — |
| `Requester.cancel` | `Requester::cancel(task_id)` | js | 同上 | ✅ | — |
| `Requester.close` | `Requester::close` | js | 同上 | ✅ | — |

> 2026-10-28 复核：5 例全绿（此前「落 inbox 文件模式」「单机闭环」两例已修复）。

### 5.4 `executor.py` → `rhop/executor.mbt`（7/7 ✅）

| vools 符号 | MoonBit 符号 | 目标 | 测试 | 状态 | 备注 |
|---|---|---|---|---|---|
| `Executor` | `executor.mbt: Executor` | js | `executor_test.mbt`（6 例） | ✅ | — |
| `Executor.claim` | `Executor::claim -> Result[Envelope?, String]` | js | 同上 | ✅ | — |
| `Executor.execute` | `Executor::execute(Envelope)`（+ `execute_next`） | js | 同上 | ✅ | `execute_next` 为增量 |
| `Executor.report_result` | `Executor::report_result(task_id, result)` | js | 同上 | ✅ | — |
| `Executor.report_failure` | `Executor::report_failure(task_id, error)` | js | 同上 | ✅ | — |
| `Executor.list_pending` | `Executor::list_pending -> Array[Json]` | js | 同上 | ✅ | — |
| `Executor.close` | `Executor::close` | js | 同上 | ✅ | — |

### 5.5 `actions/__init__.py` → `rhop/actions.mbt`（2/2 ✅，`actions_test.mbt` 10 例）；`actions/jump.py`（14：1 ✅ / 13 ⛔）

| vools 符号 | MoonBit 符号 | 目标 | 测试 | 状态 | 备注 |
|---|---|---|---|---|---|
| `run_action(action, cfg, payload)` | `actions.mbt: run_action` | 三目标 | `test-suit/rhop/actions_test.mbt`（10 例） | ✅ | 未知动作返回可用清单 |
| `omega_unwrap(result)` | `actions.mbt: omega_unwrap` | 三目标 | 同上 | ✅ | 成功/partial/外层异常/data 缺失/内层失败 五形态 |
| `jump_probe(cfg, payload)` | 内置动作 `jump.probe`（离线：校验 sftp 配置返回结构化探测） | 三目标 | 同上 | ✅ | 不真连网；出参四字段对齐 vools |
| `jump_push` / `jump_pull` / `jump_sync` | — | — | — | ⛔ | 需真实 SFTP，P2 |
| `compute_sync_plan` / `scan_local_files` / `scan_remote_files_paramiko` / `collect_files` / `should_exclude` | — | — | — | ⛔ | 目录同步扫描族，P2 |
| `SFTP_KIND_*` / `PARAMIKO_HINT` / `ACTIONS` 常量 | — | — | — | ⛔ | 随上面 API 一起 P2 |

### 5.6 `sync_folder.py` → `rhop/sync_folder.mbt`（9/9 ✅）

| vools 符号 | MoonBit 符号 | 目标 | 测试 | 状态 | 备注 |
|---|---|---|---|---|---|
| `MANIFEST_NAME` | `sync_folder.mbt: SYNC_MANIFEST_NAME` 常量 | 三目标 | `sync_folder_test.mbt`（5 例）、`sync_glob_test.mbt`（5 例） | ✅ | 值为 `.sync_manifest.json` |
| `LocalDirSource` | 由 `SyncFolder::new(source, target, pattern)` 承担（源目录即本地目录） | js | 同上 | ✅ | 无独立 Source 抽象（差异见 §7） |
| `LocalDirSource.list_files` | `SyncFolder::sync_once` 内部列举（`sync_glob_match` 公开） | js | 同上 | ✅ | — |
| `LocalDirSource.open_bytes` | 内部读取 | js | 同上 | ✅ | — |
| `LocalDirSource.describe` | — | — | — | ✅ | 由 `sync_once` 回执承载（无独立 describe） |
| `SyncFolder` | `SyncFolder::new(source, target, pattern)` | js | 同上 | ✅ | `with_recursive` 为增量 |
| `SyncFolder.sync_once` | `SyncFolder::sync_once -> Json` | js | 同上 | ✅ | 幂等（manifest 去重） |
| `SyncFolder.run_forever` | `SyncFolder::run_forever(...) -> Json` + `stop()` | js | 同上 | ✅ | 同步批处理语义（非阻塞流） |
| `sync_folder_once` | 便捷路径 = `SyncFolder::new(...).sync_once()` | js | 同上 | ✅ | 无独立自由函数（差异见 §7） |

### 5.7 `clipboard.py` → `rhop/clipboard.mbt`（8：6 ✅ / 2 🟡）· **本轮新增**

| vools 符号 | MoonBit 符号 | 目标 | 测试 | 状态 | 备注 |
|---|---|---|---|---|---|
| `CLIP_FILE = "clipboard.txt"` | `clipboard.mbt: CLIP_FILE` | 三目标 | `rhop_clipboard/clipboard_test.mbt`（25 例） | ✅ | 常量逐字一致 |
| `get_clipboard_backend()` | `get_clipboard_backend() -> &ClipboardBackend?` + `get_clipboard_backend_name()` | js（非 js 恒 None） | 同上 | 🟡 | trait object 取代 `(read_fn, write_fn, name)` 三元组；名字走独立函数 |
| `read_clipboard(backend?)` | `read_clipboard(backend?) -> String` | js | 同上 | ✅ | 失败返回 `""`，原因进 `last_read_reason()` |
| `write_clipboard(text, backend?)` | `write_clipboard(text, backend?) -> Bool` | js | 同上 | ✅ | — |
| `last_read_reason()` | `last_read_reason() -> String` | 三目标 | 同上 | ✅ | 成功清空、失败给可诊断原因 |
| `ClipboardFileSync` | `ClipboardFileSync::new(directory, role?, filename?, backend?, writer?, auto_detect?)` | 三目标（状态机）；文件/剪贴板 IO 仅 js | 同上 | ✅ | role 仅 push/pull，其它 `Err`；构造尽力建目录 |
| `ClipboardFileSync.sync_once` | `ClipboardFileSync::sync_once -> Json`（+ `sync_rounds(n)`） | 三目标 | 同上 | ✅ | `{changed, reason, text_len?, from_writer?}` 与 vools 同形；`sync_rounds` 为增量 |
| `ClipboardFileSync.run_forever` | `ClipboardFileSync::run_forever(poll_interval_ms?) -> @rx.Observable[Json, String]` | js（非 js 只推首轮） | 同上 | 🟡 | 响应式流（订阅即首轮 + 定时推送 + dispose 停止）取代阻塞线程 |

> 交换文件 `{"text","updated_at","writer"}` 原子写（tmp+rename）；`text_len` 用码点计数对齐 Python `len`。
> 测试覆盖：push/pull 全状态机、无后端空转不写坏文件、写失败可诊断、坏 JSON、1MB 文本、中文/emoji 码点、端到端 p0→share→p1、run_forever 首轮 + dispose。

### 5.8 `secret.py`（1 ⛔）

| vools 符号 | 说明 | 状态 |
|---|---|---|
| `secret.py: main` | 命令行「生成/查看密钥」工具 | ⛔ 不迁 CLI（密钥读取走 `rhop/key.mbt` 的 `load_key`） |

### 5.9 P2：`task/` 子包（230）→ `rhop_task/`（**P2a + P2b 已落地**）

> vools `task/` 是独立的通用任务队列（A 提交加密 JSON → B 解密执行；SQLite 管依赖/状态；存储可换后端）。
> 契约 §3 把它列为 P2（「不列入本轮验收硬门槛」）。本项目已分两批落地：
> **P2a**（数据/配置/密文）+ **P2b**（存储/队列/心跳/执行/同步），共 8 个文件；
> 测试 `test-suit/rhop_task`：**wasm/native 46 例、js 99 例，全绿**（7 个测试文件 js-only，含与真 vools Heartbeat 的双向互操作用例）。

| vools 模块 | MoonBit 文件 | 关键符号 | 状态 | 测试 |
|---|---|---|---|---|
| `task/models.py` | `rhop_task/task_models.mbt` | `TaskState`（+`can_transition`/`to_status`/`from_status`）、`TaskRecord`（`new`/`with_*` 15 个 wither/`validate`/`to_dict`/`from_dict`）、ISO 时间工具（`utcnow_iso`/`parse_iso`/`to_iso`/`iso_add_seconds`） | ✅ P2a | `task_models_test.mbt`（20 例，三目标） |
| `task/config.py` | `rhop_task/task_config.mbt` | `TaskRole`、`normalize_role`、`TaskConfig`（`from_dict`/`from_json_text`/`from_file`/`to_dict(mask)`/`describe`/`build_crypto`/`worker_id`/`plaintext_findings`）、`load_task_config`、`default_queue`/`default_exec` | ✅ P2a | `task_config_test.mbt`（13 例三目标）+ `task_config_js_test.mbt`（7 例 js） |
| `task/secrets.py` | `rhop_task/task_secrets.mbt` | `SecretResolver`（`resolve`/`flag_plaintext`/`findings`）、`SecretFinding`、`SecretField`、`find_secret_fields`、`is_sensitive_leaf`、`mask_value(_default)`、`command_hint`、`plaintext_message` | ✅ P2a | `task_secrets_test.mbt`（13 例三目标）+ `task_secrets_js_test.mbt`（4 例 js） |
| `task/store/`（base + sqlite） | `rhop_task/task_store.mbt` | `TaskStoreSpec::for_kind`、`schema_sql`、`SqliteTaskStore`（`open`/`init_schema`/`insert_tasks`/`claim_next`/`set_state`/`update_fields`/`clean_stale_locks`/`requeue`/`set_cancel_requested`/`get_task`/`list_tasks`/`count_by_state`/`active_tasks`/`is_all_done`/`summary`/`apply_task`/`describe`/`close`） | ✅ P2b | `task_store_test.mbt`（8 例 js，`node:sqlite`） |
| `task/queue.py` | `rhop_task/task_queue.mbt` | `TaskQueue`（`new`/`from_config`/`submit`/`claim`/`mark_running`/`mark_done`/`mark_failed`/`cancel`/`retry_failed`/`requeue`/`list_tasks`/`status_counts`/`decrypt_payload`/`verify_payload_sha`/`crypto_enabled`/`close`） | ✅ P2b | `task_queue_test.mbt`（7 例 js） |
| `task/heartbeat.py` | `rhop_task/task_heartbeat.mbt` | `Heartbeat`（`new`/`from_config`/`beat`/`mark_closed`/`read`/`is_alive`/`check`/`clear`/`filename`/`stale_after_sec`）、`HeartbeatSnapshot`、`HeartbeatPump`（`start`/`stop`/`shutdown`/`is_running`/`last_ok`） | ✅ P2b | `task_heartbeat_test.mbt`（5 例 js） |
| `task/exec.py` | `rhop_task/task_exec.mbt` | `ExecPolicy`（`new`/`default`/`from_config`/`allows`）、`ExecResult`、`register_handler`/`get_handler`/`list_handlers`/`clear_handlers`、`detect_language`、`run_payload` | ✅ P2b | `task_exec_test.mbt`（8 例 js） |
| `task/sync.py` | `rhop_task/task_sync.mbt` | `TaskSync`（`new`/`peer`/`pending_count`/`pending_tasks`/`export_pending`/`import_pack`/`mark_synced`/`export_and_mark`） | ✅ P2b | `task_sync_test.mbt`（5 例 js） |
| `task/cli.py` / `task/__main__.py` | — | — | ⛔ CLI 不迁 | — |
| `task/daemon.py`（`TaskDaemon`/`build_queue`） | — | — | ⛔ 未移植（中继守护的 task 版；`rhop/daemon.mbt` 已覆盖镜像 daemon） | — |
| `task/local_runner.py`（`run_local_task`/`should_run_local`/`mark_local_result`） | — | — | ⛔ 未移植（本机执行器快捷路径） | — |
| `task/errors.py`（`RhopTaskError`/`DagValidationError`/`TaskNotFound`/… 10 个异常类型） | 以 `Result[_, String]` + 文本前缀表达（如 `stale_version:`） | — | 🟡 语义等价（错误类型 → Result） | — |
| `task/store/pg_store.py`（Postgres 后端） | — | — | ⛔ 未移植（仅 SQLite 后端） | — |

**P2 映射现状（诚实口径）**：8 个文件对应 vools `task/` 的 models/config/secrets/store/queue/heartbeat/exec/sync；
vools `task/` 共 230 个公开符号，本项目**按模块级对位 21 个关键符号**（见上表「关键符号」列），
其余为 CLI / daemon / local_runner / Postgres 后端等明确未移植项 —— **逐符号映射留待后续（P2b-2）**，
故 P2 不参与 §8 的契约覆盖率分母。

#### P2 · A. 明确未实现 / 未接线（如实记账）

| # | 缺口 | 影响 | 状态 |
|---|---|---|---|
| A1 | **Postgres 后端未实现**：仅 SQLite（`node:sqlite`） | `task/store/pg_store.py` 无对应；`TaskStoreSpec::for_kind` 只接受 sqlite 形态 | ⛔ |
| A2 | **`queue.file_channel` 大载荷落文件未实现**：vools 把超阈值载荷写文件再引用，本实现配置项保留但走内联 | 超大 payload 会直接进 SQLite 行 | ⛔ |
| A3 | **`tasks_executions` 表已建但未写入** | 执行历史表为预留，`SqliteTaskStore` 不落执行明细 | ⚠️ 预留 |
| A4 | **`write_retries` / `retry_backoff` 字段定义但退避重试未接线**：遇 `database is locked` 直接返回 `Err` | 高并发写库时无自动重试（调用方可自行重试） | ⚠️ |
| A5 | **exec 的 `workdir` / `env` / `shell:true` 未携带未应用** | 仅按语言白名单 spawn，不注入环境与工作目录 | ⚠️（与 B7 相关） |
| A6 | **同步冲突仅「version 新者胜」**：无 field-level merge、无墓碑（删除标记） | 并发双向同步可能丢字段更新 | ⚠️ |
| A7 | **`local_runner` / `daemon`（task 版）/ `cli` 未复刻** | 本机执行快捷路径、task 守护进程、命令行入口均不提供 | ⛔ |

#### P2 · B. 早期偏差已解决（B1 / B2 → ✅ 已对齐，2026-10-28 T0r15）

> T0r15 由 impl-crypto 完成 vools 字节级对齐并实测：`beat` 输出 vools 同形纯文本（`<ISO.%fZ>`，微秒精度，
> MoonBit 侧 ms 精度补 `000`），`include_worker~` 默认 **false**；`mark_closed` 写字面量 `closed_token`
> （已核对 vools = `"closed"`）；`read` 三级兼容（`closed_token` → JSON 存量 → 纯文本，ISO 秒/微秒都收）；
> `max_future_skew_sec` 默认 **60s**（vools 值）+ `with_max_future_skew` + 可从 `queue.heartbeat` 读，超容差 **fail-closed** 判 dead；
> **真 vools `Heartbeat` 类双向互操作 6/6 通过**（不是字符串模拟）。

| # | 原偏差（v3 记录） | 现状 | 证据 |
|---|---|---|---|
| **B1** | 心跳文件格式：vools 纯文本 ↔ 本项目 JSON ⇒ 双向不可互读 | ✅ **已对齐**：`beat` 写 vools 同形纯文本（微秒 ISO；`include_worker=false` 时仅时间戳，true 时 `<ts> <worker>`）；`mark_closed` 写字面量 `"closed"`；`read` 三级兼容（vools closed_token / vools 纯文本 / 历史 JSON 存量） | 真 vools `Heartbeat` 双向互操作 **6/6**；`test-suit/rhop_task` 心跳用例在三目标全绿（js 99 例整体全绿） |
| **B2** | 未来时间戳方向：vools fail-closed ↔ 本项目 fail-open | ✅ **已对齐**：`max_future_skew_sec` 默认 **60s**（与 vools 同值），超出容差的未来时间戳 **fail-closed** 判 dead；容差可经 `with_max_future_skew` 或 `queue.heartbeat.max_future_skew_sec` 配置 | 同上（单测覆盖 ±容差边界） |
| B5 | 结果截断用自定义 `__truncated__` 结构 | ⚠️ 仍为有意偏差（读取方需识别该键；仅影响超长 stdout/stderr） | — |
| B7 | 显式不支持 `shell: true`（安全取舍） | ⚠️ 有意取舍，保持不变 | — |
| B8 | action 注册表仅进程内（无持久化） | ⚠️ 保持不变（内置动作不受影响） | — |

#### P2 · C. 有意增量（P2b 新增，vools 无对应物）

`ExecResult` 结构化结果（exit/stdout/stderr/duration/truncated 一次返回）、`detect_language`（按 payload 推断语言）、
`verify_payload_sha`（载荷完整性校验）、`export_and_mark`（导出+标记一步完成）、`HeartbeatPump` 的 timer `unref` +
注册表计数断言（便于测试与进程退出）、SQLite 句柄注册表（关闭后访问返回可诊断 `Err` 而非崩溃）、
表名白名单（防注入）、`describe` + `summary`（库自检视图）、心跳 `ts` + `epoch` 双写（同时给 ISO 与秒）、
全链路中文可诊断错误。

#### P2 · D. 复用而非重造（与 Batch A/B/P2a 的关系）

| 复用点 | 来源 | 用途 |
|---|---|---|
| `@rp.RhopCrypto` | Batch B | 载荷加密/解密（`TaskQueue::decrypt_payload`、`TaskSync` 导出包） |
| `@rp.sha256_hex_of_utf8` | Batch A | `payload_sha` 载荷摘要 |
| `@rp.SharedPath`（原子写） | Batch B | 心跳/同步文件落盘（tmp+rename，杜绝半写） |
| `TaskConfig` / `SecretResolver` | P2a | P2b 的 store/queue/heartbeat 全部读同一配置与密文解析 |
| `TaskState` ↔ `@rp.TaskStatus` 显式桥接 | Batch A | `TaskState::to_status` / `from_status`，任务队列与信封状态机同源 |

**这些是「尽量复刻」的真实账**：P2 的 8 个文件是**可用**的（46·99·46 例全绿），A1–A7 与 B5/B7/B8 必须与「已对齐」
区分开看；**B1/B2 已在 T0r15 解决** —— 心跳与 vools 双向互操作、未来时间戳按 60s 容差 fail-closed，混部（Python + MoonBit）现在可用。

## 6. 有意增量（契约外新增 API，不代表 vools 有对应物）

| MoonBit 符号 | 文件 | 理由 |
|---|---|---|
| `canonical_json_ascii` / `canonical_json_ascii_utf8` | `rhop/json_canonical.mbt` | vools **两套 JSON 口径**：envelope 用 ensure_ascii=False，signer preimage 用默认 ensure_ascii=True。复刻事实，不替它纠偏 |
| `canonical_object` | `rhop/json_canonical.mbt` | 便捷构造有序对象，减少调用点样板 |
| `Envelope::new` / `Envelope::new_full` | `rhop/envelope.mbt` | vools 用 dataclass 构造；MoonBit 需显式构造器（`new` 自动算 checksum = `__post_init__` 语义） |
| `Envelope::compute_checksum`（公开化） | `rhop/envelope.mbt` | vools `_compute_checksum` 为私有；公开便于诊断与测试断言 |
| `Envelope::with_result` / `with_updated_at` / `with_hops_seen` / `with_status` / `with_signature` | `rhop/envelope.mbt` | 契约 §3 要求 wither（不可变更新 + 重算 checksum）；后两个为便捷补充 |
| `TaskStatus::all()` | `rhop/core.mbt` | 状态机全矩阵测试与按状态计数需要 |
| `IntegrityChecker::new` + `integrity_verify` / `integrity_verify_bytes` / `integrity_checksum_match` | `rhop/integrity.mbt` | 契约 §3 要求的便捷函数（vools 用 `@staticmethod` 直调） |
| `FileHashSigner::signature` / `NPUSigner::marker` / `has_serial` / `with_default_marker` / `NPU_MARKER_DEFAULT` | `rhop/signer.mbt` | trait 方法之外的可测试便捷入口；NPU 不 spawn 子进程 |
| `sha256_hex` / `sha256_hex_of_utf8` / `md5_hex` / `md5_hex_of_utf8` / `hmac_sha256_hex` / `pbkdf2_hmac_sha256_hex` | `rhop/digest.mbt` | vools 直接调 hashlib；MoonBit 需显式每步实现，hex 入口便于对照 fixture |
| `bytes_of_utf8` / `utf8_text` / `bytes_from_hex` | `rhop/digest.mbt` | 字节/文本/fixture 转换（三个目标通用）；lead 已裁定保留 |
| `SharedPath::name` / `SharedPath::root`、`OnlineChannel::name` | `rhop/transport_base.mbt` | 契约 §3 的 trait 形态要求（vools 侧在实现类上另有属性） |
| `EndpointSharedPath`、`SharedPathView::write_name`/`read_name`、`make_shared_path_from_views` | `rhop/transport_base.mbt` | 把 `&EndpointView` 适配成 `SharedPath`；视图命名用于选择理由 |
| `any_online_available` | `rhop/transport_selector.mbt` | 选择逻辑复用 |
| `normalize_path` / `join_shared` / `write_text_atomic` / `read_text_at` | `rhop/transport_local.mbt` | 原子写与路径归一的实现级公开工具 |
| `RelayServer::port` / `process_alive` | `rhop/relay.mbt` | 端口与子进程判活诊断 |
| `RhopWatcher::observe` / `skip_existing` / `with_extensions` / `extensions` / `bad_files` / `is_started` / `process_file` | `rhop/watch.mbt` | 契约 §2.6 要求复用 `@rx.Observable`；`process_file` 供无监控后端的目标手动处理 |
| `RhopCrypto::new` / `key_material` / `encrypt_json_result` / `encrypt_json_text` | `rhop/crypto.mbt` | 诊断型入口（`encrypt_json` 失败返回 `""` 时的可诊断替代） |
| `VerifyResult::new` / `pass` / `fail` / `to_string` | `rhop/key.mbt` | 构造与日志可读性 |
| `ClipboardBackend` / `CommandClipboardBackend` / `set_clipboard_backend_probe` / `reset_clipboard_backend_probe` / `reset_clipboard_backend_cache` | `rhop/clipboard.mbt` | vools 用 monkeypatch + `(read_fn, write_fn)` 元组；本项目用 trait + 显式探测钩子（测试不碰真机剪贴板） |
| `ClipboardFileSync::sync_rounds` / `rounds` / `changes` / `last_text` / `role` / `path` / `writer` / `auto_detect` 参数 | `rhop/clipboard.mbt` | 同步批处理与可测性；vools 只有阻塞 `run_forever` |
| `Role::lower`、`Session::new`/`empty`/`select`/`has_*`/`online_count`/`name` | `rhop/session.mbt` | 构造与诊断 |
| `_key_from_cfg` / `RhopConfig::new`/`has_key`/`name`/`role` | `rhop/config.mbt` | vools 私有名公开化 + 便捷访问器 |
| `MirrorDB::open_temp`/`is_open`/`try_*`/`claim_next`/`raw_run`/`pending_count`/`sync_log_count`/`count_by_status_full`/`path`；`is_stale_version_error`；`StaleVersionError` 类型化 | `rhop/mirror.mbt` | 测试与诊断入口；乐观锁错误可判别 |
| `Requester::from_config_dir`/`from_mirror_path`/`wait_result`/`data_dir`/`mirror`；`Executor::from_*`/`execute_next`/`worker_id`/`mirror`；`RelayDaemon::run_once`/`process_inbox`/`push_local`/`pull_remote`/`mirror`/`rounds`/`side`/`is_running`/`data_dir`/`close`/`from_config_dir` | C/D 业务文件 | vools 的私有流程公开化，供测试与外部驱动 |
| `SyncFolder::with_recursive`/`rounds`/`stop`/`manifest_path`；`sync_glob_match` | `rhop/sync_folder.mbt` | 可测性与停表 |
| `register_action` / `list_actions` | `rhop/actions.mbt` | 注册表管理（vools 只有 `ACTIONS` 字典常量） |
| `rhop_fs_*` / `rhop_db_*` / `http_request` / `HttpResp` / `uri_encode` / `uri_decode` / `file_url_to_path` / `is_file_url` / `rhop_now_iso` / `rhop_sleep_ms` / `rhop_join` / `rhop_ensure_data_dirs` | `rhop/rhop_js.mbt`（基础设施层） | 跨目标 IO / SQLite / HTTP 原语，被 crypto / transport / mirror 复用；vools 直接用 os / sqlite3 / urllib |

## 7. 已知差异（不是遗漏，是有意取舍或有明确边界）

| # | 差异 | 影响面 | 处置 |
|---|---|---|---|
| 1 | **canonical JSON 浮点**：Python `repr(1.0)`=`"1.0"`，本实现 `Double::to_string(1.0)`=`"1"`；指数形态（`1e+20` vs `1e20`）、`NaN`/`Infinity` 字面量亦不同形 | envelope checksum / signer preimage 若含浮点 | 语料只用 int/字符串/布尔/null/嵌套；解析侧用 `preserve_number_repr=true` 保留整数原文；已在 `json_canonical.mbt` 文档注释写明 |
| 2 | **signer preimage 的 ensure_ascii 口径**：vools signer 用默认 `True`（非 ASCII → `\uXXXX`），envelope 用 `False` | 含中文 result 的签名 | 分别用 `canonical_json_ascii` / `canonical_json`；qa fixture `signer.file_hash.cases[1] unicode_result` 为硬判据（签名 `sha256:008d35d8…` 已对齐） |
| 3 | **错误表达**：vools 抛异常（`ValueError`/`RuntimeError`），本项目一律 `Result[_, String]`（契约 §2.2） | 全部入口 | 错误文本保留可诊断信息（`checksum mismatch` / `缺少必填字段` / `解析失败` 等原文短语可在测试中匹配） |
| 4 | **watch 监控后端**：`@monitor.watch_folder` 只有 js/native 实现，wasm 无 | `RhopWatcher::start` | wasm 下返回可诊断 `Err`（不影响包在 wasm 编译）；另提供 `process_file` 手动路径 |
| 5 | **Fernet 加解密仅 js**：非 js 无 `node:crypto` | `encrypt_json`/`decrypt_verify`/`encrypt_secret`/`decrypt_secret` | 非 js 返回 `""` 或 `BAD_TOKEN`（显式失败，不静默成功）；结构/校验逻辑三目标通用 |
| 6 | **SFTP 远端文件操作**：vools 有 `put/get/listdir/mkdirs` 等（依赖 paramiko） | `SftpChannel` | 本项目不引入 paramiko 等价依赖，只保留 `available/send/receive`；其余标 ⛔ P2 |
| 7 | **CLI 入口不迁**：`daemon.main` / `secret.main` / `task/cli` | — | MoonBit 侧由库 API + 脚本驱动，不做 CLI |
| 8 | **命名调整**：`Side.other`/`is_terminal`/`url`/`root` 等 property → MoonBit 方法；`snake_case` 保持一致 | 调用点 | 契约 §2.1 命名约定 |
| 9 | **`canonical_json` 对未知 envelope 字段的处理**：与 Python 一致（pop checksum 后对剩余全部键 re-dump，未知键参与校验） | 前向兼容 | 有专门用例（未知字段被篡改 ⇒ checksum mismatch） |
| 10 | **`IntegrityChecker::verify` 忽略 `env` 参数** | — | 与 vools 行为一致（vools 也只校验 raw），参数保留以便逐字对应 |
| 11 | **clipboard 后端探测链**：vools = pyperclip → powershell（`shutil.which`）；本项目 = 按平台 `which` 探测 powershell / wl-paste / xclip / pbpaste（无 pyperclip 等价物） | `get_clipboard_backend` | 提供探测钩子，测试完全离线；三目标 API 齐备（非 js 恒 None） |
| 12 | **clipboard 轮询形态**：vools = 阻塞线程 + `stop_event`；本项目 = `@rx.Observable[Json, String]`（订阅即首轮、`dispose()` 停止），阻塞等价物 `sync_rounds(n)` | 轮询调用方 | 已写进 `clipboard.mbt` 文档注释（🟡） |
| 13 | **在线通道能力**：vools 有真实 paramiko / git 实现；本项目 `available()` 真探测、`send/receive` 在无凭据时返回可诊断 `Err` | `GitChannel` / `SftpChannel` | 契约 §3 允许「无外部依赖时以 Err/不可用实现」；测试覆盖探测与降级 |
| 14 | **sync_folder 无独立 Source 抽象**：vools `LocalDirSource`（list_files / open_bytes / describe）；本项目由 `SyncFolder` 内部承担 + 公开 `sync_glob_match` | 同步实现 | 语义等价（源目录即本地目录）；无独立 describe |
| 15 | **HTTP / 端点 / 子进程能力仅 js**：`HttpEndpoint`、clipboard 后端、`RelayServer` 子进程 | 相关类型 | 非 js 返回可诊断 `Err` 或 `available()=false`；三目标均可编译 |
| 16 | **CLI 与 P2 task 队列**：vools 有 CLI 入口与完整 `task/` 队列（230 符号）；本项目不迁 CLI，`rhop_task` 覆盖数据/配置/密文（P2a）+ 存储/队列/心跳/执行/同步（P2b）共 8 文件，尚未移植 `task/cli.py`、`task/daemon.py`、`task/local_runner.py`、Postgres 后端 | P2 | 见 §5.9 与 §11 |
| 17 | **信封字段类型严格度高于 vools**：`task_id:123` / `error:5` / `hops_seen:[1]` / `version:"3"` 本实现 `Err`，vools dataclass 无运行期类型检查会接受 | 读取他方产出的畸形 `.rhop` | 有意保留（C1 PROTO-03）：显式失败优于静默接受；vools 能读的文件本实现可能拒绝 |
| 18 | **非规范数字字面量**：payload 写 `1.50` / `1e2` 时本实现按 `preserve_number_repr` 保留原文重算 checksum；vools `json.loads` 规范化（`1.5` / `100.0`）后重算，对同一文件判 `checksum mismatch` | 与 vools 交换含非规范数字的文件 | 有意保留（C1 PROTO-07）：避免二次序列化改值；规范语料（Python `json.dumps` 产出）不受影响 |
| 19 | **信封嵌套深度不对称（C2P-05）**：写侧迭代序列化无深度上限，读侧受 `MAX_ENVELOPE_NESTING_DEPTH = 1000` 约束 | 深嵌套 payload（>1000 层） | 深度 1000–2000+ 可写出但读不回，属 out-of-contract；常量已显式化并有用例固定该行为 |
| 20 | **payload/result 的 Json 引用共享（C2P-04）**：wither 复用同一 `Json`（与 vools dataclass 同）；`hops_seen` 已改为构造时防御性复制（C2P-03） | 多个持有方共享信封 | 契约：`payload`/`result` 按不可变值使用，不得原地改内层 Array/Map；已写入 DOC.md 与结构体 docstring |
| 21 | **PBKDF2 200000 轮耗时（C2P-02）**：纯 MoonBit 实现，优化后 js ≈0.8 s / wasm ≈1.8 s / native ≈2.0 s（旧实现 2.4–3.8 s） | Fernet KDF（每个信封一次） | 算法语义与 RFC 向量不变；高频收发建议复用派生密钥（同一 key 只派生一次） |

> 历史条目（v3 的第 17/18 条：P2 心跳文件格式不互通、未来时间戳判定方向）**已于 2026-10-28 T0r15 解决**（vools 字节级对齐 + 真 vools 双向互操作 6/6），已移出本表，证据见 §5.9 B1/B2。

## 8. 统计与覆盖率

**分母说明**

- `已落地范围（A+B）` = 契约 §3 Batch A + Batch B 的 124 个符号。
- `契约范围（A–D + clipboard）` = **192** 个符号 = 契约 §3 列出的全部模块（core/envelope/signer/integrity/crypto/watch/transport×7/session/interact/config/mirror/daemon/requester/executor/actions(2)/sync_folder/clipboard(8)）；不含 `secret.py` CLI（1）、`actions/jump.py` 动作族（14）、P2 `task/` 子包（230，单列于 §5.9）。
- `vools 全量` = **437** 个符号（193 主模块 + 14 jump + 230 task）。

| 口径 | 符号数 | ✅ | 🟡 | ⚠️ | ⏳ | ⛔ | 覆盖率 |
|---|---:|---:|---:|---:|---:|---:|---|
| 已落地范围（A+B） | 124 | 113 | 2 | 1 | 0 | 8 | **91.1%** 完全对齐；对齐+等价+部分 = 93.5% |
| 契约范围（A–D + clipboard） | 192 | 178 | 4 | 1 | 0 | 9 | **92.7%** 完全对齐；对齐+等价+部分 = **95.3%**；不做 4.7% |
| vools 全量（含 P2） | 437 | 179 | 4 | 1 | 0 | 253 | **41.0%** 完全对齐；对齐+等价+部分 = 42.1% |

**结论**

1. **契约范围内 192 个符号中 178 个已完全对齐（92.7%），加上语义等价（🟡 4）与部分（⚠️ 1，watch 的无公开 `DEFAULT_EXTENSIONS` 常量）达 95.3%**；余下 9 个 ⛔ 全是明确不做项（SFTP 远端文件操作 8 + CLI 入口 1）。
2. Batch A/B（124）保持 91.1%，跨实现字节级对齐有 qa fixture 硬证据（envelope checksum/字节、canonical JSON 7 例、digest 13 例、signer 3 例）。
3. Batch C/D **全部落地且测试全绿**：session 7 / interact 2 / config 11 / mirror 12 / daemon 3+1CLI / requester 6 / executor 7 / sync_folder 9 / actions 2（`actions_test.mbt` 10 例）/ clipboard 6✅+2🟡（25 例）。
4. P2（`rhop_task`）不计入契约覆盖率：P2a + P2b **已全部落地**（8 文件，测试 wasm/native 46、js 99 全绿），按模块级映射 21/230 符号可对位（models/config/secrets/store/queue/heartbeat/exec/sync），剩余 209 为 CLI/daemon/local_runner/Postgres 后端等未移植项——**逐符号映射仍待后续**（见 §5.9）。

## 9. 复核方式（可重复执行）

```bash
# ① 本项目公开面（权威：moon info 生成的接口）
cd E:/IDEProjects/AI/rx-mbt
grep -cE "^pub " rhop/pkg.generated.mbti                                           # 337 行 pub 声明
grep -oE "^pub (fn|struct|enum|trait|const|using|impl)" rhop/pkg.generated.mbti | sort | uniq -c
#   8 pub const / 278 pub fn / 15 pub impl / 32 pub struct / 2 pub trait（+ 2 行 pub(all) enum）

# ② vools 公开面（AST 枚举，避免手抄遗漏）
cd E:/IDEProjects/AI/vools/rhop/vools/rhop
python - <<'PY'
import ast, io
for m in ["core.py","envelope.py","signer.py","integrity.py","crypto.py","watch.py"]:
    t = ast.parse(io.open(m, encoding="utf-8").read())
    print(m, sum(1 for n in t.body if isinstance(n,(ast.ClassDef,ast.FunctionDef)) and not n.name.startswith("_")))
PY

# ③ 分包测试（只看汇总行）
moon check -p rhop && moon check -p rhop --target js && moon check -p rhop --target native
moon test test-suit/rhop --target js
moon test -p test-suit/rhop_js --target js
moon test -p test-suit/rhop_clipboard --target js
moon test -p test-suit/rhop_interact --target js
moon test -p test-suit/rhop_business --target js
moon test -p test-suit/rhop_task --target js
```

**复核时刻实测状态（C2 轮修复后快照 2026-10-28 14:2x，Windows / moon 0.1.20261016 / node v25.2.1）**

> ⚠️ C2 并行 lane（crypto/session/business）仍在追加测试，**跨 lane 总数持续变化**；下表为本域快照，
> 跨 lane / 项目级数字以 `bash scripts/test_all.sh`（qa 终验）为准。

| 命令 | 结果 |
|---|---|
| `moon check`（项目级，三目标） | wasm / js / native 均 **0 error**（`moon check` 实测 0） |
| `moon check -p rhop`（wasm / js / native） | 三目标均 **0 error** |
| `moon test test-suit/rhop`（wasm） | `Total tests: 156, passed: 156, failed: 0.` |
| `moon test test-suit/rhop --target js` | `Total tests: 160, passed: 160, failed: 0.` |
| `moon test test-suit/rhop --target native` | `Total tests: 156, passed: 156, failed: 0.` |
| `moon test test-suit/rhop_vectors --target js` | `Total tests: 2, passed: 2, failed: 0.`（互操作产物生产者） |
| `moon test -p test-suit/rhop_js --target js` | `Total tests: 56, passed: 56, failed: 0.` |
| `moon test -p test-suit/rhop_clipboard --target js` | `Total tests: 25, passed: 25, failed: 0.` |
| `moon test -p test-suit/rhop_interact --target js` | `Total tests: 22, passed: 22, failed: 0.` |
| `moon test test-suit/rhop_business`（wasm/native） | `Total tests: 10, passed: 10, failed: 0.` |
| `moon test test-suit/rhop_business --target js` | `Total tests: 53, passed: 53, failed: 0.` |
| `moon test test-suit/rhop_task`（wasm/native） | `Total tests: 46, passed: 46, failed: 0.`（P2a 纯逻辑部分）|
| `moon test test-suit/rhop_task --target js` | `Total tests: 101, passed: 101, failed: 0.`（P2a+P2b，含心跳 vools 互操作用例）|
| 项目级 `moon test`（wasm） | `Total tests: 612, passed: 612, failed: 0.`（快照）|
| 项目级 `moon test --target native` | `Total tests: 612, passed: 612, failed: 0.`（快照）|
| 项目级 `moon test --target js` | 快照时点 `819` 例（C2 并行 lane 正在追加测试，故不冻结单一总数；本域各包均绿，见上表）|

> 判绿纪律：只认 `moon test` 汇总行（`Total tests: N, passed: N, failed: 0`），不认 exit code。
> 本表所有数字均在表格标注时刻实际运行得到；P2 / Batch D 在途项恢复后应重跑并把 `rhop_business` 一行改为 38/38。

## 10. 测试覆盖对照（vools 模块 → 本项目测试文件与用例数）

| 本项目测试包 / 文件 | 用例数 | 覆盖的 vools 模块 | 目标 |
|---|---:|---|---|
| `test-suit/rhop/core_test.mbt` | 10 | `core.py`（含 6×6 流转矩阵） | wasm/js/native |
| `test-suit/rhop/digest_test.mbt` | 18 | hashlib 等价（sha256/md5/hmac/pbkdf2） | wasm/js/native |
| `test-suit/rhop/json_canonical_test.mbt` | 19 | `envelope.py` + `signer.py` 的双 JSON 口径 | wasm/js/native |
| `test-suit/rhop/envelope_test.mbt` | 18 | `envelope.py`（含 qa fixture 逐字节向量） | wasm/js/native |
| `test-suit/rhop/signer_test.mbt` | 9 | `signer.py`（fixture 3 例签名硬判据） | wasm/js/native |
| `test-suit/rhop/integrity_test.mbt` | 7 | `integrity.py` + 端到端链路 | wasm/js/native |
| `test-suit/rhop/config_test.mbt` | 18 | `config.py` | wasm/js/native |
| `test-suit/rhop/session_test.mbt` | 15 | `session.py` | wasm/js/native |
| `test-suit/rhop/actions_test.mbt` | 10 | `actions/__init__.py` + `jump.probe` | wasm/js/native |
| `test-suit/rhop/rhop_test.mbt` + `rhop_js_test.mbt` | 7 + 4 | **既有** RX-MBT 的 `RhopPacket`/`RhopEnvelope`/`RhopCipherNone`（非 vools 对照面） | 默认 / js |
| **`test-suit/rhop` 小计** | **156（wasm/native）/ 160（js）** | — | — |
| `test-suit/rhop_js/crypto_test.mbt` | 24 | `crypto.py`（Fernet 双向互解、三态 reason、`RHOP-ENC`） | js |
| `test-suit/rhop_js/transport_test.mbt` | 16 | `transport/{base,local,endpoint,selector,shared}.py` | js |
| `test-suit/rhop_js/watch_test.mbt` | 6 | `watch.py` | js |
| `test-suit/rhop_js/relay_test.mbt` | 6 | `transport/relay.py` | js |
| **`test-suit/rhop_js` 小计** | **56** | — | js |
| `test-suit/rhop_clipboard/clipboard_test.mbt` | 25 | `clipboard.py`（push/pull 状态机、探测、边界） | js |
| `test-suit/rhop_interact/interact_test.mbt` | 22 | `interact.py` + `actions/` 三模式 | js |
| `test-suit/rhop_business/mirror_test.mbt` | 11 | `mirror.py` | js |
| `test-suit/rhop_business/executor_test.mbt` | 6 | `executor.py` | js |
| `test-suit/rhop_business/requester_test.mbt` | 5 | `requester.py` | js |
| `test-suit/rhop_business/daemon_test.mbt` | 6 | `daemon.py` | js |
| `test-suit/rhop_business/sync_folder_test.mbt` + `sync_glob_test.mbt` | 5 + 5 | `sync_folder.py` | js |
| `test-suit/rhop_business/nonjs_test.mbt` + helpers | 5（+ 0 例 helper 模块） | 非 js 降级路径 | wasm/native |
| **`test-suit/rhop_business` 小计** | **10（wasm/native）/ 53（js）** | — | — |
| `test-suit/rhop_task/*`（10 文件） | **46（wasm/native）/ 101（js）** | P2a（models/config/secrets）+ P2b（store/queue/heartbeat/exec/sync，含 vools 心跳互操作） | wasm/js/native（7 个文件 js-only） |

**rhop 相关合计**

- **js 口径**：160(rhop) + 2(vectors) + 56(rhop_js) + 25(clipboard) + 22(interact) + 53(business) + 101(task) = **419 例**（快照）
- **wasm / native 口径**：156(rhop) + 10(business) + 46(task) = **212 例**（不含 js-only 包）
- **全模块（项目级，快照）**：wasm **612** / native **612**，js 快照 **819**；js 侧随并行 lane 追加而变，以 `scripts/test_all.sh` 输出为准
- 其中 vools 契约范围（A–D + clipboard）约 318 例（js），P2 占 101 例（js）

## 11. 本轮完成情况与「待终轮更新」清单

**本轮（v2）已完成**
1. Batch C 全部落地核实并转 ✅：`session.mbt`(7)、`config.mbt`(11)、`interact.mbt`(2)，测试 15 + 18 + 13 例。
2. Batch D 落地核实：`mirror`(12 ✅)、`executor`(7 ✅)、`sync_folder`(9 ✅)、`daemon`(3 ✅ + 1 ⛔ CLI)、`requester`(6 ✅，测试在途)、`actions`(2 ⚠️ 已实现未测)。
3. clipboard 一节按实测改写（8 个符号：6 ✅ + 2 🟡，25 例测试），并给出探测/轮询两处差异说明。
4. P2 `rhop_task` 单列（骨架 + 57 例 js 绿；逐符号对照与 native 支持留 P2b）。
5. 重算三档覆盖率（A+B 124 → 91.1%；契约范围 192 → 91.7%/95.3%；全量 437 → 40.3%）。
6. 有意增量补登 C/D/clipboard/基础设施层 10 组；已知差异补到 16 条。

**本轮收尾时已关闭的项**
- `test-suit/rhop_business` 已 38/38 全绿 → §5.2/§5.3 的 ⚠️ 均改 ✅。
- `actions_test.mbt` 已交付（10 例，包级全绿）→ §5.5 三行改 ✅。

**待终轮更新（P2 收尾后需要再刷一遍）**
1. （C2 轮更新）本域已全绿：wasm 612/612、native 612/612（项目级快照），`test-suit/rhop` 156/160/156、`rhop_vectors` 0/2/0；
   项目级 js 因并行 lane 持续追加测试未冻结单一总数。**C2 修复项**：C2P-01 深嵌套栈溢出、C2P-02 PBKDF2 秒级阻塞、C2P-03 hops_seen 引用外泄、
   C2P-05 读写深度不对称、C2P-06 文档数字漂移、C2P-07 键排序分配 —— 详见 `fist-mbt/reports/2026-10-28-c2-{bugfind,fix}-protocol.md`。
2. P2b：`rhop_task` 与 vools `task/`（230 符号）逐符号对照表 + native 目标结论。
3. 覆盖率：当前契约范围 **92.7%**（178/192），已无在途 ⏳ 项；仅剩 ⚠️ 1（watch 常量）与 ⛔ 9（明确不做）。
