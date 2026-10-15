// 分类测试：Haskell 迭代器语义移植（haskell）
// 覆盖 ops_haskell.mbt：iterate / repeat_infinite / cycle / unfoldr /
// reverse / intersperse / intercalate / zip_with / zip3 / unzip / transpose /
// span / break_pred / split_at / partition / not_elem / delete_first /
// group_adjacent / group_adjacent_by / is_prefix_of / is_suffix_of /
// is_infix_of / foldr / scanr / product / fold_map / sort_by / sort_on /
// maximum_by_cmp / minimum_by_cmp / find_indices / elem_index / elem_indices /
// lookup / Itor::fold

///|
test "haskell: iterate 无限迭代配合 take 截断" {
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::iterate(
    fn(x : Int) { x * 2 },
    1,
  ).take(5)
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1, 2, 4, 8, 16])
}

///|
test "haskell: repeat_infinite 无限重复配合 take 截断" {
  let values : Ref[Array[String]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[String, Unit] = @rx.Observable::repeat_infinite("x").take(3)
  let _ = obs.subscribe_on_next(fn(v : String) { values.val.push(v) })
  assert_eq(values.val, ["x", "x", "x"])
}

///|
test "haskell: cycle 无限循环数组配合 take 截断" {
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::cycle([1, 2, 3]).take(7)
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1, 2, 3, 1, 2, 3, 1])
}

///|
test "haskell: unfoldr 展开（递减到 0 结束）" {
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::unfoldr(
    fn(s : Int) -> (Int, Int)? {
      if s <= 0 {
        None
      } else {
        Some((s, s - 1))
      }
    },
    4,
  )
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [4, 3, 2, 1])
}

///|
test "haskell: unfoldr 立即结束（空流）" {
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::unfoldr(
    fn(_s : Int) -> (Int, Int)? { None },
    0,
  )
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [])
}

///|
test "haskell: reverse 收集后反转" {
  let values : Ref[Array[Array[Int]]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Array[Int], Unit] = @rx.Observable::from_iter(
    [1, 2, 3, 4],
  ).reverse()
  let _ = obs.subscribe_on_next(fn(v : Array[Int]) { values.val.push(v) })
  assert_eq(values.val, [[4, 3, 2, 1]])
}

///|
test "haskell: intersperse 元素间插入分隔符" {
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter(
    [1, 2, 3],
  ).intersperse(0)
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1, 0, 2, 0, 3])
}

///|
test "haskell: intersperse 单元素流不插分隔符" {
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::of(7).intersperse(0)
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [7])
}

///|
test "haskell: intercalate 数组流用分隔数组连接" {
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter(
    [[1, 2], [3], [4, 5]],
  ).intercalate([0])
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1, 2, 0, 3, 0, 4, 5])
}

///|
test "haskell: zip_with 双流合并映射" {
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3]).zip_with(
    @rx.Observable::from_iter([10, 20, 30]),
    fn(a : Int, b : Int) { a + b },
  )
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [11, 22, 33])
}

///|
test "haskell: zip_with 一方完成后提前终止" {
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3, 4]).zip_with(
    @rx.Observable::from_iter([10, 20]),
    fn(a : Int, b : Int) { a + b },
  )
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [11, 22])
}

///|
test "haskell: zip3 三流拉链" {
  let values : Ref[Array[(Int, String, Bool)]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[(Int, String, Bool), Unit] = @rx.Observable::from_iter(
    [1, 2],
  ).zip3(
    @rx.Observable::from_iter(["a", "b"]),
    @rx.Observable::from_iter([true, false]),
  )
  let _ = obs.subscribe_on_next(fn(v : (Int, String, Bool)) { values.val.push(v) })
  assert_eq(values.val, [(1, "a", true), (2, "b", false)])
}

///|
test "haskell: unzip 拆分为两列" {
  let values : Ref[Array[(Array[Int], Array[String])]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[(Array[Int], Array[String]), Unit] = @rx.Observable::from_iter(
    [(1, "a"), (2, "b"), (3, "c")],
  ).unzip()
  let _ = obs.subscribe_on_next(fn(v : (Array[Int], Array[String])) { values.val.push(v) })
  assert_eq(values.val, [([1, 2, 3], ["a", "b", "c"])])
}

///|
test "haskell: transpose 矩阵转置" {
  let values : Ref[Array[Array[Array[Int]]]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Array[Array[Int]], Unit] = @rx.Observable::from_iter(
    [[1, 2, 3], [4, 5, 6]],
  ).transpose()
  let _ = obs.subscribe_on_next(fn(v : Array[Array[Int]]) { values.val.push(v) })
  assert_eq(values.val, [[[1, 4], [2, 5], [3, 6]]])
}

///|
test "haskell: span 满足谓词的最长前缀与剩余" {
  let values : Ref[Array[(Array[Int], Array[Int])]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[(Array[Int], Array[Int]), Unit] = @rx.Observable::from_iter(
    [1, 2, 3, 1, 4],
  ).span(fn(x : Int) { x < 3 })
  let _ = obs.subscribe_on_next(fn(v : (Array[Int], Array[Int])) { values.val.push(v) })
  assert_eq(values.val, [([1, 2], [3, 1, 4])])
}

///|
test "haskell: break_pred 前缀不满足谓词" {
  let values : Ref[Array[(Array[Int], Array[Int])]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[(Array[Int], Array[Int]), Unit] = @rx.Observable::from_iter(
    [1, 2, 3, 1],
  ).break_pred(fn(x : Int) { x > 2 })
  let _ = obs.subscribe_on_next(fn(v : (Array[Int], Array[Int])) { values.val.push(v) })
  assert_eq(values.val, [([1, 2], [3, 1])])
}

///|
test "haskell: split_at 前 n 个与剩余" {
  let values : Ref[Array[(Array[Int], Array[Int])]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[(Array[Int], Array[Int]), Unit] = @rx.Observable::from_iter(
    [1, 2, 3, 4, 5],
  ).split_at(2)
  let _ = obs.subscribe_on_next(fn(v : (Array[Int], Array[Int])) { values.val.push(v) })
  assert_eq(values.val, [([1, 2], [3, 4, 5])])
}

///|
test "haskell: partition 满足与不满足两路" {
  let values : Ref[Array[(Array[Int], Array[Int])]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[(Array[Int], Array[Int]), Unit] = @rx.Observable::from_iter(
    [1, 2, 3, 4, 5],
  ).partition(fn(x : Int) { x % 2 == 0 })
  let _ = obs.subscribe_on_next(fn(v : (Array[Int], Array[Int])) { values.val.push(v) })
  assert_eq(values.val, [([2, 4], [1, 3, 5])])
}

///|
test "haskell: not_elem 不含目标发 true" {
  let values : Ref[Array[Bool]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Bool, Unit] = @rx.Observable::from_iter([1, 2, 3]).not_elem(9)
  let _ = obs.subscribe_on_next(fn(v : Bool) { values.val.push(v) })
  assert_eq(values.val, [true])
}

///|
test "haskell: not_elem 含目标发 false" {
  let values : Ref[Array[Bool]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Bool, Unit] = @rx.Observable::from_iter([1, 2, 3]).not_elem(2)
  let _ = obs.subscribe_on_next(fn(v : Bool) { values.val.push(v) })
  assert_eq(values.val, [false])
}

///|
test "haskell: delete_first 删除第一个匹配" {
  let values : Ref[Array[Array[Int]]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Array[Int], Unit] = @rx.Observable::from_iter(
    [1, 2, 3, 2],
  ).delete_first(2)
  let _ = obs.subscribe_on_next(fn(v : Array[Int]) { values.val.push(v) })
  assert_eq(values.val, [[1, 3, 2]])
}

///|
test "haskell: group_adjacent 相邻相等分组" {
  let values : Ref[Array[Array[Int]]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Array[Int], Unit] = @rx.Observable::from_iter(
    [1, 1, 2, 2, 2, 3, 1],
  ).group_adjacent()
  let _ = obs.subscribe_on_next(fn(v : Array[Int]) { values.val.push(v) })
  assert_eq(values.val, [[1, 1], [2, 2, 2], [3], [1]])
}

///|
test "haskell: group_adjacent_by 相邻满足谓词分组" {
  let values : Ref[Array[Array[Int]]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Array[Int], Unit] = @rx.Observable::from_iter(
    [1, 3, 2, 4, 5],
  ).group_adjacent_by(fn(a : Int, b : Int) { (a + b) % 2 == 0 })
  let _ = obs.subscribe_on_next(fn(v : Array[Int]) { values.val.push(v) })
  assert_eq(values.val, [[1, 3], [2, 4], [5]])
}

///|
test "haskell: is_prefix_of 是前缀" {
  let values : Ref[Array[Bool]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Bool, Unit] = @rx.Observable::from_iter([1, 2, 3, 4]).is_prefix_of(
    [1, 2],
  )
  let _ = obs.subscribe_on_next(fn(v : Bool) { values.val.push(v) })
  assert_eq(values.val, [true])
}

///|
test "haskell: is_prefix_of 非前缀" {
  let values : Ref[Array[Bool]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Bool, Unit] = @rx.Observable::from_iter([1, 2, 3]).is_prefix_of(
    [2, 3],
  )
  let _ = obs.subscribe_on_next(fn(v : Bool) { values.val.push(v) })
  assert_eq(values.val, [false])
}

///|
test "haskell: is_suffix_of 是后缀" {
  let values : Ref[Array[Bool]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Bool, Unit] = @rx.Observable::from_iter([1, 2, 3, 4]).is_suffix_of(
    [3, 4],
  )
  let _ = obs.subscribe_on_next(fn(v : Bool) { values.val.push(v) })
  assert_eq(values.val, [true])
}

///|
test "haskell: is_infix_of 包含子序列" {
  let values : Ref[Array[Bool]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Bool, Unit] = @rx.Observable::from_iter([1, 2, 3, 4, 5]).is_infix_of(
    [3, 4],
  )
  let _ = obs.subscribe_on_next(fn(v : Bool) { values.val.push(v) })
  assert_eq(values.val, [true])
}

///|
test "haskell: is_infix_of 不含子序列" {
  let values : Ref[Array[Bool]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Bool, Unit] = @rx.Observable::from_iter([1, 2, 3]).is_infix_of(
    [2, 1],
  )
  let _ = obs.subscribe_on_next(fn(v : Bool) { values.val.push(v) })
  assert_eq(values.val, [false])
}

///|
test "haskell: foldr 右折叠（减法验证方向）" {
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  // Haskell: foldr (-) 0 [1,2,3] = 1 - (2 - (3 - 0)) = 2
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3]).foldr(
    0,
    fn(x : Int, acc : Int) { x - acc },
  )
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [2])
}

///|
test "haskell: scanr 右扫描结果列表" {
  let values : Ref[Array[Array[Int]]] = Ref::Ref(Array(capacity=0))
  // Haskell: scanr (+) 0 [1,2,3] = [6,5,3,0]
  let obs : @rx.Observable[Array[Int], Unit] = @rx.Observable::from_iter([1, 2, 3]).scanr(
    0,
    fn(x : Int, acc : Int) { x + acc },
  )
  let _ = obs.subscribe_on_next(fn(v : Array[Int]) { values.val.push(v) })
  assert_eq(values.val, [[6, 5, 3, 0]])
}

///|
test "haskell: product 累乘" {
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([2, 3, 4]).product()
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [24])
}

///|
test "haskell: product 空流不发值" {
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([]).product()
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [])
}

///|
test "haskell: fold_map 映射后累积" {
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  // 相当于 map(x -> x*2) 再 sum
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3]).fold_map(
    0,
    fn(x : Int) { x * 2 },
    fn(a : Int, b : Int) { a + b },
  )
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [12])
}

///|
test "haskell: sort_by 按比较函数排序（自定义规则）" {
  let values : Ref[Array[Array[Int]]] = Ref::Ref(Array(capacity=0))
  // 按绝对值降序
  let obs : @rx.Observable[Array[Int], Unit] = @rx.Observable::from_iter(
    [-3, 1, -2, 4],
  ).sort_by(fn(a : Int, b : Int) { (a * a).compare(b * b) })
  let _ = obs.subscribe_on_next(fn(v : Array[Int]) { values.val.push(v) })
  assert_eq(values.val, [[1, -2, -3, 4]])
}

///|
test "haskell: sort_on 按键投影排序" {
  let values : Ref[Array[Array[Int]]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Array[Int], Unit] = @rx.Observable::from_iter(
    [3, 1, 2],
  ).sort_on(fn(x : Int) { x })
  let _ = obs.subscribe_on_next(fn(v : Array[Int]) { values.val.push(v) })
  assert_eq(values.val, [[1, 2, 3]])
}

///|
test "haskell: maximum_by_cmp 按比较函数求最大" {
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  // 按绝对值最大：|-3| 最大
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, -3, 2]).maximum_by_cmp(
    fn(a : Int, b : Int) { (a * a).compare(b * b) },
  )
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [-3])
}

///|
test "haskell: minimum_by_cmp 按比较函数求最小" {
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, -3, 2]).minimum_by_cmp(
    fn(a : Int, b : Int) { (a * a).compare(b * b) },
  )
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1])
}

///|
test "haskell: find_indices 收集所有满足索引" {
  let values : Ref[Array[Array[Int]]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Array[Int], Unit] = @rx.Observable::from_iter(
    [10, 21, 32, 43],
  ).find_indices(fn(x : Int) { x % 2 == 1 })
  let _ = obs.subscribe_on_next(fn(v : Array[Int]) { values.val.push(v) })
  assert_eq(values.val, [[1, 3]])
}

///|
test "haskell: elem_index 等值查找索引" {
  let values : Ref[Array[Int64]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Int64, Unit] = @rx.Observable::from_iter([5, 6, 7]).elem_index(6)
  let _ = obs.subscribe_on_next(fn(v : Int64) { values.val.push(v) })
  assert_eq(values.val, [1L])
}

///|
test "haskell: elem_index 找不到发 -1" {
  let values : Ref[Array[Int64]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Int64, Unit] = @rx.Observable::from_iter([5, 6, 7]).elem_index(9)
  let _ = obs.subscribe_on_next(fn(v : Int64) { values.val.push(v) })
  assert_eq(values.val, [-1L])
}

///|
test "haskell: elem_indices 收集所有等值索引" {
  let values : Ref[Array[Array[Int]]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Array[Int], Unit] = @rx.Observable::from_iter(
    [2, 3, 2, 4, 2],
  ).elem_indices(2)
  let _ = obs.subscribe_on_next(fn(v : Array[Int]) { values.val.push(v) })
  assert_eq(values.val, [[0, 2, 4]])
}

///|
test "haskell: lookup 按键查找发值" {
  let values : Ref[Array[String?]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[String?, Unit] = @rx.Observable::from_iter(
    [(1, "a"), (2, "b")],
  ).lookup(
    2,
    fn(p : (Int, String)) { p.0 },
    fn(p : (Int, String)) { p.1 },
  )
  let _ = obs.subscribe_on_next(fn(v : String?) { values.val.push(v) })
  assert_eq(values.val, [Some("b")])
}

///|
test "haskell: lookup 找不到发 None" {
  let values : Ref[Array[String?]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[String?, Unit] = @rx.Observable::from_iter(
    [(1, "a")],
  ).lookup(
    9,
    fn(p : (Int, String)) { p.0 },
    fn(p : (Int, String)) { p.1 },
  )
  let _ = obs.subscribe_on_next(fn(v : String?) { values.val.push(v) })
  assert_eq(values.val, [None])
}

///|
test "haskell: Itor::fold 消费迭代器累加" {
  let itor = @rx.Itor::from_array([1, 2, 3, 4])
  let total = itor.fold(0, fn(acc : Int, v : Int) { acc + v })
  assert_eq(total, 10)
}

///|
test "haskell: Itor::fold 空迭代器返回 seed" {
  let itor = @rx.Itor::from_array([])
  let total = itor.fold(100, fn(acc : Int, v : Int) { acc + v })
  assert_eq(total, 100)
}

// ============================================================================
// 第二批 / 第三批补全 API：tail / init / scanl1 / scanr1 / foldr1 /
// map_accum_l / map_accum_r / all_true / any_true / take_while_end /
// drop_while_end / inits / tails / strip_prefix / strip_suffix /
// delete_first_by / is_subsequence_of / nub_by / unzip3 / union / intersect /
// difference / insert / insert_by / lines / words / unlines / unwords
// ============================================================================

///|
test "haskell: tail 丢弃首元素" {
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3]).tail()
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [2, 3])
}

///|
test "haskell: tail 空流不发值" {
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([]).tail()
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [])
}

///|
test "haskell: init 丢弃末元素" {
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3]).init()
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1, 2])
}

///|
test "haskell: scanl1 无种子左扫描" {
  // Haskell: scanl1 (+) [1,2,3] = [1,3,6]
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3]).scanl1(fn(a : Int, b : Int) { a + b })
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1, 3, 6])
}

///|
test "haskell: scanl1 减法验证累积方向" {
  // Haskell: scanl1 (-) [1,2,3] = [1, -1, -4]
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3]).scanl1(fn(a : Int, b : Int) { a - b })
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [1, -1, -4])
}

///|
test "haskell: scanr1 无种子右扫描" {
  // Haskell: scanr1 (-) [1,2,3] = [1-(2-3), 2-3, 3] = [2, -1, 3]
  let values : Ref[Array[Array[Int]]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Array[Int], Unit] = @rx.Observable::from_iter([1, 2, 3]).scanr1(fn(a : Int, b : Int) { a - b })
  let _ = obs.subscribe_on_next(fn(v : Array[Int]) { values.val.push(v) })
  assert_eq(values.val, [[2, -1, 3]])
}

///|
test "haskell: foldr1 无种子右折叠" {
  // Haskell: foldr1 (-) [1,2,3] = 1-(2-3) = 2
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([1, 2, 3]).foldr1(fn(a : Int, b : Int) { a - b })
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [2])
}

///|
test "haskell: foldr1 单元素直接发该元素" {
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([42]).foldr1(fn(a : Int, b : Int) { a + b })
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [42])
}

///|
test "haskell: map_accum_l 带状态左映射" {
  // Haskell: mapAccumL (\acc x -> (acc+x, acc+x)) 0 [1,2,3] = (6, [1,3,6])
  let values : Ref[Array[(Int, Int)]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[(Int, Int), Unit] = @rx.Observable::from_iter(
    [1, 2, 3],
  ).map_accum_l(0, fn(acc : Int, x : Int) -> (Int, Int) { (acc + x, acc + x) })
  let _ = obs.subscribe_on_next(fn(v : (Int, Int)) { values.val.push(v) })
  assert_eq(values.val, [(1, 1), (3, 3), (6, 6)])
}

///|
test "haskell: map_accum_r 带状态右映射" {
  // Haskell: mapAccumR (\acc x -> (acc+x, acc+x)) 0 [1,2,3]
  // 从右往左：先处理 3 -> (3,3)，再 2 -> (5,5)，再 1 -> (6,6)，输出保持原顺序
  let values : Ref[Array[(Int, Int)]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[(Int, Int), Unit] = @rx.Observable::from_iter(
    [1, 2, 3],
  ).map_accum_r(0, fn(acc : Int, x : Int) -> (Int, Int) { (acc + x, acc + x) })
  let _ = obs.subscribe_on_next(fn(v : (Int, Int)) { values.val.push(v) })
  assert_eq(values.val, [(6, 6), (5, 5), (3, 3)])
}

///|
test "haskell: all_true 全真发 true" {
  let values : Ref[Array[Bool]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Bool, Unit] = @rx.Observable::from_iter([true, true, true]).all_true()
  let _ = obs.subscribe_on_next(fn(v : Bool) { values.val.push(v) })
  assert_eq(values.val, [true])
}

///|
test "haskell: all_true 遇 false 早停发 false" {
  let values : Ref[Array[Bool]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Bool, Unit] = @rx.Observable::from_iter([true, false, true]).all_true()
  let _ = obs.subscribe_on_next(fn(v : Bool) { values.val.push(v) })
  assert_eq(values.val, [false])
}

///|
test "haskell: any_true 任一真发 true" {
  let values : Ref[Array[Bool]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Bool, Unit] = @rx.Observable::from_iter([false, true, false]).any_true()
  let _ = obs.subscribe_on_next(fn(v : Bool) { values.val.push(v) })
  assert_eq(values.val, [true])
}

///|
test "haskell: any_true 全假发 false" {
  let values : Ref[Array[Bool]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Bool, Unit] = @rx.Observable::from_iter([false, false]).any_true()
  let _ = obs.subscribe_on_next(fn(v : Bool) { values.val.push(v) })
  assert_eq(values.val, [false])
}

///|
test "haskell: take_while_end 尾部连续满足的最长后缀" {
  // Haskell: takeWhileEnd even [1,2,3,4,6] = [4,6]
  let values : Ref[Array[Array[Int]]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Array[Int], Unit] = @rx.Observable::from_iter(
    [1, 2, 3, 4, 6],
  ).take_while_end(fn(v : Int) { v % 2 == 0 })
  let _ = obs.subscribe_on_next(fn(v : Array[Int]) { values.val.push(v) })
  assert_eq(values.val, [[4, 6]])
}

///|
test "haskell: drop_while_end 去掉尾部满足段" {
  // Haskell: dropWhileEnd even [1,2,3,4,6] = [1,2,3]
  let values : Ref[Array[Array[Int]]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Array[Int], Unit] = @rx.Observable::from_iter(
    [1, 2, 3, 4, 6],
  ).drop_while_end(fn(v : Int) { v % 2 == 0 })
  let _ = obs.subscribe_on_next(fn(v : Array[Int]) { values.val.push(v) })
  assert_eq(values.val, [[1, 2, 3]])
}

///|
test "haskell: inits 全部前缀" {
  let values : Ref[Array[Array[Array[Int]]]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Array[Array[Int]], Unit] = @rx.Observable::from_iter(
    [1, 2, 3],
  ).inits()
  let _ = obs.subscribe_on_next(fn(v : Array[Array[Int]]) { values.val.push(v) })
  assert_eq(values.val, [[[], [1], [1, 2], [1, 2, 3]]])
}

///|
test "haskell: tails 全部后缀" {
  let values : Ref[Array[Array[Array[Int]]]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Array[Array[Int]], Unit] = @rx.Observable::from_iter(
    [1, 2, 3],
  ).tails()
  let _ = obs.subscribe_on_next(fn(v : Array[Array[Int]]) { values.val.push(v) })
  assert_eq(values.val, [[[1, 2, 3], [2, 3], [3], []]])
}

///|
test "haskell: strip_prefix 匹配发剩余" {
  let values : Ref[Array[Array[Int]?]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Array[Int]?, Unit] = @rx.Observable::from_iter(
    [1, 2, 3],
  ).strip_prefix([1, 2])
  let _ = obs.subscribe_on_next(fn(v : Array[Int]?) { values.val.push(v) })
  assert_eq(values.val, [Some([3])])
}

///|
test "haskell: strip_prefix 不匹配发 None" {
  let values : Ref[Array[Array[Int]?]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Array[Int]?, Unit] = @rx.Observable::from_iter(
    [1, 2, 3],
  ).strip_prefix([2, 3])
  let _ = obs.subscribe_on_next(fn(v : Array[Int]?) { values.val.push(v) })
  assert_eq(values.val, [None])
}

///|
test "haskell: strip_suffix 匹配发剩余" {
  let values : Ref[Array[Array[Int]?]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Array[Int]?, Unit] = @rx.Observable::from_iter(
    [1, 2, 3],
  ).strip_suffix([2, 3])
  let _ = obs.subscribe_on_next(fn(v : Array[Int]?) { values.val.push(v) })
  assert_eq(values.val, [Some([1])])
}

///|
test "haskell: delete_first_by 按谓词删除第一个" {
  let values : Ref[Array[Array[Int]]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Array[Int], Unit] = @rx.Observable::from_iter(
    [1, 2, 3, 4],
  ).delete_first_by(2, fn(a : Int, b : Int) { a == b })
  let _ = obs.subscribe_on_next(fn(v : Array[Int]) { values.val.push(v) })
  assert_eq(values.val, [[1, 3, 4]])
}

///|
test "haskell: is_subsequence_of 是子序列" {
  let values : Ref[Array[Bool]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Bool, Unit] = @rx.Observable::from_iter(
    [1, 2, 3, 4],
  ).is_subsequence_of([1, 3])
  let _ = obs.subscribe_on_next(fn(v : Bool) { values.val.push(v) })
  assert_eq(values.val, [true])
}

///|
test "haskell: is_subsequence_of 非子序列" {
  let values : Ref[Array[Bool]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Bool, Unit] = @rx.Observable::from_iter(
    [1, 2, 3, 4],
  ).is_subsequence_of([3, 1])
  let _ = obs.subscribe_on_next(fn(v : Bool) { values.val.push(v) })
  assert_eq(values.val, [false])
}

///|
test "haskell: nub_by 两两比较去重" {
  // 按绝对值去重，无 Hash 约束
  let values : Ref[Array[Array[Int]]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Array[Int], Unit] = @rx.Observable::from_iter(
    [1, -1, 2, -2, 1],
  ).nub_by(fn(a : Int, b : Int) { a.abs() == b.abs() })
  let _ = obs.subscribe_on_next(fn(v : Array[Int]) { values.val.push(v) })
  assert_eq(values.val, [[1, 2]])
}

///|
test "haskell: unzip3 拆分三元组" {
  let values : Ref[Array[(Array[Int], Array[String], Array[Bool])]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[(Array[Int], Array[String], Array[Bool]), Unit] =
    @rx.Observable::from_iter([(1, "a", true), (2, "b", false)]).unzip3()
  let _ = obs.subscribe_on_next(fn(v : (Array[Int], Array[String], Array[Bool])) { values.val.push(v) })
  assert_eq(values.val, [([1, 2], ["a", "b"], [true, false])])
}

///|
test "haskell: union 并集" {
  // Haskell: union [1,2,3] [2,3,4,4] = [1,2,3,4]
  let values : Ref[Array[Array[Int]]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Array[Int], Unit] = @rx.Observable::from_iter(
    [1, 2, 3],
  ).union([2, 3, 4, 4])
  let _ = obs.subscribe_on_next(fn(v : Array[Int]) { values.val.push(v) })
  assert_eq(values.val, [[1, 2, 3, 4]])
}

///|
test "haskell: intersect 交集" {
  // Haskell: intersect [1,2,3,4] [2,4,6] = [2,4]（保持源流顺序）
  let values : Ref[Array[Array[Int]]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Array[Int], Unit] = @rx.Observable::from_iter(
    [1, 2, 3, 4],
  ).intersect([2, 4, 6])
  let _ = obs.subscribe_on_next(fn(v : Array[Int]) { values.val.push(v) })
  assert_eq(values.val, [[2, 4]])
}

///|
test "haskell: difference 差集" {
  // Haskell: [1,2,3,2,4] \\ [2,4] = [1,3,2]（按出现次数逐个删除）
  let values : Ref[Array[Array[Int]]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Array[Int], Unit] = @rx.Observable::from_iter(
    [1, 2, 3, 2, 4],
  ).difference([2, 4])
  let _ = obs.subscribe_on_next(fn(v : Array[Int]) { values.val.push(v) })
  assert_eq(values.val, [[1, 3, 2]])
}

///|
test "haskell: insert 有序插入" {
  // Haskell: insert 3 [1,2,4,5] = [1,2,3,4,5]
  let values : Ref[Array[Array[Int]]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Array[Int], Unit] = @rx.Observable::from_iter(
    [1, 2, 4, 5],
  ).insert(3)
  let _ = obs.subscribe_on_next(fn(v : Array[Int]) { values.val.push(v) })
  assert_eq(values.val, [[1, 2, 3, 4, 5]])
}

///|
test "haskell: insert 插入开头与末尾" {
  let values : Ref[Array[Array[Int]]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Array[Int], Unit] = @rx.Observable::from_iter(
    [2, 3],
  ).insert(1)
  let _ = obs.subscribe_on_next(fn(v : Array[Int]) { values.val.push(v) })
  assert_eq(values.val, [[1, 2, 3]])
}

///|
test "haskell: insert_by 自定义比较插入" {
  // 按长度插入字符串（短 -> 长）
  let values : Ref[Array[Array[String]]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Array[String], Unit] = @rx.Observable::from_iter(
    ["a", "ccc"],
  ).insert_by(fn(a : String, b : String) { a.length().compare(b.length()) }, "bb")
  let _ = obs.subscribe_on_next(fn(v : Array[String]) { values.val.push(v) })
  assert_eq(values.val, [["a", "bb", "ccc"]])
}

///|
test "haskell: lines 按换行切分" {
  // Haskell: lines "a\nb\n" = ["a","b"]；lines "\n" = [""]；lines "" = []
  let values : Ref[Array[String]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[String, Unit] = @rx.lines("a\nb\n")
  let _ = obs.subscribe_on_next(fn(v : String) { values.val.push(v) })
  assert_eq(values.val, ["a", "b"])
}

///|
test "haskell: words 按空白切分" {
  // Haskell: words " a  b\nc " = ["a","b","c"]
  let values : Ref[Array[String]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[String, Unit] = @rx.words(" a  b\nc ")
  let _ = obs.subscribe_on_next(fn(v : String) { values.val.push(v) })
  assert_eq(values.val, ["a", "b", "c"])
}

///|
test "haskell: unlines 行连接" {
  // Haskell: unlines ["a","b"] = "a\nb\n"
  let values : Ref[Array[String]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[String, Unit] = @rx.Observable::from_iter(["a", "b"]).unlines()
  let _ = obs.subscribe_on_next(fn(v : String) { values.val.push(v) })
  assert_eq(values.val, ["a\nb\n"])
}

///|
test "haskell: unwords 词连接" {
  // Haskell: unwords ["a","b"] = "a b"
  let values : Ref[Array[String]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[String, Unit] = @rx.Observable::from_iter(["a", "b"]).unwords()
  let _ = obs.subscribe_on_next(fn(v : String) { values.val.push(v) })
  assert_eq(values.val, ["a b"])
}
