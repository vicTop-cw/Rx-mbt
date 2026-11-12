// ============================================================================
// rhop_business · C4 端到端/集成压力/安全审计回归（js）
//
// 覆盖 C4 寻虫报告（fist-mbt/reports/2026-10-28-c4-bugfind-business.md）里
// 可在 CI 复现的关键结论：
//   c4-1 跨进程 E2E（出站）：requester daemon 把信封投到共享介质 →
//        **独立 node 子进程**（对端替身）校验 checksum/字段后回写结果信封
//   c4-2 跨进程 E2E（入站）：子进程投递合法 Pending 信封 → executor daemon 执行 →
//        结果信封落回共享介质（对端可读）
//   c4-3 多进程 sqlite：子进程与父进程同时抢同一任务（claim 竞争）⇒ 恰好一方成功，
//        无丢更新、无库损坏；再验「sqlite-local + shared 间接」拓扑一次
//   c4-4 sync_folder 真实大目录（1200 文件/嵌套）：一次拉平 + 重跑幂等 + 中断后重跑
//   c4-5 安全：task_id 路径穿越（submit / 信封）、共享介质里的符号链接、
//        动作回执的口令掩码、坏信封错误文本不含 payload
//   c4-6 kill -9：子进程被强杀后库仍可读、无 *.tmp 残留、残留目录可被清扫
//
// 说明：所有子进程脚本都是**临时生成**的（写在 workspace 里），不落仓库。
// ============================================================================

// ---------------------------------------------------------------------------
// 子进程探针（测试专用 FFI）
// ---------------------------------------------------------------------------

///|
/// 同步跑一段 node 脚本（`process.execPath -e <script>`），返回 JSON
/// `{"status":<int>,"stdout":"…","stderr":"…"}`；脚本写入 `dir` 下（避免仓库残留）。
extern "js" fn c4_run_node(
  dir : String,
  name : String,
  script : String,
) -> String =
  #| (dir, name, script) => { try { const cp = process.getBuiltinModule("node:child_process"); const fs = process.getBuiltinModule("node:fs"); const pathMod = process.getBuiltinModule("node:path"); const file = pathMod.join(String(dir), String(name)); fs.writeFileSync(file, String(script), "utf8"); const r = cp.spawnSync(process.execPath, [file], { encoding: "utf8", timeout: 120000 }); return JSON.stringify({ status: (r.status === null ? -1 : r.status), stdout: String(r.stdout || ""), stderr: String(r.stderr || "") }); } catch (e) { return JSON.stringify({ status: -2, stdout: "", stderr: String((e && e.message) || e) }); } }

///|
/// 异步启动 node 脚本，返回进程 id（登记在 `globalThis.__c4_children`）。
extern "js" fn c4_spawn_node(
  dir : String,
  name : String,
  script : String,
) -> Int32 =
  #| (dir, name, script) => { try { const cp = process.getBuiltinModule("node:child_process"); const fs = process.getBuiltinModule("node:fs"); const pathMod = process.getBuiltinModule("node:path"); const G = globalThis; if (G.__c4_children === undefined) { G.__c4_children = new Map(); G.__c4_seq = 1; } const file = pathMod.join(String(dir), String(name)); fs.writeFileSync(file, String(script), "utf8"); const child = cp.spawn(process.execPath, [file], { stdio: "ignore", windowsHide: true }); const id = G.__c4_seq++; G.__c4_children.set(id, child); return id; } catch (e) { return -1; } }

///|
/// SIGKILL 一个子进程（模拟 kill -9）。
extern "js" fn c4_kill9(id : Int32) -> Unit =
  #| (id) => { const G = globalThis; if (G.__c4_children === undefined) { return; } const c = G.__c4_children.get(Number(id)); if (c !== undefined) { try { c.kill("SIGKILL"); } catch (e) {} G.__c4_children.delete(Number(id)); } }

///|
/// 取子进程退出码（未退出返回 null）。
extern "js" fn c4_exit_code(id : Int32) -> Int32 =
  #| (id) => { const G = globalThis; if (G.__c4_children === undefined) { return -2; } const c = G.__c4_children.get(Number(id)); if (c === undefined) { return -2; } if (c.exitCode === null) { return -1; } return Number(c.exitCode); }

///|
/// 子进程 peek 退出状态（非阻塞）；返回 -1 表示仍在跑。
extern "js" fn c4_peek(id : Int32) -> Int32 =
  #| (id) => { const G = globalThis; if (G.__c4_children === undefined) { return -2; } const c = G.__c4_children.get(Number(id)); if (c === undefined) { return -2; } return (c.exitCode === null) ? -1 : Number(c.exitCode); }

// ---------------------------------------------------------------------------
// 共用：JSON 取值
// ---------------------------------------------------------------------------

///|
/// 认知辅助：取对象字符串字段（缺失 → ""）。
fn c4_str(value : Json, key : String) -> String {
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
/// 取对象数字字段（缺失 → -1）。
fn c4_num(value : Json, key : String) -> Int32 {
  match value {
    Object(members) =>
      match members.get(key) {
        Some(Number(n, ..)) => n.to_int()
        _ => -1
      }
    _ => -1
  }
}

///|
/// 解析 JSON（失败 abort）。
fn c4_json(text : String) -> Json {
  @json.parse(text) catch {
    e => abort("JSON 解析失败: \{text}（\{e}）")
  }
}

// ---------------------------------------------------------------------------
// c4-1 跨进程 E2E（出站）：requester daemon → 共享介质 → 独立进程校验并回写结果
// ---------------------------------------------------------------------------

///|
/// 对端替身（独立 node 进程）：从 `<shared>/inbox/executor/` 收包，
/// **重算 checksum 校验**，写一份 Done 结果信封到 `<shared>/inbox/requester/`，
/// 并把观察到的字段打成 JSON 打到 stdout。最后把收到的包**删掉**（模拟消费即删）。
fn c4_peer_script_verify() -> String {
  "const fs=process.getBuiltinModule('node:fs');\n" +
  "const pathMod=process.getBuiltinModule('node:path');\n" +
  "const crypto=process.getBuiltinModule('node:crypto');\n" +
  "const shared=process.env.C4_SHARED;\n" +
  "const inbox=pathMod.join(shared,'inbox','executor');\n" +
  "const out=pathMod.join(shared,'inbox','requester');\n" +
  "fs.mkdirSync(out,{recursive:true});\n" +
  "const canon=(v)=>{ if(v===null) return 'null'; if(typeof v==='boolean') return v?'true':'false'; if(typeof v==='number') return Number.isInteger(v)?String(v):String(v); if(typeof v==='string') return JSON.stringify(v); if(Array.isArray(v)) return '['+v.map(canon).join(', ')+']'; const ks=Object.keys(v).sort(); return '{'+ks.map(k=>JSON.stringify(k)+': '+canon(v[k])).join(', ')+'}'; };\n" +
  "let seen=[]; let ok=0; let bad=0;\n" +
  "for(const n of fs.readdirSync(inbox)){ if(!n.endsWith('.rhop')) continue; const t=fs.readFileSync(pathMod.join(inbox,n),'utf8'); let env=null; try{ env=JSON.parse(t); }catch(e){ bad++; seen.push(n+':not-json'); fs.unlinkSync(pathMod.join(inbox,n)); continue; }\n" +
  "  const got=env.checksum; const body={}; for(const k of Object.keys(env)){ if(k!=='checksum') body[k]=env[k]; }\n" +
  "  const want='sha256:'+crypto.createHash('sha256').update(canon(body),'utf8').digest('hex');\n" +
  "  if(got!==want){ bad++; seen.push(n+':checksum-mismatch'); fs.unlinkSync(pathMod.join(inbox,n)); continue; }\n" +
  "  ok++; seen.push(env.task_id+':'+env.status+':'+env.side);\n" +
  "  const res={ v:1, task_id: env.task_id, status:'done', payload: env.payload, result:{ executed_by:'peer-child', pid: process.pid }, error:null, side:'executor', version: env.version+1, created_at: env.created_at, updated_at: new Date().toISOString().replace(/\\.\\d{3}Z$/,'Z'), hops_seen: env.hops_seen||[], signature:null };\n" +
  "  const rbody={}; for(const k of Object.keys(res)){ if(k!=='checksum') rbody[k]=res[k]; }\n" +
  "  res.checksum='sha256:'+crypto.createHash('sha256').update(canon(rbody),'utf8').digest('hex');\n" +
  "  fs.writeFileSync(pathMod.join(out, env.task_id+'.rhop'), JSON.stringify(res), 'utf8');\n" +
  "  fs.unlinkSync(pathMod.join(inbox,n));\n" +
  "}\n" +
  "console.log(JSON.stringify({ pid: process.pid, ok: ok, bad: bad, seen: seen }));\n"
}

///|
test "c4-1: 跨进程 E2E 出站 —— daemon 投递 → 独立进程校验 checksum 并回写结果" {
  let dir = biz_temp_workspace()
  let shared = @rp.rhop_join(dir, "shared")
  let req_data = @rp.rhop_join(dir, "req-data")
  ignore(@rp.rhop_fs_mkdir_p(shared))
  // 1. requester 侧 daemon（本进程）
  let daemon = match
    @rp.RelayDaemon::from_config_dir(
      biz_cfg("send", shared),
      req_data,
      poll_interval_ms=0,
    ) {
    Ok(d) => d
    Err(e) => abort("构造 daemon 失败: \{e}")
  }
  // 2. 提交一个任务（落 req-data/inbox）并跑一轮 → 信封进 <shared>/inbox/executor/
  let req = match
    @rp.Requester::from_mirror_path(
      biz_cfg("send", shared),
      @rp.rhop_join(req_data, "mirror.db"),
      req_data,
    ) {
    Ok(r) => r
    Err(e) => abort("构造 Requester 失败: \{e}")
  }
  match req.submit("c4-e2e-out", biz_action_payload("jump.probe")) {
    Ok(_) => ()
    Err(e) => abort("submit 失败: \{e}")
  }
  let one = match daemon.run_once() {
    Ok(v) => v
    Err(e) => abort("run_once 失败: \{e}")
  }
  if c4_num(one, "pushed") != 1 {
    abort("应投递 1 个信封，实际 pushed=\{c4_num(one, "pushed")}")
  }
  // 3. 独立 node 进程充当对端：校验 checksum + 回写结果
  let script = c4_peer_script_verify()
  let out = c4_run_shared_ffi(dir, "peer_verify.js", script, shared, "")
  let parsed = c4_json(out)
  if c4_num(parsed, "status") != 0 {
    abort(
      "对端子进程失败: status=\{c4_num(parsed, "status")} stderr=\{c4_str(parsed, "stderr")}",
    )
  }
  let stdout = c4_str(parsed, "stdout")
  let report = c4_json(stdout)
  if c4_num(report, "ok") != 1 {
    abort(
      "对端应校验通过 1 个信封，实际 \{c4_num(report, "ok")}（\{stdout}）",
    )
  }
  if c4_num(report, "bad") != 0 {
    abort("对端不应有校验失败，实际 \{c4_num(report, "bad")}")
  }
  // 4. 回写的结果信封必须能被本端 daemon 消费（checksum 由**另一进程**生成 ⇒ 跨实现互验）
  let two = match daemon.run_once() {
    Ok(v) => v
    Err(e) => abort("第二轮失败: \{e}")
  }
  if c4_num(two, "pulled") < 1 {
    abort(
      "应拉回 ≥1 个结果信封，实际 pulled=\{c4_num(two, "pulled")}",
    )
  }
  let local_state = match req.mirror().get_task("c4-e2e-out") {
    Some(t) => t.status.to_string()
    None => "缺失"
  }
  let result = match req.get_result("c4-e2e-out") {
    Some(v) => v
    None =>
      abort("跨进程结果未回流：req mirror 里仍是 " + local_state)
  }
  if c4_str(result, "status") != "done" {
    abort("回流状态应 done，实际 \{c4_str(result, "status")}")
  }
  // 结果里应带对端进程标识（证明是子进程产出的）
  let inner = match result {
    Object(members) =>
      match members.get("result") {
        Some(v) => v
        _ => Json::null()
      }
    _ => Json::null()
  }
  if c4_str(inner, "executed_by") != "peer-child" {
    abort("结果未来自对端子进程: \{@rp.canonical_json(result)}")
  }
  req.close()
  daemon.close()
  biz_cleanup(dir)
}

// ---------------------------------------------------------------------------
// c4-2 跨进程 E2E（入站）：子进程投递合法信封 → executor daemon 执行 → 结果落共享介质
// ---------------------------------------------------------------------------

///|
/// 对端替身（入站）：用 node 自己构造一枚**合法 Pending 信封**（canonical + checksum），
/// 投到 `<shared>/inbox/executor/`，然后把 `<shared>/inbox/requester/` 里的结果读回来校验。
fn c4_peer_script_deliver(task_id : String, action_name : String) -> String {
  "const fs=process.getBuiltinModule('node:fs');\n" +
  "const pathMod=process.getBuiltinModule('node:path');\n" +
  "const crypto=process.getBuiltinModule('node:crypto');\n" +
  "const shared=process.env.C4_SHARED;\n" +
  "const canon=(v)=>{ if(v===null) return 'null'; if(typeof v==='boolean') return v?'true':'false'; if(typeof v==='number') return Number.isInteger(v)?String(v):String(v); if(typeof v==='string') return JSON.stringify(v); if(Array.isArray(v)) return '['+v.map(canon).join(', ')+']'; const ks=Object.keys(v).sort(); return '{'+ks.map(k=>JSON.stringify(k)+': '+canon(v[k])).join(', ')+'}'; };\n" +
  "const now=new Date().toISOString().replace(/\\.\\d{3}Z$/,'Z');\n" +
  "const env={ v:1, task_id: process.env.C4_TASK, status:'pending', payload: { action: process.env.C4_ACTION }, result:null, error:null, side:'requester', version:1, created_at: now, updated_at: now, hops_seen:[], signature:null };\n" +
  "const body={}; for(const k of Object.keys(env)){ if(k!=='checksum') body[k]=env[k]; }\n" +
  "env.checksum='sha256:'+crypto.createHash('sha256').update(canon(body),'utf8').digest('hex');\n" +
  "const put=pathMod.join(shared,'inbox','executor'); fs.mkdirSync(put,{recursive:true});\n" +
  "fs.writeFileSync(pathMod.join(put, process.env.C4_TASK+'.rhop'), JSON.stringify(env), 'utf8');\n" +
  "console.log(JSON.stringify({ delivered: env.task_id, checksum: env.checksum }));\n"
}

///|
/// 校验共享介质里是否已有该任务的结果信封（独立进程读取并重算 checksum）。
fn c4_peer_script_expect_result(task_id : String) -> String {
  "const fs=process.getBuiltinModule('node:fs');\n" +
  "const pathMod=process.getBuiltinModule('node:path');\n" +
  "const crypto=process.getBuiltinModule('node:crypto');\n" +
  "const shared=process.env.C4_SHARED;\n" +
  "const canon=(v)=>{ if(v===null) return 'null'; if(typeof v==='boolean') return v?'true':'false'; if(typeof v==='number') return String(v); if(typeof v==='string') return JSON.stringify(v); if(Array.isArray(v)) return '['+v.map(canon).join(', ')+']'; const ks=Object.keys(v).sort(); return '{'+ks.map(k=>JSON.stringify(k)+': '+canon(v[k])).join(', ')+'}'; };\n" +
  "const f=pathMod.join(shared,'inbox','requester', process.env.C4_TASK+'.rhop');\n" +
  "if(!fs.existsSync(f)){ console.log(JSON.stringify({ found:false })); process.exit(0); }\n" +
  "const env=JSON.parse(fs.readFileSync(f,'utf8'));\n" +
  "const body={}; for(const k of Object.keys(env)){ if(k!=='checksum') body[k]=env[k]; }\n" +
  "const want='sha256:'+crypto.createHash('sha256').update(canon(body),'utf8').digest('hex');\n" +
  "console.log(JSON.stringify({ found:true, status: env.status, side: env.side, checksum_ok: env.checksum===want, has_result: env.result!==null && env.result!==undefined }));\n"
}

///|
test "c4-2: 跨进程 E2E 入站 —— 独立进程投递信封 → daemon 执行 → 结果落共享介质" {
  let dir = biz_temp_workspace()
  let shared = @rp.rhop_join(dir, "shared")
  let exec_data = @rp.rhop_join(dir, "exec-data")
  ignore(@rp.rhop_fs_mkdir_p(shared))
  let daemon = match
    @rp.RelayDaemon::from_config_dir(
      biz_cfg("recv", shared),
      exec_data,
      poll_interval_ms=0,
    ) {
    Ok(d) => d
    Err(e) => abort("构造 executor daemon 失败: \{e}")
  }
  // 子进程投递（用 env 传参，避免脚本拼接注入）
  let script = c4_peer_script_deliver("c4-e2e-in", "jump.probe")
  let deliver_raw = c4_run_deliver_ffi(
    dir, "peer_deliver.js", script, shared, "c4-e2e-in", "jump.probe",
  )
  let deliver = c4_json(deliver_raw)
  if c4_num(deliver, "status") != 0 {
    abort(
      "投递子进程失败: status=\{c4_num(deliver, "status")} stderr=\{c4_str(deliver, "stderr")}",
    )
  }
  let one = match daemon.run_once() {
    Ok(v) => v
    Err(e) => abort("run_once 失败: \{e}")
  }
  if c4_num(one, "pulled") != 1 {
    abort("应拉入 1 个信封，实际 pulled=\{c4_num(one, "pulled")}")
  }
  if c4_num(one, "processed") != 1 {
    abort(
      "应处理 1 个信封，实际 processed=\{c4_num(one, "processed")}",
    )
  }
  if c4_num(one, "failed") != 0 {
    abort("不应失败，实际 failed=\{c4_num(one, "failed")}")
  }
  // 本地库里应为 done
  match daemon.mirror().get_task("c4-e2e-in") {
    Some(t) =>
      if t.status != @rp.TaskStatus::Done {
        abort("本地状态应为 done，实际 \{t.status.to_string()}")
      }
    None => abort("本地库应有 c4-e2e-in")
  }
  // 另一进程读结果信封并独立校验 checksum
  let check = c4_peer_script_expect_result("c4-e2e-in")
  let expect_raw = c4_run_deliver_ffi(
    dir, "peer_expect.js", check, shared, "c4-e2e-in", "jump.probe",
  )
  let expect_parsed = c4_json(expect_raw)
  if c4_num(expect_parsed, "status") != 0 {
    abort(
      "校验子进程失败: status=\{c4_num(expect_parsed, "status")} stderr=\{c4_str(expect_parsed, "stderr")}",
    )
  }
  let report = c4_parse_stdout(c4_str(expect_parsed, "stdout"))
  if !c4_bool(report, "found") {
    abort("共享介质里没有结果信封（对端读不到）")
  }
  if !c4_bool(report, "checksum_ok") {
    abort("另一进程重算的 checksum 不匹配（跨实现不一致）")
  }
  if c4_str(report, "status") != "done" {
    abort("结果信封状态应 done，实际 \{c4_str(report, "status")}")
  }
  if !c4_bool(report, "has_result") {
    abort("结果信封应带 result")
  }
  daemon.close()
  biz_cleanup(dir)
}

// ---------------------------------------------------------------------------
// c4-3 多进程 sqlite：claim 竞争 / busy / 版本冲突（两种拓扑）
// ---------------------------------------------------------------------------

///|
/// 竞争子进程：直接对同一 sqlite 库做「读 version → 带守卫更新」的 claim 竞争，
/// 并把结果打到 stdout。用 busy_timeout=5000 + BEGIN IMMEDIATE，与库内实现同口径。
fn c4_peer_script_race(db_path : String, rounds : String) -> String {
  "const sqlite=process.getBuiltinModule('node:sqlite');\n" +
  "const db=new sqlite.DatabaseSync(process.env.C4_DB);\n" +
  "db.exec('PRAGMA busy_timeout = 5000');\n" +
  "let claimed=0, busy=0, stale=0, other=0;\n" +
  "const N=Number(process.env.C4_ROUNDS||'20');\n" +
  "for(let i=0;i<N;i++){\n" +
  "  try{\n" +
  "    db.exec('BEGIN IMMEDIATE');\n" +
  "    const row=db.prepare(\"SELECT version FROM tasks WHERE task_id='c4-race' AND status='pending'\").get();\n" +
  "    if(row===undefined){ db.exec('COMMIT'); other++; continue; }\n" +
  "    const info=db.prepare(\"UPDATE tasks SET status='claimed', version=version+1, claimed_by='peer' WHERE task_id='c4-race' AND status='pending'\").run();\n" +
  "    if(Number(info.changes)===1){ db.exec('COMMIT'); claimed++; } else { db.exec('ROLLBACK'); stale++; }\n" +
  "  }catch(e){ busy++; try{ db.exec('ROLLBACK'); }catch(_e){} }\n" +
  "}\n" +
  "const row=db.prepare(\"SELECT status, version, claimed_by FROM tasks WHERE task_id='c4-race'\").get();\n" +
  "db.close();\n" +
  "console.log(JSON.stringify({ claimed:claimed, busy:busy, stale:stale, other:other, final: row }));\n"
}

///|
test "c4-3a: 多进程 sqlite claim 竞争 —— 恰好一方成功、无丢更新" {
  let dir = biz_temp_workspace()
  let db_path = @rp.rhop_join(dir, "shared.db")
  let db = match @rp.MirrorDB::open(db_path) {
    Ok(v) => v
    Err(e) => abort("open 失败: \{e}")
  }
  match
    db.upsert_task(
      mk_env("c4-race", @rp.TaskStatus::Pending, @rp.Side::Requester, 1),
    ) {
    Ok(_) => ()
    Err(e) => abort("upsert 失败: \{e}")
  }
  // 子进程（另一个 OS 进程）并发抢同一个任务
  let script = c4_peer_script_race(db_path, "20")
  let out = c4_run_node_env_db(dir, "peer_race.js", script, db_path, "20")
  let report = match out {
    Ok(v) => v
    Err(e) => abort("竞争子进程失败: \{e}")
  }
  let peer_claimed = c4_num(report, "claimed")
  // 父进程（本进程）同时抢一次
  let mine_ok = match db.get_task("c4-race") {
    Some(t) =>
      if t.status == @rp.TaskStatus::Pending {
        match db.claim_task("c4-race", "parent") {
          Ok(_) => true
          Err(_) => false
        }
      } else {
        false
      }
    None => false
  }
  // 合计只能有一次成功 claim（先到先得）
  let total = peer_claimed + (if mine_ok { 1 } else { 0 })
  if total != 1 {
    abort(
      "claim 竞争应恰好 1 方成功，实际 peer=\{peer_claimed} parent=\{mine_ok} 合计=\{total}（对端报告: \{@rp.canonical_json(report)}）",
    )
  }
  // 库里状态必须 claimed 且 version 只 +1（无丢更新/双写）
  let db_final = match db.get_task("c4-race") {
    Some(t) => t
    None => abort("任务不应消失")
  }
  println(db_final.status.to_string() + " version=" + db_final.version.to_string())
  if db_final.status != @rp.TaskStatus::Claimed {
    abort("最终状态应 claimed，实际 \{db_final.status.to_string()}")
  }
  if db_final.version != 2 {
    abort(
      "version 应恰好 +1（=2），实际 \{db_final.version}（疑似双写/丢更新）",
    )
  }
  db.close()
  biz_cleanup(dir)
}

///|
test "c4-3b: sqlite-local + shared 间接拓扑 —— 两侧各持本地库、经共享目录同步" {
  let dir = biz_temp_workspace()
  let shared = @rp.rhop_join(dir, "shared")
  ignore(@rp.rhop_fs_mkdir_p(shared))
  let req_data = @rp.rhop_join(dir, "a-data")
  let exec_data = @rp.rhop_join(dir, "b-data")
  // A：requester daemon（本地 sqlite）
  let a = match
    @rp.RelayDaemon::from_config_dir(
      biz_cfg("send", shared),
      req_data,
      poll_interval_ms=0,
    ) {
    Ok(v) => v
    Err(e) => abort("构造 A 失败: \{e}")
  }
  // B：executor daemon（各自本地 sqlite，仅共享目录相连）
  let b = match
    @rp.RelayDaemon::from_config_dir(
      biz_cfg("recv", shared),
      exec_data,
      poll_interval_ms=0,
    ) {
    Ok(v) => v
    Err(e) => abort("构造 B 失败: \{e}")
  }
  if @rp.rhop_join(req_data, "mirror.db") ==
    @rp.rhop_join(exec_data, "mirror.db") {
    abort("两侧应各持本地库（拓扑校验）")
  }
  let req = match
    @rp.Requester::from_mirror_path(
      biz_cfg("send", shared),
      @rp.rhop_join(req_data, "mirror.db"),
      req_data,
    ) {
    Ok(v) => v
    Err(e) => abort("构造 Requester 失败: \{e}")
  }
  match req.submit("c4-topo", biz_action_payload("jump.probe")) {
    Ok(_) => ()
    Err(e) => abort("submit 失败: \{e}")
  }
  // A→shared→B→执行→shared→A
  ignore(a.run_once())
  let b1 = match b.run_once() {
    Ok(v) => v
    Err(e) => abort("B run_once 失败: \{e}")
  }
  if c4_num(b1, "processed") != 1 {
    abort("B 应处理 1 个，实际 \{c4_num(b1, "processed")}")
  }
  let a2 = match a.run_once() {
    Ok(v) => v
    Err(e) => abort("A 第二轮失败: \{e}")
  }
  if c4_num(a2, "pulled") != 1 {
    abort("A 应拉回 1 个结果，实际 \{c4_num(a2, "pulled")}")
  }
  match req.get_result("c4-topo") {
    Some(v) =>
      if c4_str(v, "status") != "done" {
        abort("A 侧结果应 done，实际 \{c4_str(v, "status")}")
      }
    None => abort("A 侧应能读到 done 结果")
  }
  // 两侧库各自独立：B 库有、A 库也有（各自本地真相）
  if (a.mirror().get_task("c4-topo") is None) ||
    (b.mirror().get_task("c4-topo") is None) {
    abort("两侧本地库都应持有该任务")
  }
  req.close()
  a.close()
  b.close()
  biz_cleanup(dir)
}

///|
/// c4-3c（C4-01 回归）：**只更新列**的外部写入方（另一个进程/直接 SQL/vools 式实现）
/// 不得让 `get_task` 读到过期快照 —— 读回必须「以列为准」。
test "c4-3c: 外部只写列 → 读回以列为准（列/envelope 撕裂自愈）" {
  let dir = biz_temp_workspace()
  let db_path = @rp.rhop_join(dir, "torn.db")
  let db = match @rp.MirrorDB::open(db_path) {
    Ok(v) => v
    Err(e) => abort("open 失败: \{e}")
  }
  match
    db.upsert_task(
      mk_env("c4-torn", @rp.TaskStatus::Pending, @rp.Side::Requester, 1),
    ) {
    Ok(_) => ()
    Err(e) => abort("upsert 失败: \{e}")
  }
  // 外部写入方：只改列（模拟另一进程 claim），**不动 envelope 列**
  match
    db.raw_run(
      "UPDATE tasks SET status = ?, version = ?, claimed_by = ? WHERE task_id = ?",
      c4_json("[\"claimed\", 2, \"external-peer\", \"c4-torn\"]"),
    ) {
    Ok(_) => ()
    Err(e) => abort("外部列更新失败: \{e}")
  }
  // 读回必须是列真相（旧实现会返回 pending v1）
  let got = match db.get_task("c4-torn") {
    Some(v) => v
    None => abort("任务不应消失")
  }
  if got.status != @rp.TaskStatus::Claimed {
    abort(
      "读回状态仍为 " +
      got.status.to_string() +
      "（应 claimed：列是真相，读路径必须覆盖 envelope 旧快照）",
    )
  }
  if got.version != 2 {
    abort("读回 version 应为 2，实际 " + got.version.to_string())
  }
  // 撕裂自愈后返回的信封必须自洽（checksum 与内容一致）
  if got.checksum != got.compute_checksum() {
    abort("撕裂重建后的信封 checksum 不自洽")
  }
  // 重复领取仍被拒（乐观锁用的是列，不受 envelope 影响）
  match db.claim_task("c4-torn", "another") {
    Ok(_) => abort("已被外部 claim 的任务不应能再次领取")
    Err(_) => ()
  }
  db.close()
  biz_cleanup(dir)
}

// ---------------------------------------------------------------------------
// c4-4 sync_folder 真实大目录（1200 文件 / 嵌套 / 重跑幂等 / 中断后重跑）
// ---------------------------------------------------------------------------

///|
test "c4-4: sync_folder 1200 文件 + 嵌套目录：一次拉平、重跑幂等、中断后重跑收敛" {
  let dir = biz_temp_workspace()
  let source = @rp.rhop_join(dir, "src")
  let target = @rp.rhop_join(dir, "dst")
  // 造 1200 个文件：根 200 + 5 个子目录各 200
  let mut made = 0
  for i in 0..<200 {
    match @rp.rhop_fs_write_text(@rp.rhop_join(source, "f-\{i}.csv"), "v\{i}") {
      Ok(_) => made = made + 1
      Err(e) => abort("造文件失败: \{e}")
    }
  }
  for d in 0..<5 {
    for i in 0..<200 {
      let rel = "d\{d}/s\{d}-\{i}.csv"
      match @rp.rhop_fs_write_text(@rp.rhop_join(source, rel), "v\{d}-\{i}") {
        Ok(_) => made = made + 1
        Err(e) => abort("造嵌套文件失败: \{e}")
      }
    }
  }
  if made != 1200 {
    abort("应造 1200 个文件，实际 \{made}")
  }
  // 1) 一次拉平（递归）
  let sf = @rp.SyncFolder::new(source, target, "*.csv").with_recursive(true)
  let one = sf.sync_once()
  let pulled1 = jstr_array(one, "pulled").length()
  if pulled1 != 1200 {
    abort(
      "首轮应拉 1200 个，实际 \{pulled1}（errors: \{jstr_array(one, "errors").join("; ")}）",
    )
  }
  if jstr_array(one, "errors").length() != 0 {
    abort("首轮不应有错误: \{jstr_array(one, "errors").join("; ")}")
  }
  // 2) 重跑幂等：0 拉、1200 跳过
  let two = sf.sync_once()
  if jstr_array(two, "pulled").length() != 0 {
    abort("重跑不应再拉，实际 \{jstr_array(two, "pulled").length()}")
  }
  if c4_num(two, "skipped") != 1200 {
    abort("重跑应跳过 1200，实际 \{c4_num(two, "skipped")}")
  }
  // 3) 中断后重跑：删掉部分目标文件（模拟上一轮只拷了一半就崩），再跑应补齐且不重复
  let mut removed = 0
  for d in 0..<5 {
    for i in 0..<40 {
      let rel = "d\{d}/s\{d}-\{i}.csv"
      match @rp.rhop_fs_remove(@rp.rhop_join(target, rel)) {
        Ok(_) => removed = removed + 1
        Err(_) => ()
      }
    }
  }
  if removed != 200 {
    abort("应删除 200 个目标文件，实际 \{removed}")
  }
  let three = sf.sync_once()
  let repulled = jstr_array(three, "pulled").length()
  if repulled != 200 {
    abort("中断后应补拉 200，实际 \{repulled}")
  }
  if c4_num(three, "skipped") != 1000 {
    abort("其余 1000 应跳过，实际 \{c4_num(three, "skipped")}")
  }
  // 4) 收敛：再跑一次 0 拉
  let four = sf.sync_once()
  if jstr_array(four, "pulled").length() != 0 {
    abort("收敛后不应再拉")
  }
  biz_cleanup(dir)
}

///|
/// c4-7：daemon **进程重启**后续跑（同一 data_dir，关掉再开）。
///
/// 场景：上一轮跑到一半被杀/重启，inbox 里还有未处理信封、outbox 里还有未投递信封。
/// 期望：新实例 run_once 能继续把 inbox 处理完、把 outbox 投出去（幂等、不丢）。
test "c4-7: daemon 重启后续跑（inbox/outbox 遗留仍被处理）" {
  let dir = biz_temp_workspace()
  let shared = @rp.rhop_join(dir, "shared")
  let data = @rp.rhop_join(dir, "data")
  ignore(@rp.rhop_fs_mkdir_p(shared))
  // 第一个实例：提交 + 跑一轮（信封从 inbox → outbox → 共享介质）
  let req1 = match
    @rp.Requester::from_mirror_path(
      biz_cfg("send", shared),
      @rp.rhop_join(data, "mirror.db"),
      data,
    ) {
    Ok(v) => v
    Err(e) => abort("构造 Requester 失败: \{e}")
  }
  match req1.submit("c4-restart-1", biz_action_payload("jump.probe")) {
    Ok(_) => ()
    Err(e) => abort("submit 失败: \{e}")
  }
  req1.close()
  let d1 = match
    @rp.RelayDaemon::from_config_dir(
      biz_cfg("send", shared),
      data,
      poll_interval_ms=0,
    ) {
    Ok(v) => v
    Err(e) => abort("构造 daemon1 失败: \{e}")
  }
  let r1 = match d1.run_once() {
    Ok(v) => v
    Err(e) => abort("run_once#1 失败: \{e}")
  }
  if c4_num(r1, "pushed") != 1 {
    abort("首轮应投递 1 个，实际 \{c4_num(r1, "pushed")}")
  }
  d1.close()
  // 模拟「重启前又被塞了一个待处理信封」：直接放进 inbox
  let req2 = match
    @rp.Requester::from_mirror_path(
      biz_cfg("send", shared),
      @rp.rhop_join(data, "mirror.db"),
      data,
    ) {
    Ok(v) => v
    Err(e) => abort("重开 Requester 失败: \{e}")
  }
  match req2.submit("c4-restart-2", biz_action_payload("jump.probe")) {
    Ok(_) => ()
    Err(e) => abort("submit#2 失败: \{e}")
  }
  req2.close()
  // 第二个实例（同一 data_dir）：应继续处理遗留信封并投递
  let d2 = match
    @rp.RelayDaemon::from_config_dir(
      biz_cfg("send", shared),
      data,
      poll_interval_ms=0,
    ) {
    Ok(v) => v
    Err(e) => abort("构造 daemon2 失败: \{e}")
  }
  let r2 = match d2.run_once() {
    Ok(v) => v
    Err(e) => abort("run_once#2 失败: \{e}")
  }
  if c4_num(r2, "processed") != 1 {
    abort("重启后应处理遗留 1 个，实际 \{c4_num(r2, "processed")}")
  }
  if c4_num(r2, "pushed") != 1 {
    abort("重启后应投递 1 个，实际 \{c4_num(r2, "pushed")}")
  }
  // 两个任务都在共享介质的对端收件箱里
  let remote = @rp.rhop_join(@rp.rhop_join(shared, "inbox"), "executor")
  let names = @rp.rhop_fs_list_dir(remote)
  if !names.contains("c4-restart-1.rhop") ||
    !names.contains("c4-restart-2.rhop") {
    abort("共享介质应有两条任务信封，实际: \{names.join(", ")}")
  }
  // 再跑一轮无残留（幂等）
  let r3 = match d2.run_once() {
    Ok(v) => v
    Err(e) => abort("run_once#3 失败: \{e}")
  }
  if c4_num(r3, "processed") != 0 || c4_num(r3, "pushed") != 0 {
    abort(
      "重启实例第二轮应全 0（幂等），实际 \{@rp.canonical_json(r3)}",
    )
  }
  d2.close()
  biz_cleanup(dir)
}

// ---------------------------------------------------------------------------
// c4-5 安全：路径穿越 / 符号链接 / 口令掩码 / 错误文本
// ---------------------------------------------------------------------------

///|
test "c4-5a: task_id 路径穿越被拒（submit 与信封两条入口）" {
  let dir = biz_temp_workspace()
  let data = @rp.rhop_join(dir, "data")
  let req = match
    @rp.Requester::from_mirror_path(
      biz_cfg("send", ""),
      @rp.rhop_join(data, "mirror.db"),
      data,
    ) {
    Ok(v) => v
    Err(e) => abort("构造 Requester 失败: \{e}")
  }
  for evil in ["../../evil", "..", ".", "a/b", "a\\\\b", "c:evil", ""] {
    match req.submit(evil, Json::null()) {
      Ok(_) => abort("恶意 task_id 应被拒绝: \{evil}")
      Err(_) => ()
    }
  }
  // 不得在期望目录之外落盘
  let escaped = @rp.rhop_join(@rp.rhop_join(dir, ".."), "evil.rhop")
  if @rp.rhop_fs_exists(escaped) {
    abort("路径穿越文件被写出: \{escaped}")
  }
  // 合法 id 仍可提交
  match req.submit("ok-id_1.2", Json::null()) {
    Ok(_) => ()
    Err(e) => abort("合法 task_id 应通过: \{e}")
  }
  req.close()
  biz_cleanup(dir)
}

///|
test "c4-5b: 恶意信封（穿越/超长 task_id）→ 进 failed/，不落任何越界路径" {
  let dir = biz_temp_workspace()
  let data = @rp.rhop_join(dir, "exec-data")
  let daemon = match
    @rp.RelayDaemon::from_config_dir(
      biz_cfg("recv", ""),
      data,
      poll_interval_ms=0,
    ) {
    Ok(d) => d
    Err(e) => abort("构造 daemon 失败: \{e}")
  }
  let inbox = @rp.rhop_join(data, "inbox")
  ignore(@rp.rhop_fs_mkdir_p(inbox))
  // 用合法 checksum 但非法 task_id 的信封（模拟对端恶意构造）
  let now = @rp.rhop_now_iso()
  let evil = @rp.Envelope::new_full(
    "../../etc/passwd",
    @rp.TaskStatus::Pending,
    Json::null(),
    @rp.Side::Requester,
    version=1,
    created_at=now,
    updated_at=now,
  )
  match
    @rp.rhop_fs_write_text(
      @rp.rhop_join(inbox, "evil.rhop"),
      @rp.utf8_text(evil.to_rhop_bytes()),
    ) {
    Ok(_) => ()
    Err(e) => abort("造恶意信封失败: \{e}")
  }
  let one = match daemon.run_once() {
    Ok(v) => v
    Err(e) => abort("run_once 失败: \{e}")
  }
  if c4_num(one, "failed") != 1 {
    abort("恶意信封应计 failed=1，实际 \{c4_num(one, "failed")}")
  }
  if !@rp.rhop_fs_exists(
      @rp.rhop_join(@rp.rhop_join(data, "failed"), "evil.rhop"),
    ) {
    abort("恶意信封应进 failed/")
  }
  // 不得越界落盘
  let escaped = @rp.rhop_join(@rp.rhop_join(data, "outbox"), "..")
  if @rp.rhop_fs_exists(@rp.rhop_join(escaped, "etc")) {
    abort("越界路径被创建")
  }
  daemon.close()
  biz_cleanup(dir)
}

///|
test "c4-5c: rhop.echo 对口令/密钥类字段做深度掩码（凭据不外泄）" {
  let cfg = c4_json(
    "{\"sftp\":{\"host\":\"h\",\"user\":\"u\",\"password\":\"SECRET-PW\",\"key_path\":\"C:/k/id\"},\"relay\":{\"token\":\"SECRET-TOKEN\"},\"list\":[{\"api_key\":\"SECRET-KEY\"}]}",
  )
  let out = @rp.run_action("rhop.echo", cfg, Some(c4_json("{\"x\":1}")))
  let text = @rp.canonical_json(out)
  for secret in ["SECRET-PW", "SECRET-TOKEN", "SECRET-KEY"] {
    if text.contains(secret) {
      abort("rhop.echo 泄漏了凭据 \{secret}: \{text}")
    }
  }
  if !text.contains("***") {
    abort("掩码占位 *** 缺失: \{text}")
  }
  // 非敏感字段仍可见（可诊断性不丢）
  if !text.contains("\"host\":\"h\"") && !text.contains("\"host\": \"h\"") {
    abort("非敏感字段 host 不应被掩掉: \{text}")
  }
}

///|
test "c4-5d: 坏信封的错误文本不含 payload 内容（日志不泄漏业务数据）" {
  let dir = biz_temp_workspace()
  let data = @rp.rhop_join(dir, "exec-data")
  let daemon = match
    @rp.RelayDaemon::from_config_dir(
      biz_cfg("recv", ""),
      data,
      poll_interval_ms=0,
    ) {
    Ok(d) => d
    Err(e) => abort("构造 daemon 失败: \{e}")
  }
  let inbox = @rp.rhop_join(data, "inbox")
  ignore(@rp.rhop_fs_mkdir_p(inbox))
  // 含敏感内容的坏信封（checksum 被篡改）
  let now = @rp.rhop_now_iso()
  let good = @rp.Envelope::new_full(
    "job-secret",
    @rp.TaskStatus::Pending,
    c4_json("{\"password\":\"PAYLOAD-SECRET\"}"),
    @rp.Side::Requester,
    version=1,
    created_at=now,
    updated_at=now,
  )
  let mut text = @rp.utf8_text(good.to_rhop_bytes())
  // 篡改一个字符让 checksum 失配
  text = text + " "
  match @rp.rhop_fs_write_text(@rp.rhop_join(inbox, "tampered.rhop"), text) {
    Ok(_) => ()
    Err(e) => abort("造坏信封失败: \{e}")
  }
  let one = match daemon.run_once() {
    Ok(v) => v
    Err(e) => abort("run_once 失败: \{e}")
  }
  let errors = jstr_array(one, "errors")
  let joined = errors.join("; ")
  if joined.contains("PAYLOAD-SECRET") {
    abort("错误文本泄漏 payload: \{joined}")
  }
  if c4_num(one, "failed") != 1 {
    abort("坏信封应计 failed=1，实际 \{c4_num(one, "failed")}")
  }
  daemon.close()
  biz_cleanup(dir)
}

// ---------------------------------------------------------------------------
// c4-6 kill -9：强杀后库可读、无 *.tmp、残留可清扫
// ---------------------------------------------------------------------------

///|
/// 子进程：建库 + 写入 + 进入长睡眠（等待被 SIGKILL），保证被杀时句柄仍打开。
fn c4_peer_script_longrun(db_path : String) -> String {
  "const sqlite=process.getBuiltinModule('node:sqlite');\n" +
  "const db=new sqlite.DatabaseSync(process.env.C4_DB);\n" +
  "db.exec('PRAGMA busy_timeout = 5000');\n" +
  "db.exec(\"CREATE TABLE IF NOT EXISTS tasks (task_id TEXT PRIMARY KEY, status TEXT NOT NULL)\");\n" +
  "db.exec(\"INSERT OR REPLACE INTO tasks VALUES ('killed-mid','running')\");\n" +
  "console.log('READY');\n" +
  "setInterval(()=>{}, 1000);\n"
}

///|
test "c4-6: kill -9 后数据库仍可读、无 *.tmp 残留、残留目录可清扫" {
  let dir = biz_temp_workspace()
  let db_path = @rp.rhop_join(dir, "killed.db")
  let script = c4_peer_script_longrun(db_path)
  let pid = c4_spawn_node_env(dir, "longrun.js", script, db_path)
  if pid < 0 {
    abort("启动子进程失败")
  }
  // 等它就绪（最多 5s）
  let mut waited = 0
  while waited < 5000 && !@rp.rhop_fs_exists(db_path) {
    @rp.rhop_sleep_ms(100)
    waited = waited + 100
  }
  if !@rp.rhop_fs_exists(db_path) {
    abort("子进程未创建库文件")
  }
  @rp.rhop_sleep_ms(200)
  // SIGKILL（模拟 kill -9：无退出钩子、无清理机会）
  c4_kill9(pid)
  @rp.rhop_sleep_ms(300)
  // ① 库仍可打开且未损坏（SQLite 回滚日志保证）
  let db = match @rp.MirrorDB::open(db_path) {
    Ok(v) => v
    Err(e) => abort("强杀后库无法打开: \{e}")
  }
  match
    db.raw_run(
      "SELECT task_id FROM tasks WHERE task_id = ?",
      c4_json("[\"killed-mid\"]"),
    ) {
    Ok(_) => ()
    Err(e) => abort("强杀后库查询失败（疑似损坏）: \{e}")
  }
  db.close()
  // ② 无 *.tmp 残留（写原子性）
  let names = @rp.rhop_fs_list_dir(dir)
  for n in names {
    if n.has_suffix(".tmp") {
      abort("强杀后残留临时文件: \{n}")
    }
  }
  // ③ 残留目录可被清扫（下次运行能收敛）
  match @rp.rhop_remove_dir_all(dir) {
    Ok(_) => ()
    Err(e) => abort("强杀后残留目录无法清扫: \{e}")
  }
  if @rp.rhop_fs_exists(dir) {
    abort("清扫后目录仍存在")
  }
}

// ---------------------------------------------------------------------------
// 本文件私有 FFI / helper（env 传参版本，避免脚本注入）
// ---------------------------------------------------------------------------

///|
/// 同步跑脚本并通过环境变量传参；成功（exit 0）时返回 stdout 解析后的 JSON。
extern "js" fn c4_run_env_ffi(
  dir : String,
  name : String,
  script : String,
  key1 : String,
  val1 : String,
  key2 : String,
  val2 : String,
) -> String =
  #| (dir, name, script, k1, v1, k2, v2) => { try { const cp = process.getBuiltinModule("node:child_process"); const fs = process.getBuiltinModule("node:fs"); const pathMod = process.getBuiltinModule("node:path"); const file = pathMod.join(String(dir), String(name)); fs.writeFileSync(file, String(script), "utf8"); const env = Object.assign({}, process.env); if (k1) { env[String(k1)] = String(v1); } if (k2) { env[String(k2)] = String(v2); } const r = cp.spawnSync(process.execPath, [file], { encoding: "utf8", timeout: 120000, env: env }); return JSON.stringify({ status: (r.status === null ? -1 : r.status), stdout: String(r.stdout || ""), stderr: String(r.stderr || "") }); } catch (e) { return JSON.stringify({ status: -2, stdout: "", stderr: String((e && e.message) || e) }); } }

///|
/// 跑一个「经 env 传 C4_TASK / C4_ACTION」的子进程，返回其 stdout 的首行 JSON。
fn c4_run_node_env(
  dir : String,
  name : String,
  script : String,
  task_id : String,
  action : String,
) -> Result[Json, String] {
  let raw = c4_run_env_ffi(
    dir, name, script, "C4_TASK", task_id, "C4_ACTION", action,
  )
  let parsed = c4_json(raw)
  let status = c4_num(parsed, "status")
  if status != 0 {
    return Err("子进程退出码 \{status}: \{c4_str(parsed, "stderr")}")
  }
  let stdout = c4_str(parsed, "stdout")
  if stdout == "" {
    return Err("子进程无输出")
  }
  Ok(c4_parse_stdout(stdout))
}

///|
/// 跑一个「经 env 传 C4_DB / C4_ROUNDS」的子进程，返回其 stdout 首行 JSON。
fn c4_run_node_env_db(
  dir : String,
  name : String,
  script : String,
  db_path : String,
  rounds : String,
) -> Result[Json, String] {
  let raw = c4_run_env_ffi(
    dir, name, script, "C4_DB", db_path, "C4_ROUNDS", rounds,
  )
  let parsed = c4_json(raw)
  let status = c4_num(parsed, "status")
  if status != 0 {
    return Err("子进程退出码 \{status}: \{c4_str(parsed, "stderr")}")
  }
  Ok(c4_parse_stdout(c4_str(parsed, "stdout")))
}

///|
/// 取子进程 stdout 的**最后一行** JSON（子进程可能先打印其它行）。
fn c4_parse_stdout(stdout : String) -> Json {
  let lines = stdout.split("\n")
  let mut last = ""
  for line in lines {
    let trimmed = line.trim().to_owned()
    if trimmed != "" && trimmed.has_prefix("{") {
      last = trimmed
    }
  }
  if last == "" {
    abort("子进程 stdout 里没有 JSON: \{stdout}")
  }
  c4_json(last)
}

///|
/// 异步启动「经 env 传 C4_DB」的长跑子进程。
extern "js" fn c4_spawn_env_ffi(
  dir : String,
  name : String,
  script : String,
  key1 : String,
  val1 : String,
) -> Int32 =
  #| (dir, name, script, k1, v1) => { try { const cp = process.getBuiltinModule("node:child_process"); const fs = process.getBuiltinModule("node:fs"); const pathMod = process.getBuiltinModule("node:path"); const G = globalThis; if (G.__c4_children === undefined) { G.__c4_children = new Map(); G.__c4_seq = 1; } const file = pathMod.join(String(dir), String(name)); fs.writeFileSync(file, String(script), "utf8"); const env = Object.assign({}, process.env); env[String(k1)] = String(v1); const child = cp.spawn(process.execPath, [file], { stdio: "ignore", windowsHide: true, env: env }); const id = G.__c4_seq++; G.__c4_children.set(id, child); return id; } catch (e) { return -1; } }

///|
/// 异步启动长跑子进程（C4_DB 传参）。
fn c4_spawn_node_env(
  dir : String,
  name : String,
  script : String,
  db_path : String,
) -> Int32 {
  c4_spawn_env_ffi(dir, name, script, "C4_DB", db_path)
}

///|
/// 取 Json 布尔字段（缺失 → false）。
fn c4_bool(value : Json, key : String) -> Bool {
  match value {
    Object(members) =>
      match members.get(key) {
        Some(True) => true
        _ => false
      }
    _ => false
  }
}

// 说明：c4-1 用 C4_SHARED 传共享目录；上面 env 版 FFI 固定两个键位，
// 这里再补一个「C4_SHARED + C4_TASK」组合的入口。

///|
/// 跑「经 env 传 C4_SHARED」的子进程（c4-1 对端替身）。
extern "js" fn c4_run_shared_ffi(
  dir : String,
  name : String,
  script : String,
  shared : String,
  task_id : String,
) -> String =
  #| (dir, name, script, shared, task) => { try { const cp = process.getBuiltinModule("node:child_process"); const fs = process.getBuiltinModule("node:fs"); const pathMod = process.getBuiltinModule("node:path"); const file = pathMod.join(String(dir), String(name)); fs.writeFileSync(file, String(script), "utf8"); const env = Object.assign({}, process.env); env.C4_SHARED = String(shared); env.C4_TASK = String(task); const r = cp.spawnSync(process.execPath, [file], { encoding: "utf8", timeout: 120000, env: env }); return JSON.stringify({ status: (r.status === null ? -1 : r.status), stdout: String(r.stdout || ""), stderr: String(r.stderr || "") }); } catch (e) { return JSON.stringify({ status: -2, stdout: "", stderr: String((e && e.message) || e) }); } }

///|
/// 诊断用：列出目录下两层内容（测试失败时打印，便于定位）。
fn c4_tree(root : String) -> Json {
  let fields : Map[String, Json] = Map([])
  for name in @rp.rhop_fs_list_dir(root) {
    fields[name] = Json::string("file")
  }
  for
    sub in [
      "inbox", "outbox", "failed", "processed", "inbox/executor", "inbox/requester",
    ] {
    let dir = @rp.rhop_join(root, sub)
    let names = @rp.rhop_fs_list_dir(dir)
    if names.length() > 0 {
      let arr : Array[Json] = []
      for n in names {
        arr.push(Json::string(n))
      }
      fields[sub] = Json::array(arr)
    }
  }
  Json::object(fields)
}

///|
/// 同步跑「投递对端替身」脚本：env 传 C4_SHARED / C4_TASK / C4_ACTION。
extern "js" fn c4_run_deliver_ffi(
  dir : String,
  name : String,
  script : String,
  shared : String,
  task_id : String,
  action : String,
) -> String =
  #| (dir, name, script, shared, task, action) => { try { const cp = process.getBuiltinModule("node:child_process"); const fs = process.getBuiltinModule("node:fs"); const pathMod = process.getBuiltinModule("node:path"); const file = pathMod.join(String(dir), String(name)); fs.writeFileSync(file, String(script), "utf8"); const env = Object.assign({}, process.env); env.C4_SHARED = String(shared); env.C4_TASK = String(task); env.C4_ACTION = String(action); const r = cp.spawnSync(process.execPath, [file], { encoding: "utf8", timeout: 120000, env: env }); return JSON.stringify({ status: (r.status === null ? -1 : r.status), stdout: String(r.stdout || ""), stderr: String(r.stderr || "") }); } catch (e) { return JSON.stringify({ status: -2, stdout: "", stderr: String((e && e.message) || e) }); } }
