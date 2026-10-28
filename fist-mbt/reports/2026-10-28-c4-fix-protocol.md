# C4 修复报告 — 协议 / 摘要 / 生成物 / 文档域

> 轮次：C4（单轮：寻虫→修复→打磨→验证→清整），主题：端到端 + 生成物卫生 + 安全审计。
> 输入：`fist-mbt/reports/2026-10-28-c4-bugfind-protocol.md`（C4P-01…07）。
> 执行：impl-core，2026-10-28（UTC+8）。纪律：moon 命令全经 `bash scripts/with_moon_lock.sh`；格式化 `~/.moon/bin/moonfmt.exe -w`。
> **未改任何 API 签名、未新增功能**；产品代码改动 1 处纯内部优化（字符串转义批量写）+ 测试/文档。

---

## 1. 摘要

| ID | 严重度 | 处置 | 结果 |
|---|---|---|---|
| **C4P-01** | P1 | 生产者产物加**可复现元数据** + 确定性回归用例（`deterministic_sections` / `volatile_sections` / `deterministic_digest`） | 两次运行 `deterministic_digest` **完全相同**（`e3b90080…`）；整文件仅 `crypto` 变化；回归用例把「确定性被破坏」变成硬红 |
| **C4P-02** | P1 | `write_canonical_string` 改为**普通字符 run 批量写入**（内部实现，输出逐字节不变） | 10MB payload：checksum **3531→632 ms（5.6×）**、写 **3522→366 ms（9.6×）**、读 **3437→334 ms（10.3×）**；10×1MB 往返 3924→904 ms（4.3×） |
| C4P-03 | P2 | 跨进程 e2e 正向基线（已实测，无需修） | 双进程 5/5 收齐；并发写同名 5/5 合法、0 `.tmp`；坏包不崩、静默跳过 |
| C4P-04 | P2 | 深嵌套 e2e 证据（已知行为，无需修） | depth 2000/5000 可写、读 `Err(Depth limit)`；与 `MAX_ENVELOPE_NESTING_DEPTH=1000` 文档一致 |
| C4P-05 | P3 | 记录建议（不改协议/API） | 建议调用方把 `RhopWatcher::bad_files()` 打点 |
| C4P-06 | P3 | ✅ 文档数字刷新到 C4 快照 | README×2 / DOC / 矩阵同步（见 §4） |
| C4P-07 | P3 | 记录方法学结论 | 先前的「null 被拒」是探针键序问题，非缺陷 |

**移交 Lead（生成物策略，需 git 操作）**：
```bash
git rm --cached fist-mbt/reports/moonbit_vectors_full.json
git rm --cached test-suit/rhop_js/fixtures/moonbit_vectors.json
# 建议在仓库 .gitignore 增补一行：
#   fist-mbt/reports/moonbit_vectors_full.json
# （fixtures/.gitignore 已声明 moonbit_vectors.json，untrack 后立即生效）
```
> 未由本 lane 执行：C4 分工规定生成物 untrack/ignore 由 Lead 统一清整。

---

## 2. 关键修复细节

### 2.1 C4P-01 生成物可复现（`test-suit/rhop_vectors/producer_test.mbt`）

新增：

```moonbit
fn deterministic_digest(canonical_json : Array[Json], digest : Json,
                        envelope : Array[Json], signer : Json) -> String
```

产物顶层新增三个字段：

```jsonc
"deterministic_sections": ["canonical_json", "digest", "envelope", "signer"],
"volatile_sections": ["crypto"],           // Fernet 随机 IV + 时间戳
"deterministic_digest": "sha256:<hex>",    // 对四节 canonical_json 求 sha256
```

新增回归 `vectors · 确定性分节可复现（crypto 为 volatile）`：
同一次运行内两次构建，四节 canonical 文本必须完全相同、`deterministic_digest` 必须相同，
而 `crypto` 两次必须不同（随机 IV）——把「可复现性」变成可执行判据。

**实测证据**（两次独立 `moon test -p test-suit/rhop_vectors --target js`）：

```text
run1 deterministic_digest = e3b90080ff1e3f6e01e22da7a9f4c4560755d3d69906acfa0d8016d0b7e49210
run2 deterministic_digest = e3b90080ff1e3f6e01e22da7a9f4c4560755d3d69906acfa0d8016d0b7e49210
确定性摘要一致: YES
整文件是否变化: True        （crypto 随机 ⇒ 文件仍会变，故不入库）
crypto 变化: True
其余四节变化: False
```

### 2.2 C4P-02 字符串转义批量写（`rhop/json_canonical.mbt`）

旧实现：`for c in text { ... buf.write_char(c) ... }` —— 每个 UTF-16 码元一次方法调用。
新实现：按「需要转义的码元」切分，普通 run 一次性 `buf.write_string(text.substring(start,end))`；
只有 `"`、反斜杠、控制字符、以及 `ensure_ascii=true` 时的非 ASCII 才进入 `write_canonical_escape_unit`。
转义仍按 **UTF-16 码元** 输出，因此 `ensure_ascii=true` 下 emoji 自然拆成 `\ud83d\ude00`（与 Python 代理对逐字节一致）。

**性能实测**（一次性副本，js 目标）：

| 场景 | 修复前 | 修复后 | 提升 |
|---|---:|---:|---:|
| 10MB payload checksum | 3531 ms | **632 ms** | 5.6× |
| 10MB `to_rhop_bytes` | 3522 ms | **366 ms** | 9.6× |
| 10MB `from_rhop_bytes` | 3437 ms | **334 ms** | 10.3× |
| 10×1MB 往返 | 3924 ms | **904 ms** | 4.3× |

**正确性**：新增 3 条回归（1MB 纯文本 bulk 路径、run 边界交替转义、两种口径非 ASCII/代理对），
并与既有 21 条 canonical 用例 + qa fixture 7 例一起通过 ⇒ 输出逐字节不变。

---

## 3. 跨进程端到端基线（C4P-03，作为后续回归基线）

| 场景 | 结论 |
|---|---|
| 双进程 watch-skip + send | 5/5 收齐并解密（`received 1..5`）|
| 并发写同名（两个 sender） | 5 个文件全合法 JSON；**0 个 `.tmp` 残留** ⇒ tmp+rename 原子写有效 |
| 坏包（截断） | watcher 不崩、不中断，静默跳过；好包正常收（诊断可观测性见 C4P-05）|

**多进程 e2e 的正确姿势（本轮踩坑记录）**：不要用 `with_moon_lock.sh moon run <长驻进程>`，
它会在进程整个生命周期持锁 ⇒ 另一进程的 `moon run` 永久等待（实测死锁）。改为**先持锁 `moon build`**，
再 `node <构建产物>` 直接起多个进程。

---

## 4. 文档刷新（C4P-06，C4 快照）

| 文档 | 改动 |
|---|---|
| `README.md` / `README.mbt.md`（逐字节同步） | 计数表：`rhop` **159/163/159**、`rhop_vectors` **0/3/0**、全模块 **wasm 615 / js 849 / native 615**；时间戳改「2026-10-28 17:4x C4 快照」 |
| 矩阵 | §9 实测表与 §10 覆盖表/合计按 C4 快照刷新（js 口径 **429 例**、wasm/native **215 例**） |

> 说明：数字仍会随各 lane 增量变化；长期建议 README 计数表以「命令 + 快照时间」为主（C4P-06 建议）。

---

## 5. 验证（真实输出）

### Windows（`scripts/test_all.sh` 四步 + 分包）

```text
 SUMMARY  (platform=windows, moon=moon 0.1.20261016, node=/c/Program Files/nodejs/node)
 check    PASS   0 errors
 wasm     PASS   Total tests: 615, passed: 615, failed: 0
 js       PASS   Total tests: 849, passed: 849, failed: 0
 native   PASS   Total tests: 615, passed: 615, failed: 0
 RESULT: PASS —— 所有已执行步骤判绿（4 步）
```

分包：`test-suit/rhop` **159/163/159**、`rhop_vectors` **0/3/0**。

### WSL（Ubuntu-22.04 / moon 0.1.20261021）

```text
WSL check: 0 errors
WSL rhop wasm/js/native: 159 / 163 / 159
WSL vectors js: Total tests: 3, passed: 3, failed: 0
WSL project wasm:   Total tests: 615, passed: 615, failed: 0
WSL project js:     Total tests: 849, passed: 849, failed: 0
WSL project native: Total tests: 615, passed: 615, failed: 0
```

### 卫生与格式化

```text
fmt 幂等: YES（rhop/json_canonical.mbt、json_canonical_test.mbt、producer_test.mbt、signer.mbt 连续两次 moonfmt -a 后 sha256 一致）
README.md / README.mbt.md：diff 为空；围栏 22 / 22；DOC.md 54；矩阵 2（均成对）
生成物可复现证据：deterministic_digest 两次一致（§2.1）
```

---

## 6. 改动文件清单

**产品代码（1，纯内部优化，无 API 变化）**
1. `rhop/json_canonical.mbt` —— `write_canonical_string` run 批量写 + 新增私有 `write_canonical_escape_unit`

**测试（2）**
2. `test-suit/rhop/json_canonical_test.mbt` —— +3 条（bulk 路径 / run 边界 / 两种口径非 ASCII 与代理对）
3. `test-suit/rhop_vectors/producer_test.mbt` —— 产物三字段元数据 + `deterministic_digest` + 1 条确定性回归

**文档（4）**
4. `README.md`、5. `README.mbt.md`（同步）、6. `fist-mbt/docs/2026-10-27-rhop-vools-parity-matrix.md`（§9/§10 数字）
   注：`DOC.md` 本轮无实质改动（C3 已补的资源说明仍适用）

**报告（2）**
7. `fist-mbt/reports/2026-10-28-c4-bugfind-protocol.md`
8. `fist-mbt/reports/2026-10-28-c4-fix-protocol.md`（本文件）

> 未改动：`rhop_task/*`、`monitor/*`、`moon.mod`、`moon.pkg`、rhop 包内他人文件、`scripts/*`、`.gitignore`（生成物策略由 Lead 执行）。
