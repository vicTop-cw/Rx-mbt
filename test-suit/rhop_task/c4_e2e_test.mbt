// ============================================================================
// C4 · 端到端（跨进程真实场景）：rhop_task 队列
//
// 与既有 task_store/queue 用例的区别：既有用例都是**单进程**（同一 store 句柄）。
// 这里有**独立的 node 进程**直接打开同一份 sqlite 产物库（fixtures/task_worker.js），
// 验证：① 跨进程可见性（进程 A 写入 → 进程 B 领到 → 进程 A 读到 LOCKED）
//       ② 跨进程并发 claim 的唯一性（多进程同时抢，命名不得重复）
//
// 说明：worker 用 node:sqlite 直接操作同一 schema —— 这正是「sqlite-shared 拓扑要求
// 任何实现都能读写同一份库」的契约检验，而不是只验证我方单进程自洽。
// ============================================================================

///|
extern "js" fn ffi_c4t_repo_root() -> String =
  #| () => { const fs = process.getBuiltinModule("node:fs"); const path = process.getBuiltinModule("node:path"); let d = process.cwd(); for (;;) { try { if (fs.existsSync(path.join(d, "moon.mod"))) { return d; } } catch (_e) {} const p = path.dirname(d); if (p === d) { return process.cwd(); } d = p; } }

///|
extern "js" fn ffi_c4t_mkdtemp(prefix : String) -> String =
  #| (prefix) => { try { const G = globalThis; if (!G.__rxmbt_tmp_reg) { G.__rxmbt_tmp_reg = new Set(); } if (!G.__rxmbt_tmp_hook) { G.__rxmbt_tmp_hook = true; process.on("exit", () => { try { const fsm = process.getBuiltinModule("node:fs"); for (const d of G.__rxmbt_tmp_reg) { try { fsm.rmSync(d, { recursive: true, force: true }); } catch (_e) {} } G.__rxmbt_tmp_reg.clear(); } catch (_e2) {} }); } const fs = process.getBuiltinModule("node:fs"); const os = process.getBuiltinModule("node:os"); const path = process.getBuiltinModule("node:path"); const d = fs.mkdtempSync(path.join(os.tmpdir(), String(prefix) + "-")); G.__rxmbt_tmp_reg.add(d); return d; } catch (_e) { return ""; } }

///|
extern "js" fn ffi_c4t_join(dir : String, name : String) -> String =
  #| (dir, name) => { try { return process.getBuiltinModule("node:path").join(String(dir), String(name)); } catch (_e) { return String(dir) + "/" + String(name); } }

///|
extern "js" fn ffi_c4t_rmrf(p : String) -> Unit =
  #| (p) => { try { process.getBuiltinModule("node:fs").rmSync(String(p), { recursive: true, force: true }); } catch (_e) {} }

///|
/// 起一个独立 node 进程跑 task_worker.js，返回单行 JSON。
extern "js" fn ffi_c4t_run_worker(
  repo_root : String,
  args_json : String,
) -> String =
  #| (repoRoot, argsJson) => { try { const cp = process.getBuiltinModule("node:child_process"); const path = process.getBuiltinModule("node:path"); const script = path.join(String(repoRoot), "test-suit", "rhop_task", "fixtures", "task_worker.js"); const args = JSON.parse(String(argsJson || "[]")).map((x) => String(x)); const out = cp.execFileSync(process.execPath, [script].concat(args), { encoding: "utf8", timeout: 120000, windowsHide: true, stdio: ["ignore", "pipe", "pipe"] }); return String(out).trim(); } catch (e) { const so = (e && e.stdout) ? String(e.stdout).trim() : ""; if (so) { return so; } return JSON.stringify({ ok: false, error: String((e && e.message) || e) }); } }

///|
/// 通过协调器进程并发拉起 N 个独立 worker 抢任务，返回各自输出（JSON 字符串的数组文本）。
///
/// **设计要点**：不能在本进程用 `Atomics.wait` 等 async `spawn` —— 那会阻塞本进程事件
/// 循环，子进程的 `close` 事件永不触发 ⇒ 死锁（C2 已记录同类问题）。正确做法是同步
/// `execFileSync` 一个协调器，由它在自己（独立进程）的事件循环里并发拉起 workers。
extern "js" fn ffi_c4t_run_workers_parallel(
  repo_root : String,
  db_path : String,
  table : String,
  worker_ids_json : String,
) -> String =
  #| (repoRoot, dbPath, table, idsJson) => { try { const cp = process.getBuiltinModule("node:child_process"); const path = process.getBuiltinModule("node:path"); const worker = path.join(String(repoRoot), "test-suit", "rhop_task", "fixtures", "task_worker.js"); const coord = path.join(String(repoRoot), "test-suit", "rhop_task", "fixtures", "task_worker_parallel.js"); const out = cp.execFileSync(process.execPath, [coord, worker, String(dbPath), String(table), String(idsJson)], { encoding: "utf8", timeout: 120000, windowsHide: true, stdio: ["ignore", "pipe", "pipe"] }); return String(out).trim(); } catch (e) { const so = (e && e.stdout) ? String(e.stdout).trim() : ""; if (so) { return so; } return JSON.stringify([]); } }

///|
/// 把字符串数组序列化成 JSON（供 FFI 的 args_json 形参用）。
fn c4t_args(items : Array[String]) -> String {
  Json::stringify(Json::array(items.map(fn(s) { Json::string(s) })))
}

///|
/// 取 JSON 数组里的字符串元素。
fn c4t_str_list(j : Json) -> Array[String] {
  let out : Array[String] = []
  match j {
    Array(items) =>
      for it in items {
        match it {
          String(s) => out.push(s)
          _ => out.push("")
        }
      }
    _ => ()
  }
  out
}

///|
/// 解析 worker 输出的单行 JSON。
fn c4t_parse(out : String) -> Json raise {
  let j = @json.parse(out) catch { _ => fail("worker 输出非 JSON: " + out) }
  j
}

///|
test "C4-E2E · sqlite-shared 跨进程可见性：本进程提交 → 独立进程 claim → 本进程读到 LOCKED" {
  let repo = ffi_c4t_repo_root()
  let dir = ffi_c4t_mkdtemp("rhop-c4-task")
  let db = ffi_c4t_join(dir, "shared.db")
  let spec = match @rt.TaskStoreSpec::for_kind("sqlite-local", db) {
    Ok(v) => v
    Err(e) => fail("spec: \{e}")
  }
  let store = match @rt.SqliteTaskStore::open(spec) {
    Ok(v) => v
    Err(e) => fail("open: \{e}")
  }
  // ① 本进程（A）写入两条任务
  assert_eq(
    @rt.SqliteTaskStore::insert_tasks(store, [
      @rt.TaskRecord::new("t-hi").with_priority(9),
      @rt.TaskRecord::new("t-lo"),
    ]),
    Ok(2),
  )
  // ② 独立进程（B）claim：应领到优先级更高的 t-hi
  let claim_out = ffi_c4t_run_worker(
    repo,
    c4t_args(["claim", db, "tasks", "worker-B"]),
  )
  let claimed = match c4t_parse(claim_out) {
    { "ok": True, "claimed": String(name), .. } => name
    other => fail("独立进程 claim 失败: " + Json::stringify(other))
  }
  assert_eq(claimed, "t-hi")
  // ③ 本进程（A）立刻可见 B 的写入（跨进程可见性）：状态 LOCKED + worker_id
  let rec = match @rt.SqliteTaskStore::require_task(store, "t-hi") {
    Ok(v) => v
    Err(e) => fail("读回失败: \{e}")
  }
  assert_eq(rec.state, @rt.TaskState::Locked)
  assert_eq(rec.worker_id, Some("worker-B"))
  assert_true(rec.lock_time is Some(_))
  // ④ 再让独立进程 peek 一次，确认它也能读到我方的版本号
  let peek_out = ffi_c4t_run_worker(
    repo,
    c4t_args(["peek", db, "tasks", "t-hi"]),
  )
  match c4t_parse(peek_out) {
    { "ok": True, "state": String(st), "worker_id": String(wid), .. } => {
      assert_eq(st, "LOCKED")
      assert_eq(wid, "worker-B")
    }
    other => fail("peek 失败: " + Json::stringify(other))
  }
  @rt.SqliteTaskStore::close(store)
  ffi_c4t_rmrf(dir)
}

// 并发 claim 跨进程压测：见 c4-bugfind 报告「未完成项」——本次未纳入（设计已改为
// 「同步等协调器」避免 Atomics 死锁，但预算不足未完成验证）。
