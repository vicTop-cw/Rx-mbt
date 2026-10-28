# C2 修复报告 · Batch D 业务层（资源与并发）

- 轮次：C2（第 2/3 步：修复 + 回归）
- 执行体：impl-business
- 域：`rhop/{mirror,requester,executor,daemon,sync_folder}.mbt` + `test-suit/rhop_business/` + `test-suit/rhop/actions_test.mbt`
- 寻虫报告：`fist-mbt/reports/2026-10-28-c2-bugfind-business.md`（8 缺陷 P0×1/P1×3/P2×4 + 5 条记录级风险）
- 纪律遵守：**未改任何公开 API 签名、未加功能**（只做资源/幂等/可诊断性硬化；新增的只有测试文件与私有 helper）

---

## 1. 逐条：issue → 修法 → 回归用例 → 证据

### C2-BUG-01 [P0] daemon 消费不幂等 → 已修

| 项 | 内容 |
|---|---|
| issue | `process_inbox` 只看信封自带 status，不看库内当前状态 ⇒ inbox 文件搬运失败/崩溃后重读同一枚 `Pending v1`，会**重复执行动作**（库内 Running）或产生虚假 failed + 重复结果信封（库内 Done） |
| 修法 | 执行分支前增加**幂等守卫**：`local_is_pending = mirror.get_task(id).status == Pending`；非 Pending ⇒ 不执行，信封移入 `processed/` 留档并计入已处理（at-most-once + 版本去重）。跨进程竞争仍由 `Pending→Claimed` 的零行守卫兜底 |
| 回归用例 | `test-suit/rhop_business/c2_regression_test.mbt` · `c2-1`（库内 Running + 残留 Pending 信封 ⇒ 动作执行 0 次、状态保持 running、failed=0）、`c2-2`（库内 Done + 残留信封 ⇒ 执行次数保持 1、无虚假 failed） |
| 证据 | 修前 RED：`Total tests: 53, passed: 51, failed: 2.`，失败点 `c2_regression_test.mbt:107` = `abort("重复执行了动作 N 次（应 0 次）…")` → 修后 `passed: 53, failed: 0` |

### C2-BUG-02 [P1] 递归列举跟随符号链接 → 已修

| 项 | 内容 |
|---|---|
| issue | `rhop_ffi_list_files_recursive` / `rhop_ffi_list_dir` 用 `fs.statSync`（跟随链接）：自指环 ⇒ 路径爆炸；指向源根外 ⇒ 越根枚举 |
| 修法 | 两处都改成 `readdirSync(dir, { withFileTypes: true })` + `ent.isSymbolicLink() → skip`，并加递归深度上限 64（防硬链接环/超深目录） |
| 回归用例 | `c2-3`（自指环 + 指向外部目录的链接：断言不出现 `loop/`、`outside/`，条目数 ≤4；Windows 无建链接权限时退化为基础正确性断言） |
| 证据 | WSL 探针（源目录 1 文件 + 1 自指环 + 1 指向 `/etc` 的链接）：修前 **67,453 条**（其中 `outside/` 1,715 条 = 读到了 `/etc` 下文件）；跳链接后 **1 条**。Windows 因建链接需特权（`EPERM`）不会现形 ⇒ 该缺陷**只在 WSL/Linux 可证**，本机已在 WSL 复现并锁定 |

### C2-BUG-03 [P1] 大文件摘要整读（RSS 与文件 1:1）→ 已修

| 项 | 内容 |
|---|---|
| issue | `rhop_ffi_file_digest` 用 `readFileSync` 全量读入 |
| 修法 | 1MB 分块 `readSync` 喂 `createHash`，`catch`/正常路径都确保 `closeSync(fd)`（无 fd 泄漏） |
| 回归用例 | `c2-4`（2.56MB 文件：分块摘要必须等于 `sha256_hex(bytes_of_utf8(text))`，字节数一致） |
| 证据 | 256MB 文件探针：修前 **rss +256.1MB / 330ms**；分块后 **rss +1.0MB / 278ms**，摘要一致（`== true`，总字节 268,435,456） |

### C2-BUG-04 [P1] 临时目录残留（Windows 句柄泄漏耦合）→ 已修

| 项 | 内容 |
|---|---|
| issue | ① 退出钩子先 `rm` 后（其实没有）关库 ⇒ Windows 上「未关的 sqlite 句柄」让 `rm -rf` 报 EPERM，目录留下；② `daemon_test` 3 处只 close 双端之一，句柄泄漏 |
| 修法 | ① 退出钩子改为**先遍历 `__rhop_db` 逐个 `db.close()`、清空语句缓存，再带重试(3×)删目录**；② 测试全部 close 双端 daemon 并 `rhop_remove_dir_all(workspace)`；③ 新增「句柄泄漏探测器」用例 |
| 回归用例 | `c2-5`（关闭全部句柄后目录**必须**可递归删除——只要哪个类忘了 close，这条在 Windows 上就红） |
| 证据 | 复跑整套 business 测试，**我域前缀（`rhop-biz-*` / `rhop-mirror-*`）净增 = 0**（`comm -13 before after` 空集）。修前同一命令净增 3 个 `rhop-biz-*`（每个 ~23MB，对应 3 处只 close 一端的用例）。注：裸 `%TEMP%/rhop-*` 的 +7 来自其他 lane（`rhop-it-*`/`rhop-c2-race-*`/`rhop-c2-tmp-*`，出自 `test-suit/rhop_interact`），不计入本域 |

### C2-BUG-05 [P2] prepared statement 无界增长 → 已修

| 项 | 内容 |
|---|---|
| issue | 每次 `db_run`/`db_all` 都 `db.prepare(sql)`；node v25 的 `StatementSync` **没有 close/finalize**（探针确认原型方法只有 iterate/all/get/run/columns/…），只能等 GC |
| 修法 | 有界语句缓存：键 = `连接id + "|" + SQL`，容量 64（超出淘汰最旧），`close()` 时按 `id|` 前缀清理；同时把 `__rhop_stmt_prepared` 计数暴露给测试观测 |
| 回归用例 | `c2-6`（300 轮 upsert + count：新增 prepared 条数必须 < 60，即按「不同 SQL 条数」增长而非按调用次数） |
| 证据 | 2,000 次调用探针：prepare-per-call **rss +4.4MB** vs 复用 **+0.2MB**（≈2KB/条未回收）；测试断言在修前后都跑通（修前因计数器不存在为 0，修后计数器真实可用，因此断言开始有约束力） |

### C2-BUG-06 [P2] `SQLITE_BUSY` 文本不可读 → 已修

| 项 | 内容 |
|---|---|
| issue | busy_timeout 已生效（C1 加的 `PRAGMA busy_timeout=5000`），但错误面只有英文 `database is locked`，无法与「SQL 写错」区分 |
| 修法 | `db_run`/`db_all` 的 `catch` 把 `database is locked` / `SQLITE_BUSY` 映射为「数据库忙（SQLITE_BUSY）：…busy_timeout(5000ms)…请重试」并**保留原文**；`Result[T,String]` 签名不变 |
| 回归用例 | 由既有「已关闭句柄/版本冲突/坏库」用例覆盖错误面；并发语义由探针取证（busy 等待 5,543ms 后 ERR_SQLITE_ERROR） |
| 证据 | 探针：`busy_timeout=5000` ⇒ 第二连接写等待 **5,543ms** 后失败；未设 timeout ⇒ **2ms** 立即失败。修复后错误文本带中文前缀，可在日志里直接识别并重试 |

### C2-BUG-07 [P2] 每文件一条 `log_sync` = 每文件一次 fsync → 已修

| 项 | 内容 |
|---|---|
| issue | `push_local` 每个投递成功的文件写一条审计日志（独立隐式事务 ⇒ 一次 fsync） |
| 修法 | 循环内只收集 `(task_id, bytes)`，轮末一次 `write_tx`（`BEGIN IMMEDIATE`）批量落库；文件投递本身仍在事务外（不持写锁做慢 IO）；审计失败不阻断投递（只回执里体现） |
| 回归用例 | 既有 `daemon: 两 daemon 单机中继闭环` / `push_local 无介质` 用例 + 全套 53 例 |
| 证据 | 探针 N=2000：**带事务 16ms vs 不带事务 22,660ms**（≈11ms/条，几乎全是 fsync）⇒ 1,000 个信封从「≈10s 纯等待」降为一次提交 |

### C2-BUG-08 [P2] `write_atomic` 失败残留 `*.tmp` → 已修

| 项 | 内容 |
|---|---|
| issue | 写 tmp 后 rename 失败（Windows 目标被占用 ⇒ EPERM）时未清理 tmp |
| 修法 | `catch` 中 `fs.unlinkSync(tmp)`（吞二次错误）后再返回 false |
| 回归用例 | 既有 envelope/inbox 写入用例（路径覆盖）+ `c2-5`（目录可删，不再有 `.tmp` 残留挡住删除） |
| 证据 | Windows 探针：目标被另一句柄占用时 `renameSync` = **EPERM**、`copyFileSync` 可覆盖；修复后失败路径不再留 `*.tmp` |

---

## 2. 记录级风险（本轮不改 API，仅文档化 — 详见寻虫报告 §2）

| 编号 | 结论 |
|---|---|
| C2-RISK-01 | `daemon.start()` 在 js 主线程阻塞（`Atomics.wait`），`stop()` 同线程不可达；只有 `start(max_rounds>0)` 能退出。要修必须改接口语义（异步循环/回调），本轮只记录；规避：外部进程管理 + `run_once()` 幂等轮询 |
| C2-RISK-02 | `MirrorDB` 是值类型：`Requester::mirror()` 返回副本，对副本 `close()` 会关底层句柄而原件 `closed` 仍 false（后续报「句柄无效」，可诊断）；`open_temp()` 的副本 close 还会删临时目录。已在文档标注「只读、勿 close」 |
| C2-RISK-03 | 共享介质「消费即删除」= 单消费者语义；无 ack。丢包分析：`pull_remote` 是**先写本地 inbox、再删共享**，因此**不会丢包**；删除失败只会重复投递（版本去重 + BUG-01 守卫后无副作用），即 at-least-once + 幂等 |
| C2-RISK-04 | 未启用 WAL（`journal_mode=delete`）：网络盘上 WAL 不安全，保持现状；并发写偶发 BUSY 现在可被中文文本识别（BUG-06） |
| C2-RISK-05 | `sync manifest` 无裁剪，长期轮换文件名场景会线性膨胀（本轮不改） |

---

## 3. 两平台验证（最终态，均为真实汇总行）

判包用**精确路径**（`-p test-suit/rhop` 会前缀误匹配 `test-suit/rhop_task`/`rhop_js`，见寻虫报告）。

### Windows（Git Bash，moon 0.1.20261016，node v25.2.1）

```
[W] moon check (default)        : 0 errors
[W] moon check --target js      : 0 errors
[W] moon check --target native  : 0 errors
[W] test-suit/rhop_business --target js : Total tests: 53, passed: 53, failed: 0.
[W] test-suit/rhop_business (wasm)      : Total tests: 10, passed: 10, failed: 0.
[W] test-suit/rhop_business --target native : Total tests: 10, passed: 10, failed: 0.
[W] test-suit/rhop --target js          : Total tests: 160, passed: 160, failed: 0.
[W] full moon test (wasm)               : Total tests: 612, passed: 612, failed: 0.
[W] full moon test --target js          : Total tests: 819, passed: 819, failed: 0.
```

### WSL Ubuntu-22.04（moon 0.1.20261021，node v25.2.1，`bash scripts/with_moon_lock.sh`）

```
[L] moon check (default)        : 0 errors
[L] test-suit/rhop_business --target js : Total tests: 53, passed: 53, failed: 0.
[L] test-suit/rhop --target js          : Total tests: 160, passed: 160, failed: 0.
[L] full moon test (wasm)               : Total tests: 612, passed: 612, failed: 0.
[L] full moon test --target js          : Total tests: 819, passed: 819, failed: 0.
```

### 卫生 / 资源归零

```
$ ls -d "@TMP@" "rhop-data"        # 仓库根
none (clean)

# 我域临时目录净增（same-run before/after set diff on rhop-biz-* / rhop-mirror-*）
净增 = 0
```

> 附：本机 `%TEMP%` 历史上累积了 4,889+ 个 `rhop-*` 目录（≈151MB，跨 lane/跨轮次）。本轮修复保证**新跑不再新增我域残留**，历史残留建议仓主一次性清扫：`rm -rf "$TEMP"/rhop-*`（无 daemon 在跑时）。

---

## 4. 改动文件清单

| 文件 | 改动 |
|---|---|
| `rhop/mirror.mbt` | ① 递归/非递归列举跳过符号链接 + 深度上限；② 文件摘要改 1MB 分块读取；③ 有界语句缓存（≤64，按 `连接id|SQL`）+ `__rhop_stmt_prepared` 计数 + close 清理；④ `SQLITE_BUSY` 中文可诊断映射；⑤ 退出钩子先关库再重试删临时目录；⑥ `write_atomic` 失败清理 `*.tmp` |
| `rhop/daemon.mbt` | ① `process_inbox` 增加「库内必须仍为 Pending」幂等守卫（P0）；② `push_local` 审计日志轮末一事务批量写（`flush_push_logs` 私有 helper） |
| `test-suit/rhop_business/c2_regression_test.mbt` | **新增**：c2-1/c2-2/c2-3/c2-4/c2-5/c2-6（对应 6 条关键发现，含句柄泄漏探测器与语句缓存有界断言） |
| `test-suit/rhop_business/daemon_test.mbt` | 7 处 hygiene：全部 close 双端 daemon + 轮末 `rhop_remove_dir_all(workspace)` |
| `test-suit/rhop_business/moon.pkg` | 注册 `c2_regression_test.mbt`（js 目标） |

- 公开 API：**零变更**（`moon info` 复跑；本域未新增任何 `pub fn`，`pkg.generated.mbti` 公开面不变）。
- `moon fmt` 已对本域文件执行（无 diff 残留）。

---

## 5. 回归防护要点（给后续轮次）

1. `c2-1`/`c2-2` 锁死「daemon 不重放动作副作用」：任何对 `process_inbox` 执行分支的改动都必须先过这两条。
2. `c2-3` 锁死「递归列举跳过符号链接」：新增文件遍历（sync/jump/daemon）必须复用 `rhop_fs_list_files_recursive`，不要另写 `statSync` 版本。
3. `c2-5` 是**句柄泄漏探测器**：新增任何持有 MirrorDB 的类型，都必须在其 `close()` 里释放，否则 Windows 上这条会红。
4. `c2-4` 锁死分块摘要与整体 sha256 等价（改摘要实现必须过）。
5. `c2-6` 锁死语句缓存有界（改 FFI 时必须保留缓存键设计，否则长驻 daemon RSS 会回升）。
