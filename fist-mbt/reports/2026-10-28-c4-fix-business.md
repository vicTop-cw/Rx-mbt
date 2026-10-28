# C4 修复报告 · Batch D 业务层（端到端 / 集成压力 / 安全 / 卫生）

- 轮次：C4（第 2–3 步：修复 + 回归 + 双平台验证）
- 执行体：impl-business
- 寻虫报告：`fist-mbt/reports/2026-10-28-c4-bugfind-business.md`
- 纪律：MCP 断连 → 本地证据链；`moon` 一律经 `bash scripts/with_moon_lock.sh`；**未改公开 API 签名、未加功能**

## 改动文件清单

| 文件 | 类型 | 改动 |
|---|---|---|
| `rhop/mirror.mbt` | **P1 修复** | `mir_row_to_envelope` 读路径改为「以列为准」（列与 `envelope` 列撕裂时自愈并重算 checksum） |
| `rhop/daemon.mbt` | P2 加固 | `pull_remote` / `push_local` 的文件名拼接改走 `rhop_join_checked`（词法前缀断言） |
| `test-suit/rhop_business/c4_e2e_test.mbt` | **新增 12 例** | 跨进程 E2E / 多进程 sqlite / 大目录 / 安全 / kill -9 / 重启续跑 |
| `test-suit/rhop_business/moon.pkg` | 登记 | `c4_e2e_test.mbt`（js 目标） |
| `test-suit/rhop_business/c3_regression_test.mbt` | 自测修正 | `c3-1a` 全局「≤1 workspace」断言放宽为 `≤2`（并行测试下不再误报，核心断言保留） |
| `fist-mbt/docs/2026-10-27-rhop-vools-parity-matrix.md` | 文档 | §5.1.1 增「读回以列为准」；§7 #27 补一句 |
| `DOC.md` | 文档 | mirror schema 段增「读回以列为准（C4-01）」 |

---

## 1. C4-01 [P1] 多进程下读回**过期快照** → 已修

### issue
`tasks` 表的 `status`/`version`/`side` **同时**存在于「列」与「`envelope` 列」。本项目自身写入始终双写一致，
但任何**只更新列**的外部写入方（另一个进程直接跑 SQL、vools 式实现、运维手改）会让两者撕裂；
而读路径（`get_task`/`list_tasks`/`try_*`）以 `envelope` 为准 ⇒ 读到旧状态。

### 证据（修前，真子进程竞争）
```
C4DIAG c4-3a peer report = {"claimed":1,"final":{"status":"claimed","version":2,"claimed_by":"peer"},"other":19}
C4DIAG c4-3a parent view: status=pending version=1     ← 父进程（本实现）读到过期快照
```
对照：纯 node:sqlite 跨进程读写**正常可见**（parent before v1 → child 写 → parent after v2），
⇒ 排除 sqlite 隔离/缓存因素，确认是「列 vs envelope」双份状态撕裂。

### 修法
`mir_row_to_envelope`：解析 `envelope`（保留 checksum 校验）→ 用列的 `status`/`version`/`side`/`updated_at`
覆盖 → **撕裂时**用 `new_full` 重算 checksum（返回信封自洽）；**未撕裂时行为与旧版逐字节一致**（既有往返用例不变）。
理由：乐观锁（`update_status`/`claim_task`/upsert 版本守卫）只读列，若读回用 envelope 旧快照就会出现
「别人已 claim、我仍看到 pending」⇒ 重复执行/重复回报/丢更新。

### 回归
- `c4-3c`（新）：外部 SQL 只改列（status/version/claimed_by）→ `get_task` 必须读到 `claimed v2`、
  checksum 与内容自洽、`claim_task` 再领被拒。
- `c4-3a`：父进程 + 子进程争抢同一任务 ⇒ 合计恰好 1 次 claim、version 只 +1；**修后**父进程读回
  `status=claimed version=2`（修前为 `pending v1`）。

---

## 2. C4-02 [P2] daemon 文件名拼接加固 → 已修

- `pull_remote`：`fname` 来自**共享介质**（不可信边界）。虽然 `readdir` 只返回单层名字，仍改为
  `rhop_join_checked(...)`（非空/无分隔符/无 `..`/结果前缀断言），可疑条目计入 errors 并跳过。
- `push_local`：投递路径同样走 `rhop_join_checked`（防御纵深）。
- 证据：既有 daemon 用例（含 `c4-1`/`c4-2`/`c4-7`）全绿，未改行为语义。

> 说明：与 C1 已有的 `validate_task_id` + `rhop_join_checked`（`write_outbox_result`）形成三层防御：
> 信封解码即校验 task_id → 落盘路径词法断言 → 共享介质条目名断言。

---

## 3. C4-03 / C4-04 / C4-05：记录级风险（需产品/部署决策，本轮不改）

| 编号 | 风险 | 现状与建议 |
|---|---|---|
| C4-04 | **动作层无「对端可执行动作」白名单**：能写共享介质的一方即可让执行端跑任意已注册 action（含 `jump.*` 的本地目录扫描：泄漏文件名与 `{sha256,size}`） | 已有缓解：真传输 `unsupported`、回执深度掩码、未知 action 必失败。建议：部署侧只 `register_action` 允许的动作；或后续加 allowlist 配置项（=加功能，待决策）。已写进报告。 |
| C4-05 | `failed/`、`processed/` **无保留上限**：坏信封永久堆积，异常/恶意对端可缓慢撑爆磁盘 | 建议运维定期清理；根治需保留策略配置项（=加功能，待决策） |
| C4-03 | （合并入 C4-05 的同类资源问题） | 同上 |

---

## 4. C4-06 [P2] 文档缺口 → 已补

- 矩阵 §5.1.1：新增「读回语义（C4-01，重要）」段落，说明列/envelope 双写、撕裂原因、
  「以列为准」的规则与回归用例编号。
- 矩阵 §7 #27：在「镜像库列级增量」行补一句「读回以列为准」。
- `DOC.md` mirror schema 段：补同样的说明（含 `c4-3c` 指针）。

---

## 5. C4-07 [P3] 自测缺陷：`c3-1a` 并行下误报 → 已修

`c3-1a` 原先断言「全局存活的 `rhop-biz-*` 目录 ≤1」，但 `moon test` 可并行执行同包不同测试文件，
其它用例的 workspace 会同时存在 ⇒ 误报（本轮实测撞到 1 次）。改为：
- 保留强断言「新建第二个后**第一个必须消失**」；
- 全局计数放宽为 `≤2`（串行时仍为 ≤1），并注明原因。

---

## 6. 新增回归用例（`c4_e2e_test.mbt`，12 例）

| 用例 | 覆盖 | 关键断言 |
|---|---|---|
| `c4-1` | 跨进程 E2E 出站 | 对端子进程**独立重算 checksum** 校验通过；回写结果被本端消费；`result.executed_by=="peer-child"` |
| `c4-2` | 跨进程 E2E 入站 | 子进程构造合法信封投递 → daemon 执行 → 第三子进程读到 `status=done/checksum_ok/has_result` |
| `c4-3a` | 多进程 sqlite claim 竞争 | 合计恰好 1 次成功、version 只 +1、`busy=0` |
| `c4-3b` | sqlite-local + shared 拓扑 | 两侧各持本地库，经共享目录完成提交→执行→结果回流 |
| `c4-3c` | **C4-01 回归** | 外部只写列 → 读回以列为准 + checksum 自洽 + 重复领取被拒 |
| `c4-4` | 1200 文件大目录 | 首轮 1200 pulled；重跑 0/1200 skipped；删 200 后补 200；再收敛 0 |
| `c4-5a` | 注入 task_id 穿越 | 7 种恶意 id 全 Err，`dir/../evil.rhop` 不存在 |
| `c4-5b` | 恶意信封穿越 | 进 `failed/`、`failed=1`、无越界目录 |
| `c4-5c` | 口令掩码 | `password`/`key_path`/`token`/`api_key` 值均不出现在回执，`***` 存在，非敏感字段仍可见 |
| `c4-5d` | 错误文本 | 坏信封错误文本不含 payload 里的 `PAYLOAD-SECRET` |
| `c4-6` | **kill -9** | 强杀后库可打开可查询、目录无 `*.tmp`、残留目录可清扫 |
| `c4-7` | daemon 进程重启 | 新实例继续处理 inbox 遗留 + 投递 outbox 遗留（两条信封都到共享介质），第三轮全 0 |

---

## 7. 双平台验证（最终态，真实汇总行）

### Windows（Git Bash，moon 0.1.20261016，node v25.2.1）

```
[W] moon check (default)                : 0 errors
[W] moon check --target js              : 0 errors
[W] moon check --target native          : 0 errors
[W] moon test test-suit/rhop_business --target js : Total tests: 69, passed: 69, failed: 0.
[W] moon test test-suit/rhop_business (wasm)      : Total tests: 10, passed: 10, failed: 0.
[W] moon test test-suit/rhop_business --target native : Total tests: 10, passed: 10, failed: 0.
[W] moon test test-suit/rhop --target js          : Total tests: 163, passed: 163, failed: 0.
[W] moon test (wasm，全量)                        : Total tests: 615, passed: 615, failed: 0.
[W] moon test --target js (全量)                  : Total tests: 849, passed: 849, failed: 0.
```

### WSL Ubuntu-22.04（moon 0.1.20261021 / node v25.2.1，`--target-dir _build/wsl`）

```
[L] moon check (default)                : 0 errors
[L] moon check --target js              : 0 errors
[L] moon test test-suit/rhop_business --target js : Total tests: 69, passed: 69, failed: 0.
[L] moon test test-suit/rhop_business (wasm)      : Total tests: 10, passed: 10, failed: 0.
[L] moon test test-suit/rhop --target js          : Total tests: 163, passed: 163, failed: 0.
[L] moon test (wasm，全量)                        : Total tests: 615, passed: 615, failed: 0.
[L] moon test --target js (全量)                  : Total tests: 849, passed: 849, failed: 0.
```

### 卫生

| 检查 | 结果 |
|---|---|
| `ls -d @TMP@ rhop-data`（仓库根，Windows） | none |
| `/tmp/rhop-biz-*` delta（WSL，跑完 business 69 例） | **0** |
| `rhop-biz-*` delta（Windows，跑完 business 69 例） | **0** |
| 遗留补丁脚本 / 临时探针脚本 | 无（全部写在 workspace 内，随 `biz_cleanup` 删除） |

---

## 8. 遗留风险（本域）

1. **C4-04 动作白名单**、**C4-05 目录保留策略**：需产品/部署决策，本轮只记录（未加功能）。
2. 权限拒绝场景（sync_folder 读源/写目标 EACCES）在 Windows 难以稳定构造（需管理员 ACL）、
   WSL 以 root 跑 chmod 无效 ⇒ 本轮未覆盖；同类代码路径已由「源目录不存在 → errors 不中断」用例覆盖。
3. C2/C3 既有风险不变：daemon `start()` 主线程阻塞、`MirrorDB` 值类型副本 close 语义、
   共享介质单消费者、未启 WAL、sync manifest 无裁剪 —— 均已文档化。
