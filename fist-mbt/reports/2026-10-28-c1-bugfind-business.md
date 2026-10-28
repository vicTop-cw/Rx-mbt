# C1 寻虫报告 · 业务层 / 持久化域

- 审计人：impl-business（业务层 owner）
- 时间：2026-10-28 12:08–12:30（Asia/Shanghai）
- 模式：**只读审计**。本轮无 `mcp__fist-mbt__*` 工具，用「代码定位 + node 实测复现 + 参考实现对照」替代；未改动任何 `.mbt` 源码，未提交 git。
- 只读范围：`rhop/{mirror,requester,executor,daemon,sync_folder,actions,clipboard}.mbt`、`rhop_task/{task_store,task_queue,task_exec,task_sync}.mbt`、`test-suit/rhop_business/`、`test-suit/rhop/actions_test.mbt`、`test-suit/rhop_task/`、`test-suit/rhop_clipboard/`。
- 参考实现对照：`E:/IDEProjects/AI/vools/rhop/vools/rhop/{daemon,actions,clipboard}.py`。
- 工作区状态：`git status --porcelain` 只有他人 lane 的 `M test-suit/rhop_js/fixtures/moonbit_vectors.json` 与本轮报告/复现脚本，**无本域代码改动**。

## 0. 结论摘要

| 级别 | 数量 | 一句话 |
| --- | --- | --- |
| P0 | 0 | 未发现无需并发前置条件即可触发的数据损坏/凭证泄露 |
| P1 | 6 | mirror 的「乐观锁 / 领取 / 写结果」三者全链路非原子且**静默成功**；daemon 执行失败不回传（parity 偏离）；`task_id` 路径穿越 |
| P2 | 11 | 事务缺失、连接/临时目录泄漏、busy 无退避、状态机弱约束、截断口径错误等 |
| P3 | 6 | 诊断文案、幂等噪音、测试缺口 |

最关键的一条：`rhop/mirror.mbt` 的乐观锁**只在 SQL 之外比较**——SQL 本身没有版本谓词，且 `rhop_ffi_db_run` 把 SQLite 的 `changes` 丢弃后返回 `true`。结果是「丢失更新」「双领」「零行更新」三种错误一律静默成功，调用方无法察觉。仓库内已有正确范式（`rhop_task/task_store.mbt:544` 的 `BEGIN IMMEDIATE` + 状态守卫 + changes 校验），修复路径明确。

## 1. P1（正确性 / 安全）

### P1-1 乐观锁非原子 → 丢失更新（silent lost update）

| 项 | 内容 |
| --- | --- |
| 位置 | `rhop/mirror.mbt:868`（`SELECT * FROM tasks WHERE task_id = ?`）→ `rhop/mirror.mbt:923`（`UPDATE tasks SET status=?, version=?, updated_at=?, result=?, error=?, signature=?, checksum=?, envelope=? WHERE task_id=?`） |
| 现象 | 版本比较（`:875` 一带）发生在 SQL **之外**；`:923` 的 UPDATE 只按 `task_id` 定位，没有 `AND version = ?`。A 读到 version=1 后，B 在同一连接窗口把行推进到 version=2（如被 claim），A 随后仍能写成功并把自己的状态覆盖回去。 |
| 证据（node 实测两连接同库） | `[A] SELECT 得到 version = 1 status = pending` / `[B] 已 claim，version=2 claimed_by=B` / `[A] UPDATE changes = 1（A 认为自己写入成功）` / `[final] = {"status":"running","version":2,"claimed_by":"B"}` / `结论：B 的 claim 被 A 覆盖，且全程无任何 Err` |
| 复现 | 见附录 A 脚本第 1 段（`node <脚本>`，node 25.2.1 + `node:sqlite`）。生产可达路径：CLI（submit/cancel 进程）+ daemon 常驻进程共用同一 `data_dir` 的 mirror 库；或 `rhop_task` 宣称的跨机/多 worker 场景。**注**：单个 JS 进程内 MoonBit 同步语句块不会交错，因此该缺陷需要 ≥2 个进程（或 worker_threads）。 |
| 影响 | 状态机被回退（claim/running 结果被旧状态覆盖），且版本号停在同一值，连「版本回退检测」都发现不了；上层拿到 `Ok`。 |
| 建议修法 | ① `UPDATE ... WHERE task_id = ? AND version = ?`（期望版本），检查 `changes == 1`，否则返回 `StaleVersionError`；② 整段包 `BEGIN IMMEDIATE ... COMMIT`，失败 `ROLLBACK`；③ 直接对齐 `rhop_task/task_store.mbt:544-583` 的写法（同一仓库、同一 SQLite，已被 P2 lane 验证）。 |

### P1-2 `claim_task` 无状态守卫 → 双领（double claim）

| 项 | 内容 |
| --- | --- |
| 位置 | `rhop/mirror.mbt:1032`（`UPDATE tasks SET status=?, version=?, updated_at=?, claimed_by=?, checksum=?, envelope=? WHERE task_id=?`） |
| 现象 | UPDATE 既无 `AND status='pending'`，也无版本谓词；`claim_task` 先 SELECT（`:994`）判断，再无条件 UPDATE。两个 executor 进程对同一 pending 任务都「领取成功」。 |
| 证据 | `[双领] A.changes = 1  B.changes = 1  最终 claimed_by = worker-B` |
| 影响 | 动作重复执行（side-effect ×2：`rhop.echo` 无害，`jump.push` 之类会重复推送）。**这是继承自 vools 的共同缺陷**，不是本次复刻引入：vools `rhop/vools/rhop/daemon.py:200` 的 `update_status(task_id, TaskStatus.CLAIMED)` 同样无版本守卫。但既然 rhop_task 已实现正确范式，建议本域一并修正而非保持 parity。 |
| 建议修法 | `... SET ... WHERE task_id = ? AND status = 'pending'`（可再加 `AND version = ?`），`changes != 1` → `Err(\"claim 冲突: ...\")`；`Executor::claim` 已经有 `Result[Envelope?, String]` 通道，不需要改签名。 |

### P1-3 `rhop_ffi_db_run` 丢弃 `changes` → 零行更新报成功（P1-1/P1-2 的「静默」根因）

| 项 | 内容 |
| --- | --- |
| 位置 | `rhop/mirror.mbt:1369`（`extern \"js\" fn rhop_ffi_db_run(...)`；JS 侧 `db.prepare(sql).run(...)` 的返回值被丢弃，只 `return true`）；上层 `MirrorDB::run` 把 `true` 当 `Ok(())` |
| 现象 | 任何 0 行命中的写语句都与命中完全相同地返回成功。 |
| 证据 | `[零行更新] changes = 0 → rhop_ffi_db_run 仍返回 true，上层拿到 Ok(())` |
| 影响 | 使 P1-1/P1-2 从「报错可发现」退化为「静默错误」；也让「任务不存在」这类语义只能靠前一条 SELECT 兜（那又引入 TOCTOU）。 |
| 建议修法 | FFI 返回 JSON `{ok, changes, lastInsertRowid}`（与 `rhop_task/task_store.mbt:332` 的 `{changes,lastInsertRowid}` 形状一致），`MirrorDB::run` 返回 `Result[(Int32, Int64), String]`，claim/update 校验 `changes == 1`。这是**最小改动、收益最大**的一条，建议先修。 |

### P1-4 `upsert_task` 读-改-写非原子 + `INSERT OR REPLACE` 清空 `claimed_by`

| 项 | 内容 |
| --- | --- |
| 位置 | `rhop/mirror.mbt:708`（`SELECT version FROM tasks WHERE task_id = ?`）/ `:727`（`INSERT OR REPLACE INTO tasks (...) VALUES (...)`，第 13 列 `claimed_by` 固定传 `Json::null()`，见 `:741`）/ `:748`（`append_event`） |
| 现象 | (a) `env.version > local_v` 的判断在 SELECT 与 INSERT 之间，两个并发 upsert 可同时通过 → 后者覆盖前者（与 P1-1 同族）；(b) `REPLACE` 语义是删行重插，**每次 upsert 都把本端 `claimed_by` 抹成 NULL**，也把 `result/error` 整体替换为信封值；(c) 主表写成功、`append_event` 失败时返回 `Err`，但行已落库——无回滚，调用方看到失败而库里是半写状态。 |
| 建议修法 | ① 用单条 `INSERT INTO tasks (...) VALUES (...) ON CONFLICT(task_id) DO UPDATE SET ... WHERE excluded.version > tasks.version`，`changes == 0` 即 stale；② 保留 `claimed_by`（DO UPDATE 里不清空该列）；③ 主表 + 事件流水放同一事务。 |

### P1-5 daemon 执行失败**不回传**结果信封（与 vools 偏离）

| 项 | 内容 |
| --- | --- |
| 位置 | `rhop/daemon.mbt:342-369`。成功分支在 `:349-355` 写 `outbox/<task_id>.rhop`；**失败分支 `:363-366` 只 `errors.push` + `failed++`**，随后 `:369` 的 `move_to(..., \"processed\")` 把信封消费掉。 |
| 参考实现 | `E:/IDEProjects/AI/vools/rhop/vools/rhop/daemon.py:218-222`：except 里 `update_status(task_id, FAILED, error=str(e))`，然后**无条件**（注释「5. 移动信封到 outbox/」）`self._move_envelope(fname, \"outbox\")`。 |
| 现象 | executor 侧执行失败时：mirror 里状态已置 Failed（`rhop/executor.mbt:157` `fail_and_report`），但 outbox 里没有结果信封 → 需求端 `Requester::wait_result`（`rhop/requester.mbt:171`）永远看不到终态，只能超时。 |
| 影响 | 「失败可观测」变成「失败=挂起」；对端无法区分「还在跑」与「已经失败」。属于 parity 偏离（矩阵 §5.9 未列此项）。 |
| 建议修法 | 失败分支同样按 mirror 当前（Failed）状态序列化信封写入 `outbox/`，与成功分支共用一段「写结果信封」逻辑；`failed` 计数保留，但不再吞掉回传。 |
| 测试缺口 | `test-suit/rhop_business/daemon_test.mbt` 只有成功闭环（:71）、坏信封（:153）、加密降级（:207）等，无「执行失败」用例。 |

### P1-6 `task_id` 路径穿越 → 越界写文件

| 项 | 内容 |
| --- | --- |
| 位置 | 拼接点 `rhop/daemon.mbt:349-353`（`rhop_join(rhop_join(self.data_dir, \"outbox\"), env.task_id + \".rhop\")`）；来源 `rhop/envelope.mbt:270-280`（`require_string` 只校验「是字符串」，不校验内容）；同类 `rhop/requester.mbt:114-117`（调用方传入的 `task_id` 拼 inbox 路径）。 |
| 证据（node 实测 `path.join` 语义） | `task_id = \"../../evil\"` → `E:\\work\\evil.rhop` *** 逃出 data_dir ***；`task_id = \"a/b\"` → 自动创建子目录后写入成功。 |
| 影响 | 持有共享密钥的对端（或对端的一个 bug）可以让本端把 `.rhop` 文件写到 `data_dir` 之外任意可写位置；Windows 上 `...\\Start Menu\\Programs\\Startup\\x.rhop` 属于「落地即可执行」面。当前任务内容本身受 action 白名单约束，但**文件系统副作用不受约束**。 |
| 建议修法 | 在信封解码处（`from_rhop_bytes` / `require_string` 之后）统一做 `task_id` 白名单：`^[A-Za-z0-9._-]{1,128}$` 且不含 `..`、分隔符、控制字符；`rhop_join` 侧再做一道「规范化后必须落在 base 前缀内」的断言（防御纵深）。一旦拒绝，走「坏信封 → failed/」既有通道并计数。 |

## 2. P2（健壮性 / 可维护性）

| ID | 位置 | 问题 | 证据 / 影响 | 建议修法 |
| --- | --- | --- | --- | --- |
| P2-1 | `rhop/mirror.mbt` 全文 | **零事务**：`grep -c \"BEGIN\\|COMMIT\\|ROLLBACK\\|busy_timeout\\|journal_mode\"` = **0**。upsert（主表+事件）、update_status（更新+事件）、`log_sync`/`pending_sync` 都是多条独立语句 | 进程崩溃或第二条语句失败 → 表与事件流水不一致，且无回滚（见 P1-4c） | 写操作统一 `BEGIN IMMEDIATE … COMMIT / ROLLBACK`，封装 `MirrorDB::with_tx(fn)` |
| P2-2 | `rhop/mirror.mbt` 全文（对照 `rhop_task/task_store.mbt:35-40`） | 无 `busy_timeout`、无 `journal_mode` 设置 | 多进程（CLI+daemon）同库时一旦重叠写就 `SQLITE_BUSY` 直接失败，无重试、无退避；`task_store` 有 `journal_mode` + `busy_timeout_sec=5.0` 的良好范式 | 建库时 `PRAGMA busy_timeout=5000`，共享盘场景显式 `journal_mode=DELETE`、本机 `WAL` |
| P2-3 | `rhop/mirror.mbt:1536`（`rhop_ffi_temp_db_path`） | 每次 `open_temp()` 都 `mkdtempSync` 一个新目录，**从不删除** | 实测本机 `C:/Users/victo/AppData/Local/Temp/rhop-mirror-*` 已累积 **1768 个**目录；测试助手 `test-suit/rhop_business/biz_helpers_test.mbt:118-126` 每个用例再借一次 `open_temp()` 的父目录 → 泄漏随用例数线性增长 | `MirrorDB` 增加 `temp: Bool` 标记，`close()` 时删目录；Windows 上先 `close` 连接再 `rmSync`（recursive + retries），失败只告警不抛 |
| P2-4 | `rhop/mirror.mbt:1363`（`rhop_ffi_db_close`） | JS 侧 `try { db.close() } catch (e) {}` 吞掉关闭错误，且**无条件**从注册表删除 id；`MirrorDB::close`（`:1241`）返回 `Unit`，没有失败通道 | 关闭失败（例如仍有未 finalize 的 statement）时连接泄漏且无任何诊断；后续同路径 `open` 可能遇到锁 | close 返回 `Result[Unit, String]`；注册表只在成功后删除；失败时保留句柄并给出 `last_error` |
| P2-5 | `rhop/daemon.mbt:342-378` | 接力执行前**不 claim**（直接 `advance_to(Running)`），而同仓库 `rhop/executor.mbt:90` 有 `claim()`；两个 executor 进程消费同一份投递时会重复执行 | vools 至少在 `daemon.py:200` 做了 CLAIMED 标记（虽然同样无版本守卫），本实现连这一步都跳过 | 执行前先 `claim_task`，claim 失败（`changes != 1`）就跳过并记一条 `skipped` 计数 |
| P2-6 | `rhop/daemon.mbt:264-280` | 「读共享介质 → 写本地 inbox → 删共享文件」顺序正确（**不会丢消息**），但删除失败时下一轮会重复投递同一个信封 → `upsert_task` 返回 `stale_version` → 走 `:333-338` 计入 `failed` | 重复投递被计为「失败」，`failed` 指标失真；对端/运维会把幂等重投误判为异常 | 区分「同版本重复」与真失败：`env.version <= local_version` 时计 `skipped`（不 push errors） |
| P2-7 | `rhop/sync_folder.mbt:179` vs `:188` | 文档写「**至少跑一轮**」，实现是 `while !self.stopped` | 预先 `stop()` 后 `run_forever` 跑 **0 轮**，与 vools「先跑一轮再判停止」不同；`test-suit/rhop_business/sync_glob_test.mbt` 的「置位后 0 轮」用例把这个行为固化成了期望 | 改成 `while true { 跑一轮; if self.stopped || (max_rounds>0 && rounds>=max_rounds) { break } }`，并同步改文档与用例（属于已知的行为-文档不一致，需产品口径确认） |
| P2-8 | `rhop_task/task_queue.mbt:211-233`（`encode_result`） | 注释称「按 UTF-8 字节数」，实际 `payload.length()` 是 **UTF-16 code unit** 数（MoonBit `String::length` 文档：`\"🤣\".length() == 2`），`get_view(start,end)` 也按 code unit 切 | `result_max_bytes` 名为字节实为 code unit → 中文结果实际允许约 **3 倍** UTF-8 字节；且当切点落在代理对中间时 `get_view` 返回 `None`（`builtin/stringview.mbt:637` 的文档用例「Splitting a surrogate pair is rejected」即此行为），`:221-224` 回退为**整段不截断**，静默越过上限 | 用 `@utf8`/`String::to_bytes().length()` 求真实字节数，或改名 `result_max_chars` 并改文档；切点回退策略改为「向前收缩到合法边界」而不是放弃截断 |
| P2-9 | `rhop_task/task_queue.mbt:199-207 / 245-256 / 267-277` | `mark_running/mark_done/mark_failed` 全部传 `expect_version = None`，且 `set_state` 不校验 `worker_id` 归属 | 租约过期、任务被另一 worker 重新领取后，**过期 worker 仍能把自己的结果写成终态**（状态流转 RUNNING→COMPLETED 合法，通过） | `set_state` 增加可选 `expect_worker` 参数；或 `mark_*` 传 claim 时拿到的 version 作为 `expect_version` |
| P2-10 | `rhop/requester.mbt:141` | `get_result` 把 DB 错误折叠成 `None`（`Err(_) => return None`），与「仍在跑」不可区分 | `wait_result` 在库损坏/已关闭时一路 poll 到超时，报「超时」而不是「库错误」；`get_task` 的文档（`:762`）已声明此取舍，但 `wait_result` 没给区分通道 | `get_result` 保持兼容，新增 `try_get_result(...) -> Result[Json?, String]`，`wait_result` 内部用它并在库错误时立刻返回 `Err` |
| P2-11 | `rhop/actions.mbt`（`list_actions` / 全局 `Map`） | 注册表是包级可变全局；`list_actions` 顺序取决于 Map 迭代序 | 未知动作错误里的「可用: a, b, c」文案不稳定（测试若断言整句会 flaky）；同一测试进程内 register/unregister 残留会污染其它用例 | `list_actions` 返回前排序（确定性）；注册表提供 `reset_actions()` 供测试 teardown |

## 3. P3（诊断 / 幂等噪音 / 测试）

| ID | 位置 | 问题 | 建议 |
| --- | --- | --- | --- |
| P3-1 | `rhop/clipboard.mbt:258-266` + `:433` | `CommandClipboardBackend::read` 失败时 `ignore(err)` 返回空串；`read_clipboard` 随后**无条件** `set_last_read_reason(\"\")` → 「读失败」与「剪贴板为空」完全等价。触发面真实存在：`ffi_exec`（`:81-85`）没设 `maxBuffer`，node 默认 1MB，超过即 ENOBUFS；另有 15s 超时、powershell 运行期缺失两条路径 | 后端 `read` 改为 `Result[String, String]`（或返回 reason），`read_clipboard` 只在成功时清空 reason |
| P3-2 | `rhop_task/task_queue.mbt:143-180` + `task_store.mbt:432-448` | `submit` 走 `INSERT OR IGNORE`（按 `task_name` 去重）→ 重复提交（即使 payload 不同）**静默忽略**，返回插入数 0，不报冲突 | 返回 `{inserted, ignored:[names]}` 或在 payload 不同时给出 `duplicate_task` 诊断 |
| P3-3 | `rhop/actions.mbt`（`omega_unwrap`，`:140-186`） | 内层 `data` 是 dict 但缺 `status` 时，复用「内层 data 缺失或非 dict」文案（`:158`），与事实不符 | 文案改为「内层 data 缺 status 字段」；行为本身与 vools `actions/__init__.py:63-89` 一致，不需动语义 |
| P3-4 | `test-suit/rhop_business/biz_helpers_test.mbt:118-126` | 每个用例借 `open_temp()` 的父目录当工作区，mkdtemp 目录从不删除（与 P2-3 同一根因） | teardown 删目录；或在 helpers 里提供 `with_workspace(fn)` 保证清理 |
| P3-5 | `test-suit/rhop_clipboard/clipboard_test.mbt` | 未覆盖「后端读失败」路径（只测成功/无后端），P3-1 因此无测试拦截 | 用注入的 fake backend 返回失败，断言 reason 非空 |
| P3-6 | `rhop/mirror.mbt` 事件/同步日志表 | `log_sync` / `pending_sync` 无保留期与清理入口，长期运行单调增长 | 提供 `prune_sync_log(before_iso)` / 按条数上限截断 |

## 4. 已核实「非缺陷」（避免下一轮重复投入）

| 检查点 | 结论与证据 |
| --- | --- |
| clipboard 命令注入 | **无**。写入走 stdin，不拼 shell：`rhop/clipboard.mbt:321` 一带 `$t=[Console]::In.ReadToEnd(); Set-Clipboard -Value $t`；执行器 `:76-92` 用 `spawnSync(argv[0], argv.slice(1))`（`shell` 未开启），`encoding:\"utf8\"`；Windows 命令行首尾显式 `InputEncoding/OutputEncoding = UTF8`。 |
| clipboard 编码 | UTF-8 双端一致（写 `InputEncoding`、读 `OutputEncoding` + `encoding:\"utf8\"`），未见 GBK 混用。 |
| clipboard 定时器 / 订阅泄漏 | `run_forever` 的 `Subscription::dispose()` 会 `clearInterval`（`:879-882`）；`ffi_set_interval` 的 `Number(id)` 在 node 实测得 `3`（Timeout 有 `Symbol.toPrimitive`），清定时器有效。 |
| clipboard `text_len` 口径 | 用 `char_length()`（code point），与 vools `len(text)` 对齐（`:715 / :763 / :782`）。 |
| MoonBit 可变字段的值语义 | 已验证「带 `mut` 字段的 struct 跨方法调用共享状态」（`SyncFolder::stop()` 后 `run_forever` 0 轮、`rounds()` 累加，`test-suit/rhop_business/sync_glob_test.mbt` 通过），因此 `let me = self` 一类写法不会造成状态分裂。 |
| omega_unwrap 外层 `partial` | 不被当成功（`:141-149`），与 vools `_OK_STATUSES` 仅用于内层的语义一致 → 不是缺陷。 |
| `jump.*` 未知动作错误形状 | 外层 `{status:\"error\", omega_gate:{error:\"未知动作: X（可用: …）\"}}`，与 `vools/actions/__init__.py:40-49` 同形（`test-suit/rhop/actions_test.mbt:122-143` 已断言）。 |
| daemon 共享介质消费顺序 | 「读 → 写本地 inbox → 删共享」顺序正确，崩溃只会导致重复投递（见 P2-6），**不丢消息**。 |
| daemon 坏信封 / 加密降级 | 有处理且被用例覆盖（`daemon_test.mbt:153 / :207`），坏信封进 `failed/` 不阻塞同轮其它信封。 |
| 已关闭句柄 / 坏库 | 有诊断且被覆盖（`mirror_test.mbt:361-366`、`executor_test.mbt:205-211` 断言 `e.contains(\"已关闭\")`）。 |
| `task_exec` CLI 通道 | `shell:false` + argv 数组 + `maxBuffer: 8MB` + `windowsHide` + 超时（`task_exec.mbt:352` 单行 JS），并有 `allow` 白名单校验 `cli:<prog>`（`:288-305`）→ 无注入面。workdir/env 不可配置属矩阵 §5.9 已列缺口，不重复报告。 |

## 5. 测试强度评估

| 维度 | 结论 |
| --- | --- |
| 断言强度 | **合格**：全仓 `test-suit/` 无 `assert_true(true)`、无裸 `is Err`（grep 均 0 命中）；错误分支普遍断言 reason 子串。 |
| 乐观锁用例性质 | `mirror_test.mbt:118-179` 的版本冲突用的是「已知旧 version」（99 / 已递增后的 1），命中的是 pre-SELECT 分支；**不覆盖** A 读完、B 写入、A 再写 的窗口（P1-1）。 |
| 领取用例性质 | `mirror_test.mbt:182-210` 是顺序重复领取（第二次因状态已 claimed 被拒），**不覆盖**并发双领（P1-2）。 |
| 零行更新语义 | 无任何用例断言「0 行命中必须报错」（P1-3 因此无拦截）。 |
| 执行失败回传 | `daemon_test.mbt` 无「executor 执行失败」用例（P1-5 因此无拦截）。 |
| 库生命周期 | 已关闭句柄、坏库有覆盖（见 §4）；`close` 失败路径无覆盖（P2-4）。 |
| 临时目录 | 不清理（P2-3 / P3-4），实测 1768 个残留目录，`git status` 不受影响但污染开发机 Temp。 |
| js-only 覆盖 | 业务包绝大多数用例在 js 目标；`nonjs_test.mbt` 5 例覆盖「非 js 返回可诊断 Err」，方向正确。 |
| 全局状态/顺序依赖 | actions 注册表为包级全局（P2-11）；clipboard 的 `detect_cache`/`detect_probe`（`clipboard.mbt:281/287`）同为全局 `Ref`，测试若不 reset 会跨用例串味。 |

## 6. 建议修复顺序（供 C1-修复轮使用）

1. **P1-3**（`rhop_ffi_db_run` 回传 changes + `MirrorDB::run` 返回 changes）——最小改动，是其余几条能被「测出来」的前提。
2. **P1-1 / P1-2 / P1-4**（SQL 加版本/状态谓词 + `changes == 1` 校验 + 单条 UPSERT + 事务）。同批给 `rhop_business` 补：两个 `MirrorDB` 实例在同一库上构造「读→另一实例写→写」交错，断言 `StaleVersionError` 而不是静默成功。
3. **P1-5**（daemon 失败回传）+ 补 `daemon_test` 用例。
4. **P1-6**（`task_id` 白名单 + join 前缀断言）+ 补 traversal 用例（`../../evil`、`a/b`、`..`、空串）。
5. **P2-1/2/3/4**（事务、busy_timeout、temp 清理、close 结果化）——一起改，避免二次改同一段。
6. P2/P3 其余按成本排序。

## 7. 局限

- P1-1/P1-2 的证据来自 **SQL 层两连接实测** + 代码路径定位；未在 MoonBit 层构造真实并发（本轮只读，不能加测试/改代码）。修复轮建议按 §6 的顺序补并发用例再复验。
- 未在 WSL/CI 复核 node 版本差异（本机 node 25.2.1）；`node:sqlite` 在 node ≥22 才稳定，属既有环境前提。
- 未审计 `monitor/` 与 `rhop_task` 之外的 P2 lane 新文件（不在本域范围）。
- `clipboard` 的「>1MB 读失败」是基于 node `spawnSync` 默认 `maxBuffer` 的推理 + `ignore(err)` 的代码路径，未实机造 2MB 剪贴板验证（会动真实剪贴板，只读轮次未做）。

## 附录 A：P1-1/P1-2/P1-3 最小复现（node:sqlite，两连接）

```js
// node repro: 与 rhop/mirror.mbt:868/923/1032/1369 完全同形的 SQL
const { DatabaseSync } = require("node:sqlite");
const A = new DatabaseSync("t.db"); const B = new DatabaseSync("t.db");
A.exec("CREATE TABLE tasks(task_id TEXT PRIMARY KEY, status TEXT, version INT, claimed_by TEXT)");
A.exec("INSERT INTO tasks VALUES('job-1','pending',1,NULL)");

// P1-1 丢失更新：A 先读 version
const v = A.prepare("SELECT version,status FROM tasks WHERE task_id=?").get("job-1");
// B claim（模拟另一进程）
B.prepare("UPDATE tasks SET status=?,version=?,claimed_by=? WHERE task_id=?").run("claimed",2,"B","job-1");
// A 仍按旧 version 写（mirror.mbt:923 无 version 谓词）
const r = A.prepare("UPDATE tasks SET status=?,version=?,claimed_by=? WHERE task_id=?").run("running",2,v.claimed_by,"job-1");
console.log("[A] changes =", r.changes);                       // 1 —— A 认为成功
console.log("[final]", A.prepare("SELECT * FROM tasks").get()); // B 的 claim 被覆盖

// P1-3 零行更新：changes=0 但 rhop_ffi_db_run 仍返回 true
console.log("[零行更新] changes =", A.prepare("UPDATE tasks SET status=? WHERE task_id=?").run("x","nope").changes);

// P1-2 双领：mirror.mbt:1032 无 status 守卫
A.prepare("UPDATE tasks SET status=?,version=?,claimed_by=? WHERE task_id=?").run("pending",3,null,"job-1");
console.log("A.changes =", A.prepare("UPDATE tasks SET status=?,version=?,claimed_by=? WHERE task_id=?").run("claimed",4,"worker-A","job-1").changes);
console.log("B.changes =", B.prepare("UPDATE tasks SET status=?,version=?,claimed_by=? WHERE task_id=?").run("claimed",4,"worker-B","job-1").changes);
```

（本轮实测输出见 §1 各条「证据」行；脚本随报告内联，已删除临时 `.js` 以免污染仓库。）
