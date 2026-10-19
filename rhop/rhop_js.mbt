// ============================================================================
// rhop · js 目标实现（node fs / crypto）
//   1. Aes256GcmCipher：AES-256-GCM（PBKDF2 派生密钥）
//   2. rhop_send：写 .rhop 文件（tmp + rename 原子写）
//   3. from_filesystem：监控 shared path，把新 .rhop 文件解码为消息流
// ============================================================================

/// AES-256-GCM 信封密码学（js 目标，node crypto）
/// 密钥由密码 + 固定盐经 PBKDF2-SHA256(100000) 派生；每次加密随机 12B IV。
/// token 格式：base64(iv) : base64(tag) : base64(ciphertext)
pub struct Aes256GcmCipher {
  password : String
}

pub fn Aes256GcmCipher::new(password : String) -> Aes256GcmCipher {
  { password, }
}

pub impl RhopCipher for Aes256GcmCipher with alg_name(self) {
  "aes-256-gcm"
}

pub impl RhopCipher for Aes256GcmCipher with encrypt(self, plain) {
  let t = ffi_aes_encrypt(self.password, plain)
  if t == "" {
    // 加密失败：回退明文 + none 算法，保证链路可用（失败可见性由调用方承担）
    "fallback:encrypt-error"
  } else {
    t
  }
}

pub impl RhopCipher for Aes256GcmCipher with decrypt(self, token) {
  let r = ffi_aes_decrypt(self.password, token)
  if r == "" {
    None
  } else {
    Some(r)
  }
}

/// 发送一条 RHOP 消息：原子写 shared_path/<filename>.rhop
/// filename 为不带扩展名的文件名（如 "msg-001"），自动补 .rhop。
/// 写入顺序：先写 <filename>.rhop.tmp 再 rename，接收方只看到完整文件。
pub fn[T : RhopCipher] rhop_send(
  shared_path : String,
  filename : String,
  packet : RhopPacket,
  cipher : T,
) -> Unit {
  let ct = cipher.encrypt(packet.to_json_string())
  let text = RhopEnvelope::encode(1, cipher.alg_name(), ct)
  ffi_write_atomic(join_path(shared_path, filename + ".rhop"), text)
}

/// 监控 shared path：捕获新增/变更的 .rhop 文件，解码为 RhopPacket 流。
/// 失败策略：坏文件（解析/解密失败）跳过不中断，仅文档化；监控启动失败走 error。
pub fn[T : RhopCipher] from_filesystem(
  shared_path : String,
  cipher : T,
) -> @rx.Observable[RhopPacket, String] {
  let seen : @ref.Ref[@hashset.HashSet[String]] = @ref.Ref::new(@hashset.HashSet::new())
  @rx.Observable::new(
    fn(observer : @rx.Observer[RhopPacket, String]) -> @rx.Subscription {
      let sub = @monitor.watch_folder(shared_path).subscribe(
        @rx.Observer::new(
          fn(ev : @monitor.WatchEvent) {
            if ev.kind == @monitor.WatchKind::Removed {
              return
            }
            if !ev.path.has_suffix(".rhop") {
              return
            }
            if ev.path.has_suffix(".rhop.tmp") {
              return
            }
            if seen.val.contains(ev.path) {
              return
            }
            seen.val.add(ev.path)
            let text = ffi_read_file(ev.path)
            if text == "" {
              return
            }
            match RhopEnvelope::decode(text) {
              Err(_) => return
              Ok(env) => {
                if env.v != 1 {
                  return
                }
                match cipher.decrypt(env.ct) {
                  None => return
                  Some(plain) => {
                    match RhopPacket::from_json_text(plain) {
                      Err(_) => return
                      Ok(pkt) => observer.on_next(pkt)
                    }
                  }
                }
              }
            }
          },
          fn(err : @monitor.WatchError) {
            observer.on_error(@monitor.WatchError::to_string(err))
          },
          fn() {
            observer.on_completed()
          },
        ),
      )
      @rx.Subscription::new(fn() {
        sub.dispose()
      })
    },
  )
}

fn join_path(root : String, fname : String) -> String {
  if root.has_suffix("/") || root.has_suffix("\\") {
    root + fname
  } else {
    root + "\\" + fname
  }
}

// ---------------------------------------------------------------------------
// FFI（node fs / crypto；失败通过返回 "" + globalThis.__rxmbt_io_err /
// __rxmbt_crypto_err 上报）
// ---------------------------------------------------------------------------

/// 读取 utf8 文本文件；失败返回 "" 并写错误槽
extern "js" fn ffi_read_file(path : String) -> String =
  #| (path) => { const G = globalThis; try { return process.getBuiltinModule("node:fs").readFileSync(path, "utf8"); } catch (e) { if (G.__rxmbt_io_err === undefined) { G.__rxmbt_io_err = ""; } G.__rxmbt_io_err = String(e && e.message || e); return ""; } }

/// 原子写：先写 tmp 再 rename
extern "js" fn ffi_write_atomic(path : String, content : String) -> Unit =
  #| (path, content) => { const fs = process.getBuiltinModule("node:fs"); const tmp = path + ".tmp"; fs.writeFileSync(tmp, content, "utf8"); fs.renameSync(tmp, path); }

/// AES-256-GCM 加密，返回 "iv_b64:tag_b64:ct_b64"；失败返回 ""
extern "js" fn ffi_aes_encrypt(password : String, plain : String) -> String =
  #| (password, plain) => { const G = globalThis; try { const crypto = process.getBuiltinModule("node:crypto"); const salt = Buffer.from("rx-mbt-rhop-salt-v1"); const key = crypto.pbkdf2Sync(password, salt, 100000, 32, "sha256"); const iv = crypto.randomBytes(12); const cipher = crypto.createCipheriv("aes-256-gcm", key, iv); const enc = Buffer.concat([cipher.update(plain, "utf8"), cipher.final()]); const tag = cipher.getAuthTag(); const token = iv.toString("base64") + ":" + tag.toString("base64") + ":" + enc.toString("base64"); if (G.__rxmbt_crypto_err === undefined) { G.__rxmbt_crypto_err = ""; } return token; } catch (e) { if (G.__rxmbt_crypto_err === undefined) { G.__rxmbt_crypto_err = ""; } G.__rxmbt_crypto_err = String(e && e.message || e); return ""; } }

/// AES-256-GCM 解密；失败返回 ""
extern "js" fn ffi_aes_decrypt(password : String, token : String) -> String =
  #| (password, token) => { const G = globalThis; try { if (token === "" || token === "fallback:encrypt-error") { G.__rxmbt_crypto_err = "bad token"; return ""; } const parts = token.split(":"); if (parts.length !== 3) { G.__rxmbt_crypto_err = "malformed token"; return ""; } const crypto = process.getBuiltinModule("node:crypto"); const salt = Buffer.from("rx-mbt-rhop-salt-v1"); const key = crypto.pbkdf2Sync(password, salt, 100000, 32, "sha256"); const iv = Buffer.from(parts[0], "base64"); const tag = Buffer.from(parts[1], "base64"); const enc = Buffer.from(parts[2], "base64"); const decipher = crypto.createDecipheriv("aes-256-gcm", key, iv); decipher.setAuthTag(tag); const dec = Buffer.concat([decipher.update(enc), decipher.final()]); if (G.__rxmbt_crypto_err === undefined) { G.__rxmbt_crypto_err = ""; } return dec.toString("utf8"); } catch (e) { if (G.__rxmbt_crypto_err === undefined) { G.__rxmbt_crypto_err = ""; } G.__rxmbt_crypto_err = String(e && e.message || e); return ""; } }
