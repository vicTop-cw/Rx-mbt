# PLAN-rhop-native-fs —— rhop/monitor 的 native 文件系统能力补齐

> 日期：2026-11-14 ｜ 状态：**M1 完成（C stub + fs 原语 + monitor），M2 完成（rhop_native 落地），M3 完成**
> 上游依赖关系：本计划是 FIST-Mbt 4pools 跨机池（M2）的**硬前置**——跨机池走共享目录交换，
> native 消费端没有文件系统能力就建了也空转（R96 定案原文的「阻塞点」）。
> 计划写作时实测锚点：`rhop/rhop_native.mbt` 47 行 stub、`monitor/watcher_native.mbt`
> Unsupported 占位、`rhop/rhop_js.mbt` 210 行完整实现、moon.mod version=0.4.1。

---

## ⚠️ 给实现 agent 的第一条指令

**开始实现前：先用 Skill 工具加载 `moonbit-c-binding` 技能**（本地仓库
`E:\IDEProjects\moonbit-skills\skills\moonbit-c-binding\SKILL.md`），它提供 FFI 声明、
`#borrow`/`#owned` 所有权注解、C stub 写法（`moonbit.h` / `MOONBIT_FFI_EXPORT`）、
MoonBit UTF-16 ↔ C UTF-8 字符串转换、AddressSanitizer 验证的完整工作流。
`make-moonbit-c-bindings` 技能（同仓库）在需要 vendoring/包配置细节时按需加载。

## 0. 环境前置自检（第一步就做，不通过则停下报 owner）

MoonBit native 后端链接 C stub 需要本机 C 编译器。先验证：

```
cd E:/IDEProjects/AI/rx-mbt
moon run --target native cmd/main        # 或任一最小可运行入口
```

- 若报缺 C 编译器：装 MSVC Build Tools 或 mingw-w64（`gcc` 进 PATH）后重试。
- 自检不过 = 路径 2（自写 C FFI）在本机不可行，**停下回报，不许改走其他路径**。

## 1. 背景与现状（为什么缺）

两个包的 native 目标全是占位，根因相同：MoonBit core 无文件系统 API。

| 文件 | 现状 | js 对照 |
|---|---|---|
| `rhop/rhop_native.mbt`（47 行） | `rhop_send` 只 println 不落盘；`from_filesystem[_with]` 返回立即 on_error 的 Observable | `rhop_js.mbt`（210 行）：node fs 原子写 + fs.watch 监控 + node crypto AES-GCM |
| `monitor/watcher_native.mbt` | `watch_file`/`watch_folder` 返回 `Unsupported` 错误流 | `watcher_js.mbt`：node fs.watch 事件驱动 |

已预留的扩展点（`watcher_native.mbt` 头注释原文）：
「native polling（C FFI readdir + 快照 diff）……直接替换本文件实现即可，**公共 API 签名不变**」。
本计划即按此路线执行。

## 2. 目标与非目标

**目标**
1. native 目标下 `rhop_send` 真实原子落盘、`from_filesystem[_with]` 真实产出消息流。
2. native 目标下 `monitor.watch_folder` / `watch_file` 真实产出 `WatchEvent` 流。
3. 公共 API 签名零变更（`.mbti` diff 只允许新增，不允许改签名）。
4. Windows 本机全绿；Linux/macOS 由 CI 或如实标注「本机不可测」。

**非目标（本轮明确不做）**
- native AES-GCM（不引入 OpenSSL/mbedTLS；native 用既有 `RhopCipherNone` 纯 base64，`alg_name()` 已正确返回 "none"）。
- 事件驱动监控（inotify / ReadDirectoryChangesW）——统一轮询快照 diff，够用且跨平台一致。
- wasm 目标（`moon.mod` preferred_target=wasm，但 rhop/monitor 均按文件级 target 门控，wasm 不在范围）。
- 抽取 js/native 共用的 envelope 解码核心为公共文件（可做的重构，但**先直写复刻**，重构另行评估，见 M3）。

## 3. 技术方案

### 3.1 FFI 面（新增 C stub，落 `monitor/` 包）

新增 `monitor/fs_native_stubs.c`（+ 按技能规范配 `moonbit.h`），在 `monitor/moon.pkg`
登记 `native-stub`（js 目标不受影响——stub 只参与 native 链接）。最小函数集：

| C 函数 | 语义 | 平台要点 |
|---|---|---|
| `fs_read_text(path) -> String/err` | 读 UTF-8 文本 | Windows 用 `_wopen`/宽字符 API，路径 UTF-16 转换走技能提供的 helper |
| `fs_write_atomic(path, content)` | 写 tmp + rename 原子写 | POSIX `rename()` 原子覆盖；Windows 必须 `MoveFileExW(MOVEFILE_REPLACE_EXISTING)`（裸 rename 不覆盖已存在目标） |
| `fs_list_rhop(dir) -> String[]` | 列目录下 `*.rhop`（排除 `.rhop.tmp`） | POSIX `opendir/readdir`；Windows `FindFirstFileW/FindNextFileW` |
| `fs_stat(path) -> (mtime_ns, size)` | 快照指纹 | POSIX `stat`；Windows `GetFileAttributesExW`；不存在返回约定错误码 |

错误上报对齐 rhop_js 的既有约定风格：失败返回约定空值/错误码 + 错误槽（具体形态按技能的
ownership/错误处理章节定，写进实现注释）。

### 3.2 MoonBit 侧分层

- `monitor/fs_native.mbt`（新，targets 门控 `[native]`）：`extern "c"` 声明 + MoonBit 包装
  （路径归一化、错误包装），给本包 watcher 和 rhop 包共同消费。
- `monitor/watcher_native.mbt`（替换实现，签名不变）：轮询快照 diff——
  快照 = `Map<path, (mtime, size)>`；每个轮询间隔重扫目录，diff 出
  `Created/Modified/Removed`；`watch_file` = 单文件版同一套快照逻辑。
- `rhop/rhop_native.mbt`（替换实现，签名不变）：
  - `rhop_send` = `cipher.encrypt` → `RhopEnvelope::encode` → `fs_write_atomic`（与 js 版 1:1 对齐，含 `join_path`）；
  - `from_filesystem_with` = 复刻 js 版全流程（skip_existing 种子 / seen 集合 / `.rhop.tmp` 过滤 /
    envelope v=1 校验 / decrypt / from_json_text），仅把 node FFI 换成 `monitor.fs_native`。

### 3.3 轮询语义（必须写进实现文档）

native 的 `subscribe` 内是**同步阻塞轮询循环**（js 是事件驱动立即返回）——这是记录在案的
语义差异，不是缺陷：rhop 消费方本来就是独立线程/进程主循环（fist-mbt serve）。轮询间隔
默认 1000ms，提供编译期可调常量（不放公共 API 签名上）。

## 4. 里程碑（每步独立可验收，逐步提交）

### M1 —— C stub + fs 原语 + monitor.watch_folder/watch_file 落地
- 改动面：`monitor/fs_native_stubs.c`、`monitor/fs_native.mbt`、`monitor/watcher_native.mbt`、
  `monitor/moon.pkg`（native-stub 登记）、`monitor/pkg.generated.mbti`（moon info 产物）。
- 测试：`monitor/fs_native_wbtest.mbt`（native 目标真跑：读/原子写/列目录/stat 四原语 +
  原子写覆盖已存在文件 + tmp 排除）；`watcher_native` 的 Created/Modified/Removed 三事件
  快照 diff 测试（真实临时目录，非 mock）。
- 验收门禁：`moon check`（js+native 双目标 0 errors）、`moon test --target js`（全绿无回归）、
  `moon test --target native`（全绿）、`moon fmt && moon info`（.mbti diff 仅新增）。

### M2 —— rhop_native 落地（发送 + 接收全链路）
- 改动面：`rhop/rhop_native.mbt`、`rhop/pkg.generated.mbti`；rhop 的 moon.pkg 按需加 import。
- 测试：`rhop/rhop_native_wbtest.mbt`：native 端到端（send → from_filesystem 收到同一条，
  含 skip_existing=true 不重放 / 坏文件跳过不中断 / `.rhop.tmp` 不消费三格）；
  js 目标同电池跑一遍保证两目标行为对齐。
- 验收门禁：同 M1 全套 + **js/native 双目标同一测试电池行为一致**。

### M3 —— 收口
- `demo/` 或 `cmd/` 下若有 rhop 示例，native 目标真跑一遍冒烟。
- 更新 `DOC.md` / `README.mbt.md` 中「native 不可用」相关表述（如有）。
- 回写本计划状态行 + 实测读数；提交历史按 M1/M2/M3 分批，每批消息含门禁读数。

## 5. 风险与已知边界

| 风险 | 处置 |
|---|---|
| 本机无 C 编译器 | §0 前置自检先行，不过即停 |
| Windows rename 不覆盖已存在文件 | 必须 `MoveFileExW` + `MOVEFILE_REPLACE_EXISTING`（最易踩的坑，测试锁死） |
| Windows 文件名 UTF-16 vs MoonBit String UTF-16 | 天然对齐但转换 helper 必须走技能规范，防 UTF-8 中转丢字 |
| 轮询与写入竞态（读到半写文件） | 原子写（tmp+rename）保证读方只见完整文件；`.rhop.tmp` 过滤双保险（js 版已有，native 复刻） |
| 轮询间隔内同文件多次改写 | 快照 diff 只报最后一次状态（Modified 去重），与 js 事件流允许有差异，写进语义文档 |
| Linux/macOS 无法本机验证 | POSIX 路径按标准写 + CI/WSL 复测；不可测则如实标注，不许假绿 |

## 6. 范围纪律（给实现 agent）

- 只动 `monitor/`、`rhop/`、`cmd/`、`demo/` 及本计划文件；不碰 `fist-mbt*`、`memory/`、
  `backup/`、`test-suit/` 等无关面。
- 每个里程碑独立提交；提交前门禁全套跑绿；读数写进提交消息。
- 任何「本机不可测」如实标注；状态声明必须等于代码实测。
