// ============================================================================
// rhop_business · 动作集的真文件部分（js：node:fs）
//
// test-suit/rhop/actions_test.mbt（全目标）只覆盖纯逻辑；这里覆盖需要真实文件系统的那部分：
//   - jump.push 的 dry_run 真实扫描（含 exclude 生效、递归、限长）；
//   - jump_scan_local 的 sha256 + size 产物形状；
//   - jump.sync / jump.pull 用调用方注入的 remote_files 离线算出真计划。
// 目标：js。
// ============================================================================

///|
/// 造一个源目录：a.csv / b.tmp / sub/c.csv。
fn actions_fs_fixture(dir : String) -> String {
  let src = @rp.rhop_join(dir, "src")
  let files : Array[(String, String)] = [
    ("a.csv", "alpha"),
    ("b.tmp", "junk"),
    ("sub/c.csv", "nested"),
  ]
  for pair in files {
    let (rel, content) = pair
    match @rp.rhop_fs_write_text(@rp.rhop_join(src, rel), content) {
      Ok(_) => ()
      Err(e) => abort("造动作测试文件失败 \{rel}: \{e}")
    }
  }
  src
}

///|
test "actions(fs): jump.push dry_run 真实扫描本地目录（exclude 生效 + 递归）" {
  let dir = biz_temp_workspace()
  let src = actions_fs_fixture(dir)
  let cfg_fields : Map[String, Json] = Map([])
  cfg_fields["sftp"] = Json::object({ "host": Json::string("h.example") })
  let cfg = Json::object(cfg_fields)
  let payload_fields : Map[String, Json] = Map([])
  payload_fields["local_path"] = Json::string(src)
  payload_fields["remote_path"] = Json::string("/remote/inbox")
  payload_fields["dry_run"] = Json::boolean(true)
  payload_fields["exclude"] = Json::array([Json::string("*.tmp")])
  let payload = Json::object(payload_fields)
  let out = @rp.run_action("jump.push", cfg, Some(payload))
  assert_status(ac_field_of(out, "data"), "ok")
  let data = ac_field_of(out, "data")
  // 2 个（a.csv + sub/c.csv），b.tmp 被 exclude 掉
  assert_eq(jnum(data, "total_files"), 2.0)
  assert_true(jbool(data, "dry_run"))
  let files = jstr_array(data, "files")
  assert_eq(files.length(), 2)
  assert_true(files.contains("a.csv"))
  assert_true(files.contains("sub/c.csv"))
  assert_true(!files.contains("b.tmp"))
}

///|
test "actions(fs): jump_scan_local 产出 {relpath: {sha256,size}}" {
  let dir = biz_temp_workspace()
  let src = actions_fs_fixture(dir)
  let scan = @rp.jump_scan_local(src, [])
  // 3 个文件全在（含 b.tmp：本次不排除）
  let upload = jstr_array(
    @rp.jump_compute_sync_plan(scan, Json::object(Map([])), "upload", false),
    "upload",
  )
  assert_eq(sort_strings(upload).join(","), "a.csv,b.tmp,sub/c.csv")
  // 每个条目带 sha256（64 hex）与 size
  match scan {
    Object(members) =>
      match members.get("a.csv") {
        Some(entry) => {
          let sha = jstr(entry, "sha256")
          assert_eq(sha.length(), 64)
          assert_eq(jnum(entry, "size"), 5.0)
        }
        None => abort("scan 结果应含 a.csv")
      }
    _ => abort("scan 结果应是 JSON 对象")
  }
}

///|
test "actions(fs): jump.sync 带 remote_files → 离线算真计划（upload/download/skip）" {
  let dir = biz_temp_workspace()
  let src = actions_fs_fixture(dir)
  let scan = @rp.jump_scan_local(src, [])
  // 远端清单：a.csv 与本地同内容（skip）、c.csv 内容不同（conflict）、remote-only.txt 只在远端（download）
  let a_entry = match scan {
    Object(members) => members.get("a.csv")
    _ => None
  }
  let remote_fields : Map[String, Json] = Map([])
  remote_fields["a.csv"] = match a_entry {
    Some(v) => v
    None => Json::null()
  }
  remote_fields["sub/c.csv"] = Json::object({
    "sha256": Json::string("deadbeef"),
    "size": Json::number(6.0),
  })
  remote_fields["remote-only.txt"] = Json::object({
    "sha256": Json::string("cafe"),
    "size": Json::number(4.0),
  })
  let remote = Json::object(remote_fields)
  let payload_fields : Map[String, Json] = Map([])
  payload_fields["local_path"] = Json::string(src)
  payload_fields["remote_path"] = Json::string("/remote")
  payload_fields["dry_run"] = Json::boolean(true)
  payload_fields["direction"] = Json::string("both")
  payload_fields["remote_files"] = remote
  let payload = Json::object(payload_fields)
  let cfg = Json::object({
    "sftp": Json::object({ "host": Json::string("h.example") }),
  })
  let out = @rp.run_action("jump.sync", cfg, Some(payload))
  let data = ac_field_of(out, "data")
  assert_status(data, "ok")
  assert_true(jbool(data, "remote_listing_provided"))
  let plan = ac_field_of(data, "plan")
  let upload = sort_strings(jstr_array(plan, "upload"))
  let download = sort_strings(jstr_array(plan, "download"))
  let conflict = sort_strings(plan_relpaths(plan, "conflict"))
  let skip = sort_strings(jstr_array(plan, "skip"))
  // b.tmp 只在本地 → upload；remote-only.txt 只在远端 → download
  assert_true(upload.contains("b.tmp"))
  assert_true(download.contains("remote-only.txt"))
  // sub/c.csv 两侧 sha 不同 → conflict（both 方向）
  assert_true(conflict.contains("sub/c.csv"))
  // a.csv 两侧一致 → skip
  assert_true(skip.contains("a.csv"))
}

// ---------------------------------------------------------------------------
// 本文件私有 helper（js-only 测试，与其它测试文件不冲突的命名）
// ---------------------------------------------------------------------------

///|
/// 取 Json 对象字段（缺失 → Null）。
fn ac_field_of(value : Json, key : String) -> Json {
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
/// 取计划里某一侧的「条目名」：字符串项直接用，对象项取 `relpath`（conflict 是对象）。
fn plan_relpaths(plan : Json, key : String) -> Array[String] {
  let out : Array[String] = []
  for item in jarr(plan, key) {
    match item {
      String(s) => out.push(s)
      Object(members) =>
        match members.get("relpath") {
          Some(String(s)) => out.push(s)
          _ => ()
        }
      _ => ()
    }
  }
  out
}

///|
/// 取 Json 布尔字段（缺失 → false）。
fn jbool(value : Json, key : String) -> Bool {
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
/// 原地排序字符串数组（返回新数组，稳定便于断言）。
fn sort_strings(items : Array[String]) -> Array[String] {
  let out = items.copy()
  let n = out.length()
  let mut i = 0
  while i < n {
    let mut j = 0
    while j + 1 < n - i {
      if out[j] > out[j + 1] {
        let tmp = out[j]
        out[j] = out[j + 1]
        out[j + 1] = tmp
      }
      j = j + 1
    }
    i = i + 1
  }
  out
}
