// ============================================================================
// rhop · 消息摘要（纯 MoonBit 实现，wasm / js / native 三目标可用）
//
// 提供 vools-rhop 依赖的全部摘要/派生原语：
//   - sha256 / sha256_hex / sha256_hex_of_utf8   （envelope checksum、FileHashSigner）
//   - md5 / md5_hex / md5_hex_of_utf8            （NPUSigner）
//   - hmac_sha256                                （HMAC 原语）
//   - pbkdf2_hmac_sha256                         （Fernet 的密钥派生，RFC 8018）
// 无外部依赖、无 FFI；字节序严格按各标准（SHA-256 大端、MD5 小端）。
// ============================================================================

///|
/// SHA-256 分组大小（字节），HMAC 的块大小同为 64。
pub const SHA256_BLOCK_SIZE : Int32 = 64

///|
/// SHA-256 摘要长度（字节）。
pub const SHA256_DIGEST_SIZE : Int32 = 32

///|
/// MD5 摘要长度（字节）。
pub const MD5_DIGEST_SIZE : Int32 = 16

///|
/// 32 位循环右移（SHA-256 的 Σ 变换用）。
fn rotr32(x : UInt32, n : Int32) -> UInt32 {
  (x >> n) | (x << (32 - n))
}

///|
/// 32 位循环左移（MD5 用）。
fn rotl32(x : UInt32, n : Int32) -> UInt32 {
  (x << n) | (x >> (32 - n))
}

///|
/// 拼接两段字节。
fn bytes_concat(a : Bytes, b : Bytes) -> Bytes {
  let na = a.length()
  let nb = b.length()
  let out : FixedArray[Byte] = FixedArray::make(na + nb, b'\x00')
  for i in 0..<na {
    out[i] = a[i]
  }
  for i in 0..<nb {
    out[na + i] = b[i]
  }
  Bytes::from_array(out)
}

///|
/// 字节序列的小写十六进制表示（`a`-`f` 小写，无分隔符）。
///
/// 不依赖 `@hex` 的输出大小写口径，解码侧（Python `binascii.hexlify`）逐字符一致。
fn bytes_to_hex_lower(data : Bytes) -> String {
  let digits : Array[String] = [
    "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f",
  ]
  let out = StringBuilder(size_hint=data.length() * 2)
  for i in 0..<data.length() {
    let v = data[i].to_uint().reinterpret_as_int()
    out.write_string(digits[(v >> 4) & 0xF])
    out.write_string(digits[v & 0xF])
  }
  out.to_string()
}

///|
/// SHA-256 轮常数 K（前 64 个素数立方根小数部分的前 32 位）。
let sha256_k : Array[UInt32] = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
  0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
  0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
  0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
  0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
  0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
  0xc67178f2,
]

///|
/// SHA-256 初始哈希值 H0（前 8 个素数平方根小数部分的前 32 位）。
fn sha256_iv() -> Array[UInt32] {
  [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
    0x5be0cd19,
  ]
}

///|
/// 处理一个 64 字节分组，就地更新 8 字状态。
fn sha256_compress(h : Array[UInt32], data : Bytes, offset : Int32) -> Unit {
  let w : Array[UInt32] = Array::make(64, 0)
  for i in 0..<16 {
    let p = offset + i * 4
    w[i] = (data[p].to_uint() << 24) |
      (data[p + 1].to_uint() << 16) |
      (data[p + 2].to_uint() << 8) |
      data[p + 3].to_uint()
  }
  for i in 16..<64 {
    let x = w[i - 15]
    let y = w[i - 2]
    let s0 = rotr32(x, 7) ^ rotr32(x, 18) ^ (x >> 3)
    let s1 = rotr32(y, 17) ^ rotr32(y, 19) ^ (y >> 10)
    w[i] = w[i - 16] + s0 + w[i - 7] + s1
  }
  let mut a = h[0]
  let mut b = h[1]
  let mut c = h[2]
  let mut d = h[3]
  let mut e = h[4]
  let mut f = h[5]
  let mut g = h[6]
  let mut hh = h[7]
  for i in 0..<64 {
    let s1 = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25)
    let ch = (e & f) ^ (e.lnot() & g)
    let temp1 = hh + s1 + ch + sha256_k[i] + w[i]
    let s0 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22)
    let maj = (a & b) ^ (a & c) ^ (b & c)
    let temp2 = s0 + maj
    hh = g
    g = f
    f = e
    e = d + temp1
    d = c
    c = b
    b = a
    a = temp1 + temp2
  }
  h[0] = h[0] + a
  h[1] = h[1] + b
  h[2] = h[2] + c
  h[3] = h[3] + d
  h[4] = h[4] + e
  h[5] = h[5] + f
  h[6] = h[6] + g
  h[7] = h[7] + hh
}

///|
/// 按 SHA-256 规则填充：追加 0x80、若干 0x00、8 字节大端比特长度。
fn sha256_pad(data : Bytes) -> Bytes {
  let n = data.length()
  let mut total = n + 9
  let rem = total % 64
  if rem != 0 {
    total = total + (64 - rem)
  }
  let padded : FixedArray[Byte] = FixedArray::make(total, b'\x00')
  for i in 0..<n {
    padded[i] = data[i]
  }
  padded[n] = b'\x80'
  let bits = n.to_int64() * 8L
  for k in 0..<8 {
    let shift = 56 - 8 * k
    padded[total - 8 + k] = ((bits >> shift).to_int() & 0xFF).to_byte()
  }
  Bytes::from_array(padded)
}

///|
/// SHA-256 摘要（FIPS 180-4），输入任意长度字节，输出 32 字节。
///
/// 边界：空输入合法（得到 e3b0c442… 的标准空串摘要）；长度以 64 位比特数
/// 追加，故远超单块的长输入与标准一致。
pub fn sha256(data : Bytes) -> Bytes {
  let padded = sha256_pad(data)
  let total = padded.length()
  let h = sha256_iv()
  let mut offset = 0
  while offset < total {
    sha256_compress(h, padded, offset)
    offset = offset + 64
  }
  let out : FixedArray[Byte] = FixedArray::make(SHA256_DIGEST_SIZE, b'\x00')
  for i in 0..<8 {
    let word = h[i]
    out[i * 4] = ((word >> 24).reinterpret_as_int() & 0xFF).to_byte()
    out[i * 4 + 1] = ((word >> 16).reinterpret_as_int() & 0xFF).to_byte()
    out[i * 4 + 2] = ((word >> 8).reinterpret_as_int() & 0xFF).to_byte()
    out[i * 4 + 3] = (word.reinterpret_as_int() & 0xFF).to_byte()
  }
  Bytes::from_array(out)
}

///|
/// SHA-256 摘要的小写十六进制字符串（64 个字符）。
pub fn sha256_hex(data : Bytes) -> String {
  bytes_to_hex_lower(sha256(data))
}

///|
/// UTF-8 编码后取 SHA-256 的小写十六进制（envelope checksum / signer 的常用入口）。
pub fn sha256_hex_of_utf8(text : String) -> String {
  sha256_hex(@utf8.encode(text))
}

///|
/// MD5 轮常数 K（`floor(abs(sin(i+1)) * 2^32)`，RFC 1321 表）。
let md5_k : Array[UInt32] = [
  0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613,
  0xfd469501, 0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193,
  0xa679438e, 0x49b40821, 0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d,
  0x02441453, 0xd8a1e681, 0xe7d3fbc8, 0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
  0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a, 0xfffa3942, 0x8771f681, 0x6d9d6122,
  0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70, 0x289b7ec6, 0xeaa127fa,
  0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665, 0xf4292244,
  0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
  0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb,
  0xeb86d391,
]

///|
/// MD5 每轮左移位数 S（RFC 1321 表）。
let md5_s : Array[Int32] = [
  7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 5, 9, 14, 20, 5, 9,
  14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
  4, 11, 16, 23, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
]

///|
/// 处理一个 64 字节分组，就地更新 4 字状态（a/b/c/d 打包在 `state[0..3]`）。
fn md5_compress(state : Array[UInt32], data : Bytes, offset : Int32) -> Unit {
  // 16 个小端 32 位字 M[0..15]
  let m : Array[UInt32] = Array::make(16, 0)
  for i in 0..<16 {
    let p = offset + i * 4
    m[i] = data[p].to_uint() |
      (data[p + 1].to_uint() << 8) |
      (data[p + 2].to_uint() << 16) |
      (data[p + 3].to_uint() << 24)
  }
  let mut a = state[0]
  let mut b = state[1]
  let mut c = state[2]
  let mut d = state[3]
  for i in 0..<64 {
    let pair = if i < 16 {
      ((b & c) | (b.lnot() & d), i)
    } else if i < 32 {
      ((d & b) | (d.lnot() & c), (5 * i + 1) % 16)
    } else if i < 48 {
      (b ^ c ^ d, (3 * i + 5) % 16)
    } else {
      (c ^ (b | d.lnot()), 7 * i % 16)
    }
    let f = pair.0
    let g = pair.1
    let tmp = d
    d = c
    c = b
    let sum = f + a + md5_k[i] + m[g]
    b = b + rotl32(sum, md5_s[i])
    a = tmp
  }
  state[0] = state[0] + a
  state[1] = state[1] + b
  state[2] = state[2] + c
  state[3] = state[3] + d
}

///|
/// 按 MD5 规则填充：追加 0x80、若干 0x00、8 字节小端比特长度。
fn md5_pad(data : Bytes) -> Bytes {
  let n = data.length()
  let mut total = n + 9
  let rem = total % 64
  if rem != 0 {
    total = total + (64 - rem)
  }
  let padded : FixedArray[Byte] = FixedArray::make(total, b'\x00')
  for i in 0..<n {
    padded[i] = data[i]
  }
  padded[n] = b'\x80'
  let bits = n.to_int64() * 8L
  for k in 0..<8 {
    let shift = 8 * k
    padded[total - 8 + k] = ((bits >> shift).to_int() & 0xFF).to_byte()
  }
  Bytes::from_array(padded)
}

///|
/// MD5 摘要（RFC 1321），输入任意长度字节，输出 16 字节。
///
/// 仅用于对齐 vools `NPUSigner` 的 md5 签名格式；**不可用于安全用途**。
/// 边界：空输入合法（d41d8cd9… 的标准空串摘要）。
pub fn md5(data : Bytes) -> Bytes {
  let padded = md5_pad(data)
  let total = padded.length()
  let state : Array[UInt32] = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476]
  let mut offset = 0
  while offset < total {
    md5_compress(state, padded, offset)
    offset = offset + 64
  }
  let out : FixedArray[Byte] = FixedArray::make(MD5_DIGEST_SIZE, b'\x00')
  for i in 0..<4 {
    let word = state[i]
    out[i * 4] = (word.reinterpret_as_int() & 0xFF).to_byte()
    out[i * 4 + 1] = ((word >> 8).reinterpret_as_int() & 0xFF).to_byte()
    out[i * 4 + 2] = ((word >> 16).reinterpret_as_int() & 0xFF).to_byte()
    out[i * 4 + 3] = ((word >> 24).reinterpret_as_int() & 0xFF).to_byte()
  }
  Bytes::from_array(out)
}

///|
/// MD5 摘要的小写十六进制字符串（32 个字符）。
pub fn md5_hex(data : Bytes) -> String {
  bytes_to_hex_lower(md5(data))
}

///|
/// UTF-8 编码后取 MD5 的小写十六进制（NPUSigner 的签名正文入口）。
pub fn md5_hex_of_utf8(text : String) -> String {
  md5_hex(@utf8.encode(text))
}

///|
/// HMAC-SHA256（RFC 2104），`key` 超过 64 字节时先取 SHA-256 折叠。
///
/// 输出 32 字节。空 key、空 message 均合法。
pub fn hmac_sha256(key : Bytes, message : Bytes) -> Bytes {
  let mut k = key
  if k.length() > SHA256_BLOCK_SIZE {
    k = sha256(k)
  }
  let ipad : FixedArray[Byte] = FixedArray::make(SHA256_BLOCK_SIZE, b'\x36')
  let opad : FixedArray[Byte] = FixedArray::make(SHA256_BLOCK_SIZE, b'\x5c')
  for i in 0..<k.length() {
    ipad[i] = (ipad[i].to_uint() ^ k[i].to_uint()).to_byte()
    opad[i] = (opad[i].to_uint() ^ k[i].to_uint()).to_byte()
  }
  let inner = sha256(bytes_concat(Bytes::from_array(ipad), message))
  sha256(bytes_concat(Bytes::from_array(opad), inner))
}

///|
/// HMAC-SHA256 的小写十六进制字符串。
pub fn hmac_sha256_hex(key : Bytes, message : Bytes) -> String {
  bytes_to_hex_lower(hmac_sha256(key, message))
}

///|
/// 大端 32 位整数编码（PBKDF2 的块序号编码）。
fn int_be32(value : Int32) -> Bytes {
  let out : FixedArray[Byte] = FixedArray::make(4, b'\x00')
  out[0] = ((value >> 24) & 0xFF).to_byte()
  out[1] = ((value >> 16) & 0xFF).to_byte()
  out[2] = ((value >> 8) & 0xFF).to_byte()
  out[3] = (value & 0xFF).to_byte()
  Bytes::from_array(out)
}

// ---------------------------------------------------------------------------
// SHA-256 增量原语（PBKDF2 专用，避免每轮重新处理 ipad/opad 与重复分配）
//
// 背景（C2 资源审计）：旧 pbkdf2 每轮调用 hmac_sha256 ⇒ 每轮 ~6 次堆分配，
// 且 ipad/opad 的两个 64 字节块每轮都被重新压缩。Fernet KDF 用 200000 轮，
// 旧实现实测 js 2.4–3.4 s / wasm 2.8 s / native 3.8 s。
// 这里把「pad 块压缩成初始状态」只做一次，内层循环只做必要的 1–2 次压缩。
// ---------------------------------------------------------------------------

///|
/// 把 64 字节 pad 块压缩进 8 字状态（从标准 IV 起），供 HMAC/PBKDF2 复用。
fn sha256_pad_state(pad : Bytes) -> Array[UInt32] {
  let state = sha256_iv()
  sha256_compress(state, pad, 0)
  state
}

///|
/// 从给定 8 字状态继续吸收 `data` 并收尾（含 0x80 填充与 8 字节大端比特长度）。
///
/// `prefix_len` = 该状态此前已吸收的字节数（必须是 64 的倍数：HMAC 的 pad 块 = 64）。
/// 返回 32 字节摘要。`data` 可为任意长度（PBKDF2 内层为 32 字节、外层为 32 字节，
/// 但本函数也支持更长的 salt||block）。
fn sha256_finish_from_state(
  state : Array[UInt32],
  data : Bytes,
  prefix_len : Int32,
) -> Bytes {
  let total = data.length()
  let full = total / SHA256_BLOCK_SIZE
  for b in 0..<full {
    sha256_compress(state, data, b * SHA256_BLOCK_SIZE)
  }
  let rem = total - full * SHA256_BLOCK_SIZE
  // rem ≤ 63；rem ≥ 56 时填充需要额外一个块
  let need_two = rem >= 56
  let block : FixedArray[Byte] = FixedArray::make(
    if need_two {
      128
    } else {
      64
    },
    b'\x00',
  )
  for i in 0..<rem {
    block[i] = data[full * SHA256_BLOCK_SIZE + i]
  }
  block[rem] = b'\x80'
  // 长度 = prefix + data 的总字节数（比特）
  let bits = (prefix_len + total).to_int64() * 8L
  let base = if need_two { 120 } else { 56 }
  for k in 0..<8 {
    let shift = 56 - 8 * k
    block[base + k] = ((bits >> shift).to_int() & 0xFF).to_byte()
  }
  let head = Bytes::from_array(block)
  sha256_compress(state, head, 0)
  if need_two {
    sha256_compress(state, head, 64)
  }
  sha256_state_to_bytes(state)
}

///|
/// 8 字状态 → 32 字节大端摘要。
fn sha256_state_to_bytes(state : Array[UInt32]) -> Bytes {
  let out : FixedArray[Byte] = FixedArray::make(SHA256_DIGEST_SIZE, b'\x00')
  for i in 0..<8 {
    let word = state[i]
    out[i * 4] = ((word >> 24).to_int() & 0xFF).to_byte()
    out[i * 4 + 1] = ((word >> 16).to_int() & 0xFF).to_byte()
    out[i * 4 + 2] = ((word >> 8).to_int() & 0xFF).to_byte()
    out[i * 4 + 3] = (word.to_int() & 0xFF).to_byte()
  }
  Bytes::from_array(out)
}

///|
/// 基于「pad 已收纳状态」的 HMAC-SHA256 单次计算（PBKDF2 内层循环用）。
///
/// 语义等价于 `hmac_sha256(key, message)`，但跳过 ipad/opad 块的重复压缩与
/// `bytes_concat` 分配。`ipad_state`/`opad_state` 必须由 `sha256_pad_state` 生成。
fn sha256_hmac_from_pad_states(
  ipad_state : Array[UInt32],
  opad_state : Array[UInt32],
  message : Bytes,
) -> Bytes {
  let inner = sha256_finish_from_state(
    ipad_state.copy(),
    message,
    SHA256_BLOCK_SIZE,
  )
  sha256_finish_from_state(opad_state.copy(), inner, SHA256_BLOCK_SIZE)
}

///|
/// PBKDF2 的 pad 状态对（ipad/opad 各一次，跨全部块与全部迭代复用）。
fn pbkdf2_pad_states(password : Bytes) -> (Array[UInt32], Array[UInt32]) {
  let mut k = password
  if k.length() > SHA256_BLOCK_SIZE {
    k = sha256(k)
  }
  let ipad : FixedArray[Byte] = FixedArray::make(SHA256_BLOCK_SIZE, b'\x36')
  let opad : FixedArray[Byte] = FixedArray::make(SHA256_BLOCK_SIZE, b'\x5c')
  for i in 0..<k.length() {
    ipad[i] = (ipad[i].to_uint() ^ k[i].to_uint()).to_byte()
    opad[i] = (opad[i].to_uint() ^ k[i].to_uint()).to_byte()
  }
  (
    sha256_pad_state(Bytes::from_array(ipad)),
    sha256_pad_state(Bytes::from_array(opad)),
  )
}

///|
/// PBKDF2-HMAC-SHA256 密钥派生（RFC 8018 §5.2）。
///
/// - `iterations`：迭代次数。**边界**：`iterations < 1` 视为「无迭代」，
///   直接返回长度 0 的 `Bytes`（Python `hashlib.pbkdf2_hmac` 对 `iterations < 1`
///   抛 `ValueError`；此处以零长度返回值表达同一「无效」语义，不 panic）；
///   `iterations == 1` 是合法输入，等价于单次 HMAC（RFC 6070 向量即用例）。
/// - `dk_len`：派生长度（字节）。`dk_len <= 0` 同样返回长度 0 的 `Bytes`。
/// - 输出按 32 字节块 `T_i = U_1 ^ … ^ U_c` 拼接、末块截断，故任意正整数
///   `dk_len` 都可用（含跨越多个 T 块的长输出）。
/// - **资源**：ipad/opad 只压缩一次（C2 优化），200000 轮（Fernet KDF 参数）
///   较旧实现减少约一半压缩次数与大部分堆分配；无输入长度上限。
pub fn pbkdf2_hmac_sha256(
  password : Bytes,
  salt : Bytes,
  iterations : Int32,
  dk_len : Int32,
) -> Bytes {
  if iterations < 1 || dk_len <= 0 {
    return Bytes::make(0, b'\x00')
  }
  let out : FixedArray[Byte] = FixedArray::make(dk_len, b'\x00')
  let (ipad_state, opad_state) = pbkdf2_pad_states(password)
  let mut block_index = 1
  let mut written = 0
  while written < dk_len {
    // U_1 = HMAC(P, S || INT_BE(block_index))，其后 U_j = HMAC(P, U_{j-1})
    let mut u = sha256_hmac_from_pad_states(
      ipad_state,
      opad_state,
      bytes_concat(salt, int_be32(block_index)),
    )
    let t : FixedArray[Byte] = FixedArray::make(SHA256_DIGEST_SIZE, b'\x00')
    for i in 0..<SHA256_DIGEST_SIZE {
      t[i] = u[i]
    }
    let mut round = 1
    while round < iterations {
      u = sha256_hmac_from_pad_states(ipad_state, opad_state, u)
      for i in 0..<SHA256_DIGEST_SIZE {
        t[i] = (t[i].to_uint() ^ u[i].to_uint()).to_byte()
      }
      round = round + 1
    }
    let take = if dk_len - written < SHA256_DIGEST_SIZE {
      dk_len - written
    } else {
      SHA256_DIGEST_SIZE
    }
    for i in 0..<take {
      out[written + i] = t[i]
    }
    written = written + take
    block_index = block_index + 1
  }
  Bytes::from_array(out)
}

///|
/// PBKDF2-HMAC-SHA256 的小写十六进制字符串（测试与 fixture 对照用）。
pub fn pbkdf2_hmac_sha256_hex(
  password : Bytes,
  salt : Bytes,
  iterations : Int32,
  dk_len : Int32,
) -> String {
  bytes_to_hex_lower(pbkdf2_hmac_sha256(password, salt, iterations, dk_len))
}

///|
/// UTF-8 字符串转字节（等价 `@utf8.encode`，供上游/测试与 fixture 使用的稳定入口）。
pub fn bytes_of_utf8(text : String) -> Bytes {
  @utf8.encode(text)
}

///|
/// UTF-8 字节转字符串，非法字节以 U+FFFD 替换（等价 `@utf8.decode_lossy`）。
///
/// 这是**容错**解码，供日志/测试展示用；需要「非法 UTF-8 必须是错误」的
/// 场合请走 `Envelope::from_rhop_bytes`（返回 `Err`）。
pub fn utf8_text(bytes : Bytes) -> String {
  @utf8.decode_lossy(bytes)
}

///|
/// 单个十六进制字符（UInt16 代码元）的数值：`0-9` / `a-f` / `A-F`，非法返回 -1。
fn hex_value_of_code_unit(unit : UInt16) -> Int32 {
  let v = unit.to_int()
  if v >= 48 && v <= 57 {
    v - 48
  } else if v >= 97 && v <= 102 {
    v - 87
  } else if v >= 65 && v <= 70 {
    v - 55
  } else {
    -1
  }
}

///|
/// 解析十六进制字符串（大小写均可、无分隔符、必须偶数长度）为字节。
///
/// 用于消费跨实现 conformance 向量（Python `bytes.hex()` 的输出）。
/// 非法输入（奇数长度 / 非十六进制字符）返回 `Err`（中文原因），不静默截断。
pub fn bytes_from_hex(text : String) -> Result[Bytes, String] {
  let n = text.length()
  if n % 2 != 0 {
    return Err(
      "bytes_from_hex: 十六进制字符串长度必须为偶数（当前 \{n}）",
    )
  }
  let out : FixedArray[Byte] = FixedArray::make(n / 2, b'\x00')
  let mut i = 0
  while i < n {
    let hi = hex_value_of_code_unit(text[i])
    let lo = hex_value_of_code_unit(text[i + 1])
    if hi < 0 || lo < 0 {
      return Err(
        "bytes_from_hex: 第 \{i} 位不是合法的十六进制字符",
      )
    }
    out[i / 2] = (hi * 16 + lo).to_byte()
    i = i + 2
  }
  Ok(Bytes::from_array(out))
}
