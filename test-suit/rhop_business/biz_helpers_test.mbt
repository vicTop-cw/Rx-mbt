// ============================================================================
// rhop_business · 测试共用夹具（本包内所有测试文件共享同一命名空间）
//
// 这里只放**不依赖目标**的纯辅助（造配置 / 造信封 / 读 Json 字段），
// 以及「拿一个唯一临时工作目录」的 js 便捷封装（非 js 目标调用会 fail，
// 故只在 js 测试文件里用）。
// ============================================================================

///|
/// 取 Json 对象里的数字字段（缺失/类型不符返回 -1，便于断言「键不存在」）。
fn jnum(value : Json, key : String) -> Double {
  match value {
    Object(members) =>
      match members.get(key) {
        Some(Number(n, ..)) => n
        _ => -1.0
      }
    _ => -1.0
  }
}

///|
/// 取 Json 对象里的字符串字段（缺失/类型不符返回 ""）。
fn jstr(value : Json, key : String) -> String {
  match value {
    Object(members) =>
      match members.get(key) {
        Some(String(text)) => text
        _ => ""
      }
    _ => ""
  }
}

///|
/// 取 Json 对象里的数组字段（缺失返回空数组）。
fn jarr(value : Json, key : String) -> Array[Json] {
  match value {
    Object(members) =>
      match members.get(key) {
        Some(Array(items)) => items
        _ => []
      }
    _ => []
  }
}

///|
/// 取 Json 数组里的字符串项（非字符串项跳过）。
fn jstr_array(value : Json, key : String) -> Array[String] {
  let out : Array[String] = []
  for item in jarr(value, key) {
    match item {
      String(text) => out.push(text)
      _ => ()
    }
  }
  out
}

///|
/// 造一个最小信封（payload 固定 `{"cmd":"echo hi"}`）。
fn mk_env(
  task_id : String,
  status : @rp.TaskStatus,
  side : @rp.Side,
  version : Int32,
) -> @rp.Envelope {
  let payload = @json.parse("{\"cmd\":\"echo hi\"}") catch { _ => Json::null() }
  @rp.Envelope::new_full(
    task_id,
    status,
    payload,
    side,
    version~,
    created_at="2026-10-21T10:00:00Z",
    updated_at="2026-10-21T10:00:00Z",
  )
}

///|
/// 造一份最小 `RhopConfig`（key 为明文；shared 为空串表示不配共享介质）。
fn biz_cfg(role : String, shared : String) -> @rp.RhopConfig {
  let fields : Map[String, Json] = Map([])
  fields["key"] = Json::string("biz-test-key")
  fields["role"] = Json::string(role)
  fields["name"] = Json::string("biz-test")
  if shared != "" {
    fields["shared"] = Json::string(shared)
  }
  match @rp.RhopConfig::from_dict(Json::object(fields)) {
    Ok(cfg) => cfg
    Err(e) => abort("造配置失败: \{e}")
  }
}

///|
/// 造一个可执行动作的 payload：`{"action": "<name>", ...extra}`。
fn biz_action_payload(action : String) -> Json {
  let fields : Map[String, Json] = Map([])
  fields["action"] = Json::string(action)
  // 动作配置走 payload.cfg（executor 会把它当 cfg 传给 run_action）
  fields["cfg"] = Json::object({
    "sftp": Json::object({
      "host": Json::string("example.invalid"),
      "port": Json::number(22.0),
      "user": Json::string("probe"),
    }),
  })
  Json::object(fields)
}

///|
/// 拿一个**唯一**临时工作目录（js：`rhop_temp_workspace`，每次调用新建
/// `rhop-biz-<rand>/`；这些目录登记在进程退出钩子里统一递归删除）。
///
/// 非 js 目标无文件系统 ⇒ `abort`（只在 js 测试文件里调用）。
fn biz_temp_workspace() -> String {
  match @rp.rhop_temp_workspace("rhop-biz-") {
    Ok(dir) => dir
    Err(e) => abort("rhop_temp_workspace 失败（需要 js 目标）: \{e}")
  }
}

///|
/// 断言 Json 对象里 `status` 字段等于期望值。
fn assert_status(value : Json, expected : String) -> Unit {
  let actual = jstr(value, "status")
  if actual != expected {
    abort(
      "status 期望 \{expected}，实际 \"\{actual}\"（回执: \{@rp.canonical_json(value)}）",
    )
  }
}
