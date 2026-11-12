// ============================================================================
// rhop · envelope 单元测试（跨目标）
//
// 对齐 vools `tests/test_envelope.py`，并加入**跨实现逐字节向量**（期望值由
// Python 3.13 vools-rhop 口径生成：json.dumps(ensure_ascii=False, sort_keys=True)
// + sha256）。checksum 与 .rhop 字节必须与 Python 完全一致。
// ============================================================================

///|
/// 便捷构造：vools `test_envelope.py::_make_env` 的等价物。
fn make_env(task_id : String, status : @rp.TaskStatus) -> @rp.Envelope {
  @rp.Envelope::new(
    task_id,
    status,
    @json.parse("{\"cmd\":\"echo hi\"}") catch {
      _ => Json::null()
    },
    @rp.Side::Requester,
  )
}

///|
test "envelope: checksum 前缀与格式（sha256: + 64 位小写 hex）" {
  let env = make_env("job-001", @rp.TaskStatus::Pending)
  assert_true(env.checksum.has_prefix("sha256:"))
  assert_eq(env.checksum.length(), 7 + 64)
  // 去掉前缀后是 64 个小写十六进制字符
  let hex = env.checksum[7:].to_owned()
  assert_eq(hex.length(), 64)
  assert_eq(hex, hex.to_lower())
}

///|
test "envelope: 与 Python 逐字节一致（向量 A：pending + 时间戳）" {
  // Python: task_id="job-001", status=pending, payload={"cmd":"echo hi"},
  //         side=requester, created_at/updated_at="2026-10-21T10:00:00Z"
  let env = @rp.Envelope::new_full(
    "job-001",
    @rp.TaskStatus::Pending,
    @json.parse("{\"cmd\":\"echo hi\"}") catch {
      _ => fail("payload 解析失败")
    },
    @rp.Side::Requester,
    created_at="2026-10-21T10:00:00Z",
    updated_at="2026-10-21T10:00:00Z",
  )
  assert_eq(
    env.checksum,
    "sha256:f9d834bcd27ee379c0b852f30d073c3cb68284178719d098b1f0140b5fb2967e",
  )
  let expected = "{\"checksum\": \"sha256:f9d834bcd27ee379c0b852f30d073c3cb68284178719d098b1f0140b5fb2967e\", \"created_at\": \"2026-10-21T10:00:00Z\", \"error\": null, \"hops_seen\": [], \"payload\": {\"cmd\": \"echo hi\"}, \"result\": null, \"side\": \"requester\", \"signature\": null, \"status\": \"pending\", \"task_id\": \"job-001\", \"updated_at\": \"2026-10-21T10:00:00Z\", \"v\": 1, \"version\": 1}"
  let bytes = env.to_rhop_bytes()
  // C1 审计 F9：直接比字节（原先两边各算 sha256 再比，若 sha256_hex 整体缺陷则断言永真）
  assert_eq(bytes, @rp.bytes_of_utf8(expected))
  match @rp.Envelope::from_rhop_bytes(@rp.bytes_of_utf8(expected)) {
    Err(e) => fail("Python 向量反序列化失败: \{e}")
    Ok(restored) => {
      assert_eq(restored.task_id, "job-001")
      assert_eq(restored.checksum, env.checksum)
    }
  }
}

///|
test "envelope: 与 Python 逐字节一致（向量 B：done + 中文 + hops + 签名）" {
  let payload = @json.parse(
    "{\"\u{4efb}\u{52a1}\":\"\u{4e2d}\u{6587}\u{8f7d}\u{8377}\",\"n\":3}",
  ) catch {
    _ => fail("payload 解析失败")
  }
  let result = @json.parse("{\"stdout\":\"ok\",\"code\":0}") catch {
    _ => fail("result 解析失败")
  }
  let env = @rp.Envelope::new_full(
    "job-002",
    @rp.TaskStatus::Done,
    payload,
    @rp.Side::Executor,
    result~,
    version=2,
    created_at="2026-10-21T10:00:00Z",
    updated_at="2026-10-21T10:05:00Z",
    hops_seen=["requester", "executor"],
    signature="sha256:deadbeef",
  )
  assert_eq(
    env.checksum,
    "sha256:c462014049adfd29e3e964834d406f156c57ca1a9b24f4ecd9f6f92c63573ca7",
  )
  let expected = "{\"checksum\": \"sha256:c462014049adfd29e3e964834d406f156c57ca1a9b24f4ecd9f6f92c63573ca7\", \"created_at\": \"2026-10-21T10:00:00Z\", \"error\": null, \"hops_seen\": [\"requester\", \"executor\"], \"payload\": {\"n\": 3, \"\u{4efb}\u{52a1}\": \"\u{4e2d}\u{6587}\u{8f7d}\u{8377}\"}, \"result\": {\"code\": 0, \"stdout\": \"ok\"}, \"side\": \"executor\", \"signature\": \"sha256:deadbeef\", \"status\": \"done\", \"task_id\": \"job-002\", \"updated_at\": \"2026-10-21T10:05:00Z\", \"v\": 1, \"version\": 2}"
  assert_eq(
    @rp.sha256_hex(env.to_rhop_bytes()),
    @rp.sha256_hex(@rp.bytes_of_utf8(expected)),
  )
}

///|
test "envelope: to_rhop_bytes → from_rhop_bytes 往返（字段全等）" {
  let env = @rp.Envelope::new_full(
    "job-003",
    @rp.TaskStatus::Running,
    @json.parse("{\"a\":[1,2,3],\"b\":true}") catch {
      _ => fail("payload")
    },
    @rp.Side::Executor,
    result=@json.parse("{\"r\":null}") catch { _ => fail("result") },
    error="none",
    version=3,
    created_at="t0",
    updated_at="t1",
    hops_seen=["requester", "executor"],
    signature="sig",
  )
  match @rp.Envelope::from_rhop_bytes(env.to_rhop_bytes()) {
    Err(e) => fail("往返失败: \{e}")
    Ok(restored) => {
      assert_eq(restored.task_id, env.task_id)
      assert_eq(restored.status, env.status)
      assert_eq(restored.side, env.side)
      assert_eq(restored.version, env.version)
      assert_eq(restored.created_at, env.created_at)
      assert_eq(restored.updated_at, env.updated_at)
      assert_eq(restored.hops_seen, env.hops_seen)
      assert_eq(restored.checksum, env.checksum)
      assert_eq(restored.error, env.error)
      assert_eq(restored.signature, env.signature)
      // payload / result 语义相等
      assert_eq(
        @rp.canonical_json(restored.payload),
        @rp.canonical_json(env.payload),
      )
    }
  }
}

///|
test "envelope: to_rhop_bytes 是合法 JSON 且含 v / checksum 键" {
  let env = make_env("job-001", @rp.TaskStatus::Pending)
  let raw = env.to_rhop_bytes()
  let text = @rp.utf8_text(raw)
  let parsed = @json.parse(text) catch {
    _ => fail("to_rhop_bytes 不是合法 JSON")
  }
  match parsed {
    Object(fields) => {
      assert_eq(fields.get("v"), Some(Json::number(1.0)))
      assert_eq(fields.get("task_id"), Some(Json::string("job-001")))
      assert_eq(fields.get("status"), Some(Json::string("pending")))
      match fields.get("checksum") {
        Some(String(cs)) => assert_true(cs.has_prefix("sha256:"))
        _ => fail("checksum 缺失或类型错误")
      }
    }
    _ => fail("应是 JSON 对象")
  }
}

///|
test "envelope: 篡改字节 → checksum mismatch" {
  let env = make_env("job-001", @rp.TaskStatus::Pending)
  let raw = env.to_rhop_bytes()
  // 翻转 payload 里的一个字符（保持 JSON 合法，只让内容与 checksum 不符）
  let tampered = @rp.bytes_of_utf8(
    @rp.utf8_text(raw).replace(old="echo hi", new="echo HO"),
  )
  match @rp.Envelope::from_rhop_bytes(tampered) {
    Ok(_) => fail("篡改后应校验失败")
    Err(reason) => assert_true(reason.contains("checksum mismatch"))
  }
}

///|
test "envelope: 坏 JSON / 非法 UTF-8 → 解析失败" {
  match @rp.Envelope::from_rhop_bytes(@rp.bytes_of_utf8("not valid json")) {
    Ok(_) => fail("坏 JSON 应失败")
    Err(reason) => assert_true(reason.contains("解析失败"))
  }
  // 非法 UTF-8 字节（0xFF 不是合法 UTF-8 起始字节）
  let bad : FixedArray[Byte] = FixedArray::make(2, b'\xff')
  match @rp.Envelope::from_rhop_bytes(Bytes::from_array(bad)) {
    Ok(_) => fail("非法 UTF-8 应失败")
    Err(reason) => assert_true(reason.contains("解析失败"))
  }
  // 顶层是数组而非对象
  match @rp.Envelope::from_rhop_bytes(@rp.bytes_of_utf8("[1,2]")) {
    Ok(_) => fail("顶层数组应失败")
    Err(reason) => assert_true(reason.contains("解析失败"))
  }
}

///|
test "envelope: 缺必填字段 → 缺字段错误（不是 KeyError 式崩溃）" {
  // 缺 task_id：先构造合法 checksum，确保走到字段校验而不是 checksum 失败
  let body = "{\"payload\": {}, \"side\": \"requester\", \"status\": \"pending\", \"v\": 1, \"version\": 1}"
  let checksum = "sha256:" + @rp.sha256_hex_of_utf8(body)
  let raw = "{\"checksum\": \"\{checksum}\", \"payload\": {}, \"side\": \"requester\", \"status\": \"pending\", \"v\": 1, \"version\": 1}"
  match @rp.Envelope::from_rhop_bytes(@rp.bytes_of_utf8(raw)) {
    Ok(_) => fail("缺 task_id 应失败")
    Err(reason) => assert_true(reason.contains("缺少必填字段"))
  }
  // 缺 payload
  let body2 = "{\"side\": \"requester\", \"status\": \"pending\", \"task_id\": \"x\", \"v\": 1, \"version\": 1}"
  let cs2 = "sha256:" + @rp.sha256_hex_of_utf8(body2)
  let raw2 = "{\"checksum\": \"\{cs2}\", \"side\": \"requester\", \"status\": \"pending\", \"task_id\": \"x\", \"v\": 1, \"version\": 1}"
  match @rp.Envelope::from_rhop_bytes(@rp.bytes_of_utf8(raw2)) {
    Ok(_) => fail("缺 payload 应失败")
    Err(reason) => assert_true(reason.contains("缺少必填字段"))
  }
}

///|
test "envelope: 非法 status / side 字面量 → 字段值非法" {
  let body = "{\"payload\": {}, \"side\": \"requester\", \"status\": \"archived\", \"task_id\": \"x\", \"v\": 1, \"version\": 1}"
  let cs = "sha256:" + @rp.sha256_hex_of_utf8(body)
  let raw = "{\"checksum\": \"\{cs}\", \"payload\": {}, \"side\": \"requester\", \"status\": \"archived\", \"task_id\": \"x\", \"v\": 1, \"version\": 1}"
  match @rp.Envelope::from_rhop_bytes(@rp.bytes_of_utf8(raw)) {
    Ok(_) => fail("非法 status 应失败")
    Err(reason) => assert_true(reason.contains("字段值非法"))
  }
}

///|
test "envelope: 中文 payload 往返（ensure_ascii=False）" {
  let payload = @json.parse(
    "{\"\u{6d88}\u{606f}\":\"\u{4f60}\u{597d} rhop\",\"n\":1}",
  ) catch {
    _ => fail("payload 解析失败")
  }
  let env = @rp.Envelope::new(
    "job-cn",
    @rp.TaskStatus::Pending,
    payload,
    @rp.Side::Requester,
  )
  let text = @rp.utf8_text(env.to_rhop_bytes())
  // 非 ASCII 原样落盘
  assert_true(text.contains("\u{4f60}\u{597d} rhop"))
  match @rp.Envelope::from_rhop_bytes(env.to_rhop_bytes()) {
    Err(e) => fail("往返失败: \{e}")
    Ok(restored) =>
      assert_eq(
        @rp.canonical_json(restored.payload),
        @rp.canonical_json(payload),
      )
  }
}

///|
test "envelope: hops_seen 顺序保留、空 hops_seen 合法" {
  let env = @rp.Envelope::new_full(
    "job-hops",
    @rp.TaskStatus::Running,
    @json.parse("{}") catch {
      _ => fail("payload")
    },
    @rp.Side::Requester,
    hops_seen=["requester", "executor", "requester"],
  )
  match @rp.Envelope::from_rhop_bytes(env.to_rhop_bytes()) {
    Err(e) => fail("往返失败: \{e}")
    Ok(restored) =>
      assert_eq(restored.hops_seen, ["requester", "executor", "requester"])
  }
  // 空 hops_seen 与空 payload 的组合
  let empty = @rp.Envelope::new_full(
    "job-empty",
    @rp.TaskStatus::Pending,
    @json.parse("{}") catch {
      _ => fail("payload")
    },
    @rp.Side::Requester,
  )
  assert_eq(empty.hops_seen.length(), 0)
  match @rp.Envelope::from_rhop_bytes(empty.to_rhop_bytes()) {
    Err(e) => fail("空 hops 往返失败: \{e}")
    Ok(restored) => assert_eq(restored.hops_seen.length(), 0)
  }
}

///|
test "envelope: wither 返回新对象并重算 checksum" {
  let base = make_env("job-w", @rp.TaskStatus::Pending)
  let base_checksum = base.checksum
  // with_result
  let with_result = base.with_result(
    Some(@json.parse("{\"stdout\":\"ok\"}") catch { _ => fail("result") }),
  )
  assert_eq(base.checksum, base_checksum) // 原对象不变
  assert_true(with_result.checksum != base_checksum)
  assert_eq(with_result.checksum, with_result.compute_checksum())
  match @rp.Envelope::from_rhop_bytes(with_result.to_rhop_bytes()) {
    Err(e) => fail("with_result 后往返失败: \{e}")
    Ok(restored) => assert_true(restored.result is Some(_))
  }
  // with_updated_at
  let with_updated = base.with_updated_at("2026-10-21T11:00:00Z")
  assert_true(with_updated.checksum != base_checksum)
  assert_eq(with_updated.checksum, with_updated.compute_checksum())
  assert_eq(with_updated.updated_at, "2026-10-21T11:00:00Z")
  // with_hops_seen
  let with_hops = base.with_hops_seen(["requester"])
  assert_true(with_hops.checksum != base_checksum)
  assert_eq(with_hops.checksum, with_hops.compute_checksum())
  assert_eq(with_hops.hops_seen, ["requester"])
  // with_status / with_signature 同样重算
  let with_status = base.with_status(@rp.TaskStatus::Claimed)
  assert_eq(with_status.checksum, with_status.compute_checksum())
  assert_true(with_status.checksum != base_checksum)
  let with_sig = base.with_signature(Some("sha256:abc"))
  assert_eq(with_sig.checksum, with_sig.compute_checksum())
  // 四个 wither 出来的信封都能通过反序列化校验
  for env in [with_result, with_updated, with_hops, with_status, with_sig] {
    match @rp.Envelope::from_rhop_bytes(env.to_rhop_bytes()) {
      Err(e) => fail("wither 结果往返失败: \{e}")
      Ok(_) => ()
    }
  }
}

///|
test "envelope: to_dict / from_dict 往返（to_dict 不含 v 键）" {
  let env = @rp.Envelope::new_full(
    "job-d",
    @rp.TaskStatus::Done,
    @json.parse("{\"x\":1}") catch {
      _ => fail("payload")
    },
    @rp.Side::Executor,
    result=
      @json.parse("{\"stdout\":\"ok\"}") catch {
        _ => fail("result")
      },

    error="none",
  )
  let dict = env.to_dict()
  match dict {
    Object(fields) => {
      assert_eq(fields.get("v"), None)
      match fields.get("checksum") {
        Some(String(cs)) => assert_eq(cs, env.checksum)
        _ => fail("to_dict 应含 checksum")
      }
      match fields.get("result") {
        Some(Null) => fail("to_dict 的 result 不应是 null")
        Some(_) => ()
        None => fail("to_dict 应含 result 键")
      }
    }
    _ => fail("to_dict 应返回对象")
  }
  match @rp.Envelope::from_dict(dict) {
    Err(e) => fail("from_dict 失败: \{e}")
    Ok(restored) => {
      assert_eq(restored.task_id, "job-d")
      assert_eq(restored.status, @rp.TaskStatus::Done)
      assert_eq(restored.checksum, env.checksum)
      assert_eq(restored.error, Some("none"))
    }
  }
}

///|
test "envelope: from_dict 缺 checksum 自动重算（vools __post_init__ 语义）" {
  let dict = @json.parse(
    "{\"task_id\":\"job-x\",\"status\":\"pending\",\"payload\":{},\"side\":\"requester\",\"version\":1}",
  ) catch {
    _ => fail("dict 解析失败")
  }
  match @rp.Envelope::from_dict(dict) {
    Err(e) => fail("from_dict 失败: \{e}")
    Ok(env) => {
      assert_true(env.checksum.has_prefix("sha256:"))
      assert_eq(env.checksum, env.compute_checksum())
    }
  }
}

///|
test "envelope: 未知字段参与 checksum（与 Python pop+re-dump 口径一致）" {
  // 带一个未知字段 extra，并给出覆盖 extra 的合法 checksum
  let body = "{\"extra\": \"keep-me\", \"payload\": {}, \"side\": \"requester\", \"status\": \"pending\", \"task_id\": \"job-u\", \"v\": 1, \"version\": 1}"
  let cs = "sha256:" + @rp.sha256_hex_of_utf8(body)
  let raw = "{\"checksum\": \"\{cs}\", \"extra\": \"keep-me\", \"payload\": {}, \"side\": \"requester\", \"status\": \"pending\", \"task_id\": \"job-u\", \"v\": 1, \"version\": 1}"
  match @rp.Envelope::from_rhop_bytes(@rp.bytes_of_utf8(raw)) {
    Err(e) => fail("带未知字段但 checksum 正确时应通过: \{e}")
    Ok(env) => assert_eq(env.task_id, "job-u")
  }
  // 同样的字节但改掉 extra → checksum 不再匹配
  let raw_bad = raw.replace(old="keep-me", new="changed")
  match @rp.Envelope::from_rhop_bytes(@rp.bytes_of_utf8(raw_bad)) {
    Ok(_) => fail("未知字段被篡改应校验失败")
    Err(reason) => assert_true(reason.contains("checksum mismatch"))
  }
}

// ============================================================================
// qa fixture 对齐：test-suit/rhop_js/fixtures/vools_vectors.json → envelope 节
// 真实 vools-rhop 0.9.0 生成的 checksum 与 to_rhop_bytes 字节，逐字节比对。
// ============================================================================

///|
test "envelope: 消费 qa fixture · minimal_pending（checksum + 字节全等）" {
  let payload = @json.parse(
    "{\"cmd\": \"jump.probe\", \"ok\": true, \"\u{53c2}\u{6570}\": {\"\u{76ee}\u{6807}\": \"\u{6d4b}\u{8bd5}\u{673a}\", \"\u{91cd}\u{8bd5}\": 2}, \"\u{6570}\u{7ec4}\": [1, \"\u{4e8c}\", {\"\u{4e09}\": 3}], \"\u{7a7a}\": null}",
    preserve_number_repr=true,
  ) catch {
    _ => fail("payload 解析失败")
  }
  let env = @rp.Envelope::new_full(
    "task-001",
    @rp.TaskStatus::Pending,
    payload,
    @rp.Side::Requester,
    created_at="2026-10-27T11:00:00Z",
    updated_at="2026-10-27T11:00:00Z",
  )
  assert_eq(
    env.checksum,
    "sha256:248e08c31f172d69360aec041047471b46b8456e8630a6e720b34db1eee98f05",
  )
  let expected = "{\"checksum\": \"sha256:248e08c31f172d69360aec041047471b46b8456e8630a6e720b34db1eee98f05\", \"created_at\": \"2026-10-27T11:00:00Z\", \"error\": null, \"hops_seen\": [], \"payload\": {\"cmd\": \"jump.probe\", \"ok\": true, \"\u{53c2}\u{6570}\": {\"\u{76ee}\u{6807}\": \"\u{6d4b}\u{8bd5}\u{673a}\", \"\u{91cd}\u{8bd5}\": 2}, \"\u{6570}\u{7ec4}\": [1, \"\u{4e8c}\", {\"\u{4e09}\": 3}], \"\u{7a7a}\": null}, \"result\": null, \"side\": \"requester\", \"signature\": null, \"status\": \"pending\", \"task_id\": \"task-001\", \"updated_at\": \"2026-10-27T11:00:00Z\", \"v\": 1, \"version\": 1}"
  assert_eq(
    @rp.sha256_hex(env.to_rhop_bytes()),
    @rp.sha256_hex(@rp.bytes_of_utf8(expected)),
  )
  // fixture 的 integrity_verify = [true, ""]、checksum_match = true
  let (ok, reason) = @rp.integrity_verify_bytes(env.to_rhop_bytes())
  assert_true(ok)
  assert_eq(reason, "")
  assert_true(@rp.integrity_checksum_match(env))
  // fixture 的 to_rhop_bytes_utf8 能反向解析
  match @rp.Envelope::from_rhop_bytes(@rp.bytes_of_utf8(expected)) {
    Err(e) => fail("fixture 字节反序列化失败: \{e}")
    Ok(restored) => assert_eq(restored.checksum, env.checksum)
  }
}

///|
test "envelope: 消费 qa fixture · full_done（v3 + hops + 签名 + 中文）" {
  let payload = @json.parse(
    "{\"cmd\": \"echo\", \"\u{6587}\u{672c}\": \"\u{4e2d}\u{6587}\u{8f7d}\u{8377}\"}",
    preserve_number_repr=true,
  ) catch {
    _ => fail("payload")
  }
  let result = @json.parse(
    "{\"ok\": true, \"\u{6307}\u{6807}\": [1, 2, 3], \"\u{7ed3}\u{8bba}\": \"\u{5b8c}\u{6210}\"}",
    preserve_number_repr=true,
  ) catch {
    _ => fail("result")
  }
  let env = @rp.Envelope::new_full(
    "task-002",
    @rp.TaskStatus::Done,
    payload,
    @rp.Side::Executor,
    result~,
    version=3,
    created_at="2026-10-27T11:00:00Z",
    updated_at="2026-10-27T12:30:00Z",
    hops_seen=["requester", "executor"],
    signature="sha256:deadbeef",
  )
  assert_eq(
    env.checksum,
    "sha256:ce9a0b78795987da9845780059f460dbc182f716f480b82020f9848b94756c40",
  )
  let expected = "{\"checksum\": \"sha256:ce9a0b78795987da9845780059f460dbc182f716f480b82020f9848b94756c40\", \"created_at\": \"2026-10-27T11:00:00Z\", \"error\": null, \"hops_seen\": [\"requester\", \"executor\"], \"payload\": {\"cmd\": \"echo\", \"\u{6587}\u{672c}\": \"\u{4e2d}\u{6587}\u{8f7d}\u{8377}\"}, \"result\": {\"ok\": true, \"\u{6307}\u{6807}\": [1, 2, 3], \"\u{7ed3}\u{8bba}\": \"\u{5b8c}\u{6210}\"}, \"side\": \"executor\", \"signature\": \"sha256:deadbeef\", \"status\": \"done\", \"task_id\": \"task-002\", \"updated_at\": \"2026-10-27T12:30:00Z\", \"v\": 1, \"version\": 3}"
  assert_eq(
    @rp.sha256_hex(env.to_rhop_bytes()),
    @rp.sha256_hex(@rp.bytes_of_utf8(expected)),
  )
  let (ok, reason) = @rp.integrity_verify_bytes(env.to_rhop_bytes())
  assert_true(ok)
  assert_eq(reason, "")
  // to_dict 与 fixture 的 fields 一致（fields 里没有 v 键、有 checksum）
  match env.to_dict() {
    Object(fields) => {
      assert_eq(fields.get("v"), None)
      assert_eq(fields.get("version"), Some(Json::number(3.0)))
      assert_eq(fields.get("status"), Some(Json::string("done")))
      assert_eq(fields.get("side"), Some(Json::string("executor")))
    }
    _ => fail("to_dict 应为对象")
  }
}

///|
test "envelope: 消费 qa fixture · tampered_checksum 必须报 checksum mismatch" {
  let payload = @json.parse(
    "{\"cmd\": \"jump.probe\", \"ok\": true, \"\u{53c2}\u{6570}\": {\"\u{76ee}\u{6807}\": \"\u{6d4b}\u{8bd5}\u{673a}\", \"\u{91cd}\u{8bd5}\": 2}, \"\u{6570}\u{7ec4}\": [1, \"\u{4e8c}\", {\"\u{4e09}\": 3}], \"\u{7a7a}\": null}",
    preserve_number_repr=true,
  ) catch {
    _ => fail("payload")
  }
  let env = @rp.Envelope::new_full(
    "task-001",
    @rp.TaskStatus::Pending,
    payload,
    @rp.Side::Requester,
    created_at="2026-10-27T11:00:00Z",
    updated_at="2026-10-27T11:00:00Z",
  )
  let text = @rp.utf8_text(env.to_rhop_bytes())
  // 只改 checksum 的第一个 hex 字符（内容不动）
  let broken = text.replace(
    old="sha256:248e08c31f172d69360aec041047471b46b8456e8630a6e720b34db1eee98f05",
    new="sha256:348e08c31f172d69360aec041047471b46b8456e8630a6e720b34db1eee98f05",
  )
  match @rp.Envelope::from_rhop_bytes(@rp.bytes_of_utf8(broken)) {
    Ok(_) => fail("篡改 checksum 应失败")
    Err(reason) => assert_true(reason.contains("checksum mismatch"))
  }
  let (ok, reason) = @rp.integrity_verify_bytes(@rp.bytes_of_utf8(broken))
  assert_false(ok)
  assert_true(reason.contains("checksum mismatch"))
}

// ============================================================================
// C1 修复回归（PROTO-01 / PROTO-02）
//
// PROTO-01：`to_rhop_bytes` 每次序列化都按当前字段重算 checksum（vools
// `envelope.py:79-83` 同），不再把已失效的旧 checksum 原样写出去。
// PROTO-02：可选字段显式 `null` / 浮点 `version` 一律 `字段值非法`，
// 不静默改值（vools 保留 None/2.7，本实现用 Int/String/数组无法无损表达）。
// ============================================================================

///|
/// 由「去掉 checksum 的规范 JSON body」拼出合法的 .rhop 文本
/// （body 必须已是 canonical 形态：键升序、`", "` / `": "` 分隔）。
fn raw_with_checksum(body : String) -> String {
  "{\"checksum\": \"sha256:" +
  @rp.sha256_hex_of_utf8(body) +
  "\", " +
  body[1:].to_owned()
}

///|
test "envelope(PROTO-01): from_dict 带错 checksum → 写出时重算、自身可读回" {
  let dict = @json.parse(
    "{\"task_id\":\"job-fix\",\"status\":\"pending\",\"payload\":{},\"side\":\"requester\",\"checksum\":\"sha256:bad\"}",
  ) catch {
    _ => fail("dict 解析失败")
  }
  match @rp.Envelope::from_dict(dict) {
    Err(e) => fail("from_dict 不校验 checksum（vools 语义）: \{e}")
    Ok(env) => {
      // 语义保留：对象上的 checksum 仍是传入的旧值（供 checksum_match 判假）
      assert_eq(env.checksum, "sha256:bad")
      let bytes = env.to_rhop_bytes()
      let text = @rp.utf8_text(bytes)
      // 写出的字节必须用重算值，而不是旧的 "sha256:bad"
      assert_false(text.contains("sha256:bad"))
      assert_true(text.contains(env.compute_checksum()))
      match @rp.Envelope::from_rhop_bytes(bytes) {
        Err(e) => fail("重算后写出的字节应可读回: \{e}")
        Ok(restored) => {
          assert_eq(restored.checksum, env.compute_checksum())
          assert_eq(restored.task_id, "job-fix")
        }
      }
    }
  }
}

///|
test "envelope(PROTO-01): 缺可选键的文件 → 回写补默认值并重算、可读回" {
  // 只给必填 + v：缺 side/version/created_at/updated_at/hops_seen/result/error/signature
  let body = "{\"payload\": {}, \"side\": \"requester\", \"status\": \"pending\", \"task_id\": \"job-m\", \"v\": 1}"
  let raw = raw_with_checksum(body)
  match @rp.Envelope::from_rhop_bytes(@rp.bytes_of_utf8(raw)) {
    Err(e) => fail("缺可选键应被接受（与 Python 同）: \{e}")
    Ok(env) => {
      assert_eq(env.version, 1) // 补默认值
      assert_eq(env.hops_seen.length(), 0)
      let bytes = env.to_rhop_bytes()
      let text = @rp.utf8_text(bytes)
      // 文件的旧 checksum 是对「缺键 body」算的，回写后必须变成对补全后的 body 算的
      assert_false(text.contains("sha256:" + @rp.sha256_hex_of_utf8(body)))
      assert_true(text.contains(env.compute_checksum()))
      match @rp.Envelope::from_rhop_bytes(bytes) {
        Err(e) => fail("回写后应能读回: \{e}")
        Ok(restored) => {
          assert_eq(restored.checksum, env.compute_checksum())
          assert_eq(restored.version, 1)
        }
      }
    }
  }
}

///|
test "envelope(PROTO-01): 原地改 hops_seen / payload 后 to_rhop_bytes 重算" {
  let env = make_env("job-mut", @rp.TaskStatus::Pending)
  let stale = env.checksum
  env.hops_seen.push("requester")
  match env.payload {
    Object(members) => members["injected"] = Json::string("yes")
    _ => fail("payload 应为对象")
  }
  // 字段是 String，原地改集合不会同步 checksum
  assert_eq(env.checksum, stale)
  let bytes = env.to_rhop_bytes()
  let text = @rp.utf8_text(bytes)
  assert_true(text.contains("\"injected\""))
  assert_true(text.contains(env.compute_checksum()))
  assert_false(text.contains(stale))
  match @rp.Envelope::from_rhop_bytes(bytes) {
    Err(e) => fail("原地修改后回写应可读回: \{e}")
    Ok(restored) => {
      assert_eq(restored.hops_seen, ["requester"])
      assert_eq(
        @rp.canonical_json(restored.payload),
        @rp.canonical_json(env.payload),
      )
    }
  }
}

///|
test "envelope(PROTO-01): 含未知字段 → 回写丢弃未知字段并重算、可读回" {
  let body = "{\"extra\": \"keep-me\", \"payload\": {}, \"side\": \"requester\", \"status\": \"pending\", \"task_id\": \"job-u\", \"v\": 1}"
  let raw = raw_with_checksum(body)
  match @rp.Envelope::from_rhop_bytes(@rp.bytes_of_utf8(raw)) {
    Err(e) => fail("未知字段参与校验，checksum 正确应通过: \{e}")
    Ok(env) => {
      let bytes = env.to_rhop_bytes()
      let text = @rp.utf8_text(bytes)
      assert_false(text.contains("\"extra\"")) // 未知字段被丢弃（vools 同）
      match @rp.Envelope::from_rhop_bytes(bytes) {
        Err(e) =>
          fail("丢弃未知字段后 checksum 必须重算、可读回: \{e}")
        Ok(restored) => assert_eq(restored.task_id, "job-u")
      }
    }
  }
}

///|
test "envelope(PROTO-02): 可选字段显式 null / 浮点 version → 字段值非法（不静默改值）" {
  let cases : Array[(String, String, String)] = [
    (
      "side:null", "{\"payload\": {}, \"side\": null, \"status\": \"pending\", \"task_id\": \"x\", \"v\": 1}",
      "None is not a valid Side",
    ),
    (
      "version:null", "{\"payload\": {}, \"status\": \"pending\", \"task_id\": \"x\", \"version\": null}",
      "version 不能为 null",
    ),
    (
      "version:2.7", "{\"payload\": {}, \"status\": \"pending\", \"task_id\": \"x\", \"version\": 2.7}",
      "version 必须是整数",
    ),
    (
      "created_at:null", "{\"created_at\": null, \"payload\": {}, \"status\": \"pending\", \"task_id\": \"x\"}",
      "created_at 不能为 null",
    ),
    (
      "updated_at:null", "{\"payload\": {}, \"status\": \"pending\", \"task_id\": \"x\", \"updated_at\": null}",
      "updated_at 不能为 null",
    ),
    (
      "hops_seen:null", "{\"hops_seen\": null, \"payload\": {}, \"status\": \"pending\", \"task_id\": \"x\"}",
      "hops_seen 不能为 null",
    ),
  ]
  for case in cases {
    let (label, body, needle) = case
    let dict = @json.parse(body) catch { _ => fail("解析失败: \{label}") }
    match @rp.Envelope::from_dict(dict) {
      Ok(env) =>
        fail(
          "\{label} 应被拒绝，却得到 version=\{env.version} side=\{env.side.to_string()}",
        )
      Err(reason) => {
        assert_true(reason.contains("字段值非法"))
        assert_true(reason.contains(needle))
      }
    }
  }
  // from_rhop_bytes 同一解析路径：checksum 正确也必须拒绝
  let raw = raw_with_checksum(
    "{\"payload\": {}, \"side\": null, \"status\": \"pending\", \"task_id\": \"job-null\", \"v\": 1}",
  )
  match @rp.Envelope::from_rhop_bytes(@rp.bytes_of_utf8(raw)) {
    Ok(_) => fail("side:null 应被拒绝（vools: None is not a valid Side）")
    Err(reason) => assert_true(reason.contains("None is not a valid Side"))
  }
}

// ============================================================================
// C2 资源审计回归
// ============================================================================

///|
test "envelope: hops_seen 防御性复制（外部 push 不影响已封信封）" {
  let arr : Array[String] = ["requester"]
  let env = @rp.Envelope::new_full(
    "c2-hops",
    @rp.TaskStatus::Running,
    @json.parse("{}") catch {
      _ => Json::null()
    },
    @rp.Side::Requester,
    hops_seen=arr,
  )
  let sealed_ = env.checksum
  arr.push("executor")
  // 信封内的数组是副本：仍是 1 条，且 checksum 与内容自洽
  assert_eq(env.hops_seen.length(), 1)
  assert_eq(env.hops_seen, ["requester"])
  assert_eq(env.checksum, sealed_)
  assert_eq(env.checksum, env.compute_checksum())
  // with_hops_seen 同样复制
  let arr2 : Array[String] = ["a"]
  let next = env.with_hops_seen(arr2)
  arr2.push("b")
  assert_eq(next.hops_seen.length(), 1)
  assert_eq(next.checksum, next.compute_checksum())
}

///|
test "envelope: MAX_ENVELOPE_NESTING_DEPTH 常量与读写深度边界" {
  assert_eq(@rp.MAX_ENVELOPE_NESTING_DEPTH, 1000)
  // 深度 300（远小于上限）：写→读往返成功
  let nested = {
    let mut v : Json = Json::null()
    let mut i = 0
    while i < 300 {
      v = Json::array([v])
      i = i + 1
    }
    v
  }
  let env = @rp.Envelope::new(
    "depth-300",
    @rp.TaskStatus::Pending,
    nested,
    @rp.Side::Requester,
  )
  match @rp.Envelope::from_rhop_bytes(env.to_rhop_bytes()) {
    Err(e) => fail("深度 300 应可往返: \{e}")
    Ok(restored) => assert_eq(restored.task_id, "depth-300")
  }
  // 深度 2000（超过上限）：写成功、读得可诊断 Err（已知不对称，固定行为）
  let deep = {
    let mut v : Json = Json::null()
    let mut i = 0
    while i < 2000 {
      v = Json::array([v])
      i = i + 1
    }
    v
  }
  let deep_env = @rp.Envelope::new(
    "depth-2000",
    @rp.TaskStatus::Pending,
    deep,
    @rp.Side::Requester,
  )
  let raw = deep_env.to_rhop_bytes()
  assert_true(raw.length() > 0)
  match @rp.Envelope::from_rhop_bytes(raw) {
    Ok(_) =>
      fail(
        "超过 MAX_ENVELOPE_NESTING_DEPTH 应返回 Err（已知不对称）",
      )
    Err(reason) =>
      assert_true(
        reason.contains("Depth limit") || reason.contains("解析失败"),
      )
  }
}