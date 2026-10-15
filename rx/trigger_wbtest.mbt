// ============================================================================
// trigger_wbtest —— TriggerRegistry 白盒测试（可访问包内字段）
// 覆盖：fire 后触发器内部 fired_count 观测字段递增
// ============================================================================

///|
test "fired_count：fire 后内部计数器递增" {
  let reg : TriggerRegistry[Int] = TriggerRegistry::new()
  let id = reg.register("cnt", fn(ev : TriggerEvent[Int]) { ignore(ev.payload) })
  reg.fire("cnt", 1)
  reg.fire("cnt", 2)
  let mut fc = 0
  for t in reg.triggers.val {
    if t.id == id {
      fc = t.fired_count.val
    }
  }
  assert_eq(fc, 2)
}

///|
test "fired_count：condition 不满足不递增，once 注销后计数保留" {
  let reg : TriggerRegistry[Int] = TriggerRegistry::new()
  let id = reg.register_with(
    "cnt",
    fn(ev : TriggerEvent[Int]) { ignore(ev.payload) },
    condition=Some(fn(ev : TriggerEvent[Int]) { ev.payload > 0 }),
  )
  reg.fire("cnt", -1)
  let mut fc = 0
  for t in reg.triggers.val {
    if t.id == id {
      fc = t.fired_count.val
    }
  }
  assert_eq(fc, 0)
  reg.fire("cnt", 1)
  reg.fire("cnt", 2)
  fc = 0
  for t in reg.triggers.val {
    if t.id == id {
      fc = t.fired_count.val
    }
  }
  assert_eq(fc, 2)
}
