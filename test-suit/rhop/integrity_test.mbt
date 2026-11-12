// ============================================================================
// rhop · integrity 单元测试（跨目标）
//
// 对齐 vools `tests/test_integrity.py`，并补一条端到端链路：
//   Envelope → sign(result) → with_signature → to_rhop_bytes
//            → from_rhop_bytes → verify(signature) → checksum_match
// ============================================================================

///|
/// 构造与 vools `test_integrity.py::_make_env` 等价的信封。
fn integrity_env() -> @rp.Envelope {
  @rp.Envelope::new_full(
    "job-001",
    @rp.TaskStatus::Pending,
    @json.parse("{\"cmd\":\"echo hi\"}") catch {
      _ => abort("payload")
    },
    @rp.Side::Requester,
    created_at="2026-10-21T10:00:00Z",
    updated_at="2026-10-21T10:00:00Z",
  )
}

///|
test "integrity: verify 通过（合法字节）" {
  let env = integrity_env()
  let raw = env.to_rhop_bytes()
  let (ok, reason) = @rp.IntegrityChecker::verify(env, raw)
  assert_true(ok)
  assert_eq(reason, "")
  // 便捷函数同义
  let (ok2, _) = @rp.integrity_verify(env, raw)
  assert_true(ok2)
}

///|
test "integrity: verify 检测篡改（改内容不改 checksum）" {
  let env = integrity_env()
  let raw = env.to_rhop_bytes()
  let tampered = @rp.bytes_of_utf8(
    @rp.utf8_text(raw).replace(old="echo hi", new="echo HO"),
  )
  let (ok, reason) = @rp.IntegrityChecker::verify(env, tampered)
  assert_false(ok)
  assert_true(reason.contains("checksum mismatch"))
}

///|
test "integrity: verify_bytes 正反例（含坏 JSON / 缺字段）" {
  let env = integrity_env()
  let raw = env.to_rhop_bytes()
  let (ok, reason) = @rp.IntegrityChecker::verify_bytes(raw)
  assert_true(ok)
  assert_eq(reason, "")
  assert_true(@rp.integrity_verify_bytes(raw).0)
  // 坏 JSON
  let (ok2, _) = @rp.IntegrityChecker::verify_bytes(
    @rp.bytes_of_utf8("not-json"),
  )
  assert_false(ok2)
  // 合法 JSON 但 checksum 错
  let (ok3, reason3) = @rp.IntegrityChecker::verify_bytes(
    @rp.bytes_of_utf8(
      "{\"v\":1,\"task_id\":\"x\",\"checksum\":\"sha256:wrong\"}",
    ),
  )
  assert_false(ok3)
  assert_true(reason3.contains("checksum mismatch"))
  // 空字节（资源下限：零长度输入不 panic）
  let (ok4, _) = @rp.IntegrityChecker::verify_bytes(Bytes::make(0, b'\x00'))
  assert_false(ok4)
}

///|
test "integrity: verify 截断字节（传输中断语义）" {
  let env = integrity_env()
  let raw = env.to_rhop_bytes()
  // 去掉末尾 10 字节：JSON 不完整 → 解析失败（不是 checksum 失败，但同为 false）
  let text = @rp.utf8_text(raw)
  let truncated = @rp.bytes_of_utf8(text[0:text.length() - 10].to_owned())
  let (ok, reason) = @rp.IntegrityChecker::verify(env, truncated)
  assert_false(ok)
  assert_true(reason.contains("解析失败"))
}

///|
test "integrity: checksum_match 正例与篡改反例" {
  let env = integrity_env()
  assert_true(@rp.IntegrityChecker::checksum_match(env))
  assert_true(@rp.integrity_checksum_match(env))
  // 用 from_dict 造一个 checksum 与内容不符的信封（不校验 checksum，原样保留）
  let dict = @json.parse(
    "{\"task_id\":\"job-bad\",\"status\":\"pending\",\"payload\":{},\"side\":\"requester\",\"version\":1,\"checksum\":\"sha256:wrong\"}",
  ) catch {
    _ => fail("dict")
  }
  match @rp.Envelope::from_dict(dict) {
    Err(e) => fail("from_dict 失败: \{e}")
    Ok(bad) => {
      assert_eq(bad.checksum, "sha256:wrong")
      // 反序列化会因 checksum 不匹配而失败 ⇒ false
      assert_false(@rp.IntegrityChecker::checksum_match(bad))
    }
  }
}

///|
test "integrity: 端到端 Envelope → sign → bytes → from_bytes → verify" {
  // 1) 需求端造信封
  let payload = @json.parse(
    "{\"cmd\":\"echo\",\"\u{6587}\u{672c}\":\"\u{4e2d}\u{6587}\u{8f7d}\u{8377}\"}",
    preserve_number_repr=true,
  ) catch {
    _ => fail("payload")
  }
  let result = @json.parse(
    "{\"ok\":true,\"\u{6307}\u{6807}\":[1,2,3],\"\u{7ed3}\u{8bba}\":\"\u{5b8c}\u{6210}\"}",
    preserve_number_repr=true,
  ) catch {
    _ => fail("result")
  }
  let base = @rp.Envelope::new_full(
    "job-e2e",
    @rp.TaskStatus::Done,
    payload,
    @rp.Side::Executor,
    result~,
    version=2,
    created_at="2026-10-27T11:00:00Z",
    updated_at="2026-10-27T12:00:00Z",
    hops_seen=["requester", "executor"],
  )
  // 2) 对结果签名（FileHashSigner：ensure_ascii=True 口径）
  let signer = @rp.FileHashSigner::new()
  let signature = signer.signature("job-e2e", result)
  // 3) 把签名写进信封（重算 checksum）
  let signed = base.with_signature(Some(signature))
  assert_eq(signed.signature, Some(signature))
  assert_true(signed.checksum != base.checksum)
  // 4) 落盘字节 → 反序列化
  let raw = signed.to_rhop_bytes()
  let (ok, reason) = @rp.integrity_verify_bytes(raw)
  assert_true(ok)
  assert_eq(reason, "")
  match @rp.Envelope::from_rhop_bytes(raw) {
    Err(e) => fail("反序列化失败: \{e}")
    Ok(restored) => {
      // 5) 签名复验（对反序列化后的 result 再签一次必须一致）
      match restored.result {
        None => fail("result 不应为空")
        Some(restored_result) => {
          let restored_sig = signer.signature(restored.task_id, restored_result)
          assert_eq(Some(restored_sig), restored.signature)
          assert_true(
            @rp.AbstractSigner::verify(
              signer,
              restored.task_id,
              restored_result,
              restored_sig,
            ),
          )
        }
      }
      // 6) checksum 自洽
      assert_true(@rp.IntegrityChecker::checksum_match(restored))
      assert_eq(restored.checksum, restored.compute_checksum())
    }
  }
}

///|
test "integrity: 端到端篡改签名后 checksum 仍自洽但验签失败" {
  let result = @json.parse("{\"stdout\":\"ok\"}") catch { _ => fail("result") }
  let signer = @rp.FileHashSigner::new()
  let env = @rp.Envelope::new_full(
    "job-sig",
    @rp.TaskStatus::Done,
    @json.parse("{}") catch {
      _ => fail("payload")
    },
    @rp.Side::Executor,
    result~,
    signature="sha256:not-the-real-one",
  )
  // checksum 覆盖 signature 字段 ⇒ 自身仍自洽
  assert_true(@rp.IntegrityChecker::checksum_match(env))
  match @rp.Envelope::from_rhop_bytes(env.to_rhop_bytes()) {
    Err(e) => fail("往返失败: \{e}")
    Ok(restored) => {
      // 但签名本身对不上 => 验签失败
      let expected = signer.signature("job-sig", result)
      match restored.signature {
        None => fail("signature 不应为空")
        Some(sig) => {
          assert_false(sig == expected)
          assert_false(
            @rp.AbstractSigner::verify(signer, "job-sig", result, sig),
          )
        }
      }
    }
  }
}
