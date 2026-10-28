// ============================================================================
// rhop_business · 非 js 目标（wasm / native）可诊断 Err 测试
//
// Batch D 的业务层依赖 node:sqlite / node:fs，**只有 js 目标真跑**。
// 本文件锁定「非 js 不给假成功」这一契约：构造期/首调即返回带原因的中文 Err，
// 且纯逻辑部分（TaskStatus 流转等）仍可用 —— 保证三目标 `moon check` 之外，
// `moon test` 的 wasm/native 也不是空跑。
// ============================================================================

///|
test "nonjs: MirrorDB::open 返回可诊断 Err（不假装建库成功）" {
  match @rp.MirrorDB::open("nope.db") {
    Ok(_) => abort("非 js 目标不应能建 sqlite 库")
    Err(e) => {
      assert_true(e.contains("js"))
      assert_true(e.contains("sqlite") || e.contains("SQLite"))
    }
  }
  // open_temp 同样不可用
  match @rp.MirrorDB::open_temp() {
    Ok(_) => abort("非 js 目标不应能建临时库")
    Err(e) => assert_true(e.length() > 0)
  }
  // 空路径是**语言级**校验，三目标一致
  match @rp.MirrorDB::open("") {
    Ok(_) => abort("空路径应被拒绝")
    Err(e) => assert_true(e.contains("非空"))
  }
}

///|
test "nonjs: Requester / Executor 构造期即 Err（不返回半残对象）" {
  let cfg = biz_cfg("send", "")
  match @rp.Requester::from_mirror_path(cfg, "nope.db", "") {
    Ok(_) => abort("非 js 目标不应构造出 Requester")
    Err(e) => assert_true(e.contains("建库失败") || e.contains("js"))
  }
  let cfg2 = biz_cfg("recv", "")
  match @rp.Executor::from_mirror_path(cfg2, "nope.db", "") {
    Ok(_) => abort("非 js 目标不应构造出 Executor")
    Err(e) => assert_true(e.contains("建库失败") || e.contains("js"))
  }
  match @rp.RelayDaemon::from_config_dir(cfg, "nope-dir", poll_interval_ms=0) {
    Ok(_) => abort("非 js 目标不应构造出 RelayDaemon")
    Err(e) => assert_true(e.contains("js") || e.contains("执行端"))
  }
}

///|
test "nonjs: 文件系统 API 一律可诊断 Err（写/读/移动/删除/摘要）" {
  let cases : Array[Result[Unit, String]] = [
    @rp.rhop_fs_mkdir_p("x"),
    @rp.rhop_fs_write_text("x/a.txt", "hi"),
    @rp.rhop_fs_move("x/a.txt", "x/b.txt"),
    @rp.rhop_fs_remove("x/a.txt"),
  ]
  for item in cases {
    match item {
      Ok(_) => abort("非 js 目标文件系统写操作不应成功")
      Err(e) => assert_true(e.contains("js"))
    }
  }
  match @rp.rhop_fs_read_text("x/a.txt") {
    Ok(_) => abort("非 js 目标不应读到文件")
    Err(e) => assert_true(e.contains("js"))
  }
  match @rp.rhop_fs_digest_file("x/a.txt") {
    Ok(_) => abort("非 js 目标不应能算文件摘要")
    Err(e) => assert_true(e.contains("js"))
  }
  // 列目录 / 存在性：返回空/false（不抛），由调用方按 errors 处理
  assert_eq(@rp.rhop_fs_list_dir("x").length(), 0)
  assert_eq(@rp.rhop_fs_list_files_recursive("x").length(), 0)
  assert_true(!@rp.rhop_fs_exists("x"))
}

///|
test "nonjs: SyncFolder.sync_once 不抛，错误进 errors 字段" {
  let sf = @rp.SyncFolder::new("src", "dst", "*")
  let one = sf.sync_once()
  assert_eq(jstr_array(one, "pulled").length(), 0)
  assert_true(jstr_array(one, "errors").length() > 0)
  // manifest 路径是纯字符串逻辑，三目标一致
  assert_eq(sf.manifest_path(), "dst/.sync_manifest.json")
}

///|
test "nonjs: 纯逻辑部分仍可用（glob / 时间戳占位 / 任务状态流转）" {
  assert_true(@rp.sync_glob_match("*.csv", "a.csv"))
  // 非 js 无时钟 API：固定占位（文档化行为，不是「随机失败」）
  assert_eq(@rp.rhop_now_iso(), "1970-01-01T00:00:00Z")
  assert_true(@rp.TaskStatus::Pending.can_transition(@rp.TaskStatus::Claimed))
  assert_true(!@rp.TaskStatus::Done.can_transition(@rp.TaskStatus::Running))
  assert_true(@rp.TaskStatus::Done.is_terminal())
}
