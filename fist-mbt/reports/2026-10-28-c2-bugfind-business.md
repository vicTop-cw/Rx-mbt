# C2 寻虫报告 · Batch D 业务层（资源与并发）

- 轮次：C2（组合模式第 1 步：只读寻虫）
- 执行体：impl-business
- 域：`rhop/{mirror,requester,executor,daemon,sync_folder}.mbt` + `test-suit/rhop_business/` + `test-suit/rhop/actions_test.mbt`
- 时间：2026-10-28
- 环境：Windows 10/11 + Git Bash，moon 0.1.20261016，node v25.2.1；WSL Ubuntu-22.04（node v25.2.1）对照
- 方法：读码 + 独立 node 探针复现（探针脚本均在系统临时目录，未落仓库）+ 先把结论写成**会失败的回归测试**取证

> 结论摘要：**8 个缺陷**（P0×1、P1×3、P2×4）+ **5 条记录级风险**。
> 最重的两条：① daemon 消费不幂等，会把同一 Pending 信封**重复执行**（副作用重放）；
> ② 递归列举**跟随符号链接**，实测把 1 个文件放大成 67,453 条路径并穿出源根读到 `/etc`。

---

## 1. 缺陷清单

### C2-BUG-01 [P0] daemon 消费不幂等：同一 Pending 信封会被重复执行

- **位置**：`rhop/daemon.mbt` · `RelayDaemon::process_inbox`，分支条件
  `if self.side == Side::Executor && env.status == TaskStatus::Pending`
- **问题**：判定只看**信封自带的 status**（inbox 文件是历史快照），不看镜像库里该任务**当前**状态。
  inbox 里的信封只有在成功 `move_to(processed)` 后才消失；一旦搬运失败（Windows 文件被
  AV/索引器占用 → `EPERM`）或进程在「执行完、未搬完」之间崩溃，下一轮会再次读到同一枚
  `Pending v1` 信封：
  - 库内已是 `Done` ⇒ `upsert` 被版本守卫正确跳过，但**执行分支照走** ⇒
    `advance_to(Running)` 命中终态 → 虚假 `failed` 计数 + 重复写一份结果信封到 outbox；
  - 库内已是 `Running`（另一个执行体正在跑 / 上个进程执行中崩溃）⇒ `advance_to(Running)`
    直接判成功 ⇒ **动作第二次执行**（真实副作用重放）。
- **证据**（修复前 RED，已固化为回归测试）：
  ```
  $ moon test test-suit/rhop_business --target js
  [..] c2_regression_test.mbt:70 ("c2-1: daemon 不重复执行本地已在 Running 的任务（消费幂等）") failed: Error
  [..] c2_regression_test.mbt:130 ("c2-2: daemon 对已 Done 任务的残留信封不重复执行 / 不计虚假失败") failed: Error
  Total tests: 53, passed: 51, failed: 2.
  ```
  失败点 = `c2_regression_test.mbt:107`（`abort("重复执行了动作 N 次（应 0 次）…")`）。
- **最小复现**：① 镜像库里把任务推到 `running`（或 `done`）；② 把旧的 `Pending v1` 信封
  写回 `data_dir/inbox/`；③ `daemon.process_inbox()` → 动作计数器 0 → 1。
- **影响**：动作副作用重复（重复写库、重复跑命令、重复上传）；错误面被虚假 failed 污染，
  需求端可能收到错误的结果信封。
- **建议修法**：执行前读本地状态，**仅当库内为 `Pending`** 才执行；否则把信封移入
  `processed/` 留档并计入已处理（at-most-once + 版本去重）。跨进程竞争由
  `Pending → Claimed` 的零行守卫兜底（`run_changes` 变更行数为 0 时视为已被领走）。

### C2-BUG-02 [P1] 递归列举跟随符号链接：路径爆炸 + 穿出源根

- **位置**：`rhop/mirror.mbt` · `rhop_ffi_list_files_recursive`（原实现用 `fs.statSync`，
  **跟随**符号链接；`rhop_ffi_list_dir` 同病）
- **问题**：`statSync` 解析链接目标，`isDirectory()` 对「指向目录的链接」为真 ⇒ 递归进入；
  自指链接成环时靠 `ELOOP` 兜底才停，但**沿途已产出大量重复路径**；指向源根之外的链接
  会把外部文件也枚举进来。
- **证据**（WSL 探针，源目录只有 1 个文件 + 1 个自指环 + 1 个指向 `/etc` 的链接）：
  ```
  条目数 = 67453
  前 6 条: ["a.txt","loop/a.txt","loop/loop/a.txt","loop/loop/loop/a.txt", …]
  含 outside/ 的条目数 = 1715  例: ["outside/.java/.systemPrefs/.system.lock", …]
  [lstat+skip-link 修法] 条目数 = 1 ["a.txt"]
  ```
  Windows 默认无建链接权限（`EPERM`），因此**只有 WSL/Linux 会红** —— 这类「Windows 绿、
  WSL 也绿、但 Linux 生产环境炸」的问题必须靠 WSL 侧证据锁定（本机已复现）。
- **影响**：`sync_folder`/`jump.*` 扫描时内存与 CPU 爆炸（6.7 万条 → 每条再算一次 sha256），
  并把源根之外的文件复制进目标目录（意外数据外泄 / 覆盖同名文件）。
- **建议修法**：`readdirSync(dir, { withFileTypes: true })` + `ent.isSymbolicLink() → skip`，
  另加递归深度上限（64）兜底硬链接环/深目录。

### C2-BUG-03 [P1] 大文件摘要整读内存：RSS 与文件大小 1:1

- **位置**：`rhop/mirror.mbt` · `rhop_ffi_file_digest`（原 `fs.readFileSync` 全量读入）
- **证据**（256MB 文件，`--expose-gc`，同机对比）：
  ```
  当前实现 readFileSync: 文件MB=256, rss增量MB = 256.1 耗时ms = 330
  分块实现 readSync(1MB): rss增量MB = 1.0 耗时ms = 278 摘要一致 = true 总字节 = 268435456
  ```
- **影响**：`sync_folder.sync_once` / `jump.push` 扫描 GB 级 parquet 时 RSS 随文件线性上涨，
  容器内直接 OOM kill 常驻 daemon。
- **建议修法**：1MB 分块 `readSync` 喂 `createHash`，`finally` 关 fd；摘要语义与字节数不变
  （回归测试 `c2-4` 锁定「分块结果 == 整体 sha256」）。

### C2-BUG-04 [P1] 临时目录残留（并与 Windows 句柄泄漏耦合）

- **位置**：`rhop/mirror.mbt` 的进程退出钩子（`process.on("exit")`）+ 测试脚本生命周期
- **证据**：
  - 本机 `%TEMP%` 已累积 **4,889 个 `rhop-*` 目录 / ~151MB**（其中 `rhop-mirror-` 1,912 个，
    是历史轮次跑出来的）；
  - 单跑一次 `moon test test-suit/rhop_business --target js`，`%TEMP%` 净增 **3 个**
    `rhop-biz-*`，且每个 ~23MB（`daemon_test.mbt` 有 3 处只 `close()` 了双端 daemon 中的一端，
    另一端句柄泄漏）；
  - 探针证明 Windows 语义：**sqlite 句柄未关时 `rm -rf` 目录报 `EPERM`**；关库后才成功。
    退出钩子虽然会 `rm`，但句柄未释放 ⇒ 删除失败 ⇒ 目录留下（Linux 上 unlink 已打开文件
    合法，所以 **WSL 侧永远看不到这个残留**）。
- **影响**：长跑机器磁盘被临时库占满；残留目录里的 sqlite 文件还可能让后续复现串库。
- **建议修法**：退出钩子**先遍历 `__rhop_db` 逐个 `close()`**，再带重试删目录；测试侧
  全部 close 双端 daemon；新增 c2-5「关闭全部句柄后目录必须可删」作为句柄泄漏探测器。
  另外建议仓主执行一次 `%TEMP%\rhop-*` 清扫（见 §4 命令）。

### C2-BUG-05 [P2] prepared statement 无界增长（StatementSync 只能等 GC）

- **位置**：`rhop/mirror.mbt` · `rhop_ffi_db_run` / `rhop_ffi_db_all`（每次调用 `db.prepare(sql)`）
- **证据**：
  - node v25 的 `sqlite.StatementSync.prototype` 只有 `iterate/all/get/run/columns/…`，
    **没有 close/finalize**（探针打印确认）⇒ 语句只能等 GC；
  - 2,000 次调用：prepare-per-call RSS **+4.4MB** vs 复用 +0.2MB（≈2KB/条未回收）。
- **影响**：常驻 daemon 每轮处理 N 个信封就新建 N×M 条语句，RSS 呈锯齿上升。
- **建议修法**：有界语句缓存（按「连接 id + SQL」为键，容量 64，`close()` 时按前缀清理），
  并暴露 `__rhop_stmt_prepared` 计数供测试断言有界（回归测试 `c2-6`）。

### C2-BUG-06 [P2] `SQLITE_BUSY` 的错误文本不可读

- **位置**：`rhop/mirror.mbt` · `rhop_ffi_db_run` / `_db_all` / `_db_exec` 的 `catch`
- **证据**（探针，两个连接同库）：设 `busy_timeout=5000` 后，持写锁期间另一连接写
  **等待 5,543ms 后失败**（`ERR_SQLITE_ERROR`，原文 `database is locked`）；未设 timeout 时
  **2ms 立即失败**。也就是说 busy_timeout 已生效（C1 已加 `PRAGMA busy_timeout=5000`），
  但错误面只有英文原文，排查者无法区分「锁冲突」与「SQL 写错」。
- **建议修法**：`catch` 里把 `database is locked` / `SQLITE_BUSY` 映射为
  「数据库忙（SQLITE_BUSY）：…busy_timeout(5000ms)…请重试」并保留原文；`Result`/`Err`
  类型与签名不变。

### C2-BUG-07 [P2] 每文件一条 `log_sync` = 每文件一次 fsync

- **位置**：`rhop/daemon.mbt` · `RelayDaemon::push_local`（每个投递成功的文件发一条审计日志）
- **证据**（探针）：2,000 条写，**带事务 16ms vs 不带事务 22,660ms**（≈11ms/条，绝大多数是
  fsync）。也就是说「N 个文件 = N 个隐式事务 = N 次磁盘同步」。
- **影响**：一次推送 1,000 个信封 ≈ 10s 纯等待，期间 daemon 循环被拖住；与 C2-RISK-01
  叠加后表现为「推送一多就看起来像卡死」。
- **建议修法**：把一轮的审计日志收集起来，用 `write_tx`（`BEGIN IMMEDIATE`）**一次事务**
  批量写；文件投递本身仍在事务外（不持写锁做慢 IO）。

### C2-BUG-08 [P2] `write_atomic` 失败残留 `*.tmp`

- **位置**：`rhop/mirror.mbt` · `rhop_ffi_write_atomic`（写 tmp → rename；失败未清理 tmp）
- **证据**：读码 + Windows 语义探针：目标被占用时 `renameSync` 抛 `EPERM`（`copyFileSync`
  可覆盖，`rm` 不可）。失败路径把 `path.tmp` 留在目标目录 ⇒ 下一轮 `rhop_fs_list_dir`
  会把它当普通文件看到（daemon/sync 目录里出现 `xxx.rhop.tmp` 垃圾）。
- **建议修法**：`catch` 里 `fs.unlinkSync(tmp)`（忽略二次错误）后再返回 false。

---

## 2. 记录级风险（本轮不改 API/不加功能，仅记录与文档化）

### C2-RISK-01 `daemon.start()` 阻塞主线程，`stop()` 同线程不可达
`start()` 用 `while self.running` + `rhop_sleep_ms`（`Atomics.wait`）在**主线程**阻塞，
因此同线程无法调用 `stop()`；js 侧也无法用信号处理器优雅停机。当前只有
`start(max_rounds>0)` 能退出。**结论**：这是接口层的既有约束（vools 用 Python 线程/信号），
要修必须引入异步循环或回调，属「改功能」，本轮只记录。
规避：常驻场景用外部进程管理（kill）+ 每轮短事务；`run_once()` 保持幂等可反复调用。

### C2-RISK-02 `MirrorDB` 是值类型：`Requester::mirror()` 返回副本
副本与原件共享同一个 JS 句柄，但 `closed` 标志各自独立：
- 对**副本**调 `close()` 会关掉底层连接，原件 `is_open()` 仍为 true，后续操作报
  「数据库句柄无效（可能已 close）」——可诊断，但极易误用；
- 对 `open_temp()` 得到的库，副本 `close()` 还会**递归删掉临时目录**（原件继续用会报错）。

**结论**：`mirror()` 已在文档里标注「只读用途、不要在外部 close」；若要根治需改成
引用共享（`Ref`/注册表），属改设计，本轮记录。

### C2-RISK-03 共享介质「消费即删除」= 单消费者语义
`pull_remote` 读成功即删远端文件。两进程同时消费同一共享目录会丢包（无 ack）。
当前明确是 MVP 单消费者（已在文件头写明），多消费者需要 ack/租约协议，本轮不做。

### C2-RISK-04 未启用 WAL（`journal_mode=delete`）
探针确认默认 `journal_mode = delete`。WAL 能提升读写并发，但 **WAL 放在网络盘（SMB/UNC）
上不安全**，而 `data_dir` 允许指向共享目录。结论：保持 delete 模式 + `busy_timeout=5000`，
把「并发写偶发 BUSY」当作可重试错误（C2-BUG-06 的文本改进让它可以被识别）。

### C2-RISK-05 `sync manifest` 无裁剪
`.sync_manifest.json` 只增不减：源端长期轮换文件名的场景会线性膨胀（每条 ~60B，10 万条
≈6MB，读写都要全量解析）。当前可接受，若要做需引入「N 天未出现则淘汰」。

---

## 3. 跨平台语义矩阵（本轮实测，Windows vs WSL）

| 行为 | Windows（NTFS） | WSL（ext4） | 对本项目的影响 |
|---|---|---|---|
| `rename` 覆盖已存在目标 | OK（Node 用 ReplaceExisting） | OK | `write_atomic` 可放心覆盖 |
| `rename` 到**被占用**目标 | **EPERM** | OK（Linux 允许） | `rhop_fs_move` 必须保留 copy+unlink 回退；daemon 搬信封可能失败 ⇒ 正是 C2-BUG-01 的触发条件 |
| `rm -rf` 目录时有 sqlite 句柄未关 | **EPERM** | OK（unlink 已打开文件合法） | 临时目录残留**只在 Windows 现形**（C2-BUG-04）；WSL 绿不能代表 Windows 绿 |
| 建符号链接 | 默认无权限（EPERM） | 可建 | 符号链接类缺陷**只在 WSL/Linux 现形**（C2-BUG-02）；Windows 绿不能代表 Linux 绿 |
| 跨设备 `rename` | 需 copy+unlink 回退 | 同样 | `rhop_fs_move` 已有回退，保持 |

**结论（给终验的提醒）**：Windows 与 WSL **互为盲区** —— 句柄泄漏类缺陷在 WSL 上不可见，
符号链接类缺陷在 Windows 上不可见。两平台必须各自把 gate 跑满，且都应覆盖
「句柄关闭后目录可删」「递归列举跳过链接」这两条用例。

---

## 4. 复现/取证命令（本轮实际使用）

```bash
# 判包（精确路径，避免 -p 前缀误匹配 test-suit/rhop_task）
bash scripts/with_moon_lock.sh moon test test-suit/rhop_business --target js

# 符号链接爆炸（WSL）
wsl.exe -e bash -lc 'node /tmp/probe1b.js'      # 输出 67453 条 / outside 1715 条

# 大文件摘要内存（Windows）
node --expose-gc probe2.js                      # readFileSync +256.1MB vs 分块 +1.0MB

# 语句/事务成本
node --expose-gc probe3b.js                     # 带事务 16ms vs 无事务 22660ms

# busy_timeout 行为
node probe4.js                                  # 等 5543ms 后 ERR_SQLITE_ERROR

# 文件语义矩阵（Windows / WSL 各跑一遍）
node probe5.js

# 临时目录残留盘点（仓主可执行一次清扫）
ls -d "$TEMP"/rhop-* | wc -l
rm -rf "$TEMP"/rhop-*        # 仅当没有 daemon 在跑时
```

---

## 5. 修复计划（本轮 P0/P1/P2 全修，均不改公开 API 签名、不加功能）

| 编号 | 级别 | 修法 | 回归用例 |
|---|---|---|---|
| C2-BUG-01 | P0 | `process_inbox` 增加「库内必须仍为 Pending」守卫，否则移 `processed/` 留档 | `c2-1`、`c2-2` |
| C2-BUG-02 | P1 | `withFileTypes` + 跳过 `isSymbolicLink` + 深度上限 64（递归/非递归两处） | `c2-3`（Windows 退化断言 + WSL 实证） |
| C2-BUG-03 | P1 | 1MB 分块 `readSync` 摘要，失败关 fd | `c2-4` |
| C2-BUG-04 | P1 | 退出钩子先关全部库句柄再重试删目录；测试补齐双端 close | `c2-5` |
| C2-BUG-05 | P2 | 有界语句缓存（≤64）+ `__rhop_stmt_prepared` 计数 | `c2-6` |
| C2-BUG-06 | P2 | `SQLITE_BUSY` → 中文可诊断文本（保留原文） | 由 `c2-1`…间接覆盖 + 手工探针 |
| C2-BUG-07 | P2 | `push_local` 审计日志一轮一事务批量写 | 既有 daemon 用例 + 计时记录 |
| C2-BUG-08 | P2 | `write_atomic` 失败清理 `*.tmp` | 既有 envelope/daemon 用例（路径覆盖） |

修复后证据与两平台验证记录见 `2026-10-28-c2-fix-business.md`。
