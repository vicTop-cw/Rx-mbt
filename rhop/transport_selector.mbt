// ============================================================================
// rhop · 通道选择（在线优先，离线回退 shared path）
//
// 对照 vools.rhop.transport.selector：
//   按序探测在线通道，任一可用即选它；否则回退 shared path；
//   两者都不可用时给出**可诊断**的原因（哪条通道试过、shared 为何不可达）。
//
// 目标说明：纯逻辑，三目标（wasm / js / native）通用。
// ============================================================================

///|
/// 按序探测在线通道；任一可用则选在线，否则回退 shared path。
///
/// - `online` 空数组 ⇒ 不探测，直接看 shared；
/// - `shared` 为 None ⇒ 没有兜底介质（此时若在线也全不可用，返回 transport="none"）；
/// - `available()` 抛错/返回 false 都按「不可用」处理，绝不中断选择流程。
pub fn select_transport(
  online : Array[&OnlineChannel],
  shared : &SharedPath?,
) -> TransportSelection {
  let tried : Array[String] = []
  for ch in online {
    let nm = OnlineChannel::name(ch)
    let ok = OnlineChannel::available(ch)
    tried.push("\{nm}=\{if ok { "up" } else { "down" }}")
    if ok {
      return TransportSelection::new(
        "online",
        nm,
        true,
        "在线通道可用: " + nm,
      )
    }
  }
  let tried_s = if tried.length() == 0 {
    "(无在线通道)"
  } else {
    tried.join(", ")
  }
  match shared {
    None =>
      TransportSelection::new(
        "none",
        "",
        false,
        "无可用通道：没有在线通道也没有 shared path（探测: " +
        tried_s +
        "）",
      )
    Some(sp) => {
      let nm = SharedPath::name(sp)
      let ok = SharedPath::available(sp)
      if ok {
        TransportSelection::new(
          "shared",
          nm,
          false,
          "在线通道均不可用，回退 shared path: " +
          nm +
          "（探测: " +
          tried_s +
          "）",
        )
      } else {
        TransportSelection::new(
          "none",
          nm,
          false,
          "在线通道均不可用且 shared path 不可达: " +
          nm +
          "（探测: " +
          tried_s +
          "）",
        )
      }
    }
  }
}

///|
/// 仅探测在线通道是否至少有一条可用（不产生选择结果，供探活/降级判断复用）。
pub fn any_online_available(online : Array[&OnlineChannel]) -> Bool {
  for ch in online {
    if OnlineChannel::available(ch) {
      return true
    }
  }
  false
}
