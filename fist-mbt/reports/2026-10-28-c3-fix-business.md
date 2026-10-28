# C3 修复报告 · Batch D 业务层（契约与文档一致性 / 清整收尾）

- 轮次：C3（第 2–3 步：修复 + 双平台验证）
- 执行体：impl-business
- 寻虫报告：`fist-mbt/reports/2026-10-28-c3-bugfind-business.md`
- 纪律遵守：**本轮零源码语义改动** —— `rhop/*.mbt` 全部未动（mtime 仍为 C2 轮的 14:0x–14:26），
  只改「测试卫生 + 文档」；**不改 API 签名、不加功能**

| 改动文件 | 类型 | mtime |
|---|---|---|
| `test-suit/rhop_business/biz_helpers_test.mbt` | 测试 helper 硬化 | 15:08 |
| `test-suit/rhop_business/c3_regression_test.mbt` | **新增** 4 例回归 | 15:08 |
| `test-suit/rhop_business/moon.pkg` | 登记新测试文件（js 目标） | 15:08 |
| `fist-mbt/docs/2026-10-27-rhop-vools-parity-matrix.md` | 14 处一致性刷新 | 15:12 |
| `DOC.md` | 4 处业务段补齐 | 15:14 |
| `rhop/{mirror,requester,executor,daemon,sync_folder,actions}.mbt` | **未改** | 14:0x–14:26（C2） |

---

## 1. C3-01 [P1] workspace 卫生：结构性残留 → 已修

### issue
`biz_temp_workspace()` 每用例建 1 个 `%TEMP%/rhop-biz-*`，**清理完全依赖进程退出钩子**
（36 处创建仅 11 处显式收尾）。进程被 kill/超时（钩子不执行）⇒ 残留；且**历史残留不会被下次运行回收**
（复现：手造 2 个 `rhop-biz-*` → 跑整套 → 仍在）。这正是 QA C2-V1 观察到的「每轮约 9 个」的根因类别
（C2 修复已把「正常退出」路径清零，但 kill 路径仍会积）。

### 修法（三件套，全部在测试 helper 内，不动库代码）
1. **首次调用清扫历史残留**：进程内第一次 `biz_temp_workspace()` 先 `biz_sweep_stale()` 删除
   `%TEMP%/rhop-biz-*`（前缀为本包专属，不误伤其它 lane）。
2. **任意时刻 ≤1 个 workspace**：新建前先删掉「上一个」，即使被强杀也最多残留 1 个目录。
3. **显式收尾入口**：`biz_cleanup(dir)`（幂等，清空「上一个」指针），供用例末尾调用。

### 回归用例（`c3_regression_test.mbt`）
- `c3-1a`：连续建两个 workspace ⇒ 第一个必须已被回收、存活数 ≤1、`biz_cleanup` 后消失。
- `c3-1b`：手造 2 个假历史残留（模拟被 kill 的上一轮）⇒ `biz_sweep_stale()` 返回 ≥2、目录数下降、
  两个假残留具体消失。

### 证据

```
# 连跑 3 次（Windows，%TEMP%/rhop-biz-* set-diff）
Total tests: 57, passed: 57, failed: 0.   run#1: before=0 after=0 delta=0
Total tests: 57, passed: 57, failed: 0.   run#2: before=0 after=0 delta=0
Total tests: 57, passed: 57, failed: 0.   run#3: before=0 after=0 delta=0

# WSL（/tmp/rhop-biz-*）
[L] business js: 57/57  →  temp residue: 0

# 仓库根
$ ls -d "@TMP@" "rhop-data"   →  none (clean)
```

> 与 C2 的区别：C2 解决「正常退出时的句柄泄漏残骸」，C3 解决「异常终止 + 历史残骸」，
> 两者叠加后本域临时目录在**正常与异常**两种退出方式下都不再有累积。

---

## 2. C3-02 [P1] 矩阵 14 处不一致 → 已修

`fist-mbt/docs/2026-10-27-rhop-vools-parity-matrix.md`（只改业务层 §5/§7/§11，不动其它 lane 内容）：

| tag | 改动 | 关键点 |
|---|---|---|
| M1-intro | §5 引言重写 | 删掉**假风险**「daemon 2 例、requester 2 例当前失败」，改为 C3 复核结论 + 测试分布（business 57 js / 10 wasm+native；actions_test 10 三目标） |
| M2-rows | §5.1 补 3 行 | `pending_count`/`sync_log_count`/`raw_run`、`try_*` 三兄弟；`close` 行补「`open_temp` 库关闭即删临时目录」 |
| M2-schema | **新增 §5.1.1** | schema 列级契约表（tasks 13 / events 7 / sync_log 8 = 28 vs vools 26；索引 3 vs 2；类型/NULL 差异；护栏用例 `c3-2`） |
| M3-start | §5.2 签名修正 | `start(poll_interval_ms)` → **`start(max_rounds : Int32)`**，并说明轮询间隔在 `from_config_dir(..., poll_interval_ms?)` |
| M3-rows | §5.2 补 2 行 | vools 私有 `_run_once`/`_pull_remote`/`_process_inbox`/`_push_local` → 本项目公开增量；构造/观测入口 8 个 |
| M3-notes | §5.2 语义边界 | 单消费者/消费即删 + 不丢包分析、主线程阻塞、pull→process→push、C2 幂等守卫 |
| M4-rows | §5.4 补 1 行 | `Executor::{from_config_dir, from_mirror_path, worker_id, mirror}` |
| M5-55 | §5.5 整段重写 | jump 族 **⛔→✅ 8 个**（push/pull/sync、compute_sync_plan、scan_local_files、collect_files、should_exclude、`_fnmatch`），保留 6 个真 ⛔（paramiko 专属/真传输）；新增 `rhop.echo` 与 `get_handler`/`unregister_action` 行；标题改为「14：8 ✅ / 6 ⛔」 |
| M6-runforever | §5.6 参数顺序 | `run_forever(poll_interval_ms, max_rounds)` + 退出语义 |
| M6-glob | §5.6 补 1 行 | `fnmatch`→`sync_glob_match` 标 🟡（无 `[seq]`） |
| M7-diffs | §7 追加 6 条 | #22 jump 真传输 unsupported、#23 daemon 主循环形态、#24 同步判据 sha256≠size+mtime、#25 glob 无字符类、#26 单消费者、#27 镜像库列级增量 |
| M8-11-batchd / closed / counts | §11 数字与状态刷新 | actions「已实现未测」→ 2 ✅ + 2 增量；business 38/38 → **57/57**；`test-suit/rhop` 156/160/156 → **131/160/131**；项目级 wasm 612 / js 825 / native 612 |

---

## 3. C3-03 [P1] DOC.md 4 处业务段补齐 → 已修

| 位置 | 修前 | 修后 |
|---|---|---|
| `Executor` 代码块 | 只有 `new` | 补 `from_config_dir(RhopConfig, String, worker_id?)` / `from_mirror_path(RhopConfig, String, String, worker_id?)` |
| mirror 段 | 无 schema 说明 | 补「列级契约」段：13/7/8 = 28 列、+`envelope`/`claimed_by`、`version NOT NULL`、与 vools 不兼容共库（指向矩阵 §5.1.1 / §7 #27）、`c3-2` 护栏、`raw_run` 性质 |
| daemon 段 | 无语义说明 | 补「daemon 语义边界」：单轮顺序 + `run_once` 幂等、对称布局 + 消费即删（单消费者）+ 丢包分析、**主循环阻塞**（`Atomics.wait`，`stop()` 同线程不可达）、C2 幂等守卫 |
| sync_folder 段 | `run_forever // (rounds, poll_ms)`；`sync_glob_match // (* / ? / **)` | 改为 `(poll_interval_ms, max_rounds)`；改为「只支持 `*` / `?`（无 `[seq]` 字符类）」；补 `SYNC_MANIFEST_NAME`、`with_recursive` 返回新对象、同步语义 4 条（sha256 幂等、basename 匹配、跳符号链接、阻塞限制） |

> 说明：DOC.md 的 actions/mirror/requester/daemon **API 列表**在 C2 已由他人刷新过，本轮只补「语义/差异」
> 与仍缺的 Executor 构造入口；未改动其它 lane 的段落。

---

## 4. C3-04 [P2] schema 列级契约 + 可执行护栏 → 已加

- 文档：矩阵新增 §5.1.1、DOC.md mirror 段补段（见上）。
- **可执行护栏 `c3-2`**（`c3_regression_test.mbt`）：用独立只读连接跑
  `SELECT COUNT(*) FROM pragma_table_info(?)` 实测三表列数，断言 **13 / 7 / 8**；
  再用一条 SELECT 逐列寻址 13/7/8 列全部可读（防「文档说 13 列、实际少一列」）。
- 口径澄清（写进寻虫报告 §4）：任务书提到的「31 列」≠ mirror 侧实测值；mirror 三表 = **28 列 + 3 索引**。
  task_store 侧（P2b）由 impl-crypto 域出对照，本报告不越界。

---

## 5. C3-05 / C3-06 / C3-07

- **C3-05（语义差异补登记）**：4 项差异中 3 项此前只在源码头注释里有 ⇒ 本轮补进 DOC + 矩阵 §7（#22/#25/#26）；
  第 4 项（乐观锁 `stale_version:` 前缀）经核对在 DOC/矩阵**已存在**，不动。
- **C3-06（文档漂移）**：DOC 已刷新而矩阵滞后一轮，是「手工维护两个文档」的结构性问题。
  **建议**（未擅自实施）：终验前由 qa 用 `.mbti` + 测试汇总行生成矩阵 §5/§11 的数字与签名行；
  本轮已在两份报告中标注，避免下次再漂。
- **C3-07（README）**：`README.md:257` / `README.mbt.md:257` 业务行与代码一致且两份逐字相同 ⇒ **无需改**（0 处不一致）。

---

## 6. 双平台验证（最终态，真实汇总行）

### Windows（Git Bash，moon 0.1.20261016，node v25.2.1）

```
[W] moon check (default)                : 0 errors
[W] moon check --target js              : 0 errors
[W] moon check --target native          : 0 errors
[W] moon test test-suit/rhop_business --target js : Total tests: 57, passed: 57, failed: 0.
[W] moon test test-suit/rhop_business (wasm)      : Total tests: 10, passed: 10, failed: 0.
[W] moon test test-suit/rhop_business --target native : Total tests: 10, passed: 10, failed: 0.
[W] moon test test-suit/rhop --target js          : Total tests: 160, passed: 160, failed: 0.
[W] moon test (wasm，全量)                        : Total tests: 612, passed: 612, failed: 0.
[W] moon test --target js (全量)                  : Total tests: 825, passed: 825, failed: 0.
```

### WSL Ubuntu-22.04（moon 0.1.20261021 / node v25.2.1，`--target-dir _build/wsl` 隔离构建，经 `with_moon_lock.sh`）

```
[L] moon check (default)                : 0 errors
[L] moon check --target js              : 0 errors
[L] moon test test-suit/rhop_business --target js : Total tests: 57, passed: 57, failed: 0.
[L] moon test test-suit/rhop_business (wasm)      : Total tests: 10, passed: 10, failed: 0.
[L] moon test test-suit/rhop --target js          : Total tests: 160, passed: 160, failed: 0.
[L] moon test (wasm，全量)                        : Total tests: 612, passed: 612, failed: 0.
[L] moon test --target js (全量)                  : Total tests: 825, passed: 825, failed: 0.
[L] /tmp/rhop-biz-* 残留                          : 0
```

### temp delta（本域专属前缀，set-diff）

| 平台 | 场景 | delta |
|---|---|---|
| Windows | 连跑 3 次 business（57 例） | 0 / 0 / 0 |
| WSL | 跑 1 次 business（57 例） | 0 |
| 仓库根 | `ls -d "@TMP@" "rhop-data"` | none（clean） |

---

## 7. 回归防护要点（给后续轮次）

1. `c3-1a/1b` 锁死 workspace 生命周期：任何新增用例都必须用 `biz_temp_workspace()`（自动清扫+回收），
   不要自己写 `rhop_temp_workspace` 或裸 `mkdtemp`。
2. `c3-2` 锁死 schema 列数：若给 `tasks/events/sync_log` 加列，必须同步改文档（DOC + 矩阵 §5.1.1）与该断言。
3. 文档数字（§5 测试分布 / §11 汇总）已标注为「C3 实测」，下次改动测试数量请同步；建议最终由 qa 脚本生成。

## 8. 遗留风险（本域，未在本轮改动）

1. **kill 时最多残留 1 个 workspace**：SIGKILL 无法被 js 钩子捕获，只能靠「下次运行清扫」收敛（已实现）。
2. **矩阵/DOC 双份手工维护**会继续漂移（C3-06），根治要生成式文档（建议给 qa）。
3. C2 遗留的 5 条记录级风险（daemon 阻塞式 `start`、`MirrorDB` 值类型副本 close 语义、单消费者、
   未启 WAL、sync manifest 无裁剪）现状不变，均已文档化。
