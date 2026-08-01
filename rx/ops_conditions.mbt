// ============================================================================
// 条件类操作符：every / some / find / find_index / is_empty
// ============================================================================

/// every：所有值都满足谓词时发 true（流结束时）；任一不满足发 false
pub fn[T, E] Observable::every(
  self : Observable[T, E],
  predicate : (T) -> Bool,
) -> Observable[Bool, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[Bool, E]) -> Subscription = fn(downstream : Observer[Bool, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let done = Ref::Ref(false)
    source_fn({
      next: fn(v : T) {
        if !done.val {
          if !predicate(v) {
            done.val = true
            next(false)
            complete()
          }
        }
      },
      error: error,
      complete: fn() {
        if !done.val {
          done.val = true
          next(true)
        }
        complete()
      },
    })
  }
  Observable::new(subscribe_fn)
}

/// some：任一值满足谓词发 true（立即完成）；流结束时发 false
pub fn[T, E] Observable::some(
  self : Observable[T, E],
  predicate : (T) -> Bool,
) -> Observable[Bool, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[Bool, E]) -> Subscription = fn(downstream : Observer[Bool, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let done = Ref::Ref(false)
    source_fn({
      next: fn(v : T) {
        if !done.val {
          if predicate(v) {
            done.val = true
            next(true)
            complete()
          }
        }
      },
      error: error,
      complete: fn() {
        if !done.val {
          done.val = true
          next(false)
        }
        complete()
      },
    })
  }
  Observable::new(subscribe_fn)
}

/// find：发射第一个满足谓词的值后完成
pub fn[T, E] Observable::find(
  self : Observable[T, E],
  predicate : (T) -> Bool,
) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let found = Ref::Ref(false)
    source_fn({
      next: fn(v : T) {
        if !found.val {
          if predicate(v) {
            found.val = true
            next(v)
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

/// find_index：发射第一个满足谓词的值的索引（找不到发 -1）
pub fn[T, E] Observable::find_index(
  self : Observable[T, E],
  predicate : (T) -> Bool,
) -> Observable[Int64, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[Int64, E]) -> Subscription = fn(downstream : Observer[Int64, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let idx = Ref::Ref(0L)
    let found = Ref::Ref(false)
    source_fn({
      next: fn(v : T) {
        if !found.val {
          if predicate(v) {
            found.val = true
            next(idx.val)
            complete()
          } else {
            idx.val = idx.val + 1L
          }
        }
      },
      error: error,
      complete: fn() {
        if !found.val {
          next(-1L)
        }
        complete()
      },
    })
  }
  Observable::new(subscribe_fn)
}

/// is_empty：流没有任何值时发 true，否则发 false
pub fn[T, E] Observable::is_empty(self : Observable[T, E]) -> Observable[Bool, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[Bool, E]) -> Subscription = fn(downstream : Observer[Bool, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let empty = Ref::Ref(true)
    source_fn({
      next: fn(_ : T) { empty.val = false },
      error: error,
      complete: fn() {
        next(empty.val)
        complete()
      },
    })
  }
  Observable::new(subscribe_fn)
}

/// all：所有值都满足谓词时发 true（every 的 Rx-Rust 别名）
pub fn[T, E] Observable::all(
  self : Observable[T, E],
  predicate : (T) -> Bool,
) -> Observable[Bool, E] {
  self.every(predicate)
}
