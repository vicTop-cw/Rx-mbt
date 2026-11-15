# PLAN · 为 mcp-watcher 扩充响应式 API（rx-mbt 作为"资粮"）

> 背景：mcp-watcher 是一个声明式文件系统事件 daemon（目标 MoonBit `native` 单二进制，下月参赛）。它把 rx-mbt 当作响应式内核来复用。
> 本文是**给 rx-mbt 的增资计划**：列出 rx 需要**新增 / 增强**的、且**符合响应式 API 范围**（Observable / Observer / Subject / Operator / Subscription / Scheduler / TriggerRegistry）的"更实 API"，使 mcp-watcher 能直接复用，而不是把 mcp-watcher 的领域逻辑写进 rx。
> 范围纪律：只新增"响应式原语"，**不**把 config/CLI/规则 DSL 写进 rx；保持 rx 零外部 OS 依赖（新增的 native 能力只依赖 MoonBit 生态内的 `@ffi` 与 `moonbitlang/async`，仍静态链接）。

---

## 0. 现状可复用资产（已读源码核实）

| 资产 | 位置 | 对 mcp-watcher 的价值 |
|------|------|----------------------|
| `TriggerRegistry[T]` | `rx/trigger.mbt` | 规则派发内核：事件名 `.` 分段通配（`*`/`**`）+ condition + 优先级 + once + 幂等去重 |
| `Observable/Observer/Subscription` | `rx/RX-MBT.mbt` | action 管线（一事件扇出多 action、error/complete） |
| `Subject`（Publish/Behavior/Replay） | `rx/subject.mbt` | 多播事件总线 |
| 时间算子（虚拟时钟） | `rx/ops_time.mbt` | `interval/timer/debounce/throttle/timeout/sample` 算法可复用 |
| `WatchEvent/WatchKind` | `monitor/watch_event.mbt` | 文件事件类型定义 |
| `ExecPolicy` 白名单模型 | `rhop_task/task_exec.mbt` | `allow/allow_any/timeout` + argv 不走 shell 的安全模型 |

**缺口（即本文要补的）**：① 原生文件监控后端是占位 `Unsupported`；② 时间算子只有虚拟时钟，无真实定时器；③ 命令执行 `run_cli` 仅 js 可用；④ 无 cron 解析；⑤ `TriggerRegistry.fire` 用虚拟时钟。

---

## 1. 需要新增 / 增强的 API（四组，均符合响应式范围）

### R1 · 真实时钟时间算子（扩展 `rx/ops_time.mbt`）

**目标**：mcp-watcher 需要真实世界的定时（cron 调度、去抖），而现有 `Clock` 是虚拟的（`advance` 手动推）。

新增 API 草图：
```moonbit
// 真实 interval：订阅后按真实墙钟每隔 ms 发射自增整数（冷 Observable）
pub fn real_interval(ms : Int64) -> Observable[Int64, Unit]

// 真实 timer：真实延迟 ms 后发射 0 并完成
pub fn real_timer(ms : Int64) -> Observable[Int64, Unit]

// 基于真实时钟的去抖/节流（复用现有算法，桥接虚拟 Clock）
pub fn[T, E] Observable::debounce_real(self : Observable[T, E], ms : Int64) -> Observable[T, E]
pub fn[T, E] Observable::throttle_real(self : Observable[T, E], ms : Int64) -> Observable[T, E]

// 注入真实墙钟，使现有虚拟算子"真实化"：每次真实 tick 调用 default_clock.advance(墙钟增量)
pub fn install_real_clock() -> Unit
```

- **为何 mcp-watcher 需要**：cron 调度（`real_interval` 驱动 `next_after` 计算）、fs 事件连续 modify 的合并（`debounce_real`）。
- **响应式契合点**：仍是 `Observable` + Operator，零领域耦合。
- **依赖**：`moonbitlang/async`（`@async.sleep`）用于 native 真实定时；wasm/js 回退到 async 或保留虚拟路径。
- **测试**：用 `install_real_clock` 注入可控 `RealClock` 做单测；同时保留纯虚拟路径做确定性测试（沿用 `advance_time`）。

### R2 · 原生文件系统事件源（补齐 `monitor/`）

**目标**：当前 `monitor/watcher_native.mbt` 返回 `Unsupported`，mcp-watcher 必须有真实监听后端。

新增 / 改造 API 草图：
```moonbit
// 替换占位：native 真实监听，产出热 Observable（事件到达即 on_next）
pub fn watch_folder_native(path : String, recursive~ : Bool = true)
  -> Observable[WatchEvent, WatchError]

// 单文件监视（native）
pub fn watch_file_native(path : String) -> Observable[WatchEvent, WatchError]

// WatchEvent 增强字段（对齐 mcp-watcher）：绝对 path、is_dir、mtime、size、rename_cookie
```
- **实现策略**（编译期择平台，非运行期分支）：
  - Linux → inotify（`inotify_init`/`add_watch` + 读 fd → 解析 `inotify_event`）
  - macOS → FSEvents（CoreFoundation FFI，事件循环回调）
  - Windows → `ReadDirectoryChangesW`（Overlapped/完成端口或后台线程阻塞读）
  - 公共 API 签名三平台一致；js 目标保留现有 node `fs.watch` 实现。
- **为何 mcp-watcher 需要**：这是 daemon 的"事件源"，没有它整个管线无输入。
- **响应式契合点**：事件源即 `Observable[WatchEvent, WatchError]`，天然接入 `filter/map/subscribe`。
- **依赖**：`@ffi`（平台 syscall）；无外部库。
- **测试（关键）**：**必须双进程物料验证**——一个 server 跑 `watch_folder_native` 监听某 tmp 目录并落盘结果，另一个 trigger 程序对该目录做 create/modify/delete。详见 mcp-watcher 侧 `tests/harness/`。

### R3 · 命令执行作为响应式 source/sink（增强 `rhop_task/` 或新包 `rx/sink`）

**目标**：当前 `run_cli` 仅 js 的 `spawnSync`；mcp-watcher 的 `command` action 需要 native 命令执行。

新增 API 草图：
```moonbit
// 冷 Observable：订阅即执行命令，发射执行结果（含 stdout/stderr/exit/耗时）
pub fn run_command(policy : ExecPolicy, payload : Json) -> Observable[ExecResult, ExecError]

// 订阅即执行的 sink 封装（把一个 action 流扇入命令执行）
pub fn command_sink(policy : ExecPolicy) -> ((Json) -> Unit)   // 或作为 Observable 的 subscribe 副作用
```
- **执行引擎**：用 `moonbitlang/async` 的 `@process`（`run`/`spawn`/`collect_output_merged`，native 跨平台，Windows 有 `spawn_shell`）。
- **安全模型（沿用并强化 `ExecPolicy`）**：`allow : Array[String]`（`cli:<prog>`/`*`）、`allow_any=false`、`timeout_sec`；**一律 argv 数组 + `shell=false`**，仅显式需要时 `spawn_shell`。
- **为何 mcp-watcher 需要**：`command` action 直接复用；`ExecPolicy` 白名单即 action 安全层。
- **响应式契合点**：命令是"冷 Observable"，可被 `map/filter/flat_map` 编排进 action 管线。
- **依赖**：`moonbitlang/async`；js 回退到现有 `spawnSync`。
- **测试**：白名单放行（`echo`/`true`）与拒绝（未授权程序）用例；无害命令即可。

### R4 · 派发与条件组合（增强 `rx/trigger.mbt` + `rx/ops_conditions.mbt`）

**目标**：让 mcp-watcher 的"事件名 = `<事件类型>.<glob>`"派发与 Layer2 条件（AND 语义）更实。

新增 API 草图：
```moonbit
// 类型化事件总线（构建于 TriggerRegistry）：按事件名 glob 发布/订阅
pub struct EventBus[T] { registry : TriggerRegistry[T] }
pub fn EventBus::new() -> EventBus[T]
pub fn EventBus::publish(self : EventBus[T], name : String, payload : T, at~ : Int64 = real_now()) -> Unit
pub fn EventBus::subscribe(self : EventBus[T], event_name : String, handler : (TriggerEvent[T]) -> Unit,
  condition~ : .., once~ : .., priority~ : ..) -> Int32

// 条件组合子（扩展 ops_conditions）：把多个 (TriggerEvent) -> Bool 组合
pub fn all_of[T](conds : Array[(TriggerEvent[T]) -> Bool]) -> (TriggerEvent[T]) -> Bool
pub fn any_of[T](conds : Array[(TriggerEvent[T]) -> Bool]) -> (TriggerEvent[T]) -> Bool
pub fn not_[T](c : (TriggerEvent[T]) -> Bool) -> (TriggerEvent[T]) -> Bool

// 让 TriggerRegistry 用真实时间（默认仍虚拟，兼容测试）
pub fn[T] TriggerRegistry::fire_real(self, name, payload) -> Unit   // = fire_at(.., real_now())
```

- **为何 mcp-watcher 需要**：`EventBus` 直接当规则派发内核；`all_of` 对应 condition 的 AND；`priority` 对应规则优先级；`fire_real` 解决 §0 缺口⑤。
- **响应式契合点**：事件总线、条件组合都是响应式/函数式原语，无领域耦合。
- **依赖**：纯逻辑（无 async/ffi）。
- **测试**：glob 匹配、优先级、once、去重、条件组合单测（沿用现有 `trigger_test.mbt`）。

---

## 2. 与 mcp-watcher 的复用映射

| mcp-watcher 组件 | 复用 rx 的（本文计划后） |
|------------------|--------------------------|
| 文件监听后端 | R2 `watch_folder_native`（`Observable[WatchEvent]`） |
| 规则派发内核 | R4 `EventBus` / `TriggerRegistry` |
| 时间 / 去抖 | R1 `real_interval` / `debounce_real`（或 `install_real_clock` 桥接现有算子） |
| `command` action | R3 `run_command` + `ExecPolicy` |
| Layer2 条件（AND） | R4 `all_of` 条件组合子 |
| action 管线（扇出） | `Observable` 链式 `map/flat_map/filter` |

**mcp-watcher 仍需自建（不属于响应式原语，rx 不应包含）**：config JSON（`@json` 解析）、CLI（start/stop/status/run/validate）、schema 语义校验、规则 DSL、变量占位、dry-run、遥测、扩展位注册表（EP-01~12）、热重载编排。

---

## 3. 实施顺序与验收（建议）

| 阶段 | 内容 | 风险 | 验收 |
|------|------|------|------|
| 1 | R4 派发 + 条件组合（纯逻辑） | 低 | 单测：glob/优先级/once/去重/条件组合 |
| 2 | R1 真实时钟（纯 + async） | 低 | 单测：真实 interval 节拍、debounce 真实化、可控 RealClock |
| 3 | R3 命令 Observable（async @process） | 中 | 单测：白名单放行/拒绝、无害命令、超时 |
| 4 | R2 原生监控（最重，需 ffi） | 高 | **双进程物料**（server 监听 + trigger 变更）覆盖 create/modify/delete/rename |

每阶段必须产出单测并进入 `TEST_REPORT`，保持 rx 既有"零警告零错误"门禁。

## 4. 非目标（边界）

- 不把 mcp-watcher 的 config/CLI/规则 DSL 写进 rx。
- 不为 rx 引入外部 OS 动态库；新增能力仅用 `@ffi` + `moonbitlang/async`（MoonBit 生态内、静态链接）。
- cron 表达式解析（纯逻辑）可放在 mcp-watcher，也可作为 rx 的一个轻量 `rx/cron.mbt` 纯算子；本文倾向放 mcp-watcher（领域相关），rx 只提供 `real_interval` 这类驱动原语。
