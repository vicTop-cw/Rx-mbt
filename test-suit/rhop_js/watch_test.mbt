// ============================================================================
// rhop · 接收方触发器监控测试（js 目标）
//
// 说明：`@monitor` 的 fs.watch 事件只能由事件循环推动，而 MoonBit 测试是同步的
// （主线程阻塞等待时回调永远不会来）。因此本文件用 `RhopWatcher::process_file`
// 这个**同步入口**覆盖「过滤 → 读 → decrypt_verify → 推送/跳过计数」全链路
// （`process_file` 正是事件回调的实际实现），另外单独覆盖 start/stop 生命周期
// 与 skip_existing 的 seen 预填语义。
//
// 覆盖：
//   1. 好文件 → 推送 (filename, VerifyResult(OK))，订阅方收到
//   2. 坏文件（非 JSON 信封 / 错 key）→ 跳过并计数，不推、不中断
//   3. 扩展名过滤（.txt 不处理；with_extensions 可改）
//   4. .tmp 中间态不处理
//   5. 同一路径重复不重复推送（seen）
//   6. start：路径不存在 → Err；已存在 → Ok 且幂等；stop 复位
//   7. skip_existing：启动瞬间已存在的目标文件视为已消费
// ============================================================================

///|
extern "js" fn ffi_w_mkdtemp(prefix : String) -> String =
  #| (prefix) => { try { const fs = process.getBuiltinModule("node:fs"); const os = process.getBuiltinModule("node:os"); const path = process.getBuiltinModule("node:path"); return fs.mkdtempSync(path.join(os.tmpdir(), String(prefix) + "-")); } catch (_e) { return ""; } }

///|
extern "js" fn ffi_w_write(p : String, content : String) -> Bool =
  #| (p, content) => { try { process.getBuiltinModule("node:fs").writeFileSync(String(p), String(content), "utf8"); return true; } catch (_e) { return false; } }

///|
extern "js" fn ffi_w_rmrf(p : String) -> Unit =
  #| (p) => { try { process.getBuiltinModule("node:fs").rmSync(String(p), { recursive: true, force: true }); } catch (_e) {} }

///|
/// 收集订阅到的条目（用 Ref 让闭包可写）。
fn collector() -> (
  @ref.Ref[Array[String]],
  @rx.Observer[(String, @rp.VerifyResult), String],
) {
  let got : @ref.Ref[Array[String]] = @ref.Ref::new([])
  let obs = @rx.Observer::new(
    fn(item : (String, @rp.VerifyResult)) {
      got.val = got.val.copy() + ["\{item.0}|\{item.1.reason}"]
    },
    fn(err : String) { got.val = got.val.copy() + ["ERR:" + err] },
    fn() { () },
  )
  (got, obs)
}

///|
test "watch · 好文件被推送（process_file 全链路）" {
  let dir = ffi_w_mkdtemp("rhop-w1")
  let key = "watch-test-key"
  let crypto = @rp.RhopCrypto::from_key(key)
  let w = @rp.RhopWatcher::new(dir, crypto)
  let (got, obs) = collector()
  let sub = w.observe().subscribe(obs)
  let payload = @json.parse("{\"seq\": 1, \"msg\": \"你好\"}") catch {
    _ => fail("测试载荷解析失败")
  }
  let env = crypto.encrypt_json(payload)
  assert_true(env != "")
  let path = @rp.join_shared(dir, "pkg-1.rhop")
  assert_true(ffi_w_write(path, env))
  match w.process_file(path) {
    Some(r) => {
      assert_true(r.ok)
      assert_eq(r.reason, "OK")
    }
    None => fail("好文件应当被处理并推送")
  }
  assert_eq(w.bad_files(), 0)
  assert_eq(got.val.length(), 1)
  assert_eq(got.val[0], "pkg-1.rhop|OK")
  // 重复同一路径不再推送（seen 去重）
  match w.process_file(path) {
    Some(_) => fail("同一路径不应重复推送")
    None => ()
  }
  assert_eq(got.val.length(), 1)
  sub.dispose()
  ffi_w_rmrf(dir)
}

///|
test "watch · 坏文件跳过并计数（不推送、不中断）" {
  let dir = ffi_w_mkdtemp("rhop-w2")
  let crypto = @rp.RhopCrypto::from_key("watch-test-key")
  let w = @rp.RhopWatcher::new(dir, crypto)
  let (got, obs) = collector()
  let sub = w.observe().subscribe(obs)
  // 1) 不是 JSON 信封
  let bad1 = @rp.join_shared(dir, "bad1.rhop")
  assert_true(ffi_w_write(bad1, "definitely-not-json"))
  assert_true(w.process_file(bad1) is None)
  // 2) 信封结构对但解不开（错 key 加密）
  let other = @rp.RhopCrypto::from_key("another-key")
  let env = other.encrypt_json(
    @json.parse("{\"a\":1}") catch {
      _ => fail("x")
    },
  )
  let bad2 = @rp.join_shared(dir, "bad2.rhop")
  assert_true(ffi_w_write(bad2, env))
  assert_true(w.process_file(bad2) is None)
  // 3) 文件不存在
  assert_true(w.process_file(@rp.join_shared(dir, "nope.rhop")) is None)
  assert_eq(w.bad_files(), 3)
  // 一推送都没有，且后续好文件仍然能收到（不中断）
  assert_eq(got.val.length(), 0)
  let good = @rp.join_shared(dir, "good.rhop")
  assert_true(
    ffi_w_write(
      good,
      crypto.encrypt_json(@json.parse("{\"ok\":true}") catch { _ => fail("x") }),
    ),
  )
  assert_true(w.process_file(good) is Some(_))
  assert_eq(got.val.length(), 1)
  assert_eq(w.bad_files(), 3)
  sub.dispose()
  ffi_w_rmrf(dir)
}

///|
test "watch · 扩展名过滤与 .tmp 中间态" {
  let dir = ffi_w_mkdtemp("rhop-w3")
  let crypto = @rp.RhopCrypto::from_key("watch-test-key")
  let w = @rp.RhopWatcher::new(dir, crypto)
  let env = crypto.encrypt_json(
    @json.parse("{\"x\":1}") catch {
      _ => fail("x")
    },
  )
  // 非 .rhop 扩展名 → 不处理（也不计入坏文件）
  let txt = @rp.join_shared(dir, "note.txt")
  assert_true(ffi_w_write(txt, env))
  assert_true(w.process_file(txt) is None)
  assert_eq(w.bad_files(), 0)
  // .rhop.tmp 中间态 → 不处理
  let tmp = @rp.join_shared(dir, "pkg.rhop.tmp")
  assert_true(ffi_w_write(tmp, env))
  assert_true(w.process_file(tmp) is None)
  assert_eq(w.bad_files(), 0)
  // with_extensions 改成 .pkg 后，.rhop 不再匹配、.pkg 匹配
  let w2 = @rp.RhopWatcher::new(dir, crypto).with_extensions([".pkg"])
  assert_eq(w2.extensions().length(), 1)
  assert_eq(w2.extensions()[0], ".pkg")
  let rhop_file = @rp.join_shared(dir, "z.rhop")
  assert_true(ffi_w_write(rhop_file, env))
  assert_true(w2.process_file(rhop_file) is None)
  let pkg_file = @rp.join_shared(dir, "z.pkg")
  assert_true(ffi_w_write(pkg_file, env))
  assert_true(w2.process_file(pkg_file) is Some(_))
  // 扩展名规范化：给 "PKG" 也等价于 ".pkg"
  let w3 = @rp.RhopWatcher::new(dir, crypto).with_extensions(["PKG"])
  assert_eq(w3.extensions()[0], ".pkg")
  ffi_w_rmrf(dir)
}

///|
test "watch · start/stop 生命周期与错误路径" {
  let dir = ffi_w_mkdtemp("rhop-w4")
  let crypto = @rp.RhopCrypto::from_key("watch-test-key")
  // 路径不存在 → Err（可诊断）
  let ghost = @rp.RhopWatcher::new(
    @rp.join_shared(dir, "no-such-subdir"),
    crypto,
  )
  match ghost.start() {
    Err(e) => assert_true(e.contains("监控路径不存在"))
    Ok(_) => fail("不存在的路径 start 应当 Err")
  }
  // 正常目录 → Ok，幂等，stop 复位
  let w = @rp.RhopWatcher::new(dir, crypto)
  assert_false(w.is_started())
  assert_eq(w.start(), Ok(()))
  assert_true(w.is_started())
  assert_eq(w.start(), Ok(()))
  assert_true(w.is_started())
  w.stop()
  assert_false(w.is_started())
  // stop 幂等
  w.stop()
  assert_false(w.is_started())
  ffi_w_rmrf(dir)
}

///|
test "watch · skip_existing：启动瞬间已存在的目标文件视为已消费" {
  let dir = ffi_w_mkdtemp("rhop-w5")
  let crypto = @rp.RhopCrypto::from_key("watch-test-key")
  let env = crypto.encrypt_json(
    @json.parse("{\"old\":true}") catch {
      _ => fail("x")
    },
  )
  let old = @rp.join_shared(dir, "old.rhop")
  assert_true(ffi_w_write(old, env))
  // 不 skip：老文件会被处理
  let w_no = @rp.RhopWatcher::new(dir, crypto)
  assert_eq(w_no.start(), Ok(()))
  assert_true(w_no.process_file(old) is Some(_))
  w_no.stop()
  // skip：先记住已存在文件，再处理同一路径 → 跳过（不推、不计坏）
  let w_skip = @rp.RhopWatcher::new(dir, crypto).skip_existing(true)
  let (got, obs) = collector()
  let sub = w_skip.observe().subscribe(obs)
  assert_eq(w_skip.start(), Ok(()))
  assert_true(w_skip.process_file(old) is None)
  assert_eq(w_skip.bad_files(), 0)
  assert_eq(got.val.length(), 0)
  // 新文件仍然能被处理
  let fresh = @rp.join_shared(dir, "fresh.rhop")
  assert_true(ffi_w_write(fresh, env))
  assert_true(w_skip.process_file(fresh) is Some(_))
  assert_eq(got.val.length(), 1)
  assert_eq(got.val[0], "fresh.rhop|OK")
  sub.dispose()
  w_skip.stop()
  ffi_w_rmrf(dir)
}

///|
/// 诊断用：统计 monitor 注册表里的 watcher 数量（js: globalThis.__rxmbt_watch_reg）。
extern "js" fn ffi_watch_count() -> Int32 =
  #| () => { const G = globalThis; if (!G.__rxmbt_watch_reg) { return 0; } let n = 0; for (const _k of G.__rxmbt_watch_reg.keys()) { n++; } return n; }

///|
/// 回归用例：`stop()` 必须真正关闭 fs.watch 句柄。
///
/// 历史缺陷（已修）：monitor 的 `ffi_watch_stop` 用 BigInt 去查以 number 为键的
/// `__rxmbt_watch_reg`，`get` 恒 undefined ⇒ close() 从不执行 ⇒ `@rx.Subscription::dispose()`
/// 名存实亡：句柄泄漏 + node 测试进程跑完不退出（moon 永远打不出汇总行）。
/// 这里断言「start 后注册表 +1，stop 后回到基线」，正是该缺陷的回归点。
test "watch · stop() 真正关闭 fs.watch 句柄（dispose 回归）" {
  let dir = ffi_w_mkdtemp("rhop-w6")
  let base = ffi_watch_count()
  let w = @rp.RhopWatcher::new(dir, @rp.RhopCrypto::from_key("k"))
  assert_eq(w.start(), Ok(()))
  assert_eq(ffi_watch_count(), base + 1)
  w.stop()
  assert_eq(ffi_watch_count(), base)
  // 重复 start/stop 也不残留
  assert_eq(w.start(), Ok(()))
  assert_eq(ffi_watch_count(), base + 1)
  w.stop()
  assert_eq(ffi_watch_count(), base)
  ffi_w_rmrf(dir)
}
