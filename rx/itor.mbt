// ============================================================================
// rx/itor.mbt —— 可控制迭代器（Itor）
// 复刻 vools 库（vools/data/itor.py）的 Itor 核心 API：
//   Node（懒加载链表）+ ItorState（状态机）+ Itor（插队/暂停/重启/历史/停止）
// 底层使用 moonbitlang/core 的 Iter[T]（惰性迭代器）作为源。
// 说明：vools 中 `resume` / `do` 为 MoonBit 保留字，此处更名为
//       `resume_iter` / `do_iter`，语义保持一致。
// ============================================================================

/// 链表节点：存储插队值与历史记录值。
///
/// 支持**懒加载**：通过 `from_iter` 从迭代器创建时不会立即展开整条链表，
/// 而是在访问 `next` 时按需生成后续节点；迭代器耗尽后自动接上 `fallback`。
pub struct Node[T] {
  mut val : T
  mut next_field : Node[T]?
  mut iter : Iter[T]? // 懒加载源
  mut fallback : Node[T]? // 懒加载链表的尾后节点
  mut is_replay : Bool // 是否来自历史重放（重放节点不再写入历史）
}

/// 构造一个节点
pub fn[T] Node::new(val : T, next? : Node[T]) -> Node[T] {
  { val: val, next_field: next, iter: None, fallback: None, is_replay: false }
}

/// 获取节点保存的值
pub fn[T] Node::val(self : Node[T]) -> T {
  self.val
}

/// 设置节点保存的值
pub fn[T] Node::set_val(self : Node[T], v : T) -> Unit {
  self.val = v
}

/// 下一个节点。
///
/// 对懒加载节点，首次访问时从底层迭代器取数生成下一个节点；
/// 迭代器耗尽后返回 `fallback`（如果有）。
pub fn[T] Node::next(self : Node[T]) -> Node[T]? {
  match self.next_field {
    Some(_) => self.next_field
    None => {
      match self.iter {
        Some(it) => {
          match it.next() {
            Some(v) => {
              let node : Node[T] = Node::new(v)
              node.iter = Some(it)
              node.fallback = self.fallback
              self.next_field = Some(node)
              self.next_field
            }
            None => {
              // 迭代器耗尽：接上 fallback 并清除懒加载源
              self.next_field = self.fallback
              self.iter = None
              self.fallback = None
              self.next_field
            }
          }
        }
        None => None
      }
    }
  }
}

/// 手动设置下一个节点，同时清除懒加载源。
pub fn[T] Node::set_next(self : Node[T], node : Node[T]?) -> Unit {
  self.next_field = node
  self.iter = None
  self.fallback = None
}

/// 从迭代器构建 Node 链表（懒加载）。
///
/// 返回链表头节点；若迭代器为空则返回 `None`。
pub fn[T] Node::from_iter(iter : Iter[T]) -> Node[T]? {
  match iter.next() {
    Some(v) => {
      let head : Node[T] = Node::new(v)
      head.iter = Some(iter)
      Some(head)
    }
    None => None
  }
}

/// 按链表顺序产出节点保存的值（惰性）。
pub fn[T] Node::to_iter(self : Node[T]) -> Iter[T] {
  let cur : Ref[Node[T]?] = Ref::Ref(Some(self))
  Iter::new(fn() {
    match cur.val {
      Some(node) => {
        cur.val = node.next()
        Some(node.val())
      }
      None => None
    }
  })
}

/// 将当前 Node 链表转换为 Itor 实例。
pub fn[T] Node::to_itor(self : Node[T]) -> Itor[T] {
  Itor::from_iter(self.to_iter())
}

// ============================================================================
// ItorState —— 迭代器内部状态
// ============================================================================

/// Itor 内部状态：
/// - `Pending`: 未开始或已重置，等待首次产出
/// - `Iterring`: 正在迭代中
/// - `Paused`: 已暂停（暂停期间 `next` 不产出）
/// - `Stopped`: 已终止
pub enum ItorState {
  Pending
  Iterring
  Paused
  Stopped
} derive(Eq, Debug)

/// 将派生的 Eq/Debug 方法显式提升为普通方法，消除 implicit_impl_as_method 警告
pub extend ItorState with Eq::{not_equal, equal}
pub extend ItorState with @moonbitlang/core/debug.Debug::{to_repr}

// ============================================================================
// Itor —— 可控制迭代器
// ============================================================================

/// 可控制迭代器：将任意可重复迭代的源包装成支持插队、断点暂停、
/// 历史重放重启与停止控制的迭代器。
///
/// 底层源通过工厂 `() -> Iter[T]` 提供，每次 `copy` 都会重新调用工厂
/// 获得独立的新迭代器（对数组等可重复源，各副本完全独立；对一次性
/// 生成器源，副本间共享底层迭代器，与 vools 一致）。
pub struct Itor[T] {
  source : () -> Iter[T] // 源工厂
  mut iterator : Iter[T]? // 当前活跃迭代器
  mut state : ItorState
  mut dummy : Node[T]? // 哨兵节点，其 next 指向下一个待产出的 Node（插队用）
  mut history_head : Node[T]?
  mut history_tail : Node[T]?
  mut replay_mode : Bool
  mut replay_node : Node[T]?
  mut pending_source : Node[T]?
  mut conditional_jumps : Array[(Node[T], (Itor[T]) -> Bool)]
  mut history_strategy : ((Itor[T]) -> Unit)?
  mut stop_requested : Bool
}

/// 用源工厂构造 Itor
pub fn[T] Itor::new(source : () -> Iter[T]) -> Itor[T] {
  {
    source: source,
    iterator: None,
    state: Pending,
    dummy: None,
    history_head: None,
    history_tail: None,
    replay_mode: false,
    replay_node: None,
    pending_source: None,
    conditional_jumps: [],
    history_strategy: None,
    stop_requested: false,
  }
}

/// 从数组构造 Itor（数组每次被重新迭代，副本互相独立）
pub fn[T] Itor::from_array(values : Array[T]) -> Itor[T] {
  Itor::new(fn() { values.iter() })
}

/// 从惰性迭代器构造 Itor（一次性源，副本共享底层迭代器）
pub fn[T] Itor::from_iter(iter : Iter[T]) -> Itor[T] {
  Itor::new(fn() { iter })
}

/// 当前状态
pub fn[T] Itor::state(self : Itor[T]) -> ItorState {
  self.state
}

/// 是否处于 Pending（未开始或已重置）
pub fn[T] Itor::is_pending(self : Itor[T]) -> Bool {
  self.state == Pending
}

/// 是否处于 Iterring（正在迭代中）
pub fn[T] Itor::is_iterring(self : Itor[T]) -> Bool {
  self.state == Iterring
}

/// 是否处于 Paused（已暂停）
pub fn[T] Itor::is_paused(self : Itor[T]) -> Bool {
  self.state == Paused
}

/// 是否处于 Stopped（已终止）
pub fn[T] Itor::is_stopped(self : Itor[T]) -> Bool {
  self.state == Stopped
}

/// 插队：将 `jump` 节点链表插入到下一个产出位置。
///
/// 在 `jump_when` 为 `None` 时紧急插队（下一轮立即产出）；
/// 否则注册为条件插队，每次产出前检查条件，满足时才插入。
///
/// 若迭代器已处于 `Stopped` 状态，插队无效（静默忽略）。
pub fn[T] Itor::send(
  self : Itor[T],
  jump : Node[T],
  jump_when? : (Itor[T]) -> Bool,
) -> Itor[T] {
  if self.state == Stopped {
    return self
  }
  match jump_when {
    Some(condition) => self.conditional_jumps.push((jump, condition))
    None => self.insert_jump_chain(jump)
  }
  self
}

/// 插队单个值（包装为单节点后调用 `send`）
pub fn[T] Itor::send_value(self : Itor[T], value : T) -> Itor[T] {
  self.send(Node::new(value))
}

/// 插队一组值（从数组构建懒加载链表后调用 `send`）
pub fn[T] Itor::send_values(self : Itor[T], values : Array[T]) -> Itor[T] {
  match Node::from_iter(values.iter()) {
    Some(head) => self.send(head)
    None => self
  }
}

/// 强制暂停：状态切为 `Paused`。
/// 暂停期间 `next` 返回 `None` 且不推进（配合外部逻辑等待 `resume_iter`）。
pub fn[T] Itor::set_pause(self : Itor[T]) -> Itor[T] {
  if self.state == Pending || self.state == Iterring {
    self.state = Paused
  }
  self
}

/// 恢复暂停：状态由 `Paused` 切回 `Iterring`。
pub fn[T] Itor::resume_iter(self : Itor[T]) -> Itor[T] {
  if self.state == Paused {
    self.state = Iterring
  }
  self
}

/// 基于历史流重新开始迭代。
///
/// 状态回到 `Pending`，从历史记录头部开始重放；重放结束后继续源迭代器
/// 未消费的部分。任何状态（包括 `Stopped`）均可调用。
pub fn[T] Itor::restart(self : Itor[T]) -> Itor[T] {
  self.state = Pending
  self.stop_requested = false
  self.replay_mode = true
  self.replay_node = self.history_head
  // 清空 dummy 之后可能残留的插队节点
  self.dummy = None
  // 清空暂存源值（取数期间发生 restart 的残留）
  self.pending_source = None
  // 清空待处理的条件插队（重启视为新生命周期）
  self.conditional_jumps = []
  self
}

/// 设置历史保留策略。
///
/// `strategy` 为 `None` 表示完全保留；策略函数在每次产出值后被调用。
pub fn[T] Itor::history_strategy(
  self : Itor[T],
  strategy : ((Itor[T]) -> Unit)?,
) -> Itor[T] {
  self.history_strategy = strategy
  self
}

/// 为指定 Itor 设置"最大历史长度"策略。
///
/// - `max_len == -1`：完全保留（清除已有策略）
/// - `max_len >= 0`：最多保留最近 `max_len` 条
/// - `max_len < -1`：非法，静默忽略
pub fn[T] Itor::set_history_max(self : Itor[T], max_len : Int) -> Unit {
  if max_len < -1 {
    return
  }
  if max_len == -1 {
    self.history_strategy = None
    return
  }
  self.history_strategy = Some(fn(itor : Itor[T]) {
    let mut count = 0
    let mut cur = itor.history_head
    while true {
      match cur {
        Some(c) => {
          count = count + 1
          cur = c.next()
        }
        None => break
      }
    }
    while count > max_len {
      match itor.history_head {
        Some(h) => {
          itor.history_head = h.next()
          count = count - 1
        }
        None => break
      }
    }
    if itor.history_head is None {
      itor.history_tail = None
    }
  })
}

/// 终止迭代：状态切为 `Stopped` 并设置停止请求。
pub fn[T] Itor::stop(self : Itor[T]) -> Itor[T] {
  self.state = Stopped
  self.stop_requested = true
  self
}

/// 返回当前 Itor 的全新状态副本。
///
/// 新实例拥有独立的迭代状态与历史链表，状态重置为 `Pending`；
/// 共享源工厂与历史策略函数。
pub fn[T] Itor::copy(self : Itor[T]) -> Itor[T] {
  let new : Itor[T] = Itor::new(self.source)
  new.history_strategy = self.history_strategy
  new
}

/// `call` 与 `copy` 等价（对应 vools 的 `itor()` 调用）。
pub fn[T] Itor::call(self : Itor[T]) -> Itor[T] {
  self.copy()
}

/// 获取下一个值。
///
/// 返回 `None` 表示没有更多数据（状态为 `Stopped`），
/// 或在暂停期间表示暂无产出（状态保持 `Paused`）。
pub fn[T] Itor::next(self : Itor[T]) -> T? {
  // 初始化源迭代器
  if self.iterator is None {
    self.iterator = Some((self.source)())
  }
  if self.state == Pending {
    self.state = Iterring
  }

  // 暂停：不产出也不推进
  if self.state == Paused {
    return None
  }
  if self.state == Stopped || self.stop_requested {
    return None
  }

  // 处理条件插队
  self.process_conditional_jumps()

  // 获取下一个产出节点
  let node = self.get_next_node()
  match node {
    Some(n) => {
      // 产出值
      let v = n.val()
      // 维护历史（重放节点不再重复写入，避免成环）
      if !n.is_replay {
        self.add_history(n)
      }
      // 应用历史策略
      match self.history_strategy {
        Some(strategy) => strategy(self)
        None => ()
      }
      Some(v)
    }
    None => {
      self.state = Stopped
      None
    }
  }
}

/// 将 `jump` 节点及其后续链表整体插入到 dummy 之后。
///
/// 对懒加载/无限链表直接设置 `fallback`，避免无法穷举到尾节点。
fn[T] Itor::insert_jump_chain(self : Itor[T], jump : Node[T]) -> Unit {
  if jump.iter is Some(_) {
    // 懒加载/无限链表：无法遍历到尾，设置 fallback 后插入头部
    jump.fallback = self.dummy
    self.dummy = Some(jump)
    return
  }
  let mut tail = jump
  while true {
    match tail.next() {
      Some(t) => tail = t
      None => break
    }
  }
  tail.set_next(self.dummy)
  self.dummy = Some(jump)
}

/// 检查并插入所有满足条件的插队节点。
fn[T] Itor::process_conditional_jumps(self : Itor[T]) -> Unit {
  let mut i = 0
  while i < self.conditional_jumps.length() {
    let (node, condition) = self.conditional_jumps[i]
    if condition(self) {
      // 满足条件：插入整条链表并移除该条件插队
      self.insert_jump_chain(node)
      ignore(self.conditional_jumps.remove(i))
    } else {
      i = i + 1
    }
  }
}

/// 获取下一个待产出的节点。
///
/// 取值顺序：历史重放 -> 紧急插队 -> 待处理源值 -> 源迭代器。
/// 返回 `None` 表示没有更多数据。
fn[T] Itor::get_next_node(self : Itor[T]) -> Node[T]? {
  // 1. 历史重放优先（restart 后从历史头部重放；重放期间新插队排在重放之后）
  if self.replay_mode {
    match self.replay_node {
      Some(rn) => {
        self.replay_node = rn.next()
        let node : Node[T] = Node::new(rn.val())
        node.is_replay = true
        return Some(node)
      }
      None => {
        // 历史重放结束，切换回正常模式
        self.replay_mode = false
      }
    }
  }

  // 2. 紧急插队节点（普通模式下优先级最高；重放结束后紧随重放）
  match self.dummy {
    Some(d) => {
      self.dummy = d.next()
      d.set_next(None)
      return Some(d)
    }
    None => ()
  }

  // 3. 待处理源值（源迭代期间发生 restart 时暂存）
  match self.pending_source {
    Some(ps) => {
      self.pending_source = None
      return Some(ps)
    }
    None => ()
  }

  // 4. 调用源迭代器
  let iterator = match self.iterator {
    Some(it) => it
    None => return None
  }
  let v = iterator.next()
  match v {
    None => None
    Some(val) => {
      // 取数期间可能发生了 restart 或紧急插队
      if self.replay_mode {
        // 取数期间被 restart：保存该值，等重放结束后再产出
        self.pending_source = Some(Node::new(val))
        match self.replay_node {
          Some(rn) => {
            self.replay_node = rn.next()
            let node : Node[T] = Node::new(rn.val())
            node.is_replay = true
            Some(node)
          }
          None => {
            // 历史为空，直接产出刚才取到的值
            let ps = match self.pending_source {
              Some(p) => p
              None => Node::new(val)
            }
            self.pending_source = None
            self.replay_mode = false
            Some(ps)
          }
        }
      } else {
        match self.dummy {
          Some(d) => {
            // 优先处理紧急插队：保存该值，先产出插队值
            self.pending_source = Some(Node::new(val))
            self.dummy = d.next()
            d.set_next(None)
            Some(d)
          }
          None => Some(Node::new(val))
        }
      }
    }
  }
}

/// 将节点加入历史链表尾。
fn[T] Itor::add_history(self : Itor[T], node : Node[T]) -> Unit {
  node.set_next(None)
  match self.history_tail {
    Some(tail) => {
      tail.set_next(Some(node))
      self.history_tail = Some(node)
    }
    None => {
      self.history_head = Some(node)
      self.history_tail = Some(node)
    }
  }
}

/// 副作用遍历：应用函数后返回自身，支持链式调用。
///
/// - `f`: 主函数，接收 Itor 实例
/// - `pre_f`: 预处理函数（可选），接收 Itor 返回 Itor
/// - `sub_f`: 后处理函数（可选），接收 Itor 无返回值
pub fn[T] Itor::do_iter(
  self : Itor[T],
  f : (Itor[T]) -> Unit,
  pre_f? : (Itor[T]) -> Itor[T],
  sub_f? : (Itor[T]) -> Unit,
) -> Itor[T] {
  let mut rs : Itor[T] = self
  match pre_f {
    Some(pre) => rs = pre(rs)
    None => ()
  }
  f(rs)
  match sub_f {
    Some(sub) => sub(rs)
    None => ()
  }
  self
}

/// 历史记录长度（供测试与调试使用）
pub fn[T] Itor::history_len(self : Itor[T]) -> Int {
  let mut count = 0
  let mut cur = self.history_head
  while true {
    match cur {
      Some(c) => {
        count = count + 1
        cur = c.next()
      }
      None => break
    }
  }
  count
}

/// 折叠：从 seed 开始，逐次调用 f(acc, next_value) 消费整个迭代器。
/// 对应 Haskell `Data.Iterator.fold`（或 Prelude `foldl`）语义：
/// 持续调用 `next` 直到流结束（状态为 Stopped），返回最终累积值。
pub fn[T, Acc] Itor::fold(self : Itor[T], seed : Acc, f : (Acc, T) -> Acc) -> Acc {
  let mut acc = seed
  while true {
    match self.next() {
      Some(v) => acc = f(acc, v)
      None => break
    }
  }
  acc
}
