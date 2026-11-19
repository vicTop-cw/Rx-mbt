// ============================================================================
// rhop_native_gcm · native 目标：AES-256-GCM 密码臂强验证（R1-A）
//
// 验收映射（temp/spec_t011.json）：
//   A3 → "KDF：PBKDF2 派生 key32 与 js 轨 fixture key32_hex 一致"
//   A2 → "KAT：js 轨（node:crypto）token 解密还原明文（4 例）"
//   A4 → "负例：错误密码 / 篡改 tag / 畸形 token 全部 None"
//   A5 → "往返：native encrypt→decrypt、token 三段形态、IV 随机性"
//   KAT → 标准向量：FIPS-197 C.3（AES-256 块）+ NIST SP 800-38D（GCM，
//        数值经 node:crypto v25.2.1 独立复验，2026-11-18）
//
// fixture：fixtures/gcm_kat.json（gen_kat.js 生成，node:crypto 真值）
// 运行：moon test --target native -j 1
// 注意：本版本 MoonBit 中 fail 只能在 error 类型函数（test 块）里用，
//       故 helper 一律返回 Option，由 test 体 match 后 fail。
// ============================================================================

///|
/// 与 fixture 同密码（gen_kat.js 的 PASSWORD 常量；A3 还会断言二者一致）
let kat_password : String = "rx-mbt-gcm-native-cross-test"

///|
/// 全文件共享同一密码臂实例：PBKDF2 只派生一次（≈1–2 s），避免每例重派生
let kat_cipher : @rp.RhopCipherAesGcmNative = @rp.RhopCipherAesGcmNative::new(kat_password)

// ---------------------------------------------------------------------------
// 助手（fail 不可用于非 test 函数：一律返回 Option）
// ---------------------------------------------------------------------------

///|
/// fixture 路径探测（moon test 二进制的 cwd 不固定：仓库根 / 包目录两种口径）
fn fixture_path() -> String? {
  let cands : Array[String] = [
    "fixtures/gcm_kat.json",
    "test-suit/rhop_native_gcm/fixtures/gcm_kat.json",
    "../rhop_native_gcm/fixtures/gcm_kat.json",
    "../../test-suit/rhop_native_gcm/fixtures/gcm_kat.json",
  ]
  for p in cands {
    // 必须用 rhop_fs_native.mbt 的 native 真实现 fs_exists（C FFI）；
    // mirror.mbt 的 rhop_fs_exists 是 js-only 桩，native 恒 false（2026-11-19 定位）。
    if @rp.fs_exists(p) {
      return Some(p)
    }
  }
  None
}

///|
fn load_kat() -> Json? {
  match fixture_path() {
    None => None
    Some(p) =>
      // 同理用 native 真实现 fs_read_text（mirror.mbt 版非 js 恒 Err）
      match @rp.fs_read_text(p) {
        Err(_) => None
        Ok(text) => (Some(@json.parse(text)) catch {
          _ => None
        })
      }
  }
}

///|
fn kat_cases(doc : Json) -> Array[Json]? {
  match doc {
    { "cases": Array(cases), .. } => Some(cases)
    _ => None
  }
}

let hex_digits : Array[String] = [
  "0", "1", "2", "3", "4", "5", "6", "7",
  "8", "9", "a", "b", "c", "d", "e", "f",
]

///|
fn bytes_hex(b : Bytes) -> String {
  let mut out = ""
  for i in 0..<b.length() {
    let v = b[i].to_int()
    out = out + hex_digits[v >> 4] + hex_digits[v & 0xF]
  }
  out
}

fn hex_val(c : Int) -> Int? {
  if c >= 48 && c <= 57 {
    Some(c - 48)
  } else if c >= 97 && c <= 102 {
    Some(c - 97 + 10)
  } else if c >= 65 && c <= 70 {
    Some(c - 65 + 10)
  } else {
    None
  }
}

///|
fn hex_to_bytes(h : String) -> Bytes? {
  let hb = @utf8.encode(h)
  let n = hb.length() / 2
  let fa : FixedArray[Byte] = FixedArray::make(n, b'\x00')
  for i in 0..<n {
    match (hex_val(hb[2 * i].to_int()), hex_val(hb[2 * i + 1].to_int())) {
      (Some(hi), Some(lo)) => {
        fa[i] = (hi * 16 + lo).to_byte()
      }
      _ => return None
    }
  }
  Some(Bytes::from_array(fa))
}

///|
/// 篡改 base64 串第 idx 位（翻成另一个合法字母，保证解码字节必变）
fn tamper_b64_char(s : String, idx : Int) -> String {
  let sb = @utf8.encode(s)
  let c = sb[idx].to_int()
  let nc = if c == 0x41 {
    "B"
  } else {
    "A"
  }
  (match s.get_view(start=0, end=idx) {
    None => ""
    Some(pre) => pre.to_owned()
  }) + nc + (match s.get_view(start=idx + 1) {
    None => ""
    Some(post) => post.to_owned()
  })
}

// ---------------------------------------------------------------------------
// A3：KDF 一致性（PBKDF2 1:1 实证）
// ---------------------------------------------------------------------------

///|
test "A3 KDF：PBKDF2 派生 key32 与 js 轨 fixture 一致" {
  match load_kat() {
    None => fail("fixture 不可读")
    Some(doc) => {
      let expect = match doc {
        { "key32_hex": String(h), .. } => h
        _ => fail("fixture 缺 key32_hex")
      }
      let pw = match doc {
        { "password": String(p), .. } => p
        _ => fail("fixture 缺 password")
      }
      assert_eq(pw, kat_password)
      assert_eq(bytes_hex(kat_cipher.derived_key32()), expect)
    }
  }
}

// ---------------------------------------------------------------------------
// A2：js 轨 KAT 互解密（node:crypto 真值 → native 解密）
// ---------------------------------------------------------------------------

///|
test "A2 KAT：js 轨 token 解密还原明文（ascii/utf8/empty/long 4 例）" {
  match load_kat() {
    None => fail("fixture 不可读")
    Some(doc) =>
      match kat_cases(doc) {
        None => fail("fixture 缺 cases 段")
        Some(cases) => {
          let mut n = 0
          for c in cases {
            let name = match c {
              { "name": String(x), .. } => x
              _ => "?"
            }
            let plain = match c {
              { "plain": String(x), .. } => x
              _ => fail("case \{name} 缺 plain")
            }
            let token = match c {
              { "token": String(x), .. } => x
              _ => fail("case \{name} 缺 token")
            }
            match kat_cipher.decrypt(token) {
              None => fail("case \{name}: js 轨 token 解密失败（AES-256-GCM 互操作断裂）")
              Some(back) => assert_eq(back, plain)
            }
            n = n + 1
          }
          assert_true(n >= 4)
        }
      }
  }
}

// ---------------------------------------------------------------------------
// A4：负例（全部必须 None）
// ---------------------------------------------------------------------------

///|
test "A4 负例：错误密码 / 篡改 tag / 畸形 token 全部 None" {
  match load_kat() {
    None => fail("fixture 不可读")
    Some(doc) =>
      match kat_cases(doc) {
        None => fail("fixture 缺 cases 段")
        Some(cases) =>
          match cases[0] {
            { "token": String(token0), .. } => {
              let parts = token0.split(":").collect()
              assert_eq(parts.length(), 3)
              let iv0 = parts[0].to_owned()
              let tag0 = parts[1].to_owned()
              let ct0 = parts[2].to_owned()
              // 1) 错误密码（另一把派生密钥 → tag 必不匹配）
              let wrong = @rp.RhopCipherAesGcmNative::new(kat_password + "-wrong")
              assert_eq(wrong.decrypt(token0), None)
              // 2) 篡改 tag（翻一个 base64 字符 → 解码字节变 → GCM 认证必失败）
              let tampered = iv0 + ":" + tamper_b64_char(tag0, 1) + ":" + ct0
              assert_eq(kat_cipher.decrypt(tampered), None)
              // 3) 2 段 token
              assert_eq(kat_cipher.decrypt("a:b"), None)
              // 4) 4 段 token
              assert_eq(kat_cipher.decrypt("a:b:c:d"), None)
              // 5) 坏 base64
              assert_eq(kat_cipher.decrypt("!!!!:!!!!:!!!!"), None)
              // 6) 坏 IV 长度：6 字节（8 个 'A' = 6 个零字节）
              assert_eq(kat_cipher.decrypt("AAAAAAAA:" + tag0 + ":" + ct0), None)
              // 7) 坏 IV 长度：16 字节（22 个 'A' + 补位 = 16 个零字节）
              assert_eq(kat_cipher.decrypt("AAAAAAAAAAAAAAAAAAAAAA==:" + tag0 + ":" + ct0), None)
            }
            _ => fail("缺 token")
          }
      }
  }
}

// ---------------------------------------------------------------------------
// A5：native 自往返 + token 形态 + IV 随机性
// ---------------------------------------------------------------------------

///|
test "A5 往返：native encrypt→decrypt + token 三段形态（3 种明文）" {
  let mut long = ""
  for _ in 0..<1000 {
    long = long + "x"
  }
  long = long + "tail-边界-16字节对齐测试"
  let plains : Array[String] = ["", "hello 你好 gcm 往返", long]
  for p in plains {
    let t = kat_cipher.encrypt(p)
    let parts = t.split(":").collect()
    assert_eq(parts.length(), 3)
    let iv = @base64.decode(parts[0].to_owned()) catch {
      _ => fail("iv 段不是合法 base64")
    }
    let tag = @base64.decode(parts[1].to_owned()) catch {
      _ => fail("tag 段不是合法 base64")
    }
    let ct = @base64.decode(parts[2].to_owned()) catch {
      _ => fail("ct 段不是合法 base64")
    }
    assert_eq(iv.length(), 12)
    assert_eq(tag.length(), 16)
    // CTR：密文与明文等长（含空明文 0 字节）
    assert_eq(ct.length(), @utf8.encode(p).length())
    match kat_cipher.decrypt(t) {
      None => fail("自往返解密失败（明文长度 \{p.length()}）")
      Some(back) => assert_eq(back, p)
    }
  }
  // 同明文两次加密：token 必不同（随机 IV），且都能解回
  let t1 = kat_cipher.encrypt("same-plain-twice")
  let t2 = kat_cipher.encrypt("same-plain-twice")
  assert_true(t1 != t2)
  assert_eq(kat_cipher.decrypt(t2), Some("same-plain-twice"))
}

// ---------------------------------------------------------------------------
// KAT：标准向量（AES-256 块 + GCM 全套；独立于 js 轨的第二真值源）
// ---------------------------------------------------------------------------

///|
test "KAT FIPS-197 C.3：AES-256 单块加密向量" {
  match (
    hex_to_bytes("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"),
    hex_to_bytes("00112233445566778899aabbccddeeff"),
  ) {
    (Some(key), Some(pt)) => {
      let ct = @rp.aes256_encrypt_block(key, pt)
      assert_eq(bytes_hex(ct), "8ea2b7ca516745bfeafc49904b496089")
    }
    _ => fail("KAT 向量 hex 非法")
  }
}

///|
test "KAT GCM：零密钥空明文 tag（NIST SP 800-38D TC6，node:crypto 复验）" {
  let key = Bytes::make(32, b'\x00')
  let iv = Bytes::make(12, b'\x00')
  let pt = Bytes::make(0, b'\x00')
  let (ct, tag) = @rp.gcm_seal(key, iv, pt)
  assert_eq(ct.length(), 0)
  assert_eq(bytes_hex(tag), "530f8afbc74536b9a963b4f1c4cb738b")
  // 解密方向同样走通
  match @rp.gcm_open(key, iv, ct, tag) {
    None => fail("空明文解密失败")
    Some(back) => assert_eq(bytes_hex(back), bytes_hex(pt))
  }
}

///|
test "KAT GCM：16B 零明文双密钥向量 + 篡改 tag 拒绝（node:crypto v25.2.1 复验）" {
  match (
    hex_to_bytes("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"),
    hex_to_bytes("feff2d4189147c58ef0d78ee084ef79150c1ac190b18a63943b04b2c1b75bd02"),
    hex_to_bytes("cafebabefacedbaddecaf888"),
  ) {
    (Some(k1), Some(k2), Some(iv2)) => {
      let pt = Bytes::make(16, b'\x00')
      let iv1 = Bytes::make(12, b'\x00')
      // 向量 1：key = 000102..1f，IV = 0^12
      let (ct1, tag1) = @rp.gcm_seal(k1, iv1, pt)
      assert_eq(bytes_hex(ct1), "0ebcb5deb52c83bd08a8a935182c9199")
      assert_eq(bytes_hex(tag1), "3862642986c953e87b3ce99b0decdf34")
      // 向量 2：key = feff2d..63，IV = cafebabe...（24 hex = 12B）
      let (ct2, tag2) = @rp.gcm_seal(k2, iv2, pt)
      assert_eq(bytes_hex(ct2), "93cf5e77bc85157e2752bd99860426c7")
      assert_eq(bytes_hex(tag2), "f6071b64d06e18c4502eb3dc553fa890")
      // 解密方向还原
      match @rp.gcm_open(k1, iv1, ct1, tag1) {
        None => fail("向量 1 解密失败")
        Some(back) => assert_eq(bytes_hex(back), bytes_hex(pt))
      }
      match @rp.gcm_open(k2, iv2, ct2, tag2) {
        None => fail("向量 2 解密失败")
        Some(back) => assert_eq(bytes_hex(back), bytes_hex(pt))
      }
      // 篡改 tag 一位 → 必须拒绝（Bytes 不可变：FixedArray 重建）
      let bad_tag_fa : FixedArray[Byte] = FixedArray::make(16, b'\x00')
      for i in 0..<16 {
        bad_tag_fa[i] = if i == 0 {
          (tag1[i].to_int() ^ 1).to_byte()
        } else {
          tag1[i]
        }
      }
      let bad_tag = Bytes::from_array(bad_tag_fa)
      assert_eq(@rp.gcm_open(k1, iv1, ct1, bad_tag), None)
    }
    _ => fail("KAT 向量 hex 非法")
  }
}


