// ============================================================================
// rhop · js 目标测试：AES-256-GCM 加解密（node crypto）
// ============================================================================

///|
test "rhop-js: Aes256GcmCipher encrypt/decrypt 往返" {
  let cipher = @rp.Aes256GcmCipher::new("s3cr3t-password")
  assert_eq(@rp.RhopCipher::alg_name(cipher), "aes-256-gcm")
  let ct = @rp.RhopCipher::encrypt(cipher, "hello 你好 rhop")
  match @rp.RhopCipher::decrypt(cipher, ct) {
    None => fail("AES 解密失败")
    Some(plain) => assert_eq(plain, "hello 你好 rhop")
  }
}

///|
test "rhop-js: Aes256GcmCipher 错误 token 返回 None" {
  let cipher = @rp.Aes256GcmCipher::new("s3cr3t-password")
  match @rp.RhopCipher::decrypt(cipher, "bad-token") {
    None => ()
    Some(_) => fail("错误 token 应解密失败")
  }
}

///|
test "rhop-js: Aes256GcmCipher 错误密码无法解密" {
  let c1 = @rp.Aes256GcmCipher::new("correct-pw")
  let c2 = @rp.Aes256GcmCipher::new("wrong-pw")
  let ct = @rp.RhopCipher::encrypt(c1, "secret message")
  match @rp.RhopCipher::decrypt(c2, ct) {
    None => ()
    Some(_) => fail("错误密码应解密失败")
  }
}

///|
test "rhop-js: Aes256GcmCipher 空 token 返回 None" {
  let cipher = @rp.Aes256GcmCipher::new("s3cr3t-password")
  match @rp.RhopCipher::decrypt(cipher, "") {
    None => ()
    Some(_) => fail("空 token 应解密失败")
  }
}
