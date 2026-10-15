// ============================================================================
// trigger_test —— TriggerRegistry 黑盒测试（仅使用公共 API）
// 覆盖：精确/单段通配/多段通配匹配、priority 排序、once 自动注销、
//       condition 过滤、幂等 key 去重、unregister / clear / trigger_count、
//       fire 后 once 行为验证。
// 运行：moon test --target js
// ============================================================================

///|
test "精确匹配：仅命中同名事件" {
  let reg : @rx.TriggerRegistry[Int] = @rx.TriggerRegistry::new()
  let fired = Ref::Ref(Array::new())
  let _ = reg.register("task.done", fn(ev : @rx.TriggerEvent[Int]) {
    fired.val.push(ev.payload)
  })
  reg.fire("task.done", 1)
  reg.fire("task.fail", 2)
  assert_eq(fired.val, [1])
}

///|
test "单段通配：task.* 命中 task.done / task.fail，不命中多段 task.a.b" {
  let reg : @rx.TriggerRegistry[Int] = @rx.TriggerRegistry::new()
  let fired = Ref::Ref(Array::new())
  let _ = reg.register("task.*", fn(ev : @rx.TriggerEvent[Int]) {
    fired.val.push(ev.name)
  })
  reg.fire("task.done", 1)
  reg.fire("task.fail", 2)
  reg.fire("task.a.b", 3)
  assert_eq(fired.val, ["task.done", "task.fail"])
}

///|
test "多段通配：task.** 命中任意 task. 前缀的多段事件" {
  let reg : @rx.TriggerRegistry[Int] = @rx.TriggerRegistry::new()
  let fired = Ref::Ref(Array::new())
  let _ = reg.register("task.**", fn(ev : @rx.TriggerEvent[Int]) {
    fired.val.push(ev.name)
  })
  reg.fire("task.done", 1)
  reg.fire("task.a.b.c", 2)
  reg.fire("other.event", 3)
  assert_eq(fired.val, ["task.done", "task.a.b.c"])
}

///|
test "priority：高优先先执行，同优先按注册序" {
  let reg : @rx.TriggerRegistry[Int] = @rx.TriggerRegistry::new()
  let order = Ref::Ref(Array::new())
  let _ = reg.register_with(
    "evt",
    fn(ev : @rx.TriggerEvent[Int]) { order.val.push(1) },
    priority=10,
  )
  let _ = reg.register_with(
    "evt",
    fn(ev : @rx.TriggerEvent[Int]) { order.val.push(2) },
    priority=30,
  )
  let _ = reg.register_with(
    "evt",
    fn(ev : @rx.TriggerEvent[Int]) { order.val.push(3) },
    priority=20,
  )
  reg.fire("evt", 0)
  assert_eq(order.val, [2, 3, 1])
}

///|
test "once：触发一次后自动注销，再次 fire 不再执行" {
  let reg : @rx.TriggerRegistry[Int] = @rx.TriggerRegistry::new()
  let fired = Ref::Ref(0)
  let _ = reg.register_with(
    "once.evt",
    fn(ev : @rx.TriggerEvent[Int]) { fired.val = fired.val + 1 },
    once=true,
  )
  reg.fire("once.evt", 1)
  reg.fire("once.evt", 2)
  reg.fire("once.evt", 3)
  assert_eq(fired.val, 1)
  assert_eq(reg.trigger_count(), 0)
}

///|
test "condition：条件不满足则不执行" {
  let reg : @rx.TriggerRegistry[Int] = @rx.TriggerRegistry::new()
  let fired = Ref::Ref(Array::new())
  let _ = reg.register_with(
    "data",
    fn(ev : @rx.TriggerEvent[Int]) { fired.val.push(ev.payload) },
    condition=Some(fn(ev : @rx.TriggerEvent[Int]) { ev.payload > 0 }),
  )
  reg.fire("data", -1)
  reg.fire("data", 0)
  reg.fire("data", 5)
  assert_eq(fired.val, [5])
}

///|
test "fire_with_key：同 key 只触发一次，不同 key 各自触发" {
  let reg : @rx.TriggerRegistry[Int] = @rx.TriggerRegistry::new()
  let fired = Ref::Ref(0)
  let _ = reg.register("dup", fn(ev : @rx.TriggerEvent[Int]) {
    fired.val = fired.val + 1
  })
  reg.fire_with_key("dup", 1, "k1")
  reg.fire_with_key("dup", 2, "k1")
  reg.fire_with_key("dup", 3, "k2")
  assert_eq(fired.val, 2)
}

///|
test "unregister：注销后不再触发，重复注销返回 false" {
  let reg : @rx.TriggerRegistry[Int] = @rx.TriggerRegistry::new()
  let fired = Ref::Ref(0)
  let id = reg.register("evt", fn(ev : @rx.TriggerEvent[Int]) {
    fired.val = fired.val + 1
  })
  assert_true(reg.unregister(id))
  assert_eq(reg.unregister(id), false)
  assert_eq(reg.trigger_count(), 0)
  reg.fire("evt", 1)
  assert_eq(fired.val, 0)
}

///|
test "clear：清空触发器与幂等键，后续 fire 无效果" {
  let reg : @rx.TriggerRegistry[Int] = @rx.TriggerRegistry::new()
  let fired = Ref::Ref(0)
  let _ = reg.register("evt", fn(ev : @rx.TriggerEvent[Int]) {
    fired.val = fired.val + 1
  })
  reg.fire_with_key("evt", 1, "dup")
  assert_eq(fired.val, 1)
  reg.clear()
  assert_eq(reg.trigger_count(), 0)
  reg.fire("evt", 1)
  reg.fire_with_key("evt", 2, "dup")
  assert_eq(fired.val, 1)
}

///|
test "trigger_count / has_trigger：注册与注销后数量与匹配状态正确" {
  let reg : @rx.TriggerRegistry[Int] = @rx.TriggerRegistry::new()
  assert_eq(reg.trigger_count(), 0)
  assert_false(reg.has_trigger("task.done"))
  let _ = reg.register("task.done", fn(ev : @rx.TriggerEvent[Int]) {
    ignore(ev.payload)
  })
  let _ = reg.register("task.*", fn(ev : @rx.TriggerEvent[Int]) {
    ignore(ev.payload)
  })
  assert_eq(reg.trigger_count(), 2)
  assert_true(reg.has_trigger("task.done"))
  assert_true(reg.has_trigger("task.fail"))
  assert_false(reg.has_trigger("other.done"))
  assert_false(reg.has_trigger("task.a.b"))
}

///|
test "fire_at：事件携带指定时刻与自增序号" {
  let reg : @rx.TriggerRegistry[Int] = @rx.TriggerRegistry::new()
  let times = Ref::Ref(Array::new())
  let ids = Ref::Ref(Array::new())
  let _ = reg.register("ts", fn(ev : @rx.TriggerEvent[Int]) {
    times.val.push(ev.at)
    ids.val.push(ev.id)
  })
  reg.fire_at("ts", 1, 100L)
  reg.fire_at("ts", 2, 200L)
  assert_eq(times.val, [100L, 200L])
  assert_eq(ids.val, [1L, 2L])
}
