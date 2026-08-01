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
    source_fn({
      next: fn(v : T) {
        let inner = mapper(v)
        let _ = inner.subscribe({
          next: next,
          error: error,
          complete: fn() {},
        })
      },
      error: error,
      complete: complete,
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
  let acc = Ref::Ref(seed)
  let subscribe_fn : (Observer[Acc, E]) -> Subscription = fn(downstream : Observer[Acc, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
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
    source_fn({
      next: fn(v : T) {
        match current.val {
          Some(sub) => sub.dispose()
          None => ()
        }
        let inner = mapper(v)
        let inner_sub = inner.subscribe({
          next: next,
          error: error,
          complete: fn() {},
        })
        current.val = Some(inner_sub)
      },
      error: error,
      complete: complete,
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
