// 分类测试：创建类（Creation）
// of / from_iter / range / from_range / from_range_with_step / from_callable /
// start / empty / never / error / repeat / interval / timer
// Blackbox 视角：使用公开 API（@rx.Observer::new / subscribe_on_next 等）

///|
test "create: of 发射单值并完成" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let done : Ref[Bool] = Ref::Ref(false)
  let _ = @rx.Observable::of(42).subscribe(
    @rx.Observer::new(
      fn(v : Int) { values.val.push(v) },
      fn(_ : Unit) {},
      fn() { done.val = true },
    ),
  )
  assert_eq(values.val, [42])
  assert_true(done.val)
}

///|
test "create: from_iter 发射全部值并完成" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let done : Ref[Bool] = Ref::Ref(false)
  let _ = @rx.Observable::from_iter([1, 2, 3]).subscribe(
    @rx.Observer::new(
      fn(v : Int) { values.val.push(v) },
      fn(_ : Unit) {},
      fn() { done.val = true },
    ),
  )
  assert_eq(values.val, [1, 2, 3])
  assert_true(done.val)
}

///|
test "create: empty 立即完成不发射值" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let done : Ref[Bool] = Ref::Ref(false)
  let _ = @rx.Observable::empty().subscribe(
    @rx.Observer::new(
      fn(v : Int) { values.val.push(v) },
      fn(_ : Unit) {},
      fn() { done.val = true },
    ),
  )
  assert_eq(values.val, [])
  assert_true(done.val)
}

///|
test "create: never 不发射不完成" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let done : Ref[Bool] = Ref::Ref(false)
  let _ = @rx.Observable::never().subscribe(
    @rx.Observer::new(
      fn(v : Int) { values.val.push(v) },
      fn(_ : Unit) {},
      fn() { done.val = true },
    ),
  )
  assert_eq(values.val, [])
  assert_false(done.val)
}

///|
test "create: error 只触发错误回调" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let err : Ref[Option[String]] = Ref::Ref(None)
  let _ = @rx.Observable::error("boom").subscribe(
    @rx.Observer::new(
      fn(v : Int) { values.val.push(v) },
      fn(e : String) { err.val = Some(e) },
      fn() {},
    ),
  )
  assert_eq(values.val, [])
  assert_eq(err.val, Some("boom"))
}

///|
test "create: repeat 重复发射指定次数" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::repeat(7, 3)
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [7, 7, 7])
}

///|
test "create: from_range 发射半开区间序列" {
  let values : Ref[Array[Int64]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int64, Unit] = @rx.Observable::from_range(2L, 5L)
  let _ = obs.subscribe_on_next(fn(v : Int64) { values.val.push(v) })
  assert_eq(values.val, [2L, 3L, 4L])
}

///|
test "create: from_range_with_step 按步长发射" {
  let values : Ref[Array[Int64]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int64, Unit] = @rx.Observable::from_range_with_step(1L, 9L, 2L)
  let _ = obs.subscribe_on_next(fn(v : Int64) { values.val.push(v) })
  assert_eq(values.val, [1L, 3L, 5L, 7L])
}

///|
test "create: from_callable 调用函数并发射结果" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_callable(fn() { 99 })
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [99])
}

///|
test "create: start 等价 from_callable" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::start(fn() { 42 })
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [42])
}
