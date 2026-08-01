///|
test "probe: ItorState 跨包变体引用" {
  let s : @rx.ItorState = @rx.ItorState::Stopped
  assert_eq(s, @rx.ItorState::Stopped)
}
