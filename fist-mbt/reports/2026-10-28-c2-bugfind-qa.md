# C2 寻虫报告 — 资源与并发（QA 域 / qa-platform）

- 轮次：C2（组合模式 ×3 轮之 C2），主题：**资源与并发**
- 范围：`scripts/test_all.sh`、`scripts/test_all.ps1`、`scripts/gen_conformance_vectors.py`、
  `scripts/verify_interop.py`、`scripts/with_moon_lock.sh`、`test-suit/rhop_js/fixtures/**`、`fist-mbt/reports/**`
- 方式：**只读寻虫**（日志/进程/文件取证 + 定点复现），未改任何产品代码；证据全部落在 `C:/tmp/c2_*`
- 环境：Windows 11 + Git Bash、PowerShell 5.1、WSL Ubuntu-22.04；Python 3.13 / 3.10
- 时间：2026-10-28 13:50–14:15（期间其他 lane 正在改 `test-suit/rhop_js/relay_test.mbt`，凡受影响的实验均已标注）

> 说明：C1 已修 F1–F10（`--strict` 假绿、`-like`→`-match`、PS/bash skip 语义、参数校验、失败现场保留等）。
> 本报告**只登记 C2 新发现**（以及 C1 修复未闭合的残留），并按 P0/P1/P2/P3 排序。

---

## 0. 汇总表

| ID | 严重度 | 位置 | 一句话 | 状态 |
|---|---|---|---|---|
| Q1 | **P1** | `test_all.sh:300-309`（`cleanup_orphans` 调用点 + pattern） | 清理 pattern 与真实测试进程 cmdline **对不上**：Windows 用反斜杠、WSL 隔离后路径是 `_build/wsl/...` ⇒ 超时后孤儿进程**永远不会被清理**（C1 F2 只修了匹配机制，pattern 仍错） | 已复现 |
| Q2 | **P1** | `test_all.sh:307`（兜底 `cleanup_orphans "_build"`）+ `:241-260` | 兜底 pattern 过宽：`_build` 会命中**别的项目/别的进程**（实测命中 `FIST-Mbt/_build/.../cli.js serve`）⇒ 超时清理会**误杀 MCP server 或其他 lane** | 已复现 |
| Q3 | **P1** | `scripts/with_moon_lock.sh:68-76`（陈旧锁判定） | 跨平台 pid 命名空间不匹配 + `host` 字段从不参与判定 ⇒ **WSL 能在 Windows 持锁期间"偷锁"**（实测），跨平台串行化保证不成立 | 已复现 |
| Q4 | P2 | `test_all.sh:315-320`（check 判据） | 锁等待超时（rc=75）在 gate 里显示为 `moon check 退出码 75`，无任何「有并发 moon / 请重试」提示，易被误判为产品红 | 已复现 |
| Q5 | P2 | `test_all.sh:381-387`（失败现场保留） | `run-logs/` **无保留策略**：每次失败新建时间戳目录（实测单步 28KB、整轮 112KB+）⇒ 长期无界增长（≈8MB/天@20 次红）；内含完整 PATH/绝对路径（无密钥，已扫描确认） | 已测量 |
| Q6 | P2 | `test-suit/rhop_js/fixtures/moonbit_vectors.json` | 该文件是**测试运行时生成物**（Fernet 随机 IV ⇒ 每次 js 测试内容都变），且未被 `.gitignore` 覆盖 ⇒ 每跑一次 js 测试工作树就脏 | 已确认（含证据） |
| Q7 | P3 | `gen_conformance_vectors.py:write_text()` | 临时文件名固定 `<out>.tmp`：同参数并发实测无害（内容相同、原子 replace），但**不同参数并发**时 last-writer-wins / 可能读到半截（本次未复现，属潜在竞态） | 未复现（潜在） |
| Q8 | P3 | `test_all.ps1:148` | Git Bash 探测字面量里混入 **2 个 0x08 控制字符**（`'Git␈in␈ash.exe'`）⇒ 恒 `Test-Path=False`，静默回退到 `Get-Command bash`（本机命中 DSH 自带 MSYS bash；候选里还有 WSL bash，无排除、无告警） | 已复现 |
| Q9 | P3 | `test_all.ps1:25` vs `test_all.sh:56-64` | 非法超时值：bash `--timeout=abc` → rc=2（用法错误），PS `-TimeoutSec abc` → rc=1（PS 参数绑定异常）⇒ 两入口错误码不一致 | 已复现 |
| Q10 | P3 | `test_all.sh:371-373` / `test_all.ps1:316-319` | 「全部跳过」与「用法错误」同为 rc=2，调用方无法区分「没跑」和「参数错」 | 已复现 |
| Q11 | P3 | `test_all.ps1:198` | C1 F7 声称已移除的 `$timedOut` 死代码仍残留（赋值后从未使用） | 代码审读 |
| Q12 | P3 | `test_all.sh:152-161`（`_build` 隔离） | 隔离只覆盖「用脚本跑」的路径：WSL 里**手工** `moon …`（不带 `--target-dir`）仍写共享 `_build`；PS 入口无隔离概念（若在 WSL 侧被调用则失效） | 设计缺口 |
| Q13 | P3 | `verify_interop.py` 顶部 | 导入 `gen_conformance_vectors` 时在 `scripts/__pycache__/` 落 `.pyc`（`scripts/` 已 gitignore，但属多余产物；`scripts/__pycache__` 现存 2 个文件 74KB） | 已测量 |

**正向确认（审计未见缺陷，均实测）**：

- 退出码主矩阵一致：bash `--help`=0、未知参数=2、非法 `--timeout`=2、非法 `--skip`=2、全跳过=2、超时=1(FAIL)、全绿=0；PS 未知 skip=2、`-TimeoutSec 0`=2、全跳过=2、全绿=0（§5）。
- `run-logs` **不含密钥**：对 28KB 现场日志做 `secret|password|token|api_key|BEGIN PRIVATE` 扫描，唯一命中是 MoonBit 变量名 `token`（误报）。
- 失败现场保留生效：`--timeout=1` 强制 js 超时 → 生成 `run-logs/20261028-135803/js.log`（28KB），锁已释放、无残留 moon/node。
- js 自然退出 3 连跑稳定：3/3 `rc=0`，`Total tests: 52/52/54 passed`，跑后 `node(rhop_js)` 与 `moon` 进程计数均为 **0**（§3）。
- `gen_conformance_vectors.py` 幂等 + 跨平台一致：同参数并发 2 次均 rc=0、产物 sha256 `f22dda48…` 正确、无 `.tmp` 残留。
- `with_moon_lock.sh` 正常路径：获锁→执行→释放，陷阱释放正确（`--timeout=1` 强制失败后锁目录消失）。

---

## 1. Q1（P1）超时清理 pattern 与真实进程 cmdline 不匹配 ⇒ 清理是空操作

### 位置
`scripts/test_all.sh:300-309`：

```bash
case "$step" in
  js)     cleanup_orphans "_build/js/debug/test" ;;
  native) cleanup_orphans "_build/native" ;;
  *)      cleanup_orphans "_build" ;;
esac
```

Windows 分支（`:244-256`）用 `Get-CimInstance … -match $pat`；WSL 分支（`:257-259`）用 `pkill -f "$pat"`。

### 证据（两个平台各一次实测）
**Windows**：造一个"假孤儿"——真实 node 进程、参数就是 moon 传给测试二进制的**反斜杠路径**：

```powershell
# 造孤儿
node -e "setTimeout(()=>{},30000)" 'E:\IDEProjects\AI\rx-mbt\_build\js\debug\test\dummy_orphan.js'
# 用脚本里的 pattern 复刻匹配
pattern [_build/js/debug/test]                 -> 0 hit(s)      ← 脚本现状：命中 0
pattern [_build[\\/]js[\\/]debug[\\/]test]     -> 1 hit(s)      ← 修正后命中
```
真实 moon 产生的 js 测试进程 cmdline（2026-10-27 21:0x 实测抓取）就是反斜杠形态：
`…\node.exe … E:\IDEProjects\AI\rx-mbt\_build\js\debug\test\test-suit\rhop_js\rhop_js.blackbox_test.js`。

**WSL**：`_build` 隔离后（见 Q12）测试二进制在 `_build/wsl/…`：

```
alive_before=1
alive_after_current_pattern=1     ← pkill -f "_build/js/debug/test" 没杀到
alive_after_fixed_pattern=0       ← pkill -f "_build/wsl/js/debug/test" 杀到了
```

### 复现
```bash
# Windows
node -e "setTimeout(()=>{},30000)" 'E:\IDEProjects\AI\rx-mbt\_build\js\debug\test\x.js' &
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='node.exe'\" | Where-Object { \$_.CommandLine -match '_build/js/debug/test' } | Measure-Object | % Count"
# WSL
wsl.exe -e bash -c 'node -e "setTimeout(()=>{},30000)" /mnt/e/IDEProjects/AI/rx-mbt/_build/wsl/js/debug/test/x.js & sleep 2; pkill -f "_build/js/debug/test"; pgrep -fc x.js'
```

### 建议修法
pattern 必须同时兼容两种分隔符与两种构建根，且**限定在本仓库内**：

```bash
WEB="_build[\\\\/](wsl[\\\\/])?js[\\\\/]debug[\\\\/]test"
NATIVE="_build[\\\\/](wsl[\\\\/])?native"
```
- Windows 分支：`Get-CimInstance` 只匹配 `Name in (node.exe, moon.exe)` 且 `CommandLine -match $pat`；
  同时把 `$PROJECT_DIR` 编进 pattern（`[\\/]rx-mbt[\\/]_build…`）避免跨仓库误杀。
- WSL 分支：`pgrep -fc` 先计数再 `pkill -f`，并把计数打印出来（便于判断"清理了 0 个"是正常还是 pattern 失效）。
- 超时消息里打印实际匹配数（0 命中要显式告警「pattern 未命中，可能路径形态变了」）。

---

## 2. Q2（P1）兜底 `cleanup_orphans "_build"` 误杀面过大

### 位置
`scripts/test_all.sh:307`（`*)` 分支），Windows 分支不过滤仓库路径（`:251`）。

### 证据
同时造两个 node 进程：一个本仓库 js 测试形态、一个 **FIST-Mbt CLI server** 形态：

```
pattern [_build] -> 2 hit(s)
    hit pid=9072  cmd=node.exe -e … E:\IDEProjects\AI\rx-mbt\_build\js\debug\test\d…
    hit pid=30292 cmd=node.exe -e … E:/IDEProjects/AI/FIST-Mbt/_build/js/release/bu…
```
即：一旦 `check`/`wasm` 步骤超时，`cleanup_orphans "_build"` 会把 **FIST-Mbt 的 CLI/MCP server**
（以及任何 cmdline 含 `_build` 的 node/moon）一并 `Stop-Process -Force`。

### 复现
同 Q1 证据命令，把 pattern 换成 `_build`。

### 建议修法
1. **删掉 `*)` 兜底**：check/wasm 步骤的挂死对象是 moon 本身，用针对性的 `moon.exe` + 本仓库路径 pattern；
2. 所有 pattern 前置本仓库根路径（`rx-mbt` 或 `$PROJECT_DIR` 规范化后）；
3. 清理前打印“将杀 N 个：pid/cmd 摘要”，并支持 `RX_MBT_NO_CLEANUP=1` 关闭自动清理。

---

## 3. Q3（P1）跨平台锁：pid 命名空间不匹配导致"偷锁"

### 位置
`scripts/with_moon_lock.sh:66-78`：

```bash
if [ -f "$LOCK_DIR/owner" ]; then
  owner_pid=$(sed -n 's/^pid=\([0-9]*\).*/\1/p' "$LOCK_DIR/owner")
  if [ -n "${owner_pid:-}" ] && ! kill -0 "$owner_pid" 2>/dev/null; then
    echo "with_moon_lock: 清理陈旧锁（pid=$owner_pid 已退出）" >&2
    rm -rf "$LOCK_DIR"; continue
  fi
fi
```
写锁时记录了 `host=$(hostname)`，但**判定时完全没用到 host**。

### 证据（实测）
```
windows-side lock owner: pid=973 host=pikaqiu cmd=bash -c sleep 8     ← Windows 侧持锁（活进程）
WSL: with_moon_lock: 获得锁，执行：echo WSL-GOT-LOCK-while-windows-holder-alive
     WSL-GOT-LOCK-while-windows-holder-alive                          ← WSL 在 Windows 持锁期间拿到锁
```
原因：Windows pid 973 在 WSL 的 pid 命名空间里不存在（或对应无关进程）→ `kill -0` 失败 →
被当作"陈旧锁"清掉。注意 `hostname` 在 WSL 默认继承 Windows 主机名，**不能**用它区分平台。

### 影响
- 「跨平台严格串行」的保证不成立（Windows 与 WSL 可同时构建）；
- 目前因为 WSL 已用 `_build/wsl` 隔离（Q12），**同仓构建互相污染的概率下降**，但：
  ① 两侧共用 `~/.moon` 之外的锁语义被破坏；② 其他 lane 依赖锁做同平台串行，被跨平台偷锁后
  可能出现"以为持锁实际没持锁"的窗口；③ 与 `run-logs`/报告里的"串行纪律"结论矛盾。

### 建议修法
owner 文件里加 `os=$(uname -s)`；判定陈旧时要求 **同 os 且同 host** 才允许回收，否则：
- 视为"外部持有"→ 继续等待；超时时在消息里写明 `holder os=… host=…`，并提示手工 `rm -rf`；
- 提供 `--break-stale` 显式破锁开关（默认关闭）。

---

## 4. Q4（P2）锁超时（75）在 gate 里呈现为 `moon check 退出码 75`

### 位置
`scripts/test_all.sh:315-320`（只按 `rc != 0` 判红，未识别 75）。

### 证据
```
$ MOON_LOCK_TIMEOUT=3 bash scripts/test_all.sh --skip=wasm,js,native   # 事先手工占锁
with_moon_lock: 等待锁超时（3s）…（holder: pid=7342 …）
    --> FAIL  moon check 退出码 75  (4914 ms)
 RESULT: FAIL
```

### 建议修法
`run_step` 里对 `rc=75` 单独出文案：
`构建锁等待超时（有并发 moon 正在跑，holder=…）；这不是编译/测试失败，请重试或调 MOON_LOCK_TIMEOUT`。
并在 SUMMARY 里用 `LOCK-TIMEOUT` 这种可 grep 的措辞，避免被当成产品红。

---

## 5. Q5（P2）`run-logs/` 无保留策略

### 位置
`scripts/test_all.sh:381-387`；`test_all.ps1:263-271`。

### 证据
- 目录形态：`fist-mbt/reports/run-logs/<YYYYmmdd-HHMMSS>[-ps1]/<step>.log`；
- 实测单步 28KB（`--timeout=1` 的极短 js 日志），整轮日志实测 112KB（`final_sh_win.log`）；
- 估算：4 步全红 ≈ 0.4MB/次；每日 20 次红 ≈ 8MB/天；30 天 ≈ 240MB；**没有任何裁剪代码**。
- 内容敏感性：扫描 `secret|password|token|api_key|BEGIN .*PRIVATE`，仅 1 条误报（MoonBit 变量名 `token`）；
  但包含完整 `PATH`（用户名）与绝对路径 → 属"低敏但应保留期受限"。
- 好的一面：`.gitignore` 已含 `fist-mbt/reports/run-logs/`（不会误入库）。

### 建议修法
在写新目录前做保留裁剪（默认保留最近 **20** 个目录且总量 ≤ **50MB**，可用
`RX_MBT_RUNLOG_KEEP` / `RX_MBT_RUNLOG_MAXMB` 覆盖）；旧目录按 mtime 删除；删除动作打印一行摘要。

---

## 6. Q6（P2）fixtures 里的运行时生成物让工作树反复变脏

### 位置
`test-suit/rhop_js/fixtures/moonbit_vectors.json`（由 `test-suit/rhop_js/crypto_test.mbt` 写出）。

### 证据
- 文件内容含 `envelope_json`/`secret` 等 **Fernet 密文**，Fernet token 带随机 IV ⇒ 每次 js 测试运行内容都不同；
- 实测两次采样 sha256 不同（`e2710ff4…` vs 12:xx 版本），文件 mtime 每次 js run 都更新；
- `.gitignore` 中**没有**该路径（`grep -n "fixtures\|moonbit_vectors" .gitignore` 无命中）⇒ 已入库文件会持续处于 modified 状态；
- 反向证据：同一次运行失败（编译错）时文件**未变**（未走到写出用例），说明"变/不变"取决于测试是否跑到 crypto 用例。

### 建议修法（QA 作用域内可做）
1. 在 `test-suit/rhop_js/fixtures/.gitignore` 里忽略 `moonbit_vectors.json`（不动产品代码、不改根 `.gitignore`）；
2. 报告里建议 owner 把产物写到 `_build/` 或 `temp/`（长期方案，需改测试路径，属产品域）。

---

## 7. Q7（P3）gen 的固定 `.tmp` 名：潜在并发竞态

### 位置
`gen_conformance_vectors.py:write_text()`（`tmp = path + ".tmp"` → `os.replace`）。

### 证据
- 同参数并发 2 个 gen：均 rc=0、产物 sha256 `f22dda48…` 正确、无残留（良性）；
- 不同参数并发（一个正常、一个 `--skip-crypto`）：两者都 rc=0，最终文件为其中一份（last-writer-wins），
  **未观察到半截写**；因写入量小且 `os.replace` 原子，实际风险低。

### 建议修法
用 `tempfile.mkstemp(dir=os.path.dirname(path), suffix=".tmp")` 生成唯一临时名，
`os.replace` 前 `flush+fsync`，异常路径 `finally` 清理；顺带把 `--random-iv` 的产物在文件里打标
（如 `"deterministic": false`）以免误入库。

---

## 8. Q8（P3）PS 的 Git Bash 探测字面量含控制字符

### 位置
`test_all.ps1:148`：`$gitBash = Join-Path $env:ProgramFiles 'Git␈in␈ash.exe'`（`od -c` 实测 2 个 `0x08 EXISTS`）。

### 证据
```
Test-Path 'C:\Program Files\Git␈in␈ash.exe' -> False
bash candidates: <DSH-msys>/usr/bin/bash.exe | C:\Windows\system32\bash.exe | …WindowsApps\bash.exe
which bash resolves first: <DSH-msys>/usr/bin/bash.exe
```
即：首选 Git Bash 分支**永远不命中**，实际用的是 `Get-Command bash` 的 PATH 顺序结果（本机是 DSH 自带
MSYS bash）。而候选里第 2 位就是 **WSL 的 bash**——换一台机器若 PATH 顺序不同，moon 会被 **WSL bash**
包裹执行（Windows `moon.exe` 路径穿过 WSL interop），锁目录路径也会被 WSL 解析成 `/mnt/e/...`，
行为不可预期（潜在假红/超时）。

### 建议修法
1. 用 `Get-Command git` → `Split-Path (Split-Path (git).Source)` 推导 `…\Git\bin\bash.exe`；
   再补 `$env:ProgramFiles\Git\bin\bash.exe`、`${env:ProgramFiles(x86)}\Git\bin\bash.exe`、`D:\Program Files\Git\bin\bash.exe`；
2. **排除** `C:\Windows\System32\bash.exe` 与 `…\WindowsApps\bash.exe`（WSL 入口）；
3. 若只找到 WSL/未知 bash → 打印 WARN 并**禁用锁**（退回无锁直跑），不要静默用错 shell。

---

## 9. Q9 / Q10 / Q11（P3）退出码与残留

- **Q9**：`--timeout=abc`：bash → rc=2（用法）；PS `-TimeoutSec abc` → rc=1（PS 绑定异常）。
  建议 PS 参数改 `[string]$TimeoutSec='600'` 后自校验，非法统一 rc=2。
- **Q10**：全跳过与用法错误都 rc=2（实测两入口一致）。建议「全跳过」改用 **rc=3**，
  与「参数/环境错误=2」区分；两入口同步。
- **Q11**：`test_all.ps1:198` `$timedOut = $false` 无任何使用点（C1 F7 声称已清理）→ 删除。

---

## 10. Q12（P3）`_build` 隔离的覆盖边界

- 已做到：`test_all.sh` 在 WSL 侧默认 `--target-dir <repo>/_build/wsl`（实测四步全绿，见 parity 报告 §2.5.2）；
- **未覆盖**：① WSL 里手工 `moon check/test/build` 不带 `--target-dir` 时仍写共享 `_build`（moon 默认）；
  ② `test_all.ps1` 没有隔离参数（Windows 自身不需要，但若从 WSL 调用 ps1 则失效）；
  ③ 任何绕过脚本的 CI/IDE 调用。
- 建议：脚本头部/文档明示「WSL 侧请用 `bash scripts/test_all.sh`，不要裸跑 moon」；
  可选提供 `scripts/moon_wsl.sh` 包装（`moon --target-dir _build/wsl "$@"`）。

---

## 11. Q13（P3）`scripts/__pycache__` 副作用

`verify_interop.py` 顶部 `import gen_conformance_vectors` ⇒ 在 `scripts/__pycache__/` 生成
`gen_conformance_vectors.cpython-3{10,13}.pyc`（实测 2 个文件 74KB）。`scripts/` 已被 gitignore，故不进库；
建议在 `verify_interop.py` 顶部（import gen 之前）设 `sys.dont_write_bytecode = True`，并清理现有缓存。

---

## 12. 附 A：证据清单

| 主题 | 证据文件（均在 `C:/tmp/`） |
|---|---|
| Q1/Q2 清理 pattern | `probe_cleanup.ps1`、`wsl_pkill.sh`、终端输出（pattern hit 计数） |
| Q3 跨平台偷锁 | `c2_win_lock.log`、终端输出（WSL `GOT-LOCK`） |
| Q4 锁超时呈现 | `c2_lock.log`、`c2_lock_gate.log` |
| Q5 run-logs | `fist-mbt/reports/run-logs/20261028-135803/js.log`（28KB）、`final_sh_win.log`（112KB） |
| Q6 fixtures 抖动 | `moonbit_vectors.json` 两次 sha256 采样 |
| Q7 gen 并发 | `genrace/`（同参数）、`genrace2/`（不同参数） |
| Q8 PS bash 探测 | `probe_ps1_bash.ps1` 输出、`od -c` 十六进制 |
| Q13 pycache | `ls -l scripts/__pycache__` |

## 13. 附 B：复现命令（关键几条）

```bash
# Q1 Windows：真实反斜杠 cmdline 不被现有 pattern 命中
node -e "setTimeout(()=>{},30000)" 'E:\IDEProjects\AI\rx-mbt\_build\js\debug\test\x.js' &
powershell -NoProfile -ExecutionPolicy Bypass -File C:/tmp/probe_cleanup.ps1

# Q1 WSL：隔离后的 _build/wsl 路径不被现有 pattern 命中
wsl.exe -e bash -c 'bash /mnt/c/tmp/wsl_pkill.sh'

# Q3 跨平台偷锁
( bash scripts/with_moon_lock.sh bash -c 'sleep 8' & ); sleep 2
wsl.exe -e bash -c 'cd /mnt/e/IDEProjects/AI/rx-mbt && MOON_LOCK_TIMEOUT=5 bash scripts/with_moon_lock.sh echo GOT-LOCK'

# Q4 锁超时呈现
mkdir -p .moon-build.lock && printf 'pid=%s\n' "$$" > .moon-build.lock/owner
MOON_LOCK_TIMEOUT=3 bash scripts/test_all.sh --skip=wasm,js,native

# Q5 失败现场 + 体积
rm -rf fist-mbt/reports/run-logs && bash scripts/test_all.sh --timeout=1 --skip=check,wasm,native
du -sh fist-mbt/reports/run-logs

# Q8 PS bash 探测
powershell -NoProfile -ExecutionPolicy Bypass -File C:/tmp/probe_ps1_bash.ps1
sed -n '148p' scripts/test_all.ps1 | od -c
```

## 14. 附 C：审计范围外（未越界声明）

- `test-suit/rhop_js/relay_test.mbt` 的泄漏守门断言强度（C1 F8）属 impl-crypto 域，本报告只做
  "3 连跑自然退出"的外部观测（§3 正向确认），不改产品代码；
- `with_moon_lock.sh` 是 C1 由 lead 侧新增的设施，本报告只登记其**并发/跨平台判定**缺陷（Q3），
  修复方案建议以 owner 确认后合入（QA 会在 fix 报告里给出补丁说明）。
