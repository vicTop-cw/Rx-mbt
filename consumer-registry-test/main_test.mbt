///|
/// 通过 mooncakes 依赖（vicTop-cw/RX-MBT）使用 rx-mbt 的 blackbox 测试。
/// 验证从 registry 拉取的包在独立工程中可编译、可测试。
/// 运行：`moon test`（依赖工程根目录）
///|
test "依赖包: Observable map/filter 链式操作" {
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3, 4, 5])
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let _sub = obs.map(fn(x) { x * 2 }).filter(fn(x) { x > 4 }).subscribe_on_next(fn(v) {
    values.val.push(v)
  })
  assert_eq(values.val, [6, 8, 10])
}

///|
test "依赖包: take 截断无限源" {
  let taken = Ref::Ref(0)
  let rng : @rx.Observable[Int64, Unit] = @rx.Observable::range(0L, 100L)
  let _ = rng.take(3).subscribe_on_next(fn(_ : Int64) { taken.val = taken.val + 1 })
  assert_eq(taken.val, 3)
}

///|
test "依赖包: Itor 可控制迭代器" {
  let doubled = @rx.Itor::from_array([1, 2, 3]).map(fn(x) { x * 2 }).to_array()
  assert_eq(doubled, [2, 4, 6])
}

///|
test "依赖包: 全链路 from_iter -> map -> take" {
  let flow : @rx.Observable[Int, Unit] =
    @rx.Observable::from_iter([1, 2, 3, 4, 5]).map(fn(x) { x * 10 }).take(4)
  let got = Ref::Ref(Array::new())
  let _ = flow.subscribe_on_next(fn(v : Int) { got.val.push(v) })
  assert_eq(got.val, [10, 20, 30, 40])
}

///|
test "依赖包: Subject 多播" {
  let subject : @rx.PublishSubject[Int, Unit] = @rx.PublishSubject::new()
  let a = Ref::Ref(Array::new())
  let b = Ref::Ref(Array::new())
  let _ = subject.subscribe(@rx.Observer::on_next_only(fn(v) { a.val.push(v) }))
  let _ = subject.subscribe(@rx.Observer::on_next_only(fn(v) { b.val.push(v) }))
  subject.on_next(1)
  subject.on_next(2)
  assert_eq(a.val, [1, 2])
  assert_eq(b.val, [1, 2])
}
