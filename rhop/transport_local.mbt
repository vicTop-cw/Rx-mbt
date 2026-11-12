// ============================================================================
// rhop · 本地 shared path（同机两进程 A/B 通过目录收发）
//
// 对照 vools.rhop.transport.local / endpoint.LocalEndpoint：
//   - 写入原子化：先写 <name>.tmp，再 rename 覆盖 —— 接收方只看得到完整文件；
//   - 路径统一用 "/" 分隔（node fs 在 Windows 下同样接受 "/"，跨平台一致）；
//   - available() 会在必要时 mkdir -p（与 vools 的 os.makedirs(exist_ok=True) 等价）。
//
// 目标说明：文件系统操作仅 js 目标可用（node:fs）；wasm/native 下同签名返回
// 可诊断 Err（或 available()=false），保证 rhop 包在三目标都能编译。
// ============================================================================

///|
/// 本地目录 shared path（写读同视图）。
pub struct LocalSharedPath {
  /// 归一化后的根目录（"/" 分隔，无尾斜杠）
  root : String
}

///|
/// 以根目录构造（相对路径按进程 cwd 解析成绝对路径）。
pub fn LocalSharedPath::new(root : String) -> LocalSharedPath {
  { root: normalize_path(fs_abs(root)), }
}

///|
/// 根目录（"/" 分隔）。注意：契约里的 `SharedPath::root` 返回 `String?`，
/// 本实现在 trait 里实现；这里不再额外提供同名 inherent 方法以免歧义。
///|
pub extend LocalSharedPath with SharedPath::{available, write_text, read_text, exists, remove, name, root}

pub impl SharedPath for LocalSharedPath with fn available(self) {
  match fs_ensure_dir(self.root) {
    Ok(_) => true
    Err(_) => false
  }
}

///|
pub impl SharedPath for LocalSharedPath with fn write_text(
  self,
  filename,
  content,
) {
  write_text_atomic(self.root, filename, content)
}

///|
pub impl SharedPath for LocalSharedPath with fn read_text(self, filename) {
  read_text_at(self.root, filename)
}

///|
pub impl SharedPath for LocalSharedPath with fn exists(self, filename) {
  fs_exists(join_shared(self.root, filename))
}

///|
pub impl SharedPath for LocalSharedPath with fn remove(self, filename) {
  fs_remove(join_shared(self.root, filename))
}

///|
pub impl SharedPath for LocalSharedPath with fn name(self) {
  "local:\{self.root}"
}

///|
pub impl SharedPath for LocalSharedPath with fn root(self) {
  Some(self.root)
}

// ---------------------------------------------------------------------------
// 共用helper：路径归一化 / 拼接 / 原子读写（transport_endpoint 亦复用）
// ---------------------------------------------------------------------------

///|
/// 路径归一化为 "/" 分隔：反斜杠转正斜杠、折叠重复斜杠、去尾斜杠（保留盘符根）。
pub fn normalize_path(p : String) -> String {
  let s = p.replace_all(old="\\", new="/")
  let sb = StringBuilder()
  let mut prev_slash = false
  for i in 0..<s.length() {
    let ch = s.get_char(i).unwrap_or('/')
    if ch == '/' {
      if !prev_slash {
        sb.write_char(ch)
      }
      prev_slash = true
    } else {
      sb.write_char(ch)
      prev_slash = false
    }
  }
  let collapsed = sb.to_string()
  // 去掉尾斜杠，但保留 "/" 与 "C:/" 这类根形态
  if collapsed.length() > 1 && collapsed.has_suffix("/") {
    match collapsed.get_view(start=0, end=collapsed.length() - 1) {
      Some(v) => v.to_owned()
      None => collapsed
    }
  } else {
    collapsed
  }
}

///|
/// 拼接 shared path 与文件名（统一 "/"）。
pub fn join_shared(root : String, filename : String) -> String {
  let f = normalize_path(filename)
  let f = if f.has_prefix("/") { f[1:].to_owned() } else { f }
  if root == "" {
    f
  } else if root.has_suffix("/") {
    root + f
  } else {
    root + "/" + f
  }
}

///|
/// 原子写：先写 <dest>.tmp 再 rename（目标目录不存在时自动创建）。
pub fn write_text_atomic(
  root : String,
  filename : String,
  content : String,
) -> Result[Unit, String] {
  let dest = join_shared(root, filename)
  // 目标可能是子目录（filename 含 "/"）：建它自己的父目录，而不只是 root
  match fs_ensure_parent(dest) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  let tmp = dest + ".tmp"
  match fs_write_file(tmp, content) {
    Err(e) => return Err("rhop: 写入临时文件失败: \{tmp}: \{e}")
    Ok(_) => ()
  }
  match fs_rename(tmp, dest) {
    Err(e) => {
      // rename 失败时清掉临时文件，避免残留
      let _ = fs_remove(tmp)
      Err("rhop: 原子替换失败: \{tmp} -> \{dest}: \{e}")
    }
    Ok(_) => Ok(())
  }
}

///|
/// 建某个文件路径的父目录（dest 已归一化为 "/" 分隔）。
fn fs_ensure_parent(dest : String) -> Result[Unit, String] {
  match dest.rev_split_once("/") {
    Some(pair) => fs_ensure_dir(pair.0.to_owned())
    None => Ok(())
  }
}

///|
/// 从 root/filename 读文本；不存在返回可诊断 Err。
pub fn read_text_at(root : String, filename : String) -> Result[String, String] {
  let p = join_shared(root, filename)
  match fs_read_text(p) {
    Ok(t) => Ok(t)
    Err(e) => Err("rhop: 读取失败: \{p}: \{e}")
  }
}

// ---------------------------------------------------------------------------
// 文件系统原语（js: node:fs；非 js：可诊断 Err）
// 约定：globalThis.__rxmbt_fs_err 记录最近一次失败原因；成功路径清空。
// ---------------------------------------------------------------------------

///|
/// 把路径解析成绝对路径（"/" 分隔），用于 LocalSharedPath 的 root 定型。
#cfg(target="js")
extern "js" fn ffi_fs_abs(p : String) -> String =
  #| (p) => { try { const path = process.getBuiltinModule("node:path"); return path.resolve(p); } catch (_e) { return p; } }

///|
#cfg(target="js")
extern "js" fn ffi_fs_ensure_dir(p : String) -> Bool =
  #| (p) => { const G = globalThis; try { const fs = process.getBuiltinModule("node:fs"); fs.mkdirSync(p, { recursive: true }); G.__rxmbt_fs_err = ""; return true; } catch (e) { G.__rxmbt_fs_err = String((e && e.message) || e); return false; } }

///|
#cfg(target="js")
extern "js" fn ffi_fs_write_file(p : String, content : String) -> Bool =
  #| (p, content) => { const G = globalThis; try { const fs = process.getBuiltinModule("node:fs"); fs.writeFileSync(p, content, "utf8"); G.__rxmbt_fs_err = ""; return true; } catch (e) { G.__rxmbt_fs_err = String((e && e.message) || e); return false; } }

///|
#cfg(target="js")
extern "js" fn ffi_fs_rename(from : String, to : String) -> Bool =
  #| (from, to) => { const G = globalThis; try { const fs = process.getBuiltinModule("node:fs"); fs.renameSync(from, to); G.__rxmbt_fs_err = ""; return true; } catch (e) { G.__rxmbt_fs_err = String((e && e.message) || e); return false; } }

///|
#cfg(target="js")
extern "js" fn ffi_fs_read_file(p : String) -> String =
  #| (p) => { const G = globalThis; try { const fs = process.getBuiltinModule("node:fs"); const t = fs.readFileSync(p, "utf8"); G.__rxmbt_fs_err = ""; return t; } catch (e) { G.__rxmbt_fs_err = String((e && e.message) || e); return ""; } }

///|
#cfg(target="js")
extern "js" fn ffi_fs_exists(p : String) -> Bool =
  #| (p) => { try { return process.getBuiltinModule("node:fs").existsSync(p); } catch (_e) { return false; } }

///|
#cfg(target="js")
extern "js" fn ffi_fs_remove(p : String) -> Bool =
  #| (p) => { const G = globalThis; try { const fs = process.getBuiltinModule("node:fs"); fs.unlinkSync(p); G.__rxmbt_fs_err = ""; return true; } catch (e) { G.__rxmbt_fs_err = String((e && e.message) || e); return false; } }

///|
#cfg(target="js")
extern "js" fn ffi_fs_last_error() -> String =
  #| () => { const G = globalThis; return (G.__rxmbt_fs_err === undefined) ? "" : G.__rxmbt_fs_err; }

///|
#cfg(target="js")
fn fs_abs(p : String) -> String {
  ffi_fs_abs(p)
}

///|
#cfg(not(target="js"))
fn fs_abs(p : String) -> String {
  p
}

///|
#cfg(target="js")
fn fs_ensure_dir(p : String) -> Result[Unit, String] {
  if ffi_fs_ensure_dir(p) {
    Ok(())
  } else {
    Err(ffi_fs_last_error())
  }
}

///|
#cfg(not(target="js"))
fn fs_ensure_dir(p : String) -> Result[Unit, String] {
  Err(
    "rhop: 目录创建仅 js 目标可用（wasm/native 无文件系统 API）",
  )
}

///|
#cfg(target="js")
fn fs_write_file(p : String, content : String) -> Result[Unit, String] {
  if ffi_fs_write_file(p, content) {
    Ok(())
  } else {
    Err(ffi_fs_last_error())
  }
}

///|
#cfg(not(target="js"))
fn fs_write_file(p : String, content : String) -> Result[Unit, String] {
  Err("rhop: 写文件仅 js 目标可用（wasm/native 无文件系统 API）")
}

///|
#cfg(target="js")
fn fs_rename(from : String, to : String) -> Result[Unit, String] {
  if ffi_fs_rename(from, to) {
    Ok(())
  } else {
    Err(ffi_fs_last_error())
  }
}

///|
#cfg(not(target="js"))
fn fs_rename(from : String, to : String) -> Result[Unit, String] {
  Err("rhop: 重命名仅 js 目标可用（wasm/native 无文件系统 API）")
}

///|
#cfg(target="js")
fn fs_read_text(p : String) -> Result[String, String] {
  let t = ffi_fs_read_file(p)
  let err = ffi_fs_last_error()
  if err != "" {
    Err(err)
  } else {
    Ok(t)
  }
}

///|
#cfg(not(target="js"))
fn fs_read_text(p : String) -> Result[String, String] {
  Err("rhop: 读文件仅 js 目标可用（wasm/native 无文件系统 API）")
}

///|
#cfg(target="js")
fn fs_exists(p : String) -> Bool {
  ffi_fs_exists(p)
}

///|
#cfg(not(target="js"))
fn fs_exists(p : String) -> Bool {
  false
}

///|
#cfg(target="js")
fn fs_remove(p : String) -> Result[Unit, String] {
  if ffi_fs_remove(p) {
    Ok(())
  } else {
    let err = ffi_fs_last_error()
    if fs_exists(p) {
      Err(err)
    } else {
      // 不存在视为删除成功（幂等，与 vools remove() 的 False 语义对齐为「无副作用」）
      Ok(())
    }
  }
}

///|
#cfg(not(target="js"))
fn fs_remove(p : String) -> Result[Unit, String] {
  Err("rhop: 删文件仅 js 目标可用（wasm/native 无文件系统 API）")
}
