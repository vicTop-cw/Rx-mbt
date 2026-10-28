// ============================================================================
// rhop · canonical_json 单元测试（跨目标）
//
// 期望值全部由 Python 3.13 生成并逐字符比对：
//   json.dumps(x, ensure_ascii=False, sort_keys=True)
// 覆盖：键排序（含中文/emoji 码点序）、分隔符、转义、空容器、嵌套、数字形态。
// ============================================================================

///|
/// 便捷构造：把 `(键, 值)` 数组转成 `Json` 对象（插入顺序与输出顺序无关）。
fn jobj(entries : Array[(String, Json)]) -> Json {
  let map : Map[String, Json] = Map([])
  for i in 0..<entries.length() {
    let (k, v) = entries[i]
    map[k] = v
  }
  Json::object(map)
}

///|
test "canonical: 对象键升序 + 分隔符 \", \" / \": \"" {
  let value = jobj([("b", Json::number(1.0)), ("a", Json::number(2.0))])
  assert_eq(@rp.canonical_json(value), "{\"a\": 2, \"b\": 1}")
}

///|
test "canonical: 嵌套对象/数组/布尔/null 混合（Python 同形）" {
  let nested = jobj([
    ("z", Json::number(1.0)),
    (
      "y",
      Json::array([
        Json::number(1.0),
        Json::number(2.0),
        jobj([("k", Json::string("v"))]),
      ]),
    ),
  ])
  let value = jobj([
    ("name", Json::string("\u{5f20}\u{4e09}")),
    ("age", Json::number(30.0)),
    ("tags", Json::array([Json::string("a"), Json::string("b")])),
    ("ok", Json::boolean(true)),
    ("none", Json::null()),
    ("nested", nested),
  ])
  assert_eq(
    @rp.canonical_json(value),
    "{\"age\": 30, \"name\": \"\u{5f20}\u{4e09}\", \"nested\": {\"y\": [1, 2, {\"k\": \"v\"}], \"z\": 1}, \"none\": null, \"ok\": true, \"tags\": [\"a\", \"b\"]}",
  )
}

///|
test "canonical: 字符串转义（控制字符/引号/反斜杠，非 ASCII 原样）" {
  let value = jobj([
    ("ctrl", Json::string("a\nb\tc\rd\u{08}e\u{0c}f\u{01}g")),
    ("quote", Json::string("he said \"hi\"")),
    ("back", Json::string("a\\b")),
  ])
  assert_eq(
    @rp.canonical_json(value),
    "{\"back\": \"a\\\\b\", \"ctrl\": \"a\\nb\\tc\\rd\\be\\ff\\u0001g\", \"quote\": \"he said \\\"hi\\\"\"}",
  )
}

///|
test "canonical: 非 ASCII 原样输出（ensure_ascii=False）" {
  assert_eq(
    @rp.canonical_json(Json::string("\u{4e2d}\u{6587}")),
    "\"\u{4e2d}\u{6587}\"",
  )
  // emoji（非 BMP）原样，不做 \uXXXX 代理对转义
  assert_eq(@rp.canonical_json(Json::string("\u{1F600}")), "\"\u{1F600}\"")
  // 0x7F(DEL) 与 U+2028 不属于 < 0x20，Python 也不转义
  assert_eq(
    @rp.canonical_json(Json::string("\u{7f}\u{2028}")),
    "\"\u{7f}\u{2028}\"",
  )
}

///|
test "canonical: 键按 Unicode 码点排序（ASCII < CJK < emoji）" {
  let value = jobj([
    ("\u{1F600}", Json::number(4.0)),
    ("B", Json::number(1.0)),
    ("a", Json::number(2.0)),
    ("\u{4e2d}", Json::number(3.0)),
  ])
  assert_eq(
    @rp.canonical_json(value),
    "{\"B\": 1, \"a\": 2, \"\u{4e2d}\": 3, \"\u{1F600}\": 4}",
  )
}

///|
test "canonical: 补充平面字符键按码点序（判别 UTF-16 序实现）" {
  // U+FFFD < U+1F600：码点序 FFFD 在前；UTF-16 码元序 D83D < FFFD 会把 😀 排前面。
  // 现有 B/a/中/😀 用例在两种实现下同形，无法判别；这条用例能区分（PROTO-08）。
  let value = jobj([
    ("\u{1F600}", Json::number(2.0)),
    ("\u{FFFD}", Json::number(1.0)),
  ])
  assert_eq(@rp.canonical_json(value), "{\"\u{FFFD}\": 1, \"\u{1F600}\": 2}")
}

///|
test "canonical: 空对象与空数组" {
  assert_eq(@rp.canonical_json(jobj([])), "{}")
  assert_eq(@rp.canonical_json(Json::array([])), "[]")
  assert_eq(
    @rp.canonical_json(jobj([("e", jobj([])), ("a", Json::array([]))])),
    "{\"a\": [], \"e\": {}}",
  )
}

///|
test "canonical: 整数无 \".0\"、负数、浮点" {
  assert_eq(@rp.canonical_json(Json::number(1.0)), "1")
  assert_eq(@rp.canonical_json(Json::number(0.0)), "0")
  assert_eq(@rp.canonical_json(Json::number(-42.0)), "-42")
  // 浮点按最短往返表示（Python 1.5 → "1.5"）
  assert_eq(@rp.canonical_json(Json::number(1.5)), "1.5")
  assert_eq(
    @rp.canonical_json(
      jobj([
        ("int", Json::number(1.0)),
        ("neg", Json::number(-42.0)),
        ("float", Json::number(1.5)),
      ]),
    ),
    "{\"float\": 1.5, \"int\": 1, \"neg\": -42}",
  )
}

///|
test "canonical: 显式 repr 优先（保留原始数字文本）" {
  // 解析保持原始表示：1.0 与 1e2 各自原样，不归一化
  let parsed = @json.parse(
    "{\"z\": 1.0, \"a\": 100}",
    preserve_number_repr=true,
  ) catch {
    _ => fail("解析失败")
  }
  assert_eq(@rp.canonical_json(parsed), "{\"a\": 100, \"z\": 1.0}")
}

///|
test "canonical: 与 Python json.loads 往返（字符串/整数/嵌套）" {
  let source = "{\"nested\": {\"a\": {\"b\": {\"c\": [true, false, null]}}}}"
  let parsed = @json.parse(source) catch { _ => fail("解析失败") }
  assert_eq(@rp.canonical_json(parsed), source)
}

///|
test "canonical: canonical_json_utf8 与 canonical_json 字节一致" {
  let value = jobj([
    ("k", Json::string("\u{4e2d}\u{6587}")),
    ("n", Json::number(7.0)),
  ])
  let bytes = @rp.canonical_json_utf8(value)
  let text = @rp.canonical_json(value)
  // UTF-8 字节长度：`{"k": "中文", "n": 7}` = 23 字节（中文各 3 字节）
  assert_eq(bytes.length(), 23)
  assert_eq(text, "{\"k\": \"\u{4e2d}\u{6587}\", \"n\": 7}")
}

///|
test "canonical: 键排序对无关插入顺序稳定" {
  let a = jobj([
    ("c", Json::number(3.0)),
    ("a", Json::number(1.0)),
    ("b", Json::number(2.0)),
  ])
  let b = jobj([
    ("a", Json::number(1.0)),
    ("b", Json::number(2.0)),
    ("c", Json::number(3.0)),
  ])
  assert_eq(@rp.canonical_json(a), @rp.canonical_json(b))
  assert_eq(@rp.canonical_json(a), "{\"a\": 1, \"b\": 2, \"c\": 3}")
}

// ============================================================================
// qa fixture 对齐：test-suit/rhop_js/fixtures/vools_vectors.json → canonical_json 节
// （expected = 真实 vools/Python json.dumps(ensure_ascii=False, sort_keys=True)）
// ============================================================================

///|
/// 解析 fixture 的 input JSON（保留数字原始表示，避免 int 被渲染成浮点形态）。
fn canon_input(text : String) -> Json {
  @json.parse(text, preserve_number_repr=true) catch {
    _ => abort("fixture input JSON 解析失败: \{text}")
  }
}

///|
test "canonical: fixture empty_object / empty_array" {
  assert_eq(@rp.canonical_json(canon_input("{}")), "{}")
  assert_eq(@rp.canonical_json(canon_input("[]")), "[]")
}

///|
test "canonical: fixture scalars（null/bool/int/负数/零）" {
  assert_eq(
    @rp.canonical_json(
      canon_input(
        "{\"false\": false, \"int\": 42, \"negative\": -7, \"null\": null, \"true\": true, \"zero\": 0}",
      ),
    ),
    "{\"false\": false, \"int\": 42, \"negative\": -7, \"null\": null, \"true\": true, \"zero\": 0}",
  )
}

///|
test "canonical: fixture key_order（数字/大写/小写/中文键混排）" {
  assert_eq(
    @rp.canonical_json(
      canon_input(
        "{\"z\": 1, \"a\": 2, \"A\": 3, \"1\": 4, \"\u{4e2d}\u{6587}a\": 5, \"b\": 6}",
      ),
    ),
    "{\"1\": 4, \"A\": 3, \"a\": 2, \"b\": 6, \"z\": 1, \"\u{4e2d}\u{6587}a\": 5}",
  )
}

///|
test "canonical: fixture nested_unicode（中文键值 + 嵌套 + 数组）" {
  let input = canon_input(
    "{\"task_id\": \"task-001\", \"\u{4e2d}\u{6587}\u{952e}\": \"\u{4e2d}\u{6587}\u{503c}\", \"\u{5d4c}\u{5957}\": {\"\u{542f}\u{7528}\": true, \"\u{76ee}\u{6807}\": \"\u{6d4b}\u{8bd5}\u{673a}\", \"\u{7a7a}\u{503c}\": null, \"\u{91cd}\u{8bd5}\": 2}, \"\u{6570}\u{7ec4}\": [1, 2, 3, \"\u{56db}\", {\"\u{4e94}\": 5}]}",
  )
  assert_eq(
    @rp.canonical_json(input),
    "{\"task_id\": \"task-001\", \"\u{4e2d}\u{6587}\u{952e}\": \"\u{4e2d}\u{6587}\u{503c}\", \"\u{5d4c}\u{5957}\": {\"\u{542f}\u{7528}\": true, \"\u{76ee}\u{6807}\": \"\u{6d4b}\u{8bd5}\u{673a}\", \"\u{7a7a}\u{503c}\": null, \"\u{91cd}\u{8bd5}\": 2}, \"\u{6570}\u{7ec4}\": [1, 2, 3, \"\u{56db}\", {\"\u{4e94}\": 5}]}",
  )
}

///|
test "canonical: fixture deep_nest（深层嵌套对象/数组）" {
  assert_eq(
    @rp.canonical_json(
      canon_input(
        "{\"L1\": {\"L2\": {\"L3\": {\"L4\": [{\"L5\": \"\u{5e95}\"}]}}}}",
      ),
    ),
    "{\"L1\": {\"L2\": {\"L3\": {\"L4\": [{\"L5\": \"\u{5e95}\"}]}}}}",
  )
}

///|
/// 单个反斜杠（用 Char 构造，避免源码里的转义序列被编辑器/工具二次解释）。
fn bs() -> String {
  Char::from_int(92).to_string()
}

///|
test "canonical: fixture escapes（引号/反斜杠/控制字符/emoji/斜杠）" {
  let b = bs()
  // 用 b 拼 JSON 原文，避免源码层面出现易被误转义的 \\uXXXX 序列
  let input_text = "{" +
    "\"backslash\": \"a" +
    b +
    b +
    "b\", " +
    "\"backspace\": \"a" +
    b +
    "bb\", " +
    "\"cr\": \"a" +
    b +
    "rb\", " +
    "\"ctrl_0x01\": \"" +
    b +
    "u0001\", " +
    "\"emoji\": \"\u{1F680}\", " +
    "\"formfeed\": \"a" +
    b +
    "fb\", " +
    "\"newline\": \"line1" +
    b +
    "nline2\", " +
    "\"quote\": \"he said " +
    b +
    "\"hi" +
    b +
    "\"\", " +
    "\"slash\": \"a/b\", " +
    "\"tab\": \"a" +
    b +
    "tb\"}"
  let actual = @rp.canonical_json(canon_input(input_text))
  // C1 审计 F9：整串比对（原先是 10 条 contains 片段断言，拼错字段名/多出字段/键序异常都抓不到）。
  // input_text 与 fixture.vools_vectors.json canonical_json/escapes 用例的 expected 逐字节相同，
  // 整串相等即证明 canonical 输出与 Python json.dumps(ensure_ascii=False, sort_keys=True) 逐字符对齐。
  assert_eq(actual, input_text)
}

///|
test "canonical: canonical_json_ascii 与 ensure_ascii=True 同形（含代理对）" {
  let b = bs()
  // BMP 中文 → 4 位 \uXXXX（BMP 单码点不拆代理对）
  assert_eq(
    @rp.canonical_json_ascii(Json::string("\u{4e2d}\u{6587}")),
    "\"" + b + "u4e2d" + b + "u6587\"",
  )
  // 非 BMP（U+1F680 🚀）→ 代理对 \ud83d\ude80（Python 同形）
  assert_eq(
    @rp.canonical_json_ascii(Json::string("\u{1F680}")),
    "\"" + b + "ud83d" + b + "ude80\"",
  )
  // ASCII 部分两口径一致
  assert_eq(
    @rp.canonical_json_ascii(canon_input("{\"b\": 1, \"a\": \"x\"}")),
    @rp.canonical_json(canon_input("{\"b\": 1, \"a\": \"x\"}")),
  )
  // 控制字符仍是 \u00XX（0x01），emoji 在 False 口径下原样
  let esc = canon_input("{\"c\": \"" + b + "u0001\", \"e\": \"\u{1F680}\"}")
  assert_eq(
    @rp.canonical_json_ascii(esc),
    "{\"c\": \"" + b + "u0001\", \"e\": \"" + b + "ud83d" + b + "ude80\"}",
  )
  assert_eq(
    @rp.canonical_json(esc),
    "{\"c\": \"" + b + "u0001\", \"e\": \"\u{1F680}\"}",
  )
}

///|
test "canonical: 资源边界 · 深嵌套不 panic（数组 100 层 / 对象 50 层）" {
  // Python 侧同样受递归深度限制；这里只要求「可序列化且形态正确」，不 panic
  let mut deep : Json = Json::number(1.0)
  for _ in 0..<100 {
    deep = Json::array([deep])
  }
  let text = @rp.canonical_json(deep)
  assert_eq(text.length(), 100 + 1 + 100) // 100 个 '[' + "1" + 100 个 ']'
  assert_true(text.has_prefix("[[["))

  let mut deep_obj : Json = Json::string("leaf")
  for _ in 0..<50 {
    deep_obj = jobj([("k", deep_obj)])
  }
  let obj_text = @rp.canonical_json(deep_obj)
  assert_true(obj_text.contains("\"leaf\""))
  assert_eq(@rp.canonical_json_ascii(deep_obj), obj_text) // 纯 ASCII 两口径一致
}

// ============================================================================
// C2 资源审计回归：深嵌套不再栈溢出（writer 已改为显式栈迭代；旧递归实现
// 在 js 下约 2500–5000 层触发 `RangeError: Maximum call stack size exceeded`，
// 且阈值随外层调用深度漂移）。
// ============================================================================

///|
/// 构造 depth 层嵌套数组 `[[[…null…]]]`。
fn deeply_nested(depth : Int32) -> Json {
  let mut v : Json = Json::null()
  let mut i = 0
  while i < depth {
    v = Json::array([v])
    i = i + 1
  }
  v
}

///|
test "canonical: 深嵌套 5000 层不栈溢出（wasm/js/native 一致）" {
  let depth = 5000
  let text = @rp.canonical_json(deeply_nested(depth))
  assert_eq(text.length(), depth + 4 + depth) // '['*d + "null" + ']'*d
  assert_true(text.has_prefix("[[["))
  // ensure_ascii 变体走同一条迭代 writer
  assert_eq(@rp.canonical_json_ascii(deeply_nested(depth)), text)
}

///|
test "canonical: 深嵌套 20000 层（更深的资源边界，仍不崩）" {
  let depth = 20000
  let text = @rp.canonical_json(deeply_nested(depth))
  assert_eq(text.length(), depth + 4 + depth)
}

// ============================================================================
// C4 性能回归：字符串转义改为「普通字符 run 批量写入」后，转义语义必须保持。
// 覆盖：长纯文本（bulk 路径）、run 边界紧邻转义、ASCII 口径下的非 ASCII 与代理对。
// ============================================================================

///|
test "canonical: 长纯文本走 bulk 路径且字节数正确（1MB）" {
  let s = "x".repeat(1000000)
  let text = @rp.canonical_json(Json::string(s))
  assert_eq(text.length(), 1000000 + 2) // 两端引号
  assert_true(text.has_prefix("\"xxx"))
  // 1MB 内容里不应出现任何转义反斜杠
  assert_false(text.contains("\\"))
}

///|
test "canonical: run 边界转义正确（纯文本与转义字符交替）" {
  let b = bs()
  // 长 run + 每类转义 + 再长 run，验证切分不吞字符、不重复字符
  let s = "a".repeat(1000) +
    "\u{01}" +
    "b".repeat(1000) +
    "\"" +
    "c".repeat(1000) +
    "\\" +
    "d".repeat(1000) +
    "\n\t\r\u{08}\u{0C}" +
    "e".repeat(1000)
  let text = @rp.canonical_json(Json::string(s))
  // 期望用 b（反斜杠）拼接，避免源码层面的转义被二次解释
  let expected = "\"" +
    "a".repeat(1000) +
    b +
    "u0001" +
    "b".repeat(1000) +
    b +
    "\"" +
    "c".repeat(1000) +
    b +
    b +
    "d".repeat(1000) +
    b +
    "n" +
    b +
    "t" +
    b +
    "r" +
    b +
    "b" +
    b +
    "f" +
    "e".repeat(1000) +
    "\""
  assert_eq(text, expected)
}

///|
test "canonical: bulk 路径与非 ASCII / 代理对（两种口径）" {
  let b = bs()
  // ensure_ascii=false：原样（含 4 字节 emoji，走 bulk 分支）
  let s = "中".repeat(1000) + "\u{1F600}" + "文".repeat(1000)
  let plain = @rp.canonical_json(Json::string(s))
  assert_eq(plain, "\"" + s + "\"")
  // ensure_ascii=true：中文逐码元 uXXXX + emoji 代理对（用 b 拼，避免源码转义歧义）
  let ascii = @rp.canonical_json_ascii(Json::string(s))
  assert_true(ascii.contains(b + "u4e2d"))
  assert_true(ascii.contains(b + "ud83d" + b + "ude00"))
  // 转义数量可核对：2000 个中文 × 6 字符 + emoji 代理对 12 字符 + 两端引号
  assert_eq(ascii.length(), 2 + 2000 * 6 + 12)
}
