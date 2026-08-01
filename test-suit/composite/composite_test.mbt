// 分类测试：组合类（Combination）
// start_with / concat / merge / zip / combine_latest / with_latest_from /
// amb / end_with / iif / sequence_equal

///|
test "composite: start_with 前置发射前缀" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([3, 4]).start_with([1, 2])
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1, 2, 3, 4])
}

///|
test "composite: concat 串接两个流" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let a : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2])
  let b : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([3, 4])
  let _ = a.concat(b).subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1, 2, 3, 4])
}

///|
test "composite: merge 合并两个流" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let a : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2])
  let b : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([3, 4])
  let _ = a.merge(b).subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1, 2, 3, 4])
}

///|
test "composite: merge 自由函数版" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let a : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1])
  let b : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([2])
  let _ = @rx.merge(a, b).subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1, 2])
}

///|
test "composite: zip 按位置配对" {
  let values : Ref[Array[(Int, String)]] = Ref::Ref(Array::new())
  let a : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2])
  let b : @rx.Observable[String, Unit] = @rx.Observable::from_iter(["a", "b"])
  let _ = @rx.zip(a, b).subscribe_on_next(fn(p : (Int, String)) { values.val.push(p) })
  assert_eq(values.val, [(1, "a"), (2, "b")])
}

///|
test "composite: combine_latest 任一源新值时组合" {
  let values : Ref[Array[(Int, Int)]] = Ref::Ref(Array::new())
  let a : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2])
  let b : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([10])
  let _ = @rx.combine_latest(a, b).subscribe_on_next(fn(p : (Int, Int)) { values.val.push(p) })
  // 同步订阅顺序：a 先发完（此时 b 尚无值，不触发），b 再发 10 触发最后一次组合
  assert_eq(values.val, [(2, 10)])
}

///|
test "composite: with_latest_from a 发值时带 b 最新值" {
  let values : Ref[Array[(Int, Int)]] = Ref::Ref(Array::new())
  let a : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2])
  let b : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([10])
  let _ = @rx.with_latest_from(a, b).subscribe_on_next(fn(p : (Int, Int)) { values.val.push(p) })
  assert_eq(values.val, [(1, 10), (2, 10)])
}

///|
test "composite: amb 先发射者胜出" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let a : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2])
  let b : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([3, 4])
  let _ = @rx.amb(a, b).subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1, 2])
}

///|
test "composite: end_with 完成前追加后缀" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2]).end_with([9])
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1, 2, 9])
}

///|
test "composite: iif 条件为真选 then 分支" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let then_obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1])
  let else_obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([2])
  let _ = @rx.iif(true, then_obs, else_obs).subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1])
}

///|
test "composite: iif 条件为假选 otherwise 分支" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let then_obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1])
  let else_obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([2])
  let _ = @rx.iif(false, then_obs, else_obs).subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [2])
}

///|
test "composite: sequence_equal 相等返回 true" {
  let values : Ref[Array[Bool]] = Ref::Ref(Array::new())
  let a : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3])
  let b : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3])
  let _ = @rx.sequence_equal(a, b).subscribe_on_next(fn(v : Bool) { values.val.push(v) })
  assert_eq(values.val, [true])
}

///|
test "composite: sequence_equal 不等返回 false" {
  let values : Ref[Array[Bool]] = Ref::Ref(Array::new())
  let a : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2])
  let b : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 3])
  let _ = @rx.sequence_equal(a, b).subscribe_on_next(fn(v : Bool) { values.val.push(v) })
  assert_eq(values.val, [false])
}

///|
test "composite: zip 方法版配对" {
  let values : Ref[Array[(Int, Int)]] = Ref::Ref(Array::new())
  let a : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2])
  let b : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([10, 20])
  let _ = a.zip(b).subscribe_on_next(fn(p : (Int, Int)) { values.val.push(p) })
  assert_eq(values.val, [(1, 10), (2, 20)])
}

///|
test "composite: zip 任一源完成即终止（回归：不等挂起的另一源）" {
  let values : Ref[Array[(Int, Int)]] = Ref::Ref(Array::new())
  let done : Ref[Bool] = Ref::Ref(false)
  let a : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2])
  let b : @rx.Observable[Int, Unit] = @rx.Observable::never()
  let _ = @rx.zip(a, b).subscribe(
    @rx.Observer::new(
      fn(p : (Int, Int)) { values.val.push(p) },
      fn(_ : Unit) {},
      fn() { done.val = true },
    ),
  )
  assert_eq(values.val, [])
  assert_true(done.val)
}
