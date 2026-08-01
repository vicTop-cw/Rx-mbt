// 分类测试：过滤类（Filter）
// filter / take / skip / first / last / take_while / skip_while / skip_last /
// take_last / element_at / distinct / distinct_by / distinct_until_changed /
// distinct_until_changed_by / skip_until / take_until / contains / includes

///|
test "filter: 只放行满足谓词的值" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3, 4]).filter(
    fn(v : Int) { v % 2 == 0 },
  )
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [2, 4])
}

///|
test "filter: take 取前 n 个后完成" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let done : Ref[Bool] = Ref::Ref(false)
  let _ = @rx.Observable::from_iter([1, 2, 3, 4, 5]).take(3).subscribe(
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
test "filter: skip 跳过前 n 个" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3, 4]).skip(2)
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [3, 4])
}

///|
test "filter: first 取第一个值" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([5, 6, 7]).first()
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [5])
}

///|
test "filter: last 取最后一个值" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([5, 6, 7]).last()
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [7])
}

///|
test "filter: take_while 谓词为假即停" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3, 1]).take_while(
    fn(v : Int) { v < 3 },
  )
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1, 2])
}

///|
test "filter: skip_while 跳过满足谓词的前缀" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3, 1]).skip_while(
    fn(v : Int) { v < 3 },
  )
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [3, 1])
}

///|
test "filter: skip_last 跳过最后 n 个" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3, 4, 5]).skip_last(2)
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1, 2, 3])
}

///|
test "filter: take_last 只取最后 n 个" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3, 4, 5]).take_last(2)
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [4, 5])
}

///|
test "filter: element_at 取第 index 个" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([10, 20, 30]).element_at(1)
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [20])
}

///|
test "filter: distinct 全局去重" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 1, 3, 2]).distinct()
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1, 2, 3])
}

///|
test "filter: distinct_by 按键去重" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([2, 4, 3, 5]).distinct_by(
    fn(v : Int) { v % 2 },
  )
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [2, 3])
}

///|
test "filter: distinct_until_changed 去连续重复" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter(
    [1, 1, 2, 2, 1],
  ).distinct_until_changed()
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1, 2, 1])
}

///|
test "filter: distinct_until_changed_by 按键去连续重复" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 3, 2, 4]).distinct_until_changed_by(
    fn(v : Int) { v % 2 },
  )
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1, 2])
}

///|
test "filter: skip_until 触发前不放行" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let trigger : @rx.Observable[Unit, Unit] = @rx.Observable::of(())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3]).skip_until(trigger)
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1, 2, 3])
}

///|
test "filter: take_until 触发后即停" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let trigger : @rx.Observable[Unit, Unit] = @rx.Observable::of(())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3]).take_until(trigger)
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [])
}

///|
test "filter: contains 命中返回 true" {
  let values : Ref[Array[Bool]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Bool, Unit] = @rx.Observable::from_iter([1, 2, 3]).contains(2)
  let _ = obs.subscribe_on_next(fn(v : Bool) { values.val.push(v) })
  assert_eq(values.val, [true])
}

///|
test "filter: contains 未命中返回 false" {
  let values : Ref[Array[Bool]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Bool, Unit] = @rx.Observable::from_iter([1, 2, 3]).contains(9)
  let _ = obs.subscribe_on_next(fn(v : Bool) { values.val.push(v) })
  assert_eq(values.val, [false])
}

///|
test "filter: includes 命中返回 true" {
  let values : Ref[Array[Bool]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Bool, Unit] = @rx.Observable::from_iter([1, 2, 3]).includes(3)
  let _ = obs.subscribe_on_next(fn(v : Bool) { values.val.push(v) })
  assert_eq(values.val, [true])
}

///|
test "filter: element_at 命中后不发错误（回归）" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let got_err : Ref[Bool] = Ref::Ref(false)
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([10, 20, 30]).element_at(1)
  let _ = obs.subscribe(
    @rx.Observer::new(
      fn(v : Int) { values.val.push(v) },
      fn(_ : Unit) { got_err.val = true },
      fn() {},
    ),
  )
  assert_eq(values.val, [20])
  assert_true(!got_err.val)
}

///|
test "filter: element_at 越界发错误" {
  let got_err : Ref[Bool] = Ref::Ref(false)
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([10, 20, 30]).element_at(9)
  let _ = obs.subscribe(
    @rx.Observer::new(
      fn(_ : Int) {},
      fn(_ : Unit) { got_err.val = true },
      fn() {},
    ),
  )
  assert_true(got_err.val)
}
