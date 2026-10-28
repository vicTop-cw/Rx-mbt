# 2026-10-28 · fist-mbt 【寻虫-修复-打磨-验证-清整】组合模式 × 3 轮 · 执行计划

- 目标（用户原话）：使用 fist-mbt 【寻虫-修复-打磨-验证-清整】组合模式跑 3 轮（1 个组合 = 1 轮）
- 适用对象：本会话新增/修改的全部代码与资产（`rhop/`、`rhop_task/`、`monitor/watcher_js.mbt`、
  `test-suit/rhop*`、`scripts/`、README/DOC/矩阵/报告）
- 模式定义来源：`E:\IDEProjects\AI\FIST-Mbt\templates\pipeline_mode_{bugfind,fix_and_merge,polish,verify,tidy}.md`
- **环境限制（如实记录）**：本轮 toolset 未暴露 `mcp__fist-mbt__*` MCP 工具（`mode_list`/`publish`/
  `claim`/`run_check`/`output_validate`/`submit` 均不可用）。本计划以「模式模板约束 + 本地等价证据链」
  执行：每个模式产出**可复核文件 + 真实命令输出 + git 提交**，替代 MCP 的 output_validate/submit。
  MCP 恢复后补登任务流水。

## 0. 组合轮次定义

每一轮（C1/C2/C3）严格按顺序跑 5 个模式，前序模式不通过不得进入下一模式：

| 步骤 | 模式 | 职责 | 交付物（硬性） |
|---|---|---|---|
| 1 | 寻虫 `bugfind` | 只读扫描，产出**可复现/有代码证据**的 issue 清单（禁止臆造） | `fist-mbt/reports/YYYY-MM-DD-c<N>-bugfind.md` |
| 2 | 修复 `fix_and_merge`（本地适配：无 GitHub token，改为本地修复 + git 提交） | 修复 issue 池，保持公开 API 签名；每修一处补回归测试 | `fist-mbt/reports/YYYY-MM-DD-c<N>-fix.md` + commit |
| 3 | 打磨 `polish` | 不新增功能：重构/补测试/性能/可读性；禁发布新功能 | `fist-mbt/reports/YYYY-MM-DD-c<N>-polish.md` + commit |
| 4 | 验证 `verify` | API 枚举/文档自洽/双平台四步 gate/互操作；对交付物逐条核验 | `fist-mbt/reports/YYYY-MM-DD-c<N>-verify.md` + 汇总行 |
| 5 | 清整 `tidy` | 清 dead code/废弃 API/临时产物/过期文档/看板残留；禁新增代码 | `fist-mbt/reports/YYYY-MM-DD-c<N>-tidy.md` + commit |

**每轮判绿硬门（同 verify 模板）**：
- `moon check` 三目标 0 error
- `scripts/test_all.sh`（Windows Git Bash）+ WSL 版本均 `RESULT: PASS`（四步贯穿）
- `scripts/verify_interop.py --strict` PASS
- `moonfmt` 幂等（`needs_format=0`）
- git 工作树干净，每步有 commit

## 1. 分工（指挥官不下工地）

| 角色 | 承担 |
|---|---|
| Lead | 组合编排、issue 裁决（修/不修/延后）、验收判绿、git 提交、报告汇总、goal 记账 |
| `bugfind-scout-*`（fresh subagent） | 寻虫扫描（语义差异 / 静态质量与测试质量），只读 |
| `qa-platform` | 测试设施/跨平台/脚本/互操作性寻虫 + 每轮 verify 终验 |
| `impl-core` | rhop 协议/摘要/文档类修复与打磨；verify 独立复核 |
| `impl-crypto` | 密码学/介质/心跳/rhop_task 修复与打磨 |
| `impl-session` | 会话/配置/交互修复与打磨 |
| `impl-business` | 业务层/镜像/sqlite/清整 |

## 2. 三轮主题（递进，避免重复劳动）

| 轮次 | 寻虫重点 | 修复重点 | 打磨重点 | 清整重点 |
|---|---|---|---|---|
| C1 | 语义保真度：与 vools-rhop 源码逐函数对照（错误语义、静默降级、边界）；测试断言强度 | P0/P1 缺陷 + 回归测试 | 弱断言/重复代码/错误文案 | 临时文件、文档数字不一致、fmt |
| C2 | 资源与并发：sqlite 句柄、子进程、timer、文件句柄、watch 挂死、双平台差异 | P0/P1 + 双平台复现缺陷 | 资源生命周期统一、超时与降级路径 | 废弃 API/死代码、看板残留、脚本重复 |
| C3 | 契约与文档一致性：API 枚举 vs .mbti vs 文档 vs 矩阵；跨实现互操作盲区 | 剩余可修缺陷 | 文档/示例/报告一致性、可读性 | 全仓清整 + 最终验收归档 |

## 3. 当前基线（C1 起点，2026-10-28 11:36 实测）

- `moon check` 三目标 0 error；项目级测试 wasm 587 / js 765 / native 587（全绿，commit `4874f8e`）
- 双平台 `scripts/test_all.sh` PASS；互操作 `--strict` 20/20；工作树干净
- 已知遗留（来自上一目标，作为 C1 寻虫输入之一）：MCP 账本未补登、`--strict` 四分节无 MoonBit 生产者、
  P2 A* 缺口、SFTP/jump 真传输未实现、`moon fmt --check` 工具面缺陷

## 4. 记录规范

- 每轮 5 个模式各一份报告；issue 编号 `C<N>-<序号>`（P0 阻塞/P1 重要/P2 一般/P3 建议）
- 每条 issue 必须含：位置、证据（代码片段/命令输出/vools 对照）、复现方式、建议修法、裁决（修/不修/延后）
- 修复必须附回归测试名；验证报告必须贴真实汇总行与 commit hash
