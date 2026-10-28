// C4 E2E：独立进程的 task 队列 worker（用 node:sqlite 直接操作**同一份产物库**）。
// 用途：验证 rhop_task 的 sqlite schema/claim 语义在**跨进程**下成立（而不是只有单进程自洽）。
//
// 用法:
//   node task_worker.js claim <dbPath> <table> <workerId>
//        → {"ok":true,"claimed":"<task_name>"|null,"error":null}
//   node task_worker.js peek <dbPath> <table> <taskName>
//        → {"ok":true,"state":"...","worker_id":"...","version":N}
//   node task_worker.js insert <dbPath> <table> <taskName> <priority>
//        → {"ok":true,"inserted":N}
//
// claim 的语义与产品 `SqliteTaskStore::claim_next` 一致：
//   BEGIN IMMEDIATE → 选 PENDING/RETRY_PENDING 且未请求取消的行（priority DESC, task_id ASC）
//   → 带状态守卫的 UPDATE（changes==1 才算领到）→ COMMIT
const sqlite = process.getBuiltinModule("node:sqlite");

function nowIso() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}

function main() {
  const [mode, dbPath, table, a, b] = process.argv.slice(2);
  if (!mode || !dbPath || !table) {
    console.log(JSON.stringify({ ok: false, error: "usage: task_worker.js <claim|peek|insert> <db> <table> [args]" }));
    return;
  }
  let db = null;
  try {
    db = new sqlite.DatabaseSync(dbPath);
    db.exec("PRAGMA busy_timeout = 5000");
    const now = nowIso();

    if (mode === "claim") {
      const workerId = String(a || "w");
      db.exec("BEGIN IMMEDIATE");
      const rows = db.prepare(
        "SELECT * FROM " + table + " WHERE state IN (?, ?) AND cancel_requested = 0 " +
        "AND (scheduled_at IS NULL OR scheduled_at <= ?) ORDER BY priority DESC, task_id ASC LIMIT 50"
      ).all("PENDING", "RETRY_PENDING", now);
      let claimed = null;
      for (const row of rows) {
        const upd = db.prepare(
          "UPDATE " + table + " SET state = ?, worker_id = ?, lock_time = ?, expire_time = ?, " +
          "version = version + 1, updated_at = ? " +
          "WHERE task_id = ? AND state IN (?, ?) AND cancel_requested = 0"
        ).run("LOCKED", workerId, now, now, now, row.task_id, "PENDING", "RETRY_PENDING");
        if (Number(upd.changes) === 1) { claimed = row.task_name; break; }
      }
      db.exec("COMMIT");
      console.log(JSON.stringify({ ok: true, claimed: claimed, error: null }));
      return;
    }

    if (mode === "peek") {
      const row = db.prepare("SELECT * FROM " + table + " WHERE task_name = ?").get(String(a));
      console.log(JSON.stringify(row
        ? { ok: true, state: row.state, worker_id: row.worker_id, version: Number(row.version) }
        : { ok: true, state: null, error: "not found" }));
      return;
    }

    if (mode === "insert") {
      const now2 = nowIso();
      const r = db.prepare(
        "INSERT OR IGNORE INTO " + table + " (task_name, state, priority, created_at, updated_at) VALUES (?, ?, ?, ?, ?)"
      ).run(String(a), "PENDING", Number(b || 0), now2, now2);
      console.log(JSON.stringify({ ok: true, inserted: Number(r.changes) }));
      return;
    }

    console.log(JSON.stringify({ ok: false, error: "unknown mode: " + mode }));
  } catch (e) {
    try { if (db) { db.exec("ROLLBACK"); } } catch (_e2) {}
    console.log(JSON.stringify({ ok: false, error: String((e && e.message) || e) }));
  } finally {
    try { if (db) { db.close(); } } catch (_e3) {}
  }
}

main();
