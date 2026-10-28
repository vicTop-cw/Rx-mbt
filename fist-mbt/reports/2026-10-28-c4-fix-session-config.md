# 2026-10-28 · C4 修复报告 · 会话 / 配置 / 交互 / 动作域

- 状态：修复完成 + 双平台验证全绿，待 Lead 复核
- 执行者：impl-session
- 前置：`fist-mbt/reports/2026-10-28-c4-bugfind-session-config.md`
- 域（仅此）：`rhop/{session,config,interact,actions}.mbt` + `test-suit/rhop/{session,config}_test.mbt` + `test-suit/rhop_interact/`
- 纪律：不改公开 API 签名、不新增功能；未动他人文件；未 git 提交；
  moon 命令一律 `bash scripts/with_moon_lock.sh moon ...`；WSL 用 `--target-dir _build/wsl`

## 1. 修复清单

### FIX-C4-01（P1 · 安全）深掩码键表收紧

**文件**：`rhop/config.mbt: cfg_is_secret_key`（`to_dict` 与 `rhop.echo` 共用同一张表）

**改法**：显式键表补齐四族（大小写不敏感、精确匹配）：
- 口令：`password` / `passwd` / `pass` / `passphrase` / `secret`
- 密钥：`key` / `key_path` / `private_key` / `secret_key` / `signing_key` / `encryption_key` /
  `master_key` / `session_key` / `api_key`
- 票据：`token` / `auth_token` / `access_token` / `refresh_token` / `bearer_token`
- 凭据：`credential` / `credentials` / `client_secret`

**为什么不做后缀规则**（`*_key` 之类）：会误伤 `has_key`（语义相反的布尔存在性键）；文档里写明
「有意不掩码：`public_key`（公开）、`has_key`（布尔）」，避免下次又被"顺手"改坏。

**before/after（探针实测）**
```
BEFORE  [C4-3] echo leaks: bare_key=true secret_key=true passphrase=true password=false sftp_key=true sftp_pass=true token=false
        [C4-3] to_dict leaks: config_key=false relay_key=true token=false
AFTER   [C4-3] echo leaks: bare_key=false secret_key=false passphrase=false password=false sftp_key=false sftp_pass=false token=false
        [C4-3] to_dict leaks: config_key=false relay_key=false token=false
```
**回归**：`interact_test.mbt`「C4-01：深掩码键表收紧」（覆盖 8 个敏感键 + 断言 `public_key`/`host` 等
非敏感字段仍在，防"掩码变删字段"）。

### FIX-C4-02（P1 · 互操作）UTF-8 BOM 密钥文件

**文件**：`rhop/config.mbt`
- 新增 `cfg_strip_bom(value)`：**只剥开头 U+FEFF，不 trim**（保住用户密钥里的空格）；
- 在 `_key_from_cfg` 的**四个来源**统一应用：
  1. 字符串明文（`key: "\uFEFFxxx"`）；
  2. `{"plain": …}`；
  3. `{"cipher": …}` 的**外层解锁密钥**（`load_key(...)` 结果）；
  4. 解密出的主密钥（`decrypt_secret` 结果）；
  5. 分支 4 的 `load_key(source/path/env)` 结果。

**before/after（探针实测）**
```
BEFORE  [C4-4] BOM load_key_from_path => Ok(len=13 startsWithBom=true)
        [C4-4] BOM cipher unlock     => Err(key.cipher 解密失败: … bad fernet hmac)
AFTER   [C4-4] BOM cipher unlock     => Ok(key=inner-key-bom)     ✅
```
**回归**：`interact_test.mbt`「C4-02：BOM 密钥文件（Windows 记事本产物）跨平台可解锁」——
真实 BOM 文件 + `{"cipher"/"path"}` 解锁成功；纯字符串 `"\uFEFF…"` 也被剥。

### FIX-C4-03（P2 · 文档）探测期 vs 投递期失败分界

**文件**：`rhop/interact.mbt`（`interact` doc）、`rhop/session.mbt`（分流原则段）
- 明确：`select()` 判 `none`（中转/http 端点不可达、shared 写端不可用）→ **`Err`**；
  选定介质后**投递失败**（写不进/读不到/对端不在/解密不过）→ **`status:"error"` 收据**；
  `phase` 只描述投递阶段。

### FIX-C4-08（P3 · 文档）`_key_from_cfg` 的 D10 注释过期

行为已在更早轮次改为「**拒绝布尔**」（避免与 vools `str(True)` 口径不一致导致换实现解不开），
但注释还写"布尔按 JSON 文本当密钥" → 已改为与实现一致，并写明拒绝理由。

### FIX-C4-04~06（验证型回归，无产品改动）

`test-suit/rhop_interact/interact_test.mbt` 新增 3 条（把 C4 探针结论钉住）：
1. **C4-03 relay 中转 E2E**：真实 `RelayServer` 子进程；
   ① roundtrip 双向 `transport=relay`、`response_transport=relay`、`result=ok`；
   ② 重放：同一请求包第二次 `handle_request` → `error` + reason 含"无包"（取走即删）；
   ③ 坏包：非信封 → `error` + reason `MALFORMED`。
2. **C4-04 http 端点 E2E**：测试内起**真实 HTTP 文件服务**（node 子进程，PUT/GET/DELETE + 端口回写），
   `interact` roundtrip 成功、`transport=shared`（HttpEndpoint 属 shared path）；
   服务停掉后再跑 → `Err(…全不可达)`（与 §FIX-C4-03 的文档分界一致，反向钉住语义）。
3. **C4-05 同名并发**：A 手工投递 + B 同名完整 roundtrip → B ok、**A 拿 `status=error` 收据**
   （token + 一次性删除守卫，绝不把 B 的结果当自己的）。

## 2. 本轮**未**改动

| 项 | 决定 | 理由 |
|---|---|---|
| `rhop/key.mbt: load_key_from_path` 不剥 BOM | **报告 + 建议** | 不在我的作用域（impl-crypto 的 key.mbt）。建议源头也剥（`RhopCrypto::from_path` 直接调用者才能受益）；配置层已做防御 |
| HTTP 端点 read 不删除 → 请求可重放 | 报告 | 属 `transport_endpoint.mbt` 语义（他人作用域）；本项目靠 token 防"拿错结果"，防"重复执行"需上层幂等（daemon task_id 已具备） |
| 真实剪贴板后端不可用（本机 `none`） | 记录 | 无头环境限制；已用注入后端验证 push/pull 真文件交换 + 无后端降级 |
| `%TEMP%` 中 205 个其它 lane 残留（`rhop-html` 99 / `rhop-git` 88 / `t1..t7` 7 …） | 报告 | 别人的测试文件；建议各 lane 复用 C3-01 的 `rhop_temp_workspace` 修法 |
| 文件权限（0600）建议 | 只报告 | 无跨平台设权限 API；建议写进 DOC 的 key.mbt 段 |
| `action_cfg` 含 sftp 原文 | 保持 | 设计如此（jump.* 真连需要），已在 C3/C4 doc 标注"严禁落日志；回显走 rhop.echo" |

## 3. 改动文件清单

**产品（3）**
- `rhop/config.mbt`：`cfg_is_secret_key` 键表收紧（C4-01）、`cfg_strip_bom` + 4 处应用（C4-02）、D10 doc 修正（C4-08）
- `rhop/interact.mbt`：探测期/投递期分界 doc（C4-03）
- `rhop/session.mbt`：分流原则段补同一分界（C4-03）

**测试（1）**
- `test-suit/rhop_interact/interact_test.mbt`：+5 用例（C4-01 掩码、C4-02 BOM、C4-03 relay E2E、C4-04 http E2E、C4-05 并发）

**报告（2）**：本文件 + `2026-10-28-c4-bugfind-session-config.md`
**临时物**：`scratch_c4_test.mbt` 已删，`moon.pkg` targets 已复原。

## 4. 验证（Windows + WSL，全部经 `with_moon_lock.sh`）

### 4.1 Windows（moon 0.1.20261016 / node v25.2.1）
```
moon check                 → 0 errors
moon check --target js     → 0 errors
moon check --target native → 0 errors
moon test test-suit/rhop                  → Total tests: 159, passed: 159, failed: 0.（wasm）
moon test test-suit/rhop --target js      → Total tests: 163, passed: 163, failed: 0.
moon test test-suit/rhop --target native  → Total tests: 159, passed: 159, failed: 0.
moon test test-suit/rhop_interact --target js → Total tests: 28, passed: 28, failed: 0.
moon test test-suit/rhop_clipboard --target js → Total tests: 25, passed: 25, failed: 0.
moon test                 → Total tests: 615, passed: 615, failed: 0.（wasm 全量）
moon test --target js     → Total tests: 849, passed: 849, failed: 0.（js 全量）
```

### 4.2 WSL（Ubuntu-22.04，`--target-dir _build/wsl`）
```
moon check --target js                    → 0 errors
moon test test-suit/rhop                  → Total tests: 159, passed: 159, failed: 0.
moon test test-suit/rhop --target js      → Total tests: 163, passed: 163, failed: 0.
moon test test-suit/rhop --target native  → Total tests: 159, passed: 159, failed: 0.
moon test test-suit/rhop_interact --target js → Total tests: 28, passed: 28, failed: 0.
moon test test-suit/rhop_clipboard --target js → Total tests: 25, passed: 25, failed: 0.
moon test                 → Total tests: 615, passed: 615, failed: 0.
moon test --target js     → Total tests: 849, passed: 849, failed: 0.
```

### 4.3 双平台对照
| 入口 | Windows | WSL |
|---|---|---|
| `moon check`（默认/js/native） | 0 / 0 / 0 errors | 0 errors（js 复核） |
| `test-suit/rhop` wasm / js / native | 159 / 163 / 159，全 `failed: 0` | 159 / 163 / 159，全 `failed: 0` |
| `test-suit/rhop_interact --target js` | **28 / 28 / 0** | **28 / 28 / 0** |
| `test-suit/rhop_clipboard --target js` | **25 / 25 / 0** | **25 / 25 / 0** |
| 全量 `moon test`（wasm） | **615 / 615 / 0** | **615 / 615 / 0** |
| 全量 `moon test --target js` | **849 / 849 / 0** | **849 / 849 / 0** |
| **temp 增量（本域，每次 interact 测试）** | **+0**（`rhop-it-*`/`rhop-c4-*` 均为 0） | **+0** |

> temp 说明：Windows `%TEMP%` 总量 205→211 的 +6 全部来自并行 lane（`rhop-git-*` 等），本域 0。
> WSL `/tmp` 跑前 0 → 跑后 0。

## 5. 给 Lead / 其它 lane 的建议

1. **P1 源头修复（impl-crypto）**：`rhop/key.mbt` 的 `load_key_from_path` / `load_key` 应自行剥 UTF-8 BOM，
   否则 `RhopCrypto::from_path` 的直接调用者仍会被 BOM 坑（配置层已做防御，属双保险）。
2. **P2（impl-crypto）**：`HttpEndpoint::read_text` 不删除包 → 请求可被重复执行；如要"至少一次"变"至多一次"，
   需要 HTTP 侧 DELETE-on-read 或上层幂等（daemon 有 task_id，可复用）。
3. **P2（各 lane 清整）**：`%TEMP%` 205 个残留，主力是 `rhop-html`(99)/`rhop-git`(88)/
   `test-suit/rhop_js/transport_test.mbt` 的 `t1..t7`；建议统一切到 `rhop_temp_workspace`（带 exit 钩子）。
4. **P3（文档）**：文件权限建议（密钥文件 0600 / Windows ACL）写进 DOC `key.mbt` 段；
   `~` 不展开的提示也一并加（C3 已建议，尚未落笔）。
5. **性能记录**：http 端点介质一轮 roundtrip ≈1.4–2.3 s（每请求一个 node 子进程）；
   relay 一轮 ≈0.2–0.5 s。可入 C4 性能基线表（qa-platform 域）。