// ============================================================================
// event_bus_test —— EventBus / fire_real / 条件组合器黑盒测试（仅使用公共 API）
// 覆盖：EventBus glob 匹配、priority 排序、once 自动注销、条件过滤、
//       all_of / any_of / not_ 条件组合、fire_real 墙钟时刻、publish 指定 at
// 运行：moon test --target js
// ============================================================================

///|
test "EventBus glob 匹配：订阅 task.* 命中 task.done / task.fail，不命中多段 task.a.b" {
  let bus : @rx.EventBus[Int32] = @rx.EventBus::new()
  let fired = Ref::Ref(Array(capacity=0))
  let _ = bus.subscribe("task.*", fn(ev : @rx.TriggerEvent[Int32]) {
    fired.val.push(ev.name)
  })
  bus.publish("task.done", 1)
  bus.publish("task.fail", 2)
  bus.publish("task.a.b", 3)
  assert_eq(fired.val, ["task.done", "task.fail"])
}

///|
test "EventBus 多段通配：订阅 task.** 命中任意 task. 前缀的多段事件" {
  let bus : @rx.EventBus[Int32] = @rx.EventBus::new()
  let fired = Ref::Ref(Array(capacity=0))
  let _ = bus.subscribe("task.**", fn(ev : @rx.TriggerEvent[Int32]) {
    fired.val.push(ev.name)
  })
  bus.publish("task.done", 1)
  bus.publish("task.a.b.c", 2)
  bus.publish("other.event", 3)
  assert_eq(fired.val, ["task.done", "task.a.b.c"])
}

///|
test "EventBus priority：高优先级先执行，同优先级按订阅序" {
  let bus : @rx.EventBus[Int32] = @rx.EventBus::new()
  let order = Ref::Ref(Array(capacity=0))
  let _ = bus.subscribe(
    "evt",
    fn(_ : @rx.TriggerEvent[Int32]) { order.val.push(1) },
    priority=10,
  )
  let _ = bus.subscribe(
    "evt",
    fn(_ : @rx.TriggerEvent[Int32]) { order.val.push(2) },
    priority=30,
  )
  let _ = bus.subscribe(
    "evt",
    fn(_ : @rx.TriggerEvent[Int32]) { order.val.push(3) },
    priority=20,
  )
  bus.publish("evt", 0)
  assert_eq(order.val, [2, 3, 1])
}

///|
test "EventBus once：触发一次后自动注销，再 publish 不执行" {
  let bus : @rx.EventBus[Int32] = @rx.EventBus::new()
  let fired = Ref::Ref(0)
  let _ = bus.subscribe(
    "once.evt",
    fn(_ : @rx.TriggerEvent[Int32]) { fired.val = fired.val + 1 },
    once=true,
  )
  bus.publish("once.evt", 1)
  bus.publish("once.evt", 2)
  bus.publish("once.evt", 3)
  assert_eq(fired.val, 1)
}

///|
test "EventBus condition：条件不满足则不执行" {
  let bus : @rx.EventBus[Int32] = @rx.EventBus::new()
  let fired = Ref::Ref(Array(capacity=0))
  let _ = bus.subscribe(
    "data",
    fn(ev : @rx.TriggerEvent[Int32]) { fired.val.push(ev.payload) },
    condition=Some(fn(ev : @rx.TriggerEvent[Int32]) { ev.payload > 0 }),
  )
  bus.publish("data", -1)
  bus.publish("data", 0)
  bus.publish("data", 5)
  assert_eq(fired.val, [5])
}

///|
test "EventBus publish 指定 at：事件携带传入时刻" {
  let bus : @rx.EventBus[Int32] = @rx.EventBus::new()
  let times = Ref::Ref(Array(capacity=0))
  let _ = bus.subscribe("ts", fn(ev : @rx.TriggerEvent[Int32]) {
    times.val.push(ev.at)
  })
  bus.publish("ts", 1, at=100L)
  bus.publish("ts", 2, at=200L)
  assert_eq(times.val, [100L, 200L])
}

///|
test "fire_real：事件时刻取墙钟当前时间" {
  let reg : @rx.TriggerRegistry[Int32] = @rx.TriggerRegistry::new()
  let times = Ref::Ref(Array(capacity=0))
  let _ = reg.register("ts", fn(ev : @rx.TriggerEvent[Int32]) {
    times.val.push(ev.at)
  })
  // R1 后：real_now 未注入真实时钟时取默认虚拟时钟当前时刻（同步连续 fire 值相同）
  let t0 = @rx.real_now()
  reg.fire_real("ts", 1)
  reg.fire_real("ts", 2)
  assert_eq(times.val, [t0, t0])
}

///|
test "all_of：全部条件满足才为 true，任一不满足为 false" {
  let bus : @rx.EventBus[Int32] = @rx.EventBus::new()
  let fired = Ref::Ref(Array(capacity=0))
  let conds : Array[(@rx.TriggerEvent[Int32]) -> Bool] = [
    fn(ev : @rx.TriggerEvent[Int32]) { ev.payload > 0 },
    fn(ev : @rx.TriggerEvent[Int32]) { ev.payload % 2 == 0 },
  ]
  let combined = @rx.all_of(conds)
  let _ = bus.subscribe(
    "e",
    fn(ev : @rx.TriggerEvent[Int32]) { fired.val.push(ev.payload) },
    condition=Some(combined),
  )
  bus.publish("e", 4)
  bus.publish("e", 3)
  bus.publish("e", -2)
  assert_eq(fired.val, [4])
}

///|
test "any_of：任一条件满足即为 true，全部不满足为 false" {
  let bus : @rx.EventBus[Int32] = @rx.EventBus::new()
  let fired = Ref::Ref(Array(capacity=0))
  let conds : Array[(@rx.TriggerEvent[Int32]) -> Bool] = [
    fn(ev : @rx.TriggerEvent[Int32]) { ev.payload < 0 },
    fn(ev : @rx.TriggerEvent[Int32]) { ev.payload == 100 },
  ]
  let combined = @rx.any_of(conds)
  let _ = bus.subscribe(
    "e",
    fn(ev : @rx.TriggerEvent[Int32]) { fired.val.push(ev.payload) },
    condition=Some(combined),
  )
  bus.publish("e", -1)
  bus.publish("e", 100)
  bus.publish("e", 50)
  assert_eq(fired.val, [-1, 100])
}

///|
test "not_：对单个条件取反" {
  let bus : @rx.EventBus[Int32] = @rx.EventBus::new()
  let fired = Ref::Ref(Array(capacity=0))
  let not_positive = @rx.not_(fn(ev : @rx.TriggerEvent[Int32]) {
    ev.payload > 0
  })
  let _ = bus.subscribe(
    "e",
    fn(ev : @rx.TriggerEvent[Int32]) { fired.val.push(ev.payload) },
    condition=Some(not_positive),
  )
  bus.publish("e", 5)
  bus.publish("e", -5)
  assert_eq(fired.val, [-5])
}

///|
test "条件组合器接入 EventBus：all_of + not_ 复合条件过滤分发" {
  let bus : @rx.EventBus[Int32] = @rx.EventBus::new()
  let fired = Ref::Ref(Array(capacity=0))
  let in_range = @rx.all_of([
    fn(ev : @rx.TriggerEvent[Int32]) { ev.payload >= 10 },
    fn(ev : @rx.TriggerEvent[Int32]) { ev.payload <= 20 },
  ])
  let not_zero = @rx.not_(fn(ev : @rx.TriggerEvent[Int32]) { ev.payload == 0 })
  let _ = bus.subscribe(
    "range",
    fn(ev : @rx.TriggerEvent[Int32]) { fired.val.push(ev.payload) },
    condition=Some(@rx.all_of([in_range, not_zero])),
  )
  bus.publish("range", 0)
  bus.publish("range", 5)
  bus.publish("range", 15)
  bus.publish("range", 25)
  assert_eq(fired.val, [15])
}
