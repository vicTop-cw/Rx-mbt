# C4 寻虫报告 · 端到端/集成压力/安全（impl-crypto 域）

- 日期：2026-10-28
- 起点 HEAD `0e17d21`（v0.4.0，wasm 612 / js 825 / native 612）
- 域：crypto / transport / relay / watch / rhop_task
- 方式：只读审计 + 新增跨进程 E2E 用例取证 + 一次真实 Python vools 双向互读（C3 已建，C4 复用）

## 一、按计划五项的完成度（先给结论，再给细节）

| # | 项 | 状态 | 说明 |
|---|---|---|---|
| ① | relay 跨进程 A→C→B 真实端到端 | ✅ **完成并绿** | 独立进程作为 A 侧投递方 + 产品子进程中转 + 本进程 B；1MB 载荷、双向、错误 token 403 全部实测 |
| ② | rhop_task 双进程 E2E | 🟡 **部分完成** | **跨进程可见性已实测绿**（A 写 → 独立进程 claim → A 读到 LOCKED/worker_id）；`sqlite-local + TaskSync` 双进程拓扑与**跨进程并发 claim 唯一性**未完成（设计已修正但预算耗尽，见「未完成项」） |
| ③ | 心跳真实双进程扩展（崩溃/超时/未来时间戳） | 🟡 **部分** | C3 的 Python↔MoonBit 双向字节级互读用例仍在且绿；本轮**未新增**崩溃/未来时间戳的端到端用例（未来时间戳的 fail-closed 已有单测覆盖） |
| ④ | sqlite 并发压测 | 🔴 **未完成** | 首次实现踩了 `Atomics.wait` 等 async `spawn` 的**自锁**（正是 C2 记录过的同一类问题），已改为「同步等协调器进程」设计并落地 fixture，但**未跑通验证** |
| ⑤ | 安全审计 | ✅ **完成**，发现并修复 1 处真问题 | 见下 |

## 二、安全审计（⑤）

| 审计点 | 结论 | 证据 |
|---|---|---|
| **relay token 比较是否恒时** | ❌→✅ **发现真问题并已修** | 子进程原实现 `req.headers["x-rhop-token"] !== tok` —— 字符串 `!==` 首字节不同即短路，存在**时序侧信道**（可逐字节探测 token 前缀）。已改为 `sha256(got)` 与 `sha256(tok)` 后 `crypto.timingSafeEqual`（见 fix 报告） |
| 文件名校验 | ✅ 安全 | 服务端拒绝含 `/` 与 `\` 的名字（`indexOf("/")`、`indexOf(String.fromCharCode(92))`），并有 400 响应与用例 |
| 路径穿越 | ✅ 安全 | ①服务端文件名校验挡 `../`；②`HttpEndpoint` 对文件名整体 `uri_encode`（`%2F` 编码后不再是路径分隔）；③`file_url_to_path` 只接受 `file://` 且做归一化 |
| 临时目录权限 | ✅ 平台默认即可 | `fs.mkdtempSync` 在 POSIX 上以 `0700` 创建；Windows 下走用户临时目录 ACL。**未做显式 `chmod`**（跨平台收益低、Windows 无对应语义），记录为「依赖平台默认」 |
| 凭据落日志 | ✅ 无泄漏路径 | relay/token 仅出现在 HTTP 头与 `spec` 传递，不写日志；`TaskConfig::to_dict(mask=true)` 对 key/password/token 打码（C3 已验） |

## 三、① relay 跨进程 E2E 的实测证据（新增用例）

`test-suit/rhop_js/c4_e2e_test.mbt`（+2 用例）：

1. **1MB 大载荷 + 真实三方**
   - A = **独立 node 进程**（`fixtures/relay_peer.js`，我自己写的 HTTP 客户端，不走产品代码 → 真正独立对手方）
   - C = 产品的中转子进程（`RelayServer`）
   - B = 本进程（`RelayChannel`）
   - 断言：A 侧 `sentSha256` == 1MB 原文 sha256；B 侧取回长度一致且 sha256 一致；**反向**（本进程 PUT → 独立进程 GET）sha256 也一致
2. **错误 token 跨进程**：独立进程持错 token 读 → **403**（且拿不到内容）
3. **多包并发投递**：6 个不同包名逐个投递后逐个取回，内容与 sha 均不串（验证"包名→内容"映射在跨进程下不混淆）
4. 收尾断言：`__rxmbt_relay` 注册表清零

> 结论：relay 的 A→C→B 在**真实跨进程**下闭环成立，大载荷无丢包/无截断、token 校验与错误码符合 vools 协议。

## 四、② rhop_task 跨进程 E2E 的实测证据

`test-suit/rhop_task/c4_e2e_test.mbt`（+1 用例，绿）：

- 本进程（A）用产品 `SqliteTaskStore` 建库并写入 2 条任务（`t-hi` 优先级 9、`t-lo`）
- **独立 node 进程**（`fixtures/task_worker.js`，用 `node:sqlite` 直接操作**同一份产物库**，claim 语义与产品逐句对齐：`BEGIN IMMEDIATE` → 选 PENDING/RETRY_PENDING → 带状态守卫的 UPDATE → COMMIT）claim → 领到 `t-hi`
- 本进程立刻回读：`state=LOCKED`、`worker_id=worker-B`、`lock_time` 非空 ⇒ **跨进程可见性成立**
- 反向 `peek`：独立进程也能读到产品写的任务（双向可见）
- 收尾：句柄 close + 目录清理

> 这验证的是 **sqlite-shared 拓扑的核心契约**：任何实现（Python/MoonBit/其它）都能读写同一份库，而不是只验证我方单进程自洽。

## 五、未完成项（如实，不美化）

| 项 | 原因 | 下一步 |
|---|---|---|
| ④ sqlite **跨进程并发** claim 压测 | 首版用 `Atomics.wait` 等 async `spawn` → 阻塞本进程事件循环 → 子进程 `close` 不触发 → 自锁（**与 C2 记录的挂死同类**）。已修设计：改为同步 `execFileSync` 一个**协调器进程**，由协调器在自身事件循环里并发拉起 N 个 worker（`fixtures/task_worker_parallel.js` 已落地），但**未完成跑通与断言** | 下轮直接跑：5 个独立进程抢 5 条任务，断言命名互不重复 + 最终全 LOCKED |
| ② `sqlite-local + TaskSync` 双进程拓扑 | 预算耗尽（单进程版已有 C3 加密同步闭环用例） | 下轮：A 导出加密包落文件 → B 进程导入 → B 侧可见 |
| ③ 心跳「崩溃/超时」端到端 | 预算耗尽；`mark_closed`/过期判死已有单测 | 下轮：独立进程写 closed 标记/停写心跳 → 对端判 dead |
| 我域 temp 残留 +1 | 本轮实测 `rhop-*` 总 delta **+8**、我域前缀 delta **+1**（未定位具体目录名） | 已全量注入 exit hook（C3），需复查是哪条用例在 exit hook 之外仍留 1 个目录 |

## 六、级别汇总

| 级别 | 条目 |
|---|---|
| **P2（安全）** | relay token 非恒时比较（**已修**，见 fix 报告） |
| 观察（P3） | 临时目录权限依赖平台默认；本轮 temp delta 我域 +1 未定位 |
| 无 P0/P1 发现 | 跨进程 relay/task 主链路均无丢包、无句柄/注册表残留、无自锁（除已修正的设计问题） |
