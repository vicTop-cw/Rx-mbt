// ============================================================================
// gen_kat.js —— R1 KAT fixture 生成器（js 轨真值）
//
// 与 rhop/rhop_js.mbt 的 ffi_aes_encrypt 逐字同参（node:crypto）：
//   key = PBKDF2-HMAC-SHA256(password, salt="rx-mbt-rhop-salt-v1", 100000, 32)
//   GCM = AES-256-GCM，IV 12B，tag 16B，无 AAD
//   token = base64(iv) : base64(tag) : base64(ct)   （标准 base64，含 = 补位）
//
// IV 确定性：sha256("rx-mbt-gcm-kat:<name>")[:12]（可复现，KAT 专用；
// 产品路径的随机 IV 由 native 侧 @env.rand 生成，见 gcm_native_test.mbt）
//
// 运行：node test-suit/rhop_native_gcm/gen_kat.js
// 产物：test-suit/rhop_native_gcm/fixtures/gcm_kat.json
// ============================================================================
"use strict";
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const PASSWORD = "rx-mbt-gcm-native-cross-test";
const SALT = Buffer.from("rx-mbt-rhop-salt-v1", "utf8");
const key = crypto.pbkdf2Sync(PASSWORD, SALT, 100000, 32, "sha256");

function encrypt(plain, iv) {
  const c = crypto.createCipheriv("aes-256-gcm", key, iv);
  const enc = Buffer.concat([c.update(plain, "utf8"), c.final()]);
  const tag = c.getAuthTag();
  return (
    iv.toString("base64") +
    ":" +
    tag.toString("base64") +
    ":" +
    enc.toString("base64")
  );
}

function detIv(name) {
  return crypto
    .createHash("sha256")
    .update("rx-mbt-gcm-kat:" + name)
    .digest()
    .subarray(0, 12);
}

const cases = [
  { name: "ascii", plain: "hello rhop native gcm cross-check" },
  { name: "utf8", plain: "世界-UTF8-测试-moonbit-Ω-🌙" },
  { name: "empty", plain: "" },
  {
    name: "long",
    plain: "x".repeat(1000) + "tail-边界-16字节对齐测试",
  },
];

const doc = {
  spec:
    "token=base64(iv):base64(tag):base64(ct); PBKDF2-HMAC-SHA256(pw, salt='rx-mbt-rhop-salt-v1', 100000, 32); AES-256-GCM iv=12B tag=16B no-AAD; IV=sha256('rx-mbt-gcm-kat:<name>')[:12] 确定性",
  generated_by: "gen_kat.js (node:" + process.version + ", node:crypto 真实现)",
  password: PASSWORD,
  key32_hex: key.toString("hex"),
  cases: cases.map((c) => ({
    name: c.name,
    plain: c.plain,
    token: encrypt(c.plain, detIv(c.name)),
  })),
};

const out = path.join(__dirname, "fixtures", "gcm_kat.json");
fs.mkdirSync(path.dirname(out), { recursive: true });
fs.writeFileSync(out, JSON.stringify(doc, null, 2) + "\n", "utf8");
console.log("written: " + out);
console.log("key32_hex: " + key.toString("hex"));
for (const c of doc.cases) {
  console.log(c.name + ": " + c.token.slice(0, 60) + "...");
}
