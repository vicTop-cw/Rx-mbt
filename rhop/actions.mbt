// ============================================================================
// rhop · 公开动作集（Batch D 完整版）
//
// 对照 vools.rhop.actions（actions/__init__.py + actions/jump.py）：
//   动作名 + 配置 + payload 即得统一出参，每个动作签名 `(cfg, payload) -> dict`，
//   出参形状（内层）:
//       {"status": "ok"|"partial"|"error", ...动作自定义字段}
//   run_action 再包一层外层状态:
//       {"status": "ok", "action": <name>, "data": <内层出参>}
//       {"status": "error", "action": <name>, "data": null, "omega_gate": {"error": ...}}
//
// 跨动作调用带 Ω-gate 容错解包（对齐 analysis/rhop-PLAN.md 附录 C C2.2）：
//   omega_unwrap(result):
//     - 外层 status=="ok" 且内层 data.status in ("ok","partial") -> 判成功，返回内层 data；
//     - 否则返回带 omega_gate 字段的错误出参（gate error 挂 omega_gate）。
//
// **四个签名冻结**（interact.mbt 直接依赖，Batch C 已交付，本批不得改动）：
//   register_action(String, (Json, Json?) -> Json) -> Unit
//   list_actions() -> Array[String]
//   run_action(String, Json, Json?) -> Json
//   omega_unwrap(Json) -> Json
//
// 内置动作（对照 vools `ACTIONS` 四项 + 一项离线自检增量）：
//   jump.probe  —— 配置结构探测（**离线**，不真连网；出参形状与 Batch C 完全一致）
//   jump.push   —— 推送本地文件/目录（vools 走 paramiko/SFTP；本实现**离线**：
//                  dry_run 时真实扫描本地目录并给出结构化计划，真传返回可诊断错误）
//   jump.pull   —— 拉取远端文件/目录（同上；dry_run 需 payload.remote_files 才能推出计划）
//   jump.sync   —— 双向同步（同上；给了 payload.remote_files 就用纯逻辑算真计划）
//   rhop.echo   —— **离线增量**：回显 cfg/payload，供 interact 闭环与链路自检（无副作用）
//
// 为什么 jump.* 不做真传输：MoonBit/js 侧没有 SSH/SFTP 客户端，硬编造「传输成功」
// 就是假 GREEN。这里的选择是：**能离线做的真做**（本地扫描、sha256、同步计划），
// 真传输一律返回 `{"status":"error", "message": "...未实现...", "transport":"unsupported"}`
// 并给出替代通道（SyncFolder / 共享目录），让调用方看见原因而不是拿到一个骗人的 0。
//
// 目标说明：纯逻辑部分三目标（wasm / js / native）通用；涉及文件扫描的只在 js 生效
// （非 js 的 `rhop_fs_*` 返回可诊断 Err，动作会把它转成结构化错误而不是崩溃）。
// ============================================================================

// ---------------------------------------------------------------------------
// 注册表（四个冻结签名 + 两个增量查询/注销）
// ---------------------------------------------------------------------------

///|
/// 动作注册表：动作名 -> 处理函数。
///
/// 处理函数**不得抛异常**（MoonBit 侧约定：错误一律以 `{"status": "error", ...}`
/// 出参表达）；注册同名动作会覆盖旧处理器。
let action_registry : Map[String, (Json, Json?) -> Json] = Map([])

///|
/// 注册（或覆盖）一个动作处理器（**签名冻结**）。
///
/// 空名 / 纯空白名不做特殊校验，注册后仍可被 `run_action` 或 `list_actions` 看见
/// （保持「注册即所见」的直白语义，不静默吞掉调用方的写操作）。
pub fn register_action(name : String, handler : (Json, Json?) -> Json) -> Unit {
  action_registry[name] = handler
}

///|
/// 注销一个已注册动作（**增量**，供测试清理与运行时热卸载；内置动作不受影响）。
///
/// 返回是否真的删掉了（未注册过 ⇒ false，不静默成功）。
pub fn unregister_action(name : String) -> Bool {
  match action_registry.get(name) {
    Some(_) => {
      action_registry.remove(name)
      true
    }
    None => false
  }
}

///|
/// 查一个动作的处理器（**增量**）：注册表优先，其次内置动作；无则 `None`。
///
/// 与 `run_action` 的区别：这是**只查不跑**的入口，便于调用方先探测能力再决定调用，
/// 也便于测试断言「某动作确实注册过」而不产生副作用。
pub fn get_handler(name : String) -> ((Json, Json?) -> Json)? {
  action_lookup(name)
}

///|
/// 列出当前可执行的动作名（**签名冻结**；注册表 ∪ 内置动作）。
///
/// 顺序：先注册顺序、后内置顺序，**不保证字典序**（调用方按需自行排序）。
pub fn list_actions() -> Array[String] {
  let seen : @hashset.HashSet[String] = @hashset.HashSet([])
  let out : Array[String] = []
  for name in action_registry.keys() {
    if !seen.contains(name) {
      seen.add(name)
      out.push(name)
    }
  }
  for name in builtin_action_names() {
    if !seen.contains(name) {
      seen.add(name)
      out.push(name)
    }
  }
  out
}

///|
/// 按动作名执行，统一包一层外层状态（**签名冻结**，对照 vools `run_action`）。
///
/// 未知动作返回**可诊断**错误结构（含当前可用动作清单），绝不静默成功：
/// `{"status": "error", "action": <name>, "data": null, "omega_gate": {"error": "未知动作: …"}}`
pub fn run_action(name : String, cfg : Json, payload : Json?) -> Json {
  match action_lookup(name) {
    None => {
      let known = list_actions().join(", ")
      Json::object({
        "status": Json::string("error"),
        "action": Json::string(name),
        "data": Json::null(),
        "omega_gate": Json::object({
          "error": Json::string(
            "未知动作: " + name + "（可用: " + known + "）",
          ),
        }),
      })
    }
    Some(handler) =>
      Json::object({
        "status": Json::string("ok"),
        "action": Json::string(name),
        "data": handler(cfg, payload),
      })
  }
}

///|
/// Ω-gate 容错解包（**签名冻结**，对照 vools `omega_unwrap`）。
///
/// - 外层 `status=="ok"` 且内层 `data.status` 为 `"ok"` / `"partial"` → 返回内层 `data`；
/// - 其余返回 `{"status": "error", "omega_gate": {...}}`，错误细节集中挂在 `omega_gate`：
///   外层状态异常 / 内层 data 缺失或非对象 / 内层 status 非成功态。
pub fn omega_unwrap(result : Json) -> Json {
  let outer_ok = match act_json_field(result, "status") {
    Some(String(s)) => s == "ok"
    _ => false
  }
  if !outer_ok {
    let gate = match act_json_field(result, "omega_gate") {
      Some(g) => g
      None => act_gate("外层状态异常")
    }
    return act_error(gate)
  }
  let data = match act_json_field(result, "data") {
    Some(d) => d
    None => return act_error(act_gate("内层 data 缺失或非 dict"))
  }
  let inner_status = act_json_str(data, "status")
  match inner_status {
    None => act_error(act_gate("内层 data 缺失或非 dict"))
    Some(status) =>
      if status == "ok" || status == "partial" {
        data
      } else {
        act_error(
          Json::object({
            "action": match act_json_field(result, "action") {
              Some(a) => a
              None => Json::null()
            },
            "error": Json::string("内层 status=" + status),
            "data": data,
          }),
        )
      }
  }
}

// ---------------------------------------------------------------------------
// 内置动作清单 / 查找
// ---------------------------------------------------------------------------

///|
/// 内置动作名表（与 `builtin_action_lookup` 一一对应）。
fn builtin_action_names() -> Array[String] {
  ["jump.probe", "jump.push", "jump.pull", "jump.sync", "rhop.echo"]
}

///|
/// 内置动作查找：返回处理函数或 None。
///
/// 单独走一次查找（而不是在包初始化时塞进注册表）是为了**没有初始化顺序问题**：
/// 无论哪个 target、哪个模块先跑，内置动作恒可解析；且 `register_action` 同名注册
/// 优先级更高（先查注册表），调用方仍可覆盖内置动作。
fn builtin_action_lookup(name : String) -> ((Json, Json?) -> Json)? {
  match name {
    "jump.probe" => Some(jump_probe)
    "jump.push" => Some(jump_push)
    "jump.pull" => Some(jump_pull)
    "jump.sync" => Some(jump_sync)
    "rhop.echo" => Some(rhop_echo)
    _ => None
  }
}

///|
/// 动作查找：注册表优先，其次内置动作。
fn action_lookup(name : String) -> ((Json, Json?) -> Json)? {
  match action_registry.get(name) {
    Some(handler) => Some(handler)
    None => builtin_action_lookup(name)
  }
}

// ---------------------------------------------------------------------------
// 内置动作 · jump.probe（离线结构化探测，出参形状与 Batch C 交付版一致）
// ---------------------------------------------------------------------------

///|
/// 内置动作 `jump.probe` 的**离线**实现：只读配置里的 sftp 字段并做结构校验，
/// **不发起任何网络连接**。
///
/// 出参（内层，对齐 vools `jump_probe` 的 status/reachable/detail/transport 四字段）：
/// `{"status": "ok", "reachable": false, "detail": "...", "transport": "offline"|"none",
///   "offline": true, "host", "port", "dir", "has_user", "has_credentials"}`
///
/// 与 vools 的差异：vools 在 paramiko 可用时会真连；本实现**没有 SSH 客户端**，
/// 因此在 `detail` 里明说「离线探测、未建立真实连接」，并把不可达原因写清，
/// 避免调用方把 reachable=false 误读成「跳板机真的挂了」。
pub fn jump_probe(cfg : Json, payload : Json?) -> Json {
  let _ = payload
  let sftp = jump_sftp_cfg(cfg)
  let host = match act_json_str(sftp, "host") {
    Some(h) => h
    None => ""
  }
  let port = act_json_int(sftp, "port", 22)
  let dir = match act_json_str(sftp, "dir") {
    Some(d) => d
    None =>
      match act_json_str(sftp, "remote_dir") {
        Some(d) => d
        None => ""
      }
  }
  let user = match act_json_str(sftp, "user") {
    Some(u) => u
    None =>
      match act_json_str(sftp, "username") {
        Some(u) => u
        None => ""
      }
  }
  let has_password = act_json_str(sftp, "password") != None
  let has_key_path = act_json_str(sftp, "key_path") != None
  let detail = if host == "" {
    "缺少 sftp.host 配置（视为不可达）"
  } else {
    "离线探测（未建立真实连接）：目标 \{user}@\{host}:\{port}，dir=\{dir}；" +
    "MoonBit/js 侧无 SSH 客户端，只做配置结构校验"
  }
  let transport = if host == "" { "none" } else { "offline" }
  Json::object({
    "status": Json::string("ok"),
    "reachable": Json::boolean(false),
    "detail": Json::string(detail),
    "transport": Json::string(transport),
    "offline": Json::boolean(true),
    "host": Json::string(host),
    "port": Json::number(port.to_double()),
    "dir": Json::string(dir),
    "has_user": Json::boolean(user != ""),
    "has_credentials": Json::boolean(has_password || has_key_path),
  })
}

// ---------------------------------------------------------------------------
// 内置动作 · jump.push / jump.pull / jump.sync
//
// 共同点（对齐 vools 的入参约定与错误形状）：
//   cfg   —— sftp 配置（`cfg.sftp` / `cfg.media.sftp` / 直接用 cfg 本身，三种形态都认）
//   payload —— {local_path, remote_path, exclude[], dry_run, direction, strategy, delete,
//               remote_files?}
// 差异：vools 用 paramiko 真传；这里**离线做计划**，真传给可诊断错误 + 替代通道。
// ---------------------------------------------------------------------------

///|
/// 内置动作 `jump.push`：推送本地文件/目录到远端。
///
/// - cfg 缺 host / payload 缺路径 → `{"status":"error","message":...}`（与 vools 同文案）；
/// - `dry_run=true` → **真实扫描本地目录**（js），返回 `{files, total_files, dry_run:true}`，
///   路径不存在时 `files=[] / total_files=0` 并在 message 里说明；
/// - 非 dry_run → `{"status":"error","transport":"unsupported","message":"...未实现..."}`
///   （不伪造 files_transferred）。
pub fn jump_push(cfg : Json, payload : Json?) -> Json {
  match jump_require_target(cfg, payload) {
    Err(msg) => jump_error(msg)
    Ok(plan) => {
      let (sftp, local_path, _remote_path) = plan
      let _ = sftp
      let exclude = act_payload_list(payload, "exclude")
      let dry_run = act_payload_bool(payload, "dry_run", false)
      let files = jump_collect_files(local_path, exclude)
      if files.length() == 0 {
        return Json::object({
          "status": Json::string("ok"),
          "files_transferred": Json::number(0.0),
          "bytes": Json::number(0.0),
          "message": Json::string(
            "没有需要传输的文件（本地路径不存在或全部被 exclude 排除）",
          ),
          "total_files": Json::number(0.0),
          "transport": Json::string("offline"),
        })
      }
      if dry_run {
        return Json::object({
          "status": Json::string("ok"),
          "files_transferred": Json::number(0.0),
          "bytes": Json::number(0.0),
          "dry_run": Json::boolean(true),
          "files": jump_str_array(jump_take(files, 50)),
          "total_files": Json::number(files.length().to_double()),
          "transport": Json::string("offline"),
          "message": Json::string(
            "离线预览：已真实扫描本地目录，未发起传输",
          ),
        })
      }
      jump_unsupported("push", files.length())
    }
  }
}

///|
/// 内置动作 `jump.pull`：从远端拉取文件/目录到本地。
///
/// 远端无法列举（无 SSH 客户端），因此：
/// - `dry_run=true` 且 payload 带 `remote_files`（对象 `{relpath: {...}}`）→
///   用纯逻辑算出「需下载」清单；
/// - `dry_run=true` 但没给 `remote_files` → `status:"ok" + remote_listing_provided:false`
///   并明说需要该字段才能离线预览（不假装知道远端有什么）；
/// - 非 dry_run → 可诊断 `unsupported` 错误。
pub fn jump_pull(cfg : Json, payload : Json?) -> Json {
  match jump_require_target(cfg, payload) {
    Err(msg) => jump_error(msg)
    Ok(plan) => {
      let (_sftp, local_path, _remote_path) = plan
      let dry_run = act_payload_bool(payload, "dry_run", false)
      let exclude = act_payload_list(payload, "exclude")
      let remote_files = act_payload_field(payload, "remote_files")
      if !dry_run {
        return jump_unsupported("pull", 0)
      }
      match remote_files {
        None =>
          Json::object({
            "status": Json::string("ok"),
            "files_transferred": Json::number(0.0),
            "bytes": Json::number(0.0),
            "dry_run": Json::boolean(true),
            "remote_listing_provided": Json::boolean(false),
            "transport": Json::string("offline"),
            "message": Json::string(
              "离线预览需要 payload.remote_files（{relpath: {sha256,size}}）：" +
              "MoonBit/js 侧无 SSH 客户端，无法自行列举远端",
            ),
          })
        Some(remote) => {
          let local = jump_scan_local(local_path, exclude)
          let plan_json = jump_compute_sync_plan(
            local, remote, "download", false,
          )
          Json::object({
            "status": Json::string("ok"),
            "files_transferred": Json::number(0.0),
            "bytes": Json::number(0.0),
            "dry_run": Json::boolean(true),
            "remote_listing_provided": Json::boolean(true),
            "plan": plan_json,
            "transport": Json::string("offline"),
            "message": Json::string(
              "离线预览：计划由本地扫描 + 调用方给的远端清单计算",
            ),
          })
        }
      }
    }
  }
}

///|
/// 内置动作 `jump.sync`：双向同步（含 upload/download/conflict/skip/delete 五分类）。
///
/// 复用 vools `compute_sync_plan` 的判定语义（`direction` / `strategy` / `delete`），
/// 但「文件是否相同」判据用 **sha256**（vools 用 size+mtime；sha 更强且跨平台一致）。
/// 同样要求调用方给 `payload.remote_files` 才能离线算计划；非 dry_run 一律可诊断错误。
pub fn jump_sync(cfg : Json, payload : Json?) -> Json {
  match jump_require_target(cfg, payload) {
    Err(msg) => jump_error(msg)
    Ok(plan) => {
      let (_sftp, local_path, _remote_path) = plan
      let dry_run = act_payload_bool(payload, "dry_run", false)
      let exclude = act_payload_list(payload, "exclude")
      let direction = act_payload_str(payload, "direction", "both")
      let delete_extra = act_payload_bool(payload, "delete", false)
      let remote_files = act_payload_field(payload, "remote_files")
      if !dry_run {
        return jump_unsupported("sync", 0)
      }
      match remote_files {
        None =>
          Json::object({
            "status": Json::string("ok"),
            "dry_run": Json::boolean(true),
            "remote_listing_provided": Json::boolean(false),
            "direction": Json::string(direction),
            "transport": Json::string("offline"),
            "message": Json::string(
              "离线预览需要 payload.remote_files（{relpath: {sha256,size}}）",
            ),
          })
        Some(remote) => {
          let local = jump_scan_local(local_path, exclude)
          let plan_json = jump_compute_sync_plan(
            local, remote, direction, delete_extra,
          )
          Json::object({
            "status": Json::string("ok"),
            "dry_run": Json::boolean(true),
            "remote_listing_provided": Json::boolean(true),
            "direction": Json::string(direction),
            "plan": plan_json,
            "transport": Json::string("offline"),
            "message": Json::string(
              "离线预览：计划由本地扫描 + 调用方给的远端清单计算（判据 sha256）",
            ),
          })
        }
      }
    }
  }
}

///|
/// 内置动作 `rhop.echo`（**离线增量**）：原样回显 cfg 与 payload，无副作用。
///
/// 用途：interact / daemon / executor 的链路自检（不依赖 SFTP、不碰网络），
/// 也是「动作注册表真的能跑通」的最小证据。
pub fn rhop_echo(cfg : Json, payload : Json?) -> Json {
  Json::object({
    "status": Json::string("ok"),
    "action": Json::string("rhop.echo"),
    "cfg": cfg,
    "payload": match payload {
      Some(v) => v
      None => Json::null()
    },
    "offline": Json::boolean(true),
  })
}

// ---------------------------------------------------------------------------
// 同步计划（纯逻辑，对照 vools `compute_sync_plan`）
// ---------------------------------------------------------------------------

///|
/// 计算同步计划（对照 vools `compute_sync_plan`，判据换成 sha256）。
///
/// 入参：`local_files` / `remote_files` 都是 `{relpath: {"sha256": ..., "size": n}}`
/// 形态的 JSON 对象。出参：
/// `{"upload": [...], "download": [...], "conflict": [{relpath,local,remote}], "skip": [...],
///   "delete": [...]}`。
///
/// `direction`：`upload` / `download` / `both`（其它值按 `both`）；`delete_extra` 仅在
/// `direction=="upload"` 时把「远端独有」的文件列入 delete（vools 同语义）。
pub fn jump_compute_sync_plan(
  local_files : Json,
  remote_files : Json,
  direction : String,
  delete_extra : Bool,
) -> Json {
  let local_keys = act_object_keys(local_files)
  let remote_keys = act_object_keys(remote_files)
  let upload : Array[Json] = []
  let download : Array[Json] = []
  let conflict : Array[Json] = []
  let skip : Array[Json] = []
  let to_delete : Array[Json] = []
  let seen : @hashset.HashSet[String] = @hashset.HashSet([])
  for key in local_keys {
    seen.add(key)
    let in_remote = remote_keys.contains(key)
    if !in_remote {
      if direction == "upload" || direction == "both" {
        upload.push(Json::string(key))
      } else {
        skip.push(Json::string(key))
      }
    } else {
      let same = jump_same_content(
        act_object_get(local_files, key),
        act_object_get(remote_files, key),
      )
      if same {
        skip.push(Json::string(key))
      } else if direction == "upload" {
        upload.push(Json::string(key))
      } else if direction == "download" {
        download.push(Json::string(key))
      } else {
        conflict.push(
          Json::object({
            "relpath": Json::string(key),
            "local": act_object_get(local_files, key),
            "remote": act_object_get(remote_files, key),
          }),
        )
      }
    }
  }
  for key in remote_keys {
    if seen.contains(key) {
      continue
    }
    if direction == "download" || direction == "both" {
      download.push(Json::string(key))
    } else if direction == "upload" && delete_extra {
      to_delete.push(Json::string(key))
    } else {
      skip.push(Json::string(key))
    }
  }
  Json::object({
    "upload": Json::array(upload),
    "download": Json::array(download),
    "conflict": Json::array(conflict),
    "skip": Json::array(skip),
    "delete": Json::array(to_delete),
  })
}

///|
/// 扫本地目录（js：真实扫描；非 js：空对象 + 动作会在上层给出可诊断错误）。
///
/// 返回 `{relpath: {"sha256": ..., "size": n}}`（与 `jump_compute_sync_plan` 入参同形）。
pub fn jump_scan_local(local_path : String, exclude : Array[String]) -> Json {
  let fields : Map[String, Json] = Map([])
  if local_path == "" {
    return Json::object(fields)
  }
  for rel in rhop_fs_list_files_recursive(local_path) {
    if jump_should_exclude(rel, exclude) {
      continue
    }
    match rhop_fs_digest_file(rhop_join(local_path, rel)) {
      Ok(digest) => fields[rel] = digest
      Err(_) => ()
    }
  }
  Json::object(fields)
}

///|
/// 收集本地待传文件（相对路径，已排除 exclude）。
///
/// 目录不存在 ⇒ 空数组（调用方据此给出「没有需要传输的文件」，与 vools 一致）。
pub fn jump_collect_files(
  local_path : String,
  exclude : Array[String],
) -> Array[String] {
  let out : Array[String] = []
  if local_path == "" {
    return out
  }
  for rel in rhop_fs_list_files_recursive(local_path) {
    if !jump_should_exclude(rel, exclude) {
      out.push(rel)
    }
  }
  out
}

///|
/// 排除规则（对照 vools `should_exclude`）：对**相对路径**与**basename** 双向 glob 匹配。
///
/// 支持 `*` / `?` 通配（复用 `sync_glob_match`）；精确相等也算命中。
pub fn jump_should_exclude(relpath : String, patterns : Array[String]) -> Bool {
  let base = jump_basename_of(relpath)
  for p in patterns {
    if p == "" {
      continue
    }
    if p == relpath || p == base {
      return true
    }
    if sync_glob_match(p, base) || sync_glob_match(p, relpath) {
      return true
    }
  }
  false
}

// ---------------------------------------------------------------------------
// 动作私有 helper
// ---------------------------------------------------------------------------

///|
/// 从 cfg 提取 sftp 配置（对照 vools `_sftp_cfg_of`：cfg.sftp → cfg.media.sftp → cfg 本身）。
fn jump_sftp_cfg(cfg : Json) -> Json {
  match act_json_field(cfg, "sftp") {
    Some(v) =>
      match v {
        Null => jump_media_cfg(cfg)
        _ => v
      }
    None => jump_media_cfg(cfg)
  }
}

///|
/// `cfg.media.sftp` 或 cfg 本身（`_sftp_cfg_of` 的第二/第三优先级）。
fn jump_media_cfg(cfg : Json) -> Json {
  match act_json_field(cfg, "media") {
    Some(media) =>
      match act_json_field(media, "sftp") {
        Some(v) =>
          match v {
            Null => cfg
            _ => v
          }
        None => cfg
      }
    None => cfg
  }
}

///|
/// 校验 jump.* 的公共前置条件，返回 `(sftp_cfg, local_path, remote_path)`。
///
/// 错误文案与 vools 逐字对齐（便于跨实现对照）：
///   - 缺 host → `缺少 sftp.host 配置`
///   - 缺路径 → `payload 需要 local_path 与 remote_path`（pull 为 remote 在前）
fn jump_require_target(
  cfg : Json,
  payload : Json?,
) -> Result[(Json, String, String), String] {
  let sftp = jump_sftp_cfg(cfg)
  let host = match act_json_str(sftp, "host") {
    Some(h) => h
    None => ""
  }
  if host == "" {
    return Err("缺少 sftp.host 配置")
  }
  let local_path = act_payload_str(payload, "local_path", "")
  let remote_path = act_payload_str(payload, "remote_path", "")
  if local_path == "" || remote_path == "" {
    return Err("payload 需要 local_path 与 remote_path")
  }
  Ok((sftp, local_path, remote_path))
}

///|
/// 构造 `{"status":"error","message":...}`（内层动作错误形状，对齐 vools）。
fn jump_error(message : String) -> Json {
  Json::object({
    "status": Json::string("error"),
    "message": Json::string(message),
    "transport": Json::string("none"),
  })
}

///|
/// 真传输不可用时的可诊断出参（**绝不**伪造 files_transferred）。
fn jump_unsupported(op : String, planned : Int32) -> Json {
  Json::object({
    "status": Json::string("error"),
    "files_transferred": Json::number(0.0),
    "planned_files": Json::number(planned.to_double()),
    "transport": Json::string("unsupported"),
    "message": Json::string(
      "jump.\{op} 真传输未实现：MoonBit/js 侧无 SSH/SFTP 客户端；" +
      "请用 dry_run 取结构化计划，或改用共享目录通道（SyncFolder / shared）",
    ),
  })
}

///|
/// 两条文件记录的内容是否相同（优先 sha256；缺失时退回 size 比较）。
fn jump_same_content(local : Json?, remote : Json?) -> Bool {
  let l = match local {
    Some(v) => v
    None => return false
  }
  let r = match remote {
    Some(v) => v
    None => return false
  }
  let l_sha = act_json_str(l, "sha256")
  let r_sha = act_json_str(r, "sha256")
  match (l_sha, r_sha) {
    (Some(a), Some(b)) => a == b
    _ => act_json_int(l, "size", -1) == act_json_int(r, "size", -2)
  }
}

///|
/// 取相对路径的最后一段。
fn jump_basename_of(relpath : String) -> String {
  let n = relpath.length()
  let mut cut = 0
  let mut i = 0
  while i < n {
    let ch = match relpath.get_view(start=i, end=i + 1) {
      Some(v) => v.to_owned()
      None => ""
    }
    if ch == "/" || ch == "\\" {
      cut = i + 1
    }
    i = i + 1
  }
  match relpath.get_view(start=cut) {
    Some(v) => v.to_owned()
    None => ""
  }
}

///|
/// payload 取整数字段辅助（保留给后续动作；当前用于类型对齐）。
fn act_payload_int(payload : Json?, key : String, default : Int32) -> Int32 {
  match payload {
    Some(v) => act_json_int(v, key, default)
    None => default
  }
}

///|
/// 取 payload 的 `{}`/数组等任意字段（缺失 → None）。
fn act_payload_field(payload : Json?, key : String) -> Json? {
  match payload {
    Some(v) => act_json_field(v, key)
    None => None
  }
}

///|
/// payload 取字符串字段（缺失/空串 → default）。
fn act_payload_str(payload : Json?, key : String, default : String) -> String {
  match payload {
    Some(v) =>
      match act_json_str(v, key) {
        Some(s) => if s == "" { default } else { s }
        None => default
      }
    None => default
  }
}

///|
/// payload 取布尔字段（缺失 → default）。
fn act_payload_bool(payload : Json?, key : String, default : Bool) -> Bool {
  match act_payload_field(payload, key) {
    Some(True) => true
    Some(False) => false
    _ => default
  }
}

///|
/// payload 取字符串数组字段（缺失/类型不符 → 空数组；非字符串项跳过）。
fn act_payload_list(payload : Json?, key : String) -> Array[String] {
  let out : Array[String] = []
  match act_payload_field(payload, key) {
    Some(Array(items)) =>
      for item in items {
        match item {
          String(s) => out.push(s)
          _ => ()
        }
      }
    _ => ()
  }
  out
}

///|
/// Json 对象取键列表（非对象 → 空）。
fn act_object_keys(value : Json) -> Array[String] {
  let out : Array[String] = []
  match value {
    Object(members) =>
      for key in members.keys() {
        out.push(key)
      }
    _ => ()
  }
  out
}

///|
/// Json 对象取字段（非对象/缺失 → None）。
fn act_object_get(value : Json, key : String) -> Json? {
  match value {
    Object(members) => members.get(key)
    _ => None
  }
}

///|
/// 字符串数组 → Json 数组。
fn jump_str_array(items : Array[String]) -> Json {
  let out : Array[Json] = []
  for item in items {
    out.push(Json::string(item))
  }
  Json::array(out)
}

///|
/// 取前 n 个元素（预览列表限长，避免巨型目录把出参撑爆）。
fn jump_take(items : Array[String], n : Int32) -> Array[String] {
  let out : Array[String] = []
  let cap = if n < 0 { 0 } else { n }
  let mut i = 0
  while i < items.length() && i < cap {
    out.push(items[i])
    i = i + 1
  }
  out
}

// ---------------------------------------------------------------------------
// JSON 取值 helper（原有，名字带 act_ 前缀以避免与其它 lane 的同名 helper 撞）
// ---------------------------------------------------------------------------

///|
/// 取对象字段；非对象或字段缺失返回 None。
fn act_json_field(j : Json, key : String) -> Json? {
  match j {
    Object(members) => members.get(key)
    _ => None
  }
}

///|
/// 取字符串字段；缺失或类型不符返回 None。
fn act_json_str(j : Json, key : String) -> String? {
  match act_json_field(j, key) {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
/// 取整数字段（数字或可解析的字符串），缺失/非法时回退 `default`。
fn act_json_int(j : Json, key : String, default : Int32) -> Int32 {
  match act_json_field(j, key) {
    Some(Number(n, ..)) => n.to_int()
    Some(String(s)) => {
      let parsed = @json.parse(s) catch { _ => Json::null() }
      match parsed {
        Number(n, ..) => n.to_int()
        _ => default
      }
    }
    _ => default
  }
}

///|
/// 构造 `{"error": msg}` 的 omega_gate 载荷。
fn act_gate(msg : String) -> Json {
  Json::object({ "error": Json::string(msg) })
}

///|
/// 构造 `{"status": "error", "omega_gate": gate}` 的错误出参。
fn act_error(gate : Json) -> Json {
  Json::object({ "status": Json::string("error"), "omega_gate": gate })
}
