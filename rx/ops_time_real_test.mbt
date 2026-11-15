// ============================================================================
// ops_time_real_test —— R1 真实时钟时间算子测试
// 覆盖：
//   1. 可控 RealClock 注入（install_real_clock_with + real_clock_tick）确定性测试
//   2. real_interval / real_timer 可控注入下的确定性节拍
//   3. debounce_real / throttle_real 可控注入下的确定性窗口
//   4. 纯虚拟路径确定性测试（未安装真实时钟，advance_time 驱动）
//   5. EventBus::publish 默认 at 使用真实墙钟（R4 衔接）
//   6. 真实时钟 async 测试（js/native）：interval 节拍、timer、debounce、throttle
// 运行：moon test --target js rx
// ============================================================================

///|
test "uninstall 后 real_now 保持占位虚拟语义" {
  @rx.uninstall_real_clock()
  assert_eq(@rx.real_now(), 0L)
  @rx.advance_time(42L)
  assert_eq(@rx.real_now(), 42L)
}

///|
test "install_real_clock_with：real_now 取注入墙钟，tick 幂等" {
  let wall = @rx.Clock::new()
  @rx.install_real_clock_with(wall)
  assert_eq(@rx.real_now(), 0L)
  wall.advance(100L)
  assert_eq(@rx.real_now(), 100L)
  // 墙钟未前进时 tick 不推进（增量非正跳过）；桥接行为由 real_interval 测试间接验证
  @rx.real_clock_tick()
  assert_eq(@rx.real_now(), 100L)
  @rx.uninstall_real_clock()
}

///|
test "real_interval 可控注入：每 ms 节拍发射自增整数" {
  @rx.uninstall_real_clock()
  let wall = @rx.Clock::new()
  @rx.install_real_clock_with(wall)
  let got = Ref::Ref(Array(capacity=0))
  let sub = @rx.real_interval(10L).subscribe_on_next(fn(v : Int64) {
    got.val.push(v)
  })
  wall.advance(10L)
  @rx.real_clock_tick()
  assert_eq(got.val, [0L])
  wall.advance(10L)
  @rx.real_clock_tick()
  assert_eq(got.val, [0L, 1L])
  // 未到期不发射
  wall.advance(9L)
  @rx.real_clock_tick()
  assert_eq(got.val, [0L, 1L])
  wall.advance(1L)
  @rx.real_clock_tick()
  assert_eq(got.val, [0L, 1L, 2L])
  sub.dispose()
  @rx.uninstall_real_clock()
}

///|
test "real_timer 可控注入：延迟 ms 后发射 0 并完成" {
  @rx.uninstall_real_clock()
  let wall = @rx.Clock::new()
  @rx.install_real_clock_with(wall)
  let got = Ref::Ref(Array(capacity=0))
  let completed = Ref::Ref(false)
  let sub = @rx.real_timer(10L).subscribe(
    @rx.Observer::new(fn(v : Int64) { got.val.push(v) }, fn(_e : Unit) {  }, fn() {
      completed.val = true
    }),
  )
  wall.advance(9L)
  @rx.real_clock_tick()
  assert_eq(got.val, [])
  assert_true(!completed.val)
  wall.advance(1L)
  @rx.real_clock_tick()
  assert_eq(got.val, [0L])
  assert_true(completed.val)
  sub.dispose()
  @rx.uninstall_real_clock()
}

///|
test "debounce_real 可控注入：窗口结束后仅发最后一个值" {
  @rx.uninstall_real_clock()
  let wall = @rx.Clock::new()
  @rx.install_real_clock_with(wall)
  let subj : @rx.PublishSubject[Int32, Unit] = @rx.PublishSubject::new()
  let got = Ref::Ref(Array(capacity=0))
  let _ = subj
    .as_observable()
    .debounce_real(10L)
    .subscribe_on_next(fn(v : Int32) { got.val.push(v) })
  subj.on_next(1)
  subj.on_next(2) // 同窗口：仅最后一个值在窗口结束后发出
  wall.advance(10L)
  @rx.real_clock_tick()
  assert_eq(got.val, [2])
  subj.on_next(3)
  wall.advance(10L)
  @rx.real_clock_tick()
  assert_eq(got.val, [2, 3])
  @rx.uninstall_real_clock()
}

///|
test "throttle_real 可控注入：每窗口最多放行一个值" {
  @rx.uninstall_real_clock()
  let wall = @rx.Clock::new()
  @rx.install_real_clock_with(wall)
  let subj : @rx.PublishSubject[Int32, Unit] = @rx.PublishSubject::new()
  let got = Ref::Ref(Array(capacity=0))
  let _ = subj
    .as_observable()
    .throttle_real(10L)
    .subscribe_on_next(fn(v : Int32) { got.val.push(v) })
  subj.on_next(1) // 放行
  subj.on_next(2) // 同刻拦截
  assert_eq(got.val, [1])
  wall.advance(10L)
  @rx.real_clock_tick()
  subj.on_next(3) // 窗口已过，放行
  subj.on_next(4) // 拦截
  assert_eq(got.val, [1, 3])
  @rx.uninstall_real_clock()
}

///|
test "纯虚拟路径：未安装真实时钟时 real_interval 由 advance_time 确定性驱动" {
  @rx.uninstall_real_clock()
  let got = Ref::Ref(Array(capacity=0))
  let sub = @rx.real_interval(5L).subscribe_on_next(fn(v : Int64) {
    got.val.push(v)
  })
  @rx.advance_time(5L)
  @rx.advance_time(5L)
  @rx.advance_time(5L)
  assert_eq(got.val, [0L, 1L, 2L])
  sub.dispose()
}

///|
test "EventBus publish 默认 at：install_real_clock_with 后使用注入墙钟时间" {
  @rx.uninstall_real_clock()
  let wall = @rx.Clock::new()
  @rx.install_real_clock_with(wall)
  let bus : @rx.EventBus[Int32] = @rx.EventBus::new()
  let times = Ref::Ref(Array(capacity=0))
  let _ = bus.subscribe("ts", fn(ev : @rx.TriggerEvent[Int32]) {
    times.val.push(ev.at)
  })
  wall.advance(50L)
  bus.publish("ts", 1) // 默认 at = real_now() = 注入墙钟 50
  wall.advance(25L)
  bus.publish("ts", 2, at=999L) // 显式 at 不受影响
  assert_eq(times.val, [50L, 999L])
  @rx.uninstall_real_clock()
}

///|
#cfg(not(target="wasm"))
async test "real_interval 真实节拍：安装真实时钟 + 驱动循环按真实毫秒递增发射" {
  @rx.install_real_clock()
  @async.with_task_group <| tg => {
    tg.spawn_bg(no_wait=true) <| () => {
      @rx.drive_real_clock(5L, max_ticks=30L)
    }
    let got = Ref::Ref(Array(capacity=0))
    let sub = @rx.real_interval(10L).subscribe_on_next(fn(v : Int64) {
      got.val.push(v)
    })
    @async.sleep(80)
    sub.dispose()
    assert_true(got.val.length() >= 2)
    // 严格递增
    for i in 1..<got.val.length() {
      assert_true(got.val[i] > got.val[i - 1])
    }
  }
  @rx.uninstall_real_clock()
}

///|
#cfg(not(target="wasm"))
async test "real_timer 真实延迟：ms 后发射 0 并完成" {
  @rx.install_real_clock()
  @async.with_task_group <| tg => {
    tg.spawn_bg(no_wait=true) <| () => {
      @rx.drive_real_clock(5L, max_ticks=30L)
    }
    let got = Ref::Ref(Array(capacity=0))
    let completed = Ref::Ref(false)
    let sub = @rx.real_timer(20L).subscribe(
      @rx.Observer::new(fn(v : Int64) { got.val.push(v) }, fn(_e : Unit) {  }, fn() {
        completed.val = true
      }),
    )
    @async.sleep(10)
    // 20ms 未到：墙钟最多推进约 10ms，不应发射
    assert_true(got.val.length() == 0)
    @async.sleep(30)
    assert_eq(got.val, [0L])
    assert_true(completed.val)
    sub.dispose()
  }
  @rx.uninstall_real_clock()
}

///|
#cfg(not(target="wasm"))
async test "debounce_real 真实化：真实墙钟窗口结束后发出最后一个值" {
  @rx.install_real_clock()
  @async.with_task_group <| tg => {
    tg.spawn_bg(no_wait=true) <| () => {
      @rx.drive_real_clock(5L, max_ticks=30L)
    }
    let subj : @rx.PublishSubject[Int32, Unit] = @rx.PublishSubject::new()
    let got = Ref::Ref(Array(capacity=0))
    let _ = subj
      .as_observable()
      .debounce_real(30L)
      .subscribe_on_next(fn(v : Int32) { got.val.push(v) })
    subj.on_next(1)
    @async.sleep(50) // 30ms 窗口到期 → 发出 1
    subj.on_next(2)
    @async.sleep(50) // 再次到期 → 发出 2
    assert_eq(got.val, [1, 2])
  }
  @rx.uninstall_real_clock()
}

///|
#cfg(not(target="wasm"))
async test "throttle_real 真实化：真实墙钟每窗口最多放行一个值" {
  @rx.install_real_clock()
  @async.with_task_group <| tg => {
    tg.spawn_bg(no_wait=true) <| () => {
      @rx.drive_real_clock(5L, max_ticks=30L)
    }
    let subj : @rx.PublishSubject[Int32, Unit] = @rx.PublishSubject::new()
    let got = Ref::Ref(Array(capacity=0))
    let _ = subj
      .as_observable()
      .throttle_real(30L)
      .subscribe_on_next(fn(v : Int32) { got.val.push(v) })
    subj.on_next(1) // 放行
    subj.on_next(2) // 拦截
    @async.sleep(40)
    subj.on_next(3) // 30ms 已过，放行
    subj.on_next(4) // 拦截
    @async.sleep(40)
    assert_eq(got.val, [1, 3])
  }
  @rx.uninstall_real_clock()
}
