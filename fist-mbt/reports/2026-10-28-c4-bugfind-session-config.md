# 2026-10-28 · C4 寻虫报告 · 会话 / 配置 / 交互 / 动作域

- 状态：寻虫完成；修复见 `fist-mbt/reports/2026-10-28-c4-fix-session-config.md`
- 执行者：impl-session
- 计划：`fist-mbt/plans/2026-10-28-combo-c4.md`；起点 HEAD `0e17d21`（v0.4.0）
- 域：`rhop/{session,config,interact,actions}.mbt` + `test-suit/rhop/{session,config}_test.mbt` + `test-suit/rhop_interact/`
- 方式：**真实介质/真实子进程探针**（临时探针文件 `test-suit/rhop_interact/scratch_c4_test.mbt`，js 目标，
  日志 `<tmp>/rhop-c4-*/c4-probe.log`；跑完即删 + `moon.pkg` targets 复原）+ 只读代码审计
- 纪律：moon 命令一律 `bash scripts/with_moon_lock.sh moon ...`；WSL 用 `--target-dir _build/wsl`
- 基线：本域 `test-suit/rhop` 156/160/156、`rhop_interact` js 23/23/0（C3 收口时）

## 0. 结论摘要

| 编号 | 级别 | 关注点 | 标题 | 处置 |
|---|---|---|---|---|
| **C4-01** | **P1（安全）** | ② | 深掩码键表**覆盖不全**：`rhop.echo` 与 `to_dict` 会泄漏 **裸 `key`、`secret_key`、`passphrase`、`sftp.key`、`sftp.passphrase`、`relay.key`** | **已修**（键表收紧 + 回归） |
| **C4-02** | **P1（互操作）** | ③ | **UTF-8 BOM 密钥文件**（Windows 记事本/PowerShell `Out-File` 产物）导致跨平台解密**静默失败**（fernet hmac 不符） | **已修**（配置层剥 BOM + 回归；`key.mbt` 源头未改，见 §5） |
| C4-03 | P2（文档） | ① | 「探测期失败 → `Err`」vs「投递期失败 → `status:error` 收据」的分界未成文，实测两者表现不同（http 端点下线 → `Err(…全不可达)`） | 已补 doc（`interact` / `session`） |
| C4-04 | ✅ 通过（无缺陷） | ① | **relay 中转端到端**：`interact` roundtrip 双向 `transport=relay`、加密包不落 shared 盘；**重放**被「取走即删」挡住（第二次处理 `error/无包`）；**坏包** → `MALFORMED` | 已固化 3 条回归 |
| C4-05 | ✅ 通过（无缺陷） | ① | **HTTP 端点介质端到端**：真实 HTTP 文件服务（PUT/GET/DELETE 子进程）上 roundtrip 成功，`transport=shared`；单轮 ≈1.4–2.3 s（每请求一个 node 子进程） | 已固化 1 条回归 + 性能记录 |
| C4-06 | ✅ 通过（无缺陷） | ⑤ | **同名并发互踩**：A 手工投递 + B 完整 roundtrip（同名）→ B 成功、**A 拿到 `status:error` 收据**（token+一次性删除守卫生效，绝不把 B 的结果当自己的） | 已固化 1 条回归 |
| C4-07 | P2（清整，**其他 lane**） | ④/清整 | `%TEMP%` 现有 **205** 个 `rhop-*` 残留：`rhop-html` 99、`rhop-git` 88、`rhop-actions-root` 12、`rhop-sftp-root` 11、`rhop-t1..t7` 7（后者来自 `test-suit/rhop_js/transport_test.mbt` 的 `ffi_t_mkdtemp`）；本域 **+0** | 报告 + 建议各 lane 切 `rhop_temp_workspace` |
| C4-08 | P3（文档） | ③ | `_key_from_cfg` 的 D10 注释已过期（行为已改为**拒绝布尔**，注释还写"按 JSON 文本"） | 已修 doc |
| C4-09 | P3（残留） | ②③ | 错误回执里的 URL/路径会带上介质地址（无凭据）；`action_cfg` 仍含 sftp 原文（已文档化为设计） | 记录（无动作） |

---

## 1. C4-01（P1 · 安全）深掩码键表覆盖不全

**位置**：`rhop/config.mbt: cfg_is_secret_key`（被 `to_dict` 与 `rhop/actions.mbt: rhop_echo` 共用）

**证据（探针 C4-3，修复前）**
```
[C4-3] echo leaks: bare_key=true secret_key=true passphrase=true password=false sftp_key=true sftp_pass=true token=false
[C4-3] to_dict leaks: config_key=false relay_key=true token=false
[C4-3] action_cfg contains password=true      ← 设计如此（jump.* 真连需要）
```
- `rhop.echo`（**链路自检动作，结果常被直接 println/写日志**）会把 `{"key": …}`、`{"secret_key": …}`、
  `{"passphrase": …}`、`{"sftp": {"key"/"passphrase": …}}` 原样回显；
- `to_dict` 的递归掩码也漏 `relay.key` / `sftp.key` 这类**裸 key**；
- 讽刺点：`key_path` / `private_key` / `password` / `token` 都掩了，唯独最常用的 `key` 没掩。

**复现**
```moonbit
@rp.run_action("rhop.echo",
  Json::object({"key": Json::string("SECRET"), "sftp": Json::object({"key": Json::string("K")})}), None)
// 修复前：回执 json 里能看到 SECRET / K；修复后：均为 "***"
```

**影响**：daemon/executor 侧 `run_action(name, cfg, …)` 的 cfg 可能来自任务 payload 或 `action_cfg()`
（`executor.mbt:133-138`：payload 里给了 `cfg` 就用 payload 的），一旦其中带裸 `key`，就会随
`rhop.echo`/日志外泄。

**根因**：键表是手写白名单，新增字段（如 `sftp.key`、`relay.key`）时没人回头补；且**后缀规则不可用**——
`*_key` 会误伤 `has_key`（语义相反的布尔键）。

**建议修法（已实施）**：显式键表补齐四族（口令/密钥/票据/凭据），并对「不掩码」的
`public_key` / `has_key` 写出理由；不做后缀猜测。

---

## 2. C4-02（P1 · 互操作）UTF-8 BOM 密钥文件跨平台失效

**位置**：`rhop/key.mbt: load_key_from_path`（`trim()` 不剥 BOM）+ `rhop/config.mbt: _key_from_cfg`（配置层调用点）

**证据（探针 C4-4，修复前）**
```
[C4-4] LF key   => inner-key-c4                     ✅
[C4-4] CRLF key => inner-key-c4                     ✅（trim 顺带覆盖 \r）
[C4-4] BOM load_key_from_path => Ok(len=13 startsWithBom=true)   ⚠️ 返回的密钥带 BOM
[C4-4] BOM cipher unlock     => Err(key.cipher 解密失败: … bad fernet hmac)   ❌
```
- Windows 记事本 / PowerShell `Out-File -Encoding utf8`（Windows PowerShell 5.1 默认带 BOM）写出的
  密钥文件首字节是 `EF BB BF`；MoonBit `String::trim()` 只去空白，**BOM 不是空白**；
- 于是密钥变成 `"\uFEFF<key>"` → PBKDF2 派生不同 → Fernet HMAC 不符 → **解密失败**；
- 失败信息是「密钥不符或密文被篡改」，**看起来像口令错**，实际是编码事故 —— 极难排查。

**复现**
```bash
printf '\xEF\xBB\xBFouter-key\n' > /tmp/bom.key     # Windows 侧常见形态
# 配置 {"key": {"cipher": "RHOP-ENC:…", "path": "/tmp/bom.key"}} → 修复前必然解不开
```

**影响**：「Windows 生成密钥 / WSL 或 Linux 使用」（以及反过来）这条最常见的跨平台路径失效；
与 C3-06 的 CRLF 用例是同一族问题（行尾已覆盖，编码没覆盖）。

**建议修法（已实施）**：配置层统一 `cfg_strip_bom`（只剥开头 U+FEFF，不 trim），覆盖四个来源
（明文串 / `plain` 字段 / `cipher` 外层密钥 / `path|env|source`）。
**源头修复建议（不在我作用域）**：`load_key_from_path` / `load_key` 应自己去 BOM，这样
`RhopCrypto::from_path` 直接调用者也能受益（见 §5）。

修复后实测：
```
[C4-4] BOM cipher unlock => Ok(key=inner-key-c4)    ✅
```

---

## 3. C4-03（P2 · 文档）探测期 vs 投递期的失败分界

**证据（探针 C4-2a / C4-7）**
```
[C4-2a] http 端点停掉后 roundtrip => Err(rhop session: 无可用的传输介质（relay/online/shared 全不可达）)
[C4-7]  relay-only 且中转停掉     => Err(同上)
[C4-7]  relay 有包但坏包          => {"status":"error","reason":"MALFORMED","transport":"relay"}   ← 收据
[C4-7]  relay 无包               => {"status":"error","reason":"rhop relay: 中转无包 …"}          ← 收据
```
即：**探测阶段**判死 → `Err`；**投递阶段**失败 → 收据。两种都合理（前者是"环境/配置不成立"），
但此前文档只写了"介质/加解密失败走收据"，没写清"介质不可达走 Err"，容易让调用方写错分支。

**建议修法（已实施）**：`interact` / `send_package` doc 明确写这一条分界（含 `phase` 只描述投递阶段）。

---

## 4. ① 真实第三方介质端到端（探针结论：**闭环成立**）

### 4.1 relay 中转（C4-1）
```
relay port=56842
roundtrip => status=ok transport=relay response_transport=relay result=ok
shared dir listing after = 0            ← 加密包全程只在中转内存里，没落 shared 盘
handle bad relay pkg => status=error reason=MALFORMED
handle#1 (request)  => status=ok
handle#2 (同一包重放) => status=error reason=rhop relay: 中转无包 …   ← 取走即删挡住重放
```
结论：**interact 的 roundtrip 在真实第三方介质（C 端中转子进程）上完整成立**，且
「坏包 / 重放 / 对端不在」三种失败面都有闭环响应（收据或 Err，语义见 §3）。

### 4.2 http 端点（C4-2）
```
http port=57593
roundtrip http => status=ok transport=shared response_transport=shared result=ok in 1440 ms
```
- `HttpEndpoint` 属 **shared path**（不是 OnlineChannel），所以 `transport` 标签是 `shared` —— 与设计一致
  （C3 doc 已注明"URL 形态 ≠ 联网通道"）。
- 单轮 roundtrip ≈1.4–2.3 s：`HttpEndpoint` 每个请求都 fork 一个 `node -e` 子进程（`transport_endpoint.mbt`
  的同步 HTTP 桥），一轮 roundtrip 约 8–10 次请求 → **性能记录（非缺陷）**，已在 C2-04 记录同源。
- **重放风险（HTTP 特有）**：relay 是"取走即删"，而 `HttpEndpoint::read_text` **不删除** →
  同一请求包可被对端**重复执行**。本项目靠「一次性 token 校验回执」防"拿错结果"，
  但**不防"请求被执行两次"**；幂等动作无碍，非幂等动作需要上层去重（daemon 已有 task_id 语义）。

### 4.3 ⑤ 同名并发互踩（C4-6）
```
B roundtrip (req_race.rhop) => status=ok
A recv res_req_race.rhop    => status=error（B 已把 res_ 消费删除）
```
结论：并发同名时**先投递方拿到干净的 error 收据**，不会把别人的结果当自己的 —— token + 一次性删除
守卫有效（与 C2-05 的"请求可能丢失"是两个不同问题：丢失仍可能，但**错拿**不会）。

### 4.4 ④ clipboard（真实后端 / 降级 / 文件交换）
```
[C4-5] real backend name => <none>            ← 本机无头环境，无剪贴板后端
[C4-5] push#1 => {"changed":true,"text_len":12}
[C4-5] file after push = {"text": "clip-text-c4", "updated_at": "…", "writer": "rhop"}
[C4-5] pull#1 => {"changed":true,"text_len":12,"from_writer":"rhop"}
[C4-5] pull#2(幂等) => {"changed":false,"reason":"内容未变化"}
[C4-5] push without backend => {"changed":false,"reason":"无可用剪贴板后端"}   ← 降级路径正确
```
结论：`ClipboardFileSync` 的 push/pull 真文件交换**成立**（交换文件 schema 与 `writer` 字段正确），
无后端时**明确降级**（`changed:false` + 可诊断 reason），不崩不误报。
真实剪贴板后端在本机（Windows 沙箱 & WSL）都探测为 `none`，故**真实后端 E2E 无法在此环境验证**（记录）。

---

## 5. ③ 配置敏感文件在 Windows / WSL 的差异（补齐 C3 结论）

| 项 | Windows | WSL | 本项目行为 |
|---|---|---|---|
| 密钥文件 BOM | 记事本/PS5.1 默认带 BOM | 一般无 | **修复前跨平台必失败** → 已修（配置层剥 BOM） |
| 行尾 CRLF | 常见 | LF | `trim()` 已覆盖（C3-06 回归） |
| 文件权限 | ACL 继承（通常用户可读） | 常 0644（umask） | 无设置权限能力 → 建议文档要求 0600（非本域） |
| 路径形态 | `E:\keys\x` / `C:/keys/x` | `/root/.rhop/key` | 不互通；错误可诊断（C2-01 截断） |
| `file://` 地址 | `file:///E:/share` → `E:/share` | `file:///mnt/e/share` → 原样 | 各自正确（纯字符串逻辑） |
| 掩码输出 | `to_dict` 两平台逐字节一致 | 同 | 键名匹配，与 OS 无关（已由三目标用例覆盖） |

---

## 6. 清整（④/清整主题，非本域）

`%TEMP%` 实测 **205** 个 `rhop-*` 残留目录（本域 **0**）：

| 前缀 | 数量 | 来源（推断） |
|---|---|---|
| `rhop-html` | 99 | 其它 lane 的 html/watch 相关测试 |
| `rhop-git` | 88 | git 通道测试（`test-suit/rhop_js`） |
| `rhop-actions-root` | 12 | actions/business 测试 |
| `rhop-sftp-root` | 11 | sftp 测试 |
| `rhop-t1..rhop-t7` | 7 | `test-suit/rhop_js/transport_test.mbt` 的 `ffi_t_mkdtemp`（裸 mkdtemp，与 C3-01 本域问题同款） |
| `rhop-mirror` | 2 | mirror（已有 exit 钩子，应为强杀残留） |

建议：把 C3-01 的修法（`rhop_temp_workspace`，带 `process.on("exit")` 钩子）推广到上述各 lane 的测试；
`rhop-t1..t7` 与本域 C3 修复前完全同型（裸 `ffi_t_mkdtemp`）。此处只报告，不改别人的测试文件。

## 7. 本轮修复范围

见 `2026-10-28-c4-fix-session-config.md`：C4-01（掩码键表）、C4-02（BOM）、C4-03/C4-08（doc）+
5 条回归（relay E2E/重放/坏包、http 端点 E2E、掩码、BOM、同名并发）。
**不改**：公开 API 签名、`key.mbt`（他人作用域，只给建议）、别人的测试、clipboard 实现（只验证）。