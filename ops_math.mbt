// ============================================================================
// 数学/容器类操作符：sort / top_k / bottom_k / drop_none / fill_none / clamp
// ============================================================================

/// sort：收集所有值，排序后一次性发出
pub fn[T : Compare, E] Observable::sort(self : Observable[T, E]) -> Observable[Array[T], E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[Array[T], E]) -> Subscription = fn(downstream : Observer[Array[T], E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let buf = Ref::Ref(Array::new())
    source_fn({
      next: fn(v : T) { buf.val.push(v) },
      error: error,
      complete: fn() {
        let arr = buf.val
        arr.sort()
        next(arr)
        complete()
      },
    })
  }
  Observable::new(subscribe_fn)
}

/// top_k：收集所有值，发出最大的 k 个（降序）
pub fn[T : Compare, E] Observable::top_k(
  self : Observable[T, E],
  k : Int,
) -> Observable[Array[T], E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[Array[T], E]) -> Subscription = fn(downstream : Observer[Array[T], E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let buf = Ref::Ref(Array::new())
    source_fn({
      next: fn(v : T) { buf.val.push(v) },
      error: error,
      complete: fn() {
        let arr = buf.val
        arr.sort()
        arr.rev_in_place()
        if arr.length() > k {
          arr.truncate(k)
        }
        next(arr)
        complete()
      },
    })
  }
  Observable::new(subscribe_fn)
}

/// bottom_k：收集所有值，发出最小的 k 个（升序）
pub fn[T : Compare, E] Observable::bottom_k(
  self : Observable[T, E],
  k : Int,
) -> Observable[Array[T], E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[Array[T], E]) -> Subscription = fn(downstream : Observer[Array[T], E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let buf = Ref::Ref(Array::new())
    source_fn({
      next: fn(v : T) { buf.val.push(v) },
      error: error,
      complete: fn() {
        let arr = buf.val
        arr.sort()
        if arr.length() > k {
          arr.truncate(k)
        }
        next(arr)
        complete()
      },
    })
  }
  Observable::new(subscribe_fn)
}

/// drop_none：丢弃 Option 流中的 None，只放行 Some 的值
pub fn[T, E] Observable::drop_none(self : Observable[T?, E]) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    source_fn({
      next: fn(v : T?) {
        match v {
          Some(x) => next(x)
          None => ()
        }
      },
      error: error,
      complete: complete,
    })
  }
  Observable::new(subscribe_fn)
}

/// fill_none：把 Option 流中的 None 替换为给定值
pub fn[T, E] Observable::fill_none(
  self : Observable[T?, E],
  fill : T,
) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    source_fn({
      next: fn(v : T?) {
        match v {
          Some(x) => next(x)
          None => next(fill)
        }
      },
      error: error,
      complete: complete,
    })
  }
  Observable::new(subscribe_fn)
}

/// clamp：把值夹在 [min, max] 之间
pub fn[T : Compare, E] Observable::clamp(
  self : Observable[T, E],
  min : T,
  max : T,
) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    source_fn({
      next: fn(v : T) {
        if v.compare(min) < 0 {
          next(min)
        } else if v.compare(max) > 0 {
          next(max)
        } else {
          next(v)
        }
      },
      error: error,
      complete: complete,
    })
  }
  Observable::new(subscribe_fn)
}
