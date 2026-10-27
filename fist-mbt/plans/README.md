# 计划治理流程

本目录（`fist-mbt/plans/`）是团队的**计划治理中枢**。所有计划从提案到归档
走一条固定链路，保证"谁决定、何时决定、决定什么"全程可追溯。

## 流程：提案 → 定案 → 执行 → 归档

1. **提案（Proposal）**：在 `plans/` 新建 `NNNN-<slug>-proposal.md`，
   用 `_template-proposal.md` 起稿。状态为 `draft`。
2. **定案（Decision）**：`human_steward` 审阅后，把文件移动/落定到
   `plans/decisions/`，YAML 头补全 4 字段（见硬规则 1），状态为 `decided`。
3. **执行（Execution）**：拆解出的子任务在 fist-mbt 任务库推进，
   每份执行汇报放 `fist-mbt/reports/`（见硬规则 3）。
4. **归档（Archive）**：执行完毕、结论沉淀后，把计划文件移入
   `plans/archived/`，状态为 `archived`。归档保留可追溯，不删除。

## 4 条硬规则

- **规则 1 · YAML 头 4 字段**：每份计划文件顶部必须含
  `status` / `decided_by` / `decided_at` / `decision` 四字段，
  缺一即视为未定案，不得进入执行。
- **规则 2 · plans/ 专放计划**：`plans/` 及其子目录只放计划文件
  （提案 / 定案 / 归档）。执行汇报、任务清单一律不放这里。
- **规则 3 · reports/ 只放执行汇报**：`fist-mbt/reports/` 只放执行汇报
  （`YYYY-MM-DD-<任务名>-report.md`，用 `_template-report.md` 起稿），
  不放计划、不放源代码、不放临时笔记。
- **规则 4 · 定案权仅 human_steward**：只有 `human_steward` 可以把
  计划置为 `decided` / `archived`。其他角色（含 agent / leader）只可
  提案与执行，不可定案、不可归档。

## 占位模板

- 提案模板：`plans/_template-proposal.md`
- 执行汇报模板：`reports/_template-report.md`
- 规范文档模板：`docs/_template-standard.md`
