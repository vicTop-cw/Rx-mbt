// ============================================================================
// rhop_task · 模型层测试（纯逻辑，wasm / js / native 三目标通用）
//
// 覆盖：
//   1. TaskState：字面量 / 大小写归一 / 非法值 Err / 分类谓词
//   2. TaskState 全 7×7 流转矩阵（逐条对照 vools _TRANSITIONS）
//   3. 与 rhop.TaskStatus 的桥接（含 RETRY_PENDING 的信息差）
//   4. 时间：format_epoch_seconds 已知向量 / parse_iso 五种写法 / 坏 ISO / 加减秒
//   5. TaskRecord：默认值 / validate 边界 / to_dict-from_dict 往返与容错
//   6. DAG：正常链拓扑序 / 重名 / 自依赖 / 缺依赖 / 成环 / 确定性
// ============================================================================

// ---------------------------------------------------------------------------
// 1. TaskState 基础
// ---------------------------------------------------------------------------

///|
test "models · TaskState 字面量（大写，落库/JSON 形态）" {
  assert_eq(@rt.TaskState::Pending.to_string(), "PENDING")
  assert_eq(@rt.TaskState::Locked.to_string(), "LOCKED")
  assert_eq(@rt.TaskState::Running.to_string(), "RUNNING")
  assert_eq(@rt.TaskState::Completed.to_string(), "COMPLETED")
  assert_eq(@rt.TaskState::Failed.to_string(), "FAILED")
  assert_eq(@rt.TaskState::RetryPending.to_string(), "RETRY_PENDING")
  assert_eq(@rt.TaskState::Cancelled.to_string(), "CANCELLED")
  // 全量集合 7 个
  assert_eq(@rt.task_state_all().length(), 7)
}

///|
test "models · TaskState::parse 大小写不敏感 + 非法值可诊断 Err" {
  assert_eq(@rt.TaskState::parse("pending"), Ok(@rt.TaskState::Pending))
  assert_eq(@rt.TaskState::parse("  Running "), Ok(@rt.TaskState::Running))
  assert_eq(
    @rt.TaskState::parse("retry_pending"),
    Ok(@rt.TaskState::RetryPending),
  )
  match @rt.TaskState::parse("DONE") {
    Err(e) => {
      assert_true(e.contains("未知任务状态"))
      assert_true(e.contains("PENDING"))
    }
    Ok(_) => fail("DONE 不是队列层状态（是协议层字面量），应当 Err")
  }
  match @rt.TaskState::parse("") {
    Err(e) => assert_true(e.contains("未知任务状态"))
    Ok(_) => fail("空串应当 Err")
  }
  assert_true(@rt.TaskState::is_valid("cancelled"))
  assert_false(@rt.TaskState::is_valid("bogus"))
}

///|
test "models · TaskState 分类谓词（终态/活跃/可领取）" {
  assert_true(@rt.TaskState::Completed.is_terminal())
  assert_true(@rt.TaskState::Failed.is_terminal())
  assert_true(@rt.TaskState::Cancelled.is_terminal())
  assert_false(@rt.TaskState::Pending.is_terminal())
  assert_false(@rt.TaskState::Locked.is_terminal())
  assert_false(@rt.TaskState::Running.is_terminal())
  assert_false(@rt.TaskState::RetryPending.is_terminal())

  assert_true(@rt.TaskState::Pending.is_active())
  assert_true(@rt.TaskState::RetryPending.is_active())
  assert_false(@rt.TaskState::Cancelled.is_active())

  assert_true(@rt.TaskState::Pending.is_claimable())
  assert_true(@rt.TaskState::RetryPending.is_claimable())
  assert_false(@rt.TaskState::Locked.is_claimable())
  assert_false(@rt.TaskState::Running.is_claimable())
}

// ---------------------------------------------------------------------------
// 2. 流转矩阵（7×7 全组合）
// ---------------------------------------------------------------------------

///|
test "models · TaskState 流转矩阵：合法边逐条对齐 vools _TRANSITIONS" {
  // PENDING → {LOCKED, CANCELLED}
  assert_true(@rt.TaskState::Pending.can_transition(@rt.TaskState::Locked))
  assert_true(@rt.TaskState::Pending.can_transition(@rt.TaskState::Cancelled))
  // LOCKED → {RUNNING, PENDING, CANCELLED}
  assert_true(@rt.TaskState::Locked.can_transition(@rt.TaskState::Running))
  assert_true(@rt.TaskState::Locked.can_transition(@rt.TaskState::Pending))
  assert_true(@rt.TaskState::Locked.can_transition(@rt.TaskState::Cancelled))
  // RUNNING → {COMPLETED, FAILED, RETRY_PENDING, CANCELLED}
  assert_true(@rt.TaskState::Running.can_transition(@rt.TaskState::Completed))
  assert_true(@rt.TaskState::Running.can_transition(@rt.TaskState::Failed))
  assert_true(@rt.TaskState::Running.can_transition(@rt.TaskState::RetryPending))
  assert_true(@rt.TaskState::Running.can_transition(@rt.TaskState::Cancelled))
  // RETRY_PENDING → {LOCKED, CANCELLED}
  assert_true(@rt.TaskState::RetryPending.can_transition(@rt.TaskState::Locked))
  assert_true(
    @rt.TaskState::RetryPending.can_transition(@rt.TaskState::Cancelled),
  )
}

///|
test "models · TaskState 流转矩阵：其余 41 条边全部非法（全组合穷举）" {
  let all = @rt.task_state_all()
  // 合法边集合（与上面逐条断言的集合一致）
  let legal : Array[(String, String)] = [
    ("PENDING", "LOCKED"), ("PENDING", "CANCELLED"), ("LOCKED", "RUNNING"),
    ("LOCKED", "PENDING"), ("LOCKED", "CANCELLED"), ("RUNNING", "COMPLETED"),
    ("RUNNING", "FAILED"), ("RUNNING", "RETRY_PENDING"),
    ("RUNNING", "CANCELLED"), ("RETRY_PENDING", "LOCKED"),
    ("RETRY_PENDING", "CANCELLED"),
  ]
  let mut legal_count = 0
  for from_s in all {
    for to_s in all {
      let key = (from_s.to_string(), to_s.to_string())
      let expected = legal.contains(key)
      let actual = from_s.can_transition(to_s)
      if expected != actual {
        fail("流转 \{key.0} -> \{key.1} 期望 \{expected}，实得 \{actual}")
      }
      if actual {
        legal_count = legal_count + 1
      }
    }
  }
  assert_eq(legal_count, 11)
  // 终态不可流转（含自环）
  for t in [@rt.TaskState::Completed, @rt.TaskState::Failed, @rt.TaskState::Cancelled] {
    for to_s in all {
      assert_false(t.can_transition(to_s))
    }
  }
}

// ---------------------------------------------------------------------------
// 3. 与 rhop.TaskStatus 的桥接
// ---------------------------------------------------------------------------

///|
test "models · 桥接 rhop.TaskStatus：7 态映射与协议字面量" {
  assert_eq(
    @rt.TaskState::Pending.to_status().to_string(),
    "pending",
  )
  assert_eq(@rt.TaskState::Locked.to_status().to_string(), "claimed")
  assert_eq(@rt.TaskState::Running.to_status().to_string(), "running")
  assert_eq(@rt.TaskState::Completed.to_status().to_string(), "done")
  assert_eq(@rt.TaskState::Failed.to_status().to_string(), "failed")
  assert_eq(@rt.TaskState::Cancelled.to_status().to_string(), "cancelled")
  // RETRY_PENDING 在协议层无对应态 → 归入 pending（文档化的信息差）
  assert_eq(@rt.TaskState::RetryPending.to_status().to_string(), "pending")
  // 反向
  assert_eq(
    @rt.TaskState::from_status(@rp.TaskStatus::Claimed),
    @rt.TaskState::Locked,
  )
  assert_eq(
    @rt.TaskState::from_status(@rp.TaskStatus::Done),
    @rt.TaskState::Completed,
  )
}

///|
test "models · 桥接往返：除 RETRY_PENDING 外应精确回到原状态" {
  for s in @rt.task_state_all() {
    let back = @rt.TaskState::from_status(s.to_status())
    if s == @rt.TaskState::RetryPending {
      // 显式声明：协议层无 RETRY_PENDING，桥接后只能回到 Pending
      assert_eq(back, @rt.TaskState::Pending)
      assert_false(s.status_roundtrip_exact())
    } else {
      assert_eq(back, s)
      assert_true(s.status_roundtrip_exact())
    }
  }
}

// ---------------------------------------------------------------------------
// 4. 时间辅助
// ---------------------------------------------------------------------------

///|
test "models · format_epoch_seconds 已知向量" {
  assert_eq(@rt.format_epoch_seconds(0L), "1970-01-01T00:00:00Z")
  assert_eq(@rt.format_epoch_seconds(1L), "1970-01-01T00:00:01Z")
  assert_eq(@rt.format_epoch_seconds(1700000000L), "2023-11-14T22:13:20Z")
  // 闰日（2024-02-29）
  assert_eq(@rt.format_epoch_seconds(1709164800L), "2024-02-29T00:00:00Z")
  // 负数（1970 之前）
  assert_eq(@rt.format_epoch_seconds(-1L), "1969-12-31T23:59:59Z")
}

///|
test "models · parse_iso 五种写法 + 坏 ISO 返回 None" {
  let expect = 1700000000L
  assert_eq(@rt.parse_iso("2023-11-14T22:13:20Z"), Some(expect))
  assert_eq(@rt.parse_iso("2023-11-14T22:13:20"), Some(expect))
  assert_eq(@rt.parse_iso("2023-11-14 22:13:20"), Some(expect))
  assert_eq(@rt.parse_iso("2023-11-14T22:13:20.500Z"), Some(expect))
  // 仅日期 → 当天 0 点
  assert_eq(@rt.parse_iso("2023-11-14"), Some(1699920000L))
  // epoch 数字文本
  assert_eq(@rt.parse_iso("1700000000"), Some(expect))
  assert_eq(@rt.parse_iso("1700000000.9"), Some(expect))
  // 空 / 坏输入
  assert_eq(@rt.parse_iso(""), None)
  assert_eq(@rt.parse_iso("   "), None)
  assert_eq(@rt.parse_iso("not-a-time"), None)
  assert_eq(@rt.parse_iso("2023-13-01T00:00:00Z"), None)
  assert_eq(@rt.parse_iso("2023-11-14T25:00:00Z"), None)
  assert_eq(@rt.parse_iso("2023-11"), None)
  // 归一
  assert_eq(@rt.to_iso("2023-11-14T22:13:20.500Z"), Some("2023-11-14T22:13:20Z"))
  assert_eq(@rt.to_iso("bogus"), None)
}

///|
test "models · iso_add_seconds 正负偏移与空基线的兜底" {
  assert_eq(
    @rt.iso_add_seconds("2023-11-14T22:13:20Z", 60.0),
    "2023-11-14T22:14:20Z",
  )
  assert_eq(
    @rt.iso_add_seconds("2023-11-14T22:13:20Z", -20.0),
    "2023-11-14T22:13:00Z",
  )
  // 跨天
  assert_eq(
    @rt.iso_add_seconds("2023-11-14T23:59:30Z", 60.0),
    "2023-11-15T00:00:30Z",
  )
  // 空基线 → 以当前时间兜底（结果必须能解析回来）
  let now = @rt.iso_add_seconds("", 0.0)
  assert_true(@rt.parse_iso(now) is Some(_))
}

///|
test "models · utcnow_iso 形状与单调性" {
  let t1 = @rt.utcnow_iso()
  assert_eq(t1.length(), 20)
  assert_true(t1.has_suffix("Z"))
  assert_true(t1.contains("T"))
  let parsed = @rt.parse_iso(t1)
  assert_true(parsed is Some(_))
  match parsed {
    Some(secs) =>
      // 与 now 的差值应在 5 秒内（避免时钟/实现偏差导致的假红）
      {
        let d = @rt.utcnow_seconds() - secs
        assert_true(d >= -5L && d <= 5L)
      }
    None => fail("utcnow_iso 解析失败")
  }
}

// ---------------------------------------------------------------------------
// 5. TaskRecord
// ---------------------------------------------------------------------------

///|
test "models · TaskRecord 默认值与 withers" {
  let r = @rt.TaskRecord::new(" task-1 ")
  // 默认值逐项对齐 vools __post_init__
  assert_eq(r.task_name, "task-1")
  assert_eq(r.task_type, "CLI")
  assert_eq(r.state, @rt.TaskState::Pending)
  assert_eq(r.priority, 0)
  assert_eq(r.timeout_min, 60.0)
  assert_eq(r.retry_delay_min, 5.0)
  assert_eq(r.retry_count, 0)
  assert_eq(r.max_retries, 3)
  assert_eq(r.version, 1)
  assert_false(r.cancel_requested)
  assert_eq(r.deps.length(), 0)
  assert_eq(r.tags.length(), 0)
  assert_eq(r.queue, "")
  // withers
  let r2 = r.with_type("SHELL").with_priority(7).with_max_retries(5).with_timeout_min(30.0).with_deps(["a", "b"]).with_tags(["t1"]).with_queue("q1").with_owner("alice")
  assert_eq(r2.task_type, "SHELL")
  assert_eq(r2.priority, 7)
  assert_eq(r2.max_retries, 5)
  assert_eq(r2.timeout_min, 30.0)
  assert_eq(r2.deps, ["a", "b"])
  assert_eq(r2.tags, ["t1"])
  assert_eq(r2.queue, "q1")
  assert_eq(r2.owner, "alice")
  // 原对象不受影响（值语义）
  assert_eq(r.task_type, "CLI")
  assert_eq(r.deps.length(), 0)
}

///|
test "models · TaskRecord::validate 边界（空 name / 负值 / retry 越界 / 空依赖）" {
  assert_eq(@rt.TaskRecord::new("ok").validate(), Ok(()))
  // 空 name
  match @rt.TaskRecord::new("").validate() {
    Err(e) => assert_true(e.contains("task_name 不能为空"))
    Ok(_) => fail("空 task_name 应当 Err")
  }
  match @rt.TaskRecord::new("   ").validate() {
    Err(e) => assert_true(e.contains("task_name 不能为空"))
    Ok(_) => fail("纯空白 task_name 应当 Err")
  }
  // 空 type
  match @rt.TaskRecord::new("a").with_type("").validate() {
    Err(e) => assert_true(e.contains("task_type 不能为空"))
    Ok(_) => fail("空 task_type 应当 Err")
  }
  // 非正超时
  match @rt.TaskRecord::new("a").with_timeout_min(0.0).validate() {
    Err(e) => assert_true(e.contains("timeout_min 必须为正"))
    Ok(_) => fail("timeout_min=0 应当 Err")
  }
  // retry_count > max_retries（直接构造越界记录）
  let bad = { ..@rt.TaskRecord::new("a"), retry_count: 5, max_retries: 3 }
  match bad.validate() {
    Err(e) => assert_true(e.contains("不能超过 max_retries"))
    Ok(_) => fail("retry_count 越界应当 Err")
  }
  // 依赖里含空名
  match @rt.TaskRecord::new("a").with_deps(["x", " "]).validate() {
    Err(e) => assert_true(e.contains("deps 里含空依赖名"))
    Ok(_) => fail("空依赖名应当 Err")
  }
}

///|
test "models · TaskRecord to_dict / from_dict 往返" {
  let r = @rt.TaskRecord::new("task-42").with_type("HTTP").with_priority(9).with_deps(["a", "b"]).with_tags(["x", "y"]).with_state(@rt.TaskState::Running).with_queue("q").with_owner("bob").with_scheduled_at(Some("2023-11-14T22:13:20Z"))
  let d = r.to_dict()
  let back = match @rt.TaskRecord::from_dict(d) {
    Ok(v) => v
    Err(e) => fail("to_dict → from_dict 失败: \{e}")
  }
  assert_eq(back.task_name, "task-42")
  assert_eq(back.task_type, "HTTP")
  assert_eq(back.priority, 9)
  assert_eq(back.deps, ["a", "b"])
  assert_eq(back.tags, ["x", "y"])
  assert_eq(back.state, @rt.TaskState::Running)
  assert_eq(back.queue, "q")
  assert_eq(back.owner, "bob")
  assert_eq(back.scheduled_at, Some("2023-11-14T22:13:20Z"))
  // JSON 文本往返
  let text = @rt.task_record_to_json_text(r)
  let back2 = match @rt.task_record_from_json_text(text) {
    Ok(v) => v
    Err(e) => fail("JSON 文本往返失败: \{e}")
  }
  assert_eq(back2.task_name, "task-42")
  assert_eq(back2.state, @rt.TaskState::Running)
}

///|
test "models · from_dict 容错（deps 为 JSON 文本 / 数字写成字符串 / 缺省字段）" {
  let j = @json.parse(
    "{\"task_name\":\"t1\",\"deps\":\"[\\\"a\\\",\\\"b\\\"]\",\"priority\":\"7\",\"max_retries\":\"2\",\"state\":\"locked\",\"cancel_requested\":1}",
  ) catch {
    _ => fail("测试 JSON 解析失败")
  }
  let r = match @rt.TaskRecord::from_dict(j) {
    Ok(v) => v
    Err(e) => fail("容错解析失败: \{e}")
  }
  assert_eq(r.deps, ["a", "b"])
  assert_eq(r.priority, 7)
  assert_eq(r.max_retries, 2)
  assert_eq(r.state, @rt.TaskState::Locked)
  assert_true(r.cancel_requested)
  // 缺省字段取默认
  let j2 = @json.parse("{\"task_name\":\"t2\"}") catch {
    _ => fail("x")
  }
  let r2 = match @rt.TaskRecord::from_dict(j2) {
    Ok(v) => v
    Err(e) => fail("缺省解析失败: \{e}")
  }
  assert_eq(r2.state, @rt.TaskState::Pending)
  assert_eq(r2.max_retries, 3)
  assert_eq(r2.timeout_min, 60.0)
}

///|
test "models · from_dict 错误路径（非对象 / 未知状态 / 类型不符）" {
  match @rt.TaskRecord::from_dict(Json::string("nope")) {
    Err(e) => assert_true(e.contains("需要 JSON 对象"))
    Ok(_) => fail("非对象应当 Err")
  }
  let bad_state = @json.parse("{\"task_name\":\"a\",\"state\":\"DONE\"}") catch {
    _ => fail("x")
  }
  match @rt.TaskRecord::from_dict(bad_state) {
    Err(e) => assert_true(e.contains("未知任务状态"))
    Ok(_) => fail("未知状态应当 Err")
  }
  let bad_type = @json.parse("{\"task_name\":\"a\",\"priority\":\"高\"}") catch {
    _ => fail("x")
  }
  match @rt.TaskRecord::from_dict(bad_type) {
    Err(e) => assert_true(e.contains("priority"))
    Ok(_) => fail("类型不符应当 Err 且点名字段")
  }
}

// ---------------------------------------------------------------------------
// 6. DAG
// ---------------------------------------------------------------------------

///|
/// 构造一条带依赖的记录。
fn rec(name : String, deps : Array[String]) -> @rt.TaskRecord {
  @rt.TaskRecord::new(name).with_deps(deps)
}

///|
test "models · DAG 正常链：依赖在前的确定性拓扑序" {
  let rs = [
    rec("c", ["b"]),
    rec("b", ["a"]),
    rec("a", []),
  ]
  assert_eq(@rt.validate_dag(rs), Ok(()))
  match @rt.topo_order(rs) {
    Ok(order) => assert_eq(order, ["a", "b", "c"])
    Err(e) => fail("拓扑排序失败: \{e}")
  }
  // 并列节点按名字排序（确定性）
  let rs2 = [rec("z", []), rec("m", []), rec("a", [])]
  match @rt.topo_order(rs2) {
    Ok(order) => assert_eq(order, ["a", "m", "z"])
    Err(e) => fail("并列节点排序失败: \{e}")
  }
}

///|
test "models · DAG 错误：重名 / 自依赖 / 缺依赖 / 成环" {
  // 重名
  match @rt.validate_dag([rec("a", []), rec("a", [])]) {
    Err(e) => assert_true(e.contains("任务名重复"))
    Ok(_) => fail("重名应当 Err")
  }
  // 自依赖
  match @rt.validate_dag([rec("a", ["a"])]) {
    Err(e) => assert_true(e.contains("依赖了自己"))
    Ok(_) => fail("自依赖应当 Err")
  }
  // 缺依赖
  match @rt.validate_dag([rec("a", ["ghost"])]) {
    Err(e) => assert_true(e.contains("缺依赖"))
    Ok(_) => fail("缺依赖应当 Err")
  }
  // 成环 a→b→c→a
  let cyclic = [rec("a", ["c"]), rec("b", ["a"]), rec("c", ["b"])]
  match @rt.validate_dag(cyclic) {
    Err(e) => {
      assert_true(e.contains("成环"))
      // 环上任务应被点名
      assert_true(e.contains("a"))
      assert_true(e.contains("b"))
      assert_true(e.contains("c"))
    }
    Ok(_) => fail("成环应当 Err")
  }
  // 空名参与 DAG
  match @rt.validate_dag([rec("", [])]) {
    Err(e) => assert_true(e.contains("task_name 为空"))
    Ok(_) => fail("空名应当 Err")
  }
}

///|
test "models · DAG 自依赖在 topo_order 单独调用时也判环" {
  // topo_order 不校验缺依赖/自依赖语义，只看能否排完：自环必然排不完
  match @rt.topo_order([rec("a", ["a"])]) {
    Err(e) => assert_true(e.contains("成环"))
    Ok(_) => fail("自环应当排不出")
  }
}

///|
test "models · task_columns 覆盖 31 列且 to_dict 键集合一致" {
  let cols = @rt.task_columns()
  assert_eq(cols.length(), 31)
  let d = @rt.TaskRecord::new("t").to_dict()
  match d {
    Object(m) => {
      assert_eq(m.length(), 31)
      for c in cols {
        if !m.contains(c) {
          fail("to_dict 缺列: \{c}")
        }
      }
    }
    _ => fail("to_dict 应返回对象")
  }
}
