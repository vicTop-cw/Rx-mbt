// ============================================================================
// 错误处理与背压类操作符：retry / retry_indefinitely / retry_when /
// retry_with_backoff / catch_error / on_error_return / on_error_resume_next /
// backpressure_buffer / backpressure_drop / backpressure_error /
// backpressure_latest / circuit_breaker
// ============================================================================

/// retry：出错时重新订阅源流，最多重试 times 次
pub fn[T, E] Observable::retry(self : Observable[T, E], times : Int) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let attempts = Ref::Ref(0)
    let done = Ref::Ref(false)
    let try_ref = Ref::Ref(fn() {})
    let try_subscribe : () -> Unit = fn() {
      if done.val {
        return
      }
      let _ = source_fn({
        next: next,
        error: fn(e : E) {
          if attempts.val < times {
            attempts.val = attempts.val + 1
            (try_ref.val)()
          } else {
            done.val = true
            error(e)
          }
        },
        complete: fn() {
          if !done.val {
            done.val = true
            complete()
          }
        },
      })
    }
    try_ref.val = try_subscribe
    try_subscribe()
    Subscription::empty()
  }
  Observable::new(subscribe_fn)
}
/// retry_indefinitely：出错时无限重试
pub fn[T, E] Observable::retry_indefinitely(self : Observable[T, E]) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let _error = downstream.error
    let complete = downstream.complete
    let done = Ref::Ref(false)
    let try_ref = Ref::Ref(fn() {})
    let try_subscribe : () -> Unit = fn() {
      if done.val {
        return
      }
      let _ = source_fn({
        next: next,
        error: fn(_e : E) { (try_ref.val)() },
        complete: fn() {
          if !done.val {
            done.val = true
            complete()
          }
        },
      })
    }
    try_ref.val = try_subscribe
    try_subscribe()
    Subscription::empty()
  }
  Observable::new(subscribe_fn)
}
/// retry_when：出错时按条件决定是否重试
pub fn[T, E] Observable::retry_when(
  self : Observable[T, E],
  should_retry : (E) -> Bool,
) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let done = Ref::Ref(false)
    let try_ref = Ref::Ref(fn() {})
    let try_subscribe : () -> Unit = fn() {
      if done.val {
        return
      }
      let _ = source_fn({
        next: next,
        error: fn(e : E) {
          if should_retry(e) {
            (try_ref.val)()
          } else {
            done.val = true
            error(e)
          }
        },
        complete: fn() {
          if !done.val {
            done.val = true
            complete()
          }
        },
      })
    }
    try_ref.val = try_subscribe
    try_subscribe()
    Subscription::empty()
  }
  Observable::new(subscribe_fn)
}
/// retry_with_backoff：出错后按指数退避延迟重试（依赖默认虚拟时钟）
pub fn[T, E] Observable::retry_with_backoff(
  self : Observable[T, E],
  initial_ms : Int64,
) -> Observable[T, E] {
  self.retry_with_backoff_on(default_clock, initial_ms)
}

/// retry_with_backoff_on：指定虚拟时钟的指数退避重试
pub fn[T, E] Observable::retry_with_backoff_on(
  self : Observable[T, E],
  clock : Clock,
  initial_ms : Int64,
) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let _error = downstream.error
    let complete = downstream.complete
    let done = Ref::Ref(false)
    let attempts = Ref::Ref(0)
    let try_ref = Ref::Ref(fn() {})
    let try_subscribe : () -> Unit = fn() {
      if done.val {
        return
      }
      let _ = source_fn({
        next: next,
        error: fn(_e : E) {
          let shift = 1 << attempts.val
          let delay = initial_ms * Int64::from_int(shift)
          attempts.val = attempts.val + 1
          clock.set_timer(delay, fn() { (try_ref.val)() })
        },
        complete: fn() {
          if !done.val {
            done.val = true
            complete()
          }
        },
      })
    }
    try_ref.val = try_subscribe
    try_subscribe()
    Subscription::empty()
  }
  Observable::new(subscribe_fn)
}
/// catch_error：出错时切换到 handler 返回的备用流
pub fn[T, E] Observable::catch_error(
  self : Observable[T, E],
  handler : (E) -> Observable[T, E],
) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let done = Ref::Ref(false)
    source_fn({
      next: next,
      error: fn(e : E) {
        if !done.val {
          done.val = true
          let _ = handler(e).subscribe({
            next: next,
            error: error,
            complete: complete,
          })
        }
      },
      complete: fn() {
        if !done.val {
          done.val = true
          complete()
        }
      },
    })
  }
  Observable::new(subscribe_fn)
}

/// on_error_return：出错时发射给定值并完成
pub fn[T, E] Observable::on_error_return(
  self : Observable[T, E],
  value : T,
) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let complete = downstream.complete
    let done = Ref::Ref(false)
    source_fn({
      next: next,
      error: fn(_e : E) {
        if !done.val {
          done.val = true
          next(value)
          complete()
        }
      },
      complete: fn() {
        if !done.val {
          done.val = true
          complete()
        }
      },
    })
  }
  Observable::new(subscribe_fn)
}

/// on_error_resume_next：出错时接续发射 other 流
pub fn[T, E] Observable::on_error_resume_next(
  self : Observable[T, E],
  other : Observable[T, E],
) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let other_fn = other.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let done = Ref::Ref(false)
    source_fn({
      next: next,
      error: fn(_e : E) {
        if !done.val {
          done.val = true
          let _ = other_fn({
            next: next,
            error: error,
            complete: complete,
          })
        }
      },
      complete: fn() {
        if !done.val {
          done.val = true
          complete()
        }
      },
    })
  }
  Observable::new(subscribe_fn)
}

// ----------------------------------------------------------------------------
// 背压类：同步模型下没有慢消费者，以下实现为透传并保留 Rx-Rust 签名
// ----------------------------------------------------------------------------

/// backpressure_buffer：保留签名（同步模型下透传）
pub fn[T, E] Observable::backpressure_buffer(
  self : Observable[T, E],
  _buffer_size : Int,
) -> Observable[T, E] {
  self
}

/// backpressure_drop：保留签名（同步模型下透传）
pub fn[T, E] Observable::backpressure_drop(self : Observable[T, E]) -> Observable[T, E] {
  self
}

/// backpressure_error：缓冲区满（max_size）时发出错误（同步模型下透传）
pub fn[T, E] Observable::backpressure_error(
  self : Observable[T, E],
  _max_size : Int,
) -> Observable[T, E] {
  self
}

/// backpressure_latest：保留签名（同步模型下透传）
pub fn[T, E] Observable::backpressure_latest(self : Observable[T, E]) -> Observable[T, E] {
  self
}

/// circuit_breaker：熔断器。连续失败 max_failures 次后熔断，
/// 熔断期间错误被吞掉，reset_ms 毫秒后自动恢复（依赖默认虚拟时钟）
pub fn[T, E] Observable::circuit_breaker(
  self : Observable[T, E],
  max_failures : Int,
  reset_ms : Int64,
) -> Observable[T, E] {
  self.circuit_breaker_on(default_clock, max_failures, reset_ms)
}

/// circuit_breaker_on：指定虚拟时钟的熔断器
pub fn[T, E] Observable::circuit_breaker_on(
  self : Observable[T, E],
  clock : Clock,
  max_failures : Int,
  reset_ms : Int64,
) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let failures = Ref::Ref(0)
    let open_at = Ref::Ref(-1L)
    source_fn({
      next: fn(v : T) {
        failures.val = 0
        next(v)
      },
      error: fn(e : E) {
        if open_at.val >= 0L {
          if clock.now() - open_at.val >= reset_ms {
            open_at.val = -1L
            failures.val = 0
            error(e)
          }
        } else {
          failures.val = failures.val + 1
          if failures.val >= max_failures {
            open_at.val = clock.now()
          } else {
            error(e)
          }
        }
      },
      complete: complete,
    })
  }
  Observable::new(subscribe_fn)
}
