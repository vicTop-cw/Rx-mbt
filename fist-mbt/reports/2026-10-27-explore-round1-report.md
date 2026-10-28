# 2026-10-27 · rhop ← vools-rhop 复刻 · 探索模式第 1 轮执行汇报

- 命名空间：fist-mbt `rx-rhop`
- 执行契约：`fist-mbt/plans/decisions/2026-10-27-rhop-vools-parity-decision.md`
- 参考实现：`E:\IDEProjects\AI\vools\rhop`（vools-rhop 0.9.0）

## 1. 复杂度打分（explore 模式步骤 1）

根目标（用户原话，153 码点）：

| 信号 | 判据 | 得分 |
|---|---|---|
| 描述长度 | 153 码点 < 200 | +0 |
| 已有子任务数 | 打分时 0 | +0 |
| 提及缺陷 | 无 | +0 |
| 提及测试 | “测试 / 通过” | +1 |
| 提及接口 | “api” | +1 |
| 提及扩边界 | “迭代开发 / 复刻”（迁移/新功能语义） | +1 |
| 提及文档 | 无 | +0 |

⇒ **c = 3**，按档表该档是 `polish`；但根目标「一句话讲不完、跨 4 个交付批次 + 1 个测试平台」，
适用探索模式**步骤 3.5（复合目标先递归拆解）**：先 `task_plan_deep` 再对子树重新打分。

子树重算（以 Batch A 为例，描述 629 码点）：描述长度 +2、提及测试 +1、提及接口/api +1、
提及扩边界（复刻/新功能）+1 ⇒ **c = 5 ⇒ chosen_mode = `advance`**（唯一允许扩大功能边界的档）。
其余 Batch B/C/D 与 QA 同构 ⇒ 本轮实际工作模式 = `advance`。

## 2. 并行判定（步骤 4 四道门）

W1 候选：Batch A（impl-core）、Batch B-前段（impl-crypto）、QA 平台（qa-platform）。

| 门 | 结论 |
|---|---|
| ① 候选除选中模式外 ≥1 | 通过（3 路） |
| ② 每路申报非空作用域且一一对应 | 通过（见 §4 回执清单） |
| ③ 作用域两两不相交（按 trim 后字面路径） | 通过：A={rhop/core,digest,json_canonical,envelope,signer,integrity + test-suit/rhop 6 个测试}；B1={rhop/key,crypto,test-suit/rhop_js/moon.pkg,crypto_test}；QA={scripts/4 个脚本,test-suit/rhop_js/fixtures/,fist-mbt/reports/} |
| ④ reserve_scope 三分支 + 认领前 conflicts_check | reserve_scope 全部 `reserved`（其中 `rhop/*.mbt`、`test-suit/rhop_js/fixtures/` 为 `unregistered` advisory 登记 —— 按模板要求由第 ③ 门字面不相交兜底）。**conflicts_check 无法执行**：该工具没有 `namespace` 参数，查 default 库对 `rx-rhop` 任务恒报 `task not found` ⇒ 退化为「claim 本身即冲突裁决」（claim 对已持有任务会拒绝），并已向 FIST-Mbt 报缺陷（BUG-452） |

⇒ **parallel_allowed = true**（第 ④ 门的 conflicts_check 因子被工具面缺陷阻断，已用 claim 冲突语义替代并留痕）。
W2（Batch C）在 W1 的 B1/B2 完成后串行开，W3（Batch D）在 C 后串行。

## 3. 任务树与执行单元

规划树 `T0`（`task_plan_deep`，六开关全开：gradient / gradient_dag / boundary_probe /
reinject_context / calibrate=[2,3,4,4,5] / omega_strong_verify）+ 24 个规划片
（6 分支 × 3 片，易/中/难梯度 + 真实 DAG 前置 + 边界四问）。

**规划树作废原因（实测）**：
1. `publish(level=0)` 使叶子被算成 `level=2`（师长）⇒ Executor（rank 5）`claim` 被
   `RANK_GATE` 拒；而 `rank_of(level, leaf=true)` 文档写「叶子恒为士兵」⇒ claim 门未用 `is_leaf`。
   已报 **FIST-Mbt BUG-451**。
2. `project_dir="."` 按 MCP server 进程 cwd（`E:/IDEProjects/AI/FIST-Mbt`）解析，
   导致 `run_check` 在错仓库执行、`output_validate` 找不到产物（实测回执已证）。
   修正：执行单元改用**绝对** `project_dir="E:/IDEProjects/AI/rx-mbt"`、`level=6`。

**执行单元（新）**：

| 任务 | 内容 | owner | 依赖 |
|---|---|---|---|
| `T0r2` | RX-A 协议/摘要层（rhop core/digest/json_canonical/envelope/signer/integrity） | impl-core | — |
| `T0r3` | RX-B1 密码学（key/crypto/Fernet） | impl-crypto | — |
| `T0r4` | RX-B2 介质层（transport/watch/relay/online） | impl-crypto | T0r3 |
| `T0r5` | RX-C 会话/配置/交互 | impl-session | T0r3, T0r4 |
| `T0r6` | RX-D 业务层（actions/mirror/requester/executor/daemon） | impl-business | T0r5 |
| `T0r7` | RX-QA 跨平台测试 + 跨实现向量 + 终验汇报 | qa-platform | — |

## 4. reserve_scope 回执（W1）

- impl-core：`rhop/core.mbt`、`rhop/digest.mbt`、`rhop/json_canonical.mbt`、`rhop/envelope.mbt`、
  `rhop/signer.mbt`、`rhop/integrity.mbt`、`test-suit/rhop/{core,digest,json_canonical,envelope,signer,integrity}_test.mbt`
  —— 12/12 `reserved`（unregistered advisory）。
- impl-crypto：`rhop/key.mbt`、`rhop/crypto.mbt`、`test-suit/rhop_js/crypto_test.mbt`、`test-suit/rhop_js/moon.pkg`
  —— 4/4 `reserved`（unregistered advisory）。
- qa-platform：`scripts/test_all.sh`、`scripts/test_all.ps1`、`scripts/gen_conformance_vectors.py`、
  `scripts/verify_interop.py`（4/4 `reserved`，已登记路径）、`test-suit/rhop_js/fixtures/`、`fist-mbt/reports/`（unregistered advisory）。
- lead：`rhop/moon.pkg`（integration 单点所有权；已预置 env/hex/string/buffer import，避免多人写同一文件）。

## 5. 环境基线（本轮实测）

| 平台 | moon | wasm | js | native | check |
|---|---|---|---|---|---|
| Windows 11 | 0.1.20261016 | 407/407 | 411/411（PATH 前置真 node 后） | 407/407 | 0 error, 23 warnings |
| WSL Ubuntu-22.04 | 0.1.20261021 | 407/407 | 411/411（PATH 净化后） | 待脚本固化 | 0 error, 23 warnings |

当前进度（Batch A/B1/B2 落地后，Windows 全量）：wasm **488/488**、js **543/543**、native **488/488**，check 三目标 0 error。

已知坑（已写进契约 §0 与 qa 脚本要求）：
- Windows PATH 里 `...\.desktop-bin\node.cmd` 先于真 node ⇒ moon 以 cmd 批处理 spawn 长 JSON 参数被截断
  （`failed to parse args: Unterminated string in JSON`）；
- WSL PATH 含 Windows 路径 ⇒ moon 选到 `node.cmd`（Exec format error）；
- MCP server 侧 `cmd="bash"` 实际解析到 **System32\bash.exe（WSL）** 而非 Git Bash ⇒ Windows 原生 gate 记录要用
  `cmd="powershell"` + `-File scripts/test_all.ps1`（qa 实测）。

## 6. 本轮实际完成

- 契约定案（`plans/decisions/2026-10-27-rhop-vools-parity-decision.md`）。
- fist-mbt：ns `rx-rhop`、规划树 T0（24 片，作废留痕）、执行单元 T0r2–T0r7 + T0r8（monitor 修复）；
  ACL 授权 5 个身份、reserve_scope 32 条、缺陷入账 3 条（BUG-451 RANK_GATE/leaf、BUG-452 conflicts_check 缺 namespace、
  BUG-454 tx_contract 缺 namespace）。
- 执行单元进度：
  - **T0r2 / RX-A（Batch A）已完成并 verify**：12 文件，88/92/88 三目标全绿；checksum/to_rhop_bytes 与 vools fixture 逐字节一致；
    signer 双口径（envelope ensure_ascii=False / signer ensure_ascii=True）用 unicode_result fixture 锁死。
  - **T0r3 / RX-B1（Batch B 前段）已完成并 verify**：Fernet 与 vools VText 双向互操作实测（Python 密文 MoonBit 解、MoonBit 密文 Python 解），27/27。
  - **T0r4 / RX-B2（Batch B 后段）已完成并 verify**：7 产品文件 + 51 条 js 测试；LocalSharedPath 原子写、Endpoint 三态、
    selector 三档、watch 复用 @monitor、Relay 子进程真实 A→C→B 回环、Git/Sftp 降级；全量 488/543/488 全绿。
  - **T0r7 / RX-QA**：scripts/test_all.sh + test_all.ps1 + fixtures 生成器 + verify_interop.py；两平台实测全绿（415 时点），
    跨实现互操作 4/4 PASS；终验待 T0r6 完成后收口。
  - **T0r5 / RX-C**：impl-session 已 spawn 开工。
  - **T0r8 / RX-FIX1**：monitor/watcher_js.mbt 的 BigInt/number 键不匹配导致 fs.watch 句柄泄漏（真实上游缺陷，impl-crypto 定位），
    已派单给 impl-crypto 修复。

## 7. 执行中发现的项目级缺陷（已记录/派单）

| # | 位置 | 症状 | 处置 |
|---|---|---|---|
| 1 | FIST-Mbt claim RANK_GATE | 用 task.level 判级忽略 is_leaf，叶子任务 Executor 永久不可领 | BUG-451（FIST-Mbt 账本），本项目改用 level=6 执行单元 |
| 2 | FIST-Mbt conflicts_check | 缺 namespace 参数，非 default ns 恒 not found | BUG-452 |
| 3 | FIST-Mbt tx_contract | 缺 namespace 参数，给出与 get 相反的结论 | BUG-454 |
| 4 | monitor/watcher_js.mbt | `__rxmbt_watch_reg` number 键 vs stop 传入 BigInt ⇒ close 恒不执行、句柄泄漏、node 测试挂住 | T0r8 派单修复 |
| 5 | 流程 | task_plan_deep 从 level=0 根生成的叶子为 level=2（师长），与「叶子恒为士兵」文档矛盾 | 归入 BUG-451 |
| 6 | 流程 | task_plan_deep 生成的 project_dir="." 按 server cwd 解析到 FIST-Mbt，run_check/validate 指错仓库 | 本项目改用绝对 project_dir；已在任务树说明 |
| 7 | 流程 | MCP 无「给既有任务开启 Omega 强验证」入口，重建任务丢失 omega:required | 本轮如实记为偏差，不伪造 omega 回执 |


