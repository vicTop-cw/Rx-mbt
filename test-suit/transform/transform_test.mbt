// 分类测试：变换类（Transform）
// map / filter_map / flat_map / flat_map_latest / scan / concat_map /
// switch_map / group_by / curry_map

///|
test "transform: map 对每个值应用映射" {
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3]).map(
    fn(x : Int) { x * 10 },
  )
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [10, 20, 30])
}

///|
test "transform: filter_map 保留 Some 丢弃 None" {
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3, 4]).filter_map(
    fn(x : Int) -> Int? { if x % 2 == 0 { Some(x * 100) } else { None } },
  )
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [200, 400])
}

///|
test "transform: flat_map 平铺内部流" {
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2]).flat_map(
    fn(x : Int) -> @rx.Observable[Int, Unit] {
      @rx.Observable::from_iter([x, x * 10])
    },
  )
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1, 10, 2, 20])
}

///|
test "transform: scan 累积并发出中间结果" {
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3, 4]).scan(
    0,
    fn(acc : Int, v : Int) { acc + v },
  )
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1, 3, 6, 10])
}

///|
test "transform: scan 多次订阅各自独立（冷流语义）" {
  // 回归：修复前 acc 在 subscribe_fn 外共享，第二次订阅会继承第一次的累积值
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3]).scan(
    100,
    fn(acc : Int, v : Int) { acc + v },
  )
  let first = Ref::Ref(Array(capacity=0))
  let second = Ref::Ref(Array(capacity=0))
  let _ = obs.subscribe_on_next(fn(v : Int) { first.val.push(v) })
  let _ = obs.subscribe_on_next(fn(v : Int) { second.val.push(v) })
  assert_eq(first.val, [101, 103, 106])
  assert_eq(second.val, [101, 103, 106])
}

///|
test "transform: concat_map 串行平铺" {
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2]).concat_map(
    fn(x : Int) -> @rx.Observable[Int, Unit] { @rx.Observable::of(x) },
  )
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1, 2])
}

///|
test "transform: switch_map 切换到最新内部流" {
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([5, 6]).switch_map(
    fn(x : Int) -> @rx.Observable[Int, Unit] { @rx.Observable::of(x * 2) },
  )
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [10, 12])
}

///|
test "transform: flat_map_latest 别名 switch_map" {
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([3]).flat_map_latest(
    fn(x : Int) -> @rx.Observable[Int, Unit] { @rx.Observable::of(x + 1) },
  )
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [4])
}

///|
test "transform: group_by 按键分组" {
  let values : Ref[Array[(String, @rx.Observable[Int, Unit])]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[(String, @rx.Observable[Int, Unit]), Unit] = @rx.Observable::from_iter(
    [1, 2, 3, 4],
  ).group_by(
    fn(v : Int) -> String { if v % 2 == 0 { "even" } else { "odd" } },
    fn() -> @rx.Observable[Int, Unit] { @rx.Observable::empty() },
  )
  let _ = obs.subscribe_on_next(
    fn(pair : (String, @rx.Observable[Int, Unit])) { values.val.push(pair) },
  )
  assert_eq(values.val.length(), 2)
}

///|
test "transform: curry_map 柯里化映射" {
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let mapper : (@rx.Observable[Int, Unit]) -> @rx.Observable[Int, Unit] = @rx.curry_map(
    fn(v : Int, k : Int) { v * k },
    10,
  )
  let obs = mapper(@rx.Observable::from_iter([1, 2, 3]))
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [10, 20, 30])
}
