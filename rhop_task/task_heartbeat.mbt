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
  /// closed 标记的文本值
  closed_token : String
  /// 本端 worker 标识
  worker_id : String
}

///|
/// 构造心跳对象。
pub fn Heartbeat::new(
  shared : &@rp.SharedPath?,
  filename : String,
  interval_sec : Double,
  stale_after_sec : Double,
  closed_token : String,
  worker_id : String,
) -> Heartbeat {
  { shared, filename, interval_sec, stale_after_sec, closed_token, worker_id, }
}

///|
/// 从 TaskConfig 构造（文件名/间隔/阈值/closed_token 全取配置）。
pub fn Heartbeat::from_config(
  shared : &@rp.SharedPath?,
  config : TaskConfig,
) -> Heartbeat {
  Heartbeat::new(
    shared,
    config.heartbeat_file,
    config.heartbeat_interval_sec,
    config.heartbeat_stale_after_sec,
    "closed",
    config.worker_id(),
  )
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
/// 把心跳序列化成文件内容（单行 JSON）。
fn heartbeat_payload(
  worker_id : String,
  ts : String,
  epoch : Int64,
  closed : Bool,
  closed_token : String,
) -> String {
  Json::stringify(
    Json::object({
      "worker_id": Json::string(worker_id),
      "ts": Json::string(ts),
      "epoch": Json::number(epoch.to_double()),
      "closed": Json::boolean(closed),
      "closed_token": Json::string(closed_token),
    }),
  )
}

///|
/// 写一次心跳（原子写：由 @rp.SharedPath 实现保证 tmp+rename）。
pub fn Heartbeat::beat(self : Heartbeat, now : String?) -> Result[Unit, String] {
  let ts = match now {
    Some(v) => if v == "" { utcnow_iso() } else { v }
    None => utcnow_iso()
  }
  let epoch = match parse_iso(ts) {
    Some(e) => e
    None => utcnow_seconds()
  }
  let text = heartbeat_payload(
    self.worker_id,
    ts,
    epoch,
    false,
    self.closed_token,
  )
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
/// 写入「主动下线」标记（closed=true）。
pub fn Heartbeat::mark_closed(
  self : Heartbeat,
  now : String?,
) -> Result[Unit, String] {
  let ts = match now {
    Some(v) => if v == "" { utcnow_iso() } else { v }
    None => utcnow_iso()
  }
  let epoch = match parse_iso(ts) {
    Some(e) => e
    None => utcnow_seconds()
  }
  let text = heartbeat_payload(
    self.worker_id,
    ts,
    epoch,
    true,
    self.closed_token,
  )
  match self.shared {
    None => Err("rhop_task: 心跳缺少共享介质（shared=None）")
    Some(sp) =>
      match @rp.SharedPath::write_text(sp, self.filename, text) {
        Err(e) =>
          Err("rhop_task: 写心跳下线标记失败 \{self.filename}: \{e}")
        Ok(_) => Ok(())
      }
  }
}

///|
/// 读并解析心跳文件；文件不存在/内容非法 → Ok(None)。
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
      let j = @json.parse(text) catch { _ => return Ok(None) }
      match j {
        {
          "worker_id": String(wid),
          "ts": String(ts),
          "epoch": Number(ep, ..),
          "closed": closed_j,
          ..
        } =>
          Ok(
            Some({
              worker_id: wid,
              ts,
              epoch: ep.to_int64(),
              closed: match closed_j {
                True => true
                False => false
                _ => false
              },
            }),
          )
        _ => Ok(None)
      }
    }
  }
}

///|
/// 从心跳内容判断是否存活：未 closed 且 age <= stale_after_sec。
fn snapshot_alive(
  snap : HeartbeatSnapshot,
  stale_after_sec : Double,
  now_secs : Int64,
) -> Bool {
  if snap.closed {
    return false
  }
  let age = (now_secs - snap.epoch).to_double()
  age >= 0.0 && age <= stale_after_sec
}

///|
/// 是否存活（文件不存在/过期/已下线 → false）。
pub fn Heartbeat::is_alive(self : Heartbeat, now_secs : Int64?) -> Bool {
  let now = match now_secs {
    Some(v) => v
    None => utcnow_seconds()
  }
  match self.read() {
    Err(_) => false
    Ok(None) => false
    Ok(Some(snap)) => snapshot_alive(snap, self.stale_after_sec, now)
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
      if age < 0.0 {
        // 时钟回拨/跨机时钟偏差：不判死，但要说明
        return Ok(
          (
            true,
            "对端心跳时间戳在未来（时钟偏差 " +
            age.to_string() +
            "s）",
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
  match self.hb.beat(None) {
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
  let id = pump_spawn(interval, fn() { let _ = hb_copy.beat(None) })
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
