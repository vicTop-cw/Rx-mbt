# C3 修复报告 — 协议 / 摘要 / 文档域（契约与文档一致性 + 清整）

> 轮次：C3（组合模式 ×3 轮的第 3 轮），主题：**契约与文档一致性 + 互操作盲区 + 清整收尾**。
> 输入：本域寻虫 `2026-10-28-c3-bugfind-protocol.md`（C3P-01…10）+ **QA 交叉输入** `2026-10-28-c3-bugfind-qa.md`（C3-Q1…Q5）+ **impl-session 交叉输入** `2026-10-28-c3-fix-session-config.md` §5。
> 执行：impl-core，2026-10-28（UTC+8）。纪律：moon 命令全经 `bash scripts/with_moon_lock.sh`；格式化 `~/.moon/bin/moonfmt.exe -w`。
> **未改任何 API 签名**；产品代码改动仅 1 处注释（`rhop/signer.mbt` 的矩阵引用）+ 1 处测试（生产者负向用例）。

---

## 1. 摘要（按 Lead 指定优先级：安全口径 > 字段 > 计数 > 符号 > 其他）

| # | 项 | 来源 | 处置 |
|---|---|---|---|
| **1** | **矩阵 §4.3 `action_cfg` 口径写反（安全相关）** | session §5.1 | ✅ 改为「**含 sftp 原文凭据**（jump.* 真连需要），严禁落日志；回显掩码只在 `rhop.echo` 回执」；DOC 同步 |
| **2** | **`send_package` 回执字段错**（矩阵 + DOC） | session §5.2 | ✅ send = `{status,transport,filename,role}`；`payload` 只在 `recv_package` 回执 |
| **3** | **计数/覆盖率（QA C3-Q1）** | QA | ✅ online 16→**17**（补 `SftpChannel.port_reachable` ⛔ 行）；契约 192→**193**；task 230→**264**（逐文件表）；全量 437→**472**；§1 全量行分类修正为 **179 ✅ / 25 🟡 / 1 ⚠️ / 267 ⛔**；覆盖率 **92.2% / 94.8% / 37.9% / 39.0%** |
| **4** | **§9 项目侧公开面数字（QA C3-Q2）** | QA | ✅ 337→**353 行 pub**（300 fn / 32 struct / 3 enum / 2 trait / 10 const + 15 impl），补 `rhop_task` 163 行与「以 `moon info` 为准」注 |
| **5** | **68 个符号零提及 + 3 文件未逐文件覆盖（QA C3-Q3）** | QA | ✅ DOC 补：TaskRecord 14 个 wither 逐个列名、TaskConfig/TaskRole/TaskState 成员、jump_* 8、rhop_* 原语 9、Secret* 5、MirrorDB::try_*/count_by_status_full、Executor::from_*、Handler/JsonRows；新增 `cipher.mbt` / `packet.mbt` / `rhop_native.mbt` 三个逐文件小节 |
| **6** | **互操作负向盲区（QA C3-Q4）** | QA | ✅ `test-suit/rhop_vectors/producer_test.mbt` 增 **tampered_checksum 负向用例**：本地断言 MoonBit 必须 `Err(checksum mismatch)`，并把 `rejected/actual_error` 写进产物；**`verify_interop.py --strict --require-negative` 现 PASS=47 FAIL=0 WARN=0 SKIP=0**（此前 WARN=1） |
| **7** | **README 退出码小节（QA C3-Q5）** | QA | ✅ README×2 增「测试入口退出码」表：0 全绿 / 1 真失败 / 2 用法环境 / 3 全跳过 / 4 锁超时 |
| **8** | **signer 行为陈述与实现相反（C3P-01）** | 本域 | ✅ README:366、DOC:748、矩阵 signer 三行全部改为「`UNKNOWN_NPU` 兜底、`sign()` 恒 `Some`、`has_serial()` 只表示真实序列号」；补 `NPU_UNKNOWN_SERIAL` 常量与安全说明 |
| **9** | **矩阵 §4 测试数过期** | session §5.4 | ✅ session 20 / config 25 / interact 23（§4 引言 + §4.1–4.3 表 + §10 覆盖表同步） |
| **10** | **`to_dict` 口径旧** | session §5.3 | ✅ 改为「**递归深度脱敏**（sftp/online/shared/relay 下 password/key_path/token/secret），**比 vools 更严**」 |
| **11** | **`interact` 目标列** | session §5.5 | ✅ 注明「纯分派三目标；**真实闭环仅 js**」 |
| **12** | **`~` 展开未文档化** | session §5.7 | ✅ DOC `key.mbt` 段注明「不做 `~` 展开（两平台一致），请给绝对路径或环境变量」 |
| **13** | **README 差异摘要 +3 行** | session §5.6 | ✅ 增 D1（回执分流）/ D6+D7（safe_filename + remove_package，纯增量）/ D8+D12（一次性 token + `interact` 只收 `RhopConfig`） |
| **14** | **矩阵补 6 条实现层差异** | session §5（D3/D6/D7/D8/D10/D12） | ✅ §7 增至 34 条（新增并整体重排编号，signer 差异为第 22 条） |
| **15** | **`available()/select()` 副作用口径** | session §5.8 | ✅ 改为「**会实际探测**：在线通道可能起子进程/发网络，http 介质约 0.5 s，**不是**无副作用查询」 |
| **16** | `rhop/signer.mbt` 注释引用失效（C3P-08） | 本域 | ✅ 指向矩阵 §7 差异 22（重排后的正确行） |
| **17** | 矩阵标题/版本行陈旧（C3P-06） | 本域 | ✅ 标题改「全量落地：Batch A–D + clipboard + P2」；版本升 **v5** |
| **18** | 矩阵 §2 signer 三行 / §6 增量（C3P-07） | 本域 | ✅ 行内改新语义；§6 增 `NPU_UNKNOWN_SERIAL` 与 `Aes256GcmCipher` |
| **19** | mbti 陈旧（C3P-02） | 本域 | 📄 报告并**移交 Lead**：`rhop` mbti 缺 `Aes256GcmCipher` 3 项；建议终验统一 `moon info`（并行 lane 期间单独跑会写入他人未落定公开面） |

> 未做/接受：C3P-04/08/09 的深度项（payload 深拷贝、单例隔离、流式写出）为 C2 已记录的有意取舍，本轮仅补文档；`C3-Q6` 的两处措辞（RISK-01/04）属 business/crypto lane 报告，未在本域修改。

---

## 2. 关键修复细节

### 2.1 安全口径（最高优先）
- **`action_cfg` 含原文凭据**：矩阵与 DOC 都改成「供 `jump.*` 真连使用的 sftp 原文；严禁直接落日志；掩码只发生在 `rhop.echo` 回执」。这是安全相关错误（原文档会让使用者以为它已脱敏而放心打日志）。
- **`to_dict` 递归脱敏**：原写「与 vools 同（只处理 sftp.password/key_path）」，实际实现递归处理 sftp/online/shared/relay 下 token/secret 等键 ⇒ 改为「**比 vools 更严**」并列出键表。

### 2.2 互操作负向证据（QA C3-Q4）
`test-suit/rhop_vectors/producer_test.mbt` 的 `build_envelope` 现在同时处理两类 fixture 用例：
- 正向（有 `fields`）：`from_dict → to_rhop_bytes → checksum_match`；
- **负向（`expect_error: true`）**：hex 解码 `to_rhop_bytes_utf8_hex` → `Envelope::from_rhop_bytes` **必须 Err** → 断言错误文本含 `checksum mismatch` → 产物写 `{name, to_rhop_bytes_utf8_hex, rejected:true, actual_error, expect_error_contains}`。
失败即 `abort`（把「MoonBit 未拒绝篡改信封」变成硬红）。
**结果**：产物 envelope 分节 2 → **3** 条；`python scripts/verify_interop.py … --strict --require-negative` → **PASS=47 / FAIL=0 / WARN=0 / SKIP=0**。

### 2.3 计数与覆盖率（QA C3-Q1）
- §1：`online.py` 17（新增 `SftpChannel.port_reachable` ⛔ 行）、契约小计 **193**、task **264**、全量 **472**，且全量行改为可自洽的 **179 ✅ / 25 🟡 / 1 ⚠️ / 267 ⛔**（此前 🟡 漏计 task 的 21、⛔ 把 task 整块计入，两者抵消掩盖了分类错误）。
- §5.9：新增 vools `task/` **17 文件逐符号分布表**（合计 264），避免再漂移。
- §8：分母说明与统计表按 193/472 重算；结论 1/4 同步。
- §9：`353 行 pub`（含分类明细）+ `rhop_task 163 行` + 「以 `moon info` 为准」注。

### 2.4 文档覆盖（QA C3-Q3 / session §5.5）
DOC.md 增补/改写 **约 60 行**：TaskRecord 14 个 wither 逐个列名（可逐项检索）、TaskConfig::has_key/role_long/role_short、TaskRole::short、TaskState::is_valid/to_string/status_roundtrip_exact、SecretField/SecretFinding 成员、MirrorDB::try_*/count_by_status_full、Executor::from_config_dir/from_mirror_path、Handler/JsonRows 类型别名、jump_* 8 个动作与辅助、rhop_* 原语 9 个、`Aes256GcmCipher`（js-only，含 token 格式）、`MAX_ENVELOPE_NESTING_DEPTH`/`NPU_UNKNOWN_SERIAL` 常量；并把「既有协议类型」拆成 `cipher.mbt` / `packet.mbt` / `rhop_native.mbt` 三个逐文件小节。

---

## 3. 验证（真实输出）

### Windows（moon 0.1.20261016 / node v25.2.1，全经 `with_moon_lock.sh`）

```text
moon check（wasm）  : 0 error
moon check --target js     : 0 error
moon check --target native : 0 error

moon test              : Total tests: 612, passed: 612, failed: 0.
moon test --target js  : Total tests: 825, passed: 825, failed: 0.
moon test --target native : Total tests: 612, passed: 612, failed: 0.
```

分包（wasm / js）：

```text
test-suit/rhop            156 / 160    （含 session 20 / config 25 / digest 21 / canonical 21 / envelope 20 …）
test-suit/rhop_vectors      0 / 2      （含 tampered 负向断言）
test-suit/rhop_js           0 / 56
test-suit/rhop_clipboard    0 / 25
test-suit/rhop_interact     0 / 23
test-suit/rhop_business    10 / 57
test-suit/rhop_task        46 / 102
```

### WSL（Ubuntu-22.04 / moon 0.1.20261021）

```text
WSL check errors: 0
WSL wasm:   Total tests: 612, passed: 612, failed: 0
WSL js:     Total tests: 825, passed: 825, failed: 0
WSL native: Total tests: 612, passed: 612, failed: 0
```

### 互操作门禁

```text
python scripts/verify_interop.py fist-mbt/reports/moonbit_vectors_full.json --strict --require-negative
  PASS=47  FAIL=0  WARN=0  SKIP=0  (total 47)
  RESULT: PASS -- 所有已产出项经 vools 复核一致
```

### 格式与文档自检

```text
fmt 幂等: YES（8 个 .mbt 连续两次 moonfmt -w 后 sha256 集合一致）
README.md / README.mbt.md：diff 为空；围栏 22 / 22
DOC.md 围栏 54（成对）；矩阵围栏 2（成对）
```

---

## 4. 改动文件清单

**产品代码（1，仅注释）**
1. `rhop/signer.mbt` —— 矩阵差异引用 `§7 差异 17` → `§7 差异 22`（重排后的 signer 行）

**测试（1，新增负向用例 + 断言计数）**
2. `test-suit/rhop_vectors/producer_test.mbt` —— tampered_checksum 负向分支 + envelope 条数 2→3

**文档（4）**
3. `fist-mbt/docs/2026-10-27-rhop-vools-parity-matrix.md`（v5：计数 193/264/472、覆盖率、§9 353 行、§4/§5/§6/§7/§8/§9/§10 全面刷新；安全口径与 signer 语义修正；§7 增 6 条实现差异并重排 34 条）
4. `DOC.md`（action_cfg/to_dict/send_package/interact/available 语义；`~` 路径约定；AES-256-GCM；约 60 行缺失符号；3 个逐文件小节；常量表补 2 项）
5. `README.md`（退出码表、差异摘要 +3 行、signer 安全说明、AES 提及、计数表刷新）
6. `README.mbt.md`（与 README.md **逐字节同步**）

**报告（2）**
7. `fist-mbt/reports/2026-10-28-c3-bugfind-protocol.md`
8. `fist-mbt/reports/2026-10-28-c3-fix-protocol.md`（本文件）

> 未改动：`rhop_task/*`、`monitor/*`、`moon.mod`、`moon.pkg`、rhop 包内他人文件（config/session/actions/mirror/interact/daemon…）。
> 移交 Lead：`rhop/pkg.generated.mbti` 需在并行 lane 收口后统一 `moon info`（当前缺 `Aes256GcmCipher` 3 项）。
