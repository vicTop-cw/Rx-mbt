# PLAN-mcp-watcher-native-gaps —— 补齐 native 命令执行与真实文件监听

> 日期：2026-11-15 ｜ 状态：**draft（待 human_steward 定案后进入执行）**
> 上游：`PLAN-mcp-watcher-apis.md`（增资计划；R1/R4 已交付，本计划接 R2/R3 尾巴）
> 问题依据：`ISSUES-mcp-watcher-gap-audit.md`（2026-11-15 实测审计，ISS-1~4）
> 计划写作时实测锚点：native 全量 646 测试 645 过 1 挂（ISS-2）；
> `moon.mod` 已引入 `async@0.22.9` 未用 `@process`；
> `monitor/` 全目录无 sleep/@async/spawn（ISS-3）。

---

## ⚠️ 给实现 agent 的第一条指令

**开始实现前，先做 P-0 环境自检，不过则停下报 owner，不许改道：**

1. `moonbitlang/async@0.22.9` 是否真有 `@process`（`run` / `spawn` /
   `collect_output_merged`）与可用的 sleep 原语——`PLAN-mcp-watcher-apis.md`
   的该断言**未经实测**。写最小探针（`moon run --target native`）逐个验证。
2. `async test` 在 native 下的调度行为（`rx/ops_time_real_test.mbt` 已有
   async test 先例，确认其在本机 native 全量中的通过状态）。
3. 自检不过 = P1/P2 的技术前提不成立，**停下回报，不许臆造 API 或改用
   未经验证的绕行路径**。

## 0. 背景与现状（为什么补）

mcp-watcher（声明式文件系统事件 daemon，目标 MoonBit native 单二进制）
按 `PLAN-mcp-watcher-apis.md` 把 rx-mbt 当响应式内核复用。审计结论：
R1/R4 纯逻辑基建已达标；R2/R3 两块 OS 交互基建是缺口，而它们恰是
daemon 的事件源与 action 执行的命根子。详见 ISSUES 文档 ISS-1~4。

| 阶段 | 解决 | 对应问题 |
|---|---|---|
| P0 | 门禁回绿 + 账本更新 | ISS-2、ISS-4 |
| P1 | R3 native 命令执行 | ISS-1（连带 ISS-2 双目标恢复） |
| P2 | R2 轮询真实化（@async 化） | ISS-3 |
| P3 | R2 事件驱动真后端（stretch，交拍板） | 设计升级，非缺陷修复 |

## 1. 目标与非目标

**目标**
1. `moon test --target native` 与 `moon test --target js` 双目标全绿，
   TEST_REPORT 按双目标重生成（P0）。
2. native 目标下 `run_command` 白名单放行命令**真实执行**，
   返回 exit_code/stdout/stderr/真实 duration_ms（P1）。
3. native 目标下 `watch_folder_native` / `watch_file_native` 在后台任务中
   以真实间隔轮询，`subscribe` 不阻塞调用方，`unsubscribe` 后循环可退出
   （P2）；通过双进程物料验证。
4. 公共 API 签名零变更（`.mbti` diff 只允许新增，不允许改签名）。

**非目标（本轮明确不做）**
- 事件驱动监控（inotify / FSEvents / ReadDirectoryChangesW）→ P3 单列，
  须人工拍板后才立项，不混入本轮。
- cron 解析进 rx（维持 `PLAN-mcp-watcher-apis.md` §4 边界，留 mcp-watcher）。
- mcp-watcher 侧接线（`moon add` + 占位替换）——属 mcp-watcher 仓的执行轮。
- wasm 目标（monitor/rhop_task 按文件级 target 门控，wasm 不在范围）。

## 2. 技术方案

### P0 · 门禁回绿 + 账本更新（最小改动，先行）

1. `task_exec_test.mbt`「白名单放行 echo 命令」用例加 `#cfg(target="js")`
   （native 语义由既有用例「非 js 目标返回 SpawnFailed」覆盖）。
   头注释同步订正为「js 目标真实执行；native 见 SpawnFailed 用例」。
2. 重跑双目标全量，确认 native 645/645、js 646/646（读数以实跑为准）。
3. TEST_REPORT.md 重生成（含 native 与 js 两组读数与生成时间）。

### P1 · R3 native 命令执行（接 `@process`）

1. 前置自检（见首条指令）确认 `@process.run` 形态后，实现非 js 版 `run_cli`：
   - `@process.run`（或 spawn）以 **argv 数组 + shell=false** 启动，
     stdout/stderr 分别 Collect，`policy.timeout_sec` 超时（超时路径
     须杀进程并返回 `ExecError::Timeout`——现枚举已含 Timeout，无 js 实测路径，
     本轮补上）。
   - 结果映射 `(exit_code, stdout, stderr)`；启动失败 → `SpawnFailed`。
2. `run_command` 非 js 版从「同步调 run_cli 恒 Err」改为在 async 任务组内
   执行，`duration_ms` 用真实墙钟差值（js 版现为写死 `0L`，一并修为真实值）。
3. **恢复双目标测试**：P0 里 `#cfg(target="js")` 的 echo 用例，改为
   双目标真实执行断言（native 下 exit_code=0 且 stdout 命中）。
4. 新增用例：native 白名单放行（echo）、未授权拒绝（PolicyDenied）、
   超时（Timeout）、duration_ms > 0。

### P2 · R2 轮询真实化（@async 化，公共签名不变）

1. `watch_folder_native` / `watch_file_native` 订阅闭包改为：
   `@async.spawn` 后台任务 → 循环体内 `@async.sleep(poll_interval_ms)`
   真实睡眠 → 全量快照 diff → `on_next`；`subscribe` 立即返回 Subscription。
2. stop 语义：`Subscription` 回调置 `stopped = true`，循环在下一 sleep 醒来
   后退出并 `on_completed`（或静默结束，与 js 版语义对齐）。
3. 事件 `timestamp` 从虚拟 `watch_clock.now()` 改为真实墙钟
   （`real_now()` 语义，R1 已提供注入能力）。
4. 保留虚拟时钟确定性测试路径（沿用 `advance_time` 驱动验证 diff 逻辑），
   真实路径用可控间隔（如 100ms）+ 临时目录做短周期集成测试。
5. **双进程物料验证**（R2 验收主证据）：server 进程 `watch_folder_native`
   监听 tmp 目录并落盘事件序列；trigger 进程做 create/modify/delete/rename；
   断言事件种类与路径命中。物料放 `tests/harness/`（与 mcp-watcher 侧规划对齐）。
6. 可选增强（顺手做，不膨胀）：快照 diff 时把 `mtime_ns`/`size` 带入
   `WatchEvent.raw` 或新增可选字段——`fs_stat` 已返回这两项，零新 FFI；
   `is_dir` 需扩 C stub，**本轮不做**（进 P3 清单）。

### P3 · 事件驱动真后端（stretch，另立计划交拍板）

- Windows `ReadDirectoryChangesW`（Overlapped / 后台线程）优先
  （mcp-watcher 运行平台）；Linux inotify、macOS FSEvents 后续。
- `WatchEvent` 增强字段（is_dir / rename_cookie）与 C stub 扩展一并评估。
- 本轮只留问题记录，不写实现细节，防止未拍板先膨胀。

## 3. 验收标准（可机械判定）

| # | 标准 | 判定 |
|---|---|---|
| 1 | `moon fmt --check` / `moon check` 零错误零警告（双目标） | 退出码 0 |
| 2 | `moon test --target native` 全绿（P0 后 0 failed） | 实跑读数 |
| 3 | `moon test --target js` 全绿 | 实跑读数 |
| 4 | native `run_command` echo 白名单用例 stdout 命中、duration_ms > 0 | 测试断言 |
| 5 | 双进程物料：create/modify/delete/rename 事件序列命中 | harness 脚本退出码 |
| 6 | `watch_folder_native` 订阅后调用方不阻塞、unsubscribe 后进程可正常退出 | harness 脚本退出码 |
| 7 | `.mbti` diff 仅新增 | diff 审查 |
| 8 | TEST_REPORT.md 重生成且含双目标读数 | 文件检查 |

## 4. 风险

- **风险 1｜`@process` API 缺失或语义不符**：P-0 自检兜底，停下报 owner。
- **风险 2｜@async.sleep 粒度/Windows 调度抖动**：物料验证用宽松断言
  （事件命中即可，不强断言毫秒级时序）；轮询间隔可配置。
- **风险 3｜双进程编排在测试框架内不稳**：物料脚本化（独立可执行），
  不嵌在 `moon test` 内强跑；本机跑通为准，CI 行为如实标注。
- **风险 4｜P1 超时杀进程的平台差异**（Windows taskkill vs POSIX kill）：
  超时用例先以「返回 Timeout」为验收，进程回收完备性在 P3 评估。
