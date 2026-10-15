// ============================================================================
// rx-mbt —— MoonBit 实现的响应式编程库（Rx-Rust 的 MoonBit 复刻）
// 核心抽象：Observer / Subscription / Observable + 创建类工厂函数
// ============================================================================

/// 观察者：承载三个回调（on_next / on_error / on_completed）
/// `interrupt` 是同步源与下游之间的中断通道（Ref 引用共享）：
/// 同步无限源（iterate / repeat_infinite / cycle / unfoldr）在订阅时
/// 把"停止函数"写入 interrupt，take / take_while 取够后调用它中断同步循环。
pub struct Observer[T, E] {
  next : (T) -> Unit
  error : (E) -> Unit
  complete : () -> Unit
  interrupt : Ref[(() -> Unit)?]
}

/// 构造一个 Observer
pub fn[T, E] Observer::new(
  next : (T) -> Unit,
  error : (E) -> Unit,
  complete : () -> Unit,
) -> Observer[T, E] {
  {
    next: next,
    error: error,
    complete: complete,
    interrupt: Ref::Ref(None),
  }
}

/// 发射一个值
pub fn[T, E] Observer::on_next(self : Observer[T, E], value : T) -> Unit {
  (self.next)(value)
}

/// 发射一个错误
pub fn[T, E] Observer::on_error(self : Observer[T, E], err : E) -> Unit {
  (self.error)(err)
}

/// 通知完成
pub fn[T, E] Observer::on_completed(self : Observer[T, E]) -> Unit {
  (self.complete)()
}

/// 只关心 on_next 的便捷构造（其余回调为空操作）
pub fn[T, E] Observer::on_next_only(next : (T) -> Unit) -> Observer[T, E] {
  {
    next: next,
    error: fn(_err : E) {},
    complete: fn() {},
    interrupt: Ref::Ref(None),
  }
}

// ============================================================================
// Subscription —— 订阅句柄
// ============================================================================

/// 订阅句柄：可 dispose 取消订阅
pub struct Subscription {
  disposed : Ref[Bool]
  dispose_fn : () -> Unit
}

/// 空订阅（dispose 无副作用）
pub fn Subscription::empty() -> Subscription {
  { disposed: Ref::Ref(false), dispose_fn: fn() {} }
}

/// 创建订阅：dispose 时执行回调（仅一次）
pub fn Subscription::new(dispose_fn : () -> Unit) -> Subscription {
  { disposed: Ref::Ref(false), dispose_fn: dispose_fn }
}

/// 取消订阅（幂等）
pub fn Subscription::dispose(self : Subscription) -> Unit {
  if !self.disposed.val {
    self.disposed.val = true
    (self.dispose_fn)()
  }
}

/// 是否已取消
pub fn Subscription::is_disposed(self : Subscription) -> Bool {
  self.disposed.val
}

// ============================================================================
// Observable —— 可观察对象
// ============================================================================

/// 可观察对象：包装一个订阅函数（冷流，每次 subscribe 重新执行）
pub struct Observable[T, E] {
  subscribe_fn : (Observer[T, E]) -> Subscription
}

/// 用订阅函数构造 Observable
pub fn[T, E] Observable::new(f : (Observer[T, E]) -> Subscription) -> Observable[T, E] {
  { subscribe_fn: f }
}

/// 订阅：传入 Observer，返回 Subscription
pub fn[T, E] Observable::subscribe(
  self : Observable[T, E],
  observer : Observer[T, E],
) -> Subscription {
  (self.subscribe_fn)(observer)
}

/// 订阅：只关心 on_next
pub fn[T, E] Observable::subscribe_on_next(
  self : Observable[T, E],
  next : (T) -> Unit,
) -> Subscription {
  self.subscribe(Observer::on_next_only(next))
}

/// 订阅：只关心 on_error
pub fn[T, E] Observable::subscribe_on_error(
  self : Observable[T, E],
  error : (E) -> Unit,
) -> Subscription {
  self.subscribe({
    next: fn(_value : T) {},
    error: error,
    complete: fn() {}, interrupt: Ref::Ref(None),
  })
}

/// 订阅：只关心 on_completed
pub fn[T, E] Observable::subscribe_on_completed(
  self : Observable[T, E],
  complete : () -> Unit,
) -> Subscription {
  self.subscribe({
    next: fn(_value : T) {},
    error: fn(_err : E) {},
    complete: complete, interrupt: Ref::Ref(None),
  })
}

// ============================================================================
// 创建类工厂函数
// ============================================================================

/// 从数组创建一个同步发射所有值后完成的 Observable
pub fn[T, E] Observable::from_iter(values : Array[T]) -> Observable[T, E] {
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(observer : Observer[T, E]) {
    for v in values {
      observer.on_next(v)
    }
    observer.on_completed()
    Subscription::empty()
  }
  Observable::new(subscribe_fn)
}

/// 发射单个值后完成
pub fn[T, E] Observable::of(value : T) -> Observable[T, E] {
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(observer : Observer[T, E]) {
    observer.on_next(value)
    observer.on_completed()
    Subscription::empty()
  }
  Observable::new(subscribe_fn)
}

/// 重复发射同一个值 count 次后完成
pub fn[T, E] Observable::repeat(value : T, count : Int) -> Observable[T, E] {
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(observer : Observer[T, E]) {
    let mut i = 0
    while i < count {
      observer.on_next(value)
      i = i + 1
    }
    observer.on_completed()
    Subscription::empty()
  }
  Observable::new(subscribe_fn)
}

/// 立即完成的空流
pub fn[T, E] Observable::empty() -> Observable[T, E] {
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(observer : Observer[T, E]) {
    observer.on_completed()
    Subscription::empty()
  }
  Observable::new(subscribe_fn)
}

/// 永不发射、永不完成的流
pub fn[T, E] Observable::never() -> Observable[T, E] {
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(_observer : Observer[T, E]) {
    Subscription::empty()
  }
  Observable::new(subscribe_fn)
}

/// 立即发射错误的流
pub fn[T, E] Observable::error(err : E) -> Observable[T, E] {
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(observer : Observer[T, E]) {
    observer.on_error(err)
    Subscription::empty()
  }
  Observable::new(subscribe_fn)
}

/// 发射 [start, start+count) 的整数序列后完成
pub fn[E] Observable::range(start : Int64, count : Int64) -> Observable[Int64, E] {
  let subscribe_fn : (Observer[Int64, E]) -> Subscription = fn(observer : Observer[Int64, E]) {
    let mut i : Int64 = 0L
    while i < count {
      observer.on_next(start + i)
      i = i + 1L
    }
    observer.on_completed()
    Subscription::empty()
  }
  Observable::new(subscribe_fn)
}

/// 从 start 到 end（不含）发射整数序列
pub fn[E] Observable::from_range(start : Int64, end : Int64) -> Observable[Int64, E] {
  let subscribe_fn : (Observer[Int64, E]) -> Subscription = fn(observer : Observer[Int64, E]) {
    let mut i = start
    while i < end {
      observer.on_next(i)
      i = i + 1L
    }
    observer.on_completed()
    Subscription::empty()
  }
  Observable::new(subscribe_fn)
}

/// 从 start 到 end（不含）按 step 步长发射整数序列
pub fn[E] Observable::from_range_with_step(
  start : Int64,
  end : Int64,
  step : Int64,
) -> Observable[Int64, E] {
  let subscribe_fn : (Observer[Int64, E]) -> Subscription = fn(observer : Observer[Int64, E]) {
    let mut i = start
    if step > 0L {
      while i < end {
        observer.on_next(i)
        i = i + step
      }
    } else if step < 0L {
      while i > end {
        observer.on_next(i)
        i = i + step
      }
    }
    observer.on_completed()
    Subscription::empty()
  }
  Observable::new(subscribe_fn)
}

/// 订阅时调用函数并发射其返回值（之后完成）
pub fn[T, E] Observable::from_callable(f : () -> T) -> Observable[T, E] {
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(observer : Observer[T, E]) {
    observer.on_next(f())
    observer.on_completed()
    Subscription::empty()
  }
  Observable::new(subscribe_fn)
}

/// from_callable 的别名
pub fn[T, E] Observable::start(f : () -> T) -> Observable[T, E] {
  Observable::from_callable(f)
}

// ============================================================================
// 单元测试
// ============================================================================

///|
/// 测试辅助：构造 None 选项
fn init_none() -> String? {
  None
}

///|
test "of 发射单值并完成" {
  let values = Ref::Ref(Array(capacity=0))
  let done = Ref::Ref(false)
  let obs : Observable[Int, Unit] = Observable::of(42)
  let _ = obs.subscribe({
    next: fn(x : Int) { values.val.push(x) },
    error: fn(_ : Unit) {  },
    complete: fn() { done.val = true }, interrupt: Ref::Ref(None),
  })
  assert_eq(values.val, [42])
  assert_true(done.val)
}

///|
test "from_iter 发射全部值" {
  let values = Ref::Ref(Array(capacity=0))
  let obs : Observable[Int, Unit] = Observable::from_iter([1, 2, 3, 4, 5])
  let _ = obs.subscribe_on_next(fn(x) { values.val.push(x) })
  assert_eq(values.val, [1, 2, 3, 4, 5])
}

test "range 发射正确序列" {
  let values = Ref::Ref(Array(capacity=0))
  let obs : Observable[Int64, Unit] = Observable::range(10L, 3L)
  let _ = obs.subscribe_on_next(fn(x) { values.val.push(x) })
  assert_eq(values.val, [10L, 11L, 12L])
}

///|
test "empty 立即完成" {
  let done = Ref::Ref(false)
  let obs : Observable[Int, Unit] = Observable::empty()
  let _ = obs.subscribe({
    next: fn(_ : Int) {  },
    error: fn(_ : Unit) {  },
    complete: fn() { done.val = true }, interrupt: Ref::Ref(None),
  })
  assert_true(done.val)
}

test "error 发射错误不发射值" {
  let got_err = Ref::Ref(init_none())
  let obs : Observable[Int, String] = Observable::error("boom")
  let _ = obs.subscribe({
    next: fn(_ : Int) {},
    error: fn(err : String) { got_err.val = Some(err) },
    complete: fn() {}, interrupt: Ref::Ref(None),
  })
  assert_eq(got_err.val, Some("boom"))
}

test "repeat 重复发射" {
  let values = Ref::Ref(Array(capacity=0))
  let obs : Observable[Int, Unit] = Observable::repeat(7, 3)
  let _ = obs.subscribe_on_next(fn(x) { values.val.push(x) })
  assert_eq(values.val, [7, 7, 7])
}

///|
test "订阅可取消（幂等）" {
  let sub = Subscription::new(fn() {  })
  assert_true(!sub.is_disposed())
  sub.dispose()
  assert_true(sub.is_disposed())
  sub.dispose()
  assert_true(sub.is_disposed())
}
