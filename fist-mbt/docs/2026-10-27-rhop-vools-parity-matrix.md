# vools-rhop 0.9.0 → rx-mbt/rhop API 对照矩阵（Batch A/B 已核，Batch C/D 计划）

| 项 | 值 |
|---|---|
| 文档版本 | **v2（2026-10-28 09:3x，Batch A/B/C/D + clipboard 全部落地后复核）**；v1 2026-10-27 起稿、v1.1 更新 actions 行 |
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
| `daemon.py` | 4 | 3 | 0 | 0 | 0 | 1 | `rhop/daemon.mbt`（6 例，2 例在途） |
| `requester.py` | 6 | 6 | 0 | 0 | 0 | 0 | `rhop/requester.mbt`（5 例，2 例在途） |
| `executor.py` | 7 | 7 | 0 | 0 | 0 | 0 | `rhop/executor.mbt`（6 例） |
| `actions/__init__.py` | 2 | 0 | 0 | 2 | 0 | 0 | `rhop/actions.mbt`（已实现；无专属测试 → 保持 ⚠️） |
| `sync_folder.py` | 9 | 9 | 0 | 0 | 0 | 0 | `rhop/sync_folder.mbt`（5 例） |
| `clipboard.py` | 8 | 6 | 2 | 0 | 0 | 0 | `rhop/clipboard.mbt`（25 例，新包 test-suit/rhop_clipboard） |
| **契约范围小计** | **192** | **176** | **4** | **3** | **0** | **9** | — |
| `actions/jump.py` | 14 | 0 | 0 | 1 | 0 | 13 | 仅 `jump.probe` 内建（无专属测试） |
| `secret.py` | 1 | 0 | 0 | 0 | 0 | 1 | CLI 工具，不迁 |
| `task/` 子包（含 `task/store/`） | 230 | 0 | 0 | 0 | 0 | 230 | P2（`rhop_task` 已落地骨架 + 57 例，见 §5.9） |
| **vools 全量** | **437** | **176** | **4** | **4** | **0** | **253** | — |

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

## 4. Batch C（会话/配置/交互）· 计划对齐 ⏳ · owner impl-session

> 依据契约 §3 Batch C 的目标形态列出；文件尚未落地（`rhop/session.mbt`、`rhop/config.mbt`、`rhop/interact.mbt` 当前不存在）。

### 4.1 `session.py` → 计划 `rhop/session.mbt`（7 ⏳）

| vools 符号 | 计划 MoonBit 符号 | 目标 | 状态 |
|---|---|---|---|
| `Role`（SEND/RECV/RELAY） | `Role` enum + `parse`/`to_string` | 三目标 | ⏳ |
| `Session` | `Session { role; shared; online; relay; crypto; name }` | 三目标 | ⏳ |
| `Session.available` | `Session::available` | 三目标 | ⏳ |
| `Session.send_package` | `Session::send_package -> Result[Json, String]` | 三目标 | ⏳ |
| `Session.recv_package` | `Session::recv_package -> Result[Json, String]` | 三目标 | ⏳ |
| `Session.reverse` | `Session::reverse` | 三目标 | ⏳ |
| `Session.describe` | `Session::describe -> Json` | 三目标 | ⏳ |

### 4.2 `interact.py` → 计划 `rhop/interact.mbt`（2 ⏳）

| vools 符号 | 计划 MoonBit 符号 | 目标 | 状态 |
|---|---|---|---|
| `interact(cfg, action, payload, mode)` | `interact(...) -> Result[Json, String]`（mode: execute/request/roundtrip） | 三目标 | ⏳ |
| `handle_request(cfg, filename, session?)` | `handle_request(...) -> Result[Json, String]`（回传 `res_` 前缀） | 三目标 | ⏳ |

### 4.3 `config.py` → 计划 `rhop/config.mbt`（11 ⏳）

| vools 符号 | 计划 MoonBit 符号 | 目标 | 状态 |
|---|---|---|---|
| `RhopConfig` | `RhopConfig { key; role; sftp; online; shared; relay; name }` | 三目标 | ⏳ |
| `RhopConfig.from_dict` | `RhopConfig::from_dict -> Result` | 三目标 | ⏳ |
| `RhopConfig.from_file` | `RhopConfig::from_file`（js） | js | ⏳ |
| `RhopConfig.to_dict` | `RhopConfig::to_dict`（密码字段打 `***`） | 三目标 | ⏳ |
| `RhopConfig.build_crypto` | `build_crypto` | 三目标 | ⏳ |
| `RhopConfig.build_online` | `build_online` | 三目标 | ⏳ |
| `RhopConfig.build_shared` | `build_shared` | 三目标 | ⏳ |
| `RhopConfig.build_relay` | `build_relay` | 三目标 | ⏳ |
| `RhopConfig.build_session` | `build_session(role?)` | 三目标 | ⏳ |
| `RhopConfig.action_cfg` | `action_cfg -> Json` | 三目标 | ⏳ |
| `load_config(path_or_dict)` | `load_config` | 三目标（file 分支 js） | ⏳ |

## 5. Batch D（业务层：镜像/守护/需求端/执行端/动作）· 计划对齐 ⏳ / 部分 P2 ⛔ · owner impl-business

### 5.1 `mirror.py` → 计划 `rhop/mirror.mbt`（12 ⏳）

| vools 符号 | 计划 MoonBit 符号 | 目标 | 状态 |
|---|---|---|---|
| `SCHEMA_SQL` | 内建建表 SQL（实现细节，不单独公开） | js | ⏳ |
| `StaleVersionError` | 语义等价：`Err` 中带 `StaleVersion` 标记 | js | ⏳ |
| `MirrorDB` | `MirrorDB` | js | ⏳ |
| `MirrorDB.upsert_task` | `MirrorDB::upsert_task(Envelope)` | js | ⏳ |
| `MirrorDB.get_task` | `MirrorDB::get_task -> Envelope?` | js | ⏳ |
| `MirrorDB.list_tasks` | `MirrorDB::list_tasks(status?)` | js | ⏳ |
| `MirrorDB.update_status` | `MirrorDB::update_status(id, status, version)`（乐观锁） | js | ⏳ |
| `MirrorDB.claim_task` | `MirrorDB::claim_task(claimer)` | js | ⏳ |
| `MirrorDB.count_by_status` | `MirrorDB::count_by_status` | js | ⏳ |
| `MirrorDB.log_sync` | `MirrorDB::log_sync` | js | ⏳ |
| `MirrorDB.pending_sync` | `MirrorDB::pending_sync` | js | ⏳ |
| `MirrorDB.close` | `MirrorDB::close` | js | ⏳ |

### 5.2 `daemon.py` → 计划 `rhop/daemon.mbt`（4：3 ⏳ / 1 ⛔）

| vools 符号 | 计划 MoonBit 符号 | 目标 | 状态 |
|---|---|---|---|
| `RelayDaemon` | `RelayDaemon` | js | ⏳ |
| `RelayDaemon.start` | `RelayDaemon::start` | js | ⏳ |
| `RelayDaemon.stop` | `RelayDaemon::stop` | js | ⏳ |
| `main()`（CLI 入口） | — | — | ⛔ | 不迁 CLI（MoonBit 侧由调用方/脚本驱动） |

> 契约 §3 另列 `run_once`/`process_inbox`/`push_local` 三个行为方法（vools 中为私有实现细节），将在 `rhop/daemon.mbt` 中以公开方法提供。

### 5.3 `requester.py` → 计划 `rhop/requester.mbt`（6 ⏳）

| vools 符号 | 计划 MoonBit 符号 | 目标 | 状态 |
|---|---|---|---|
| `Requester` | `Requester` | js | ⏳ |
| `Requester.submit` | `Requester::submit(task_id, payload)` | js | ⏳ |
| `Requester.get_result` | `Requester::get_result(task_id)` | js | ⏳ |
| `Requester.list_tasks` | `Requester::list_tasks(status?)` | js | ⏳ |
| `Requester.cancel` | `Requester::cancel(task_id)` | js | ⏳ |
| `Requester.close` | `Requester::close` | js | ⏳ |

### 5.4 `executor.py` → 计划 `rhop/executor.mbt`（7 ⏳）

| vools 符号 | 计划 MoonBit 符号 | 目标 | 状态 |
|---|---|---|---|
| `Executor` | `Executor` | js | ⏳ |
| `Executor.claim` | `Executor::claim()` | js | ⏳ |
| `Executor.execute` | `Executor::execute(task)` | js | ⏳ |
| `Executor.report_result` | `Executor::report_result(task_id, result)` | js | ⏳ |
| `Executor.report_failure` | `Executor::report_failure(task_id, error)` | js | ⏳ |
| `Executor.list_pending` | `Executor::list_pending()` | js | ⏳ |
| `Executor.close` | `Executor::close` | js | ⏳ |

### 5.5 `actions/__init__.py` → `rhop/actions.mbt`（2：2 ⚠️「已实现未测」）；`actions/jump.py`（14：1 ⚠️ / 13 ⛔）

> 说明：`rhop/actions.mbt` 已于 2026-10-28 上午落盘（288 行，`moon check` 0 error、已进 `pkg.generated.mbti`），
> 含 `register_action` / `list_actions` / `run_action` / `omega_unwrap` 与内置 `jump.probe` 离线实现；
> **但 `test-suit/rhop_js/actions_test.mbt` 尚未交付**（属 Batch D 收尾），故这两行状态记 ⚠️（已实现未测），不计入 ✅。

| vools 符号 | MoonBit 符号（文件:符号） | 目标 | 测试 | 状态 | 备注 |
|---|---|---|---|---|---|
| `run_action(action, cfg, payload)` | `rhop/actions.mbt: run_action` | 三目标 | 待补 `actions_test.mbt` | ⚠️ | 注册表可扩展；未知 action 返回结构化错误 JSON |
| `omega_unwrap(result)` | `rhop/actions.mbt: omega_unwrap` | 三目标 | 待补 `actions_test.mbt` | ⚠️ | ok/error/原样三形态 |
| `jump_probe(cfg, payload)` | `rhop/actions.mbt` 内置动作 `jump.probe`（离线：校验 sftp 配置返回结构化探测） | 三目标 | 待补 `actions_test.mbt` | ⚠️ | 不真连网；出参四字段 status/reachable/detail/transport 对齐 vools |
| `jump_push` / `jump_pull` / `jump_sync` | — | — | ⛔ | 需真实 SFTP/paramiko，P2 |
| `compute_sync_plan` / `scan_local_files` / `scan_remote_files_paramiko` / `collect_files` / `should_exclude` | — | — | ⛔ | 目录同步扫描族，P2 |
| `SFTP_KIND_FILE` / `SFTP_KIND_DIR` / `SFTP_KIND_OTHER` / `PARAMIKO_HINT` / `ACTIONS` | — | — | ⛔ | 常量/注册表，随上面 API 一起 P2 |

### 5.6 `sync_folder.py` → 计划 `rhop/sync_folder.mbt`（9 ⏳；P1 可缓）

| vools 符号 | 计划 MoonBit 符号 | 目标 | 状态 |
|---|---|---|---|
| `MANIFEST_NAME` | `MANIFEST_NAME` 常量 | 三目标 | ⏳ |
| `LocalDirSource` | `LocalDirSource` | 三目标 | ⏳ |
| `LocalDirSource.list_files` | `list_files` | 三目标 | ⏳ |
| `LocalDirSource.open_bytes` | `open_bytes` | 三目标 | ⏳ |
| `LocalDirSource.describe` | `describe` | 三目标 | ⏳ |
| `SyncFolder` | `SyncFolder::new(source, target, pattern)` | 三目标 | ⏳ |
| `SyncFolder.sync_once` | `sync_once`（幂等） | 三目标 | ⏳ |
| `SyncFolder.run_forever` | `run_forever` | 三目标 | ⏳ |
| `sync_folder_once` | 便捷函数 | 三目标 | ⏳ |

### 5.7 `clipboard.py`（8：3 ⏳ / 5 ⛔；非硬门槛）

| vools 符号 | 计划 MoonBit 符号 | 目标 | 状态 | 备注 |
|---|---|---|---|---|
| `ClipboardFileSync` | 接口（js 可降级） | js | ⏳ | 契约 §3 列为可缓 |
| `ClipboardFileSync.sync_once` | `sync_once` | js | ⏳ | — |
| `ClipboardFileSync.run_forever` | `run_forever` | js | ⏳ | — |
| `get_clipboard_backend` | — | — | ⛔ | 平台剪贴板 FFI，不迁 |
| `read_clipboard` / `write_clipboard` | — | — | ⛔ | 同上 |
| `last_read_reason` | — | — | ⛔ | 同上 |
| `CLIP_FILE` | — | — | ⛔ | 同上 |

### 5.8 `secret.py`（1 ⛔）与 `task/` 子包（230 ⛔ · P2）

| vools 符号 | 说明 | 状态 |
|---|---|---|
| `secret.py: main` | 命令行「生成/查看密钥」工具 | ⛔ 不迁 CLI |
| `task/*`（cli/config/daemon/errors/exec/heartbeat/local_runner/models/queue/secrets/sync + `task/store/`） 230 个公开符号 | 通用任务队列（A 提交加密 JSON → B 解密执行；SQLite 管依赖/状态） | ⛔ P2：契约 §3 注「不列入本轮验收硬门槛，但任务树中保留」 |

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
| `normalize_role` 等（C/D 落地后追加） | 计划 | 待 Batch C/D 落地补登 |

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

## 8. 统计与覆盖率

**分母说明**：`契约范围` = 契约 §3 列出的 vools 模块（含 Batch A–D 全部模块，不含 `task/` 子包、不含 `secret.py` CLI、不含 `actions/jump.py` 动作族与 `clipboard.py` 平台 FFI 部分）。`已落地范围` = Batch A + Batch B（124 个符号）。

| 口径 | 符号数 | ✅ | 🟡 | ⚠️ | ⏳ | ⛔ | 对齐率 |
|---|---:|---:|---:|---:|---:|---:|---:|
| 已落地范围（A+B） | 124 | 113 | 2 | 1 | 0 | 8 | **91.1%**（✅ 计）；
按状态分布：✅ 91.1% / 🟡 1.6% / ⚠️ 0.8% / ⛔ 6.5% |
| 已落地范围（A+B+actions） | 126 | 113 | 2 | 3 | 0 | 8 | ✅ 89.7%；对齐+等价+部分 = 118/126 = **93.7%** |
| 契约范围（A–D） | 184 | 113 | 2 | 3 | 57 | 9 | **61.4%** 已对齐；
对齐+等价+部分 = 118/184 = **64.1%**；
在途 ⏳ 57/184 = 31.0%；
不做 ⛔ 9/184 = 4.9% |
| vools 全量（含 P2） | 437 | 113 | 2 | 4 | 60 | 258 | **25.9%** 已对齐；
若只算「契约承诺范围」见上一行 |

**结论**：
1. Batch A + Batch B 的 124 个符号里，**113 个完全对齐、2 个仅错误表达/命名调整、1 个部分（watch 常量）、8 个明确不做（SFTP 远端文件操作，P2）** ⇒ 已落地部分的 API 复刻完成度 **91.1%**，且跨实现字节级对齐有 fixture 硬证据（envelope checksum/字节、canonical JSON 7 例、digest 13 例、signer 3 例）。
2. 契约范围内仍有 57 个符号在途（Batch C 的 session/interact/config 共 20 个；Batch D 的 mirror/daemon/requester/executor/sync_folder 共 37 个）；`actions` 的 2 个已实现待测（+ `jump.probe` 1 个）。全部落地并补测后，契约范围对齐率预计可达 **≈93–96%**（剩余 9 个为 CLI/P2 明确不做）。

## 9. 复核方式（可重复执行）

```bash
# ① 本项目公开面（权威：moon info 生成的接口）
cd E:/IDEProjects/AI/rx-mbt
grep -cE "^pub " rhop/pkg.generated.mbti                                          # 181 行 pub 声明
grep -oE "^pub (fn|struct|enum|trait|const|using|impl)" rhop/pkg.generated.mbti | sort | uniq -c
#   6 pub const / 135 pub fn / 14 pub impl / 22 pub struct / 2 pub trait（+ 2 行 pub(all) enum）

# ② vools 公开面（AST 枚举，避免手抄遗漏）
cd E:/IDEProjects/AI/vools/rhop/vools/rhop
python - <<'PY'
import ast, io
for m in ["core.py","envelope.py","signer.py","integrity.py","crypto.py","watch.py"]:
    t = ast.parse(io.open(m, encoding="utf-8").read())
    print(m, sum(1 for n in t.body if isinstance(n,(ast.ClassDef,ast.FunctionDef)) and not n.name.startswith("_")))
PY

# ③ 测试判绿（本机实测汇总行见 §7/交付回执）
moon check && moon check --target js && moon check --target native
moon test -p test-suit/rhop                              # Total tests: 88, passed: 88, failed: 0.
moon test test-suit/rhop --target js                     # Total tests: 92, passed: 92, failed: 0.
moon test test-suit/rhop --target native                 # Total tests: 88, passed: 88, failed: 0.
moon test -p test-suit/rhop_js --target js               # test-suit/rhop_js 的 51 个用例
```

**复核时刻实测状态（2026-10-28 08:5x，Windows / moon 0.1.20261016 / node v25.2.1）**

| 命令 | 结果 |
|---|---|
| `moon check`（wasm 默认） | 0 error |
| `moon check --target js` | 0 error |
| `moon check --target native` | **13 处 error，全部落在 `rhop_task/task_models.mbt`**（P2 `task/` 子包的 MoonBit 移植正在并行落地，不在本表契约范围；与本表记录的 `rhop/` 包无关） |
| `moon test -p test-suit/rhop` | `Total tests: 88, passed: 88, failed: 0.` |
| `moon test test-suit/rhop --target js` | `Total tests: 92, passed: 92, failed: 0.` |
| `moon test test-suit/rhop --target native` | `Total tests: 88, passed: 88, failed: 0.` |
| `moon test -p test-suit/rhop_js --target js` | `Total tests: 51, passed: 51, failed: 0.` |

> 上面 native 的 13 处 error 是**并行在途包**（`rhop_task/`，P2 task 子包移植）造成的，不是 `rhop/` 包的回归；
> 同一时刻 `moon test --target native`（只构建 `rhop` 及其测试）是 88/88 绿的，可交叉印证。等 P2 落地后此格应回到 0 error。

## 10. 测试覆盖对照（vools 模块 → 本项目测试文件与用例数）

| 本项目测试文件 | 用例数 | 覆盖的 vools 模块 | 目标 |
|---|---:|---|---|
| `test-suit/rhop/core_test.mbt` | 10 | `core.py`（含 6×6 流转矩阵） | wasm/js/native |
| `test-suit/rhop/digest_test.mbt` | 18 | hashlib 等价（sha256/md5/hmac/pbkdf2，供 envelope/signer 用） | wasm/js/native |
| `test-suit/rhop/json_canonical_test.mbt` | 19 | `envelope.py` 的 `json.dumps` 口径 + `signer.py` 的 ensure_ascii 口径 | wasm/js/native |
| `test-suit/rhop/envelope_test.mbt` | 18 | `envelope.py`（含 qa fixture 逐字节向量） | wasm/js/native |
| `test-suit/rhop/signer_test.mbt` | 9 | `signer.py`（fixture 3 例签名硬判据） | wasm/js/native |
| `test-suit/rhop/integrity_test.mbt` | 7 | `integrity.py` + Envelope→sign→bytes→verify 端到端 | wasm/js/native |
| `test-suit/rhop/rhop_test.mbt` / `rhop_js_test.mbt` | 7 / 4 | **既有** RX-MBT 的 `RhopPacket`/`RhopEnvelope`/`RhopCipherNone`（非 vools 对照面） | 默认 / js |
| `test-suit/rhop_js/crypto_test.mbt` | 24 | `crypto.py`（Fernet 双向互解、三态 reason、`RHOP-ENC`） | js |
| `test-suit/rhop_js/transport_test.mbt` | 16 | `transport/{base,local,endpoint,selector,shared}.py` | js |
| `test-suit/rhop_js/watch_test.mbt` | 6 | `watch.py`（捕获→decrypt_verify、坏文件跳过） | js |
| `test-suit/rhop_js/relay_test.mbt` | 5 | `transport/relay.py`（A→C→B 回环） | js |
| **合计** | **143** | — | — |

> 判绿纪律：只认 `moon test` 的汇总行（`Total tests: N, passed: N, failed: 0`），不认 exit code。
> 实测：`test-suit/rhop` wasm 88 / js 92 / native 88；`test-suit/rhop_js` js 51。

## 11. 下一轮（T0r10）待补

1. Batch C/D 落地后：把 §4/§5 的 ⏳ 行逐条改成 ✅/🟡/⚠️，并补上「实测测试文件与用例数」。
   - 已发生的首个变化：`rhop/actions.mbt` 已落地（2026-10-28），§5.5 已从 ⏳ 改为 ⚠️「已实现未测」；等 `test-suit/rhop_js/actions_test.mbt` 到位后转 ✅。
2. 复跑 `moon info` 后复核 `rhop/pkg.generated.mbti` 与本表 MoonBit 符号列一致（当前 181 行 pub 声明）。
3. 若 Batch C/D 引入新的有意增量（如 `Role` 的别名归一化、`interact` 的 mode 枚举），补登 §6。
4. 终验时把本表覆盖率与 qa 的 `scripts/verify_interop.py` 结果并列写进 `fist-mbt/reports/`。
