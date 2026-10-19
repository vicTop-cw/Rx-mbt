// ============================================================================
// rhop · 协议单元测试（跨目标）：packet / envelope / cipher-none
// ============================================================================

///|
test "rhop: RhopPacket to_json_string/from_json_text 往返" {
  let payload = @json.parse("{\"k\":\"v\",\"n\":1,\"nested\":{\"a\":true}}")
  let pkt = @rp.RhopPacket::new(
    "id-001", "proc-a", "command", payload, 1700000000123L,
  )
  let text = pkt.to_json_string()
  match @rp.RhopPacket::from_json_text(text) {
    Err(e) => fail("解析失败: \{e}")
    Ok(p) => {
      assert_eq(p.id, "id-001")
      assert_eq(p.source, "proc-a")
      assert_eq(p.kind, "command")
      assert_eq(p.at, 1700000000123L)
      // payload 往返一致
      assert_eq(p.to_json_string(), text)
    }
  }
}

///|
test "rhop: RhopPacket 带中文与转义字符往返" {
  let payload = @json.parse("{\"msg\":\"你好 rhop\"}")
  let pkt = @rp.RhopPacket::new(
    "id-\"quoted\"", "节点-A", "state", payload, 1L,
  )
  match @rp.RhopPacket::from_json_text(pkt.to_json_string()) {
    Err(e) => fail("解析失败: \{e}")
    Ok(p) => {
      assert_eq(p.id, "id-\"quoted\"")
      assert_eq(p.source, "节点-A")
    }
  }
}

///|
test "rhop: RhopPacket from_json_text 字段缺失返回 Err" {
  match @rp.RhopPacket::from_json_text("{\"id\":\"x\",\"source\":\"a\"}") {
    Err(_) => ()
    Ok(_) => fail("应解析失败")
  }
}

///|
test "rhop: RhopEnvelope encode/decode 往返" {
  let text = @rp.RhopEnvelope::encode(1, "none", "aGVsbG8=")
  match @rp.RhopEnvelope::decode(text) {
    Err(e) => fail("解码失败: \{e}")
    Ok(env) => {
      assert_eq(env.v, 1)
      assert_eq(env.alg, "none")
      assert_eq(env.ct, "aGVsbG8=")
    }
  }
}

///|
test "rhop: RhopEnvelope decode 坏 JSON 返回 Err" {
  match @rp.RhopEnvelope::decode("not-json") {
    Err(_) => ()
    Ok(_) => fail("应解析失败")
  }
}

///|
test "rhop: RhopCipherNone encrypt/decrypt 往返" {
  let cipher = @rp.RhopCipherNone::new()
  assert_eq(@rp.RhopCipher::alg_name(cipher), "none")
  let ct = @rp.RhopCipher::encrypt(cipher, "hello 你好")
  match @rp.RhopCipher::decrypt(cipher, ct) {
    None => fail("解密失败")
    Some(plain) => assert_eq(plain, "hello 你好")
  }
}

///|
test "rhop: RhopCipherNone decrypt 坏密文返回 None" {
  let cipher = @rp.RhopCipherNone::new()
  match @rp.RhopCipher::decrypt(cipher, "!!!not-base64!!!") {
    None => ()
    Some(_) => fail("坏密文应解密失败")
  }
}
