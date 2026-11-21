// GHASH 独立参考实现（GF(2^128)，NIST SP 800-38D）：对拍 rx-mbt @rp.ghash
// k4 输入：H=f29000b62a499fd0a9f39a6add2e7780，
// fa = ct16(0ebcb5deb52c83bd08a8a935182c9199) || len块(0^15 || 0x80)，共 2 块
function xmult(X, Y) {
  // GF(2^128) 乘法，MSB-first（x_0 为 X 最高位），R = 0xe1<<120
  const R = 0xe1000000000000000000000000000000n;
  const mask = (1n << 128n) - 1n;
  let Z = 0n;
  let V = Y & mask;
  for (let i = 0; i < 128; i++) {
    const bit = (X >> BigInt(127 - i)) & 1n;
    if (bit === 1n) Z ^= V;
    const lsb = V & 1n;
    V = (V >> 1n) & mask;
    if (lsb === 1n) V ^= R;
  }
  return Z & mask;
}
function hex2bi(h) { return BigInt('0x' + h); }
function bi2hex(b) { return b.toString(16).padStart(32, '0'); }

const H = hex2bi('f29000b62a499fd0a9f39a6add2e7780');
const ct16 = hex2bi('0ebcb5deb52c83bd08a8a935182c9199');
const lenblk = 0x80n; // 128 bits，64-bit big-endian 于块末字节

let Y = 0n;
Y = xmult(Y ^ ct16, H);      // 块1: ct
Y = xmult(Y ^ lenblk, H);    // 块2: 0^15 || 0x80
console.log('正确布局 ghash =', bi2hex(Y), '(期望 c83f1287...)');

// k4 测试实际喂入的坏布局：Int 移位 mod 32 回绕 → fa[27] 与 fa[31] 双 0x80
// 块2 字节 = [0×11, 0x80, 0, 0, 0, 0x80]
const badBlk = 0x80n * (1n << 32n) | 0x80n; // byte11 与 byte15 各 0x80
let Yb = 0n;
Yb = xmult(Yb ^ ct16, H);
Yb = xmult(Yb ^ badBlk, H);
console.log('坏布局   ghash =', bi2hex(Yb), '(native 实际 b79be1f1...)');
console.log('native实际 = b79be1f1e9263ddc95473d58d52e5f23');
