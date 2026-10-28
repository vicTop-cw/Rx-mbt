# C4 寻虫报告 — 端到端真实场景 / 集成压力 / 安全审计 / 生成物与工作树卫生（QA 域）

- 轮次：C4（单轮组合：寻虫→修复→打磨→验证→清整），QA 域
- 起点：HEAD `0e17d21`（v0.4.0；wasm 612 / js 825 / native 612）
- 方式：**只读寻虫 + 定点实测**；基线测量与并发实验均在本机完成，证据见 §7
- 时间：2026-10-28 17:02–18:00（UTC+8）
- 环境：Windows 11 `MINGW64_NT-10.0-26200` / moon `0.1.20261016` / node v25.2.1 / Python 3.13；
  WSL Ubuntu-22.04 / moon `0.1.20261021` / node v25.2.1
- ⚠ 期间 **C4 各 lane 在并发改代码**（`git status` 可见 `rhop/*.mbt`、`test-suit/**/*.mbt` 多处修改与
  未跟踪的 `c4_e2e_test.mbt`），因此本轮所有性能/计数数字标注为「C4 过程中快照」，终值以 C4 verify 为准。

---

## 0. 汇总

| ID | 严重度 | 主题 | 一句话 | 状态 |
|---|---|---|---|---|
| **C4-Q1** | **P1** | ① 生成物/工作树卫生 | 2 个**生成物被 git tracked**（`test-suit/rhop_js/fixtures/moonbit_vectors.json`、`fist-mbt/reports/moonbit_vectors_full.json`），且都含 Fernet 随机 IV ⇒ **每跑一轮 js 测试就 dirty**；`fixtures/.gitignore` 对已 tracked 文件**无效**；`reports/` 下还有 3 个 tracked 的机器报告 JSON 同属生成物 | **已修（ignore 侧）** + 移交 untrack 命令 |
| **C4-Q2** | P2 | ② 性能基线 | 仓库**没有 rhop 关键路径的基准入口**（`test-suit/bench` 只覆盖 Rx 算子且 `#skip`）；PBKDF2 200k / canonical 5000 键**无直接用例** | **已修**：新增 `scripts/bench_baseline.sh` + 基线数字（§2） |
| **C4-Q3** | P2 | ③ determinism | `gen` 产物**逐字节幂等**（Windows×2/WSL×1 同 sha）；生产者产物**每次必变**，但差异**恰好只有 5 个 crypto 字段**（随机 IV/时间戳），**非 crypto 字段跨平台逐字段一致** ⇒ 现状可接受但缺**可重复的检查入口** | **已修**：新增 `scripts/check_determinism.sh`（Win/WSL 均 PASS） |
| **C4-Q4** | P2 | ④ 脚本韧性 | 锁竞争 → `LOCK-TIMEOUT` rc=4（非假红）✅；**跨平台并发**（Windows+WSL 同时跑 check 步 / 同时构建）**均全绿且 0 污染错误** ✅ | ✅ 无缺陷，已有防护有效（§4） |
| **C4-Q5** | P3 | ⑤ 文档/脚本一致性 | README 退出码表（0/1/2/3/4）与脚本一致 ✅；`run-logs` 保留策略生效（当前 10 个目录 ≤ 20）✅；**README「最新实测计数」快照已过期**（612/825 → 实测 615/849） | 记录，C4 verify 时刷新 |
| **C4-Q6** | P3 | 工具自身缺陷 | 我新增/修改的 bench、determinism 脚本在首跑暴露 5 个自身缺陷（`moon test` 缺 `test` 子命令 → rc=127、`${t1-t0}` 非算术、GBK 编码、python 解析路径、printf 标签） | **已修**（§5） |
| **C4-Q7** | P3 | 观察（非法缺陷） | 并行编辑窗口内 `-p test-suit/rhop_business --target js` 一度 3–4 例失败（未跟踪的 `c4_e2e_test.mbt` 在途），lane 推进后恢复 **69/69 绿** | 记录，不作缺陷 |

---

## 1. C4-Q1（P1）生成物被 tracked ⇒ 每轮测试都把工作树弄脏

### 事实
| 文件 | tracked? | 每轮是否变 | 变化原因 |
|---|---|---|---|
| `test-suit/rhop_js/fixtures/moonbit_vectors.json` | **是** | **是** | 由 `test-suit/rhop_js/crypto_test.mbt` 写出，含 Fernet 随机 IV 的密文/RHOP-ENC |
| `fist-mbt/reports/moonbit_vectors_full.json` | **是** | **是** | 由 `test-suit/rhop_vectors/producer_test.mbt` 写出，含 3 个 `encrypt_json` + 2 个 `encrypt_secret` 随机密文 |
| `fist-mbt/reports/{interop-verify,c2-interop-verify,c3-interop-verify}.json` | **是** | 仅在重跑复核时变（含绝对路径与逐项明细） | `verify_interop.py --out` 生成 |
| `TEST_REPORT.json`（仓库根） | 是 | 否（历史产物，2026-10-15） | 旧 `gen_test_report.ps1` |
| `fist-mbt/reports/run-logs/**` | 否（`gitignore` ✅） | 失败时新增 | 失败现场保留 |
| `_build/`、`_build/wsl/`、`.moon-build.lock/`、`scripts/__pycache__` | 否（忽略 ✅） | 是 | 构建/锁/字节码 |

### 证据 1：`fixtures/.gitignore` 对已 tracked 文件无效
```
$ git ls-files test-suit/rhop_js/fixtures/moonbit_vectors.json fist-mbt/reports/moonbit_vectors_full.json
test-suit/rhop_js/fixtures/moonbit_vectors.json
fist-mbt/reports/moonbit_vectors_full.json          # ← 两个都被跟踪
$ git check-ignore -v test-suit/rhop_js/fixtures/moonbit_vectors.json
(无输出：tracked 文件不参与 ignore 判定)
```
`test-suit/rhop_js/fixtures/.gitignore` 里写了 `moonbit_vectors.json`（C2 修复所加），但**对已跟踪文件不生效**
——这正是 C4 任务 ① 指出的现象。

### 证据 2：生产者产物每次运行 sha 都不同，且差异**恰好 5 个字段**
```
run1 sha=4a5175c2…  run2 sha=485beb29…  run3 sha=f6af42b1…   （3/3 两两不同）
p1 vs p2: 差异字段 5 个 → /cases/crypto/encrypt_json[0..2]/ciphertext_json_text
                          /cases/crypto/encrypt_secret[0..1]/secret
p1 vs p3 / p2 vs p3: 同样是 5 个、同一批字段
```
即：**除 Fernet 随机 IV/时间戳外，产物完全确定**（envelope 字节/checksum、canonical、digest、signer 均稳定）。

### 证据 3：工作树 dirty 现状（实测）
```
$ git status --porcelain
 M fist-mbt/reports/moonbit_vectors_full.json
 M test-suit/rhop_js/fixtures/moonbit_vectors.json
 ...（另有 C4 各 lane 在途的源码修改）
```
> 注意：C4 期间工作树本来就有 lane 的在途修改，所以"跑一轮前后 diff"看不出增量；
> 但上面证据 1/2 已经证明这两个文件**只要跑测试就会变**（此前 C2/C3 verify 的记录也一致）。

### 建议修法（三级）
1. **止损（本轮已做，QA 作用域内）**：新增 `fist-mbt/reports/.gitignore`
   —— 忽略 `moonbit_vectors_full.json`、`*-interop-verify.json`、`*bench*.json`；
   `fixtures/.gitignore` 已存在（C2 加），untrack 后即生效。
2. **untrack（需要改 git index，交 lead 执行）**：
   ```bash
   git rm --cached test-suit/rhop_js/fixtures/moonbit_vectors.json \
                  fist-mbt/reports/moonbit_vectors_full.json \
                  fist-mbt/reports/interop-verify.json \
                  fist-mbt/reports/c2-interop-verify.json \
                  fist-mbt/reports/c3-interop-verify.json
   git commit -m "chore: untrack generated interop artifacts (C4)"
   ```
3. **根治（产品域，owner=impl-core/impl-crypto）**：让生产者**确定性化**——
   产物里的 `encrypt_json/encrypt_secret` 若要保留"真加密演示"，可给测试加
   `RHOP_VECTORS_DETERMINISTIC=1`（固定 IV + 固定 ts，参考 `gen_conformance_vectors.py` 的
   `DeterministicFernet` 做法）；或把产物改写到 `_build/` / `temp/`（完全不进仓库）。

---

## 2. C4-Q2（P2）性能基线：现状缺口 + 本轮固化数字

### 缺口
- `test-suit/bench` 只覆盖 Rx 算子（map/filter/…），且全部 `#skip("slow tests")`，与 rhop 关键路径无关；
- **PBKDF2 200k 无直接微基准**：它内嵌在 Fernet 加/解密里（`rhop/crypto.mbt` 的 js FFI `pbkdf2Sync(...,200000,...)`），
  只能以 `crypto_test` 的墙钟作代理；
- **canonical 5000 键无既有用例**：`json_canonical_test.mbt` 只有「深嵌套 5000/20000」与键序小样例。

### 本轮固化（Windows 11 / moon 0.1.20261016 / node v25.2.1；口令 `scripts/bench_baseline.sh`）

| CASE | TARGET | MIN | MED | MAX | 说明 |
|---|---|---:|---:|---:|---|
| pbkdf2/kdf（Fernet 200k，24 例） | js | **3 442 ms** | 3 637 ms | 96 442 ms | 每例=1 次加密/解密（含一次 200k KDF） |
| canonical 深嵌套 5k/20k（25 例） | wasm | **864 ms** | 973 ms | 1 006 ms | 含 5 000 / 20 000 层 |
| envelope 往返/校验（25 例） | wasm | **837 ms** | 986 ms | 1 021 ms | to_rhop_bytes ↔ from_rhop_bytes + checksum |
| relay 单次收发（8 例，js） | js | **3 423 ms** | 3 614 ms | 4 410 ms | 含子进程 relay server 起停 |
| sqlite claim 并发（69 例，js） | js | **26 208 ms** | 26 279 ms | 26 728 ms | 含多进程 claim / E2E 用例 |
| digest（21 例） | wasm | **1 407 ms** | 1 439 ms | 13 410 ms | 含 PBKDF2 小轮（c=2000/20000） |
| 全量测试（615 例） | wasm | **1 354 ms** | — | — | 单样本 |
| 全量测试（849 例） | js | **25 899 ms** | — | — | 单样本 |
| 全量测试（615 例） | native | **1 465 ms** | — | — | 单样本 |

> **噪声说明**：MAX 列的大偏差来自 C4 并行 lane 抢 CPU（`bench_baseline.sh` 每组先 warm 再计时，
> 且 moon 调用走 `with_moon_lock.sh` 串行；但其它 lane 的编译/测试仍会争 CPU）。**跨轮对比请用 MIN 或 MED，并固定机器负载。**
>
> 基线缺口（建议 owner 后续补）：
> ① 一个 `#skip("slow")` 的 PBKDF2-200k 微基准（直接调 `pbkdf2_hmac_sha256_hex(...,200000,32)` ×N 次取中位数）；
> ② 一个 canonical「5 000 键对象」用例（当前只有深嵌套）。

---

## 3. C4-Q3（P2）determinism 实测

### 3.1 `gen_conformance_vectors.py`（契约向量）——**完全确定性** ✅
```
Windows run1 = Windows run2 = WSL run3 = f22dda48e3b6b5083a5ae84f0f0872ec93f7fceb3c04fddfcb3b3742e8a3b9b3
= 仓库内 tracked fixture 的 sha256
```

### 3.2 生产者产物（`moonbit_vectors_full.json`）——**除随机 IV 外确定** ✅
| 对比 | 差异字段 | 非 crypto 差异 |
|---|---:|---:|
| Windows 三次两两对比 | 5（全部 crypto） | **0** |
| Windows vs WSL（同一份逻辑跨平台） | 5（全部 crypto） | **0** |
| 其中 `envelope`（含 to_rhop_bytes 字节 + checksum）、`canonical_json`、`digest`、`signer` | 0 | **逐字段一致** |

结论：**跨平台字节级一致性在"非随机字段"上成立**；随机字段是 Fernet 语义固有（vools 同样随机），
不属缺陷，但需要工具能区分"预期随机"与"意外漂移"。

### 3.3 新增可重复检查入口
`scripts/check_determinism.sh`：跑 N 轮 gen（比对 sha256）+ N 轮生产者（字段级 diff，自动把 `/crypto/`
路径归为"预期随机"），任一非 crypto 差异即 FAIL。Windows / WSL 实测均 **PASS**（见 §6）。

---

## 4. C4-Q4（P2）脚本端到端韧性（按既有自测边界）

| 场景 | 做法 | 结果 |
|---|---|---|
| 锁被跨平台持有 | 隔离锁目录 + `os=linux` owner，跑 gate check 步 | ✅ `LOCK-TIMEOUT` 判定，**rc=4**，无假红；文案提示"并发 moon，非产品红" |
| 跨平台并发（轻） | Windows check 步 与 WSL check 步**同时**启动 | ✅ 两者 rc=0（总墙钟 43s；`with_moon_lock` 串行化生效） |
| 跨平台并发（重） | Windows `moon test`(wasm) 与 WSL `moon test --target js` **同时**跑 | ✅ Windows `615/615 passed`、WSL `849/849 passed`，两边 **0 个** `Sys_error` / `cannot find binary path` ⇒ 锁 + `_build/wsl` 隔离在真实并发下有效 |
| 网络抖动 | relay 走本机子进程（无外网依赖）；按任务边界**不做**故障注入 | 未覆盖（记录为局限） |

> 未观察到"幽灵红"。C4 期间唯一一次 `cannot find binary path (rc=127)` 经定位是**我自己 bench 脚本**
> 漏传 `test` 子命令所致（见 §5），不是 moon/环境的瞬时故障 —— 这里如实纠正，避免误导后续排查。

---

## 5. C4-Q6（P3）本轮新增/修改脚本的自身缺陷（首跑暴露，均已修）

| # | 缺陷 | 现象 | 修法 |
|---|---|---|---|
| 1 | `bench_baseline.sh` 的 `measure` 调用漏了 `test` 子命令 | `moon <file>` → `no such subcommand` / rc=127 | 各步骤补 `test`（`moon test <file>`） |
| 2 | `bench_baseline.sh` 用 `${t1-t0}` 输出耗时 | 打印 epoch 大数（参数默认值语义，不是算术） | 改 `$((t1 - t0))` |
| 3 | `bench_baseline.sh` 用 `echo "…%s…"` 带占位符 | 标签里出现字面 `%s` | 改 `printf` |
| 4 | `check_determinism.sh` 收敛 PATH 后再找 python | Windows 下 `python` 不在最小组 PATH → gen 全部失败 | 先捕获 python 绝对路径，再收敛 PATH |
| 5 | 内联 python 输出 GBK 编码 | `UnicodeEncodeError: 'gbk' codec can't encode '✓'` | `sys.stdout.reconfigure(encoding="utf-8")` + 判定行改 ASCII 标记 |

---

## 6. C4-Q5（P3）文档 / 脚本一致性

| 检查项 | 结果 |
|---|---|
| README「测试入口退出码」表（0/1/2/3/4）与两脚本实现 | ✅ 完全一致（`scripts/test_all.sh --help` 同表） |
| `run-logs` 保留策略是否生效 | ✅ 代码存在（`RX_MBT_RUNLOG_KEEP=20` / `MAXMB=50` + `prune_run_logs`），实测目录数 **10**（≤20），无增长失控 |
| README「最新实测计数」快照 | ⚠ 已过期：README 写 612/825/612（C3 快照），C4 过程实测 **615/849/615**（lane 在途）→ 建议 C4 verify 后统一刷新 |
| 矩阵 v5 计数 | 与 C3 verify 一致（193/264/472），本轮未变 |
| 报告内数字 | C2/C3 报告为历史快照，属正常；C4 报告以「C4 过程中快照」标注 |

---

## 7. 证据清单

| 主题 | 证据 |
|---|---|
| ① tracked / ignore 失效 | `git ls-files` / `git check-ignore -v` 输出（§1） |
| ① 产物抖动 | 3 次生产者 sha（`4a5175c2…`/`485beb29…`/`f6af42b1…`）+ 字段级 diff 5 处（全 crypto） |
| ② 性能基线 | `scripts/bench_baseline.sh`、`fist-mbt/reports/c4-bench-windows.json`、`C:/tmp/c4_bench_*.log` |
| ③ determinism | `scripts/check_determinism.sh`（Win/WSL 各一次 PASS）、`C:/tmp/c4_gen_{a,b}.json`、`/tmp/c4_gen_wsl.json` |
| ④ 韧性 | `C:/tmp/c4_lock.log`（rc=4）、`C:/tmp/c4_conc_win.log`、`/tmp/c4_conc_wsl.log`、`C:/tmp/c4_conc_win_build.log`、`/tmp/c4_conc_wsl_build.log` |
| ⑤ 文档一致性 | `README.md:340-356`、`scripts/test_all.sh` 头部/`--help`、`prune_run_logs`（`test_all.sh:459`） |
| ⑦ 并行中间态 | `git status --porcelain`（`?? test-suit/*/c4_e2e_test.mbt` 等） |

## 8. 局限

1. 未做网络故障注入（relay/HTTP 端点均本机回环），仅覆盖锁竞争与跨平台并发；
2. 性能基线受 C4 并行 lane 噪声影响（MIN 与 MED 已给出，但仍建议在冻结树上复测一次）；
3. 安全审计（路径穿越/掩码/坏信封不回显 payload）由 business/protocol/crypto lane 的 C4 报告覆盖，
   本轮 QA 只做**工具与卫生面**的抽验，未重复其审计内容。
