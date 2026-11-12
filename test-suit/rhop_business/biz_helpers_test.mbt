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
/// 本进程「上一个」workspace（新建前会被清掉，保证任意时刻存活 ≤1 个）。
let biz_last_workspace : Ref[String] = Ref("")

///|
/// 是否已经做过一次「陈旧残留清扫」（每进程只需一次）。
let biz_stale_swept : Ref[Bool] = Ref(false)

///|
/// 扫掉 `%TEMP%/rhop-biz-*` 历史残留（上一次被 kill/超时打断留下的），返回清理个数。
///
/// 前缀 `rhop-biz-` 是本包专属，因此不会误伤其它 lane 的临时目录；
/// 非 js 目标无文件系统 ⇒ 恒返回 0。
fn biz_sweep_stale() -> Int32 {
  biz_ffi_sweep_stale("rhop-biz-")
}

///|
/// 拿一个**唯一**临时工作目录，并让「任意时刻最多 1 个 workspace 存活」。
///
/// C3 卫生硬化（QA C2-V1）：
///   - 首次调用先清扫本包历史残留（测试进程被 kill 时退出钩子不执行，会留下
///     `%TEMP%/rhop-biz-*`）；
///   - 每次新建前删掉上一个 workspace ⇒ 即使进程被强杀，也最多残留 1 个目录；
///   - 目录本身仍登记在 `rhop_temp_workspace` 的退出钩子里，正常退出自动清理。
///
/// 用例收尾请调用 `biz_cleanup(dir)`（幂等）；非 js 目标无文件系统 ⇒ `abort`
/// （只在 js 测试文件里调用）。
fn biz_temp_workspace() -> String {
  if !biz_stale_swept.val {
    biz_stale_swept.val = true
    ignore(biz_sweep_stale())
  }
  let prev = biz_last_workspace.val
  if prev != "" {
    ignore(@rp.rhop_remove_dir_all(prev))
  }
  let dir = match @rp.rhop_temp_workspace("rhop-biz-") {
    Ok(dir) => dir
    Err(e) => abort("rhop_temp_workspace 失败（需要 js 目标）: \{e}")
  }
  biz_last_workspace.val = dir
  dir
}

///|
/// 收尾清理某个 workspace（幂等；不存在视为成功），并把「上一个 workspace」指针清空。
fn biz_cleanup(dir : String) -> Unit {
  if dir == "" {
    return
  }
  ignore(@rp.rhop_remove_dir_all(dir))
  if biz_last_workspace.val == dir {
    biz_last_workspace.val = ""
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

// ---------------------------------------------------------------------------
// 测试专用 FFI：陈旧 workspace 清扫（js）/ 空实现（wasm、native）
// ---------------------------------------------------------------------------

///|
/// js：删除 `%TEMP%` 下所有以 `prefix` 开头的目录，返回删除个数。
#cfg(target="js")
extern "js" fn biz_ffi_sweep_stale(prefix : String) -> Int32 =
  #| (prefix) => { try { const fs = process.getBuiltinModule("node:fs"); const os = process.getBuiltinModule("node:os"); const pathMod = process.getBuiltinModule("node:path"); const tmp = os.tmpdir(); const pre = String(prefix); let n = 0; for (const name of fs.readdirSync(tmp)) { if (String(name).indexOf(pre) === 0) { try { fs.rmSync(pathMod.join(tmp, name), { recursive: true, force: true, maxRetries: 3, retryDelay: 20 }); n = n + 1; } catch (e) {} } } return n; } catch (e) { return 0; } }

///|
/// 非 js：无文件系统，恒 0。
#cfg(not(target="js"))
fn biz_ffi_sweep_stale(prefix : String) -> Int32 {
  let _ = prefix
  0
}
