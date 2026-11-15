// ============================================================================
// 条件类操作符：every / some / find / find_index / is_empty
// ============================================================================

///|
/// every：所有值都满足谓词时发 true（流结束时）；任一不满足发 false
pub fn[T, E] Observable::every(
  self : Observable[T, E],
  predicate : (T) -> Bool,
) -> Observable[Bool, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[Bool, E]) -> Subscription = fn(
    downstream : Observer[Bool, E],
  ) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let done = Ref::Ref(false)
    let stopped = Ref::Ref(false)
    let source_sub = Ref::Ref(Subscription::empty())
    source_sub.val = source_fn({
      next: fn(v : T) {
        if !stopped.val {
          if !predicate(v) {
            stopped.val = true
            done.val = true
            next(false)
            // 提前终止：取消上游，避免热流继续泄漏
            source_sub.val.dispose()
            complete()
          }
        }
      },
      error: fn(e : E) {
        if !stopped.val {
          stopped.val = true
          error(e)
        }
      },
      complete: fn() {
        if !stopped.val {
          stopped.val = true
          if !done.val {
            next(true)
          }
          complete()
        }
      },
      interrupt: Ref::Ref(None),
    })
    Subscription::new(fn() {
      stopped.val = true
      source_sub.val.dispose()
    })
  }
  Observable::new(subscribe_fn)
}

///|
/// some：任一值满足谓词发 true（立即完成）；流结束时发 false
pub fn[T, E] Observable::some(
  self : Observable[T, E],
  predicate : (T) -> Bool,
) -> Observable[Bool, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[Bool, E]) -> Subscription = fn(
    downstream : Observer[Bool, E],
  ) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let done = Ref::Ref(false)
    let stopped = Ref::Ref(false)
    let source_sub = Ref::Ref(Subscription::empty())
    source_sub.val = source_fn({
      next: fn(v : T) {
        if !stopped.val {
          if predicate(v) {
            stopped.val = true
            done.val = true
            next(true)
            // 提前终止：取消上游，避免热流继续泄漏
            source_sub.val.dispose()
            complete()
          }
        }
      },
      error: fn(e : E) {
        if !stopped.val {
          stopped.val = true
          error(e)
        }
      },
      complete: fn() {
        if !stopped.val {
          stopped.val = true
          if !done.val {
            next(false)
          }
          complete()
        }
      },
      interrupt: Ref::Ref(None),
    })
    Subscription::new(fn() {
      stopped.val = true
      source_sub.val.dispose()
    })
  }
  Observable::new(subscribe_fn)
}

///|
/// find：发射第一个满足谓词的值后完成
pub fn[T, E] Observable::find(
  self : Observable[T, E],
  predicate : (T) -> Bool,
) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(
    downstream : Observer[T, E],
  ) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let found = Ref::Ref(false)
    let stopped = Ref::Ref(false)
    let source_sub = Ref::Ref(Subscription::empty())
    source_sub.val = source_fn({
      next: fn(v : T) {
        if !stopped.val && !found.val {
          if predicate(v) {
            found.val = true
            stopped.val = true
            next(v)
            // 找到后立即取消上游，避免热流继续泄漏
            source_sub.val.dispose()
            complete()
          }
        }
      },
      error: fn(e : E) {
        if !stopped.val {
          stopped.val = true
          error(e)
        }
      },
      complete: fn() {
        if !stopped.val {
          stopped.val = true
          complete()
        }
      },
      interrupt: Ref::Ref(None),
    })
    Subscription::new(fn() {
      stopped.val = true
      source_sub.val.dispose()
    })
  }
  Observable::new(subscribe_fn)
}

///|
/// find_index：发射第一个满足谓词的值的索引（找不到发 -1）
pub fn[T, E] Observable::find_index(
  self : Observable[T, E],
  predicate : (T) -> Bool,
) -> Observable[Int64, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[Int64, E]) -> Subscription = fn(
    downstream : Observer[Int64, E],
  ) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let idx = Ref::Ref(0L)
    let found = Ref::Ref(false)
    let stopped = Ref::Ref(false)
    let source_sub = Ref::Ref(Subscription::empty())
    source_sub.val = source_fn({
      next: fn(v : T) {
        if !stopped.val && !found.val {
          if predicate(v) {
            found.val = true
            stopped.val = true
            next(idx.val)
            // 找到后立即取消上游，避免热流继续泄漏
            source_sub.val.dispose()
            complete()
          } else {
            idx.val = idx.val + 1L
          }
        }
      },
      error: fn(e : E) {
        if !stopped.val {
          stopped.val = true
          error(e)
        }
      },
      complete: fn() {
        if !stopped.val {
          stopped.val = true
          if !found.val {
            next(-1L)
          }
          complete()
        }
      },
      interrupt: Ref::Ref(None),
    })
    Subscription::new(fn() {
      stopped.val = true
      source_sub.val.dispose()
    })
  }
  Observable::new(subscribe_fn)
}

///|
/// is_empty：流没有任何值时发 true，否则发 false
pub fn[T, E] Observable::is_empty(
  self : Observable[T, E],
) -> Observable[Bool, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[Bool, E]) -> Subscription = fn(
    downstream : Observer[Bool, E],
  ) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let empty = Ref::Ref(true)
    source_fn({
      next: fn(_ : T) { empty.val = false },
      error,
      complete: fn() {
        next(empty.val)
        complete()
      },
      interrupt: Ref::Ref(None),
    })
  }
  Observable::new(subscribe_fn)
}

///|
/// all：所有值都满足谓词时发 true（every 的 Rx-Rust 别名）
pub fn[T, E] Observable::all(
  self : Observable[T, E],
  predicate : (T) -> Bool,
) -> Observable[Bool, E] {
  self.every(predicate)
}

// ============================================================================
// 触发条件组合器：把多个 (TriggerEvent[T]) -> Bool 组合为复合条件
// all_of = AND、any_of = OR、not_ = 取反；供 EventBus / TriggerRegistry 条件过滤使用
// ============================================================================

///|
/// all_of：所有条件都满足时才为 true（AND 语义）。空数组视为恒真。
pub fn[T] all_of(
  conds : Array[(TriggerEvent[T]) -> Bool],
) -> (TriggerEvent[T]) -> Bool {
  fn(ev : TriggerEvent[T]) -> Bool {
    let mut ok = true
    for c in conds {
      if !c(ev) {
        ok = false
        break
      }
    }
    ok
  }
}

///|
/// any_of：任一条件满足即为 true（OR 语义）。空数组视为恒假。
pub fn[T] any_of(
  conds : Array[(TriggerEvent[T]) -> Bool],
) -> (TriggerEvent[T]) -> Bool {
  fn(ev : TriggerEvent[T]) -> Bool {
    let mut ok = false
    for c in conds {
      if c(ev) {
        ok = true
        break
      }
    }
    ok
  }
}

///|
/// not_：对单个条件取反。
pub fn[T] not_(c : (TriggerEvent[T]) -> Bool) -> (TriggerEvent[T]) -> Bool {
  fn(ev : TriggerEvent[T]) -> Bool { !c(ev) }
}
