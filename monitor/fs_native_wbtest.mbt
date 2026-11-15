///|
test "stub" {
  // fs_read_text is defined in fs_native.mbt (same package, gated to native)
  let result = fs_read_text("/tmp/test.txt")
  match result {
    Err(_) => ()
    Ok(_) => fail("expected error")
  }
}
