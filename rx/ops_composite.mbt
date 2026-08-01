// ============================================================================
// 组合类操作符：start_with / concat / merge / zip / combine_latest /
// with_latest_from / amb / end_with / iif / sequence_equal
// ============================================================================

/// start_with：先发射前缀数组中的值，再发射自身
pub fn[T, E] Observable::start_with(
  self : Observable[T, E],
  prefix : Array[T],
) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    for v in prefix {
      next(v)
    }
    source_fn({
      next: next,
      error: error,
      complete: complete,
    })
  }
  Observable::new(subscribe_fn)
}

/// concat：自身完成后接续 other
pub fn[T, E] Observable::concat(
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
      error: error,
      complete: fn() {
        if !done.val {
          done.val = true
          let _ = other_fn({
            next: next,
            error: error,
            complete: complete,
          })
        }
      },
    })
  }
  Observable::new(subscribe_fn)
}

/// merge：合并两个流（同步语义下等价 concat，顺序发射）
pub fn[T, E] Observable::merge(
  self : Observable[T, E],
  other : Observable[T, E],
) -> Observable[T, E] {
  self.concat(other)
}

/// merge：自由函数版
pub fn[T, E] merge(
  a : Observable[T, E],
  b : Observable[T, E],
) -> Observable[T, E] {
  a.concat(b)
}

/// zip：按位置配对两个流的值，两者都完成后一次性按序发射
pub fn[T, E, U] zip(
  a : Observable[T, E],
  b : Observable[U, E],
) -> Observable[(T, U), E] {
  let a_fn = a.subscribe_fn
  let b_fn = b.subscribe_fn
  let subscribe_fn : (Observer[(T, U), E]) -> Subscription = fn(downstream : Observer[(T, U), E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let buf_a = Ref::Ref(Array::new())
    let buf_b = Ref::Ref(Array::new())
    let done_a = Ref::Ref(false)
    let done_b = Ref::Ref(false)
    let emitted = Ref::Ref(false)
    let both_subscribed = Ref::Ref(false)
    let try_emit : () -> Unit = fn() {
      // Rx 语义：双方都订阅后，任一源完成即终止（先把已缓冲的配对发完）
      if both_subscribed.val && (done_a.val || done_b.val) && !emitted.val {
        emitted.val = true
        let na = buf_a.val.length()
        let nb = buf_b.val.length()
        let n = if na < nb { na } else { nb }
        for i = 0; i < n; i = i + 1 {
          next((buf_a.val[i], buf_b.val[i]))
        }
        complete()
      }
    }
    let _ = a_fn({
      next: fn(v : T) { buf_a.val.push(v) },
      error: error,
      complete: fn() { done_a.val = true; try_emit() },
    })
    let b_sub = b_fn({
      next: fn(v : U) { buf_b.val.push(v) },
      error: error,
      complete: fn() { done_b.val = true; try_emit() },
    })
    both_subscribed.val = true
    try_emit()
    b_sub
  }
  Observable::new(subscribe_fn)
}

/// zip：方法版
pub fn[T, E, U] Observable::zip(
  self : Observable[T, E],
  other : Observable[U, E],
) -> Observable[(T, U), E] {
  zip(self, other)
}

/// combine_latest：任一源发值时，发射两个源最新值的组合
pub fn[T, E, U] combine_latest(
  a : Observable[T, E],
  b : Observable[U, E],
) -> Observable[(T, U), E] {
  let a_fn = a.subscribe_fn
  let b_fn = b.subscribe_fn
  let subscribe_fn : (Observer[(T, U), E]) -> Subscription = fn(downstream : Observer[(T, U), E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let init_a : T? = None
    let init_b : U? = None
    let last_a = Ref::Ref(init_a)
    let last_b = Ref::Ref(init_b)
    let done_a = Ref::Ref(false)
    let done_b = Ref::Ref(false)
    let try_emit : () -> Unit = fn() {
      match (last_a.val, last_b.val) {
        (Some(x), Some(y)) => next((x, y))
        _ => ()
      }
    }
    let maybe_complete : () -> Unit = fn() {
      if done_a.val && done_b.val {
        complete()
      }
    }
    let _ = a_fn({
      next: fn(v : T) { last_a.val = Some(v); try_emit() },
      error: error,
      complete: fn() { done_a.val = true; maybe_complete() },
    })
    b_fn({
      next: fn(v : U) { last_b.val = Some(v); try_emit() },
      error: error,
      complete: fn() { done_b.val = true; maybe_complete() },
    })
  }
  Observable::new(subscribe_fn)
}

/// with_latest_from：a 每次发值时，携带 b 的最新值一起发射
pub fn[T, E, U] with_latest_from(
  a : Observable[T, E],
  b : Observable[U, E],
) -> Observable[(T, U), E] {
  let a_fn = a.subscribe_fn
  let b_fn = b.subscribe_fn
  let subscribe_fn : (Observer[(T, U), E]) -> Subscription = fn(downstream : Observer[(T, U), E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let init : U? = None
    let last_b = Ref::Ref(init)
    let _ = b_fn({
      next: fn(v : U) { last_b.val = Some(v) },
      error: error,
      complete: fn() {},
    })
    let done = Ref::Ref(false)
    a_fn({
      next: fn(v : T) {
        match last_b.val {
          Some(u) => next((v, u))
          None => ()
        }
      },
      error: error,
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

/// amb：先发射的流胜出，另一方被忽略
pub fn[T, E] amb(
  a : Observable[T, E],
  b : Observable[T, E],
) -> Observable[T, E] {
  let a_fn = a.subscribe_fn
  let b_fn = b.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let winner = Ref::Ref(0)
    let done = Ref::Ref(false)
    let _ = a_fn({
      next: fn(v : T) {
        if winner.val == 0 { winner.val = 1 }
        if winner.val == 1 { next(v) }
      },
      error: error,
      complete: fn() {
        if !done.val && winner.val != 2 {
          done.val = true
          complete()
        }
      },
    })
    b_fn({
      next: fn(v : T) {
        if winner.val == 0 { winner.val = 2 }
        if winner.val == 2 { next(v) }
      },
      error: error,
      complete: fn() {
        if !done.val && winner.val != 1 {
          done.val = true
          complete()
        }
      },
    })
  }
  Observable::new(subscribe_fn)
}

/// end_with：流完成前追加后缀值
pub fn[T, E] Observable::end_with(
  self : Observable[T, E],
  suffix : Array[T],
) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let done = Ref::Ref(false)
    source_fn({
      next: next,
      error: error,
      complete: fn() {
        if !done.val {
          done.val = true
          for v in suffix {
            next(v)
          }
          complete()
        }
      },
    })
  }
  Observable::new(subscribe_fn)
}

/// iif：按条件选择发射哪个流
pub fn[T, E] iif(
  condition : Bool,
  then : Observable[T, E],
  otherwise : Observable[T, E],
) -> Observable[T, E] {
  if condition { then } else { otherwise }
}

/// sequence_equal：比较两个流的值序列是否完全相等
pub fn[T : Eq, E] sequence_equal(
  a : Observable[T, E],
  b : Observable[T, E],
) -> Observable[Bool, E] {
  let a_fn = a.subscribe_fn
  let b_fn = b.subscribe_fn
  let subscribe_fn : (Observer[Bool, E]) -> Subscription = fn(downstream : Observer[Bool, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let buf_a = Ref::Ref(Array::new())
    let buf_b = Ref::Ref(Array::new())
    let done_a = Ref::Ref(false)
    let done_b = Ref::Ref(false)
    let emitted = Ref::Ref(false)
    let try_emit : () -> Unit = fn() {
      if done_a.val && done_b.val && !emitted.val {
        emitted.val = true
        let arr_a = buf_a.val
        let arr_b = buf_b.val
        let equal = if arr_a.length() != arr_b.length() {
          false
        } else {
          let mut same = true
          for i = 0; i < arr_a.length(); i = i + 1 {
            if arr_a[i] != arr_b[i] {
              same = false
              break
            }
          }
          same
        }
        next(equal)
        complete()
      }
    }
    let _ = a_fn({
      next: fn(v : T) { buf_a.val.push(v) },
      error: error,
      complete: fn() { done_a.val = true; try_emit() },
    })
    b_fn({
      next: fn(v : T) { buf_b.val.push(v) },
      error: error,
      complete: fn() { done_b.val = true; try_emit() },
    })
  }
  Observable::new(subscribe_fn)
}
