// ============================================================================
// rhop_js_wbtest.mbt —— rhop js 白盒测试（与 rhop_js.mbt 同目标门控）
// 覆盖：join_path 根尾反斜杠分支、join_shared 种子键口径、
//       RhopWatcher 事件侧 seen 键归一化（BUG-1 同族根治回归）
// 运行：moon test --target js
// ============================================================================

///|
/// mkdtemp：Windows 下返回反斜杠绝对路径（正是混合分隔符事件形态的来源）。
extern "js" fn ffi_wb_mkdtemp(prefix : String) -> String =
  #| (prefix) => { const G = globalThis; try { const fs = process.getBuiltinModule("node:fs"); const os = process.getBuiltinModule("node:os"); const d = fs.mkdtempSync(os.tmpdir() + "/" + String(prefix) + "-"); G.__rxmbt_wb_err = ""; return d; } catch (e) { G.__rxmbt_wb_err = String((e && e.message) || e); return ""; } }

///|
extern "js" fn ffi_wb_write(p : String, content : String) -> Bool =
  #| (p, content) => { try { process.getBuiltinModule("node:fs").writeFileSync(String(p), String(content), "utf8"); return true; } catch (_e) { return false; } }

///|
extern "js" fn ffi_wb_rmrf(dir : String) -> Unit =
  #| (dir) => { try { process.getBuiltinModule("node:fs").rmSync(String(dir), { recursive: true, force: true }); } catch (_e) {} }

///|
test "rhop-js  join_path：根尾反斜杠/正斜杠均产出 \"/\" 拼接" {
  // 根以 "\" 结尾（Windows 原样路径）——修复前原样拼出反斜杠路径
  assert_eq(join_path("C:\\dir\\", "x.rhop"), "C:/dir/x.rhop")
  // 根以 "/" 结尾：行为不变
  assert_eq(join_path("C:/dir/", "x.rhop"), "C:/dir/x.rhop")
  // 根无尾分隔符：补 "/"
  assert_eq(join_path("C:/dir", "x.rhop"), "C:/dir/x.rhop")
  // Windows 反斜杠根（内部反斜杠一并归一化）
  assert_eq(join_path("C:\\dir", "x.rhop"), "C:/dir/x.rhop")
  // 纯根形态保留
  assert_eq(join_path("/", "x.rhop"), "/x.rhop")
}

///|
test "rhop-js  join_shared：根尾反斜杠不再产出 \\/ 混合形态" {
  // 修复前：root="C:\dir\" 原样进拼接 → "C:\dir\/old-1.rhop"（与事件键失配）
  assert_eq(join_shared("C:\\dir\\", "old-1.rhop"), "C:/dir/old-1.rhop")
  assert_eq(join_shared("C:/dir", "old-1.rhop"), "C:/dir/old-1.rhop")
}

///|
test "rhop-js  RhopWatcher 事件侧：混合分隔符路径不重放已存在项" {
  let dir = ffi_wb_mkdtemp("rhop-wb-skip")
  assert_true(dir != "")
  let key = "wb-test-key"
  let crypto = RhopCrypto::from_key(key)
  let w = RhopWatcher::new(dir, crypto)
  w.skip_existing_files = true
  // 预置「订阅前已存在」的信封（真实信封：同一把 key 加密）
  let payload = @json.parse("{\"seq\": 1}") catch { _ => fail("测试载荷解析失败") }
  let env = crypto.encrypt_json(payload)
  assert_true(env != "")
  let old_path = join_shared(dir, "old-1.rhop")
  assert_true(ffi_wb_write(old_path, env))
  // start() 的种子语义（同步可测路径）：join_shared 产归一化键
  seed_seen(dir, w.exts, w.seen)
  assert_eq(w.seen.val.length(), 1)
  // 事件分支：mkdtemp 在 Windows 产出反斜杠绝对路径，"+" 拼接得混合形态
  //（修复前事件路径正是这种形态 ⇒ seen 失配重放）
  w.handle_event(
    @monitor.WatchEvent::{
      path: dir + "/old-1.rhop",
      kind: @monitor.WatchKind::Modified,
      timestamp: 1700000006000L,
      raw: "rename",
    },
  )
  // 已存在项不被重放：seen 不增长、也不计坏文件
  assert_eq(w.seen.val.length(), 1)
  assert_eq(w.bad.val, 0)
  // 正向对照：新文件仍被处理并入账（归一化键）
  let payload2 = @json.parse("{\"seq\": 2}") catch { _ => fail("测试载荷解析失败") }
  let env2 = crypto.encrypt_json(payload2)
  assert_true(ffi_wb_write(join_shared(dir, "new-1.rhop"), env2))
  w.handle_event(
    @monitor.WatchEvent::{
      path: dir + "/new-1.rhop",
      kind: @monitor.WatchKind::Modified,
      timestamp: 1700000007000L,
      raw: "rename",
    },
  )
  assert_eq(w.seen.val.length(), 2)
  ffi_wb_rmrf(dir)
}
