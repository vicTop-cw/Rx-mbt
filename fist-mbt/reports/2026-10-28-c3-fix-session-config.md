# 2026-10-28 · C3 修复报告 · 会话 / 配置 / 交互域（契约与文档一致性 + 清整收尾）

- 状态：修复完成 + 双平台验证全绿，待 Lead 复核
- 执行者：impl-session
- 前置：`fist-mbt/reports/2026-10-28-c3-bugfind-session-config.md`
- 域（仅此）：`rhop/{session,config,interact,actions}.mbt` + `test-suit/rhop/{session,config}_test.mbt` + `test-suit/rhop_interact/`
- 纪律：**不改任何公开 API 签名、不改运行时行为**（唯一行为变化在「测试临时目录来源」）；
  未动别人文件；未 git 提交；moon 命令一律 `bash scripts/with_moon_lock.sh moon ...`；WSL 用 `--target-dir _build/wsl`

## 1. 修复清单

### FIX-C3-01（P1 · 卫生）interact 测试临时目录：每轮 +18 → **+0**

**文件**：`test-suit/rhop_interact/interact_test.mbt`

**改法**
1. `it_dir(tag)` 从裸 `fs.mkdtempSync` 改为产品侧 `@rp.rhop_temp_workspace(tag + "-")`：
   该 API 的 FFI 会把目录登记进 `globalThis.__rhop_tmp_dirs` 并注册一次性 `process.on("exit")` 钩子，
   进程退出时 `fs.rmSync(dir, { recursive: true, force: true, maxRetries: 5 })` 递归清理
   （与 `rhop/mirror.mbt` 生产路径同一套机制）。
2. 删除裸 `ffi_tmp` extern（消除第二条无清理的创建路径 / 未使用 FFI 警告）。

**before / after 计数（Windows，`%TEMP%`）**
```
# BEFORE（改前）：先清掉历史残留，确认基线 7 个（其它 lane 的 rhop-git-*/rhop-actions-*/rhop-sftp-*）
$ ls -d $TEMP/rhop-* | wc -l                        → 7
$ moon test test-suit/rhop_interact --target js     → Total tests: 22, passed: 22, failed: 0.
$ ls -d $TEMP/rhop-* | wc -l                        → 25      # +18
$ ls -d $TEMP/rhop-it-* | wc -l                     → 16
$ ls -d $TEMP/rhop-c2-* | wc -l                     → 2

# AFTER（改后）：同一基线 7 个
$ ls -d $TEMP/rhop-* | wc -l                        → 7
$ moon test test-suit/rhop_interact --target js     → Total tests: 23, passed: 23, failed: 0.
$ ls -d $TEMP/rhop-* | wc -l                        → 7       # +0
$ ls -d $TEMP/rhop-it-* | wc -l                     → 0
$ ls -d $TEMP/rhop-c2-* | wc -l                     → 0
```
**WSL（`/tmp`）**：跑前 `/tmp/rhop-*` = 0，跑后 = 0，`/tmp/rhop-it-*` = 0（同一实现，同一结论）。

> 说明：CI 里若进程被强杀（超时/OOM），exit 钩子不执行，当轮目录仍会残留 —— 这是「进程退出清理」
> 机制的固有边界，比"永不清理"好，且与生产 `mirror` 路径行为一致（已写入寻虫报告 §1.5）。

### FIX-C3-02~08（文档补齐：契约 / 语义差异 / 平台差异，仅 doc 注释）

> 全部是 `///` 文档注释改动，**零代码/零签名变更**；`moon check` 三目标仍 0 error。

**`rhop/session.mbt`**
- `safe_filename`：补全 6 条规则（含 C2-03 的纯点号 / 结尾点 / Windows 设备名）+ **标注「D6：vools 无此校验，本项纯增量」**。
- `Session` struct：补 **「D3：vools 的 Session 还持有 `relay_server`，本项目拆成独立 `RelayServer`」**。
- `Session::available`：把「不产生副作用」改成**精确口径**——无文件系统副作用，但 relay/http 会发请求、
  在线通道探测走子进程，实测 http 介质 ≈0.5 s（**C2-04 量化**），「可自检、勿热路径」。
- `Session::select`：补「探测代价同 available，且每次重新探测不缓存」。
- `Session::remove_package`：标 **「D7：vools 无删除契约，本项为 F1 一次性 res_ 而加的增量」**。
- `Session::reverse`：补 **C2-09 注意项**（`online` 浅拷贝共享同一批通道对象；当前无 mut 状态所以安全；
  将来加连接复用等可变状态需重新设计）。

**`rhop/config.mbt`**
- `RhopConfig::action_cfg`：⚠️ 明确「**sftp 是原文（含 password/key_path）**，jump.* 真连需要；
  严禁直接落日志；诊断回显请走 `rhop.echo`（有深度掩码）；`to_dict` 是脱敏视图，两者不要混用」
  —— 这条直接修掉了矩阵里把 `action_cfg` 写成「脱敏后」的口径错误（C3-02）。
- `_key_from_cfg`：补 **D10**（数字/布尔 key：本项目用 JSON 文本 `"true"`，vools `str()` 给 `"True"`）。
- `load_config`：补 **D9**（vools 只有 dict/路径两形态；本项目多接受 JSON 文本，代价是形状判定）。

**`rhop/interact.mbt`**
- 主文档新增「与 vools 的差异」段：**D12**（只接受 `RhopConfig`，vools `_coerce` 三形态）、
  **D8**（一次性 token + 发送前清理陈旧 `res_` + 消费后删除，vools 无）。
- 新增 **roundtrip 失败相位词表**：`send` / `request` / `receive` / `response` 的触发条件与回执形状。
- 新增 **C2-05 并发注意**：缺省包名不唯一 → 同介质并发同动作会「后写者胜、前写者静默丢失」，
  并发方必须显式传唯一 `request_filename` 或由 daemon/executor 队列化。
- `interact_next_token`：补 **C2-07**（`Ref[Int32]` 非原子、单线程适用；2^31 次回绕不致误判）。

### FIX-C3-06（P2 · 互操作）CRLF 密钥文件回归用例

`test-suit/rhop_interact/interact_test.mbt` 新增 1 例（js）：
- 写 `outer.key` 内容为 `"<key>\r\n"`（模拟 Windows 编辑器产物），断言文件长度 +2（确实带 CRLF）；
- 用 `{"key": {"cipher": "RHOP-ENC:…", "path": "…/outer.key"}}` 解锁 → 主密钥解出正确；
- 反例：外层密钥不对 → `Err("key.cipher 解密失败…")`（不静默把密文当明文）。

这样「Windows 写密钥文件 → WSL 读」这条跨平台路径有了固定用例（`load_key` 的 `trim()` 覆盖 `\r`）。

## 2. 本轮**未**改（有意保留）

| 项 | 决定 | 理由 |
|---|---|---|
| `DOC.md` / `README.md` / 矩阵 | **只报告，不改** | 不在我的写作用域（Lead/QA 域）。寻虫报告 §2 给了逐行现状 / 应为 / 替换文本，可直接落笔 |
| 产品探测行为的优化（C2-04 缓存/TTL） | 不改 | 会改变「可用性实时性」语义，需单独立契约定案 |
| `interact` 缺省包名唯一化（C2-05） | 不改 | 缺省名是契约字面量；唯一化应在 daemon/executor（Batch D） |
| 注册表加锁 / nonce 换 Int64（C2-06/07） | 不改 | 当前单线程模型下无缺陷；改了反而增加复杂度，已文档化边界 |
| 其它 lane 留下的 `%TEMP%/rhop-git-*`、`rhop-actions-*`、`rhop-sftp-*` | 不清理 | 非本域测试产生；已在寻虫报告 §1.1 记录（建议对应 lane 用 `rhop_temp_workspace`） |

## 3. 改动文件清单

**产品（3，纯文档注释）**
- `rhop/session.mbt`：`safe_filename` / `Session` / `available` / `select` / `remove_package` / `reverse` 文档
- `rhop/config.mbt`：`action_cfg` / `_key_from_cfg` / `load_config` 文档
- `rhop/interact.mbt`：主入口文档（差异段 + 相位词表 + 并发注意）+ `interact_next_token` 文档

**测试（1）**
- `test-suit/rhop_interact/interact_test.mbt`：`it_dir` 改走 `rhop_temp_workspace`、删裸 `ffi_tmp`、+1 例 CRLF 密钥用例

**报告（2）**：本文件 + `2026-10-28-c3-bugfind-session-config.md`

未改：`rhop/actions.mbt`（本轮无待改项，C2 已修）、`rhop/interact.mbt` 的任何代码逻辑、别人文件、`moon.pkg`。

## 4. 验证（Windows + WSL，全部经 `with_moon_lock.sh`）

### 4.1 Windows（moon 0.1.20261016 / node v25.2.1）
```
moon check                 → 0 errors
moon check --target js     → 0 errors
moon check --target native → 0 errors
moon test test-suit/rhop                  → Total tests: 156, passed: 156, failed: 0.（wasm）
moon test test-suit/rhop --target js      → Total tests: 160, passed: 160, failed: 0.
moon test test-suit/rhop --target native  → Total tests: 156, passed: 156, failed: 0.
moon test test-suit/rhop_interact --target js → Total tests: 23, passed: 23, failed: 0.
moon test                 → Total tests: 612, passed: 612, failed: 0.（wasm 全量）
moon test --target js     → Total tests: 825, passed: 825, failed: 0.（js 全量）
```

### 4.2 WSL（Ubuntu-22.04，`--target-dir _build/wsl`）
```
moon check --target js                    → 0 errors
moon test test-suit/rhop                  → Total tests: 156, passed: 156, failed: 0.
moon test test-suit/rhop --target js      → Total tests: 160, passed: 160, failed: 0.
moon test test-suit/rhop --target native  → Total tests: 156, passed: 156, failed: 0.
moon test test-suit/rhop_interact --target js → Total tests: 23, passed: 23, failed: 0.
moon test                 → Total tests: 612, passed: 612, failed: 0.
moon test --target js     → Total tests: 825, passed: 825, failed: 0.
```

### 4.3 双平台对照
| 入口 | Windows | WSL |
|---|---|---|
| `moon check`（默认/js/native） | 0 / 0 / 0 errors | 0 errors（js 复核） |
| `test-suit/rhop` wasm / js / native | 156 / 160 / 156，全 `failed: 0` | 156 / 160 / 156，全 `failed: 0` |
| `test-suit/rhop_interact --target js` | **23 / 23 / 0** | **23 / 23 / 0** |
| 全量 `moon test`（wasm） | **612 / 612 / 0** | **612 / 612 / 0** |
| 全量 `moon test --target js` | **825 / 825 / 0** | **825 / 825 / 0** |
| **temp 增量（每次 interact 测试）** | **+0**（改前 +18） | **+0** |

> js 全量 819 → 825：本题域 +1（CRLF 用例），其余 +5 来自并行 lane 的新增用例（非本域）。

## 5. 遗留风险 / 建议 Lead 处理的文档补丁（超出我的作用域）

1. **矩阵 §4.3 `action_cfg`**（关键，安全口径写反）：
   现状「动作层视图（脱敏后）」→ 建议「动作层视图（**含 sftp 原文凭据**，供 jump.* 真连；严禁直接落日志；回显侧由 `rhop.echo` 掩码）」。
2. **矩阵 / DOC.md 的 `send_package` 回执字段**：现写 `{status,transport,filename,payload}` →
   应为 send `{status,transport,filename,role}`、recv 才有 `payload`。
3. **矩阵 / DOC.md 的 `to_dict` 口径**：现写「sftp.password/key_path → ***（与 vools 同）」→
   应为「递归深度脱敏（sftp/online/shared/relay + token/secret 等键表），**比 vools 更严**」。
4. **测试用例数**：矩阵 §4 引言与 §4.2/4.3 → session 20、config 25、interact 23；
   README L73「253 js / 121 wasm」→ 项目级 js 825 / wasm 612（快照随时变动，建议改为「以矩阵 §9 为准」）。
5. **DOC.md 漏列符号**：`safe_filename`、`Session::remove_package`、`unregister_action`、`rhop_echo`
   （`get_handler` 建议一并归位到 interact/actions 代码块）。
6. **README 差异摘要**：建议追加 3 行（D1 收据分流 / D6+D7 白名单与 remove_package 增量 / D8+D12 token 与入参形态）。
7. **`~` 展开**：`key.mbt` 不做 `~` 展开（两平台一致）但无文档，建议在 DOC 的 `key.mbt` 段注明「请给绝对路径或环境变量」。
8. 退出钩子的固有边界（进程被强杀时残留）已在报告记录；若 CI 有超时强杀，建议 gate 前 `rm -rf $TEMP/rhop-*` 兜底。