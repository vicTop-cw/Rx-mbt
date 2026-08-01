// ============================================================================
// 聚合类操作符：count / count_events / reduce / collect / to_list / sum /
// average / minimum / maximum / min / max / mean / median / variance / std /
// quantile / n_unique / arg_min / arg_max / cum_prod / cum_mean / rolling_* /
// to_map / to_set
// ============================================================================

/// count：统计值个数，流结束时发出
pub fn[T, E] Observable::count(self : Observable[T, E]) -> Observable[Int, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[Int, E]) -> Subscription = fn(downstream : Observer[Int, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let counter = Ref::Ref(0)
    source_fn({
      next: fn(_ : T) { counter.val = counter.val + 1 },
      error: error,
      complete: fn() {
        next(counter.val)
        complete()
      },
    })
  }
  Observable::new(subscribe_fn)
}

/// count_events：每收到 n 个事件发射一次计数（批次统计）
pub fn[T, E] count_events(source : Observable[T, E], n : Int) -> Observable[Int, E] {
  let source_fn = source.subscribe_fn
  let subscribe_fn : (Observer[Int, E]) -> Subscription = fn(downstream : Observer[Int, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let counter = Ref::Ref(0)
    // n <= 0 无意义（每 n 个事件发一次），防御：退化为每次发 1
    let chunk = if n < 1 { 1 } else { n }
    source_fn({
      next: fn(_ : T) {
        counter.val = counter.val + 1
        if counter.val >= chunk {
          let cnt = counter.val
          counter.val = 0
          next(cnt)
        }
      },
      error: error,
      complete: complete,
    })
  }
  Observable::new(subscribe_fn)
}

/// reduce：从 seed 累积，流结束时发出最终结果
pub fn[T, E, Acc] Observable::reduce(
  self : Observable[T, E],
  seed : Acc,
  f : (Acc, T) -> Acc,
) -> Observable[Acc, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[Acc, E]) -> Subscription = fn(downstream : Observer[Acc, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let acc = Ref::Ref(seed)
    source_fn({
      next: fn(v : T) { acc.val = f(acc.val, v) },
      error: error,
      complete: fn() {
        next(acc.val)
        complete()
      },
    })
  }
  Observable::new(subscribe_fn)
}

/// reduce_no_seed：无 seed 版本，首元素直接作为初始值（对应 Rx-Rust extended::reduce）
pub fn[T, E] Observable::reduce_no_seed(
  self : Observable[T, E],
  f : (T, T) -> T,
) -> Observable[T, E] {
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
          Some(cur) => { acc.val = Some(f(cur, v)) }
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
      },
    })
  }
  Observable::new(subscribe_fn)
}

/// collect：把流中所有值收集成数组，流结束时发出
pub fn[T, E] Observable::collect(self : Observable[T, E]) -> Observable[Array[T], E] {
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
        next(buf.val)
        complete()
      },
    })
  }
  Observable::new(subscribe_fn)
}

/// to_list：collect 的别名
pub fn[T, E] Observable::to_list(self : Observable[T, E]) -> Observable[Array[T], E] {
  self.collect()
}

/// sum：累加所有值，流结束时发出（需要 T : Add + Default）
pub fn[T : Add + Default, E] Observable::sum(self : Observable[T, E]) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let init : T = Default::default()
    let acc = Ref::Ref(init)
    source_fn({
      next: fn(v : T) { acc.val = acc.val + v },
      error: error,
      complete: fn() {
        next(acc.val)
        complete()
      },
    })
  }
  Observable::new(subscribe_fn)
}

/// sum_direct：从给定 seed 开始累加
pub fn[T : Add, E] Observable::sum_direct(
  self : Observable[T, E],
  seed : T,
) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let acc = Ref::Ref(seed)
    source_fn({
      next: fn(v : T) { acc.val = acc.val + v },
      error: error,
      complete: fn() {
        next(acc.val)
        complete()
      },
    })
  }
  Observable::new(subscribe_fn)
}

/// sum_by：按 key_mapper 提取数值后累加，返回 Double（对应 Rx-Rust extended::sum）
pub fn[T, E] Observable::sum_by(
  self : Observable[T, E],
  key_mapper : (T) -> Double,
) -> Observable[Double, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[Double, E]) -> Subscription = fn(downstream : Observer[Double, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let acc = Ref::Ref(0.0)
    source_fn({
      next: fn(v : T) { acc.val = acc.val + key_mapper(v) },
      error: error,
      complete: fn() {
        next(acc.val)
        complete()
      },
    })
  }
  Observable::new(subscribe_fn)
}

/// average：求 Double 流的算术平均值
pub fn[E] Observable::average(self : Observable[Double, E]) -> Observable[Double, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[Double, E]) -> Subscription = fn(downstream : Observer[Double, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let sum = Ref::Ref(0.0)
    let cnt = Ref::Ref(0)
    source_fn({
      next: fn(v : Double) {
        sum.val = sum.val + v
        cnt.val = cnt.val + 1
      },
      error: error,
      complete: fn() {
        if cnt.val > 0 {
          next(sum.val / Double::from_int(cnt.val))
        }
        complete()
      },
    })
  }
  Observable::new(subscribe_fn)
}

/// average_direct：average 的别名
pub fn[E] Observable::average_direct(self : Observable[Double, E]) -> Observable[Double, E] {
  self.average()
}

/// average_by：按 key_mapper 提取数值后求均值，返回 Double（对应 Rx-Rust extended::average）
pub fn[T, E] Observable::average_by(
  self : Observable[T, E],
  key_mapper : (T) -> Double,
) -> Observable[Double, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[Double, E]) -> Subscription = fn(downstream : Observer[Double, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let sum = Ref::Ref(0.0)
    let cnt = Ref::Ref(0)
    source_fn({
      next: fn(v : T) {
        sum.val = sum.val + key_mapper(v)
        cnt.val = cnt.val + 1
      },
      error: error,
      complete: fn() {
        if cnt.val > 0 {
          next(sum.val / Double::from_int(cnt.val))
        }
        complete()
      },
    })
  }
  Observable::new(subscribe_fn)
}

/// minimum：求最小值（流结束时发出）
pub fn[T : Compare, E] Observable::minimum(self : Observable[T, E]) -> Observable[T, E] {
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
          Some(cur) => { if v.compare(cur) < 0 { best.val = Some(v) } }
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
      },
    })
  }
  Observable::new(subscribe_fn)
}

/// minimum_by：按 key_mapper 提取比较值后求最小值（对应 Rx-Rust extended::minimum）
pub fn[T, E] Observable::minimum_by(
  self : Observable[T, E],
  key_mapper : (T) -> Double,
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
          Some(cur) => { if key_mapper(v) < key_mapper(cur) { best.val = Some(v) } }
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
      },
    })
  }
  Observable::new(subscribe_fn)
}
pub fn[T : Compare, E] Observable::maximum(self : Observable[T, E]) -> Observable[T, E] {
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
          Some(cur) => { if v.compare(cur) > 0 { best.val = Some(v) } }
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
      },
    })
  }
  Observable::new(subscribe_fn)
}

/// minimum_direct：minimum 的别名
pub fn[T : Compare, E] Observable::minimum_direct(self : Observable[T, E]) -> Observable[T, E] {
  self.minimum()
}

/// maximum_by：按 key_mapper 提取比较值后求最大值（对应 Rx-Rust extended::maximum）
pub fn[T, E] Observable::maximum_by(
  self : Observable[T, E],
  key_mapper : (T) -> Double,
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
          Some(cur) => { if key_mapper(v) > key_mapper(cur) { best.val = Some(v) } }
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
      },
    })
  }
  Observable::new(subscribe_fn)
}

/// maximum_direct：maximum 的别名
pub fn[T : Compare, E] Observable::maximum_direct(self : Observable[T, E]) -> Observable[T, E] {
  self.maximum()
}

/// min：求最小值（自由函数版）
pub fn[T : Compare, E] min(source : Observable[T, E]) -> Observable[T, E] {
  source.minimum()
}

/// max：求最大值（自由函数版）
pub fn[T : Compare, E] max(source : Observable[T, E]) -> Observable[T, E] {
  source.maximum()
}

/// mean：求 Double 流的算术平均值（自由函数版）
pub fn[E] mean(source : Observable[Double, E]) -> Observable[Double, E] {
  source.average()
}

/// median：求中位数（流结束时发出）
pub fn[E] median(source : Observable[Double, E]) -> Observable[Double, E] {
  let source_fn = source.subscribe_fn
  let subscribe_fn : (Observer[Double, E]) -> Subscription = fn(downstream : Observer[Double, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let buf = Ref::Ref(Array::new())
    source_fn({
      next: fn(v : Double) { buf.val.push(v) },
      error: error,
      complete: fn() {
        let arr = buf.val
        arr.sort()
        let n = arr.length()
        if n > 0 {
          let mid = n / 2
          if n % 2 == 1 {
            next(arr[mid])
          } else {
            next((arr[mid - 1] + arr[mid]) / 2.0)
          }
        }
        complete()
      },
    })
  }
  Observable::new(subscribe_fn)
}

/// variance：求总体方差（流结束时发出）
pub fn[E] variance(source : Observable[Double, E]) -> Observable[Double, E] {
  let source_fn = source.subscribe_fn
  let subscribe_fn : (Observer[Double, E]) -> Subscription = fn(downstream : Observer[Double, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let buf = Ref::Ref(Array::new())
    source_fn({
      next: fn(v : Double) { buf.val.push(v) },
      error: error,
      complete: fn() {
        let arr = buf.val
        let n = arr.length()
        if n > 0 {
          let mut sum = 0.0
          for x in arr {
            sum = sum + x
          }
          let m = sum / Double::from_int(n)
          let mut acc = 0.0
          for x in arr {
            let d = x - m
            acc = acc + d * d
          }
          next(acc / Double::from_int(n))
        }
        complete()
      },
    })
  }
  Observable::new(subscribe_fn)
}

/// std：求标准差（总体方差的平方根）
pub fn[E] std(source : Observable[Double, E]) -> Observable[Double, E] {
  let source_fn = source.subscribe_fn
  let subscribe_fn : (Observer[Double, E]) -> Subscription = fn(downstream : Observer[Double, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let buf = Ref::Ref(Array::new())
    source_fn({
      next: fn(v : Double) { buf.val.push(v) },
      error: error,
      complete: fn() {
        let arr = buf.val
        let n = arr.length()
        if n > 0 {
          let mut sum = 0.0
          for x in arr {
            sum = sum + x
          }
          let m = sum / Double::from_int(n)
          let mut acc = 0.0
          for x in arr {
            let d = x - m
            acc = acc + d * d
          }
          next((acc / Double::from_int(n)).sqrt())
        }
        complete()
      },
    })
  }
  Observable::new(subscribe_fn)
}

/// quantile：求分位数（q 为 0..1），流结束时发出
pub fn[E] quantile(source : Observable[Double, E], q : Double) -> Observable[Double, E] {
  let source_fn = source.subscribe_fn
  let subscribe_fn : (Observer[Double, E]) -> Subscription = fn(downstream : Observer[Double, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let buf = Ref::Ref(Array::new())
    source_fn({
      next: fn(v : Double) { buf.val.push(v) },
      error: error,
      complete: fn() {
        let arr = buf.val
        let n = arr.length()
        if n > 0 {
          arr.sort()
          // 防御：q 夹取到 [0, 1]，避免 (n-1)*q 越界访问
          let qq = if q < 0.0 { 0.0 } else if q > 1.0 { 1.0 } else { q }
          let idx = (Double::from_int(n - 1) * qq).to_int()
          next(arr[idx])
        }
        complete()
      },
    })
  }
  Observable::new(subscribe_fn)
}

/// n_unique：统计去重后值的个数
pub fn[T : Hash + Eq, E] n_unique(source : Observable[T, E]) -> Observable[Int, E] {
  let source_fn = source.subscribe_fn
  let subscribe_fn : (Observer[Int, E]) -> Subscription = fn(downstream : Observer[Int, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let set = Ref::Ref(@hashset.from_array([]))
    source_fn({
      next: fn(v : T) { set.val.add(v) },
      error: error,
      complete: fn() {
        next(set.val.length())
        complete()
      },
    })
  }
  Observable::new(subscribe_fn)
}

/// arg_min：返回最小值的索引（找不到发 -1）
pub fn[T : Compare, E] arg_min(source : Observable[T, E]) -> Observable[Int, E] {
  let source_fn = source.subscribe_fn
  let subscribe_fn : (Observer[Int, E]) -> Subscription = fn(downstream : Observer[Int, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let init : T? = None
    let best = Ref::Ref(init)
    let best_idx = Ref::Ref(-1)
    let idx = Ref::Ref(0)
    source_fn({
      next: fn(v : T) {
        match best.val {
          Some(cur) => { if v.compare(cur) < 0 { best.val = Some(v); best_idx.val = idx.val } }
          None => { best.val = Some(v); best_idx.val = idx.val }
        }
        idx.val = idx.val + 1
      },
      error: error,
      complete: fn() {
        next(best_idx.val)
        complete()
      },
    })
  }
  Observable::new(subscribe_fn)
}

/// arg_max：返回最大值的索引（找不到发 -1）
pub fn[T : Compare, E] arg_max(source : Observable[T, E]) -> Observable[Int, E] {
  let source_fn = source.subscribe_fn
  let subscribe_fn : (Observer[Int, E]) -> Subscription = fn(downstream : Observer[Int, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let init : T? = None
    let best = Ref::Ref(init)
    let best_idx = Ref::Ref(-1)
    let idx = Ref::Ref(0)
    source_fn({
      next: fn(v : T) {
        match best.val {
          Some(cur) => { if v.compare(cur) > 0 { best.val = Some(v); best_idx.val = idx.val } }
          None => { best.val = Some(v); best_idx.val = idx.val }
        }
        idx.val = idx.val + 1
      },
      error: error,
      complete: fn() {
        next(best_idx.val)
        complete()
      },
    })
  }
  Observable::new(subscribe_fn)
}

/// cum_prod：累积乘积（每个值发出到当前的累积结果）
pub fn[T : Mul, E] Observable::cum_prod(self : Observable[T, E]) -> Observable[T, E] {
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
          Some(cur) => {
            let nxt = cur * v
            acc.val = Some(nxt)
            next(nxt)
          }
          None => {
            acc.val = Some(v)
            next(v)
          }
        }
      },
      error: error,
      complete: complete,
    })
  }
  Observable::new(subscribe_fn)
}

/// cum_mean：累积平均值（每个值发出到当前的均值）
pub fn[E] Observable::cum_mean(self : Observable[Double, E]) -> Observable[Double, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[Double, E]) -> Subscription = fn(downstream : Observer[Double, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let sum = Ref::Ref(0.0)
    let cnt = Ref::Ref(0)
    source_fn({
      next: fn(v : Double) {
        sum.val = sum.val + v
        cnt.val = cnt.val + 1
        next(sum.val / Double::from_int(cnt.val))
      },
      error: error,
      complete: complete,
    })
  }
  Observable::new(subscribe_fn)
}

/// cum_sum：累积求和（每个值发出到当前的累计和）
pub fn[T : Add + Default, E] Observable::cum_sum(self : Observable[T, E]) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let init : T = Default::default()
    let acc = Ref::Ref(init)
    source_fn({
      next: fn(v : T) {
        acc.val = acc.val + v
        next(acc.val)
      },
      error: error,
      complete: complete,
    })
  }
  Observable::new(subscribe_fn)
}

/// cum_min：累积最小值（每个值发出当前最小值）
pub fn[T : Compare, E] Observable::cum_min(self : Observable[T, E]) -> Observable[T, E] {
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
          Some(cur) => { if v.compare(cur) < 0 { best.val = Some(v) } }
          None => best.val = Some(v)
        }
        match best.val {
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

/// cum_max：累积最大值（每个值发出当前最大值）
pub fn[T : Compare, E] Observable::cum_max(self : Observable[T, E]) -> Observable[T, E] {
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
          Some(cur) => { if v.compare(cur) > 0 { best.val = Some(v) } }
          None => best.val = Some(v)
        }
        match best.val {
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

/// rolling_sum：滑动窗口求和（窗口大小 n，每个值发出当前窗口和）
pub fn[E] Observable::rolling_sum(
  self : Observable[Double, E],
  n : Int,
) -> Observable[Double, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[Double, E]) -> Subscription = fn(downstream : Observer[Double, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let buf = Ref::Ref(Array::new())
    let sum = Ref::Ref(0.0)
    source_fn({
      next: fn(v : Double) {
        buf.val.push(v)
        sum.val = sum.val + v
        // n <= 0 时窗口退化为整个流（不做裁剪，避免 remove(0) 空指针）
        if n > 0 && buf.val.length() > n {
          let old = buf.val.remove(0)
          sum.val = sum.val - old
        }
        next(sum.val)
      },
      error: error,
      complete: complete,
    })
  }
  Observable::new(subscribe_fn)
}

/// rolling_mean：滑动窗口平均值
pub fn[E] Observable::rolling_mean(
  self : Observable[Double, E],
  n : Int,
) -> Observable[Double, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[Double, E]) -> Subscription = fn(downstream : Observer[Double, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let buf = Ref::Ref(Array::new())
    let sum = Ref::Ref(0.0)
    source_fn({
      next: fn(v : Double) {
        buf.val.push(v)
        sum.val = sum.val + v
        // n <= 0 时窗口退化为整个流（不做裁剪）
        if n > 0 && buf.val.length() > n {
          let old = buf.val.remove(0)
          sum.val = sum.val - old
        }
        next(sum.val / Double::from_int(buf.val.length()))
      },
      error: error,
      complete: complete,
    })
  }
  Observable::new(subscribe_fn)
}

/// rolling_min：滑动窗口最小值
pub fn[T : Compare, E] Observable::rolling_min(
  self : Observable[T, E],
  n : Int,
) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let buf = Ref::Ref(Array::new())
    source_fn({
      next: fn(v : T) {
        buf.val.push(v)
        // n <= 0 时窗口退化为整个流（不做裁剪）
        if n > 0 && buf.val.length() > n {
          let _ = buf.val.remove(0)
        }
        let init : T? = None
        let best = Ref::Ref(init)
        for x in buf.val {
          match best.val {
            Some(cur) => { if x.compare(cur) < 0 { best.val = Some(x) } }
            None => best.val = Some(x)
          }
        }
        match best.val {
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

/// rolling_max：滑动窗口最大值
pub fn[T : Compare, E] Observable::rolling_max(
  self : Observable[T, E],
  n : Int,
) -> Observable[T, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[T, E]) -> Subscription = fn(downstream : Observer[T, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let buf = Ref::Ref(Array::new())
    source_fn({
      next: fn(v : T) {
        buf.val.push(v)
        // n <= 0 时窗口退化为整个流（不做裁剪）
        if n > 0 && buf.val.length() > n {
          let _ = buf.val.remove(0)
        }
        let init : T? = None
        let best = Ref::Ref(init)
        for x in buf.val {
          match best.val {
            Some(cur) => { if x.compare(cur) > 0 { best.val = Some(x) } }
            None => best.val = Some(x)
          }
        }
        match best.val {
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

/// rolling_count：滑动窗口内元素个数
pub fn[T, E] Observable::rolling_count(
  self : Observable[T, E],
  n : Int,
) -> Observable[Int, E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[Int, E]) -> Subscription = fn(downstream : Observer[Int, E]) {
    let next = downstream.next
    let error = downstream.error
    let complete = downstream.complete
    let buf = Ref::Ref(Array::new())
    source_fn({
      next: fn(v : T) {
        buf.val.push(v)
        // n <= 0 时窗口退化为整个流（不做裁剪）
        if n > 0 && buf.val.length() > n {
          let _ = buf.val.remove(0)
        }
        next(buf.val.length())
      },
      error: error,
      complete: complete,
    })
  }
  Observable::new(subscribe_fn)
}

/// to_map：把流收集成 HashMap（key_fn 取键，val_fn 取值）
pub fn[T, E, K : Hash + Eq, V] Observable::to_map(
  self : Observable[T, E],
  key_fn : (T) -> K,
  val_fn : (T) -> V,
) -> Observable[@hashmap.HashMap[K, V], E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[@hashmap.HashMap[K, V], E]) -> Subscription =
    fn(downstream : Observer[@hashmap.HashMap[K, V], E]) {
      let next = downstream.next
      let error = downstream.error
      let complete = downstream.complete
      let map = Ref::Ref(@hashmap.from_array([]))
      source_fn({
        next: fn(v : T) { map.val.set(key_fn(v), val_fn(v)) },
        error: error,
        complete: fn() {
          next(map.val)
          complete()
        },
      })
    }
  Observable::new(subscribe_fn)
}

/// to_set：把流收集成 HashSet（去重）
pub fn[T : Hash + Eq, E] Observable::to_set(
  self : Observable[T, E],
) -> Observable[@hashset.HashSet[T], E] {
  let source_fn = self.subscribe_fn
  let subscribe_fn : (Observer[@hashset.HashSet[T], E]) -> Subscription =
    fn(downstream : Observer[@hashset.HashSet[T], E]) {
      let next = downstream.next
      let error = downstream.error
      let complete = downstream.complete
      let set = Ref::Ref(@hashset.from_array([]))
      source_fn({
        next: fn(v : T) { set.val.add(v) },
        error: error,
        complete: fn() {
          next(set.val)
          complete()
        },
      })
    }
  Observable::new(subscribe_fn)
}
