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
