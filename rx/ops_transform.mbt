// ============================================================================
// 转换类操作符：map / filter_map / flat_map / flat_map_latest / scan /
// concat_map / switch_map / group_by
// ============================================================================

/// 转换：对每个值应用 mapper，发出映射结果
pub fn[T, E, U] Observable::map(
  self : Observable[T, E],
  mapper : (T) -> U,
) -> Observable[U, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[U, E]) -> Subscription = fn(downstream : Observer[U, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    source_fn({
      next: fn(v : T) { next(mapper(v)) },
      error: error,
      complete: complete,
    })
  }
  Observable::new(subscribe_fn)
}

/// 过滤 + 转换：f 返回 Some(u) 则发射 u，None 则丢弃
pub fn[T, E, U] Observable::filter_map(
  self : Observable[T, E],
  f : (T) -> U?,
) -> Observable[U, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[U, E]) -> Subscription = fn(downstream : Observer[U, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    source_fn({
      next: fn(v : T) {
        match f(v) {
          Some(u) => next(u)
          None => ()
        }
      },
      error: error,
      complete: complete,
    })
  }
  Observable::new(subscribe_fn)
}

/// 平铺：mapper 返回内部 Observable，订阅并将内部值转发到下游
pub fn[T, E, U] Observable::flat_map(
  self : Observable[T, E],
  mapper : (T) -> Observable[U, E],
) -> Observable[U, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[U, E]) -> Subscription = fn(downstream : Observer[U, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    // 收集所有内层订阅，dispose 时统一释放，避免资源泄漏
    let inner_subs = Ref::Ref(Array::new())
    let stopped = Ref::Ref(false)
    let source_sub = source_fn({
      next: fn(v : T) {
        if !stopped.val {
          let inner = mapper(v)
          let sub = inner.subscribe({
            next: next,
            error: error,
            complete: fn() {},
          })
          inner_subs.val.push(sub)
        }
      },
      error: error,
      complete: fn() {
        if !stopped.val {
          stopped.val = true
          complete()
        }
      },
    })
    Subscription::new(fn() {
      stopped.val = true
      source_sub.dispose()
      for sub in inner_subs.val {
        sub.dispose()
      }
    })
  }
  Observable::new(subscribe_fn)
}

/// 累积：从 seed 开始，每来一个值用 scanner 累积并发出中间结果
pub fn[T, E, Acc] Observable::scan(
  self : Observable[T, E],
  seed : Acc,
  scanner : (Acc, T) -> Acc,
) -> Observable[Acc, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[Acc, E]) -> Subscription = fn(downstream : Observer[Acc, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    // 累加器必须在每次订阅时重新创建：scan 是冷流，多次订阅互不影响
    let acc = Ref::Ref(seed)
    source_fn({
      next: fn(v : T) {
        let cur = acc.val
        let nxt = scanner(cur, v)
        acc.val = nxt
        next(nxt)
      },
      error: error,
      complete: complete,
    })
  }
  Observable::new(subscribe_fn)
}

/// 串行平铺：映射并依次订阅内部 Observable（同步流下与 flat_map 等价）
pub fn[T, E, U] Observable::concat_map(
  self : Observable[T, E],
  mapper : (T) -> Observable[U, E],
) -> Observable[U, E] {
  self.flat_map(mapper)
}

/// 切换平铺：新的内部 Observable 到来时取消前一个订阅（同步流下与 flat_map 等价）
pub fn[T, E, U] Observable::switch_map(
  self : Observable[T, E],
  mapper : (T) -> Observable[U, E],
) -> Observable[U, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[U, E]) -> Subscription = fn(downstream : Observer[U, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let init_sub : (Subscription)? = None
    let current = Ref::Ref(init_sub)
    let stopped = Ref::Ref(false)
    let dispose_current : () -> Unit = fn() {
      match current.val {
        Some(sub) => sub.dispose()
        None => ()
      }
      current.val = None
    }
    let source_sub = source_fn({
      next: fn(v : T) {
        if !stopped.val {
          dispose_current()
          let inner = mapper(v)
          let inner_sub = inner.subscribe({
            next: next,
            error: error,
            complete: fn() {},
          })
          current.val = Some(inner_sub)
        }
      },
      error: fn(e : E) {
        if !stopped.val {
          stopped.val = true
          dispose_current()
          error(e)
        }
      },
      complete: fn() {
        if !stopped.val {
          stopped.val = true
          dispose_current()
          complete()
        }
      },
    })
    Subscription::new(fn() {
      stopped.val = true
      dispose_current()
      source_sub.dispose()
    })
  }
  Observable::new(subscribe_fn)
}

/// flat_map_latest 别名（与 switch_map 语义一致）
pub fn[T, E, U] Observable::flat_map_latest(
  self : Observable[T, E],
  mapper : (T) -> Observable[U, E],
) -> Observable[U, E] {
  self.switch_map(mapper)
}

/// 按键分组：收集所有值，流结束时每组发出 (key, Observable[T,E])
pub fn[T, E, K : Hash + Eq] Observable::group_by(
  self : Observable[T, E],
  key_fn : (T) -> K,
  _make_observable : () -> Observable[T, E],
) -> Observable[(K, Observable[T, E]), E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[(K, Observable[T, E]), E]) -> Subscription =
    fn(downstream : Observer[(K, Observable[T, E]), E]) {
      let next = downstream.next
      let error = downstream.error
      let complete = downstream.complete
      let groups : @hashmap.HashMap[K, Array[T]] = @hashmap.from_array([])
      source_fn({
        next: fn(v : T) {
          let k = key_fn(v)
          match groups.get(k) {
            Some(arr) => arr.push(v)
            None => groups.set(k, [v])
          }
        },
        error: error,
        complete: fn() {
          groups.each(fn(k : K, arr : Array[T]) {
            next((k, Observable::from_iter(arr)))
          })
          complete()
        },
      })
    }
  Observable::new(subscribe_fn)
}

/// curry_map：把 `func(value, arg)` 部分应用到源流上，返回一个函数，
/// 该函数接收 Observable 并返回应用后的 Observable（函数式组合用）
pub fn[T, E, R, A] curry_map(
  func : (T, A) -> R,
  arg : A,
) -> (Observable[T, E]) -> Observable[R, E] {
  fn(source : Observable[T, E]) -> Observable[R, E] {
    source.map(fn(v : T) { func(v, arg) })
  }
}
