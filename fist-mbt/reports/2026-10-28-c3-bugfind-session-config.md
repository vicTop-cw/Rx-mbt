# 2026-10-28 · C3 寻虫报告 · 会话 / 配置 / 交互域（契约与文档一致性 + 互操作盲区 + 清整）

- 状态：寻虫完成；修复见 `fist-mbt/reports/2026-10-28-c3-fix-session-config.md`
- 执行者：impl-session
- 域：`rhop/{session,config,interact,actions}.mbt` + `test-suit/rhop/{session,config}_test.mbt` + `test-suit/rhop_interact/`
- 纪律：只读审计 + 实测；moon 命令一律 `bash scripts/with_moon_lock.sh moon ...`；WSL 用 `--target-dir _build/wsl`
- 基线（本域，改前）：`test-suit/rhop` wasm/js/native = 156/160/156 全绿；`rhop_interact` js = 22/22/0

## 0. 结论摘要

| 编号 | 级别 | 关注点 | 标题 | 处置 |
|---|---|---|---|---|
| C3-01 | **P1（卫生）** | ① | `interact_test.mbt` 每轮在 `%TEMP%` 留 **18** 个 `rhop-*` 目录（无退出钩子），Windows/WSL 均无界堆积 | **已修**（改走产品 `rhop_temp_workspace`，实测 +18 → **+0**） |
| C3-02 | **P1（文档错误）** | ②③ | 矩阵 §4.3 称 `action_cfg` 为「脱敏后视图」，**实际是原文（含 sftp.password）** —— 正好把 C2-02 的安全口径写反 | 报告 + 代码 doc 已修，矩阵待 Lead 改 |
| C3-03 | P2（文档） | ② | 矩阵 §4 / DOC.md / README 的 Batch C 测试数与签名/回执字段过期：session 15→**20**、config 18→**25**、interact 13→**22**；`send_package` 回执被写成含 `payload`（实际是 `role`，payload 只在 recv） | 报告 + DOC 建议 patch |
| C3-04 | P2（文档缺口） | ② | DOC.md 漏列 4 个已发布符号：`safe_filename`、`Session::remove_package`、`unregister_action`、`rhop_echo`；矩阵漏列前两个 | 报告 + 代码 doc 已补 |
| C3-05 | P2（语义清单） | ③ | vools 语义差异清单**不完整**：13 条中 6 条只在代码注释里、README「差异摘要」7 条未覆盖任何 Batch C 项 | 报告 + 代码 doc 全部补齐（D3/D6/D7/D8/D9/D10/D12） |
| C3-06 | P2（互操作） | ④ | 跨平台 secret 读取差异：**CRLF 密钥文件**（Windows 写、WSL 读）未被任何用例覆盖；Windows 风格 `key_path`/`E:\` 路径在 WSL 必然 ENOENT 但无文档 | 报告 + 新增 CRLF 回归用例 + doc |
| C3-07 | P3（文档） | ②③ | 探测代价（C2-04）与「不产生副作用」表述冲突：`available()/select()` 对 relay/online/http **会起子进程 + 发网络请求**，doc 只说「不建目录不写文件」 | 代码 doc 已修（语义不变） |
| C3-08 | P3（文档） | ③ | `interact` 缺「失败相位词表」（send/request/receive/response）与「唯一包名要求」（C2-05）、nonce 单线程/溢出（C2-07）说明 | 代码 doc 已修 |

---

## 1. ① temp 卫生（QA C2-V1）：实测 +18/轮 → 修复后 +0/轮

### 1.1 量化（Windows，`%TEMP%` = `C:\Users\victo\AppData\Local\Temp`）
```
# 清掉历史残留后建立基线
$ ls -d $TEMP/rhop-* | wc -l          → 7        # 其它 lane 留下的 rhop-git-*/rhop-actions-*/rhop-sftp-*（非本域）
$ moon test test-suit/rhop_interact --target js  → Total tests: 22, passed: 22, failed: 0.
$ ls -d $TEMP/rhop-* | wc -l          → 25       # +18
$ ls -d $TEMP/rhop-it-* | wc -l       → 16       # it_dir("rhop-it-…")
$ ls -d $TEMP/rhop-c2-* | wc -l       → 2        # C2 轮新增用例 it_dir("rhop-c2-…")
```
即 **每跑一轮 interact 测试 = 18 个临时目录永久残留**（22 个用例里 18 处 `it_dir`），与 QA C2-V1 的 18 一致。

### 1.2 根因
`test-suit/rhop_interact/interact_test.mbt` 的 `ffi_tmp` 是裸 `fs.mkdtempSync(os.tmpdir()/prefix)`：
**没有任何清理钩子**，测试也不删除；Windows 与 WSL 行为一致地堆积（`/tmp/rhop-it-*`）。

### 1.3 修法（采纳 Lead 建议的「产品已有 API」）
产品侧 `rhop/mirror.mbt: rhop_temp_workspace(prefix)` 的 FFI 在 `mkdtempSync` 之后把目录登记到
`globalThis.__rhop_tmp_dirs`，并注册一次性 `process.on("exit")` 钩子 → 进程退出时
`fs.rmSync(dir, { recursive: true, force: true, maxRetries: 5 })` 递归清理（生产代码同路径，已被 mirror 用例使用）。

修复：
- `it_dir(tag)` 改为 `@rp.rhop_temp_workspace(tag + "-")`（失败 → `abort` 带原因）；
- 删除裸 `ffi_tmp` extern（否则留一个未使用的 FFI + 两个创建路径）。

### 1.4 修复后实测
```
$ ls -d $TEMP/rhop-* | wc -l          → 7        # 基线
$ moon test test-suit/rhop_interact --target js  → Total tests: 22, passed: 22, failed: 0.
$ ls -d $TEMP/rhop-* | wc -l          → 7        # +0
$ ls -d $TEMP/rhop-it-* | wc -l       → 0
$ ls -d $TEMP/rhop-c2-* | wc -l       → 0
```
**before +18 / after +0**（WSL 侧同一实现，见修复报告 §4 的 `/tmp` 计数）。

### 1.5 残留风险（诚实记录）
退出钩子在**进程正常退出**时执行；若测试进程被强杀（超时/OOM/CI 取消），当轮目录仍会残留。
缓解：该 API 与 mirror 生产路径共用同一钩子，CI 里超时本就是异常路径；不建议在测试里加「某处统一删除」
（会与并行 lane 的目录混淆），保持「谁创建谁登记、进程退出统一清」的单一机制。

---

## 2. ② 文档 / 矩阵一致性（逐条 diff，位置精确到行）

### 2.1 测试用例数（全部过期）
| 位置 | 现在写的 | 实际（`grep -c '^test '`） | 建议 |
|---|---|---|---|
| 矩阵 `§4` 引言（L256-258） | `session_test.mbt` 15 例、`config_test.mbt` 18 例、`interact_test.mbt` 13 例 | **20 / 25 / 22** | 改成 20 / 25 / 22 |
| 矩阵 `§4.2`（L276） | `rhop_interact/interact_test.mbt`（13 例） | **22 例** | 改成 22 |
| 矩阵 `§4.3`（L283） | `config_test.mbt`（18 例） | **25 例** | 改成 25 |
| README L73 | 「rhop 相关 253 例（js）/ 121 例（wasm、native…）」 | 本域 js 160、wasm/native 156；**项目级** js 819 / wasm 612（矩阵 §9 快照同源） | 改成 819 / 612（并注明随 lane 变动） |
| README L329/331 | 「rhop 相关 156 例（wasm）/ 156 例（native）」 | 正确（156/156） | 保持 |

### 2.2 签名 / 回执字段错误
1. **矩阵 §4.1 `Session.send_package` 行（L266）**：备注「回执 `{status, transport, filename, payload}` 同形」——
   实际 **send** 回执是 `{status, transport, filename, role}`，`payload` 只出现在 **recv** 回执。
   同一错误也出现在 **DOC.md L939**（"`send_package` 回执 `{status, transport, filename, payload}` 与 vools 同形"）。
2. **矩阵 §4.3 `action_cfg` 行（L293 附近）**：写「动作层视图（脱敏后）」——**方向反了**。
   实际 `action_cfg()` 返回 **sftp 原文**（含 `password` / `key_path`；`jump.push/pull/sync` 真连 SFTP 需要凭据）。
   C2-02 的收口是「**回执/回显侧**掩码」（`rhop.echo`），不是 `action_cfg`。建议改为：
   > 动作层视图（**含 sftp 原文凭据**，供 jump.* 真连；严禁直接落日志；回显侧由 `rhop.echo` 掩码）
3. **矩阵 §4.3 `to_dict` 行**：写「`sftp.password`/`sftp.key_path` → `"***"`（与 vools 同）」——
   实际已升级为**递归深度脱敏**（`sftp`/`online`/`shared`/`relay` 全下钻，键表 `password/passwd/key_path/
   private_key/secret/token/api_key/access_token/refresh_token`），比 vools **更严**；DOC.md 的 `to_dict` 注已同步，
   矩阵这一行还旧。
4. **矩阵 §4.2 `interact` 目标列**写「三目标」：编译成立，但**真实闭环（roundtrip/文件介质/Fernet）仅 js**。
   建议备注「三目标可编译；execute 全域可用，request/roundtrip 实际仅 js」。

### 2.3 DOC.md 漏列已发布符号（L917-973 三个代码块）
| 漏列符号 | 出处 | 类型 | 建议 |
|---|---|---|---|
| `pub fn safe_filename(String) -> Result[String, String]` | `session.mbt` | **P0 安全边界**（send/recv/remove/interact 缺省名都过它） | 补进 `session.mbt` 代码块 + 一句规则说明 |
| `pub fn Session::remove_package(Self, String) -> Result[Unit, String]` | `session.mbt` | roundtrip 一次性消费（F1） | 补进 `session.mbt` 代码块 |
| `pub fn unregister_action(String) -> Bool` | `actions.mbt` | 增量注册表 | 补进 `interact.mbt / actions.mbt` 代码块 |
| `pub fn rhop_echo(Json, Json?) -> Json` | `actions.mbt` | 离线自检动作（**注意：回执掩码**） | 补进同块 |
（`get_handler` 在 DOC 中出现 1 次但并不在 §interact/actions 代码块里，建议一并归位。）

### 2.4 矩阵「全量符号统计」口径
矩阵 L544/557 的「契约范围 192」按 §3 清单计；而 **C1/C2 增量已把本域公开面扩到**
`Session::select/remove_package/has_*、safe_filename、_key_from_cfg、RhopConfig::new/has_key/name/role、
actions: unregister_action/get_handler/rhop_echo/jump_*` 等（矩阵 §6 只列了一部分）。
建议在 §6「增量 API」表补 `safe_filename` / `Session::remove_package` / `unregister_action` 三行，
并注明「增量不计入 192 的分母」。

---

## 3. ③ vools 语义差异清单（13 条，标注文档化状态）

> 图例：✅ = 代码 doc 已写明；⚠️ = 只在实现里、doc 缺失（本轮补）；❌ = 全库无文档。

| # | 差异（vools → 本项目） | 状态（修前） | 落点 |
|---|---|---|---|
| D1 | 介质/解密失败：vools 抛异常 → 本项目 `Ok({status:"error",…})` 收据；参数/配置类才 `Err` | ✅ | `session.mbt` `send_package`/`recv_package` doc |
| D2 | `Role` 用 `pub(all) enum`（vools 用字符串常量 `SEND/RECV/RELAY`） | ✅ | `session.mbt` `Role` doc |
| D3 | **`Session` 无 `relay_server` 字段**（vools 会话内挂中转服务端；本项目 `RelayServer` 独立生命周期） | ⚠️ | 本轮补进 `Session` doc |
| D4 | `describe()` 逐字同形（vools `getattr` 缺失给 null） | ✅ | `session.mbt` `describe` doc |
| D5 | `select()` 用会话层标签 `relay/online/shared/none`（与 `select_transport` 的 `online/shared/none` 词汇不同） | ✅ | `session.mbt` `select` doc |
| D6 | **`safe_filename` 白名单是纯增量**（vools 直接把文件名拼进路径，无校验） | ⚠️ | 本轮补进 `safe_filename` doc |
| D7 | **`remove_package` 是增量**（vools 无删除契约；本项为 F1「一次性 res_ 」而加） | ⚠️ | 本轮补进 `remove_package` doc |
| D8 | **`interact` 的一次性 token / 陈旧 `res_` 清理 / 四相位错误**（vools 无；vools 只按 status 判） | ❌ | 本轮补进 `interact` doc |
| D9 | **`load_config` 三形态**（vools 只有 dict / 路径；本项目额外接受 JSON **文本**并按形状判定，C2-01） | ✅（C2-01 时已写） | `config.mbt` `load_config` doc |
| D10 | `_key_from_cfg` 对数字/布尔 key：本项目按 **JSON 文本**（`"12345"` / `"true"`），vools `str()` 给 `"12345"` / `"True"`（大小写不同） | ⚠️ | 本轮补进 `_key_from_cfg` doc |
| D11 | `to_dict` **递归深度脱敏**（vools 仅 sftp 两项），安全优先 | ✅ | `config.mbt` `to_dict` doc |
| D12 | **`interact` 只接受 `RhopConfig`**（vools `_coerce` 接受 RhopConfig/dict/路径三形态；本项目调用方先 `load_config`） | ❌ | 本轮补进 `interact` doc |
| D13 | `actions`: handler **不得 raise**（vools 用 `try/except` 收容）；未知动作给结构化错误 | ✅ | `actions.mbt` `run_action` doc |

**README「差异摘要」7 条未覆盖任何 Batch C 项**（第 3 条「错误表达 Result」只覆盖了大方向）。
建议在 README 差异表追加 3 行（D1 收据分流 / D6+D7 safe_filename+remove_package 增量 / D8+D12 interact 的 token 与入参形态）。

---

## 4. ④ secret / 路径处理在 WSL 与 Windows 的差异

### 4.1 结论：**脱敏逻辑本身与 OS 无关**，差异全在「路径与文件形态」
- `cfg_mask_deep` / `cfg_is_secret_key` 只按 **JSON 键名**（`to_lower()`）匹配 → Windows/WSL 输出**逐字节一致**；
  `to_dict` 的掩码结果不含任何路径，故不存在平台差异（已由 `config_test.mbt` 三目标用例覆盖）。
- 差异点集中在 **`key: {"path": …}` / `key_path` / `shared` 地址**：

| 场景 | Windows | WSL | 本项目行为 |
|---|---|---|---|
| 密钥文件路径 | `E:\keys\rhop.key`、`C:/keys/rhop.key` | `/root/.rhop/key`、`/mnt/e/keys/rhop.key` | 原样交给 `fs.readFileSync`；**跨平台路径不互通**（Windows 形态在 WSL 必 ENOENT），错误文案可诊断（C2-01 已截断） |
| `file://` shared 地址 | `file:///E:/share` → `file_url_to_path` → `E:/share` | `file:///mnt/e/share` → `/mnt/e/share` | 两平台各自正确（`transport_endpoint.mbt` 已覆盖三种形态；WSL 形态未单测，但纯字符串逻辑） |
| 路径分隔符 | `normalize_path` 把 `\`→`/` | 无 `\` | 统一 `/`，测试里都走 `normalize_path` |
| **密钥文件换行** | Windows 编辑器常写 **CRLF** | POSIX 常写 LF | `load_key_from_path` 走 `trim()`（含 `\r`）→ 两平台都能读；**但没有专门用例**（本轮补） |
| 临时目录 | `%TEMP%\rhop-*`（反斜杠） | `/tmp/rhop-*` | 测试统一 `normalize_path` 后写进 JSON；C3-01 已改为退岀即清 |
| 环境变量密钥 `RHOP_KEY` | `@env.get_env_var` | 同左 | 三目标一致；env 缺失给可诊断 Err |
| 隐式 `~` 展开 | ❌ 不支持（两平台都不展开 `~`） | ❌ 同 | **文档未写**（建议在 `key.mbt` / DOC 注明「不做 `~` 展开，请给绝对路径或环境变量」——`key.mbt` 非本轮作用域，故只报告） |

### 4.2 本轮补的互操作用例（C3-06）
`test-suit/rhop_interact/interact_test.mbt` 新增：**CRLF 外层密钥文件**解锁 `{"key": {"cipher": …, "path": …}}`
—— 模拟「Windows 上生成的密钥文件在 WSL 上使用」，并顺带断言密文/明文正常（不因 `\r` 污染解密）。
（真正跨 OS 的路径互通用例不适合放单机测试；已在报告 4.1 表格里作为已知限制记录。）

### 4.3 顺带发现（只报告，不在本轮作用域）
- `rhop/key.mbt` 的 `load_key` 优先级 `source > path > env` 与本项目「空串按未提供处理」的差异已文档化 ✅；
- `rhop/clipboard.mbt` / `rhop_task` 的 secret 处理也走 `cfg_is_secret_key` 同口径（跨 lane 一致性 OK）；
- WSL 下 `%TEMP%` 语义为 `/tmp`，QA 脚本 `test_all.sh` 已隔离 `_build/wsl`，不会与 Windows `_build` 互污染 ✅。

---

## 5. 本轮修复范围（详见 fix 报告）

| 类别 | 文件 | 内容 |
|---|---|---|
| 卫生修复 | `test-suit/rhop_interact/interact_test.mbt` | `it_dir` 改走 `@rp.rhop_temp_workspace`，删裸 `ffi_tmp`（+18 → +0） |
| 文档补齐（代码 doc） | `rhop/session.mbt` | `safe_filename` 规则补 C2-03；`available/select` 补探测代价（子进程/网络）；`remove_package` 标「vools 无·增量」；`Session` 补「无 relay_server 字段」；`reverse/pick_relay` 补值拷贝注意项 |
| 文档补齐（代码 doc） | `rhop/config.mbt` | `action_cfg` 明确「sftp 原文凭据，严禁直接落日志」；`_key_from_cfg` 补数字/布尔口径差异（D10）；`load_config` 补「vools 只有 dict/路径，本项目三形态」 |
| 文档补齐（代码 doc） | `rhop/interact.mbt` | 补四相位词表、一次性 token/陈旧 res_ 清理（D8）、只接受 RhopConfig（D12）、唯一包名要求（C2-05）、nonce 单线程/溢出（C2-07） |
| 回归测试 | `test-suit/rhop_interact/interact_test.mbt` | CRLF 密钥文件解锁（C3-06） |

**不改**：任何公开 API 签名、任何运行时行为（除测试临时目录来源）、文档类大文件（DOC.md/README/矩阵，
属 Lead/QA 作用域 → 本报告给出精确行号与替换文本，由 Lead 落笔）。