// ============================================================================
// watcher_js_wbtest.mbt —— monitor js 白盒测试（与 watcher_js.mbt 同目标门控）
// 覆盖：join_path 根尾反斜杠分支 + normalize_root 口径（BUG-1 同族根治）
// 运行：moon test --target js
// ============================================================================

///|
test "monitor-js  join_path：根尾反斜杠/正斜杠均产出 \"/\" 拼接" {
  assert_eq(join_path("C:\\dir\\", "x.rhop"), "C:/dir/x.rhop")
  assert_eq(join_path("C:/dir/", "x.rhop"), "C:/dir/x.rhop")
  assert_eq(join_path("C:/dir", "x.rhop"), "C:/dir/x.rhop")
  assert_eq(join_path("C:\\dir", "x.rhop"), "C:/dir/x.rhop")
  assert_eq(join_path("/", "x.rhop"), "/x.rhop")
  // 盘符根：归一化去尾斜杠后由拼接补回 "/"
  assert_eq(join_path("C:/", "x.rhop"), "C:/x.rhop")
}

///|
test "monitor-js  normalize_root：反斜杠/重复分隔符/尾分隔符归一" {
  assert_eq(normalize_root("C:\\a\\b\\"), "C:/a/b")
  assert_eq(normalize_root("C:/a//b/"), "C:/a/b")
  assert_eq(normalize_root("/"), "/")
  assert_eq(normalize_root("C:/"), "C:")
}
