# C4 寻虫报告 · Batch D 业务层（端到端 / 集成压力 / 安全 / 卫生）

- 轮次：C4（端到端真实场景 + 集成压力 + 安全审计 + 生成物/工作树卫生）
- 执行体：impl-business
- 域：`rhop/{mirror,requester,executor,daemon,sync_folder}.mbt` + `test-suit/rhop_business/`
- 起点 HEAD：`0e17d21`（v0.4.0）
- 时间：2026-10-28
- 方法：**真子进程**（node `spawn`/`spawnSync`，可控 SIGKILL）+ 独立进程重算 checksum 互验 + 1200 文件真实目录 + 外部 SQL 只写列 + 静态审计
- 纪律：MCP 断连，全本地证据链

> 结论：**1 个 P1 真缺陷（多进程下读回过期快照，可导致重复领取/丢更新）+ 4 个 P2 风险 + 1 个自测缺陷**。
> 其余重点项（跨进程 E2E、claim 竞争、大目录、安全穿越、kill -9）**实测通过**，已固化为回归用例 10 条。

---

## 1. ① daemon 双进程共享介质真实 E2E —— 实测通过（无缺陷）

做法：本进程跑 MoonBit daemon，**另一个真实 OS 进程**（node 子进程）充当对端替身，
按同一 on-disk 协议收发 `.rhop`；对端**独立实现** canonical JSON + checksum 重算用于互验。

| 用例 | 场景 | 结果 |
|---|---|---|
| `c4-1` | requester daemon → `<shared>/inbox/executor/` → 子进程**重算 checksum 校验**后回写 Done 信封 → daemon 再拉回 → 本端 `get_result` = done 且 `result.executed_by == "peer-child"`（证明结果确由另一进程产出） | ✅ 通过（跨实现 checksum 一致） |
| `c4-2` | 子进程用 node 自己构造**合法 Pending 信封**投递 → executor daemon 拉取/入库/执行 → 结果信封写到 `<shared>/inbox/requester/` → **第三个子进程**读取并重算 checksum、断言 `status=done/has_result` | ✅ 通过 |
| `c4-3b` | sqlite-local + shared 间接拓扑：A/B 各持本地库、仅经共享目录相连，完成 提交→执行→结果回流，两侧本地库各自持有该任务 | ✅ 通过 |

补充说明：daemon 的「重复 run_once 幂等」「坏信封进 failed/」「进程重启续跑」在 C2/C3 已有用例
（`daemon_test.mbt` 6 例 + `c2-1/c2-2` 幂等守卫）；本轮新增的跨进程用例只验证**进程边界**与
**协议字节级互操作**。

---

## 2. ② requester/executor 多进程 sqlite —— **发现 P1 缺陷**

### C4-01 [P1] 镜像行「列 vs `envelope` 列」双份状态可撕裂 ⇒ 多进程下读回**过期快照**

- **位置**：`rhop/mirror.mbt` · `mir_row_to_envelope`（读路径）+ `tasks` 表结构
- **触发**：任何**只更新列**的写入方 —— 另一个进程直接跑 SQL（`c4-3a` 里的对端子进程就是）、
  vools 式实现（其 `update_status` 只写列）、运维手改。
- **证据（修前，`c4-3a` 诊断输出）**：
  ```
  C4DIAG c4-3a peer report = {"claimed":1,"final":{"status":"claimed","version":2,"claimed_by":"peer"},"other":19}
  C4DIAG c4-3a total=1 mine_ok=false
  C4DIAG c4-3a parent view: status=pending version=1     ← 父进程读回过期快照
  ```
  对照实验（纯 node:sqlite，跨进程可见性正常）：
  ```
  parent before: [{"k":"a","v":1}]
  parent after : [{"k":"a","v":2}]      ← 直接列读写无问题
  reopen       : [{"k":"a","v":2}]
  ```
  ⇒ 不是 sqlite 缓存/隔离问题，而是**我们把 status/version/side 同时存在列与 `envelope` 列里**，
  读路径以 `envelope` 为准，于是「列已 claimed v2」被读成「pending v1」。
- **影响（真实后果）**：
  1. 拿到的信封状态过期 ⇒ 调用方可能**重复执行/重复回报**（C2 的幂等守卫基于 `get_task` 的状态判断，
     读到 pending 就会重新执行）；
  2. `list_tasks(status=…)` 过滤用列、返回的信封 status 用 envelope ⇒ **同一接口自相矛盾**；
  3. 与 vools 共用同一库文件的场景（§7 #27 已声明不保证）会静默读错，且难以定位。
- **修法**：读路径**以列为准**：解析 envelope（保留 checksum 校验）→ 用列的 `status/version/side/updated_at`
  覆盖 → 撕裂时用 `new_full` 重算 checksum（返回的信封自洽）；未撕裂时与旧行为逐字节一致。
- **回归**：`c4-3c`（外部 SQL 只改列 → `get_task` 读到 claimed v2、checksum 自洽、重复领取被拒）。

### 2.1 多进程 claim 竞争实测（通过）

`c4-3a`：父进程（MoonBit `MirrorDB`）+ 子进程（独立 node:sqlite 连接，20 轮 `BEGIN IMMEDIATE`+守卫 UPDATE）
同时抢同一 Pending 任务 ⇒ 子进程 `claimed=1`、父进程因任务已非 pending 而放弃，
**合计恰好 1 次成功**，`version` 只 +1（无丢更新/双写），`busy=0`（busy_timeout=5000 生效）。

---

## 3. ③ sync_folder 真大目录 —— 实测通过（无缺陷）

`c4-4`：1200 个文件（根 200 + 5 个子目录各 200）、`*.csv` 过滤、递归：

| 阶段 | 期望 | 实测 |
|---|---|---|
| 首轮拉平 | 1200 pulled / 0 skipped / 0 errors | ✅ |
| 立即重跑 | 0 pulled / 1200 skipped | ✅（幂等） |
| **中断后重跑**：删掉 200 个目标文件（模拟拷一半崩） | 补 200 pulled / 1000 skipped | ✅ |
| 再收敛 | 0 pulled | ✅ |

- 符号链接：C2 已修（`c2-3` 在 WSL 实测：修前 67,453 条路径 → 修后仅真实文件）。
- **权限拒绝**：Windows 上难以稳定构造（ACL 需管理员），WSL 以 root 跑 chmod 无效 ⇒ 本轮**未覆盖**，
  风险记录为「sync_once 对读源失败/写本地失败均计入 `errors` 且不中断，已由 `sync_glob_test.mbt`
  的「源目录不存在」用例覆盖同类代码路径」。

---

## 4. ④ 安全审计 —— 4 项实测，1 项风险

| 项 | 结论 | 证据 |
|---|---|---|
| **task_id 路径穿越（submit 入口）** | ✅ 已拦截：`Requester::submit` 在落盘前 `validate_task_id`（白名单 `[A-Za-z0-9._-]`、≤128、禁 `..`/`.`、禁分隔符） | `c4-5a`：`../../evil`、`..`、`.`、`a/b`、`a\b`、`c:evil`、空 全部 Err，且 `dir/../evil.rhop` 不存在 |
| **恶意信封（穿越/超长 task_id）** | ✅ 已拦截：`decode_envelope` 解码后立刻校验，非法 id 走「坏信封」通道进 `failed/`，**不进入任何落盘拼接**；`write_outbox_result` 另用 `rhop_join_checked` 兜底 | `c4-5b`：`../../etc/passwd` 信封 → `failed=1`、进 `failed/`、无越界目录 |
| **动作回执口令泄漏** | ✅ 已掩码：`RhopConfig::action_cfg` 走 `cfg_mask_secrets`，`rhop.echo` 走 `cfg_mask_deep`（递归、大小写不敏感、命中键整体 `"***"`） | `c4-5c`：cfg 内 `password`/`key_path`/`token`/`api_key` 三个 SECRET 值均不出现在回执 canonical JSON 中，`***` 存在，非敏感 `host` 仍可见 |
| **日志/错误文本泄漏 payload** | ✅ 不泄漏：坏信封错误只含 checksum/字段级信息 | `c4-5d`：把含 `"password":"PAYLOAD-SECRET"` 的信封篡改 → `errors` 文本不含 `PAYLOAD-SECRET` |
| **动作层信任边界（风险）** | ⚠️ C4-04：`Executor::execute` 会执行**对端 payload 指定的任意已注册 action**。`jump.push/pull/sync` 虽然「真传输 unsupported」，但其 `dry_run` 会**真实扫描调用方给的 `local_path`** 并回传 `files`（文件名）与 `{sha256,size}` ⇒ 能写共享介质的一方可以让执行端**枚举任意本地目录** | 见 §5 C4-04 |

**jump 真传输的「安全替代建议」**：`unsupported` 错误消息里已给
「请用 dry_run 取结构化计划，或改用共享目录通道（SyncFolder / shared）」，未建议关闭校验/降级明文 ✅。

---

## 5. 风险清单（本域，不属「修 bug」范畴或需产品决策）

### C4-04 [P2] 动作层缺少「对端可执行动作白名单」
- 现状：任何能写共享介质的一方都能让执行端跑任意已注册 action（含 `jump.*` 的本地目录扫描）；
  身份层只有「能写共享目录」这一隐含前提（无签名/身份绑定，`FileHashSigner` 只绑定 task_id+result）。
- 已有缓解：真传输 unsupported、回执掩码、payload 里的 action 未知则失败（不静默）。
- 建议（需 API/产品决策，本轮**不加功能**）：执行端部署时只 `register_action` 允许的动作，
  或后续加「action allowlist 配置项」；短期把「共享介质目录的写权限 = 执行端可执行面」写进部署文档。

### C4-05 [P2] `failed/` 与 `processed/` 无保留上限
- 坏信封会永久堆在 `failed/`：恶意/异常对端持续投递坏包可缓慢撑爆磁盘（DoS）。
- 建议：运维定期清理；若要根治需加保留策略（配置项 = 加功能，本轮不做）。

### C4-06 [P2] 文档缺口：C4-01 的「列为准」语义此前未文档化
- `mirror.mbt` 头注释只描述了「envelope 列自证完整性」，未说明**列与 envelope 撕裂时以列为准**，
  也未说明这与 §7 #27「不与 vools 共库」的关系。
- 处置：已在修复中补进 `mirror.mbt` 读路径文档 + DOC.md + 矩阵 §5.1.1/§7 #27（见 fix 报告）。

### C4-07 [P3] 自测缺陷：`c3-1a` 的「全局 ≤1 workspace」断言在并行测试下不稳
- `moon test` 可并行跑同包不同测试文件，其它用例的 workspace 会同时存在 ⇒ 全局计数断言误报
  （本轮实测撞到一次）。核心不变量应是「上一个 workspace 被回收」。
- 处置：放宽为 `≤2` 并保留「first 必须消失」的强断言；串行时仍为 ≤1。

---

## 6. ⑤ 资源与失败恢复（kill -9）—— 实测通过（无缺陷）

`c4-6`：子进程建库、写入 `running` 行后进入 `setInterval` 常驻；父进程 `kill -9`（**无退出钩子、无清理机会**）：

| 检查 | 结果 |
|---|---|
| 强杀后库仍能 `MirrorDB::open` 且可查询（SQLite 回滚日志生效，未损坏） | ✅ |
| 目录内无 `*.tmp` 残留（原子写 `tmp+rename` 的 tmp 不会遗留） | ✅ |
| 残留目录可被 `rhop_remove_dir_all` 清扫（下次运行可收敛） | ✅ |

另：C3 的 workspace 卫生（首次清扫 + 存活 ≤1 + 显式 cleanup）在本轮 10 个新用例上继续生效，
`%TEMP%/rhop-biz-*` 净增 0。

---

## 7. 用例与代码位置索引

| 用例 | 文件 | 覆盖 |
|---|---|---|
| `c4-1` | `test-suit/rhop_business/c4_e2e_test.mbt` | 跨进程出站 + 对端独立 checksum 互验 + 结果回流 |
| `c4-2` | 同上 | 跨进程入站（对端构造信封）+ 执行 + 结果可被第三进程读取校验 |
| `c4-3a` | 同上 | 多进程 sqlite claim 竞争（恰好一方成功、version 只 +1） |
| `c4-3b` | 同上 | sqlite-local + shared 间接拓扑全链路 |
| `c4-3c` | 同上 | **C4-01 回归**：外部只写列 ⇒ 读回以列为准 |
| `c4-4` | 同上 | 1200 文件大目录 + 重跑幂等 + 中断后收敛 |
| `c4-5a/b/c/d` | 同上 | 路径穿越（两入口）/ 口令掩码 / 错误文本不泄漏 payload |
| `c4-6` | 同上 | kill -9 后库可读、无 tmp 残留、残留可清扫 |

修复与双平台验证见 `fist-mbt/reports/2026-10-28-c4-fix-business.md`。
