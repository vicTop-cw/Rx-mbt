// 探针：验证 Array pop / String substring / 拼接
fn main {
  let a = ["x", "y", "z"]
  let last = a.pop()
  println("pop: \{last} remaining: \{a.length()}")
  let s = "hello world"
  let sub = s.substring(0, 5)
  println("substring: [\{sub}]")
  let sub2 = s.sub(6, 11)
  println("sub2: [\{sub2}]")
  let joined = "a" + "b" + "c"
  println("join: \{joined}")
  let ch = Char::from_int(97)
  println("char from int: \{ch}")
  let c2 = s[0]
  println("idx0: \{c2.to_int()}")
}
