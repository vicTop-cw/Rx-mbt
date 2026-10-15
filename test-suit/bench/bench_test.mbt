// 基准测试：与 Rx-Rust benches/bench.rs 对齐的 5 个核心操作
// 运行：moon test -g "bench" （或直接 moon test，带 #skip 默认跳过）
// 结果写入目标目录下的 moon_bench.json 便于对比

///|
#skip("slow tests")
test "bench: map 10 万元素" {
  let data = Array::make(100_000, 0)
  let mut i = 0
  while i < 100_000 {
    data[i] = i
    i = i + 1
  }
  let summary = @bench_core.single_bench(
    name="mbt_map_100k",
    fn() {
      let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
      let src : @rx.Observable[Int, Unit] = @rx.Observable::from_iter(data)
      let _ = src.map(fn(x : Int) { x * 2 }).subscribe_on_next(
        fn(v : Int) { values.val.push(v) },
      )
    },
    count=20,
  )
  let json = @json.to_json(summary).stringify()
  println("mbt_map_100k: \{json}")
  assert_true(json.length() > 0)
}

///|
#skip("slow tests")
test "bench: filter 10 万元素" {
  let data = Array::make(100_000, 0)
  let mut i = 0
  while i < 100_000 {
    data[i] = i
    i = i + 1
  }
  let summary = @bench_core.single_bench(
    name="mbt_filter_100k",
    fn() {
      let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
      let src : @rx.Observable[Int, Unit] = @rx.Observable::from_iter(data)
      let _ = src.filter(fn(x : Int) { x % 2 == 0 }).subscribe_on_next(
        fn(v : Int) { values.val.push(v) },
      )
    },
    count=20,
  )
  let json = @json.to_json(summary).stringify()
  println("mbt_filter_100k: \{json}")
  assert_true(json.length() > 0)
}

///|
#skip("slow tests")
test "bench: reduce 10 万元素" {
  let data = Array::make(100_000, 0)
  let mut i = 0
  while i < 100_000 {
    data[i] = i
    i = i + 1
  }
  let summary = @bench_core.single_bench(
    name="mbt_reduce_100k",
    fn() {
      let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
      let src : @rx.Observable[Int, Unit] = @rx.Observable::from_iter(data)
      let _ = src.reduce(0, fn(acc : Int, v : Int) { acc + v }).subscribe_on_next(
        fn(v : Int) { values.val.push(v) },
      )
    },
    count=20,
  )
  let json = @json.to_json(summary).stringify()
  println("mbt_reduce_100k: \{json}")
  assert_true(json.length() > 0)
}

///|
#skip("slow tests")
test "bench: scan 10 万元素" {
  let data = Array::make(100_000, 0)
  let mut i = 0
  while i < 100_000 {
    data[i] = i
    i = i + 1
  }
  let summary = @bench_core.single_bench(
    name="mbt_scan_100k",
    fn() {
      let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
      let src : @rx.Observable[Int, Unit] = @rx.Observable::from_iter(data)
      let _ = src.scan(0, fn(acc : Int, v : Int) { acc + v }).subscribe_on_next(
        fn(v : Int) { values.val.push(v) },
      )
    },
    count=20,
  )
  let json = @json.to_json(summary).stringify()
  println("mbt_scan_100k: \{json}")
  assert_true(json.length() > 0)
}

///|
#skip("slow tests")
test "bench: map+filter+take 链" {
  let data = Array::make(100_000, 0)
  let mut i = 0
  while i < 100_000 {
    data[i] = i
    i = i + 1
  }
  let summary = @bench_core.single_bench(
    name="mbt_chain_100k",
    fn() {
      let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
      let src : @rx.Observable[Int, Unit] = @rx.Observable::from_iter(data)
      let _ = src
        .map(fn(x : Int) { x * 2 })
        .filter(fn(x : Int) { x % 4 == 0 })
        .take(100)
        .subscribe_on_next(fn(v : Int) { values.val.push(v) })
    },
    count=20,
  )
  let json = @json.to_json(summary).stringify()
  println("mbt_chain_100k: \{json}")
  assert_true(json.length() > 0)
}

///|
#skip("slow tests")
test "bench: zip 2x5 万元素" {
  let a = Array::make(50_000, 0)
  let b = Array::make(50_000, 0)
  let mut i = 0
  while i < 50_000 {
    a[i] = i
    b[i] = i
    i = i + 1
  }
  let summary = @bench_core.single_bench(
    name="mbt_zip_50k",
    fn() {
      let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
      let a_obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter(a)
      let b_obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter(b)
      let src = @rx.Observable::zip(a_obs, b_obs)
      let _ = src.subscribe_on_next(fn(v : (Int, Int)) { values.val.push(v.0) })
    },
    count=20,
  )
  let json = @json.to_json(summary).stringify()
  println("mbt_zip_50k: \{json}")
  assert_true(json.length() > 0)
}

///|
#skip("slow tests")
test "bench: merge 2x5 万元素" {
  let a = Array::make(50_000, 0)
  let b = Array::make(50_000, 0)
  let mut i = 0
  while i < 50_000 {
    a[i] = i
    b[i] = i
    i = i + 1
  }
  let summary = @bench_core.single_bench(
    name="mbt_merge_50k",
    fn() {
      let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
      let a_obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter(a)
      let b_obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter(b)
      let src = @rx.Observable::merge(a_obs, b_obs)
      let _ = src.subscribe_on_next(fn(v : Int) { values.val.push(v) })
    },
    count=20,
  )
  let json = @json.to_json(summary).stringify()
  println("mbt_merge_50k: \{json}")
  assert_true(json.length() > 0)
}
