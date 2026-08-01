// 分类测试：聚合类（Aggregation）
// count / count_events / reduce / collect / to_list / sum / sum_direct /
// average / minimum / maximum / min / max / mean / median / variance / std /
// quantile / n_unique / arg_min / arg_max / cum_prod / cum_mean / rolling_* /
// to_map / to_set / sort / top_k / bottom_k

///|
test "aggregation: count 统计个数" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3, 4]).count()
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [4])
}

///|
test "aggregation: count_events 每 n 个发一次" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.count_events(@rx.Observable::from_iter([1, 2, 3, 4, 5]), 2)
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [2, 2])
}

///|
test "aggregation: reduce 累积出最终结果" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3]).reduce(
    0,
    fn(acc : Int, v : Int) { acc + v },
  )
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [6])
}

///|
test "aggregation: collect 收集成数组" {
  let values : Ref[Array[Array[Int]]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Array[Int], Unit] = @rx.Observable::from_iter([1, 2, 3]).collect()
  let _ = obs.subscribe_on_next(fn(v : Array[Int]) { values.val.push(v) })
  assert_eq(values.val, [[1, 2, 3]])
}

///|
test "aggregation: to_list 别名 collect" {
  let values : Ref[Array[Array[Int]]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Array[Int], Unit] = @rx.Observable::from_iter([1, 2]).to_list()
  let _ = obs.subscribe_on_next(fn(v : Array[Int]) { values.val.push(v) })
  assert_eq(values.val, [[1, 2]])
}

///|
test "aggregation: sum 累加" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3, 4]).sum()
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [10])
}

///|
test "aggregation: sum_direct 从 seed 累加" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2]).sum_direct(100)
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [103])
}

///|
test "aggregation: average 求均值" {
  let values : Ref[Array[Double]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Double, Unit] = @rx.Observable::from_iter([1.0, 2.0, 3.0]).average()
  let _ = obs.subscribe_on_next(fn(v : Double) { values.val.push(v) })
  assert_eq(values.val, [2.0])
}

///|
test "aggregation: minimum 求最小值" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([3, 1, 2]).minimum()
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1])
}

///|
test "aggregation: maximum 求最大值" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([3, 1, 2]).maximum()
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [3])
}

///|
test "aggregation: min 自由函数" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.min(@rx.Observable::from_iter([5, 2, 8]))
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [2])
}

///|
test "aggregation: max 自由函数" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.max(@rx.Observable::from_iter([5, 2, 8]))
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [8])
}

///|
test "aggregation: mean 求均值" {
  let values : Ref[Array[Double]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Double, Unit] = @rx.mean(@rx.Observable::from_iter([2.0, 4.0, 6.0]))
  let _ = obs.subscribe_on_next(fn(v : Double) { values.val.push(v) })
  assert_eq(values.val, [4.0])
}

///|
test "aggregation: median 求中位数（偶数取中间平均）" {
  let values : Ref[Array[Double]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Double, Unit] = @rx.median(@rx.Observable::from_iter([1.0, 2.0, 3.0, 4.0]))
  let _ = obs.subscribe_on_next(fn(v : Double) { values.val.push(v) })
  assert_eq(values.val, [2.5])
}

///|
test "aggregation: variance 求总体方差" {
  let values : Ref[Array[Double]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Double, Unit] = @rx.variance(@rx.Observable::from_iter([2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0]))
  let _ = obs.subscribe_on_next(fn(v : Double) { values.val.push(v) })
  assert_eq(values.val, [4.0])
}

///|
test "aggregation: std 求标准差" {
  let values : Ref[Array[Double]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Double, Unit] = @rx.std(@rx.Observable::from_iter([2.0, 2.0]))
  let _ = obs.subscribe_on_next(fn(v : Double) { values.val.push(v) })
  assert_eq(values.val, [0.0])
}

///|
test "aggregation: quantile 求分位数" {
  let values : Ref[Array[Double]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Double, Unit] = @rx.quantile(
    @rx.Observable::from_iter([1.0, 2.0, 3.0, 4.0]),
    1.0,
  )
  let _ = obs.subscribe_on_next(fn(v : Double) { values.val.push(v) })
  assert_eq(values.val, [4.0])
}

///|
test "aggregation: n_unique 去重计数" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.n_unique(@rx.Observable::from_iter([1, 2, 1, 3]))
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [3])
}

///|
test "aggregation: arg_min 返回最小值的索引" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.arg_min(@rx.Observable::from_iter([5, 2, 8]))
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1])
}

///|
test "aggregation: arg_max 返回最大值的索引" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.arg_max(@rx.Observable::from_iter([5, 2, 8]))
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [2])
}

///|
test "aggregation: cum_prod 累积乘积" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3, 4]).cum_prod()
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1, 2, 6, 24])
}

///|
test "aggregation: cum_mean 累积均值" {
  let values : Ref[Array[Double]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Double, Unit] = @rx.Observable::from_iter([1.0, 3.0]).cum_mean()
  let _ = obs.subscribe_on_next(fn(v : Double) { values.val.push(v) })
  assert_eq(values.val, [1.0, 2.0])
}

///|
test "aggregation: rolling_sum 滑动窗口求和" {
  let values : Ref[Array[Double]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Double, Unit] = @rx.Observable::from_iter([1.0, 2.0, 3.0, 4.0]).rolling_sum(2)
  let _ = obs.subscribe_on_next(fn(v : Double) { values.val.push(v) })
  assert_eq(values.val, [1.0, 3.0, 5.0, 7.0])
}

///|
test "aggregation: rolling_mean 滑动窗口均值" {
  let values : Ref[Array[Double]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Double, Unit] = @rx.Observable::from_iter([2.0, 4.0]).rolling_mean(2)
  let _ = obs.subscribe_on_next(fn(v : Double) { values.val.push(v) })
  assert_eq(values.val, [2.0, 3.0])
}

///|
test "aggregation: rolling_min 滑动窗口最小值" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([3, 1, 2]).rolling_min(2)
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [3, 1, 1])
}

///|
test "aggregation: rolling_max 滑动窗口最大值" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([3, 1, 2]).rolling_max(2)
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [3, 3, 2])
}

///|
test "aggregation: rolling_count 滑动窗口计数" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3]).rolling_count(2)
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1, 2, 2])
}

///|
test "aggregation: sort 收集排序" {
  let values : Ref[Array[Array[Int]]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Array[Int], Unit] = @rx.Observable::from_iter([3, 1, 2]).sort()
  let _ = obs.subscribe_on_next(fn(v : Array[Int]) { values.val.push(v) })
  assert_eq(values.val, [[1, 2, 3]])
}

///|
test "aggregation: top_k 取最大 k 个" {
  let values : Ref[Array[Array[Int]]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Array[Int], Unit] = @rx.Observable::from_iter([1, 5, 3, 4]).top_k(2)
  let _ = obs.subscribe_on_next(fn(v : Array[Int]) { values.val.push(v) })
  assert_eq(values.val, [[5, 4]])
}

///|
test "aggregation: bottom_k 取最小 k 个" {
  let values : Ref[Array[Array[Int]]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Array[Int], Unit] = @rx.Observable::from_iter([1, 5, 3, 4]).bottom_k(2)
  let _ = obs.subscribe_on_next(fn(v : Array[Int]) { values.val.push(v) })
  assert_eq(values.val, [[1, 3]])
}

///|
test "aggregation: to_map 收集成映射" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[@hashmap.HashMap[String, Int], Unit] = @rx.Observable::from_iter(
    [1, 2],
  ).to_map(
    fn(v : Int) -> String { "k\{v}" },
    fn(v : Int) { v * 10 },
  )
  let _ = obs.subscribe_on_next(fn(m : @hashmap.HashMap[String, Int]) {
    match m.get("k1") {
      Some(v) => values.val.push(v)
      None => ()
    }
  })
  assert_eq(values.val, [10])
}

///|
test "aggregation: to_set 收集去重" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[@hashset.HashSet[Int], Unit] = @rx.Observable::from_iter(
    [1, 2, 1],
  ).to_set()
  let _ = obs.subscribe_on_next(fn(s : @hashset.HashSet[Int]) {
    values.val.push(s.length())
  })
  assert_eq(values.val, [2])
}

///|
test "aggregation: sum_by 按 key_mapper 累加为 Double" {
  let values : Ref[Array[Double]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Double, Unit] = @rx.Observable::from_iter(
    [1, 2, 3],
  ).sum_by(fn(v : Int) -> Double { Double::from_int(v) * 1.5 })
  let _ = obs.subscribe_on_next(fn(v : Double) { values.val.push(v) })
  assert_eq(values.val, [9.0])
}

///|
test "aggregation: average_by 按 key_mapper 求均值" {
  let values : Ref[Array[Double]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Double, Unit] = @rx.Observable::from_iter(
    [1, 2, 3],
  ).average_by(fn(v : Int) -> Double { Double::from_int(v * 2) })
  let _ = obs.subscribe_on_next(fn(v : Double) { values.val.push(v) })
  assert_eq(values.val, [4.0])
}

///|
test "aggregation: minimum_by 按 key_mapper 求最小值" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter(
    [3, 1, 4],
  ).minimum_by(fn(v : Int) -> Double { Double::from_int(v) })
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1])
}

///|
test "aggregation: maximum_by 按 key_mapper 求最大值" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter(
    [3, 1, 4],
  ).maximum_by(fn(v : Int) -> Double { Double::from_int(v) })
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [4])
}

///|
test "aggregation: reduce_no_seed 首元素作初始值" {
  let values : Ref[Array[Int]] = Ref::Ref(Array::new())
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter(
    [1, 2, 3, 4],
  ).reduce_no_seed(fn(acc : Int, v : Int) { acc + v })
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [10])
}
