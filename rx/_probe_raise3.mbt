// 验证：raise 匿名函数能否作为非 raise 回调传递（验证后删除）
priv suberror RxProbe3 {
  RxProbe3
}

///|
test "rxprobe3: raise 函数作为回调" {
  let mut sum = 0
  // 尝试：fn(v : Int) raise 赋值给普通回调
  let cb : (Int) -> Unit = fn(v : Int) raise {
    if v > 3 {
      raise RxProbe3::RxProbe3
    }
    sum = sum + v
  }
  try {
    cb(1)
    cb(5)
  } catch {
    RxProbe3::RxProbe3 => ()
  }
  assert_eq(sum, 1)
}
