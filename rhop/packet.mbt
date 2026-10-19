// ============================================================================
// rhop · 协议消息与信封编解码（纯 MoonBit，跨平台）
// RhopPacket：应用层消息（id / source / kind / payload / at）
// RhopEnvelope：.rhop 文件内容 {"v":1,"alg":...,"ct":...}，ct 为密文段
// ============================================================================

///|
/// RHOP 应用层消息包
pub struct RhopPacket {
  /// 消息唯一 id（发送方生成，接收方可按 id 去重）
  id : String
  /// 发送方标识（进程名 / 节点名）
  source : String
  /// 消息类型（command / state / event / ack 等）
  kind : String
  /// 载荷（任意 JSON）
  payload : Json
  /// 发送时刻（epoch 毫秒）
  at : Int64
}

///|
pub fn RhopPacket::new(
  id : String,
  source : String,
  kind : String,
  payload : Json,
  at : Int64,
) -> RhopPacket {
  { id, source, kind, payload, at, }
}

///|
/// JSON 字符串转义（复用 Json::stringify 对 string 的转义）
fn json_escape(s : String) -> String {
  Json::stringify(Json::string(s))
}

///|
/// 序列化为协议 JSON 文本（不含信封）
pub fn RhopPacket::to_json_string(self : RhopPacket) -> String {
  let payload_s = Json::stringify(self.payload)
  "{\"id\":\{json_escape(self.id)},\"source\":\{json_escape(self.source)},\"kind\":\{json_escape(self.kind)},\"payload\":\{payload_s},\"at\":\{self.at.to_string()}}"
}

///|
/// 从协议 JSON 解析
pub fn RhopPacket::from_json_text(text : String) -> Result[RhopPacket, String] {
  let j = @json.parse(text) catch {
    _ => return Err("RhopPacket: JSON 解析失败")
  }
  if j
    is {
      "id": String(id),
      "source": String(source),
      "kind": String(kind),
      "payload": payload,
      "at": Number(at, ..),
      ..
    } {
    Ok({ id, source, kind, payload, at: at.to_int64(), })
  } else {
    Err("RhopPacket: 字段缺失或类型错误")
  }
}

///|
/// .rhop 信封
pub struct RhopEnvelope {
  /// 协议版本
  v : Int32
  /// 加密算法标识（none / aes-256-gcm）
  alg : String
  /// 密文段（alg=none 时为 base64(明文)）
  ct : String
}

///|
/// 编码为 .rhop 文件内容
pub fn RhopEnvelope::encode(v : Int32, alg : String, ct : String) -> String {
  "{\"v\":\{v.to_string()},\"alg\":\{json_escape(alg)},\"ct\":\{json_escape(ct)}}"
}

///|
/// 解析 .rhop 文件内容
pub fn RhopEnvelope::decode(text : String) -> Result[RhopEnvelope, String] {
  let j = @json.parse(text) catch {
    _ => return Err("RhopEnvelope: JSON 解析失败")
  }
  if j is { "v": Number(v, ..), "alg": String(alg), "ct": String(ct), .. } {
    Ok({ v: v.to_int(), alg, ct, })
  } else {
    Err("RhopEnvelope: 字段缺失或类型错误")
  }
}
