# C2 寻虫报告 · 资源与并发（impl-crypto 域）

- 日期：2026-10-28
- 范围：`rhop/{key,crypto,watch,transport_base,transport_local,transport_endpoint,transport_selector,online,relay}.mbt` + `rhop_task/*.mbt` + 对应测试
- 方式：代码审读 + node 探针（不写工作树）+ 既有测试基线对照
- 平台：Windows 11 / node v25.2.1 / moon 0.1.20261016 + WSL2 Ubuntu-22.04 / node v25.2.1 / moon 0.1.20261021

## 0. 两个关键事实（先做探针，避免误判严重度）

| 探针 | 命令（要点） | 结果 | 结论 |
|---|---|---|---|
| P-1 未关闭的 `node:sqlite` 句柄 | `new DatabaseSync(":memory:")` 后不 close 直接退出 | **exit=0** | 未关闭的 sqlite 句柄**不会阻塞 node 退出** ⇒ 泄漏属「资源泄漏/句柄占用」，**不是挂死源**（严重度最高只到 P2） |
| P-2 `detached+unref` 子进程 | spawn 一个 60s 存活子进程，`detached:true`+`unref()` | **exit=0** | relay 的 `detached+unref+stdio:ignore` 设计确认**不会**拖住父进程 |

> 这两条把「挂死」范围收窄到：被 ref 的 timer（已 unref）、fs.watch（monitor 已修）、以及**同一进程内的 server/socket**（本域只有 relay，已跨进程）。

---

## BUG-1【P1】relay 每次 start/stop 泄漏一个临时目录

- **位置**：`rhop/relay.mbt` — `unique_tmp_path("rhop-relay")`（FFI `ffi_unique_tmp`，L263）与 `RelayServer::stop`（L139–147）
- **证据**：`ffi_unique_tmp` 用 `fs.mkdtempSync(<tmp>/rhop-relay-XXXX)` **创建目录**并返回 `<dir>/port`；`stop()` 只 `fs_remove(self.port_file)`（删文件），**从未删除 mkdtemp 建出的目录**。
- **影响**：每起停一次中转，`os.tmpdir()` 留下一个空目录；测试里一次 run 起 3 个 server ⇒ 每轮 3 个空目录累积（CI 长跑会积灰）。
- **复现**：js 里 `RelayServer::new(...)` → `start()` → `stop()`，然后列 `os.tmpdir()`，可见 `rhop-relay-*` 目录残留（文件已删、目录还在）。
- **建议修法**：`stop()` 删端口文件后，再删其父目录（专用私有 FFI `ffi_remove_dir`，失败静默）；`start()` 超时分支已走 `stop()`，自动受益。

## BUG-2【P1】watch 先登记 `seen` 后读取 ⇒ 读失败/半写文件会**永久丢失**

- **位置**：`rhop/watch.mbt` — `RhopWatcher::process_file`
- **证据**：
  ```
  if self.seen.val.contains(path) { return None }
  self.seen.val.add(path)          // ← 先登记
  match fs_read_text(path) {
    Err(_) => { bad += 1; None }   // ← 读失败也留在 seen，后续事件被 contains 挡掉
    Ok(text) => { ... if !r.ok { bad += 1; None } ... }  // ← 解密失败同理
  }
  ```
- **影响**：两个真实场景会**静默丢消息**：① 写入方非原子写（外部程序直接 `cp`/重定向），事件在文件写一半时到达 → 读失败或解密失败 → 之后写入完成的新事件被 `seen` 挡掉；② 瞬时 IO 错误（杀软占用/网络盘抖动）。
- **注**：本项目的 `LocalSharedPath` 是原子写（tmp+rename），所以自家链路不触发；但 watch 的契约是监控**目录**，对端未必是自家实现（vools/其它工具）。
- **复现**：写半截 → `process_file(p)` 返回 None 且 `bad_files()==1`；再写完整 → `process_file(p)` 仍返回 None（应为 Some）。
- **建议修法**：`seen` 只在**成功推送**后登记；读失败/解密失败时**不登记**（允许下个事件重试）。坏文件重复告警的风险由 `bad` 计数与事件驱动（仅文件变化才触发）自然收敛。

## BUG-3【P2】`stop()` 不清 `seen`，stop→start 后旧路径被永久压制

- **位置**：`rhop/watch.mbt` — `RhopWatcher::stop`
- **证据**：`stop()` 只 dispose 订阅 + `started=false`，`seen`/`bad` 保持原状；`start()` 在 `skip_existing=false` 时不做任何重置。
- **影响**：用户 stop 后重新 start（典型：换盘、重连共享目录）期望「重新看待这个目录」，但同名文件的新事件会被 `seen` 丢弃；`skip_existing=true` 时行为反而正确（start 会重新 seed）。
- **建议修法**：`stop()` 里 `seen` 清空（`bad` 保留，作为累计诊断计数）。语义与 `skip_existing` 一致：每次 start 都是新的观察窗口。

## BUG-4【P2】`clean_stale_locks` 静默吞掉回收失败

- **位置**：`rhop_task/task_store.mbt` — `clean_stale_locks`
- **证据**：`match self.set_state(...) { Err(_) => () Ok(true) => n+=1 Ok(false) => () }` — 回收单条失败（DB 忙、行被并发改动）**无任何痕迹**。
- **影响**：失效锁没被回收时，上层看到 `Ok(0)` 会以为「没有需要回收的」，实际上有 N 条失败；共享盘偶发 locked 时尤其难查。
- **建议修法**：记录首个错误；若有失败，返回 `Err`（文案含 成功数/失败数/首个原因）。API 签名不变（同 `Result[Int, String]`）。

## BUG-5【P2】`RelayServer::start` 只看 `child != 0` 判「已启动」，子进程已死时不重启

- **位置**：`rhop/relay.mbt` — `RelayServer::start` 首行 `if self.child != 0L { return Ok(()) }`
- **证据**：TTL 到期 / 子进程异常退出后 `child` 仍是旧 id，`alive()`（=已启动语义）为 true，但 `process_alive()` 已是 false；再 `start()` 直接 Ok 返回 ⇒ 调用方以为服务可用，随后 send/receive 才失败。
- **建议修法**：`start()` 幂等判断改为「`child != 0` **且** `relay_alive(child)`」，否则先清理旧 id/端口文件再重新拉起。

## BUG-6【P2】sqlite FFI 在 PRAGMA 失败路径泄漏已打开的数据库句柄

- **位置**：`rhop_task/task_store.mbt` — `ffi_sqlite_open`（L~1150 的单行 FFI）
- **证据**：`const db = new DatabaseSync(path); db.exec("PRAGMA busy_timeout..."); db.exec("PRAGMA journal_mode = WAL"); ...` 全在一个 try 里；**若 `journal_mode`/`synchronous` 的 exec 抛错，`db` 已创建却不会 `db.close()`**，直接 `catch` 返回 -1。
- **影响**：在不支持 WAL 的介质（9p/网络盘常见）或权限异常时，每次打开失败都留下一个原生句柄（P-1 已证不阻塞退出，但句柄泄漏）。
- **建议修法**：catch 里先尝试 `db.close()` 再返回 -1；并在 journal 设置失败时**降级**（WAL→DELETE 重试一次），把实际生效的 journal 记回 spec 供 `describe()` 诊断。

## BUG-7【P3】测试里 sqlite 句柄在「断言失败」时不 close（泄漏面）

- **位置**：`test-suit/rhop_task/task_store_test.mbt` / `task_queue_test.mbt` / `task_sync_test.mbt` — 每个用例末尾 `@rt.SqliteTaskStore::close(store)`，但断言失败会 raise 跳过 close。
- **影响**：单个用例失败 ⇒ 该次 run 泄漏若干句柄（P-1 已证不阻塞退出，故不是挂死；但「失败时资源不归零」会污染后续诊断）。
- **建议修法**（不动产品 API）：测试包内加一条**收尾守卫用例**：用测试本地 FFI 遍历 `globalThis.__rxmbt_sqlite_reg` 强制 close 并断言注册表归零——与本域已有 relay/watch 守门风格一致。

## BUG-8【P3】`HeartbeatPump` 的 timer 在对象被丢弃后仍持续写心跳

- **位置**：`rhop_task/task_heartbeat.mbt` — `HeartbeatPump::start`（回调捕获 `hb_copy`）
- **证据**：timer 已 `unref()`（**不会阻塞进程退出**，这点是对的），但没有 RAII：调用方忘记 `stop()/shutdown()` 时 timer 会跑到进程结束，持续写心跳文件（对端会看到「一直活着」）。
- **影响**：进程活着期间无害；语义上掩盖了 worker 已经不干活的事实。
- **建议**：文档已写明必须 stop；本轮**不改代码**（无 API 变更前提下无法做 RAII），在报告中登记为已知限制。

## BUG-9【信息】WSL 与 Windows 的差异点（实测 + 推断分级）

| 差异点 | 实测/推断 | 结论 |
|---|---|---|
| `node:sqlite` 可用性 | 两平台均 `exports=DatabaseSync/StatementSync/Session/constants/backup`，建表→插入→查 通 | **无差异** |
| 未关闭句柄是否阻塞退出 | 两平台探针均 exit=0 | 无差异 |
| relay 绑定地址 | 我方显式绑 `127.0.0.1`，不写 `localhost` | 规避 IPv6 `::1` 解析差异（若写 localhost，Windows/WSL 解析顺序可能不同） |
| **WAL on /mnt/e（drvfs）** | 我方测试用 `os.tmpdir()`（WSL 下是 ext4）故未覆盖；9p/drvfs 上 WAL 的共享内存/锁语义不可靠 | **真实风险**：用户把 `sqlite-local` 指向 `/mnt/e` 时可能异常。建议 BUG-6 的降级方案覆盖（WAL 失败 → DELETE），并在文档标注 |
| 临时目录 | 两平台 `os.tmpdir()` 均可写；Windows 路径含空格/反斜杠已被 `normalize_path` 归一 | 无差异 |
| 子进程可执行体 | 用 `process.execPath`（真 node），不经 `.cmd` shim | 规避 Windows `node.cmd` 参数截断坑 |

---

## 汇总（按严重度）

| 级别 | 编号 | 一句话 |
|---|---|---|
| **P1** | BUG-1 | relay 每起停泄漏一个临时目录（从未删 mkdtemp 目录） |
| **P1** | BUG-2 | watch 先登记 seen 后读 ⇒ 读失败/半写文件**永久丢消息** |
| P2 | BUG-3 | watch `stop()` 不清 seen，重启后旧路径被压制 |
| P2 | BUG-4 | `clean_stale_locks` 静默吞回收失败 |
| P2 | BUG-5 | relay `start()` 不判断子进程是否还活着 |
| P2 | BUG-6 | sqlite FFI PRAGMA 失败路径泄漏 db 句柄（且 WAL 不支持时硬失败） |
| P3 | BUG-7 | 测试失败路径不 close sqlite 句柄（加收尾守卫） |
| P3 | BUG-8 | HeartbeatPump 无 RAII（已 unref，登记为已知限制） |
| 信息 | BUG-9 | 双平台差异清单（含 WAL on 9p 风险） |

本轮修复计划：**BUG-1/2/3/4/5/6/7 全修 + 每处补回归测试**；BUG-8 只登记；BUG-9 随 BUG-6 的降级实现落地并在报告标注。

---

## 补记（验证阶段新发现，寻虫时未覆盖到）

## BUG-10【P1】relay 端口文件的跨进程握手竞态 ⇒ start() 假失败

- **位置**：`rhop/relay.mbt` — `RelayServer::start` 的端口文件轮询 + `ffi_relay_spawn` 子进程脚本
- **发现方式**：WSL 侧验证跑出来的**偶发失败**（不是设计审查发现的）：
  ```
  relay · stop() 连临时目录一起清掉（C2 BUG-1 回归） failed:
  中转服务启动失败: rhop relay: 端口文件内容不是合法 JSON: 
  ```
  注意错误里的内容为空串 —— 这是关键线索。
- **根因**：子进程用 `fs.writeFileSync(spec.port_file, …)` **非原子写**，父进程轮询时可能命中「文件已创建、内容尚未落盘」的窗口期；旧实现 `match @json.parse(text) { Err(_) => return Err(...) }` —— **解析失败立刻放弃**，而不是继续等。
- **影响**：**假失败**。服务其实几十毫秒内就绪，但 `start()` 直接返回 Err（调用方会认为中转不可用）。9p/网络盘等慢 I/O 介质把窗口放大 ⇒ WSL 上高概率命中，Windows 上概率低但同样存在（属竞态）。
- **复现**：WSL 上 `moon test -p test-suit/rhop_js --target js` 反复跑，偶发上述失败。
- **修法（双侧，根治）**：
  1. 子进程改为 **tmp + rename 原子写**端口文件（读方永远看不到半截内容）；
  2. 父进程把「内容为空/不可解析/缺 port」一律视为**未就绪**，继续轮询；只有 5s 超时才报错，并在错误里带上最后一次读到的内容便于诊断。
- **回归**：`relay · stop() 连临时目录一起清掉（C2 BUG-1 回归）` 在 WSL 上连跑 5 次、Windows 连跑 3 次均通过（修前 WSL 上会偶发）。

> 这条是本轮最有价值的发现：它不在静态审查的视野里，只有在**双平台 + 多次重复**的验证矩阵里才会暴露，也正是 C2「资源与并发」主题的典型形态。
