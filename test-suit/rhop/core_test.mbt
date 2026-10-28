// ============================================================================
// rhop · core 单元测试（跨目标）：Side + TaskStatus 状态机
//
// 对齐 vools `tests/test_core.py`，并额外覆盖 6×6 全流转矩阵（契约要求的
// 「状态流转全矩阵」）与非法字面量边界。
// ============================================================================

///|
test "core: Side 字面量与 vools core.py 一致（小写）" {
  assert_eq(@rp.Side::Requester.to_string(), "requester")
  assert_eq(@rp.Side::Executor.to_string(), "executor")
}

///|
test "core: Side::other 对端互指" {
  assert_eq(@rp.Side::Requester.other(), @rp.Side::Executor)
  assert_eq(@rp.Side::Executor.other(), @rp.Side::Requester)
  // 两次取对端回到自身（对合性）
  assert_eq(@rp.Side::Requester.other().other(), @rp.Side::Requester)
}

///|
test "core: Side::parse 往返与非法输入" {
  for side in [@rp.Side::Requester, @rp.Side::Executor] {
    match @rp.Side::parse(side.to_string()) {
      Ok(parsed) => assert_eq(parsed, side)
      Err(e) => fail("解析失败: \{e}")
    }
  }
  // 边界：空串 / 大小写不符 / 中文，都必须 Err
  for bad in ["", "Requester", "REQUESTER", "executor ", "任务端"] {
    match @rp.Side::parse(bad) {
      Ok(_) => fail("非法字面量 \"\{bad}\" 应解析失败")
      Err(_) => ()
    }
  }
}

///|
test "core: TaskStatus 字面量与 vools core.py 一致（小写）" {
  assert_eq(@rp.TaskStatus::Pending.to_string(), "pending")
  assert_eq(@rp.TaskStatus::Claimed.to_string(), "claimed")
  assert_eq(@rp.TaskStatus::Running.to_string(), "running")
  assert_eq(@rp.TaskStatus::Done.to_string(), "done")
  assert_eq(@rp.TaskStatus::Failed.to_string(), "failed")
  assert_eq(@rp.TaskStatus::Cancelled.to_string(), "cancelled")
}

///|
test "core: TaskStatus::parse 六态往返与非法输入" {
  assert_eq(@rp.TaskStatus::all().length(), 6)
  for status in @rp.TaskStatus::all() {
    match @rp.TaskStatus::parse(status.to_string()) {
      Ok(parsed) => assert_eq(parsed, status)
      Err(e) => fail("解析失败: \{e}")
    }
  }
  for bad in ["", "PENDING", "done ", "archived", "取消"] {
    match @rp.TaskStatus::parse(bad) {
      Ok(_) => fail("非法字面量 \"\{bad}\" 应解析失败")
      Err(_) => ()
    }
  }
}

///|
test "core: 流转表逐条照抄 core.py" {
  // PENDING → {CLAIMED, CANCELLED}
  assert_true(@rp.TaskStatus::Pending.can_transition(@rp.TaskStatus::Claimed))
  assert_true(@rp.TaskStatus::Pending.can_transition(@rp.TaskStatus::Cancelled))
  // CLAIMED → {RUNNING, CANCELLED}
  assert_true(@rp.TaskStatus::Claimed.can_transition(@rp.TaskStatus::Running))
  assert_true(@rp.TaskStatus::Claimed.can_transition(@rp.TaskStatus::Cancelled))
  // RUNNING → {DONE, FAILED}
  assert_true(@rp.TaskStatus::Running.can_transition(@rp.TaskStatus::Done))
  assert_true(@rp.TaskStatus::Running.can_transition(@rp.TaskStatus::Failed))
}

///|
test "core: 非法跳转一律 false（不能越级/回退/自环）" {
  // 越级
  assert_false(@rp.TaskStatus::Pending.can_transition(@rp.TaskStatus::Running))
  assert_false(@rp.TaskStatus::Pending.can_transition(@rp.TaskStatus::Done))
  assert_false(@rp.TaskStatus::Pending.can_transition(@rp.TaskStatus::Failed))
  assert_false(@rp.TaskStatus::Claimed.can_transition(@rp.TaskStatus::Done))
  // 回退
  assert_false(@rp.TaskStatus::Claimed.can_transition(@rp.TaskStatus::Pending))
  assert_false(@rp.TaskStatus::Running.can_transition(@rp.TaskStatus::Claimed))
  // 终态不允许任何出边
  assert_false(@rp.TaskStatus::Done.can_transition(@rp.TaskStatus::Running))
  assert_false(@rp.TaskStatus::Failed.can_transition(@rp.TaskStatus::Running))
  assert_false(
    @rp.TaskStatus::Cancelled.can_transition(@rp.TaskStatus::Pending),
  )
}

///|
test "core: 6×6 全流转矩阵（合法边恰为 6 条）" {
  // 期望的合法边集合（与 core.py `_TRANSITIONS` 逐条对应）
  let allow : Array[(String, String)] = [
    ("pending", "claimed"),
    ("pending", "cancelled"),
    ("claimed", "running"),
    ("claimed", "cancelled"),
    ("running", "done"),
    ("running", "failed"),
  ]
  let statuses = @rp.TaskStatus::all()
  let mut legal_count = 0
  for from in statuses {
    for to in statuses {
      let got = from.can_transition(to)
      let mut want = false
      for edge in allow {
        if edge.0 == from.to_string() && edge.1 == to.to_string() {
          want = true
        }
      }
      if got != want {
        let msg = "流转判定不符: \{from.to_string()} → \{to.to_string()}（期望 \{want}，实际 \{got}）"
        fail(msg)
      }
      if got {
        legal_count = legal_count + 1
      }
    }
  }
  assert_eq(legal_count, 6)
  // 36 个组合里，6 条合法、30 条非法
  assert_eq(36 - legal_count, 30)
}

///|
test "core: 终态判定 only Done/Failed/Cancelled" {
  assert_true(@rp.TaskStatus::Done.is_terminal())
  assert_true(@rp.TaskStatus::Failed.is_terminal())
  assert_true(@rp.TaskStatus::Cancelled.is_terminal())
  assert_false(@rp.TaskStatus::Pending.is_terminal())
  assert_false(@rp.TaskStatus::Claimed.is_terminal())
  assert_false(@rp.TaskStatus::Running.is_terminal())
  // 不变式：is_terminal ⇔ 无任何合法出边
  for status in @rp.TaskStatus::all() {
    let mut has_edge = false
    for next in @rp.TaskStatus::all() {
      if status.can_transition(next) {
        has_edge = true
      }
    }
    assert_eq(status.is_terminal(), !has_edge)
  }
}

///|
test "core: all() 顺序与 vools 声明顺序一致" {
  let names : Array[String] = []
  for status in @rp.TaskStatus::all() {
    names.push(status.to_string())
  }
  assert_eq(names, [
    "pending", "claimed", "running", "done", "failed", "cancelled",
  ])
}
