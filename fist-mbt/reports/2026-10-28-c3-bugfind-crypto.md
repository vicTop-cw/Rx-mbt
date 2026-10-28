# C3 互操作盲区审计（impl-crypto 域：crypto / 介质 / rhop_task）

- 日期：2026-10-28
- 方式：只读审计（对照 `E:\IDEProjects\AI\vools\rhop\vools\rhop` 真实源码）+ 一次真实 Python vools 双向互读实测
- 平台：Windows 11 / node v25.2.1 / moon 0.1.20261016；WSL2 Ubuntu-22.04 / node v25.2.1 / moon 0.1.20261021

## ① 与 vools 的错误语义 / 字面量差异

| 面 | vools 行为 | MoonBit 现状 | 判定 |
|---|---|---|---|
| `VerifyResult.reason` 四态 | `OK` / `MALFORMED` / `BAD_TOKEN` / `NOT_JSON` | **同四态、同字面量** | ✅ 一致 |
| `decrypt_verify` 的 BAD_TOKEN 启发 | 解密后明文若以 `F:`/`E:`/`A:` 开头也算 BAD_TOKEN（VText 回退原文的痕迹） | `decrypt_verify` 无此前缀启发（明文非 JSON ⇒ `NOT_JSON`）；`decrypt_secret` **有** | ⚠️ 边缘差异：合法 Fernet 明文恰以 `F:` 开头时会分到 NOT_JSON。**已文档化**，实际不可达（我方 encrypt_json 永远产出 JSON 对象） |
| `decrypt_secret` 三种错误 | ① 前缀不符 → ValueError（含"明文请直接填明文区"）；② **前缀后为空 → 返回 `""` 不报错**；③ 密钥不符/篡改 → ValueError（含 `: %s` 原因） | ① 前缀不符 → Err（同语义，文案不同）；② **空 token → Err**（有意偏差）；③ Err（含 `: {e}`） | ⚠️ ②是**有意偏差**：空密文几乎总是配置事故，静默返回空串会让下游误当"明文就是空"。已在 T0r3 交付说明与本报告双处记录 |
| relay 协议码 | `/health` 200（不校验 token）；PUT `/pkg/<n>` 201；GET 200（取走即删）；坏 token 403；坏文件名 400；无包 404 | **完全一致**（有断言：403/400/404/201/200） | ✅ 一致 |
| watch 坏文件处理 | 无"坏文件计数"概念；**失败结果也会回调** `on_packet(filename, result)`（含 ok=False） | **跳过坏文件 + 计数**，不推给订阅者 | ⚠️ **行为差异**（更严格过滤）。消费方若依赖"收到失败结果"做告警，需要读 `bad_files()`。已文档化 |
| `payload_sha` | 明文载荷的 sha256 | **同语义**（另加 `verify_payload_sha`：能解密就按明文比对） | ✅ 一致 + 增量 |

## ② 心跳 B1/B2 的真实字节级互读验证（**已实测通过**）

当前工作树中 B1（双格式兼容读 + vools 同形纯文本写）与 B2（`max_future_skew_sec` fail-closed）**已实现**，本轮补的是"是否真的能互读"的证据：

- 新增用例 `task_heartbeat_test.mbt: heartbeat · 与真实 Python vools 字节级双向互读（C3 互操作）`
- helper：`test-suit/rhop_task/fixtures/hb_interop.py`（调用**真实 vools** `Heartbeat`，非模拟）
- 双向结果（Windows，Python 3.13 + vools 0.9.0）：
  - **Python → MoonBit**：vools 写出 `2026-10-28T…Z <worker>`（纯文本、带微秒），MoonBit `read()` 解析出 `worker_id=python-vools-worker`、`ts` 含 `T`、`closed=false`、`epoch>0`，且 `is_alive()==true`
  - **MoonBit → Python**：MoonBit `beat(include_worker=true)` 写出同形纯文本（断言不以 `{` 开头），vools `Heartbeat.read()` 判定 **`state=alive`**、`worker_id=moonbit-worker`
- 环境缺 python / vools 时**软跳过**并打印原因（不影响 CI 判绿）
- 注解：vools `include_worker` 默认 **False**（只写时间戳）；我方 `beat` 亦默认 false，需要 worker 字段时显式 `include_worker=true` —— 两侧默认一致，无差异

## ③ 结果截断 schema 与 `payload_sha`

- `payload_sha`：✅ 语义一致（明文 sha256）。
- **结果截断：原本是真实 schema 分歧，本轮已对齐**：
  - vools `_shrink_result_to_bytes`：在**结果节点上**加 `truncated: true` + `truncate_hint: "结果超过 result_max_bytes，已截断；大结果请写文件并用 payload 里的引用路径回传。"`，两阶段降级（先裁 `stdout`/`stderr` 到 2000 字符，仍超预算则退化为 `{truncated, truncate_hint, result_kind, result_chars, result_head}` 紧凑摘要）
  - 我方原实现：`{"__truncated__": true, "limit_bytes": N, "head": "…"}` —— **键名与 vools 不同**，Python 消费方按 `result["truncated"]` 判断会漏判
  - 本轮修复：改为 **vools 同名字面量** `truncated` + `truncate_hint`（提示文案逐字一致），保留 `result_chars`/`result_head` 作诊断补充
  - 已文档化的简化：我方是**单阶段** head 截断，vools 是两阶段（字段级裁剪 + 紧凑摘要）。语义等效（都不超 `result_max_bytes` 且都标记 `truncated`），但长 `stdout` 场景下 vools 保留的结构更多

## ④ `task_store` 31 列 vs vools schema 逐列核对（**完全一致**）

用脚本从两侧源码抽取列定义后做精确 diff：

```
vools 列数=31 ; 我方列数=31 ; diff 行数 = 0
```

- 覆盖：`task_id / task_name / task_type / value / deps / state / priority / timeout_min / retry_delay_min / retry_count / max_retries / scheduled_at / worker_id / lock_time / expire_time / start_time / end_time / cancel_requested / version / payload_enc / payload_sha / back_info / last_err / tags / queue / owner / team / group_name / extra_desc / created_at / updated_at`
- **名称、顺序、类型（INTEGER/TEXT/REAL）、NOT NULL/UNIQUE/默认值、state 的 CHECK 枚举** 全部逐字一致
- 我方额外建 `tasks_executions` / `tasks_sync_log` 两表（vools 侧 sync_log 在 sync 模块；executions 我方建表未写入，属已知缺口 A3，见 C2 报告）

## ⑤ 测试临时目录前缀归属（`%TEMP%` 卫生审计）

Windows 实测残留（审计时刻，共 40 个 `rhop-*`）：

| 前缀 | 数量 | 归属 | 说明 |
|---|---|---|---|
| `rhop-git-*` | 13 | **非我域** | 未静态定位到创建点（建议对应 owner 自查） |
| `rhop-html-*` | 9 | **非我域** | 同上 |
| `rhop-it-*` | 4 | impl-session | `test-suit/rhop_interact/interact_test.mbt` 的 `it_dir(...)` |
| `rhop-actions-root-*` | 2 | **非我域** | actions 相关（impl-business 域） |
| `rhop-sftp-root-*` | 2 | **非我域** | sftp 相关 |
| `rhop-relay-*` | 1 | **我域** | 我是 `rhop/relay.mbt` 的 `unique_tmp_path`；该残留是 **C2 BUG-1 修复前**遗留（已清理） |
| `rhop-hb-interop-*` | 2 | **我域** | 本轮新增互操作用例的临时目录；来自**修复前那次失败运行**（已清理） |

- 我域前缀全清单：`rhop-t*`（transport）/`rhop-w*`（watch）/`rhop-task-*`（config）/`rhop-store`/`rhop-queue`/`rhop-sync-*`/`rhop-hb*`/`rhop-relay*`
- 审计结论：**成功路径下我域一直是 0 残留**（用例末尾 `rmrf`）；泄漏只发生在**断言失败跳过 rmrf** 的路径 —— 与 QA C2-V1 观测（每轮 +121 个）是同一类问题的不同来源
- 处置：我域 8 个 `mkdtemp` FFI 全部注入 **exit hook**（见修复报告），并清掉历史残留

## 汇总

| 项 | 结论 |
|---|---|
| ① 错误语义 | 4 态字面量、relay 协议码 ✅ 一致；3 处**已文档化差异**（`decrypt_verify` 前缀启发 / `decrypt_secret` 空 token 报错 / watch 坏文件不回调） |
| ② 心跳互读 | ✅ **真实 vools 双向字节级互读通过**（新增自动化用例，可重复执行） |
| ③ 截断 schema | ⚠️→✅ **本轮已对齐**（`truncated`/`truncate_hint`），单阶段 vs 两阶段已文档化 |
| ④ 31 列 | ✅ **diff=0**，含类型/默认值/CHECK |
| ⑤ temp 归属 | 我域 3 个历史残留已清理；8 个 mkdtemp 已加 exit hook；非我域前缀已列表移交 |
