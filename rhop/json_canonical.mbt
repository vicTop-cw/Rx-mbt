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
  for c in text {
    let code = c.to_int()
    if c == '"' {
      buf.write_char('\\')
      buf.write_char('"')
    } else if c == '\\' {
      buf.write_char('\\')
      buf.write_char('\\')
    } else if c == '\n' {
      buf.write_string("\\n")
    } else if c == '\t' {
      buf.write_string("\\t")
    } else if c == '\r' {
      buf.write_string("\\r")
    } else if c == '\u{08}' {
      buf.write_string("\\b")
    } else if c == '\u{0C}' {
      buf.write_string("\\f")
    } else if code < 0x20 {
      write_canonical_control(buf, code)
    } else if ascii_only && code > 0x7F {
      if code <= 0xFFFF {
        write_unicode_escape(buf, code)
      } else {
        // U+10000..U+10FFFF → UTF-16 代理对
        let v = code - 0x10000
        write_unicode_escape(buf, 0xD800 + (v >> 10))
        write_unicode_escape(buf, 0xDC00 + (v & 0x3FF))
      }
    } else {
      buf.write_char(c)
    }
  }
  buf.write_char('"')
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
/// 字符串的码点序比较（UTF-8 字节序与 Unicode 码点序等价），供对象键排序用。
///
/// 与 Python `sorted(dict)` 一致；非 BMP 字符（emoji 等）也按码点而非
/// UTF-16 代码元排序，避免代理对比较带来的次序差异。
fn compare_codepoint(a : String, b : String) -> Int32 {
  let ba = @utf8.encode(a)
  let bb = @utf8.encode(b)
  let na = ba.length()
  let nb = bb.length()
  let n = if na < nb { na } else { nb }
  let mut i = 0
  while i < n {
    let x = ba[i].to_uint().to_int()
    let y = bb[i].to_uint().to_int()
    if x != y {
      return x - y
    }
    i = i + 1
  }
  na - nb
}

///|
/// 递归写出规范化 JSON 文本。
fn write_canonical_json(
  buf : StringBuilder,
  value : Json,
  ascii_only : Bool,
) -> Unit {
  match value {
    Null => buf.write_string("null")
    True => buf.write_string("true")
    False => buf.write_string("false")
    Number(n, repr~) => buf.write_string(canonical_number(n, repr))
    String(s) => write_canonical_string(buf, s, ascii_only)
    Array(items) => {
      buf.write_char('[')
      for i in 0..<items.length() {
        if i > 0 {
          buf.write_string(", ")
        }
        write_canonical_json(buf, items[i], ascii_only)
      }
      buf.write_char(']')
    }
    Object(members) => {
      let keys : Array[String] = []
      for k in members.keys() {
        keys.push(k)
      }
      keys.sort_by(compare_codepoint)
      buf.write_char('{')
      for i in 0..<keys.length() {
        if i > 0 {
          buf.write_string(", ")
        }
        let key = keys[i]
        write_canonical_string(buf, key, ascii_only)
        buf.write_string(": ")
        match members.get(key) {
          Some(v) => write_canonical_json(buf, v, ascii_only)
          None => buf.write_string("null")
        }
      }
      buf.write_char('}')
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
