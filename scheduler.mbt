// ============================================================================
// 调度器：CurrentThreadScheduler / ImmediateScheduler / AsyncScheduler /
// ThreadPoolScheduler
//
// 说明：MoonBit 稳定版标准库无线程/异步运行时（wasm 目标），调度器以
// 同步语义 + 虚拟时钟（Clock）等价实现：`now()` 返回虚拟时间，
// `schedule()` 立即同步执行任务。ThreadPoolScheduler 保留线程数参数，
// 但实际仍在当前线程立即执行（与 Rx-Rust 签名对齐）。
// ============================================================================

/// 当前线程调度器：任务在订阅者所在线程立即执行
pub struct CurrentThreadScheduler {
  clock : Clock
}

/// 创建当前线程调度器（使用默认虚拟时钟）
pub fn CurrentThreadScheduler::new() -> CurrentThreadScheduler {
  { clock: default_clock }
}

/// 创建指定虚拟时钟的当前线程调度器
pub fn CurrentThreadScheduler::with_clock(clock : Clock) -> CurrentThreadScheduler {
  { clock: clock }
}

/// 当前虚拟时间（毫秒）
pub fn CurrentThreadScheduler::now(self : CurrentThreadScheduler) -> Int64 {
  self.clock.now()
}

/// 立即同步执行任务（同步模型下任务不排队、不延迟）
pub fn CurrentThreadScheduler::schedule(
  _self : CurrentThreadScheduler,
  task : () -> Unit,
) -> Unit {
  task()
}

/// 立即调度器：与 CurrentThreadScheduler 语义一致（任务立即执行）
pub struct ImmediateScheduler {
  clock : Clock
}

/// 创建立即调度器（使用默认虚拟时钟）
pub fn ImmediateScheduler::new() -> ImmediateScheduler {
  { clock: default_clock }
}

/// 创建指定虚拟时钟的立即调度器
pub fn ImmediateScheduler::with_clock(clock : Clock) -> ImmediateScheduler {
  { clock: clock }
}

/// 当前虚拟时间（毫秒）
pub fn ImmediateScheduler::now(self : ImmediateScheduler) -> Int64 {
  self.clock.now()
}

/// 立即同步执行任务
pub fn ImmediateScheduler::schedule(
  _self : ImmediateScheduler,
  task : () -> Unit,
) -> Unit {
  task()
}

/// 异步调度器：同步模型下任务仍立即执行（保留 Rx-Rust 签名）
pub struct AsyncScheduler {
  clock : Clock
}

/// 创建异步调度器（使用默认虚拟时钟）
pub fn AsyncScheduler::new() -> AsyncScheduler {
  { clock: default_clock }
}

/// 创建指定虚拟时钟的异步调度器
pub fn AsyncScheduler::with_clock(clock : Clock) -> AsyncScheduler {
  { clock: clock }
}

/// 当前虚拟时间（毫秒）
pub fn AsyncScheduler::now(self : AsyncScheduler) -> Int64 {
  self.clock.now()
}

/// 同步模型下立即执行任务
pub fn AsyncScheduler::schedule(
  _self : AsyncScheduler,
  task : () -> Unit,
) -> Unit {
  task()
}

/// 线程池调度器：保留线程数参数（同步模型下实际仍单线程立即执行）
pub struct ThreadPoolScheduler {
  clock : Clock
  num_threads : Int
}

/// 创建线程池调度器（默认 2 个工作线程，同步模型下不实际生效）
pub fn ThreadPoolScheduler::new() -> ThreadPoolScheduler {
  { clock: default_clock, num_threads: 2 }
}

/// 创建指定线程数的线程池调度器
pub fn ThreadPoolScheduler::with_threads(num_threads : Int) -> ThreadPoolScheduler {
  {
    clock: default_clock,
    num_threads: if num_threads < 1 { 1 } else { num_threads },
  }
}

/// 创建指定虚拟时钟和线程数的线程池调度器
pub fn ThreadPoolScheduler::with_clock(
  clock : Clock,
  num_threads : Int,
) -> ThreadPoolScheduler {
  {
    clock: clock,
    num_threads: if num_threads < 1 { 1 } else { num_threads },
  }
}

/// 当前虚拟时间（毫秒）
pub fn ThreadPoolScheduler::now(self : ThreadPoolScheduler) -> Int64 {
  self.clock.now()
}

/// 工作线程数
pub fn ThreadPoolScheduler::get_num_threads(self : ThreadPoolScheduler) -> Int {
  self.num_threads
}

/// 同步模型下立即执行任务（不实际分发到工作线程）
pub fn ThreadPoolScheduler::schedule(
  _self : ThreadPoolScheduler,
  task : () -> Unit,
) -> Unit {
  task()
}
