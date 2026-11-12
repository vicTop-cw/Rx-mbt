///|
/// RX-MBT rhop 同机器异进程演示：
///   node rhop_demo.js send <shared_path> [count]   （进程 A：发送 N 条加密消息）
///   node rhop_demo.js watch <shared_path> [count]  （进程 B：监控 shared path，接收并解密全部）
///   node rhop_demo.js watch-skip <shared_path>     （进程 B：跳过 shared path 已有历史，只收新消息）
///
/// 先起 watch 进程，再起 send 进程，验证 shared path 事件驱动传输。
extern "js" fn ffi_argv_at(i : Int32) -> String =
  #| (i) => {
  #|   const a = (typeof process !== "undefined" && process.argv) ? process.argv.slice(2) : [];
  #|   return (i < a.length) ? a[i] : "";
  #| }

///|
extern "js" fn ffi_exit(code : Int32) -> Unit =
  #| (code) => { process.exit(code); }

///|
const DEMO_COUNT : Int32 = 5

///|
const DEMO_PASSWORD : String = "demo-password"

///|
fn main {
  let mode = ffi_argv_at(0)
  let shared = ffi_argv_at(1)
  if shared == "" {
    println(
      "用法: node rhop_demo.js <send|watch|watch-skip> <shared_path> [count]",
    )
    ffi_exit(1)
  }
  if mode == "send" {
    run_send(shared) catch {
      _ => println("send 失败")
    }
  } else if mode == "watch" {
    run_watch(shared, false)
  } else if mode == "watch-skip" {
    run_watch(shared, true)
  } else {
    println("未知模式: \{mode}，仅支持 send / watch / watch-skip")
    ffi_exit(1)
  }
}

///|
fn run_send(shared : String) -> Unit raise @json.ParseError {
  let cipher = @rhop.Aes256GcmCipher::new(DEMO_PASSWORD)
  // 可选第三参数指定条数（默认 DEMO_COUNT）
  let mut count = DEMO_COUNT
  let count_arg = ffi_argv_at(2)
  if count_arg != "" {
    let n = @string.parse_int(count_arg) catch { _ => -1 }
    if n >= 0 {
      count = n
    }
  }
  let mut i = 0
  while i < count {
    let payload = @json.parse(
      "{\"seq\": \{i.to_string()}, \"msg\": \"hello from proc A\"}",
    )
    let pkt = @rhop.RhopPacket::new(
      "demo-\{i.to_string()}",
      "proc-send",
      "state",
      payload,
      i.to_int64(),
    )
    @rhop.rhop_send(shared, "msg-\{i.to_string()}", pkt, cipher)
    println("sent \{i}")
    i = i + 1
  }
  println("send 完成，共 \{count} 条")
}

///|
fn run_watch(shared : String, skip_existing : Bool) -> Unit {
  let cipher = @rhop.Aes256GcmCipher::new(DEMO_PASSWORD)
  let mut expect = DEMO_COUNT
  let count_arg = ffi_argv_at(2)
  if count_arg != "" {
    let n = @string.parse_int(count_arg) catch { _ => -1 }
    if n >= 0 {
      expect = n
    }
  }
  let got : @ref.Ref[Int32] = @ref.Ref(0)
  let source = if skip_existing {
    @rhop.from_filesystem_with(shared, cipher, true)
  } else {
    @rhop.from_filesystem(shared, cipher)
  }
  let _ = source.subscribe(
    @rx.Observer::new(
      fn(pkt : @rhop.RhopPacket) {
        got.val = got.val + 1
        println("received \{got.val}: \{pkt.id} kind=\{pkt.kind}")
        if got.val >= expect {
          println("watch 完成，共收到 \{expect} 条")
          ffi_exit(0)
        }
      },
      fn(err : String) {
        println("watch error: \{err}")
        ffi_exit(2)
      },
      fn() { println("watch completed") },
    ),
  )
  // 保持事件循环运行直到收满退出
}
