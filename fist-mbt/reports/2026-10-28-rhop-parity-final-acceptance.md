# 2026-10-28 · rhop ← vools-rhop 复刻 · 最终验收汇报（Lead 汇总）

- 目标（用户原话）：使用 fist-mbt [探索] 模式迭代开发 rhop，将 vools-rhop 的 API 尽量复刻到手，
  善用 fist-mbt 任何能力，复用本项目其它 API，测试 WSL 和 Windows 均通过。
- 执行契约：`fist-mbt/plans/decisions/2026-10-27-rhop-vools-parity-decision.md`
- API 对照矩阵（终版 v4）：`fist-mbt/docs/2026-10-27-rhop-vools-parity-matrix.md`
- QA 终验报告（final v2）：`fist-mbt/reports/2026-10-27-rhop-parity-report.md`
- 参考实现：`E:\IDEProjects\AI\vools\rhop`（vools-rhop 0.9.0）

## 1. 验收结论（一句话）

**通过**：Windows 与 WSL 双平台、四步 gate（check / wasm / js / native）全部 `failed: 0`；
契约范围内 API 对齐 **92.7%（178/192，含等价/部分 95.3%）**；跨实现（Python↔MoonBit）
envelope checksum 逐字节一致、Fernet 密文双向可解、心跳文件双向可读。

## 2. 终验证据（2026-10-28 11:27–11:35，代码冻结后严格串行复跑）

| 入口 | check | wasm | js | native | RESULT |
|---|---|---|---|---|---|
| Windows Git Bash（`scripts/test_all.sh`） | 0 errors | 587/587/0 | 765/765/0 | 587/587/0 | PASS（4 步） |
| Windows PowerShell（`scripts/test_all.ps1`） | 0 errors | 587/587/0 | 765/765/0 | 587/587/0 | PASS（4 步） |
| WSL Ubuntu-22.04（`_build/wsl` 隔离） | 0 errors | 587/587/0 | 765/765/0 | 587/587/0 | PASS（4 步） |

- 互操作：`verify_interop.py --strict` → **PASS=20 / FAIL=0 / SKIP=0**（16 项 fixture 自检 + 4 项
  MoonBit 产物复核）；fixture sha256 `f22dda48…` 跨平台/重复生成逐字节一致。
- 格式化：`moonfmt -w` 全量 112 文件 + 二次幂等（unstable=0）；QA 独立扫描 144 文件 `needs_format=0`。
- 编译：`moon check` 三目标 0 error。

## 3. 交付物清单（代码）

### 3.1 `rhop` 包（协议 → 业务全层）
| 层 | 文件 | 覆盖 |
|---|---|---|
| 协议/摘要 | core / digest / json_canonical / envelope / signer / integrity | Side/TaskStatus 状态机、纯 MoonBit SHA-256/MD5/HMAC/PBKDF2、Python 同形 canonical JSON（双 ensure_ascii 口径）、Envelope checksum、签名、完整性 |
| 密码学 | key / crypto | Fernet（与 vools VText 完全互操作）、RHOP-ENC、VerifyResult 三态 |
| 介质 | transport_base/local/endpoint/selector、online、relay、watch | SharedPath/Endpoint 三态、选择器、HTTP、Git/Sftp 降级、Relay 子进程中转、watch 复用 @monitor |
| 会话/配置/交互 | session / config / interact / actions | 通道链 relay>online>shared、四分支密钥、interact 三模式、动作注册表 |
| 业务/镜像 | mirror / requester / executor / daemon / sync_folder | node:sqlite MirrorDB、需求端/执行端、daemon、幂等 sync |
| 剪贴板 | clipboard | 后端探测 + ClipboardFileSync 响应式 run_forever |

### 3.2 `rhop_task` 包（vools task/ 子包复刻，契约外扩展）
- P2a：task_models / task_config / task_secrets
- P2b：task_store（node:sqlite 31 列）/ task_queue / task_heartbeat（与 vools 纯文本字节级互操作，
  `max_future_skew_sec=60` fail-closed）/ task_exec（白名单 + argv 数组，无 shell 拼接）/ task_sync
- P2 缺口如实入档：Postgres、file_channel、写退避、exec workdir/env、field-level merge、
  local_runner/task-daemon/CLI 未做（矩阵 §5.9 A 节）。

### 3.3 测试与工具
- 测试：`test-suit/rhop`（131/135/131）、`rhop_js` 52、`rhop_clipboard` 25、`rhop_interact` 13、
  `rhop_business` 10/41/10、`rhop_task` 46/99/46；全模块 **587 / 765 / 587**。
- 交叉验证：Python 生成 fixtures + `verify_interop.py` 双向复核；跨平台 `scripts/test_all.sh|ps1`。
- 文档：README（368 行×2 同步）、DOC.md（1290 行 rhop 章节）、矩阵 v4（661 行）。

## 4. 复用本项目其它 API（非重造）

`@rx.Observable/Subject/Observer/Subscription`（watch/interact/clipboard 周期流）、
`@monitor.watch_folder`（watch）、既有 `RhopPacket/RhopCipher/rhop_js` FFI 风格、
`RhopCrypto`（rhop_task 加解密）、`sha256_hex_of_utf8`（P2 摘要）、`SharedPath` 原子写（P2 心跳）。

## 5. fist-mbt 执行留痕

- 命名空间 `rx-rhop`；任务树：规划树 T0（24 片，作废留痕）+ 执行单元 T0r2–T0r14 全部 verify；
  T0r15（心跳互操作）、T0r16（文档收口）在 MCP 工具缺失期间完成，待工具恢复后补登。
- explore 模式：复杂度打分/选模/并行四门记录见 `2026-10-27-explore-round1-report.md`；
  reserve_scope 32 条；缺陷入账 BUG-451/452/454（FIST-Mbt 账本）。
- 工具面事实（已记入 QA 报告 §8）：`conflicts_check`/`tx_contract` 缺 namespace；
  claim RANK_GATE 忽略 is_leaf；MCP 后续轮次不可用（run_check/output_validate 最后由 Lead 侧实测替代）；
  `moon fmt` 子命令本机 program not found（用 `moonfmt -w` 等价）。

## 6. 遗留（不影响验收）

1. T0r7（QA 终验任务）已 submit 待 verify、T0r15/T0r16 未入账 —— MCP 工具恢复后补齐。
2. 规划树 T0 及 24 个规划片仍在看板（作废标记），待工具恢复后归档。
3. `verify_interop.py --strict` 的 canonical/digest/envelope/signer 四分节暂无 MoonBit 侧产物生产者
   （现为「fixture 被 MoonBit 测试硬引用 27/34=79.4% + MoonBit 产物被 Python 复核 20/20」双向合成）。
4. vools 未复刻/未接线项见矩阵 §5.9 A/B（Postgres、file_channel、写退避、exec workdir/env、
   field-level merge、CLI/daemon/local_runner、shell=true 不支持等）。
5. SFTP/Git 远端文件操作、jump 真传输未实现（无 SSH 客户端；dry_run/计划计算为真实实现）。

## 7. 版本与提交

代码冻结于提交 `6d9a50f`（心跳 B1/B2 关闭）；随后 `3a56a8c`（文档 v4）、`4e2fe67`（QA final v2）。
工作树干净（`git status` 空）。
