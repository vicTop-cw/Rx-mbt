# C1 审计问题修复报告（协议/摘要域，PROTO-01～08）

- 任务：C1 寻虫修复（协议/摘要域，对应 `fist-mbt/reports/2026-10-28-c1-bugfind-protocol.md`）
- 执行体：impl-core
- 日期：2026-10-28
- 范围：只动 `rhop/envelope.mbt`、`rhop/signer.mbt` 与 `test-suit/rhop/{core,digest,envelope,json_canonical,signer}_test.mbt`；新增 `test-suit/rhop_vectors/`（互操作产物生产者）；`fist-mbt/docs/2026-10-27-rhop-vools-parity-matrix.md` 仅追加 §7 两行差异登记
- 未动：`rhop/moon.pkg`、`moon.mod`、`README.md`、`DOC.md`、其它人的产品文件；**未执行 git commit**；所有 `moon` 命令均经 `scripts/with_moon_lock.sh`
- 结论：**PROTO-01～08 全部处理完毕**——6 条已修代码/测试（01/02/04/05/06/08），2 条（03/07）经判定为「有意保留的严格度差异」，已登记矩阵 §7；无遗留阻塞项

---

## 1. 摘要

| Issue | 修复前级别 | 状态 | 一句话修法 |
|---|---|---|---|
| PROTO-01 `to_rhop_bytes` 不重算 checksum | **P1** | **已修** | 序列化时按当前字段重算 checksum（照抄 vools `envelope.py:79-83`），回写字节自身可读回 |
| PROTO-02 可选字段 null / 浮点静默改值 | P2 | **已修** | `version:null` / `version:2.7` / `side:null` / `created_at:null` / `updated_at:null` / `hops_seen:null` 一律 `Err`，不再静默改写 |
| PROTO-03 字段类型严格度高于 vools | P3 | **有意保留 + 登记** | 显式失败优于静默接受；矩阵 §7 第 17 行登记与 vools 的差异 |
| PROTO-04 MD5 长输入自比恒真断言 | P3 | **已修** | 改为真实向量 `md5_hex_of_utf8("a"×1000) = cabe45dc…` |
| PROTO-05 core 测试标题「7 条」与断言 6 条不一致 | P3 | **已修** | 标题改「合法边恰为 6 条」，与 `core.py:_TRANSITIONS` 一致 |
| PROTO-06 NPUSigner 缺 `UNKNOWN_NPU` 兜底 | P3 | **已修** | provider 返回 `None` ⇒ 用 `UNKNOWN_NPU` 签名（`sign` 恒不为 `None`），文档同步 |
| PROTO-07 接受非规范数字字面量 | P3 | **有意保留 + 登记** | `preserve_number_repr` 保留原文以避免二次序列化改值；矩阵 §7 第 18 行登记 |
| PROTO-08 canonical 键序用例无判别性 | P3 | **已补测试** | 新增 `U+FFFD < U+1F600` 用例（UTF-16 码元序会排反），另把 fixture escapes 的 10 条 `contains` 收紧为整串 `assert_eq` |

---

## 2. 逐条修法

### PROTO-01（P1）`to_rhop_bytes` 不重算 checksum → 回写即失效

- 位置：`rhop/envelope.mbt:182-194`（`Envelope::to_rhop_bytes`）
- 修复前：`fields["checksum"] = Json::string(self.checksum)` —— 原样写构造时/文件里的 checksum。
- 根因：vools `envelope.py:79-83` 的 `to_rhop_bytes()` 每次都 `calculate_checksum()` 后 dump；本实现把「构造时算一次」当成了「永远有效」，于是四类信封回写即坏：① `from_dict` 传入错 checksum；② 文件缺可选键（校验按缺键 body 通过、随后补默认值）；③ 调用方原地改 `payload/hops_seen`；④ 含未知字段（校验参与、回写丢弃）。
- 修法：`fields["checksum"] = Json::string(self.compute_checksum())`；`self.checksum` 仍保留构造值（`from_dict` 不校验，vools 语义），只有写出/校验时重算。文档注释同步写清「与 vools 逐字节一致的前提是对象未被改动且语料不含浮点」。
- 测试（`test-suit/rhop/envelope_test.mbt`）：
  - `:540` `envelope(PROTO-01): from_dict 带错 checksum → 写出时重算、自身可读回`
  - `:568` `envelope(PROTO-01): 缺可选键的文件 → 回写补默认值并重算、可读回`
  - `:594` `envelope(PROTO-01): 原地改 hops_seen / payload 后 to_rhop_bytes 重算`
  - `:622` `envelope(PROTO-01): 含未知字段 → 回写丢弃未知字段并重算、可读回`
- 与 vools 的一致性：读入后 checksum 仍为文件值（`verify_bytes` 语义不变：`checksum_match(env)` 对「文件 checksum 已旧」的对象仍返回 false，与 vools 相同）；变化只在**写出**：vools 会重算，本实现现在也重算。

### PROTO-02（P2）可选字段 null / 浮点被静默改值，`side:null` 该拒未拒

- 位置：`rhop/envelope.mbt:311`（`optional_string_or`）、`:343`（`optional_int`）、`:387`（`parse_side`）、`:405`（`parse_hops_seen`）
- 修复前：`None | Some(Null) => default`；`optional_int` 直接 `value.to_int()` 截断。
- 根因：MoonBit 侧用 `String`/`Int32`/`Array[String]` 表示 vools 的 `Optional[...]`，`null` 与缺失被当成同一语义 → 静默改值；`side:null` 在 vools 明确 `ValueError: None is not a valid Side`。
- 修法（**缺键才默认，显式 null 一律拒绝**）：
  - `optional_string_or`：`Some(Null)` ⇒ `envelope 字段值非法: <key> 不能为 null`；
  - `optional_int`：`Some(Null)` ⇒ 拒绝；`Number` 先排除 `NaN/Inf/|v|>1e18`（wasm 上 `to_int()` 会 trap），再校验 `to_int().to_double() == v`，浮点/非整数（`2.7`）⇒ `必须是整数` 且错误文本带上原文；
  - `parse_side`：`Some(Null)` ⇒ `None is not a valid Side`（与 vools 原文一致）；
  - `parse_hops_seen`：`Some(Null)` ⇒ 拒绝。
- 测试：`test-suit/rhop/envelope_test.mbt:640` 六例（side/version null、version 2.7、created_at/updated_at null、hops_seen null）逐条断言 `Err` 且错误文本含对应片段。

### PROTO-03（P3，有意保留）字段类型严格度高于 vools

- 位置：`rhop/envelope.mbt:270-283 / 284-299 / 323-334 / 361-384` 与 `envelope.py:99-116`、`:136-150`
- 现象：`task_id:123`、`error:5`、`hops_seen:[1]`、`version:"3"` 本实现 `Err`；vools dataclass 无运行期类型检查，全部接受。
- 裁定：**保留**。显式 `Err`（可诊断文本）优于静默接受后类型混淆；方向安全（拒绝而非改值）。差异已登记矩阵 §7 第 17 行，注明「vools 能读的畸形文件本实现可能拒绝」。

### PROTO-04（P3）MD5 长输入用例是自比恒真断言

- 位置：`test-suit/rhop/digest_test.mbt:87-99`
- 修复前：两侧同一表达式 `md5_hex_of_utf8("a".repeat(1000))`，断言恒真。
- 修法：右侧改真实向量 `"cabe45dcc9ae5b66ba86600cca6b8ba8"`（与 SHA-256 同类用例口径一致）。
- 测试：`digest: MD5 输出 16 字节、中文 UTF-8、长输入`（`:87`）。

### PROTO-05（P3）core 测试标题陈旧数字

- 位置：`test-suit/rhop/core_test.mbt:98`
- 修法：标题「合法边恰为 7 条」→「合法边恰为 6 条」；断言 `legal_count == 6` 与 `rhop/core.mbt:65-66`、`core.py:_TRANSITIONS` 逐条一致，未改产品代码。

### PROTO-06（P3）NPUSigner 缺 `UNKNOWN_NPU` 兜底

- 位置：`rhop/signer.mbt:104`（新增 `pub const NPU_UNKNOWN_SERIAL`）、`:149-155`（新增 `resolved_serial`）、`:157-166`（`sign`）
- 修复前：provider 返回 `None` ⇒ `sign` 返回 `None`（把「工具不存在」与「无序列号」混为一谈，且签名恒失败）。
- 修法：按 vools `_get_npu_serial` 语义，provider 返回 `None` ⇒ `UNKNOWN_NPU` 兜底；`sign` 恒产出 `"<marker>:<serial>:<md5>"`。文档同步说明：本库不 spawn 子进程、无法区分「npu-smi 不存在」，故统一按可签名处理（「工具不存在 ⇒ None」分支无法表达，已在文档与矩阵 §7 差异登记中说明）。
- 测试（`test-suit/rhop/signer_test.mbt`）：`:141` 默认 provider → `UNKNOWN_NPU` 兜底；`:170` 注入 provider → 格式；`:199` marker 定制 + provider None 兜底。

### PROTO-07（P3，有意保留）接受非规范数字字面量

- 位置：`rhop/envelope.mbt:196`（`preserve_number_repr=true`）+ `:209-218`
- 现象：payload 写 `1.50` / `1e2` 时本实现按原文重算 checksum；vools `json.loads` 规范化（`1.5` / `100.0`）后重算 ⇒ 同一文件 vools 判 `checksum mismatch`（已实测）。
- 裁定：**保留**。保留原文可避免二次序列化改值，方向更宽松但静默；规范语料（`python json.dumps` 产出）不受影响。已登记矩阵 §7 第 18 行。

### PROTO-08（P3）canonical 键序/转义用例无判别性

- 位置：`rhop/json_canonical.mbt:122-138`（实现正确：按 UTF-8 字节比较 = 码点序）与 `test-suit/rhop/json_canonical_test.mbt`
- 修法（仅测试）：
  - 新增 `:96` `canonical: 补充平面字符键按码点序（判别 UTF-16 序实现）`：键 `U+FFFD` 与 `U+1F600`，UTF-16 码元序（`D83D… < FFFD`）会排反，能真正判别实现；
  - `:256` fixture `escapes` 用例：原 10 条 `contains` 片段断言（字段名拼错/多字段/键序异常都抓不到）→ 整串 `assert_eq(actual, input_text)`，input_text 与 fixture 期望逐字节相同。
- 测试：上述两条 + 原有 20 条 canonical 用例全绿。

---

## 3. 五分节互操作产物生产者（本轮最有价值产出）

### 3.1 背景

`scripts/verify_interop.py --strict` 对扁平产物（只有 `{"envelope_json": ...}`）会把 `canonical_json / digest / envelope / crypto.encrypt_secret / signer` 5 个分节记 SKIP 并判失败。本项目此前没有「五分节」形状的 MoonBit 侧产物，导致 `--strict` 无法真绿。

### 3.2 新增

`test-suit/rhop_vectors/`（js-only，3 文件）：

| 文件 | 作用 |
|---|---|
| `moon.pkg` | 依赖 `vicTop-cw/RX-MBT/rhop` + `moonbitlang/core/json`，测试用 |
| `producer_test.mbt`（529 行） | 用**真实 rhop API** 对 qa fixture 的**输入**逐条求值，产出五分节 JSON 写盘；期望值一律不读（防「拿期望冒充实现」） |
| `pkg.generated.mbti` | 生成接口（空，符合预期） |

产物：`fist-mbt/reports/moonbit_vectors_full.json`，形状遵循 fixture 的 `moonbit_output_schema`：

- `cases.canonical_json[]`（7 条）
- `cases.digest.{sha256,md5,hmac_sha256,pbkdf2_hmac_sha256}[]`（13 条）
- `cases.envelope[]`（2 条，含 `checksum` / `to_rhop_bytes_utf8` / `checksum_match`）
- `cases.crypto.{encrypt_json,encrypt_secret}[]`（3 + 2 条）
- `cases.signer.file_hash[]`（3 条）

生成命令（在仓库根、js 目标）：

```bash
export PATH="/c/Program Files/nodejs:/c/Users/victo/.moon/bin:/usr/bin:/bin"
bash scripts/with_moon_lock.sh moon test -p test-suit/rhop_vectors --target js
```

生产者自检输出（本轮实跑）：

```
[vectors] 写出 .../fist-mbt/reports/moonbit_vectors_full.json：canonical=7 digest=13 envelope=2 crypto=3+2 signer=3
[vectors] 读回校验通过：canonical=7/7 digest=13/13 envelope=2/2 crypto=3+2 signer=3
```

### 3.3 vools 反向复核（硬证据）

```bash
# 在 WSL 的 python3（3.10+）下执行，仓库挂在 /mnt/e
wsl.exe -e bash -lc 'cd /mnt/e/IDEProjects/AI/rx-mbt && python3 scripts/verify_interop.py fist-mbt/reports/moonbit_vectors_full.json --strict'
```

```text
  PASS=46  FAIL=0  SKIP=0  (total 46)

 RESULT: PASS -- 所有已产出项经 vools 复核一致
```

> 该结果**由 lead 独立复跑复核通过**（lead 用同一命令得到 `PASS=46 FAIL=0 SKIP=0 rc=0`），本报告引用的数字经双人验证。

---

## 4. 验证汇总（本轮真实输出）

| 命令（均经 `with_moon_lock.sh`） | 结果 |
|---|---|
| `moon test -p test-suit/rhop`（wasm 默认） | `Total tests: 200, passed: 200, failed: 0.` |
| `moon test -p test-suit/rhop --target js` | `Total tests: 392, passed: 392, failed: 0.` |
| `moon check`（wasm） | `Finished. moon: ran 14 tasks, now up to date (255 warnings, 0 errors)` |
| `moon check --target js` | `Finished. moon: ran 21 tasks, now up to date (235 warnings, 0 errors)` |
| `moon check --target native` | `Finished. moon: ran 21 tasks, now up to date (257 warnings, 0 errors)` |
| `python3 scripts/verify_interop.py fist-mbt/reports/moonbit_vectors_full.json --strict`（WSL） | `PASS=46 FAIL=0 SKIP=0`，rc=0 |

注：wasm/js 的 warnings 为全仓既存告警（含他人包），非本次改动引入；`test-suit/rhop` 两目标全绿。

## 5. 未修项 / 已接受差异

| 项 | 处置 |
|---|---|
| PROTO-03 字段类型严格度高于 vools | 有意保留；矩阵 §7 第 17 行登记 |
| PROTO-07 非规范数字字面量 | 有意保留；矩阵 §7 第 18 行登记 |
| canonical 浮点限制（既有差异） | 矩阵 §7 第 1 行既有登记，本轮未变（`json_canonical.mbt` 未改） |
| `test-suit/rhop_task` 的 2 个失败（`mark_closed` 返回旧值，wasm 193/192/1、js 371/369/2 为**修复前历史数字**） | **不属于本域**，属 impl-crypto `task_heartbeat`；lead 已转交，本轮不复现（复跑 `test-suit/rhop` 已 200/392 全绿） |

## 6. 改动清单（仅本域）

```text
rhop/envelope.mbt                            +73/-？  PROTO-01/02
rhop/signer.mbt                              +54/-？  PROTO-06
test-suit/rhop/envelope_test.mbt             +183     PROTO-01/02 用例（6 条）
test-suit/rhop/signer_test.mbt               +36      PROTO-06 用例（3 条）
test-suit/rhop/digest_test.mbt                2 行    PROTO-04
test-suit/rhop/core_test.mbt                  2 行    PROTO-05
test-suit/rhop/json_canonical_test.mbt       +26      PROTO-08（判别用例 + 整串断言）
test-suit/rhop_vectors/{moon.pkg,producer_test.mbt,pkg.generated.mbti}  新增
fist-mbt/docs/2026-10-27-rhop-vools-parity-matrix.md   §7 +2 行（17/18）
fist-mbt/reports/moonbit_vectors_full.json            新增（生产者产物）
fist-mbt/reports/2026-10-28-c1-fix-protocol.md        本报告
```

未执行 `git commit`（按 lead 纪律，提交由 lead 统一做）。
