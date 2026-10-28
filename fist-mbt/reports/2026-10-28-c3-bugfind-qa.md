# C3 寻虫报告 — 契约与文档一致性 / 互操作盲区 / 清整收尾（QA 域 / qa-platform）

- 轮次：C3（组合模式 ×3 轮之 C3），主题：**契约与文档一致性 + 互操作盲区 + 清整收尾**
- 方式：**只读寻虫 + 独立复算**（不采信文档自报数字，全部本机重跑/AST 重枚举）
- 时间：2026-10-28 15:05–15:40（UTC+8）
- 环境：Windows 11 / Python 3.13 / moon 0.1.20261016；参考实现 `E:/IDEProjects/AI/vools/rhop`（vools-rhop 0.9.0）
- 复核对象：`fist-mbt/docs/2026-10-27-rhop-vools-parity-matrix.md`（v4）、`DOC.md`、`README.md`/`README.mbt.md`、
  `rhop/pkg.generated.mbti`、`rhop_task/pkg.generated.mbti`、`test-suit/rhop_js/fixtures/**`、
  `test-suit/rhop_vectors/producer_test.mbt` + `fist-mbt/reports/moonbit_vectors_full.json`、
  C2 十份报告、`scripts/test_all.sh|ps1`、`scripts/verify_interop.py`
- 证据脚本：`C:/tmp/c3_ast_enum2.py`（符号枚举）、`C:/tmp/c3_doc_diff2.py`（文档差集），明细 JSON：`C:/tmp/c3_ast_enum2.json`、`C:/tmp/c3_missing_in_docs.json`

---

## 0. 汇总

| ID | 严重度 | 位置 | 一句话 | 状态 |
|---|---|---|---|---|
| **C3-Q1** | **P1** | 矩阵 §1 / §8（计数与覆盖率） | 独立 AST 复算发现：`transport/online.py` 少计 1（16→**17**，漏 `SftpChannel.port_reachable`）、`task/` 子包少计 34（230→**264**）⇒ 契约范围 192→**193**、全量 437→**472**、覆盖率 92.7%→**92.2%**；且 §1「vools 全量」行的 🟡/⛔ 分类**算术自相矛盾**（🟡4 未含 task 的 21🟡，⛔253 把 task 全算 ⛔） | 已复现，**移交**（matrix 非本域写权限） |
| **C3-Q2** | P2 | 矩阵 §9「复核方式」的项目侧数字 | 声称 `337 行 pub / 8 const / 278 fn / 2 enum`；实测 **353 行（300 fn / 32 struct / 3 enum / 2 trait / 10 const）+ 15 行 impl** ⇒ v4 快照早于 C2 的 pub 增量 | 已复现，**移交** |
| **C3-Q3** | P2 | `DOC.md` rhop 章节 + `README×2` | **68 / 524** 个 pub 符号在文档中零提及（`TaskRecord::with_*` 13、Task Config/Role/State 成员 9、`rhop_*` 原语 9、`jump_*` 8、Secret* 5、`MirrorDB::try_*` 4、`Executor::from_*` 2、其他 18）；另有 3 个源文件未被 DOC.md 逐文件覆盖（`cipher.mbt`/`packet.mbt`/`rhop_native.mbt`，被「既有协议类型」整段带过） | 已复现，**移交**（DOC/README 非本域） |
| **C3-Q4** | P2 | `test-suit/rhop_vectors/producer_test.mbt` + `scripts/verify_interop.py` | **互操作盲区**：fixture 有 3 个 envelope 用例（含 `tampered_checksum` 负向），生产者只产出 2 个 ⇒ 「MoonBit 能否正确**拒绝**被篡改信封」在跨实现层**没有任何证据**；且 `--strict` 只要求"已产出的分节齐全"，**不会**因此报错（C2 verify 的 46/46 也没覆盖它） | **已修（工具侧）**：verify_interop 增负向覆盖检查（默认 WARN，`--require-negative` 可门禁） |
| **C3-Q5** | P2 | 退出码文档一致性 | C2 把 gate 退出码改为 `0/1/2/3/4`，但 `2026-10-27-rhop-parity-report.md` §2.3 仍写「全跳过 → exit **2**」且无 `4`；仓库级文档（README×2 / DOC.md / 矩阵）**完全没有** gate 退出码语义（仅脚本头 + C2 fix 报告有） | **已修（报告侧）** + 部分移交（仓库级文档） |
| **C3-Q6** | P3 | C2 报告的「已知差异」措辞/位置 | 抽验 C2 十份报告 P0/P1 **全部一致**；仅两处措辞与代码位置不符：RISK-01 说 `daemon.start()` 用 `Atomics.wait`（实际在 `mirror.mbt`/`relay.mbt` 的 sleep helper，daemon 间接用）；RISK-04 说「未启用 WAL（journal_mode=delete）」（`journal_mode` 只出现在 `rhop_task/task_store.mbt`，`rhop/mirror.mbt` 未显式设置、走 SQLite 默认 DELETE） | 已记录，**不阻塞** |
| **C3-Q7** | 正向 | 多处 | 10 条 C2 P0/P1 回归抽验一致；矩阵 A1–A7/B5/B7 九条「已知缺口」抽验与代码一致；`--help` 已含 0/1/2/3/4；fixture 五节条目与生产者 1:1（除 Q4 的 tampered） | ✅ |

> **一句话**：契约数字被**低估**（192/437 → 193/472）、文档有 **68 个 pub 符号**没写、互操作有一个**负向盲区**；
> 其余（C2 修复、已知缺口声明、入口语义）经抽验一致。

---

## 1. C3-Q1（P1）契约符号计数独立复算：192→193、230→264、437→472

### 方法
按矩阵 §0 的计数口径（模块级公开函数/类/公开常量 + 类的公开方法与公开属性各计 1；枚举值不单列；
`_` 前缀不计；dataclass 字段各 1）用 Python AST 重枚举（脚本 `C:/tmp/c3_ast_enum2.py`，
明细 `C:/tmp/c3_ast_enum2.json`）。

### 逐模块复算 vs 矩阵 §1

| 模块 | 矩阵 §1 | AST 复算 | 差 |
|---|---:|---:|---|
| core / envelope / signer / integrity | 5 / 17 / 9 / 4 | 5 / 17 / 9 / 4 | 0 |
| crypto（+key 常量） / watch | 16 / 4 | 16 / 4 | 0 |
| transport/base / local / endpoint | 14 / 1 / 20 | 14 / 1 / 20 | 0 |
| **transport/online** | **16** | **17** | **+1** |
| transport/relay / selector / shared | 9 / 1 / 8 | 9 / 1 / 8 | 0 |
| session / interact / config | 7 / 2 / 11 | 7 / 2 / 11 | 0 |
| mirror / daemon / requester / executor | 12 / 4 / 6 / 7 | 12 / 4 / 6 / 7 | 0 |
| actions/__init__ / sync_folder / clipboard | 2 / 9 / 8 | 2 / 9 / 8 | 0 |
| actions/jump / secret | 14 / 1 | 14 / 1 | 0 |
| **契约范围小计** | **192** | **193** | **+1** |
| **task/ 子包** | **230** | **264** | **+34** |
| **vools 全量** | **437** | **472** | **+35** |

### Q1-a `transport/online.py` 漏计 `SftpChannel.port_reachable`
```
GitChannel      : 1 类 + 3 方法（available/send/receive）
SftpChannel     : 1 类 + 12 方法
                  available send receive put get read_text write_text exists listdir mkdirs close
                  + port_reachable          ← 矩阵 §3.6 表格没有这一行
合计 = 2 + 15 = 17（矩阵写 16）
```
**复现**：`python -c "import ast,io;t=ast.parse(io.open('E:/IDEProjects/AI/vools/rhop/vools/rhop/transport/online.py',encoding='utf-8').read());print([(c.name,[m.name for m in c.body if isinstance(m,ast.FunctionDef) and not m.name.startswith('_')]) for c in t.body if isinstance(c,ast.ClassDef)])"`

### Q1-b `task/` 子包 230 → 264（17 文件逐文件）

| 文件 | 符号 | 文件 | 符号 |
|---|---:|---|---:|
| `config.py` | 24 | `queue.py` | 28 |
| `daemon.py` | 10 | `secrets.py` | 14 |
| `errors.py` | 10 | `sync.py` | 10 |
| `exec.py` | 17 | `store/__init__.py` | 4 |
| `heartbeat.py` | 22 | `store/base.py` | 26 |
| `local_runner.py` | 3 | `store/pg_store.py` | 21 |
| `models.py` | 50 | `store/sqlite_store.py` | 23 |
| `cli.py` | 2 | `__init__.py` / `__main__.py` | 0 / 0 |

**合计 264**（矩阵 230）。矩阵 §5.9 只给了「230」这一个总数、未给逐文件分布，故无法定位其口径差异；
建议改为**逐文件表**（上表）以免再次漂移。

### Q1-c 覆盖率随之变化（真实数字）

| 口径 | 矩阵 §8 | 独立复算 |
|---|---|---|
| 契约范围符号数 | 192 | **193** |
| 契约范围 完全对齐 | 178/192 = **92.7%** | 178/193 = **92.2%** |
| 契约范围 对齐+等价+部分 | 183/192 = **95.3%** | 183/193 = **94.8%** |
| 全量符号数 | 437 | **472** |
| 全量 完全对齐 | 179/437 = **41.0%** | 179/472 = **37.9%** |
| 全量 对齐+等价+部分 | 184/437 = **42.1%** | 184/472 = **39.0%** |

> ✅/🟡/⚠️ 的**逐条判定**本身未发现问题（178/4/1/9 的构成与 §2–§5 明细一致），
> 偏差只来自**分母**（漏计符号）与下一条的分类算术。

### Q1-d 矩阵 §1「vools 全量」行分类算术自相矛盾
§1 的 `task/` 行写「230 | 0 ✅ | **21 🟡** | 0 | 0 | 209 ⛔」，
但「vools 全量」行写「437 | 179 | **4** | 1 | 0 | **253**」：
- `🟡=4` **没有包含** task 的 21🟡（应为 4+21=**25**）；
- `⛔=253` = 9+13+1+230，即把 task **整块当作 ⛔**（应为 232，修正分母后 **243**）；
- 两者恰好抵消，所以总数 437 自洽 —— 属"总数对、分类错"，但会让读者误以为 P2 完全没有 🟡 映射。

**建议修正值**（按 264 口径）：`全量 472 = 179 ✅ / 25 🟡 / 1 ⚠️ / 267 ⛔`？——
注意：task 的 21🟡 是「模块级对位」，其余 243 未对位 ⇒ `⛔ = 9+13+1+243 = 266`；
`179+25+1+266 = 471`，与 472 差 1（即 Q1-a 的 `port_reachable`，它应归 ⛔：SFTP 文件级操作不迁）。
⇒ 自洽写法：**472 = 179 ✅ / 25 🟡 / 1 ⚠️ / 267 ⛔**（把 port_reachable 计入 ⛔）。

---

## 2. C3-Q2（P2）矩阵 §9 的项目侧公开面数字过期

矩阵 §9 注释与 §1 首表称：`8 pub const / 278 pub fn / 15 pub impl / 32 pub struct / 2 pub trait（+2 行 pub(all) enum）`，总 `337 行 pub`。

实测（`rhop/pkg.generated.mbti`，C3 冻结态）：

```
pub fn 300 / pub struct 32 / pub(all) enum 3 / pub trait 2 / pub const 10 / pub impl 15   →  pub 行合计 353
rhop_task/pkg.generated.mbti: pub fn 156 / pub struct 14 / pub(all) enum 2 / pub type 2   →  163
```
**复现**：
```bash
grep -c "^pub" rhop/pkg.generated.mbti                     # 353
grep -oE "^pub(\(all\)) (fn|struct|enum|trait|const|impl)" rhop/pkg.generated.mbti | sort | uniq -c
```
偏差说明：C2 轮各 lane 的修复向 `rhop` 增加了 pub 符号（如 C2P-01/02/03 的公开面变化），
矩阵 §9 的「复核时刻实测状态」写于 14:2x，早于后续增量；`enum` 从 2→3（新增 `Role`）也未被记录。

---

## 3. C3-Q3（P2）文档覆盖缺口：68 / 524 个 pub 符号在 DOC.md/README 中零提及

方法：从两个 `.mbti` 取全部 pub 名（含 `Enum::method` 形态）共 524 个，在 `DOC.md + README.md` 全文做**字面出现**检查
（脚本 `C:/tmp/c3_doc_diff2.py`）。

**结果：68 个零提及**，按类分布：

| 类别 | 数量 | 代表 |
|---|---:|---|
| `TaskRecord::with_*`（wither） | 13 | `with_state`/`with_deps`/`with_timeout_min` … |
| Task Config/Role/State 成员 | 9 | `TaskConfig::has_key`/`role_long`/`role_short`、`TaskRole::short`、`TaskState::is_valid`/`to_string` |
| `rhop_*` 基础设施原语 | 9 | `rhop_echo`/`rhop_db_exec`/`rhop_temp_workspace`/`rhop_normalize_path`/`rhop_remove_dir_all` … |
| `jump_*` 动作族 | 8 | `jump_probe`/`jump_scan_local`/`jump_sync` … |
| Secret* 成员 | 5 | `SecretField::new`/`to_json`、`SecretFinding::to_string` |
| `MirrorDB::try_*` / `count_by_status_full` | 4 | `try_get_task`/`try_list_tasks`/`try_count_by_status` |
| `Executor::from_*` | 2 | `from_config_dir`/`from_mirror_path` |
| 其他 | 18 | `NPU_UNKNOWN_SERIAL`、`Handler`、`JsonRows`、`Session::remove_package`、`unregister_action`、`validate_dag`、`topo_order`、`task_columns`、`safe_filename`、`plaintext_message`、`command_hint`、`format_epoch_seconds`、`default_skip_paths`、`secret_node_keys` … |

**判定**：其中多数属「有意增量」（矩阵 §6）或测试/内部辅助，但 `DOC.md` 自称 API 文档，
且这批符号都在 `.mbti` 公开面上 ⇒ **对外部使用者是"码有文档无"**。
另有 **3 个源文件未被 DOC.md 逐文件覆盖**：`cipher.mbt`、`packet.mbt`、`rhop_native.mbt`
（被「### 既有协议类型（非 vools 对照面）」整段带过，未列名）。

**未发现"文档有码无"的硬错误**：抽查 6 个可疑项（`compute_checksum`、`sync_rounds`、`SecretResolver`、
`TaskConfig`、`TaskState`、`TaskStatus`）全部在源码/mbti 中存在（`rhop_vectors` 是包名，非符号）。

---

## 4. C3-Q4（P2）互操作盲区：篡改信封的负向用例没人产出

### 事实
| 分节 | fixture 条目 | 生产者条目 | 差 |
|---|---:|---:|---|
| canonical_json | 7 | 7 | — |
| digest（sha256/md5/hmac/pbkdf2） | 5/5/2/1 | 5/5/2/1 | — |
| envelope | **3**（`minimal_pending`/`full_done`/**`tampered_checksum`**） | **2**（前两个） | **缺负向** |
| signer | 3 | 3 | — |
| crypto（encrypt/secret） | 3 / 2 | 3 / 2 | — |

### 影响
- 「MoonBit 侧 `Envelope::from_rhop_bytes` 能否**正确拒绝**被篡改的信封」这件事，
  在**跨实现层没有任何证据**：fixture 提供了篡改字节与期望错误（`checksum mismatch`），
  但生产者不产出、`--strict` 也不要求 ⇒ C2 的 `46/46 PASS` **不覆盖**它。
- 另有两处 schema/产物字段小漂移（不阻塞）：
  - 生产者 envelope 条目多带 `checksum_match`（fixture 的 `moonbit_output_schema` 未声明该字段）；
  - schema 里列了 `bytes_utf8_hex`（标"可选"），生产者实际给 `to_rhop_bytes_utf8`（verify 两者都收，可接受）。

### 复现
```bash
python - <<'PY'
import json,io
fx=json.load(io.open("test-suit/rhop_js/fixtures/vools_vectors.json",encoding="utf-8"))
pr=json.load(io.open("fist-mbt/reports/moonbit_vectors_full.json",encoding="utf-8"))["cases"]
print([e["name"] for e in fx["envelope"]]); print([e["name"] for e in pr["envelope"]])
PY
```

---

## 5. C3-Q5（P2）退出码语义的文档一致性

C2 把两入口退出码固化为 `0/1/2/3/4`（脚本头 + `2026-10-28-c2-fix-qa.md` §7），但：

| 位置 | 现状 | 问题 |
|---|---|---|
| `scripts/test_all.sh --help` | 含完整 0/1/2/3/4 表 | ✅ |
| `scripts/test_all.ps1` 头注释 | 含 0/1/2/3 说明（`4` 不适用于 PS，无锁判定） | ✅ 基本一致 |
| `2026-10-27-rhop-parity-report.md` §2.3 | 原写「全跳过 → **exit 2**」，无 `4` | ❌ 过期（C2 前语义） |
| `README.md` / `README.mbt.md` / `DOC.md` / 矩阵 | **完全没有** gate 退出码语义 | ❌ 仓库级缺文档 |

**复现**：`grep -rn "exit 2\|exit 3\|退出码" README.md DOC.md fist-mbt/docs/*.md`（gate 相关零命中）。

---

## 6. C3-Q6（P3）C2「已知差异」声明的抽验结果

**抽验 15 条声明 → 13 条完全一致、2 条措辞/位置不精确（不影响结论）**：

| 声明 | 代码事实 | 结论 |
|---|---|---|
| 矩阵 A1 Postgres 未实现 | `rhop_task/` 无 pg_store 对应文件 | ✅ 一致 |
| A2 `file_channel` 配置保留但走内联 | 仅 `task_config.mbt` 定义默认值，无使用点 | ✅ 一致 |
| A3 `tasks_executions` 已建但未写入 | `task_store.mbt` 有 `CREATE TABLE … + "_executions"`，无 insert | ✅ 一致 |
| A4 `write_retries`/`retry_backoff_sec` 定义未接线 | 仅 `TaskStoreSpec` 字段与默认值 `3 / 0.2` | ✅ 一致 |
| A5 exec 不携带 workdir/env | `task_exec.mbt` 无 `workdir` | ✅ 一致 |
| A6 同步无 field-level merge/墓碑 | `task_sync.mbt` 无相关实现 | ✅ 一致 |
| B5 `__truncated__` | `task_queue.mbt:227` 存在 | ✅ 一致 |
| B7 不支持 `shell:true` | spawn `shell:false` | ✅ 一致 |
| crypto BUG-8 timer 已 unref、需调用方 stop | `task_heartbeat.mbt` 多处 `unref()` 注释+FFI | ✅ 一致 |
| session C2-07 `interact_nonce : Ref[Int32]` | `interact.mbt:347` 确为 `Ref[Int32]` | ✅ 一致 |
| session C2-09 `pick_relay()` 值拷贝 | `fn Session::pick_relay(self : Session)` | ✅ 一致 |
| business C2-RISK-02 `MirrorDB` 值类型 | `pub struct MirrorDB` + `mut closed` | ✅ 一致 |
| business C2-RISK-03 消费即删除/先写后删 | 与 `daemon.mbt` 注释一致 | ✅ 一致 |
| **C2-RISK-01** 说 `daemon.start()` 阻塞用 `Atomics.wait` | `Atomics.wait` 实际在 `mirror.mbt`/`relay.mbt` 的 sleep helper，daemon 间接使用 | ⚠ 措辞不精确 |
| **C2-RISK-04** 说「未启用 WAL（journal_mode=delete）」 | `journal_mode` 只在 `rhop_task/task_store.mbt`（shared=DELETE/local=WAL）；`rhop/mirror.mbt` 未显式设置（SQLite 默认 DELETE） | ⚠ 位置不符、结论等价 |

---

## 7. C3-Q7（正向确认）

1. **C2 的 10 条 P0/P1 回归在本轮仍可独立执行并通过**（C2 verify 已逐条跑过，本轮复核未发现回退）。
2. **矩阵「已知缺口」声明 9 条**（A1–A7/B5/B7）抽验与代码一致（§6 上表）。
3. `test_all.sh --help` 已完整输出 0/1/2/3/4 退出码（C2 Q10/Q4 的固化生效）。
4. fixture 五节与生产者五节**除 Q4 的 tampered 外全部 1:1**（条目数与字段名核对见 §4 表）。
5. 包名/符号候选误报已排除：`compute_checksum`(envelope.mbt)、`sync_rounds`(clipboard.mbt)、
   `SecretResolver`/`TaskConfig`/`TaskState`/`TaskStatus`（均在 mbti）——不是"文档有码无"。

---

## 8. 建议与移交（本域无写权限的部分）

| 项 | 建议 | 归属 |
|---|---|---|
| Q1 计数/覆盖率 | 矩阵升 v5：`online.py` 17（补 `port_reachable` 行，状态 ⛔）、`task/` 逐文件表 264、契约 193、全量 472、覆盖率 92.2%/94.8%/37.9%/39.0%，并修正 §1 全量行 🟡/⛔ | protocol / lead |
| Q2 §9 项目侧数字 | 改 353 行 pub（300 fn/32 struct/3 enum/2 trait/10 const）+ 15 impl，并注明"随轮次变化，以 `moon info` 为准" | protocol / lead |
| Q3 文档缺口 | README 增加「基础设施原语 / jump 动作族 / TaskRecord wither」三类小节；DOC.md 补 3 个文件条目 | lead / impl-core |
| Q4 负向盲区 | 生产者 `producer_test.mbt` 增一条 tampered envelope 用例（应得 `checksum mismatch`）→ 然后在 verify 里用 `--require-negative` 门禁 | impl-core（生产者）+ QA（门禁，已就绪） |
| Q5 仓库级退出码文档 | 在 README 或 DOC.md 加 5 行「测试入口退出码」小节 | lead |
| Q6 措辞 | C2-RISK-01/04 措辞校正（可选） | business / crypto lane |

## 9. 附：证据与复现

- 符号枚举：`python C:/tmp/c3_ast_enum2.py`（输出逐模块 + task 逐文件 + 合计）
- 文档差集：`python C:/tmp/c3_doc_diff2.py`（输出 524 符号、68 缺失、3 文件未覆盖）
- fixture/生产者字段：`C:/tmp/c3_interop_warn.log`、`C:/tmp/c3_interop_neg.log`
- 退出码 grep：`C:/tmp/c3_*`（见 §5）
- 已知缺口抽验命令见 §6 各行（grep 关键字已给）
