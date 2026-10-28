# C2 寻虫报告 — 协议 / 摘要 / 文档域（资源与并发视角）

> 轮次：C2（寻虫→修复→打磨→验证→清整 ×3 轮的第 2 轮），主题：**资源与并发**
> （sqlite 句柄、子进程、timer、文件句柄、watch 挂死、双平台差异；本域聚焦「内存/引用复用、CPU 边界、栈深度、缓冲区、全局单例、文档数字漂移」）。
> 范围（只读）：`rhop/{core,digest,json_canonical,envelope,signer,integrity}.mbt` + `test-suit/rhop/*` + `test-suit/rhop_vectors` + `README.md` / `DOC.md` / 矩阵。
> 方式：**只读审计；真树未改任何产品代码/测试**。动态证据在一次性副本 `E:/tmp/c2audit`（工作树 tar 拷贝，排除 `_build`/`.git`，新增 throwaway 包 `test-suit/c2audit`）。
> 探针断言的是**当前行为**（打印测量值 / 复现异常），因此「打印出数据」「RangeError」= 缺陷在。
> 审计人：impl-core　时间：2026-10-28（UTC+8）
> 结论：**P0 × 0 / P1 × 2 / P2 × 3 / P3 × 4**；P1 两条都建议本轮修（一处栈溢出、一处 PBKDF2 秒级阻塞）。
> 与 C1 的关系：C1 已修 PROTO-01（`to_rhop_bytes` 重算 checksum）、PROTO-02/04/05/08；本报告**不重复** C1 条目，只在必要时引用其结论。

---

## 0. 汇总表

| ID | 严重度 | 位置 | 一句话 | 裁决建议 |
|---|---|---|---|---|
| **C2P-01** | **P1** | `rhop/json_canonical.mbt:144-195`（`write_canonical_json` 递归） | 深嵌套 Json 递归写入 → **`RangeError: Maximum call stack size exceeded`**；阈值不确定（2000 可过 / 3000 崩 / 5000 视调用深度有时过有时崩）⇒ 同一份数据在不同调用上下文下「有时能校验、有时进程崩」 | **本轮修**：改显式栈迭代写（API 不变） |
| **C2P-02** | **P1** | `rhop/digest.mbt:372-419`（`pbkdf2_hmac_sha256` 内部逐轮 `hmac_sha256`） | PBKDF2 **200000 次（Fernet KDF 的官方参数）实测 2.4–3.8 s**（js 2.4–3.4 s / wasm 2.8 s / native 3.8 s）；每轮 6 次堆分配 + 重复处理 ipad/opad 块 ⇒ 加密/解密单个信封阻塞数秒 | **本轮修**：缓存 pad 后状态 + 免分配内层循环（API 不变） |
| **C2P-03** | P2 | `rhop/envelope.mbt:39-80`（`assemble` 直接存 `hops_seen` 引用）+ `:465-486`（`with_hops_seen`） | **hops_seen 数组引用外泄**：调用方 `push` 后信封内容变化、`checksum != compute_checksum()`（已封信封被静默无效化）；且 `with_hops_seen` 与 `with_result`（复制）行为不一致 | **本轮修**：`assemble` 统一防御性复制 |
| **C2P-04** | P2 | `rhop/envelope.mbt` 全体 wither（`payload` 直接复用） | `payload` / `result` 的 `Json` **引用被多个信封共享**（`with_updated_at` 后的信封与原件同引用），任一持有方原地改数组合则两封信封同时变化 | 本轮**文档化契约**（payload 按不可变使用）+ 加回归用例；不深拷贝（避免 1MB payload 复制成本，且与 vools 一致） |
| **C2P-05** | P2 | `rhop/envelope.mbt:192-222`（`from_rhop_bytes` 未显式给 `max_nesting_depth`） | **写/读深度不对称**：`to_rhop_bytes` 可写出 2000 层嵌套，`from_rhop_bytes` 读同字节报 `Depth limit exceeded`（实测 1000 层可读、2000 层不可读）⇒ 自己写的文件自己读不回 | **本轮修**：显式具名常量 + 文档标注上限 + 回归用例 |
| **C2P-06** | P2 | `README.md:341-350`、矩阵 `§9/§10`、`§11` | **文档数字漂移**：文档 587/756|765/587，实测 **600/797/600**；分包 rhop 文档 131/135/131 vs 实测 **144/148/144**、interact 13 vs **25**、business 10/41/10 vs **10/47/10**、task 46/90/46 vs **46/99/46**；新增 `test-suit/rhop_vectors`（0/2/0）**三份文档均未记录** | **本轮修**：全部按实测更新（文档属本域作用域） |
| C2P-07 | P3 | `rhop/json_canonical.mbt:122-138`（`compare_codepoint`） | 键排序**每次比较都做 2 次 UTF-8 编码**（O(n log n) 次分配）：5000 键实测 68–135 ms | 可选优化（预编码排序），不影响正确性 |
| C2P-08 | P3 | `rhop/clipboard.mbt`（`last_read_reason_slot` / `detect_cache` / `detect_probe`）、`rhop/digest.mbt`（`sha256_k` / `md5_k` 为可变 `let Array`） | **进程级可变单例**：多 fiber / 多逻辑上下文交错时状态互相覆盖（`last_read_reason` 尤其容易被另一路读覆盖）；digest 常量数组虽未导出，但仍是可变全局 | 文档标注「单线程/单上下文假设」+ 不改 API |
| C2P-09 | P3 | `rhop/json_canonical.mbt:196-210`、`rhop/envelope.mbt:175-179` | **峰值内存 2–3×**：`canonical_json` 先建完整 String 再 `utf8.encode` 成 Bytes；1MB payload 实测 `to_rhop_bytes` 87–118 ms、峰值约 2 MB 额外 | 文档声明 O(n) 峰值；若日后要流式，再引 Buffer 直写 |

---

## 1. C2P-01（P1）`canonical_json` 递归 → 深嵌套栈溢出（非确定阈值）

**位置**：`rhop/json_canonical.mbt:144-195` `write_canonical_json(buf, value, ascii_only)` 递归调用自身；被 `canonical_json`/`canonical_json_ascii`/`canonical_json_utf8`/`canonical_json_ascii_utf8` 复用，进而被 `Envelope::compute_checksum` / `to_rhop_bytes` / `signer_preimage` / `canonical_object` 调用。

**动态证据**（`E:/tmp/c2audit`，js；`moon test -p test-suit/c2audit --target js`）：

```text
R6a depth=500   ok len=1004   ms=0
R6d envelope depth=2000 bytes=4290 ms=0
R6b depth=5000  ok len=10004  ms=1       ← 同一次运行的另一次跑法里是 RangeError（见下）
R13a depth=2500 ok ms=1 len=5004
R13b depth=3000 failed: RangeError: Maximum call stack size exceeded
R6c depth=50000 failed: RangeError: Maximum call stack size exceeded
```

**关键点：阈值不确定**。同一深度 5000 在两轮运行中一次成功、一次 `RangeError`（js 调用栈剩余深度取决于外层调用链；wasm 的栈上限又是另一个值）。这意味着：
- 同一份 payload 在「直接校验」时可能通过、在「daemon 里深一层调用」时崩；
- 崩溃形态是 **abort/RangeError（进程级），不是可捕获 Err** —— 对 daemon/relay 这类长驻进程是可用性事故，而不是一条错误日志。

**可达性**：`@json.parse` 有 `max_nesting_depth`（默认 ~1000），所以**外部字节**进不来；但**程序化构造**的 payload（例如任务结果里嵌了 AST/目录树、或 `RhopPacket.payload` 层层包装）可以超过阈值；本仓库多个 lane（mirror/daemon/sync）都会把外部 JSON 原样塞进 `Envelope.payload` 再 `to_rhop_bytes`。

**建议修法（本轮修，API 不变）**：把 `write_canonical_json` 改成**显式栈迭代**（与 `moonbitlang/core/json` 的 `Json::stringify` 同思路）：

```moonbit
priv enum CanonTask { Val(Json); Key(String); Raw(String); CloseArray; CloseObject }

fn write_canonical_json(buf : StringBuilder, value : Json, ascii_only : Bool) -> Unit {
  let stack : Array[CanonTask] = [Val(value)]
  while stack.pop() is Some(task) {
    match task {
      Raw(s) => buf.write_string(s)
      CloseArray => buf.write_char(']')
      CloseObject => buf.write_char('}')
      Key(k) => write_canonical_string(buf, k, ascii_only)
      Val(v) => match v {
        Null => buf.write_string("null")
        True => buf.write_string("true")
        False => buf.write_string("false")
        Number(n, repr~) => buf.write_string(canonical_number(n, repr))
        String(s) => write_canonical_string(buf, s, ascii_only)
        Array(items) =>
          if items.is_empty() { buf.write_string("[]") } else {
            buf.write_char('[')
            stack.push(CloseArray)
            let mut i = items.length() - 1
            while i >= 0 {
              stack.push(Val(items[i]))
              if i > 0 { stack.push(Raw(", ")) }
              i = i - 1
            }
          }
        Object(members) => { /* 排序后按同样方式逆序压栈：Val(v) / Raw(": ") / Key(k) / Raw(", ") */ }
      }
    }
  }
}
```

**回归用例（加到 `test-suit/rhop/json_canonical_test.mbt`）**：
① 深度 5000 的数组 `canonical_json` 不崩且长度 = 5000+1+5000；② 同深度 `canonical_json_ascii` 一致；③ 深度 2000 的 `Envelope.payload` → `to_rhop_bytes` 不崩；④ **字节等价性护栏**：已落地 fixture 7 例 + `JSON_EXPECTED` 全绿（保证迭代化不失真）。

**裁决建议**：P1 本轮修。附带把 §9 测试覆盖里补一条「深嵌套资源用例」。

---

## 2. C2P-02（P1）PBKDF2 200k 迭代 = 秒级阻塞（资源：CPU / 分配）

**位置**：`rhop/digest.mbt:372-419` `pbkdf2_hmac_sha256`；每次迭代调用 `hmac_sha256(password, u)`，而 `hmac_sha256`（`:330-345`）内部 `bytes_concat(ipad, msg)` / `sha256(...)` / `bytes_concat(opad, inner)` / `sha256(...)`——每轮约 6 次堆分配，且 **ipad/opad 的两个 64 字节块每轮都被重新压缩**。

**动态证据**（三目标实测，`moon test -p test-suit/c2audit`）：

```text
js      R7  pbkdf2 1 iter=1ms, 1000=18ms, 200000=2421ms     （另一轮 3391ms）
wasm    R20 pbkdf2 1000=35ms, 100000=1408ms                  → 200k ≈ 2.8 s
native  R20 pbkdf2 1000=18ms, 100000=1886ms                  → 200k ≈ 3.8 s
```

对照：`sha256 1MB = 15–27ms`、`hmac 1MB = 23–33ms`、`hmac-sha256 RFC 向量` 全绿 ⇒ **不是算法错，是每轮固定开销过大**。
影响面：`rhop/crypto.mbt` 的 Fernet KDF 用 200000 次（VText 口径），即**每个信封加密/解密阻塞 2.4–3.8 秒**；watch/daemon 高频收包时会明显掉吞吐（且 js 单线程下整段事件循环被占住）。

**建议修法（本轮修，API 不变）**：在 `digest.mbt` 内加**私有**的 SHA-256 增量原语，PBKDF2 复用它，并把 pad 只处理一次：

1. `sha256_pad_block_state(pad : FixedArray[Byte]) -> Array[UInt32]`：把 64 字节 ipad/opad 直接压缩成 8 字初始状态（每轮不再重算）；
2. `sha256_from_state(state : Array[UInt32], data : Bytes) -> Bytes`：从给定状态继续吸收 `data`（长度 ≤ 64+8 的小块：内层 32 字节 U_{j-1}、外层 32 字节 digest），只做 1–2 次压缩；
3. PBKDF2 内层循环改为：`inner = sha256_from_state(ipad_state, u)`、`u = sha256_from_state(opad_state, inner)`，`t` 用固定 `FixedArray[Byte]` 原地 XOR。
   预期：每轮压缩次数 4 → 2、堆分配 6 → 1–2，**目标 ≥ 2× 提速**（200k 从 ~2.4 s 降到 ~1.2 s 以内；本机实测值见修复报告）。

**回归网**：RFC 6070 / RFC 7914 向量（c=1/2/4096）、`dk_len` 40/64 跨块、fixture `pbkdf2_hmac_sha256`（iterations=1000）全部必须保持逐字节相同 —— **算法语义零变化**，只改实现路径。

**裁决建议**：P1 本轮修。若时间不足，退路是「文档标注 200k ≈ 3 s 并建议调用方缓存派生密钥」，但那不解决 daemon 阻塞，故优先修。

---

## 3. C2P-03（P2）`hops_seen` 数组引用外泄 → 已封信封可被静默无效化

**位置**：`rhop/envelope.mbt:39-80` `assemble(..., hops_seen : Array[String], ...)` 直接把入参存进结构体（无复制）；`new_full`（`:105`）与 `with_hops_seen`（`:465`）都把它透传给 `assemble`；对照 `with_result`/`with_status`/`with_updated_at`/`with_signature` 内部**有** `.copy()`（`:424-462`、`:489-520`）⇒ 自身行为不一致。

**动态证据**：

```text
R2 new_full(hops_seen=arr) 后调用方 arr.push("h2")  ⇒ env.len=2, checksum stale: true
R3 with_hops_seen(arr)     后调用方 arr.push("y")   ⇒ wither.len=2, checksum stale: true
R1 默认 hops_seen 每次新数组（无共享缺陷）；但信封构造后被 push ⇒ e1.checksum==compute: false
```

**后果**：`Envelope` 语义是「12 字段 + checksum 一起封存」，但 `hops_seen` 是可逃逸的可变数组——
① 调用方（daemon 审计链、测试夹具）在信封构造后 append 会让 `checksum` 字段**立即过期**（`checksum_match` 变 false；C1 已让 `to_rhop_bytes` 重算，所以写盘字节仍合法，但内存对象自相矛盾）；
② 两个信封共享同一数组时互相串扰（并发/审计场景下最难查的一类）。

**建议修法（本轮修，API 不变）**：`assemble` 内统一 `hops_seen.copy()`（单点修复覆盖 `new_full`/`from_dict`/`from_rhop_bytes`/全部 wither）；`new` 的 `[]` 已是每次新数组。**回归用例**：R2/R3 场景改造为「调用方 push 后，信封 len 不变且 checksum 仍 == compute_checksum()」。

---

## 4. C2P-04（P2）`payload` / `result` 的 Json 引用共享（契约缺失）

**位置**：`rhop/envelope.mbt` 所有 wither 复用 `self.payload` / `self.result`。

**动态证据**：`R4 e1.payload.len=? e2.payload.len=2（同引用则=2）`、`R4 base/with_result payload same ref: true`。

**判断**：与 vools（Python dataclass 存引用）**行为一致**，不算复刻缺陷；但本项目多处把 `Envelope` 交给不同 actor（daemon 读、executor 写、mirror 存），Json 内部的 `Array`/`Map` 可变 ⇒ 「谁改了我的 payload」类问题。**不改深拷贝**（1MB payload 每信封复制 = 破坏性能且与 vools 不同）。

**建议**：在 `Envelope` 的 docstring + `DOC.md` 明确「**payload/result 按不可变值使用**：构造/接收后不得原地修改其内层 Array/Map；需要变更时构造新 Json 并通过 wither 替换」；并加一条回归用例固定该契约（共享引用存在，但「改 payload 后 checksum 必须重算」由调用方负责）。

---

## 5. C2P-05（P2）写/读深度不对称：自己写的信封自己读不回

**位置**：`rhop/envelope.mbt:192-222` `from_rhop_bytes` 调 `@json.parse(text, preserve_number_repr=true)`，**未显式指定 `max_nesting_depth`**（用核心默认值，实测约 1000）；写侧 `to_rhop_bytes` 无深度限制（受 C2P-01 栈限制，但 2000 层实测可写）。

**动态证据**：

```text
R10 depth=150/200/300: write ok, read ok
R15 depth=500/1000:    write ok, read ok
R15 depth=2000:        write ok, read ERR: envelope JSON 解析失败: Depth limit exceeded, please increase the max_nesting_depth parameter
```

**后果**：`1000 < depth ≲ 2000+` 区间内，`to_rhop_bytes` 产出的字节**只有本实现会拒绝**（跨实现/跨版本更糟）；且默认值随核心版本可变，属隐式依赖。

**建议修法（本轮修，API 不变）**：在 `envelope.mbt` 顶部加具名常量并在 `from_rhop_bytes` 显式传入：

```moonbit
/// 信封反序列化的嵌套深度上限（与 @json.parse 默认一致，显式化避免核心默认漂移）。
pub const MAX_ENVELOPE_NESTING_DEPTH : Int32 = 1000
...
let parsed = @json.parse(text, preserve_number_repr=true, max_nesting_depth=MAX_ENVELOPE_NESTING_DEPTH) catch { ... }
```

docstring 写明「写侧无限制（迭代式）、读侧上限 1000；超过上限的 payload 属 out-of-contract（需拆层或改为外部引用）」。回归用例：depth 300 往返绿（已有 R10 证据）；depth 2000 写成功 + 读得可诊断 Err（固定该不对称，防日后无声变化）。

---

## 6. C2P-06（P2）文档数字漂移（README / DOC / 矩阵）

**实测（本轮，`bash scripts/with_moon_lock.sh moon test ...`）**：

| 项 | 文档现值 | 实测值 | 漂移 |
|---|---|---|---|
| 全模块 wasm / js / native | 587 / 765（README 另一处 756）/ 587 | **600 / 797 / 600** | +13 / +32~41 / +13 |
| `test-suit/rhop`（wasm/js/native） | 131 / 135 / 131 | **144 / 148 / 144** | +13 / +13 / +13 |
| `test-suit/rhop_interact`（js） | 13 | **25** | +12 |
| `test-suit/rhop_business`（wasm/js/native） | 10 / 41 / 10 | **10 / 47 / 10** | 0 / +6 / 0 |
| `test-suit/rhop_task`（wasm/js/native） | 46 / 90 / 46 | **46 / 99 / 46** | 0 / +9 / 0 |
| `test-suit/rhop_vectors`（js） | **未记录** | 0 / 2 / 0（C1 新增的互操作产物生产者） | 缺失整包 |
| 其它（rhop_js 52 / clipboard 25） | 52 / 25 | 52 / 25 | 一致 |

**影响**：验收数字与文档不一致（C1 之后新增的向量包/测试没回灌），下轮复核会反复对不上账。
**修法**：README 两份、矩阵 §9/§10/§11 全部按上表刷新；`rhop_vectors` 补一行；时间戳改本轮实测时刻；矩阵 §10 合计按新口径重算。

---

## 7. C2P-07（P3）`compare_codepoint` 每次比较 2 次 UTF-8 编码（O(n log n) 次分配）

`rhop/json_canonical.mbt:122-138`：`compare_codepoint` 每次调用都 `@utf8.encode(a)` / `@utf8.encode(b)`。排序 5000 键时比较次数 ≈ 5000·log2(5000) ≈ 6 万次 ⇒ 12 万次短字符串编码 + 分配。

**证据**：`R5 canonical 5000 keys: 68 ms（另一轮 135 ms）, out len=87780`；同为 87 KB 输出，`sha256` 只需 8–11 ms ⇒ 键排序是主要成本。
**建议**（可选，本轮做低风险版）：先 `Array[(String, Bytes)]` 预编码一次，再 `sort_by` 比较已编码字节。收益 ~2×（5000 键）；正确性由现有 fixture + 键序用例保障。

---

## 8. C2P-08（P3）进程级可变单例（并发语义未声明）

- `rhop/clipboard.mbt`：`last_read_reason_slot`（`Ref[String]`）、`detect_cache`（`Ref[String]`）、`detect_probe`（`Ref[(() -> &ClipboardBackend?)?]`）——被 `read_clipboard` / `get_clipboard_backend` 全局共享。**两个逻辑上下文交替调用时，后一个的 reason 会覆盖前一个**（诊断信息串台），`set_clipboard_backend_probe` 也会影响所有后续调用方（测试间串扰风险）。
- `rhop/digest.mbt`：`sha256_k` / `md5_k` 是顶层 `let Array[...]`（可变数组，未 `pub`，不可从包外改；但仍是全局可变状态）。
- `rhop/clipboard.mbt` 的 `ClipboardFileSync::rounds_done/changes_done` 是**结构体 mut 字段**（实例级，正常）。

**判断**：MoonBit 侧单线程（wasm/js）下不构成数据竞争；但「多 daemon 实例 / 多 fiber 交错」时属于**共享单例语义**，需在文档声明。**建议**：在 `clipboard.mbt` 头部与 `DOC.md` 的 clipboard 节写明「`last_read_reason` / 探测缓存为进程级单例，不适用于多租户线程模型；需要隔离时请各自持有 backend 并直接调用 trait 方法」。

---

## 9. C2P-09（P3）峰值内存 2–3×（String + UTF-8 Bytes 双份）

`canonical_json` 产出 `String`，`canonical_json_utf8` / `to_rhop_bytes` 再 `@utf8.encode` 成 `Bytes` ⇒ 峰值 ≈ `String` 与 `Bytes` 各一份（非 ASCII 时 Bytes 更小）。
**证据**：`R8 1MB payload: envelope checksum 41–81 ms、to_rhop_bytes 87–118 ms（bytes=1000287）、from_rhop_bytes 44–71 ms` ⇒ 吞吐 OK，但峰值约 +1–2 MB。
**建议**：本轮只在文档写「O(n) 时间，峰值 ~2–3× payload」；若日后要稳定大文件流式，再引入直接写 Buffer 的私有路径（不改公开 API）。

---

## 10. 已核实无问题（本轮不必重复劳动）

1. **信封写入会重算 checksum**（C1 PROTO-01 已修）：`to_rhop_bytes` 现取 `compute_checksum()`，`from_dict` 坏 checksum / 缺可选键 / 未知字段四种回写场景已合法（C1 修复报告 §PROTO-01 的 4 条回归用例）。
2. **默认 `hops_seen` 每次新数组**：`R1 e1.len=1 e2.len=0`（默认值不共享）。
3. **大输入线性**：`sha256 1MB 15–27 ms`、`md5 1MB 36–46 ms`、`hmac 1MB 23–33 ms`、`hops_seen 10000 条 to_rhop_bytes 12–15 ms`、`pbkdf2 dk_len=100000 384–592 ms`（线性、无异常）。
4. **信封 1MB payload 往返**：`write 87–118 ms / read 44–71 ms / ok=true`，无截断、无 OOM。
5. **`bytes_from_hex` / `utf8_text` / `canonical_object`** 无状态、无共享引用。
6. **三目标均全绿**（本轮实测）：wasm 600/600、js 797/797、native 600/600，`moon check` 0 error。

---

## 11. 复现方式（一次性副本，不污染真树）

```bash
# 1) 建立审计副本（排除构建产物）
rm -rf /e/tmp/c2audit && mkdir -p /e/tmp/c2audit
cd /e/IDEProjects/AI/rx-mbt && (tar -cf - --exclude=_build --exclude=.git --exclude=.moon-build.lock .) | tar -xf - -C /e/tmp/c2audit

# 2) 探针包（本次新增：test-suit/c2audit/{moon.pkg,probe_test.mbt,probe2_test.mbt,deep_test.mbt,probe3_test.mbt}）
#    探针只打印测量值/复现异常，不改产品代码

# 3) 运行
cd /e/tmp/c2audit
bash scripts/with_moon_lock.sh moon test -p test-suit/c2audit --target js    # R1–R15（js）
bash scripts/with_moon_lock.sh moon test -p test-suit/c2audit                # R20（wasm 计时）
bash scripts/with_moon_lock.sh moon test -p test-suit/c2audit --target native # R20（native 计时）
```

> 探针源码随本报告留档在 `fist-mbt/reports/run-logs/c2-probe-*.txt`（见修复报告附录；本轮同时把原始输出贴入）。
