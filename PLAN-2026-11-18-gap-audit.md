# PLAN · rx-mbt 0.4.4 缺口实测与收口计划（2026-11-18）

> 本文是**实测后**的缺口清单（逐文件看源码核实，非照抄旧计划），并给出收口顺序。
> 旧计划 `PLAN-mcp-watcher-apis.md` 的 R1（真实时钟）已落地，本文只列**仍然真缺**的部分。

## 一、实测结论（0.4.4 @ `2b90d39`）

| 能力 | 旧计划口径 | 实测状态 | 判定 |
|------|-----------|---------|------|
| 真实时钟时间算子 | 缺 | `rx/ops_time_real.mbt`：`install_real_clock` / `real_interval` / `real_timer` / `debounce_real` 全在 | **已补齐** |
| native 文件监控 | 占位 Unsupported | `monitor/watcher_native.mbt`(185 行) + `fs_native.mbt`(240 行) + C stubs，0.4.4 修了路径粘连 | **已补齐** |
| cron 解析 | 缺 | rx 本体仍无，但下游 mcp-watcher `cron/cron.mbt` 已有完整 parse/matches/next_after | **rx 不必补**（避免重复造，见 R3） |
| `run_cli` 仅 js | 缺 | `rhop_task/task_exec.mbt` 有 `ExecPolicy` 白名单模型；native 执行臂未见 | **仍缺**（R2） |
| native 加密传输 | stub | `rhop/rhop_native.mbt`(133 行) 收发已 1:1 做实，但**只支持 `RhopCipherNone`（纯 base64）**；`rhop/crypto.mbt` 的 `from_path`/`from_env` 非 js 返回可诊断 Err，`encrypt_json` 失败返回空串 | **传输已通、加密未通**（R1） |
| native crypto FFI | 缺 | 无（Fernet 仅 `extern "js"`） | **仍缺**（R1 的根） |

## 二、收口计划（按优先级）

### R1 · native AES-GCM 密码臂（高，阻塞 fist-mbt 跨机池加密）

- 目标：`RhopCipher` 新增 native 实现（`RhopCipherAesGcmNative`），`rhop_native.mbt` 收发链路换真加密。
- 约束：不引入 OpenSSL（遵循 `rhop_native.mbt` 头注）。两条路线二选一：
  a) 纯 MoonBit 实现 AES-256-GCM +已有 PBKDF2（js 轨已验证的密钥派生逻辑平移）；
  b) 平台密钥库 FFI：Windows BCrypt / Linux kernel crypto AF_ALG，静态链接、零外部依赖。
- 验收：js(AES-GCM) ↔ native(AES-GCM) 互加密互解密对拍全绿；`encrypt_json` 失败不再返回空串（改 Result）。
- 连带收益：解除 mcp-watcher「加密动作 🚧 明确降级」的阻塞。

### R2 · `ExecPolicy` native 执行臂（中）

- 目标：`run_cli`/`task_exec` 补 native 进程启动（`@ffi` spawn + 管道回采），白名单/超时语义与 js 轨 1:1。
- 验收：native 轨按白名单放行/拒绝对拍 + 超时杀进程用例。

### R3 · cron 解析上游（低，可选）

- mcp-watcher 的 `cron.mbt` 是独立包，可平移进 rx（如 `rx/cron.mbt`）使 rx 自足；
  若平移，mcp-watcher 改 import rx，删本地副本，保持单一真源。不急，等有第二个消费者再动。

## 三、依赖方影响

- fist-mbt：跨机任务池/跨机消息池（4 池后半）的解冻条件 = R1 落地；fist-mbt 依赖行
  `RX-MBT@0.4.0` 应升 `0.4.4`（0.4.3/0.4.4 的 R1~R4 基座与 native watch 修复全适用）。
- mcp-watcher：R1 落地后 `encrypt_file` 从"诚实降级"转正。
