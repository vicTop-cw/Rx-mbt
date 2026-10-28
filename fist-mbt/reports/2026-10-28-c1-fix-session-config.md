# C1 修复报告 — Batch C（session / config / interact）

> 任务：按 lead 派单修 C1 寻虫（`fist-mbt/reports/2026-10-28-c1-bugfind-session-config.md`）中的 F1/F2/F4/F5/F6/F7/F8 + 测试层缺口；F3/F9 不改 `rhop/online.mbt` / `rhop/transport_*.mbt`，只登记待 online lane。
> 范围（全部在授权写作用域内）：`rhop/session.mbt`、`rhop/config.mbt`、`rhop/interact.mbt`、`test-suit/rhop/session_test.mbt`、`test-suit/rhop/config_test.mbt`、`test-suit/rhop_interact/interact_test.mbt`。
> **未执行 git commit**；产品代码改动仅限上述三个 rhop 文件，未触碰其他 lane 的文件。
> 所有 moon 命令均经 `bash scripts/with_moon_lock.sh [--wait N] moon …` 串行化执行。
> 执行人：impl-session　时间：2026-10-28（UTC+8）

## 0. 判绿证据（真实输出）

```
$ bash scripts/with_moon_lock.sh --wait 900 moon check rhop                 → Finished. moon: ran 4 tasks, now up to date (114 warnings, 0 errors)
$ bash scripts/with_moon_lock.sh --wait 900 moon check rhop --target js     → Finished. moon: ran 3 tasks, now up to date (91 warnings, 0 errors)
$ bash scripts/with_moon_lock.sh --wait 900 moon check rhop --target native → Finished. moon: ran 3 tasks, now up to date (116 warnings, 0 errors)

$ bash scripts/with_moon_lock.sh --wait 900 moon test test-suit/rhop                  → Total tests: 144, passed: 144, failed: 0.   (wasm)
$ bash scripts/with_moon_lock.sh --wait 900 moon test test-suit/rhop --target js      → Total tests: 148, passed: 148, failed: 0.
$ bash scripts/with_moon_lock.sh --wait 900 moon test test-suit/rhop --target native  → Total tests: 144, passed: 144, failed: 0.
$ bash scripts/with_moon_lock.sh --wait 900 moon test test-suit/rhop_interact --target js → Total tests: 19, passed: 19, failed: 0.

$ bash scripts/with_moon_lock.sh --wait 900 moon test --target js            → Total tests: 792, passed: 792, failed: 0.   (全量，无回归)
```

文件规模（改后）：`rhop/session.mbt` 667 行、`rhop/config.mbt` 724 行、`rhop/interact.mbt` 359 行、`test-suit/rhop/session_test.mbt` 744 行、`test-suit/rhop/config_test.mbt` 688 行、`test-suit/rhop_interact/interact_test.mbt` 990 行。

## 0.1 汇总表

| # | 状态 | 修法位置 | 回归用例 |
|---|---|---|---|
| F1 | 已修 | `rhop/interact.mbt:76/83/97/106/134-149`、`rhop/session.mbt:588`（`remove_package`） | `interact · roundtrip：预置陈旧 res_ 不被采信，取回后删除（C1-F1）`、`interact · roundtrip：发送失败立即 error(phase=send)，不返回上一轮结果（C1-F1）` |
| F2 | 已修（session 层）/ 残留待 transport lane | `rhop/session.mbt:88`（`safe_filename`）、`rhop/interact.mbt:67/188/311` | `session · safe_filename：白名单放行，穿越/分隔符/空白/超长全部 Err`、`session · send/recv 拒绝非法文件名且不触碰介质（C1-F2）`、`interact · 包名白名单：穿越名 Err 不落盘、缺省名按 action 净化（C1-F2）` |
| F4 | 已修 | `rhop/interact.mbt:252-275` | `interact · handle_request：回执写失败 → status:error + phase=response（C1-F4）` |
| F5 | 已修 | `rhop/session.mbt:257/269/292/306/323/350` | `session · shared 读/写分开判定：只读介质不被判全不可达…（C1-F5）`、`interact · available()/select() 不建目录；只读接收端可收（C1-F5）`、`interact · 只读介质：接收端能收、发送端给出「写端不可用」专门 Err（C1-F5）` |
| F6 | 已修 | `rhop/config.mbt:234-243/529/544/573/582` | `config · to_dict 递归掩码：online/relay/shared 的 password/key_path/token 都是 ***` |
| F7 | 已修 | `rhop/config.mbt:381/382/632/658/671` | `config · build_relay：host 空串回退 127.0.0.1；port 0/负值归一（C1-F7）` |
| F8 | 已修（低成本项全做） | `rhop/config.mbt:137/178/311-335/464` | `config · F8 语义对齐：role 空串→SEND、shared {}→None、online 非对象→Err、key 布尔→Err` |
| T1 | 已修 | `test-suit/rhop/config_test.mbt:130-134` | 同上文件内（弱断言收紧为「空串不得当密钥」） |
| T2 | 已修 | `test-suit/rhop/config_test.mbt:553` | F6 用例 |
| T4 | 已修 | 三个测试文件 | F2/F5/F7/F8 用例覆盖穿越名、`shared:{}`、`role:""`、`relay.host:""` |
| T5 | 已修 | `test-suit/rhop_interact/interact_test.mbt:765/801/830` | F1/F4 用例 |
| F3 | **未修（登记）** | `rhop/online.mbt:144-155` + `rhop/session.mbt:416-506` | 需 online lane 决策：sftp `send/receive` 恒 Err，而通道选择把「TCP 探活成功」当「能发」，且不回退 shared |
| F9 | **未修（登记）** | `rhop/online.mbt:85-91`（`SftpChannel` 无 `password/key_path/probe_mode` 字段） | 需 online lane 决策：sftp 凭据被 `cfg_channel_from_spec` 静默丢弃 |
| F10 | **部分（仅登记）** | `rhop/actions.mbt`（`known` 未排序、`omega_gate:{}` 不回退）+ `rhop/interact.mbt:49` | `run_action` 可用列表排序、`omega_unwrap` 空 gate 回退归 actions lane；`mode` 保留 `trim+to_lower`（见 §F10） |
| F11 | **登记（不改）** | `rhop/config.mbt:417-435`、`rhop/interact.mbt`（同形 vools 行为） | `load_config("{...}")` 仍按路径处理（vools 同形，语义明确）；`res_` 自噬风险已由 F1 的一次性消费 + token 校验消除大部分 |

---

## F1（P1）roundtrip 忽略投递失败、用上一轮 `res_` 冒充成功

**修法**：
1. 请求包带一次性令牌：`rhop/interact.mbt:76` 生成 `token = interact_next_token(filename, action)`（进程内 nonce，`interact.mbt:326/333`），写入请求包 `{"action","payload","token"}`（`:83`）。
2. 发送后立刻判结果：`:97` 起 `status != "ok"` → `{"status":"error","phase":"send","filename":…,"detail":<send 回执>}`，**不再往下走**。
3. 取回前清残留：`:106` `let _ = sender.remove_package(resp_filename)`（`res_<filename>`）。
4. 回执校验：`handle_request` 把请求里的 `token` 原样回显（`interact.mbt:257`）；roundtrip 取回后比对 `:134-149`，不匹配 → `{"status":"error","phase":"response","reason":"回执与本次请求不匹配（疑似陈旧 res_ 或串包）"}`；匹配则**消费即删**（`:149` `remove_package`）。
5. `rhop/session.mbt:588` 新增 `pub fn Session::remove_package(self, filename) -> Result[Unit,String]`：走读视图 `SharedPath::remove`（幂等），供一次性消费；无 shared 介质时 `Err "仅 shared path 支持删除包"`。

**证据**（`test-suit/rhop_interact/interact_test.mbt:765`）：预置一份「上一轮」合法密文 `res_req_rhop_echo.rhop`（`token: tok:0:…`），再连跑两轮 marker=`fresh-run-1/2`：

```
interact · roundtrip：预置陈旧 res_ 不被采信，取回后删除（C1-F1）  → passed
  · 两轮均 status=="ok" 且 action_result.payload.marker == 本轮 marker
  · 每轮结束后 !ffi_exists(res_req_rhop_echo.rhop)（一次性消费）
```

发送失败路径（`interact_test.mbt:801`，写端父路径被普通文件挡住）：

```
interact · roundtrip：发送失败立即 error(phase=send)，不返回上一轮结果（C1-F1） → passed
  断言 status=="error"、phase=="send"、detail.status=="error"、整包不含 "run1"
```

**语义说明**：`send_package` 的 I/O 失败仍是 `Ok({status:"error"})` 收据（Batch C 有意差异，见 `session.mbt:381-388` 分流原则），roundtrip 把它翻译成 `phase:"send"` 的错误包，因此调用方看到的一定是 `status:"error"`，不再是假 ok。

---

## F2（P1）文件名零净化：路径穿越写穿 shared 根

**修法**：
1. `rhop/session.mbt:88` 新增 `pub fn safe_filename(name : String) -> Result[String,String]`：白名单 `^[A-Za-z0-9._-]{1,128}$`，显式拒 `.`/`..`/任一 `..` 子串（防穿越），非白名单字符报「只允许 A-Za-z0-9._-，遇到非法字符（码点 N）」。
2. `send_package`（`session.mbt:425`）、`recv_package`（`:516`）、`remove_package`（`:592`）统一先过 `safe_filename`，非法即 `Err`，**介质层拿不到可穿越路径**。
3. `handle_request`（`interact.mbt:188`）同样先净化，非法 → `{"status":"error","reason":"包文件名非法: …","transport":null}`。
4. 缺省文件名不再直接拼 action：`interact.mbt:296-311` 先把 `.` 及白名单外字符换成 `_`（`jump/probe` → `req_jump_probe.rhop`），空动作名兜底 `action`，超长截断，最后仍过 `safe_filename`。

**证据**：

```
session · safe_filename：白名单放行，穿越/分隔符/空白/超长全部 Err      → passed
  Ok("req_jump_probe.rhop")、Ok("a-b_c.9")；
  Err: "../escaped.rhop","..","./x.rhop","a/b.rhop","a\b.rhop","C:\x.rhop",
       "sub/../../x.rhop","req a.rhop","包.rhop", ""（"包文件名不能为空"）, 129×'a'（"过长"）
session · send/recv 拒绝非法文件名且不触碰介质（C1-F2）                → passed
  send("../escaped.rhop") / send("sub/dir.rhop") / recv("../escaped.rhop") 全 Err 且介质写入计数=0
interact · 包名白名单：穿越名 Err 不落盘、缺省名按 action 净化（C1-F2） → passed
  request_filename ∈ {"../escaped.rhop","sub/dir.rhop","..\up.rhop"} → Err contains "包文件名"
  !ffi_exists(dir+"/../escaped.rhop")；interact(...,"jump/probe") → filename "req_jump_probe.rhop"
```

**残留（明确移交）**：`join_shared` 归一化后「前缀断言在 base 内 + 拒绝 `..`/绝对路径」属 `rhop/transport_local.mbt:106-116`，按 lead 指令本轮不动 `transport_*.mbt`。当前 session 层白名单已使穿越在该路径的**唯一入口**不可达（所有 filename 进入介质前都已被白名单约束），因此不阻塞；建议 transport lane 补 `join_shared` 的断言作为纵深防御（测试可直接调 `rhop.join_shared`）。

---

## F4（P2→已修）`handle_request` 回执写失败仍报 `status:"ok"`

**修法**：`rhop/interact.mbt:252-275`——回执包仍带 `token`，但 `sent.status != "ok"` 时返回
`{"status":"error","phase":"response","action","transport","response_filename","detail":<send 回执>}`，不再把失败藏在 `response_sent` 里报成功。

**证据**（`interact_test.mbt:830`）：接收端读端正常、写端指向「父路径是文件」的不可写位置：

```
interact · handle_request：回执写失败 → status:error + phase=response（C1-F4） → passed
  handle_request => status:"error"、phase:"response"、detail.status:"error"
```

**与 vools 差异**：vools `interact.py:130-136` 无条件返回 ok（同形缺陷）。此处按 lead 裁决「回执写失败不得 status:ok」修，属**有意优于参考实现**，已在返回值里保留 `detail` 便于诊断。

---

## F5（P2）`available()/select()` 建目录副作用 + 写端不可用拖垮整个 shared 视图

**修法**（全部在 `rhop/session.mbt`，不改 transport 层）：
1. `:257` `sp_is_local_endpoint`：用 `SharedPath::name` 前缀 `shared:local:` / `shared:file-url:` 识别本地端点适配器（`EndpointSharedPath.root()` 恒 `None`，不能靠 root 判断）。
2. `:269` `sp_side_usable(sp, for_write)`：纯探测——先 `exists(".")`（读侧）/`exists(".")||exists("..")`（写侧，写入时自建目录）；本地端点存在性不满足即判不可用（**绝不为了探测而建目录**）；非本地端点（http(s)）才回退 `available()`（HTTP GET，无写入副作用）；`root()` 已知的 mock/`LocalSharedPath` 同理走存在性。
3. `:292` `pick_shared`（读侧）与 `:306` `pick_shared_write`（写侧）分离；`available()`（`:323`）= relay > online > 读侧 > 写侧；`select()`（`:350`）shared 分支读侧不可用但写侧可用时仍报 shared。
4. `send_package` 用写侧（`:447` `pick_shared_write`）、`recv_package` 用读侧（`:333` 附近的判定链与 `:526` 起）；写端不可用时给出**专门** Err「shared path 写端不可用（介质只读）」/ 读端不可用时「shared path 读端不可用（介质无读取视图）」，替代笼统的「全不可达」。
5. doc 明确「探测不产生副作用，可用于热路径」。

**证据**：

```
interact · available()/select() 不建目录；只读接收端可收（C1-F5） → passed
  ffi_exists(dir+"/fresh")==false → available()==true → 仍 false → select().transport=="shared" → 仍 false
  send_package 之后 ffi_exists(dir+"/fresh/pkg.rhop")==true（只有真发送才建目录）
  只读接收端（write 不可写/read=dir）recv_package("ro.rhop") → status:"ok"
interact · 只读介质：接收端能收、发送端给出「写端不可用」专门 Err（C1-F5） → passed
  recv ok；write="…/blocker3/sub"（父路径是文件）→ send 得 status:"error" 收据（非笼统全不可达）
  write="…/nodir/sub"（父目录不存在，本地端点）→ send 得 Err contains "写端不可用"，且 !ffi_exists(dir+"/nodir")
session · shared 读/写分开判定：只读介质不被判全不可达，发给出专门 Err（C1-F5） → passed（wasm/js/native）
  RootedPath mock：available()==false（证明不再依赖 Mock.available），read 侧 exists(".") 即判可用，
  recv_package 不再被写端拖死；select().transport=="shared"
```

写侧专门 Err 的断言放在 js 包（非 js 目标 `RhopCrypto` 无法加密，`send_package` 会先卡在「加密不可用」，见 `session.mbt:406-409`），故 `session_test.mbt:686` 用例只覆盖跨目标的读侧判定，并在注释里写明分工。

---

## F6（P2）`to_dict()` 明文导出 `online/relay` 凭据

**修法**：`rhop/config.mbt`
- `:529` `cfg_is_secret_key(key)`：大小写不敏感匹配 `password/passwd/key_path/private_key/secret/token/api_key/access_token/refresh_token`。
- `:544` `cfg_mask_deep(value)`：对象逐键（敏感 → `"***"`，否则递归）、数组逐项递归、标量原样；`:573` `cfg_mask_deep_or_null` 处理 `None → null`。
- `:582` `cfg_mask_secrets` 改为对 sftp 走 `cfg_mask_deep`；`:234-243` `to_dict` 的 `online/shared/relay` 从原样透出改为 `cfg_mask_deep_or_null`。

**证据**（`config_test.mbt:553`）：

```
config · to_dict 递归掩码：online/relay/shared 的 password/key_path/token 都是 *** → passed
  串里预埋 SFTP-PW-X / ONLINE-PW-X / /id-online-x / ONLINE-TOKEN-X / INNER-TOKEN-X /
  RELAY-TOKEN-X / SHARED-PW-X → Json::stringify(to_dict()) 均**不含**这些明文；
  同时 role/online[0].password="***"/online[1].token="***"/relay.host="10.0.0.1"/relay.token="***" 结构不变
```

**注意**：`action_cfg()`（`config.mbt:425-431`）仍**原样**透出 `sftp`（含密码），这是对照 vools `config.py:205-207` 的**有意行为**——动作处理器需要真实凭据；掩码只作用于 `to_dict()` 这类对外展示面。

---

## F7（P2）Python `or` 语义未复刻

**修法**：`rhop/config.mbt`
- `:632` `cfg_str_or_nonblank(j,key,default)`：字段缺失 / 空串 / 纯空白都回退 default（复刻 `spec.get(k) or default`）。
- `:658` `cfg_json_int_pos(j,key,default)`：`<= 0` 回退 default（复刻 `int(port or 22)`）。
- `:671` `cfg_timeout_ms`：末尾 `if ms <= 0 { default } else { ms }`（`timeout: 0` / 负值视为未配置，回退默认 3000ms）。
- 应用点：`:381` `build_relay` host 用 `cfg_str_or_nonblank`、`:382` port 用 `cfg_json_int_pos`；`cfg_channel_from_spec` 的 sftp port 用 `cfg_json_int_pos(…, 22)`、relay 分支同规则。

**语义口径（写入 doc）**：`port: 0` 在 relay 侧合法（表示「由 `RelayChannel` 自选/未指定端口」，`port or 0` 的 Python 同形），在 sftp 侧回退 22；`timeout <= 0` 一律回退默认值而非「0 毫秒」。

**证据**（`config_test.mbt:598`）：

```
config · build_relay：host 空串回退 127.0.0.1；port 0/负值归一（C1-F7） → passed
  {"host":"","port":9000} → base()=="http://127.0.0.1:9000"（修复前是 "http://:9000"）
  port 0 与 -5 → "http://127.0.0.1:0"；{"host":"h","port":1,"timeout":0} → "http://h:1"（不 panic、不 0ms）
```

---

## F8（P2）类型校验不一致 + 静默降级

**修法**：`rhop/config.mbt`
- `:464` `cfg_channel_from_spec` 开头加类型门：非对象 → `Err "在线通道配置必须是对象（kind 缺省 sftp）: <原文>"`（修复 `online:["oops",42]` 静默造两个空 sftp 通道）。
- `:178` `from_dict` role：`Some(String(s))` 且 `s.trim()` 为空 → `Role::Send`（复刻 `data.get("role") or SEND`）。
- `:311-335` `build_shared`：空对象 `{}` → `Ok(None)`（复刻 `if not self.shared: return None`），同时保留「有键但缺 write/spec → Err」。
- `:137` `_key_from_cfg`：`true/false` 不再当密钥文本，直接 `Err "配置字段 key 不接受布尔值（请用字符串，或对象 {plain|cipher|path|env|source}）"`。

**有意差异（需 lead 知悉）**：vools 用 `str(True)` → `"True"`；MoonBit 的布尔字符串化是 `"true"`，静默接受会让同一份配置在两边解出**不同密钥**，因此选择显式拒绝而不是模仿。数字 key（`{"key":12345}`）仍按 JSON 文本 `"12345"` 接受（`config_test.mbt:151` 覆盖）。

**证据**（`config_test.mbt:648`）：

```
config · F8 语义对齐：role 空串→SEND、shared {}→None、online 非对象→Err、key 布尔→Err → passed
  role "" / "  " → Role::Send；shared {} → build_shared Ok(None)
  {"online":["oops",42]} → build_online Err contains "必须是对象"
  {"key":true} / _key_from_cfg(Some(false)) → Err contains "不接受布尔值"
```

---

## 测试层缺口

| # | 状态 | 处置 |
|---|---|---|
| T1 | 已修 | `config_test.mbt:130-134` 弱断言收紧：`{"plain":""}` 只能是「来自 env/path 的非空密钥」或 `Err "未找到本地固定密钥"`，不再接受空串或宽泛 `contains` |
| T2 | 已修 | F6 用例覆盖 online/relay/shared 嵌套掩码（`config_test.mbt:553`） |
| T3 | 部分 | `session_test.mbt` 新增 `RootedPath` mock（`available()` 恒 false、`exists("."/`..`)` 可控），使「读端可用性不依赖 `available()`」可测；原 `MemPath::read_text` 不检查 `reachable` 的历史 mock 未改（它已不参与可用性判定，改动价值低） |
| T4 | 已修 | 新增穿越名 / `shared:{}` / `role:""` / `relay.host:""` / `key:true` 用例 |
| T5 | 已修 | F1（发送失败 + 旧 `res_`）、F4（回执写失败）均有独立用例 |
| T6 | 未做 | 「`describe()` 快照」「减少 `contains` 改结构断言」属测试风格重构，未在本轮范围，登记 |

---

## 未修项与移交

### F3（P1，登记）通道选择把「探活」当「能发」

`rhop/session.mbt:416-506` 的 `pick_online` 只看 `OnlineChannel::available`（sftp 即 TCP 探活），而 `rhop/online.mbt:144-155` 的 `send/receive` **恒 Err**（无 paramiko 等价能力），且在线通道失败后**不回退 shared**。因此「配了 sftp online + 可用 shared」的配置下发送整体失败。修法需要 online lane 二选一：①给 `OnlineChannel` 加 `can_send/can_receive` 能力查询（sftp 返 false，通道链跳过）；②`send_package` 在 online 失败时回退 shared。两方案都触碰 `online.mbt`/`transport_base.mbt`，按指令未动。

### F9（P2，登记）sftp 凭据被静默丢弃

`rhop/config.mbt:464` 的 sftp 分支只构造 `SftpChannel::new(host,port,dir).with_username(user)`，`password/key_path/probe_mode` 无处可放——`rhop/online.mbt:85-91` 的 `SftpChannel` 没有这些字段。要么扩 `SftpChannel` 字段，要么在 `cfg_channel_from_spec` 显式 Err「sftp 凭据字段当前不受支持」以免静默丢失；属 online lane 决策。

### F10（P3，部分）动作注册面

`rhop/actions.mbt` 的 `run_action` 可用列表未排序（vools 用 `sorted(ACTIONS.keys())`）、`omega_unwrap` 对空 `omega_gate:{}` 不回退「外层状态异常」——归 actions lane（Batch D），本轮未改（该文件已被接管）。`interact` 的 `mode` 保留 `trim + to_lower`（vools 精确匹配，`"EXECUTE"` 直接 ValueError）：MoonBit 侧选择更宽松的入口归一，**行为差异已在此登记**；如需严格对齐，改为精确匹配即可（一行）。

### F11（P3，登记）`load_config` 的 JSON 文本 / 路径二义

`rhop/config.mbt:417-435` 仍把「非 JSON 对象的字符串」当文件路径（`load_config("{not-json")` → ENOENT 文案）。vools 是「dict 或路径」二选一，本实现的「先试 JSON 文本」是便利扩展；错误文案已带路径，可诊断，故保留。`res_res_a.rhop` 自噬由 F1 的一次性消费 + token 校验消解（回执取回即删，且 token 不匹配会被拒）。

---

## 附：本轮新增/变更的公开 API

| API | 文件:行 | 用途 |
|---|---|---|
| `pub fn safe_filename(String) -> Result[String,String]` | `rhop/session.mbt:88` | 包名白名单（防穿越），session/interact 共用 |
| `pub fn Session::remove_package(Self, String) -> Result[Unit,String]` | `rhop/session.mbt:588` | 一次性消费 `res_` 包（幂等） |

内部新增（非 pub）：`sp_is_local_endpoint`、`sp_side_usable`、`Session::pick_shared_write`（session.mbt）；`cfg_is_secret_key`、`cfg_mask_deep`、`cfg_mask_deep_or_null`、`cfg_str_or_nonblank`、`cfg_json_int_pos`（config.mbt）；`interact_nonce`、`interact_next_token`（interact.mbt）。
