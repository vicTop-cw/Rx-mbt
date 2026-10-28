# C1 修复轮报告 · 业务层 / 持久化域（impl-business）

- 输入：`fist-mbt/reports/2026-10-28-c1-bugfind-business.md`（P0 0 / P1 6 / P2 11 / P3 6）
- 修复范围：`rhop/mirror.mbt`、`rhop/daemon.mbt`、`rhop/requester.mbt`、`test-suit/rhop_business/`
- 未提交 git（lead 统一提交）。

## 0. 结论摘要

| 类别 | 结果 |
| --- | --- |
| P1 | **6 / 6 已修**，全部有回归用例锁定 |
| P2 | **4 / 11 已修**（P2-1 事务、P2-2 busy_timeout、P2-3 临时目录泄漏、P2-4 close 错误可见性）；其余 7 条见 §3（跨 lane / 需产品口径 / 已评估为延后） |
| P3 | **1 / 6 已修**（P3-4 测试工作区泄漏，随 P2-3 同根因）；其余属其它 lane（clipboard / task_queue / actions / sync_log 保留期） |
| 新增回归用例 | 6 个（`p1_fix_regression_test.mbt`，47 例中 6 例） |
| 公开 API | **无破坏性变更**；新增 5 个 additive 函数（§4） |

判绿门真实汇总行（全部本机实跑，`bash scripts/with_moon_lock.sh` 包裹以避开并行构建锁）：

```
moon check                          → Finished. moon: ran 22 tasks, now up to date (255 warnings, 0 errors)
moon test -p test-suit/rhop_business --target js → Total tests: 47, passed: 47, failed: 0.
moon test test-suit/rhop --target js             → Total tests: 148, passed: 148, failed: 0.
moon test --target js                            → Total tests: 792, passed: 792, failed: 0.
```

> 说明：`moon check` 用仓库根（等价于 `moon check rhop` 的超集），三目标（js / wasm / wasm-gc）0 error。
> 全量 js 首跑时 `test-suit/rhop_interact/interact_test.mbt:967`（C1-F5 只读介质）曾失败 1 例，
> 定位为 **impl-session lane 在途改动**（`rhop/session.mbt:457-464` 的「写端不可用」判定 + 测试同批新增），
> 复跑（其落盘后）已 792/792 全绿；与本轮改动无因果关系（`send_package` 不经过 mirror/daemon/requester 写路径）。

## 1. P1 逐条

### P1-3 `rhop_ffi_db_run` 丢弃 `changes` → 零行更新伪装成功

- **修法**：JS 侧返回 `{changes, lastInsertRowid}`；MoonBit 侧 `rhop_db_run_changes` / `MirrorDB::run_changes` 把 `(changes, lastInsertRowid)` 一路带到调用方，所有写路径**必须**显式校验。
- **改动**：`rhop/mirror.mbt:169`（`pub fn rhop_db_run_changes`）、`:186/:209`（js / 非 js 实现）、`:843`（`MirrorDB::run_changes`）、`:1669`（`rhop_ffi_db_run` JS 体）。
- **用例**：`test "P1-3: 零行更新不再伪装成功——同版本 upsert 必须 stale Err，更高版本可写"`（`p1_fix_regression_test.mbt:33`）。
- **证据**：修复前 JS 体 `try { db.run(...); return true } catch` —— 恒 `true`；修复后同版本 upsert 走 `changes==0` 分支 → `stale_version` Err。

### P1-1 乐观锁非原子 → 丢失更新

- **修法**：`UPDATE ... WHERE task_id=? AND version=?` 谓词下推；`changes != 1` 时**事务内**再读一次，区分「任务被删」与「版本被推进」，后者返回 `StaleVersionError`（`stale_version: task=… local=… expect=…`）。
- **改动**：`rhop/mirror.mbt:1167`（版本谓词 SQL）、`:1096`（`update_status` 整体：读 → 校验 → 谓词更新 → 零行复核）。
- **用例**：`test "P1-1: 两 MirrorDB 实例交错 → 旧 version 的 update_status 必须 Err（丢失更新回归）"`（`p1_fix_regression_test.mbt:65`）。两个 `MirrorDB` 实例指向同一库文件，B 先 claim 到 v2，A 持 v1 写 Running（Claimed→Running 本身是合法流转，所以成功只可能来自版本守卫失效）→ 断言 Err 含 `stale_version` 且库里仍是 v2/Claimed。

### P1-2 `claim_task` 无状态守卫 → 双领

- **修法**：`UPDATE tasks SET status='claimed', claimed_by=?, version=version+1, … WHERE task_id=? AND status=? AND version=?`；零行 → 事务内复核（任务消失 / 已被别人领 / 版本已推进），分别给可诊断 Err。
- **改动**：`rhop/mirror.mbt:1278`（领取 SQL 谓词）、`:1226`（`claim_task` 整体）。
- **用例**：`test "P1-2: 双 claim 同一任务 → 第二个 Err，状态不被第二个 worker 改写"`（`p1_fix_regression_test.mbt:102`）。A 领取成功（Claimed/v2）→ B 再领必须 Err，且库中 `claimed_by` 仍是 A。

### P1-4 `upsert_task` 读-改-写非原子 + `INSERT OR REPLACE` 清空 `claimed_by`

- **修法**：改成单语句原子写：
  `INSERT INTO tasks (...) VALUES (..., NULL) ON CONFLICT(task_id) DO UPDATE SET ... WHERE excluded.version > tasks.version`；
  `claimed_by` 不在 UPDATE 列里（保留原值），低版本写入被 `WHERE` 挡掉并归为 `stale_version`。
- **改动**：`rhop/mirror.mbt:937`（原子 upsert SQL）、`:918`（`upsert_task` 改为单语句 + 零行复核，不再 pre-SELECT）。
- **用例**：同 P1-3 用例（同版本 → stale；更高版本 → 成功且 `claimed_by` 保留）。

### P1-5 daemon 执行失败不回传结果信封 → 需求端永久超时

- **修法**：抽出 `RelayDaemon::write_outbox_result(task_id)`，成功/失败两条分支共用；失败分支先把任务显式落到终态 `Failed`（`report_failure`，仅当还没到终态）再写 outbox 结果信封。与 vools `daemon.py:218-222`（无条件移入 outbox）语义对齐，并额外携带错误原因。
- **改动**：`rhop/daemon.mbt:296`（`write_outbox_result`）、`:372`（成功分支）、`:380-392`（失败分支：落 Failed → 写 outbox）。
- **用例**：`test "P1-5: executor 执行失败 → outbox 有 Failed 信封，结果能回到需求端并可查 failed"`（`p1_fix_regression_test.mbt:136`）。用未注册 action 触发失败，断言：共享介质上出现回传给 requester 的 `job-bad.rhop`、其信封 `status == Failed`、executor 镜像库里是 `Failed`、requester `get_result` 能取到 `failed`。

### P1-6 `task_id` 路径穿越 → 越界写文件

- **修法**：三层防御
  1. `validate_task_id`：白名单 `^[A-Za-z0-9._-]{1,128}$` + 显式拒绝 `..`/`.`/`/`/`\`/控制字符/空串（`rhop/mirror.mbt:609`）；
  2. DB 层四个入口（`upsert_task`/`get_task`/`update_status`/`claim_task`…）统一校验，非法 id 直接 Err；
  3. 落盘层 `rhop_join_checked`（`rhop/mirror.mbt:644`，规范化后用 `rhop_normalize_path`(`:580`) 断言结果仍以 base 前缀开头），在 `requester.mbt:116` 与 `daemon.mbt:308` 的 outbox/收件箱路径使用；解码层 `daemon.mbt:514` 拒绝非法 id 并走「坏信封 → `failed/`」通道计数。
- **用例**：`test "P1-6: 非法 task_id 在 submit / DB / daemon 解码三处全拒，且不落盘到目录外"`（`p1_fix_regression_test.mbt:209`），覆盖 `../../evil`、`a/b`、`a\b`、空串、`.`、`..`、`a..b`、129 字符超长，并断言工作目录之外（向上两级）无任何落下物。

## 2. P2 已修

### P2-1 零事务（半写状态）

- **修法**：新增私有 `MirrorDB::write_tx(body)`（`rhop/mirror.mbt:873`）：`BEGIN IMMEDIATE` → body → `COMMIT`；body Err 或 COMMIT 失败一律 `ROLLBACK`（尽力）并给可诊断 Err，不假装成功。不可嵌套（文档写明）。
- **接入**：`upsert_task`（`:990`）、`update_status`（`:1215`）、`claim_task`（`:1335`）——主表更新 + 事件流水现在同事务。
- **用例**：由 P1-1/P1-2/P1-3/P1-4 用例间接覆盖（交错失败后库内状态与事件一致）。

### P2-2 无 `busy_timeout` → 多进程同库 `SQLITE_BUSY` 直接失败

- **改动**：`rhop/mirror.mbt:809` 建库时 `PRAGMA busy_timeout = 5000`（对齐 `rhop_task/task_store.mbt` 的 `busy_timeout_sec=5.0`）。短事务在忙时自动串行化，而不是立刻失败。
- **未做**：显式 `journal_mode`（共享盘 DELETE / 本机 WAL）——涉及部署语义，留给 lead 决定（§3）。

### P2-3 + P3-4 临时目录泄漏（实测 1768 个 `rhop-mirror-*`）

- **修法**：
  - `MirrorDB` 增加私有 `mut temp_root : String`（仅 `open_temp()` 设置）；
  - `close()` 在连接关闭后递归删除自己的临时目录（`rhop/mirror.mbt:1520-1532`）；Windows 上句柄未释放会 EPERM，失败时静默保留、由退出钩子兜底（close 语义仍不抛错）；
  - `rhop_ffi_temp_dir` 新增**进程退出钩子**统一清理本进程建过的临时目录（`:1854` 单行 JS：`process.on("exit")` → `fs.rmSync(recursive, maxRetries:3)`）；
  - 新增 `pub fn rhop_temp_workspace(prefix)`（`:1844`）给测试用独立工作目录；`test-suit/rhop_business/biz_helpers_test.mbt:118` 的 `biz_temp_workspace()` 改用它（不再借 `open_temp()` 的父目录）。
- **用例**：`test "临时目录：open_temp 的目录在 close 后递归删除（不再往 %TEMP% 无限堆积）"`（`p1_fix_regression_test.mbt:292`）。

### P2-4 `close` 吞错误 + 无条件摘注册表

- **修法**：JS 体改为「`db.close()` 成功才从 `__rhop_db` 删除 id；失败把原因写 `__rhop_db_err` 并**保留**句柄登记」（`rhop/mirror.mbt:1661`）——不再出现「关闭失败但 id 已被摘掉 → 连接泄漏且无诊断」。
- **未做**：`MirrorDB::close` 仍返回 `Unit`（改成 `Result` 会破坏公开 API，需 lead 拍板，见 §3）。

## 3. 未修 / 延后（含理由）

| ID | 位置 | 决定 | 理由 |
| --- | --- | --- | --- |
| P2-5 | `rhop/daemon.mbt:369` | 延后 | 单个 daemon 内部现在由 DB 层版本守卫兜住重复推进；但**两个 executor 各有独立 mirror 库**、同抢共享介质时仍可能各执行一次。彻底修需要共享介质级 claim 协议或锁目录，属跨模块设计决策（且 vools 同样缺此保证），不适宜在修复轮单方面改协议。 |
| P2-6 | `rhop/daemon.mbt:333-338` | 延后 | 「同版本重复投递」应计 `skipped` 而非 `failed`。当前重复投递会走 `stale_version` → `failed` 计数，指标失真但**不丢消息**。改动需要同时在 `run_once` 返回结构里加 `skipped` 字段并更新既有用例断言，属可观测性改进，本轮时间优先给 P1。 |
| P2-7 | `rhop/sync_folder.mbt:179/188` | 不修 | 文档说「至少跑一轮」、实现是 `while !self.stopped` → 预置 stop 后 0 轮。这是**行为-文档不一致**，改实现会翻转 `sync_glob_test.mbt` 已固化的期望，需要产品口径确认（vools 语义 vs 现有测试）。 |
| P2-8 / P2-9 | `rhop_task/task_queue.mbt` | 不修（跨 lane） | impl-crypto / P2 lane 的文件，且 P2 阶段本就划给 `rhop_task`；另有 lane 正在编辑该目录。 |
| P2-10 | `rhop/requester.mbt:141` | 延后 | `get_result` 把库错误折叠成 `None`，新增 `try_get_result` 是 additive 改动，但需同步 `wait_result` 与用例；收益低于 P1，列为下一轮首选项。 |
| P2-11 | `rhop/actions.mbt` | 不修（跨 lane） | 注册表排序/`reset_actions` 属 actions lane 本轮冻结范围（interact 依赖四个签名）。 |
| P3-1 / P3-5 | `rhop/clipboard.mbt` | 不修（跨 lane） | clipboard 归另一 lane；且属诊断精度问题，非正确性。 |
| P3-2 | `rhop_task/task_queue.mbt:143` | 不修（跨 lane） | 同上。 |
| P3-3 | `rhop/actions.mbt` | 不修（跨 lane） | 文案问题，行为与 vools 一致。 |
| P3-6 | `rhop/mirror.mbt` sync_log | 延后 | `prune_sync_log(before_iso)` 属运维接口，需先定保留期策略；已在本报告登记，避免丢失。 |
| P2-2 补充 | `rhop/mirror.mbt` | 延后 | `journal_mode`（共享盘 DELETE / 本机 WAL）涉及部署口径，留给 lead。 |

## 4. 公开 API（additive，无破坏）

新增（全部是**新增**，未改任何既有签名/语义）：
- `rhop_normalize_path(path : String) -> String`（`rhop/mirror.mbt:580`）
- `validate_task_id(task_id : String) -> Result[Unit, String]`（`:609`）
- `rhop_join_checked(a : String, b : String) -> Result[String, String]`（`:644`）
- `rhop_db_run_changes(...) -> Result[(Int32, Int64), String]`（`:169`）
- `rhop_temp_workspace(prefix : String) -> Result[String, String]`（`:1844`）

`MirrorDB` struct 新增字段均为**非 pub**（blackbox），外部仍只能经 `open`/`open_temp` 构造，不破坏调用方。
`.mbti` 未由我重生成（`rhop/pkg.generated.mbti` 是多 lane 共享生成物，并发 `moon info` 会互相覆盖）——**请 lead 在收口时统一跑 `moon info && moon fmt`**。

## 5. 边界四问对照（本轮新增用例）

| 边界 | 覆盖 |
| --- | --- |
| 空库 / 未知 task | 既有 `mirror_test.mbt` 覆盖；`update_status`/`claim_task` 零行分支新增「任务被删」诊断文案 |
| 坏库 / 已关闭句柄 | 既有用例保留并通过（`mirror_test.mbt:361+`、`executor_test.mbt:205+`） |
| 重复 claim | 新增 P1-2 用例（交错双领） |
| 版本冲突 | 新增 P1-1 用例（A 读 → B 写 → A 再写）与 P1-3 用例（同版本 upsert） |
| 坏 payload / 未知 action | 新增 P1-5 用例（未注册 action → Failed 回传） |
| daemon 重复 run_once | 既有 `daemon_test.mbt` 锁定「第二轮全 0」；P1-5 用例额外断言第二轮 `pushed == 0`（幂等） |
| sync 重复拷贝 | 既有 `sync_folder` 用例覆盖，本轮未改该文件 |
| 路径穿越 | 新增 P1-6 用例（8 种非法 id + 目录外无落下物） |

## 6. 残余风险

1. **P2-5 双执行**：两 executor 独立 mirror + 同一共享介质，仍可能各消费一次同一信封（vools 同病）。需要协议层设计（claim 落共享介质 or 目录锁）。
2. **P2-6 指标失真**：幂等重投仍计入 `failed`，运维看板会把正常重投当异常。
3. **`journal_mode` 未定**：共享盘场景（SMB/NFS）用 WAL 可能坏库，当前沿用 sqlite 默认（DELETE），未显式化。
4. **`close()` 仍无错误通道**：关闭失败只写 `__rhop_db_err` 全局，上层看不到；要根治需改签名（破坏 API）。
5. **Windows 临时目录删除**：句柄未释放时 `close` 内的 `rmSync` 会 EPERM（已静默 + 退出钩子兜底），极端情况下单进程不退出仍会留目录。
6. 本轮改动集中 `mirror.mbt`（+878/-296 行规模），建议 lead 在收口时按 §4 重生成 `.mbti` 并做一次全量 `moon test`（三目标）。
