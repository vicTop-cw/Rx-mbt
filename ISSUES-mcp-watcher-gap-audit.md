# ISSUES-mcp-watcher-gap-audit —— 为 mcp-watcher 复用做缺口审计（2026-11-15）

> ## ⚠️ 本文档已作废（2026-11-15 22:2x 复核）
>
> 本审计写于 2026-11-15 09:48，其后**基座 R2/R3 已落地并修复**，本文结论已全面过期。
> 原文保留仅供追溯，**不得再作为判断依据**。当前结论以
> `mcp-watcher/workbuddy/plan/rx-baseline-verification.md` 为准。
>
> | 原文结论 | 现状 |
> |---|---|
> | ISS-1「R3 命令执行 native 路径为可诊断占位」 | ❌ **已失效**：R3 native 已改为 C FFI `moonbit_cmd_run`（协议 v2 + `"timeout"` 哨兵），真实可执行命令 |
> | ISS-2「native 门禁红 645/646」 | ❌ **已失效**：native 现为 **673/673 全绿** |
> | ISS-3「R2 形似神不似」 | ❌ **已失效**：R2 native 已改为 Windows `ReadDirectoryChangesW` 内核事件（C 后台线程 + `moonbit_watch_start/poll/stop`），事件驱动 |
> | 「R2/R3 未达标」 | ❌ **已失效**：R1~R4 全部落地且**跨包可消费**（`pub(all)` 可见性已补齐） |
>
> 复核时另修复了基座引入的 3 处回归：wasm 缺 fs 原语（7 errors）、wasm 误纳 extern "C"（1 error）、
> 泛型/非泛型类型跨包不可见（阻断级）。

---

> 审计方式：逐文件静态读取 + native 全量实测门禁（2026-11-15 当日跑）。
> 上游需求：`PLAN-mcp-watcher-apis.md`（R1~R4 四组增资 API）。
> 审计结论：**R1/R4 已达标可复用；R2/R3 未达标，且 R2 现状比占位更危险（见 ISS-3）。**
> 对账总表：

| 组 | 计划 API | 现状 | 门禁证据 |
|---|---|---|---|
| R1 真实时钟 | `install_real_clock` / `real_interval` / `real_timer` / `debounce_real` / `throttle_real` | ✅ 已落地（`rx/ops_time_real.mbt`），双轨测试（虚拟确定性 + async 真实节拍） | native 实测全过 |
| R4 派发组合 | `EventBus[T]` / `fire_real` / `all_of` / `any_of` / `not_` | ✅ 已落地（`rx/trigger.mbt` + `rx/ops_conditions.mbt`），glob/priority/once/condition 测试齐 | native 实测全过 |
| R2 原生监听 | `watch_folder_native` / `watch_file_native` | ⚠️ 形似神不似（ISS-3） | 双进程物料验证未做 |
| R3 命令执行 | `run_command` / `command_sink` | ❌ js-only（ISS-1） | native 门禁挂 1（ISS-2） |

---

## ISS-1 · R3 命令执行 native 路径为可诊断占位（硬缺口）

- **现象**：`rhop_task/task_exec.mbt:383-392` 非 js 目标的 `run_cli` 恒返回
  `Err("rhop_task: CLI 执行仅 js 目标可用（wasm/native 无子进程能力）")`；
  native 版 `run_command`（同文件 :523-600）完全依赖它，订阅即 `SpawnFailed`。
- **与计划的差距**：`PLAN-mcp-watcher-apis.md` R3 要求 native 走
  `moonbitlang/async` 的 `@process`（run/spawn/collect_output_merged）；
  `moon.mod` 已引入 `async@0.22.9`，但 `@process` 一行未接。
- **影响**：mcp-watcher 目标形态是 **MoonBit native 单二进制**，
  `command` action 在目标平台上完全不可用。
- **修复方向**：PLAN-mcp-watcher-native-gaps.md P1。

## ISS-2 · task_exec_test 无 target 分离，native 门禁红

- **现象**：`rhop_task/task_exec_test.mbt:9-54`「白名单放行 echo 命令」用例
  无 `#cfg` 门控，而其头注释（:5）自述「运行：moon test --target js」。
  native 下 `run_cli` 恒 Err → observer 走 `on_error` → :52 `fail("expected object")`。
- **实测证据**：2026-11-15 本机 `moon test --target native` 全量
  **Total 646, passed 645, failed 1**，失败即此用例
  （`task_exec_test.mbt:52:10-52:33 FAILED: expected object`）。
- **影响**：rx-mbt native 门禁当前**不是绿的**；任何以「native 全绿」为前提
  的下游动作（含 mcp-watcher 接线）都被这道红闸挡住。
- **修复方向**：PLAN-mcp-watcher-native-gaps.md P0（先用 `#cfg(target="js")`
  分离让 native 回绿；R3 落地后再恢复为双目标真实执行用例）。

## ISS-3 · watcher_native 轮询循环零等待，subscribe 即阻塞（比占位更危险）

- **事实 1（零等待）**：`monitor/watcher_native.mbt:157-173` 的
  `while !stopped.val` 循环内唯一"延时"是 :159 `watch_clock.advance(poll_interval_ms)`
  ——**虚拟时钟**推进（内存 O(1)），无任何真实 sleep/wait。
  monitor 全目录 grep `sleep|@async|spawn` **零命中**。
  等价于全速 busy-scan（每轮全量递归扫目录 + stat），CPU 打满。
- **事实 2（订阅即阻塞，静态判读待实测坐实）**：`Observable::new` 的订阅闭包
  同步执行该 while 循环，循环内无挂起点——单线程协作式调度下，
  `subscribe` 调用即卡死在循环里，`Subscription` 的 `stopped.val = true`
  回调没有机会被执行，且饿死整个 async 调度器。
  文件头注释（:3/:156）自认「同步阻塞轮询循环」「应在独立线程/进程中运行」，
  但未提供任何后台化机制。
- **事实 3（零覆盖）**：monitor 包仅 `fs_native_wbtest.mbt` 一个测试文件
  （覆盖 fs 原语），`watcher_native.mbt` 循环体**无任何测试**；
  `PLAN-mcp-watcher-apis.md` R2 定的验收「双进程物料验证」未做。
- **设计取舍边界**：`PLAN-rhop-native-fs.md` 非目标里「统一轮询快照 diff
  （不用 inotify/FSEvents/ReadDirectoryChangesW）」是**有意决策**，本审计不改判；
  但「轮询」必须含真实轮询间隔——零间隔全速循环不是轮询，是缺陷。
- **修复方向**：PLAN-mcp-watcher-native-gaps.md P2（@async 后台任务 +
  `@async.sleep` 真实间隔；事件驱动真后端列为 P3 交人工拍板）。

## ISS-4 · TEST_REPORT.md 账本漂移

- **现象**：`TEST_REPORT.md` 生成于 **2026-10-15 10:49:46**（wasm 目标，
  400 测试全绿）；当前代码已 646 测试，且 native 目标存在 1 失败（ISS-2）。
  账本读数与代码实况严重脱节，不能作为门禁依据引用。
- **修复方向**：PLAN-mcp-watcher-native-gaps.md P0 验收内
  重生成 TEST_REPORT（native + js 双目标读数）。

---

## 附：本次审计实测命令与读数

```
cd E:/IDEProjects/AI/rx-mbt
moon test --target native
# Total tests: 646, passed: 645, failed: 1.
# 失败：rhop_task/task_exec_test.mbt:9 "run_command: 白名单放行 echo 命令"
```

## 附：mcp-watcher 侧接线现状（审计顺带核实）

- `mcp-watcher/moon.mod` 无 rx 依赖；各包 `moon.pkg` 无 rx import——
  「复用 rx 作响应式内核」目前代码层面零接线，均为 trait + 占位 + TODO。
- `watch/backend.mbt`、`scheduler/run_scheduler` 占位注释明确等待
  rx 的 `monitor.watch_folder_native` 与 `EventBus + real_interval` 接入。
- 领域侧自建（cron 解析、glob 匹配、config 手动解析）符合
  `PLAN-mcp-watcher-apis.md` §4 边界，无需回炉。
