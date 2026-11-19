// ============================================================================
// rhop · native AES-256-GCM 密码臂（纯 MoonBit，无 OpenSSL）
//
// R1（PLAN-2026-11-18-gap-audit.md）：为 native 目标提供可用的 `RhopCipher`
// 实现，与 js 轨 `Aes256GcmCipher`（rhop/rhop_js.mbt，node:crypto）逐字节
// 互操作（同 PBKDF2 参数、同 token 格式）。
//
//   KDF  : PBKDF2-HMAC-SHA256(password, salt="rx-mbt-rhop-salt-v1",
//          iterations=100000, dk_len=32) —— 复用 digest.mbt 的纯 MoonBit 实现
//   GCM  : AES-256，IV 12B（@env.rand 平台熵，None 时退 ChaCha8 固定种子），
//          tag 16B，无 AAD（与 js 轨一致）
//   token: base64(iv) : base64(tag) : base64(ct)   （标准 base64，含 = 补位）
//   失败语义：decrypt 任何失败 → None（与 js 轨一致）
//
// 强验证锚点（见 test-suit/rhop_native_gcm/gcm_native_test.mbt）：
//   - S-box 由 test-suit/rhop_native_gcm/gen_sbox.py 权威生成（三重交叉验证：
//     两种独立求逆实现互验 + 与 FIPS-197 官方表 256/256 一致 + 逆表双射）
//   - FIPS-197 附录 C.3 AES-256 单块向量
//   - NIST SP 800-38D GCM 向量（数值经 node:crypto v25.2.1 独立复验）
//   - js 轨 KAT fixture（gen_kat.js，node:crypto 真值）互解密
//
// Bug 历史（2026-11-18）：首版 S-box 生成器的仿射变换第一项错用输入 i 而非
// 逆元 b（i=0/1 恰好 i==b 未暴露，i=2 出错）。gen_sbox.py 已修正并固化验证。
// ============================================================================

///|
/// AES S-box（FIPS-197）。由 `test-suit/rhop_native_gcm/gen_sbox.py` 重生成；
/// 再跑该脚本必须保持三重验证全绿，否则不得改本表。
let sbox_table : Array[Byte] = [
  0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
  0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
  0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
  0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
  0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
  0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
  0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
  0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
  0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
  0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
  0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
  0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
  0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
  0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
  0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
  0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
]

///|
/// AES 密钥扩展轮常量（Rcon，下标 = 轮常量序号 0..14；AES-256 用到 1..14）。
let rcon_table : Array[Byte] = [
  0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36, 0x6c, 0xd8, 0xab, 0x4d,
]

// ---------------------------------------------------------------------------
// 字节级助手（一律在 Int32 0..255 域运算，同 digest.mbt 口径）
// ---------------------------------------------------------------------------

fn byte_of(b : Byte) -> Int {
  b.to_int()
}

fn sbox_val(v : Int) -> Int {
  byte_of(sbox_table[v])
}

///|
/// GF(2^8) 乘 x（xtime）：高位置 1 则 (2a mod 256) ^ 0x1b。
/// 注意：必须先把 2a 掩回 8 位再异或——否则结果带 bit8（256..511），
/// 下游 sbox_table 索引越界读堆（2026-11-18 定位的崩溃根因）。
fn xtime(a : Int) -> Int {
  if a >= 0x80 {
    ((a << 1) & 0xFF) ^ 0x1B
  } else {
    a << 1
  }
}

fn rcon(idx : Int) -> Int {
  byte_of(rcon_table[idx])
}

// ---------------------------------------------------------------------------
// AES-256 核心（仅加密方向 —— GCM 双向都是 CTR 流，无需解密方向）
// 状态列主序：s[4c + r] = 输入第 4c + r 字节
// ---------------------------------------------------------------------------

///|
/// AES-256 密钥扩展：32B key → 240B 轮密钥（15 轮 × 4 字 × 4 字节）。
pub fn aes256_key_expand(key : Bytes) -> Array[Int] {
  let w : Array[Int] = Array::make(240, 0)
  for i in 0..<32 {
    w[i] = byte_of(key[i])
  }
  let mut i = 32
  while i < 240 {
    let p0 = w[i - 4]
    let p1 = w[i - 3]
    let p2 = w[i - 2]
    let p3 = w[i - 1]
    if i % 32 == 0 {
      // w[i] = w[i-8词] ^ SubWord(RotWord(w[i-1])) ^ Rcon[i/8]
      w[i] = w[i - 32] ^ (sbox_val(p1) ^ rcon(i / 32))
      w[i + 1] = w[i - 31] ^ sbox_val(p2)
      w[i + 2] = w[i - 30] ^ sbox_val(p3)
      w[i + 3] = w[i - 29] ^ sbox_val(p0)
    } else if i % 16 == 0 {
      // AES-256 特有分支：w[i/4 % 8 == 4]
      w[i] = w[i - 32] ^ sbox_val(p0)
      w[i + 1] = w[i - 31] ^ sbox_val(p1)
      w[i + 2] = w[i - 30] ^ sbox_val(p2)
      w[i + 3] = w[i - 29] ^ sbox_val(p3)
    } else {
      w[i] = w[i - 32] ^ p0
      w[i + 1] = w[i - 31] ^ p1
      w[i + 2] = w[i - 30] ^ p2
      w[i + 3] = w[i - 29] ^ p3
    }
    i = i + 4
  }
  w
}

fn add_round_key(s : Array[Int], w : Array[Int], round : Int) -> Unit {
  for c in 0..<4 {
    for r2 in 0..<4 {
      s[4 * c + r2] = s[4 * c + r2] ^ w[16 * round + 4 * c + r2]
    }
  }
}

fn sub_bytes(s : Array[Int]) -> Unit {
  for i in 0..<16 {
    s[i] = sbox_val(s[i])
  }
}

fn shift_rows(s : Array[Int]) -> Unit {
  // 行 r 左旋 r：new s[4c+r] = old s[4((c+r)%4)+r]
  let a = s[1]
  let b = s[5]
  let c = s[9]
  let d = s[13]
  let e = s[2]
  let f = s[6]
  let g = s[10]
  let h = s[14]
  let i = s[3]
  let j = s[7]
  let k = s[11]
  let l = s[15]
  s[1] = b
  s[5] = c
  s[9] = d
  s[13] = a
  s[2] = g
  s[6] = h
  s[10] = e
  s[14] = f
  s[3] = l
  s[7] = i
  s[11] = j
  s[15] = k
}

fn mix_columns(s : Array[Int]) -> Unit {
  for c in 0..<4 {
    let a0 = s[4 * c]
    let a1 = s[4 * c + 1]
    let a2 = s[4 * c + 2]
    let a3 = s[4 * c + 3]
    let x0 = xtime(a0)
    let x1 = xtime(a1)
    let x2 = xtime(a2)
    let x3 = xtime(a3)
    s[4 * c] = x0 ^ (x1 ^ a1) ^ a2 ^ a3
    s[4 * c + 1] = a0 ^ x1 ^ (x2 ^ a2) ^ a3
    s[4 * c + 2] = a0 ^ a1 ^ x2 ^ (x3 ^ a3)
    s[4 * c + 3] = (x0 ^ a0) ^ a1 ^ a2 ^ x3
  }
}

pub fn aes256_block_enc(w : Array[Int], in16 : Bytes) -> Array[Int] {
  let s : Array[Int] = []
  for i in 0..<16 {
    s.push(byte_of(in16[i]))
  }
  add_round_key(s, w, 0)
  for r in 1..<14 {
    sub_bytes(s)
    shift_rows(s)
    mix_columns(s)
    add_round_key(s, w, r)
  }
  sub_bytes(s)
  shift_rows(s)
  add_round_key(s, w, 14)
  s
}

///|
/// AES-256 单块加密（16B 输入 → 16B 输出）。
/// 强验证入口：FIPS-197 附录 C.3 向量（见 gcm_native_test.mbt）。
pub fn aes256_encrypt_block(key32 : Bytes, block16 : Bytes) -> Bytes {
  let w = aes256_key_expand(key32)
  let out = aes256_block_enc(w, block16)
  let fa : FixedArray[Byte] = FixedArray::make(16, b'\x00')
  for i in 0..<16 {
    fa[i] = out[i].to_byte()
  }
  Bytes::from_array(fa)
}

// ---------------------------------------------------------------------------
// GCM（NIST SP 800-38D）：CTR(AES-256) + GHASH
// 128 位组 = 8×Int32（idx0 为最高字节，大端位序）
// ---------------------------------------------------------------------------

pub fn zero16() -> Array[Int] {
  [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
}

pub fn arr16_to_bytes(a : Array[Int]) -> Bytes {
  let fa : FixedArray[Byte] = FixedArray::make(16, b'\x00')
  for i in 0..<16 {
    fa[i] = a[i].to_byte()
  }
  Bytes::from_array(fa)
}

///|
/// J0 = IV || 0x00000001（IV 恰 12B 的标准 GCM 情形）。
pub fn make_j0(iv12 : Bytes) -> Array[Int] {
  let j0 : Array[Int] = []
  for i in 0..<12 {
    j0.push(byte_of(iv12[i]))
  }
  j0.push(0)
  j0.push(0)
  j0.push(0)
  j0.push(1)
  j0
}

///|
/// inc32：计数器块末 32 位加 1（mod 2^32，字节序大端）。
pub fn gcm_inc32(block : Array[Int]) -> Array[Int] {
  let out : Array[Int] = []
  for i in 0..<16 {
    out.push(block[i])
  }
  let mut i = 15
  while i >= 12 {
    let nb = out[i] + 1
    if nb <= 255 {
      out[i] = nb
      break
    }
    out[i] = 0
    i = i - 1
  }
  out
}

///|
/// GHASH 域乘（GF(2^128)，NIST SP 800-38D 字节序约定）。
/// 组元素 = 16 字节，idx0 为最高字节。算法（2026-11-19 以 node:crypto 真值
/// 裁定为唯一与 node 对得上的约定，裁定脚本 temp/r1_adjudicate.py，15/15
/// 全绿：两套 setup 的单乘/双块链/33B/100B 长链 + NIST TC4 含 AAD 向量）：
/// y 的位自 MSB 起遍历（NIST X_0 = byte0 的 MSB，故第一轮异或进整个 X），
/// V ← V·x 为 128 位右移（byte j-1 的 bit0 进入 byte j 的 bit7），byte15 的
/// LSB 挤出的位为 1 时向 byte0 异或 0xE1（0xE1 是 0x87 约简常数的位反转，
/// 二者是同一域、不同字节序视角）。
/// 注意：本约定下乘法单位元是 [0x80, 0×15]（不是 [0×15, 0x01]）。
/// 历史根因（2026-11-18→19）："左移+0x87+y 从 byte15 bit0 起遍历"的旧式
/// 代数自洽（恒等/零元/交换律全过），但它是 NIST 字节序的位反转乘积，
/// tag 与 node:crypto 不符——代数自洽不等于字节序对齐，必须用真值对拍裁定。
// 2026-11-19：核心乘法重写为 (hi, lo) 双 64 位标量形态。旧版「16 字节数组
// in-place + v[15-j]/v[14-j] 反向索引移位」在 native 代码生成下产生值相关的
// 1-2 bit 损坏（GF(2^128) 逆解实锤：乘积有效 x 操作数个别字节低位被翻转，
// 如 ascii 用例最终步 byte13 bit0、utf8 链第 3 步 byte2 bit0；同代码对 NIST
// 16B 向量却正确——纯值相关，输入校验无法规避）。标量形态无数组、无反向
// 索引、无 in-place 改，只剩移位/异或。
fn g128_mul_hilo(xh : UInt64, xl : UInt64, yh : UInt64, yl : UInt64) -> (UInt64, UInt64) {
  let mut zh : UInt64 = 0UL
  let mut zl : UInt64 = 0UL
  let mut vh : UInt64 = xh
  let mut vl : UInt64 = xl
  for i in 0..<128 {
    // y 位自 MSB 起（前 64 位取 yh，后 64 位取 yl）
    let ybit = if i < 64 {
      ((yh >> (63 - i)) & 1UL).to_int()
    } else {
      ((yl >> (127 - i)) & 1UL).to_int()
    }
    if ybit == 1 {
      zh = zh ^ vh
      zl = zl ^ vl
    }
    // V ← V·ρ：128 位右移（hi 的 bit0 流入 lo 的 bit63），挤出 vl 的 bit0
    let ovf = (vl & 1UL).to_int()
    vl = (vl >> 1) | ((vh & 1UL) << 63)
    vh = vh >> 1
    if ovf == 1 {
      vh = vh ^ (0xE1UL << 56)
    }
  }
  (zh, zl)
}

///|
/// GF(2^128) 乘法（接口不变：16 字节 big-endian 数组进出）。
/// 2026-11-19：半字从 Int（32 位）改为 UInt64——Int 截断 + 移位计数 mod 32
/// 回绕，导致乘积呈 4 字节组重复模式（probe 实锤 S1 两半相同）。
pub fn g128_mul(x : Array[Int], y : Array[Int]) -> Array[Int] {
  let xh = bytes8_u64(x, 0)
  let xl = bytes8_u64(x, 8)
  let yh = bytes8_u64(y, 0)
  let yl = bytes8_u64(y, 8)
  let (zh, zl) = g128_mul_hilo(xh, xl, yh, yl)
  let out : Array[Int] = []
  for i in 0..<8 {
    out.push(((zh >> (8 * (7 - i))) & 0xFFUL).to_int())
  }
  for i in 0..<8 {
    out.push(((zl >> (8 * (7 - i))) & 0xFFUL).to_int())
  }
  out
}

///|
fn bytes8_u64(a : Array[Int], off : Int) -> UInt64 {
  let mut v : UInt64 = 0UL
  for i in 0..<8 {
    v = (v << 8) | a[off + i].to_uint64()
  }
  v
}

///|
/// GHASH：X_0 = 0，X_i = (X_{i-1} ⊕ block_i) · H（尾部不足 16B 补零）。
pub fn ghash(h : Array[Int], data : Bytes) -> Array[Int] {
  let mut x : Array[Int] = []
  for i in 0..<16 {
    x.push(0)
  }
  let n = data.length()
  let blocks = (n + 15) / 16
  for bi in 0..<blocks {
    for j in 0..<16 {
      let idx = bi * 16 + j
      if idx < n {
        x[j] = x[j] ^ byte_of(data[idx])
      }
    }
    x = g128_mul(x, h)
  }
  x
}

///|
/// 常量时间比较（tag 比较不提前退出，避免泄露前缀匹配长度）。
fn bytes_const_eq(a : Bytes, b : Bytes) -> Bool {
  if a.length() != b.length() {
    false
  } else {
    let mut diff = 0
    for i in 0..<a.length() {
      diff = diff | (byte_of(a[i]) ^ byte_of(b[i]))
    }
    diff == 0
  }
}

///|
/// GCM-CTR：data（seal 传明文 / open 传密文）与密钥流异或，双向同一函数。
pub fn gcm_ctr(w : Array[Int], j0 : Array[Int], data : Bytes) -> Bytes {
  let n = data.length()
  let buf : FixedArray[Byte] = FixedArray::make(n, b'\x00')
  let nblocks = if n == 0 {
    0
  } else {
    (n + 15) / 16
  }
  let mut counter = gcm_inc32(j0)
  for bi in 0..<nblocks {
    let ks = aes256_block_enc(w, arr16_to_bytes(counter))
    for j in 0..<16 {
      let idx = bi * 16 + j
      if idx < n {
        buf[idx] = (byte_of(data[idx]) ^ ks[j]).to_byte()
      }
    }
    counter = gcm_inc32(counter)
  }
  Bytes::from_array(buf)
}

///|
/// GCM tag（无 AAD，与 js 轨一致）：
/// T = GHASH_H( ct||pad ‖ 0^64(len AAD) ‖ len(ct)*8 大端 64 ) ⊕ E_K(J0)。
pub fn gcm_tag(w : Array[Int], j0 : Array[Int], ciphertext : Bytes) -> Bytes {
  let h = aes256_block_enc(w, arr16_to_bytes(zero16()))
  let e_j0 = aes256_block_enc(w, arr16_to_bytes(j0))
  // len(AAD)*8 = 0（无 AAD）；GHASH 输入 = ct||pad ‖ 0^64 ‖ len(ct)*8 大端 64。
  // 两段式（密文本体先跑 ghash，再与长度块异或乘一次，代数等价）。
  let s1 = ghash(h, ciphertext)
  // 2026-11-19 根因（GF(2^128) 反解 + 原版/展开版/标记版三观测逐位吻合）：
  // 标量 `ciphertext.length() * 8` 在本 native 代码生成下，32 位乘积被广播进
  // 64 位寄存器两半（n=16 时 0x80 → 0x0000008000000080），长度块第 4 字节
  // 多出 0x80，tag 与 node:crypto 系统性不符。改用 n 的移位链逐字节推导
  // （n*8 = n<<3；每字节末位 & 0xFF 屏蔽中间值），不再产生该标量。
  let n = ciphertext.length()
  let lenblk : Array[Int] = []
  for i in 0..<11 {
    lenblk.push(0)
  }
  // n*8 < 2^35（n 为 32 位 Int），仅字节 11..15 非零；移位量全部 < 32。
  // ⚠ 不可写 n>>53/n>>45/n>>37 这类 64 位移位——32 位 Int 移位计数 mod 32
  //   回绕（n>>37 按 n>>5 求值），n≥32 的明文 lenblk[10] 会被错置为 1。
  lenblk.push((n >> 29) & 0xFF)
  lenblk.push((n >> 21) & 0xFF)
  lenblk.push((n >> 13) & 0xFF)
  lenblk.push((n >> 5) & 0xFF)
  lenblk.push(((n & 0x1F) << 3) & 0xFF)
  let m : Array[Int] = []
  for i in 0..<16 {
    m.push(s1[i] ^ lenblk[i])
  }
  let s = g128_mul(m, h)
  let tag_arr : Array[Int] = []
  for i in 0..<16 {
    tag_arr.push(s[i] ^ e_j0[i])
  }
  arr16_to_bytes(tag_arr)
}

///|
/// AES-256-GCM 加密（无 AAD）：返回 (密文, 16B tag)。
/// 强验证入口：NIST SP 800-38D 向量（见 gcm_native_test.mbt）。
pub fn gcm_seal(key32 : Bytes, iv12 : Bytes, pt : Bytes) -> (Bytes, Bytes) {
  let w = aes256_key_expand(key32)
  let j0 = make_j0(iv12)
  let ct = gcm_ctr(w, j0, pt)
  let tag = gcm_tag(w, j0, ct)
  (ct, tag)
}

///|
/// AES-256-GCM 解密（无 AAD）：tag 校验失败 / 参数畸形 → None。
pub fn gcm_open(key32 : Bytes, iv12 : Bytes, ct : Bytes, tag : Bytes) -> Bytes? {
  if iv12.length() != 12 || tag.length() != 16 {
    return None
  }
  let w = aes256_key_expand(key32)
  let j0 = make_j0(iv12)
  let pt = gcm_ctr(w, j0, ct)
  let expect = gcm_tag(w, j0, ct)
  if !bytes_const_eq(expect, tag) {
    return None
  }
  Some(pt)
}

// ---------------------------------------------------------------------------
// IV 来源：@env.rand 平台熵优先，None 时退 ChaCha8（固定域分离种子）
// ---------------------------------------------------------------------------

///|
fn chacha8_iv() -> Bytes {
  // 固定域分离种子（sha256 → 恰好 32B）：降级路径确定可复现、不静默失败；
  // 真实环境 @env.rand（native 走 moonbit_rt_get_random）几乎必然可用。
  let seed = sha256(@utf8.encode("rx-mbt-gcm-native-chacha8-fallback"))
  let r = @random.Rand::chacha8(seed=seed)
  let a = r.int64()
  let b = r.int64()
  let fa : FixedArray[Byte] = FixedArray::make(12, b'\x00')
  for j in 0..<8 {
    fa[j] = ((a >> (8 * j)) & 0xFF).to_int().to_byte()
  }
  for j in 0..<4 {
    fa[8 + j] = ((b >> (8 * j)) & 0xFF).to_int().to_byte()
  }
  Bytes::from_array(fa)
}

///|
fn random_iv() -> Bytes {
  match @env.rand(12) {
    Some(iv) => iv
    None => chacha8_iv()
  }
}

// ---------------------------------------------------------------------------
// RhopCipherAesGcmNative —— native 目标可用的 RhopCipher 实现
// ---------------------------------------------------------------------------

///|
/// native AES-256-GCM 密码（与 js 轨 `Aes256GcmCipher` 逐字节互操作）。
///
/// 密钥由 `password` 经 PBKDF2-HMAC-SHA256(100000, 32) 派生；`derived_key32`
/// 惰性缓存（纯 MoonBit PBKDF2-100000 ≈ 1–2 s，from_filesystem 轮询循环
/// 不可每次调用重派生）。
pub struct RhopCipherAesGcmNative {
  /// 密钥原文（utf8 后作为 PBKDF2 的 password）
  password : String
  /// 惰性缓存的 32B 派生密钥
  key32 : Ref[Bytes?]
}

///|
pub fn RhopCipherAesGcmNative::new(password : String) -> Self {
  { password, key32: Ref::Ref(None) }
}

///|
pub extend RhopCipherAesGcmNative with RhopCipher::{alg_name, encrypt, decrypt}

///|
pub impl RhopCipher for RhopCipherAesGcmNative with fn alg_name(self) {
  "aes-256-gcm"
}

///|
/// 32B 派生密钥（惰性派生 + 缓存；测试 A3 用它对照 fixture key32_hex）。
pub fn RhopCipherAesGcmNative::derived_key32(self : RhopCipherAesGcmNative) -> Bytes {
  match self.key32.val {
    None => {
      let k = pbkdf2_hmac_sha256(
        @utf8.encode(self.password),
        @utf8.encode("rx-mbt-rhop-salt-v1"),
        100000,
        32,
      )
      self.key32.val = Some(k)
      k
    }
    Some(k) => k
  }
}

///|
/// base64 解码；任何失败（非法字符 / 坏补位）→ None。
fn b64_or_none(s : String) -> Bytes? {
  Some(@base64.decode(s)) catch {
    _ => None
  }
}

///|
pub impl RhopCipher for RhopCipherAesGcmNative with fn encrypt(self, plain) {
  let key = self.derived_key32()
  let iv = random_iv()
  let (ct, tag) = gcm_seal(key, iv, @utf8.encode(plain))
  @base64.encode(iv) + ":" + @base64.encode(tag) + ":" + @base64.encode(ct)
}

///|
pub impl RhopCipher for RhopCipherAesGcmNative with fn decrypt(self, token) {
  let parts = token.split(":").collect()
  if parts.length() != 3 {
    return None
  }
  match (
    b64_or_none(parts[0].to_owned()),
    b64_or_none(parts[1].to_owned()),
    b64_or_none(parts[2].to_owned()),
  ) {
    (Some(iv), Some(tag), Some(ct)) =>
      match gcm_open(self.derived_key32(), iv, ct, tag) {
        None => None
        Some(pt) => (Some(@utf8.decode(pt)) catch { _ => None })
      }
    _ => None
  }
}
