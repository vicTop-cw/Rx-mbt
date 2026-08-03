///|
/// rx-mbt（mooncakes 依赖）可用性验证入口。
/// 通过 `moon add vicTop-cw/RX-MBT` 从 mooncakes 拉取依赖后运行一组核心 API，
/// 验证依赖下载、编译、运行全链路可用。
fn main {
  // 1. 创建 + 转换：from_iter / map / filter
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3, 4, 5])
  let doubled = obs.map(fn(x) { x * 2 }).filter(fn(x) { x > 4 })
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let _sub = doubled.subscribe_on_next(fn(v) { values.val.push(v) })
  println("map/filter 结果: \{@debug.to_string(values.val)}") // 期望 [6, 8, 10]

  // 2. 聚合：take 截断
  let taken = Ref::Ref(0)
  let rng : @rx.Observable[Int64, Unit] = @rx.Observable::range(0L, 100L)
  let _ = rng.take(3).subscribe_on_next(fn(_ : Int64) { taken.val = taken.val + 1 })
  println("take(3) 发射次数: \{taken.val}") // 期望 3

  // 3. Itor 可控制迭代器
  let doubled_itor = @rx.Itor::from_array([1, 2, 3]).map(fn(x) { x * 2 }).to_array()
  println("Itor map 结果: \{@debug.to_string(doubled_itor)}") // 期望 [2, 4, 6]

  // 4. 全链路：from_iter -> map -> take -> subscribe
  let flow : @rx.Observable[Int, Unit] =
    @rx.Observable::from_iter([1, 2, 3, 4, 5]).map(fn(x) { x * 10 }).take(4)
  let got = Ref::Ref(Array::new())
  let _ = flow.subscribe_on_next(fn(v : Int) { got.val.push(v) })
  println("全链路结果: \{@debug.to_string(got.val)}") // 期望 [10, 20, 30, 40]
}
