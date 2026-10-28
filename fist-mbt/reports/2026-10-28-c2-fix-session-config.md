# 2026-10-28 · C2 修复报告 · 会话 / 配置 / 交互 / 动作

- 状态：修复完成 + 双平台验证全绿（见 §4.3），待 Lead 复核
- 执行者：impl-session
- 前置：寻虫报告 `fist-mbt/reports/2026-10-28-c2-bugfind-session-config.md`
- 作用域（仅此）：`rhop/{session,config,interact,actions}.mbt` + `test-suit/rhop/{session,config}_test.mbt` + `test-suit/rhop_interact/`
- 纪律：未改任何公开 API 签名；未加新功能；未动别人的文件；未 git 提交；
  所有 moon 命令经 `bash scripts/with_moon_lock.sh moon ...`；WSL 用 `--target-dir _build/wsl` 隔离。

## 1. 修复清单（3 项，含回归测试）

### FIX-C2-01（P1）配置文本 vs 文件路径：形状判定 + 错误串截断

**文件**：`rhop/config.mbt`
- 新增 `const CFG_PATH_MAX_LEN : Int32 = 4096`、`fn cfg_snippet(raw, max)`（控制字符归一 + 截断 + `…`）。
- `load_config(Json::string)` 改成**形状优先**：
  1. `{`/`[` 开头 ⇒ 当配置**文本**解析；对象 → `from_dict`；`[`/非对象 → `Err("配置必须是 dict/JSON 对象（收到: …）")`；
     解析失败 → `Err("cfg 不是合法 JSON（片段: …）")`；**不再回落成文件路径**；
  2. 含换行或长度 > 4096 ⇒ `Err("cfg 既不是配置对象 JSON 也不是可用的文件路径（长度 N，片段: …）")`；
  3. 其余才当路径交给 `from_file`。
- `from_file`：路径 > 4096 直接 `Err("配置文件路径过长（N 字符，上限 4096）: …")`；
  「读取配置文件失败」/「不是合法 JSON」里的路径与系统错误都截断到 ≤200 字符。

**效果对比（实测，探针 P3）**

| 输入 | 修复前 | 修复后 |
|---|---|---|
| 2048 层深 JSON 文本（12311 字符） | `Err(读取配置文件失败: {"key": "k", "junk": {"a":{"a":…`（整段回显） | `Err(cfg 不是合法 JSON（片段: {"key": "k", "junk": {"a":…）`（≤120 字符） |
| 8192 层深 JSON 文本 | `ENAMETOOLONG: name too long, open 'E:\…\{"key": …'` | `Err(cfg 不是合法 JSON（片段: …）` |
| `[1, 2, 3]` | `Err(读取配置文件失败: [1, 2, 3]: ENOENT …)`（说成文件问题） | `Err(配置必须是 dict/JSON 对象（收到: [1, 2, 3]）)` |

**回归测试**：`test-suit/rhop/config_test.mbt` 新增 4 例（C2-01 段）：
非对象 JSON 文本、超长非法文本（12KB，断言错误串 < 400 且不含「读取配置文件失败」/ENAMETOOLONG）、
多行文本、超长路径（>4096 → 「路径过长」+ 上限提示）；`deep_json_text(2048)` 用例只断言
「**绝不**回落成读文件」——不依赖各目标解析器的深度上限（js 接受 600 层、2048 层拒绝，wasm/native 上限不同，故不做绝对断言）。

### FIX-C2-02（P1）`rhop.echo` 回执掩码：不再泄漏跳板机口令 / 私钥路径

**文件**：`rhop/actions.mbt` `rhop_echo`
- `"cfg": cfg` → `"cfg": cfg_mask_deep(cfg)`（复用 `rhop/config.mbt` 的同一套掩码口径：
  `password/passwd/key_path/private_key/secret/token/api_key/access_token/refresh_token`，
  大小写不敏感、对象/数组递归下钻、非敏感字段与键序不变）。
- 出参形状不变（`status/action/cfg/payload/offline`），未加新键。
- `RhopConfig::action_cfg()` **保持原文**（`jump.push/pull/sync` 真连 SFTP 需要凭据），
  泄漏面收口在「回显/回执」一侧 —— 与 `to_dict` 已深度掩码的口径一致。

**实测（探针 P7）**：`rhop.echo leaks: sftp_pw=true key_path=true` → 修复后 `false / false`；
`interact(execute) leaks: sftp_pw=false`。`to_dict` 三项本就 false（未回归）。

**回归测试**：`test-suit/rhop_interact/interact_test.mbt` 新增
「interact · C2-02：rhop.echo 回执不再泄漏 sftp 口令 / key_path」——
断言回执不含口令/私钥路径、`password`/`key_path` 为 `"***"`、`host`/`dir`/`config_name` 与 `payload.marker` 仍完整（自检能力不回退）。

### FIX-C2-03（P2）`safe_filename` 平台化收紧：纯点号 / Windows 设备名 / 结尾点

**文件**：`rhop/session.mbt`
- 新增 `fn is_windows_device_name(name)`：base（第一个 `.` 之前）大小写不敏感匹配
  `CON/PRN/AUX/NUL/CLOCK$` 与 `COM1..COM9/LPT1..LPT9`。
- `safe_filename` 在原有长度/字符集/`..` 检查之后追加三条拒绝：
  1. 纯点号（`.`、`...`）→ `Err("包文件名不能是纯点号…")`；
  2. 结尾点（`a.`）→ `Err("…不能以 \"\.\" 结尾（Windows 会静默抹掉结尾点…）")`；
  3. Windows 保留设备名 → `Err("…不能是 Windows 保留设备名（CON/PRN/AUX/NUL/COM1-9/LPT1-9）…")`。

**理由（探针 P1/P2 实测）**：
- `.` 通过白名单后 `send_package(".")` 要走到 `rename` 才失败（`EPERM`），而 `exists(".")` 恒 true（目录）→ 信号误导；
- `NUL.rhop/CON.rhop/COM1.rhop` 通过白名单：Node 因 `\\?\` 形式会建成**真实文件**，
  但 cmd/PowerShell/普通 Win32/运维脚本会解析成**设备**（写入被丢弃/读取挂起）→ 换实现就「假成功丢数据」；
- 结尾点在 Win32 被抹掉、POSIX 保留 → 同一逻辑名两平台指向不同文件（跨端 A 写 B 找不到包）。

**回归测试**：`test-suit/rhop/session_test.mbt` 新增 1 例（C2-03 段）：
拒绝 `.`/`..`/`...`、`NUL.rhop/nul.rhop/CON/con.txt/PRN/AUX/COM1/COM9/LPT1/lpt3/CLOCK$`、`a.`/`pkg.rhop.`；
放行 `console.rhop/com0.rhop/com10.rhop/lpt0.rhop/a.rhop/-x.rhop/x.y.z/nulish.rhop`（确认没把白名单收过头）。

### FIX-验证型回归（无产品改动，C2-08 / C2-05）
`test-suit/rhop_interact/interact_test.mbt` 新增 2 例：
- **C2-08 资源**：目标名被目录占用 → 原子写 rename 失败给 `status:error` 收据，
  `readdir` 里**没有 `.tmp`**；roundtrip 请求包写失败 → `status:error + phase=send` 且**不产生** `res_` 半成品。
- **C2-05 并发语义固定**：同一缺省包名连发两次 → 介质上只留 1 个包，解密确认残留的是**后写者**
  （`BBB` 在、`AAA` 不在）——把「同名并发会丢前一个请求」这个事实钉进测试，防止未来误以为会排队。

## 2. 本轮**未**改动（有意保留，已在寻虫报告给出理由）

| 编号 | 决定 | 理由 |
|---|---|---|
| C2-04 探测副作用/代价（http 介质 `available()`≈0.5 s、起 node 子进程） | 仅文档化 | 语义级改动（探测缓存/去重）会改变「可用性实时性」契约；本轮只量化 + 标注「勿在热路径高频调用」 |
| C2-05 同名请求覆盖 | 文档化 + 回归固定 | 缺省包名 `req_<action>.rhop` 是契约字面量；唯一化属 daemon/executor 层（Batch D），API 冻结期不做 |
| C2-06 注册表无锁/重入 | 文档化 | 当前无可达的「迭代中写入」路径；改实现（快照迭代）属防御性优化，留给后续轮次 |
| C2-07 `interact_nonce : Ref[Int32]` 溢出 | 文档化 | 需 2^31 次 roundtrip 才回绕，且回绕不致错判；改 Int64 会动内部实现，非本轮必要 |
| C2-09 Session trait object 生命周期 | 仅结论入档 | GC 托管无悬垂；`pick_relay()` 值拷贝当前无状态丢失，但**注意项**已写进寻虫报告（未来给 RelayChannel 加 `mut` 状态需改持有方式） |

## 3. 改动文件清单

**产品（3）**
- `rhop/config.mbt`：`CFG_PATH_MAX_LEN` + `cfg_snippet` + `load_config` 形状判定 + `from_file` 加固（FIX-C2-01）
- `rhop/actions.mbt`：`rhop_echo` 回执掩码 + 文档（FIX-C2-02）
- `rhop/session.mbt`：`safe_filename` 三条拒绝 + `is_windows_device_name`（FIX-C2-03）

**测试（3）**
- `test-suit/rhop/config_test.mbt`：+4 例（C2-01）
- `test-suit/rhop/session_test.mbt`：+1 例（C2-03，含放行集合）
- `test-suit/rhop_interact/interact_test.mbt`：+3 例（C2-02 / C2-08 / C2-05）

**报告（2）**：本文件 + `2026-10-28-c2-bugfind-session-config.md`
**临时物**：`test-suit/rhop_interact/scratch_probe_test.mbt`（探针）已删除，`moon.pkg` targets 已复原。

## 4. 验证（Windows + WSL）

### 4.1 Windows（Git Bash，moon 0.1.20261016 + node v25）
```
moon check                 → 0 errors（268 warnings）
moon check --target js     → 0 errors（248 warnings）
moon check --target native → 0 errors（270 warnings）
moon test test-suit/rhop                  → Total tests: 156, passed: 156, failed: 0.
moon test test-suit/rhop --target js      → Total tests: 160, passed: 160, failed: 0.
moon test test-suit/rhop --target native  → Total tests: 156, passed: 156, failed: 0.
moon test test-suit/rhop_interact --target js → Total tests: 22, passed: 22, failed: 0.
moon test                 → Total tests: 612, passed: 612, failed: 0.
moon test --target js     → Total tests: 819, passed: 819, failed: 0.
```

### 4.2 WSL（Ubuntu-22.04，`--target-dir _build/wsl` 隔离，经 `scripts/with_moon_lock.sh`）
```
moon check --target js                    → 0 errors（250 warnings）
moon test test-suit/rhop                  → Total tests: 156, passed: 156, failed: 0.（wasm）
moon test test-suit/rhop --target js      → Total tests: 160, passed: 160, failed: 0.
moon test test-suit/rhop --target native  → Total tests: 156, passed: 156, failed: 0.
moon test test-suit/rhop_interact --target js → Total tests: 22, passed: 22, failed: 0.
moon test                 → Total tests: 612, passed: 612, failed: 0.
moon test --target js     → Total tests: 819, passed: 819, failed: 0.
```

### 4.3 双平台一致性结论
| 入口 | Windows | WSL | 一致 |
|---|---|---|---|
| `moon check`（默认/js/native） | 0 / 0 / 0 errors | 0 errors（js 复核） | ✅ |
| `test-suit/rhop`（wasm） | 156/156/0 | 156/156/0 | ✅ |
| `test-suit/rhop --target js` | 160/160/0 | 160/160/0 | ✅ |
| `test-suit/rhop --target native` | 156/156/0 | 156/156/0 | ✅ |
| `test-suit/rhop_interact --target js` | 22/22/0 | 22/22/0 | ✅ |
| 全量 `moon test`（wasm） | 612/612/0 | 612/612/0 | ✅ |
| 全量 `moon test --target js` | 819/819/0 | 819/819/0 | ✅ |

> 过程留痕：WSL 全量套件首跑曾撞上 `rhop/relay.mbt:156` 的在途编辑（别人 lane 的 parse error）；
> 该文件落定后按上表严格复跑，全部 `failed: 0`。说明多 lane 并发下**必须**用 `with_moon_lock.sh`
> 串行化并在别人落盘窗口后复跑，否则红不是本任务造成的。

## 5. 遗留风险 / 后续建议

1. **C2-04 探测代价**：带 relay/http 介质的 `interact` 一次 roundtrip 有 1.5~2.5 s 纯探测开销
   （每轮建 2~3 个 session，各自真实探测）。建议后续轮次引入「探测结果按调用去重 / 可选 TTL 缓存」，
   本轮不动语义。
2. **C2-05 并发丢请求**：缺省包名不唯一。daemon/executor（Batch D）应显式传唯一 `request_filename`
   或做队列化；否则同一介质上的并发请求会互相覆盖（已由测试固定为「后写者胜」）。
3. **C2-06/C2-07**：注册表与 nonce 的单线程假设已文档化；若将来引入多线程执行体，需要加同步/换 Int64。
4. **C2-09 注意项**：`RelayChannel` 目前无 `mut` 状态，`pick_relay()` 的值拷贝安全；
   一旦给它加连接复用缓存，需同步改 `Session::pick_relay`（改为持有引用或在 Session 内保存原对象）。
5. 本轮 `moonfmt` 仅格式化我改动的 3 个产品文件/3 个测试文件（`~/.moon/bin/moonfmt.exe -w`）；
   `moon fmt` 在本机仍不可用（program not found），全量格式一致性仍建议在 Lead gate 侧复核。