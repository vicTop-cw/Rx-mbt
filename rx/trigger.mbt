// ============================================================================
// Trigger —— 非定时任务触发机制（TriggerEvent / Trigger / TriggerRegistry）
// 设计来源：triggers.do / zrb / polix.triggers.core / pynenc / Airflow /
//           TimeOS / gookit/event / libevent 等触发机制调研
// 核心思想：事件名精确 + 通配匹配 → 条件过滤 → 优先级排序 → 分发执行；
//           once 自动注销；幂等 key 去重；触发与执行解耦（事件驱动）。
// ============================================================================

///|
/// 触发事件：事件名 + 载荷 + 事件序号 + 发生时刻（虚拟时钟毫秒）
pub struct TriggerEvent[T] {
  name : String
  payload : T
  id : Int64
  at : Int64
}

///|
/// 触发器：事件名（支持通配）+ 条件 + 时机 + 处理器
pub struct Trigger[T] {
  id : Int
  event_name : String
  condition : (TriggerEvent[T]) -> Bool
  once : Bool
  priority : Int
  handler : (TriggerEvent[T]) -> Unit
  fired_count : Ref[Int]
}

///|
/// 触发器注册表：集中管理 + 事件分发 + 幂等去重
pub struct TriggerRegistry[T] {
  triggers : Ref[Array[Trigger[T]]]
  seq : Ref[Int]
  event_seq : Ref[Int64]
  dedup_keys : Ref[@hashset.HashSet[String]]
}

///|
/// 创建空注册表
pub fn[T] TriggerRegistry::new() -> TriggerRegistry[T] {
  {
    triggers: Ref::Ref(Array(capacity=0)),
    seq: Ref::Ref(0),
    event_seq: Ref::Ref(0L),
    dedup_keys: Ref::Ref(@hashset.from_array([])),
  }
}

///|
/// 注册简单触发器（无条件、非一次性、优先级 0），返回 trigger_id
pub fn[T] TriggerRegistry::register(
  self : TriggerRegistry[T],
  event_name : String,
  handler : (TriggerEvent[T]) -> Unit,
) -> Int {
  self.register_with(event_name, handler)
}

///|
/// 注册触发器（可指定条件 / 一次性 / 优先级），返回 trigger_id
pub fn[T] TriggerRegistry::register_with(
  self : TriggerRegistry[T],
  event_name : String,
  handler : (TriggerEvent[T]) -> Unit,
  condition? : ((TriggerEvent[T]) -> Bool)? = None,
  once? : Bool = false,
  priority? : Int = 0,
) -> Int {
  let id = self.seq.val
  self.seq.val = self.seq.val + 1
  let cond = match condition {
    None => fn(_ev : TriggerEvent[T]) { true }
    Some(f) => f
  }
  self.triggers.val.push({
    id,
    event_name,
    condition: cond,
    once,
    priority,
    handler,
    fired_count: Ref::Ref(0),
  })
  id
}

///|
/// 注销触发器：存在并移除返回 true，不存在返回 false
pub fn[T] TriggerRegistry::unregister(
  self : TriggerRegistry[T],
  trigger_id : Int,
) -> Bool {
  let keep = Array(capacity=0)
  let mut removed = false
  for t in self.triggers.val {
    if t.id == trigger_id {
      removed = true
    } else {
      keep.push(t)
    }
  }
  self.triggers.val = keep
  removed
}

///|
/// 按 "." 分段转为字符串数组
fn split_dot(s : String) -> Array[String] {
  let res = Array(capacity=0)
  for sv in s.split(".") {
    res.push(sv.to_owned())
  }
  res
}

/// 事件名匹配：精确 / "*" 单段通配 / "**" 多段通配（分段比较，不引入正则）
/// "*" 仅匹配单个段；"**" 可出现在任意位置，匹配零段或多段
fn event_matches(pattern : String, name : String) -> Bool {
  let pat = split_dot(pattern)
  let parts = split_dot(name)
  let p_len = pat.length()
  let n_len = parts.length()
  let mut pi = 0
  let mut ni = 0
  // star_p / star_n：记录最近的 "**" 模式段位置及对应 name 指针，用于回溯
  let mut star_p = -1
  let mut star_n = -1
  while ni < n_len {
    if pi < p_len {
      let p = pat[pi]
      if p == "**" {
        star_p = pi
        star_n = ni
        pi = pi + 1
      } else if p == "*" {
        pi = pi + 1
        ni = ni + 1
      } else {
        if p == parts[ni] {
          pi = pi + 1
          ni = ni + 1
        } else if star_p != -1 {
          // 当前段不匹配且之前出现过 "**"：让该 "**" 多吞一段后重试
          star_n = star_n + 1
          pi = star_p + 1
          ni = star_n
        } else {
          return false
        }
      }
    } else if star_p != -1 {
      star_n = star_n + 1
      pi = star_p + 1
      ni = star_n
    } else {
      return false
    }
  }
  // name 已耗尽：pattern 剩余段必须全为 "**" 才匹配
  while pi < p_len {
    if pat[pi] != "**" {
      return false
    }
    pi = pi + 1
  }
  true
}

///|
/// 分发事件（指定时刻）：匹配 → 按优先级降序（同优先按注册序）→
/// 条件通过则执行；once 触发器触发后自动注销
pub fn[T] TriggerRegistry::fire_at(
  self : TriggerRegistry[T],
  name : String,
  payload : T,
  at : Int64,
) -> Unit {
  self.event_seq.val = self.event_seq.val + 1
  let ev : TriggerEvent[T] = { name, payload, id: self.event_seq.val, at, }
  // 收集命中事件名的触发器（保持注册序）
  let hit = Array(capacity=0)
  for t in self.triggers.val {
    if event_matches(t.event_name, name) {
      hit.push(t)
    }
  }
  // 优先级降序稳定排序（同优先保持注册序）
  insertion_sort(hit, fn(a : Trigger[T], b : Trigger[T]) {
    b.priority - a.priority
  })
  // 分发执行；once 触发后收集待注销 id
  let to_remove = Array(capacity=0)
  for t in hit {
    if (t.condition)(ev) {
      (t.handler)(ev)
      t.fired_count.val = t.fired_count.val + 1
      if t.once {
        to_remove.push(t.id)
      }
    }
  }
  for id in to_remove {
    let _ = self.unregister(id)
  }
}

///|
/// 分发事件：时刻取默认虚拟时钟当前时间
pub fn[T] TriggerRegistry::fire(
  self : TriggerRegistry[T],
  name : String,
  payload : T,
) -> Unit {
  self.fire_at(name, payload, default_clock.now())
}

///|
/// 幂等触发：key 已存在则整体跳过，否则记录 key 并分发
pub fn[T] TriggerRegistry::fire_with_key(
  self : TriggerRegistry[T],
  name : String,
  payload : T,
  key : String,
) -> Unit {
  if self.dedup_keys.val.contains(key) {
    return
  }
  self.dedup_keys.val.add(key)
  self.fire(name, payload)
}

///|
/// 是否存在匹配该事件名（含通配）的触发器
pub fn[T] TriggerRegistry::has_trigger(
  self : TriggerRegistry[T],
  event_name : String,
) -> Bool {
  let mut found = false
  for t in self.triggers.val {
    if event_matches(t.event_name, event_name) {
      found = true
      break
    }
  }
  found
}

///|
/// 当前注册的触发器数量
pub fn[T] TriggerRegistry::trigger_count(self : TriggerRegistry[T]) -> Int {
  self.triggers.val.length()
}

///|
/// 清空所有触发器与幂等键（事件序号继续递增）
pub fn[T] TriggerRegistry::clear(self : TriggerRegistry[T]) -> Unit {
  self.triggers.val = Array(capacity=0)
  self.dedup_keys.val = @hashset.from_array([])
}

///|
/// 仅清空幂等去重键（不清触发器、不清事件序号）。
/// 用于长周期运行控制 dedup 表内存占用：与 clear 不同，保留已注册触发器，
/// 清后同 key 可再次触发。
pub fn[T] TriggerRegistry::reset_dedup_keys(self : TriggerRegistry[T]) -> Unit {
  self.dedup_keys.val = @hashset.from_array([])
}
