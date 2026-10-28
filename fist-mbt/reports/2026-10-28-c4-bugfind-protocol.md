# C4 寻虫报告 — 协议 / 摘要 / 生成物 / 文档域（端到端 + 生成物卫生 + 安全审计）

> 轮次：C4（单轮：寻虫→修复→打磨→验证→清整），主题：**端到端真实场景 + 集成压力 + 安全审计 + 生成物/工作树卫生**。
> 范围（只读）：`rhop/{core,digest,json_canonical,envelope,signer,integrity}.mbt` + `test-suit/rhop/*` + `test-suit/rhop_vectors/*` + 生成物（`fist-mbt/reports/moonbit_vectors_full.json`、`test-suit/rhop_js/fixtures/moonbit_vectors.json`）+ README/DOC/矩阵。
> 方式：**只读审计**；动态证据 = 两个真实 node 进程（`_build/js/.../rhop_demo.js`）+ 一次性副本 `E:/tmp/c4audit`（探针包，排除 `_build`/`.git` 拷贝）。
> 审计人：impl-core　时间：2026-10-28（UTC+8）
> 结论：**P0 × 0 / P1 × 2 / P2 × 2 / P3 × 3**；两条 P1 本轮均已修（生成物可复现元数据 + 10MB 级 canonical 性能 5–10×）。

---

## 0. 汇总表

| ID | 严重度 | 位置 | 一句话 | 裁决 |
|---|---|---|---|---|
| **C4P-01** | **P1** | `test-suit/rhop_vectors/producer_test.mbt` 产物 + `test-suit/rhop_js/fixtures/moonbit_vectors.json` + `fist-mbt/reports/moonbit_vectors_full.json` | **生成物不可复现且被 tracked**：产物 `crypto` 分节（Fernet 随机 IV + 时间戳）每次运行都变 ⇒ 整个 `moonbit_vectors_full.json` 每次 dirty；`fixtures/moonbit_vectors.json` 被 `fixtures/.gitignore` 声明忽略但**已经 tracked**（ignore 对已跟踪文件无效）⇒ 工作树长期带 2 个 modified | **本轮修**：产物加 `deterministic_sections` / `volatile_sections` / `deterministic_digest` + 确定性回归用例；untrack 由 Lead 执行 |
| **C4P-02** | **P1** | `rhop/json_canonical.mbt` `write_canonical_string` | **10MB 级 payload 端到端被字符串转义拖慢**：旧实现逐码元 `write_char`，实测 10MB payload checksum 3531 ms / 写 3522 ms / 读 3437 ms（≈3.5 s×3） | **本轮修**：改为「普通字符 run 批量 `substring` 写入」；实测 **632 / 366 / 334 ms（5.6× / 9.6× / 10.3×）**，输出逐字节不变 |
| C4P-03 | P2 | 跨进程 envelope 互操作（demo 双进程） | **正向验证通过**：两个真实 node 进程（watch-skip + send）5/5 收齐并解密；**两个 sender 并发写同名** 5 文件全合法 JSON、0 个 `.tmp` 残留（原子写有效）；坏包写入时 watcher **不崩、跳过**继续运行 | 记录（无需修） |
| C4P-04 | P2 | 深嵌套 payload 端到端 | depth **2000 / 5000** 写成功（5–6 ms / 4–10 KB），`from_rhop_bytes` 均 `Err(Depth limit)`（上限 1000，C2P-05 已文档化）⇒ e2e 复现「可写不可读」窗口 | 记录（已文档化，无需修） |
| C4P-05 | P3 | demo/`from_filesystem` 坏包诊断 | 坏 `.rhop` 被静默跳过（不中断、不报错），但**没有任何可观察诊断**（`RhopWatcher::bad_files()` 未接进 demo/日志） | 建议（不改协议）：调用方把 `bad_files()` 打日志 |
| C4P-06 | P3 | README / DOC / 矩阵数字 | 计数随 lane 变动再次漂移（本轮新增 7 条用例；示例：`test-suit/rhop` 163/159/159、`rhop_vectors` 3、全模块随本轮 +7） | 本轮刷新（C3 快照 → C4 快照） |
| C4P-07 | P3 | 审计方法学（负面结论） | 「null 可选字段被拒」是**探针假象**：手写 JSON 键序非规范时 checksum 会被正确拒绝（本项目用 canonical 重算）；用 `canonical_json` 构造 body 后 null/未知字段/noncanon 数字均按设计表现 | 记录（避免后续误报） |

**另外记录（非本域缺陷，供 Lead triage）**：C4 期间 `test_all.sh` 的 js 步曾一次性 FAIL（1187 ms），根因是**他人 lane 正在写的** `test-suit/rhop_js/c4_e2e_test.mbt` 触发 `unused_mut` 并被当作 error（工作树并发编辑的证据）；随后该文件修好即恢复。与 C2/C3 记录的「共享 `_build` 并发」属同类，非产品缺陷。

---

## 1. C4P-01（P1）生成物不可复现 + tracked-but-ignored

### 证据（两次运行逐节 diff）

```text
整体一致: False
  canonical_json: changed=False
  digest:         changed=False
  envelope:       changed=False
  crypto:         changed=True      ← encrypt_json / encrypt_secret 都变
  signer:         changed=False
cases sha256[:16]: 4d8f3e5346503bc6 ≠ 4fb79bfa8df4894d
```

### 两类文件的现状

| 文件 | 写入者 | 是否 tracked | 是否在 .gitignore | 问题 |
|---|---|---|---|---|
| `fist-mbt/reports/moonbit_vectors_full.json` | `test-suit/rhop_vectors`（生产者） | **是**（C3 提交入库） | 否 | 每次跑测试内容都变（crypto 随机）⇒ 工作树恒 dirty |
| `test-suit/rhop_js/fixtures/moonbit_vectors.json` | `test-suit/rhop_js/crypto_test.mbt` | **是** | **是**（`fixtures/.gitignore` 第 4 行） | ignore 对已跟踪文件无效 ⇒ 声明形同虚设，且与 intent 冲突 |

### 影响
- 每次 `moon test --target js` 都会把两个文件改成 modified → 与 C4「工作树干净」硬门冲突；
- 产物被当作 reviewable 内容提交，但其中 crypto 部分是随机密文，diff 噪声大、无语义；
- 新人会误以为 fixture 应入库（ignore 与 tracked 矛盾）。

### 建议修法
1. **代码侧（本轮已做）**：生产者产物增加显式元数据，把「可复现」与「随机」分开，并加回归用例，任何人破坏确定性都会红：

```jsonc
{
  "deterministic_sections": ["canonical_json", "digest", "envelope", "signer"],
  "volatile_sections": ["crypto"],
  "deterministic_digest": "sha256:<hex>",     // 对四节 canonical_json 求 sha256
  ...
}
```
2. **仓库侧（Lead 执行，属 git 操作）**：
   ```bash
   git rm --cached fist-mbt/reports/moonbit_vectors_full.json
   git rm --cached test-suit/rhop_js/fixtures/moonbit_vectors.json
   # 并在 .gitignore 增补：fist-mbt/reports/moonbit_vectors_full.json
   ```
   （`fixtures/.gitignore` 已声明 `moonbit_vectors.json`，untrack 后立即生效。）
3. **可选（更强）**：生产者支持 `--out` 环境变量把产物写到 `_build/`（qa 的 verify_interop 已支持传路径），彻底不碰工作树。

---

## 2. C4P-02（P1）10MB 级 payload：字符串转义逐字符写入是主瓶颈

### 证据（一次性副本 `E:/tmp/c4audit`，js 目标，10MB 纯文本 payload）

```text
修复前  C4A 10MB: checksum=3531ms write=3522ms bytes=10000292 read=3437ms ok=true
        C4B 10x1MB roundtrip: 3924ms
修复后  C4A 10MB: checksum= 632ms write= 366ms bytes=10000292 read= 334ms ok=true
        C4B 10x1MB roundtrip: 904ms
```

### 根因
`write_canonical_string` 旧实现对每个 UTF-16 码元调用一次 `buf.write_char`：10MB 纯文本 = **1000 万次** 方法调用 + 逐字符分支判断；同一个 10MB payload 在 `Envelope::new`（checksum）、`to_rhop_bytes`（再算一次 checksum）、`from_rhop_bytes`（解析后重算）中被重复穿越 3 次 ⇒ 累计 ≈10 s。

### 修法（本轮已做，无 API 变化）
按「需要转义的码元」切分：连续普通字符一次性 `buf.write_string(text.substring(...))`，只有 `"`、反斜杠、控制字符、以及 `ensure_ascii=true` 时的非 ASCII 才走逐字符转义分支。补充：转义按 **UTF-16 码元** 输出，因此 `ensure_ascii=true` 下 emoji 自然拆成 `\ud83d\ude00`（与 Python 代理对写法逐字节一致）。
回归：新增 3 条用例（1MB 纯文本 bulk 路径、run 边界交替转义、两种口径非 ASCII/代理对），并保留全部既有 fixture/escapes 用例 ⇒ 输出字节不变。

---

## 3. C4P-03（P2）跨进程 envelope 互操作（正向基线，已实测）

### 方法
构建 `moon build demo/rhop_demo --target js`（**不在持锁状态下跑长驻进程**——见下方经验），再用 `node _build/js/debug/build/demo/rhop_demo/rhop_demo.js` 直接起两个真实进程。

### 结果

| 场景 | 命令 | 结果 |
|---|---|---|
| 双进程收/发 | `watch-skip <dir> 5` + `send <dir>` | watcher 输出 `received 1..5`、`watch 完成，共收到 5 条`；落盘 5 个 `.rhop` |
| 并发写同名 | 两个 `send <dir>` 同时跑（都写 `msg-0..4.rhop`） | 两个进程各 `send 完成，共 5 条`；目录仍 5 个文件；**5/5 为合法 JSON**（`v/alg/ct` 齐全）；**0 个 `.tmp` 残留** ⇒ tmp+rename 原子写在并发下有效（last-writer-wins，无撕裂） |
| 坏包 | watcher 期间写入被截断的 `broken.rhop` | watcher **未崩溃、未报错**，继续等待；好包正常收；坏文件被静默跳过 |

### 经验（写进本报告，供后续多进程 e2e 复用）
**不要**用 `bash scripts/with_moon_lock.sh moon run <长驻进程>` 起 watcher：它会在整个进程生命周期内持锁，导致其他 moon 命令（含另一进程的 `moon run send`）永久等待 —— 实测触发死锁。正确姿势：**先持锁 `moon build`**，再直接用 `node <构建产物>` 起多个进程（零锁竞争）。

---

## 4. C4P-04（P2）深嵌套端到端复现「可写不可读」窗口

```text
C4C depth=2000: write=5ms bytes=4290 read=Err(Depth limit)
C4C depth=5000: write=6ms bytes=10290 read=Err(Depth limit)
```

与 C2P-05 的文档一致（写侧迭代式无深度上限，读侧 `MAX_ENVELOPE_NESTING_DEPTH = 1000`）。
**结论**：非新缺陷，属已声明的 out-of-contract 行为；本轮补了 e2e 证据（此前只有单侧证据）。

---

## 5. C4P-05（P3）坏包静默跳过缺少可观察诊断

`RhopWatcher::bad_files()` 已实现计数，但 demo 与非 daemon 用法没有把它暴露出来；跨进程实测中「坏包被跳过」只能靠行为推断（进程没崩），没有日志/指标。
**建议**（不改协议、不改 API）：调用方在 `observe()` 流结束时读 `bad_files()` 打点；或 demo 在 `watch completed` 后打印 `bad=\{n}`。

---

## 6. C4P-06（P3）文档数字漂移（本轮刷新）

本轮新增 7 条用例（`test-suit/rhop/json_canonical_test.mbt` +3、`test-suit/rhop_vectors` +1，另 3 条为前两轮已加），分包数字从 C3 的 `rhop 156/160/156` 变为 **`159/163/159`**、`rhop_vectors 3`；全模块同步刷新（见修复报告 §4）。**长期建议**：README 的计数表以「命令 + 快照时间」而不是硬数字为主，减少每轮漂移成本。

---

## 7. C4P-07（P3）探针假象：非规范键序 ≠ 拒绝 null

首版探针里手工拼 `{"error": null, ...}` 但键序非 canonical，导致 `checksum mismatch` 被误读为「null 可选字段被拒」。
用 `@rp.canonical_json` 构造 body 再算 checksum 后：**未知字段 accept、null 可选字段 accept、非规范数字（1.50）accept**（付 payload 按 `preserve_number_repr` 保留原文）。
**结论**：无缺陷；记录该方法学教训（C4D 探针的输出不再作为判据）。

---

## 8. 复现方式

```bash
# ① 生成物确定性（主仓）
bash scripts/with_moon_lock.sh moon test -p test-suit/rhop_vectors --target js
cp fist-mbt/reports/moonbit_vectors_full.json /tmp/run1.json
bash scripts/with_moon_lock.sh moon test -p test-suit/rhop_vectors --target js
# 对比 run1 与当前文件：crypto 变、其余四节不变（且 deterministic_digest 相同）

# ② 跨进程 e2e（主仓，先构建再直起 node）
bash scripts/with_moon_lock.sh moon build demo/rhop_demo --target js
D=_build/js/debug/build/demo/rhop_demo/rhop_demo.js
SH=$(mktemp -d); node $D watch-skip "$SH" 5 > /tmp/w.txt 2>&1 & sleep 3; node $D send "$SH"; sleep 5; cat /tmp/w.txt

# ③ 10MB / 深嵌套探针（一次性副本，避免污染真树）
rm -rf /e/tmp/c4audit && mkdir -p /e/tmp/c4audit
(cd /e/IDEProjects/AI/rx-mbt && tar -cf - --exclude=_build --exclude=.git --exclude=.moon-build.lock .) | tar -xf - -C /e/tmp/c4audit
# 探针包：/e/tmp/c4audit/test-suit/c4audit/{moon.pkg,probe_test.mbt}
cd /e/tmp/c4audit && bash scripts/with_moon_lock.sh moon test -p test-suit/c4audit --target js
```
