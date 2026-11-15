// ============================================================================
// 真实时钟时间操作符（R1，PLAN-mcp-watcher-apis.md 阶段2）
// 依赖 moonbitlang/async（@async.sleep / @async.now）实现 native/js 真实定时：
//   - install_real_clock()：注入真实墙钟（real_now 切换为真实时间语义）
//   - drive_real_clock(tick_ms)：async 驱动循环，每个真实 tick 把墙钟增量
//     推进到 default_clock（每次 tick 调用 default_clock.advance(墙钟增量)）
//   - real_interval / real_timer / debounce_real / throttle_real：桥接现有
//     interval_on / timer_on / debounce_on / throttle_on（挂在 default_clock 上），
//     安装并驱动真实时钟后即按真实时间工作；未安装时等价虚拟算子
//     （advance_time 驱动），保证既有确定性测试路径不变。
//
// 平台回退策略：
//   - native / js：@async.now() 为单调毫秒墙钟、@async.sleep() 为真实定时，走真实路径；
//   - wasm：async 的 sleep 为 abort 桩（无真实定时器），drive_real_clock 退化为
//     no-op，install_real_clock 仍可注入墙钟（@async.now 在 wasm 可用）但驱动循环
//     不运行，真实算子回退虚拟路径（由 advance_time / Clock::advance 手动驱动）。
// ============================================================================

///|
/// 真实时钟状态：是否已注入真实墙钟（install_real_clock / install_real_clock_with）
let real_clock_enabled : Ref[Bool] = Ref::Ref(false)

///|
/// 墙钟源（可注入）：默认取默认虚拟时钟（占位）；安装后取真实墙钟 @async.now()
let wall_now_fn : Ref[() -> Int64] = Ref::Ref(fn() { default_clock.now() })

///|
/// 上次真实 tick 记录的墙钟时刻（毫秒），用于计算每次 tick 的墙钟增量
let last_wall_ms : Ref[Int64] = Ref::Ref(0L)

///|
/// 当前墙钟时刻：安装真实时钟后为真实墙钟（@async.now，单调毫秒）；
/// 未安装时为默认虚拟时钟当前值（占位，保持既有确定性测试语义不变）
fn wall_now() -> Int64 {
  (wall_now_fn.val)()
}

///|
/// 注入真实墙钟：启用真实时钟模式，此后 real_now() / EventBus::publish 默认 at
/// 使用真实墙钟时间。真实定时驱动需在 async 上下文（async main / async test /
/// task group）中运行 drive_real_clock(tick_ms) 后台循环：
/// 每个真实 tick 把墙钟增量推进到 default_clock，桥接既有时间算子。
/// native / js 使用 moonbitlang/async 的单调毫秒时钟；wasm 下仅注入墙钟
/// 读数（@async.now 可用），驱动循环回退虚拟路径（见 drive_real_clock）。
pub fn install_real_clock() -> Unit {
  real_clock_enabled.val = true
  wall_now_fn.val = fn() { @async.now() }
  last_wall_ms.val = wall_now()
}

///|
/// 可控 RealClock 注入（测试用）：把墙钟源替换为可手动推进的 Clock。
/// 此后 real_now() 返回该墙钟当前时刻；调用 real_clock_tick() 把墙钟增量
/// 推进到 default_clock（桥接虚拟定时器）。不依赖真实时间，完全确定。
pub fn install_real_clock_with(wall : Clock) -> Unit {
  real_clock_enabled.val = true
  wall_now_fn.val = fn() { wall.now() }
  last_wall_ms.val = wall.now()
}

///|
/// 移除真实时钟注入，恢复占位虚拟路径（测试隔离用）。
/// 未注入时 real_now() 等价 default_clock.now()。
pub fn uninstall_real_clock() -> Unit {
  real_clock_enabled.val = false
  wall_now_fn.val = fn() { default_clock.now() }
  last_wall_ms.val = 0L
}

///|
/// 单次真实 tick：把墙钟增量推进到 default_clock（驱动循环每次迭代执行一次）。
/// 供可控注入测试手动调用；增量非正时跳过（墙钟未前进则不推进）。
pub fn real_clock_tick() -> Unit {
  let wall = wall_now()
  let delta = wall - last_wall_ms.val
  last_wall_ms.val = wall
  if delta > 0L {
    default_clock.advance(delta)
  }
}

///|
/// 真实时钟驱动循环（async）：每 tick_ms 真实毫秒执行一次 real_clock_tick()，
/// 把墙钟增量推进到 default_clock，使挂在 default_clock 上的时间算子真实化。
/// max_ticks 用于测试限定迭代次数（默认 -1 为无限循环）；
/// 需在 async 上下文（async main / async test / task group）中作为后台任务运行。
#cfg(not(target="wasm"))
pub async fn drive_real_clock(
  tick_ms : Int64,
  max_ticks~ : Int64 = -1L,
) -> Unit {
  let mut ticks = 0L
  while max_ticks < 0L || ticks < max_ticks {
    @async.sleep(tick_ms.to_int())
    real_clock_tick()
    ticks = ticks + 1L
  }
}

///|
/// wasm 回退实现：async 无真实定时器（@async.sleep 为 abort 桩），驱动循环
/// 退化为 no-op，真实算子回退虚拟路径（由 advance_time / Clock::advance 驱动）。
/// 注：wasm 后端不支持 async 语义，本分支为普通函数（签名与 async 分支对齐）。
#cfg(target="wasm")
pub fn drive_real_clock(_tick_ms : Int64, max_ticks~ : Int64 = -1L) -> Unit {
  // wasm：无真实定时器，不推进 default_clock（虚拟路径由 advance_time 驱动）
  let _ = max_ticks
}

// ----------------------------------------------------------------------------
// 真实时钟创建类算子
// ----------------------------------------------------------------------------

///|
/// real_interval：真实墙钟每 ms 毫秒发射自增整数（0, 1, 2, ...），冷 Observable。
/// 等价 interval_on(default_clock, ms)：安装真实时钟并在 async 上下文运行
/// drive_real_clock 后按真实时间发射；未安装时等同虚拟 interval（advance_time 驱动）。
pub fn real_interval(ms : Int64) -> Observable[Int64, Unit] {
  interval_on(default_clock, ms)
}

///|
/// real_timer：真实延迟 ms 毫秒后发射 0 并完成。
/// 安装真实时钟并驱动后按真实时间触发；未安装时等同虚拟 timer（advance_time 驱动）。
pub fn real_timer(ms : Int64) -> Observable[Int64, Unit] {
  timer_on(default_clock, ms)
}

///|
/// debounce_real：真实墙钟防抖，值停止发射 ms 毫秒后发出最后一个值。
/// 桥接 debounce_on(default_clock, ms)，安装真实时钟并驱动后即真实化；
/// 未安装时等同虚拟 debounce（advance_time 驱动）。
pub fn[T, E] Observable::debounce_real(
  self : Observable[T, E],
  ms : Int64,
) -> Observable[T, E] {
  self.debounce_on(default_clock, ms)
}

///|
/// throttle_real：真实墙钟节流，每 ms 毫秒最多放行一个值。
/// 桥接 throttle_on(default_clock, ms)，安装真实时钟并驱动后即真实化；
/// 未安装时等同虚拟 throttle（advance_time 驱动）。
pub fn[T, E] Observable::throttle_real(
  self : Observable[T, E],
  ms : Int64,
) -> Observable[T, E] {
  self.throttle_on(default_clock, ms)
}
