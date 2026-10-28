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
  let filename = match request_filename {
    Some(f) =>
      if f.trim().length() == 0 {
        interact_default_filename(action)
      } else {
        f
      }
    None => interact_default_filename(action)
  }
  let sender = match cfg.build_session(role=Role::Send) {
    Ok(s) => s
    Err(e) => return Err(e)
  }
  let request = Json::object({
    "action": Json::string(action),
    "payload": match payload {
      Some(p) => p
      None => Json::object(Map([]))
    },
  })
  let sent = match sender.send_package(filename, request) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if normalized == "request" {
    return Ok(sent)
  }
  // roundtrip：对端同进程模拟（B 端复用同一份介质/密钥取包执行并回传）
  let response = match handle_request(cfg, filename) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if cfg_json_str(response, "status") != Some("ok") {
    return Ok(
      Json::object({ "status": Json::string("error"), "omega_gate": response }),
    )
  }
  let resp_filename = "res_" + filename
  let fetched = match sender.recv_package(resp_filename) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if cfg_json_str(fetched, "status") != Some("ok") {
    return Ok(
      Json::object({ "status": Json::string("error"), "omega_gate": fetched }),
    )
  }
  let payload_out = interact_payload_or_empty(fetched)
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
  let receiver = match session {
    Some(s) => s
    None =>
      match cfg.build_session(role=Role::Recv) {
        Ok(s) => s
        Err(e) => return Err(e)
      }
  }
  let received = match receiver.recv_package(filename) {
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
  let resp_filename = "res_" + filename
  let sender = receiver.reverse()
  let response_body = Json::object({
    "action": Json::string(action),
    "result": interact_field_or_null(unwrapped, "status"),
    "action_result": unwrapped,
  })
  let sent = match sender.send_package(resp_filename, response_body) {
    Ok(v) => v
    Err(e) => return Err(e)
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
/// 缺省动作包文件名：`req_<action>`，其中 action 里的 `.` 换成 `_`（vools 同规则）。
fn interact_default_filename(action : String) -> String {
  "req_" + action.replace(old=".", new="_") + ".rhop"
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
