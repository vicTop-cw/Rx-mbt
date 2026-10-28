# 2026-10-27 rhop ← vools-rhop 复刻 · 跨平台验收与跨实现互操作汇报（RX-QA / qa-platform）

- 状态：**final v2（代码冻结后终验复跑 2026-10-28 11:27–11:35，三入口四目标全绿 + 互操作 --strict 通过 + fmt 门已关闭）**
- 执行者：qa-platform（fist-mbt ns=`rx-rhop`，任务 `T0r7`，level=6）
- 依据契约：`fist-mbt/plans/decisions/2026-10-27-rhop-vools-parity-decision.md` §0 / §4（§4.2 测试入口、§4.3 验收清单）
- API 对齐统计来源：`fist-mbt/docs/2026-10-27-rhop-vools-parity-matrix.md`（契约范围 192 个符号 → 178 全对齐 = **92.7%**，
  +4 语义等价 +1 部分 = 95.3%；9 个 ⛔ 为明确不做项）

> 职责边界（自证）：本执行体只写 `scripts/test_all.sh`、`scripts/test_all.ps1`、
> `scripts/gen_conformance_vectors.py`、`scripts/verify_interop.py`、
> `test-suit/rhop_js/fixtures/**`、`fist-mbt/reports/**`。**未改动任何 `rhop/*.mbt` 产品代码、
> `moon.mod`、`rhop/moon.pkg`、`test-suit/rhop_js/moon.pkg`、README/DOC.md**，未执行任何 git 命令。
> 发现的产品/工具面缺陷全部以汇报 + 消息形式交给 lead 转报，不自行修产品代码。

---

## 1. 结果摘要

一句话：**三个测试入口（Windows PowerShell / Windows Git Bash / WSL）在四个目标上全部判绿，
跨实现向量由真实 Python vools-rhop 生成且两平台逐字节一致，反向互操作 `--strict` 20/20 通过。**

| # | 交付物 | 状态 | 指纹 / 证据 |
|---|---|---|---|
| ① | `scripts/test_all.sh`（339 行） | ✅ | sha256 `f47cc7d0ab4ee263a96e677684577aa2c2295c4321da7e330b3ff477502cdb6f`；两平台四目标全绿（冻结后复跑同绿） |
| ① | `scripts/test_all.ps1`（257 行） | ✅ | sha256 `18022feffb0f7bad4117f962b44ddcbc1b1d5abf6dab3992715babfecfe05ead`；Windows 原生入口四目标全绿 |
| ② | `scripts/gen_conformance_vectors.py`（963 行） | ✅ | sha256 `37dc1cb1e21477e73cd09f1702dc01a2f7e304eb94eb74e05f8e15730252f58d`；幂等自检 + 跨平台同 sha |
| ② | `test-suit/rhop_js/fixtures/vools_vectors.json` | ✅ | 32710 bytes，sha256 `f22dda48e3b6b5083a5ae84f0f0872ec93f7fceb3c04fddfcb3b3742e8a3b9b3` |
| ② | `scripts/verify_interop.py`（747 行） | ✅ | sha256 `e4d0465c0540fb940a28c72ee2bbb3ae214c830da4dc0c0bf1a615579987297b`；`--strict` 20/20，自检 3/3 |
| ③ | 全量跨平台终验 + §4.3 逐条勾 | ✅ | §2.2 / §7 |

**终验四目标计数（三入口一致，代码冻结后复跑）**：`moon check` 0 error；`moon test`（wasm）**587/587/0**；
`moon test --target js` **765/765/0**（P2 心跳用例 +9：90→99）；`moon test --target native` **587/587/0**。

---

## 2. 环境矩阵与实测输出

### 2.1 平台与工具链（脚本自己打印，不是手填）

| 入口 | 平台 | moon | node | PATH 处理 | 构建目录 |
|---|---|---|---|---|---|
| Git Bash | Windows 11 `MINGW64_NT-10.0-26200` | `0.1.20261016` (1af328f) | `/c/Program Files/nodejs/node` v25.2.1 | 整条 PATH 替换为 `node:/moon:/usr/bin:/bin`（挤掉 `node.cmd` shim） | `_build`（默认） |
| PowerShell 5.1 | Windows 同机 | 同上 | `C:\Program Files\nodejs\node.exe` v25.2.1 | 前置真 node + **剔除所有含 `node.cmd` 的 PATH 项**（见 §2.5.1） | `_build`（默认） |
| WSL | Ubuntu-22.04 | `0.1.20261021` (a4f8933) | `/usr/local/bin/node` v25.2.1 | 净化 PATH 为 `$HOME/.moon/bin:/usr/local/bin:/usr/bin:/bin` | **`_build/wsl`**（见 §2.5.2） |

### 2.2 三入口 × 四目标实测汇总行（代码冻结后终验复跑 2026-10-28 11:27–11:35，三入口严格串行）

**A) Windows 原生 PowerShell 入口**
`powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_all.ps1`

```
 check    PASS   0 errors
 wasm     PASS   Total tests: 587, passed: 587, failed: 0
 js       PASS   Total tests: 765, passed: 765, failed: 0
 native   PASS   Total tests: 587, passed: 587, failed: 0
 RESULT: PASS - every executed step is green          （进程退出码 0）
```

**B) Windows Git Bash 入口** `"D:\Program Files\Git\bin\bash.exe" scripts/test_all.sh`（Git 5.3.15 cygwin）

```
 platform   : windows (MINGW64_NT-10.0-26200)
 moon       : /c/Users/victo/.moon/bin/moon -> moon 0.1.20261016 (1af328f 2026-10-16)
 node       : /c/Program Files/nodejs/node -> v25.2.1
 单步超时   : 600s
 构建目录   : <默认 _build>
 check    PASS   0 errors                                             945 ms
 wasm     PASS   Total tests: 587, passed: 587, failed: 0             680 ms
 js       PASS   Total tests: 765, passed: 765, failed: 0            6504 ms
 native   PASS   Total tests: 587, passed: 587, failed: 0             700 ms
 RESULT: PASS —— 所有已执行步骤判绿（4 步）            （进程退出码 0）
```

**C) WSL 入口** `wsl.exe -e bash -lc "cd /mnt/e/IDEProjects/AI/rx-mbt && bash scripts/test_all.sh --quiet"`（rc=0，elapsed 42s）

```
 platform   : wsl (Linux)
 moon       : /root/.moon/bin/moon -> moon 0.1.20261021 (a4f8933 2026-10-21)
 node       : /usr/local/bin/node -> v25.2.1
 单步超时   : 600s
 构建目录   : /mnt/e/IDEProjects/AI/rx-mbt/_build/wsl
 check    PASS   0 errors                                            3096 ms
 wasm     PASS   Total tests: 587, passed: 587, failed: 0            3240 ms
 js       PASS   Total tests: 765, passed: 765, failed: 0           21467 ms
 native   PASS   Total tests: 587, passed: 587, failed: 0            3378 ms
 RESULT: PASS —— 所有已执行步骤判绿（4 步）            （进程退出码 0）
```

> 与契约 §0 基线的差异：wasm 407 → **587**、js 411 → **765**、native 407 → **587**（Batch A–D/P2a/P2b/clipboard
> 全量落地 + P2 心跳 B1/B2 修复后的增量）。三入口数字逐字一致，说明跨平台没有目标差异。
> 分包计数（lead 侧复核 + 本次 gate 同源）：rhop 131/135/131、rhop_js 52、rhop_clipboard 25、
> rhop_interact 13、rhop_business 10/41/10、rhop_task 46/90/46（wasm/js/native）。

### 2.3 判绿纪律与「假绿」防护

- 判绿只认 `moon test` 的 `Total tests: N, passed: N, failed: 0` 汇总行，并额外要求 `passed == total`；
  **汇总行缺失也算失败**（防「退出码 0 但根本没跑测试」）。
- `moon check` 判据是 `N errors` 必须为 0（不是只看退出码）。
- **全部步骤被 `--skip` 跳过 → RESULT: SKIP 且 exit 2**（不允许「什么都没跑」冒充 PASS）。
- 每步**硬超时**（默认 600s，`--timeout=秒` / `RX_MBT_STEP_TIMEOUT` 可调），超时判 FAIL 并清理残留测试进程。
- 四步原始输出全量落盘（`--quiet` 只在回显上收尾，解析仍用完整日志）。

### 2.4 `set -u` 下的健壮性（脚本自身缺陷的修复记录）

终验前 impl-crypto 实测：脚本打印完头部即中断，`TIMEOUT_SECS: unbound variable`（脚本开着 `set -uo pipefail`）。
**根因是我引入的回归**：新增的超时变量赋值在首次使用之后。修复 + 全文按「`set -u` 下不可能未初始化」重审：

| 变量 / 展开 | 处理 |
|---|---|
| `TIMEOUT_SECS` / `TARGET_DIR` / `TARGET_ARGS` | 赋值前移到首次使用之前 |
| `SKIP_LIST` / `QUIET` / `PLATFORM` / `PATH_NOTE` / `HAVE_TIMEOUT` / `TMPDIR_RUN` / `OVERALL_RC` | 顶部显式默认 |
| `${SUMMARY_ROWS[@]}` / `${TARGET_ARGS[@]}` | 改 `${X[@]+"${X[@]}"}`（旧 bash 空数组展开会 unbound） |
| `parse_summary` 的 `t p fl n` | `read ... \|\| true` + `${t:-0}` 等默认 |
| `$HOME` / `$USERPROFILE` | 改 `${HOME:-${USERPROFILE:-}}`（MCP server 侧 bash 可能无 HOME） |

自查：`bash -n`；`--help` rc=0；`--skip=check,wasm,js,native` → SKIP + exit 2；`env -u HOME ... --help` rc=0 —— 全过。

PowerShell 版同轮自查出的三处坑（均已修）：
1. `-File` 下 `-Skip wasm,js,native` 是**一个字符串**，`-contains` 永不命中 ⇒ 加逗号拆分（实测生效）；
2. PS 5.1 `Start-Process -PassThru`（带 `-RedirectStandardOutput`）拿到的 `$proc.ExitCode` 为 `$null`
   （实测 `finished=True exitCode=[]`）⇒ 退回 `& $moon @args` + `$LASTEXITCODE`（现在能正确报 `moon check exit code 1`）；
   另外 `New-Object System.Diagnostics.ProcessStartInfo` 在本机受限宿主里属性赋值直接 `PropertyNotFound`，一并避开；
3. `[System.Diagnostics.Stopwatch]::StartNew()` 返回 `$null`（耗时会静默为空）⇒ PS 版不再输出耗时列，只输出结论。

### 2.5 js 测试挂死（gate 必须带硬超时）及其根因

2026-10-27 20:54–20:57 三次 `moon test --target js` 留下 **3 个挂死的 node 测试进程**（各吃 400s+ CPU，
`Stop-Process` 前一直不退出），命令行指向 `_build/js/debug/test/test-suit/rhop_js/rhop_js.blackbox_test.js`。

**根因（impl-crypto 定位并修复，fist-mbt `T0r8`）**：`monitor/watcher_js.mbt` 里 `ffi_watch_start` 用
JS number 当 `globalThis.__rxmbt_watch_reg` 的 key，而 `ffi_watch_stop(id : Int64)` 的 id 在 JS 侧是 **BigInt**，
`BigInt(0) !== 0` ⇒ `reg.get(id)` 恒 `undefined` ⇒ `watcher.close()` **从不执行** ⇒ 每次 `stop()` 漏一个被 ref 的
`fs.watch` 句柄，node 事件循环永不空 —— 断言全过、汇总行不打印、进程挂死。修复后连测 5/5 自然退出。

**判据沉淀**：
1. 判泄漏**只认「进程能否自然退出 + exit code」**；`process.getActiveResourcesInfo()` 只作诊断快照、
   **不得断言**（impl-crypto 实测：Windows 上会把已 close 未 GC 的句柄仍列出来，用它断言会假红）。
2. 因此 gate 必须带硬超时（bash 版 `timeout -k 15`，超时判 FAIL + 清理 `_build/js/debug/test` 残留进程）。

### 2.5.1 PowerShell 入口专属坑：只前置真 node 不够，必须剔掉含 `node.cmd` 的 PATH 项

同一构建、同一时刻：bash 版 js 步骤绿，PS 版 js 整批红：

```
failed to parse args:  Unterminated string in JSON at position 1346 (line 1 column 1347)
Error: failed to run test for target Js      （exit code -1）
```

根因：bash 版是**整条 PATH 替换**（shim 目录被挤掉）；PS 版只是「前置」真 node，PATH 里
`...\.desktop-bin\node.cmd` 仍在，moon 偶发仍通过 cmd 批处理 spawn node，>8191 字符的 JSON 参数被截断。
修法：PS 版把「目录里存在 `node.cmd`」的 PATH 项**整条剔除**。修完 js 步骤不再出现 parse args 错误。

### 2.5.2 跨平台共享 `_build` 的互相污染（终验新发现，已隔离）

Windows 与 WSL **共用同一个 `_build/`**（都在 `/mnt/e` 上）。Windows 侧 gate 刚跑完、WSL 侧立刻跑时：

```
Error: Sys_error("\\\\?\\E:\\...\\_build\\js\\debug\\test\\monitor\\monitor.mi: No such file or directory")
Error: failed to build ... (js) ×N
```

两次独立观测：
- Windows PS gate 与 WSL gate 并发 → WSL 的 js 整批构建失败（缺 `.mi`）；
- 顺序跑时 WSL native FAIL（同一份 `_build/native` 里混放 MSVC 与 gcc 产物）。

**处置（已固化进脚本）**：WSL 侧默认改用 **`_build/wsl`**（`moon … --target-dir`，仍在 `.gitignore` 的
`_build/` 之内），Windows 侧保持默认 `_build`；可用 `RX_MBT_TARGET_DIR` 覆盖。
隔离后 WSL 四目标全绿（§2.2-C），且与 Windows 结果逐字一致。

> 这也是终验前多轮「瞬时红/幽灵红」的主要来源之一：**不是产品回归，而是两平台共享构建目录**。

### 2.6 本任务 run_check 记录的如实说明（防止把假绿当证据）

| 记录 | status | 真实含义 |
|---|---|---|
| `check:T0r7:r1` | failed | 真实四步，但并行执行体正在改 `rhop/*.mbt`（同刻手工 `moon check` 也 rc=1）——**瞬时中间态红** |
| `check:T0r7:r2` | passed | ⚠ **无效记录**：环境探测用的包装命令（`rc=$?` 取空 → 外层 exit 0），**不是 gate 运行** |
| `check:T0r7:r3`–`r7` | failed | 中间态 / 旧版 PS 缺陷（`$rc` 为空）/ PS 走 node.cmd shim，均已定位并修复，见 §2.4–§2.5.1 |
| `check:T0r7:r8` | **passed** | 真实 Windows 原生 gate（`cmd="powershell"` + `-File scripts/test_all.ps1 -Quiet`），构建稳定窗口内自然跑完 |
| `check:T0r7:r9` | **passed** | Windows 原生 gate（`cmd="powershell"` + `-File scripts/test_all.ps1 -Quiet`），stdout 完整四步汇总行（587/756/587） |
| `check:T0r7:r10` | **passed** | WSL gate（`cmd="bash"` + `--quiet`），构建目录 `_build/wsl` |
| 代码冻结后复跑（2026-10-28 11:27–11:35） | 待 lead 记账 | 本轮 MCP fist-mbt 工具在本执行体会话不可用（`mcp__fist-mbt__*` 未暴露），
      **真实输出已在本报告 §2.2 与给 lead 的汇报中固化**，run_check/submit 由 lead 记账补登 |

**环境事实（重要）**：MCP server 侧 `cmd="bash"` 解析到的是 **WSL 的 `/bin/bash`**（`HOME=/root`、
`node=/usr/local/bin/node`、`C:/tmp` 被当相对路径），所以 `run_check(cmd="bash")` 实际跑的是 **WSL 侧** gate；
要 Windows 原生记录必须用 `cmd="powershell"`。

---

## 3. 跨实现一致性向量（fixture）

**生成命令**（幂等，Windows / WSL 均可）：

```bash
python scripts/gen_conformance_vectors.py                    # 生成 + 幂等自检
python scripts/gen_conformance_vectors.py --print-sha256     # 只打印指纹
python scripts/gen_conformance_vectors.py --verify <moonbit.json>   # 反向校验（转交 verify_interop）
```

**产物**：`test-suit/rhop_js/fixtures/vools_vectors.json` — 32710 bytes，UTF-8（无 BOM），
`sort_keys=True` + `indent=2` + `\n`；sha256 `f22dda48…`；来源 `vools-rhop 0.9.0`。

| 分节 | 条数 | 内容 |
|---|---|---|
| `canonical_json` | 7 | 空对象/空数组/中文嵌套/转义（`"` `\` `\n` `\t` `\r` `\b` `\f` U+0001/emoji/`/`）/标量/键序/深嵌套；含 `expected` 与 `expected_utf8_hex` |
| `digest` | 5+5+2+1 | sha256、md5、hmac_sha256、pbkdf2_hmac_sha256（iterations=1000 测试口径） |
| `envelope` | 3 | `minimal_pending` / `full_done` / `tampered_checksum`（负例）；含 `fields`、`checksum`、**`checksum_preimage_utf8`**、`to_rhop_bytes_utf8(_hex)`、`integrity_verify`=[true,""] |
| `crypto` | 3+2+7 | `encrypt_json`（含 `ct_token_parts` 逐层拆解：version_byte/ts/iv/ciphertext/hmac）、`encrypt_secret`、`negative_cases`（附 vools 真实 reason：MALFORMED×5 / BAD_TOKEN×2）；含 `kdf`（salt_hex / iterations=200000 / `fk_b64url`） |
| `signer` | 3+1 | FileHashSigner 3 例（**含真实 `preimage`**）+ NPUSigner（无 npu-smi ⇒ None） |
| `status_flow` | — | `TaskStatus.can_transition/is_terminal` 真实流转表 + `Side.other` |
| `parity_notes` | — | QA 判据：vools 两套 JSON 口径的裁定（§4） |
| `moonbit_output_schema` | — | 给 MoonBit 侧的产物契约（verify_interop 输入形状） |

**幂等性**：Fernet token 含随机 IV + 时间戳，生成脚本在窗口内固定 `os.urandom`（确定性 IV 序列
`sha256('rx-mbt-iv:<n>')`）与 `time.time`（ts=1793000000），**Fernet 算法本身仍是 cryptography 真实现**；
默认自校验「连续两次生成逐字节相同」，不成立 exit 4。
实测：Windows py3.13 + cryptography 48 与 WSL py3.10 + cryptography 3.4.8 产出**同一份 sha256**。

---

## 4. QA 判据：vools 的两套 JSON 口径（lead 2026-10-27 裁定）

vools 自身存在不一致，本项目**按事实精确复刻**，不「改正」它：

| 用途 | Python 口径 | ensure_ascii | 非 ASCII 表现 | MoonBit 要求 |
|---|---|---|---|---|
| `Envelope` checksum / `to_rhop_bytes` | `json.dumps(..., ensure_ascii=False, sort_keys=True)` | `False` | 中文原样 | `canonical_json` / `canonical_json_utf8` |
| `FileHashSigner.sign` preimage | `json.dumps({"task_id":…,"result":…}, sort_keys=True)` | `True`（默认） | `\uXXXX` 转义 | **单独用 `canonical_json_ascii`，不得复用 canonical_json** |

守门用例：`signer.file_hash.cases[1] unicode_result`（含中文 result）——
若 signer 复用 ensure_ascii=False，ASCII 用例全绿、只有这条会红（典型「假 GREEN」）。
fixture 里 `envelope[*].checksum_preimage_utf8`（中文原样）与 `signer…preimage`（`\u6307\u6807`）就是这个对照。

其它已记录差异：`encrypt_json` 输出用 Python 默认分隔符（带空格）；字符串 payload 非合法 JSON 时包成
`{"__text__": …}`；`VText.decrypt` 失败会静默回退（`decrypt_verify` 在其上区分 BAD_TOKEN / NOT_JSON）。

---

## 5. 反向互操作复核（`verify_interop.py`）

**终验执行（真实 vools 复核 MoonBit 产物）**：

```bash
$ python scripts/verify_interop.py test-suit/rhop_js/fixtures/moonbit_vectors.json --strict \
      --out fist-mbt/reports/interop-verify.json
  [PASS] flat/envelope_json      vools 成功解密 MoonBit 密文并解析出 payload
  [PASS] flat/envelope_nonjson   vools 解密得到非 JSON 明文，reason=NOT_JSON（符合断言）
  [PASS] flat/key                使用产物自带 key='rx-mbt-rhop-test-key-v1' 做真实解密复核
  [PASS] flat/secret             vools 解密 RHOP-ENC 成功，明文与 secret_plain 一致
  PASS=20  FAIL=0  SKIP=0  (total 20)      →  RESULT: PASS   （rc=0，含 16 项 fixture 自检）
```

**工具自检（证明校验器不是永远绿的橡皮图章）**：`python scripts/verify_interop.py --self-test`

| 场景 | 期望 | 实测 |
|---|---|---|
| 正向（按 fixture 期望值构造的「正确产物」） | 无 FAIL | ✅ PASS=47 FAIL=0 SKIP=0 |
| 对抗（注入 5 类错误：canonical 加空格 / sha256 全 0 / 签名改 hex / 垃圾 ct / 篡改信封字节） | FAIL ≥ 5 | ✅ PASS=26 FAIL=5 SKIP=0 |
| 部分产物（只有 canonical_json） | 有 SKIP 无 FAIL | ✅ PASS=7 FAIL=0 SKIP=8 |

**双向闭环现状（诚实边界）**：
- **Python → MoonBit**：impl-core 的测试**直接消费 fixture 值**做断言（canonical_json / digest / envelope /
  signer 四节），`moon test` 三目标全绿 ⇒ 这些期望值在 MoonBit 侧逐字一致。
  可量化覆盖：fixture 的 34 条硬判据中有 **27 条（79.4%）** 在 MoonBit 测试里被硬编码引用
  （canonical 2/7、sha256 5/5、md5 5/5、hmac 2/2、pbkdf2 1/1、envelope checksum 2/2、signer 3/3、
  crypto 负向 reason 7/7；剩余 7 条是 canonical 中文/转义型用例与 envelope 字节 sha256，未见硬编码）。
- **MoonBit → Python**：`moonbit_vectors.json`（impl-crypto 的 js 测试写出）经真实 vools 解密/校验 20/20 通过。
- ⚠ **未达成**：`--strict` 的五分节产物需要 MoonBit 侧写出一份 `canonical/digest/envelope/signer` 齐全的 JSON
  （当前只有扁平 crypto 产物）。这需要新增一个测试，属于 impl-core/impl-crypto 的写作用域，本执行体不越界；
  已作为「后续建议」登记（§11），不影响本次判绿依据（上述两方向已构成等价证据）。

---

## 6. 已知偏差与限制（引用 lead/实现方结论，供验收时一并确认）

1. **Omega 强验证未启用**：`T0r7.omega_required=false`，全程走普通 execute → run_check → output_validate → verify。
2. **浮点不进 checksum 语料**：契约 §2.1 明确 canonical_json 与 Python 数字最短往返表示有风险，
   语料只用 int/string/bool/null/对象/数组（fixture 里 `scalars` 用例即为该口径的边界声明）。
3. **jump 真传输未实现**：Batch D 的 `jump.probe` 等动作是离线可验证实现；SFTP 远端文件操作（8 个符号）
   与 CLI 入口（1 个）为明确 ⛔ 不做项 —— 与 92.7% 的对齐统计口径一致（矩阵文档 §统计）。
4. **P2 心跳 B1/B2 互操作缺口 —— 已解决（2026-10-28 11:2x，impl-crypto）**：
   缺口原是 MoonBit 心跳与 vools `task/heartbeat` 在 5 个点上的口径差异，现已按 vools 真实行为对齐并用真 vools 双向核验：
   - 心跳报文格式：vools **纯文本**（非 JSON）
   - 时间戳：**微秒级 ISO** 时间串
   - `include_worker`：显式 `false` 时按 vools 语义处理
   - `closed_token`：关闭态令牌与 vools 一致
   - `max_future_skew`：60s，**fail-closed**（超出即拒绝，不静默接受）
   验证方式：真 vools `Heartbeat` 与 MoonBit 侧**双向 6/6 通过**；js 目标因此新增 9 条心跳用例（90 → 99），
   使 js 总数从 756 变为 **765**，三入口在代码冻结后复跑全绿（§2.2）。
   对 QA 判据的意义：这类「报文形态 + 时间单位 + 边界 fail-closed」最容易出现「两边各自绿、互相对不上」，
   因此本报告坚持用**真实 vools 做双向核验**而不是两边各写一份期望值。

5. **P2 层**（`rhop_task` 子包）已落地（P2a/P2b verify 完成），但本轮 fixture 未覆盖 task 层语义
   （TaskState 流转 / TaskRecord 31 列 / mask_value）—— 见 §11 后续建议。
6. **monitor 的 BigInt 句柄泄漏**已由 impl-crypto 修复（`T0r8`），是本轮唯一「断言全绿但进程挂死」类缺陷。

---

## 7. 契约 §4.3 验收清单（终验逐条勾）

- [x] **`moon check` 0 error**（三目标）：Windows 三入口 check 步骤均 `0 errors`；WSL `0 errors`（§2.2 A/B/C）
- [x] **新增 API 均有测试；`moon test` 三目标 failed: 0**：wasm 587/587、js **765**/765、native 587/587（三入口一致，代码冻结后复跑）
- [x] **Windows 与 WSL 各跑一遍 `scripts/test_all.sh` 全绿**：§2.2 B（Windows Git Bash）、§2.2 C（WSL），
      外加 §2.2 A（Windows PowerShell 原生入口）
- [x] **Batch A：checksum 与 Python 逐字节一致（fixture）**：`fixture-self` 段对 3 个 envelope 用例
      用真实 vools `from_rhop_bytes` 复算 checksum + 篡改用例如期被拒；impl-core 测试消费同批值且全绿
- [x] **Batch B：Python↔MoonBit 双向解密成功**：Python 解 MoonBit（`flat/envelope_json`、`flat/secret` PASS）、
      MoonBit 解 Python（impl-crypto 的 27 条 crypto 用例消费 fixture，含 3 encrypt_json + 2 secret + 7 负向 reason）
- [x] **`moon fmt` 后无 diff；`.mbti` 变更已复核** —— **已关闭（2026-10-28 11:2x）**：
      lead 用 `moonfmt -w` 对全部 112 个 `.mbt` 逐个格式化并做**二次幂等验证（unstable=0）**，格式化后三目标仍全绿。
      本执行体用**非破坏性等价检查**独立复验（`moonfmt <file>` 输出与文件逐行 diff、CRLF 归一、全仓库扫描）：
      **144 个 .mbt 文件 needs_format=0**（`_build` 之外全量），即当前代码库已 fmt 幂等、再跑 `moon fmt` 无 diff。
      注：`moon fmt --check` 在本机仍报 `Error: program not found`（moon 找不到 `moonfmt`，见 §8），
      因此复验用上述等价检查而非该开关。`.mbti` 变更由各 owner 在各自 lane 内 `moon info` 复核（本执行体未改产品代码）。
- [x] **执行汇报写入 `fist-mbt/reports/2026-10-27-<batch>-report.md`**：即本文件 +
      `fist-mbt/reports/interop-verify.json`（机器可读逐项报告）

### 7.2 终验执行清单（命令级，已全部实跑）

```bash
export PATH="/c/Program Files/nodejs:$HOME/.moon/bin:/usr/bin:/bin"

# 1) Windows 四目标（bash 入口，内置 600s/步 硬超时）           → RESULT: PASS（4 步）
bash scripts/test_all.sh
# 2) Windows 原生 PowerShell 入口（同判据）                      → RESULT: PASS
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_all.ps1
# 3) WSL 四目标（自动用 _build/wsl 隔离构建目录）                 → RESULT: PASS（4 步）
wsl.exe -e bash -lc "cd /mnt/e/IDEProjects/AI/rx-mbt && bash scripts/test_all.sh"
# 4) fixture 可复现性                                            → f22dda48…（与入库一致）
python scripts/gen_conformance_vectors.py --print-sha256
# 5) 跨实现互操作 --strict                                       → PASS=20 FAIL=0 SKIP=0, rc=0
python scripts/verify_interop.py test-suit/rhop_js/fixtures/moonbit_vectors.json --strict \
    --out fist-mbt/reports/interop-verify.json
python scripts/verify_interop.py --self-test                    # 校验器自检 3/3
# 6) fmt 门（非破坏性）。注意 `moon fmt --check` 在本机会报 Error: program not found，
#    改用等价检查：对每个 .mbt 跑 `moonfmt <file>` 与文件逐行 diff（CRLF 归一），要求 needs_format=0
#    实测（2026-10-28 冻结后）：144 个 .mbt needs_format=0
```

---

## 8. 工具面缺陷与上游 BUG（本轮 QA 发现，均已转报 lead）

| 编号 | 内容 | 状态 |
|---|---|---|
| BUG-451 | `RANK_GATE` + `project_dir` 解析问题（导致 T0.6.x 任务作废、改用 T0r7） | lead 已入账 |
| BUG-452 | `conflicts_check` 无 namespace 参数，对 ns=`rx-rhop` 任务恒报 `task not found` | lead 已入账 |
| BUG-454 | `tx_contract` 缺 namespace 路由：对 `rx-rhop` 任务读 default 库，返回与 `get` 矛盾的「当前是 [已归档]」 | lead 已入账 |
| （monitor） | `watcher_js.mbt` BigInt/number 键不匹配 ⇒ `watcher.close()` 从不执行 ⇒ js 测试进程挂死 | impl-crypto 已修（T0r8）+ 回归守门 |
| （判据） | `process.getActiveResourcesInfo()` 在 Windows 会把已 close 未 GC 的句柄列出 ⇒ 不可用其断言泄漏 | 已写入 §2.5 判据 |
| （工具） | `moon fmt --check` 在本机报 `Error: program not found`（moon 找不到 `moonfmt`；`moonfmt` 本体可用）⇒ fmt 门须用等价检查或 `moonfmt -w` | 已写入 §7.1 / 建议转报 |
| （工具） | 本轮本执行体会话中 `mcp__fist-mbt__*` 工具不可用 ⇒ run_check/submit 由 lead 记账 | 见 §2.6 |

---

## 9. 资源消耗

- 工具：MCP fist-mbt（ns=`rx-rhop`）+ 本地 bash / PowerShell / python；未启动额外服务器。
- 时间：2026-10-27 19:46 起 → 2026-10-28 10:06 首次终验完成；**2026-10-28 11:27–11:35 代码冻结后复跑**（三入口串行，全绿）。
  含大量等待并行 lane 收敛、瞬时红复跑与三处环境/工具缺陷定位。
- 预算：未调用 model_route / executor_run，无额外配额消耗。

## 10. 遗留风险

1. **两平台并发仍要小心**（共享 `_build` 的物理事实仍在）：脚本已用 `_build/wsl` 隔离 WSL，本轮三入口**串行**复跑全绿；
   但若有人绕过脚本手工在 Windows 与 WSL 同时 `moon test`，仍可能互相踩坏产物（隔离前的 `Sys_error … .mi missing` 即此）。
2. **WSL 首次跑要全量重建**（`_build/wsl` 从零开始约 1–2 分钟），run_check 需给足 `timeout_ms`（终验用 300000）。
3. **`--strict` 五分节产物缺生产者**（§5 末尾）：要闭合需在 MoonBit 侧新增一个写出 `canonical/digest/envelope/signer`
   的测试；在此之前跨实现证据靠「fixture 被 MoonBit 测试消费 + MoonBit 产物被 Python 复核」两方向合成。
4. **fixture 里 7 条判据未被 MoonBit 硬编码引用**（canonical 中文/转义型用例、envelope 字节 sha256）：
   它们仍由 `verify_interop --self-test` 与 fixture 自检守住，但「MoonBit 侧逐字断言」覆盖不完整。

## 11. 后续建议

1. 补一个 MoonBit 侧「五节产物」写出测试（owner: impl-core/impl-crypto），让 `verify_interop.py --strict` 一次覆盖
   canonical/digest/envelope/crypto/signer 五节，替代当前的合成证据。
2. 扩 fixture 覆盖 task 层（P2a `rhop_task`）：TaskState 流转表、TaskRecord 字段、`mask_value` 行为对齐 ——
   impl-crypto 已表示有对照 vools 的语义基线，可配合出向量（本执行体负责生成脚本与复核）。
3. 把 `scripts/test_all.sh` 接成 fist-mbt 的常规 `run_check` 判据（含 `--quiet`），并固定 Windows 走
   `cmd="powershell"`、WSL 走 `cmd="bash"` 两条路径，避免后来者再踩 PATH / 共享 `_build` 的坑。
4. 建议在 CI/本地约定：**同一时刻只跑一个平台的 moon 构建**；或统一给两平台各自 `--target-dir`。

## 12. 超额内容

- `gen_conformance_vectors.py --verify`（契约 §4.2 提到但未细化）：已实现，转交 verify_interop。
- `verify_interop.py --self-test`：校验器自检三场景（正向/对抗/部分产物），一条命令复现「工具可信」。
- `verify_interop.py` 的「扁平形状」适配器：impl-crypto 现有产物**零改代码**即可被复核。
- `parity_notes` 分节：把 lead 的 signer 口径裁定固化进 fixture（判据随向量走）。
- `crypto.kdf`（`fk_b64url`）+ `ct_token_parts`（iv/hmac/ts 逐层拆解）：让 Batch B 的 Fernet 对齐可逐层定位。
- 跨平台构建目录隔离（`_build/wsl`）：解决 Windows/WSL 共享 `_build` 的互相污染，是终验能稳定出绿的前提。

## 13. 来源

- 契约：`fist-mbt/plans/decisions/2026-10-27-rhop-vools-parity-decision.md`（§0 基线、§4.2 测试入口、§4.3 验收清单）
- 对齐矩阵：`fist-mbt/docs/2026-10-27-rhop-vools-parity-matrix.md`（192 符号 / 178 全对齐 = 92.7%）
- 任务：fist-mbt ns=`rx-rhop` / `T0r7`（RX-QA，level=6）
- 参考实现：`E:/IDEProjects/AI/vools/rhop`（vools-rhop 0.9.0）
- 交付文件：`scripts/test_all.sh`、`scripts/test_all.ps1`、`scripts/gen_conformance_vectors.py`、
  `scripts/verify_interop.py`、`test-suit/rhop_js/fixtures/vools_vectors.json`、
  `fist-mbt/reports/interop-verify.json`
