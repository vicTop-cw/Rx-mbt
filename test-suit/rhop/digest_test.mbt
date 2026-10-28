// ============================================================================
// rhop · digest 单元测试（跨目标）
//
// 向量来源：FIPS 180-4 / RFC 1321 / RFC 4231 / RFC 6070+7914（Python 3.13
// hashlib+hmac 复核）。覆盖空输入、单块、跨块长输入、中文 UTF-8、以及
// iterations/dk_len 边界。
// ============================================================================

///|
test "digest: SHA-256 标准向量（空串 / abc / FIPS 多块）" {
  assert_eq(
    @rp.sha256_hex_of_utf8(""),
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  )
  assert_eq(
    @rp.sha256_hex_of_utf8("abc"),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  )
  // 448-bit（56 字节）向量
  assert_eq(
    @rp.sha256_hex_of_utf8(
      "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
    ),
    "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
  )
  // 896-bit（112 字节）向量
  assert_eq(
    @rp.sha256_hex_of_utf8(
      "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
    ),
    "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1",
  )
}

///|
test "digest: SHA-256 长输入与中文 UTF-8" {
  // 1000 个 'a'（跨 15 个分组）
  assert_eq(
    @rp.sha256_hex_of_utf8("a".repeat(1000)),
    "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3",
  )
  // 中文：UTF-8 多字节输入
  assert_eq(
    @rp.sha256_hex_of_utf8("\u{4e2d}\u{6587}rhop\u{6d4b}\u{8bd5}"),
    "41e343689740fb6b6a13a843fea2a2a635b6248be8049b7bfcbff37c5d617f3d",
  )
}

///|
test "digest: SHA-256 输出是 32 字节且 hex 为 64 小写字符" {
  let digest = @rp.sha256(@rp.bytes_of_utf8("abc"))
  assert_eq(digest.length(), 32)
  let hex = @rp.sha256_hex(digest)
  assert_eq(hex.length(), 64)
  // 只含 0-9a-f（无大写）
  assert_eq(hex, hex.to_lower())
}

///|
test "digest: MD5 标准向量（RFC 1321 全套）" {
  assert_eq(@rp.md5_hex_of_utf8(""), "d41d8cd98f00b204e9800998ecf8427e")
  assert_eq(@rp.md5_hex_of_utf8("a"), "0cc175b9c0f1b6a831c399e269772661")
  assert_eq(@rp.md5_hex_of_utf8("abc"), "900150983cd24fb0d6963f7d28e17f72")
  assert_eq(
    @rp.md5_hex_of_utf8("message digest"),
    "f96b697d7cb7938d525a2f31aaf161d0",
  )
  assert_eq(
    @rp.md5_hex_of_utf8("abcdefghijklmnopqrstuvwxyz"),
    "c3fcd3d76192e4007dfb496cca67e13b",
  )
  assert_eq(
    @rp.md5_hex_of_utf8(
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
    ),
    "d174ab98d277d9f5a5611c2c9f419d9f",
  )
  assert_eq(
    @rp.md5_hex_of_utf8(
      "12345678901234567890123456789012345678901234567890123456789012345678901234567890",
    ),
    "57edf4a22be3c955ac49da2e2107b67a",
  )
}

///|
test "digest: MD5 输出 16 字节、中文 UTF-8、长输入" {
  let digest = @rp.md5(@rp.bytes_of_utf8("abc"))
  assert_eq(digest.length(), 16)
  assert_eq(
    @rp.md5_hex_of_utf8("\u{4e2d}\u{6587}\u{6458}\u{8981}"),
    "bc23058c6af16f7090a038db561a2192",
  )
  assert_eq(
    @rp.md5_hex_of_utf8("a".repeat(1000)),
    "cabe45dcc9ae5b66ba86600cca6b8ba8",
  )
}

///|
test "digest: HMAC-SHA256 RFC 4231 向量" {
  // 用例 1：key = 0x0b * 20, data = "Hi There"
  let key1 : FixedArray[Byte] = FixedArray::make(20, b'\x0b')
  assert_eq(
    @rp.hmac_sha256_hex(Bytes::from_array(key1), @rp.bytes_of_utf8("Hi There")),
    "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
  )
  // 用例 2：短 key "Jefe"
  assert_eq(
    @rp.hmac_sha256_hex(
      @rp.bytes_of_utf8("Jefe"),
      @rp.bytes_of_utf8("what do ya want for nothing?"),
    ),
    "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
  )
  // 用例 3：key = 0xaa * 20, data = 0xdd * 50
  let key3 : FixedArray[Byte] = FixedArray::make(20, b'\xaa')
  let data3 : FixedArray[Byte] = FixedArray::make(50, b'\xdd')
  assert_eq(
    @rp.hmac_sha256_hex(Bytes::from_array(key3), Bytes::from_array(data3)),
    "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe",
  )
  // 用例 6：超过块大小的长 key（131 字节 0xaa）
  let key6 : FixedArray[Byte] = FixedArray::make(131, b'\xaa')
  assert_eq(
    @rp.hmac_sha256_hex(
      Bytes::from_array(key6),
      @rp.bytes_of_utf8(
        "Test Using Larger Than Block-Size Key - Hash Key First",
      ),
    ),
    "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54",
  )
}

///|
test "digest: HMAC-SHA256 空 key / 空消息边界" {
  assert_eq(
    @rp.hmac_sha256_hex(Bytes::make(0, b'\x00'), Bytes::make(0, b'\x00')),
    "b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad",
  )
  // 输出长度恒为 32
  assert_eq(
    @rp.hmac_sha256(Bytes::make(0, b'\x00'), @rp.bytes_of_utf8("x")).length(),
    32,
  )
}

///|
test "digest: HMAC-SHA256 块大小边界（64 / 65 字节 key）" {
  // 64 字节 key 不折叠、65 字节 key 先取 sha256；两者都应稳定可复现
  let k64 : FixedArray[Byte] = FixedArray::make(64, b'\xaa')
  let k65 : FixedArray[Byte] = FixedArray::make(65, b'\xaa')
  let msg = @rp.bytes_of_utf8(
    "Test Using Larger Than Block-Size Key and Larger Than One Block-Size Data",
  )
  let h64 = @rp.hmac_sha256_hex(Bytes::from_array(k64), msg)
  let h65 = @rp.hmac_sha256_hex(Bytes::from_array(k65), msg)
  assert_eq(h64.length(), 64)
  assert_eq(h65.length(), 64)
  assert_true(h64 != h65)
}

///|
test "digest: PBKDF2-HMAC-SHA256 标准向量（c=1/2/4096）" {
  let password = @rp.bytes_of_utf8("password")
  let salt = @rp.bytes_of_utf8("salt")
  assert_eq(
    @rp.pbkdf2_hmac_sha256_hex(password, salt, 1, 32),
    "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b",
  )
  assert_eq(
    @rp.pbkdf2_hmac_sha256_hex(password, salt, 2, 32),
    "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43",
  )
  assert_eq(
    @rp.pbkdf2_hmac_sha256_hex(password, salt, 4096, 32),
    "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a",
  )
}

///|
test "digest: PBKDF2 跨块输出（dk_len 40 / 64）" {
  let password = @rp.bytes_of_utf8("password")
  let salt = @rp.bytes_of_utf8("salt")
  assert_eq(
    @rp.pbkdf2_hmac_sha256_hex(password, salt, 1, 40),
    "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b4dbf3a2f3dad3377",
  )
  assert_eq(
    @rp.pbkdf2_hmac_sha256_hex(password, salt, 1, 64),
    "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b4dbf3a2f3dad3377264bb7b8e8330d4efc7451418617dabef683735361cdc18c",
  )
  assert_eq(@rp.pbkdf2_hmac_sha256(password, salt, 1, 64).length(), 64)
}

///|
test "digest: PBKDF2 边界（iterations 0 / dk_len 0 返回空 Bytes）" {
  let password = @rp.bytes_of_utf8("password")
  let salt = @rp.bytes_of_utf8("salt")
  // 文档化行为：iterations < 1 → 零长度（Python 抛 ValueError，这里不 panic）
  assert_eq(@rp.pbkdf2_hmac_sha256(password, salt, 0, 32).length(), 0)
  assert_eq(@rp.pbkdf2_hmac_sha256(password, salt, -1, 32).length(), 0)
  // 文档化行为：dk_len <= 0 → 零长度
  assert_eq(@rp.pbkdf2_hmac_sha256(password, salt, 1, 0).length(), 0)
  assert_eq(@rp.pbkdf2_hmac_sha256(password, salt, 1, -8).length(), 0)
}

///|
test "digest: bytes_from_hex 往返与非法输入" {
  match @rp.bytes_from_hex("00ff10ab") {
    Err(e) => fail("解析失败: \{e}")
    Ok(bytes) => {
      assert_eq(bytes.length(), 4)
      assert_eq(bytes[0], b'\x00')
      assert_eq(bytes[1], b'\xff')
      assert_eq(bytes[2], b'\x10')
      assert_eq(bytes[3], b'\xab')
    }
  }
  match @rp.bytes_from_hex("AABB") {
    Err(e) => fail("大写十六进制应可解析: \{e}")
    Ok(bytes) => {
      assert_eq(bytes.length(), 2)
      assert_eq(bytes[0], b'\xaa')
      assert_eq(bytes[1], b'\xbb')
    }
  }
  // 边界：空串合法（零长度）
  match @rp.bytes_from_hex("") {
    Err(e) => fail("空串应可解析: \{e}")
    Ok(bytes) => assert_eq(bytes.length(), 0)
  }
  // 边界：奇数长度 / 非十六进制字符 → Err
  for bad in ["abc", "zz", "0g", "12 34"] {
    match @rp.bytes_from_hex(bad) {
      Ok(_) => fail("\"\{(bad)}\" 不应解析成功")
      Err(_) => ()
    }
  }
}

// ============================================================================
// qa fixture 对齐：test-suit/rhop_js/fixtures/vools_vectors.json → digest 节
// （由真实 vools-rhop 0.9.0 + Python hashlib/hmac 生成，两平台同一份）
// ============================================================================

///|
test "digest: 消费 qa fixture · sha256 五例" {
  assert_eq(
    @rp.sha256_hex_of_utf8(""),
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  )
  assert_eq(
    @rp.sha256_hex_of_utf8("abc"),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  )
  assert_eq(
    @rp.sha256_hex_of_utf8("\u{4e2d}\u{6587}\u{6821}\u{9a8c}"),
    "620707171a865f6d3488f5a977ff4631dc896f8b96560bb4c7fb6d5c1e9b45ce",
  )
  // 200 字节长串（"rhop" * 50）
  assert_eq(
    @rp.sha256_hex_of_utf8("rhop".repeat(50)),
    "ae0fb3850a88b18f7b91df75d6f0f6ea526274dc87634be96fc13c6c974ea58d",
  )
  // JSON 文本（含中文）
  assert_eq(
    @rp.sha256_hex_of_utf8("{\"a\": 1, \"b\": \"\u{4e2d}\u{6587}\"}"),
    "1c1799998da79b2fed78696a08c9a24388d422e3314b9efabf8efe4d7af9d645",
  )
}

///|
test "digest: 消费 qa fixture · md5 五例" {
  assert_eq(@rp.md5_hex_of_utf8(""), "d41d8cd98f00b204e9800998ecf8427e")
  assert_eq(@rp.md5_hex_of_utf8("abc"), "900150983cd24fb0d6963f7d28e17f72")
  assert_eq(
    @rp.md5_hex_of_utf8("\u{4e2d}\u{6587}\u{6821}\u{9a8c}"),
    "49493b14874ac6e99b8645aee8fdf91b",
  )
  assert_eq(
    @rp.md5_hex_of_utf8("rhop".repeat(50)),
    "fa590025a9e55240b93c5c036ce9c23d",
  )
  assert_eq(
    @rp.md5_hex_of_utf8("{\"a\": 1, \"b\": \"\u{4e2d}\u{6587}\"}"),
    "90926673ee0aa0cb4ce7f53d4172e237",
  )
}

///|
test "digest: 消费 qa fixture · hmac_sha256 两例" {
  assert_eq(
    @rp.hmac_sha256_hex(
      @rp.bytes_of_utf8("rhop-hmac-key"),
      @rp.bytes_of_utf8("hello rhop"),
    ),
    "520afc274a9f0502c752ac5eda2be0f549b8fd1a310df33f5e79161351c55fc6",
  )
  assert_eq(
    @rp.hmac_sha256_hex(
      @rp.bytes_of_utf8("\u{5bc6}\u{94a5}"),
      @rp.bytes_of_utf8("\u{6d88}\u{606f}\u{5185}\u{5bb9}"),
    ),
    "ce53bd16926449b1560c2aab3583f72df174c124d78450a7bfb7ea25394d0fc6",
  )
}

///|
test "digest: 消费 qa fixture · pbkdf2（iterations=1000，32 字节）" {
  assert_eq(
    @rp.pbkdf2_hmac_sha256_hex(
      @rp.bytes_of_utf8("password-123"),
      @rp.bytes_of_utf8("salt-abc"),
      1000,
      32,
    ),
    "d483321b8c65fc041a57b1bcf206c5a3361f65c50fa37e52f4adb305958ff216",
  )
}

///|
test "digest: fixture 的 input_utf8_hex 与 bytes_from_hex 一致" {
  // fixture 同时给了 input_utf8_hex；hex 解码后必须与 UTF-8 编码等值同摘要
  let hexed = "e4b8ade69687e6a0a1e9aa8c" // "中文校验" 的 UTF-8
  match @rp.bytes_from_hex(hexed) {
    Err(e) => fail("hex 解析失败: \{e}")
    Ok(bytes) => {
      assert_eq(bytes.length(), 12)
      assert_eq(
        @rp.sha256_hex(bytes),
        @rp.sha256_hex_of_utf8("\u{4e2d}\u{6587}\u{6821}\u{9a8c}"),
      )
      assert_eq(
        @rp.md5_hex(bytes),
        @rp.md5_hex_of_utf8("\u{4e2d}\u{6587}\u{6821}\u{9a8c}"),
      )
    }
  }
  // 空 hex ⇒ 零字节（对空串摘要）
  match @rp.bytes_from_hex("") {
    Err(e) => fail("空 hex 应合法: \{e}")
    Ok(bytes) => assert_eq(@rp.sha256_hex(bytes), @rp.sha256_hex_of_utf8(""))
  }
}

///|
test "digest: 资源边界 · 1MB 输入的 SHA-256（NIST 向量）" {
  // "a" * 1_000_000 是 FIPS 180-4 的经典长消息向量，覆盖多分组/长度填充进位的极端路径
  let big = "a".repeat(1000000)
  assert_eq(big.length(), 1000000)
  assert_eq(
    @rp.sha256_hex_of_utf8(big),
    "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0",
  )
}

// ============================================================================
// C2 资源审计回归：PBKDF2 优化路径（ipad/opad 预压缩 + 免分配内层循环）
// 必须与旧实现/RFC 向量逐字节一致；含多轮迭代与超 64 字节 salt 分支。
// ============================================================================

///|
test "digest: PBKDF2 优化路径与 hashlib 一致（多轮迭代 c=2000 / 20000）" {
  let password = @rp.bytes_of_utf8("password")
  let salt = @rp.bytes_of_utf8("salt")
  assert_eq(
    @rp.pbkdf2_hmac_sha256_hex(password, salt, 2000, 32),
    "9209a0c90243e88b89488f99cd7ea010c244cc7a9d4bf65c157f2d8f642eb952",
  )
  assert_eq(
    @rp.pbkdf2_hmac_sha256_hex(password, salt, 20000, 32),
    "2a6a4f0832d046838f4a22cbadc94dff08a5bcc328467ee3cade8db8c5d93b87",
  )
}

///|
test "digest: PBKDF2 超 64 字节 salt（跨块 salt + 多轮）" {
  // salt 长度 100 > SHA256 块 64：验证优化路径下「完整块 + 尾块」拼接正确
  let password = @rp.bytes_of_utf8("pass")
  let salt = @rp.bytes_of_utf8("a".repeat(100))
  assert_eq(
    @rp.pbkdf2_hmac_sha256_hex(password, salt, 3, 32),
    "d1054b68c897351c4fdc46a6b445143cd7333415394e9bf927917257a579aeb5",
  )
}

///|
test "digest: PBKDF2 优化路径与 hashlib 一致（iterations=1 边界）" {
  assert_eq(
    @rp.pbkdf2_hmac_sha256_hex(
      @rp.bytes_of_utf8("pw"),
      @rp.bytes_of_utf8("salty"),
      1,
      32,
    ),
    "8bcb1a7f7f2780f2dec9028702fc6cd3bef846a719b927ebffdcc1117828d857",
  )
}
