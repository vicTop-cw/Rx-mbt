// ============================================================================
// Itor 的 Haskell 迭代器语义操作
// 对照 Data.List / Data.Iterator 的语义操作，补齐 Itor（可控制迭代器）
// 缺失的变换 / 折叠 / 拆分 / 判定 / 构造类 API。
//
// 语义对照（Haskell -> Itor）：
//   构造：iterate / repeat / cycle / unfoldr / fromList(from_iter)
//   变换：map(fmap) / filter / take / drop / takeWhile / dropWhile /
//         scanl(scan) / reverse / intersperse / concatMap(concat_map) /
//         zip / zipWith(zip_with)
//   折叠：foldl(fold) / foldr / length / null / sum / product /
//         any / all / elem / notElem(not_elem) / find / findIndex(find_index) /
//         maximum / minimum / toList(to_array)
//   拆分：partition / span / break(break_pred) / splitAt(split_at) /
//         group(group_adjacent) / isPrefixOf / isSuffixOf / isInfixOf
//
// 设计约定：
// - 变换类返回【新的 Itor】，惰性包装源 Itor 的 next，保留可控制能力
//   （变换后的 Itor 依然可 send 插队 / set_pause / stop / restart）。
// - 折叠 / 拆分 / 判定类为【消费式】：耗尽迭代器后返回结果（与 fold 一致）。
// - 无限构造（iterate / repeat / cycle）配合 take(n) 截断使用。
// ============================================================================

// ----------------------------------------------------------------------------
// 构造类（静态工厂）
// ----------------------------------------------------------------------------

/// iterate：从 seed 出发无限产出 x, f(x), f(f(x)), ...
/// 语义同 Haskell `iterate f x`。配合 `take(n)` 截断；`stop` 可终止。
pub fn[T] Itor::iterate(f : (T) -> T, seed : T) -> Itor[T] {
  let cur = Ref::Ref(seed)
  Itor::new(fn() {
    Iter::new(fn() -> T? {
      let v = cur.val
      cur.val = f(v)
      Some(v)
    })
  })
}

/// repeat：无限产出同一个值。
/// 语义同 Haskell `repeat x`。配合 `take(n)` 截断。
pub fn[T] Itor::repeat(value : T) -> Itor[T] {
  Itor::new(fn() {
    Iter::new(fn() -> T? { Some(value) })
  })
}

/// cycle：无限循环产出数组中的元素。
/// 语义同 Haskell `cycle xs`。空数组立即结束；配合 `take(n)` 截断。
pub fn[T] Itor::cycle(values : Array[T]) -> Itor[T] {
  let idx = Ref::Ref(0)
  Itor::new(fn() {
    Iter::new(fn() -> T? {
      if values.is_empty() {
        return None
      }
      let v = values[idx.val % values.length()]
      idx.val = idx.val + 1
      Some(v)
    })
  })
}

/// unfoldr：从 seed 出发，用 f 逐步展开。
/// 语义同 Haskell `unfoldr :: (b -> Maybe (a, b)) -> b -> [a]`：
/// f(seed) 返回 Some((value, next_seed)) 则产出 value 并继续，None 则结束。
pub fn[T, S] Itor::unfoldr(f : (S) -> (T, S)?, seed : S) -> Itor[T] {
  let state = Ref::Ref(seed)
  Itor::new(fn() {
    Iter::new(fn() -> T? {
      match f(state.val) {
        Some((v, next_s)) => {
          state.val = next_s
          Some(v)
        }
        None => None
      }
    })
  })
}

// ----------------------------------------------------------------------------
// 变换类（返回新 Itor，惰性包装源）
// ----------------------------------------------------------------------------

/// map：对每个产出值应用 f。
/// 语义同 Haskell `map` / `fmap`。返回新 Itor，共享源迭代状态。
pub fn[T, U] Itor::map(self : Itor[T], f : (T) -> U) -> Itor[U] {
  let src = self
  Itor::new(fn() {
    Iter::new(fn() -> U? {
      match src.next() {
        Some(v) => Some(f(v))
        None => None
      }
    })
  })
}

/// filter：只保留满足 pred 的值。
/// 语义同 Haskell `filter`。
pub fn[T] Itor::filter(self : Itor[T], pred : (T) -> Bool) -> Itor[T] {
  let src = self
  Itor::new(fn() {
    Iter::new(fn() -> T? {
      let mut result : T? = None
      while true {
        match src.next() {
          Some(v) => {
            if pred(v) {
              result = Some(v)
              break
            }
          }
          None => break
        }
      }
      result
    })
  })
}

/// take：只取前 n 个值。
/// 语义同 Haskell `take n xs`。n <= 0 立即结束。
pub fn[T] Itor::take(self : Itor[T], n : Int) -> Itor[T] {
  let src = self
  let taken = Ref::Ref(0)
  Itor::new(fn() {
    Iter::new(fn() -> T? {
      if taken.val >= n {
        return None
      }
      match src.next() {
        Some(v) => {
          taken.val = taken.val + 1
          Some(v)
        }
        None => None
      }
    })
  })
}

/// drop：跳过前 n 个值，之后正常产出。
/// 语义同 Haskell `drop n xs`。n <= 0 时原样透传。
pub fn[T] Itor::drop(self : Itor[T], n : Int) -> Itor[T] {
  let src = self
  let skipped = Ref::Ref(0)
  Itor::new(fn() {
    Iter::new(fn() -> T? {
      while skipped.val < n {
        match src.next() {
          Some(_) => skipped.val = skipped.val + 1
          None => return None
        }
      }
      src.next()
    })
  })
}

/// take_while：从头部开始取满足 pred 的值，遇到第一个不满足即停止。
/// 语义同 Haskell `takeWhile p xs`。
pub fn[T] Itor::take_while(self : Itor[T], pred : (T) -> Bool) -> Itor[T] {
  let src = self
  let done = Ref::Ref(false)
  Itor::new(fn() {
    Iter::new(fn() -> T? {
      if done.val {
        return None
      }
      match src.next() {
        Some(v) => {
          if pred(v) {
            Some(v)
          } else {
            done.val = true
            None
          }
        }
        None => None
      }
    })
  })
}

/// drop_while：跳过头部满足 pred 的值，遇到第一个不满足后全部透传。
/// 语义同 Haskell `dropWhile p xs`。
pub fn[T] Itor::drop_while(self : Itor[T], pred : (T) -> Bool) -> Itor[T] {
  let src = self
  let dropping = Ref::Ref(true)
  Itor::new(fn() {
    Iter::new(fn() -> T? {
      let mut result : T? = None
      while true {
        match src.next() {
          Some(v) => {
            if dropping.val && pred(v) {
              continue
            }
            dropping.val = false
            result = Some(v)
            break
          }
          None => break
        }
      }
      result
    })
  })
}

/// scan：带累积的扫描，产出 [seed, f(seed, x1), f(f(seed, x1), x2), ...]。
/// 语义同 Haskell `scanl f z xs`（包含初始 seed）。
pub fn[T, Acc] Itor::scan(
  self : Itor[T],
  seed : Acc,
  f : (Acc, T) -> Acc,
) -> Itor[Acc] {
  let src = self
  let acc = Ref::Ref(seed)
  let first = Ref::Ref(true)
  Itor::new(fn() {
    Iter::new(fn() -> Acc? {
      if first.val {
        first.val = false
        return Some(acc.val)
      }
      match src.next() {
        Some(v) => {
          acc.val = f(acc.val, v)
          Some(acc.val)
        }
        None => None
      }
    })
  })
}

/// reverse：收集全部值，反转后逐个产出。
/// 语义同 Haskell `reverse`（需要完整消费源后才开始产出）。
pub fn[T] Itor::reverse(self : Itor[T]) -> Itor[T] {
  let src = self
  let buf = Ref::Ref(Array::new())
  let idx = Ref::Ref(0)
  let loaded = Ref::Ref(false)
  Itor::new(fn() {
    Iter::new(fn() -> T? {
      if !loaded.val {
        while true {
          match src.next() {
            Some(v) => buf.val.push(v)
            None => break
          }
        }
        buf.val.rev_in_place()
        loaded.val = true
      }
      if idx.val < buf.val.length() {
        let v = buf.val[idx.val]
        idx.val = idx.val + 1
        Some(v)
      } else {
        None
      }
    })
  })
}

/// intersperse：在每两个相邻值之间插入 sep。
/// 语义同 Haskell `intersperse sep xs`（首尾不插）。
pub fn[T] Itor::intersperse(self : Itor[T], sep : T) -> Itor[T] {
  let src = self
  let first = Ref::Ref(true)
  let pending_val : Ref[T?] = Ref::Ref(None)
  Itor::new(fn() {
    Iter::new(fn() -> T? {
      // 1. 待发暂存值（上一个非首值，其前已发过 sep）
      match pending_val.val {
        Some(v) => {
          pending_val.val = None
          return Some(v)
        }
        None => ()
      }
      // 2. 取新值
      match src.next() {
        Some(v) => {
          if first.val {
            first.val = false
            Some(v)
          } else {
            // 非首值：先发 sep，把 v 暂存到下次
            pending_val.val = Some(v)
            Some(sep)
          }
        }
        None => None
      }
    })
  })
}

/// concat_map：对每个值调用 f 得到子迭代器，依次拼接产出。
/// 语义同 Haskell `concatMap` / `Data.Iterator` 的 bind。
pub fn[T, U] Itor::concat_map(self : Itor[T], f : (T) -> Itor[U]) -> Itor[U] {
  let src = self
  let inner : Ref[Itor[U]?] = Ref::Ref(None)
  Itor::new(fn() {
    Iter::new(fn() -> U? {
      let mut result : U? = None
      while true {
        match inner.val {
          Some(it) => {
            match it.next() {
              Some(v) => {
                result = Some(v)
                break
              }
              None => inner.val = None
            }
          }
          None => {
            match src.next() {
              Some(t) => inner.val = Some(f(t))
              None => break
            }
          }
        }
      }
      result
    })
  })
}

/// zip_with：从两个迭代器各取一个值，用 f 合并产出。
/// 语义同 Haskell `zipWith f xs ys`；任一方耗尽即结束。
pub fn[T, U, R] Itor::zip_with(
  self : Itor[T],
  other : Itor[U],
  f : (T, U) -> R,
) -> Itor[R] {
  let src_a = self
  let src_b = other
  Itor::new(fn() {
    Iter::new(fn() -> R? {
      match (src_a.next(), src_b.next()) {
        (Some(a), Some(b)) => Some(f(a, b))
        _ => None
      }
    })
  })
}

/// zip：从两个迭代器各取一个值，配对成元组产出。
/// 语义同 Haskell `zip`；任一方耗尽即结束。
pub fn[T, U] Itor::zip(self : Itor[T], other : Itor[U]) -> Itor[(T, U)] {
  self.zip_with(other, fn(a : T, b : U) { (a, b) })
}

// ----------------------------------------------------------------------------
// 折叠 / 聚合类（消费式）
// ----------------------------------------------------------------------------

/// foldr：右折叠。先收集全部，再从右往左累积：f(x1, f(x2, ... f(xn, seed)))。
/// 语义同 Haskell `foldr f z xs`（f 参数顺序为 (元素, 累积)）。
pub fn[T, Acc] Itor::foldr(self : Itor[T], seed : Acc, f : (T, Acc) -> Acc) -> Acc {
  let arr = self.to_array()
  let mut acc = seed
  let mut i = arr.length() - 1
  while i >= 0 {
    acc = f(arr[i], acc)
    i = i - 1
  }
  acc
}

/// length：统计元素个数。
/// 语义同 Haskell `length`。
pub fn[T] Itor::length(self : Itor[T]) -> Int {
  let mut n = 0
  while true {
    match self.next() {
      Some(_) => n = n + 1
      None => break
    }
  }
  n
}

/// null：迭代器是否为空（无元素）。
/// 语义同 Haskell `null`。
pub fn[T] Itor::null(self : Itor[T]) -> Bool {
  self.next() is None
}

/// sum：累加所有值。空迭代器返回 `T` 的默认值。
/// 语义同 Haskell `sum`（T : Add + Default）。
pub fn[T : Add + Default] Itor::sum(self : Itor[T]) -> T {
  let mut acc : T = Default::default()
  while true {
    match self.next() {
      Some(v) => acc = acc + v
      None => break
    }
  }
  acc
}

/// product：累乘所有值。空迭代器返回 `None`。
/// 语义同 Haskell `product`（T : Mul，空流无单位元故返回 None）。
pub fn[T : Mul] Itor::product(self : Itor[T]) -> T? {
  let init : T? = None
  let acc = Ref::Ref(init)
  while true {
    match self.next() {
      Some(v) => {
        match acc.val {
          Some(cur) => acc.val = Some(cur * v)
          None => acc.val = Some(v)
        }
      }
      None => break
    }
  }
  acc.val
}

/// any：是否存在满足 pred 的值（遇到第一个 true 提前终止）。
/// 语义同 Haskell `any p xs`。
pub fn[T] Itor::any(self : Itor[T], pred : (T) -> Bool) -> Bool {
  let mut found = false
  while true {
    match self.next() {
      Some(v) => {
        if pred(v) {
          found = true
          break
        }
      }
      None => break
    }
  }
  found
}

/// all：是否全部满足 pred（遇到第一个 false 提前终止）。
/// 语义同 Haskell `all p xs`。
pub fn[T] Itor::all(self : Itor[T], pred : (T) -> Bool) -> Bool {
  let mut ok = true
  while true {
    match self.next() {
      Some(v) => {
        if !pred(v) {
          ok = false
          break
        }
      }
      None => break
    }
  }
  ok
}

/// elem：是否包含等于 x 的值。
/// 语义同 Haskell `elem x xs`。
pub fn[T : Eq] Itor::elem(self : Itor[T], x : T) -> Bool {
  let mut found = false
  while true {
    match self.next() {
      Some(v) => {
        if v == x {
          found = true
          break
        }
      }
      None => break
    }
  }
  found
}

/// not_elem：是否不包含等于 x 的值。
/// 语义同 Haskell `notElem x xs`。
pub fn[T : Eq] Itor::not_elem(self : Itor[T], x : T) -> Bool {
  !self.elem(x)
}

/// find：返回第一个满足 pred 的值，找不到返回 None。
/// 语义同 Haskell `find p xs`（Maybe）。
pub fn[T] Itor::find(self : Itor[T], pred : (T) -> Bool) -> T? {
  let mut result : T? = None
  while true {
    match self.next() {
      Some(v) => {
        if pred(v) {
          result = Some(v)
          break
        }
      }
      None => break
    }
  }
  result
}

/// find_index：返回第一个满足 pred 的值的下标，找不到返回 None。
/// 语义同 Haskell `findIndex p xs`（Maybe Int）。
pub fn[T] Itor::find_index(self : Itor[T], pred : (T) -> Bool) -> Int64? {
  let mut result : Int64? = None
  let mut i = 0L
  while true {
    match self.next() {
      Some(v) => {
        if pred(v) {
          result = Some(i)
          break
        }
        i = i + 1
      }
      None => break
    }
  }
  result
}

/// maximum：返回最大元素，空迭代器返回 None。
/// 语义同 Haskell `maximum`（T : Compare）。
pub fn[T : Compare] Itor::maximum(self : Itor[T]) -> T? {
  let init : T? = None
  let best = Ref::Ref(init)
  while true {
    match self.next() {
      Some(v) => {
        match best.val {
          Some(cur) => {
            if v.compare(cur) > 0 {
              best.val = Some(v)
            }
          }
          None => best.val = Some(v)
        }
      }
      None => break
    }
  }
  best.val
}

/// minimum：返回最小元素，空迭代器返回 None。
/// 语义同 Haskell `minimum`（T : Compare）。
pub fn[T : Compare] Itor::minimum(self : Itor[T]) -> T? {
  let init : T? = None
  let best = Ref::Ref(init)
  while true {
    match self.next() {
      Some(v) => {
        match best.val {
          Some(cur) => {
            if v.compare(cur) < 0 {
              best.val = Some(v)
            }
          }
          None => best.val = Some(v)
        }
      }
      None => break
    }
  }
  best.val
}

/// to_array：收集全部值到数组。
/// 语义同 Haskell `toList`。
pub fn[T] Itor::to_array(self : Itor[T]) -> Array[T] {
  let arr = Array::new()
  while true {
    match self.next() {
      Some(v) => arr.push(v)
      None => break
    }
  }
  arr
}

// ----------------------------------------------------------------------------
// 拆分 / 分区类（消费式）
// ----------------------------------------------------------------------------

/// partition：按 pred 分成 (满足组, 不满足组)，保持各自原顺序。
/// 语义同 Haskell `partition p xs`。
pub fn[T] Itor::partition(
  self : Itor[T],
  pred : (T) -> Bool,
) -> (Array[T], Array[T]) {
  let yes = Array::new()
  let no = Array::new()
  while true {
    match self.next() {
      Some(v) => {
        if pred(v) {
          yes.push(v)
        } else {
          no.push(v)
        }
      }
      None => break
    }
  }
  (yes, no)
}

/// span：分成 (满足 pred 的最长前缀, 剩余部分)。
/// 语义同 Haskell `span p xs`。
pub fn[T] Itor::span(
  self : Itor[T],
  pred : (T) -> Bool,
) -> (Array[T], Array[T]) {
  let prefix = Array::new()
  let rest = Array::new()
  let mut passed = true
  while true {
    match self.next() {
      Some(v) => {
        if passed && pred(v) {
          prefix.push(v)
        } else {
          passed = false
          rest.push(v)
        }
      }
      None => break
    }
  }
  (prefix, rest)
}

/// break_pred：分成 (不满足 pred 的最长前缀, 剩余部分)。
/// 语义同 Haskell `break p`（= span (not . p)）。`break` 为关键字故加后缀。
pub fn[T] Itor::break_pred(
  self : Itor[T],
  pred : (T) -> Bool,
) -> (Array[T], Array[T]) {
  self.span(fn(v : T) { !pred(v) })
}

/// split_at：按前 n 个元素切分为 (前 n 个, 剩余)。
/// 语义同 Haskell `splitAt n xs`。
pub fn[T] Itor::split_at(self : Itor[T], n : Int) -> (Array[T], Array[T]) {
  let left = Array::new()
  let right = Array::new()
  let mut i = 0
  while true {
    match self.next() {
      Some(v) => {
        if i < n {
          left.push(v)
        } else {
          right.push(v)
        }
        i = i + 1
      }
      None => break
    }
  }
  (left, right)
}

/// group_adjacent：把相邻且相等的元素分成组，返回组数组。
/// 语义同 Haskell `group xs`。
pub fn[T : Eq] Itor::group_adjacent(self : Itor[T]) -> Array[Array[T]] {
  let groups = Array::new()
  let init : T? = None
  let prev = Ref::Ref(init)
  let cur = Ref::Ref(Array::new())
  let flush : () -> Unit = fn() {
    if !cur.val.is_empty() {
      groups.push(cur.val)
      cur.val = Array::new()
    }
  }
  while true {
    match self.next() {
      Some(v) => {
        match prev.val {
          Some(p) => {
            if p == v {
              cur.val.push(v)
            } else {
              flush()
              cur.val.push(v)
            }
          }
          None => cur.val.push(v)
        }
        prev.val = Some(v)
      }
      None => break
    }
  }
  flush()
  groups
}

// ----------------------------------------------------------------------------
// 子序列判定类（消费式）
// ----------------------------------------------------------------------------

/// is_prefix_of：是否以 xs 为前缀。
/// 语义同 Haskell `isPrefixOf xs ys`。
pub fn[T : Eq] Itor::is_prefix_of(self : Itor[T], xs : Array[T]) -> Bool {
  if xs.is_empty() {
    return true
  }
  let mut i = 0
  while i < xs.length() {
    match self.next() {
      Some(v) => {
        if v != xs[i] {
          return false
        }
        i = i + 1
      }
      None => return false
    }
  }
  true
}

/// is_suffix_of：是否以 xs 为后缀。
/// 语义同 Haskell `isSuffixOf xs ys`。
pub fn[T : Eq] Itor::is_suffix_of(self : Itor[T], xs : Array[T]) -> Bool {
  let arr = self.to_array()
  if xs.length() > arr.length() {
    return false
  }
  let offset = arr.length() - xs.length()
  let mut i = 0
  while i < xs.length() {
    if arr[offset + i] != xs[i] {
      return false
    }
    i = i + 1
  }
  true
}

/// is_infix_of：是否包含 xs 子序列（朴素滑动窗口匹配）。
/// 语义同 Haskell `isInfixOf xs ys`。
pub fn[T : Eq] Itor::is_infix_of(self : Itor[T], xs : Array[T]) -> Bool {
  let arr = self.to_array()
  if xs.is_empty() {
    return true
  }
  if xs.length() > arr.length() {
    return false
  }
  let mut start = 0
  while start + xs.length() <= arr.length() {
    let mut matched = true
    let mut i = 0
    while i < xs.length() {
      if arr[start + i] != xs[i] {
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
}

// ----------------------------------------------------------------------------
// 首尾 / 去重 / 排序 / 索引 / 累积映射 / 序列扩展
// ----------------------------------------------------------------------------

/// head：返回第一个元素，空迭代器返回 None。
/// 语义同 Haskell `head`（返回 Maybe 更安全）。
pub fn[T] Itor::head(self : Itor[T]) -> T? {
  self.next()
}

/// last：返回最后一个元素，空迭代器返回 None。
/// 语义同 Haskell `last`（返回 Maybe 更安全）。
pub fn[T] Itor::last(self : Itor[T]) -> T? {
  let init : T? = None
  let last = Ref::Ref(init)
  while true {
    match self.next() {
      Some(v) => last.val = Some(v)
      None => break
    }
  }
  last.val
}

/// tail：返回去掉第一个元素后的迭代器；空迭代器为空。
/// 语义同 Haskell `tail`（对空迭代器返回空而非抛错）。
pub fn[T] Itor::tail(self : Itor[T]) -> Itor[T] {
  let src = self
  let first = Ref::Ref(true)
  Itor::new(fn() {
    Iter::new(fn() -> T? {
      if first.val {
        first.val = false
        // 丢弃第一个元素
        let _ = src.next()
      }
      src.next()
    })
  })
}

/// init：返回去掉最后一个元素后的迭代器（先收集再截断）。
/// 语义同 Haskell `init`（对空迭代器返回空而非抛错）。
pub fn[T] Itor::init(self : Itor[T]) -> Itor[T] {
  let src = self
  Itor::new(fn() {
    let buf = Ref::Ref(Array::new())
    Iter::new(fn() -> T? {
      if buf.val.is_empty() {
        while true {
          match src.next() {
            Some(v) => buf.val.push(v)
            None => break
          }
        }
        if buf.val.is_empty() {
          return None
        }
        // 弹出最后一个（init 丢弃尾部元素）
        ignore(buf.val.pop())
      }
      if buf.val.is_empty() {
        None
      } else {
        Some(buf.val.remove(0))
      }
    })
  })
}

/// nub：去重（保留首次出现顺序）。
/// 语义同 Haskell `nub`（T : Hash + Eq）。
pub fn[T : Hash + Eq] Itor::nub(self : Itor[T]) -> Itor[T] {
  let src = self
  let seen : @hashset.HashSet[T] = @hashset.from_array([])
  Itor::new(fn() {
    Iter::new(fn() -> T? {
      let mut result : T? = None
      while true {
        match src.next() {
          Some(v) => {
            if !seen.contains(v) {
              seen.add(v)
              result = Some(v)
              break
            }
          }
          None => break
        }
      }
      result
    })
  })
}

/// sort_by：收集全部值，按比较函数 cmp 排序后逐个产出。
/// 语义同 Haskell `sortBy cmp xs`。
pub fn[T] Itor::sort_by(self : Itor[T], cmp : (T, T) -> Int) -> Itor[T] {
  let src = self
  Itor::new(fn() {
    let buf = Ref::Ref(Array::new())
    let idx = Ref::Ref(0)
    let loaded = Ref::Ref(false)
    Iter::new(fn() -> T? {
      if !loaded.val {
        while true {
          match src.next() {
            Some(v) => buf.val.push(v)
            None => break
          }
        }
        insertion_sort(buf.val, cmp)
        loaded.val = true
      }
      if idx.val < buf.val.length() {
        let v = buf.val[idx.val]
        idx.val = idx.val + 1
        Some(v)
      } else {
        None
      }
    })
  })
}

/// sort_on：收集全部值，按键投影 key_fn 排序后逐个产出。
/// 语义同 Haskell `sortOn f xs`（键类型需要 Compare）。
pub fn[T, K : Compare] Itor::sort_on(
  self : Itor[T],
  key_fn : (T) -> K,
) -> Itor[T] {
  self.sort_by(fn(a : T, b : T) { key_fn(a).compare(key_fn(b)) })
}

/// lookup：在 (K, V) 投影流中查找第一个 key_fn(v) == key 的值。
/// 语义同 Haskell `lookup key assocs`（K : Eq）。
pub fn[T, K : Eq, V] Itor::lookup(
  self : Itor[T],
  key : K,
  key_fn : (T) -> K,
  val_fn : (T) -> V,
) -> V? {
  let result : V? = None
  while true {
    match self.next() {
      Some(v) => {
        if key_fn(v) == key {
          return Some(val_fn(v))
        }
      }
      None => break
    }
  }
  result
}

/// elem_index：第一个等于 target 的元素下标，找不到返回 None。
/// 语义同 Haskell `elemIndex x xs`（Maybe Int）。
pub fn[T : Eq] Itor::elem_index(self : Itor[T], target : T) -> Int64? {
  self.find_index(fn(v : T) { v == target })
}

/// elem_indices：收集所有等于 target 的元素下标。
/// 语义同 Haskell `elemIndices x xs`。
pub fn[T : Eq] Itor::elem_indices(self : Itor[T], target : T) -> Array[Int] {
  self.find_indices(fn(v : T) { v == target })
}

/// find_indices：收集所有满足 pred 的元素下标。
/// 语义同 Haskell `findIndices p xs`。
pub fn[T] Itor::find_indices(self : Itor[T], pred : (T) -> Bool) -> Array[Int] {
  let idxs = Array::new()
  let mut i = 0
  while true {
    match self.next() {
      Some(v) => {
        if pred(v) {
          idxs.push(i)
        }
        i = i + 1
      }
      None => break
    }
  }
  idxs
}

/// map_accum_l：带累积状态的左映射。
/// 语义同 Haskell `mapAccumL f z xs`：f 接收 (累积, 元素) 返回 (新累积, 输出值)。
pub fn[T, Acc, U] Itor::map_accum_l(
  self : Itor[T],
  seed : Acc,
  f : (Acc, T) -> (Acc, U),
) -> (Acc, Array[U]) {
  let acc = Ref::Ref(seed)
  let out = Array::new()
  while true {
    match self.next() {
      Some(v) => {
        let (new_acc, u) = f(acc.val, v)
        acc.val = new_acc
        out.push(u)
      }
      None => break
    }
  }
  (acc.val, out)
}

/// map_accum_r：带累积状态的右映射（先收集再从右往左累积）。
/// 语义同 Haskell `mapAccumR f z xs`。
pub fn[T, Acc, U] Itor::map_accum_r(
  self : Itor[T],
  seed : Acc,
  f : (T, Acc) -> (U, Acc),
) -> (Acc, Array[U]) {
  let arr = self.to_array()
  let acc = Ref::Ref(seed)
  let out = Array::new()
  let mut i = arr.length() - 1
  while i >= 0 {
    let (u, new_acc) = f(arr[i], acc.val)
    acc.val = new_acc
    out.push(u)
    i = i - 1
  }
  out.rev_in_place()
  (acc.val, out)
}

/// replicate：重复 value 共 n 次。
/// 语义同 Haskell `replicate n x`。
pub fn[T] Itor::replicate(n : Int, value : T) -> Itor[T] {
  let left = Ref::Ref(n)
  Itor::new(fn() {
    Iter::new(fn() -> T? {
      if left.val <= 0 {
        None
      } else {
        left.val = left.val - 1
        Some(value)
      }
    })
  })
}

/// inits：收集全部前缀（含空与全量）。
/// 语义同 Haskell `inits`：inits [1,2,3] = [[],[1],[1,2],[1,2,3]]。
pub fn[T] Itor::inits(self : Itor[T]) -> Array[Array[T]] {
  let arr = self.to_array()
  let result = Array::new()
  result.push(Array::new())
  let prefix = Array::new()
  for v in arr {
    prefix.push(v)
    let copy = prefix.copy()
    result.push(copy)
  }
  result
}

/// tails：收集全部后缀（含全量与空）。
/// 语义同 Haskell `tails`：tails [1,2,3] = [[1,2,3],[2,3],[3],[]]。
pub fn[T] Itor::tails(self : Itor[T]) -> Array[Array[T]] {
  let arr = self.to_array()
  let result = Array::new()
  let mut i = 0
  while i <= arr.length() {
    let suffix = Array::new()
    let mut j = i
    while j < arr.length() {
      suffix.push(arr[j])
      j = j + 1
    }
    result.push(suffix)
    i = i + 1
  }
  result
}

/// concat：把 Itor[Itor[T]] 展平为 Itor[T]。
/// 语义同 Haskell `concat`。
pub fn[T] Itor::concat(self : Itor[Itor[T]]) -> Itor[T] {
  self.concat_map(fn(it : Itor[T]) { it })
}

/// intercalate：把 Itor[Array[T]] 展开为 Itor[T]，组与组之间插入 sep。
/// 语义同 Haskell `intercalate sep xss`。
pub fn[T] Itor::intercalate(self : Itor[Array[T]], sep : Array[T]) -> Itor[T] {
  let src = self
  let first = Ref::Ref(true)
  let pending_sep = Ref::Ref(Array::new())
  let inner : Ref[Array[T]] = Ref::Ref(Array::new())
  Itor::new(fn() {
    Iter::new(fn() -> T? {
      // 1. 组内值耗尽时尝试取下一组
      if inner.val.is_empty() && pending_sep.val.is_empty() {
        match src.next() {
          Some(group) => {
            if first.val {
              first.val = false
            } else {
              // 非首组：先插分隔符
              pending_sep.val = sep.copy()
            }
            inner.val = group
          }
          None => return None
        }
      }
      // 2. 待发分隔符（逐元素发出，优先于组内值）
      if !pending_sep.val.is_empty() {
        let s = pending_sep.val.remove(0)
        return Some(s)
      }
      // 3. 待发组内值
      if !inner.val.is_empty() {
        let v = inner.val.remove(0)
        return Some(v)
      }
      None
    })
  })
}
