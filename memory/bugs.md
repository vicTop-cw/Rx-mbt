## 记账规则（沿用 FIST-Mbt 口径：抬头状态位 + 叙述面只追加）

- **抬头文法**：`## BUG-n [ISO 时间] [critical|high|medium|low] 状态 [→BUG-m]`；
  状态闭集 = `OPEN` / `FIXED` / `DUPLICATE` / `FALSE_POSITIVE`。
- **FIXED 必须有小记点名**：`### FIXED(<日期 轮次> / BUG-a, BUG-b …)` 写清改了哪个真源、哪条锁钉住。
- **叙述面只追加**：条目正文 / 小记 / 报告一律只追加，不改历史。
- **判据不许自证**：状态只从抬头反解，不数小记条数。

---

## BUG-1 [2026-10-30T04:30:00Z] [high] FIXED
- summary: rhop js · `from_filesystem_with(skip_existing=true)` 在 Windows 上不生效 —— `seen` 集合的路径键分隔符口径不一致，订阅前已存在的 `.rhop` 会被重放
- detail:

  **现象**：`skip_existing=true` 时，订阅前目录里已存在的 `.rhop` 信封仍被投递（重放历史信号）。

  **定位**：`rhop/rhop_js.mbt` 里 `seen` 集合的两个来源用了不同分隔符口径：

  - 订阅时种子：`ffi_list_files`（L176）用 node `path.resolve(dir, n)`，Windows 下产出**反斜杠**绝对路径；
  - 运行期事件：`@monitor.watch_folder` → `monitor/watcher_js.mbt:48 join_path` 产出**正斜杠**路径
    （本例为 `C:\...\dir/old-1.rhop` 这种混合形态，因为传入的 `dir` 是 `mkdtemp` 的原始 Windows 路径）。

  两者直接 `contains` 比对必然不等 ⇒ 已存在项被当成新项重放。

  **最小复现**（纯 node，不依赖 MoonBit）：
  ```
  dir = mkdtemp(os.tmpdir())                                  # Windows: C:\Users\...\Temp\rhop-entry-skip-XXXX
  ffi_list_files   = path.resolve(dir, 'old-1.rhop')         # "C:\...\rhop-entry-skip-XXXX\old-1.rhop"   反斜杠
  watch ev.path    = join_path(dir, 'old-1.rhop')            # "C:\...\rhop-entry-skip-XXXX/old-1.rhop"  正斜杠
  seen.contains(ev.path) = false  ⇒ 重放
  ```

  **为什么是 Windows-only**：Linux/WSL 下 `resolve` 与 `join_path` 都产出 `/`，键能对上 ⇒ 测试会绿。
  ⇒ **「WSL 绿不能代表 Windows 绿」的又一实例**（与 BUG-9 / C2 报告 Q1 同族）。

  **影响面**：fist-mbt 的 `src/ops/ops_commissar.mbt:215` 正走这个入口且传 `skip_existing=true`
  ⇒ Windows 上政委 watch 会重放历史信号。

  **反证（证明病灶在 `ffi_list_files` 而非测试）**：`RhopWatcher::skip_existing`（`rhop/watch.mbt:313-323`）
  用 `join_shared(dir, name)`（`transport_local.mbt:106`，内部已 `normalize_path`）预填 `seen`，
  所以它自己的 skip_existing 用例是绿的 —— 只有 `from_filesystem_with` 这一支不一致。

- evidence:
  - 回归锚：`test-suit/rhop/rhop_entry_points_test.mbt:191`（`rhop-entry · from_filesystem_with(skip_existing=true) 不重放已存在项`）。
    修前 `Total tests: 172, passed: 171, failed: 1`，唯一红就是这格；修后 `172 / 172 / 0`；全仓 `860 / 860 / 0`。
  - 反变异：把 `seen_key` 退化为 identity（回到原始比较口径）⇒ 同一格**必须重红**（实测 `171 / 1`）；还原后复绿。
  - 平台对照：Linux 下不触发（分隔符口径天然一致）。
- reported_by: lead（FIST-Mbt T0r4 · rx-mbt 仓）

### FIXED(2026-10-30T04:30:00Z / BUG-1)

**修法**：不在两个生产端各改一套，而在 `seen` 集合的**比较边界**统一归一化 ——
新增私有 `fn seen_key(path) = normalize_path(path)`（复用同包既有工具 `transport_local.mbt:76 normalize_path`，
把 `\`→`/`、折叠重复斜杠、去尾斜杠），在三处过一遍：事件处理的 `contains` / `add`、
`seed_seen_from_listing` 的 `add`。这样无论 `shared_path` 本身是 `/` 还是 `\` 形态、无论哪个来源产的路径，
落进 `seen` 的键都同口径。

**改动面**：仅 `rhop/rhop_js.mbt`（+16 / −3），未碰 `moon.mod`、`rhop/moon.pkg`、其它包；
`seen_key` 是 private，`.mbti` 对外接口零变化。

**与既有实现对齐**：`RhopWatcher::skip_existing` 的种子侧已用 `join_shared`（内部 `normalize_path`），
本次把 `from_filesystem_with` 的种子侧与事件侧也统一到同一条 `normalize_path` 口径，两条实现路径从此一致。

**未修的同族隐患（另立单）**：`rhop/watch.mbt` 的 `handle_event` 把未归一化的 `ev.path` 直接喂
`process_file` / `seen` 比对，而种子侧用 `join_shared` 产 `/` 键；现有 skip_existing 用例只走
`process_file(join_shared(...))` 的同步路径，没触发事件分支，故未暴露。根治建议：`handle_event` 前做
`normalize_path`（或让 `RhopWatcher::new` 归一化 `path`）。
另：`join_path` 对「根以 `\` 结尾」的分支仍返回反斜杠（其注释声称统一 `/`），属既有缺陷，本次以边界归一化规避、未触碰。

## BUG-2 [2026-11-21T01:00:00Z] [high] FIXED
- summary: rhop watch  RhopWatcher 事件侧 seen 键口径失配 —— `handle_event` 喂未归一化 `ev.path`，Windows 混合分隔符路径下 skip_existing=true 重放订阅前已存在项（BUG-1 同族，BUG-1 小记 :64-67 点名的「另立单」项）
- detail:

  **现象**：BUG-1 只根治了 `from_filesystem_with`（rhop_js.mbt）那条实现路径；
  `RhopWatcher`（watch.mbt）这条路径的事件侧仍在裸比较——`process_file` 的
  `seen.contains(path)` / `seen.add(path)` 用原始路径，而种子侧 `seed_seen` 用
  `join_shared`（内部 normalize_path）产 `/` 键。Windows 下监控根以反斜杠传入时
  （mkdtemp / 常见 Win32 目录句柄均为反斜杠形态），事件路径为 `C:\dir/old-1.rhop`
  混合形态，种子键为 `C:/dir/old-1.rhop` —— 比对必然失配 ⇒ skip_existing=true
  时订阅前已存在的 `.rhop` 被重放。

  **未暴露原因**：现有 skip_existing 用例只走 `process_file(join_shared(...))`
  的同步路径，未触发事件分支。

- evidence:
  - 回归锚：`rhop/rhop_js_wbtest.mbt`「RhopWatcher 事件侧：混合分隔符路径不重放已存在项」（种子 1 键 → 事件（混合形态）→ seen 仍 1、bad=0；正向对照新文件入账 seen=2）。
  - 全仓 js 门 893/893/0（2026-11-21；修复前该用例必红）。
  - Linux 不触发（分隔符天然一致），Windows 必触发。

- reported_by: 助手（BUG-1 小记点名 + 「bug 优先」盘点）

### FIXED(2026-11-21 / BUG-2)

**修法（边界归一化，不动构造侧）**：`handle_event` 在喂 `process_file` 前先
`normalize_path(ev.path)`（复用同包 `transport_local.mbt` pub 工具），与种子侧
`join_shared` 的 `/` 键同口径；`process_file` 本体不动（同步入口语义保持「按调用方
给的路径处理」）。刻意不选 `RhopWatcher::new` 构造侧归一化：构造侧只管根、管不住
上游拼接的事件路径，边界归一化一处覆盖所有事件来源。

**种子键真源连带根治**：`join_shared`（transport_local.mbt）此前只归一化 filename、
root 原样拼接——根以 `\` 结尾时种子键本身产出 `C:\dir\/x` 的 `\/` 混合形态（即使
事件侧归一化也对不上）。现 root 先过 `normalize_path`，任何根形态都产 `/` 拼接结果。

**改动面**：`rhop/watch.mbt`（handle_event 边界）、`rhop/transport_local.mbt`
（join_shared root）；未碰 moon.mod / moon.pkg / `.mbti` 对外接口。

## BUG-3 [2026-11-21T01:00:00Z] [medium] FIXED
- summary: 路径拼接  join_path 根尾反斜杠分支原样产出反斜杠路径（三处实现：rhop_js / rhop_native / monitor watcher_js）＋ rhop_native seen_key 的 `replace(old="\\",new="/")` 只换首个反斜杠，多段 Windows 路径漏归一化
- detail:

  **现象**：三处 `join_path` 注释均声称「统一 `/` 分隔」，但「根以 `\` 结尾」分支
  `root + fname` 原样拼出反斜杠路径（`C:\dir\` + `x.rhop` → `C:\dir\x.rhop`），
  与下游 seen 键比对口径相悖（BUG-1 修复时以 seen 边界归一化规避、未触碰本缺陷，
  BUG-1 小记 :68 有载）。

  **连带**：rhop_native 的 `seen_key` 用 `path.replace(old="\\", new="/")` ——
  replace 只换**首个**反斜杠，多段 Windows 路径（`C:\a\b\x.rhop`）漏归一化为
  `C:/a\b\x.rhop`，与 js 侧 seen_key（normalize_path）口径不一致。

- evidence:
  - 回归锚：`monitor/watcher_js_wbtest.mbt`（join_path 六形态 + normalize_root）、
    `rhop/rhop_js_wbtest.mbt`（join_path + join_shared 根尾反斜杠）、
    `rhop/rhop_native_wbtest.mbt`（native join_path + seen_key 多段反斜杠）。
  - js 门 893/893/0、native 门见 BUG-4 小记读数（2026-11-21）。

- reported_by: 助手（BUG-1 小记点名 + 盘点）

### FIXED(2026-11-21 / BUG-3)

**修法**：三处 `join_path` 统一改「根先归一化再拼接」（normalize_path(root) → 尾
`/` 判定 → 拼 `/` + fname），任何根形态（`C:\dir\` / `C:/dir/` / `C:/dir` /
`C:\dir` / `/`）都产出 `/` 拼接结果。monitor 不依赖 rhop 包，新增本地
`normalize_root`（与 transport_local normalize_path 同口径本地实现）；fname 为空时
事件路径 = 监控根本身，同样归一化（watcher_js 事件下发点兜底）。
rhop_native `seen_key` 弃 replace 改 `normalize_path`，与 js 侧同口径。

**改动面**：`rhop/rhop_js.mbt`、`rhop/rhop_native.mbt`（join_path + seen_key）、
`monitor/watcher_js.mbt`（normalize_root + join_path + 事件路径兜底）；
`monitor/moon.pkg`、`rhop/moon.pkg` 各挂一条 wbtest 目标门控。

## BUG-4 [2026-11-21T01:00:00Z] [low] FIXED
- summary: test-suit/_q3only k4「gcm_tag 分步中间量」诊断残留恒红 —— 测试侧带病：fa 构造 1:1 拷贝了旧 gcm_tag 的 32 位 Int 移位 mod 32 回绕缺陷 + 末尾 fail() 自述「诊断完删除」未删；native GHASH 实现无罪
- detail:

  **现象**：native 全量门 666/667，唯一红点 k4：step4 断言 ghash 中间量
  `b79be1f1... != c83f1287...`。

  **诊断（node 独立 GHASH 参考实现对拍，temp/ghash_ref.js）**：
  ① 正确布局（ct16 ‖ len 块 0^15‖0x80）ghash = c83f1287（= 测试常量 = k3 直调锚点）；
  ② k4 实际喂入的坏布局（`bits >> (8*(7-k))` 移位回绕使 fa[27] 误写 0x80，len 块双
  0x80）ghash = b79be1f1 —— **与 native 输出逐位一致**。
  ⇒ native @rp.ghash 对坏输入算出了正确答案，实现无罪，测试带病。

  **病理**：k4 是 2026-11-19 GCM 修复轮（d2198d8）的诊断测试，1:1 拷贝当时 gcm_tag
  内部逻辑——连同当时尚未修的移位回绕缺陷一并拷入；同轮 gcm_tag 已修（改移位链推
  长度块，见 cipher_gcm.mbt :407 注释），k4 未同步且末尾 fail()（自述「诊断完删除」）
  残留。k3 已用正确布局覆盖 ghash 直调多块回归锚。

- evidence:
  - node 参考对拍：正确布局 c83f1287 / 坏布局 b79be1f1，坏布局 == native 实际输出。
  - 数学闭环：authoritative tag(38626429…) ⊕ E(J0)(f05d76ae…) = c83f1287，坏布局
    中间量若为真则 k2/k3 终值锚不可能绿。
  - 修后 q3only 6/6、全量 native 门 667/667/0、js 门 893/893/0（2026-11-21）。

- reported_by: 助手（「bug 优先」盘点，native 全量门红点）

### FIXED(2026-11-21 / BUG-4)

**修法（测试侧三处，实现零改动）**：① fa 构造弃 `bits >> (8*(7-k))` 移位循环，
改 `fa[cp+15] = 0x80` 直写（与 k3 直调布局同形，根除回绕坑）；② 末尾诊断
`fail()` 按其自述转为 `assert_eq(bytes_hex(tag_direct), bytes_hex(tag_manual))`
常驻断言（gcm_tag 直调 == 手工链，补 k3 之外的直调锚）；③ 注释转正说明病理。
实现面（cipher_gcm.mbt）零改动。

**回归锚终态**：k1（kat_v1 GHASH 链）/ k2 / k3（ghash 直调多块）/ k4
（gcm_tag 直调==手工链）四锚全绿；_q3only 保持 native-only 门控。
**注**：`test-suit/_q3only/` 被 .gitignore:71 刻意排除（本地诊断区，git ls-files 为空），
k4 修复仅存本地工作树、不入库；远端克隆不含该目录，native 全量门以本地跑数为准。
