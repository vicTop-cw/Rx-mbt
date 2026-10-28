// ============================================================================
// rhop_business · SyncFolder 真文件同步测试（js）
//
// 覆盖边界四问里的「sync 重复拷贝」：同一批文件 sync_once 两次，第二轮必须
// pulled=[] / skipped=N（不重复拷贝）；源内容变化 → 重拉；target 被清理 → 重拉；
// pattern 过滤；manifest 落盘；run_forever 累计。
// 目标：js（node:fs）。
// ============================================================================

///|
/// 在工作目录下造一个源目录 + 若干文件，返回 (source, target)。
fn sync_fixture(
  dir : String,
  files : Array[(String, String)],
) -> (String, String) {
  let source = @rp.rhop_join(dir, "src")
  let target = @rp.rhop_join(dir, "dst")
  for pair in files {
    let (name, content) = pair
    match @rp.rhop_fs_write_text(@rp.rhop_join(source, name), content) {
      Ok(_) => ()
      Err(e) => abort("造源文件失败 \{name}: \{e}")
    }
  }
  (source, target)
}

///|
test "sync: sync_once 两次 → 第二轮 pulled=0 / skipped=1（不重复拷贝）" {
  let dir = biz_temp_workspace()
  let (source, target) = sync_fixture(dir, [("data.csv", "a,b\n1,2\n")])
  let sf = @rp.SyncFolder::new(source, target, "*")
  // 第一轮：拉 1 个
  let first = sf.sync_once()
  let pulled1 = jstr_array(first, "pulled")
  assert_eq(pulled1.length(), 1)
  assert_eq(pulled1[0], "data.csv")
  assert_eq(jnum(first, "skipped"), 0.0)
  assert_true(@rp.rhop_fs_exists(@rp.rhop_join(target, "data.csv")))
  // manifest 应落盘
  assert_true(@rp.rhop_fs_exists(sf.manifest_path()))
  // 第二轮：幂等，不重拷
  let second = sf.sync_once()
  assert_eq(jstr_array(second, "pulled").length(), 0)
  assert_eq(jnum(second, "skipped"), 1.0)
  assert_eq(jstr_array(second, "errors").length(), 0)
}

///|
test "sync: 源内容变化 → 重拉；target 被删 → 重拉" {
  let dir = biz_temp_workspace()
  let (source, target) = sync_fixture(dir, [("data.csv", "v1")])
  let sf = @rp.SyncFolder::new(source, target, "*")
  assert_eq(jstr_array(sf.sync_once(), "pulled").length(), 1)
  assert_eq(jnum(sf.sync_once(), "skipped"), 1.0)
  // 改内容
  match @rp.rhop_fs_write_text(@rp.rhop_join(source, "data.csv"), "v2-longer") {
    Ok(_) => ()
    Err(e) => abort("改源文件失败: \{e}")
  }
  let changed = sf.sync_once()
  assert_eq(jstr_array(changed, "pulled").length(), 1)
  let copied = match @rp.rhop_fs_read_text(@rp.rhop_join(target, "data.csv")) {
    Ok(t) => t
    Err(e) => abort("读目标文件失败: \{e}")
  }
  assert_eq(copied, "v2-longer")
  // 删本地目标文件（源没变）→ 应重拉
  match @rp.rhop_fs_remove(@rp.rhop_join(target, "data.csv")) {
    Ok(_) => ()
    Err(e) => abort("删目标文件失败: \{e}")
  }
  let reparsed = sf.sync_once()
  assert_eq(jstr_array(reparsed, "pulled").length(), 1)
  assert_true(@rp.rhop_fs_exists(@rp.rhop_join(target, "data.csv")))
}

///|
test "sync: pattern 过滤（只拉匹配的文件）+ manifest 自身不被拉" {
  let dir = biz_temp_workspace()
  let (source, target) = sync_fixture(dir, [
    ("a.parquet", "p1"),
    ("b.xlsx", "x1"),
    ("c.parquet", "p2"),
  ])
  let sf = @rp.SyncFolder::new(source, target, "*.parquet")
  let one = sf.sync_once()
  let pulled = jstr_array(one, "pulled")
  assert_eq(pulled.length(), 2)
  assert_true(@rp.rhop_fs_exists(@rp.rhop_join(target, "a.parquet")))
  assert_true(@rp.rhop_fs_exists(@rp.rhop_join(target, "c.parquet")))
  // 不匹配的不拷
  assert_true(!@rp.rhop_fs_exists(@rp.rhop_join(target, "b.xlsx")))
  // manifest 写在 target 下，且不会被当成源文件拉回来
  assert_true(@rp.rhop_fs_exists(sf.manifest_path()))
  let second = sf.sync_once()
  assert_eq(jstr_array(second, "pulled").length(), 0)
  let pulled_names = jstr_array(second, "pulled")
  for name in pulled_names {
    assert_true(name != @rp.SYNC_MANIFEST_NAME)
  }
}

///|
test "sync: 递归模式拉子目录文件（相对路径保留层级）" {
  let dir = biz_temp_workspace()
  let source = @rp.rhop_join(dir, "src")
  let target = @rp.rhop_join(dir, "dst")
  match @rp.rhop_fs_write_text(@rp.rhop_join(source, "a.csv"), "root") {
    Ok(_) => ()
    Err(e) => abort("造文件失败: \{e}")
  }
  match @rp.rhop_fs_write_text(@rp.rhop_join(source, "sub/b.csv"), "nested") {
    Ok(_) => ()
    Err(e) => abort("造子目录文件失败: \{e}")
  }
  // 非递归：只拉 a.csv
  let flat = @rp.SyncFolder::new(source, @rp.rhop_join(dir, "dst-flat"), "*")
  assert_eq(jstr_array(flat.sync_once(), "pulled").length(), 1)
  // 递归：两个都拉（含 sub/b.csv）
  let deep = @rp.SyncFolder::new(source, target, "*.csv").with_recursive(true)
  let one = deep.sync_once()
  let pulled = jstr_array(one, "pulled")
  assert_eq(pulled.length(), 2)
  assert_true(@rp.rhop_fs_exists(@rp.rhop_join(target, "sub/b.csv")))
  // 幂等：第二轮 0 拉
  assert_eq(jstr_array(deep.sync_once(), "pulled").length(), 0)
}

///|
test "sync: run_forever 累计轮数与拉取清单" {
  let dir = biz_temp_workspace()
  let (source, target) = sync_fixture(dir, [("one.csv", "1")])
  let sf = @rp.SyncFolder::new(source, target, "*")
  let summary = sf.run_forever(0, 3)
  assert_eq(jnum(summary, "rounds"), 3.0)
  let total = jstr_array(summary, "total_pulled")
  // 第一轮拉 1 个，后两轮跳过
  assert_eq(total.length(), 1)
  assert_eq(total[0], "one.csv")
}
