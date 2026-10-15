// ============================================================================
// Subject：PublishSubject / BehaviorSubject / ReplaySubject
// 多播主题：既可被订阅，也可手动 on_next / on_error / on_completed 发射
// ============================================================================

/// 主题内部状态：订阅者列表（带 id，用于 dispose 时精确移除）
struct SubjectState[T, E] {
  observers : Ref[Array[(Int, Observer[T, E])]]
  next_id : Ref[Int]
  stopped : Ref[Bool]
  // 终止方式：None=未终止；Some=以错误终止（记录错误值）；completed 用 stopped+error=None 区分
  terminal_error : Ref[Option[E]]
}

fn[T, E] SubjectState::new() -> SubjectState[T, E] {
  {
    observers: Ref::Ref(Array(capacity=0)),
    next_id: Ref::Ref(0),
    stopped: Ref::Ref(false),
    terminal_error: Ref::Ref(None),
  }
}

fn[T, E] SubjectState::subscribe(
  self : SubjectState[T, E],
  observer : Observer[T, E],
) -> Subscription {
  // 已终止的主题：新订阅者立即收到终止信号，不加入列表（避免残留泄漏）
  if self.stopped.val {
    match self.terminal_error.val {
      Some(err) => observer.on_error(err)
      None => observer.on_completed()
    }
    return Subscription::empty()
  }
  let id = self.next_id.val
  self.next_id.val = self.next_id.val + 1
  self.observers.val.push((id, observer))
  Subscription::new(fn() {
    let arr = self.observers.val
    let keep = Array(capacity=0)
    for entry in arr {
      if entry.0 != id {
        keep.push(entry)
      }
    }
    self.observers.val = keep
  })
}

fn[T, E] SubjectState::on_next(self : SubjectState[T, E], value : T) -> Unit {
  if self.stopped.val {
    return
  }
  let snapshot = self.observers.val.copy()
  for entry in snapshot {
    (entry.1).on_next(value)
  }
}

fn[T, E] SubjectState::on_error(self : SubjectState[T, E], err : E) -> Unit {
  if self.stopped.val {
    return
  }
  self.stopped.val = true
  self.terminal_error.val = Some(err)
  let snapshot = self.observers.val.copy()
  self.observers.val = Array(capacity=0)
  for entry in snapshot {
    (entry.1).on_error(err)
  }
}

fn[T, E] SubjectState::on_completed(self : SubjectState[T, E]) -> Unit {
  if self.stopped.val {
    return
  }
  self.stopped.val = true
  self.terminal_error.val = None
  let snapshot = self.observers.val.copy()
  self.observers.val = Array(capacity=0)
  for entry in snapshot {
    (entry.1).on_completed()
  }
}

fn[T, E] SubjectState::as_observable(self : SubjectState[T, E]) -> Observable[T, E] {
  Observable::new(fn(observer : Observer[T, E]) -> Subscription {
    self.subscribe(observer)
  })
}

// ----------------------------------------------------------------------------
// PublishSubject：订阅后只收到之后发射的值
// ----------------------------------------------------------------------------

/// PublishSubject：不重放历史值
pub struct PublishSubject[T, E] {
  state : SubjectState[T, E]
}

/// 创建 PublishSubject
pub fn[T, E] PublishSubject::new() -> PublishSubject[T, E] {
  { state: SubjectState::new() }
}

/// 订阅（只接收订阅之后发射的值）
pub fn[T, E] PublishSubject::subscribe(
  self : PublishSubject[T, E],
  observer : Observer[T, E],
) -> Subscription {
  self.state.subscribe(observer)
}

/// 发射一个值
pub fn[T, E] PublishSubject::on_next(self : PublishSubject[T, E], value : T) -> Unit {
  self.state.on_next(value)
}

/// 发射错误
pub fn[T, E] PublishSubject::on_error(self : PublishSubject[T, E], err : E) -> Unit {
  self.state.on_error(err)
}

/// 通知完成
pub fn[T, E] PublishSubject::on_completed(self : PublishSubject[T, E]) -> Unit {
  self.state.on_completed()
}

/// 转成 Observable（可链式操作）
pub fn[T, E] PublishSubject::as_observable(self : PublishSubject[T, E]) -> Observable[T, E] {
  self.state.as_observable()
}

// ----------------------------------------------------------------------------
// BehaviorSubject：订阅时立即重放当前值
// ----------------------------------------------------------------------------

/// BehaviorSubject：始终持有最新值，新订阅者立刻收到该值
pub struct BehaviorSubject[T, E] {
  state : SubjectState[T, E]
  current : Ref[Option[T]]
}

/// 创建 BehaviorSubject（初始值可选）
pub fn[T, E] BehaviorSubject::new() -> BehaviorSubject[T, E] {
  { state: SubjectState::new(), current: Ref::Ref(None) }
}

/// 创建 BehaviorSubject 并设置初始值
pub fn[T, E] BehaviorSubject::with_value(initial : T) -> BehaviorSubject[T, E] {
  { state: SubjectState::new(), current: Ref::Ref(Some(initial)) }
}

/// 当前持有的值
pub fn[T, E] BehaviorSubject::value(self : BehaviorSubject[T, E]) -> Option[T] {
  self.current.val
}

/// 订阅：立即收到当前值（若有），随后接收后续值
pub fn[T, E] BehaviorSubject::subscribe(
  self : BehaviorSubject[T, E],
  observer : Observer[T, E],
) -> Subscription {
  // 已终止的主题：不重放当前值，直接转发终止信号（符合 Rx 语义）
  if !self.state.stopped.val {
    match self.current.val {
      Some(v) => observer.on_next(v)
      None => ()
    }
  }
  self.state.subscribe(observer)
}

/// 发射一个值（同时更新当前值）
pub fn[T, E] BehaviorSubject::on_next(self : BehaviorSubject[T, E], value : T) -> Unit {
  self.current.val = Some(value)
  self.state.on_next(value)
}

/// 发射错误
pub fn[T, E] BehaviorSubject::on_error(self : BehaviorSubject[T, E], err : E) -> Unit {
  self.state.on_error(err)
}

/// 通知完成
pub fn[T, E] BehaviorSubject::on_completed(self : BehaviorSubject[T, E]) -> Unit {
  self.state.on_completed()
}

/// 转成 Observable
pub fn[T, E] BehaviorSubject::as_observable(self : BehaviorSubject[T, E]) -> Observable[T, E] {
  Observable::new(fn(observer : Observer[T, E]) -> Subscription {
    self.subscribe(observer)
  })
}

// ----------------------------------------------------------------------------
// ReplaySubject：订阅时重放全部历史值
// ----------------------------------------------------------------------------

/// ReplaySubject：缓冲历史值，新订阅者收到历史后继续接收
/// buffer_size 为 0 表示缓冲全部历史（无限重放）
pub struct ReplaySubject[T, E] {
  state : SubjectState[T, E]
  buffer : Ref[Array[T]]
  buffer_size : Int
}

/// 创建 ReplaySubject（无限缓冲）
pub fn[T, E] ReplaySubject::new() -> ReplaySubject[T, E] {
  { state: SubjectState::new(), buffer: Ref::Ref(Array(capacity=0)), buffer_size: 0 }
}

/// 创建 ReplaySubject 并限制缓冲大小（只重放最近 buffer_size 个值）
pub fn[T, E] ReplaySubject::with_buffer_size(size : Int) -> ReplaySubject[T, E] {
  {
    state: SubjectState::new(),
    buffer: Ref::Ref(Array(capacity=0)),
    buffer_size: if size < 0 { 0 } else { size },
  }
}

/// 订阅：先重放全部（或最近 buffer_size 个）历史值
/// 已终止的主题：不重放历史值，直接转发终止信号（与 BehaviorSubject 一致，
/// 符合 Rx 规范——终止后不得再发 next）
pub fn[T, E] ReplaySubject::subscribe(
  self : ReplaySubject[T, E],
  observer : Observer[T, E],
) -> Subscription {
  if !self.state.stopped.val {
    for v in self.buffer.val {
      observer.on_next(v)
    }
  }
  self.state.subscribe(observer)
}

/// 发射一个值（同时进入历史缓冲，超出 buffer_size 时丢弃最旧的）
pub fn[T, E] ReplaySubject::on_next(self : ReplaySubject[T, E], value : T) -> Unit {
  // 已终止的主题：忽略发射，避免无意义地继续缓冲（内存泄漏）
  if self.state.stopped.val {
    return
  }
  let arr = self.buffer.val
  if self.buffer_size > 0 && arr.length() >= self.buffer_size {
    let keep = Array(capacity=0)
    for i = 1; i < arr.length(); i = i + 1 {
      keep.push(arr[i])
    }
    self.buffer.val = keep
  }
  self.buffer.val.push(value)
  self.state.on_next(value)
}

/// 发射错误
pub fn[T, E] ReplaySubject::on_error(self : ReplaySubject[T, E], err : E) -> Unit {
  self.state.on_error(err)
}

/// 通知完成
pub fn[T, E] ReplaySubject::on_completed(self : ReplaySubject[T, E]) -> Unit {
  self.state.on_completed()
}

/// 转成 Observable
pub fn[T, E] ReplaySubject::as_observable(self : ReplaySubject[T, E]) -> Observable[T, E] {
  Observable::new(fn(observer : Observer[T, E]) -> Subscription {
    self.subscribe(observer)
  })
}
