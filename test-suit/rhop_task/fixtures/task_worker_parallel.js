// C4 E2E 协调器：在自己（子进程）的事件循环里并发拉起 N 个 task_worker.js，
// 收集各自 JSON 输出，打印成 JSON 数组后退出。
//
// 为什么需要它：MoonBit 侧是**同步** API，若直接在父进程用 Atomics.wait 等 async spawn，
// 会阻塞父进程事件循环 → 'close' 事件永不触发 → 死锁（C2 记录过的同一类问题）。
// 正确做法：父进程用 execFileSync 同步等「协调器」进程，协调器在**自己的**事件循环里
// 并发拉起 workers 并汇总 ── 跨进程并发成立，且无自锁。
const cp = require("node:child_process");
const path = require("node:path");

const [script] = process.argv.slice(2); // task_worker.js 绝对路径
const dbPath = process.argv[3];
const table = process.argv[4];
const workerIds = JSON.parse(process.argv[5] || "[]");

if (!script || !dbPath || !table) {
  console.log(JSON.stringify({ ok: false, error: "usage: coordinator <workerScript> <db> <table> <idsJson>" }));
  process.exit(0);
}

const results = new Array(workerIds.length).fill("");
let left = workerIds.length;
const finish = () => {
  if (left === 0) {
    console.log(JSON.stringify(results));
    process.exit(0);
  }
};
if (left === 0) { finish(); }

workerIds.forEach((id, i) => {
  let buf = "";
  const child = cp.spawn(process.execPath, [script, "claim", dbPath, table, String(id)], {
    stdio: ["ignore", "pipe", "pipe"],
    windowsHide: true,
  });
  child.stdout.on("data", (c) => { buf += String(c); });
  child.on("close", () => { results[i] = buf.trim(); left -= 1; finish(); });
  child.on("error", () => { results[i] = ""; left -= 1; finish(); });
});

// 兜底：30s 后无论如何返回已有结果，避免上游同步等待被无限拖住
setTimeout(() => {
  console.log(JSON.stringify(results));
  process.exit(0);
}, 30000).unref();
