# RX-MBT

Rx-Rust 的 MoonBit 复刻：基于 Observer 模式的响应式编程库，纯 MoonBit 实现，零外部依赖。

## 作为三方依赖使用

本仓库是标准 MoonBit 库模块，**库代码在 `rx/` 子包中**，可通过两种方式引入：

### 方式一：git 依赖（无需发布到中心仓库）

```bash
# 在你的项目里执行（仓库地址替换为实际 git 地址）
moon add git+https://<你的仓库地址>.git
```

然后在依赖包的 `moon.pkg` 中声明并起别名：

```toml
import {
  "vicTop-cw/RX-MBT/rx" @rx,
}
```

### 方式二：发布到 MoonBit 中心仓库

```bash
moon publish
# 之后任何项目可用：
moon add vicTop-cw/RX-MBT
```

### 使用示例（外部项目视角）

```moonbit
// moon.pkg 中已 import "vicTop-cw/RX-MBT/rx" @rx
fn main {
  // 链式调用：map -> filter -> collect
  let result = @rx.Observable::from_iter([1, 2, 3, 4, 5])
    .map(fn(x) { x * 2 })
    .filter(fn(x) { x > 4 })
  let _ = result.subscribe_on_next(fn(v) { println(v) })

  // Subject 多播
  let subject : @rx.PublishSubject[Int, Unit] = @rx.PublishSubject::new()
  let _ = subject.subscribe(@rx.Observer::on_next_only(fn(v) { println("收到: \{v}") }))
  subject.on_next(42)
  subject.on_completed()
}
```

本仓库自带的 `cmd/main` 就是一个完整可运行的示例：`moon run cmd/main`。

## 启动与测试

```bash
moon check      # 类型检查（零警告零错误）
moon test       # 运行全部测试
```

> 完整的 API 签名与语义说明见 [DOC.md](DOC.md)（按分类整理的全部公开 API）。

### 版本与测试环境

本项目在以下环境验证通过：

| 项目 | 值 |
|---|---|
| MoonBit 工具链 | `moon 0.1.20261016 (1af328f 2026-10-16)`（`moon version` 输出） |
| 操作系统 | Windows 11（PowerShell 7 / Windows PowerShell 5.1 均可运行脚本） |
| 编译目标 | `wasm`（`preferred_target = "wasm"`，见 `moon.mod`） |
| 测试后端 | `moon test` 默认 wasm 后端；监控 / rhop 相关测试在 `js` 与 `native` 目标 |
| 库版本 | `vicTop-cw/RX-MBT@0.4.0`（`moon.mod` 的 `version` 字段） |
| 测试数量 | 全模块 **wasm 612 / js 825 / native 612**（2026-10-28 C3 快照，Windows 与 WSL 逐字一致）；rx 核心套件见 `TEST_REPORT.md`，rhop 明细见下方 rhop 章节与矩阵 |
| 基准测试 | `test-suit/bench`（`#skip` 默认跳过，`moon test -g "bench"` 运行） |

> 工具链版本以 `moon version` 输出为准。要求 `moon >= 0.1.20260724`（本项目使用了较新的 `moon.mod` / `moon.pkg` 语法与 Feature flags：`rr_moon_mod, rr_moon_pkg`）。

### 测试报告

运行报告生成脚本（PowerShell，无需额外依赖）：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/gen_test_report.ps1
```

产物：

| 文件 | 说明 |
|---|---|
| `TEST_REPORT.md` | 测试环境、汇总统计、按包分类的完整测试清单 |
| `TEST_REPORT.json` | 机器可读报告（供 CI / 对比脚本消费） |

报告包含 moon 版本、生成时间、总测试数/通过/失败，以及每个测试包的全部测试名清单。

测试按分类组织在 `test-suit/` 下（每个子目录独立成包，黑盒引用 `@rx`）：

| 目录 | 覆盖 |
|---|---|
| `test-suit/create` | of / from_iter / empty / never / error / repeat / range / from_callable / start |
| `test-suit/transform` | map / filter_map / flat_map / scan / concat_map / switch_map / group_by / curry_map |
| `test-suit/filter` | filter / take / skip / first / last / distinct / skip_until / take_until / contains |
| `test-suit/aggregation` | count / reduce / collect / sum / average / min / max / mean / median / variance / rolling_* / to_map / to_set |
| `test-suit/composite` | start_with / concat / merge / zip / combine_latest / with_latest_from / amb / iif / sequence_equal |
| `test-suit/math_conditions` | drop_none / fill_none / clamp / abs / every / some / all / find / is_empty |
| `test-suit/core` | run / debug / Subject / Scheduler / cum_* 等基础行为 |
| `test-suit/itor` | Itor / Node 可控制迭代器：send 插队 / set_pause / resume_iter / restart 重放 / stop / history 策略 |
| `test-suit/haskell` | Haskell 迭代器 API（Data.List / Data.Foldable 语义）：iterate / scanl1 / foldr1 / map_accum_l / inits / tails / union / insert / lines / words 等 |
| `test-suit/stress` | 高压测试：10 万元素链、多订阅者、Subject 高压、递归重试 |
| `test-suit/bench` | 基准测试（`#skip` 默认跳过，`moon test -g bench` 运行） |

基准测试以控制台 JSON 输出结果（每个用例一行），可与 Rx-Rust 的 `benches/bench.rs` 结果对比。如需保存：

```bash
moon test -p test-suit/bench --include-skipped > moon_bench.json
```

## 核心抽象

| 类型 | 说明 |
|---|---|
| `Observable[T, E]` | 可观察对象（冷流），包装订阅函数，每次 `subscribe` 重新执行 |
| `Observer[T, E]` | 观察者，承载 `on_next` / `on_error` / `on_completed` 三个回调 |
| `Subscription` | 订阅句柄，`dispose()` 幂等取消订阅 |
| `Clock` | 虚拟时钟，时间类操作符基于它实现，`advance_time(ms)` 推进 |
| `Node[T]` | 惰性链表节点：持有值 + 懒加载源 + fallback，`from_iter` 构建 |
| `Itor[T]` | 可控制迭代器（vools 风格）：支持 send 插队 / 暂停 / 重放 / 停止 / 历史策略 |
| `TriggerEvent[T]` | 触发事件：事件名 + 载荷 + 自增序号 + 发生时刻（虚拟时钟毫秒） |
| `Trigger[T]` | 触发器：事件名（支持通配）+ 条件 + once + 优先级 + 处理器 |
| `TriggerRegistry[T]` | 触发器注册表：集中管理 + 通配匹配 + 优先级分发 + once 自动注销 + 幂等去重 |

## Itor / Node（可控制迭代器）

复刻 vools 的 `Itor` 相关 API，包装任意可重复迭代的源（`() -> Iter[T]`）：

| API | 说明 |
|---|---|
| `Node::new(val, next?)` / `Node::from_iter(iter)` | 构造节点 / 从迭代器构建惰性链表 |
| `Node::val()` / `Node::next()` | 取值 / 取下一节点（懒加载展开） |
| `Node::to_itor()` / `Node::to_iter()` | 节点链表 → Itor / Iter |
| `Itor::new(source)` / `from_array` / `from_iter` | 构造（数组源可重复迭代，副本独立） |
| `Itor::next()` | 取下一个值（自动初始化源） |
| `Itor::send(node, jump_when?)` / `send_value(v)` / `send_values(arr)` | 紧急插队 / 条件插队 |
| `Itor::set_pause()` / `resume_iter()` / `stop()` | 暂停 / 恢复 / 终止 |
| `Itor::restart()` | 回到 Pending，从历史头部重放，重放后继续源 |
| `Itor::history_strategy(fn)` / `set_history_max(n)` | 历史保留策略（-1 全保留 / n 条窗口） |
| `Itor::state()` / `is_pending` / `is_iterring` / `is_paused` / `is_stopped` | 状态查询 |
| `Itor::copy()` / `call()` | 返回独立副本（共享源工厂） |
| `Itor::do_iter(f, pre_f?, sub_f?)` | 副作用遍历（支持前置 / 后置钩子） |

**取值顺序**：历史重放（restart 后）→ 紧急插队 → 待处理源值 → 源迭代器。

## 创建类工厂

`from_iter` / `of` / `repeat` / `empty` / `never` / `error` / `range` / `from_range` / `from_range_with_step` / `from_callable` / `start` / `interval` / `timer`

## 操作符

**转换类**：`map` / `filter_map` / `flat_map` / `flat_map_latest` / `scan` / `concat_map` / `switch_map` / `group_by` / `curry_map`

**过滤类**：`filter` / `take` / `skip` / `first` / `last` / `take_while` / `skip_while` / `skip_n_events` / `take_n_events` / `skip_last` / `take_last` / `element_at` / `distinct` / `distinct_by` / `distinct_until_changed` / `distinct_until_changed_by` / `skip_until` / `take_until` / `contains` / `includes` / `sort` / `top_k` / `bottom_k` / `drop_none` / `fill_none` / `clamp`

**聚合类**：`count` / `reduce` / `collect` / `to_list` / `sum` / `average` / `minimum` / `maximum` / `min` / `max` / `mean` / `median` / `variance` / `std` / `quantile` / `n_unique` / `arg_min` / `arg_max` / `cum_prod` / `cum_mean` / `cum_sum` / `cum_min` / `cum_max` / `rolling_sum` / `rolling_mean` / `rolling_min` / `rolling_max` / `rolling_count` / `to_map` / `to_set` / `abs`

**组合类**：`start_with` / `concat` / `merge` / `zip` / `combine_latest` / `with_latest_from` / `amb` / `end_with` / `iif` / `sequence_equal`

**条件类**：`every` / `all` / `some` / `find` / `find_index` / `is_empty`

**错误处理类**：`retry` / `retry_indefinitely` / `retry_when` / `retry_with_backoff` / `retry_with_backoff_on` / `catch_error` / `on_error_return` / `on_error_resume_next` / `circuit_breaker` / `circuit_breaker_on`（背压操作符 `backpressure_*` 保留签名、同步模型下透传）

**时间类**（基于虚拟时钟）：`delay` / `debounce` / `throttle` / `throttle_first` / `rate_limit` / `timeout` / `sample` / `timestamp`（均提供 `_on(clock)` 变体）

**工具类**：`tap` / `tap_on_next` / `default_if_empty` / `ignore_elements` / `pairwise` / `pairwise_with_buffer` / `buffer_count` / `buffer_time` / `window` / `switch` / `sample_first` / `skip_until_data` / `take_until_data` / `run` / `debug`

## 触发机制（Trigger）

事件驱动的非定时任务触发：`事件名精确 / 通配匹配 → 条件过滤 → 优先级排序 → 分发执行`。`once` 触发器自动注销；`fire_with_key` 提供幂等去重；触发与执行解耦。

| API | 说明 |
|---|---|
| `TriggerRegistry::new()` | 创建空注册表 |
| `register(event_name, handler)` | 注册简单触发器（无条件、非一次性、优先级 0） |
| `register_with(event_name, handler, condition?, once?, priority?)` | 注册可配置触发器，返回 trigger_id |
| `unregister(trigger_id)` | 注销触发器（存在返回 true，否则 false） |
| `fire(name, payload)` | 分发事件，时刻取默认虚拟时钟当前时间 |
| `fire_at(name, payload, at)` | 分发事件（指定时刻） |
| `fire_with_key(name, payload, key)` | 幂等触发：key 已存在则整体跳过 |
| `has_trigger(event_name)` | 是否存在匹配该事件名（含通配）的触发器 |
| `trigger_count()` | 当前注册的触发器数量 |
| `clear()` | 清空所有触发器与幂等键（事件序号继续递增） |

**事件名匹配规则**（按 `.` 分段比较，不引入正则）：

| 模式 | 含义 | 示例 |
|---|---|---|
| 精确 | 逐段相等 | `task.done` 匹配 `task.done` |
| `*` | 单段通配（不跨段边界） | `task.*` 匹配 `task.done`，不匹配 `task.a.b` 或 `task` |
| `**` | 多段通配（匹配零段或多段，可出现在任意位置） | `a.**.b` 匹配 `a.b` / `a.x.b` / `a.c.d.b`，不匹配 `a.x`；纯 `**` 匹配任意事件名 |

**分发顺序**：命中事件名后按 `priority` 降序执行（同优先级保持注册序）；`condition` 不满足则跳过且不递增 `fired_count`；`once=true` 的触发器触发一次后自动注销。

```moonbit
let reg : TriggerRegistry[Int] = TriggerRegistry::new()
let _ = reg.register_with(
  "task.*",
  fn(ev : TriggerEvent[Int]) { println("收到: \{ev.name}") },
  priority=10,
  once=true,
)
reg.fire("task.done", 42) // 触发一次后自动注销
```

## Subject（多播主题）

`PublishSubject` / `BehaviorSubject` / `ReplaySubject`（`with_buffer_size` 限制重放窗口），均提供 `subscribe` / `on_next` / `on_error` / `on_completed` / `as_observable`。

## 调度器

同步语义 + 虚拟时钟等价实现（MoonBit wasm 目标无线程）：

`CurrentThreadScheduler` / `ImmediateScheduler` / `AsyncScheduler` / `ThreadPoolScheduler`

每个提供 `now()` 返回虚拟时间（毫秒）、`schedule(task)` 立即同步执行；`ThreadPoolScheduler` 额外提供 `get_num_threads()`。

## 示例

```moonbit
// 链式调用：map -> filter -> collect
let result = Observable::from_iter([1, 2, 3, 4, 5])
  .map(fn(x) { x * 2 })
  .filter(fn(x) { x > 4 })
  .collect()
let _ = result.subscribe_on_next(fn(v) { println(v) })

// Subject 多播
let subject : PublishSubject[Int, Unit] = PublishSubject::new()
let _ = subject.subscribe_on_next(fn(v) { println("收到: \{v}") })
subject.on_next(42)
subject.on_completed()
```

## rhop（vools-rhop 协议复刻）

`rhop/` 是 [vools-rhop 0.9.0](https://github.com/) 的 MoonBit 复刻：双方对等镜像任务中继协议
（需求端 submit → 共享介质/在线通道 → 执行端 execute → 结果回传），带加密信封、签名、完整性校验、
镜像 SQLite、守护进程与剪贴板共享。**纯 MoonBit + 零第三方 moonbit 依赖**，跨 wasm / js / native 三目标编译。

### 能力总览

| 层 | 文件 | 能力 |
|---|---|---|
| 协议 | `core.mbt` / `envelope.mbt` | `Side`（requester/executor）、`TaskStatus` 六态状态机、`Envelope` + checksum（`sha256:` + 规范化 JSON） |
| 摘要 | `digest.mbt` / `json_canonical.mbt` | 纯 MoonBit sha256 / md5 / hmac-sha256 / pbkdf2-hmac-sha256；两套 JSON 规范口径（见下） |
| 签名 | `signer.mbt` / `integrity.mbt` | `AbstractSigner`（FileHashSigner / NPUSigner）、信封完整性校验 |
| 密码学 | `key.mbt` / `crypto.mbt` / `rhop_js.mbt` | `VerifyResult` 三态 reason、Fernet 信封加解密、`RHOP-ENC:` 秘密串（js）；另有既有 `Aes256GcmCipher`（AES-256-GCM，js-only，读历史文件用） |
| 传输 | `transport_base.mbt` / `transport_local.mbt` / `transport_endpoint.mbt` / `transport_selector.mbt` / `online.mbt` / `relay.mbt` | `SharedPath` / `OnlineChannel` 抽象、本地原子写、`file://`+`http(s)://` 端点、在线优先选择、Git/SFTP 探测、自建中转服务 |
| 会话 | `session.mbt` / `config.mbt` / `interact.mbt` | 通道链（relay > online > shared）、配置构建与脱敏、execute/request/roundtrip 三模式 |
| 业务 | `mirror.mbt` / `requester.mbt` / `executor.mbt` / `daemon.mbt` / `actions.mbt` / `sync_folder.mbt` | 镜像 SQLite（乐观锁）、需求端/执行端 API、中继守护、动作注册表、目录同步 |
| 剪贴板 | `clipboard.mbt` | 本机剪贴板读写（Windows PowerShell / Linux wl-paste|xclip / macOS pbpaste 探测）+ 共享盘 push/pull 交换协议 |
| P2 | `rhop_task/` | 通用任务队列（A 提交加密 JSON → B 解密执行，SQLite 管依赖/状态）：**P2a+P2b 已落地 8 文件**；**心跳与 vools 互操作**（纯文本 `<ISO.%fZ> [worker]` / `closed_token="closed"` 哨兵，读端三级兼容；未来时间戳容差 60s fail-closed，与 vools 一致，真 vools 双向互操作 6/6）；未实现 Postgres 后端 / 大载荷落文件 / 任务执行明细表，未复刻 CLI·task-daemon·local_runner —— 详见矩阵 §5.9 A/B 节 |
| 既有 | `packet.mbt` / `cipher.mbt` | 本仓库早期的简版 `RhopPacket` / `RhopEnvelope` / `RhopCipher`（不是 vools 对照面） |

### 跨平台可用性

| 能力 | wasm | js | native | 说明 |
|---|:--:|:--:|:--:|---|
| 协议 / 摘要 / JSON / 签名 / 完整性 / 配置 / 会话 / 动作 / 剪辑板状态机 | ✅ | ✅ | ✅ | 纯逻辑，无平台依赖 |
| 信封加解密（Fernet）、`RHOP-ENC:` 秘密串 | — | ✅ | — | 走 `node:crypto`；非 js 返回可诊断 `Err`（`BAD_TOKEN`/`""`） |
| 本地介质 / 端点 / 目录同步 / 镜像 SQLite / 业务 API / 剪贴板真实读写 | — | ✅ | — | 走 `node:fs` / `node:sqlite` / 子进程；非 js 返回可诊断 `Err` 或 `available()=false` |
| 文件监控 `RhopWatcher` | — | ✅ | ✅ | wasm 无 monitor 后端，`start()` 返回可诊断 `Err`；可用 `process_file()` 手动处理 |
| `ClipboardFileSync::run_forever` 周期轮询 | 首轮 | ✅ | 首轮 | 非 js 无定时器，订阅后只推首轮 |

### 关键 API（速查）

```moonbit
// 1) 信封 + checksum（三目标）
let env = @rhop.Envelope::new(
  "job-001", @rhop.TaskStatus::Pending,
  @json.parse("{\"cmd\":\"echo hi\"}") catch { _ => @json.Json::null() },
  @rhop.Side::Requester,
)
let raw = env.to_rhop_bytes()                       // 规范 JSON 字节（含 sha256: 前缀 checksum）
let (ok, reason) = @rhop.IntegrityChecker::verify_bytes(raw)

// 2) 签名（FileHashSigner：preimage 用 ensure_ascii=True 口径）
let signer = @rhop.FileHashSigner::new()
let sig = signer.signature("job-001", @json.parse("{\"ok\":true}") catch { _ => @json.Json::null() })

// 3) 加密信封（仅 js）
let crypto = @rhop.RhopCrypto::from_key("my-secret")
let token = crypto.encrypt_json(@json.parse("{\"a\":1}") catch { _ => @json.Json::null() })
let vr = crypto.decrypt_verify(token)               // reason: OK / BAD_TOKEN / MALFORMED / NOT_JSON

// 4) 剪贴板 push/pull（状态机 + 交换文件）
let sync = @rhop.ClipboardFileSync::new("//share/rhop", role="push")
  .unwrap_or_else(fn() { abort("role 非法") })
let out = sync.sync_once()                          // {"changed": true, "text_len": 42} / {"changed": false, "reason": "…"}
let rounds = sync.sync_rounds(3)                    // {"rounds": 3, "changes": 1}

// 5) 需求端 / 执行端（仅 js；需配置与 data_dir）
let req = @rhop.Requester::from_config_dir(cfg, "./rhop-data").unwrap_or_else(fn() { abort("open") })
let task_id = req.submit("job-002", payload).unwrap_or_else(fn() { abort("submit") })
let result = req.get_result(task_id)
```

> 完整签名与逐参数语义见 [DOC.md](DOC.md) 的「rhop」章节；与 vools 的逐符号对照见
> `fist-mbt/docs/2026-10-27-rhop-vools-parity-matrix.md`。

### 与 vools-rhop 0.9.0 的对照与差异摘要

对外统计（**参考快照 `vools@bfdb162`**，2026-10-28 C4 终态，详见矩阵 §1/§8）：契约范围 **193** 个 vools 公开符号中
**178 个完全对齐（92.2%）**，含语义等价与部分实现达 **94.8%**；vools 全量 **473** 符号（含 P2 `task/` 265）覆盖率
**37.8%**（含等价/部分 = **43.6%**）。快照之外的未提交工作树改动（如 `watch.py` +1 成员）**不计入**。

主要差异（都不改变可观察协议语义）：

| # | 差异 | 说明 |
|---|---|---|
| 1 | **两套 JSON 口径**：envelope checksum 用 `ensure_ascii=False`，signer preimage 用 `ensure_ascii=True` | 复刻 vools 事实，分别由 `canonical_json` / `canonical_json_ascii` 承担；含中文 result 的签名只在前者口径下才与 vools 一致 |
| 2 | **浮点限制**：Python `repr(1.0)="1.0"`，本实现 `"1"`；指数形态也不同形 | checksum/签名语料只用 int/字符串/布尔/null/嵌套；解析侧用 `preserve_number_repr=true` |
| 3 | **错误表达**：vools 抛异常，本项目一律 `Result[_, String]` | 错误文本保留可诊断短语（`checksum mismatch` / `缺少必填字段` / `解析失败`） |
| 4 | **`clipboard.get_clipboard_backend` 形态**：vools 返回 `(read_fn, write_fn, name)` 三元组 | 本项目返回 `&ClipboardBackend?` + `get_clipboard_backend_name()` |
| 5 | **`run_forever` 形态**：vools 阻塞线程 + `stop_event` | 本项目 `@rx.Observable`（订阅即首轮、`dispose()` 停止），阻塞等价物 `sync_rounds(n)` |
| 6 | **平台强依赖项**：Fernet、文件系统、SQLite、子进程、剪贴板真实读写 | 仅 js 目标有真实实现；wasm/native API 齐备但显式返回「不可用」 |
| 7 | **不做项**：`secret.py` CLI、SFTP 远端文件操作（`put/get/listdir/...`）、`daemon.main` CLI | 属 P1/P2 或 CLI 范畴，已在矩阵中标 ⛔ 并说明原因 |
| 8 | **回执按方向分流（D1）**：`send_package` 回执含 `role`、`recv_package` 回执含 `payload` | 矩阵 §4.1 与本表同口径；避免同名字段在收发两个方向语义漂移 |
| 9 | **文件名白名单 + 删除契约（D6/D7，纯增量）**：`safe_filename` 拒绝路径穿越/纯点号/Windows 设备名；`Session::remove_package` 提供一次性 `res_` 清理 | vools 无这两项；本项目为安全与闭环清理而加 |
| 10 | **一次性 token 与入参形态（D8/D12）**：发送前清理陈旧 `res_`、消费后删除；`interact` 只接受 `RhopConfig`（vools `_coerce` 接受三种形态） | 降低陈旧回执误配、类型更显式 |

### 测试

```bash
moon check                         # 主包类型检查（rhop 包三目标 0 error）
moon test                          # 默认 wasm 后端（rhop 相关 156 例，全绿）
moon test --target js              # js 后端（本域包合计见下方计数表）
moon test --target native          # native 后端（rhop 相关 156 例，全绿）
moon test -p test-suit/rhop_clipboard --target js   # 剪贴板 25 例
moon test -p test-suit/rhop_vectors --target js     # 互操作产物生产者 2 例
moon test test-suit/rhop_business --target js       # 业务层 53 例（wasm/native 10 例）
moon test test-suit/rhop_task --target js           # P2 任务队列 101 例（wasm/native 46 例）
moon run demo/rhop_demo --target js -- send <共享目录>   # 端到端 demo（发 5 条加密包）
bash scripts/test_all.sh           # 跨平台总入口（自动修 PATH，抓三目标汇总行）
```

**测试入口退出码（`scripts/test_all.sh` / `test_all.ps1`，C2 起两入口语义一致）**

| 退出码 | 含义 |
|---|---|
| `0` | 全部判绿（check 0 error 且三/四步测试 failed=0、汇总行齐全） |
| `1` | 有步骤真实失败（编译错 / 测试红 / 汇总行缺失） |
| `2` | 用法错误或环境缺失（未知参数、moon/node 不在 PATH 等） |
| `3` | 一步都没执行（`--skip` 全跳过；**不能当 PASS**） |
| `4` | 构建锁等待超时（`with_moon_lock.sh` 并发冲突；非产品红，重试即可） |

**最新实测计数（2026-10-28 18:1x C4 终态，Windows 11 / moon 0.1.20261016 / node v25.2.1；Windows 与 WSL 四步 `RESULT: PASS`，互操作 `--strict --require-negative` 47/47）**

> ⚠️ C2 轮并行 lane（crypto/session/business）仍在持续追加测试，**跨 lane 总数会继续变化**；
> 本表数字为上述快照时点实测，最终数字以 `bash scripts/test_all.sh`（qa 终验）输出为准；
> 本域（`test-suit/rhop` / `rhop_vectors`）数字在本轮修复后自洽。

| 测试包 | 用例数 | 结果 |
|---|---:|---|
| `test-suit/rhop`（wasm / js / native） | 159 / 163 / 159 | 全绿 |
| `test-suit/rhop_vectors`（js，互操作产物生产者） | 0 / 3 / 0 | 全绿 |
| `test-suit/rhop_js`（js） | 60 | 全绿 |
| `test-suit/rhop_clipboard`（js） | 25 | 全绿 |
| `test-suit/rhop_interact`（js） | 28 | 全绿 |
| `test-suit/rhop_business`（wasm / js / native） | 10 / 69 / 10 | 全绿 |
| `test-suit/rhop_task`（wasm / js / native，P2a+P2b） | 46 / 103 / 46 | 全绿 |
| **全模块（项目级）** | **wasm 615 / js 851 / native 615**（C4 终态，双平台一致） | 全绿 |

跨实现一致性由 `test-suit/rhop_js/fixtures/vools_vectors.json`（真实 vools-rhop 生成的 envelope 字节 /
checksum / canonical JSON / digest / signer 向量）锁定，`scripts/verify_interop.py` 可反向复核。

### 安全说明

- **envelope checksum 不是签名**：它只防传输损坏/篡改，不证明来源；需要来源证明时用 `AbstractSigner`。
- **Fernet 密钥**来自 `RHOP_KEY` 环境变量、文件或配置字符串（`key.rb` 的 `load_key` 优先级 `source > path > env`）；
  密钥不进信封，配置 `to_dict()` 会把 `sftp.password` / `sftp.key_path` 脱敏为 `"***"`。
- **`RHOP-ENC:` 秘密串**只是「避免明文落盘」的便利封装，不是密钥托管方案。
- **`NPUSigner` 不做硬件调用**：序列号由注入的 `serial_provider` 提供；**provider 返回 `None` 时用 `UNKNOWN_NPU` 兜底**，因此 `sign()` 恒返回签名（`<marker>:UNKNOWN_NPU:<md5>`）——
  它明确标注「序列号未知」，**不伪造硬件序列号**；`has_serial()` 只表示是否拿到真实序列号，不代表能否签名。
- 明文信道（`RhopCipherNone`）仅用于测试；生产请用 `RhopCrypto`。

## 与 Rx-Rust 的差异

- 监控类 API（文件/文件夹监听、`watch_file` / `watch_folder` 等）未移植
- 时间类操作符基于虚拟时钟而非真实定时器，测试时用 `advance_time(ms)` 推进
- 背压与线程池调度器在同步模型下为签名占位，语义等价透传/立即执行

