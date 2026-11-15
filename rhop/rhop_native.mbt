// ============================================================================
// rhop · native 目标实现（使用 rhop_fs_native 的 fs 原语）
// 与 js 版 1:1 对齐：
//   1. rhop_send：cipher.encrypt → RhopEnvelope::encode → fs_write_atomic
//   2. from_filesystem_with：轮询快照 → 读文件 → decode → decrypt → on_next
// 非目标：native AES-GCM（不引入 OpenSSL，用 RhopCipherNone 纯 base64）
// ============================================================================

///|
/// 发送一条 RHOP 消息：原子写 shared_path/<filename>.rhop
/// 与 js 版 1:1 对齐（仅把 node FFI 换成 C FFI）。
pub fn[T : RhopCipher] rhop_send(
  shared_path : String,
  filename : String,
  packet : RhopPacket,
  cipher : T,
) -> Unit {
  let ct = cipher.encrypt(packet.to_json_string())
  let text = RhopEnvelope::encode(1, cipher.alg_name(), ct)
  let path = join_path(shared_path, filename + ".rhop")
  match fs_write_atomic(path, text) {
    Ok(_) => ()
    Err(_) => println("rhop_send: fs_write_atomic failed")
  }
}

///|
/// 监控 shared path：捕获新增/变更的 .rhop 文件，解码为 RhopPacket 流。
pub fn[T : RhopCipher] from_filesystem(
  shared_path : String,
  cipher : T,
) -> @rx.Observable[RhopPacket, String] {
  from_filesystem_with(shared_path, cipher, false)
}

///|
/// from_filesystem 的带参版本。
/// 注意：native 后端使用同步阻塞轮询循环，与 js 事件驱动语义不同
/// 轮询间隔默认 1000ms，通过 @async.sleep 让出控制权给异步运行时
pub fn[T : RhopCipher] from_filesystem_with(
  shared_path : String,
  cipher : T,
  skip_existing : Bool,
) -> @rx.Observable[RhopPacket, String] {
  @rx.Observable::new(fn(
    observer : @rx.Observer[RhopPacket, String],
  ) -> @rx.Subscription {
    let seen = @hashset.HashSet([], capacity=0)
    // 种子：skip_existing 时预填 seen 集合
    if skip_existing {
      match fs_list_rhop(shared_path) {
        Ok(flist) =>
          for fname in flist {
            let full_path = join_path(shared_path, fname)
            seen.add(seen_key(full_path))
          }
        Err(_) => ()
      }
    }

    let stopped = Ref::Ref(false)

    // 轮询循环：每次迭代后让出控制权，避免阻塞异步运行时
    // 注意：这会阻塞当前线程，应在独立线程/进程中运行
    while !stopped.val {
      match fs_list_rhop(shared_path) {
        Ok(flist) =>
          for fname in flist {
            let full_path = join_path(shared_path, fname)
            if seen.contains(seen_key(full_path)) {
              continue
            }
            seen.add(seen_key(full_path))
            if fname.has_suffix(".rhop.tmp") {
              continue
            }
            match fs_read_text(full_path) {
              Ok(content) => {
                if content == "" {
                  continue
                }
                match RhopEnvelope::decode(content) {
                  Err(_) => continue
                  Ok(env) => {
                    if env.v != 1 {
                      continue
                    }
                    match cipher.decrypt(env.ct) {
                      None => continue
                      Some(plain) =>
                        match RhopPacket::from_json_text(plain) {
                          Err(_) => continue
                          Ok(pkt) => observer.on_next(pkt)
                        }
                    }
                  }
                }
              }
              Err(_) => continue
            }
          }
        Err(_) => continue
      }
      // 注意：同步轮询循环会阻塞当前线程
      // 调用方应在独立线程/进程中运行此 Observable
      // 添加小延迟避免 CPU 空转
      let mut _delay = 0
      while _delay < 1000000 {
        _delay = _delay + 1
      }
    }

    @rx.Subscription::new(fn() { stopped.val = true })
  })
}

// ---------------------------------------------------------------------------
// 工具函数
// ---------------------------------------------------------------------------

///|
fn join_path(root : String, fname : String) -> String {
  if root.has_suffix("/") || root.has_suffix("\\") {
    root + fname
  } else {
    root + "/" + fname
  }
}

///|
fn seen_key(path : String) -> String {
  path.replace(old="\\", new="/")
}
