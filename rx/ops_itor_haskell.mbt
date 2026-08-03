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

// ============================================================================
// Haskell Data.List 语义对照补全（第二批）
// 补齐以下缺失语义操作：
//   折叠：foldl1 / foldr1 / and / or / maximum_by / minimum_by
//   扫描：scanl1 / scanr / scanr1
//   排序：sort（默认自然序，T : Compare）
//   前缀/后缀：strip_prefix / strip_suffix / is_subsequence_of
//   索引：(!!) 按下标取元素 at
//   集合：nub_by / delete_first / delete_first_by / difference(\\) /
//         union / intersect / insert / insert_by
//   分组：group_adjacent_by（自定义谓词相邻分组）
//   结构：transpose / subsequences / permutations / chunks_of / fold_map
//   多元 zip：zip3 / zip_with3 / unzip / unzip3
// ============================================================================

// ----------------------------------------------------------------------------
// 折叠类补全（消费式）
// ----------------------------------------------------------------------------

/// foldl1：无种子左折叠。首元素作为初始累积值；空迭代器返回 None。
/// 语义同 Haskell `foldl1 f xs`。
pub fn[T] Itor::foldl1(self : Itor[T], f : (T, T) -> T) -> T? {
  let init : T? = None
  let acc = Ref::Ref(init)
  while true {
    match self.next() {
      Some(v) => {
        match acc.val {
          Some(a) => acc.val = Some(f(a, v))
          None => acc.val = Some(v)
        }
      }
      None => break
    }
  }
  acc.val
}

/// foldr1：无种子右折叠。末元素作为初始累积值；空迭代器返回 None。
/// 语义同 Haskell `foldr1 f xs`：f(x1, f(x2, ... f(x(n-1), xn)))。
pub fn[T] Itor::foldr1(self : Itor[T], f : (T, T) -> T) -> T? {
  let arr = self.to_array()
  if arr.is_empty() {
    return None
  }
  let mut acc = arr[arr.length() - 1]
  let mut i = arr.length() - 2
  while i >= 0 {
    acc = f(arr[i], acc)
    i = i - 1
  }
  Some(acc)
}

/// all_true：Bool 流是否全为 true（短路，遇到 false 立即返回）。
/// 语义同 Haskell `and` = foldr (&&) True（`and` 为 MoonBit 关键字故改名）。
pub fn Itor::all_true(self : Itor[Bool]) -> Bool {
  while true {
    match self.next() {
      Some(v) => {
        if !v {
          return false
        }
      }
      None => break
    }
  }
  true
}

/// any_true：Bool 流是否存在 true（短路，遇到 true 立即返回）。
/// 语义同 Haskell `or` = foldr (||) False（`or` 为 MoonBit 关键字故改名）。
pub fn Itor::any_true(self : Itor[Bool]) -> Bool {
  while true {
    match self.next() {
      Some(v) => {
        if v {
          return true
        }
      }
      None => break
    }
  }
  false
}

/// maximum_by：按比较函数求最大，空迭代器返回 None。
/// 语义同 Haskell `maximumBy cmp xs`。cmp 返回负数/零/正数。
pub fn[T] Itor::maximum_by(self : Itor[T], cmp : (T, T) -> Int) -> T? {
  let init : T? = None
  let best = Ref::Ref(init)
  while true {
    match self.next() {
      Some(v) => {
        match best.val {
          Some(cur) => {
            if cmp(v, cur) > 0 {
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

/// minimum_by：按比较函数求最小，空迭代器返回 None。
/// 语义同 Haskell `minimumBy cmp xs`。cmp 返回负数/零/正数。
pub fn[T] Itor::minimum_by(self : Itor[T], cmp : (T, T) -> Int) -> T? {
  let init : T? = None
  let best = Ref::Ref(init)
  while true {
    match self.next() {
      Some(v) => {
        match best.val {
          Some(cur) => {
            if cmp(v, cur) < 0 {
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

// ----------------------------------------------------------------------------
// 扫描类补全（scanl1 / scanr / scanr1）
// ----------------------------------------------------------------------------

/// scanl1：无种子左扫描。首元素作为初始累积值，逐元素产出累积。
/// 语义同 Haskell `scanl1 f xs`；空迭代器返回空。
pub fn[T] Itor::scanl1(self : Itor[T], f : (T, T) -> T) -> Itor[T] {
  let src = self
  let init : T? = None
  let acc = Ref::Ref(init)
  let started = Ref::Ref(false)
  Itor::new(fn() {
    Iter::new(fn() -> T? {
      if !started.val {
        match src.next() {
          Some(v) => {
            started.val = true
            acc.val = Some(v)
            return Some(v)
          }
          None => return None
        }
      }
      match src.next() {
        Some(v) => {
          match acc.val {
            Some(a) => {
              let new_acc = f(a, v)
              acc.val = Some(new_acc)
              Some(new_acc)
            }
            None => {
              acc.val = Some(v)
              Some(v)
            }
          }
        }
        None => None
      }
    })
  })
}

/// scanr：带种子的右扫描。从右往左累积，结果顺序与输入一致（末尾附 seed）。
/// 语义同 Haskell `scanr f z xs`；空迭代器产出 [z]。
pub fn[T, Acc] Itor::scanr(self : Itor[T], seed : Acc, f : (T, Acc) -> Acc) -> Itor[Acc] {
  let src = self
  Itor::new(fn() {
    let results = Ref::Ref(Array::new())
    let idx = Ref::Ref(0)
    let loaded = Ref::Ref(false)
    Iter::new(fn() -> Acc? {
      if !loaded.val {
        // 先收集全部（右折叠依赖右端）
        let arr = Array::new()
        while true {
          match src.next() {
            Some(v) => arr.push(v)
            None => break
          }
        }
        // 从右往左累积：results[i] = f(arr[i], results[i+1])，最后补 seed
        let out = Array::new()
        let mut acc = seed
        let mut i = arr.length() - 1
        while i >= 0 {
          acc = f(arr[i], acc)
          out.push(acc)
          i = i - 1
        }
        out.rev_in_place()
        out.push(seed)
        results.val = out
        loaded.val = true
      }
      if idx.val < results.val.length() {
        let v = results.val[idx.val]
        idx.val = idx.val + 1
        Some(v)
      } else {
        None
      }
    })
  })
}

/// scanr1：无种子的右扫描。末元素自身作为累积起点。
/// 语义同 Haskell `scanr1 f xs`；空迭代器返回空。
pub fn[T] Itor::scanr1(self : Itor[T], f : (T, T) -> T) -> Itor[T] {
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
        let arr = buf.val
        let results = Array::new()
        if !arr.is_empty() {
          let mut acc = arr[arr.length() - 1]
          let mut i = arr.length() - 2
          while i >= 0 {
            acc = f(arr[i], acc)
            results.push(acc)
            i = i - 1
          }
          results.rev_in_place()
          results.push(arr[arr.length() - 1])
        }
        buf.val = results
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

// ----------------------------------------------------------------------------
// 排序补全
// ----------------------------------------------------------------------------

/// sort：按自然序排序（T : Compare）。
/// 语义同 Haskell `sort xs`。收集全部后排序再逐个产出。
pub fn[T : Compare] Itor::sort(self : Itor[T]) -> Itor[T] {
  self.sort_by(fn(a : T, b : T) { a.compare(b) })
}

// ----------------------------------------------------------------------------
// 前缀 / 后缀 / 子序列（消费式）
// ----------------------------------------------------------------------------

/// strip_prefix：若流以 xs 为前缀，返回剥离后的剩余部分；否则 None。
/// 语义同 Haskell `stripPrefix xs ys`（消费式，返回剩余数组）。
pub fn[T : Eq] Itor::strip_prefix(self : Itor[T], xs : Array[T]) -> Array[T]? {
  let arr = self.to_array()
  if xs.length() > arr.length() {
    return None
  }
  let mut i = 0
  while i < xs.length() {
    if arr[i] != xs[i] {
      return None
    }
    i = i + 1
  }
  let rest = Array::new()
  let mut j = xs.length()
  while j < arr.length() {
    rest.push(arr[j])
    j = j + 1
  }
  Some(rest)
}

/// strip_suffix：若流以 xs 为后缀，返回剥离后的剩余部分；否则 None。
/// 语义同 Haskell `stripSuffix xs ys`（消费式，返回剩余数组）。
pub fn[T : Eq] Itor::strip_suffix(self : Itor[T], xs : Array[T]) -> Array[T]? {
  let arr = self.to_array()
  if xs.length() > arr.length() {
    return None
  }
  let offset = arr.length() - xs.length()
  let mut i = 0
  while i < xs.length() {
    if arr[offset + i] != xs[i] {
      return None
    }
    i = i + 1
  }
  let rest = Array::new()
  let mut j = 0
  while j < offset {
    rest.push(arr[j])
    j = j + 1
  }
  Some(rest)
}

/// is_subsequence_of：sub 是否为流的子序列（元素按序出现、不必连续）。
/// 语义同 Haskell `isSubsequenceOf sub ys`。消费式。
pub fn[T : Eq] Itor::is_subsequence_of(self : Itor[T], sub : Array[T]) -> Bool {
  let mut sub_i = 0
  while sub_i < sub.length() {
    let mut found = false
    while true {
      match self.next() {
        Some(v) => {
          if v == sub[sub_i] {
            found = true
            break
          }
        }
        None => break
      }
    }
    if !found {
      return false
    }
    sub_i = sub_i + 1
  }
  true
}

// ----------------------------------------------------------------------------
// 索引访问（(!!) 语义）
// ----------------------------------------------------------------------------

/// at：返回第 index 个元素（0 起），越界返回 None。
/// 语义同 Haskell `(!!)`，但越界返回 None 而非抛错。
pub fn[T] Itor::at(self : Itor[T], index : Int) -> T? {
  if index < 0 {
    return None
  }
  let mut i = 0
  while true {
    match self.next() {
      Some(v) => {
        if i == index {
          return Some(v)
        }
        i = i + 1
      }
      None => return None
    }
  } nobreak {
    None
  }
}

// ----------------------------------------------------------------------------
// 集合操作（nub_by / delete / difference / union / intersect / insert）
// ----------------------------------------------------------------------------

/// nub_by：按自定义相等谓词去重（保留首次出现顺序）。
/// 语义同 Haskell `nubBy eq xs`。O(n²) 线性查找，无 Hash 约束。
pub fn[T] Itor::nub_by(self : Itor[T], eq : (T, T) -> Bool) -> Itor[T] {
  let src = self
  let seen = Ref::Ref(Array::new())
  Itor::new(fn() {
    Iter::new(fn() -> T? {
      let mut result : T? = None
      while true {
        match src.next() {
          Some(v) => {
            let mut dup = false
            for s in seen.val {
              if eq(s, v) {
                dup = true
                break
              }
            }
            if !dup {
              seen.val.push(v)
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

/// delete_first：删除第一个等于 target 的元素（其余保留原序）。
/// 语义同 Haskell `delete target xs`。惰性返回新迭代器。
pub fn[T : Eq] Itor::delete_first(self : Itor[T], target : T) -> Itor[T] {
  let src = self
  let removed = Ref::Ref(false)
  Itor::new(fn() {
    Iter::new(fn() -> T? {
      let mut result : T? = None
      while true {
        match src.next() {
          Some(v) => {
            if !removed.val && v == target {
              removed.val = true
              continue
            }
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

/// delete_first_by：按自定义相等谓词删除第一个匹配 target 的元素。
/// 语义同 Haskell `deleteBy eq target xs`。惰性返回新迭代器。
pub fn[T] Itor::delete_first_by(
  self : Itor[T],
  target : T,
  eq : (T, T) -> Bool,
) -> Itor[T] {
  let src = self
  let removed = Ref::Ref(false)
  Itor::new(fn() {
    Iter::new(fn() -> T? {
      let mut result : T? = None
      while true {
        match src.next() {
          Some(v) => {
            if !removed.val && eq(v, target) {
              removed.val = true
              continue
            }
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

/// difference：列表差集。对 ys 中每个元素，依次删除流中第一个相等的出现。
/// 语义同 Haskell `(\\)`：xs \\ ys。消费式，返回剩余数组。
pub fn[T : Eq] Itor::difference(self : Itor[T], ys : Array[T]) -> Array[T] {
  let arr = self.to_array()
  let remaining = ys.copy()
  let result = Array::new()
  for v in arr {
    let mut found_idx : Int? = None
    let mut i = 0
    while i < remaining.length() {
      if remaining[i] == v {
        found_idx = Some(i)
        break
      }
      i = i + 1
    }
    match found_idx {
      Some(idx) => {
        // 消耗 ys 中的一个匹配
        ignore(remaining.remove(idx))
      }
      None => result.push(v)
    }
  }
  result
}

/// union：并集。流自身全部保留，ys 中未在结果中出现过的元素按序追加。
/// 语义同 Haskell `union xs ys`（保持 xs 顺序，ys 去重后补充）。
pub fn[T : Eq] Itor::union(self : Itor[T], ys : Array[T]) -> Array[T] {
  let result = self.to_array()
  for y in ys {
    let mut seen = false
    for r in result {
      if r == y {
        seen = true
        break
      }
    }
    if !seen {
      result.push(y)
    }
  }
  result
}

/// intersect：交集。流中出现在 ys 里的元素按原顺序保留。
/// 语义同 Haskell `intersect xs ys`。消费式，返回数组。
pub fn[T : Eq] Itor::intersect(self : Itor[T], ys : Array[T]) -> Array[T] {
  let result = Array::new()
  while true {
    match self.next() {
      Some(v) => {
        let mut found = false
        for y in ys {
          if y == v {
            found = true
            break
          }
        }
        if found {
          result.push(v)
        }
      }
      None => break
    }
  }
  result
}

/// insert：把 x 插入已排序流中的正确位置（保持升序）。
/// 语义同 Haskell `insert x xs`（T : Compare）。惰性返回新迭代器。
pub fn[T : Compare] Itor::insert(self : Itor[T], x : T) -> Itor[T] {
  let src = self
  let inserted = Ref::Ref(false)
  let init : T? = None
  let pending = Ref::Ref(init)
  Itor::new(fn() {
    Iter::new(fn() -> T? {
      // 1. 待发暂存值（x 插入后，被 x 挤占的 v 先发）
      match pending.val {
        Some(v) => {
          pending.val = None
          return Some(v)
        }
        None => ()
      }
      if inserted.val {
        return src.next()
      }
      match src.next() {
        Some(v) => {
          if x.compare(v) <= 0 {
            // x 应排在 v 之前：插入 x，暂存 v
            inserted.val = true
            pending.val = Some(v)
            Some(x)
          } else {
            Some(v)
          }
        }
        None => {
          // 流耗尽，x 追加在末尾
          inserted.val = true
          Some(x)
        }
      }
    })
  })
}

/// insert_by：按自定义比较函数把 x 插入已排序流中的正确位置。
/// 语义同 Haskell `insertBy cmp x xs`。惰性返回新迭代器。
pub fn[T] Itor::insert_by(self : Itor[T], cmp : (T, T) -> Int, x : T) -> Itor[T] {
  let src = self
  let inserted = Ref::Ref(false)
  let init : T? = None
  let pending = Ref::Ref(init)
  Itor::new(fn() {
    Iter::new(fn() -> T? {
      match pending.val {
        Some(v) => {
          pending.val = None
          return Some(v)
        }
        None => ()
      }
      if inserted.val {
        return src.next()
      }
      match src.next() {
        Some(v) => {
          if cmp(x, v) <= 0 {
            inserted.val = true
            pending.val = Some(v)
            Some(x)
          } else {
            Some(v)
          }
        }
        None => {
          inserted.val = true
          Some(x)
        }
      }
    })
  })
}

// ----------------------------------------------------------------------------
// 分组（group_adjacent_by，自定义谓词相邻分组）
// ----------------------------------------------------------------------------

/// group_adjacent_by：把相邻且满足 f(a, b) 的元素分成组。
/// 语义同 Haskell `groupBy f xs`。消费式，返回组数组。
pub fn[T] Itor::group_adjacent_by(self : Itor[T], f : (T, T) -> Bool) -> Array[Array[T]] {
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
            if f(p, v) {
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
// 结构操作（transpose / subsequences / permutations / chunks_of / fold_map）
// ----------------------------------------------------------------------------

/// transpose：数组流按列转置。结果第 i 行 = 各输入行第 i 列（按最长行对齐）。
/// 语义同 Haskell `transpose`。消费式，返回转置后的行数组。
pub fn[T] Itor::transpose(self : Itor[Array[T]]) -> Array[Array[T]] {
  let rows = self.to_array()
  let mut max_len = 0
  for row in rows {
    if row.length() > max_len {
      max_len = row.length()
    }
  }
  let result = Array::new()
  let mut i = 0
  while i < max_len {
    let col = Array::new()
    for row in rows {
      if i < row.length() {
        col.push(row[i])
      }
    }
    result.push(col)
    i = i + 1
  }
  result
}

/// subsequences：所有子序列（保持原序，共 2^n 个，含空与全量）。
/// 语义同 Haskell `subsequences`。消费式，返回子序列数组。
pub fn[T] Itor::subsequences(self : Itor[T]) -> Array[Array[T]] {
  let arr = self.to_array()
  let n = arr.length()
  let result = Array::new()
  let mut mask = 0
  while mask < (1 << n) {
    let sub = Array::new()
    let mut i = 0
    while i < n {
      if (mask & (1 << i)) != 0 {
        sub.push(arr[i])
      }
      i = i + 1
    }
    result.push(sub)
    mask = mask + 1
  }
  result
}

/// permutations：所有排列（共 n! 个）。
/// 语义同 Haskell `permutations`。消费式，返回排列数组。
pub fn[T] Itor::permutations(self : Itor[T]) -> Array[Array[T]] {
  let arr = self.to_array()
  let result = Array::new()
  let n = arr.length()
  // 递归回溯生成全排列
  fn gen(idx : Int) -> Unit {
    if idx == n - 1 {
      result.push(arr.copy())
      return
    }
    let mut i = idx
    while i < n {
      // 交换 arr[idx] 与 arr[i]
      let tmp = arr[idx]
      arr[idx] = arr[i]
      arr[i] = tmp
      gen(idx + 1)
      // 换回
      let tmp2 = arr[idx]
      arr[idx] = arr[i]
      arr[i] = tmp2
      i = i + 1
    }
  }
  if n == 0 {
    return result
  }
  gen(0)
  result
}

/// chunks_of：按每 n 个一组分块（最后一块可能不足 n）。
/// 语义同 Haskell `chunksOf n`（Data.List.Split）。惰性返回块迭代器。
pub fn[T] Itor::chunks_of(self : Itor[T], n : Int) -> Itor[Array[T]] {
  let src = self
  Itor::new(fn() {
    Iter::new(fn() -> Array[T]? {
      if n <= 0 {
        return None
      }
      let chunk = Array::new()
      let mut i = 0
      while i < n {
        match src.next() {
          Some(v) => {
            chunk.push(v)
            i = i + 1
          }
          None => break
        }
      }
      if chunk.is_empty() {
        None
      } else {
        Some(chunk)
      }
    })
  })
}

/// fold_map：映射后折叠。语义同 Haskell `foldMap`（以 combine 为 Monoid 结合律）。
/// 消费式，返回最终累积值。
pub fn[T, R] Itor::fold_map(
  self : Itor[T],
  seed : R,
  mapper : (T) -> R,
  combine : (R, R) -> R,
) -> R {
  let mut acc = seed
  while true {
    match self.next() {
      Some(v) => acc = combine(acc, mapper(v))
      None => break
    }
  }
  acc
}

// ----------------------------------------------------------------------------
// 多元 zip 家族（zip3 / zip_with3 / unzip / unzip3）
// ----------------------------------------------------------------------------

/// zip3：三路 zip，任一方耗尽即结束。
/// 语义同 Haskell `zip3 xs ys zs`。
pub fn[T, U, V] Itor::zip3(
  self : Itor[T],
  b : Itor[U],
  c : Itor[V],
) -> Itor[(T, U, V)] {
  let src_a = self
  let src_b = b
  let src_c = c
  Itor::new(fn() {
    Iter::new(fn() -> (T, U, V)? {
      match (src_a.next(), src_b.next(), src_c.next()) {
        (Some(x), Some(y), Some(z)) => Some((x, y, z))
        _ => None
      }
    })
  })
}

/// zip_with3：三路合并，任一方耗尽即结束。
/// 语义同 Haskell `zipWith3 f xs ys zs`。
pub fn[T, U, V, R] Itor::zip_with3(
  self : Itor[T],
  b : Itor[U],
  c : Itor[V],
  f : (T, U, V) -> R,
) -> Itor[R] {
  let src_a = self
  let src_b = b
  let src_c = c
  Itor::new(fn() {
    Iter::new(fn() -> R? {
      match (src_a.next(), src_b.next(), src_c.next()) {
        (Some(x), Some(y), Some(z)) => Some(f(x, y, z))
        _ => None
      }
    })
  })
}

/// unzip：二元组流拆分为两个数组。
/// 语义同 Haskell `unzip`。消费式。
pub fn[T, U] Itor::unzip(self : Itor[(T, U)]) -> (Array[T], Array[U]) {
  let col_t = Array::new()
  let col_u = Array::new()
  while true {
    match self.next() {
      Some((a, b)) => {
        col_t.push(a)
        col_u.push(b)
      }
      None => break
    }
  }
  (col_t, col_u)
}

/// unzip3：三元组流拆分为三个数组。
/// 语义同 Haskell `unzip3`。消费式。
pub fn[T, U, V] Itor::unzip3(
  self : Itor[(T, U, V)],
) -> (Array[T], Array[U], Array[V]) {
  let col_t = Array::new()
  let col_u = Array::new()
  let col_v = Array::new()
  while true {
    match self.next() {
      Some((a, b, c)) => {
        col_t.push(a)
        col_u.push(b)
        col_v.push(c)
      }
      None => break
    }
  }
  (col_t, col_u, col_v)
}

// ============================================================================
// Haskell Data.List 语义对照补全（第三批）
// 补齐以下缺失语义操作：
//   集合：union_by / intersect_by（自定义相等的并集 / 交集）
//   序列：append（(++) 语义）/ take_while_end / drop_while_end（Data.List 4.8+）
//   多元 zip：zip4~zip7 / zip_with4~zip7 / unzip4~unzip7
//   字符串：lines / words / unlines / unwords（Data.List 的 String 操作）
// ============================================================================

// ----------------------------------------------------------------------------
// 集合操作补全（按自定义相等的 union / intersect）
// ----------------------------------------------------------------------------

/// union_by：并集，按自定义相等谓词 eq 判定重复。
/// 语义同 Haskell `unionBy eq xs ys`（保持 xs 顺序，ys 去重后补充）。消费式。
pub fn[T] Itor::union_by(
  self : Itor[T],
  ys : Array[T],
  eq : (T, T) -> Bool,
) -> Array[T] {
  let result = self.to_array()
  for y in ys {
    let mut seen = false
    for r in result {
      if eq(r, y) {
        seen = true
        break
      }
    }
    if !seen {
      result.push(y)
    }
  }
  result
}

/// intersect_by：交集，按自定义相等谓词 eq 判定匹配。
/// 语义同 Haskell `intersectBy eq xs ys`。消费式，返回数组。
pub fn[T] Itor::intersect_by(
  self : Itor[T],
  ys : Array[T],
  eq : (T, T) -> Bool,
) -> Array[T] {
  let result = Array::new()
  while true {
    match self.next() {
      Some(v) => {
        let mut found = false
        for y in ys {
          if eq(y, v) {
            found = true
            break
          }
        }
        if found {
          result.push(v)
        }
      }
      None => break
    }
  }
  result
}

// ----------------------------------------------------------------------------
// 序列连接（(++) 语义）
// ----------------------------------------------------------------------------

/// append：把两个迭代器首尾相接（先耗尽 self，再产出 other）。
/// 语义同 Haskell `(++)`。惰性返回新迭代器。
pub fn[T] Itor::append(self : Itor[T], other : Itor[T]) -> Itor[T] {
  let src_a = self
  let src_b = other
  let stage = Ref::Ref(0)
  Itor::new(fn() {
    Iter::new(fn() -> T? {
      if stage.val == 0 {
        match src_a.next() {
          Some(v) => return Some(v)
          None => stage.val = 1
        }
      }
      src_b.next()
    })
  })
}

// ----------------------------------------------------------------------------
// 尾部条件操作（Data.List 4.8+ 的 takeWhileEnd / dropWhileEnd）
// ----------------------------------------------------------------------------

/// take_while_end：返回从尾部起连续满足 pred 的最长后缀。
/// 语义同 Haskell `takeWhileEnd p xs`：
/// takeWhileEnd even [1,2,3,4,6] = [4,6]。惰性返回新迭代器。
pub fn[T] Itor::take_while_end(self : Itor[T], pred : (T) -> Bool) -> Itor[T] {
  let src = self
  Itor::new(fn() {
    let buf = Ref::Ref(Array::new())
    let idx = Ref::Ref(0)
    let loaded = Ref::Ref(false)
    Iter::new(fn() -> T? {
      if !loaded.val {
        let arr = Array::new()
        while true {
          match src.next() {
            Some(v) => arr.push(v)
            None => break
          }
        }
        // 从尾部向前找最长连续满足 pred 的后缀起点
        let mut start = arr.length()
        let mut i = arr.length() - 1
        while i >= 0 && pred(arr[i]) {
          start = i
          i = i - 1
        }
        let keep = Array::new()
        let mut j = start
        while j < arr.length() {
          keep.push(arr[j])
          j = j + 1
        }
        buf.val = keep
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

/// drop_while_end：删除从尾部起连续满足 pred 的最长后缀，保留前缀。
/// 语义同 Haskell `dropWhileEnd p xs`：
/// dropWhileEnd even [1,2,3,4,6] = [1,2,3]。惰性返回新迭代器。
pub fn[T] Itor::drop_while_end(self : Itor[T], pred : (T) -> Bool) -> Itor[T] {
  let src = self
  Itor::new(fn() {
    let buf = Ref::Ref(Array::new())
    let idx = Ref::Ref(0)
    let loaded = Ref::Ref(false)
    Iter::new(fn() -> T? {
      if !loaded.val {
        let arr = Array::new()
        while true {
          match src.next() {
            Some(v) => arr.push(v)
            None => break
          }
        }
        // 从尾部删掉连续满足 pred 的元素
        let mut n = arr.length()
        while n > 0 && pred(arr[n - 1]) {
          n = n - 1
        }
        let keep = Array::new()
        let mut j = 0
        while j < n {
          keep.push(arr[j])
          j = j + 1
        }
        buf.val = keep
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

// ----------------------------------------------------------------------------
// 多元 zip 家族扩展（zip4~zip7 / zip_with4~zip_with7 / unzip4~unzip7）
// 语义同 Haskell `zip4..zip7`、`zipWith4..zipWith7`、`unzip4..unzip7`：
// 任一方耗尽即结束。
// ----------------------------------------------------------------------------

/// zip4：四路 zip，任一方耗尽即结束。
pub fn[T, U, V, W] Itor::zip4(
  self : Itor[T],
  b : Itor[U],
  c : Itor[V],
  d : Itor[W],
) -> Itor[(T, U, V, W)] {
  let src_a = self
  let src_b = b
  let src_c = c
  let src_d = d
  Itor::new(fn() {
    Iter::new(fn() -> (T, U, V, W)? {
      match (src_a.next(), src_b.next(), src_c.next(), src_d.next()) {
        (Some(x), Some(y), Some(z), Some(w)) => Some((x, y, z, w))
        _ => None
      }
    })
  })
}

/// zip_with4：四路合并，任一方耗尽即结束。
pub fn[T, U, V, W, R] Itor::zip_with4(
  self : Itor[T],
  b : Itor[U],
  c : Itor[V],
  d : Itor[W],
  f : (T, U, V, W) -> R,
) -> Itor[R] {
  let src_a = self
  let src_b = b
  let src_c = c
  let src_d = d
  Itor::new(fn() {
    Iter::new(fn() -> R? {
      match (src_a.next(), src_b.next(), src_c.next(), src_d.next()) {
        (Some(x), Some(y), Some(z), Some(w)) => Some(f(x, y, z, w))
        _ => None
      }
    })
  })
}

/// unzip4：四元组流拆分为四个数组。消费式。
pub fn[T, U, V, W] Itor::unzip4(
  self : Itor[(T, U, V, W)],
) -> (Array[T], Array[U], Array[V], Array[W]) {
  let col_t = Array::new()
  let col_u = Array::new()
  let col_v = Array::new()
  let col_w = Array::new()
  while true {
    match self.next() {
      Some((a, b, c, d)) => {
        col_t.push(a)
        col_u.push(b)
        col_v.push(c)
        col_w.push(d)
      }
      None => break
    }
  }
  (col_t, col_u, col_v, col_w)
}

/// zip5：五路 zip，任一方耗尽即结束。
pub fn[T, U, V, W, X] Itor::zip5(
  self : Itor[T],
  b : Itor[U],
  c : Itor[V],
  d : Itor[W],
  e : Itor[X],
) -> Itor[(T, U, V, W, X)] {
  let src_a = self
  let src_b = b
  let src_c = c
  let src_d = d
  let src_e = e
  Itor::new(fn() {
    Iter::new(fn() -> (T, U, V, W, X)? {
      match (src_a.next(), src_b.next(), src_c.next(), src_d.next(), src_e.next()) {
        (Some(x), Some(y), Some(z), Some(w), Some(v)) => Some((x, y, z, w, v))
        _ => None
      }
    })
  })
}

/// zip_with5：五路合并，任一方耗尽即结束。
pub fn[T, U, V, W, X, R] Itor::zip_with5(
  self : Itor[T],
  b : Itor[U],
  c : Itor[V],
  d : Itor[W],
  e : Itor[X],
  f : (T, U, V, W, X) -> R,
) -> Itor[R] {
  let src_a = self
  let src_b = b
  let src_c = c
  let src_d = d
  let src_e = e
  Itor::new(fn() {
    Iter::new(fn() -> R? {
      match (src_a.next(), src_b.next(), src_c.next(), src_d.next(), src_e.next()) {
        (Some(x), Some(y), Some(z), Some(w), Some(v)) => Some(f(x, y, z, w, v))
        _ => None
      }
    })
  })
}

/// unzip5：五元组流拆分为五个数组。消费式。
pub fn[T, U, V, W, X] Itor::unzip5(
  self : Itor[(T, U, V, W, X)],
) -> (Array[T], Array[U], Array[V], Array[W], Array[X]) {
  let col_t = Array::new()
  let col_u = Array::new()
  let col_v = Array::new()
  let col_w = Array::new()
  let col_x = Array::new()
  while true {
    match self.next() {
      Some((a, b, c, d, e)) => {
        col_t.push(a)
        col_u.push(b)
        col_v.push(c)
        col_w.push(d)
        col_x.push(e)
      }
      None => break
    }
  }
  (col_t, col_u, col_v, col_w, col_x)
}

/// zip6：六路 zip，任一方耗尽即结束。
pub fn[T, U, V, W, X, Y] Itor::zip6(
  self : Itor[T],
  b : Itor[U],
  c : Itor[V],
  d : Itor[W],
  e : Itor[X],
  f : Itor[Y],
) -> Itor[(T, U, V, W, X, Y)] {
  let src_a = self
  let src_b = b
  let src_c = c
  let src_d = d
  let src_e = e
  let src_f = f
  Itor::new(fn() {
    Iter::new(fn() -> (T, U, V, W, X, Y)? {
      match (src_a.next(), src_b.next(), src_c.next(), src_d.next(), src_e.next(), src_f.next()) {
        (Some(x), Some(y), Some(z), Some(w), Some(v), Some(u)) => Some((x, y, z, w, v, u))
        _ => None
      }
    })
  })
}

/// zip_with6：六路合并，任一方耗尽即结束。
pub fn[T, U, V, W, X, Y, R] Itor::zip_with6(
  self : Itor[T],
  b : Itor[U],
  c : Itor[V],
  d : Itor[W],
  e : Itor[X],
  f : Itor[Y],
  g : (T, U, V, W, X, Y) -> R,
) -> Itor[R] {
  let src_a = self
  let src_b = b
  let src_c = c
  let src_d = d
  let src_e = e
  let src_f = f
  Itor::new(fn() {
    Iter::new(fn() -> R? {
      match (src_a.next(), src_b.next(), src_c.next(), src_d.next(), src_e.next(), src_f.next()) {
        (Some(x), Some(y), Some(z), Some(w), Some(v), Some(u)) => Some(g(x, y, z, w, v, u))
        _ => None
      }
    })
  })
}

/// unzip6：六元组流拆分为六个数组。消费式。
pub fn[T, U, V, W, X, Y] Itor::unzip6(
  self : Itor[(T, U, V, W, X, Y)],
) -> (Array[T], Array[U], Array[V], Array[W], Array[X], Array[Y]) {
  let col_t = Array::new()
  let col_u = Array::new()
  let col_v = Array::new()
  let col_w = Array::new()
  let col_x = Array::new()
  let col_y = Array::new()
  while true {
    match self.next() {
      Some((a, b, c, d, e, f)) => {
        col_t.push(a)
        col_u.push(b)
        col_v.push(c)
        col_w.push(d)
        col_x.push(e)
        col_y.push(f)
      }
      None => break
    }
  }
  (col_t, col_u, col_v, col_w, col_x, col_y)
}

/// zip7：七路 zip，任一方耗尽即结束。
pub fn[T, U, V, W, X, Y, Z] Itor::zip7(
  self : Itor[T],
  b : Itor[U],
  c : Itor[V],
  d : Itor[W],
  e : Itor[X],
  f : Itor[Y],
  g : Itor[Z],
) -> Itor[(T, U, V, W, X, Y, Z)] {
  let src_a = self
  let src_b = b
  let src_c = c
  let src_d = d
  let src_e = e
  let src_f = f
  let src_g = g
  Itor::new(fn() {
    Iter::new(fn() -> (T, U, V, W, X, Y, Z)? {
      match (src_a.next(), src_b.next(), src_c.next(), src_d.next(), src_e.next(), src_f.next(), src_g.next()) {
        (Some(x), Some(y), Some(z), Some(w), Some(v), Some(u), Some(t)) => Some((x, y, z, w, v, u, t))
        _ => None
      }
    })
  })
}

/// zip_with7：七路合并，任一方耗尽即结束。
pub fn[T, U, V, W, X, Y, Z, R] Itor::zip_with7(
  self : Itor[T],
  b : Itor[U],
  c : Itor[V],
  d : Itor[W],
  e : Itor[X],
  f : Itor[Y],
  g : Itor[Z],
  h : (T, U, V, W, X, Y, Z) -> R,
) -> Itor[R] {
  let src_a = self
  let src_b = b
  let src_c = c
  let src_d = d
  let src_e = e
  let src_f = f
  let src_g = g
  Itor::new(fn() {
    Iter::new(fn() -> R? {
      match (src_a.next(), src_b.next(), src_c.next(), src_d.next(), src_e.next(), src_f.next(), src_g.next()) {
        (Some(x), Some(y), Some(z), Some(w), Some(v), Some(u), Some(t)) => Some(h(x, y, z, w, v, u, t))
        _ => None
      }
    })
  })
}

/// unzip7：七元组流拆分为七个数组。消费式。
pub fn[T, U, V, W, X, Y, Z] Itor::unzip7(
  self : Itor[(T, U, V, W, X, Y, Z)],
) -> (Array[T], Array[U], Array[V], Array[W], Array[X], Array[Y], Array[Z]) {
  let col_t = Array::new()
  let col_u = Array::new()
  let col_v = Array::new()
  let col_w = Array::new()
  let col_x = Array::new()
  let col_y = Array::new()
  let col_z = Array::new()
  while true {
    match self.next() {
      Some((a, b, c, d, e, f, g)) => {
        col_t.push(a)
        col_u.push(b)
        col_v.push(c)
        col_w.push(d)
        col_x.push(e)
        col_y.push(f)
        col_z.push(g)
      }
      None => break
    }
  }
  (col_t, col_u, col_v, col_w, col_x, col_y, col_z)
}

// ----------------------------------------------------------------------------
// 字符串语义操作（Data.List 的 lines / words / unlines / unwords）
// ----------------------------------------------------------------------------

/// lines：按换行符 \n 把字符串切分为行迭代器。
/// 语义同 Haskell `lines`：
/// lines "a\nb\n" = ["a","b"]；lines "\n" = [""]；lines "" = []。
/// 末尾换行符不产生多余空行。
pub fn Itor::lines(s : String) -> Itor[String] {
  let arr = Array::new()
  for sv in s.split("\n") {
    arr.push(sv.to_owned())
  }
  // 原串以 \n 结尾（或为空）时，split 会产生末尾空段，按 Haskell 语义丢弃
  if !arr.is_empty() && arr[arr.length() - 1] == "" {
    ignore(arr.pop())
  }
  Itor::from_array(arr)
}

/// words：按空白（空格 / 制表符 / 换行 / 回车）把字符串切分为词迭代器，
/// 连续空白合并、首尾空白忽略。
/// 语义同 Haskell `words`：
/// words " a  b\nc " = ["a","b","c"]；words "" = []。
pub fn Itor::words(s : String) -> Itor[String] {
  let arr = Array::new()
  let cur : Array[Char] = Array::new()
  for c in s.iter() {
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      if !cur.is_empty() {
        arr.push(String::from_iter(cur.iter()))
        cur.clear()
      }
    } else {
      cur.push(c)
    }
  }
  if !cur.is_empty() {
    arr.push(String::from_iter(cur.iter()))
  }
  Itor::from_array(arr)
}

/// unlines：行迭代器用 \n 连接，末尾补一个 \n；空迭代器返回空串。
/// 语义同 Haskell `unlines`：unlines ["a","b"] = "a\nb\n"。
pub fn Itor::unlines(self : Itor[String]) -> String {
  let arr = self.to_array()
  if arr.is_empty() {
    return ""
  }
  arr.iter().join("\n") + "\n"
}

/// unwords：词迭代器用空格连接（末尾无空格）；空迭代器返回空串。
/// 语义同 Haskell `unwords`：unwords ["a","b"] = "a b"。
pub fn Itor::unwords(self : Itor[String]) -> String {
  self.to_array().iter().join(" ")
}
