# C1 寻虫报告 — 测试设施 / QA 审计（qa-platform）

> 任务：rx-mbt（MoonBit 模块 vicTop-cw/RX-MBT）C1 寻虫审计，范围：测试平台与跨实现一致性设施（`scripts/*`、`test-suit/*` 断言强度、报告流程）。
> 模式：**只读审计**，不改产品代码、不提交 git。审计人：qa-platform。时间：2026-10-28（UTC+8）。
> 证据：`C:/tmp/c1_*.log`（本报告每个 finding 均给出**今天复跑**的命令与输出摘录；旧日志已失效的条目已重做）。
> 一句话结论：**同步语义核心（掩码、多 track 顺序、幂等、fixture 确定性）未见缺陷**；8 条问题集中在**验收门自身的漏检、Windows 侧守门失效、两入口判绿语义不一致**。

---

## 0. 汇总表（按严重度）

| # | 严重度 | 位置 | 一句话 |
|---|---|---|---|
| F1 | **P1** | `scripts/verify_interop.py:474-489`（flat 分支）+ `--strict` | 扁平产物形状下 `--strict` **零 SKIP、rc=0**：只给一个 `envelope_json` 密文即可通过验收，缺失的 canonical/digest/signer 分节完全不报 |
| F2 | P2 | `scripts/test_all.sh` `cleanup_orphans()`（windows 分支） | 把**正则串**塞进 PowerShell `-like` 通配符 → **恒 0 命中、静默 no-op**；实测孤儿 node（PID 存活）不被清理 |
| F3 | P2 | `scripts/test_all.ps1` | 四步全跳过（精确名）→ `RESULT: PASS` **rc=0**；bash 同参数 → `RESULT: SKIP` rc=2。判绿语义相反 |
| F4 | P2 | `scripts/test_all.sh:47` `--timeout=*` | 非法值不校验：`abc`/`-5` 被 GNU timeout 拒绝 → 伪装成「步骤 FAIL 退出码 125」；**`--timeout=0` 被接受为不限时 → 静默关闭 js 挂死防护** |
| F5 | P2 | `scripts/test_all.sh:180-181,235` | 每步日志写 `$TMPDIR_RUN/$step.log`，退出时 `trap rm -rf` **无条件删除**：失败现场不可复盘 |
| F6 | P2 | 我自己的交付报告 §4.4 | 「组件覆盖率 79.4%」口径不可靠（字面量统计受源码转义影响）；独立重算甚至 64.3–67.9%，**该百分比指标不成立**，须改逐项断言清单 |
| F7 | P3 | `scripts/test_all.ps1` 超时文案 + `$timedOut` | 屏幕打印 `timeout 600s per step`，但 `$timedOut` 恒 `$false`（无赋值点）→「step timed out」分支是死代码；注释已说明 PS 无内建超时，**输出却仍像有保护** |
| F8 | P3 | `test-suit/rhop_js/relay_test.mbt:240-248` | relay 泄漏守门：先 `kill_all` 再断言 `live_count==0` ⇒ 断言恒绿；仅 `println` 暴露泄漏（诊断可见、门不红） |
| F9 | P3 | `test-suit/rhop/json_canonical_test.mbt:280-288` / `envelope_test.mbt:47-54` | 断言强度：escapes 仅 9 条 `contains` 片段（非全等）；envelope bytes 用「双方各算 sha256 再比」（sha256 若坏则恒真） |
| F10 | P3 | `scripts/test_all.*` 参数 | `--skip wasm`（空格形式）FATAL；未知 skip 名**静默忽略**（`test` 在两入口都不存在）；PS 参数绑定错误 rc=1 vs bash 用法错误 rc=2 |

**未完成（不计入结论）**：§F12 跨平台并发实测——Windows 侧 rc=0 全绿，WSL 侧日志被调用方截断（只到「构建目录」行），未取得完整结论。
**已排除的怀疑**：`test-suit/rhop_clipboard` js 目标曾见 1 次红，**12 次复跑全绿（25/25）**，原失败日志未保留 → 不作为缺陷（flaky 待观察，见 §F13）。

---

## F1（P1）verify_interop 在扁平产物形状下让 `--strict` 失效

**位置**：`scripts/verify_interop.py` —— `run_checks()` 的 `is_flat` 判定（L484-490）、`check_flat_produced()`（L440-478）、`--strict`（L641）。

**现象（今天复跑，`C:/tmp/c1_strict_flat.log` / `c1_strict_section.log`）**：

```
# 产物 A：扁平 = 只有一段 envelope 密文，其余全缺
C:/tmp/c1_flat_hole.json = {"envelope_json": "<Fernet token>"}
$ python scripts/verify_interop.py --fixtures test-suit/rhop_js/fixtures/vools_vectors.json --strict C:/tmp/c1_flat_hole.json
  PASS=18  FAIL=0  SKIP=0  (total 18)     rc=0        ← 缺 canonical/digest/signer 分节也「全绿」

# 产物 B：同样的内容，包一层 crypto 分节
C:/tmp/c1_section_hole.json = {"crypto": {"encrypt_json": []}}
$ python ... --strict C:/tmp/c1_section_hole.json
  SKIP md5/*, pbkdf2/*, sha256/*, signer/file_hash, canonical_json/* …（9 项）
  RESULT: FAIL -- --strict 下存在 9 项 SKIP     rc=1
```

**根因**：`is_flat` 由「产物里没有分节名」判定；扁平分支只校验 `produced` 里出现的检查点，**对 fixtures 中存在而产物里缺失的检查点不记 SKIP**。于是「产物漏交分节」在扁平形状下变成「无检查项 → 无 SKIP → strict 通过」。分节形状下同样的缺失会记 9 个 SKIP → FAIL。**验收门强弱取决于实现者选哪种输出形状**，属默认不安全。

**建议修法**：扁平分支在 `--strict` 下对 fixtures 中所有检查点做「存在性」核对，缺失项记 SKIP（或直接 FAIL）；补回归用例：`{"envelope_json": <token>}` 必须 rc=1。约 15 行。

**影响**：T0r7 验收以 `verify_interop --strict` 为互操作门；当前 MoonBit 侧输出的是分节形状所以门有效，但这是**当前实现的巧合**，任何改用扁平输出的重构都会让门静默失效。

---

## F2（P2）cleanup_orphans 在 Windows 是恒空操作（正则串当 `-like` 通配符）

**位置**：`scripts/test_all.sh` `cleanup_orphans()`，windows 分支：
```bash
powershell -NoProfile -Command \
  "Get-CimInstance Win32_Process | Where-Object { \$_.CommandLine -like '*${pattern}*' -and \$_.Name -match 'node' } | …"
```
调用处传入的是**正则**：`rhop_test_.*\.(js|wasm|mjs)`。

**现象（今天复跑）**：起一个 cmdline 含 `rhop_test_orphan.js` 的 node 进程（PID 57360），再用**脚本内完全一致的字符串**匹配：
```
$ Get-CimInstance Win32_Process | ? { $_.CommandLine -like '*rhop_test_.*\.(js|wasm|mjs)*' } | Measure-Object → Count = 0
$ Get-CimInstance Win32_Process | ? { $_.CommandLine -like '*rhop_test_*' }                       → Count = 1
```
`-like` 是通配符匹配（`* ? [ ]`），不解析正则：`\.` `(` `|` `)` 全被当字面量，所以**永远 0 命中**；随后 `kill` 循环空跑，孤儿存活（PID 57360 实测未被杀，手工 Stop-Process 才清除）。

**建议修法**：`Where-Object { $_.CommandLine -match 'rhop_test_\.(js|wasm|mjs)' }`（`-match` 是正则），或改传通配符 `*rhop_test_*`；命中 0 时打 WARN（当前**完全静默**，比杀不掉更危险）。

**影响**：test_all.sh 的挂死兜底链（超时 64 分钟 → 杀进程 → 下次运行前清残留）在 Windows 侧整条断开。2026-10-27 的历史挂死出现过 3 个 CPU 累计 300+s 的 node 残留，正是依赖这条链清理的。

---

## F3（P2）PS 入口「全跳过 = PASS rc=0」，与 bash 语义相反

**位置**：`scripts/test_all.ps1` 末尾 RESULT 判定（无 AllSkipped 分支）。

**现象（今天复跑）**：
```
$ powershell -NoProfile -File scripts/test_all.ps1 -Skip check,wasm,js,native   → rc=0
  >>> [check] SKIP / [wasm] SKIP / [js] SKIP / [native] SKIP
  RESULT: PASS - every executed step is green
$ bash scripts/test_all.sh --skip=check,wasm,js,native --quiet                  → rc=2
  RESULT: SKIP —— 没有任何步骤被执行（--skip 全跳过），以下结论不构成判绿
```
（对照：`-Skip check,test,js,native` 这种含不存在名字的参数，两入口都**静默忽略 test**、实际跑 wasm —— 见 F10。）

**建议修法**：PS 末尾加 `$allSkipped = ($Rows | ? Verdict -eq 'SKIP').Count -eq $Rows.Count; if ($allSkipped) { 'RESULT: SKIP …'; exit 2 }`，与 bash 对齐。

**影响**：以 rc 判绿的自动化（run_check/CI）若走 PS 入口，可被「什么都没跑」骗成绿色。

---

## F4（P2）`--timeout` 非法值不校验，0 值静默关闭保护

**位置**：`scripts/test_all.sh:47`（`--skip=*` 旁的 `--timeout=*` 解析）与 `run_with_timeout()`（L206-213，实际执行 `timeout -k 15 "${secs}s"`）。

**现象（今天复跑）**：
```
$ bash scripts/test_all.sh --skip=check,test,native --timeout=abc --quiet
  timeout: invalid time interval 'abcs'          ← 脚本把 "abc" 拼成 "abcs"
  --> FAIL  退出码 125  (162 ms)                  ← 伪装成「步骤失败」，rc=1
$ … --timeout=-5  → 同样 "invalid time interval '-5s'"，FAIL 退出码 125
$ … --timeout=0   → timeout 0s 被 GNU 接受 = 不限时（实测 timeout 0s echo hi → rc=0）
```
即：拼出 `"${secs}s"` 后，只有纯数字才合法；脚本不校验，`125` 是 timeout 自己的用法错误码，被当成测试失败展示；`0` 合法但语义是**关闭超时**，等于把 js 挂死防护静默关掉。

**建议修法**：解析时 `case "$T" in ''|*[!0-9]*) FATAL "--timeout 需正整数（秒）";; esac`；拒绝 0；`run_with_timeout` 对 rc=125 单独归类为「参数/环境错误」而非步骤 FAIL。

**影响**：默认安全被破坏（0 值），且错误信息指向错误的排查方向。

---

## F5（P2）每步日志随临时目录删除，失败无现场

**位置**：`scripts/test_all.sh:180-181,235`：
```bash
TMPDIR_RUN=$(mktemp -d 2>/dev/null || mktemp -d -t rxmbt)
trap 'rm -rf "$TMPDIR_RUN"' EXIT
local outfile="$TMPDIR_RUN/$step.log"
```
**现象**：成功或失败都无条件删除；`--quiet` 时屏幕只留尾部 40 行，中间日志与失败前文不可追溯。
**建议修法**：失败时（`FAIL>0`）先把 `$TMPDIR_RUN/*.log` 拷到 `./.qa-logs/<timestamp>/` 并打印路径，再清理；或 trap 内判断后保留。
**影响**：与「失败可复盘、证据链可审计」的验收目标冲突；这也是我这次审计里多个问题需要重新复跑取证的原因（旧现场已删）。

---

## F6（P2）我自己交付报告里的覆盖率百分比不成立

**位置**：`fist-mbt/reports/2026-10-27-rhop-interop-report.md` §4.4「组件覆盖率 79.4%（27/34）」。

**问题**：该数字用「fixture 期望串在测试源码里字面量出现」统计；但测试源码用 `Char::from_int(92)` 拼转义、`\u{...}` 转义，字面量天然不出现 → 系统性漏计。今天用独立脚本（`C:/tmp/c1_fixture_cov.py`）重算：
```
literal-coverage : 18/28 = 64.3%
decoded-coverage : 19/28 = 67.9%
```
与 79.4% 不一致，且换个枚举口径（含/不含 negative cases、envelope 是否拆 bytes/sha 两项）数字大幅漂移 → **单一百分比指标本身不成立**。

**建议修法**：把「覆盖率」替换为逐项清单（fixture 用例 → 对应测试断言类型：全等 / contains / 语义互证 / 缺失），并在报告中写明口径；不做百分比汇总。我来改报告（本报告即口径修正声明）。

---

## F7（P3）PS 超时文案与死代码：屏幕像有保护，实际没有

**位置**：`scripts/test_all.ps1:116,146`（打印 `timeout : 600s per step`、每步 `(timeout 600s)`）、L177 `if ($timedOut)` 分支、L155-160 注释。
**现象**：`$timedOut = $false` 后无任何赋值点 →「step timed out after …」永不可达；注释明说「PowerShell 入口没有内建超时…需要请用 bash」，**但屏幕输出未标注 advisory**，用户看到 600s 会以为有硬超时。PS 原生入口跑 js 时因此没有任何挂死自救手段（bash 有 64 分钟 kill）。
**建议修法**：打印改为 `timeout : 600s per step (advisory — not enforced by PS; use bash entry for hard timeout)`；或删掉 `-TimeoutSec` 与 `$timedOut` 分支。

---

## F8（P3）relay 泄漏守门断言恒绿

**位置**：`test-suit/rhop_js/relay_test.mbt:240-248`：
```moonbit
let live = ffi_r_relay_live_count()
if live > 0 { println("[relay] 发现 \{live.to_string()} 个未停止的中转子进程 …") }
ffi_r_relay_kill_all()
assert_eq(ffi_r_relay_live_count(), 0)   // kill_all 之后必然 0
```
**现象**：断言对象是「`kill_all` 之后」的计数，泄漏会被 `kill_all` 抹掉 → 断言恒真；仅 `println` 暴露泄漏（诊断可见、门不红）。
**建议修法**：`assert_eq(ffi_r_relay_live_count(), 0)` 放在 `kill_all` **之前**（或在 `live > 0` 时直接失败）；`kill_all` 保留在 finally 式清理。

---

## F9（P3）两个关键互操作用例的断言强度

- `test-suit/rhop/json_canonical_test.mbt:280-288`：escapes 用例对 9 个字段各做 `assert_true(actual.contains("…"))` —— 片段断言，未做整串 `assert_eq`；字段名拼错/多余字段/顺序异常都不会被捕获（fixture 里有完整 expected 串可用）。
- `test-suit/rhop/envelope_test.mbt:47-54`：`assert_eq(@rp.sha256_hex(bytes), @rp.sha256_hex(@rp.bytes_of_utf8(expected)))` —— **双方各算 sha256 再比**；若 `sha256_hex` 有缺陷（恒定/截断），断言仍绿。建议直接 `assert_eq(bytes, @rp.bytes_of_utf8(expected))`，sha256 另由 digest 向量锁定。

## F10（P3）参数处理的边角

- `--skip wasm`（空格形式，非 `--skip=`）→ `FATAL 未知步骤「wasm」`；官方用法只支持 `=` 形式，报错信息应提示「请用 --skip=…」。
- 未知步骤名（如 `test`）**静默忽略**：`-Skip check,test,js,native` 两入口都照跑 wasm，用户以为跳过了测试组。
- `powershell … -NoSuchParam 1` → rc=1（PowerShell 参数绑定错误），而 bash 用法错误 rc=2（脚本约定 exit 2=用法错误）；run_check 包装层若按 exit 2 判定「用法错误」会误分类。

## F11（P3）待观察：rhop_clipboard js 曾见单次红

2026-10-27 的 js 全量跑中曾出现 `rhop_clipboard` 包 1 个红（24/25），今日 **12 次复跑全绿（25/25 × 12）**，未复现、原日志未保留。**不作为缺陷**；建议 CI 保留失败日志，若再现再按 flake 定位。

## F12（未完成）跨平台并发实测

Windows gate（`bash scripts/test_all.sh`）与 WSL gate 同时跑：Windows 侧 `rc=0`（wasm 587/587、js 765/765），WSL 侧日志写到「构建目录: _build/wsl」即被调用方截断（`C:/tmp/conc_cross_wsl.log` 939 B），**未取得完整结论**。同平台双 gate 并发实测 2/2 PASS（`C:/tmp/conc_win_a.log`、`conc_win_b.log`）。建议另行补一次完整并发跑（隔离目录 `_build/wsl` 的设计风险为低，但未实测完成前不下结论）。

---

## 附 A：证据文件清单（均为今日复跑产物）

| 证据 | 路径 |
|---|---|
| F1 扁平/分节 strict | `C:/tmp/c1_flat_hole.json`、`c1_section_hole.json`、`c1_strict_flat.log`、`c1_strict_section.log` |
| F3 PS/bash 全跳过 | `C:/tmp/c1_ps_allskip2.log`、`c1_bash_allskip.log` |
| F4 timeout 非法值 | `C:/tmp/c1_timeout_abc.log`、`c1_timeout_neg.log` |
| F6 覆盖重算脚本 | `C:/tmp/c1_fixture_cov.py`（+ 终端输出） |
| F12 并发（未完成） | `C:/tmp/conc_cross_win.log`、`conc_cross_wsl.log`、`conc_win_a.log`、`conc_win_b.log` |

F2/F7/F8/F9 是代码级证据（上文已内联源码行号），F11 是 12 次复跑输出。

## 附 B：复现命令

```bash
cd /e/IDEProjects/AI/rx-mbt
# F1
echo '{"envelope_json":"<fixture 的 crypto.encrypt_json_cases[0].ciphertext_json_text>"}' > /tmp/flat.json
python scripts/verify_interop.py --strict /tmp/flat.json          # 期望 rc=1，实测 rc=0
# F3
powershell -NoProfile -File scripts/test_all.ps1 -Skip check,wasm,js,native   # PASS rc=0（应 SKIP rc=2）
bash scripts/test_all.sh --skip=check,wasm,js,native --quiet                 # SKIP rc=2
# F4
bash scripts/test_all.sh --skip=check,test,native --timeout=abc --quiet      # "invalid time interval 'abcs'" → FAIL 125
# F6
python /tmp/c1_fixture_cov.py
```

## 附 C：审计范围内未见缺陷（正向确认，均已实测）

- 掩码 `mask_secret` 逻辑正确（≤8 全 `***`，长名留首尾 4）。
- fixtures 生成确定性：连跑两次 byte-identical（`cmp` 通过）。
- 同平台双 gate 并发 2/2 PASS（moon 构建锁串行化）。
- Windows/WSL 构建目录隔离：WSL 写 `_build/wsl`，不碰 Windows `_build/js`（mtime 未变）。
- `moon check` 0-error 判据、`Total tests: …failed: 0` 汇总行解析、`--quiet` 尾部输出均按设计工作。

---
*报告结束。优先修 F1（验收门）→ F2（Windows 守门）→ F3/F4（判绿与默认安全）→ F5；F7/F8/F9/F10 是一两行级修正，建议随 F1 一并收口。*
