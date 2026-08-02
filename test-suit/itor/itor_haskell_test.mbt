// ============================================================================
// test-suit/itor/itor_haskell_test.mbt —— Itor Haskell 迭代器语义测试
// 覆盖 ops_itor_haskell.mbt：构造（iterate/repeat/cycle/unfoldr/replicate）、
// 变换（map/filter/take/drop/take_while/drop_while/scan/reverse/intersperse/
// concat_map/zip/zip_with/tail/init/nub/sort_by/sort_on/intercalate/concat）、
// 折叠聚合（foldr/length/null/sum/product/any/all/elem/not_elem/find/
// find_index/maximum/minimum/to_array/head/last/lookup/elem_index/
// elem_indices/find_indices/map_accum_l/map_accum_r/inits/tails）、
// 拆分判定（partition/span/break_pred/split_at/group_adjacent/
// is_prefix_of/is_suffix_of/is_infix_of）。
// 运行：moon test -p test-suit/itor
// ============================================================================

///|
test "haskell-itor: iterate 无限迭代配合 take 截断" {
  let gen = @rx.Itor::iterate(fn(x : Int) { x * 2 }, 1).take(5)
  assert_eq(gen.to_array(), [1, 2, 4, 8, 16])
}

///|
test "haskell-itor: repeat 无限重复配合 take 截断" {
  let gen = @rx.Itor::repeat("x").take(3)
  assert_eq(gen.to_array(), ["x", "x", "x"])
}

///|
test "haskell-itor: cycle 无限循环数组配合 take 截断" {
  let gen = @rx.Itor::cycle([1, 2, 3]).take(7)
  assert_eq(gen.to_array(), [1, 2, 3, 1, 2, 3, 1])
}

///|
test "haskell-itor: cycle 空数组立即结束" {
  let empty : Array[Int] = []
  let gen = @rx.Itor::cycle(empty)
  assert_eq(gen.to_array(), [])
}

///|
test "haskell-itor: unfoldr 展开递减到 0 结束" {
  let gen = @rx.Itor::unfoldr(
    fn(s : Int) -> (Int, Int)? {
      if s <= 0 {
        None
      } else {
        Some((s, s - 1))
      }
    },
    4,
  )
  assert_eq(gen.to_array(), [4, 3, 2, 1])
}

///|
test "haskell-itor: unfoldr 立即结束" {
  let gen = @rx.Itor::unfoldr(fn(_s : Int) -> (Int, Int)? { None }, 0)
  assert_eq(gen.to_array(), [])
}

///|
test "haskell-itor: replicate 重复 n 次" {
  let gen = @rx.Itor::replicate(4, 7)
  assert_eq(gen.to_array(), [7, 7, 7, 7])
}

///|
test "haskell-itor: replicate 0 次为空" {
  let gen = @rx.Itor::replicate(0, 7)
  assert_eq(gen.to_array(), [])
}

///|
test "haskell-itor: map 逐元素变换" {
  let gen = @rx.Itor::from_array([1, 2, 3]).map(fn(x : Int) { x * 10 })
  assert_eq(gen.to_array(), [10, 20, 30])
}

///|
test "haskell-itor: filter 保留偶数" {
  let gen = @rx.Itor::from_array([1, 2, 3, 4, 5, 6]).filter(fn(x : Int) { x % 2 == 0 })
  assert_eq(gen.to_array(), [2, 4, 6])
}

///|
test "haskell-itor: filter 全不满足为空" {
  let gen = @rx.Itor::from_array([1, 3, 5]).filter(fn(x : Int) { x % 2 == 0 })
  assert_eq(gen.to_array(), [])
}

///|
test "haskell-itor: take 前 n 个" {
  let gen = @rx.Itor::from_array([1, 2, 3, 4, 5]).take(3)
  assert_eq(gen.to_array(), [1, 2, 3])
}

///|
test "haskell-itor: take 超过长度取全部" {
  let gen = @rx.Itor::from_array([1, 2]).take(5)
  assert_eq(gen.to_array(), [1, 2])
}

///|
test "haskell-itor: take n<=0 为空" {
  let gen = @rx.Itor::from_array([1, 2, 3]).take(0)
  assert_eq(gen.to_array(), [])
}

///|
test "haskell-itor: drop 跳过前 n 个" {
  let gen = @rx.Itor::from_array([1, 2, 3, 4, 5]).drop(2)
  assert_eq(gen.to_array(), [3, 4, 5])
}

///|
test "haskell-itor: drop 超过长度为空" {
  let gen = @rx.Itor::from_array([1, 2]).drop(5)
  assert_eq(gen.to_array(), [])
}

///|
test "haskell-itor: drop n<=0 原样透传" {
  let gen = @rx.Itor::from_array([1, 2, 3]).drop(0)
  assert_eq(gen.to_array(), [1, 2, 3])
}

///|
test "haskell-itor: take_while 取满足前缀" {
  let gen = @rx.Itor::from_array([1, 2, 3, 1, 4]).take_while(fn(x : Int) { x < 3 })
  assert_eq(gen.to_array(), [1, 2])
}

///|
test "haskell-itor: drop_while 跳过满足前缀" {
  let gen = @rx.Itor::from_array([1, 2, 3, 1, 4]).drop_while(fn(x : Int) { x < 3 })
  assert_eq(gen.to_array(), [3, 1, 4])
}

///|
test "haskell-itor: scan 含初始 seed 的累积" {
  // Haskell: scanl (+) 0 [1,2,3] = [0,1,3,6]
  let gen = @rx.Itor::from_array([1, 2, 3]).scan(0, fn(acc : Int, x : Int) { acc + x })
  assert_eq(gen.to_array(), [0, 1, 3, 6])
}

///|
test "haskell-itor: scan 空迭代器只发 seed" {
  let empty : Array[Int] = []
  let gen = @rx.Itor::from_array(empty).scan(5, fn(acc : Int, x : Int) { acc + x })
  assert_eq(gen.to_array(), [5])
}

///|
test "haskell-itor: reverse 反转" {
  let gen = @rx.Itor::from_array([1, 2, 3, 4]).reverse()
  assert_eq(gen.to_array(), [4, 3, 2, 1])
}

///|
test "haskell-itor: reverse 空迭代器为空" {
  let empty : Array[Int] = []
  let gen = @rx.Itor::from_array(empty).reverse()
  assert_eq(gen.to_array(), [])
}

///|
test "haskell-itor: intersperse 元素间插入分隔" {
  let gen = @rx.Itor::from_array([1, 2, 3]).intersperse(0)
  assert_eq(gen.to_array(), [1, 0, 2, 0, 3])
}

///|
test "haskell-itor: intersperse 单元素不插" {
  let gen = @rx.Itor::from_array([7]).intersperse(0)
  assert_eq(gen.to_array(), [7])
}

///|
test "haskell-itor: concat_map 展平" {
  let gen = @rx.Itor::from_array([1, 2, 3]).concat_map(fn(x : Int) {
    @rx.Itor::from_array([x, x * 10])
  })
  assert_eq(gen.to_array(), [1, 10, 2, 20, 3, 30])
}

///|
test "haskell-itor: zip_with 双迭代器合并" {
  let gen = @rx.Itor::from_array([1, 2, 3]).zip_with(
    @rx.Itor::from_array([10, 20, 30]),
    fn(a : Int, b : Int) { a + b },
  )
  assert_eq(gen.to_array(), [11, 22, 33])
}

///|
test "haskell-itor: zip_with 一方耗尽提前结束" {
  let gen = @rx.Itor::from_array([1, 2, 3, 4]).zip_with(
    @rx.Itor::from_array([10, 20]),
    fn(a : Int, b : Int) { a + b },
  )
  assert_eq(gen.to_array(), [11, 22])
}

///|
test "haskell-itor: zip 配对元组" {
  let gen = @rx.Itor::from_array([1, 2]).zip(@rx.Itor::from_array(["a", "b"]))
  assert_eq(gen.to_array(), [(1, "a"), (2, "b")])
}

///|
test "haskell-itor: tail 去掉首元素" {
  let gen = @rx.Itor::from_array([1, 2, 3]).tail()
  assert_eq(gen.to_array(), [2, 3])
}

///|
test "haskell-itor: tail 单元素为空" {
  let gen = @rx.Itor::from_array([1]).tail()
  assert_eq(gen.to_array(), [])
}

///|
test "haskell-itor: init 去掉尾元素" {
  let gen = @rx.Itor::from_array([1, 2, 3]).init()
  assert_eq(gen.to_array(), [1, 2])
}

///|
test "haskell-itor: nub 去重保序" {
  let gen = @rx.Itor::from_array([1, 2, 1, 3, 2, 4, 1]).nub()
  assert_eq(gen.to_array(), [1, 2, 3, 4])
}

///|
test "haskell-itor: sort_by 按比较函数排序" {
  let gen = @rx.Itor::from_array([3, 1, 2]).sort_by(fn(a : Int, b : Int) { a.compare(b) })
  assert_eq(gen.to_array(), [1, 2, 3])
}

///|
test "haskell-itor: sort_on 按键投影排序" {
  // 按绝对值排序
  let gen = @rx.Itor::from_array([-3, 1, -2, 4]).sort_on(fn(x : Int) { x * x })
  assert_eq(gen.to_array(), [1, -2, -3, 4])
}

///|
test "haskell-itor: foldr 右折叠（减法验证方向）" {
  // Haskell: foldr (-) 0 [1,2,3] = 1 - (2 - (3 - 0)) = 2
  let total = @rx.Itor::from_array([1, 2, 3]).foldr(0, fn(x : Int, acc : Int) { x - acc })
  assert_eq(total, 2)
}

///|
test "haskell-itor: length 计数" {
  let n = @rx.Itor::from_array([1, 2, 3, 4, 5]).length()
  assert_eq(n, 5)
}

///|
test "haskell-itor: null 空与非空" {
  let empty : Array[Int] = []
  assert_true(@rx.Itor::from_array(empty).null())
  assert_false(@rx.Itor::from_array([1]).null())
}

///|
test "haskell-itor: sum 累加" {
  let total = @rx.Itor::from_array([1, 2, 3, 4]).sum()
  assert_eq(total, 10)
}

///|
test "haskell-itor: sum 空迭代器为默认值" {
  let empty : Array[Int] = []
  let total = @rx.Itor::from_array(empty).sum()
  assert_eq(total, 0)
}

///|
test "haskell-itor: product 累乘" {
  let p = @rx.Itor::from_array([2, 3, 4]).product()
  assert_eq(p, Some(24))
}

///|
test "haskell-itor: product 空迭代器为 None" {
  let empty : Array[Int] = []
  let p = @rx.Itor::from_array(empty).product()
  if p is Some(_) {
    assert_true(false)
  }
}

///|
test "haskell-itor: any / all 判定" {
  assert_true(@rx.Itor::from_array([1, 2, 3]).any(fn(x : Int) { x > 2 }))
  assert_false(@rx.Itor::from_array([1, 2, 3]).any(fn(x : Int) { x > 9 }))
  assert_true(@rx.Itor::from_array([2, 4, 6]).all(fn(x : Int) { x % 2 == 0 }))
  assert_false(@rx.Itor::from_array([2, 3, 4]).all(fn(x : Int) { x % 2 == 0 }))
}

///|
test "haskell-itor: elem / not_elem 包含判定" {
  assert_true(@rx.Itor::from_array([1, 2, 3]).elem(2))
  assert_false(@rx.Itor::from_array([1, 2, 3]).elem(9))
  assert_true(@rx.Itor::from_array([1, 2, 3]).not_elem(9))
  assert_false(@rx.Itor::from_array([1, 2, 3]).not_elem(2))
}

///|
test "haskell-itor: find 找到与找不到" {
  assert_eq(@rx.Itor::from_array([1, 2, 3, 4]).find(fn(x : Int) { x % 2 == 0 }), Some(2))
  let r = @rx.Itor::from_array([1, 3, 5]).find(fn(x : Int) { x % 2 == 0 })
  if r is Some(_) {
    assert_true(false)
  }
}

///|
test "haskell-itor: find_index 下标" {
  assert_eq(
    @rx.Itor::from_array([10, 21, 32, 43]).find_index(fn(x : Int) { x % 2 == 1 }),
    Some(1L),
  )
  let r = @rx.Itor::from_array([1, 3, 5]).find_index(fn(x : Int) { x % 2 == 0 })
  if r is Some(_) {
    assert_true(false)
  }
}

///|
test "haskell-itor: maximum / minimum 极值" {
  assert_eq(@rx.Itor::from_array([3, 1, 4, 2]).maximum(), Some(4))
  assert_eq(@rx.Itor::from_array([3, 1, 4, 2]).minimum(), Some(1))
  let empty : Array[Int] = []
  if @rx.Itor::from_array(empty).maximum() is Some(_) {
    assert_true(false)
  }
  if @rx.Itor::from_array(empty).minimum() is Some(_) {
    assert_true(false)
  }
}

///|
test "haskell-itor: head / last 首尾" {
  assert_eq(@rx.Itor::from_array([1, 2, 3]).head(), Some(1))
  assert_eq(@rx.Itor::from_array([1, 2, 3]).last(), Some(3))
  let empty : Array[Int] = []
  if @rx.Itor::from_array(empty).head() is Some(_) {
    assert_true(false)
  }
  if @rx.Itor::from_array(empty).last() is Some(_) {
    assert_true(false)
  }
}

///|
test "haskell-itor: to_array 收集" {
  let gen = @rx.Itor::from_array([1, 2, 3])
  assert_eq(gen.to_array(), [1, 2, 3])
}

///|
test "haskell-itor: lookup 关联查找" {
  let gen = @rx.Itor::from_array([(1, "a"), (2, "b")])
  assert_eq(
    gen.lookup(2, fn(p : (Int, String)) { p.0 }, fn(p : (Int, String)) { p.1 }),
    Some("b"),
  )
}

///|
test "haskell-itor: lookup 找不到返回 None" {
  let gen = @rx.Itor::from_array([(1, "a")])
  let r = gen.lookup(9, fn(p : (Int, String)) { p.0 }, fn(p : (Int, String)) { p.1 })
  if r is Some(_) {
    assert_true(false)
  }
}

///|
test "haskell-itor: elem_index / elem_indices" {
  assert_eq(@rx.Itor::from_array([5, 6, 7]).elem_index(6), Some(1L))
  let r = @rx.Itor::from_array([5, 6, 7]).elem_index(9)
  if r is Some(_) {
    assert_true(false)
  }
  assert_eq(@rx.Itor::from_array([2, 3, 2, 4, 2]).elem_indices(2), [0, 2, 4])
}

///|
test "haskell-itor: find_indices 满足谓词下标" {
  assert_eq(
    @rx.Itor::from_array([10, 21, 32, 43]).find_indices(fn(x : Int) { x % 2 == 1 }),
    [1, 3],
  )
}

///|
test "haskell-itor: map_accum_l 左累积映射" {
  // 累积和，输出翻倍值
  let (acc, out) = @rx.Itor::from_array([1, 2, 3]).map_accum_l(0, fn(
    acc : Int,
    x : Int,
  ) -> (Int, Int) {
    (acc + x, (acc + x) * 2)
  })
  assert_eq(acc, 6)
  assert_eq(out, [2, 6, 12])
}

///|
test "haskell-itor: map_accum_r 右累积映射" {
  // Haskell: mapAccumR f 0 [1,2,3]，f x acc = (x+acc, x+acc)
  // (y3,z1)=f 3 0=(3,3); (y2,z2)=f 2 3=(5,5); (y1,z3)=f 1 5=(6,6)
  // 结果 (6, [6,5,3])
  let (acc, out) = @rx.Itor::from_array([1, 2, 3]).map_accum_r(0, fn(
    x : Int,
    acc : Int,
  ) -> (Int, Int) {
    (x + acc, x + acc)
  })
  assert_eq(acc, 6)
  assert_eq(out, [6, 5, 3])
}

///|
test "haskell-itor: partition 满足与不满足两路" {
  let (yes, no) = @rx.Itor::from_array([1, 2, 3, 4, 5]).partition(fn(x : Int) { x % 2 == 0 })
  assert_eq(yes, [2, 4])
  assert_eq(no, [1, 3, 5])
}

///|
test "haskell-itor: span 前缀与剩余" {
  let (prefix, rest) = @rx.Itor::from_array([1, 2, 3, 1, 4]).span(fn(x : Int) { x < 3 })
  assert_eq(prefix, [1, 2])
  assert_eq(rest, [3, 1, 4])
}

///|
test "haskell-itor: break_pred 前缀不满足谓词" {
  let (prefix, rest) = @rx.Itor::from_array([1, 2, 3, 1]).break_pred(fn(x : Int) { x > 2 })
  assert_eq(prefix, [1, 2])
  assert_eq(rest, [3, 1])
}

///|
test "haskell-itor: split_at 前 n 与剩余" {
  let (left, right) = @rx.Itor::from_array([1, 2, 3, 4, 5]).split_at(2)
  assert_eq(left, [1, 2])
  assert_eq(right, [3, 4, 5])
}

///|
test "haskell-itor: group_adjacent 相邻相等分组" {
  let groups = @rx.Itor::from_array([1, 1, 2, 2, 2, 3, 1]).group_adjacent()
  assert_eq(groups, [[1, 1], [2, 2, 2], [3], [1]])
}

///|
test "haskell-itor: is_prefix_of / is_suffix_of / is_infix_of" {
  assert_true(@rx.Itor::from_array([1, 2, 3, 4]).is_prefix_of([1, 2]))
  assert_false(@rx.Itor::from_array([1, 2, 3]).is_prefix_of([2, 3]))
  assert_true(@rx.Itor::from_array([1, 2, 3, 4]).is_suffix_of([3, 4]))
  assert_false(@rx.Itor::from_array([1, 2, 3]).is_suffix_of([2, 3, 4]))
  assert_true(@rx.Itor::from_array([1, 2, 3, 4, 5]).is_infix_of([3, 4]))
  assert_false(@rx.Itor::from_array([1, 2, 3]).is_infix_of([2, 1]))
}

///|
test "haskell-itor: inits 全部前缀" {
  let result = @rx.Itor::from_array([1, 2, 3]).inits()
  assert_eq(result, [[], [1], [1, 2], [1, 2, 3]])
}

///|
test "haskell-itor: tails 全部后缀" {
  let result = @rx.Itor::from_array([1, 2, 3]).tails()
  assert_eq(result, [[1, 2, 3], [2, 3], [3], []])
}

///|
test "haskell-itor: concat 展平 Itor[Itor]" {
  let gen = @rx.Itor::from_array([
    @rx.Itor::from_array([1, 2]),
    @rx.Itor::from_array([3]),
    @rx.Itor::from_array([4, 5]),
  ]).concat()
  assert_eq(gen.to_array(), [1, 2, 3, 4, 5])
}

///|
test "haskell-itor: intercalate 数组流插入分隔" {
  let gen = @rx.Itor::from_array([
    [1, 2],
    [3],
    [4, 5],
  ]).intercalate([0])
  assert_eq(gen.to_array(), [1, 2, 0, 3, 0, 4, 5])
}

///|
test "haskell-itor: 变换链组合 map -> filter -> take" {
  let gen = @rx.Itor::from_array([1, 2, 3, 4, 5, 6])
    .map(fn(x : Int) { x * 2 })
    .filter(fn(x : Int) { x > 4 })
    .take(3)
  assert_eq(gen.to_array(), [6, 8, 10])
}

///|
test "haskell-itor: 变换后仍可 stop 终止" {
  let gen = @rx.Itor::from_array([1, 2, 3, 4, 5]).map(fn(x : Int) { x * 10 })
  assert_eq(gen.next(), Some(10))
  ignore(gen.stop())
  assert_eq(gen.next(), None)
  assert_true(gen.is_stopped())
}

///|
test "haskell-itor: 变换后仍可 restart 重放" {
  let gen = @rx.Itor::from_array([1, 2, 3]).map(fn(x : Int) { x * 10 })
  assert_eq(gen.next(), Some(10))
  assert_eq(gen.next(), Some(20))
  ignore(gen.restart())
  // 重放历史 [10, 20] 后继续源剩余 [30]
  let vals : Array[Int] = []
  while true {
    match gen.next() {
      Some(v) => vals.push(v)
      None => break
    }
  }
  assert_eq(vals, [10, 20, 30])
}

// ============================================================================
// 第二批 Haskell Data.List 语义测试
// 覆盖：foldl1/foldr1/all_true/any_true/maximum_by/minimum_by/sort/
// scanl1/scanr/scanr1/strip_prefix/strip_suffix/is_subsequence_of/at/
// nub_by/delete_first/delete_first_by/difference/union/intersect/
// insert/insert_by/group_adjacent_by/transpose/subsequences/permutations/
// chunks_of/fold_map/zip3/zip_with3/unzip/unzip3
// ============================================================================

///|
test "haskell-itor2: foldl1 无种子左折叠" {
  // Haskell: foldl1 (+) [1,2,3,4] = 10
  assert_eq(@rx.Itor::from_array([1, 2, 3, 4]).foldl1(fn(a : Int, b : Int) { a + b }), Some(10))
  // 减法验证方向：foldl1 (-) [1,2,3] = ((1-2)-3) = -4
  assert_eq(@rx.Itor::from_array([1, 2, 3]).foldl1(fn(a : Int, b : Int) { a - b }), Some(-4))
}

///|
test "haskell-itor2: foldl1 空迭代器返回 None" {
  let empty : Array[Int] = []
  let r = @rx.Itor::from_array(empty).foldl1(fn(a : Int, b : Int) { a + b })
  if r is Some(_) {
    assert_true(false)
  }
}

///|
test "haskell-itor2: foldr1 无种子右折叠" {
  // Haskell: foldr1 (-) [1,2,3] = 1-(2-3) = 2
  assert_eq(@rx.Itor::from_array([1, 2, 3]).foldr1(fn(a : Int, b : Int) { a - b }), Some(2))
  // 单元素：返回该元素
  assert_eq(@rx.Itor::from_array([7]).foldr1(fn(a : Int, b : Int) { a + b }), Some(7))
}

///|
test "haskell-itor2: foldr1 空迭代器返回 None" {
  let empty : Array[Int] = []
  let r = @rx.Itor::from_array(empty).foldr1(fn(a : Int, b : Int) { a + b })
  if r is Some(_) {
    assert_true(false)
  }
}

///|
test "haskell-itor2: all_true / any_true 短路判定" {
  assert_true(@rx.Itor::from_array([true, true, true]).all_true())
  assert_false(@rx.Itor::from_array([true, false, true]).all_true())
  assert_true(@rx.Itor::from_array([false, true]).any_true())
  assert_false(@rx.Itor::from_array([false, false]).any_true())
  // 空流：all_true = True，any_true = False
  let empty : Array[Bool] = []
  assert_true(@rx.Itor::from_array(empty).all_true())
  assert_false(@rx.Itor::from_array(empty).any_true())
}

///|
test "haskell-itor2: maximum_by / minimum_by 自定义比较" {
  // 按绝对值求最大
  let max_abs = @rx.Itor::from_array([-5, 3, 2]).maximum_by(fn(a : Int, b : Int) {
    (a * a).compare(b * b)
  })
  assert_eq(max_abs, Some(-5))
  // 按字符串长度求最小
  let min_len = @rx.Itor::from_array(["aaa", "b", "cc"]).minimum_by(fn(a : String, b : String) {
    a.length().compare(b.length())
  })
  assert_eq(min_len, Some("b"))
}

///|
test "haskell-itor2: maximum_by / minimum_by 空迭代器返回 None" {
  let empty : Array[Int] = []
  let r = @rx.Itor::from_array(empty).maximum_by(fn(a : Int, b : Int) { a.compare(b) })
  if r is Some(_) {
    assert_true(false)
  }
}

///|
test "haskell-itor2: sort 默认自然序" {
  assert_eq(
    @rx.Itor::from_array([3, 1, 2, 5, 4]).sort().to_array(),
    [1, 2, 3, 4, 5],
  )
  assert_eq(@rx.Itor::from_array([3, 1]).sort().to_array(), [1, 3])
}

///|
test "haskell-itor2: scanl1 无种子左扫描" {
  // Haskell: scanl1 (+) [1,2,3] = [1,3,6]
  assert_eq(
    @rx.Itor::from_array([1, 2, 3]).scanl1(fn(a : Int, b : Int) { a + b }).to_array(),
    [1, 3, 6],
  )
  // 空迭代器
  let empty : Array[Int] = []
  assert_eq(@rx.Itor::from_array(empty).scanl1(fn(a : Int, b : Int) { a + b }).to_array(), [])
}

///|
test "haskell-itor2: scanr 右扫描" {
  // Haskell: scanr (+) 0 [1,2,3] = [6,5,3,0]
  assert_eq(
    @rx.Itor::from_array([1, 2, 3]).scanr(0, fn(x : Int, acc : Int) { x + acc }).to_array(),
    [6, 5, 3, 0],
  )
  // 减法验证方向：scanr (-) 0 [1,2,3] = [1-(2-(3-0)), 2-(3-0), 3-0, 0] = [2,-1,3,0]
  assert_eq(
    @rx.Itor::from_array([1, 2, 3]).scanr(0, fn(x : Int, acc : Int) { x - acc }).to_array(),
    [2, -1, 3, 0],
  )
  // 空迭代器：只发 seed
  let empty : Array[Int] = []
  assert_eq(@rx.Itor::from_array(empty).scanr(99, fn(x : Int, acc : Int) { x + acc }).to_array(), [99])
}

///|
test "haskell-itor2: scanr1 无种子右扫描" {
  // Haskell: scanr1 (+) [1,2,3] = [6,5,3]
  assert_eq(
    @rx.Itor::from_array([1, 2, 3]).scanr1(fn(a : Int, b : Int) { a + b }).to_array(),
    [6, 5, 3],
  )
  // 减法：scanr1 (-) [1,2,3] = [1-(2-3), 2-3, 3] = [2,-1,3]
  assert_eq(
    @rx.Itor::from_array([1, 2, 3]).scanr1(fn(a : Int, b : Int) { a - b }).to_array(),
    [2, -1, 3],
  )
  // 空迭代器
  let empty : Array[Int] = []
  assert_eq(@rx.Itor::from_array(empty).scanr1(fn(a : Int, b : Int) { a + b }).to_array(), [])
}

///|
test "haskell-itor2: strip_prefix / strip_suffix 剥离前后缀" {
  // Haskell: stripPrefix [1,2] [1,2,3] = Just [3]
  assert_eq(
    @rx.Itor::from_array([1, 2, 3]).strip_prefix([1, 2]),
    Some([3]),
  )
  // 不匹配返回 None
  let r = @rx.Itor::from_array([1, 2, 3]).strip_prefix([2, 3])
  if r is Some(_) {
    assert_true(false)
  }
  // 完全匹配返回空数组
  assert_eq(
    @rx.Itor::from_array([1, 2]).strip_prefix([1, 2]),
    Some([]),
  )
  // strip_suffix
  assert_eq(
    @rx.Itor::from_array([1, 2, 3]).strip_suffix([2, 3]),
    Some([1]),
  )
  let r2 = @rx.Itor::from_array([1, 2, 3]).strip_suffix([1, 2])
  if r2 is Some(_) {
    assert_true(false)
  }
}

///|
test "haskell-itor2: is_subsequence_of 子序列判定" {
  // Haskell: isSubsequenceOf [1,3] [1,2,3] = True（不必连续）
  assert_true(@rx.Itor::from_array([1, 2, 3, 4]).is_subsequence_of([1, 3]))
  assert_true(@rx.Itor::from_array([1, 2, 3]).is_subsequence_of([1, 2, 3]))
  // 顺序不对则 False
  assert_false(@rx.Itor::from_array([1, 2, 3]).is_subsequence_of([3, 1]))
  // 缺失元素 False
  assert_false(@rx.Itor::from_array([1, 2, 3]).is_subsequence_of([1, 4]))
  // 空子序列恒 True
  assert_true(@rx.Itor::from_array([1, 2, 3]).is_subsequence_of([]))
}

///|
test "haskell-itor2: at 按下标取元素" {
  // Haskell: [10,20,30] !! 1 = 20
  assert_eq(@rx.Itor::from_array([10, 20, 30]).at(1), Some(20))
  assert_eq(@rx.Itor::from_array([10, 20, 30]).at(0), Some(10))
  assert_eq(@rx.Itor::from_array([10, 20, 30]).at(2), Some(30))
  // 越界返回 None
  assert_eq(@rx.Itor::from_array([10, 20, 30]).at(3), None)
  assert_eq(@rx.Itor::from_array([10, 20, 30]).at(-1), None)
  // 空迭代器
  let empty : Array[Int] = []
  assert_eq(@rx.Itor::from_array(empty).at(0), None)
}

///|
test "haskell-itor2: nub_by 自定义谓词去重" {
  // 按绝对值去重
  assert_eq(
    @rx.Itor::from_array([1, -1, 2, -2, 1]).nub_by(fn(a : Int, b : Int) { a.abs() == b.abs() }).to_array(),
    [1, 2],
  )
}

///|
test "haskell-itor2: delete_first 删除首个匹配" {
  // Haskell: delete 2 [1,2,3,2] = [1,3,2]
  assert_eq(
    @rx.Itor::from_array([1, 2, 3, 2]).delete_first(2).to_array(),
    [1, 3, 2],
  )
  // 不存在则原样保留
  assert_eq(
    @rx.Itor::from_array([1, 2, 3]).delete_first(9).to_array(),
    [1, 2, 3],
  )
}

///|
test "haskell-itor2: delete_first_by 自定义谓词删除" {
  // 删除第一个绝对值等于 2 的元素（即 -2）
  assert_eq(
    @rx.Itor::from_array([1, -2, 3, 2]).delete_first_by(2, fn(a : Int, t : Int) { a.abs() == t.abs() }).to_array(),
    [1, 3, 2],
  )
}

///|
test "haskell-itor2: difference 列表差集" {
  // Haskell: [1,2,3,2,4] \\ [2,4] = [1,3,2]
  assert_eq(
    @rx.Itor::from_array([1, 2, 3, 2, 4]).difference([2, 4]),
    [1, 3, 2],
  )
  // 完全移除
  assert_eq(
    @rx.Itor::from_array([1, 2, 3]).difference([1, 2, 3]),
    [],
  )
}

///|
test "haskell-itor2: union 并集" {
  // Haskell: union [1,2,3] [2,3,4,4] = [1,2,3,4]
  assert_eq(
    @rx.Itor::from_array([1, 2, 3]).union([2, 3, 4, 4]),
    [1, 2, 3, 4],
  )
}

///|
test "haskell-itor2: intersect 交集" {
  // Haskell: intersect [1,2,3,4] [2,4,5] = [2,4]
  assert_eq(
    @rx.Itor::from_array([1, 2, 3, 4]).intersect([2, 4, 5]),
    [2, 4],
  )
  // 空交集
  assert_eq(
    @rx.Itor::from_array([1, 2]).intersect([3, 4]),
    [],
  )
}

///|
test "haskell-itor2: insert 有序插入" {
  // Haskell: insert 3 [1,2,4,5] = [1,2,3,4,5]
  assert_eq(
    @rx.Itor::from_array([1, 2, 4, 5]).insert(3).to_array(),
    [1, 2, 3, 4, 5],
  )
  // 插入到开头
  assert_eq(
    @rx.Itor::from_array([2, 3]).insert(1).to_array(),
    [1, 2, 3],
  )
  // 插入到末尾
  assert_eq(
    @rx.Itor::from_array([1, 2]).insert(9).to_array(),
    [1, 2, 9],
  )
  // 空迭代器
  let empty : Array[Int] = []
  assert_eq(@rx.Itor::from_array(empty).insert(5).to_array(), [5])
}

///|
test "haskell-itor2: insert_by 自定义比较插入" {
  // 输入流须已按比较序排好：[2, -3, 5]（绝对值序 2 < 3 < 5）
  // 插入 -1（绝对值 1）：应排最前
  assert_eq(
    @rx.Itor::from_array([2, -3, 5]).insert_by(fn(a : Int, b : Int) { a.abs().compare(b.abs()) }, -1).to_array(),
    [-1, 2, -3, 5],
  )
  // 插入绝对值最大的 9：应排末尾
  assert_eq(
    @rx.Itor::from_array([2, -3, 5]).insert_by(fn(a : Int, b : Int) { a.abs().compare(b.abs()) }, 9).to_array(),
    [2, -3, 5, 9],
  )
}

///|
test "haskell-itor2: group_adjacent_by 自定义谓词分组" {
  // 按奇偶分组（相邻同奇偶为一组）
  let groups = @rx.Itor::from_array([1, 3, 2, 4, 5]).group_adjacent_by(fn(a : Int, b : Int) {
    (a % 2) == (b % 2)
  })
  assert_eq(groups, [[1, 3], [2, 4], [5]])
}

///|
test "haskell-itor2: transpose 转置" {
  // Haskell: transpose [[1,2,3],[4,5,6]] = [[1,4],[2,5],[3,6]]
  assert_eq(
    @rx.Itor::from_array([[1, 2, 3], [4, 5, 6]]).transpose(),
    [[1, 4], [2, 5], [3, 6]],
  )
  // 不等长：短行缺失列跳过
  assert_eq(
    @rx.Itor::from_array([[1, 2], [3]]).transpose(),
    [[1, 3], [2]],
  )
}

///|
test "haskell-itor2: subsequences 子序列枚举" {
  // Haskell: subsequences [1,2] = [[],[1],[2],[1,2]]
  let subs = @rx.Itor::from_array([1, 2]).subsequences()
  assert_eq(subs.length(), 4)
  assert_eq(subs[0], [])
  assert_eq(subs[3], [1, 2])
  // 3 个元素共 8 个子序列
  assert_eq(@rx.Itor::from_array([1, 2, 3]).subsequences().length(), 8)
}

///|
test "haskell-itor2: permutations 排列枚举" {
  // 3 个元素共 6 个排列
  let perms = @rx.Itor::from_array([1, 2, 3]).permutations()
  assert_eq(perms.length(), 6)
  // 每个排列都是原数组的一个重排（元素和为 6，长度 3）
  for p in perms {
    assert_eq(p.length(), 3)
    assert_eq(p[0] + p[1] + p[2], 6)
  }
  // 单元素
  assert_eq(@rx.Itor::from_array([7]).permutations(), [[7]])
}

///|
test "haskell-itor2: chunks_of 按大小分块" {
  // chunksOf 3 [1..7] = [[1,2,3],[4,5,6],[7]]
  assert_eq(
    @rx.Itor::from_array([1, 2, 3, 4, 5, 6, 7]).chunks_of(3).to_array(),
    [[1, 2, 3], [4, 5, 6], [7]],
  )
  // n 超过长度：整块
  assert_eq(
    @rx.Itor::from_array([1, 2]).chunks_of(5).to_array(),
    [[1, 2]],
  )
  // 空迭代器
  let empty : Array[Int] = []
  assert_eq(@rx.Itor::from_array(empty).chunks_of(3).to_array(), [])
}

///|
test "haskell-itor2: fold_map 映射折叠" {
  // foldMap：每个元素平方后求和
  let total = @rx.Itor::from_array([1, 2, 3]).fold_map(0, fn(x : Int) { x * x }, fn(
    acc : Int,
    v : Int,
  ) {
    acc + v
  })
  assert_eq(total, 14)
  // 空迭代器返回 seed
  let empty : Array[Int] = []
  assert_eq(@rx.Itor::from_array(empty).fold_map(5, fn(x : Int) { x }, fn(acc : Int, v : Int) { acc + v }), 5)
}

///|
test "haskell-itor2: zip3 三路配对" {
  assert_eq(
    @rx.Itor::from_array([1, 2, 3])
      .zip3(@rx.Itor::from_array(["a", "b", "c"]), @rx.Itor::from_array([true, false, true]))
      .to_array(),
    [(1, "a", true), (2, "b", false), (3, "c", true)],
  )
  // 任一方耗尽提前结束
  assert_eq(
    @rx.Itor::from_array([1, 2, 3])
      .zip3(@rx.Itor::from_array(["a"]), @rx.Itor::from_array([true, false]))
      .to_array(),
    [(1, "a", true)],
  )
}

///|
test "haskell-itor2: zip_with3 三路合并" {
  assert_eq(
    @rx.Itor::from_array([1, 2, 3])
      .zip_with3(
        @rx.Itor::from_array([10, 20, 30]),
        @rx.Itor::from_array([100, 200, 300]),
        fn(a : Int, b : Int, c : Int) { a + b + c },
      )
      .to_array(),
    [111, 222, 333],
  )
}

///|
test "haskell-itor2: unzip 拆分二元组" {
  let (as_, bs) = @rx.Itor::from_array([(1, "a"), (2, "b"), (3, "c")]).unzip()
  assert_eq(as_, [1, 2, 3])
  assert_eq(bs, ["a", "b", "c"])
}

///|
test "haskell-itor2: unzip3 拆分三元组" {
  let (as_, bs, cs) = @rx.Itor::from_array([(1, "a", true), (2, "b", false)]).unzip3()
  assert_eq(as_, [1, 2])
  assert_eq(bs, ["a", "b"])
  assert_eq(cs, [true, false])
}

///|
test "haskell-itor2: 新增变换操作链式组合" {
  // sort -> chunks_of -> zip 组合
  let result = @rx.Itor::from_array([5, 3, 1, 4, 2])
    .sort()
    .chunks_of(2)
    .zip(@rx.Itor::from_array(["a", "b", "c"]))
    .to_array()
  assert_eq(result, [([1, 2], "a"), ([3, 4], "b"), ([5], "c")])
}
