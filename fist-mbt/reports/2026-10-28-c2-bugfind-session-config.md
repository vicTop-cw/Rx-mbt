# 2026-10-28 · C2 寻虫报告 · 会话 / 配置 / 交互 / 动作（只读阶段）

- 状态：定稿（寻虫阶段完成，修复另见 `2026-10-28-c2-fix-session-config.md`）
- 执行者：impl-session
- 作用域：`rhop/{session,config,interact,actions}.mbt` + `test-suit/rhop/{session,config}_test.mbt` + `test-suit/rhop_interact/`
- 方式：只读代码审计 + **运行时探针实测**（临时探针文件 `test-suit/rhop_interact/scratch_probe_test.mbt`，
  js 目标、真实 node:fs/node:crypto；证据落 `<tmp>/rhop-c2-*/c2-probe.log`，探针文件跑完即删）
- 命令纪律：所有 moon 调用都经 `bash scripts/with_moon_lock.sh moon ...`（与 Windows/WSL 并发构建隔离）

## 0. 结论摘要

| 编号 | 级别 | 主题 | 标题 | 本轮处置 |
|---|---|---|---|---|
| C2-01 | **P1** | ③ 资源/诊断 | `load_config(文本)` 把「非对象 JSON / 超深 JSON」当文件路径，错误信息回显整段输入（12KB+，可触发 ENAMETOOLONG） | **修复 + 回归** |
| C2-02 | **P1** | ③ 资源/安全 | `rhop.echo` 回执原样回显 `sftp.password` / `key_path`，经 `interact execute` 外泄 | **修复 + 回归** |
| C2-03 | P2 | ④ 路径安全 | `safe_filename` 放过 `"."`、Windows 保留设备名（`NUL`/`CON`/`COM1`…）、结尾点 `a.` | **修复 + 回归** |
| C2-04 | P2 | ⑥ 探测副作用 | `available()/select()` 会起**子进程** + 发**网络**请求：http 介质一次探测 ≈ 0.5 s | 文档化（语义不改）+ 量化证据 |
| C2-05 | P2 | ② 并发 | 同名缺省请求包（`req_<action>.rhop`）在多进程/并发下**互相覆盖**，先写方静默丢失 | 文档化 + 回归固定语义 |
| C2-06 | P3 | ⑤ 注册表 | 动作注册表是进程内全局可变 Map，无锁/无重入保护（迭代中变更风险） | 文档化 |
| C2-07 | P3 | ⑤ 重入 | `interact_nonce : Ref[Int32]` 单调计数溢出/无原子性 | 文档化 |
| C2-08 | ✅ 无缺陷 | ② 资源泄漏 | 半写文件 / `.tmp` / 句柄：实测**无残留**（rename 失败自动清理；读写走同步 API 无悬挂句柄） | **回归固定** |
| C2-09 | ✅ 无缺陷 | ① 生命周期 | `Session` 持有 `&OnlineChannel` / `SharedPathView` / `RelayChannel?`：GC 托管、`reverse()` 浅拷贝数组符合「复用介质」语义；`pick_relay()` 返回值拷贝当前无状态丢失 | 结论入档 + 注意项 |

**判绿基线（寻虫前，Windows）**：`moon check` 三目标 0 error；`test-suit/rhop` 144/144/0（wasm）、
`--target js` 148/148/0；`test-suit/rhop_interact --target js` 19/19/0。

---

## 1. C2-01（P1）配置文本被当成文件路径 → 错误信息放大 + 诊断误导

**位置**
- `rhop/config.mbt` `load_config(item : Json)`（String 分支：解析结果「非 object」一律回落 `from_file(trimmed)`）
- `rhop/config.mbt` `RhopConfig::from_file(path)`（`Err("读取配置文件失败: \{path}: \{e}")` 原样回显 path）

**证据（实测）**
```
[P3] depth=8    chars=71    => Ok(cfg)
[P3] depth=32   chars=215   => Ok(cfg)
[P3] depth=128  chars=791   => Ok(cfg)
[P3] depth=512  chars=3095  => Ok(cfg)
[P3] depth=2048 chars=12311 => Err(读取配置文件失败: {"key": "k", "junk": {"a":{"a":{"a":{"a":…)
[P3] array-text => Err(读取配置文件失败: [1, 2, 3]: ENOENT: no such file or directory, open 'E:\…)
```
- 深度 2048 起 `@json.parse` **抛错**（core json 有深度上限，未栈溢出——这点是好消息），
  但 `catch` 把结果置 `Json::null` 后进入「当路径」分支，于是整段 12KB 文本被塞进错误信息。
- 深度 8192 时更触发 `ENAMETOOLONG: name too long, open 'E:\IDEProjects\AI\rx-mbt\{"key": …'`
  —— 整段 JSON 被当文件名传给 OS（错误信息长度 ≈ 输入长度）。
- `[1, 2, 3]`（合法 JSON 数组）也被当路径，错误文案是「读取配置文件失败 … ENOENT」，
  而用户真正的问题是「配置必须是对象」。

**复现**
```moonbit
// 深度 2048
let deep = "{\"a\":" * 2048 + "1" + "}" * 2048           // 概念示意
@rp.load_config(Json::string("{\"key\": \"k\", \"junk\": " + deep + "}"))
@rp.load_config(Json::string("[1, 2, 3]"))
```

**影响**
1. 诊断错位（说成「文件读不到」而不是「配置文本非法/非对象」）；
2. 错误字符串长度 = 输入长度（日志放大、内存放大、可能被写进审计日志）；
3. 把任意（可能含控制字符/换行）输入当路径传给 `fs.readFileSync` —— 语义边界不清。

**建议修法**（本轮已做，无 API 变更）
- `load_config(String)` 先做**形状判定**：`{` 开头 → 当 JSON 解析（失败给「不是合法 JSON」+ 片段截断 ≤120 字符）；
  `[` 开头 → 直接 `Err("配置必须是 dict/JSON 对象…")`；含换行或长度 > 1024 → 判「既不是配置对象也不是可用路径」；
  其余才当文件路径。
- `from_file` 增加路径长度硬上限（4096）与错误回显截断（≤200 字符）。

---

## 2. C2-02（P1）`rhop.echo` 回显口令，经 `interact execute` 外泄

**位置**
- `rhop/actions.mbt` `rhop_echo(cfg, payload)` —— 出参 `cfg` 字段原样回显入参
- `rhop/config.mbt` `RhopConfig::action_cfg()` —— 把 `sftp` 原文（含 `password` / `key_path`）交给动作层
- `rhop/interact.mbt` `interact(mode="execute")` —— `omega_unwrap(run_action(...))` 的返回里带 `cfg`

**证据（实测，P7）**
```
[P7] to_dict leaks: sftp_pw=false online_pw=false cfg_relay_tok=false   ← to_dict 已深度掩码（好）
[P7] rhop.echo leaks: sftp_pw=true key_path=true                        ← 动作回执泄漏
[P7] interact(execute) leaks: sftp_pw=true                              ← 经 interact 外泄
```
包内已有正确口径：`rhop/config.mbt` 的 `cfg_mask_deep`（敏感键：`password/passwd/key_path/private_key/secret/token/api_key/access_token/refresh_token`，大小写不敏感、递归下钻），
`to_dict` 正因它而不漏；但 `rhop.echo` 没用它。

**复现**
```moonbit
let cfg = @rp.load_config(/* sftp.password = "SFTP-PW" 的配置 */)
Json::stringify(@rp.run_action("rhop.echo", cfg_ok.action_cfg(), None)).contains("SFTP-PW")  // true
```

**影响**：离线自检动作本是「链路自检」，常被调用方 `println`/写日志/写 trace；一旦 cfg 带跳板机口令，
口令就落进普通日志（对比：`to_dict` 已经刻意做了掩码，说明团队口径是「回执不漏密」）。

**建议修法**（本轮已做）
- `rhop_echo` 回显前对 `cfg` 做**同一套深度掩码**（复用 `config.mbt` 的 `cfg_mask_deep`，同包私有即可），
  出参形状不变（`status/action/cfg/payload/offline`），只把敏感值换成 `"***"`。
- 附：`action_cfg()` **保持原文**（`jump.push/pull/sync` 真连 SFTP 需要口令），泄漏面收口在「回显/回执」一侧。

---

## 3. C2-03（P2）`safe_filename` 放过 `"."`、Windows 保留设备名、结尾点

**位置**：`rhop/session.mbt` `safe_filename`（字符集白名单 + 长度 + `..` 检查）

**证据（实测，P1/P2）**
```
[P1/P2] name=NUL.rhop  safe=Ok  on_disk=true  send=status=ok …     ← 保留设备名通过
[P1/P2] name=CON.rhop  safe=Ok  on_disk=true  send=status=ok …
[P1/P2] name=COM1.rhop safe=Ok  on_disk=true  send=status=ok …
[P1/P2] name=AUX.rhop / PRN.rhop 同上
[P1/P2] name=.         safe=Ok  on_disk=true  send=status=error reason=rhop: 原子替换失败: …EPERM
[P1/P2] listing=["-x.rhop","AUX.rhop","COM1.rhop","CON.rhop","NUL.rhop","pkg.rhop","PRN.rhop"]
```
三点问题：
1. `"."` 通过白名单：`send_package(".")` 一路做到 `rename` 才失败（`EPERM`），而 `exists(".")` 恒 true
   （目录存在）——调用方拿到的信号是「文件在」；
2. **Windows 保留设备名**通过：Node 因 `\\?\` 长路径形式把它们建成了**真实文件**（listing 可见），
   但同样这些名字在 cmd/PowerShell/普通 Win32/部分运维脚本里会解析成**设备**（写入被丢弃、读取挂起）
   —— 介质层哪天换实现（子进程/原生）就会「假成功丢数据」；
3. **结尾点**（`a.`）通过：Win32 会抹掉结尾点（落到 `a`），POSIX 保留（落到 `a.`）——
   同一逻辑包名在两平台指向不同文件（跨端 A 写 B 读会「找不到包」）。

**建议修法**（本轮已做，纯白名单收紧，不新增 API）
- 拒绝「纯点号名」（`.`、任何 `all('.')`）；
- 拒绝 Windows 保留设备名（base = 第一个 `.` 之前那段，大小写不敏感）：`CON/PRN/AUX/NUL/CLOCK$`、`COM1..COM9`、`LPT1..LPT9`；
- 拒绝结尾 `.`。

---

## 4. C2-04（P2）通道探测的隐式副作用：子进程 + 网络 + 阻塞

**位置（代码级证据链）**
- `rhop/session.mbt` `pick_relay` → `RelayChannel::available`（`rhop/relay.mbt`）→ `http_request`（`rhop/transport_endpoint.mbt`）
  → `node:child_process.execFileSync(process.execPath, ["-e", …])`（每次探测 = fork 一个 node 子进程 + 一次 HTTP 请求）
- `rhop/session.mbt` `pick_online` → `SftpChannel::available`（TCP 探测，同样是**子进程**）、`GitChannel::available`（`git ls-remote` 子进程）
- `rhop/session.mbt` `sp_side_usable` → 本地端点用 `exists(".")`（无副作用 ✔），但 `http-url` 端点会走 `EndpointView::exists`
  → 又一次子进程 HTTP；末段兜底 `SharedPath::available` 也是 HTTP。
- `rhop/session.mbt` `Session::available` / `select` 都按这条链**逐个真实探测**。

**证据（实测，P6，Windows js）**
```
[P6] available()=false in 518 ms; select()=none in 499 ms     ← http 介质（127.0.0.1:9）
[P6] local available()=true in 0 ms                            ← 本地目录对照
```
一次「纯探测」≈ 0.5 s + 1 个 node 子进程 + 1 次 TCP 连接；`select()` 再走一遍。
`interact` 的一次 roundtrip 会构建 2~3 个 session（sender / handle_request 的 RECV / 取回），
带 relay 或 http 介质时**每次交互有 1.5~2.5 s 是纯探测**，且探测结果不复用。

**影响**：配置自检/热路径反复调用 `available()` 会放大成本；探测本身有网络副作用（对端日志可见），
在「离线可信介质」场景属意外外联。

**建议修法**（本轮**不改语义**，只文档化 + 量化）
- 文档标注：`available()/select()` 是**主动探测**（会起子进程/发网络请求），不要在热路径高频调用；
- 后续可选（不改签名）：调用内探测去重（一次 `send_package` 内 relay/online/shared 各只探一次已成立）
  或显式 `probe_ttl` 缓存。

---

## 5. C2-05（P2）同名缺省请求包互相覆盖（并发/多进程）

**位置**：`rhop/interact.mbt` `interact_default_filename`（缺省 `req_<action>.rhop`）+ roundtrip 流程

**证据（实测，P5）**
```
[P5] a=status=ok transport=shared filename=req_same.rhop role=SEND
[P5] b=status=ok transport=shared filename=req_same.rhop role=SEND
[P5] listing=["req_same.rhop"]          ← 介质上只剩 1 个包
[P5] handle=status=ok transport=shared  ← 只能处理「后写」的那一份
```
先写的那一份**静默消失**，发送方仍拿到 `status=ok`（介质层语义：原子覆盖写）。

**影响**：同一介质目录上「并发 / 多进程 / 同一 action 重试」时请求互相覆盖；
F1 的一次性 token 只能保证「不把上一轮回执当本轮」，**不能保证请求不丢**。

**建议修法**（本轮只文档化 + 回归固定，不改行为）
- 文档：缺省名只保证「单写者顺序调用」；并发方必须显式传唯一 `request_filename`
  （daemon/executor 层加 nonce/队列化，属 Batch D 职责）；
- 新增回归测试固定当前语义（同名第二个包覆盖第一个），防止未来误以为会排队。

---

## 6. C2-06（P3）动作注册表：进程内全局可变 Map，无锁/无重入保护

**位置**：`rhop/actions.mbt` `action_registry : Map[String, (Json, Json?) -> Json]`、`register_action`/`unregister_action`/`list_actions`/`run_action`

**证据（代码级）**
- `list_actions()` 用 `for name in action_registry.keys()` **边迭代**；如果同一调用栈里有 handler
  调 `register_action`/`unregister_action`，就是「迭代中改容器」。
- 实际可达路径：`run_action("未知动作")` 的错误分支会调 `list_actions()`；若某个已注册 handler 内部
  再调 `run_action("未知动作")`，则「外层 handler 在栈上、内层 list_actions 迭代」——当前不重叠（内层无写入），
  所以**未复现崩溃**；但一旦有 handler 在自身执行期间注册/注销动作并在同一栈上触发列举，就会命中。
- 多线程：js/wasm/native 若并发调 `register_action`，`Map` 无同步（MoonBit 侧无锁 API）。

**建议修法**：文档化「注册表只在启动期或单线程阶段变更」；如需热卸载，`list_actions` 先做键快照再迭代（本轮仅文档化，不动实现以免引入行为变化）。

---

## 7. C2-07（P3）`interact_nonce : Ref[Int32]` 溢出与原子性

**位置**：`rhop/interact.mbt` `let interact_nonce : Ref[Int32] = Ref::Ref(0)` / `interact_next_token`

**证据（代码级）**：`Int32` 单调递增，2^31 次 roundtrip 后回绕为负；`Ref` 读改写非原子
（js 单线程安全；wasm/native 多线程不安全）。回绕本身不致错判（token 还需 filename+action 全等），
但可预测性下降、且 2^31 次后 token 可能与历史值重复。

**建议修法**：文档化；后续换 `Int64` 或 `时间戳+计数`（不改签名则内部即可）。

---

## 8. C2-08（✅ 无缺陷，回归固定）半写文件 / 临时文件 / 句柄

**实测（P4）**：目标文件名已被**目录**占用时，原子写的 `rename` 失败 → 发送回 `status:error` 收据，
且**不留 `.tmp` 残留**：
```
[P4] send=status=error transport=shared filename=blocked.rhop reason=rhop: 原子替换失败: … EPERM
[P4] listing=["blocked.rhop"]        ← 没有 blocked.rhop.tmp
```
- 读路径 `readFileSync` / 写路径 `writeFileSync` 均是「开-用完即关」的同步 API，无悬挂句柄；
- `interact` roundtrip 的失败面：`phase=send/request/receive/response` 都会在**下一轮开始前**清理陈旧 `res_`，
  成功/令牌不符时也会删除 `res_`（F1 已覆盖）。
**结论**：该项无缺陷；本轮补回归测试固定（rename 失败无 `.tmp`；phase=send 失败不产生 `res_`）。

## 9. C2-09（✅ 无缺陷，结论入档）Session 的 trait object 生命周期与可变共享

- `Session` 持有 `online : Array[&OnlineChannel]`、`shared : SharedPathView`（内含两个 `&SharedPath`）、
  `relay : RelayChannel?`、`crypto : RhopCrypto?` —— 全部由 MoonBit GC 托管，**无生命周期悬垂**；
- `reverse()` 用 `self.online.copy()`（浅拷贝 trait 对象引用）+ 复用 `shared/relay/crypto`，
  与 vools「换角色复用同一份介质」语义一致；**注意点**：`copy()` 是浅拷贝，
  若将来引入有状态通道（连接池/游标），`reverse()` 会让两侧共享同一状态——目前无 `mut` 状态，故无缺陷；
- `pick_relay()` 返回 `RelayChannel` 的**值拷贝**（结构体无字段），随后 `let ch : &OnlineChannel = rc`
  取临时引用发请求——当前无状态丢失；若 RelayChannel 未来加 `mut` 字段（如连接复用缓存），此处会丢状态，
  需改成持有引用或在 Session 内保存原对象。
- `Session::available()/select()` 不修改任何状态（纯探测），因此并发读安全（只读 + 无缓存）。

## 10. 附：本轮修复范围与不动项

- 修复文件（仅我的作用域）：`rhop/config.mbt`（C2-01）、`rhop/actions.mbt`（C2-02 回显掩码）、
  `rhop/session.mbt`（C2-03 白名单收紧 + C2-04/C2-09 文档化）。
- 回归测试：`test-suit/rhop/config_test.mbt`、`test-suit/rhop/session_test.mbt`、
  `test-suit/rhop_interact/interact_test.mbt`（新增/强化各条对应的用例）。
- 不动：所有公开 API 签名；`rhop/transport_local.mbt`（别人作用域）；`interact` 的缺省包名语义（只文档化）。