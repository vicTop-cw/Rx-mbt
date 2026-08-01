// 分类测试：数学类 + 条件类（Math & Conditions）
// drop_none / fill_none / clamp / abs / every / some / all / find / find_index / is_empty

///|
test "math: drop_none 丢弃 None" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([Some(1), None, Some(2)]).drop_none()
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1, 2])
}

///|
test "math: fill_none 用默认值替换 None" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([Some(1), None]).fill_none(0)
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1, 0])
}

///|
test "math: clamp 夹取到区间内" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([0, 5, 10, 15]).clamp(5, 10)
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [5, 5, 10, 10])
}

///|
test "math: abs 取绝对值" {
  let values : Ref[Array[Double]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Double, Unit] = @rx.Observable::from_iter([-2.5, 3.0]).abs()
  let _ = obs.subscribe_on_next(fn(v : Double) { values.val.push(v) })
  assert_eq(values.val, [2.5, 3.0])
}

///|
test "conditions: every 全满足发 true" {
  let values : Ref[Array[Bool]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Bool, Unit] = @rx.Observable::from_iter([2, 4, 6]).every(
    fn(v : Int) { v % 2 == 0 },
  )
  let _ = obs.subscribe_on_next(fn(v : Bool) { values.val.push(v) })
  assert_eq(values.val, [true])
}

///|
test "conditions: every 不满足发 false" {
  let values : Ref[Array[Bool]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Bool, Unit] = @rx.Observable::from_iter([2, 3, 6]).every(
    fn(v : Int) { v % 2 == 0 },
  )
  let _ = obs.subscribe_on_next(fn(v : Bool) { values.val.push(v) })
  assert_eq(values.val, [false])
}

///|
test "conditions: some 命中发 true" {
  let values : Ref[Array[Bool]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Bool, Unit] = @rx.Observable::from_iter([1, 2, 3]).some(
    fn(v : Int) { v == 2 },
  )
  let _ = obs.subscribe_on_next(fn(v : Bool) { values.val.push(v) })
  assert_eq(values.val, [true])
}

///|
test "conditions: some 未命中发 false" {
  let values : Ref[Array[Bool]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Bool, Unit] = @rx.Observable::from_iter([1, 3]).some(fn(v : Int) { v == 2 })
  let _ = obs.subscribe_on_next(fn(v : Bool) { values.val.push(v) })
  assert_eq(values.val, [false])
}

///|
test "conditions: all 全满足发 true" {
  let values : Ref[Array[Bool]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Bool, Unit] = @rx.Observable::from_iter([4, 6]).all(
    fn(v : Int) { v % 2 == 0 },
  )
  let _ = obs.subscribe_on_next(fn(v : Bool) { values.val.push(v) })
  assert_eq(values.val, [true])
}

///|
test "conditions: find 返回首个匹配值" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3]).find(
    fn(v : Int) { v > 1 },
  )
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [2])
}

///|
test "conditions: find_index 返回匹配索引" {
  let values : Ref[Array[Int64]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int64, Unit] = @rx.Observable::from_iter([1, 2, 3]).find_index(
    fn(v : Int) { v > 1 },
  )
  let _ = obs.subscribe_on_next(fn(v : Int64) { values.val.push(v) })
  assert_eq(values.val, [1L])
}

///|
test "conditions: find_index 未找到发 -1" {
  let values : Ref[Array[Int64]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int64, Unit] = @rx.Observable::from_iter([1, 2]).find_index(
    fn(v : Int) { v > 9 },
  )
  let _ = obs.subscribe_on_next(fn(v : Int64) { values.val.push(v) })
  assert_eq(values.val, [-1L])
}

///|
test "conditions: is_empty 空流发 true" {
  let values : Ref[Array[Bool]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Bool, Unit] = @rx.Observable::empty().is_empty()
  let _ = obs.subscribe_on_next(fn(v : Bool) { values.val.push(v) })
  assert_eq(values.val, [true])
}

///|
test "conditions: is_empty 非空流发 false" {
  let values : Ref[Array[Bool]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Bool, Unit] = @rx.Observable::of(1).is_empty()
  let _ = obs.subscribe_on_next(fn(v : Bool) { values.val.push(v) })
  assert_eq(values.val, [false])
}

///|
test "error: backpressure_error 带 max_size 透传（同步模型）" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3]).backpressure_error(2)
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1, 2, 3])
}

///|
test "error: backpressure_buffer 带 buffer_size 透传（同步模型）" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3]).backpressure_buffer(2)
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1, 2, 3])
}

///|
test "error: backpressure_drop 透传（同步模型）" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3]).backpressure_drop()
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1, 2, 3])
}

///|
test "error: backpressure_latest 透传（同步模型）" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3]).backpressure_latest()
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1, 2, 3])
}

///|
test "error: catch_error 出错时切换到备用流" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, String] = @rx.Observable::error("boom").catch_error(
    fn(_e : String) -> @rx.Observable[Int, String] { @rx.Observable::of(42) },
  )
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [42])
}

///|
test "error: on_error_return 出错时发射兜底值" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, String] = @rx.Observable::error("boom").on_error_return(7)
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [7])
}

///|
test "error: retry 出错重试后成功" {
  let attempts = Ref::Ref(0)
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::new(fn(observer : @rx.Observer[Int, Unit]) {
    attempts.val = attempts.val + 1
    if attempts.val < 3 {
      observer.on_error(())
    } else {
      observer.on_next(99)
      observer.on_completed()
    }
    @rx.Subscription::empty()
  }).retry(5)
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [99])
  assert_eq(attempts.val, 3)
}
