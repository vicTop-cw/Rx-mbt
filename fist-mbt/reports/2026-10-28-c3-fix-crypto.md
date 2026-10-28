# C3 修复与验证报告（impl-crypto 域）

- 日期：2026-10-28
- 对应审计：`2026-10-28-c3-bugfind-crypto.md`
- 纪律：未改任何公开 API 签名、未新增业务功能、全部 moon 命令走 `bash scripts/with_moon_lock.sh`、格式化 `moonfmt.exe -w`

## 一、改动清单

| # | 类型 | 文件 | 改动 | 证据 |
|---|---|---|---|---|
| 1 | 互操作修复 | `rhop_task/task_queue.mbt` | 结果截断 schema 由自定义 `__truncated__/limit_bytes/head` **对齐为 vools 键名** `truncated` / `truncate_hint`（提示文案逐字一致），保留 `result_chars`/`result_head` 作诊断 | `task_queue_test.mbt` 截断用例断言 `"truncated":true` + `truncate_hint` |
| 2 | 互操作验证 | `test-suit/rhop_task/task_heartbeat_test.mbt`（+1 用例） | 新增「与真实 Python vools 字节级双向互读」用例（Python→MoonBit、MoonBit→Python 双向断言；缺 python/vools 软跳过） | 见下方实测输出 |
| 3 | 互操作 helper | `test-suit/rhop_task/fixtures/hb_interop.py`（新增） | 调用**真实 vools** `Heartbeat` 写/读心跳文件，输出单行 JSON 供 MoonBit 断言 | 同上 |
| 4 | 卫生修复 | `test-suit/rhop_js/*.mbt`、`test-suit/rhop_task/*.mbt`（8 处 `mkdtemp` FFI） | 全部注入 **exit hook**：`mkdtemp` 创建即登记到 `globalThis.__rxmbt_tmp_reg`，`process.on("exit")` 统一 `rmSync(recursive,force)`（幂等；成功路径的显式 `rmrf` 不受影响） | 见下方 hook 机制探针 + temp delta |
| 5 | 清整 | `%TEMP%` 我域历史残留 3 个（`rhop-relay-*`×1、`rhop-hb-interop-*`×2） | 手工清除（均为 C2 修复前/失败路径遗留） | 清理后我域残留 = 0 |

> 说明：心跳 B1（双格式兼容读 + vools 同形纯文本写）与 B2（`max_future_skew_sec` fail-closed）**在当前工作树中已实现**（非本轮新增）；本轮补的是**可重复执行的字节级互读证据**。

## 二、exit hook 机制验证（不是"看起来对"）

用与 FFI 完全相同的 JS 片段做探针，故意**不调 rmrf** 直接退出：

```
创建: C:\Users\victo\AppData\Local\Temp\rhop-hookprobe-suEfzd
结果: 目录已被 exit hook 清理（✅ 机制有效）
```

## 三、临时目录 delta（Windows，单轮）

| 时点 | 全部 `rhop-*` | 我域前缀 |
|---|---|---|
| 全量 js 套件跑之前 | 27 | 1（历史残留，已清） |
| 跑之后 | 27 | 1 |
| **delta** | **0** | **0** |

- 说明：我域**成功路径本来就是 0 残留**（用例末尾 `rmrf`）；本轮 exit hook 的价值在**断言失败路径**——此前失败会跳过 `rmrf` 造成泄漏（本轮实测到的 `rhop-hb-interop-*`×2 就是证据），现在由 exit hook 兜住。
- 非我域残留（`rhop-git-*`×13、`rhop-html-*`×9、`rhop-actions-root-*`×2、`rhop-sftp-root-*`×2、`rhop-it-*`×4）已在审计报告 ⑤ 列表移交对应 owner。

## 四、双平台验证汇总行

### Windows 11 / moon 0.1.20261016 / node v25.2.1
```
check rhop      wasm/js/native → 0 errors (123/99/125 warnings)
check rhop_task wasm/js/native → 0 errors (195/147/197 warnings)

moon test -p test-suit/rhop_js   --target js → 56/56/0   （C2 轮已含 5 连自然退出）
moon test -p test-suit/rhop_task --target js → 102/102/0
moon test -p test-suit/rhop_task --target wasm → 46/46/0
全量 wasm 612/612/0 · js 825/825/0 · native 612/612/0
```

### WSL2 Ubuntu-22.04 / moon 0.1.20261021 / node v25.2.1
```
check rhop      wasm/js/native → 0 errors (123/99/125 warnings)
check rhop_task wasm/js/native → 0 errors (195/147/197 warnings)

moon test -p test-suit/rhop_js   --target js → 56/56/0  ×5 全 exit=0（18~25s，竞态失败 0/5）
moon test -p test-suit/rhop_task --target js → 102/102/0 ×3 全 exit=0
moon test -p test-suit/rhop_task --target wasm → 46/46/0 · native → 46/46/0
全量 wasm 612/612/0 · js 825/825/0 · native 612/612/0
```

判据：**自然退出（exit=0 + 打印汇总行）**，未用 `timeout` 杀进程。

## 五、本次新增/修改的用例数

| 包 | 前 | 后 | 增量 |
|---|---|---|---|
| `test-suit/rhop_js` | 56 | 56 | 0（本轮无新增，仅注入 exit hook） |
| `test-suit/rhop_task` | 101 | **102** | +1（Python vools 双向心跳互读） |

## 六、遗留（如实）

- `decrypt_verify` 缺 vools 的 `F:/E:/A:` 前缀启发：属不可达边缘（我方加密必产 JSON），**文档化不修**。
- `decrypt_secret` 空 token 返回 Err（vools 返回 `""`）：**有意偏差**，可诊断性优先。
- watch 坏文件"跳过 + 计数"而非 vools 的"回调失败结果"：**有意偏差**，已文档化。
- 结果截断单阶段（vools 两阶段）：键名已对齐、语义等效，**粒度差异文档化**。
- `tasks_executions` 表仍建而未写、`write_retries` 退避仍未接线（C2 已登记，属功能缺口）。
