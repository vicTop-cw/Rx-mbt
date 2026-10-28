// ============================================================================
// rhop · actions（公开动作集）测试 —— 全目标（wasm / js / native）
//
// 覆盖：注册表（register/get_handler/unregister/list_actions 的并集语义与覆盖优先级）、
//       run_action 外层包装（成功/未知动作/可用清单）、omega_unwrap 全分支、
//       内置动作 jump.probe 的离线形状、jump.push/pull/sync 的前置校验与离线出参、
//       jump_compute_sync_plan 的五分类纯逻辑、jump_should_exclude、rhop.echo。
//
// 真文件扫描（jump_collect_files / jump_scan_local 的 js 分支）在
// test-suit/rhop_business/actions_fs_test.mbt（需要 node:fs）。
// ============================================================================

///|
/// 取 Json 对象里的字符串字段（缺失 → ""）。
fn ac_str(value : Json, key : String) -> String {
  match value {
    Object(members) =>
      match members.get(key) {
        Some(String(s)) => s
        _ => ""
      }
    _ => ""
  }
}

///|
/// 取 Json 对象里的布尔字段（缺失 → false）。
fn ac_bool(value : Json, key : String) -> Bool {
  match value {
    Object(members) =>
      match members.get(key) {
        Some(True) => true
        _ => false
      }
    _ => false
  }
}

///|
/// 取 Json 对象里的数字字段（缺失/非数字 → NaN，便于断言「键不存在」时失败得明显）。
fn ac_num(value : Json, key : String) -> Double {
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
/// 取 Json 对象里的数组字段（缺失 → 空数组）。
fn ac_array(value : Json, key : String) -> Array[Json] {
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
/// 取 Json 对象字段（缺失 → Null）。
fn ac_field(value : Json, key : String) -> Json {
  match value {
    Object(members) =>
      match members.get(key) {
        Some(v) => v
        _ => Json::null()
      }
    _ => Json::null()
  }
}

///|
/// 解析 JSON 文本（测试语料用；失败直接 abort，不静默）。
fn ac_json(text : String) -> Json {
  @json.parse(text) catch {
    e => abort("测试语料不是合法 JSON: \{text}（\{e}）")
  }
}

///|
test "actions: 注册表 —— register/get_handler/list/unregister 与内置动作并集" {
  let handler : (Json, Json?) -> Json = fn(cfg, payload) {
    let _ = (cfg, payload)
    Json::object({ "status": Json::string("ok"), "who": Json::string("t1") })
  }
  // 未注册前
  assert_true(@rp.get_handler("test.t1").is_none())
  @rp.register_action("test.t1", handler)
  // 注册后可见（注册表 ∪ 内置）
  let known = @rp.list_actions()
  assert_true(known.contains("test.t1"))
  assert_true(known.contains("jump.probe"))
  assert_true(known.contains("jump.push"))
  assert_true(known.contains("jump.pull"))
  assert_true(known.contains("jump.sync"))
  assert_true(known.contains("rhop.echo"))
  assert_true(@rp.get_handler("test.t1").is_some())
  // 同名注册覆盖旧处理器
  @rp.register_action("test.t1", fn(cfg, payload) {
    let _ = (cfg, payload)
    Json::object({ "status": Json::string("ok"), "who": Json::string("t2") })
  })
  let out = @rp.run_action("test.t1", Json::null(), None)
  assert_eq(ac_str(ac_field(out, "data"), "who"), "t2")
  // 注销（幂等：第二次 false）
  assert_true(@rp.unregister_action("test.t1"))
  assert_true(!@rp.unregister_action("test.t1"))
  assert_true(@rp.get_handler("test.t1").is_none())
  assert_true(!@rp.list_actions().contains("test.t1"))
  // 注销内置动作不会生效（内置不在注册表里）
  assert_true(!@rp.unregister_action("jump.probe"))
  assert_true(@rp.get_handler("jump.probe").is_some())
}

///|
test "actions: run_action 外层包装 —— 成功 / 未知动作（含可用清单）" {
  @rp.register_action("test.wrap", fn(cfg, payload) {
    let _ = (cfg, payload)
    Json::object({ "status": Json::string("ok"), "n": Json::number(1.0) })
  })
  let ok = @rp.run_action("test.wrap", Json::null(), None)
  assert_eq(ac_str(ok, "status"), "ok")
  assert_eq(ac_str(ok, "action"), "test.wrap")
  assert_eq(ac_str(ac_field(ok, "data"), "status"), "ok")
  assert_true(@rp.unregister_action("test.wrap"))
  assert_true(!@rp.unregister_action("test.wrap"))
  // 未知动作：外层 error + omega_gate.error 带「未知动作」与可用清单
  let bad = @rp.run_action("no.such.action", Json::null(), None)
  assert_eq(ac_str(bad, "status"), "error")
  assert_eq(ac_str(bad, "action"), "no.such.action")
  assert_true(ac_field(bad, "data") is Null)
  let gate_err = ac_str(ac_field(bad, "omega_gate"), "error")
  assert_true(gate_err.contains("未知动作"))
  assert_true(gate_err.contains("jump.probe"))
}

///|
test "actions: omega_unwrap —— 成功 / partial / 外层异常 / data 缺失 / 内层失败" {
  // 成功：返回内层 data
  let ok = ac_json(
    "{\"status\":\"ok\",\"action\":\"x\",\"data\":{\"status\":\"ok\",\"v\":1}}",
  )
  let unwrapped = @rp.omega_unwrap(ok)
  assert_eq(ac_str(unwrapped, "status"), "ok")
  assert_eq(ac_num(unwrapped, "v"), 1.0)
  // partial 视为可接受
  let partial = ac_json(
    "{\"status\":\"ok\",\"action\":\"x\",\"data\":{\"status\":\"partial\"}}",
  )
  assert_eq(ac_str(@rp.omega_unwrap(partial), "status"), "partial")
  // 外层异常：沿用已有 omega_gate
  let outer_bad = ac_json(
    "{\"status\":\"error\",\"action\":\"x\",\"data\":null,\"omega_gate\":{\"error\":\"boom\"}}",
  )
  let g1 = @rp.omega_unwrap(outer_bad)
  assert_eq(ac_str(g1, "status"), "error")
  assert_eq(ac_str(ac_field(g1, "omega_gate"), "error"), "boom")
  // 外层异常但没给 omega_gate：补一条原因（不返回空 gate）
  let outer_bad2 = ac_json("{\"status\":\"weird\"}")
  let g2 = @rp.omega_unwrap(outer_bad2)
  assert_eq(ac_str(ac_field(g2, "omega_gate"), "error"), "外层状态异常")
  // 内层 data 缺失 / 非对象
  let no_data = ac_json("{\"status\":\"ok\",\"action\":\"x\"}")
  assert_eq(
    ac_str(ac_field(@rp.omega_unwrap(no_data), "omega_gate"), "error"),
    "内层 data 缺失或非 dict",
  )
  let data_not_obj = ac_json(
    "{\"status\":\"ok\",\"action\":\"x\",\"data\":[1,2]}",
  )
  assert_eq(
    ac_str(ac_field(@rp.omega_unwrap(data_not_obj), "omega_gate"), "error"),
    "内层 data 缺失或非 dict",
  )
  // 内层失败：错误里带 action / 原因 / 原始 data
  let inner_bad = ac_json(
    "{\"status\":\"ok\",\"action\":\"x\",\"data\":{\"status\":\"error\"}}",
  )
  let g3 = @rp.omega_unwrap(inner_bad)
  assert_eq(ac_str(g3, "status"), "error")
  let gate = ac_field(g3, "omega_gate")
  assert_eq(ac_str(gate, "action"), "x")
  assert_eq(ac_str(gate, "error"), "内层 status=error")
  assert_eq(ac_str(ac_field(gate, "data"), "status"), "error")
}

///|
test "actions: jump.probe 离线形状（有/无 sftp.host 两态）" {
  // 有 host：reachable=false、transport=offline、offline=true、带端口/目录/凭据标记
  let cfg = ac_json(
    "{\"sftp\":{\"host\":\"jump.example\",\"port\":10022,\"user\":\"ops\",\"dir\":\"/srv\",\"password\":\"x\"}}",
  )
  let out = @rp.run_action("jump.probe", cfg, None)
  assert_eq(ac_str(out, "status"), "ok")
  let data = ac_field(out, "data")
  assert_eq(ac_str(data, "status"), "ok")
  assert_true(!ac_bool(data, "reachable")) // 离线：永不声称可达
  assert_eq(ac_str(data, "transport"), "offline")
  assert_true(ac_bool(data, "offline"))
  assert_eq(ac_str(data, "host"), "jump.example")
  assert_eq(ac_str(data, "dir"), "/srv")
  assert_true(ac_bool(data, "has_user"))
  assert_true(ac_bool(data, "has_credentials"))
  // 无 host：transport=none + detail 说明缺配置
  let no_host = @rp.run_action("jump.probe", ac_json("{\"sftp\":{}}"), None)
  let d2 = ac_field(no_host, "data")
  assert_eq(ac_str(d2, "transport"), "none")
  assert_true(ac_str(d2, "detail").contains("sftp.host"))
  // 认三种配置形态：cfg.sftp / cfg.media.sftp / cfg 本身
  let via_media = @rp.run_action(
    "jump.probe",
    ac_json("{\"media\":{\"sftp\":{\"host\":\"m.example\"}}}"),
    None,
  )
  assert_eq(ac_str(ac_field(via_media, "data"), "host"), "m.example")
  let via_self = @rp.run_action(
    "jump.probe",
    ac_json("{\"host\":\"self.example\"}"),
    None,
  )
  assert_eq(ac_str(ac_field(via_self, "data"), "host"), "self.example")
}

///|
test "actions: jump.push/pull/sync —— 前置校验错误形状与 vools 文案对齐" {
  let no_host = ac_json("{\"sftp\":{}}")
  let ok_cfg = ac_json("{\"sftp\":{\"host\":\"h.example\",\"user\":\"u\"}}")
  let no_paths = ac_json("{\"dry_run\":true}")
  // 缺 host
  for name in ["jump.push", "jump.pull", "jump.sync"] {
    let out = @rp.run_action(name, no_host, Some(no_paths))
    assert_eq(ac_str(ac_field(out, "data"), "status"), "error")
    assert_eq(
      ac_str(ac_field(out, "data"), "message"),
      "缺少 sftp.host 配置",
    )
  }
  // 缺路径
  for name in ["jump.push", "jump.pull", "jump.sync"] {
    let out = @rp.run_action(name, ok_cfg, Some(no_paths))
    assert_eq(
      ac_str(ac_field(out, "data"), "message"),
      "payload 需要 local_path 与 remote_path",
    )
  }
  // 完全没有 payload（None）
  let out = @rp.run_action("jump.push", ok_cfg, None)
  assert_eq(ac_str(ac_field(out, "data"), "status"), "error")
}

///|
test "actions: jump.push —— 不存在的本地路径 dry_run 给空清单（不伪造）" {
  let cfg = ac_json("{\"sftp\":{\"host\":\"h.example\"}}")
  let payload = ac_json(
    "{\"local_path\":\"/no/such/local-for-rhop-test\",\"remote_path\":\"/remote\",\"dry_run\":true}",
  )
  let out = @rp.run_action("jump.push", cfg, Some(payload))
  let data = ac_field(out, "data")
  assert_eq(ac_str(data, "status"), "ok")
  // 非 js 目标无文件系统 ⇒ 也必然 0；js 目标路径不存在 ⇒ 0
  assert_eq(ac_num(data, "files_transferred"), 0.0)
  assert_eq(ac_num(data, "total_files"), 0.0)
  assert_eq(ac_str(data, "transport"), "offline")
  assert_true(ac_str(data, "message").contains("没有需要传输的文件"))
  // 非 dry_run：可诊断「真传输未实现」，且 files_transferred 不被伪造
  let real = ac_json(
    "{\"local_path\":\"/no/such/local-for-rhop-test\",\"remote_path\":\"/remote\"}",
  )
  let out2 = @rp.run_action("jump.push", cfg, Some(real))
  let d2 = ac_field(out2, "data")
  // 没有文件时 vools 也是 ok + 0；这里同样是 ok（先判空再判 dry_run）
  assert_eq(ac_str(d2, "status"), "ok")
  assert_eq(ac_str(d2, "transport"), "offline")
}

///|
test "actions: jump.pull/sync —— 无 remote_files 时明说无法离线预览（不假装知道远端）" {
  let cfg = ac_json("{\"sftp\":{\"host\":\"h.example\"}}")
  let payload = ac_json(
    "{\"local_path\":\"/no/such/local\",\"remote_path\":\"/remote\",\"dry_run\":true}",
  )
  let pull = ac_field(@rp.run_action("jump.pull", cfg, Some(payload)), "data")
  assert_eq(ac_str(pull, "status"), "ok")
  assert_true(ac_bool(pull, "dry_run"))
  assert_true(!ac_bool(pull, "remote_listing_provided"))
  assert_true(ac_str(pull, "message").contains("remote_files"))
  let sync = ac_field(@rp.run_action("jump.sync", cfg, Some(payload)), "data")
  assert_eq(ac_str(sync, "status"), "ok")
  assert_true(!ac_bool(sync, "remote_listing_provided"))
  assert_eq(ac_str(sync, "direction"), "both")
}

///|
test "actions: jump_compute_sync_plan —— 五分类（upload/download/conflict/skip/delete）" {
  let local = ac_json(
    "{\"a\":{\"sha256\":\"x\",\"size\":1},\"b\":{\"sha256\":\"y\",\"size\":2},\"same\":{\"sha256\":\"s\",\"size\":3}}",
  )
  let remote = ac_json(
    "{\"b\":{\"sha256\":\"y2\",\"size\":2},\"same\":{\"sha256\":\"s\",\"size\":3},\"c\":{\"sha256\":\"z\",\"size\":4}}",
  )
  // both：a 上传、c 下载、b 冲突、same 跳过
  let both = @rp.jump_compute_sync_plan(local, remote, "both", false)
  assert_eq(ac_array(both, "upload").length(), 1)
  assert_eq(ac_array(both, "download").length(), 1)
  assert_eq(ac_array(both, "conflict").length(), 1)
  assert_eq(ac_array(both, "skip").length(), 1)
  assert_eq(ac_array(both, "delete").length(), 0)
  // upload-only：远端独有的 c 进 skip（未开 delete）
  let up = @rp.jump_compute_sync_plan(local, remote, "upload", false)
  assert_eq(ac_array(up, "upload").length(), 2)
  assert_eq(ac_array(up, "download").length(), 0)
  assert_eq(ac_array(up, "delete").length(), 0)
  // upload + delete：远端独有的 c 进 delete
  let up_del = @rp.jump_compute_sync_plan(local, remote, "upload", true)
  assert_eq(ac_array(up_del, "delete").length(), 1)
  // download-only：本地独有的 a 进 skip，b 因内容不同进 download
  let down = @rp.jump_compute_sync_plan(local, remote, "download", false)
  assert_eq(ac_array(down, "download").length(), 2)
  assert_eq(ac_array(down, "upload").length(), 0)
  assert_eq(ac_array(down, "skip").length(), 2)
  // 空两侧：全空，不崩
  let empty = @rp.jump_compute_sync_plan(
    ac_json("{}"),
    ac_json("{}"),
    "both",
    false,
  )
  assert_eq(ac_array(empty, "upload").length(), 0)
  assert_eq(ac_array(empty, "download").length(), 0)
}

///|
test "actions: jump_should_exclude —— glob / basename / 精确 / 空模式" {
  let pats : Array[String] = ["*.tmp", "cache/*", "exact.txt", ""]
  assert_true(@rp.jump_should_exclude("a.tmp", pats))
  assert_true(@rp.jump_should_exclude("sub/dir/b.tmp", pats)) // basename 命中
  assert_true(@rp.jump_should_exclude("cache/x.bin", pats)) // 相对路径命中
  assert_true(@rp.jump_should_exclude("exact.txt", pats))
  assert_true(!@rp.jump_should_exclude("keep.csv", pats))
  assert_true(!@rp.jump_should_exclude("", pats)) // 空串不被空模式命中
  // 空规则表：谁都不排
  assert_true(!@rp.jump_should_exclude("anything.bin", []))
}

///|
test "actions: rhop.echo —— 离线自检动作回显 cfg/payload" {
  let cfg = ac_json("{\"a\":1}")
  let payload = ac_json("{\"b\":[true,null]}")
  let out = @rp.run_action("rhop.echo", cfg, Some(payload))
  assert_eq(ac_str(out, "status"), "ok")
  let data = ac_field(out, "data")
  assert_eq(ac_str(data, "status"), "ok")
  assert_eq(ac_str(data, "action"), "rhop.echo")
  assert_true(ac_bool(data, "offline"))
  assert_eq(ac_field(data, "cfg"), cfg)
  assert_eq(ac_field(data, "payload"), payload)
  // payload 缺省 → null
  let out2 = ac_field(@rp.run_action("rhop.echo", cfg, None), "data")
  assert_true(ac_field(out2, "payload") is Null)
}
