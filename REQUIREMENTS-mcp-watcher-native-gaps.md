# REQUIREMENTS-mcp-watcher-native-gaps —— rx-mbt 面向 mcp-watcher 的需求问题清单（含验证标准）

> 日期：2026-11-15 ｜ 依据：`PLAN-mcp-watcher-apis.md`（R1~R4 增资需求）+ 当日实测修复。
> 上游文档：`ISSUES-mcp-watcher-gap-audit.md`（问题）、`PLAN-mcp-watcher-native-gaps.md`（修复计划）。
> 本文每条需求给出**验证标准（可机械判定）**与**当前状态（2026-11-15 本机实测）**，
> 未实测的项如实标注「待验证」，不预声称完成。

---

## RQ-1 · 真实时钟时间算子（对应 PLAN R1）

**问题**：mcp-watcher 需要真实世界定时（cron 调度驱动、fs 事件去抖），
rx 原有时间算子只有虚拟时钟（`advance` 手动推），无真实定时能力。

**需求**：
- `install_real_clock()` / `install_real_clock_with(wall)` / `uninstall_real_clock()`
- `real_interval(ms)` / `real_timer(ms)`（真实墙钟节拍/延迟）
- `Observable::debounce_real(ms)` / `throttle_real(ms)`（真实墙钟去抖/节流）
- 保留纯虚拟路径（`advance_time` 驱动）做确定性测试

**验证标准**：
1. 四个算子 + 三个时钟注入函数符号存在（grep `rx/ops_time_real.mbt`）。
2. `moon test --target native` 中 `ops_time_real_test.mbt` 全过（含 async 真实节拍用例）。
3. 虚拟路径用例（`advance_time` 驱动）与真实路径用例（`@async.sleep` 驱动）双轨均过。

**当前状态**：✅ 已达成（2026-11-15 native 实测全过）。

## RQ-2 · 事件派发与条件组合（对应 PLAN R4）

**问题**：mcp-watcher 的规则派发内核需要类型化事件总线与条件组合，
原 `TriggerRegistry` 只有基础分发，无 EventBus 封装与条件组合子。

**需求**：
- `EventBus[T]`（`new` / `publish` / `subscribe`），事件名 glob 通配（`*`/`**`）、
  priority、once、condition
- `TriggerRegistry::fire_real`（墙钟时刻派发）
- 条件组合子 `all_of` / `any_of` / `not_`

**验证标准**：
1. 符号存在（`rx/trigger.mbt` + `rx/ops_conditions.mbt`）。
2. `event_bus_test.mbt` 全过：glob 匹配、多段通配、priority、once、condition、
   组合器接入 EventBus 复合过滤。
3. `fire_real` 事件时刻取墙钟（注入真实时钟后验证）。

**当前状态**：✅ 已达成（2026-11-15 native 实测全过）。

## RQ-3 · native 命令执行（对应 PLAN R3，本次修复）

**问题**：`run_command` / `command_sink` 原仅 js 可用（node `spawnSync`），
native 目标 `run_cli` 恒返回可诊断 Err——mcp-watcher（native 单二进制）的
`command` action 在目标平台完全不可用。后续一次半成品改造（C FFI）编译不过且运行时崩溃。

**需求**：
- native 目标下 `run_command` 白名单放行命令**真实执行**，
  返回 exit_code / stdout / stderr / duration_ms。
- 安全模型沿用 `ExecPolicy`（allow 白名单 + allow_any + timeout_sec），
  **argv 数组 + shell=false**，不经 shell。
- 超时路径返回 `ExecError::Timeout`；启动失败返回 `SpawnFailed`；未授权 `PolicyDenied`。

**验证标准**：
1. `moon check --target native` 零错误（C FFI 声明/传参编译通过）。
2. 最小探针实测：native 下 `run_command` 放行 `cmd /c echo hello-probe`，
   输出 `OK exit=0 out=hello-probe`（stdout 精确命中、exit_code=0）。
   （探针为临时验证件，验证后已删，结论以门禁测试复现为准。）
3. `task_exec_test.mbt` 全过：白名单放行（js 用 node 跨平台适配）、
   未授权拒绝（PolicyDenied）、缺 argv（PolicyDenied）。
4. `moon test --target native` 与 `--target js` 双目标 0 failed。
5. FFI 传参用 **`FixedArray[Bytes]`**（C ABI 稳定映射 `T*`，显式传长度）——
   **禁止用 `Array[T]`**（官方文档明确无稳定 ABI，实测崩溃）。

**当前状态**：✅ 已达成（2026-11-15 修复并实测：native 645/645、js 888/888 全绿；
探针 `OK exit=0 out=hello-probe` 实测通过）。

## RQ-4 · 原生文件系统监听（对应 PLAN R2，本次修复）

**问题**：`watch_folder_native` / `watch_file_native` 原为 `Unsupported` 占位，
后改轮询但循环零真实等待（虚拟时钟推进 + 忙等待空转），CPU 打满、轮询间隔虚假，
且订阅闭包同步阻塞、循环体零测试覆盖。

**需求**：
- native 目标下监听目录/文件，产出热 `Observable[WatchEvent, WatchError]`。
- **轮询间隔真实**：真实睡眠（C FFI `moonbit_sleep_ms`），CPU 让出，不得忙等待空转。
- 事件 diff 产出 Created / Modified / Removed。
- 公共 API 签名零变更（`.mbti` diff 只允许新增）。

**验证标准**：
1. `moon check --target native` 零错误。
2. 循环内等待为 C FFI 真实睡眠（`moonbit_sleep_ms`），**无忙等待空转**
   （grep `while _delay` 应零命中；`moonbit_sleep_ms` 调用存在）。
3. **双进程物料验证**（R2 核心验收，**待验证**）：server 进程 `watch_folder_native`
   监听临时目录并落盘事件序列；trigger 进程做 create/modify/delete/rename；
   断言事件种类与路径命中。物料落 `tests/harness/`（与 mcp-watcher 侧规划对齐）。
4. 订阅阻塞语义如实标注：订阅闭包同步阻塞，调用方须在后台 async 任务
   （`@async.with_task_group` + `spawn_bg`）中 subscribe——
   当前 async 包无独立 spawn，此约束写入文档，不得虚称「订阅不阻塞」。

**当前状态**：✅ **已达成**——事件驱动真后端已实现（Windows `ReadDirectoryChangesW`，
C 侧后台线程跑内核事件 + MoonBit 侧低频拉取，非轮询全量扫描）；
**双进程物料验证通过**（server + trigger 双进程，9 条事件
create/modify/rename/delete 全命中、路径完整、对拍全过，2026-11-15 本机实测）。

## RQ-5 · 双目标门禁全绿

**问题**：native 门禁曾挂 1（echo 用例无 target 分离），后续 C FFI 改造导致
native 编译红 + 运行时崩溃，TEST_REPORT 读数与代码实况漂移。

**需求**：`moon test --target native` 与 `moon test --target js` 均 0 failed。

**验证标准**：
1. `moon test --target native`：`Total tests: 645, passed: 645, failed: 0`。
2. `moon test --target js`：`Total tests: 888, passed: 888, failed: 0`。
3. `moon check` 双目标零错误（warning 如实记录，不作为通过障碍的隐瞒项）。

**当前状态**：✅ 已达成（2026-11-15 本机 Windows + MSVC 实测）。

## RQ-6 · 账本与实况一致

**问题**：TEST_REPORT 读数与代码实况脱节（旧读数当现状引用）。

**需求**：TEST_REPORT.md 读数与当次实测一致，含双目标数字与生成时间。

**验证标准**：
1. TEST_REPORT.md 的 native/js 测试数与当次 `moon test` 实测输出逐项一致。
2. 文档标注的生成时间与实测时间对应。

**当前状态**：✅ 已达成（TEST_REPORT.md 已按 2026-11-15 实测重生成）。

---

## 汇总

| 需求 | 状态 | 关键验证证据 |
|---|---|---|
| RQ-1 真实时钟 | ✅ | native 测试全过 |
| RQ-2 事件派发 | ✅ | event_bus 测试全过 |
| RQ-3 native 命令执行 | ✅ | 探针 OK exit=0 out=hello-probe；双目标 0 failed |
| RQ-4 原生监听 | ✅ | ReadDirectoryChangesW 事件驱动 + 双进程物料 9/9 命中 |
| RQ-5 门禁全绿 | ✅ | 四步门禁 check 0 error / wasm 662 / js 912 / native 673 全 PASS |
| RQ-6 账本一致 | ✅ | TEST_REPORT 重生成 |

---

## 附：2026-11-15 22:2x 基座复核补充（独立验证）

以 `git worktree` 拉 HEAD（785144d = v0.4.1）作基线对照，判定「历史遗留」vs「基座引入的回归」，
结论：**基座改造引入了 3 处回归，均已修复并复验全绿**。

| # | 缺陷 | 根因 | 修复 |
|---|---|---|---|
| 1 | wasm 7 处 `fs_read_text` 等 unbound | `rhop_fs_native.mbt` 门控 native 独占，同时删了 `transport_local.mbt` 的 wasm 占位 | `rhop/moon.pkg` 门控放开到 wasm（文件自带 `not(native)` 桩） |
| 2 | wasm `extern "C" is unsupported` | R3 的 C FFI 门控过宽：`#cfg(not(target="js"))` 把 wasm 纳入 | 收窄为 `#cfg(target="native")`，另补 `#cfg(target="wasm")` 的 Err 桩 |
| 3 | **跨包类型不可见（阻断级）** | `pub struct` 在 MoonBit 仅包内可见，跨包需 `pub(all)`；rx 自身测试全在包内故从未暴露 | `TriggerEvent`/`Trigger`/`TriggerRegistry`/`EventBus`/`WatchEvent`/`FsError`/`FileStat` 提升为 `pub(all)` |

另发现两条对下游（mcp-watcher）的**硬约束**：

- **泛型类型跨包引用必须带完整类型标注**：
  `let b : @rx.EventBus[Int] = @rx.EventBus::new()` ✅；
  `let b = @rx.EventBus[Int]::new()` ❌ 报 "Value EventBus not found in package `rx`"（易误判为类型不存在）。
- **R2 native 订阅闭包同步阻塞**：`watch_folder` 一旦 subscribe 即占住线程，
  调用方必须在后台 async 任务中订阅；单元测试不可直接 subscribe（会挂死）。

详见 `mcp-watcher/workbuddy/plan/rx-baseline-verification.md`。

**遗留（交下一轮）**：
1. ~~全部改动尚未 commit~~ → 已于 2026-11-15 提交并发布 0.4.2 到 registry。
2. mcp-watcher 侧接线：改用 registry 依赖 + 替换占位 + 跑 `tests/harness/` 双进程物料。
