# C1 寻虫报告 — Batch C（session / config / interact / actions 注册面）

> 任务：rx-mbt（MoonBit 模块 vicTop-cw/RX-MBT）C1 寻虫审计，范围：`rhop/session.mbt`、`rhop/config.mbt`、`rhop/interact.mbt`、`rhop/actions.mbt` 注册面 + 三个测试文件（`test-suit/rhop/{session,config}_test.mbt`、`test-suit/rhop_interact/interact_test.mbt`）。
> 方式：**只读审计，未改真树任何产品代码/测试，未提交 git**。动态证据在一次性副本 `E:/tmp/c1audit`（真树 tar 拷贝 + 新增 throwaway 测试包 `test-suit/c1audit`，已跑 js 目标 10/10 通过——断言的是「当前行为」，因此通过即证明缺陷存在）。
> 对照基线：vools 参考实现 `E:/IDEProjects/AI/vools/rhop/vools/rhop/{session,config,interact}.py`、`actions/__init__.py`。
> 审计人：impl-session　时间：2026-10-28（UTC+8）　结论：**4 条 P1 / 6 条 P2 / 3 条 P3 + 6 条测试层缺陷**；其中 **F1、F2 建议阻塞验收**。

---

## 0. 汇总表

| # | 严重度 | 位置 | 一句话 | 阻塞验收 |
|---|---|---|---|---|
| F1 | **P1** | `rhop/interact.mbt:85-93` + `rhop/session.mbt:307-329` | roundtrip **不看投递结果**：发送失败时照样执行并对**上一轮残留的 `res_`** 解密取回，返回 `status:"ok"` + 陈旧结果（静默假成功） | **是** |
| F2 | **P1** | `rhop/interact.mbt:222`、`rhop/session.mbt:291/366`（根因 `rhop/transport_local.mbt:106-116`） | 文件名零净化：`../escaped.rhop` 实测写到 shared 根**之外**；默认文件名把 action 直接拼进路径 | **是** |
| F3 | P1 | `rhop/session.mbt:307-329` + `rhop/online.mbt:144-155` | 通道选择把「TCP 探活成功」当「能发」，而 sftp send **恒 Err**，且**不回退 shared** → 配了 online 就整体发不出包 | 否（登记 known-limitation） |
| F4 | P1 | `rhop/interact.mbt:200-213` | `handle_request` 回执写失败仍返回 `status:"ok"`，失败只藏在 `response_sent` → 请求方永远等不到回执 | 否（与 vools 同形） |
| F5 | P2 | `rhop/session.mbt:178/194/205` → `rhop/transport_local.mbt:29-34` | `available()/select()` **有建目录副作用**（实测创建 write/read 两侧目录）；且「写端不可写 ⇒ 整个 shared 视图不可用」，即使读端完全可读 | 否 |
| F6 | P2 | `rhop/config.mbt:498-520`（`cfg_mask_secrets` 只作用 sftp）+ `config.mbt:224-234`（`to_dict`） | `to_dict()` 明文导出 `relay.token`、`online[*].password/key_path/token`（sftp 已掩码） | 否 |
| F7 | P2 | `rhop/config.mbt:360`、`rhop/config.mbt:560-572`、`rhop/config.mbt:443-494` | Python `or` 语义未复刻：`relay.host:""` → `http://:9000`；`sftp.port:0` → 保持 0（vools 回退 22）；`timeout:0` → 0ms | 否 |
| F8 | P2 | `rhop/config.mbt:270-287/297-339/162/77` | 类型校验不一致 + 静默降级：`online:["oops",42]` 静默造出两个空 sftp 通道；`shared:{}` → Err（vools None）；`role:""` → Err（vools SEND）；`key.plain:123` → 落到 RHOP_KEY 报「未找到密钥」；`key:true` → `"true"` vs vools `"True"` | 否 |
| F9 | P2 | `rhop/config.mbt:443-494` + `rhop/online.mbt:85-91` | sftp 的 `password/key_path/probe_mode` 被静默丢弃（SftpChannel 无这些字段）；sftp 只能探活不能收发——跨 lane 契约缺口 | 否（登记） |
| F10 | P3 | `rhop/actions.mbt`（`run_action` / `omega_unwrap`）、`rhop/interact.mbt:54-56` | 可用列表未排序；`omega_gate:{}` 不回退「外层状态异常」；非对象入参文案与 vools 不同；`mode` 被 `to_lower`（vools 精确匹配，`"EXECUTE"` 实际执行） | 否 |
| F11 | P3 | `rhop/interact.mbt:222`、`rhop/config.mbt:417-435/210-260`、`rhop/online.mbt:163-175` | `load_config("{not-json")` 把 JSON 文本当路径报 ENOENT；`handle_request("res_a.rhop")` 可消费自己的回执（`res_res_a.rhop`，无防自噬/幂等）；每次探测 spawn node 子进程 | 否 |
| T1 | P2 | `test-suit/rhop/config_test.mbt:131-132` | 弱断言：`Ok(k) => assert_true(k == "" || k.contains("rhop"))`，`Err(e) => … "密钥" || "RHOP_KEY"` → 三选一/环境变量会让本应红的用例变绿 | 否 |
| T2 | P2 | `test-suit/rhop/config_test.mbt:197-240` | 掩码只测 sftp；online/relay 断言为 null → **F6 无回归网** | 否 |
| T3 | P2 | `test-suit/rhop/session_test.mbt:55-63` | mock `MemPath::read_text` 不检查 `reachable`（只有 `write_text` L45-48 检查）→ 「不可达介质上的读失败」路径在测试里不存在 | 否 |
| T4 | P3 | 三个测试文件 | 无 `filename` 穿越/空/绝对路径用例（F2 无网）；无 `shared:{}`/`role:""`/`relay.host:""`（F7/F8 无网） | 否 |
| T5 | P3 | `test-suit/rhop_interact/interact_test.mbt` | 未覆盖「发送失败 + 旧 res_ 存在」（F1）、「回执写失败但报 ok」（F4）、`response_sent!="ok"` | 否 |
| T6 | P3 | 三个测试文件 | 结构断言多用 `contains`；`describe()` 无快照 → 字段增删/文案漂移不报红 | 否 |

> 判绿口径提醒：F1 说明**现有 13 个 interact_test 全绿并不能证明 roundtrip 语义正确**——它们都在「发送成功」路径上跑。

---

## F1（P1）roundtrip 忽略投递失败，用上一轮 `res_` 冒充成功

**位置**：`rhop/interact.mbt:85-93`（roundtrip 分支）；配合 `rhop/session.mbt:307-329`（send_package 把 I/O 失败归一成 `{status:"error"}` 回执）。

**现象**：`interact(..., mode="roundtrip")` 完全**不检查** `sent.status`：请求包没写成功，照样 `handle_request` 去消费**旧请求包**，再把**旧回执** `res_<filename>` 解密取回，返回 `{"status":"ok", …, "action_result": {... 上一轮的 payload ...}}`。调用方看到 ok + 合法结构，误以为本轮请求成功。

**证据**（`E:/tmp/c1audit`，js 目标，A6 用例）：先跑一轮 marker=`run1` 留下 `res_rt.rhop`；再让 `rt.rhop` 写入失败（目标路径被造成目录），`request` 模式如实报错，`roundtrip` 却绿：
```
A6 第二轮 request（应失败）=> {"status":"error","transport":"shared","filename":"rt.rhop","reason":"rhop: 原子替换失败: C:/Users/victo/AppData/Local/Temp/c1a6-BcnWgp/a/rt.rhop.tmp -> .../a/rt.rhop: EPERM: operation not permitted, rename ..."}
A6 第二轮 roundtrip => {"status":"ok","transport":"shared","filename":"rt.rhop","response_transport":"shared","response_filename":"res_rt.rhop","result":"ok","action_result":{"status":"ok","action":"rhop.echo","cfg":{...},"payload":{"marker":"run1"},"offline":true}}
A6 返回结果的 marker=run1（本次请求的是 run2）
```

**根因**：①roundtrip 只看「取回成功」；②`res_` 取回没有任何「这是本轮回执」的凭据（无 request id / nonce / 时间戳校验），也无法区分「本轮刚写」与「历史残留」。vools `interact.py:70-77` 同样不查 `sent`，但 vools 的 `send_package` 在 I/O 失败时**抛 IOError**，流程根本到不了取回；我们有意把 I/O 失败降级为回执（session.mbt 注释声明的差异），于是这个上游同形缺陷在我们这里被**放大成静默假成功**。

**修法**：`sent.status != "ok"` 时直接返回 `{status:"error", phase:"send", detail:sent}`；roundtrip 发送前 `remove(res_filename)`（旧回执清除）；中期在协议包加 `request_id` 并在 `res_` 回带校验。回归用例：伪造「发送失败 + 旧 res_」必须返回 error。

**影响**：单机闭环是 Batch C 的验收演示路径，也是 daemon 请求-响应主路径；在介质满/权限/并发改名任一情况下都会把旧结果当新结果返回，且 `omega_gate` 表现为成功 → 下游据此判绿。

---

## F2（P1）文件名零净化：路径穿越写穿 shared 根

**位置**：`rhop/interact.mbt:222`（`interact_default_filename` 仅 `replace(".","_")`）、`rhop/session.mbt:291`（send_package）/`:366`（recv_package）直接透传 filename；根因落点 `rhop/transport_local.mbt:106-116`（`join_shared` 只折叠斜杠，**不消解 `..`**）、`normalize_path`（不解析 `.`/`..`）。

**现象**：`send_package("../escaped.rhop", …)` 返回 ok，文件落到 shared 根**之外**。同理：`handle_request(cfg, "../../somefile")` 可读任意路径；`interact(action="../../x", …)` 的默认文件名把 action 原样拼进路径（`"req_" + action.replace(".","_") + ".rhop"`），action 里的 `/`、`\`、`..` 全部保留。

**证据**（A4 用例）：shared 根 `.../c1a4-osfKdG/share`：
```
A4 send(../escaped.rhop) => {"status":"ok","transport":"shared","filename":"../escaped.rhop","role":"SEND"}
A4 根外文件 C:/Users/victo/AppData/Local/Temp/c1a4-osfKdG/escaped.rhop 存在=true
```
（断言通过 = 文件确实写到根外。）

**根因**：整条链路上没有任何一层把 filename 当「不可信输入」：session 透传 → SharedPathView 透传 → LocalSharedPath.join_shared 拼字符串 → `fs_ensure_parent` 还会顺着 `..` 建目录。`normalize_path` 明确只做斜杠归一，注释里也没写「不解析 `..`」。

**修法**：①在 `session.mbt` 入口加 `fn safe_filename(name : String) -> Result[String,String]`：拒绝空串、`.`/`..`、含 `/` `\`、含 `..` 段、绝对路径（盘符/`/` 开头）、`file://`/`http(s)://`、Windows 保留名（CON/NUL/COM1…）与 `:`；②`interact_default_filename` 对 action 做白名单替换（`[^A-Za-z0-9._-] → _`，并折叠前导点）；③跨 lane 建议（`transport_local.mbt` 属其他 lane）在 `join_shared` 里消解 `..` 并断言结果仍以 `root + "/"` 为前缀，双保险。

**影响**：shared 根通常是共享/挂载目录；穿越可覆盖上层任意文本文件（包括配置、密钥材料、`.rhop` 包）。写入的是密文包，但「任意文件覆盖」本身已是完整性问题。vools 同样未校验（`Path(root)/name` 会穿越），**这是需要超越上游的项**，不能以 parity 为由放行。

---

## F3（P1）通道选择把「探活」当「能发」，且不回退

**位置**：`rhop/session.mbt:307-329`（send_package 的 label→传输链）、`:178-205`（pick_relay/pick_online/pick_shared 都按 `available()` 选）、`rhop/online.mbt:144-155`（`SftpChannel::send/receive` 恒 Err「未在本实现落地」）。

**现象**：配置 `online:[{"kind":"sftp","host":"127.0.0.1","port":22}]` 且 22 可达（或 git remote 可达）→ `pick_online` 命中 → `transport:"online"` → `OnlineChannel::send` 返回 Err → 回执 `{status:"error", reason:"rhop sftp: send 未在本实现落地…"}`。**不会回退到已配置好的 shared**。即「一旦配了 online，整个会话发不出包」，且错误指向实现缺口而非配置。

**证据**：静态（online.mbt L144-155 恒 Err + session.mbt L307-329 无回退分支）；现有测试无一覆盖「online 可达但 send 不可用」——`session_test` 用 mock `MemChannel` 的 send 会成功，`interact_test` 只跑 shared/relay，所以这条缺口全绿。

**修法**：三选一 —— (a) `build_online` 对 `kind:"sftp"` 直接 Err（未实现即拒配，fail-fast）；(b) `send_package` 在 outcome Err 且存在 shared 视图时回退 shared 并标注 `fell_back:true`；(c) 中期由 sftp lane 落地 send/receive。(a) 最快且最诚实。

**影响**：迁移 vools 配置（vools 有 paramiko，sftp 可发）会得到「配置看起来合法、但一条都发不出去」；这是交付后最容易被外部使用者踩到的坑。

---

## F4（P1）handle_request 回执投递失败仍报 status:"ok"

**位置**：`rhop/interact.mbt:200-213`（`let sent = …` 到 `Ok({...})`，`response_sent` 在 L211）。

**现象**：响应包写失败（介质满/目标改名失败/目标路径是目录），`handle_request` 仍返回 `{"status":"ok", "response_sent":"error", …}`；调用方若以 `status` 判成功（vools 语义如此），会认为「请求已处理且回执已送达」。

**证据**（A5 用例：把 `a/res_x.rhop` 预先造成目录）：
```
A5 handle_request => {"status":"ok","action":"rhop.echo","transport":"shared","result":{...},"response_filename":"res_x.rhop","response_sent":"error"}
```

**根因**：无条件 `Ok(...)`，发送状态仅作为附字段（vools `interact.py:130-136` 同形）。属忠实复刻的上游缺陷。

**修法**：`response_sent != "ok"` → 返回 `{status:"error", phase:"response", detail:sent, action, …}`（或 `"partial"` 并让上层显式处理）。若为保持 vools 兼容，可保留 ok 但新增 `degraded:true` 并在文档标注——不推荐，daemon 不会看新字段。

**影响**：请求已执行但结果永久丢失，请求方轮询 `res_` 永远落空，且两端都以为一切正常。

---

## F5（P2）available()/select() 建目录副作用；写端不可写拖垮整条 shared

**位置**：`rhop/session.mbt:217`（available）、`:240`（select）、`:178/194/205`（pick_*）→ `rhop/transport_local.mbt:29-34`（`LocalSharedPath::available` = `fs_ensure_dir`）→ `rhop/transport_base.mbt`（`SharedPathView::available` = `write.available && read.available`，两侧都探测）。

**现象 1（副作用）**：只调用 `Session::available()`（纯查询语义）就会把配置里 write/read 两侧目录**创建出来**。
**证据**（A3 用例，调用前两侧均不存在）：
```
A3 available=true created_write=true created_read=true
```
**现象 2（可用性误判）**：`SharedPathView::available` 要求**写端可建目录**；当写端只读/不可写而读端完全可读时，整个 shared 视图被判「不可用」→ `recv_package` 直接失败（真实场景：接收端只挂载只读共享、发送端另配写视图）。
**根因**：把「可用」实现成「能建目录」，且写视图的可用性被拿来否决读能力。

**修法**：`LocalSharedPath::available` 改为 `fs_stat(root).is_dir`（不改文件系统）；`SharedPathView::available` 拆为 `write_available/read_available` 并让 send/recv 各自判；`Session::available()/select()` 文档标注「纯探测、无副作用」。

**影响**：①daemon 轮询探活会在任意配置路径上建目录（与 F2 叠加时可建到根外）；②只读接收端无法工作——这是实打实的功能缺失，不只是洁癖。

---

## F6（P2）to_dict 只掩码 sftp，online/relay 凭据明文导出

**位置**：`rhop/config.mbt:498-520`（`cfg_mask_secrets` 仅处理 sftp 的 password/key_path）、`rhop/config.mbt:224-234`（`to_dict` 的 `online`/`shared`/`relay` 走 `cfg_json_or_null` 原样透出）。

**证据**（A1 用例真实 dump，sftp 已掩码、其余明文）：
```
A1 to_dict={"name":"rhop-config","role":"SEND","has_key":true,
 "sftp":{"host":"h","password":"***"},
 "online":[{"kind":"sftp","host":"h","password":"ONLINE-PW-X","key_path":"/id-rsa-X","token":"ONLINE-TOKEN-X"}],
 "shared":null,
 "relay":{"host":"10.0.0.1","port":9000,"token":"RELAY-TOKEN-X"}}
```

**根因**：vools `config.py:147-159` 只掩码 sftp，我们按 parity 复刻；但我们的 online spec 是**原样 Json**（vools 侧 online 存的是对象属性），透出的面更大。

**修法**：`cfg_mask_secrets` 递归遍历 Object 子树，对键名 `password|passwd|key_path|private_key|token|secret|api_key`（大小写不敏感）统一 `"***"`；补测试断言 online/relay 掩码。**这是可以修而不破坏 parity 的项**——vools 没有这些字段的掩码只是因为它的数据形状不同。

**影响**：`to_dict()` 是「可安全打日志/进报告」的接口（`has_key` 的设计意图如此）；现在 relay token（可冒充中转端注入包）、sftp 密码/私钥路径会进日志与验收产物。

---

## F7（P2）Python `or` 语义未复刻：空串 / 0 / 0 秒

**位置**：`rhop/config.mbt:360`（`cfg_str_or(spec,"host","127.0.0.1")` 仅缺字段才默认）、`rhop/config.mbt:560-572`（`cfg_json_int` 原样取 0）、`rhop/config.mbt:443-494`（sftp port 默认 22 但 0 原样）、`rhop/config.mbt:576-585`（timeout 秒×1000，0 保持 0）。

**证据**（A2 用例）：
```
A2 relay host="" => {"name":"rhop-config","role":"SEND","online":[],"shared":null,"relay":"http://:9000","has_crypto":true}（vools: http://127.0.0.1:9000）
A2 sftp port=0 available=false（vools: 端口回退 22）
```
（vools `config.py:90-93`：`host = spec.get("host") or "127.0.0.1"`、`port=int(spec.get("port",22) or 22)`、`timeout=float(spec.get("timeout",3.0) or 3.0)`——`or` 把 `""`/`0`/`0.0` 都吞掉。）

**修法**：`cfg_str_or` 增 `blank_fallback` 语义（或新增 `cfg_str_or_nonblank`）供 relay.host 用；`cfg_json_int` 增 `zero_fallback` 供 port（sftp 22、relay 0 保持）；`cfg_timeout_ms` 对 0 回退默认 3000；文档写明「0 表示默认」。

**影响**：手写配置把 host 留空（很常见）→ `http://:9000` 连接必失败且报错模糊；`port:0`/`timeout:0` 静默变成「非法端口 / 立即超时」，排障成本高。

---

## F8（P2）配置类型校验不一致 + 静默降级

**位置/证据**（一条 A 用例内多条）：
```
A2 role="" => Err:未知角色: （可用 SEND/RECV/RELAY）（vools: SEND）
A2 shared={} build_shared => Err:shared 配置缺少 write/spec 字段（vools: None）
A10 build_online(["oops",42]) => Ok(count=2)（vools: AttributeError 崩）
A10 describe={"name":"rhop-config","role":"SEND","online":["sftp:*@:","sftp:*@:"],"shared":null,"relay":null,"has_crypto":true}
A8 key.plain=123 => Err:rhop: 未找到本地固定密钥。请通过 source / path / 环境变量 RHOP_KEY 提供。（vools: Ok("123")）
A8 key=true => key="true"（vools: "True"）
```
- `online` 元素非对象（字符串/数字）→ `cfg_channel_from_spec` 静默当 `kind:"sftp"`、host `""` → 造出 `sftp:*@:` 死通道，会话 `available()==false`，报错却是「无可用的传输介质」；vools 直接 AttributeError（两边都不理想，但我们的静默降级更难排障）。
- `shared:{}`（最常见的「没配」写法）→ `build_shared` Err，打断 onboarding；vools 视为 None。
- `role:""` → Err「未知角色: 」，vools 视作 SEND。
- `key:{"plain":123}` → 落进 `load_key`，给出「未找到本地固定密钥…RHOP_KEY」的**误导性错误**（vools 接受 `str(123)`）。
- `key:true` → `"true"`；vools `str(True)` = `"True"`。**密钥字节不一致**：凡用该 key 派生/加解密的两端实现无法互通。

**修法**：①`cfg_channel_from_spec` 对非 Object 直接 Err「在线通道配置必须是对象，收到: …」；②`build_shared` 对空 Object → Ok(None)（与 vools 对齐）；③`Role::parse` 空串 → Send（配置层特殊处理，保持 `Role::parse` 本身严格）；④`_key_from_cfg` 对 plain/cipher 的非字符串按显式规则归一（建议：`Json::stringify` 后仅接受 `number/boolean` 的十进制/`true|false`，并**把「跨实现密钥表示」写进 decision 文档 + 加对照向量**，因为 Python `str()` 与 MoonBit stringify 在布尔/浮点上不同）；⑤对 `key` 的 Err 文案追加「也可能是 key.plain/cipher 形态非法」。

---

## F9（P2）sftp 认证字段无处落地（跨 lane 契约缺口）

**位置**：`rhop/config.mbt:443-494`（构建 sftp 时只取 host/port/dir/username，**丢 password/key_path/probe_mode**）、`rhop/online.mbt:85-91`（`SftpChannel` 无这些字段）、`online.mbt:144-155`（send/receive 恒 Err）。

**现象**：迁移 vools 配置里的 `sftp.password`/`key_path` 后，值被静默丢弃；`action_cfg()` 里 `sftp` 是**原文**（含 password），说明动作侧期待认证信息，通道侧却没有入口——同一份配置两个消费者、能力不对齐。

**修法**：由 online lane 决定：要么 `SftpChannel` 增 `with_password/with_key_path/probe_mode` 并实现收发；要么在 `build_online` 明确拒绝 `kind:"sftp"`（配合 F3 的 fail-fast），并在 decision §3 标注「sftp 未落地」。当前状态建议在 README/decision 里显式登记为 known gap，避免验收时被当缺陷重复挖。

---

## F10（P3）actions 注册面与 vools 的细节偏差

- `rhop/actions.mbt` `run_action` 未知动作：`known = list_actions().join(", ")`（插入序），vools `actions/__init__.py:44` 用 `sorted(ACTIONS.keys())` → 文案顺序随注册顺序漂移，快照/文档不稳定；建议 `list_actions()` 返回前排序或 join 前排序。
- `run_action` 已知动作**无异常兜底**（vools 有 try/except → `{status:"error", omega_gate:{error:"动作执行异常: …"}}`）。MoonBit 没有异常，但 handler 里任何 `abort()` 会杀整个进程而非返回错误结构——应在 actions 约定里写明「handler 禁止 abort/fail，必须返回 error 结构」。
- `omega_unwrap`：外层非 ok 时 `Some(g) => g`，vools 是 `result.get("omega_gate") or {"error":"外层状态异常"}` → `omega_gate:{}`（空对象）在我们这里**原样返回空对象**，诊断信息丢失；非对象入参我们报「外层状态异常」、vools 报「非 dict 结果」。建议对齐 Python truthiness（空对象/Null 都回退）。
- `interact` 的 mode 被 `trim().to_lower()`，vools 精确匹配（`interact.py:64-65`）。A9 用例：`mode="EXECUTE"` 在我们这**实际执行**并返回 ok（vools 会 ValueError）。宽松对用户友好，但属 parity 偏差 → 文档写明，测试覆盖两种写法。

---

## F11（P3）其余细节

1. `load_config("{not-json")`（A8）→ `Err:读取配置文件失败: {not-json: ENOENT…`——把非法 JSON 文本当路径，报文虽含原因但易误读；建议 Err 前缀改为「既不是合法 JSON 对象，也不是可读文件: …」。
2. `handle_request(cfg,"res_a.rhop")`（A7）→ 正常执行并生成 `res_res_a.rhop`；即**回执包可被当请求包再消费**（无防自噬、无去重、无幂等键）；同 filename 重放会重复执行动作。建议：拒绝 `res_` 前缀入参，或加 `request_id` + 已处理集合。
3. 性能：`Session::available()/select()/send_package` 每次对 sftp/git 通道都 `execFileSync` 起一个 node 子进程（`online.mbt:163-175`，超时=timeout+3000）或跑 `git ls-remote`（3–5s）。daemon 轮询/多通道场景成本被放大；建议 `available()` 结果短缓存或改纯同步 socket 探活。
4. `interact` 的 `request_filename` 被 `trim()`（空白→走默认名），vools 保留 `" "` 当文件名——差异无害但需记录。
5. `describe()` 的 `shared` 输出 `"shared:A->B"`（`SharedPathView::name`），vools `getattr(shared,"name",None)` 是单名字符串 → 消费方解析差异（文档已声明）。
6. `from_file` 用**未 trim** 的 path 读文件（前面已用 trimmed 判空）→ `" path "` 会读 `" path "` 而非 `"path"`；建议统一用 trimmed。

---

## 测试层缺陷

- **T1（P2）** `test-suit/rhop/config_test.mbt:131-132`：path/env 分支的弱断言——`Ok(k) => assert_true(k == "" || k.contains("rhop"))`（本来期望 Err 的分支，若环境里恰有 `RHOP_KEY`，`k` 为空串也放行）、`Err(e) => assert_true(e.contains("密钥") || e.contains("RHOP_KEY"))`（两选一）。建议：用例内显式清空/隔离环境变量，断言精确错误前缀。
- **T2（P2）** `config_test.mbt:197-240`：掩码只测 sftp；`online/relay` 被断言为 null → F6 不可能被发现。补：带 token/password 的 online/relay + 递归掩码断言。
- **T3（P2）** `test-suit/rhop/session_test.mbt:55-63`：mock `MemPath::read_text` 不检查 `reachable`（只有 `write_text` L45-48 检查，而 `available()` L39-41 只看 `reachable`）→ **「不可达介质上的读失败」这一真实路径在测试里根本不存在**：L294「全部不可达」用例停在 session 层（`pick_shared` 返回 None，L308 断言 `全不可达`），L418「介质缺文件」用例用的是 `reachable=true` 的介质。建议 `read_text` 先判 `reachable` 返回「不可达」错，并补「available 为真、读时失败（可达性中途丢失）」用例。
- **T4（P3）** 无 `filename` 边界用例（`..`、`/`、绝对路径、空、含 `\`）→ F2 无回归网；无 `shared:{}`、`role:""`、`relay:{"host":""}`、`sftp.port:0` → F7/F8 无网。
- **T5（P3）** `interact_test.mbt` 未覆盖：发送失败 + 旧 `res_`（F1）、回执写失败但报 ok（F4）、`response_sent!="ok"`；现有 roundtrip 用例全在成功路径。
- **T6（P3）** 结构断言多为 `contains`；`describe()` 无快照 → 字段增删/文案漂移静默。建议对 `describe()/to_dict()/omega_unwrap` 输出用 `assert_eq` 全等或 `debug_inspect` 快照。

---

## 附 A：复现方法（一次性，勿提交）

```bash
# 一次性副本（真树不动）
cd /e/IDEProjects/AI/rx-mbt && tar --exclude=./_build --exclude=./.git -cf - . | (cd /e/tmp/c1audit && tar xf -)
# 新增 test-suit/c1audit/{moon.pkg, c1audit_test.mbt}（import rhop + core/json，options targets: {"c1audit_test.mbt":["js"]}）
export PATH="/c/Program Files/nodejs:/c/Users/victo/.moon/bin:/usr/bin:/bin"
cd /e/tmp/c1audit && moon test test-suit/c1audit --target js
# 结果：Total tests: 10, passed: 10, failed: 0.  ← 断言的是「当前缺陷行为」，全绿即缺陷复现成功
```
用例与覆盖：A1 to_dict 泄露 / A2 空值与 or 语义（role、shared、relay.host、port=0）/ A3 available 建目录 / A4 路径穿越 / A5 回执失败报 ok / A6 陈旧 res_ 假成功 / A7 res_ 自噬 / A8 key 形态与 load_config 报文 / A9 mode 大小写 / A10 非法 online spec 静默造通道。

## 附 B：未验证 / 不在本报告结论内

- wasm/native 目标下 config 的 `path/env` 分支（`cfg_read_text` 恒 Err）已有测试；本报告动态证据只在 **js** 目标采集（文件系统语义只在 js 存在）。
- relay 真网络路径（子进程/端口）未复现 F1；F1 的介质侧证据用 shared 本地文件等价构造，语义同一。
- F2 的 `recv_package` 读取穿越（`../../etc/...`）未单独跑，静态路径与 send 完全一致（同一 `join_shared`）。
- `rhop/online.mbt`、`rhop/transport_*.mbt` 属其他 lane；F3/F5/F9 的**修法**落在这些文件，需由对应 lane 决定，本报告只报事实。

## 附 C：结论与建议顺序

**建议阻塞验收**：F1（静默陈旧成功，验收演示会假绿）、F2（任意路径写入，安全）。
**建议同批修（低风险）**：F5（available 改纯探测，一行级的 `is_dir` 判定）、F6（递归掩码）、F7/F8（or 语义与 `shared:{}`，影响 onboarding）。
**建议登记 known-limitation**：F3/F9（sftp 未落地 + 不回退）、F4/F10/F11（与 vools 同形或纯文案）。
测试侧最小补强（可按 T2→T4→T5→T3→T1 顺序）即可把 F1/F2/F6/F7/F8 全部纳入回归网。