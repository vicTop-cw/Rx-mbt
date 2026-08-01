// Blackbox tests run against the package's public API. Use `@RX-MBT` to import.
// Prefer high-level behaviors over implementation details.
// Run `moon test` to execute and `moon test --update` to refresh snapshots.

///|
test "run 立即消费并原样返回" {
  let values = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3]).tap(
    fn(v) { values.val.push(v) },
  )
  let _ = obs.run()
  assert_eq(values.val, [1, 2, 3])
}

///|
test "debug 透传所有值" {
  let values = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3]).debug(
    Some("Test"),
  )
  let _ = obs.subscribe_on_next(fn(v) { values.val.push(v) })
  assert_eq(values.val, [1, 2, 3])
}

///|
test "all 全满足发 true" {
  let values = Ref::Ref(Array::new())
  let obs : @rx.Observable[Bool, Unit] = @rx.Observable::from_iter([2, 4, 6]).all(
    fn(v) { v % 2 == 0 },
  )
  let _ = obs.subscribe_on_next(fn(v) { values.val.push(v) })
  assert_eq(values.val, [true])
}

///|
test "ReplaySubject with_buffer_size 只重放最近 N 个" {
  let subject : @rx.ReplaySubject[Int, Unit] = @rx.ReplaySubject::with_buffer_size(2)
  subject.on_next(1)
  subject.on_next(2)
  subject.on_next(3)
  let values = Ref::Ref(Array::new())
  let _ = subject.subscribe(@rx.Observer::on_next_only(fn(v) { values.val.push(v) }))
  assert_eq(values.val, [2, 3])
}

///|
test "PublishSubject 完成后新订阅者立即收到完成信号" {
  // 回归：修复前已完成主题的新订阅者永远不会收到终止信号且残留泄漏
  let subject : @rx.PublishSubject[Int, Unit] = @rx.PublishSubject::new()
  subject.on_next(1)
  subject.on_completed()
  let values = Ref::Ref(Array::new())
  let completed = Ref::Ref(false)
  let _ = subject.subscribe(
    @rx.Observer::new(fn(v : Int) { values.val.push(v) }, fn(_ : Unit) {}, fn() {
      completed.val = true
    }),
  )
  assert_eq(values.val, [])
  assert_true(completed.val)
}

///|
test "BehaviorSubject 出错后新订阅者立即收到错误且不重放当前值" {
  // 回归：修复前已终止的 BehaviorSubject 会错误地重放 current 值
  let subject : @rx.BehaviorSubject[Int, String] = @rx.BehaviorSubject::with_value(42)
  subject.on_error("boom")
  let values = Ref::Ref(Array::new())
  let errs = Ref::Ref(Array::new())
  let _ = subject.subscribe(
    @rx.Observer::new(fn(v : Int) { values.val.push(v) }, fn(e : String) {
      errs.val.push(e)
    }, fn() {}),
  )
  assert_eq(values.val, [])
  assert_eq(errs.val, ["boom"])
}

///|
test "CurrentThreadScheduler 同步执行任务" {
  let scheduler = @rx.CurrentThreadScheduler::new()
  let ran = Ref::Ref(false)
  scheduler.schedule(fn() { ran.val = true })
  assert_true(ran.val)
  assert_true(scheduler.now() >= 0L)
}

///|
test "cum_sum 累积求和逐值发出" {
  let values = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3, 4]).cum_sum()
  let _ = obs.subscribe_on_next(fn(v) { values.val.push(v) })
  assert_eq(values.val, [1, 3, 6, 10])
}

///|
test "cum_min 累积最小值逐值发出" {
  let values = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([5, 2, 8, 1]).cum_min()
  let _ = obs.subscribe_on_next(fn(v) { values.val.push(v) })
  assert_eq(values.val, [5, 2, 2, 1])
}

///|
test "cum_max 累积最大值逐值发出" {
  let values = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([3, 1, 9, 4]).cum_max()
  let _ = obs.subscribe_on_next(fn(v) { values.val.push(v) })
  assert_eq(values.val, [3, 3, 9, 9])
}

///|
test "abs 逐元素取绝对值" {
  let values = Ref::Ref(Array::new())
  let obs : @rx.Observable[Double, Unit] = @rx.Observable::from_iter([-1.5, 2.0, -3.5]).abs()
  let _ = obs.subscribe_on_next(fn(v) { values.val.push(v) })
  assert_eq(values.val, [1.5, 2.0, 3.5])
}

///|
test "curry_map 返回可组合函数并应用" {
  let values = Ref::Ref(Array::new())
  let mapper : (@rx.Observable[Int, Unit]) -> @rx.Observable[Int, Unit] = @rx.curry_map(
    fn(v : Int, k : Int) { v * k },
    10,
  )
  let obs = mapper(@rx.Observable::from_iter([1, 2, 3]))
  let _ = obs.subscribe_on_next(fn(v) { values.val.push(v) })
  assert_eq(values.val, [10, 20, 30])
}

///|
test "ReplaySubject 终止后 on_next 不再缓冲（回归：内存泄漏修复）" {
  let s : @rx.ReplaySubject[Int, Unit] = @rx.ReplaySubject::new()
  s.on_next(1)
  s.on_completed()
  s.on_next(2) // 已终止：应被忽略，不进入缓冲
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let _ = s.as_observable().subscribe_on_next(fn(v : Int) { values.val.push(v) })
  // 终止后重放已完成前缓冲的历史（[1]），on_next(2) 未进入缓冲
  assert_eq(values.val, [1])
}

///|
test "delay_on 源完成时挂起延迟值不丢失（回归：complete 也延迟）" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let done : Ref[Bool] = Ref::Ref(false)
  let clock = @rx.Clock::new()
  let src : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3])
  let _ = src.delay_on(clock, 10L).subscribe(
    @rx.Observer::new(
      fn(v : Int) { values.val.push(v) },
      fn(_ : Unit) {},
      fn() { done.val = true },
    ),
  )
  // 源已同步完成，但延迟值尚未发射，complete 也不应已触发
  assert_eq(values.val, [])
  assert_true(!done.val)
  clock.advance(10L)
  assert_eq(values.val, [1, 2, 3])
  assert_true(done.val)
}

///|
test "timeout_on 源完成后挂起 timer 不误触发错误（回归）" {
  let got_err : Ref[Bool] = Ref::Ref(false)
  let clock = @rx.Clock::new()
  let src : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1])
  let _ = src.timeout_on(clock, 50L).subscribe(
    @rx.Observer::new(
      fn(_ : Int) {},
      fn(_ : Unit) { got_err.val = true },
      fn() {},
    ),
  )
  // 源已完成，推进时钟越过超时点：不应触发错误
  clock.advance(100L)
  assert_true(!got_err.val)
}
