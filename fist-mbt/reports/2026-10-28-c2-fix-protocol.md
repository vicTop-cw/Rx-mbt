# C2 修复报告 — 协议 / 摘要 / 文档域（资源与并发）

> 轮次：C2（寻虫→修复→打磨→验证→清整 ×3 轮的第 2 轮），主题：**资源与并发**，本域（协议/摘要/文档）修复记录。
> 输入：`fist-mbt/reports/2026-10-28-c2-bugfind-protocol.md`（C2P-01…C2P-09，P0×0 / P1×2 / P2×3 / P3×4）。
> 执行：impl-core，2026-10-28（UTC+8）。**未改任何 API 签名**（唯一新增面是一个 `pub const`，见 §2.4）。
> 纪律：所有 moon 命令经 `bash scripts/with_moon_lock.sh`；格式化用 `~/.moon/bin/moonfmt.exe -w`。

---

## 1. 摘要

| ID | 严重度 | 处置 | 结果 |
|---|---|---|---|
| **C2P-01** | P1 | ✅ 已修：`canonical_json` writer 改**显式栈迭代**（消除递归栈溢出） | 深度 3000/5000/20000 稳定序列化（修复前 3000/5000 触发 `RangeError`，阈值随调用深度漂移） |
| **C2P-02** | P1 | ✅ 已修：PBKDF2 预压缩 ipad/opad + 免分配内层循环 | 200k 轮（Fernet KDF 参数）**js 2421→794 ms（≈3.0×）**；wasm/native 100k 分别 1408→899 / 1886→1014 ms |
| **C2P-03** | P2 | ✅ 已修：`assemble` 统一 `hops_seen.copy()`（防御性复制） | 外部 push 后信封长度/checksum 不变；`with_hops_seen` 与其它 wither 行为一致 |
| **C2P-04** | P2 | ✅ 文档化：`payload`/`result` **按不可变值使用**契约（结构体 docstring + DOC.md） | 不引入深拷贝（保持 vools 语义与大对象性能） |
| **C2P-05** | P2 | ✅ 已修：新增 `MAX_ENVELOPE_NESTING_DEPTH = 1000` 并显式传给 `@json.parse` | 读写深度不对称被固定并有回归用例；不再依赖核心默认值 |
| **C2P-06** | P2 | ✅ 已修：README×2 / DOC / 矩阵数字按本轮实测刷新 | 见 §3；并新增 `test-suit/rhop_vectors` 一行（此前三份文档均缺） |
| C2P-07 | P3 | ✅ 已修（低风险版）：键排序**预编码一次**再比较 | 5000 键 canonical：68–135 ms → **22 ms**（≈3–6×） |
| C2P-08 | P3 | 📄 文档化：进程级单例语义写入 DOC/源码注释（不改 API） | — |
| C2P-09 | P3 | 📄 文档化：O(n) 峰值内存 ~2–3× payload 写入 DOC | — |

**验证结论**：Windows 与 WSL 双平台，本域四组命令全绿且数字一致（§4）。

---

## 2. 逐条修法

### 2.1 C2P-01（P1）`canonical_json` 递归 → 显式栈迭代

**文件**：`rhop/json_canonical.mbt`

- 新增 `priv enum CanonTask { Val(Json); Key(String); Raw(String); CloseArray; CloseObject }`；
- `write_canonical_json` 改为「显式栈 + 逆序压栈」的迭代实现：每个容器先把闭合符压底，再逆序压入「值 / 分隔符 / 键」，循环 `stack.pop()` 直到空栈；
- 输出与递归版**逐字节一致**（分隔符 `", "` / `": "`、键升序、转义规则不变）——由既有 19 条 canonical 用例 + qa fixture 7 例守住；
- 深度只受堆内存限制：回归用例覆盖 5000 与 20000 层（`[[…null…]]` 长度 = d+4+d）。

### 2.2 C2P-02（P1）PBKDF2 秒级阻塞 → 预压缩 pad + 免分配内层循环

**文件**：`rhop/digest.mbt`

新增 4 个**私有** SHA-256 增量原语：

| 原语 | 作用 |
|---|---|
| `sha256_pad_state(pad)` | 把 64 字节 ipad/opad **压缩成 8 字初始状态**（每轮不再重算这两个块） |
| `sha256_finish_from_state(state, data, prefix_len)` | 从给定状态继续吸收 `data` 并收尾（含 0x80 填充 + 8 字节大端比特长度；`prefix_len` 计入已吸收的 64 字节 pad） |
| `sha256_state_to_bytes(state)` | 8 字 → 32 字节大端摘要 |
| `sha256_hmac_from_pad_states(ipad_state, opad_state, msg)` | 语义等价 `hmac_sha256(key,msg)`，跳过 pad 重压缩与 `bytes_concat` 分配 |
| `pbkdf2_pad_states(password)` | 计算一次 pad 状态对（key > 64 字节先折叠，与 RFC 2104 一致） |

PBKDF2 主循环改为 `sha256_hmac_from_pad_states(ipad_state, opad_state, u)`；`t` 仍用 `FixedArray` 原地 XOR。
**压缩次数每轮 4→2、堆分配 ~6→1**。算法语义零变化：RFC 6070/7914 向量、fixture（iterations=1000）、
新增多轮向量（c=2000/20000）与 >64 字节 salt 向量全部逐字节一致。

**前后对比（同机、探针 R7/R20）**

| 目标 | 修复前 | 修复后 | 提升 |
|---|---|---|---|
| js 200k 轮 | 2421 / 3391 ms（两次） | **794 ms** | ≈3.0–4.3× |
| wasm 100k 轮 | 1408 ms | **899 ms** | ≈1.6×（200k ≈1.8 s） |
| native 100k 轮 | 1886 ms | **1014 ms** | ≈1.9×（200k ≈2.0 s） |

### 2.3 C2P-03（P2）`hops_seen` 引用外泄 → 构造时防御性复制

**文件**：`rhop/envelope.mbt`（`assemble`）

```moonbit
hops_seen: hops_seen.copy(),   // 单点修复：覆盖 new/new_full/from_dict/from_rhop_bytes/全部 wither
```

回归：`envelope_test.mbt` 新增「hops_seen 防御性复制」用例——外部数组 push 后，信封仍是 1 条、`checksum` 未变且 `== compute_checksum()`；`with_hops_seen` 同样成立。

### 2.4 C2P-05（P2）读写深度不对称 → 显式常量 + 回归固定

**文件**：`rhop/envelope.mbt`

- 新增 `pub const MAX_ENVELOPE_NESTING_DEPTH : Int32 = 1000`（**唯一新增公开面**，纯常量、无签名变更）；
- `from_rhop_bytes` 显式传 `max_nesting_depth=MAX_ENVELOPE_NESTING_DEPTH`，避免依赖 `@json.parse` 默认值（核心升级不再悄悄改变行为）；
- docstring 写明「写侧无上限 / 读侧 1000，超过属 out-of-contract」。

回归：`envelope_test.mbt` 新增「MAX_ENVELOPE_NESTING_DEPTH 常量与读写深度边界」——深度 300 往返 Ok；深度 2000 写成功、读得可诊断 `Err`（`Depth limit`），把不对称固定为可测行为。

### 2.5 C2P-04 / C2P-08 / C2P-09（P2/P3）文档化

- **payload/result 引用契约**：`Envelope.payload` 字段 docstring + `DOC.md` 写明「按不可变值使用，不得原地改内层 Array/Map」；`hops_seen` 已改为复制。
- **进程级单例**：`clipboard.mbt` 的 `last_read_reason` / 探测缓存语义在 DOC 与源码注释标注（多上下文会互相覆盖；需要隔离请各自持有 backend 并直调 trait 方法）。
- **峰值内存**：DOC 写明 O(n) 时间、峰值 ~2–3× payload（String + UTF-8 Bytes 双份），1MB payload 实测 checksum 65 ms / 写 135 ms / 读 70 ms。

### 2.6 C2P-07（P3）键排序预编码

**文件**：`rhop/json_canonical.mbt`

旧 `compare_codepoint(a,b)` 每次比较 `@utf8.encode(a)` + `@utf8.encode(b)`（排序 5000 键 ≈ 6 万次比较 → 12 万次编码）。
新 `sorted_keys(members)`：先构造 `Array[(String, Bytes)]`（每键编码一次），`sort_by(compare_codepoint_bytes)` 比较已编码字节，再抽出键序。
**5000 键 canonical：68–135 ms → 22 ms**；键序语义不变（补充平面字符仍按 Unicode 码点序，由既有 `U+FFFD < U+1F600` 判别用例守住）。

---

## 3. 文档刷新（C2P-06）

| 文档 | 改动 |
|---|---|
| `README.md` / `README.mbt.md`（逐字节同步） | 测试计数表按本轮快照刷新：`rhop` 156/160/156、`rhop_vectors` 0/2/0（**新增行**）、`rhop_js` 56、`clipboard` 25、`interact` 22、`business` 10/53/10、`task` 46/101/46、全模块 wasm 612 / native 612 / js 819；命令块同步；顶部加「并行 lane 仍在追加测试，最终数字以 `scripts/test_all.sh` 为准」的快照说明 |
| `DOC.md` | 新增 C2 资源说明：canonical writer 迭代化 + 键排序预编码（20000 层、5000 键 22 ms）；PBKDF2 资源与提速（含 200k 三目标实测）；envelope 的载荷契约 / 嵌套深度不对称 / 峰值内存 |
| 矩阵 `2026-10-27-rhop-vools-parity-matrix.md` | §9 实测状态表按快照刷新（含 `rhop_vectors` 行、并行 lane 说明）；§10 覆盖表与小计/合计重算（js 419 例、wasm/native 212 例）；§7 新增 19/20/21 三条「资源类已知差异」（深度不对称、payload 引用契约、PBKDF2 耗时）；§11 记录 C2 修复项 |

---

## 4. 验证汇总（本轮真实输出）

### Windows（Git Bash；moon 0.1.20261016 / node v25.2.1）

```text
moon check（项目级）                              : 0 error
moon test test-suit/rhop                         : Total tests: 156, passed: 156, failed: 0.
moon test test-suit/rhop --target js             : Total tests: 160, passed: 160, failed: 0.
moon test test-suit/rhop --target native         : Total tests: 156, passed: 156, failed: 0.
moon test -p test-suit/rhop_vectors --target js  : Total tests: 2, passed: 2, failed: 0.
```

### WSL（Ubuntu-22.04；moon 0.1.20261021）

```text
WSL check errors: 0
WSL rhop wasm:   Total tests: 156, passed: 156, failed: 0
WSL rhop js:     Total tests: 160, passed: 160, failed: 0
WSL rhop native: Total tests: 156, passed: 156, failed: 0
WSL vectors js:  Total tests: 2, passed: 2, failed: 0
```

> 双平台数字**逐项一致**；所有 moon 命令均经 `bash scripts/with_moon_lock.sh`（避免与其他 lane 的构建并发污染）。
> 格式化：`~/.moon/bin/moonfmt.exe -w` 作用于 3 个产品文件 + 3 个测试文件；格式化后重跑上述四组命令仍全绿。

### 新增回归用例（+7）

| 文件 | 用例 | 守护目标 |
|---|---|---|
| `test-suit/rhop/json_canonical_test.mbt` | 深嵌套 5000 层不栈溢出（含 ascii 口径一致）；深嵌套 20000 层 | C2P-01 |
| `test-suit/rhop/digest_test.mbt` | PBKDF2 c=2000 / c=20000（hashlib 向量）；>64 字节 salt（100B）；iterations=1 边界 | C2P-02 |
| `test-suit/rhop/envelope_test.mbt` | hops_seen 防御性复制（new_full + with_hops_seen）；`MAX_ENVELOPE_NESTING_DEPTH` 与读写深度边界 | C2P-03 / C2P-05 |

---

## 5. 改动文件清单

**产品代码（仅本域 3 个文件，未改 API 签名）**

1. `rhop/json_canonical.mbt` —— writer 迭代化 + `CanonTask` + `sorted_keys`（预编码键排序）
2. `rhop/digest.mbt` —— PBKDF2 优化 + 5 个私有 SHA-256 增量原语
3. `rhop/envelope.mbt` —— `hops_seen.copy()`、`MAX_ENVELOPE_NESTING_DEPTH` 常量 + 显式 parse 深度、payload 契约 docstring

**测试（3 个文件，+7 用例）**

4. `test-suit/rhop/json_canonical_test.mbt`
5. `test-suit/rhop/digest_test.mbt`
6. `test-suit/rhop/envelope_test.mbt`

**文档（4 份）**

7. `README.md`、8. `README.mbt.md`（同步）、9. `DOC.md`、10. `fist-mbt/docs/2026-10-27-rhop-vools-parity-matrix.md`

**报告（2 份）**

11. `fist-mbt/reports/2026-10-28-c2-bugfind-protocol.md`（寻虫）
12. `fist-mbt/reports/2026-10-28-c2-fix-protocol.md`（本文件）

> 未改动：`rhop_task/*`、`monitor/*`、`rhop` 包内他人文件（config/session/actions/mirror…）、`moon.mod`、`moon.pkg`。

---

## 6. 未修 / 已接受项（留待 C3 或后续）

1. **C2P-04 payload 深拷贝**：有意不做（1MB payload 每信封复制违背性能目标，且与 vools 存引用一致）→ 以契约 + 用例固定。
2. **C2P-08 单例隔离**：不改 API（会破坏 clipboard 的便捷函数），仅文档声明；若要多租户，建议调用方直接持有 `&ClipboardBackend`。
3. **C2P-09 峰值内存**：未引入流式写出（需要新 API/内部 Buffer 路径），当前 O(n) 峰值 2–3× 已在文档写明。
4. **PBKDF2 仍为纯 MoonBit**：200k 轮 js ≈0.8 s 属可接受（Fernet 每信封一次）；若吞吐仍是瓶颈，C3 可考虑「派生密钥缓存」而非继续压轮数（那会改变协议语义）。
