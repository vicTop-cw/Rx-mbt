///|
/// RX-MBT 库使用示例：以三方依赖方式引用 `vicTop-cw/RX-MBT/rx`（别名 @rx）
/// 运行：`moon run cmd/main`

fn main {
  // 创建冷流并链式操作：map -> filter -> collect
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3, 4, 5])
  let doubled = obs.map(fn(x) { x * 2 }).filter(fn(x) { x > 4 })
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let _sub = doubled.subscribe_on_next(fn(v) { values.val.push(v) })
  println("结果: \{@debug.to_string(values.val)}") // 结果: [6, 8, 10]

  // Subject 多播
  let subject : @rx.PublishSubject[Int, Unit] = @rx.PublishSubject::new()
  let _ = subject.subscribe(@rx.Observer::on_next_only(fn(v) { println("收到: \{v}") }))
  subject.on_next(42)
  subject.on_completed()
}
