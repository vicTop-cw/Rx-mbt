// 分类测试：组合类（Combination）
// start_with / concat / merge / zip / combine_latest / with_latest_from /
// amb / end_with / iif / sequence_equal

///|
test "composite: start_with 前置发射前缀" {
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([3, 4]).start_with([1, 2])
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1, 2, 3, 4])
}

///|
test "composite: concat 串接两个流" {
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let a : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2])
  let b : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([3, 4])
  let _ = a.concat(b).subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1, 2, 3, 4])
}

///|
test "composite: merge 合并两个流" {
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let a : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2])
  let b : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([3, 4])
  let _ = a.merge(b).subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1, 2, 3, 4])
}

///|
test "composite: merge 自由函数版" {
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let a : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1])
  let b : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([2])
  let _ = @rx.merge(a, b).subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1, 2])
}

///|
test "composite: zip 按位置配对" {
  let values : Ref[Array[(Int, String)]] = Ref::Ref(Array(capacity=0))
  let a : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2])
  let b : @rx.Observable[String, Unit] = @rx.Observable::from_iter(["a", "b"])
  let _ = @rx.zip(a, b).subscribe_on_next(fn(p : (Int, String)) { values.val.push(p) })
  assert_eq(values.val, [(1, "a"), (2, "b")])
}

///|
test "composite: combine_latest 任一源新值时组合" {
  let values : Ref[Array[(Int, Int)]] = Ref::Ref(Array(capacity=0))
  let a : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2])
  let b : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([10])
  let _ = @rx.combine_latest(a, b).subscribe_on_next(fn(p : (Int, Int)) { values.val.push(p) })
  // 同步订阅顺序：a 先发完（此时 b 尚无值，不触发），b 再发 10 触发最后一次组合
  assert_eq(values.val, [(2, 10)])
}

///|
test "composite: with_latest_from a 发值时带 b 最新值" {
  let values : Ref[Array[(Int, Int)]] = Ref::Ref(Array(capacity=0))
  let a : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2])
  let b : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([10])
  let _ = @rx.with_latest_from(a, b).subscribe_on_next(fn(p : (Int, Int)) { values.val.push(p) })
  assert_eq(values.val, [(1, 10), (2, 10)])
}

///|
test "composite: amb 先发射者胜出" {
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let a : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2])
  let b : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([3, 4])
  let _ = @rx.amb(a, b).subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1, 2])
}

///|
test "composite: amb 先完成者胜出，另一方后续值被忽略（回归）" {
  // 回归：修复前 a 先完成（done=true）后，b 发射的值仍会被转发
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let a : @rx.Observable[Int, Unit] = @rx.Observable::empty()
  let b : @rx.PublishSubject[Int, Unit] = @rx.PublishSubject::new()
  let _ = @rx.amb(a, b.as_observable()).subscribe_on_next(fn(v : Int) { values.val.push(v) })
  b.on_next(99)
  assert_eq(values.val, [])
}

///|
test "composite: end_with 完成前追加后缀" {
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2]).end_with([9])
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1, 2, 9])
}

///|
test "composite: iif 条件为真选 then 分支" {
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let then_obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1])
  let else_obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([2])
  let _ = @rx.iif(true, then_obs, else_obs).subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1])
}

///|
test "composite: iif 条件为假选 otherwise 分支" {
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let then_obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1])
  let else_obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([2])
  let _ = @rx.iif(false, then_obs, else_obs).subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [2])
}

///|
test "composite: sequence_equal 相等返回 true" {
  let values : Ref[Array[Bool]] = Ref::Ref(Array(capacity=0))
  let a : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3])
  let b : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3])
  let _ = @rx.sequence_equal(a, b).subscribe_on_next(fn(v : Bool) { values.val.push(v) })
  assert_eq(values.val, [true])
}

///|
test "composite: sequence_equal 不等返回 false" {
  let values : Ref[Array[Bool]] = Ref::Ref(Array(capacity=0))
  let a : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2])
  let b : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 3])
  let _ = @rx.sequence_equal(a, b).subscribe_on_next(fn(v : Bool) { values.val.push(v) })
  assert_eq(values.val, [false])
}

///|
test "composite: zip 方法版配对" {
  let values : Ref[Array[(Int, Int)]] = Ref::Ref(Array(capacity=0))
  let a : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2])
  let b : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([10, 20])
  let _ = a.zip(b).subscribe_on_next(fn(p : (Int, Int)) { values.val.push(p) })
  assert_eq(values.val, [(1, 10), (2, 20)])
}

///|
test "composite: zip 双方都有值时立即配对发射（Subject 热流回归）" {
  // 回归：修复前 zip 只在"一方完成"时才发射，热流下永远不会出值
  let values : Ref[Array[(Int, Int)]] = Ref::Ref(Array(capacity=0))
  let a : @rx.PublishSubject[Int, Unit] = @rx.PublishSubject::new()
  let b : @rx.PublishSubject[Int, Unit] = @rx.PublishSubject::new()
  let _ = @rx.zip(a.as_observable(), b.as_observable()).subscribe_on_next(
    fn(p : (Int, Int)) { values.val.push(p) },
  )
  a.on_next(1)
  b.on_next(10)
  a.on_next(2)
  b.on_next(20)
  assert_eq(values.val, [(1, 10), (2, 20)])
}

///|
test "composite: zip 一方完成且缓冲耗尽即终止（不等挂起的另一源）" {
  let values : Ref[Array[(Int, Int)]] = Ref::Ref(Array(capacity=0))
  let done : Ref[Bool] = Ref::Ref(false)
  // a 立即完成且无缓冲值，b 永不完成：zip 应立即终止（Rx 标准语义）
  let a : @rx.Observable[Int, Unit] = @rx.Observable::empty()
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

///|
test "composite: zip 一方完成但缓冲有值则等另一方配对（Rx 标准语义）" {
  let values : Ref[Array[(Int, Int)]] = Ref::Ref(Array(capacity=0))
  let done : Ref[Bool] = Ref::Ref(false)
  // a=[1,2] 完成但缓冲有值，b=never 永不发射：zip 永不完成、不发值（标准行为）
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
  assert_true(!done.val)
}

///|
test "composite: zip 任一源错误时立即终止并取消对方订阅（回归）" {
  let got_err : Ref[Bool] = Ref::Ref(false)
  let done : Ref[Bool] = Ref::Ref(false)
  let a : @rx.Observable[Int, String] = @rx.Observable::error("boom")
  let b : @rx.PublishSubject[Int, String] = @rx.PublishSubject::new()
  let sub = @rx.zip(a, b.as_observable()).subscribe(
    @rx.Observer::new(
      fn(_ : (Int, Int)) {},
      fn(e : String) { got_err.val = true; if e != "boom" { got_err.val = false } },
      fn() { done.val = true },
    ),
  )
  assert_true(got_err.val)
  assert_true(!done.val)
  sub.dispose()
  // 对方订阅已被取消：后续 on_next 不再触发任何回调（不崩溃即可）
  b.on_next(1)
}

///|
test "composite: amb a 胜出后 b 订阅被取消，b 后续值不转发（回归）" {
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let a : @rx.PublishSubject[Int, Unit] = @rx.PublishSubject::new()
  let b : @rx.PublishSubject[Int, Unit] = @rx.PublishSubject::new()
  let _ = @rx.amb(a.as_observable(), b.as_observable()).subscribe_on_next(
    fn(v : Int) { values.val.push(v) },
  )
  a.on_next(1)
  b.on_next(2)
  a.on_next(3)
  assert_eq(values.val, [1, 3])
}

///|
test "composite: concat 进入第二段后 dispose 可取消第二段订阅（回归）" {
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let done : Ref[Bool] = Ref::Ref(false)
  let tail : @rx.PublishSubject[Int, Unit] = @rx.PublishSubject::new()
  let src : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1])
  let sub = src.concat(tail.as_observable()).subscribe(
    @rx.Observer::new(
      fn(v : Int) { values.val.push(v) },
      fn(_ : Unit) {},
      fn() { done.val = true },
    ),
  )
  assert_eq(values.val, [1]) // 第一段已完成，第二段已订阅
  sub.dispose()
  tail.on_next(2) // 第二段已取消：不转发
  assert_eq(values.val, [1])
  assert_true(!done.val)
}

///|
test "composite: with_latest_from a 完成后 b 订阅被取消（回归）" {
  let values : Ref[Array[(Int, Int)]] = Ref::Ref(Array(capacity=0))
  let b : @rx.PublishSubject[Int, Unit] = @rx.PublishSubject::new()
  let a : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2])
  let _ = @rx.with_latest_from(a, b.as_observable()).subscribe_on_next(
    fn(v : (Int, Int)) { values.val.push(v) },
  )
  // a 同步完成前 b 无值：无配对发射；a 完成后 b 订阅已取消
  b.on_next(99) // 不应再影响任何输出
  assert_eq(values.val, [])
}
