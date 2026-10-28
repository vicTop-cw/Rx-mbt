# C1 寻虫报告 — 协议 / 摘要 / 文档一致性域（Batch A）

> 任务：rx-mbt（MoonBit 模块 `vicTop-cw/RX-MBT`）C1 寻虫审计 · 协议/摘要/文档一致性域。
> 范围（只读）：`rhop/{core,digest,json_canonical,envelope,signer,integrity}.mbt` + `test-suit/rhop/{core,digest,json_canonical,envelope,signer,integrity}_test.mbt`，并抽查 `README.md` / `DOC.md` / 矩阵 v4 与代码的一致性。
> 基线：vools 参考实现 `E:/IDEProjects/AI/vools/rhop/vools/rhop/{core,envelope,signer,integrity}.py`（逐函数对照）。
> 方式：**只读审计，真树未改任何产品代码/测试，未提交 git**；动态证据在一次性副本 `E:/tmp/c1audit`（tar 拷贝 + throwaway 包 `test-suit/c1audit/protocol_test.mbt`，断言的是**当前行为**，所以「全绿 = 缺陷存在」）。
> 审计人：impl-core　时间：2026-10-28（UTC+8）
> 结论：**P0 × 0 / P1 × 1 / P2 × 1 / P3 × 6**；其中 **PROTO-01 建议阻塞验收**（写出的 .rhop 字节可能是无效的，且与 vools 行为不一致）。

---

## 0. 汇总表

| ID | 严重度 | 位置 | 一句话 | 阻塞验收 |
|---|---|---|---|---|
| **PROTO-01** | **P1** | `rhop/envelope.mbt:175-179`（+ `:192-222`、`:261`、`rhop/integrity.mbt:41-58`）vs `vools envelope.py:79-83` | `to_rhop_bytes` **原样写 `self.checksum`、不重算**（vools 每次重算）→ 「从文件读入但补过默认值 / 被调用方改过 / 含未知字段 / checksum 传入即错」的信封，**回写出的字节 checksum 已失效**，自己都读不回；`verify_bytes=true` 之后写回的字节又 `verify_bytes=false` | **是** |
| PROTO-02 | P2 | `rhop/envelope.mbt:329`（`optional_int` null→default）、`:330`（`value.to_int()` 截断）、`:303`（`optional_string_or`）、`:350`（`side: null`→Requester）、`:368`（`hops_seen: null`→`[]`） | 可选字段为 `null` 时**静默改值**（version:null→1、version:2.7→**2**、side:null→requester、created_at/updated_at:null→""、hops_seen:null→[]）：对象内容与自身 checksum 脱钩；其中 `side:null` 在 vools 是**拒绝**，本实现却接受 | 否（但需与 PROTO-01 一起修） |
| PROTO-03 | P3 | `rhop/envelope.mbt:270-283 / 284-299 / 323-334 / 361-384` vs `envelope.py:99-116`、`:136-150` | 字段类型严格度高于 vools：`task_id:123`、`error:5`、`hops_seen:[1]`、`version:"3"`、`version:true` 本实现 Err，vools 全部接受（dataclass 无运行期类型检查）；矩阵 §2 未记录该差异 | 否 |
| PROTO-04 | P3 | `test-suit/rhop/digest_test.mbt:94-97` | MD5 长输入用例是**自比恒真断言**（两侧同表达式）→ 相当于没有覆盖；SHA-256 同类用例（`:37-40`）有真实向量，不对称 | 否 |
| PROTO-05 | P3 | `test-suit/rhop/core_test.mbt:98` vs `:128`、`rhop/core.mbt:65-66` | 测试标题「合法边恰为 7 条」与断言 `legal_count == 6`、文档列 6 条边不一致（陈旧数字，易诱导后人「修成 7」） | 否 |
| PROTO-06 | P3 | `rhop/signer.mbt:86-101`、`:130-141` vs `vools signer.py:52-74` | 缺 vools 的 `UNKNOWN_NPU` 兜底语义：vools「npu-smi 可执行但无 serial 行 ⇒ `UNKNOWN_NPU` 仍可签」；本实现只有 provider→`None`⇒不签，`:87` 文案称「真实语义」但漏了这一分支；矩阵 §2 signer 9/9 ✅ 未标注 | 否 |
| PROTO-07 | P3 | `rhop/envelope.mbt:196`（`preserve_number_repr=true`）+ `:209-218` | 接受**非规范数字字面量**（payload 写 `1.50` / `1e2`）并按原文重算 checksum；vools `json.loads` 规范化后重算 ⇒ 对同一文件 vools 判 `checksum mismatch`（已实测）。方向是「更宽松且静默」 | 否 |
| PROTO-08 | P3 | `test-suit/rhop/json_canonical_test.mbt:84-92` vs `rhop/json_canonical.mbt:122-138` | 键序用例 `B < a < 中 < 😀` 在 UTF-16 序下同样成立，**无法判别**实现用的是码点还是 UTF-16；实现当前正确（UTF-8 字节比较），但缺回归网 | 否 |

> 判绿口径提醒：现有 18 个 `envelope_test` 全绿**不能证明 PROTO-01 不存在**——它们只覆盖「构造/往返后未被改动」的路径（`envelope_test.mbt:98`、`:281`、`:380` 均未断言回写字节的有效性）。

---

## 1. PROTO-01（P1）`to_rhop_bytes` 不重算 checksum：接受过的信封回写即失效

**位置**：`rhop/envelope.mbt:175-179`（`to_rhop_bytes`，`fields["checksum"] = Json::string(self.checksum)`）；校验侧 `:192-222`；`checksum` 原样保留于 `:261`；下游 `rhop/integrity.mbt:41-58`。对照 `vools envelope.py:63-83`（每次 `to_rhop_bytes` 用当前字段重算 `checksum` 后写入）。

**现象**：checksum 只在**校验时**按「文件原始键集」重算（`:209-218`），而对象构造时会补默认值/接受调用方传入的任意 checksum（`from_dict` 语义 = vools：不校验、仅保留，`:229-240`、`:261`）。一旦「对象内容 ≠ checksum 覆盖的内容」，`to_rhop_bytes` 会把这个已经失效的 checksum 原样写出去，产出的 `.rhop` 文件**通不过任何一侧的 `from_rhop_bytes`**。四个触发面（全部有动态证据）：

| 面 | 触发方式 | 动态证据（`E:/tmp/c1audit`） |
|---|---|---|
| a | `from_dict` 传入错误 checksum（vools 语义如此，`envelope_test.mbt:364` 只测了「缺 checksum 自动重算」） | `PROTO-01a`：写出字节含 `"checksum": "sha256:bad"`，`from_rhop_bytes(raw)` → **Err**，而 `env.compute_checksum() != "sha256:bad"` |
| b | 文件**缺可选键**（`side/version/created_at/updated_at/hops_seen/result/error/signature` 任缺）：校验按「缺键」的 body 通过，随后补默认值 → 对象与 checksum 脱钩 | `PROTO-01b`：接受且 `version==1`、`hops_seen==[]`；`to_rhop_bytes` 回读 **Err** |
| c | 调用方原地改 `hops_seen`（`Envelope` 持有 `Array` 引用）或改 `payload` 对象 | 同 (a) 机制（`:175-179` 只读 `self.checksum`） |
| d | 文件含**未知顶层字段**：校验时参与（`:209-218`、`envelope_test.mbt:380`），`assemble` 却丢弃 → 回写 checksum 仍按旧键集 | 同 (b) 机制；`envelope_test.mbt:380` 只测「读入通过」，未测回写 |

**vools 对照（实测）**：

```text
stale: env.checksum= sha256:bad | to_rhop_bytes.checksum= sha256:d9686bef98c2e | differs= True
```

即 vools 对同一对象会**重算**并写出合法字节（vools 侧 `checksum_match` 对这种「旧 checksum」对象仍返回 False，与本实现一致——**不要改 `checksum_match`**）。

**后果**：① 跨实现字节不等，直接违背 `envelope.mbt:7`、`:173-174` 与矩阵 `:90` 的「与 Python `to_rhop_bytes()` 逐字节一致」承诺；② 本实现 self-round-trip 失败（读进来的文件写回去读不回）；③ `IntegrityChecker.verify_bytes`（`integrity.mbt:41-46`）对同一批字节先 `true` 后 `false`，SFTP/Git 传输层「校验通过 → 落盘回写 → 对方校验失败」是可复现的假通过。**动态证据 `PROTO-01c`**：version:null 文件 `verify_bytes=true`，同一对象 `checksum_match=false`。

**复现**：`E:/tmp/c1audit/test-suit/c1audit/protocol_test.mbt` 中 `PROTO-01a / 01b / 01c`（20/20 全绿即现状确认，见附录 A）。

**建议修法（1 处改动 + 文案）**：

```moonbit
// rhop/envelope.mbt:175-179
pub fn Envelope::to_rhop_bytes(self : Envelope) -> Bytes {
  let fields = self.body_fields()
  // 与 vools envelope.py:79-83 一致：序列化时按当前字段重算 checksum。
  // 这样「读入时补过默认值 / 调用方改过 / 含未知字段被丢弃」的信封也能写出有效字节。
  fields["checksum"] = Json::string(self.compute_checksum())
  canonical_json_utf8(Json::object(fields))
}
```

同时把 `:171-174` 的 docstring 改成：「与 vools 一样，序列化时按当前字段重算 checksum；**构造后未被改动**且语料不含浮点时与 Python 输出逐字节一致」；矩阵 `:90` 同步加限定词。

**测试（红→绿，加到 `test-suit/rhop/envelope_test.mbt`）**：① `from_dict` + `checksum="sha256:bad"` → 回写 → `from_rhop_bytes` 必须 Ok 且 `Ok.checksum == env.compute_checksum()`；② 缺可选键 body → 回写 → 再读 Ok；③ `hops_seen` 原地 push 后回写 → 再读 Ok；④ 未知字段 body → 回写 → 再读 Ok（未知字段被丢弃但字节有效）。

---

## 2. PROTO-02（P2）可选字段 null / 浮点被静默改值，`side:null` 该拒未拒

**位置**：`rhop/envelope.mbt:323-334`（`optional_int`：`:329` `Some(Null) => default`、`:330` `value.to_int()`）、`:301-311`（`optional_string_or`：`:303` `None => default`）、`:348-359`（`parse_side`：`:350` `Some(Null) => Requester`，`:346` 注释却声称「与 Python `Side(data.get("side","requester"))` 一致」）、`:361-384`（`parse_hops_seen`：`:368` `Some(Null) => []`）。

**现象与 vools 对照（全部实测，见附录 B）**：

| 文件字段 | vools `from_rhop_bytes` | 本实现 | 差异性质 |
|---|---|---|---|
| `version: null` | **接受**（`version=None` 保留，`:105`） | **接受**，静默变 `1` | 静默改值；对象 checksum 与内容脱钩（动态 `PROTO-02a`） |
| `side: null` | **拒绝** `ValueError: 字段值非法: None is not a valid Side`（`:104` + `:113-117`） | **接受**，变 `requester`（动态 `PROTO-02b`） | **该拒未拒** + 注释 `:346` 与事实不符 |
| `version: 2.7` | 接受，保留 `2.7` | 接受，`to_int` 截断为 **2**（动态 `PROTO-02c`） | 静默数据变更（非四舍五入） |
| `created_at/updated_at: null` | 接受，保留 `None` | 接受，变 `""` | 静默改值 |
| `hops_seen: null` | 接受，保留 `None` | 接受，变 `[]` | 静默改值 |

**后果**：与 PROTO-01 叠加时，「已通过 checksum 校验」的信封内容被改、回写字节无效；即便单独看，`version: 2.7 → 2` 是**无提示的数据变更**，排障时极难发现（文件里写 2.7、内存里 2、回写后 2），且 `calculate_checksum` 与文件 checksum 不一致却无任何告警。

**复现**：附录 A 的 `PROTO-02a/b/c`（断言当前行为，绿=缺陷在）。

**建议修法（与 PROTO-01 同批；二选一，推荐 A）**：

- **A. 显式拒绝无法无损表示的值**（推荐，符合「宁可红不要静默错」）：

  ```moonbit
  // rhop/envelope.mbt:348-359 parse_side：去掉 Some(Null) 分支，让显式 null 走「字段值非法」
  match fields.get("side") {
    None => Requester                     // 仅「缺键」给默认，与 vools 一致
    Some(String(raw)) => ...              // 原有解析
    Some(_) => raise EnvelopeError("envelope 字段值非法: side 必须是字符串（vools 对 null 报 None is not a valid Side）")
  }
  ```

  同理：`optional_int` 的 `Some(Null)` 不再回落 default，而是
  `raise EnvelopeError("envelope 字段值非法: version 必须是整数")`；`Some(Number(value, ..))` 增加整数性检查（`value == value.floor()` 之外还要防 2.7），否则报同一条错误；`optional_string_or`（created_at/updated_at）与 `parse_hops_seen` 的 `Some(Null)` 同样报错，或按 B 记录为有意取舍。
- **B. 保持宽松但如实记录**：`side:null` 仍然必须改成拒绝（对齐 vools，成本最低、风险最小）；其余 null/浮点截断写入 `envelope.mbt` docstring + 矩阵 §7 新行「null/浮点可选字段会被规范化（version 截断为整数）」。

**测试**：表驱动 5 条（version:null / side:null / created_at:null / hops_seen:null / version:2.7），按选定方案断言 `Err` 且 message 含 `字段值非法`（A）或断言规范化结果并在文档标注（B）。

---

## 3. PROTO-03（P3）字段类型严格度高于 vools（拒绝 vools 能读的文件）

**位置**：`rhop/envelope.mbt:270-283`（`task_id` 必须字符串）、`:284-299`（`error` 必须字符串或 null）、`:323-334`（`version` 必须数字）、`:361-384`（`hops_seen` 元素必须字符串）。对照 `vools envelope.py:99-116`（`data["task_id"]` / `data.get("error")` / `data.get("hops_seen", [])` 无类型检查）与 `:136-150`（`from_dict` 同）。

**现象（vools 实测接受）**：`task_id: 123`、`error: 5`、`hops_seen: [1]`、`version: "3"`、`version: true`、`version: 2.7` 全部通过 vools（dataclass 保留原值，checksum 按原值计算）；本实现前五个 `Err("… 必须是字符串/数字")`，第六个静默截断（PROTO-02）。

**影响**：读 vools/第三方「宽松写入」的信封时被拒；反向（本实现写 → vools 读）不受影响。属**可接受的更严格**，但矩阵 §2 把 envelope 记成 17/17 ✅ 而未标注类型严格度差异，后续会误判「完全对齐」。

**修法**：不改行为（严格更安全，且错误信息已可诊断）；在矩阵 §7 增加一行「字段类型严格度」：`task_id/error/hops_seen/version` 本实现按 JSON 类型严格校验，vools 依赖 dataclass 不做运行期检查；并在 `envelope.mbt:246-268` 的 docstring 写明「比 vools 更严格」。补 3 条固定用例（`task_id:123`、`error:5`、`hops_seen:[1]` 断言 Err 文案），防止日后无声放宽。

---

## 4. PROTO-04（P3）MD5 长输入用例是恒真断言

**位置**：`test-suit/rhop/digest_test.mbt:94-97`：

```moonbit
  assert_eq(
    @rp.md5_hex_of_utf8("a".repeat(1000)),
    @rp.md5_hex_of_utf8("a".repeat(1000)),
  )
```

两侧同表达式，**永远为真**，等于没有覆盖「MD5 跨 64 字节分组」的路径；同文件 `:37-40` 的 SHA-256 长输入用例有真实向量（`41edece4…`），两者不对称。

**复现/修复值（本次用 hashlib 实测，且动态测试 `PROTO-04` 在当前实现上为绿，说明实现本身正确）**：

```text
md5("a"*1000) = cabe45dcc9ae5b66ba86600cca6b8ba8
md5("a")      = 0cc175b9c0f1b6a831c399e269772661
```

**修法**：把第二行换成真实向量 `"cabe45dcc9ae5b66ba86600cca6b8ba8"`，保留 `md5(...).length() == 16` 的断言；可选：把该向量并入 `test-suit/rhop_js/fixtures/vools_vectors.json`（由 qa 负责，跨实现硬证据）。

---

## 5. PROTO-05（P3）测试标题「7 条」与断言「6 条」矛盾

**位置**：`test-suit/rhop/core_test.mbt:98` 标题「core: 6×6 全流转矩阵（合法边恰为 7 条）」；`:128` `assert_eq(legal_count, 6)`；`:130` `assert_eq(36 - legal_count, 30)`；`rhop/core.mbt:65-66` 文档列 6 条边（PENDING→{CLAIMED,CANCELLED}、CLAIMED→{RUNNING,CANCELLED}、RUNNING→{DONE,FAILED}）。

**修法**：标题改「合法边恰为 6 条」。纯文案，1 行。

---

## 6. PROTO-06（P3）NPUSigner 缺 vools 的 `UNKNOWN_NPU` 兜底语义

**位置**：`rhop/signer.mbt:86-101`（`serial_provider` 注入，默认 `fn() { None }`）、`:130-141`（`None ⇒ sign 返回 None / verify false`）；对照 `vools signer.py:52-74`。

**现象**：vools 的分支是——`npu-smi -q` 可执行但输出里没有 `serial`/`sn` 行 → `return "UNKNOWN_NPU"`（**仍可签名**，`<marker>:UNKNOWN_NPU:<md5>`）；只有 `npu-smi` 不存在/超时/异常 → `None`（不可签）。本实现把「不可签」抽象成 provider 返回 `None`，`:87` 文案称「本机无 npu-smi 的真实语义」——只覆盖了后一半分支；在真 NPU 机上（工具在、序列号解析不到）vools 能签、本实现默认签不了（需调用方注入 provider）。矩阵 §2 signer 9/9 ✅ 未标注该差异。

**修法（二选一）**：
- (a) 只补文档/矩阵：`signer.mbt:86-101` 文案改为「provider 返回 `None` ⇒ 不可签（对应 vools 中 npu-smi 不可用）；vools 的 `UNKNOWN_NPU` 兜底由注入的 provider 自行实现」；矩阵 §7 增一行。
- (b) 真对齐：`NPUSigner` 增 `fallback_serial? : String? = None`，`serial_provider` 返回 `None` 时用 fallback（默认 `None` 保持现状），并加一条 `with_serial_provider(fn() { None }).with_fallback_serial("UNKNOWN_NPU")` 的签名格式测试。

---

## 7. PROTO-07（P3）接受非规范数字字面量（vools 拒绝）

**位置**：`rhop/envelope.mbt:196`（`@json.parse(text, preserve_number_repr=true)`）+ `:209-218`（重算用解析出的原始 `repr`）。

**现象**：文件 payload 里写 `1.50` / `1e2` / `-0.0` 时，本实现保留字面量重算 → 自洽通过；vools 先 `json.loads`（规范化成 `1.5` / `100.0`）再 `dumps` → 期望 checksum 不同 → `checksum mismatch`。**实测**（附录 B 第三段）：同一字节串 `vools: REJECTED -> ValueError checksum mismatch`，本实现 `Ok`（动态 `PROTO-07` 绿）。方向是「更宽松且静默」，会掩盖非规范生成器；与矩阵 §7 #1（浮点**打印**形态不同）不是同一条，属新缺口。

**修法**：文档项——矩阵 §7 #1 补一句「非规范数字字面量（`1.50`、`1e2`）本实现接受、vools 拒绝」；若要对齐，需在 checksum 重算前把 `repr` 规范化（牵涉 `canonical_number` 整套浮点限制，成本高，**不建议本轮做**）；可加一条「接受即现状」的用例固定行为，避免日后无意识收紧。

---

## 8. PROTO-08（P3）键序测试缺判别性用例（实现正确，缺回归网）

**位置**：`test-suit/rhop/json_canonical_test.mbt:84-92`（键序用例 `{"B":1,"a":2,"中":3,"😀":4}`）vs `rhop/json_canonical.mbt:122-138`（`compare_codepoint` 按 UTF-8 字节比较）。

**现象**：`B < a < 中 < 😀` 在 UTF-16 码元序下**同样成立**（`😀` 的代理 `D83D` > `4E2D`），所以这条用例无法判别实现用的是「码点」还是「UTF-16 码元」；若日后有人把 `compare_codepoint` 简化成 `String::compare`，所有含补充平面字符的 payload 的 checksum 会**静默**与 Python 分歧，现有测试不会红。实现当前正确（动态 `PROTO-08` 绿）。

**修法**：加判别用例——键 `"\u{FFFD}"` 与 `"\u{1F600}"`：码点序 `FFFD < 1F600`（正确输出 FFFD 在前），UTF-16 序 `D83D < FFFD`（😀 在前）。

```moonbit
test "canonical: 补充平面字符键按码点排序（U+FFFD < U+1F600，判别 UTF-16 实现）" {
  let m : Map[String, Json] = Map([])
  m["\u{1F600}"] = Json::number(2.0)
  m["\u{FFFD}"] = Json::number(1.0)
  assert_eq(@rp.canonical_json(Json::object(m)), "{\"\u{FFFD}\": 1, \"\u{1F600}\": 2}")
}
```

---

## 9. 已核实无问题（C1-修复阶段不必重复劳动）

1. **core**：6 条合法边、3 个终态、`to_string` 小写字面量、`parse` 接受/拒绝集合与 `vools core.py` 逐条一致（`core.mbt:12-145`，`core_test.mbt:98-131` 的 36 组合矩阵通过）。
2. **checksum 参与字段完整**：`body_fields` 12 键（`envelope.mbt:140-168`）与 vools `_compute_checksum` 12 键（`envelope.py:44-61`）**逐一对应**，无遗漏无多余；`v=1` 固定、不含 `checksum` 自引用，均与 vools 同。
3. **`to_dict` / `from_dict`**：`to_dict` 不含 `v`、含 `checksum`（`envelope.mbt:388-410` vs `envelope.py:118-134`）；`from_dict` 缺 `checksum` 自动重算（`:229-240`、`envelope_test.mbt:364`）——一致。
4. **canonical JSON 转义**：`\n\t\r\b\f` 短形式、其余 `< 0x20` 用 `\u00XX` **小写**十六进制、非 BMP 输出 `\ud83d\ude80` 代理对、`ensure_ascii=True/False` 双口径分别用于 signer/envelope——与 CPython 同形，且有 fixture 钉死（`json_canonical.mbt:30-120`，`json_canonical_test.mbt:300-314`，`signer_test.mbt:159-187`）。
5. **digest**：SHA-256（空串/`abc`/1000×`a`/中文/百万级长输入）、MD5（空串/`abc`/中文）、HMAC-SHA256（RFC 4231 #1/#2）、PBKDF2-HMAC-SHA256（`120fb6cf…`）向量全部通过；HMAC 超块长 key 先哈希；PBKDF2 `iterations < 1 ⇒ ""` 已在 `digest.mbt` 文档写明且**无生产调用方**（`crypto.mbt:291/297` 走 `node:crypto` 的 `pbkdf2Sync(…,200000,…)`）——无静默误用风险。
6. **integrity**：`verify` / `verify_bytes` 忽略 `env` 与 vools 一致（`integrity.py:14-33`，矩阵 §7 #10 已记录）；`checksum_match` 的往返比对与 `integrity.py:36-42` 同构。
7. **tamper / 坏 JSON / 非法 UTF-8 / 顶层数组 / 缺必填字段 / 非法 status·side 字面量**：错误文案与 `Result` 化均符合契约 §2.2，`envelope_test.mbt:159-222` 覆盖。
8. **signer**：`FileHashSigner` 的 preimage（`sort_keys=True` + `ensure_ascii=True`）与签名格式 `sha256:<hex>` 与 vools 一致（`signer.py:26-39`）；`unicode_result` fixture（`sha256:008d35d8…`）已钉死双口径差异。

---

## 10. 不重复报（矩阵 §7 已覆盖）

- #1 canonical 浮点打印形态（`1.0` vs `1`、指数形态、NaN/Infinity）：已知限制，`json_canonical.mbt:18-27` 已写明（PROTO-07 是其**新方向**，不与 #1 重复）。
- #3 错误以 `Result[_, String]` 表达、#9 未知字段参与校验、#10 `verify` 忽略 `env`：均已登记。
- #2 signer `ensure_ascii` 双口径：已用 fixture 硬对齐，**测试确实能区分**（`signer_test.mbt:159-187` 的 unicode 签名断言与 `envelope_test.mbt:440-470` 的 `ensure_ascii=False` 字节断言互为对照）。

---

## 11. 未验证观察（不计入缺陷表，供 C1-修复阶段决定是否深挖）

1. **递归深度**：`write_canonical_json`（`json_canonical.mbt:141-188`）与 `@json.parse` 均无深度上限；Python 侧 `RecursionError` 可被 `except` 捕获，本项目深层嵌套（万级）可能**进程崩溃**而非 `Err`。建议加一条 1 万层 payload 的健壮性测试确认落点，再决定是否限深。
2. **超大 `Double → Int32`**：`optional_int`（`envelope.mbt:330`）对 `1e300` 之类 `to_int` 的饱和/回绕行为未验证（`version` 实际不会出现，P4）。
3. **孤立代理项**：`"\ud800"` 在 Python `json.dumps` 与本项目 `@json.parse` 中的落点均未实测；属恶意输入域（P4）。

---

## 附录 A：动态证据（一次性副本，真树未改）

```bash
# ① 拷贝真树（另一审计人已在 E:/tmp/c1audit 预留 test-suit/c1audit 包）
cd /e/tmp/c1audit && cp -r /e/IDEProjects/AI/rx-mbt/rhop/. rhop/ && cp -r /e/IDEProjects/AI/rx-mbt/test-suit/. test-suit/
# ② 新增 throwaway 用例：test-suit/c1audit/protocol_test.mbt（10 例，断言「当前行为」）
# ③ 跑（Windows 必须先修 PATH，否则选到 .desktop-bin/node.cmd）
export PATH="/c/Program Files/nodejs:/c/Users/victo/.moon/bin:/usr/bin:/bin"
moon test -p test-suit/c1audit --target js    # Total tests: 20, passed: 20, failed: 0
moon test -p test-suit/c1audit                # Total tests: 10, passed: 10, failed: 0（wasm；对方文件 js-only 被排除）
```

用例清单（全部绿 = 缺陷现状成立）：`PROTO-01a`（旧 checksum 原样写出 + 回读失败）、`PROTO-01b`（缺可选键被接受但回写不可读）、`PROTO-01c`（`verify_bytes=true` 而 `checksum_match=false`）、`PROTO-02a`（version:null→1 且 checksum 脱钩）、`PROTO-02b`（side:null→requester）、`PROTO-02c`（version:2.7→2）、`PROTO-03a`（task_id:123→Err）、`PROTO-07`（`1.50` 被接受）、`PROTO-04`（真实 MD5 向量当前实现正确）、`PROTO-08`（FFFD<😀 当前实现正确）。

## 附录 B：vools 实测输出（`cd E:/IDEProjects/AI/vools/rhop && python -c "…"`）

```text
version:null -> ACCEPTED                 # version=None 保留
side:null    -> REJECTED: ValueError envelope 字段值非法: None is not a valid Side
version:2.7  -> ACCEPTED                 # 2.7 保留
nulls        -> ACCEPTED                 # created_at/updated_at/hops_seen 保留 None
version:"3" / task_id:123 / error:5 / hops:[1] -> ACCEPTED（dataclass 无类型检查）
stale: env.checksum= sha256:bad | to_rhop_bytes.checksum= sha256:d9686bef98c2e | differs= True
# PROTO-07：checksum 按字面量 1.50 计算的文件
vools: REJECTED -> ValueError checksum mismatch: envelope may be corrupted
```

## 附录 C：C1-修复的动手顺序（建议）

1. **PROTO-01**（1 行 + docstring + 4 条测试）——唯一 P1，动 `to_rhop_bytes` 后所有「回写失效」类现象一起消失。
2. **PROTO-02**（`side:null` 拒绝必做；version 截断/null 按方案 A 拒绝或 B 记录；5 条表驱动测试）。
3. **PROTO-03/06/07**（矩阵 §7 各加一行 + docstring 措辞，零代码或近零代码）。
4. **PROTO-04/05/08**（三条测试修正，零产品代码）。
5. 收尾：`moon fmt`、三目标 `moon check` / `moon test -p test-suit/rhop`（js/wasm），并按契约把新增测试计入测试数统计（文档中的 587/765 等数字随之刷新）。
