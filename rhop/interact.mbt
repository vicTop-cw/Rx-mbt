// ============================================================================
// rhop · 配置驱动一键交互入口（Batch C）
//
// 对照 vools.rhop.interact：
//   rhop.interact(cfg, action="jump.push", payload={...})
//   # cfg: 密钥 + 本端角色 + 介质配置 + 对端/中转地址
//   # 自动完成: 选通道 -> 加密 -> 传输 -> 解密验证 -> 执行动作 -> 回传结果
//
// 三种模式（mode）：
//   "execute"    本端直接执行动作（jump.probe 等无对端动作）→ omega_unwrap 后的结果
//   "request"    发送侧：加密动作请求包投递到介质，交由对端处理 → 投递回执
//   "roundtrip"  单机闭环：发送请求包 → 对端（同进程模拟）取包解密执行 →
//                加密回传 → 本端取回解密验证（测试/演示用）
//
// 接收侧处理：
//   handle_request(cfg, filename)  取包 -> 解密验证 -> run_action ->
//                                  加密回传 "res_<filename>"，返回完整结果
//
// 目标说明：纯编排逻辑，三目标可编译；实际可用性取决于介质与加密的目标可用性
// （roundtrip 的真实闭环只在 js 目标成立 —— 需要 node:fs + node:crypto）。
// ============================================================================

///|
/// 配置驱动一键交互（对照 vools `interact`）。
///
/// 参数：
/// - `cfg`：已解析的 `RhopConfig`（配置对象/文件路径请先过 `load_config`）；
/// - `action`：动作名（最小集里内置 `jump.probe`）；
/// - `payload`：动作载荷（None 视为 `{}`）；
/// - `mode`：`execute` / `request` / `roundtrip`（大小写不敏感）；
/// - `request_filename`：动作包文件名（缺省 `req_<action 里的 . 换 _>.rhop`）。
///
/// 返回：
/// - `execute`   → omega_unwrap 后的动作结果；
/// - `request`   → `{"status":"ok","transport","filename","role"}` 投递回执；
/// - `roundtrip` → `{"status":"ok","transport","filename","response_transport",
///   "response_filename","result","action_result"}`，任一环节失败则
///   `{"status":"error","omega_gate":<失败环节回执>}`（与 vools 同形）。
///
/// `Err` 只用于**参数/配置类**错误：未知 mode、空 filename、配置构件无法构造、
/// 通道链全不可达。介质/加解密类失败以 `status:"error"` 结构表达（可跨进程转发）。
///
/// **探测期 vs 投递期的分界（C4 实测）**：如果连"哪条介质可用"都探不出来
/// （中转不可达、http 端点不在线、shared 不可写 —— 即 `select()` 得到 `none`），
/// 返回 `Err("…全不可达")`；一旦选出介质、**真正投递**时才失败（写不进/读不到/对端不在），
/// 返回带 `phase` 的 `status:"error"` 收据。两者都带可诊断原因，前者属于"配置/环境不成立"，
/// 后者属于"介质尽力了但失败"，因此归到不同通道。
///
/// ## 与 vools 的差异
/// - **D12 入参形态**：vools 的 `_coerce` 接受 `RhopConfig / dict / 路径` 三形态；
///   本项目只接受已解析的 `RhopConfig`（dict/路径请先过 `config.load_config`）——
///   把"解析"与"执行"分开，避免在交互入口里静默吞掉配置错误。
/// - **D8 一次性令牌**：vools 没有 token 机制。本项目在请求包里带
///   `token = tok:<nonce>:<filename>:<action>`，对端原样回显，发起端校验一致才认；
///   配合「发送前清理陈旧 `res_`」+「取回后删除 `res_`」，保证**上一轮残留回执永远不会被当成本轮结果**。
///
/// ## roundtrip 的失败相位（`phase` 词表，便于调用方定位）
/// | phase | 含义 | 回执形状 |
/// |---|---|---|
/// | `send` | 请求包投递失败 | `{status:"error", phase:"send", filename, detail}` |
/// | `request` | 对端处理失败（取包/解密/缺 action） | `{status:"error", phase:"request", omega_gate}` |
/// | `receive` | 取回执失败（介质读/解密） | `{status:"error", phase:"receive", omega_gate}` |
/// | `response` | 回执与本次请求不匹配（陈旧/串包/令牌不符） | `{status:"error", phase:"response", reason, omega_gate}` |
///
/// ## 并发注意（C2-05，资源/并发轮实测）
/// 缺省包名只由 action 派生（`req_<action>.rhop`），**不唯一**：同一介质上并发/多进程
/// 跑同一动作时，后写者会原子覆盖前写者，**先投递的请求静默丢失**（两次 send 都返回 `ok`）。
/// 并发方必须显式传唯一 `request_filename`（如带 nonce/worker id），或由上层（daemon/executor）队列化。
pub fn interact(
  cfg : RhopConfig,
  action : String,
  payload : Json?,
  mode : String,
  request_filename? : String,
) -> Result[Json, String] {
  let normalized = mode.trim().to_owned().to_lower()
  if normalized == "execute" {
    let result = run_action(action, cfg.action_cfg(), payload)
    return Ok(omega_unwrap(result))
  }
  if normalized != "request" && normalized != "roundtrip" {
    return Err("未知 mode: \{mode}（可用 execute/request/roundtrip）")
  }
  let requested = match request_filename {
    Some(f) =>
      if f.trim().length() == 0 {
        interact_default_filename(action)
      } else {
        f
      }
    None => interact_default_filename(action)
  }
  // 安全边界：包名统一走白名单（防路径穿越；缺省名同样要过校验）
  let filename = match safe_filename(requested) {
    Ok(n) => n
    Err(e) => return Err("rhop interact: " + e)
  }
  let sender = match cfg.build_session(role=Role::Send) {
    Ok(s) => s
    Err(e) => return Err(e)
  }
  // 一次性请求令牌：绑定「本次请求」，用于拒绝陈旧 res_ 回执（F1）
  let token = interact_next_token(filename, action)
  let request = Json::object({
    "action": Json::string(action),
    "payload": match payload {
      Some(p) => p
      None => Json::object(Map([]))
    },
    "token": Json::string(token),
  })
  let sent = match sender.send_package(filename, request) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if normalized == "request" {
    return Ok(sent)
  }
  // F1：请求一旦投递失败必须立刻返回，绝不能继续用上一轮残留的 res_ 当本轮回执
  if cfg_json_str(sent, "status") != Some("ok") {
    return Ok(
      Json::object({
        "status": Json::string("error"),
        "phase": Json::string("send"),
        "filename": Json::string(filename),
        "detail": sent,
      }),
    )
  }
  // roundtrip：对端同进程模拟（B 端复用同一份介质/密钥取包执行并回传）
  let resp_filename = "res_" + filename
  // 清掉历史残留回执：陈旧 res_ 不得作为本轮结果
  let _ = sender.remove_package(resp_filename)
  let response = match handle_request(cfg, filename) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if cfg_json_str(response, "status") != Some("ok") {
    return Ok(
      Json::object({
        "status": Json::string("error"),
        "phase": Json::string("request"),
        "omega_gate": response,
      }),
    )
  }
  let fetched = match sender.recv_package(resp_filename) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if cfg_json_str(fetched, "status") != Some("ok") {
    return Ok(
      Json::object({
        "status": Json::string("error"),
        "phase": Json::string("receive"),
        "omega_gate": fetched,
      }),
    )
  }
  let payload_out = interact_payload_or_empty(fetched)
  // 令牌校验：回执必须回显本次请求的 token，否则判为陈旧/串包响应
  if cfg_json_str(payload_out, "token") != Some(token) {
    let _ = sender.remove_package(resp_filename)
    return Ok(
      Json::object({
        "status": Json::string("error"),
        "phase": Json::string("response"),
        "reason": Json::string(
          "回执与本次请求不匹配（疑似陈旧 res_ 或串包）",
        ),
        "omega_gate": fetched,
      }),
    )
  }
  // 一次性消费：取回后删除响应包（防下一轮复用）
  let _ = sender.remove_package(resp_filename)
  Ok(
    Json::object({
      "status": Json::string("ok"),
      "transport": interact_field_or_null(sent, "transport"),
      "filename": Json::string(filename),
      "response_transport": interact_field_or_null(fetched, "transport"),
      "response_filename": Json::string(resp_filename),
      "result": interact_field_or_null(payload_out, "result"),
      "action_result": interact_field_or_null(payload_out, "action_result"),
    }),
  )
}

///|
/// 接收侧处理一个动作请求包（对照 vools `handle_request`）。
///
/// 流程：取包 -> 解密验证 -> run_action -> omega_unwrap -> 加密回传 `res_<filename>`。
///
/// 返回成功：`{"status":"ok","action","transport","result","response_filename","response_sent"}`
/// 返回失败（取包/解密失败或请求包缺 action）：
///   `{"status":"error","reason","transport"}` —— 与 vools 同形。
///
/// `session` 缺省按配置构造 RECV 会话（`build_session(role=Role::Recv)`）。
pub fn handle_request(
  cfg : RhopConfig,
  filename : String,
  session? : Session,
) -> Result[Json, String] {
  if filename.trim().length() == 0 {
    return Ok(
      Json::object({
        "status": Json::string("error"),
        "reason": Json::string("filename 不能为空"),
        "transport": Json::null(),
      }),
    )
  }
  // 安全边界：入站包名同样过白名单（拒绝穿越路径）
  let name = match safe_filename(filename) {
    Ok(n) => n
    Err(e) =>
      return Ok(
        Json::object({
          "status": Json::string("error"),
          "reason": Json::string("包文件名非法: " + e),
          "transport": Json::null(),
        }),
      )
  }
  let receiver = match session {
    Some(s) => s
    None =>
      match cfg.build_session(role=Role::Recv) {
        Ok(s) => s
        Err(e) => return Err(e)
      }
  }
  let received = match receiver.recv_package(name) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if cfg_json_str(received, "status") != Some("ok") {
    return Ok(
      Json::object({
        "status": Json::string("error"),
        "reason": interact_field_or_null(received, "reason"),
        "transport": interact_field_or_null(received, "transport"),
      }),
    )
  }
  let request = interact_payload_or_empty(received)
  let action = match cfg_json_str(request, "action") {
    Some(a) =>
      if a.trim().length() == 0 {
        return Ok(
          Json::object({
            "status": Json::string("error"),
            "reason": Json::string("请求包缺少 action 字段"),
            "transport": interact_field_or_null(received, "transport"),
          }),
        )
      } else {
        a
      }
    None =>
      return Ok(
        Json::object({
          "status": Json::string("error"),
          "reason": Json::string("请求包缺少 action 字段"),
          "transport": interact_field_or_null(received, "transport"),
        }),
      )
  }
  let result = run_action(
    action,
    cfg.action_cfg(),
    cfg_json_field(request, "payload"),
  )
  let unwrapped = omega_unwrap(result)
  // 回传处理结果：RELAY 无方向，SEND<->RECV 由 reverse() 换角色，介质原样复用
  let resp_filename = "res_" + name
  let sender = receiver.reverse()
  let response_body = Json::object({
    "action": Json::string(action),
    "result": interact_field_or_null(unwrapped, "status"),
    "action_result": unwrapped,
    // 回显请求令牌：发起方据此拒绝陈旧/串包响应（F1）
    "token": interact_field_or_null(request, "token"),
  })
  let sent = match sender.send_package(resp_filename, response_body) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  // F4：回执写失败必须报 error，不能把 sent 的失败藏进 response_sent 后仍报 ok
  if cfg_json_str(sent, "status") != Some("ok") {
    return Ok(
      Json::object({
        "status": Json::string("error"),
        "phase": Json::string("response"),
        "action": Json::string(action),
        "transport": interact_field_or_null(received, "transport"),
        "response_filename": Json::string(resp_filename),
        "detail": sent,
      }),
    )
  }
  Ok(
    Json::object({
      "status": Json::string("ok"),
      "action": Json::string(action),
      "transport": interact_field_or_null(received, "transport"),
      "result": unwrapped,
      "response_filename": Json::string(resp_filename),
      "response_sent": interact_field_or_null(sent, "status"),
    }),
  )
}

// ---------------------------------------------------------------------------
// 内部 helper
// ---------------------------------------------------------------------------

///|
/// 缺省动作包文件名：`req_<action>`，action 里的 `.` 换成 `_`（vools 同规则）。
///
/// 但 vools 直接拼进文件名，`jump/push` 这类带分隔符的动作名会拼出子目录路径；
/// 这里把白名单外的字符统一换成 `_`，再兜底保证结果能过 `safe_filename`。
fn interact_default_filename(action : String) -> String {
  let dashed = action.replace(old=".", new="_")
  let sb = StringBuilder()
  for c in dashed {
    let code = c.to_int()
    let ok = (code >= 48 && code <= 57) ||
      (code >= 65 && code <= 90) ||
      (code >= 97 && code <= 122) ||
      code == 95 ||
      code == 45
    sb.write_char(if ok { c } else { '_' })
  }
  let body = sb.to_string()
  let stem = if body == "" { "action" } else { body }
  match safe_filename("req_" + stem + ".rhop") {
    Ok(n) => n
    // 极端超长动作名：截断到白名单长度上限内
    Err(_) => {
      let cut = match stem.get_view(start=0, end=100) {
        Some(v) => v.to_owned()
        None => stem
      }
      "req_" + cut + ".rhop"
    }
  }
}

///|
/// roundtrip 一次性请求令牌计数器（进程内单调递增）。
let interact_nonce : Ref[Int32] = Ref::Ref(0)

///|
/// 生成一次性请求令牌：`tok:<nonce>:<filename>:<action>`。
///
/// 令牌随请求包一起投递，对端原样回显；发起端校验回执里的令牌与本次请求一致，
/// 因此上一轮残留的 `res_` 永远不会被当成本轮结果（配合「发送前清理 + 消费后删除」）。
///
/// 实现约束（C2-07）：
/// - 计数器是进程内 `Ref[Int32]` 单调递增，**无原子性** —— 适用于单线程执行体
///   （js 事件循环 / 单线程 wasm/native 测试）；若将来引入多线程，需要换 `Int64`/原子实现；
/// - 2^31 次 roundtrip 后回绕为负；即便回绕，token 仍需 `filename + action + nonce` 全等才被接受，
///   不会误判（只是可预测性下降）。
fn interact_next_token(filename : String, action : String) -> String {
  let n = interact_nonce.val
  interact_nonce.val = n + 1
  "tok:\{n}:\{filename}:\{action}"
}

///|
/// 取回执里的 `payload` 字段；缺失/非对象时回退空对象（vools 的 `or {}`）。
fn interact_payload_or_empty(envelope : Json) -> Json {
  match cfg_json_field(envelope, "payload") {
    Some(Object(_)) =>
      match cfg_json_field(envelope, "payload") {
        Some(p) => p
        None => Json::object(Map([]))
      }
    _ => Json::object(Map([]))
  }
}

///|
/// 取字段或 null（回执里固定保留键位，便于调用方判空）。
fn interact_field_or_null(j : Json, key : String) -> Json {
  match cfg_json_field(j, key) {
    Some(v) => v
    None => Json::null()
  }
}
