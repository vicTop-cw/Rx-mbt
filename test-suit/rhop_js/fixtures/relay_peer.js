// C4 E2E：独立进程的中转客户端（模拟 A 侧真实投递方）。
// 用法: node relay_peer.js <method-write|read> <baseUrl> <token|-> <filename> <payloadFile|payloadText>
// 输出单行 JSON：{ok, status, gotLen, gotSha256, error}
const fs = require("node:fs");
const http = require("node:http");
const crypto = require("node:crypto");

function req(method, url, token, body) {
  return new Promise((resolve) => {
    const headers = { "Content-Type": "application/octet-stream" };
    if (token && token !== "-") headers["X-RHOP-Token"] = token;
    const chunks = [];
    let settled = false;
    const done = (o) => { if (!settled) { settled = true; resolve(o); } };
    try {
      const r = http.request(url, { method, headers, timeout: 30000 }, (res) => {
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => done({ status: res.statusCode, body: Buffer.concat(chunks) }));
      });
      r.on("timeout", () => { r.destroy(); done({ status: -1, body: Buffer.alloc(0), error: "timeout" }); });
      r.on("error", (e) => done({ status: -1, body: Buffer.alloc(0), error: String((e && e.message) || e) }));
      if (body && body.length) r.write(body);
      r.end();
    } catch (e) {
      done({ status: -1, body: Buffer.alloc(0), error: String((e && e.message) || e) });
    }
  });
}

(async () => {
  const [mode, base, token, filename, arg] = process.argv.slice(2);
  try {
    if (mode === "write") {
      const payload = fs.existsSync(arg) ? fs.readFileSync(arg) : Buffer.from(String(arg), "utf8");
      const r = await req("PUT", base + "/pkg/" + encodeURIComponent(filename), token, payload);
      const sha = crypto.createHash("sha256").update(payload).digest("hex");
      console.log(JSON.stringify({ ok: r.status === 201 || r.status === 200, status: r.status, sentLen: payload.length, sentSha256: sha, error: r.error || null }));
      return;
    }
    if (mode === "read") {
      const r = await req("GET", base + "/pkg/" + encodeURIComponent(filename), token, null);
      const sha = crypto.createHash("sha256").update(r.body).digest("hex");
      console.log(JSON.stringify({ ok: r.status === 200, status: r.status, gotLen: r.body.length, gotSha256: sha, error: r.error || null }));
      return;
    }
    console.log(JSON.stringify({ ok: false, error: "unknown mode: " + mode }));
  } catch (e) {
    console.log(JSON.stringify({ ok: false, error: String((e && e.message) || e) }));
  }
})();
