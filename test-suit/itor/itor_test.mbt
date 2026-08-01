// ============================================================================
// test-suit/itor/itor_test.mbt —— Itor（可控制迭代器）黑盒测试
// 对照 vools 库（vools/data/itor.py）测试用例逐条复刻，剔除线程相关用例
// （MoonBit 当前为单线程运行时，暂停/恢复为同步语义），补充惰性链表、
// 条件插队、历史策略、停止控制等边界用例。
// 运行：moon test
// ============================================================================

///|
test "Node: 值读写与 next 链" {
  let a = @rx.Node::new(42)
  assert_eq(a.val(), 42)
  // 初始 next 为 None
  if a.next() is Some(_) {
    assert_true(false)
  }
  let b = @rx.Node::new(99)
  a.set_next(Some(b))
  match a.next() {
    Some(n) => assert_eq(n.val(), 99)
    None => assert_true(false)
  }
  a.set_next(None)
  if a.next() is Some(_) {
    assert_true(false)
  }
}

///|
test "Node: from_iter 基本链" {
  match @rx.Node::from_iter([10, 20, 30].iter()) {
    Some(head) => {
      assert_eq(head.val(), 10)
      match head.next() {
        Some(n2) => {
          assert_eq(n2.val(), 20)
          match n2.next() {
            Some(n3) => {
              assert_eq(n3.val(), 30)
              if n3.next() is Some(_) {
                assert_true(false)
              }
            }
            None => assert_true(false)
          }
        }
        None => assert_true(false)
      }
    }
    None => assert_true(false)
  }
}

///|
test "Node: from_iter 空迭代器返回 None" {
  let empty : Array[Int] = []
  if @rx.Node::from_iter(empty.iter()) is Some(_) {
    assert_true(false)
  }
}

///|
test "Node: to_iter 按序产出" {
  match @rx.Node::from_iter([1, 2, 3].iter()) {
    Some(head) => {
      let vals : Array[Int] = []
      for v in head.to_iter() {
        vals.push(v)
      }
      assert_eq(vals, [1, 2, 3])
    }
    None => assert_true(false)
  }
}

///|
test "Node: to_iter 单节点" {
  let node = @rx.Node::new(42)
  let vals : Array[Int] = []
  for v in node.to_iter() {
    vals.push(v)
  }
  assert_eq(vals, [42])
}

///|
test "Node: 无限惰性链表可安全取前 N 个" {
  // 模拟无限迭代器：迭代器每次被调用产生自增值
  let counter = Ref::Ref(0)
  let infinite : Iter[Int] = Iter::new(fn() {
    let c = counter.val
    counter.val = c + 1
    Some(c)
  })
  match @rx.Node::from_iter(infinite) {
    Some(head) => {
      // 手动取前 3 个：验证惰性展开
      assert_eq(head.val(), 0)
      match head.next() {
        Some(n1) => assert_eq(n1.val(), 1)
        None => assert_true(false)
      }
      // next 已被缓存，不再调用迭代器：取值仍为 1
      match head.next() {
        Some(n1) => assert_eq(n1.val(), 1)
        None => assert_true(false)
      }
      match head.next() {
        Some(n2) => assert_eq(n2.val(), 2)
        None => assert_true(false)
      }
    }
    None => assert_true(false)
  }
}

///|
test "Node: to_itor 转 Itor 并迭代" {
  match @rx.Node::from_iter([1, 2, 3].iter()) {
    Some(head) => {
      let itor = head.to_itor()
      let gen = itor.call()
      let vals : Array[Int] = []
      while true {
        match gen.next() {
          Some(v) => vals.push(v)
          None => break
        }
      }
      assert_eq(vals, [1, 2, 3])
      assert_true(gen.is_stopped())
    }
    None => assert_true(false)
  }
}

///|
test "Node: to_itor 无限流可 stop 终止" {
  let counter = Ref::Ref(0)
  let infinite : Iter[Int] = Iter::new(fn() {
    let c = counter.val
    counter.val = c + 1
    Some(c)
  })
  match @rx.Node::from_iter(infinite) {
    Some(head) => {
      let gen = head.to_itor()
      assert_eq(gen.next(), Some(0))
      assert_eq(gen.next(), Some(1))
      gen.stop()
      assert_eq(gen.next(), None)
      assert_true(gen.is_stopped())
    }
    None => assert_true(false)
  }
}

///|
test "Itor: 全量迭代" {
  let itor = @rx.Itor::from_iter([1, 2, 3].iter())
  let gen = itor.call()
  let vals : Array[Int] = []
  while true {
    match gen.next() {
      Some(v) => vals.push(v)
      None => break
    }
  }
  assert_eq(vals, [1, 2, 3])
}

///|
test "Itor: from_array 全量迭代" {
  let itor = @rx.Itor::from_array([4, 5, 6])
  let gen = itor.call()
  let vals : Array[Int] = []
  while true {
    match gen.next() {
      Some(v) => vals.push(v)
      None => break
    }
  }
  assert_eq(vals, [4, 5, 6])
}

///|
test "Itor: 耗尽后状态为 Stopped" {
  let itor = @rx.Itor::from_array([1])
  let gen = itor.call()
  assert_eq(gen.next(), Some(1))
  assert_eq(gen.next(), None)
  assert_true(gen.is_stopped())
}

///|
test "Itor: 直接 next 逐个取值" {
  let itor = @rx.Itor::from_array([1, 2, 3])
  assert_eq(itor.next(), Some(1))
  assert_eq(itor.next(), Some(2))
  assert_eq(itor.next(), Some(3))
  assert_eq(itor.next(), None)
  assert_true(itor.is_stopped())
}

///|
test "Itor: call 返回独立副本，互不影响" {
  let itor = @rx.Itor::from_array([1, 2, 3])
  let gen = itor.call()
  assert_true(gen.is_pending())
  assert_true(itor.is_pending())
  assert_eq(gen.next(), Some(1))
  assert_true(gen.is_iterring())
  assert_true(itor.is_pending())
  // 原实例仍可独立迭代
  assert_eq(itor.next(), Some(1))
  assert_eq(itor.next(), Some(2))
}

///|
test "Itor: 暂停期间不推进，恢复后继续" {
  let itor = @rx.Itor::from_array([1, 2, 3])
  let gen = itor.call()
  assert_eq(gen.next(), Some(1))
  gen.set_pause()
  assert_true(gen.is_paused())
  // 暂停期间 next 返回 None 且不推进源
  assert_eq(gen.next(), None)
  assert_eq(gen.next(), None)
  gen.resume_iter()
  assert_true(gen.is_iterring())
  assert_eq(gen.next(), Some(2))
  assert_eq(gen.next(), Some(3))
  assert_eq(gen.next(), None)
}

///|
test "Itor: 紧急插队单节点" {
  let itor = @rx.Itor::from_array([1, 2, 3, 4, 5])
  let gen = itor.call()
  assert_eq(gen.next(), Some(1))
  gen.send(@rx.Node::new(99))
  assert_eq(gen.next(), Some(99))
  assert_eq(gen.next(), Some(2))
  let rest : Array[Int] = []
  while true {
    match gen.next() {
      Some(v) => rest.push(v)
      None => break
    }
  }
  assert_eq(rest, [3, 4, 5])
}

///|
test "Itor: 紧急插队整条链表" {
  let itor = @rx.Itor::from_array([1, 2, 3, 4, 5])
  let gen = itor.call()
  assert_eq(gen.next(), Some(1))
  match @rx.Node::from_iter([98, 99].iter()) {
    Some(chain) => gen.send(chain)
    None => assert_true(false)
  }
  assert_eq(gen.next(), Some(98))
  assert_eq(gen.next(), Some(99))
  assert_eq(gen.next(), Some(2))
  let rest : Array[Int] = []
  while true {
    match gen.next() {
      Some(v) => rest.push(v)
      None => break
    }
  }
  assert_eq(rest, [3, 4, 5])
}

///|
test "Itor: send_value 插队单个值" {
  let itor = @rx.Itor::from_array([1, 2, 3])
  let gen = itor.call()
  assert_eq(gen.next(), Some(1))
  gen.send_value(88)
  assert_eq(gen.next(), Some(88))
  assert_eq(gen.next(), Some(2))
}

///|
test "Itor: send_values 插队多个值" {
  let itor = @rx.Itor::from_array([1, 2, 3])
  let gen = itor.call()
  assert_eq(gen.next(), Some(1))
  gen.send_values([88, 89])
  assert_eq(gen.next(), Some(88))
  assert_eq(gen.next(), Some(89))
  assert_eq(gen.next(), Some(2))
}

///|
test "Itor: 条件插队（历史长度达 3 时插入单节点）" {
  let itor = @rx.Itor::from_array([1, 2, 3, 4, 5])
  let gen = itor.call()
  gen.send(
    @rx.Node::new(88),
    jump_when=fn(it : @rx.Itor[Int]) { it.history_len() == 3 },
  )
  let vals : Array[Int] = []
  while true {
    match gen.next() {
      Some(v) => vals.push(v)
      None => break
    }
  }
  assert_eq(vals, [1, 2, 3, 88, 4, 5])
}

///|
test "Itor: 条件插队整条链表" {
  let itor = @rx.Itor::from_array([1, 2, 3, 4, 5])
  let gen = itor.call()
  match @rx.Node::from_iter([88, 89].iter()) {
    Some(chain) => gen.send(
      chain,
      jump_when=fn(it : @rx.Itor[Int]) { it.history_len() == 3 },
    )
    None => assert_true(false)
  }
  let vals : Array[Int] = []
  while true {
    match gen.next() {
      Some(v) => vals.push(v)
      None => break
    }
  }
  assert_eq(vals, [1, 2, 3, 88, 89, 4, 5])
}

///|
test "Itor: 条件永不满足则不插队" {
  let itor = @rx.Itor::from_array([1, 2, 3])
  let gen = itor.call()
  gen.send(
    @rx.Node::new(99),
    jump_when=fn(it : @rx.Itor[Int]) { it.history_len() > 100 },
  )
  let vals : Array[Int] = []
  while true {
    match gen.next() {
      Some(v) => vals.push(v)
      None => break
    }
  }
  assert_eq(vals, [1, 2, 3])
}

///|
test "Itor: 停止后插队无效（静默忽略）" {
  let itor = @rx.Itor::from_array([1])
  let gen = itor.call()
  assert_eq(gen.next(), Some(1))
  assert_eq(gen.next(), None)
  gen.send(@rx.Node::new(99))
  assert_eq(gen.next(), None)
}

///|
test "Itor: 链式调用返回自身" {
  let itor = @rx.Itor::from_array([1, 2, 3])
  let gen = itor.call()
  assert_eq(gen.next(), Some(1))
  gen.send(@rx.Node::new(99)).set_pause().resume_iter()
  assert_eq(gen.next(), Some(99))
  assert_eq(gen.next(), Some(2))
  gen.history_strategy(None)
  gen.stop()
  assert_true(gen.is_stopped())
}

///|
test "Itor: restart 重放历史并继续源" {
  let itor = @rx.Itor::from_array([1, 2, 3])
  let gen = itor.call()
  assert_eq(gen.next(), Some(1))
  assert_eq(gen.next(), Some(2))
  gen.restart()
  // 重放历史 [1, 2] 后继续源剩余 [3]
  let vals : Array[Int] = []
  while true {
    match gen.next() {
      Some(v) => vals.push(v)
      None => break
    }
  }
  assert_eq(vals, [1, 2, 3])
}

///|
test "Itor: 耗尽后 restart 仍可重放全部历史" {
  let itor = @rx.Itor::from_array([1, 2, 3])
  let gen = itor.call()
  let vals : Array[Int] = []
  while true {
    match gen.next() {
      Some(v) => vals.push(v)
      None => break
    }
  }
  assert_eq(vals, [1, 2, 3])
  gen.restart()
  let replay : Array[Int] = []
  while true {
    match gen.next() {
      Some(v) => replay.push(v)
      None => break
    }
  }
  assert_eq(replay, [1, 2, 3])
}

///|
test "Itor: set_history_max 保留最近 N 条（N=3）" {
  let itor = @rx.Itor::from_array([1, 2, 3, 4, 5])
  itor.set_history_max(3)
  let gen = itor.call()
  let vals : Array[Int] = []
  while true {
    match gen.next() {
      Some(v) => vals.push(v)
      None => break
    }
  }
  assert_eq(vals, [1, 2, 3, 4, 5])
  gen.restart()
  let replay : Array[Int] = []
  while true {
    match gen.next() {
      Some(v) => replay.push(v)
      None => break
    }
  }
  assert_eq(replay, [3, 4, 5])
}

///|
test "Itor: set_history_max(-1) 完全保留" {
  let itor = @rx.Itor::from_array([1, 2, 3, 4, 5])
  itor.set_history_max(3)
  itor.set_history_max(-1)
  let gen = itor.call()
  while true {
    match gen.next() {
      Some(_) => ()
      None => break
    }
  }
  gen.restart()
  let replay : Array[Int] = []
  while true {
    match gen.next() {
      Some(v) => replay.push(v)
      None => break
    }
  }
  assert_eq(replay, [1, 2, 3, 4, 5])
}

///|
test "Itor: set_history_max(0) 不保留历史" {
  let itor = @rx.Itor::from_array([1, 2, 3])
  itor.set_history_max(0)
  let gen = itor.call()
  while true {
    match gen.next() {
      Some(_) => ()
      None => break
    }
  }
  gen.restart()
  let replay : Array[Int] = []
  while true {
    match gen.next() {
      Some(v) => replay.push(v)
      None => break
    }
  }
  assert_eq(replay, [])
}

///|
test "Itor: 自定义历史策略（完全丢弃历史）" {
  let itor = @rx.Itor::from_array([1, 2, 3])
  // 每次产出后清空历史：restart 后无内容可重放
  itor.history_strategy(
    Some(fn(it : @rx.Itor[Int]) { it.set_history_max(0) }),
  )
  let gen = itor.call()
  let vals : Array[Int] = []
  while true {
    match gen.next() {
      Some(v) => vals.push(v)
      None => break
    }
  }
  assert_eq(vals, [1, 2, 3])
  gen.restart()
  let replay : Array[Int] = []
  while true {
    match gen.next() {
      Some(v) => replay.push(v)
      None => break
    }
  }
  assert_eq(replay, [])
}

///|
test "Itor: stop 提前终止（不产出剩余值）" {
  let itor = @rx.Itor::from_array([1, 2, 3, 4, 5])
  let gen = itor.call()
  assert_eq(gen.next(), Some(1))
  assert_eq(gen.next(), Some(2))
  gen.stop()
  assert_eq(gen.next(), None)
  assert_true(gen.is_stopped())
}

///|
test "Itor: do_iter 副作用遍历" {
  let itor = @rx.Itor::from_array([1, 2, 3])
  let gen = itor.call()
  let seen = Ref::Ref(0)
  gen.do_iter(fn(it : @rx.Itor[Int]) {
    while true {
      match it.next() {
        Some(_) => seen.val = seen.val + 1
        None => break
      }
    }
  })
  assert_eq(seen.val, 3)
  assert_true(gen.is_stopped())
}

///|
test "Itor: do_iter 带 pre_f 与 sub_f" {
  let itor = @rx.Itor::from_array([1, 2, 3])
  let gen = itor.call()
  let log : Array[String] = []
  gen.do_iter(
    fn(it : @rx.Itor[Int]) {
      log.push("f")
      while true {
        match it.next() {
          Some(_) => ()
          None => break
        }
      }
    },
    pre_f=Some(fn(it : @rx.Itor[Int]) -> @rx.Itor[Int] {
      log.push("pre")
      it
    }),
    sub_f=Some(fn(it : @rx.Itor[Int]) { log.push("sub") }),
  )
  assert_eq(log, ["pre", "f", "sub"])
}

///|
test "Itor: 插队链保留后续源（懒加载链）" {
  let itor = @rx.Itor::from_array([1, 2, 3])
  let gen = itor.call()
  assert_eq(gen.next(), Some(1))
  // 懒加载链表（Node::from_iter 产生）
  match @rx.Node::from_iter([88, 89].iter()) {
    Some(chain) => gen.send(chain)
    None => assert_true(false)
  }
  assert_eq(gen.next(), Some(88))
  assert_eq(gen.next(), Some(89))
  assert_eq(gen.next(), Some(2))
  assert_eq(gen.next(), Some(3))
  assert_eq(gen.next(), None)
}

///|
test "Itor: 多副本独立迭代 from_array" {
  let itor = @rx.Itor::from_array([1, 2, 3])
  let a = itor.call()
  let b = itor.call()
  assert_eq(a.next(), Some(1))
  assert_eq(b.next(), Some(1)) // 副本互不影响
  assert_eq(a.next(), Some(2))
  assert_eq(b.next(), Some(2))
}

///|
test "Itor: restart 后新插队立即生效" {
  let itor = @rx.Itor::from_array([1, 2, 3])
  let gen = itor.call()
  assert_eq(gen.next(), Some(1))
  gen.restart()
  gen.send_value(99)
  // 重放历史 [1]，插队 99 在重放后、源继续前
  let vals : Array[Int] = []
  while true {
    match gen.next() {
      Some(v) => vals.push(v)
      None => break
    }
  }
  // 历史为 [1]，重放 1；随后插队 99；源剩余 [2, 3]
  assert_eq(vals, [1, 99, 2, 3])
}
