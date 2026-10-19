///|
/// RX-MBT rhop 同机器异进程演示：
///   node rhop_demo.js send <shared_path>   （进程 A：发送 N 条加密消息）
///   node rhop_demo.js watch <shared_path>  （进程 B：监控 shared path，接收并解密）
///
/// 先起 watch 进程，再起 send 进程，验证 shared path 事件驱动传输。

extern "js" fn ffi_argv_at(i : Int) -> String =
  #| (i) => {
  #|   const a = (typeof process !== "undefined" && process.argv) ? process.argv.slice(2) : [];
  #|   return (i < a.length) ? a[i] : "";
  #| }

extern "js" fn ffi_exit(code : Int) -> Unit =
  #| (code) => { process.exit(code); }

const DEMO_COUNT : Int = 5
const DEMO_PASSWORD : String = "demo-password"

fn main {
  let mode = ffi_argv_at(0)
  let shared = ffi_argv_at(1)
  if shared == "" {
    println("用法: node rhop_demo.js <send|watch> <shared_path>")
    ffi_exit(1)
  }
  if mode == "send" {
    try {
      run_send(shared)
    } catch {
      _ => println("send 失败")
    }
  } else if mode == "watch" {
    run_watch(shared)
  } else {
    println("未知模式: \{mode}，仅支持 send / watch")
    ffi_exit(1)
  }
}

fn run_send(shared : String) -> Unit raise @json.ParseError {
  let cipher = @rhop.Aes256GcmCipher::new(DEMO_PASSWORD)
  let mut i = 0
  while i < DEMO_COUNT {
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
  println("send 完成，共 \{DEMO_COUNT} 条")
}

fn run_watch(shared : String) -> Unit {
  let cipher = @rhop.Aes256GcmCipher::new(DEMO_PASSWORD)
  let got : @ref.Ref[Int] = @ref.Ref::new(0)
  let _ = @rhop.from_filesystem(shared, cipher).subscribe(
    @rx.Observer::new(
      fn(pkt : @rhop.RhopPacket) {
        got.val = got.val + 1
        println("received \{got.val}: \{pkt.id} kind=\{pkt.kind}")
        if got.val >= DEMO_COUNT {
          println("watch 完成，共收到 \{DEMO_COUNT} 条")
          ffi_exit(0)
        }
      },
      fn(err : String) {
        println("watch error: \{err}")
        ffi_exit(2)
      },
      fn() {
        println("watch completed")
      },
    ),
  )
  // 保持事件循环运行直到收满退出
}
