# C3 寻虫报告 · Batch D 业务层（契约与文档一致性 / 互操作盲区 / 清整收尾）

- 轮次：C3（组合模式第 3 轮 · 第 1 步：只读寻虫）
- 执行体：impl-business
- 域：`rhop/{mirror,requester,executor,daemon,sync_folder}.mbt` + `test-suit/rhop_business/` + `test-suit/rhop/actions_test.mbt`
- 时间：2026-10-28
- 环境：Windows + Git Bash（moon 0.1.20261016 / node v25.2.1）；WSL Ubuntu-22.04（moon 0.1.20261021 / node v25.2.1）
- 方法：读码 + 实测计数（temp 目录 set-diff）+ 文档逐条比对 `.mbti`/源码 + SQL `pragma_table_info` 实测

> 结论：**6 个文档/契约一致性问题**（D1 类 3 条、D2 类 2 条、D3 类 1 条）+ **1 个卫生结构性问题** + **1 处口径澄清**。
> 业务层**代码语义**在 C2 后已稳定（57/57 绿），本轮问题集中在「文档落后于代码」与「测试清理策略依赖退出钩子」。

---

## 1. QA C2-V1 temp 卫生：复核 + 结构性弱点（本报告核心 ①）

### 1.1 复核结论：QA 观测的「约 9/轮」在当前代码下**已不复现**

| 场景 | 观测（`%TEMP%/rhop-biz-*` 计数，set-diff） |
|---|---|
| C2 修复前（QA 观测点，daemon_test 只 close 单端 + 退出钩子不关库） | 每轮残留 **+3**（daemon 用例）～ 报告口径 **≈+9** |
| C2 修复后（先关 sqlite 句柄再删目录；daemon_test 全部 close 双端） | 正常退出 **delta = 0** |
| C3 本轮复核（连跑 3 次） | `run#1/2/3` 均 **before=0 after=0 delta=0**（57/57 绿） |

→ 说明「退出钩子 + 双端 close」已能覆盖**正常退出**路径。

### 1.2 但仍有结构性弱点（新发现，C3-01）

| 项 | 证据 |
|---|---|
| 清理**依赖进程退出钩子**：36 处 `biz_temp_workspace()` 只有 11 处显式收尾 | `grep -c "biz_temp_workspace()"` 合计 36；`grep -c "rhop_remove_dir_all"` 合计 11（c2 6 + daemon 5） |
| 进程被 **kill / 超时**（钩子不执行）时，残留上限 = 未完跑用例数 | 每用例 1 个 workspace ⇒ 若在 daemon 用例段被 kill，最多残留约 6 个；若在 suite 早期被 kill 更多 |
| 残留**不会被下一次运行自动回收** | 复现：手工造 `%TEMP%/rhop-biz-*` 两个目录（模拟被 kill 的上一轮）→ 跑 suite → 目录仍在（exit 钩子只清理本进程创建的） |

**影响**：CI/长跑机器上 `%TEMP%` 会缓慢累积（本轮实测本机历史累计 5,300+ 个 `rhop-*` ≈ 151MB，跨 lane）。
**修法（C3 已实施）**：helper 首次调用清扫本包历史残留 + 「新建即回收上一个」⇒ 任意时刻存活 ≤1，被 kill 最多留 1 个；用例收尾走 `biz_cleanup(dir)`。

---

## 2. 文档 / 矩阵一致性（本报告核心 ②）

比对对象：`fist-mbt/docs/2026-10-27-rhop-vools-parity-matrix.md`（§5/§7/§11）、`DOC.md`（业务 API 段）、`README.md` / `README.mbt.md`，
基准：`rhop/pkg.generated.mbti` + 源码 + `moon test` 实测数。

### 2.1 矩阵（修复前共 14 处不一致）

| # | 位置 | 问题 | 证据 |
|---|---|---|---|
| D1-1 | §5 引言 | 声明「**在途项**：daemon 2 例、requester 2 例当前失败（Batch D 收尾中）」 | 实测 `test-suit/rhop_business --target js` = **57/57 全绿**；该声明属**假风险**（会误导终验） |
| D1-2 | §5.2 表 | `RelayDaemon::start(poll_interval_ms)` **签名错误** | `.mbti`: `RelayDaemon::start(Self, Int32)`；源码语义是 `max_rounds`（跑满即退），轮询间隔在 `from_config_dir(..., poll_interval_ms?)` |
| D1-3 | §5.5 表 | `jump.push/pull/sync`、`compute_sync_plan`、`scan_local_files`、`collect_files`、`should_exclude` 全部标 **⛔** | 实际 8 个已落地并有测试（`actions_test.mbt` 10 例 + `actions_fs_test.mbt` 3 例）；文档**低估**覆盖率 |
| D1-4 | §5.1 表 | 缺 `pending_count` / `sync_log_count` / `raw_run` / `try_*` 四个已公开符号 | `.mbti` 中存在且被测试使用 |
| D1-5 | §5.2 表 | 缺 `run_once` / `process_inbox` / `push_local` / `pull_remote`（vools 私有 → 本项目公开增量） | `.mbti` 中存在 |
| D1-6 | §5.2 | 缺 daemon **语义边界**（单消费者/消费即删、主线程阻塞、幂等守卫） | 源码 `daemon.mbt` 头注释有，矩阵无 |
| D1-7 | §5.4 表 | 缺 `Executor::{from_config_dir, from_mirror_path, worker_id, mirror}` | `.mbti` 中存在 |
| D1-8 | §5.6 表 | `run_forever` 未标注参数顺序；缺 `fnmatch`→`sync_glob_match` 行（应标 🟡 无 `[seq]`） | 源码 `(poll_interval_ms, max_rounds)`；`sync_glob_match` 仅 `*`/`?` |
| D1-9 | §7 差异表 | 只有 21 条，缺 6 条业务层差异（jump 真传输/damon 主循环/同步判据 sha256/glob 无字符类/单消费者/镜像库列级增量） | 见 §3 差异矩阵 |
| D1-10 | §11 | 「`actions`(2 ⚠️ **已实现未测**)」「`requester`(6 ✅，**测试在途**)」 | 均已交付且有测试 |
| D1-11 | §11 | 「`test-suit/rhop_business` 已 **38/38**」 | 现为 **57/57**（js）、10/10（wasm/native） |
| D1-12 | §11 | 「`test-suit/rhop` **156/160/156**」 | 实测 **131/160/131**（wasm/js/native） |
| D1-13 | §5 | 无 schema 列级契约（列数/额外列/类型差异） | 见 §4 |
| D1-14 | §5.1 表 | `MirrorDB.close` 未说明 `open_temp()` 库关闭会递归删临时目录 | 源码 `close()` 语义 |

### 2.2 DOC.md（修复前 4 处不一致）

| # | 位置 | 问题 |
|---|---|---|
| D2-1 | `Executor` 代码块 | 缺 `Executor::from_config_dir` / `from_mirror_path`（实际存在，测试与闭环都用） |
| D2-2 | `SyncFolder::run_forever` 注释 | 写成 `// (rounds, poll_ms)` —— **参数顺序与命名都不对**（实际 `(poll_interval_ms, max_rounds)`） |
| D2-3 | `sync_glob_match` 注释 | 写成 `// pattern 匹配（* / ? / **）` ⇒ 暗示支持 `**` 与更多 glob 语法；实际只支持 `*` / `?` |
| D2-4 | mirror/daemon/sync_folder 段 | 无 schema 列级契约、无 daemon 单消费者/阻塞语义、无 sync 差异说明（详见 §3） |

> 另发现**文档刷新不同步**：DOC.md 的 actions/mirror/requester/daemon API 列表在 C2 已更新，
> 而矩阵 §5 仍停在 Batch D 收尾时的旧快照（D1-1/2/3/10/11/12）。建议后续由 qa 脚本从
> `.mbti` + 测试汇总行**生成**这两处数字，避免再次漂移（列为建议，非本轮改动）。

### 2.3 README（0 处不一致）

`README.md:257` 与 `README.mbt.md:257` 的业务行（文件清单 + 一句话职责）与代码一致，且两份文件该行逐字相同，**无需改动**。

---

## 3. 与 vools 的语义差异：文档化状态（本报告核心 ③）

| 差异 | 源码头注释 | DOC.md（修前） | 矩阵（修前） | 处置 |
|---|---|---|---|---|
| MirrorDB 乐观锁错误文本 `stale_version:` 前缀 | ✅ `mirror.mbt` 头 + `StaleVersionError::to_string` | ✅ 已有（`Err(stale_version: …)` 注释） | ✅ §5.1 备注 | 已对齐，无需补 |
| daemon **单消费者**语义（消费即删 / 无 ack / 不丢包但可能重复） | ✅ `daemon.mbt` 头 | ❌ 无 | ❌ §7 无此行 | **C3 补**（DOC 段 + §7 #26） |
| sync_folder glob **无 `[seq]`**（且只匹配 basename） | ✅ `sync_folder.mbt` 头 | ❌ 注释反而写 `* / ? / **` | ❌ 无 | **C3 补**（DOC 注释修正 + §5.6 🟡 行 + §7 #25） |
| jump 真传输 **unsupported**（绝不伪造计数） | ✅ `actions.mbt` 头 | ❌ 只说「离线实现」，未说真传行为 | ❌ 原 #6 只讲 `SftpChannel`，不覆盖 actions | **C3 补**（DOC 段 + §7 #22） |
| 另 3 条差异本轮补登记 | — | — | — | daemon 主循环阻塞（§7 #23）、同步判据 sha256≠size+mtime（§7 #24）、镜像库列级增量（§7 #27） |

---

## 4. sqlite 列级核对（本报告核心 ④）：本项目 mirror 侧 vs vools `SCHEMA_SQL`

> **口径澄清**：任务书提到「31 列」，实测（`pragma_table_info`，`c3-2` 用例）三表合计为 **28 列**；
> 31 应是「28 列 + 3 索引」或含 task_store 侧（P2b，归 impl-crypto 域）的合计口径。
> 本表只覆盖 `rhop/mirror.mbt` 的三表（mirror 侧），task_store 侧由 impl-crypto 出报告。

| 表 | vools 列（11 / 7 / 8） | 本项目列（13 / 7 / 8） | 差异 |
|---|---|---|---|
| `tasks` | task_id, status, side, payload, result, error, signature, version, created_at, updated_at, checksum | 同左 + **envelope**, **claimed_by** | 见下 3 条 |
| `events` | id, task_id, event_type, old_status, new_status, detail, created_at | 逐列一致 | 无 |
| `sync_log` | id, direction, transport, task_id, success, error, bytes_xfer, created_at | 逐列一致 | 无 |
| 索引 | `idx_events_task`, `idx_sync_task` | 同左 + **`idx_tasks_status`** | 多 1 条（状态过滤/计数用） |

逐列差异：

1. **`tasks.envelope`（新增，NOT NULL）**：整信封规范 JSON（`Envelope::to_rhop_bytes`），读回时走
   `from_rhop_bytes` ⇒ **checksum 校验**。价值：坏行必报可诊断 Err，而不是像 vools 那样从列里
   「拼」出一个看似正常的信封。代价：行体积 ≈ payload 的 2 倍（payload/result 仍单独存列，供 vools 语义查询）。
2. **`tasks.claimed_by`（新增，可空）**：记录领取者（vools 只把 worker 写进 events.detail）。价值：可直接查
   「谁领的」；不改变乐观锁语义。
3. **类型/约束**：`version` 本项目 `INTEGER NOT NULL DEFAULT 1`（vools `INTEGER DEFAULT 1`）；
   `payload` 本项目 `TEXT NOT NULL`（vools 允许 NULL）。均更严格，读取 vools 产出的库行不受影响
   （vools 写入时 payload 总是 `json.dumps` 结果）。
4. **互操作边界**：本项目**不保证**与 vools 直连共用同一 SQLite 文件（列集不同）；只保证「同库同语义」，
   跨实现交互走 `.rhop` 信封（Batch A 已逐字节对齐）。已登记为 §7 #27。

---

## 5. 问题清单与处置（汇总）

| 编号 | 级别 | 问题 | 处置 |
|---|---|---|---|
| C3-01 | P1（卫生） | workspace 清理依赖退出钩子；被 kill 时残留、且历史残留不会被下次运行回收（QA C2-V1 的结构性残留） | 已修：helper 首次清扫 + 新建即回收上一个 + `biz_cleanup`；回归 `c3-1a/1b` |
| C3-02 | P1（文档） | 矩阵 14 处与代码/实测不一致（含**错误签名**与**假风险声明**） | 已修：§5 引言/§5.1/§5.1.1(新)/§5.2/§5.4/§5.5/§5.6/§7/§11 |
| C3-03 | P1（文档） | DOC.md 4 处：缺 Executor 构造入口、`run_forever` 参数注释错、glob 注释误导、缺 schema/daemon/sync 语义 | 已修：4 段补丁 |
| C3-04 | P2（契约） | schema 列级契约无文档、无护栏 | 已修：DOC + 矩阵 §5.1.1 + 可执行护栏 `c3-2`（pragma 实测 13/7/8） |
| C3-05 | P2（文档） | 语义差异 3 条未进 DOC/矩阵 | 已修：DOC 段落 + §7 #22/#23/#24/#25/#26/#27 |
| C3-06 | P2（流程） | DOC 与矩阵由不同轮次刷新导致漂移（DOC 新、矩阵旧） | 建议：终验前由 qa 脚本用 `.mbti` + 测试汇总行生成数字（本轮已在报告标注，不擅自改 qa 脚本） |
| C3-07 | — | README 业务行 | 复核一致，**无需改** |

修复与验证证据见 `2026-10-28-c3-fix-business.md`。
