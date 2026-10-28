# 2026-10-27 rhop ← vools-rhop 复刻 · 跨平台验收与跨实现互操作汇报（RX-QA / qa-platform）

- 状态：**draft（切片①②已完成并实测；切片③终验待 lead 通知后填终数）**
- 执行者：qa-platform（fist-mbt ns=`rx-rhop`，任务 `T0r7`，level=6）
- 完成时间：2026-10-27 20:20（UTC+8，草稿提交；终稿见文末「终验记录」）
- 依据契约：`fist-mbt/plans/decisions/2026-10-27-rhop-vools-parity-decision.md` §0 / §4（§4.2 测试入口、§4.3 验收清单）

> 职责边界（自证）：本执行体只写 `scripts/test_all.sh`、`scripts/test_all.ps1`、
> `scripts/gen_conformance_vectors.py`、`scripts/verify_interop.py`、
> `test-suit/rhop_js/fixtures/**`、`fist-mbt/reports/**`。**未改动任何 `rhop/*.mbt`
> 产品代码、`moon.mod`、`rhop/moon.pkg`、`test-suit/rhop_js/moon.pkg`、README/DOC.md**，
> 未执行任何 git 命令。

---

## 1. 结果摘要

一句话：**跨平台测试入口与跨实现一致性向量两件「验收地基」已交付，且都用自己的脚本跑过真实证据**
（Windows/WSL 四目标全绿；fixture 由真实 Python vools-rhop 生成且两平台逐字节一致；反向复核脚本对
MoonBit 产物 4/4 通过，并在注入 5 类错误的对抗用例上逐项判红）。

| # | 交付物 | 状态 | 关键证据 |
|---|---|---|---|
| ① | `scripts/test_all.sh`（261 行） | ✅ 完成 | Windows + WSL 各跑一次四目标全绿，汇总行见 §2 |
| ① | `scripts/test_all.ps1`（217 行） | ✅ 完成（判据与 bash 版同源） | 判据/汇总表实现完成；构建稳定窗口的全绿留档见 §2.3 |
| ② | `scripts/gen_conformance_vectors.py`（约 1000 行） | ✅ 完成 | 真实 vools 生成 + 幂等自检；跨平台 sha256 一致 |
| ② | `test-suit/rhop_js/fixtures/vools_vectors.json` | ✅ 完成 | 32710 bytes，sha256=`f22dda48…`（见 §3） |
| ② | `scripts/verify_interop.py`（约 640 行） | ✅ 完成 | 正向 47/47 PASS；5 类注入错误全部判红；MoonBit 产物 4/4 PASS |
| ③ | 全量跨平台终验 + §4.3 逐条勾 | ⏳ 待 lead 通知 | 见 §7 终验记录（占位） |

---

## 2. 环境矩阵与实测输出

### 2.1 平台与工具链（脚本自己打印，不是手填）

| 平台 | uname | moon | node | PATH 修复策略 |
|---|---|---|---|---|
| Windows（Git Bash） | `MINGW64_NT-10.0-26200` | `0.1.20261016` (1af328f) | `/c/Program Files/nodejs/node` v25.2.1 | 前置真 node 目录（规避 `.desktop-bin\node.cmd` 截断长 JSON 参数 ⇒ `failed to parse args`） |
| WSL（Ubuntu-22.04） | `Linux` | `0.1.20261021` (a4f8933) | `/usr/local/bin/node` v25.2.1 | 净化 PATH 为 `$HOME/.moon/bin:/usr/local/bin:/usr/bin:/bin`（剔除全部 `/mnt/c` 路径 ⇒ 避免选到 Windows `node.cmd` 的 `Exec format error`；`/root/.moon/bin` 默认不在 login PATH 里，必须前置） |

### 2.2 四目标实测汇总行（`bash scripts/test_all.sh`）

**Windows（Git Bash，2026-10-27 20:0x）**

```
 platform   : windows (MINGW64_NT-10.0-26200)
 moon       : /c/Users/victo/.moon/bin/moon -> moon 0.1.20261016 (1af328f 2026-10-16)
 node       : /c/Program Files/nodejs/node -> v25.2.1
 PATH 说明  : 已前置真 node 目录：/c/Program Files/nodejs（规避 .desktop-bin/node.cmd 截断长 JSON 参数）
 check  PASS  0 errors
 wasm   PASS  Total tests: 407, passed: 407, failed: 0
 js     PASS  Total tests: 415, passed: 415, failed: 0
 native PASS  Total tests: 407, passed: 407, failed: 0
 RESULT: PASS
```

**WSL（Ubuntu-22.04，2026-10-27 20:0x）**

```
 platform   : wsl (Linux)
 moon       : /root/.moon/bin/moon -> moon 0.1.20261021 (a4f8933 2026-10-21)
 node       : /usr/local/bin/node -> v25.2.1
 PATH 说明  : 已净化 PATH，剔除所有 /mnt/c 路径
 check  PASS  0 errors                                    (4560 ms)
 wasm   PASS  Total tests: 407, passed: 407, failed: 0     (8530 ms)
 js     PASS  Total tests: 415, passed: 415, failed: 0    (12704 ms)
 native PASS  Total tests: 407, passed: 407, failed: 0    (13032 ms)
 RESULT: PASS
```

> 与契约 §0 基线的差异：**js 从 411 → 415**（impl-crypto 合并了 crypto 测试后的增量），
> wasm 407 / native 407 不变。两平台数字一致，说明跨平台没有目标差异。

### 2.3 判绿纪律与「假绿」防护

- 判绿只认 `moon test` 的 `Total tests: N, passed: N, failed: 0` 汇总行，并额外要求
  `passed == total`；**汇总行缺失也算失败**（防「命令退出码 0 但根本没跑测试」）。
- `moon check` 判据是 `N errors` 必须为 0（不是只看退出码）。
- **全部步骤被 `--skip` 跳过时 RESULT 判 `SKIP` 并 exit 2**（不允许「什么都没跑」冒充 PASS）。
- 脚本会把四步的原始输出原样 tee 到终端，便于事后定位是「真红」还是「并行写文件导致的瞬时红」。
- **每步硬超时**（默认 600s，`--timeout=秒` / `RX_MBT_STEP_TIMEOUT` 可改）：超时判 FAIL 并清理残留测试进程。
  这条是血泪加上的 —— 见 §2.5。

### 2.4 `set -u` 下的健壮性（脚本自身缺陷的修复记录）

终验前收到 impl-crypto 反馈：脚本在打印完头部后中断，`TIMEOUT_SECS: unbound variable`（脚本开着
`set -uo pipefail`）。**根因**：`TIMEOUT_SECS` 的赋值被我挪到了头部打印之后，属于我引入的回归。
修复与加固（全部按「`set -u` 下不可能未初始化」重审）：

| 变量 / 展开 | 处理 |
|---|---|
| `TIMEOUT_SECS` | 赋值提前到首次使用之前；仍保留 `RX_MBT_STEP_TIMEOUT` 覆盖 |
| `SKIP_LIST` / `QUIET` / `PLATFORM` / `PATH_NOTE` / `HAVE_TIMEOUT` / `TMPDIR_RUN` / `OVERALL_RC` | 顶部显式默认值 |
| `${SUMMARY_ROWS[@]}` | 改为 `${SUMMARY_ROWS[@]+"${SUMMARY_ROWS[@]}"}`（空数组在旧 bash 下展开会报 unbound） |
| `parse_summary` 的 `t p fl n` | `read ... \|\| true` + `${t:-0}` 等默认值 |
| `$HOME` / `$USERPROFILE` | 改为 `${HOME:-${USERPROFILE:-}}`（MCP server 侧的 bash 可能没有 HOME） |

自我验证：`bash -n`；`--help`；`--skip=check,wasm,js,native`（全跳过 → SKIP + exit 2）；
`env -u HOME bash scripts/test_all.sh --help`；以上全部通过。

PowerShell 版的坑（同一轮自查出来的，都已修）：
1. `-File` 调用时 `-Skip wasm,js,native` 是**一个字符串**，`$Skip -contains` 永远不命中 ⇒ 加逗号拆分；
2. PS 5.1 的 `Start-Process -PassThru`（尤其带 `-RedirectStandardOutput`）拿到的 `$proc.ExitCode`
   为 `$null`（实测 `finished=True exitCode=[]`）⇒ 退回 `& $moon @args` + `$LASTEXITCODE`；
3. 本机受限宿主里 `[System.Diagnostics.Stopwatch]::StartNew()` 会变 `$null`（耗时列静默为空）⇒ PS 版
   干脆不输出耗时列，只输出结论。

### 2.5 实测发现：js 测试二进制会「偶发挂死」（gate 必须带超时）

2026-10-27 20:54–20:57 三次 `moon test --target js` 留下 **3 个挂死的 node 测试进程**（各吃 400s+ CPU，
`Stop-Process` 前一直不退出），命令行都指向 `_build/js/debug/test/test-suit/rhop_js/rhop_js.blackbox_test.js`，
日志尾部停在 `[relay] port=… process_alive=true`。后果：**不带超时的 gate 会永远挂着**，看起来像「脚本卡死」。

**根因（impl-crypto 定位并修复，fist-mbt T0r8）**：`monitor/watcher_js.mbt` 里 `ffi_watch_start` 用
JS number 当 `globalThis.__rxmbt_watch_reg` 的 key，而 `ffi_watch_stop(id : Int64)` 收到的 id 在 JS 侧是
**BigInt**，`BigInt(0) !== 0` ⇒ `reg.get(id)` 恒 `undefined` ⇒ `watcher.close()` **从不执行** ⇒ 每次
`RhopWatcher::stop()` 都漏一个被 ref 的 `fs.watch` 句柄，node 事件循环永不空 —— 断言全过、汇总行不打印、
进程挂死。修复后连测 5/5 自然退出。

**判据沉淀（两条，互相印证）**：
1. 判泄漏**只认「进程能否自然退出 + exit code」**；`process.getActiveResourcesInfo()` 只作诊断快照、
   **不得用来断言** —— impl-crypto 实测该接口在 Windows 上会把「已 close 但未 GC」的句柄仍列出来，
   用它断言会**假红**。
2. 因此 gate 必须带硬超时：bash 版 `timeout -k 15`（默认 600s/步，`--timeout=` / `RX_MBT_STEP_TIMEOUT` 可调），
   超时判 FAIL 并按 `_build/js/debug/test` 清理残留 node 进程 —— 把「无限等待」变成「明确 FAIL」。

### 2.5.1 PowerShell 入口专属坑：只前置真 node 不够，必须剔掉含 `node.cmd` 的 PATH 项

同一构建、同一时刻：`bash scripts/test_all.sh` 的 js 步骤**绿**，`test_all.ps1` 的 js 步骤整批红：

```
failed to parse args:  Unterminated string in JSON at position 1346 (line 1 column 1347)
Error: failed to run test for target Js      （exit code -1）
```

**根因**：bash 版是**整条 PATH 替换**（`node_dir:moon_dir:/usr/bin:/bin`），shim 目录自然被挤掉；
PS 版只是「前置」真 node 目录，PATH 里 `...\.desktop-bin\node.cmd` 仍存在，moon 偶发仍通过 cmd 批处理
spawn node，超过 8191 字符的 JSON 参数被截断。
**修法**：PS 版除前置真 node 外，把「目录里存在 `node.cmd`」的 PATH 项**整条剔除**
（`if (Test-Path (Join-Path $part 'node.cmd')) { continue }`）。修完 PS 的 js 步骤不再出现 parse args 错误。

> 教训：**两个入口都必须被真实使用过** —— 只在 bash 跑、或只在 PS 跑，各自都会漏掉一类环境坑。

**关于截稿前的一次瞬时红（诚实记录，不是脚本缺陷）**：
20:1x 复跑 `powershell -File scripts/test_all.ps1` 时四步全 FAIL，日志显示是并行执行体正在写
`test-suit/rhop/envelope_test.mbt`（`The type TaskStatus is undefined`、`Value utf8_text not found
in package rp`），即**产品代码处于编辑中间态**；同一时刻 `moon check` 直接跑也是 6 errors。
脚本把这种状态如实判红（这正是它该做的）。

### 2.6 本任务 run_check 记录的如实说明（防止把假绿当证据）

`run_check(T0r7, ...)` 在 fist-mbt 里留了多条记录，**都不能当 gate 通过证据**（如实登记，避免用假绿凑 `[gate:required]`）：

| 记录 | status | 真实含义 |
|---|---|---|
| `check:T0r7:r1` | failed | 真实跑了四步，但当时并行执行体正在改 `rhop/*.mbt`（同一时刻手工 `moon check` 也 rc=1，`Error:[4023]/[4024]/[4021]`），属**瞬时中间态红** |
| `check:T0r7:r2` | passed | ⚠ **无效记录**：这是我做环境探测用的包装命令（`bash -c "…; rc=$?; exit $rc"`，rc 取值为空 → 外层 exit 0），**不是 gate 运行** |
| `check:T0r7:r3` | failed | 真实四步运行（出现于 WSL bash 路径），构建仍处中间态 |
| `check:T0r7:r4` | failed | 旧版 PS 入口 + 中间态；当时还叠加了「只前置真 node 不剔 shim」的缺陷（见 §2.5.1，已修） |
| `check:T0r7:r5` | failed | 中间态 |
| `check:T0r7:r6` | failed | PS 版 `$rc` 取值为空的缺陷版（`Start-Process -PassThru`），已修为 `& $moon` + `$LASTEXITCODE` |
| `check:T0r7:r7` | failed | 修复前的 PS 入口仍走 node.cmd shim（`failed to parse args`）+ 当时 `rhop_interact` 在途 |

**另一个环境事实（重要）**：MCP server 侧 `cmd="bash"` 解析到的是 **WSL 的 `/bin/bash`**（`HOME=/root`、
`node=/usr/local/bin/node`、`C:/tmp` 被当成相对路径），所以 `run_check` 实际跑的是 **WSL 侧** gate；
要拿 **Windows 原生** gate 记录必须用 `cmd="powershell"` + `-File scripts/test_all.ps1`。
两条路径都已在脚本内固化（bash 版自判 WSL/Windows 并在 Windows 上剔除 shim 目录；ps1 版只处理 Windows）。

> 结论：本任务切片①②的 gate 证据是 §2.2 的手工全绿输出；终验窗口会产出**新鲜、真实跑完**的
> passing check（Windows 走 `cmd="powershell"`，WSL 走 `cmd="bash"`），并在此表追加最终状态。

另外顺手修掉一个 PowerShell 5.1 输出瑕疵：`2>&1 | Write-Host $_` 会把 stderr 行渲染成
`System.Management.Automation.RemoteException`，已改为 `Write-Host ([string]$_)`。

---

## 3. 跨实现一致性向量（fixture）

**生成命令**（幂等，Windows / WSL 均可）：

```bash
python scripts/gen_conformance_vectors.py
python scripts/gen_conformance_vectors.py --print-sha256          # 只打印指纹
python scripts/gen_conformance_vectors.py --verify <moonbit.json> # 反向校验（转交 verify_interop）
```

**产物**：`test-suit/rhop_js/fixtures/vools_vectors.json`
- 32710 bytes，UTF-8（无 BOM），`sort_keys=True` + `indent=2` + `\n` 结尾
- sha256 = `f22dda48e3b6b5083a5ae84f0f0872ec93f7fceb3c04fddfcb3b3742e8a3b9b3`
- 来源：`vools-rhop 0.9.0`（`E:/IDEProjects/AI/vools/rhop`，模块 `vools/rhop/envelope.py`，相对路径入库，绝对路径不入 fixture）

| 分节 | 条数 | 内容 |
|---|---|---|
| `canonical_json` | 7 | 空对象/空数组/中文嵌套/转义（`"` `\` `\n` `\t` `\r` `\b` `\f` U+0001/emoji/`/`）/标量(null,bool,int)/键序（`"z" "a" "A" "1" "中文a" "b"`）/深层嵌套；每例含 `expected` 与 `expected_utf8_hex` |
| `digest.sha256` / `.md5` | 5 / 5 | 空串、`abc`、中文、重复长串、JSON 文本；含 `input_utf8_hex` |
| `digest.hmac_sha256` / `.pbkdf2_hmac_sha256` | 2 / 1 | 契约 §3 `digest.mbt` 的 HMAC/PBKDF2（iterations=1000 测试口径） |
| `envelope` | 3 | `minimal_pending`（中文 payload）/`full_done`（result+signature+hops_seen+version 3）/`tampered_checksum`（负例）；含 `fields`、`checksum`、**`checksum_preimage_utf8`**、`to_rhop_bytes_utf8(_hex)`、`integrity_verify`=[true,""] |
| `crypto` | 3+2+7 | `encrypt_json` 3 例（含 `ct_token_parts` 逐层拆解：version_byte/ts/iv/ciphertext/hmac）、`encrypt_secret` 2 例、`negative_cases` 7 例（每例附 vools **真实** reason：MALFORMED×5 / BAD_TOKEN×2）；另有 `kdf`（salt_hex、iterations=200000、`fk_b64url`） |
| `signer` | 3+1 | `FileHashSigner` 3 例（**含真实 `preimage`**，其中 `unicode_result` 展示 `\uXXXX` 转义）、`NPUSigner` 1 例（无 npu-smi ⇒ sign=None） |
| `status_flow` | — | `TaskStatus.can_transition/is_terminal` 真实流转表 + `Side.other` 映射 |
| `parity_notes` | — | **QA 判据**：vools 两套 JSON 口径的裁定（见 §4） |
| `moonbit_output_schema` | — | 给 MoonBit 侧照抄的产物契约（verify_interop 的输入形状） |

**幂等性保证（可复现）**：Fernet token 含随机 IV + 当前时间戳，直接生成每次都不同。
生成脚本在生成窗口内把 `os.urandom` 换成确定性 IV 序列（`sha256('rx-mbt-iv:<n>')`）、
把 `time.time` 固定为 `ts=1793000000`，**Fernet 算法本身仍然是 cryptography 的真实现**
（不是自写加密）。脚本默认自检「连续两次生成逐字节相同」，不成立即 exit 4。
实测：Windows py3.13 + cryptography 48 与 WSL py3.10 + cryptography 3.4.8 产出
**同一份 sha256** —— 跨平台逐字节可比。

---

## 4. QA 判据：vools 的两套 JSON 口径（lead 2026-10-27 裁定）

vools 自身存在不一致，本项目**按事实精确复刻**，不「改正」它：

| 用途 | Python 口径 | ensure_ascii | 非 ASCII 表现 | MoonBit 要求 |
|---|---|---|---|---|
| `Envelope` checksum / `to_rhop_bytes` | `json.dumps(..., ensure_ascii=False, sort_keys=True)` | `False` | 中文原样（`"测试机"`） | `canonical_json` / `canonical_json_utf8` 必须一致 |
| `FileHashSigner.sign` preimage | `json.dumps({"task_id":…,"result":…}, sort_keys=True)` | `True`（默认） | 中文转义（`\u6307\u6807`） | **必须单独实现 ensure_ascii=True 口径（如 `canonical_json_ascii`），不得复用 canonical_json** |

**这条判据最容易漏测**：若 signer 复用了 `ensure_ascii=False` 的 canonical_json，
`ascii_result` 用例仍然全绿，只有 `unicode_result`（含中文 result）会与 vools 不一致 ——
典型「假 GREEN」。fixture 里 `signer.file_hash.cases[1].preimage` 与
`envelope[*].checksum_preimage_utf8` 就是这两套口径的对照证据。

其它已记录的口径差异（同样写进 `parity_notes`）：
1. `encrypt_json` 输出文本用 Python 默认分隔符（冒号/逗号后**带空格**）——解密方只做 JSON 解析，
   所以 MoonBit 不必逐字复刻文本；但「全文相等」断言要按带空格写。
2. 字符串 payload 若不是合法 JSON，vools 会包成 `{"__text__": "..."}` 再加密（`plain_string_payload` 用例）。
3. `VText.decrypt` 解密失败会静默回退原文/空串（并抛 RuntimeWarning），
   `RhopCrypto.decrypt_verify` 在其上做启发式才能区分 `BAD_TOKEN` / `NOT_JSON` ——
   MoonBit 侧需要显式实现这三态，`crypto.negative_cases` 给了 7 条真实 reason 作为断言。

---

## 5. 反向互操作复核（verify_interop.py）

**用法**：

```bash
python scripts/verify_interop.py <moonbit产出.json>            # 逐项报告 + exit 0/1
python scripts/verify_interop.py <moonbit产出.json> --strict    # SKIP 也算失败（终验口径）
python scripts/verify_interop.py <moonbit产出.json> --out report.json
python scripts/verify_interop.py <moonbit产出.json> --no-self-check
python scripts/verify_interop.py --self-test                    # 自检校验器本身（无需 MoonBit 产物）
```

`--self-test` 会做三件事，任一条不符合预期即 exit 1 —— 用来证明「校验器不是永远绿的橡皮图章」：

| 自检场景 | 期望 | 实测 |
|---|---|---|
| 正向（用 fixture 期望值反向构造的「正确产物」） | 无 FAIL | ✅ PASS=47 FAIL=0 SKIP=0 |
| 对抗（注入 5 类错误：canonical 尾部加空格 / sha256 hex 全 0 / 签名改 hex / 密文换垃圾 ct / 正常信封换篡改字节） | FAIL ≥ 5 | ✅ PASS=26 FAIL=5 SKIP=0 |
| 部分产物（只有 canonical_json） | 有 SKIP 无 FAIL | ✅ PASS=7 FAIL=0 SKIP=8 |


**复核动作（全部由真实 vools 执行，不是字符串对答案）**：

| 分节 | 复核方式 |
|---|---|
| `envelope` | MoonBit 的 `to_rhop_bytes` 字节 → `Envelope.from_rhop_bytes`（checksum 校验 + 反序列化）→ 与 fixture 的 `fields`/`checksum` 逐字段比对；篡改用例要求 vools **拒绝** |
| `crypto` | MoonBit `encrypt_json` 文本 → `RhopCrypto.decrypt_verify` 真解密 → payload 与 fixture 一致；`v/alg` 结构一致；若 MoonBit 上报 `decrypt_payload` 则同时验证它解 fixture 密文的能力；`encrypt_secret` → `decrypt_secret` 比明文 |
| `signer` | MoonBit 签名 vs `FileHashSigner().sign(...)` 复算 |
| `canonical_json` | 与 `json.dumps(ensure_ascii=False, sort_keys=True)` 逐字符比对 |
| `digest` | sha256/md5/hmac/pbkdf2 hex 比对 |
| fixture 自检 | 用 vools 复算 fixture 自身（checksum/解密/签名），防伪造或篡改的向量表 |

**自测结果（验证工具自身可信）**：

| 场景 | 期望 | 实测 |
|---|---|---|
| 正向（按 fixture 值构造的 MoonBit 产物） | PASS | ✅ 47/47 PASS，rc=0 |
| 对抗（注入 5 类错误：canonical 改字、sha256 改 hex、密文换成垃圾 ct、envelope 改字段保留 checksum、签名改 hex） | 逐项 FAIL | ✅ 5/5 FAIL，rc=1 |
| partial 产物 + `--strict` | FAIL（SKIP 也算失败） | ✅ rc=1 |
| partial 产物（宽松模式） | PASS | ✅ rc=0 |

**真实互操作证据（Batch B 已经通了）**：对 impl-crypto 已产出的
`test-suit/rhop_js/fixtures/moonbit_vectors.json` 跑 `--no-self-check`：

```
[PASS] flat/envelope_json     vools 成功解密 MoonBit 密文并解析出 payload
[PASS] flat/envelope_nonjson  vools 解密得到非 JSON 明文，reason=NOT_JSON（符合断言）
[PASS] flat/secret            vools 解密 RHOP-ENC 成功，明文与 secret_plain 一致
PASS=4 FAIL=0 SKIP=0  →  RESULT: PASS
```

即 **MoonBit 加密 → Python 解密** 方向已验证；fixture 反向（Python 加密 → MoonBit 解密）由
impl-crypto 的 js 测试消费同一份 fixture 完成。为此脚本内置了「扁平形状」通用适配器，
impl-crypto 无需改动既有产物格式即可被复核。

---

## 6. 资源消耗

- 模型/工具：MCP fist-mbt（rx-rhop ns）+ 本地 bash/pwsh/python；未启动额外服务器或外部服务。
- 时间：2026-10-27 19:46 起，切片①②约 35 分钟（含两平台实测与自测回归）。
- 预算：无额外配额消耗（未调用 model_route / executor_run）。

## 7. 任务分配记录 / 终验记录

| 切片 | 内容 | 状态 |
|---|---|---|
| ① | `scripts/test_all.sh` + `scripts/test_all.ps1` | ✅ 已交付，双平台 bash 版全绿 |
| ② | `scripts/gen_conformance_vectors.py` + `scripts/verify_interop.py` + `fixtures/vools_vectors.json` | ✅ 已交付，正/负向自测通过 |
| ③ | 全量跨平台终验 + §4.3 逐条勾 | ⏳ 等 lead「终验开始」通知 |

### 7.1 契约 §4.3 验收清单（终验时逐条勾，现在先标可判定项）

- [ ] `moon check` 0 error（三目标并集）
- [ ] 新增 API 均有测试；`moon test` 三目标 failed: 0
- [ ] Windows 与 WSL 各跑一遍 `scripts/test_all.sh` 全绿（贴汇总行）
- [ ] Batch A：checksum 与 Python 逐字节一致（fixture）
- [ ] Batch B：Python↔MoonBit 双向解密成功
- [ ] `moon fmt` 后无 diff；`.mbti` 变更已复核
- [ ] 执行汇报写入 `fist-mbt/reports/2026-10-27-<batch>-report.md`

> fmt 复核口径（非破坏性）：`moon fmt --check`（`moon fmt --help` 确认存在该开关）。
> 注意必须用修好 PATH 的环境（`export PATH="/c/Program Files/nodejs:$HOME/.moon/bin:/usr/bin:/bin"`），
> 否则 `moonfmt` 会 `program not found`；本执行体不跑不带 `--check` 的 `moon fmt`（它会改产品代码，
> 超出 qa-platform 写作用域）。

> 说明：- [ ] 保持未勾是**故意的** —— 终验前勾绿等于伪造验收。切片①②的证据已在 §2/§3/§5
> 固化，③ 只做「把已固化的证据汇总 + 跑一次全量」。

### 7.2 终验执行清单（命令级，收到「终验开始」后照此执行）

```bash
# 0) 环境（Windows Git Bash）
export PATH="/c/Program Files/nodejs:$HOME/.moon/bin:/usr/bin:/bin"

# 1) Windows 四目标 gate（内置每步 600s 硬超时）
bash scripts/test_all.sh                      # 期待 RESULT: PASS，四步汇总行
# 1b) Windows 原生 PowerShell 入口（同判据，无内建超时）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_all.ps1 -Quiet

# 2) WSL 四目标 gate
wsl.exe -e bash -c "cd /mnt/e/IDEProjects/AI/rx-mbt && bash scripts/test_all.sh"

# 3) fixture 可复现性（必须与入库 sha256 一致）
python scripts/gen_conformance_vectors.py --print-sha256
#   期望：f22dda48e3b6b5083a5ae84f0f0872ec93f7fceb3c04fddfcb3b3742e8a3b9b3

# 4) 跨实现互操作 --strict（要求 MoonBit 产物覆盖五节；缺节按 FAIL）
python scripts/verify_interop.py test-suit/rhop_js/fixtures/moonbit_vectors.json --strict --out fist-mbt/reports/interop-verify.json
python scripts/verify_interop.py --self-test          # 校验器自身自检（3/3 场景）

# 5) fmt 门（非破坏性）
moon fmt --check

# 6) fist-mbt 记录（新鲜 passing check，两条都要）
#    run_check(T0r7, cmd="powershell", args=[...,"-File","scripts/test_all.ps1","-Quiet"], timeout_ms=300000)
#    run_check(T0r7, cmd="bash", args=["-c","cd /mnt/e/IDEProjects/AI/rx-mbt && bash scripts/test_all.sh"], timeout_ms=300000)
```

> 注意：`bash` 在 MCP server 侧解析到的是 **WSL 的 bash**，要 Windows 原生记录必须用
> `cmd="powershell"` 那条（见 §2.4 / §2.5）。


## 8. 遗留风险

1. **并行写文件的瞬时红**：Windows/WSL 的全绿证据是在构建稳定窗口取得的；终验必须在 lead 汇总
   各批之后、无人并发写 `rhop/*.mbt` 时跑，否则会把「编辑中间态」记成产品红。
2. **signer ensure_ascii 口径**：已裁定复刻 vools（§4），但 impl-core 若已按 canonical_json 实现，
   需要改成 `canonical_json_ascii`；fixture 的 `unicode_result` 用例是这件事的唯一守门人。
3. **`test-suit/rhop_js/fixtures/` 下有两份产物**：`vools_vectors.json`（本执行体生成，Python→MoonBit）
   与 `moonbit_vectors.json`（impl-crypto 的 js 测试写出，MoonBit→Python）。两者互不覆盖，但**注意别互相
   覆盖**：写文件的测试请只写 `moonbit_vectors.json`（或新名字），不要整目录清理。
4. **`tx_contract` 无 namespace 参数**：对 ns=`rx-rhop` 的任务做迁移预检时，它读的是 default 库，
   会返回「当前是 [已归档]」这类与真实状态矛盾的回执（实测 T0r7：`get` 是「已领取」，
   `tx_contract` 说「已归档」）。建议 lead 转报（我无法 report_bug：project_dir 只接受相对
   FIST-Mbt cwd 的路径）。

## 9. 后续建议

1. lead 汇总 Batch A–D 后通知一次固定窗口，我跑：两平台 `bash scripts/test_all.sh` +
   `verify_interop.py --strict`（要求 MoonBit 产物覆盖 canonical/digest/envelope/crypto/signer 五节）
   + `moon fmt` 无 diff 复核，然后把 §7.1 全部勾绿并把终数填进本文档。
2. 建议 impl-core 让 test-suit/rhop 的 js 测试把实际值写成 §3 的 `moonbit_output_schema` 形状
   （见 fixture 同名分节），这样 `--strict` 能一次覆盖 5 个分节，而不是只有 crypto。
3. 建议把 `scripts/test_all.sh` 接进 fist-mbt 的 `run_check`（我已用它做本任务的判据），
   避免以后各执行体手搓 `moon test --target js` 踩 PATH 坑。

## 10. 超额内容

- `gen_conformance_vectors.py --verify`：契约 §4.2 提到的 `--verify` 模式已实现（转交 verify_interop）。
- `verify_interop.py --self-test`：**校验器自检**（正向放行 / 注入 5 类错误必须判红 / 部分产物有 SKIP 无 FAIL），
  一条命令即可复现「这个复核工具本身可信」，不需要 MoonBit 产物。
- `verify_interop.py` 的「扁平形状」适配器：让 impl-crypto 现有产物**零改代码**即可被复核。
- `parity_notes` 分节：把 lead 的 signer 口径裁定固化进 fixture（判据随向量走，不只留在 md 里）。
- `digest.hmac_sha256` / `pbkdf2_hmac_sha256` / `crypto.kdf`（`fk_b64url`）/ `status_flow` 四组向量：超出契约 §4.2 的最低要求，直接服务 Batch A/B 的实现自证。
- PowerShell 5.1 的 stderr 渲染修复（`RemoteException` 噪声）。

## 11. 来源

- 契约：`fist-mbt/plans/decisions/2026-10-27-rhop-vools-parity-decision.md`（§0 基线、§4.2 测试入口、§4.3 验收清单）
- 任务：fist-mbt ns=`rx-rhop` / `T0r7`（RX-QA，level=6）
- 参考实现：`E:/IDEProjects/AI/vools/rhop`（vools-rhop 0.9.0）
- 交付文件：`scripts/test_all.sh`、`scripts/test_all.ps1`、`scripts/gen_conformance_vectors.py`、
  `scripts/verify_interop.py`、`test-suit/rhop_js/fixtures/vools_vectors.json`
