///|
test "probe: 枚举变体引用方式" {
  let a = @rx.ItorState::Stopped
  let b : @rx.ItorState = @rx.ItorState::Pending
  let c = @rx.ItorState::Paused
  let d = @rx.ItorState::Iterring
  assert_true(
    a == @rx.ItorState::Stopped && b == @rx.ItorState::Pending &&
    c == @rx.ItorState::Paused && d == @rx.ItorState::Iterring,
  )
}
