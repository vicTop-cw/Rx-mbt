///|
test "probe: 枚举变体引用" {
  let s = @rx.Itor::from_array([1])
  let _ = s.next()
  let st = s.state()
  ignore(st)
  assert_true(true)
}
