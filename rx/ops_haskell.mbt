// ============================================================================
// Haskell 迭代器语义操作符移植
// 对照 Data.List / Data.Foldable / Data.Iterator 的语义操作，补齐 rx 缺失项。
// 命名说明：Haskell 的 `break` / `group` / `delete` 等与语言关键字或既有
// 语义冲突，分别映射为 break_pred / group_adjacent / delete_first。
// 语义对照（Haskell -> rx）：
//   iterate        -> Observable::iterate        （无限迭代）
//   repeat         -> Observable::repeat_infinite（无限重复）
//   cycle          -> Observable::cycle          （无限循环）
//   unfoldr        -> Observable::unfoldr        （展开）
//   reverse        -> Observable::reverse        （收集后反转）
//   intersperse    -> Observable::intersperse    （元素间插分隔符）
//   intercalate    -> Observable::intercalate    （数组流用分隔数组连接）
//   zipWith        -> Observable::zip_with       （zip + 映射）
//   zip3           -> Observable::zip3           （三流拉链）
//   unzip          -> Observable::unzip          （tuple 流拆两列）
//   transpose      -> Observable::transpose      （矩阵转置）
//   span / break   -> Observable::span / break_pred
//   splitAt        -> Observable::split_at
//   partition      -> Observable::partition
//   notElem        -> Observable::not_elem
//   delete         -> Observable::delete_first
//   group / groupBy-> Observable::group_adjacent / group_adjacent_by
//   isPrefixOf 等  -> Observable::is_prefix_of / is_suffix_of / is_infix_of
//   foldr          -> Observable::foldr          （右折叠）
//   scanr          -> Observable::scanr          （右扫描）
//   product        -> Observable::product        （累乘）
//   foldMap        -> Observable::fold_map       （map + fold 单趟）
//   sortBy         -> Observable::sort_by        （比较函数排序）
//   sortOn         -> Observable::sort_on        （键投影排序）
//   maximumBy 等   -> Observable::maximum_by_cmp / minimum_by_cmp
//   findIndices    -> Observable::find_indices
//   elemIndex 等   -> Observable::elem_index / elem_indices
//   lookup         -> Observable::lookup
//   Data.Iterator.fold -> Itor::fold
// ============================================================================

// ----------------------------------------------------------------------------
// 构建类
// ----------------------------------------------------------------------------

/// iterate：从 seed 出发无限发射 x, f(x), f(f(x)), ...
/// 语义同 Haskell `iterate f x`。配合 take(n) 截断；直接订阅会无限循环
/// （与 Haskell 无限列表行为一致）。dispose 可中断。
pub fn[T, E] Observable::iterate(
  f : (T) -> T,
  seed : T,
) -> Observable[T, E] {
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(observer : Observer[T, E]) {
    let stopped = Ref::Ref(false)
    // 下游完成信号：take 取够后通过 interrupt 通道中断同步循环（修复死循环 bug）
    let finished = Ref::Ref(false)
    // 下游（take / take_while）可通过 interrupt 通道请求停止同步循环
    observer.interrupt.val = Some(fn() { finished.val = true })
    let wrapped : Observer[T, E] = {
      next: observer.next,
      error: fn(e : E) {
        finished.val = true
        observer.on_error(e)
      },
      complete: fn() {
        finished.val = true
        observer.on_completed()
      },
      interrupt: observer.interrupt,
    }
    let mut cur = seed
    while !stopped.val && !finished.val {
      wrapped.on_next(cur)
      cur = f(cur)
    }
    Subscription::new(fn() { stopped.val = true })
  }
  Observable::new(subscribe_fn)
}

/// repeat_infinite：无限发射同一个值。
/// 语义同 Haskell `repeat x`。配合 take(n) 截断；dispose 可中断。
pub fn[T, E] Observable::repeat_infinite(value : T) -> Observable[T, E] {
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(observer : Observer[T, E]) {
    let stopped = Ref::Ref(false)
    let finished = Ref::Ref(false)
    observer.interrupt.val = Some(fn() { finished.val = true })
    let wrapped : Observer[T, E] = {
      next: observer.next,
      error: fn(e : E) {
        finished.val = true
        observer.on_error(e)
      },
      complete: fn() {
        finished.val = true
        observer.on_completed()
      },
      interrupt: observer.interrupt,
    }
    while !stopped.val && !finished.val {
      wrapped.on_next(value)
    }
    Subscription::new(fn() { stopped.val = true })
  }
  Observable::new(subscribe_fn)
}

/// cycle：无限循环发射数组中的元素。
/// 语义同 Haskell `cycle xs`。配合 take(n) 截断；dispose 可中断。
pub fn[T, E] Observable::cycle(values : Array[T]) -> Observable[T, E] {
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(observer : Observer[T, E]) {
    let stopped = Ref::Ref(false)
    let finished = Ref::Ref(false)
    observer.interrupt.val = Some(fn() { finished.val = true })
    let wrapped : Observer[T, E] = {
      next: observer.next,
      error: fn(e : E) {
        finished.val = true
        observer.on_error(e)
      },
      complete: fn() {
        finished.val = true
        observer.on_completed()
      },
      interrupt: observer.interrupt,
    }
    while !stopped.val && !finished.val {
      for v in values {
        if stopped.val || finished.val {
          break
        }
        wrapped.on_next(v)
      }
    }
    Subscription::new(fn() { stopped.val = true })
  }
  Observable::new(subscribe_fn)
}

/// unfoldr：从 seed 出发，用 f 逐步展开。
/// 语义同 Haskell `unfoldr :: (b -> Maybe (a, b)) -> b -> [a]`：
/// f(seed) 返回 Some((value, next_seed)) 则发射 value 并继续，None 则结束。
pub fn[T, E, S] Observable::unfoldr(
  f : (S) -> (T, S)?,
  seed : S,
) -> Observable[T, E] {
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(observer : Observer[T, E]) {
    let stopped = Ref::Ref(false)
    // 下游（take / take_while）可通过 interrupt 通道请求停止同步循环
    let finished = Ref::Ref(false)
    observer.interrupt.val = Some(fn() { finished.val = true })
    let wrapped : Observer[T, E] = {
      next: observer.next,
      error: fn(e : E) {
        finished.val = true
        observer.on_error(e)
      },
      complete: fn() {
        finished.val = true
        observer.on_completed()
      },
      interrupt: observer.interrupt,
    }
    let mut state = seed
    while !stopped.val && !finished.val {
      match f(state) {
        Some((value, next_state)) => {
          wrapped.on_next(value)
          state = next_state
        }
        None => break
      }
    }
    observer.on_completed()
    Subscription::new(fn() { stopped.val = true })
  }
  Observable::new(subscribe_fn)
}

// ----------------------------------------------------------------------------
// 变换类
// ----------------------------------------------------------------------------

/// reverse：收集所有值，反转后一次性发出（Array[T]）。
/// 语义同 Haskell `reverse`。
pub fn[T, E] Observable::reverse(self : Observable[T, E]) -> Observable[Array[T], E] {
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
        arr.rev_in_place()
        next(arr)
        complete()
      }, interrupt: Ref::Ref(None),
    })
  }
  Observable::new(subscribe_fn)
}

/// intersperse：在元素之间插入分隔符后发射。
/// 语义同 Haskell `intersperse sep xs`（元素间插入，首尾不插）。
pub fn[T, E] Observable::intersperse(
  self : Observable[T, E],
  sep : T,
) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let first = Ref::Ref(true)
    source_fn({
      next: fn(v : T) {
        if !first.val {
          next(sep)
        }
        first.val = false
        next(v)
      },
      error: error,
      complete: complete, interrupt: Ref::Ref(None),
    })
  }
  Observable::new(subscribe_fn)
}

/// intercalate：数组流（Observable[Array[T]]）展开为 T 流，
/// 组与组之间插入分隔数组 sep。
/// 语义同 Haskell `intercalate sep xss`。
pub fn[T, E] Observable::intercalate(
  self : Observable[Array[T], E],
  sep : Array[T],
) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let first = Ref::Ref(true)
    source_fn({
      next: fn(group : Array[T]) {
        if !first.val {
          for s in sep {
            next(s)
          }
        }
        first.val = false
        for v in group {
          next(v)
        }
      },
      error: error,
      complete: complete, interrupt: Ref::Ref(None),
    })
  }
  Observable::new(subscribe_fn)
}

/// zip_with：把两个流按到达顺序配对并用 f 合并发射。
/// 语义同 Haskell `zipWith f xs ys`。
pub fn[T, E, U, R] Observable::zip_with(
  self : Observable[T, E],
  other : Observable[U, E],
  f : (T, U) -> R,
) -> Observable[R, E] {
  let source_fn = self.subscribe_fn
  let other_fn = other.subscribe_fn
  let subscribe_fn : (Observer[R, E]) -> Subscription = fn(downstream : Observer[R, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let buf_a = Ref::Ref(Array::new())
    let buf_b = Ref::Ref(Array::new())
    let done_a = Ref::Ref(false)
    let done_b = Ref::Ref(false)
    let completed = Ref::Ref(false)
    let a_sub = Ref::Ref(Subscription::empty())
    let b_sub = Ref::Ref(Subscription::empty())
    let try_emit : () -> Unit = fn() {
      while !buf_a.val.is_empty() && !buf_b.val.is_empty() && !completed.val {
        let x = buf_a.val.remove(0)
        let y = buf_b.val.remove(0)
        next(f(x, y))
      }
      if !completed.val {
        if (done_a.val && buf_a.val.is_empty()) || (done_b.val && buf_b.val.is_empty()) {
          completed.val = true
          (a_sub.val).dispose()
          (b_sub.val).dispose()
          complete()
        }
      }
    }
    let fail : (E) -> Unit = fn(e : E) {
      if !completed.val {
        completed.val = true
        (a_sub.val).dispose()
        (b_sub.val).dispose()
        error(e)
      }
    }
    a_sub.val = source_fn({
      next: fn(v : T) {
        if !completed.val {
          buf_a.val.push(v)
          try_emit()
        }
      },
      error: fail,
      complete: fn() {
        done_a.val = true
        try_emit()
      }, interrupt: Ref::Ref(None),
    })
    b_sub.val = other_fn({
      next: fn(v : U) {
        if !completed.val {
          buf_b.val.push(v)
          try_emit()
        }
      },
      error: fail,
      complete: fn() {
        done_b.val = true
        try_emit()
      }, interrupt: Ref::Ref(None),
    })
    try_emit()
    Subscription::new(fn() {
      completed.val = true
      (a_sub.val).dispose()
      (b_sub.val).dispose()
    })
  }
  Observable::new(subscribe_fn)
}

/// zip3：三流拉链，发 (T, U, V) 元组。
/// 语义同 Haskell `zip3`。
pub fn[T, E, U, V] Observable::zip3(
  self : Observable[T, E],
  b : Observable[U, E],
  c : Observable[V, E],
) -> Observable[(T, U, V), E] {
  let source_fn = self.subscribe_fn
  let b_fn = b.subscribe_fn
  let c_fn = c.subscribe_fn
  let subscribe_fn : (Observer[(T, U, V), E]) -> Subscription =
    fn(downstream : Observer[(T, U, V), E]) {
      let next = downstream.next
      let error = downstream.error
      let complete = downstream.complete
      let buf_a = Ref::Ref(Array::new())
      let buf_b = Ref::Ref(Array::new())
      let buf_c = Ref::Ref(Array::new())
      let done_a = Ref::Ref(false)
      let done_b = Ref::Ref(false)
      let done_c = Ref::Ref(false)
      let completed = Ref::Ref(false)
      let a_sub = Ref::Ref(Subscription::empty())
      let b_sub = Ref::Ref(Subscription::empty())
      let c_sub = Ref::Ref(Subscription::empty())
      let try_emit : () -> Unit = fn() {
        while !buf_a.val.is_empty() && !buf_b.val.is_empty() && !buf_c.val.is_empty() &&
          !completed.val {
          let x = buf_a.val.remove(0)
          let y = buf_b.val.remove(0)
          let z = buf_c.val.remove(0)
          next((x, y, z))
        }
        if !completed.val {
          if (done_a.val && buf_a.val.is_empty()) || (done_b.val && buf_b.val.is_empty()) ||
            (done_c.val && buf_c.val.is_empty()) {
            completed.val = true
            (a_sub.val).dispose()
            (b_sub.val).dispose()
            (c_sub.val).dispose()
            complete()
          }
        }
      }
      let fail : (E) -> Unit = fn(e : E) {
        if !completed.val {
          completed.val = true
          (a_sub.val).dispose()
          (b_sub.val).dispose()
          (c_sub.val).dispose()
          error(e)
        }
      }
      a_sub.val = source_fn({
        next: fn(v : T) {
          if !completed.val {
            buf_a.val.push(v)
            try_emit()
          }
        },
        error: fail,
        complete: fn() {
          done_a.val = true
          try_emit()
        }, interrupt: Ref::Ref(None),
      })
      b_sub.val = b_fn({
        next: fn(v : U) {
          if !completed.val {
            buf_b.val.push(v)
            try_emit()
          }
        },
        error: fail,
        complete: fn() {
          done_b.val = true
          try_emit()
        }, interrupt: Ref::Ref(None),
      })
      c_sub.val = c_fn({
        next: fn(v : V) {
          if !completed.val {
            buf_c.val.push(v)
            try_emit()
          }
        },
        error: fail,
        complete: fn() {
          done_c.val = true
          try_emit()
        }, interrupt: Ref::Ref(None),
      })
      try_emit()
      Subscription::new(fn() {
        completed.val = true
        (a_sub.val).dispose()
        (b_sub.val).dispose()
        (c_sub.val).dispose()
      })
    }
  Observable::new(subscribe_fn)
}

/// unzip：tuple 流收集后拆成 (Array[T], Array[U]) 两列发出。
/// 语义同 Haskell `unzip`。
pub fn[T, E, U] Observable::unzip(
  self : Observable[(T, U), E],
) -> Observable[(Array[T], Array[U]), E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[(Array[T], Array[U]), E]) -> Subscription =
    fn(downstream : Observer[(Array[T], Array[U]), E]) {
      let next = downstream.next
      let error = downstream.error
      let complete = downstream.complete
      let col_a = Ref::Ref(Array::new())
      let col_b = Ref::Ref(Array::new())
      source_fn({
        next: fn(pair : (T, U)) {
          col_a.val.push(pair.0)
          col_b.val.push(pair.1)
        },
        error: error,
        complete: fn() {
          next((col_a.val, col_b.val))
          complete()
        }, interrupt: Ref::Ref(None),
      })
    }
  Observable::new(subscribe_fn)
}

/// transpose：数组流（Observable[Array[T]]）收集后按列转置。
/// 语义同 Haskell `transpose`：结果第 i 行 = 各输入行第 i 列元素
/// （按最长行对齐，短行缺失列跳过）。
pub fn[T, E] Observable::transpose(
  self : Observable[Array[T], E],
) -> Observable[Array[Array[T]], E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[Array[Array[T]], E]) -> Subscription =
    fn(downstream : Observer[Array[Array[T]], E]) {
      let next = downstream.next
      let error = downstream.error
      let complete = downstream.complete
      let rows = Ref::Ref(Array::new())
      source_fn({
        next: fn(row : Array[T]) { rows.val.push(row) },
        error: error,
        complete: fn() {
          let rs = rows.val
          let mut max_len = 0
          for row in rs {
            if row.length() > max_len {
              max_len = row.length()
            }
          }
          let result = Array::new()
          let mut i = 0
          while i < max_len {
            let col = Array::new()
            for row in rs {
              if i < row.length() {
                col.push(row[i])
              }
            }
            result.push(col)
            i = i + 1
          }
          next(result)
          complete()
        }, interrupt: Ref::Ref(None),
      })
    }
  Observable::new(subscribe_fn)
}

// ----------------------------------------------------------------------------
// 过滤 / 拆分类
// ----------------------------------------------------------------------------

/// span：收集后发 (满足谓词的最长前缀, 剩余部分)。
/// 语义同 Haskell `span p xs`。
pub fn[T, E] Observable::span(
  self : Observable[T, E],
  pred : (T) -> Bool,
) -> Observable[(Array[T], Array[T]), E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[(Array[T], Array[T]), E]) -> Subscription =
    fn(downstream : Observer[(Array[T], Array[T]), E]) {
      let next = downstream.next
      let error = downstream.error
      let complete = downstream.complete
      let buf = Ref::Ref(Array::new())
      source_fn({
        next: fn(v : T) { buf.val.push(v) },
        error: error,
        complete: fn() {
          let arr = buf.val
          let prefix = Array::new()
          let rest = Array::new()
          let mut seen_break = false
          for v in arr {
            if !seen_break && pred(v) {
              prefix.push(v)
            } else {
              seen_break = true
              rest.push(v)
            }
          }
          next((prefix, rest))
          complete()
        }, interrupt: Ref::Ref(None),
      })
    }
  Observable::new(subscribe_fn)
}

/// break_pred：收集后发 (不满足谓词的最长前缀, 剩余部分)。
/// 语义同 Haskell `break p`（= span (not . p)）。`break` 为语言关键字，
/// 故命名为 break_pred。
pub fn[T, E] Observable::break_pred(
  self : Observable[T, E],
  pred : (T) -> Bool,
) -> Observable[(Array[T], Array[T]), E] {
  self.span(fn(v : T) { !pred(v) })
}

/// split_at：收集后按前 n 个元素切分，发 (前 n 个, 剩余)。
/// 语义同 Haskell `splitAt n xs`。n <= 0 时全部归入右侧；n >= 长度时全部归入左侧。
pub fn[T, E] Observable::split_at(
  self : Observable[T, E],
  n : Int,
) -> Observable[(Array[T], Array[T]), E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[(Array[T], Array[T]), E]) -> Subscription =
    fn(downstream : Observer[(Array[T], Array[T]), E]) {
      let next = downstream.next
      let error = downstream.error
      let complete = downstream.complete
      let buf = Ref::Ref(Array::new())
      source_fn({
        next: fn(v : T) { buf.val.push(v) },
        error: error,
        complete: fn() {
          let arr = buf.val
          let left = Array::new()
          let right = Array::new()
          let mut i = 0
          let mut count = 0
          while i < arr.length() {
            if count < n {
              left.push(arr[i])
            } else {
              right.push(arr[i])
            }
            count = count + 1
            i = i + 1
          }
          next((left, right))
          complete()
        }, interrupt: Ref::Ref(None),
      })
    }
  Observable::new(subscribe_fn)
}

/// partition：收集后按谓词分为 (满足组, 不满足组)。
/// 语义同 Haskell `partition p xs`。
pub fn[T, E] Observable::partition(
  self : Observable[T, E],
  pred : (T) -> Bool,
) -> Observable[(Array[T], Array[T]), E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[(Array[T], Array[T]), E]) -> Subscription =
    fn(downstream : Observer[(Array[T], Array[T]), E]) {
      let next = downstream.next
      let error = downstream.error
      let complete = downstream.complete
      let yes = Ref::Ref(Array::new())
      let no = Ref::Ref(Array::new())
      source_fn({
        next: fn(v : T) {
          if pred(v) {
            yes.val.push(v)
          } else {
            no.val.push(v)
          }
        },
        error: error,
        complete: fn() {
          next((yes.val, no.val))
          complete()
        }, interrupt: Ref::Ref(None),
      })
    }
  Observable::new(subscribe_fn)
}

/// not_elem：流中是否不含目标值。含则发 false（提前终止），不含则在流结束时发 true。
/// 语义同 Haskell `notElem x xs`。
pub fn[T : Eq, E] Observable::not_elem(
  self : Observable[T, E],
  target : T,
) -> Observable[Bool, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[Bool, E]) -> Subscription = fn(downstream : Observer[Bool, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let stopped = Ref::Ref(false)
    let source_sub = Ref::Ref(Subscription::empty())
    source_sub.val = source_fn({
      next: fn(v : T) {
        if !stopped.val {
          if v == target {
            stopped.val = true
            next(false)
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
          next(true)
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

/// delete_first：收集后删除第一个等于 target 的元素，其余保持原顺序。
/// 语义同 Haskell `delete x xs`。不存在时原样返回。
pub fn[T : Eq, E] Observable::delete_first(
  self : Observable[T, E],
  target : T,
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
        let result = Array::new()
        let mut removed = false
        for v in arr {
          if !removed && v == target {
            removed = true
          } else {
            result.push(v)
          }
        }
        next(result)
        complete()
      }, interrupt: Ref::Ref(None),
    })
  }
  Observable::new(subscribe_fn)
}

/// group_adjacent：把相邻相等的元素分成组，逐组发射 Array[T]。
/// 语义同 Haskell `group xs`（注意与既有 group_by 按键全局分组不同：
/// group_adjacent 只合并相邻且相等的元素）。
pub fn[T : Eq, E] Observable::group_adjacent(
  self : Observable[T, E],
) -> Observable[Array[T], E] {
  self.group_adjacent_by(fn(a : T, b : T) { a == b })
}

/// group_adjacent_by：把相邻且满足 f(a, b) 的元素分成组，逐组发射 Array[T]。
/// 语义同 Haskell `groupBy f xs`。
pub fn[T, E] Observable::group_adjacent_by(
  self : Observable[T, E],
  f : (T, T) -> Bool,
) -> Observable[Array[T], E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[Array[T], E]) -> Subscription = fn(downstream : Observer[Array[T], E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let current = Ref::Ref(Array::new())
    let init : T? = None
    let prev = Ref::Ref(init)
    let flush : () -> Unit = fn() {
      if !current.val.is_empty() {
        next(current.val)
        current.val = Array::new()
      }
    }
    source_fn({
      next: fn(v : T) {
        match prev.val {
          Some(p) => {
            if f(p, v) {
              current.val.push(v)
            } else {
              flush()
              current.val.push(v)
            }
          }
          None => current.val.push(v)
        }
        prev.val = Some(v)
      },
      error: error,
      complete: fn() {
        flush()
        complete()
      }, interrupt: Ref::Ref(None),
    })
  }
  Observable::new(subscribe_fn)
}

/// is_prefix_of：源流收集后判断是否以 target 开头。
/// 语义同 Haskell `isPrefixOf xs ys`。
pub fn[T : Eq, E] Observable::is_prefix_of(
  self : Observable[T, E],
  target : Array[T],
) -> Observable[Bool, E] {
  self.collect().map(fn(arr : Array[T]) {
    if target.length() > arr.length() {
      return false
    }
    let mut i = 0
    while i < target.length() {
      if arr[i] != target[i] {
        return false
      }
      i = i + 1
    }
    true
  })
}

/// is_suffix_of：源流收集后判断是否以 target 结尾。
/// 语义同 Haskell `isSuffixOf xs ys`。
pub fn[T : Eq, E] Observable::is_suffix_of(
  self : Observable[T, E],
  target : Array[T],
) -> Observable[Bool, E] {
  self.collect().map(fn(arr : Array[T]) {
    if target.length() > arr.length() {
      return false
    }
    let offset = arr.length() - target.length()
    let mut i = 0
    while i < target.length() {
      if arr[offset + i] != target[i] {
        return false
      }
      i = i + 1
    }
    true
  })
}

/// is_infix_of：源流收集后判断是否包含 target 子序列（朴素滑动窗口匹配）。
/// 语义同 Haskell `isInfixOf xs ys`。
pub fn[T : Eq, E] Observable::is_infix_of(
  self : Observable[T, E],
  target : Array[T],
) -> Observable[Bool, E] {
  self.collect().map(fn(arr : Array[T]) {
    if target.length() > arr.length() {
      return false
    }
    if target.is_empty() {
      return true
    }
    let mut start = 0
    while start + target.length() <= arr.length() {
      let mut matched = true
      let mut i = 0
      while i < target.length() {
        if arr[start + i] != target[i] {
          matched = false
          break
        }
        i = i + 1
      }
      if matched {
        return true
      }
      start = start + 1
    }
    false
  })
}

// ----------------------------------------------------------------------------
// 聚合类（右折叠 / 扫描 / 累乘 / foldMap / 排序 / 极值 / 索引 / 查找）
// ----------------------------------------------------------------------------

/// foldr：右折叠。收集后从右往左累积：f(x1, f(x2, ... f(xn, seed)))。
/// 语义同 Haskell `foldr f z xs`（注意 f 的参数顺序为 (元素, 累积)）。
pub fn[T, E, Acc] Observable::foldr(
  self : Observable[T, E],
  seed : Acc,
  f : (T, Acc) -> Acc,
) -> Observable[Acc, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[Acc, E]) -> Subscription = fn(downstream : Observer[Acc, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let buf = Ref::Ref(Array::new())
    source_fn({
      next: fn(v : T) { buf.val.push(v) },
      error: error,
      complete: fn() {
        let arr = buf.val
        let mut acc = seed
        let mut i = arr.length() - 1
        while i >= 0 {
          acc = f(arr[i], acc)
          i = i - 1
        }
        next(acc)
        complete()
      }, interrupt: Ref::Ref(None),
    })
  }
  Observable::new(subscribe_fn)
}

/// scanr：右扫描。收集后从右往左扫描，发出所有中间结果数组
/// [f(x1, acc1), f(x2, acc2), ..., seed]（Haskell scanr 的结果列表）。
pub fn[T, E, Acc] Observable::scanr(
  self : Observable[T, E],
  seed : Acc,
  f : (T, Acc) -> Acc,
) -> Observable[Array[Acc], E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[Array[Acc], E]) -> Subscription = fn(downstream : Observer[Array[Acc], E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let buf = Ref::Ref(Array::new())
    source_fn({
      next: fn(v : T) { buf.val.push(v) },
      error: error,
      complete: fn() {
        let arr = buf.val
        let results = Array::new()
        let mut acc = seed
        let mut i = arr.length() - 1
        while i >= 0 {
          acc = f(arr[i], acc)
          results.push(acc)
          i = i - 1
        }
        results.rev_in_place()
        results.push(seed)
        next(results)
        complete()
      }, interrupt: Ref::Ref(None),
    })
  }
  Observable::new(subscribe_fn)
}

/// product：累乘所有值，流结束时发出。空流不发值。
/// 语义同 Haskell `product`（T : Mul，首元素作为初始值）。
pub fn[T : Mul, E] Observable::product(self : Observable[T, E]) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let init : T? = None
    let acc = Ref::Ref(init)
    source_fn({
      next: fn(v : T) {
        match acc.val {
          Some(cur) => { acc.val = Some(cur * v) }
          None => { acc.val = Some(v) }
        }
      },
      error: error,
      complete: fn() {
        match acc.val {
          Some(v) => next(v)
          None => ()
        }
        complete()
      }, interrupt: Ref::Ref(None),
    })
  }
  Observable::new(subscribe_fn)
}

/// fold_map：mapper 映射后按 combine 累积（单趟遍历）。
/// 语义同 Haskell `foldMap`（以显式 seed + combine 替代 Monoid 约束）。
pub fn[T, E, R] Observable::fold_map(
  self : Observable[T, E],
  seed : R,
  mapper : (T) -> R,
  combine : (R, R) -> R,
) -> Observable[R, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[R, E]) -> Subscription = fn(downstream : Observer[R, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let acc = Ref::Ref(seed)
    source_fn({
      next: fn(v : T) { acc.val = combine(acc.val, mapper(v)) },
      error: error,
      complete: fn() {
        next(acc.val)
        complete()
      }, interrupt: Ref::Ref(None),
    })
  }
  Observable::new(subscribe_fn)
}

/// sort_by：收集后按比较函数 cmp(a, b) 排序（稳定插入排序）。
/// 语义同 Haskell `sortBy cmp xs`。cmp 返回负数/零/正数表示 a<b/a=b/a>b。
pub fn[T, E] Observable::sort_by(
  self : Observable[T, E],
  cmp : (T, T) -> Int,
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
        insertion_sort(arr, cmp)
        next(arr)
        complete()
      }, interrupt: Ref::Ref(None),
    })
  }
  Observable::new(subscribe_fn)
}

/// sort_on：收集后按键投影 key_fn 排序（稳定插入排序）。
/// 语义同 Haskell `sortOn f xs`（键类型需要 Compare）。
pub fn[T, E, K : Compare] Observable::sort_on(
  self : Observable[T, E],
  key_fn : (T) -> K,
) -> Observable[Array[T], E] {
  self.sort_by(fn(a : T, b : T) { key_fn(a).compare(key_fn(b)) })
}

/// maximum_by_cmp：按比较函数求最大值（流结束时发出，空流不发值）。
/// 语义同 Haskell `maximumBy cmp xs`。
pub fn[T, E] Observable::maximum_by_cmp(
  self : Observable[T, E],
  cmp : (T, T) -> Int,
) -> Observable[T, E] {
  self.extreme_by_cmp(fn(c : Int) { c > 0 }, cmp)
}

/// minimum_by_cmp：按比较函数求最小值（流结束时发出，空流不发值）。
/// 语义同 Haskell `minimumBy cmp xs`。
pub fn[T, E] Observable::minimum_by_cmp(
  self : Observable[T, E],
  cmp : (T, T) -> Int,
) -> Observable[T, E] {
  self.extreme_by_cmp(fn(c : Int) { c < 0 }, cmp)
}

/// extreme_by_cmp：按谓词判断是否替换当前最优（内部辅助）。
fn[T, E] Observable::extreme_by_cmp(
  self : Observable[T, E],
  better : (Int) -> Bool,
  cmp : (T, T) -> Int,
) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let init : T? = None
    let best = Ref::Ref(init)
    source_fn({
      next: fn(v : T) {
        match best.val {
          Some(cur) => {
            if better(cmp(v, cur)) {
              best.val = Some(v)
            }
          }
          None => best.val = Some(v)
        }
      },
      error: error,
      complete: fn() {
        match best.val {
          Some(v) => next(v)
          None => ()
        }
        complete()
      }, interrupt: Ref::Ref(None),
    })
  }
  Observable::new(subscribe_fn)
}

/// find_indices：收集所有满足谓词的元素的索引，流结束时发 Array[Int]。
/// 语义同 Haskell `findIndices p xs`。
pub fn[T, E] Observable::find_indices(
  self : Observable[T, E],
  pred : (T) -> Bool,
) -> Observable[Array[Int], E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[Array[Int], E]) -> Subscription = fn(downstream : Observer[Array[Int], E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let idxs = Ref::Ref(Array::new())
    let idx = Ref::Ref(0)
    source_fn({
      next: fn(v : T) {
        if pred(v) {
          idxs.val.push(idx.val)
        }
        idx.val = idx.val + 1
      },
      error: error,
      complete: fn() {
        next(idxs.val)
        complete()
      }, interrupt: Ref::Ref(None),
    })
  }
  Observable::new(subscribe_fn)
}

/// elem_index：第一个等于 target 的元素的索引，找不到发 -1。
/// 语义同 Haskell `elemIndex x xs`。
pub fn[T : Eq, E] Observable::elem_index(
  self : Observable[T, E],
  target : T,
) -> Observable[Int64, E] {
  self.find_index(fn(v : T) { v == target })
}

/// elem_indices：收集所有等于 target 的元素的索引，流结束时发 Array[Int]。
/// 语义同 Haskell `elemIndices x xs`。
pub fn[T : Eq, E] Observable::elem_indices(
  self : Observable[T, E],
  target : T,
) -> Observable[Array[Int], E] {
  self.find_indices(fn(v : T) { v == target })
}

/// lookup：在 (K, V) 投影流中查找第一个 key_fn(v) == key 的值，发 val_fn(v)；
/// 找不到发 None。语义同 Haskell `lookup key assocs`（K : Eq）。
pub fn[T, E, K : Eq, V] Observable::lookup(
  self : Observable[T, E],
  key : K,
  key_fn : (T) -> K,
  val_fn : (T) -> V,
) -> Observable[V?, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[V?, E]) -> Subscription = fn(downstream : Observer[V?, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let found = Ref::Ref(None)
    let stopped = Ref::Ref(false)
    let source_sub = Ref::Ref(Subscription::empty())
    source_sub.val = source_fn({
      next: fn(v : T) {
        if !stopped.val && found.val is None {
          if key_fn(v) == key {
            found.val = Some(val_fn(v))
            stopped.val = true
            next(found.val)
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
          next(None)
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

// ----------------------------------------------------------------------------
// 内部辅助
// ----------------------------------------------------------------------------

/// insertion_sort：稳定插入排序（就地修改数组）。cmp 返回负数/零/正数。
fn[T] insertion_sort(arr : Array[T], cmp : (T, T) -> Int) -> Unit {
  let mut i = 1
  while i < arr.length() {
    let key = arr[i]
    let mut j = i - 1
    while j >= 0 && cmp(arr[j], key) > 0 {
      arr[j + 1] = arr[j]
      j = j - 1
    }
    arr[j + 1] = key
    i = i + 1
  }
}