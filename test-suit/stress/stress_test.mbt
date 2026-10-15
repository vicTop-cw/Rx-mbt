// 高压测试（Stress）：大数组、长操作符链、多订阅、Subject 高压
// Blackbox 视角：只使用公开 API

///|
test "stress: 10 万元素 map+filter+reduce 链" {
  let data = Array::make(100_000, 0)
  let mut i = 0
  while i < 100_000 {
    data[i] = i
    i = i + 1
  }
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter(data)
    .map(fn(v : Int) { v * 2 })
    .filter(fn(v : Int) { v % 4 == 0 })
    .reduce(0, fn(acc : Int, v : Int) { acc + v })
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  // 0..100000 中 v*2 % 4 == 0 → v 为偶数；偶数和 = 2*Σ(0..50000) = 2 * 49999*50000/2 = 2_499_950_000
  assert_eq(values.val.length(), 1)
  assert_eq(values.val[0], 4 * 49999 * 50000 / 2)
}

///|
test "stress: 5 万元素 take_while + skip_while + count" {
  let data = Array::make(50_000, 0)
  let mut i = 0
  while i < 50_000 {
    data[i] = i
    i = i + 1
  }
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter(data)
    .skip_while(fn(v : Int) { v < 10_000 })
    .take_while(fn(v : Int) { v < 20_000 })
    .count()
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [10_000])
}

///|
test "stress: 20 个操作符长链（map 连续嵌套）" {
  let data = Array::make(20_000, 0)
  let mut i = 0
  while i < 20_000 {
    data[i] = i
    i = i + 1
  }
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let mut obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter(data)
  // 连续 20 个 map：每个元素乘以 2 共 20 次
  let mut k = 0
  while k < 20 {
    obs = obs.map(fn(v : Int) { v * 2 })
    k = k + 1
  }
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val.length(), 20_000)
  // 2^20 = 1048576 倍
  assert_eq(values.val[0], 0)
  assert_eq(values.val[1], 1048576)
}

///|
test "stress: 多订阅者（一个流 50 个订阅者）" {
  let data = Array::make(10_000, 0)
  let mut i = 0
  while i < 10_000 {
    data[i] = i
    i = i + 1
  }
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter(data).map(fn(v : Int) { v + 1 })
  let total : Ref[Int] = Ref::Ref(0)
  let mut s = 0
  while s < 50 {
    let _ = obs.subscribe_on_next(fn(_v : Int) { total.val = total.val + 1 })
    s = s + 1
  }
  assert_eq(total.val, 10_000 * 50)
}

///|
test "stress: PublishSubject 高压（10 万次 on_next）" {
  let subject : @rx.PublishSubject[Int, Unit] = @rx.PublishSubject::new()
  let count : Ref[Int] = Ref::Ref(0)
  let _ = subject.as_observable().subscribe_on_next(fn(_v : Int) { count.val = count.val + 1 })
  let mut i = 0
  while i < 100_000 {
    subject.on_next(i)
    i = i + 1
  }
  subject.on_completed()
  assert_eq(count.val, 100_000)
}

///|
test "stress: ReplaySubject 缓冲重放（1 万条重放给迟到订阅者）" {
  let subject : @rx.ReplaySubject[Int, Unit] = @rx.ReplaySubject::new()
  let mut i = 0
  while i < 10_000 {
    subject.on_next(i)
    i = i + 1
  }
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let _ = subject.as_observable().subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val.length(), 10_000)
}

///|
test "stress: distinct 处理 5 万重复元素" {
  let data = Array::make(50_000, 7)
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter(data).distinct()
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val.length(), 1)
}

///|
test "stress: to_set + count 大量重复" {
  let data = Array::make(30_000, 0)
  let mut i = 0
  while i < 30_000 {
    data[i] = i % 100
    i = i + 1
  }
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter(data).to_set().map(
    fn(s : @hashset.HashSet[Int]) { s.length() },
  )
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [100])
}

///|
test "stress: 嵌套 flat_map 展开 1 万条" {
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let obs : @rx.Observable[Int, Unit] = @rx.Observable::from_iter([0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
    .flat_map(fn(v : Int) -> @rx.Observable[Int, Unit] {
      let arr = Array::make(1_000, 0)
      let mut j = 0
      while j < 1_000 {
        arr[j] = v
        j = j + 1
      }
      @rx.Observable::from_iter(arr)
    })
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val.length(), 10_000)
}

///|
test "stress: 递归重试 + catch_error 错误路径不泄漏" {
  let attempts = Ref::Ref(0)
  let obs : @rx.Observable[Int, String] = @rx.Observable::new(fn(observer : @rx.Observer[Int, String]) {
    attempts.val = attempts.val + 1
    if attempts.val < 5 {
      observer.on_error("again")
    } else {
      observer.on_next(123)
      observer.on_completed()
    }
    @rx.Subscription::empty()
  }).retry(10).catch_error(fn(_e : String) -> @rx.Observable[Int, String] { @rx.Observable::of(-1) })
  let values : Ref[Array[Int]] = Ref::Ref(Array(capacity=0))
  let _ = obs.subscribe_on_next(fn(v : Int) { values.val.push(v) })
  assert_eq(values.val, [123])
  assert_eq(attempts.val, 5)
}
