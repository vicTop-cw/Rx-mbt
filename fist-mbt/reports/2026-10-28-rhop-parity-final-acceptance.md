# 2026-10-28 · rhop ← vools-rhop 复刻 · 最终验收汇报（Lead 汇总 · C1–C3 终版）

- 目标（用户原话）：使用 fist-mbt [探索] 模式迭代开发 rhop，将 vools-rhop 的 API 尽量复刻到手，
  善用 fist-mbt 任何能力，复用本项目其它 API，测试 WSL 和 Windows 均通过。
- 追加指令：fist-mbt【寻虫-修复-打磨-验证-清整】组合模式 × 3 轮（C1/C2/C3，每轮 5 模式）。
- 执行契约：`fist-mbt/plans/decisions/2026-10-27-rhop-vools-parity-decision.md`
- 组合模式计划：`fist-mbt/plans/2026-10-28-combo-3-cycles.md`
- API 对照矩阵（终版 v5）：`fist-mbt/docs/2026-10-27-rhop-vools-parity-matrix.md`
- QA 终验报告：`2026-10-28-c3-verify.md`（另附 C2 verify）+ `2026-10-27-rhop-parity-report.md`
- 参考实现：`E:\IDEProjects\AI\vools\rhop`（vools-rhop 0.9.0，Python）

## 1. 验收结论

**通过**。Windows 与 WSL 双平台、三入口（Git Bash / PowerShell / WSL）× 四步 gate（check/wasm/js/native）
全部 `failed: 0` 且数字逐字一致；契约范围内 API 对齐 **92.2%（178/193，含等价/部分 94.8%）**；
P2 `rhop_task`（task/ 子包，契约外扩展）已落地；跨实现互操作 **47/47 PASS**（含负向证据）；
组合模式 C1/C2/C3 三轮闭环（P1 缺陷全部修复并有回归测试）。

## 2. 终验证据（2026-10-28 15:44–15:53，代码冻结后严格串行）

| 入口 | check | wasm | js | native | RESULT |
|---|---|---|---|---|---|
| Windows Git Bash（`scripts/test_all.sh`） | 0 errors | **612/612/0** | **825/825/0** | **612/612/0** | PASS（4 步） |
| Windows PowerShell（`scripts/test_all.ps1`） | 0 errors | 612/612/0 | 825/825/0 | 612/612/0 | PASS（4 步） |
| WSL Ubuntu-22.04（`_build/wsl` 隔离） | 0 errors | 612/612/0 | 825/825/0 | 612/612/0 | PASS（4 步） |

- 互操作：`python scripts/verify_interop.py fist-mbt/reports/moonbit_vectors_full.json --strict --require-negative`
  → **PASS=47 / FAIL=0 / WARN=0 / SKIP=0**；覆盖 canonical/digest/envelope（含 tampered 负向）/crypto/signer 五分节
  - Python vools 生成 fixture → MoonBit 解密/复算 checksum/签名；MoonBit 产物 → Python vools 复核
  - 心跳文件与 vools **字节级双向互读**（真实 vools 用例，缺 python 时软跳过）
  - fixture sha256 `f22dda48…` 跨平台/重复生成逐字节一致
- 格式化：`moonfmt -w` 全量 89 文件 + 二次幂等（`needs_format=0`）；README 两份 diff 为空
- 工作树干净；版本 `0.4.0`

## 3. API 复刻账（矩阵 v5）

| 口径 | 符号 | ✅ | 🟡 | ⚠️ | ⛔ | 覆盖率 |
|---|---:|---:|---:|---:|---:|---|
| 契约范围 A–D+clipboard | **193** | 178 | 4 | 1 | 10 | **92.2%**（含等价/部分 94.8%） |
| vools 全量（含 task 264） | **472** | 179 | 25 | 1 | 267 | 37.9%（含等价/部分 39.0%） |

- Batch A 协议/摘要（core/digest/sha256/md5/hmac/pbkdf2、canonical JSON 双 ensure_ascii 口径、Envelope checksum、Signer、Integrity）
- Batch B 密码学/介质（Fernet 与 vools VText **完全互操作**、RHOP-ENC、transport/endpoint/selector、watch 复用 @monitor、Relay 子进程中转、Git/Sftp 降级）
- Batch C 会话/配置/交互（Role/Session 通道链、RhopConfig 四分支密钥、interact 三模式 + roundtrip）
- Batch D 业务层（MirrorDB node:sqlite 乐观锁、Requester/Executor、RelayDaemon、SyncFolder、actions 全族 + jump 离线计划）
- clipboard（后端探测 + ClipboardFileSync 响应式 run_forever）
- P2 `rhop_task`（TaskState/TaskConfig/Secrets + TaskStore/TaskQueue/Heartbeat/ExecPolicy/TaskSync；31 列 schema 与 vools 逐列一致）

## 4. 组合模式三轮成果

| 轮次 | 主题 | 关键成果 |
|---|---|---|
| C1 | 语义保真与测试强度 | PROTO-01（to_rhop_bytes 不重算 checksum，P1）、业务 6 条 P1、会话 F1/F4/F5、QA F1–F6 全修；tests 587→600/765→792 |
| C2 | 资源与并发 | canonical 深嵌套迭代化（20000 层稳定）、PBKDF2 **3× 加速**、relay 端口握手竞态（P1）、watch 丢消息（P1）、daemon 消费幂等守卫（P0）、符号链接爆炸（67k→1）、分块摘要（RSS 256MB→1MB）、跨平台锁偷锁（P1）、孤儿清理 pattern；tests 600→612 / 792→819 |
| C3 | 契约与文档一致性 | 551 符号三方对照、计数修正 193/264/472、DOC 补 68 符号 + 3 文件、生产者负向例补齐（互操作 46→47）、心跳/截断 schema 对齐 vools、测试 temp 卫生 +121/轮→0；tests 819→825 |

## 5. 复用本项目其它 API（非重造）

`@rx.Observable/Subject/Observer/Subscription`（watch/interact/clipboard 周期流）、`@monitor.watch_folder`（文件监控）、
既有 `RhopPacket/RhopCipher/rhop_js` FFI 风格、`RhopCrypto`（rhop_task 加解密）、`sha256_hex_of_utf8`、
`SharedPath` 原子写（P2 心跳）、`rhop_temp_workspace` 退出钩子（测试卫生）。

## 6. 已知缺口与有意偏差（矩阵 §5.9 A/B、§7 34 条）

- 未实现/未接线：Postgres 后端、`queue.file_channel`、`tasks_executions` 写入、`write_retries` 退避、exec workdir/env/shell:true、field-level merge、local_runner/task-daemon/CLI。
- 有意差异：`decrypt_verify` 无 `F:/E:/A:` 启发、`decrypt_secret` 空 token 报 Err、watch 坏文件跳过+计数、
  截断单阶段、`shell=true` 不支持（安全取舍）、canonical 浮点不保证逐字节（语料限定 int/string/bool/null/嵌套）、
  `jump.push/pull/sync` 真传输 unsupported（无 SSH 客户端；dry_run/计划计算为真）。
- 工具面：`moon fmt` 子命令本机 `program not found`（用 `moonfmt -w` 等价）；MCP fist-mbt server 后半程断连，
  `run_check/output_validate/submit` 无法补登（T0r7 终验任务停在「待验收」，C2/C3 轮未入账）——
  证据链以本报告 + 各轮 verify 报告 + git 提交为准。

## 7. 提交与复现

- 版本：`moon.mod` → **0.4.0**
- 关键提交：`6d9a50f`(心跳互操作) → `005fcc4`(C2) → `21323b4`(C3) → 本轮终版提交（文档/版本/报告）
- 复现：
  ```bash
  bash scripts/test_all.sh                      # Windows Git Bash（或 WSL，脚本自动判平台）
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_all.ps1
  python scripts/verify_interop.py fist-mbt/reports/moonbit_vectors_full.json --strict --require-negative
  ```
- fist-mbt 留痕：ns `rx-rhop`，执行单元 T0r2–T0r14 全部 verify；规划树 T0 已标 SUPERSEDED；
  缺陷入账 BUG-451/452/454（FIST-Mbt 账本）。
