// ============================================================================
// rhop · signer 单元测试（跨目标）
//
// 对齐 vools `tests/test_signer.py`，并消费 qa fixture
// `test-suit/rhop_js/fixtures/vools_vectors.json` 的 `signer.file_hash.cases[]`
// 真实向量（含 preimage 原文与签名）。
//
// ⚠ 关键口径：preimage 是 `json.dumps(..., sort_keys=True)`，vools 未传
// ensure_ascii ⇒ **ensure_ascii=True**（非 ASCII 转义成 \uXXXX）。
// `unicode_result` 那例正是两种口径的分水岭。
// ============================================================================

///|
/// 解析 JSON 文本（保留数字原始表示，避免 12 → "12.0" 之类的形态漂移）。
fn signer_result(text : String) -> Json {
  @json.parse(text, preserve_number_repr=true) catch {
    _ => abort("result JSON 解析失败: \{text}")
  }
}

///|
test "signer: FileHashSigner 签名格式 sha256:<64 hex>" {
  let signer = @rp.FileHashSigner::new()
  let sig = @rp.AbstractSigner::sign(
    signer,
    "job-001",
    signer_result("{\"stdout\": \"ok\"}"),
  )
  match sig {
    None => fail("FileHashSigner.sign 不应返回 None")
    Some(text) => {
      assert_true(text.has_prefix("sha256:"))
      assert_eq(text.length(), 7 + 64)
    }
  }
}

///|
test "signer: FileHashSigner 确定性 + 正反例" {
  let signer = @rp.FileHashSigner::new()
  let result = signer_result("{\"stdout\": \"ok\"}")
  let sig1 = signer.signature("job-001", result)
  let sig2 = signer.signature("job-001", result)
  assert_eq(sig1, sig2) // 确定性
  // verify 正例
  assert_true(@rp.AbstractSigner::verify(signer, "job-001", result, sig1))
  // verify 反例：result 不同
  assert_false(
    @rp.AbstractSigner::verify(
      signer,
      "job-001",
      signer_result("{\"stdout\": \"NO\"}"),
      sig1,
    ),
  )
  // verify 反例：task_id 不同
  assert_false(@rp.AbstractSigner::verify(signer, "job-002", result, sig1))
  // verify 反例：签名被改
  assert_false(
    @rp.AbstractSigner::verify(signer, "job-001", result, "sha256:deadbeef"),
  )
}

///|
test "signer: 与 vools fixture 逐字节一致（ascii_result）" {
  let signer = @rp.FileHashSigner::new()
  let result = signer_result(
    "{\"elapsed_ms\": 12, \"rows\": 3, \"status\": \"done\"}",
  )
  // preimage 原文（fixture signer.file_hash.cases[0].preimage）
  assert_eq(
    @rp.canonical_json_ascii(
      @rp.canonical_object([
        ("task_id", Json::string("task-001")),
        ("result", result),
      ]),
    ),
    "{\"result\": {\"elapsed_ms\": 12, \"rows\": 3, \"status\": \"done\"}, \"task_id\": \"task-001\"}",
  )
  assert_eq(
    signer.signature("task-001", result),
    "sha256:979367e98855937a0a164b19c6c8cbd925bf6f334994b10111c1515d675cea2d",
  )
}

///|
test "signer: 与 vools fixture 逐字节一致（unicode_result → ensure_ascii=True）" {
  let signer = @rp.FileHashSigner::new()
  let result = signer_result(
    "{\"\u{6307}\u{6807}\": [1, 2], \"\u{7ed3}\u{8bba}\": \"\u{5b8c}\u{6210}\"}",
  )
  // preimage 必须把中文转义成 \uXXXX（fixture signer.file_hash.cases[1].preimage）
  let preimage = @rp.canonical_json_ascii(
    @rp.canonical_object([
      ("task_id", Json::string("task-002")),
      ("result", result),
    ]),
  )
  assert_eq(
    preimage, "{\"result\": {\"\\u6307\\u6807\": [1, 2], \"\\u7ed3\\u8bba\": \"\\u5b8c\\u6210\"}, \"task_id\": \"task-002\"}",
  )
  assert_eq(
    signer.signature("task-002", result),
    "sha256:008d35d8bc6adba19859645f59bbe206ed5f0824d2d855e49b7e0a0b6be11194",
  )
}

///|
test "signer: 与 vools fixture 逐字节一致（nested_result）" {
  let signer = @rp.FileHashSigner::new()
  let result = signer_result(
    "{\"error\": null, \"result\": {\"items\": [\"a\", \"b\"], \"ok\": true}}",
  )
  assert_eq(
    signer.signature("task-003", result),
    "sha256:32803b55a365cd8d7e85dc2a36c642adb08d7079caf49a1480f9ab14a6b0c306",
  )
}

///|
test "signer: 两种 ensure_ascii 口径对 ASCII 结果等价、对中文结果不同" {
  let ascii_result = signer_result("{\"a\": 1}")
  // 纯 ASCII：两口径输出相同
  let obj = @rp.canonical_object([
    ("task_id", Json::string("t")),
    ("result", ascii_result),
  ])
  assert_eq(@rp.canonical_json_ascii(obj), @rp.canonical_json(obj))
  // 含中文：ensure_ascii=False 原样、True 转义，二者必须不同
  let uni_result = signer_result("{\"\u{4e2d}\": \"\u{6587}\"}")
  let uni_obj = @rp.canonical_object([
    ("task_id", Json::string("t")),
    ("result", uni_result),
  ])
  assert_true(@rp.canonical_json_ascii(uni_obj) != @rp.canonical_json(uni_obj))
  assert_true(@rp.canonical_json_ascii(uni_obj).contains("\\u4e2d"))
  assert_true(@rp.canonical_json(uni_obj).contains("\u{4e2d}"))
}

///|
test "signer: NPUSigner 默认 provider → sign 返回 None（无 npu-smi 语义）" {
  let signer = @rp.NPUSigner::new("NPU_MARKER")
  let result = signer_result("{\"stdout\": \"ok\"}")
  assert_eq(@rp.AbstractSigner::sign(signer, "job-001", result), None)
  // verify 在无法签名时恒为 false
  assert_false(
    @rp.AbstractSigner::verify(signer, "job-001", result, "anything"),
  )
  assert_false(signer.has_serial())
  assert_eq(signer.marker(), "NPU_MARKER")
  // 默认 marker 构造器
  assert_eq(
    @rp.NPUSigner::with_default_marker().marker(),
    @rp.NPU_MARKER_DEFAULT,
  )
}

///|
test "signer: NPUSigner 注入 provider → 格式 <marker>:<serial>:<md5>" {
  let signer = @rp.NPUSigner::new("NPU_MARKER").with_serial_provider(fn() {
    Some("ABC123")
  })
  let result = signer_result("{\"stdout\": \"ok\"}")
  assert_true(signer.has_serial())
  match @rp.AbstractSigner::sign(signer, "job-001", result) {
    None => fail("注入 provider 后 sign 不应返回 None")
    Some(sig) => {
      // 期望值由 Python 口径独立算出：
      // preimage = {"result": {"stdout": "ok"}, "task_id": "job-001"}
      assert_eq(sig, "NPU_MARKER:ABC123:c5c2ef71728dc922a90f23f5bb9bae3b")
      assert_true(sig.has_prefix("NPU_MARKER:ABC123:"))
      // verify 正反例
      assert_true(@rp.AbstractSigner::verify(signer, "job-001", result, sig))
      assert_false(
        @rp.AbstractSigner::verify(
          signer,
          "job-001",
          signer_result("{\"stdout\": \"NO\"}"),
          sig,
        ),
      )
      assert_false(@rp.AbstractSigner::verify(signer, "job-x", result, sig))
    }
  }
}

///|
test "signer: NPUSigner marker 可定制、provider 返回 None 时不可签名" {
  let signer = @rp.NPUSigner::new("TEST_MARKER").with_serial_provider(fn() {
    Some("SN-9")
  })
  match @rp.AbstractSigner::sign(signer, "t", signer_result("{\"a\": 1}")) {
    None => fail("应可签名")
    Some(sig) => assert_true(sig.has_prefix("TEST_MARKER:SN-9:"))
  }
  // provider 显式返回 None ⇒ None
  let none_signer = @rp.NPUSigner::new("M").with_serial_provider(fn() { None })
  assert_eq(
    @rp.AbstractSigner::sign(none_signer, "t", signer_result("{\"a\": 1}")),
    None,
  )
  // 空 marker / 空 serial 也是合法输入（仅格式结果更短），不 panic
  let empty_signer = @rp.NPUSigner::new("").with_serial_provider(fn() {
    Some("")
  })
  match
    @rp.AbstractSigner::sign(empty_signer, "t", signer_result("{\"a\": 1}")) {
    None => fail("空 marker/serial 仍应产生签名")
    Some(sig) => assert_true(sig.has_prefix("::"))
  }
}
