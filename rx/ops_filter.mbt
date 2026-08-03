// ============================================================================
// 过滤类操作符：filter / take / skip / first / last / take_while / skip_while /
// skip_last / take_last / element_at / distinct 系列 / skip_until / take_until
// ============================================================================

/// 过滤：只放行满足 predicate 的值
pub fn[T, E] Observable::filter(
  self : Observable[T, E],
  predicate : (T) -> Bool,
) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    source_fn({
      next: fn(v : T) { if predicate(v) { next(v) } },
      error: error,
      complete: complete, interrupt: Ref::Ref(None),
    })
  }
  Observable::new(subscribe_fn)
}

/// 取前 n 个值后完成
pub fn[T, E] Observable::take(self : Observable[T, E], n : Int) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let remaining = Ref::Ref(n)
    let stopped = Ref::Ref(false)
    let source_sub = Ref::Ref(Subscription::empty())
    // 中断通道：同步无限源（iterate / repeat_infinite / cycle / unfoldr）
    // 订阅时把"停止函数"写入 interrupt，取够后调用它中断同步循环；
    // 异步源没有该通道，改为 dispose 取消上游订阅。
    let interrupt = Ref::Ref(None)
    if n <= 0 {
      // Rx 语义：take(0) / take(负数) 不取任何值，立即完成
      stopped.val = true
      complete()
      Subscription::empty()
    } else {
      let observer = {
        next: fn(v : T) {
          if !stopped.val {
            if remaining.val > 0 {
              remaining.val = remaining.val - 1
              let done = remaining.val == 0
              next(v)
              if done {
                stopped.val = true
                // 取够：先通知下游完成
                complete()
                match interrupt.val {
                  Some(interrupt_fn) => interrupt_fn()
                  None => (source_sub.val).dispose()
                }
              }
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
        interrupt: interrupt,
      }
      source_sub.val = source_fn(observer)
      Subscription::new(fn() {
        stopped.val = true
        (source_sub.val).dispose()
      })
    }
  }
  Observable::new(subscribe_fn)
}

/// 跳过前 n 个值
pub fn[T, E] Observable::skip(self : Observable[T, E], n : Int) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let skipped = Ref::Ref(0)
    source_fn({
      next: fn(v : T) {
        if skipped.val < n {
          skipped.val = skipped.val + 1
        } else {
          next(v)
        }
      },
      error: error,
      complete: complete, interrupt: Ref::Ref(None),
    })
  }
  Observable::new(subscribe_fn)
}

/// 取第一个值后完成（无谓词版，等价 take(1)）
pub fn[T, E] Observable::first(self : Observable[T, E]) -> Observable[T, E] {
  self.take(1)
}

/// first_or_first：取第一个值（等价 first）
pub fn[T, E] Observable::first_or_first(self : Observable[T, E]) -> Observable[T, E] {
  self.take(1)
}

/// 取第一个满足谓词的值后完成（自由函数版，对应 Rx-Rust filter_extra::first）
pub fn[T, E] first(source : Observable[T, E], predicate : (T) -> Bool) -> Observable[T, E] {
  let source_fn = source.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
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
            (source_sub.val).dispose()
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
      }, interrupt: Ref::Ref(None),
    })
    Subscription::new(fn() {
      stopped.val = true
      (source_sub.val).dispose()
    })
  }
  Observable::new(subscribe_fn)
}

/// 只取最后一个值
pub fn[T, E] Observable::last(self : Observable[T, E]) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let init : T? = None
    let last_val = Ref::Ref(init)
    source_fn({
      next: fn(v : T) { last_val.val = Some(v) },
      error: error,
      complete: fn() {
        match last_val.val {
          Some(v) => next(v)
          None => ()
        }
        complete()
      }, interrupt: Ref::Ref(None),
    })
  }
  Observable::new(subscribe_fn)
}

/// last_or_last：只取最后一个值（等价 last）
pub fn[T, E] Observable::last_or_last(self : Observable[T, E]) -> Observable[T, E] {
  self.last()
}

/// 取最后一个满足谓词的值（自由函数版，对应 Rx-Rust filter_extra::last）
pub fn[T, E] last(source : Observable[T, E], predicate : (T) -> Bool) -> Observable[T, E] {
  let source_fn = source.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let init : T? = None
    let last_val = Ref::Ref(init)
    source_fn({
      next: fn(v : T) {
        if predicate(v) {
          last_val.val = Some(v)
        }
      },
      error: error,
      complete: fn() {
        match last_val.val {
          Some(v) => next(v)
          None => ()
        }
        complete()
      }, interrupt: Ref::Ref(None),
    })
  }
  Observable::new(subscribe_fn)
}

/// take_while：谓词为真时放行，一旦为假立即完成
pub fn[T, E] Observable::take_while(
  self : Observable[T, E],
  predicate : (T) -> Bool,
) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let stopped = Ref::Ref(false)
    let source_sub = Ref::Ref(Subscription::empty())
    // 中断通道：谓词首次为假时中断同步无限源（iterate / repeat_infinite / cycle / unfoldr）
    let interrupt = Ref::Ref(None)
    let observer = {
      next: fn(v : T) {
        if !stopped.val {
          if predicate(v) {
            next(v)
          } else {
            stopped.val = true
            // 谓词不满足即终止；同步源走 interrupt，异步源 dispose 取消上游
            complete()
            match interrupt.val {
              Some(interrupt_fn) => interrupt_fn()
              None => (source_sub.val).dispose()
            }
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
      interrupt: interrupt,
    }
    source_sub.val = source_fn(observer)
    Subscription::new(fn() {
      stopped.val = true
      (source_sub.val).dispose()
    })
  }
  Observable::new(subscribe_fn)
}

/// skip_while：跳过前缀中满足谓词的值，之后全部放行
pub fn[T, E] Observable::skip_while(
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
            return
          } else {
            passing.val = true
          }
        }
        next(v)
      },
      error: error,
      complete: complete, interrupt: Ref::Ref(None),
    })
  }
  Observable::new(subscribe_fn)
}

/// 跳过前 n 个事件（等价 skip）
pub fn[T, E] Observable::skip_n_events(self : Observable[T, E], n : Int) -> Observable[T, E] {
  self.skip(n)
}

/// 取前 n 个事件（等价 take）
pub fn[T, E] Observable::take_n_events(self : Observable[T, E], n : Int) -> Observable[T, E] {
  self.take(n)
}

/// 跳过最后 n 个值（用滑动缓冲实现）
pub fn[T, E] Observable::skip_last(self : Observable[T, E], n : Int) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let buf = Ref::Ref(Array::new())
    source_fn({
      next: fn(v : T) {
        buf.val.push(v)
        if buf.val.length() > n {
          let head = buf.val.remove(0)
          next(head)
        }
      },
      error: error,
      complete: complete, interrupt: Ref::Ref(None),
    })
  }
  Observable::new(subscribe_fn)
}

/// 只取最后 n 个值（用环形缓冲实现）
pub fn[T, E] Observable::take_last(self : Observable[T, E], n : Int) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let buf = Ref::Ref(Array::new())
    source_fn({
      next: fn(v : T) {
        buf.val.push(v)
        if buf.val.length() > n {
          let _ = buf.val.remove(0)
        }
      },
      error: error,
      complete: fn() {
        for x in buf.val {
          next(x)
        }
        complete()
      }, interrupt: Ref::Ref(None),
    })
  }
  Observable::new(subscribe_fn)
}

/// 取第 index 个值（从 0 开始），越界则发默认错误
pub fn[T, E : Default] Observable::element_at(
  self : Observable[T, E],
  index : Int,
) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let pos = Ref::Ref(0)
    let found = Ref::Ref(false)
    let stopped = Ref::Ref(false)
    let source_sub = Ref::Ref(Subscription::empty())
    source_sub.val = source_fn({
      next: fn(v : T) {
        if !stopped.val {
          if pos.val == index {
            pos.val = pos.val + 1
            found.val = true
            stopped.val = true
            next(v)
            // 命中后取消上游，避免热流继续泄漏
            (source_sub.val).dispose()
            complete()
          } else {
            pos.val = pos.val + 1
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
            error(E::default())
          }
        }
      }, interrupt: Ref::Ref(None),
    })
    Subscription::new(fn() {
      stopped.val = true
      (source_sub.val).dispose()
    })
  }
  Observable::new(subscribe_fn)
}

/// 去重：丢弃已出现过的值
pub fn[T : Hash + Eq, E] Observable::distinct(self : Observable[T, E]) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    // 去重集合必须每次订阅重新创建：冷流多次订阅互不影响
    let seen : @hashset.HashSet[T] = @hashset.from_array([])
    source_fn({
      next: fn(v : T) {
        if seen.add_and_check(v) {
          next(v)
        }
      },
      error: error,
      complete: complete, interrupt: Ref::Ref(None),
    })
  }
  Observable::new(subscribe_fn)
}

/// 去重（按 key）：丢弃 key 已出现过的值
pub fn[T, E, K : Hash + Eq] Observable::distinct_by(
  self : Observable[T, E],
  key_fn : (T) -> K,
) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    // 去重集合必须每次订阅重新创建：冷流多次订阅互不影响
    let seen : @hashset.HashSet[K] = @hashset.from_array([])
    source_fn({
      next: fn(v : T) {
        let k = key_fn(v)
        if seen.add_and_check(k) {
          next(v)
        }
      },
      error: error,
      complete: complete, interrupt: Ref::Ref(None),
    })
  }
  Observable::new(subscribe_fn)
}

/// 只丢弃连续重复的值
pub fn[T : Eq, E] Observable::distinct_until_changed(
  self : Observable[T, E],
) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let init : T? = None
    let last = Ref::Ref(init)
    source_fn({
      next: fn(v : T) {
        let skip = match last.val {
          Some(prev) => prev == v
          None => false
        }
        if !skip {
          last.val = Some(v)
          next(v)
        }
      },
      error: error,
      complete: complete, interrupt: Ref::Ref(None),
    })
  }
  Observable::new(subscribe_fn)
}

/// 只丢弃 key 连续重复的值
pub fn[T, E, K : Eq] Observable::distinct_until_changed_by(
  self : Observable[T, E],
  key_fn : (T) -> K,
) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let init : K? = None
    let last = Ref::Ref(init)
    source_fn({
      next: fn(v : T) {
        let k = key_fn(v)
        let skip = match last.val {
          Some(prev) => prev == k
          None => false
        }
        if !skip {
          last.val = Some(k)
          next(v)
        }
      },
      error: error,
      complete: complete, interrupt: Ref::Ref(None),
    })
  }
  Observable::new(subscribe_fn)
}

/// skip_until：trigger 发射前丢弃源流的值，trigger 发射后放行
pub fn[T, E] Observable::skip_until(
  self : Observable[T, E],
  trigger : Observable[Unit, E],
) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let trigger_fn = trigger.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    // 状态必须每次订阅重新创建：冷流多次订阅互不影响
    let triggered = Ref::Ref(false)
    let trigger_sub = Ref::Ref(Subscription::empty())
    let source_sub = Ref::Ref(Subscription::empty())
    trigger_sub.val = trigger_fn({
      next: fn(_ : Unit) {
        if !triggered.val {
          triggered.val = true
          // 触发后取消 trigger 订阅，避免热流继续泄漏
          (trigger_sub.val).dispose()
        }
      },
      error: fn(_ : E) {},
      complete: fn() {}, interrupt: Ref::Ref(None),
    })
    source_sub.val = source_fn({
      next: fn(v : T) { if triggered.val { next(v) } },
      error: error,
      complete: complete, interrupt: Ref::Ref(None),
    })
    Subscription::new(fn() {
      triggered.val = true
      (trigger_sub.val).dispose()
      (source_sub.val).dispose()
    })
  }
  Observable::new(subscribe_fn)
}

/// take_until：trigger 发射后立即终止源流
pub fn[T, E] Observable::take_until(
  self : Observable[T, E],
  trigger : Observable[Unit, E],
) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let trigger_fn = trigger.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    // 状态必须每次订阅重新创建：冷流多次订阅互不影响
    let stopped = Ref::Ref(false)
    let trigger_sub = Ref::Ref(Subscription::empty())
    let source_sub = Ref::Ref(Subscription::empty())
    trigger_sub.val = trigger_fn({
      next: fn(_ : Unit) {
        if !stopped.val {
          stopped.val = true
          // 触发即终止：取消源流，避免热流继续泄漏
          (source_sub.val).dispose()
          complete()
        }
      },
      error: fn(_ : E) {},
      complete: fn() {}, interrupt: Ref::Ref(None),
    })
    source_sub.val = source_fn({
      next: fn(v : T) {
        if !stopped.val {
          next(v)
        }
      },
      error: fn(e : E) {
        if !stopped.val {
          error(e)
        }
      },
      complete: fn() {
        if !stopped.val {
          stopped.val = true
          complete()
        }
      }, interrupt: Ref::Ref(None),
    })
    Subscription::new(fn() {
      stopped.val = true
      (trigger_sub.val).dispose()
      (source_sub.val).dispose()
    })
  }
  Observable::new(subscribe_fn)
}

/// 是否包含目标值：找到发 true 完成，流结束未找到发 false
pub fn[T : Eq, E] Observable::contains(
  self : Observable[T, E],
  target : T,
) -> Observable[Bool, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[Bool, E]) -> Subscription = fn(downstream : Observer[Bool, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let found = Ref::Ref(false)
    let stopped = Ref::Ref(false)
    let source_sub = Ref::Ref(Subscription::empty())
    source_sub.val = source_fn({
      next: fn(v : T) {
        if !stopped.val && !found.val {
          if v == target {
            found.val = true
            stopped.val = true
            next(true)
            // 找到后立即取消上游，避免热流继续泄漏
            (source_sub.val).dispose()
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
          if !found.val {
            next(false)
          }
          complete()
        }
      }, interrupt: Ref::Ref(None),
    })
    Subscription::new(fn() {
      stopped.val = true
      (source_sub.val).dispose()
    })
  }
  Observable::new(subscribe_fn)
}

/// includes：contains 的别名
pub fn[T : Eq, E] Observable::includes(
  self : Observable[T, E],
  target : T,
) -> Observable[Bool, E] {
  self.contains(target)
}
