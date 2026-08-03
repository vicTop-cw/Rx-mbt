import @rx

///|
/// 依赖验证入口：通过外部依赖声明（git 源）引入 vicTop-cw/RX-MBT，
/// 运行一组 rx 核心 API 并打印结果，确认依赖拉取、编译、运行全链路可用。
fn main {
  // 1. 创建 + 转换：of / map / filter
  let obs : @rx.Observable[Int, Unit] =
    @rx.Observable::of(1).map(fn(x) { x + 1 }).filter(fn(x) { x % 2 == 0 })

  let values : @rx.Ref[Array[Int]] = { val: [] }
  let done = { val: false }
  let _ = obs.subscribe(
    {
      next: fn(v : Int) { values.val.push(v) },
      error: fn(_err : Unit) {  },
      complete: fn() { done.val = true },
      interrupt: { val: None },
    },
  )
  println("map/filter 结果: \(values.val), 完成: \(done.val)")

  // 2. 聚合：take
  let taken = { val: 0 }
  let _ = @rx.Observable::range[Unit](0, 100).take(3).subscribe_on_next(fn(_ : Int64) {
    taken.val = taken.val + 1
  })
  println("take(3) 发射次数: \(taken.val)")

  // 3. Itor 迭代器
  let doubled = @rx.Itor::from_array([1, 2, 3]).map(fn(x) { x * 2 }).to_array()
  println("Itor map 结果: \(doubled)")

  // 4. 简易流程测试（同步流经所有操作符）
  let flow : @rx.Observable[Int, Unit] =
    @rx.Observable::from_iter([1, 2, 3, 4, 5]).map(fn(x) { x * 10 }).take(4)
  let got = { val: [] }
  let _ = flow.subscribe_on_next(fn(v : Int) { got.val.push(v) })
  println("全链路结果: \(got.val)")
}
