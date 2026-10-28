// ============================================================================
// rhop · JSON 规范化（两套 Python 口径，分别复刻，不做统一）
//
// ① `canonical_json`（ensure_ascii=False）—— 用于 **envelope checksum**：
//    与 `json.dumps(x, ensure_ascii=False, sort_keys=True)` 同形。
// ② `canonical_json_ascii`（ensure_ascii=True）—— 用于 **signer preimage**：
//    与 `json.dumps({"task_id":…,"result":…}, sort_keys=True)` 同形
//    （vools 的 signer.py 没传 ensure_ascii，走 Python 默认 True，
//    非 ASCII 一律转义成 `\uXXXX`）。
//
// 共同口径（执行契约 §2.1）：
//   - 对象键按 Unicode 码点升序（用 UTF-8 字节序比较，二者等价）；数组保序；
//   - 分隔符 ", " 与 ": "（Python json.dumps 默认 separators）；
//   - 转义：`"`→`\"`、`\`→`\\`、\b \f \n \r \t 用短转义，
//     其余 < 0x20 控制字符用 `\u00XX`（十六进制小写，与 CPython 一致）；
//   - `true` / `false` / `null` 小写；
//   - 数字：带原始表示（`Json` 的 `repr`，解析时开 `preserve_number_repr=true`
//     可保留）则原样输出；否则用 `Double::to_string`，整数值打印为整数形式
//     （无 ".0"，与 Python int 一致），其余为最短往返表示。
//
// 已知限制（跨实现对齐的风险点，语料须避开）：
//   - 浮点：Python `repr(1.0)` 是 "1.0"，本实现是 "1"（整数形态）；大/小指数
//     形态（Python "1e+20" vs MoonBit "1e20"）与 NaN/Infinity 的字面量也不保证
//     与 CPython 完全同形。checksum / 签名语料只用 int、字符串、布尔、null、
//     数组、嵌套对象，且整数走 `preserve_number_repr` 或整数值 Double。
// ============================================================================

///|
/// 十六进制数字字符（小写）：0..15 → '0'..'9' / 'a'..'f'。
fn hex_digit_char(value : Int32) -> Char {
  if value < 10 {
    Char::from_int(48 + value)
  } else {
    Char::from_int(87 + value)
  }
}

///|
/// `< 0x20` 控制字符的 `\u00XX` 转义（十六进制小写）。
fn write_canonical_control(buf : StringBuilder, code : Int32) -> Unit {
  buf.write_char('\\')
  buf.write_char('u')
  buf.write_char('0')
  buf.write_char('0')
  buf.write_char(hex_digit_char((code >> 4) & 0xF))
  buf.write_char(hex_digit_char(code & 0xF))
}

///|
/// 4 位 `\uXXXX` 转义（十六进制小写）。
fn write_unicode_escape(buf : StringBuilder, code : Int32) -> Unit {
  buf.write_char('\\')
  buf.write_char('u')
  buf.write_char(hex_digit_char((code >> 12) & 0xF))
  buf.write_char(hex_digit_char((code >> 8) & 0xF))
  buf.write_char(hex_digit_char((code >> 4) & 0xF))
  buf.write_char(hex_digit_char(code & 0xF))
}

///|
/// 按 Python `json.dumps` 的字符串转义规则写出带引号的字符串。
///
/// `ascii_only=true` 时复刻 `ensure_ascii=True`：所有非 ASCII 码点转成
/// `\uXXXX`，U+FFFF 以上输出 UTF-16 代理对（与 CPython 一致）。
fn write_canonical_string(
  buf : StringBuilder,
  text : String,
  ascii_only : Bool,
) -> Unit {
  buf.write_char('"')
  // 性能（C4）：按「需要转义的码元」切分，连续普通字符一次性 bulk 写入。
  // 旧实现每字符一次 write_char，10MB 纯文本 = 1000 万次调用（实测 checksum ≈3.5 s）；
  // 改成 run 合并后同一场景退化为几次 substring 写入。
  let n = text.length()
  let mut i = 0
  let mut run_start = 0
  while i < n {
    let unit = text[i]
    let code = unit.to_int()
    let plain = code >= 0x20 &&
      code != 0x22 &&
      code != 0x5C &&
      !(ascii_only && code > 0x7F)
    if plain {
      i = i + 1
    } else {
      if i > run_start {
        buf.write_string(text.substring(start=run_start, end=i))
      }
      write_canonical_escape_unit(buf, code)
      i = i + 1
      run_start = i
    }
  }
  if run_start < n {
    buf.write_string(text.substring(start=run_start, end=n))
  }
  buf.write_char('"')
}

///|
/// 写出单个码元的转义形式（`"` / 反斜杠 / 短转义 / `\u00XX` / `\uXXXX`）。
///
/// 按 **UTF-16 码元** 处理：`ascii_only` 时补充平面字符被拆成两个代理码元，
/// 分别输出 `\uD83D\uDE80`，与 Python `ensure_ascii=True` 的代理对写法逐字节一致。
fn write_canonical_escape_unit(buf : StringBuilder, code : Int32) -> Unit {
  if code == 0x22 {
    buf.write_char('\\')
    buf.write_char('"')
  } else if code == 0x5C {
    buf.write_char('\\')
    buf.write_char('\\')
  } else if code == 0x0A {
    buf.write_string("\\n")
  } else if code == 0x09 {
    buf.write_string("\\t")
  } else if code == 0x0D {
    buf.write_string("\\r")
  } else if code == 0x08 {
    buf.write_string("\\b")
  } else if code == 0x0C {
    buf.write_string("\\f")
  } else if code < 0x20 {
    write_canonical_control(buf, code)
  } else {
    write_unicode_escape(buf, code)
  }
}

///|
/// 数字的规范化文本：优先用 `Json` 保留的原始表示，否则最短往返表示。
///
/// `Double::to_string` 对整数值输出整数形态（`1.0` → `"1"`），与 Python 的
/// `int` 序列化一致；浮点的差异见本文件头部「已知限制」。
fn canonical_number(number : Double, repr : String?) -> String {
  match repr {
    Some(r) => r
    None => number.to_string()
  }
}

///|
/// 已编码键的字节序比较（UTF-8 字节序与 Unicode 码点序等价）。
///
/// 只比较预先编码好的字节，避免「每次比较都重新 encode」——排序 n 个键时
/// 比较次数是 O(n log n)，旧实现每次比较分配 2 个 Bytes，5000 键实测 ~68–135 ms。
fn compare_codepoint_bytes(a : Bytes, b : Bytes) -> Int32 {
  let na = a.length()
  let nb = b.length()
  let n = if na < nb { na } else { nb }
  let mut i = 0
  while i < n {
    let x = a[i].to_uint().to_int()
    let y = b[i].to_uint().to_int()
    if x != y {
      return x - y
    }
    i = i + 1
  }
  na - nb
}

///|
/// 取对象的键并按**码点序**排序（键的 UTF-8 编码只做一次）。
///
/// 与 Python `sorted(dict)` 一致；非 BMP 字符（emoji 等）也按码点而非
/// UTF-16 代码元排序，避免代理对比较带来的次序差异。
///
/// 资源说明：额外持有 n 个 (String, Bytes) 对（≈ 键总字节数），换来排序期零编码；
/// 键数量极大时峰值内存线性增长，但比「每次比较重新编码」少得多。
fn sorted_keys(members : Map[String, Json]) -> Array[String] {
  let pairs : Array[(String, Bytes)] = []
  for k in members.keys() {
    pairs.push((k, @utf8.encode(k)))
  }
  pairs.sort_by(fn(a, b) { compare_codepoint_bytes(a.1, b.1) })
  let keys : Array[String] = []
  for p in pairs {
    keys.push(p.0)
  }
  keys
}

///|
/// 迭代写栈帧：把「待写值 / 待写键 / 待写分隔符 / 待闭合容器」压入显式栈。
///
/// 用显式栈而非递归，是为了**消除深嵌套 Json 的调用栈溢出**（旧递归实现在
/// js 下约 2500–5000 层触发 `RangeError: Maximum call stack size exceeded`，
/// 且阈值随外层调用深度漂移；经 `Envelope` checksum / signer preimage 可达）。
priv enum CanonTask {
  /// 待写一个 JSON 值
  Val(Json)
  /// 待写一个对象键（含引号与转义）
  Key(String)
  /// 待写一段原样文本（分隔符）
  Raw(String)
  /// 待写数组闭合符
  CloseArray
  /// 待写对象闭合符
  CloseObject
}

///|
/// 写出规范化 JSON 文本（**迭代实现**：显式栈，深度只受堆内存限制）。
///
/// 输出与递归版逐字节一致（分隔符 `", "` / `": "`、键升序、转义规则不变），
/// 但不再受调用栈深度限制：深度 5000 / 50000 的嵌套数组也能稳定写出。
fn write_canonical_json(
  buf : StringBuilder,
  value : Json,
  ascii_only : Bool,
) -> Unit {
  let stack : Array[CanonTask] = [Val(value)]
  while !stack.is_empty() {
    let task = stack.pop().unwrap()
    match task {
      Raw(text) => buf.write_string(text)
      Key(key) => write_canonical_string(buf, key, ascii_only)
      CloseArray => buf.write_char(']')
      CloseObject => buf.write_char('}')
      Val(v) =>
        match v {
          Null => buf.write_string("null")
          True => buf.write_string("true")
          False => buf.write_string("false")
          Number(n, repr~) => buf.write_string(canonical_number(n, repr))
          String(s) => write_canonical_string(buf, s, ascii_only)
          Array(items) =>
            if items.is_empty() {
              buf.write_string("[]")
            } else {
              buf.write_char('[')
              stack.push(CloseArray)
              let mut i = items.length() - 1
              while i >= 0 {
                stack.push(Val(items[i]))
                if i > 0 {
                  stack.push(Raw(", "))
                }
                i = i - 1
              }
            }
          Object(members) =>
            if members.is_empty() {
              buf.write_string("{}")
            } else {
              let keys = sorted_keys(members)
              buf.write_char('{')
              stack.push(CloseObject)
              let mut i = keys.length() - 1
              while i >= 0 {
                let key = keys[i]
                stack.push(Val(members.get(key).unwrap_or(Json::null())))
                stack.push(Raw(": "))
                stack.push(Key(key))
                if i > 0 {
                  stack.push(Raw(", "))
                }
                i = i - 1
              }
            }
        }
    }
  }
}

///|
/// 规范化 JSON 文本（**ensure_ascii=False**，envelope checksum 用）。
///
/// 与 Python `json.dumps(value, ensure_ascii=False, sort_keys=True)` 同形：
/// 键升序、分隔符 `", "` / `": "`、非 ASCII 原样、控制字符按 Python 规则转义。
/// 信封 checksum 以此函数的输出为准，故两侧必须逐字节一致。
/// wasm / js / native 三目标均可用（纯逻辑）。
pub fn canonical_json(value : Json) -> String {
  let buf = StringBuilder(size_hint=64)
  write_canonical_json(buf, value, false)
  buf.to_string()
}

///|
/// 规范化 JSON 的 UTF-8 字节（喂 `sha256` 的便捷入口）。
pub fn canonical_json_utf8(value : Json) -> Bytes {
  @utf8.encode(canonical_json(value))
}

///|
/// 规范化 JSON 文本（**ensure_ascii=True**，signer preimage 用）。
///
/// 与 Python `json.dumps({"task_id":…, "result":…}, sort_keys=True)` 同形：
/// 其余规则与 `canonical_json` 相同，但**所有非 ASCII 字符转义成 `\uXXXX`**
/// （U+FFFF 以上输出代理对）。vools 的 `FileHashSigner` / `NPUSigner` 走这条口径。
pub fn canonical_json_ascii(value : Json) -> String {
  let buf = StringBuilder(size_hint=64)
  write_canonical_json(buf, value, true)
  buf.to_string()
}

///|
/// ensure_ascii=True 口径的 UTF-8 字节（signer 的 md5/sha256 preimage 入口）。
pub fn canonical_json_ascii_utf8(value : Json) -> Bytes {
  @utf8.encode(canonical_json_ascii(value))
}

///|
/// 构造规范 JSON 对象：键值对按传入顺序插入 `Map`，输出时按键升序。
///
/// 便捷构造器，避免调用方到处写 `Json::object(Map([...]))`。
pub fn canonical_object(entries : Array[(String, Json)]) -> Json {
  let map : Map[String, Json] = Map([])
  for i in 0..<entries.length() {
    let (k, v) = entries[i]
    map[k] = v
  }
  Json::object(map)
}
