// ============================================================================
// 工具类操作符：tap / tap_on_next / timestamp / default_if_empty /
// ignore_elements / pairwise / pairwise_with_buffer / buffer_count /
// buffer_time / window / switch / sample_first / skip_until_data /
// take_until_data
// ============================================================================

/// tap：对每个值执行副作用后原样透传
pub fn[T, E] Observable::tap(
  self : Observable[T, E],
  f : (T) -> Unit,
) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    source_fn({
      next: fn(v : T) { f(v); next(v) },
      error: error,
      complete: complete,
    })
  }
  Observable::new(subscribe_fn)
}

/// tap_on_next：tap 的别名（只在 on_next 时触发副作用）
pub fn[T, E] Observable::tap_on_next(
  self : Observable[T, E],
  f : (T) -> Unit,
) -> Observable[T, E] {
  self.tap(f)
}

/// timestamp：给每个值打上虚拟时钟时间戳，发射 (value, ms)
pub fn[T, E] Observable::timestamp(self : Observable[T, E]) -> Observable[(T, Int64), E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[(T, Int64), E]) -> Subscription = fn(downstream : Observer[(T, Int64), E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    source_fn({
      next: fn(v : T) { next((v, default_clock.now())) },
      error: error,
      complete: complete,
    })
  }
  Observable::new(subscribe_fn)
}

/// default_if_empty：流为空时发射默认值
pub fn[T, E] Observable::default_if_empty(
  self : Observable[T, E],
  default_value : T,
) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let empty = Ref::Ref(true)
    source_fn({
      next: fn(v : T) { empty.val = false; next(v) },
      error: error,
      complete: fn() {
        if empty.val {
          next(default_value)
        }
        complete()
      },
    })
  }
  Observable::new(subscribe_fn)
}

/// ignore_elements：忽略所有值，只透传错误与完成
pub fn[T, E] Observable::ignore_elements(self : Observable[T, E]) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let error = downstream.error
    let complete = downstream.complete
    source_fn({
      next: fn(_ : T) {},
      error: error,
      complete: complete,
    })
  }
  Observable::new(subscribe_fn)
}

/// pairwise：相邻两个值配对发射 (prev, curr)
pub fn[T, E] Observable::pairwise(self : Observable[T, E]) -> Observable[(T, T), E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[(T, T), E]) -> Subscription = fn(downstream : Observer[(T, T), E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let init : T? = None
    let prev = Ref::Ref(init)
    source_fn({
      next: fn(v : T) {
        match prev.val {
          Some(p) => next((p, v))
          None => ()
        }
        prev.val = Some(v)
      },
      error: error,
      complete: complete,
    })
  }
  Observable::new(subscribe_fn)
}

/// pairwise_with_buffer：按 buffer_size 分块，相邻两个块配对发射
pub fn[T, E] Observable::pairwise_with_buffer(
  self : Observable[T, E],
  buffer_size : Int,
) -> Observable[(Array[T], Array[T]), E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[(Array[T], Array[T]), E]) -> Subscription =
    fn(downstream : Observer[(Array[T], Array[T]), E]) {
      let next = downstream.next
      let error = downstream.error
      let complete = downstream.complete
      let init_buf : (Array[T])? = None
      let prev = Ref::Ref(init_buf)
      let buf = Ref::Ref(Array::new())
      source_fn({
        next: fn(v : T) {
          buf.val.push(v)
          if buf.val.length() >= buffer_size {
            let chunk = buf.val
            buf.val = Array::new()
            match prev.val {
              Some(p) => {
                prev.val = Some(chunk)
                next((p, chunk))
              }
              None => prev.val = Some(chunk)
            }
          }
        },
        error: error,
        complete: complete,
      })
    }
  Observable::new(subscribe_fn)
}

/// buffer_count：每 buffer_size 个值发射一个批次数组
pub fn[T, E] Observable::buffer_count(
  self : Observable[T, E],
  buffer_size : Int,
) -> Observable[Array[T], E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[Array[T], E]) -> Subscription = fn(downstream : Observer[Array[T], E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let buf = Ref::Ref(Array::new())
    source_fn({
      next: fn(v : T) {
        buf.val.push(v)
        if buf.val.length() >= buffer_size {
          let chunk = buf.val
          buf.val = Array::new()
          next(chunk)
        }
      },
      error: error,
      complete: fn() {
        if !buf.val.is_empty() {
          next(buf.val)
        }
        complete()
      },
    })
  }
  Observable::new(subscribe_fn)
}

/// buffer_time：按时间窗口收集值，窗口到点发射一个批次（虚拟时钟驱动）
pub fn[T, E] Observable::buffer_time(
  self : Observable[T, E],
  ms : Int64,
) -> Observable[Array[T], E] {
  self.buffer_time_on(default_clock, ms)
}

/// buffer_time_on：指定虚拟时钟的按时间窗口缓冲
pub fn[T, E] Observable::buffer_time_on(
  self : Observable[T, E],
  clock : Clock,
  ms : Int64,
) -> Observable[Array[T], E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[Array[T], E]) -> Subscription = fn(downstream : Observer[Array[T], E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let buf = Ref::Ref(Array::new())
    let stopped = Ref::Ref(false)
    let timer_ref = Ref::Ref(fn() {})
    let tick : () -> Unit = fn() {
      if !stopped.val {
        let chunk = buf.val
        buf.val = Array::new()
        if !chunk.is_empty() {
          next(chunk)
        }
        clock.set_timer(ms, timer_ref.val)
      }
    }
    timer_ref.val = tick
    clock.set_timer(ms, tick)
    source_fn({
      next: fn(v : T) { buf.val.push(v) },
      error: error,
      complete: fn() {
        stopped.val = true
        if !buf.val.is_empty() {
          next(buf.val)
        }
        complete()
      },
    })
  }
  Observable::new(subscribe_fn)
}

/// window：按时间窗口把流切成子 Observable（虚拟时钟驱动）
pub fn[T, E] Observable::window(
  self : Observable[T, E],
  ms : Int64,
) -> Observable[Observable[T, E], E] {
  self.window_on(default_clock, ms)
}

/// window_on：指定虚拟时钟的窗口切分
pub fn[T, E] Observable::window_on(
  self : Observable[T, E],
  clock : Clock,
  ms : Int64,
) -> Observable[Observable[T, E], E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[Observable[T, E], E]) -> Subscription =
    fn(downstream : Observer[Observable[T, E], E]) {
      let next = downstream.next
      let error = downstream.error
      let complete = downstream.complete
      let buf = Ref::Ref(Array::new())
      let stopped = Ref::Ref(false)
      let timer_ref = Ref::Ref(fn() {})
      let tick : () -> Unit = fn() {
        if !stopped.val {
          let chunk = buf.val
          buf.val = Array::new()
          if !chunk.is_empty() {
            next(Observable::from_iter(chunk))
          }
          clock.set_timer(ms, timer_ref.val)
        }
      }
      timer_ref.val = tick
      clock.set_timer(ms, tick)
      source_fn({
        next: fn(v : T) { buf.val.push(v) },
        error: error,
        complete: fn() {
          stopped.val = true
          if !buf.val.is_empty() {
            next(Observable::from_iter(buf.val))
          }
          complete()
        },
      })
    }
  Observable::new(subscribe_fn)
}

/// switch：切换到最新的内部 Observable（前一个内部订阅被取消）
pub fn[T, E] switch(source : Observable[Observable[T, E], E]) -> Observable[T, E] {
  let source_fn = source.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let init_sub : (Subscription)? = None
    let current = Ref::Ref(init_sub)
    source_fn({
      next: fn(inner : Observable[T, E]) {
        match current.val {
          Some(sub) => sub.dispose()
          None => ()
        }
        let sub = inner.subscribe({
          next: next,
          error: error,
          complete: fn() {},
        })
        current.val = Some(sub)
      },
      error: error,
      complete: complete,
    })
  }
  Observable::new(subscribe_fn)
}

/// sample_first：只取第一个值后完成
pub fn[T, E] sample_first(source : Observable[T, E]) -> Observable[T, E] {
  let source_fn = source.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let found = Ref::Ref(false)
    source_fn({
      next: fn(v : T) {
        if !found.val {
          found.val = true
          next(v)
          complete()
        }
      },
      error: error,
      complete: complete,
    })
  }
  Observable::new(subscribe_fn)
}

/// skip_until_data：跳过，直到第一个满足谓词的值出现后放行
pub fn[T, E] Observable::skip_until_data(
  self : Observable[T, E],
  predicate : (T) -> Bool,
) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let passing = Ref::Ref(false)
    source_fn({
      next: fn(v : T) {
        if !passing.val {
          if predicate(v) {
            passing.val = true
          } else {
            return
          }
        }
        next(v)
      },
      error: error,
      complete: complete,
    })
  }
  Observable::new(subscribe_fn)
}

/// take_until_data：一直取值，遇到第一个满足谓词的值后停止并完成
pub fn[T, E] Observable::take_until_data(
  self : Observable[T, E],
  predicate : (T) -> Bool,
) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let stopped = Ref::Ref(false)
    source_fn({
      next: fn(v : T) {
        if !stopped.val {
          next(v)
          if predicate(v) {
            stopped.val = true
            complete()
          }
        }
      },
      error: error,
      complete: complete,
    })
  }
  Observable::new(subscribe_fn)
}

/// run：立即订阅并消费全部值（触发副作用），再返回原样 Observable
/// 等价于 `source.subscribe(noop); source`，常用于触发 do_on_next 等副作用
pub fn[T, E] Observable::run(self : Observable[T, E]) -> Observable[T, E] {
  let _ = self.subscribe_on_next(fn(_ : T) {})
  self
}

/// debug：调试模式，打印订阅 / 接收 / 完成事件后原样透传
/// name 为前缀名，默认 "[Observable]"
pub fn[T, E] Observable::debug(
  self : Observable[T, E],
  name : String?,
) -> Observable[T, E] {
  let prefix = match name {
    Some(n) => n
    None => "[Observable]"
  }
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    println("\{prefix} subscribed")
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    source_fn({
      next: fn(v : T) {
        println("\{prefix} on_next")
        next(v)
      },
      error: fn(e : E) {
        println("\{prefix} on_error")
        error(e)
      },
      complete: fn() {
        println("\{prefix} on_completed")
        complete()
      },
    })
  }
  Observable::new(subscribe_fn)
}
