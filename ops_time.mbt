// ============================================================================
// 时间类操作符：虚拟时钟 Clock + interval / timer / delay / debounce /
// throttle / throttle_first / timeout / sample / rate_limit
//
// 说明：MoonBit 稳定版标准库无线程/定时器，时间类操作符基于虚拟时钟
// （Clock）实现：调用 `advance_time(ms)` 或 `Clock::advance` 推进时间，
// 到期的定时器会按注册顺序触发，行为完全确定、可测试。
// ============================================================================

/// 虚拟时钟：毫秒计数 + 定时器队列，通过 advance 手动推进
pub struct Clock {
  ms : Ref[Int64]
  timers : Ref[Array[(Int64, () -> Unit)]]
}

/// 创建虚拟时钟（时间从 0 开始）
pub fn Clock::new() -> Clock {
  { ms: Ref::Ref(0L), timers: Ref::Ref(Array::new()) }
}

/// 当前虚拟时间（毫秒）
pub fn Clock::now(self : Clock) -> Int64 {
  self.ms.val
}

/// 推进时钟 ms 毫秒，触发所有到期的定时器
pub fn Clock::advance(self : Clock, ms : Int64) -> Unit {
  self.ms.val = self.ms.val + ms
  let target = self.ms.val
  let remaining = Array::new()
  let due = Array::new()
  for t in self.timers.val {
    if t.0 <= target {
      due.push(t)
    } else {
      remaining.push(t)
    }
  }
  self.timers.val = remaining
  for t in due {
    (t.1)()
  }
}

/// 注册定时器：delay_ms 毫秒后触发 fire（内部使用）
fn Clock::set_timer(self : Clock, delay_ms : Int64, fire : () -> Unit) -> Unit {
  self.timers.val.push((self.ms.val + delay_ms, fire))
}

/// 默认虚拟时钟（全局共享）
let default_clock : Clock = Clock::new()

/// 推进默认虚拟时钟（测试/使用时间操作符时调用）
pub fn advance_time(ms : Int64) -> Unit {
  default_clock.advance(ms)
}

// ----------------------------------------------------------------------------
// interval / timer —— 创建类时间操作符
// ----------------------------------------------------------------------------

/// interval：每隔 ms 毫秒发射自增整数（0, 1, 2, ...），依赖默认虚拟时钟
pub fn interval(ms : Int64) -> Observable[Int64, Unit] {
  interval_on(default_clock, ms)
}

/// interval_on：指定虚拟时钟的 interval
pub fn interval_on(clock : Clock, ms : Int64) -> Observable[Int64, Unit] {
  Observable::new(fn(downstream : Observer[Int64, Unit]) -> Subscription {
    let next = downstream.next
    let counter = Ref::Ref(0L)
    let stopped = Ref::Ref(false)
    let timer_ref = Ref::Ref(fn() {})
    let tick : () -> Unit = fn() {
      if !stopped.val {
        let v = counter.val
        counter.val = counter.val + 1L
        next(v)
        clock.set_timer(ms, timer_ref.val)
      }
    }
    timer_ref.val = tick
    clock.set_timer(ms, tick)
    Subscription::new(fn() { stopped.val = true })
  })
}

/// timer：延迟 ms 毫秒后发射 0 并完成
pub fn timer(ms : Int64) -> Observable[Int64, Unit] {
  timer_on(default_clock, ms)
}

/// timer_on：指定虚拟时钟的 timer
pub fn timer_on(clock : Clock, ms : Int64) -> Observable[Int64, Unit] {
  Observable::new(fn(downstream : Observer[Int64, Unit]) -> Subscription {
    let next = downstream.next
    let complete = downstream.complete
    let stopped = Ref::Ref(false)
    clock.set_timer(ms, fn() {
      if !stopped.val {
        next(0L)
        complete()
      }
    })
    Subscription::new(fn() { stopped.val = true })
  })
}

// ----------------------------------------------------------------------------
// 时间转换/过滤操作符
// ----------------------------------------------------------------------------

/// delay：每个值延迟 ms 毫秒后发射（依赖默认虚拟时钟）
pub fn[T, E] Observable::delay(self : Observable[T, E], ms : Int64) -> Observable[T, E] {
  self.delay_on(default_clock, ms)
}

/// delay_on：指定虚拟时钟的 delay
pub fn[T, E] Observable::delay_on(
  self : Observable[T, E],
  clock : Clock,
  ms : Int64,
) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    source_fn({
      next: fn(v : T) { clock.set_timer(ms, fn() { next(v) }) },
      error: error,
      complete: complete,
    })
  }
  Observable::new(subscribe_fn)
}

/// debounce：防抖，值停止发射 ms 毫秒后发出最后一个值（依赖默认虚拟时钟）
pub fn[T, E] Observable::debounce(self : Observable[T, E], ms : Int64) -> Observable[T, E] {
  self.debounce_on(default_clock, ms)
}

/// debounce_on：指定虚拟时钟的 debounce
pub fn[T, E] Observable::debounce_on(
  self : Observable[T, E],
  clock : Clock,
  ms : Int64,
) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let init : T? = None
    let last_val = Ref::Ref(init)
    let running = Ref::Ref(false)
    source_fn({
      next: fn(v : T) {
        last_val.val = Some(v)
        if !running.val {
          running.val = true
          clock.set_timer(ms, fn() {
            running.val = false
            match last_val.val {
              Some(x) => next(x)
              None => ()
            }
          })
        }
      },
      error: error,
      complete: complete,
    })
  }
  Observable::new(subscribe_fn)
}

/// throttle：节流，每 ms 毫秒最多放行一个值（依赖默认虚拟时钟）
pub fn[T, E] Observable::throttle(self : Observable[T, E], ms : Int64) -> Observable[T, E] {
  self.throttle_on(default_clock, ms)
}

/// throttle_on：指定虚拟时钟的 throttle
pub fn[T, E] Observable::throttle_on(
  self : Observable[T, E],
  clock : Clock,
  ms : Int64,
) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let last_fired = Ref::Ref(0L)
    source_fn({
      next: fn(v : T) {
        let now = clock.now()
        if now >= last_fired.val {
          last_fired.val = now + ms
          next(v)
        }
      },
      error: error,
      complete: complete,
    })
  }
  Observable::new(subscribe_fn)
}

/// throttle_first：throttle 的别名（每个窗口的第一个值放行）
pub fn[T, E] Observable::throttle_first(self : Observable[T, E], ms : Int64) -> Observable[T, E] {
  self.throttle(ms)
}

/// rate_limit：限流，每 ms 毫秒最多一个值（与 throttle 同语义）
pub fn[T, E] Observable::rate_limit(self : Observable[T, E], ms : Int64) -> Observable[T, E] {
  self.rate_limit_on(default_clock, ms)
}

/// rate_limit_on：指定虚拟时钟的 rate_limit
pub fn[T, E] Observable::rate_limit_on(
  self : Observable[T, E],
  clock : Clock,
  ms : Int64,
) -> Observable[T, E] {
  self.throttle_on(clock, ms)
}

/// timeout：超过 ms 毫秒没有值则发错误（需要 E : Default）
pub fn[T, E : Default] Observable::timeout(self : Observable[T, E], ms : Int64) -> Observable[T, E] {
  self.timeout_on(default_clock, ms)
}

/// timeout_on：指定虚拟时钟的 timeout
pub fn[T, E : Default] Observable::timeout_on(
  self : Observable[T, E],
  clock : Clock,
  ms : Int64,
) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let stopped = Ref::Ref(false)
    let due = Ref::Ref(clock.now() + ms)
    let armed = Ref::Ref(false)
    let arm_ref = Ref::Ref(fn() {})
    let arm : () -> Unit = fn() {
      if stopped.val {
        return
      }
      if !armed.val {
        armed.val = true
        clock.set_timer(ms, fn() {
          armed.val = false
          if clock.now() >= due.val {
            stopped.val = true
            error(E::default())
          } else {
            (arm_ref.val)()
          }
        })
      }
    }
    arm_ref.val = arm
    arm()
    source_fn({
      next: fn(v : T) {
        if !stopped.val {
          next(v)
          due.val = clock.now() + ms
          arm()
        }
      },
      error: error,
      complete: fn() {
        stopped.val = true
        complete()
      },
    })
  }
  Observable::new(subscribe_fn)
}

/// sample：每 ms 毫秒采样一次最近的值（依赖默认虚拟时钟）
pub fn[T, E] Observable::sample(self : Observable[T, E], ms : Int64) -> Observable[T, E] {
  self.sample_on(default_clock, ms)
}

/// sample_on：指定虚拟时钟的 sample
pub fn[T, E] Observable::sample_on(
  self : Observable[T, E],
  clock : Clock,
  ms : Int64,
) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let init : T? = None
    let latest = Ref::Ref(init)
    let stopped = Ref::Ref(false)
    let timer_ref = Ref::Ref(fn() {})
    let tick : () -> Unit = fn() {
      if !stopped.val {
        let v = latest.val
        latest.val = None
        match v {
          Some(x) => next(x)
          None => ()
        }
        clock.set_timer(ms, timer_ref.val)
      }
    }
    timer_ref.val = tick
    clock.set_timer(ms, tick)
    source_fn({
      next: fn(v : T) { latest.val = Some(v) },
      error: error,
      complete: fn() {
        stopped.val = true
        complete()
      },
    })
  }
  Observable::new(subscribe_fn)
}
