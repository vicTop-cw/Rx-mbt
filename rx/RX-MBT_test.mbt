// Blackbox tests run against the package's public API. Use `@RX-MBT` to import.
// Prefer high-level behaviors over implementation details.
// Run `moon test` to execute and `moon test --update` to refresh snapshots.

///|
test "run 立即消费并原样返回" {
  let values = Ref::Ref(Array::new())
  let obs : Observable[Int, Unit] = Observable::from_iter([1, 2, 3]).tap(
    fn(v) { values.val.push(v) },
  )
  let _ = obs.run()
  assert_eq(values.val, [1, 2, 3])
}

///|
test "debug 透传所有值" {
  let values = Ref::Ref(Array::new())
  let obs : Observable[Int, Unit] = Observable::from_iter([1, 2, 3]).debug(
    Some("Test"),
  )
  let _ = obs.subscribe_on_next(fn(v) { values.val.push(v) })
  assert_eq(values.val, [1, 2, 3])
}

///|
test "all 全满足发 true" {
  let values = Ref::Ref(Array::new())
  let obs : Observable[Bool, Unit] = Observable::from_iter([2, 4, 6]).all(
    fn(v) { v % 2 == 0 },
  )
  let _ = obs.subscribe_on_next(fn(v) { values.val.push(v) })
  assert_eq(values.val, [true])
}

///|
test "ReplaySubject with_buffer_size 只重放最近 N 个" {
  let subject : ReplaySubject[Int, Unit] = ReplaySubject::with_buffer_size(2)
  subject.on_next(1)
  subject.on_next(2)
  subject.on_next(3)
  let values = Ref::Ref(Array::new())
  let _ = subject.subscribe(Observer::on_next_only(fn(v) { values.val.push(v) }))
  assert_eq(values.val, [2, 3])
}

///|
test "CurrentThreadScheduler 同步执行任务" {
  let scheduler = CurrentThreadScheduler::new()
  let ran = Ref::Ref(false)
  scheduler.schedule(fn() { ran.val = true })
  assert_true(ran.val)
  assert_true(scheduler.now() >= 0L)
}
