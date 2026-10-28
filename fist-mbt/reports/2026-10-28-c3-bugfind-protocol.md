# C3 寻虫报告 — 协议 / 摘要 / 文档域（API 枚举一致性审计）

> 轮次：C3（寻虫→修复→打磨→验证→清整 ×3 轮的第 3 轮），主题：**契约与文档一致性 + 互操作盲区 + 清整收尾**。
> 范围：`rhop/pkg.generated.mbti` + `rhop_task/pkg.generated.mbti` 的**全部 `pub` 符号** ↔ `README.md` / `README.mbt.md` / `DOC.md` / 矩阵 v4 ↔ 契约 §3 API 清单。
> 方式：**只读审计**；脚本化枚举（`E:/tmp/c3audit/audit2.py`、`sigs.py`），逐条回源码/测试核实；真树未改任何产品代码。
> 审计人：impl-core　时间：2026-10-28（UTC+8）
> 规模：**551 个公开符号**（rhop 368 + rhop_task 175，含 trait 方法；mbti 去重后 551）。
> 结论：**P0 × 0 / P1 × 1 / P2 × 4 / P3 × 4** + 1 条「已核实无缺陷」。P1 是 signer 行为陈述与实现相反（会影响使用方判断），必须本轮修。

---

## 0. 汇总表

| ID | 严重度 | 位置 | 一句话 | 裁决建议 |
|---|---|---|---|---|
| **C3P-01** | **P1** | `README.md:366`、`DOC.md:748`、矩阵 `§2`（signer 行 106-107） | **signer 行为陈述与实现相反**：三处都写「provider 缺失 ⇒ `sign()` 返回 `None`」，而 C1 已按 vools `UNKNOWN_NPU` 语义改为**兜底签名、恒不为 `None`**（`signer.mbt:104/152/158`，`signer_test.mbt:141/199` 两用例锁定） | **本轮修**（三处文档 + 安全说明） |
| C3P-02 | P2 | `rhop/pkg.generated.mbti` | **mbti 陈旧**：源码新增的 `Aes256GcmCipher` / `Aes256GcmCipher::new` / `impl RhopCipher for Aes256GcmCipher`（在 `rhop/rhop_js.mbt`）不在 mbti ⇒ 需 `moon info` 重跑（生成物） | 报告 + 由 Lead 终验统一 `moon info`（本域不单独跑，避免与并行 lane 冲突） |
| C3P-03 | P2 | `DOC.md` | **DOC 缺 41 个公开符号**（jump_* 动作族 8、rhop_* 基础设施 9、task 工具/记录 helper 8、其他 9、常量/别名 7） | **本轮补齐**（分 7 组） |
| C3P-04 | P2 | `README.md` / `DOC.md` / 矩阵 | **`Aes256GcmCipher` 零文档**：`rhop/rhop_js.mbt` 的公开密码学类型（js-only，AES-256-GCM + PBKDF2-100000），三份文档均未提及，也未标目标可用性 | **本轮补进 DOC + README 能力表** |
| C3P-05 | P2 | `DOC.md` 常量表、`README.md` 安全说明 | 常量表缺 `MAX_ENVELOPE_NESTING_DEPTH`、`NPU_UNKNOWN_SERIAL`；安全说明未写 UNKNOWN_NPU 兜底（与 C3P-01 同源） | **本轮修** |
| C3P-06 | P3 | 矩阵标题/版本行 | 标题仍写「Batch A/B 已核，Batch C/D 计划」，版本行数字（rhop_task 99 / js 765）已被 C2/C3 实测超过（101 / 819+），与正文 v4 自相矛盾 | **本轮修**（改标题 + 版本快照） |
| C3P-07 | P3 | 矩阵 §2 signer 三行、§6 | signer 行未登记 `UNKNOWN_NPU` 兜底；§6 有意增量未收录 `NPU_UNKNOWN_SERIAL`（新增常量）与 `Aes256GcmCipher`（既有 js 密码学实现） | **本轮修** |
| C3P-08 | P3 | `rhop/signer.mbt:93` | 代码注释引用失效：写「见矩阵 §7 差异 17」，而 §7 行 17 是「字段类型严格度」，**不存在 signer 差异行** | **本轮修**（补 §7 行 + 改注释指向） |
| C3P-09 | P3 | `DOC.md`「基础设施原语」小节、`Aes256GcmCipher` | **目标可用性标注缺失**：该小节全部符号来自 `rhop_js.mbt`（仅 js），但小节与逐条都未标 `js`；`Aes256GcmCipher` 同样 | **本轮修** |
| C3P-10 | — | 契约 §3 / DOC 签名 / README 覆盖面 | **已核实无缺陷**：契约 §3 抽样 18 个 API 全部存在；DOC 中 `pub fn` 签名与 mbti **参数个数 0 处不一致**；README 未提及 381 个符号属摘要层预期（唯一行为性陈旧 = C3P-01） | 记录 |

---

## 1. C3P-01（P1）signer 行为陈述与实现相反

**代码事实**（`rhop/signer.mbt`，C1 PROTO-06 修复后）：
```moonbit
pub const NPU_UNKNOWN_SERIAL : String = "UNKNOWN_NPU"
fn NPUSigner::resolved_serial(self) -> String {   // provider None ⇒ 兜底
  match (self.serial_provider)() { Some(s) => s, None => NPU_UNKNOWN_SERIAL }
}
pub impl AbstractSigner for NPUSigner with fn sign(self, task_id, result) {
  Some(self.marker + ":" + self.resolved_serial() + ":" + md5_hex_of_utf8(...))  // 恒 Some
}
```
`signer.mbt:88-93` 的 docstring 也明确：「`NPUSigner::sign` **恒不为 `None`**；vools 在『工具不存在』时返回 `None` 的分支无法在本抽象中表达（见矩阵 §7）」。
`has_serial()` 的语义是「provider 是否给了**真实**序列号」，**不是**「能否签名」。

**文档事实（陈旧）**：

| 位置 | 现文 | 应为 |
|---|---|---|
| `README.md:366` | 「序列号由注入的 `serial_provider` 提供，**缺失时 `sign()` 返回 `None`**（不伪造签名）」 | 缺失时用 `UNKNOWN_NPU` 兜底签名；**永不返回 None** |
| `DOC.md:748` | 「缺省 `None` ⇒ `sign()` 返回 `None`」 | 同上；并说明 `has_serial()` 只表示真实序列号 |
| 矩阵 `§2` 106/107 行 | 「默认 provider ⇒ `None`」「无法签名时恒 `false`」 | 默认 ⇒ `UNKNOWN_NPU` 兜底；`verify` 恒与 `sign` 结果比对（永远有期望值） |

**证据（测试）**：`test-suit/rhop/signer_test.mbt:141`「NPUSigner 默认 provider → UNKNOWN_NPU 兜底」断言 `sign` 为 `Some("NPU_MARKER:UNKNOWN_NPU:…")`；`:199` 断言 provider 显式 `None` 仍得 `M:UNKNOWN_NPU:`；`:160` 断言 `NPU_UNKNOWN_SERIAL == "UNKNOWN_NPU"`。三目标全绿。

**影响**：使用方若按 README/DOC 判断「无 NPU 时不会有签名」，会在真实场景收到 `UNKNOWN_NPU` 签名而误以为伪造；`has_serial()` 也容易被误用为签名可行性判断。
**修法**：三处文档改写为「`UNKNOWN_NPU` 兜底 + 永不 None + has_serial 语义」；README 安全说明同步（不伪造硬件序列号，只如实标注）。
**回归**：文档级（无代码改动）。测试已覆盖该行为。

---

## 2. C3P-02（P2）`rhop/pkg.generated.mbti` 陈旧

**证据**（源码 ↔ mbti 差集）：
```text
源码有 / mbti 无：Aes256GcmCipher, Aes256GcmCipher::new, Aes256GcmCipher.RhopCipher（impl）
```
`Aes256GcmCipher` 定义在 `rhop/rhop_js.mbt:12`（`pub struct Aes256GcmCipher { password : String }`，实现 `RhopCipher`，alg `"aes-256-gcm"`）；`moon.pkg` 的 `targets` 把它限定在 js 目标。mbti 最后生成于 14:37，但该类型此前已存在 ⇒ 说明 `moon info` 未覆盖（或该文件 targets 导致导出面记录滞后）。
**影响**：以 mbti 为唯一事实源的消费方（IDE 补全、外部文档生成、qa 的 API 对照脚本）看不到该类型。
**修法**：由 Lead 在终验统一 `moon info` 后复核 mbti diff（**本域不单独跑**：并行 lane 正在改代码，单独跑会把他人未落定的公开面写进生成物）。
**备注**：`rhop_task/pkg.generated.mbti` 与源码 **175/175 一致**（无差集）。

---

## 3. C3P-03（P2）DOC.md 缺 41 个公开符号（脚本枚举，逐条已回源码确认）

| 组 | 文件 | 缺失符号 |
|---|---|---|
| A. jump.* 动作族（9） | `rhop/actions.mbt` | `jump_probe` / `jump_push` / `jump_pull` / `jump_sync` / `jump_scan_local` / `jump_collect_files` / `jump_compute_sync_plan` / `jump_should_exclude` / `unregister_action` |
| B. 基础设施（9） | `rhop/rhop_js.mbt` | `rhop_echo` / `rhop_normalize_path` / `rhop_join_checked` / `rhop_db_exec` / `rhop_db_run_changes` / `rhop_default_data_dir` / `rhop_remove_dir_all` / `rhop_temp_workspace` / （`Aes256GcmCipher` 见 C3P-04） |
| C. P2 工具/记录 helper（8） | `rhop_task/task_models.mbt` | `task_state_all` / `task_columns` / `task_record_to_json_text` / `format_epoch_seconds` / `topo_order` / `validate_dag` / `TaskState::is_valid` / `TaskState::status_roundtrip_exact` |
| D. P2 配置/密文 helper（7） | `rhop_task/task_config.mbt`、`task_secrets.mbt` | `TaskConfig::role_long` / `TaskConfig::role_short` / `TaskRole::short` / `cipher_suffix` / `plain_suffix` / `secret_enc_command` / `secret_node_keys` / `default_skip_paths` / `command_hint` / `plaintext_message` |
| E. 业务/会话补充（4） | `rhop/session.mbt`、`mirror.mbt`、`requester.mbt` | `Session::remove_package` / `safe_filename` / `MirrorDB::try_get_task` / `MirrorDB::try_list_tasks` / `MirrorDB::try_count_by_status` / `validate_task_id` / `rhop_shared_local_root` |
| F. 常量（2） | `rhop/signer.mbt` | `NPU_UNKNOWN_SERIAL`（见 C3P-05）、`MAX_ENVELOPE_NESTING_DEPTH`（DOC 正文有提及，但常量表未列） |

> 计数口径：脚本「DOC 未提及」41 项 = A(9) + B(9) + C(8) + D(10) + E(7) + 常量 2，去重后 41（与脚本输出一致）。
**修法**：在 DOC.md 对应文件小节补齐签名 + 一句语义 + 目标可用性；P2 的 helper 归入「P2 章节」。
**裁决**：本轮修（纯文档）。

---

## 4. C3P-04（P2）`Aes256GcmCipher` 零文档 + 未标 js-only

**源码**：`rhop/rhop_js.mbt:12-25`
```moonbit
/// AES-256-GCM 信封密码学（js 目标，node crypto）
/// 密钥由密码 + 固定盐经 PBKDF2-SHA256(100000) 派生；每次加密随机 12B IV。
/// token 格式：base64(iv) : base64(tag) : base64(ciphertext)
pub struct Aes256GcmCipher { password : String }
pub fn Aes256GcmCipher::new(password : String) -> Aes256GcmCipher
pub impl RhopCipher for Aes256GcmCipher   // alg_name = "aes-256-gcm"
```
三份文档（README/DOC/矩阵）**零提及**；它是 `RhopCipher` 抽象的两个内置实现之一（另一个 `RhopCipherNone` 有文档）。
**影响**：使用方不知道除 Fernet（`RhopCrypto`）外还有 AES-256-GCM 选项；也容易误以为只有 js 才有 Fernet。
**修法**：DOC 基础设施/密码学小节补类型 + 目标（js）+ 与 `RhopCrypto`（Fernet）的关系；README 能力表「密码学」行加一句。
**注意**：它**不是** vools 对照面（vools 只有 Fernet），故矩阵不占 vools 符号额度，归「既有/项目内实现」。

---

## 5. C3P-05（P2）常量表与安全说明缺项

`DOC.md` 顶部常量表现有：`CLIP_FILE` / `ENV_RHOP_KEY` / `SECRET_PREFIX` / `NPU_MARKER_DEFAULT` / `SHA256_*` / `MD5_DIGEST_SIZE` / `SYNC_MANIFEST_NAME`。
缺：`NPU_UNKNOWN_SERIAL`（`"UNKNOWN_NPU"`，C1 新增）、`MAX_ENVELOPE_NESTING_DEPTH`（`1000`，C2 新增）。
`README.md` 安全说明缺「UNKNOWN_NPU 兜底 ≠ 伪造」一句（与 C3P-01 同源）。
**修法**：常量表补 2 行；README 安全说明改写 NPU 条目。

---

## 6. C3P-06（P3）矩阵标题与版本行陈旧

- 标题：`# vools-rhop 0.9.0 → rx-mbt/rhop API 对照矩阵（Batch A/B 已核，Batch C/D 计划）` —— C/D 早已落地（§4/§5 已是实测表）。
- 版本行：写「rhop_task js 99、全模块 js 765」；C2/C3 实测已到 **101 / 819+**。
**修法**：标题改「全量落地（A–D + clipboard + P2）」；版本行改为 C3 快照并注明「并行 lane 追加中，以 `scripts/test_all.sh` 为准」。

---

## 7. C3P-07（P3）矩阵 §2 signer 行 / §6 增量未登记新语义

- §2 三行仍写旧语义（见 C3P-01 表）；未列 `NPU_UNKNOWN_SERIAL`。
- §6「有意增量」未收录 `NPU_UNKNOWN_SERIAL`（vools 无此常量，是我们把 vools 的字面量提为常量）。
**修法**：§2 signer 行改写 + §6 增一行。

---

## 8. C3P-08（P3）代码注释引用失效

`rhop/signer.mbt:93`：「见矩阵 §7 差异 17」；矩阵 §7 行 17 实为「信封字段类型严格度」。
**修法**：§7 补一条 signer 差异（编号 22），并把注释改为指向该条。

---

## 9. C3P-09（P3）目标可用性标注缺失

`DOC.md`「基础设施原语（rhop_js.mbt 导出，供上层复用）」小节列了 `rhop_fs_*` / `rhop_db_*` / `rhop_now_iso` / `uri_encode` 等，但**未标注这些符号仅 js 目标可用**（源码在 `rhop_js.mbt`，其 `moon.pkg` targets 限定 js；非 js 目标这些符号不存在）。同理 `Aes256GcmCipher`。
**修法**：小节标题与正文加「仅 js 目标」；逐条不再重复标注。

---

## 10. C3P-10 已核实无缺陷（本轮不必修）

1. **契约 §3 抽查 18 个 API 全部存在**（`Side::parse` / `compute_checksum` / `with_hops_seen` / `load_key` / `pbkdf2_hmac_sha256` / `make_shared_path` / `parse_endpoint` / `select_transport` / `RelayChannel` / `Role` / `build_session` / `handle_request` / `omega_unwrap` / `claim_task` / `pending_sync` / `report_failure` / `sync_once` / `run_forever`）。
2. **DOC 签名 vs mbti：参数个数 0 处不一致**（脚本比对 `pub fn X(...) -> T` 共 200+ 条）。
3. **README 未提及 381 个符号**：摘要层预期行为（README 只列关键 API），不记为缺陷；唯一行为性陈旧是 C3P-01。
4. **文档提及但代码「无」的 29 个 `X::Y`**：经核查均为（a）rx 包符号（`Itor::*` / `Node::*` / `Subscription::dispose` 等，非 rhop 面）或（b）**trait 方法经 impl 提供**（`GitChannel::available` / `RelayChannel::send` / `SftpChannel::receive` / `SharedPath::available` 等，mbti 以 `pub impl` 记录，符号实际存在）或（c）通配写法 `Executor::from_*`。**无真实 doc-only**。

---

## 11. 审计脚本（可复跑）

```bash
mkdir -p /e/tmp/c3audit && cd /e/tmp/c3audit
# audit2.py：mbti↔源码↔四份文档 三方对照（trait 方法 / 签名参数个数 / 覆盖缺口）
# sigs.py  ：对未覆盖符号抽取 mbti 精确签名
python audit2.py   # 输出 COUNTS + A(未提及) + B(doc-only) + C(签名不一致)
python sigs.py     # 输出 FOUND/MISSING + 签名行
```

> 说明：脚本路径为一次性副本（`/e/tmp/c3audit`），不进仓；判定规则写在脚本注释里（trait 方法按 `Trait::method` 计；impl 按 `Type::Trait` 计；文档末提及判定支持反引号内任意文本）。
