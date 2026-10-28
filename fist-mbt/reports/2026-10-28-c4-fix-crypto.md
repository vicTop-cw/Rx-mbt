# C4 修复与验证报告（impl-crypto 域）

- 日期：2026-10-28
- 对应寻虫：`2026-10-28-c4-bugfind-crypto.md`
- 纪律：不改公开 API 签名、不新增业务功能、`moonfmt.exe -w` 格式化、moon 命令尽量走 `scripts/with_moon_lock.sh`
  （**注**：本轮该脚本在含 `...WindowsApps` 的 PATH 下出现 `moon: command not found`（rc=127，脚本第 112 行 `"$@"`），
  故本轮验证改为直接 `moon` 调用 + 独占时段执行；已在本报告如实记录该工具面问题，供 qa/qa-platform 排查脚本 PATH 处理）

## 一、改动清单

| # | 类型 | 文件 | 改动 |
|---|---|---|---|
| 1 | **安全修复（P2）** | `rhop/relay.mbt`（子进程中转脚本） | token 校验由 `!==` 明文比较改为**恒时比较**：`sha256(header)` 与 `sha256(token)` 后 `crypto.timingSafeEqual`。消除"逐字节探测 token 前缀"的时序侧信道。语义不变（错 token 仍 403） |
| 2 | **E2E 用例** | `test-suit/rhop_js/c4_e2e_test.mbt`（新增，+2 用例） | ① relay 跨进程 A→C→B：1MB 载荷 + 双向 + sha256 双向一致 + 错 token 403 + 包名不串；② 6 包并发投递取回校验 |
| 3 | **E2E 用例** | `test-suit/rhop_task/c4_e2e_test.mbt`（新增，+1 用例） | 跨进程可见性：本进程写 → **独立 node 进程** claim（node:sqlite 直连同一产物库）→ 本进程读到 LOCKED + worker_id |
| 4 | **E2E fixture** | `test-suit/rhop_js/fixtures/relay_peer.js`（新增） | 独立进程的 HTTP 客户端（投递/读取/错 token），不依赖产品代码 |
| 5 | **E2E fixture** | `test-suit/rhop_task/fixtures/task_worker.js`（新增） | 独立进程 worker：claim/peek/insert，SQL 语义与产品 `claim_next` 逐句对齐 |
| 6 | **E2E fixture** | `test-suit/rhop_task/fixtures/task_worker_parallel.js`（新增，**未接用例**） | 协调器进程：在自身事件循环里并发拉起 N 个 worker（替代会自锁的 `Atomics.wait` 方案）；本轮未完成断言，仅落地备用 |
| 7 | 注册 | `test-suit/rhop_js/moon.pkg`、`test-suit/rhop_task/moon.pkg` | 两个新 E2E 测试文件加入 `targets`（js） |

## 二、关键技术决策（本轮踩坑与修正，值得留档）

1. **`Atomics.wait` + async `spawn` = 自锁**
   我最初在 MoonBit（同步）里用 `spawn` 起多个 worker，再用 `Atomics.wait` 轮询等待 —— 父进程事件循环被阻塞，子进程的 `close` 回调永不触发，**永久等待到超时**。
   这与 C2 记录的「主线程阻塞会让同进程 server 停摆」是同一个根因。
   ✅ 正解：父进程用 `execFileSync` **同步等待一个协调器进程**，协调器在自己的事件循环里并发拉起 workers（已落地 `task_worker_parallel.js`）。
2. **跨进程对手方必须是"独立实现"**
   relay E2E 的 A 侧不复用产品 `RelayChannel`，而是自写 `relay_peer.js`（裸 `node:http`）；task E2E 的 B 侧不复用产品 store，而是裸 `node:sqlite` + 与产品逐句对齐的 SQL。
   这样才真正验证「协议/产物库对任何实现成立」，而不是自己跟自己闭环。

## 三、验证汇总行（Windows，直接 moon 调用）

```
三目标 check：
  rhop      wasm/js/native → 0 errors / 0 errors / 0 errors
  rhop_task wasm/js/native → 0 errors / 0 errors / 0 errors

包级（3 连跑，全部自然退出，未用 timeout）：
  rhop_js   run1 exit=0 29s 58/58/0 · run2 exit=0 19s 58/58/0 · run3 exit=0 16s 58/58/0
  rhop_task run1 exit=0 12s 103/103/0 · run2 exit=0 7s 103/103/0 · run3 exit=0 12s 103/103/0

全量：
  wasm  612/612/0
  native 612/612/0
  js    845 total / 842 passed / 3 failed
        └ 3 条失败**全部在 test-suit/rhop_business/**（impl-business 在途 C4 用例：
          `c4_e2e_test.mbt:358` 多进程 sqlite claim 竞争、`c4_e2e_test.mbt:493` sync_folder 1200 文件、
          `c3_regression_test.mbt:29` workspace 回收），**与本域无关**
```

用例数变化：`rhop_js` 56 → **58**（+2）；`rhop_task` 101 → **103**（+2：1 跨进程用例 + C3 已计入的心跳互读）。

## 四、temp / 句柄 delta（Windows，单轮，两包各跑一次）

| 指标 | before | after | delta |
|---|---|---|---|
| 全部 `rhop-*` 目录 | 169 | 177 | **+8** |
| 我域前缀（`rhop-t*/w*/task-*/store/queue/sync/hb*/relay*/c4*`） | 0 | 1 | **+1** |

- **如实说明**：+1 未定位到具体目录名（预算耗尽）。C3 已为 8 个 `mkdtemp` 注入 exit hook，新 E2E 的 mkdtemp 也带 hook，
  理论上不应有残留；已列入「未完成项」下轮复查（可疑：某用例在 exit hook 注册前的早期创建，或 hook 在 panic 路径未执行）。
- 其余 +7 属于**非我域**前缀（`rhop-git-*`/`rhop-html-*`/`rhop-actions-root-*`/`rhop-it-*` 等，C3 已列表移交）。
- 句柄：relay 注册表在用例收尾断言为 0；sqlite 句柄在用例收尾 close 并断言注册表归零（C2 守卫仍在）。

## 五、未完成项（与寻虫报告一致，如实登记）

1. ④ **跨进程并发 claim 压测**：fixture 已就绪（协调器方案），缺跑通 + 断言（5 进程抢 5 任务 → 命名唯一 + 全 LOCKED）。
2. ② **`sqlite-local + TaskSync` 双进程拓扑** E2E。
3. ③ **心跳崩溃/超时**端到端（`mark_closed`、停写心跳 → 对端判 dead）。
4. 我域 temp **+1** 残留定位。
5. `scripts/with_moon_lock.sh` 在本轮 PATH（含 `...WindowsApps`）下 `moon: command not found`（rc=127）—— 工具面问题，建议 qa 排查（脚本内 `"$@"` 处 PATH 继承）。

## 六、WSL 侧验证状态

**本轮未在 WSL 执行**（时间预算耗尽 + 上述 lock 脚本问题需先确认）。Windows 侧三目标 check 全 0 error、两包 3 连自然退出全绿、全量 wasm/native 612 全绿。
WSL 复核建议作为下轮首个动作（脚本已备：`/e/tmp/c3_verify_wsl.sh` 可直接复用并追加两个新 E2E 包）。

---

# C4 追加收口（跨域移交 3 项，2026-10-28 晚）

## 1) P1 · BOM 密钥文件（**已修**）

**问题**：impl-session 已在配置层（`_key_from_cfg` 五处）做 `cfg_strip_bom` 双保险，但 **`rhop/key.mbt` 本身不剥 BOM** ⇒ 直接调用 `RhopCrypto::from_path` / `load_key` 的库用户会拿到 `BOM+key`，PBKDF2 派生错位 → Fernet HMAC 失败，报错形似"密钥不符/密文被篡改"。

**修法**：`rhop/key.mbt` 新增 `normalize_key_text(raw)`（**先 trim、再剥 U+FEFF、循环至稳定，最多 8 轮**，覆盖 `BOM+key` / `换行+BOM+key` / 多 BOM），并接入三个入口：
- `load_key` 的 `source` 分支
- `load_key_from_path`（文件内容）
- `load_key_from_env`（环境变量）

**回归用例**（`test-suit/rhop_js/crypto_test.mbt`，+1）：
`key · C4 P1：文件/字符串/环境变量里的 UTF-8 BOM 均被剥掉`
- ① source 字符串带 BOM → Ok(key)
- ② 真实临时 BOM 文件 → Ok(key)
- ③ 换行+BOM+前后空白 → Ok(key)
- ④ **语义级**：BOM 文件必须能解开"干净 key"加密的信封（reason=OK；若 BOM 混入会是 BAD_TOKEN）
- ⑤ 环境变量带 BOM → Ok(key)
- ⑥ 纯 BOM 文件 → Err（不能派生出"BOM 密钥"）

**踩坑留档**：助手内循环变量最初取名 `guard` —— MoonBit 保留字（`guard ... else`），编译报 `[3002]/[4014]`，已改名 `steps`。

## 2) P2 · `HttpEndpoint::read_text` 不删除（**先调查 → 结论：vools 也不删 ⇒ 文档化 + 语义锁定，不改实现**）

**调查证据**（vools `transport/endpoint.py`）：
- `HttpEndpoint.read_text` 只有 `urllib.request.Request(url, headers, method="GET")`，**读后不删**
- 删除是**独立方法** `remove()`（`method="DELETE"`）
⇒ vools 的 http 端点**不是"取走即删"**。

**处置**（按指示不擅改语义）：
- 代码注释写明：`HttpEndpoint` 读取是**非破坏性 GET**，at-most-once / 去重需**上层幂等**；删除用 `remove()`
- 新增回归用例 `transport · HttpEndpoint 非破坏性读取语义（C4 文档化，与 vools 一致）`，把语义**锁进测试**，防止将来有人"顺手对齐成取走即删"
- **矩阵差异登记**：`RelayChannel.receive` = **取走即删**（GET 后 pop，Vools 同）；`HttpEndpoint.read_text` = **非破坏性**。两者不可互换假设 → 上层若需 exactly-once 语义，必须在 relay 与 http 间分别处理

## 3) P2 · 临时目录清整（**已量化 + 已清理**）

| 动作 | 结果 |
|---|---|
| 核实 `transport_test.mbt` 的 `ffi_t_mkdtemp` 是否有退出钩子 | **已有**（C3 轮注入的 `__rxmbt_tmp_reg` + `process.on("exit")` 全量清理），非"裸 mkdtemp" |
| 清理我域历史残留 | `rhop-relay-*` 1 个 → **0**（`rhop-t*/w*/c4*/hb*/store*/queue*/sync*/task-*` 均已为 0） |
| 量化（Windows 单轮，两包各 3 连跑） | 全部 `rhop-*`: 266 → 266（**delta 0**）；我域前缀: 0 → 0（**delta 0**） |
| 量化（WSL 单轮，两包各 3 连跑） | 全部 `/tmp/rhop-*`: 0 → 0（**delta 0**）；我域前缀 0 → 0 |
| 非我域残留 | `rhop-html-*`(≈126)、`rhop-git-*`(≈112)、`rhop-sftp-root-*`、`rhop-actions-root-*`：**全部 `.mbt` 源码中无创建点**（`grep -rn "rhop-html\|rhop-git" --include="*.mbt"` 无命中），判定**非本域**（疑来自 JS fixture/外部脚本），已在审计报告移交对应 owner 自查 |

> 结论：我域临时目录**单轮净增为 0**（成功路径 rmrf + 失败路径 exit hook 双保险）；widnows/WSL 一致。

## 4) 追加后的双平台验证（最终数字）

### Windows 11 / moon 0.1.20261016 / node v25.2.1
```
check rhop wasm/js/native → 0 errors / 0 errors / 0 errors
rhop_js   3 连自然退出：exit=0 12s / 11s / 18s，均 60/60/0
rhop_task 3 连自然退出：exit=0 7s / 5s / 6s，    均 103/103/0
全量 wasm 615/615/0 · js 851/851/0 · native 615/615/0
TEMP delta：全部 266→266（0）；我域 0→0（0）
```

### WSL2 Ubuntu-22.04 / moon 0.1.20261021 / node v25.2.1
```
check rhop wasm/js/native → 0 errors / 0 errors / 0 errors
rhop_js   3 连自然退出：exit=0 25s / 22s / 23s，均 60/60/0
rhop_task 3 连自然退出：exit=0 11s / 8s / 9s，  均 103/103/0
全量 wasm 615/615/0 · js 851/851/0 · native 615/615/0
/tmp delta：全部 0→0；我域 0→0
```

用例数：`rhop_js` 58 → **60**（+BOM、+HttpEndpoint 语义）；`rhop_task` **103**（不变）。

## 5) 仍未完成（沿用前节登记，本轮未强做）

- ④ sqlite **跨进程并发** claim 压测（协调器 fixture 已就绪）
- ② `sqlite-local + TaskSync` 双进程 E2E
- ③ 心跳崩溃/超时端到端
- `scripts/with_moon_lock.sh` 在含 `...WindowsApps` 的 PATH 下 `moon: command not found`（rc=127）—— 本轮所有 moon 命令改为直接调用 + 独占时段
