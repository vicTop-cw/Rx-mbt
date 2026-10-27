---
status: draft
decided_by: ""
decided_at: ""
decision: ""
---

# 2026-10-26-rhop-api-align 计划提案：rx-mbt rhop 复核 vools-rhop 并 API 对齐

## 背景

- 4 池子建设（DEC 治理基线）依赖 rx-mbt 的 rhop 作为传输底座，但 rx-mbt/rhop 目前仅实现
  cipher / packet / 单通道读写 + 文件监控雏形，与成熟参考 vools-rhop（Python，MVP-1/2/3
  全实现，18/18 测试通过）存在明显 API 面差距。
- 上游计划 `FIST-Mbt/docs/plans/2026-10-26-4pools-rhop-roadmap-proposal.md`（阶段二）已定
  向：对照 vools-rhop 补齐 rx-mbt rhop。本文档是阶段二的执行级细化计划，重点为**API 对齐
  清单**（逐模块映射 vools-rhop → rx-mbt）与**执行顺序**。
- 本次开工指令：先写本计划，再全程使用 fist-mbt 探索模式（explore）执行，开关类全开
  （task_plan_deep: gradient/gradient_dag/boundary_probe/reinject_context/calibrate/
  omega_strong_verify 全 ON；claim inject ON；watchdog phi_gate+autodispatch ON；
  reserve_scope+conflicts_check ON）。

## 目标

1. 逐模块盘点 vools-rhop 公开 API，映射到 rx-mbt/rhop，输出可核对的对齐清单（本文档 §方案）。
2. 分 3 批完成 P0/P1 API 对齐，P0 完成后 `moon test` 全绿（js 目标），对照 vools-rhop
   判据 1-5 至少通过 1/2/4。
3. 全程以 fist-mbt 探索模式驱动（复杂度选模、并行域判定），每批产出执行汇报到
   `rx-mbt/fist-mbt/reports/`。

## 方案

### A. vools-rhop 公开 API 盘点（复核基线，2026-10-26 实测）

| 模块 | 公开 API | 说明 |
|---|---|---|
| core.py | `Side`(REQUESTER/EXECUTOR, `other()`)；`TaskStatus`(PENDING/CLAIMED/RUNNING/DONE/FAILED/CANCELLED, `can_transition()`/`is_terminal()`) | 状态机与角色 |
| crypto.py | `ENV_RHOP_KEY`、`SECRET_PREFIX="RHOP-ENC:"`、`VerifyResult(ok/payload/reason)`；`load_key(source/path/env_name)`；`is_secret(value)`；`RhopCrypto.encrypt_json/decrypt_verify/encrypt_secret/decrypt_secret/from_key/from_path/from_env` | 密钥派生+加密/解密验证一体，输出 `{"v":1,"alg":"fernet","ct":...}` |
| envelope.py | `Envelope(task_id/status/payload/result/error/side/version/created_at/updated_at/hops_seen/signature/checksum)`；`to_rhop_bytes/from_rhop_bytes/to_dict/from_dict`；checksum=sha256(payload+元数据) | 任务级信封，.rhop 内层 |
| signer.py | `AbstractSigner.sign/verify`；`FileHashSigner`(sha256:<hex>)；`NPUSigner`(NPU_MARKER:<serial>:<md5>) | 结果签名 |
| integrity.py | `IntegrityChecker.verify(env,raw_bytes)/verify_bytes/checksum_match` | 完整性校验 |
| watch.py | `RhopWatcher(fd,path,on_packet,...)` `start/stop`；skip_existing 语义 | 文件监控触发器 |
| transport/base.py | `OnlineChannel.available/send/receive`；`SharedPath.available/write_text/read_text/exists/remove`；`TransportSelection` | 在线/离线通道抽象 |
| transport/endpoint.py | `EndpointView`；`LocalEndpoint(path)`；`FileUrlEndpoint(url)`；`HttpEndpoint(base_url,token,timeout,probe)`；`parse_endpoint` | 多端视图 |
| transport/local.py | `LocalSharedPath(root)` | 本地 shared path |
| transport/online.py | `GitChannel`；`SftpChannel`；探测函数 | 在线通道 |
| transport/relay.py | `RelayServer(host,port,token,ttl)` `url/start/stop/alive/__enter__/__exit__`；`RelayChannel(host,port,token,timeout,probe)` | MVP-3 中转 |
| transport/shared.py | `SharedPathView(write_view,read_view)`；`make_shared_path(write_spec,read_spec)` | 读写分离视图 |
| transport/selector.py | `select_transport(...)` | 在线优先/离线回退 |
| session.py | `Role`(SEND/RECV)；`Session.send_package/recv_package/reverse/describe/available` | 会话封装 |
| interact.py | `interact(cfg,action,payload,mode=execute/request/roundtrip,request_filename)`；`handle_request(cfg,filename,session)` | 配置驱动一键交互 |
| config.py | `RhopConfig(key_cfg/channels/shared/relay/session/actions)` `from_dict/from_file/to_dict/build_crypto/build_online/build_shared/build_relay/build_session/action_cfg`；`load_config`；`_key_from_cfg` | 配置归一 |
| mirror.py | `MirrorDB.upsert_task/get_task/list_tasks/update_status/claim_task/count_by_status/log_sync/pending_sync/close`；`StaleVersionError` | 镜像同步（P1） |
| daemon.py | `RelayDaemon.start/stop/...` | 常驻 daemon（P1） |
| requester.py | `Requester.submit/get_result/list_tasks/cancel/close` | 需求端（P1） |
| executor.py | `Executor.claim/execute/report_result/report_failure/list_pending/close` | 执行端（P1） |
| actions/ | `run_action/omega_unwrap` | 动作执行（P1） |
| sync_folder / clipboard | `SyncFolder.sync_once/run_forever`；`read_clipboard/write_clipboard/ClipboardFileSync` | 辅助同步（P1，可缓） |

### B. rx-mbt/rhop 现状（2026-10-26 实测）

| 文件 | 内容 |
|---|---|
| cipher.mbt | `RhopCipher` trait（alg_name/encrypt/decrypt）；`RhopCipherNone`（base64） |
| packet.mbt | `RhopPacket(id/source/kind/payload/at)`（to_json_string/from_json_text）；`RhopEnvelope(v/alg/ct)`（encode/decode） |
| rhop_js.mbt | `Aes256GcmCipher`（PBKDF2-SHA256(100000)+AES-256-GCM，token=iv:tag:ct）；`rhop_send`（tmp+rename 原子写）；`from_filesystem/from_filesystem_with`（@monitor.watch_folder 事件驱动，skip_existing） |
| rhop_native.mbt | stub 占位（打印不可用） |
| moon.pkg | `options(targets:{ "rhop_js.mbt":["js"], "rhop_native.mbt":["native"] })` |

### C. 对齐差距与补齐批次

**P0 批（核心协议层，本轮执行主体）**

| # | 差距 | rx-mbt 补齐动作 | 对齐参考 |
|---|---|---|---|
| P0-1 | 密钥加载/派生抽象缺失 | 新增 `key.mbt`：`load_key(source/path/env)`、`RhopKey.from_key/from_path/from_env`；PBKDF2 salt/iterations 参数化 | crypto.py |
| P0-2 | 解密验证不区分失败原因 | `RhopCipher.decrypt` 返回 `Result[String, String]`（或新增 `decrypt_verify` 返回 ok/payload/reason 三态），js 层把 FFI 错误带上 | crypto.VerifyResult |
| P0-3 | 任务级信封缺失 | 新增 `envelope.mbt`：`RhopEnvelopeTask`（task_id/status/payload/result/error/side/version/created_at/updated_at/hops_seen/signature/checksum）+ sha256 checksum + to/from 字节 | envelope.py |
| P0-4 | Side/TaskStatus 状态机缺失 | 新增 `core.mbt`：`Side`/`TaskStatus` 枚举 + `can_transition/is_terminal/other` | core.py |
| P0-5 | shared path 多端视图缺失 | 新增 `transport.mbt`（js/native 按 target 拆分）：`EndpointView`/`LocalEndpoint`/`SharedPathView`/`make_shared_path`/`parse_endpoint`（file:// 与裸路径） | transport/ |
| P0-6 | 在线/离线回退缺失 | `select_transport`：在线通道 available 优先，否则回退 shared path；js 先实现 Local 通道 + HttpEndpoint 探测，Git/SFTP/Relay 接口占位 | transport/selector.py |
| P0-7 | 信封签名/完整性缺失 | 新增 `signer.mbt`（`AbstractSigner`/`FileHashSigner`）与 `integrity.mbt`（checksum_match/verify_bytes） | signer.py、integrity.py |
| P0-8 | 会话/交互层缺失 | 新增 `session.mbt`（`Role` SEND/RECV + `send_package/recv_package/reverse`）与 `interact.mbt`（execute/request/roundtrip 三模式） | session.py、interact.py |
| P0-9 | 配置归一缺失 | 新增 `config.mbt`：`RhopConfig`（key/channels/shared/relay/session）+ from_dict/from_file/build_*；`_key_from_cfg` 支持 plain/cipher/path/env | config.py |
| P0-10 | 文件监控语义细化 | `from_filesystem_with` 补 skip_existing 文档化、坏文件策略（解析/解密失败跳过并计入计数器） | watch.py |

**P1 批（业务层，视 P0 完成后推进）**

| # | 差距 | 补齐动作 |
|---|---|---|
| P1-1 | MirrorDB | `mirror.mbt`：upsert/get/list/update_status/claim_task/count_by_status |
| P1-2 | RelayDaemon | `daemon.mbt`：start/stop/_run_once/_process_inbox/_push_local |
| P1-3 | Requester/Executor | `requester.mbt`/`executor.mbt`：submit/get_result/cancel；claim/execute/report_result |
| P1-4 | actions | `actions.mbt`：run_action/omega_unwrap 注册表 |
| P1-5 | Git/SFTP/Relay 在线通道 | `online.mbt`/`relay.mbt`：js 目标可用实现或接口占位 |

### D. 执行方式（本次开工强制约束）

- 全程 fist-mbt **探索模式（explore）**：每次执行前按复杂度选单模式
  （≤0 tidy / 1 verify / 2 bugfind / 3 polish / 4 fix_and_merge / ≥5 advance），
  判定并行域时用文件作用域不相交。
- **开关类全开**：task_plan_deep 六开关（gradient/gradient_dag/boundary_probe/
  reinject_context/calibrate/omega_strong_verify）、claim inject、watchdog
  phi_gate+autodispatch、reserve_scope+conflicts_check 全部 ON。
- 每批完成写执行汇报到 `rx-mbt/fist-mbt/reports/YYYY-MM-DD-<任务名>-report.md`。

### E. 工程约束（历史踩坑，必须遵守）

1. rx 包引用一律 `"vicTop-cw/RX-MBT/rx" @rx` 别名 + `@rx.` 前缀访问；
2. 跨包 trait impl 必须加 `pub`（`pub impl T for X with ...`）；
3. 路径拼接统一用 `/`（`root.ends_with("/") || root.ends_with("\\")` 判断）；
4. 包根名大小写敏感：`vicTop-cw/RX-MBT`（MBT 大写）；
5. 可执行包多目标占位：`moon.pkg` 的 `options.targets` 把 `main_<target>.mbt`
   绑定到 js/native/wasm，规避 Missing main；
6. native 目标 MoonBit core 无 fs/crypto，P0-1~P0-10 的 js 目标完整实现、
   native 目标至少 none/占位，保持 `moon check` 通过。

## 影响面

- 新增：`rx-mbt/rhop/key.mbt`、`envelope.mbt`、`core.mbt`、`transport.mbt`（js/native 拆分）、
  `signer.mbt`、`integrity.mbt`、`session.mbt`、`interact.mbt`、`config.mbt`（P0）；
  P1 批新增 mirror/daemon/requester/executor/actions/online/relay。
- 修改：`rhop_js.mbt`（decrypt 返回三态、错误码透传）、`cipher.mbt`（decrypt 签名
  兼容调整）、`moon.pkg`（新文件 targets 映射）。
- 不涉及 rx/rx-mbt 其他包公共 API 变更（P0 全部为 rhop 包内新增/内部调整）。

## 验收标准

1. P0 批：`moon test`（js 目标）全绿；`moon check`（默认 wasm）通过。
2. API 对齐清单核验：§方案 C P0 表逐项可勾选，含对应 vools-rhop 模块对照。
3. 判据复现：① 本地固定密钥加密 JSON、解密验证通过/失败明确区分；
   ② 同机两进程（A/B 模拟）shared path 收发一包加密 JSON 成功；
   ④ 接收方文件监控捕获新包并解密验证成功。
4. 每批产出执行汇报（`fist-mbt/reports/`），探索模式与开关全开有据可查。
5. P1 批为可选验收，P0 完成后按剩余时间与用户确认是否推进。

## 风险

| 风险 | 规避 |
|---|---|
| MoonBit 无 fs/crypto（native 目标） | 沿用 target 拆分模式，native 占位保持可编译 |
| 跨包 pub impl / @rx 别名兼容 | 按工程约束逐项自检；P0-2 动 decrypt 签名先改 cipher.mbt 再改 rhop_js |
| 探索模式并行域误判 | 按文件作用域不相交判定，跨文件依赖串行 |
| API 面过大导致单批过重 | P0 再拆 A/B 两小批（A: P0-1~P0-5；B: P0-6~P0-10），每小批独立验证 |
