// ============================================================================
// rhop_task · 心跳（存活看护）
//
// 对照 vools.rhop.task.heartbeat.Heartbeat：
//   - 写端（B 侧 worker）按 interval_sec 周期性把 `{worker_id, ts, epoch, closed}`
//     JSON 写进共享介质上的 `<name>.heartbeat` 文件（复用 rhop 的 @rp.SharedPath 原子写）；
//   - 读端（A 侧需求端）据此判断对端是否活着：age <= stale_after_sec 且未 closed；
//   - closed 标记表示 worker 主动下线（区别于"崩了/挂了"）；
//   - 时间戳同时给 ISO 文本与 epoch 秒：ISO 便于人读，epoch 便于算 age，
//     避免"解析字符串时间"带来的时区/格式坑。
//
// HeartbeatPump：在 js 目标用 `setInterval` 后台周期性 beat，**timer 必须 unref**，
// 否则测试进程会被一个永远不结束的 interval 挂住（我们在 relay/watch 上刚踩过的
// 一类问题，这里提前堵掉）；非 js 目标 start 返回可诊断 Err。
// ============================================================================

///|
/// 心跳文件内容（写端写、读端解析）。
pub(all) struct HeartbeatSnapshot {
  /// worker 标识
  worker_id : String
  /// 写入时刻（ISO UTC）
  ts : String
  /// 写入时刻（epoch 秒）
  epoch : Int64
  /// 是否已主动下线
  closed : Bool
}

///|
/// 心跳看护对象。
pub(all) struct Heartbeat {
  /// 共享介质（读写同一视图即可；None 时所有操作返回可诊断 Err）
  shared : &@rp.SharedPath?
  /// 心跳文件名（如 "rhop-link.heartbeat"）
  filename : String
  /// 写间隔（秒）
  interval_sec : Double
  /// 判死阈值（秒）
  stale_after_sec : Double
  /// closed 标记的文本值（对齐 vools 同名常量，默认 "closed"）
  closed_token : String
  /// 本端 worker 标识
  worker_id : String
  /// 「未来时间戳」容差（秒）：超出即判 dead（fail-closed，对齐 vools
  /// `max_future_skew_sec` 的防「时钟超前 / 伪造」语义，默认 60s）
  max_future_skew_sec : Double
}

///|
/// 构造心跳对象（`max_future_skew_sec` 默认 60s，与 vools 默认值一致）。
pub fn Heartbeat::new(
  shared : &@rp.SharedPath?,
  filename : String,
  interval_sec : Double,
  stale_after_sec : Double,
  closed_token : String,
  worker_id : String,
) -> Heartbeat {
  {
    shared,
    filename,
    interval_sec,
    stale_after_sec,
    closed_token: if closed_token == "" {
      "closed"
    } else {
      closed_token
    },
    worker_id,
    max_future_skew_sec: 60.0,
  }
}

///|
/// 覆盖「未来时间戳」容差（秒）。超出该容差的心跳一律判 dead。
pub fn Heartbeat::with_max_future_skew(
  self : Heartbeat,
  sec : Double,
) -> Heartbeat {
  { ..self, max_future_skew_sec: if sec <= 0.0 { 60.0 } else { sec }, }
}

///|
/// 从 TaskConfig 的 `queue.heartbeat` 段取一个字段（缺省 None）。
fn queue_heartbeat_field(config : TaskConfig, key : String) -> Json? {
  match config.queue {
    Object(m) =>
      match m.get("heartbeat") {
        Some(Object(h)) => h.get(key)
        _ => None
      }
    _ => None
  }
}

///|
/// 从 TaskConfig 构造（文件名/间隔/阈值取配置；closed_token 与未来时间戳容差
/// 也从 `queue.heartbeat` 段读，缺省 "closed" / 60s）。
pub fn Heartbeat::from_config(
  shared : &@rp.SharedPath?,
  config : TaskConfig,
) -> Heartbeat {
  let closed_token = match jstr(queue_heartbeat_field(config, "closed_token")) {
    Some(s) => if s == "" { "closed" } else { s }
    None => "closed"
  }
  let skew = match
    jdouble(queue_heartbeat_field(config, "max_future_skew_sec")) {
    Some(v) => v
    None => 60.0
  }
  Heartbeat::new(
    shared,
    config.heartbeat_file,
    config.heartbeat_interval_sec,
    config.heartbeat_stale_after_sec,
    closed_token,
    config.worker_id(),
  ).with_max_future_skew(skew)
}

///|
/// 心跳文件名。
pub fn Heartbeat::filename(self : Heartbeat) -> String {
  self.filename
}

///|
/// 判死阈值（秒）。
pub fn Heartbeat::stale_after_sec(self : Heartbeat) -> Double {
  self.stale_after_sec
}

///|
/// 「未来时间戳」容差（秒）。
pub fn Heartbeat::max_future_skew_sec(self : Heartbeat) -> Double {
  self.max_future_skew_sec
}

///|
/// 数字补零到 3 位。
fn pad3(v : Int64) -> String {
  if v < 10L {
    "00" + v.to_string()
  } else if v < 100L {
    "0" + v.to_string()
  } else {
    v.to_string()
  }
}

///|
/// 把 `YYYY-MM-DDTHH:MM:SSZ` 形状的秒级 ISO 插入 6 位微秒小数。
fn insert_micros(sec_form : String, frac6 : String) -> String {
  let head = match sec_form.get_view(end=sec_form.length() - 1) {
    Some(v) => v.to_owned()
    None => sec_form
  }
  head + "." + frac6 + "Z"
}

///|
/// 把任意可解析时间串归一成 **vools 同形**（带 6 位微秒）的 ISO：
/// `%Y-%m-%dT%H:%M:%S.%fZ`。输入自带小数则保留（补/截到 6 位），否则补 `.000000`。
fn with_micros(raw : String) -> String {
  let trimmed = raw.trim().to_owned()
  let sec_form = match to_iso(trimmed) {
    Some(c) => c
    None => return trimmed
  }
  // 取原始串里的小数部分（去掉末尾 Z 后只保留数字）
  let mut frac = ""
  match trimmed.find(".") {
    Some(i) =>
      match trimmed.get_view(start=i + 1) {
        Some(tail) => {
          let t = tail.to_owned()
          let digits = if t.has_suffix("Z") {
            match t.get_view(end=t.length() - 1) {
              Some(v) => v.to_owned()
              None => t
            }
          } else {
            t
          }
          for ch in digits {
            if ch >= '0' && ch <= '9' {
              frac = frac + ch.to_string()
            }
          }
        }
        None => ()
      }
    None => ()
  }
  let mut frac6 = frac
  while frac6.length() < 6 {
    frac6 = frac6 + "0"
  }
  if frac6.length() > 6 {
    frac6 = match frac6.get_view(end=6) {
      Some(v) => v.to_owned()
      None => frac6
    }
  }
  insert_micros(sec_form, frac6)
}

///|
/// 用进程时钟生成带 6 位微秒的 ISO（MoonBit 只有毫秒精度 ⇒ `ms*1000` 补 3 个 0，
/// 形如 `2026-10-28T03:00:11.123000Z`，与 vools `%f` 同形）。
fn now_micros_text() -> String {
  let ms = @env.now().reinterpret_as_int64()
  let secs = ms / 1000L
  let mmm = ms % 1000L
  insert_micros(format_epoch_seconds(secs), pad3(mmm) + "000")
}

///|
/// 心跳文件内容（**vools 同款纯文本**）：`include_worker` 且有 worker_id 时
/// `"<ISO> <worker_id>"`，否则只写 `<ISO>`。对应 vools `heartbeat.py` 的
/// `"%s %s" % (ts, worker_id) if (include_worker and worker_id) else ts`
/// —— 注意 vools 的 `include_worker` **默认 False**，这里也默认 False。
fn beat_text(ts : String, worker_id : String, include_worker : Bool) -> String {
  if include_worker && worker_id != "" {
    ts + " " + worker_id
  } else {
    ts
  }
}

///|
/// 按空白（空格/制表/换行）切分，丢弃空段（等价 Python `text.split()`）。
fn split_ws(text : String) -> Array[String] {
  let out : Array[String] = []
  let n = text.length()
  let mut start = 0
  let mut i = 0
  while i <= n {
    let is_sep = if i == n {
      true
    } else {
      match text.get_char(i) {
        Some(c) => c == ' ' || c == '\t' || c == '\r' || c == '\n'
        None => true
      }
    }
    if is_sep {
      if i > start {
        match text.get_view(start~, end=i) {
          Some(v) => out.push(v.to_owned())
          None => ()
        }
      }
      start = i + 1
    }
    i = i + 1
  }
  out
}

///|
/// 写一次心跳（原子写：由 @rp.SharedPath 实现保证 tmp+rename）。
pub fn Heartbeat::beat(
  self : Heartbeat,
  now : String?,
  include_worker~ : Bool = false,
) -> Result[Unit, String] {
  let raw = match now {
    Some(v) => if v == "" { now_micros_text() } else { v }
    None => now_micros_text()
  }
  // 归一成 vools 同形 `YYYY-MM-DDTHH:MM:SS.ffffffZ`（带 6 位微秒）：
  // ① 与 vools TIMESTAMP_FORMAT 字节同形；② 不含空格，不会把 `<ts> <worker>`
  // 的空白切分弄坏（vools 读端按空白切分）。
  let ts = with_micros(raw)
  let text = beat_text(ts, self.worker_id, include_worker)
  match self.shared {
    None => Err("rhop_task: 心跳缺少共享介质（shared=None）")
    Some(sp) =>
      match @rp.SharedPath::write_text(sp, self.filename, text) {
        Err(e) => Err("rhop_task: 写心跳失败 \{self.filename}: \{e}")
        Ok(_) => Ok(())
      }
  }
}

///|
/// 写入「主动下线」标记：内容是**字面量 `closed_token`**（对齐 vools
/// `_write_raw(self.closed_token)`；读端按整串相等判定停机），不是 JSON。
pub fn Heartbeat::mark_closed(
  self : Heartbeat,
  now : String?,
) -> Result[Unit, String] {
  let _ = now
  match self.shared {
    None => Err("rhop_task: 心跳缺少共享介质（shared=None）")
    Some(sp) =>
      match @rp.SharedPath::write_text(sp, self.filename, self.closed_token) {
        Err(e) =>
          Err("rhop_task: 写心跳下线标记失败 \{self.filename}: \{e}")
        Ok(_) => Ok(())
      }
  }
}

///|
/// 读并解析心跳文件（**三级兼容**）；文件不存在/内容无法识别 → Ok(None)。
///
/// 解析顺序（对齐 vools `Heartbeat.read` 的语义 + 兼容本实现早期版本）：
/// 1. 整串 == `closed_token` ⇒ 停机哨兵（vools 的写法）；
/// 2. JSON 对象（本实现早期版本写出的存量文件）；
/// 3. vools 纯文本 `<ISO> [worker_id]`：`parts[0]` 当 ISO，`parts[1]` 当 worker。
///    ISO 解析不了就返回 None —— **不猜**。
pub fn Heartbeat::read(self : Heartbeat) -> Result[HeartbeatSnapshot?, String] {
  match self.shared {
    None => Err("rhop_task: 心跳缺少共享介质（shared=None）")
    Some(sp) => {
      if !@rp.SharedPath::exists(sp, self.filename) {
        return Ok(None)
      }
      let text = match @rp.SharedPath::read_text(sp, self.filename) {
        Err(_) => return Ok(None)
        Ok(v) => v
      }
      let trimmed = text.trim().to_owned()
      if trimmed == "" {
        return Ok(None)
      }
      // ① vools 停机哨兵
      if trimmed == self.closed_token {
        return Ok(Some({ worker_id: "", ts: "", epoch: 0L, closed: true, }))
      }
      // ② JSON（兼容存量）
      if trimmed.has_prefix("{") {
        // 解析失败时回落到 ③ 纯文本分支（而不是直接判 None）
        let parsed = @json.parse(trimmed) catch { _ => Json::null() }
        match parsed {
          Object(m) =>
            match m.get("ts") {
              Some(String(ts)) => {
                let wid = jstr(m.get("worker_id")).unwrap_or("")
                let epoch = match jdouble(m.get("epoch")) {
                  Some(e) => e.to_int64()
                  None =>
                    match parse_iso(ts) {
                      Some(e) => e
                      None => 0L
                    }
                }
                let closed = jbool(m.get("closed")).unwrap_or(false)
                return Ok(Some({ worker_id: wid, ts, epoch, closed, }))
              }
              _ => ()
            }
          _ => ()
        }
      }
      // ③ vools 纯文本 `<ISO> [worker_id]`
      let parts = split_ws(trimmed)
      if parts.length() == 0 {
        return Ok(None)
      }
      let stamp = parts[0]
      let epoch = match parse_iso(stamp) {
        Some(e) => e
        None => return Ok(None)
      }
      let worker = if parts.length() > 1 { parts[1] } else { "" }
      Ok(Some({ worker_id: worker, ts: stamp, epoch, closed: false, }))
    }
  }
}

///|
/// 从心跳内容判断是否存活：未 closed、未过期，且未来时间戳不超过容差。
///
/// **fail-closed**：未来时间戳超出 `max_future_skew_sec` 一律判 dead
/// （对齐 vools：否则一个时钟超前/被篡改的心跳会让已死的对端"再活"很久）。
fn snapshot_alive(
  snap : HeartbeatSnapshot,
  stale_after_sec : Double,
  max_future_skew_sec : Double,
  now_secs : Int64,
) -> Bool {
  if snap.closed {
    return false
  }
  let age = (now_secs - snap.epoch).to_double()
  if age < -max_future_skew_sec {
    return false
  }
  age <= stale_after_sec
}

///|
/// 是否存活（文件不存在/过期/已下线/未来时间戳超容差 → false）。
pub fn Heartbeat::is_alive(self : Heartbeat, now_secs : Int64?) -> Bool {
  let now = match now_secs {
    Some(v) => v
    None => utcnow_seconds()
  }
  match self.read() {
    Err(_) => false
    Ok(None) => false
    Ok(Some(snap)) =>
      snapshot_alive(snap, self.stale_after_sec, self.max_future_skew_sec, now)
  }
}

///|
/// 存活检查 + 可诊断原因（`(alive, reason)`）。
pub fn Heartbeat::check(
  self : Heartbeat,
  now_secs : Int64?,
) -> Result[(Bool, String), String] {
  let now = match now_secs {
    Some(v) => v
    None => utcnow_seconds()
  }
  match self.read() {
    Err(e) => Ok((false, e))
    Ok(None) => Ok((false, "心跳文件不存在: " + self.filename))
    Ok(Some(snap)) => {
      if snap.closed {
        return Ok((false, "对端已主动下线（closed=true）"))
      }
      let age = (now - snap.epoch).to_double()
      if age < -self.max_future_skew_sec {
        // fail-closed：未来时间戳超容差 ⇒ 判 dead（vools 同语义，防伪造/时钟超前）
        return Ok(
          (
            false,
            "心跳时间戳在未来 " +
            (-age).to_string() +
            "s（超过容差 " +
            self.max_future_skew_sec.to_string() +
            "s），疑似时钟超前或伪造",
          ),
        )
      }
      if age < 0.0 {
        // 容差内的轻微超前：仍判存活，但要说明
        return Ok(
          (
            true,
            "对端心跳时间戳轻微超前（时钟偏差 " +
            age.to_string() +
            "s，在容差 " +
            self.max_future_skew_sec.to_string() +
            "s 内）",
          ),
        )
      }
      if age > self.stale_after_sec {
        return Ok(
          (
            false,
            "心跳过期：age=" +
            age.to_string() +
            "s > stale_after=" +
            self.stale_after_sec.to_string() +
            "s（worker=" +
            snap.worker_id +
            "）",
          ),
        )
      }
      Ok((true, "存活（age=" + age.to_string() + "s）"))
    }
  }
}

///|
/// 删除心跳文件（worker 正常退出时可调用；不存在视为成功）。
pub fn Heartbeat::clear(self : Heartbeat) -> Result[Unit, String] {
  match self.shared {
    None => Err("rhop_task: 心跳缺少共享介质（shared=None）")
    Some(sp) => @rp.SharedPath::remove(sp, self.filename)
  }
}

// ---------------------------------------------------------------------------
// 后台心跳泵（js setInterval；非 js 可诊断 Err）
// ---------------------------------------------------------------------------

///|
/// 后台心跳泵：start 后周期性调用 `beat()`，stop 时清理 timer。
///
/// **timer 一律 `unref()`**：否则一个没被 stop 的 interval 会让 node 进程永不退出
/// （与我们在 relay/watch 上遇到的那类挂死同源）。测试与 CLI 都必须 stop。
pub struct HeartbeatPump {
  /// 被驱动的心跳对象
  hb : Heartbeat
  /// timer 注册 id（0 = 未运行）
  mut timer : Int64
  /// 最近一次写入是否成功（诊断用）
  mut last_ok : Bool
  /// 最近一次错误
  mut last_error : String
}

///|
/// 构造心跳泵（未启动）。
pub fn HeartbeatPump::new(hb : Heartbeat) -> HeartbeatPump {
  { hb, timer: 0L, last_ok: false, last_error: "", }
}

///|
/// 当前是否在跑。
pub fn HeartbeatPump::is_running(self : HeartbeatPump) -> Bool {
  self.timer != 0L
}

///|
/// 最近一次 beat 是否成功。
pub fn HeartbeatPump::last_ok(self : HeartbeatPump) -> Bool {
  self.last_ok
}

///|
/// 启动（幂等）：立刻 beat 一次，再按 interval 周期 beat。
pub fn HeartbeatPump::start(self : HeartbeatPump) -> Result[Unit, String] {
  if self.timer != 0L {
    return Ok(())
  }
  // 泵写心跳时带上 worker_id（便于运维排查），与 vools 的 include_worker=True 用例一致。
  match self.hb.beat(None, include_worker=true) {
    Ok(_) => self.last_ok = true
    Err(e) => {
      self.last_error = e
      return Err(e)
    }
  }
  let ms = (self.hb.interval_sec * 1000.0).to_int()
  let interval = if ms < 50 { 50 } else { ms }
  // 周期回调只需把心跳写出去；内部 last_ok/last_error 反映的是「启动时那一次 beat」，
  // 因为 MoonBit 值语义下闭包改不到调用方的副本（这点在文档里写明，不做假承诺）。
  let hb_copy = self.hb
  let id = pump_spawn(interval, fn() {
    let _ = hb_copy.beat(None, include_worker=true)
  })
  if id < 0L {
    return Err(
      "rhop_task: 无法启动心跳定时器（仅 js 目标支持 setInterval）",
    )
  }
  self.timer = id
  Ok(())
}

///|
/// 停止（幂等）：清理 timer，**必须调用**否则会留下活跃句柄。
pub fn HeartbeatPump::stop(self : HeartbeatPump) -> Unit {
  if self.timer != 0L {
    pump_clear(self.timer)
    self.timer = 0L
  }
}

///|
/// 停止并写「已下线」标记（worker 优雅退出的推荐姿势）。
pub fn HeartbeatPump::shutdown(self : HeartbeatPump) -> Result[Unit, String] {
  self.stop()
  self.hb.mark_closed(None)
}

// ---------------------------------------------------------------------------
// setInterval FFI（js；timer unref 防挂死）
// ---------------------------------------------------------------------------

///|
/// 起一个 interval（回调 tick），返回 timer id；失败 -1。
/// **注册后立刻 unref()** —— 不让它成为"进程不退出"的原因。
#cfg(target="js")
extern "js" fn ffi_pump_spawn(interval_ms : Int32, cb : () -> Unit) -> Int64 =
  #| (ms, cb) => { const G = globalThis; try { if (!G.__rxmbt_pump_reg) { G.__rxmbt_pump_reg = new Map(); G.__rxmbt_pump_seq = 1; } const id = G.__rxmbt_pump_seq++; const t = setInterval(() => { try { cb(); } catch (_e) {} }, Number(ms)); try { t.unref(); } catch (_e) {} G.__rxmbt_pump_reg.set(id, t); return BigInt(id); } catch (e) { return BigInt(-1); } }

///|
/// 清掉一个 interval。
#cfg(target="js")
extern "js" fn ffi_pump_clear(id : Int64) -> Unit =
  #| (id) => { const G = globalThis; if (!G.__rxmbt_pump_reg) { return; } const key = Number(id); const t = G.__rxmbt_pump_reg.get(key); if (t !== undefined) { try { clearInterval(t); } catch (_e) {} G.__rxmbt_pump_reg.delete(key); } }

///|
/// js：起 interval。
#cfg(target="js")
fn pump_spawn(interval_ms : Int32, cb : () -> Unit) -> Int64 {
  ffi_pump_spawn(interval_ms, cb)
}

///|
/// 非 js：无定时器能力，返回 -1（调用方据此返回可诊断 Err）。
#cfg(not(target="js"))
fn pump_spawn(interval_ms : Int32, cb : () -> Unit) -> Int64 {
  -1L
}

///|
/// js：清 interval。
#cfg(target="js")
fn pump_clear(id : Int64) -> Unit {
  ffi_pump_clear(id)
}

///|
/// 非 js：空操作。
#cfg(not(target="js"))
fn pump_clear(id : Int64) -> Unit {
  ()
}
