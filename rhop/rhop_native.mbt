// ============================================================================
// rhop · native 目标占位
// 与 monitor 一致：MoonBit core 无文件系统 API，native 目标的文件监控与
// 读写暂不可用（js 目标为完整实现）。AES 密码学也依赖 node crypto，
// native 下请使用 RhopCipherNone（纯 MoonBit base64）。
// ============================================================================

///|
/// 发送 RHOP 消息。native 目标暂不可用（无文件系统 API）。
pub fn[T : RhopCipher] rhop_send(
  shared_path : String,
  filename : String,
  packet : RhopPacket,
  cipher : T,
) -> Unit {
  let _ = (shared_path, filename, packet, cipher)
  println(
    "rhop_send: native 目标暂不可用（MoonBit core 无文件系统 API），请使用 js 目标",
  )
}

///|
/// 监控 shared path。native 目标暂不可用。
pub fn[T : RhopCipher] from_filesystem(
  shared_path : String,
  cipher : T,
) -> @rx.Observable[RhopPacket, String] {
  from_filesystem_with(shared_path, cipher, false)
}

///|
/// from_filesystem 带参版本；native 目标暂不可用。
pub fn[T : RhopCipher] from_filesystem_with(
  shared_path : String,
  cipher : T,
  skip_existing : Bool,
) -> @rx.Observable[RhopPacket, String] {
  let _ = (shared_path, cipher, skip_existing)
  @rx.Observable::new(fn(
    observer : @rx.Observer[RhopPacket, String],
  ) -> @rx.Subscription {
    observer.on_error(
      "from_filesystem: native 目标暂不可用（MoonBit core 无文件系统 API），请使用 js 目标",
    )
    @rx.Subscription::empty()
  })
}
