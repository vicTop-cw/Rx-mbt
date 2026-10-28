// ============================================================================
// rhop_business · SyncFolder 纯逻辑测试（全目标：wasm / js / native）
//
// 只测不碰文件系统的部分：glob 匹配语义、构造缺省值、manifest 路径、
// 以及 wasm/native 下 sync_once 的「可诊断、不假装成功」行为。
// 真文件同步（幂等两次不重拷）在 sync_folder_test.mbt（js）里。
// ============================================================================

///|
test "sync: glob 匹配语义（* / ? / 字面量）" {
  // 全拉
  assert_true(@rp.sync_glob_match("*", "a.txt"))
  assert_true(@rp.sync_glob_match("*", ""))
  // 后缀过滤
  assert_true(@rp.sync_glob_match("*.parquet", "part-0.parquet"))
  assert_true(!@rp.sync_glob_match("*.parquet", "part-0.xlsx"))
  // 单字符通配
  assert_true(@rp.sync_glob_match("part-?.parquet", "part-1.parquet"))
  assert_true(!@rp.sync_glob_match("part-?.parquet", "part-10.parquet"))
  // 中缀通配
  assert_true(@rp.sync_glob_match("a*b*c", "aXXbYYc"))
  assert_true(!@rp.sync_glob_match("a*b*c", "aXXbYY"))
  // 字面量（无通配）必须全等
  assert_true(@rp.sync_glob_match("exact.csv", "exact.csv"))
  assert_true(!@rp.sync_glob_match("exact.csv", "exact.csv.bak"))
  // 多个 * 连写
  assert_true(@rp.sync_glob_match("**", "anything"))
  // 空模式只匹配空串
  assert_true(@rp.sync_glob_match("", ""))
  assert_true(!@rp.sync_glob_match("", "x"))
}

///|
test "sync: 构造缺省值（pattern 空 → *，manifest 落 target 下）" {
  let sf = @rp.SyncFolder::new("/src", "/dst", "")
  assert_eq(sf.manifest_path(), "/dst/.sync_manifest.json")
  let sf2 = @rp.SyncFolder::new("/src", "/dst", "*.csv")
  assert_eq(sf2.manifest_path(), "/dst/.sync_manifest.json")
  assert_eq(@rp.SYNC_MANIFEST_NAME, ".sync_manifest.json")
  // pattern 保留
  let one = sf.sync_once()
  match one {
    Object(members) => {
      assert_true(members.get("pulled").is_some())
      assert_true(members.get("skipped").is_some())
      assert_true(members.get("errors").is_some())
    }
    _ => abort("sync_once 应返回 JSON 对象")
  }
}

///|
test "sync: 源目录不存在 → errors 有条目、不抛、pulled 为空" {
  let sf = @rp.SyncFolder::new(
    "/no/such/dir-for-rhop-test", "/no/such/dst", "*",
  )
  let one = sf.sync_once()
  assert_eq(jstr_array(one, "pulled").length(), 0)
  let errors = jstr_array(one, "errors")
  // 非 js 目标：无文件系统，断言「有可诊断错误」；js 目标：目录不存在同样报错
  assert_true(errors.length() > 0)
}

///|
test "sync: run_forever 至少跑一轮且 max_rounds 生效" {
  let sf = @rp.SyncFolder::new(
    "/no/such/dir-for-rhop-test", "/no/such/dst", "*",
  )
  let summary = sf.run_forever(0, 2)
  assert_eq(jnum(summary, "rounds"), 2.0)
  assert_eq(sf.rounds(), 2)
  let total = jstr_array(summary, "total_pulled")
  assert_eq(total.length(), 0)
}

///|
test "sync: stop() 语义 —— 置位后 run_forever 不再跑轮" {
  let sf = @rp.SyncFolder::new(
    "/no/such/dir-for-rhop-test", "/no/such/dst", "*",
  )
  sf.stop()
  let summary = sf.run_forever(0, 5)
  // 已置停止位：一轮都不跑
  assert_eq(jnum(summary, "rounds"), 0.0)
}
