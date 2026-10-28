// ============================================================================
// rhop · 目录同步守护（Batch D · P1，可缓）
//
// 对照 vools.rhop.sync_folder（剪贴板通道见 rhop/clipboard.mbt，本文件不重复实现）：
// 生产节点把 parquet / xlsx 等文件写进共享目录，
// 本节点轮询该目录，把**新出现或内容变化**的文件拉回本地 target。
// 幂等由 manifest（`<target>/.sync_manifest.json`，记录每个文件 sha256 + size）保证：
// 内容没变且本地文件仍在 ⇒ 跳过；本地被清理（文件缺失）⇒ 重拉。
//
// 与 vools 的差异（明说，不假装对齐）：
//   - vools 有可插拔 `source` 适配器协议（list_files/open_bytes）；MoonBit 侧 MVP 直接
//     对**本地目录**（含 UNC 映射盘 / RDP tsclient 挂载点）读写，`recursive` 可选；
//   - 二进制安全：摘要与拷贝都在 js 侧做（`node:fs` + `node:crypto`），
//     文件内容不经过 MoonBit 的 UTF-8 文本通道，故 parquet/xlsx 不会被转码破坏；
//   - glob 只支持 `*` / `?`（vools 用 fnmatch 还支持 `[seq]`，这里未实现，已在文档标注）。
//
// 目标可用性：js 真跑；wasm/native 的 `sync_once` 返回 `{"errors": [...]}`（不抛、不假装成功）。
// ============================================================================

///|
/// manifest 文件名（落在 target 目录，自身永不被拉取）。
pub const SYNC_MANIFEST_NAME : String = ".sync_manifest.json"

///|
/// 单向往本地拉取的目录同步器（可单次、可守护轮询）。
pub struct SyncFolder {
  source : String
  target : String
  pattern : String
  recursive : Bool
  manifest_path : String
  mut stopped : Bool
  mut rounds : Int32
  total_pulled : Array[String]
  errors : Array[String]
}

///|
/// 构造同步器（对照 vools `SyncFolder(source, target_dir, pattern)`）。
///
/// `pattern` 为空 ⇒ `*`（全拉）；manifest 缺省落 `<target>/.sync_manifest.json`。
pub fn SyncFolder::new(
  source : String,
  target : String,
  pattern : String,
) -> SyncFolder {
  let pat = if pattern == "" { "*" } else { pattern }
  {
    source,
    target,
    pattern: pat,
    recursive: false,
    manifest_path: rhop_join(target, SYNC_MANIFEST_NAME),
    stopped: false,
    rounds: 0,
    total_pulled: [],
    errors: [],
  }
}

///|
/// 是否递归子目录（缺省 false，对照 vools `LocalDirSource(recursive=False)`）。
pub fn SyncFolder::with_recursive(
  self : SyncFolder,
  recursive : Bool,
) -> SyncFolder {
  {
    source: self.source,
    target: self.target,
    pattern: self.pattern,
    recursive,
    manifest_path: self.manifest_path,
    stopped: self.stopped,
    rounds: self.rounds,
    total_pulled: self.total_pulled.copy(),
    errors: self.errors.copy(),
  }
}

///|
/// manifest 落盘路径。
pub fn SyncFolder::manifest_path(self : SyncFolder) -> String {
  self.manifest_path
}

///|
/// 置停止标记（`run_forever` 在下一轮结束时退出；至少跑完当前轮）。
pub fn SyncFolder::stop(self : SyncFolder) -> Unit {
  self.stopped = true
}

///|
/// 单次同步（对照 vools `sync_once`）：拉取新增/变化文件。
///
/// 返回 vools 同形 JSON：`{"pulled": [names], "skipped": <n>, "errors": [msgs]}`。
/// 源列举失败**不抛**，收进 `errors`（vools 也是这样）。
pub fn SyncFolder::sync_once(self : SyncFolder) -> Json {
  let pulled : Array[String] = []
  let errors : Array[String] = []
  let mut skipped = 0
  // 1. 列源文件
  let names = if self.recursive {
    rhop_fs_list_files_recursive(self.source)
  } else {
    rhop_fs_list_dir(self.source)
  }
  if names.length() == 0 && !rhop_fs_exists(self.source) {
    errors.push(
      "源列举失败: 目录不存在或不可读（\{self.source}）",
    )
  }
  // 2. 逐文件判定
  let mut manifest = sync_load_manifest(self.manifest_path)
  let mut manifest_dirty = false
  for name in names {
    let base = sync_basename(name)
    if base == SYNC_MANIFEST_NAME {
      continue
    }
    if !sync_glob_match(self.pattern, base) {
      continue
    }
    let src_path = rhop_join(self.source, name)
    let digest = match rhop_fs_digest_file(src_path) {
      Ok(v) => v
      Err(msg) => {
        errors.push("读源失败 \{name}: \{msg}")
        continue
      }
    }
    let sha = sync_json_str(digest, "sha256")
    let local_path = rhop_join(self.target, name)
    let known = match manifest {
      Object(members) =>
        match members.get(name) {
          Some(entry) => sync_json_str(entry, "sha256")
          None => ""
        }
      _ => ""
    }
    // 内容未变且 target 文件仍在 → 跳过；target 被清理（文件缺失）→ 重拉
    if known == sha && sha != "" && rhop_fs_exists(local_path) {
      skipped = skipped + 1
      continue
    }
    match rhop_fs_copy(src_path, local_path) {
      Ok(_) => ()
      Err(msg) => {
        errors.push("写本地失败 \{name}: \{msg}")
        continue
      }
    }
    manifest_dirty = true
    pulled.push(name)
    manifest = sync_manifest_set(
      manifest,
      name,
      sha,
      sync_json_int(digest, "size"),
    )
  }
  // 3. 只有真正拉过文件才写 manifest（vools 同样只在 pulled 非空时写）
  if manifest_dirty {
    match sync_save_manifest(self.manifest_path, manifest) {
      Ok(_) => ()
      Err(msg) => errors.push("manifest 写盘失败: \{msg}")
    }
  }
  Json::object({
    "pulled": sync_str_array(pulled),
    "skipped": Json::number(skipped.to_double()),
    "errors": sync_str_array(errors),
  })
}

///|
/// 守护轮询（对照 vools `run_forever`）：每 `poll_interval_ms` 跑一次 `sync_once`。
///
/// **至少跑一轮**；`max_rounds > 0` 时跑满即退（测试/一次性批处理用），
/// `max_rounds <= 0` 时无限循环直到 `stop()` 被置位。返回累计
/// `{"total_pulled": [...], "rounds": <n>, "errors": [...]}`。
pub fn SyncFolder::run_forever(
  self : SyncFolder,
  poll_interval_ms : Int32,
  max_rounds : Int32,
) -> Json {
  let interval = if poll_interval_ms < 0 { 0 } else { poll_interval_ms }
  while !self.stopped {
    let one = self.sync_once()
    self.rounds = self.rounds + 1
    match one {
      Object(members) =>
        match members.get("pulled") {
          Some(Array(items)) =>
            for item in items {
              match item {
                String(name) => self.total_pulled.push(name)
                _ => ()
              }
            }
          _ => ()
        }
      _ => ()
    }
    match one {
      Object(members) =>
        match members.get("errors") {
          Some(Array(items)) =>
            for item in items {
              match item {
                String(msg) => self.errors.push(msg)
                _ => ()
              }
            }
          _ => ()
        }
      _ => ()
    }
    if max_rounds > 0 && self.rounds >= max_rounds {
      self.stopped = true
    }
    if !self.stopped && interval > 0 {
      rhop_sleep_ms(interval)
    }
  }
  Json::object({
    "total_pulled": sync_str_array(self.total_pulled),
    "rounds": Json::number(self.rounds.to_double()),
    "errors": sync_str_array(self.errors),
  })
}

///|
/// 已累计跑过的轮数。
pub fn SyncFolder::rounds(self : SyncFolder) -> Int32 {
  self.rounds
}

// ---------------------------------------------------------------------------
// 本文件私有 helper · manifest 与 glob
// ---------------------------------------------------------------------------

///|
/// 读 manifest（缺失/坏 JSON 一律当空对象，对照 vools `_load_manifest`）。
fn sync_load_manifest(path : String) -> Json {
  if !rhop_fs_exists(path) {
    return Json::object(Map([]))
  }
  let text = match rhop_fs_read_text(path) {
    Ok(t) => t
    Err(_) => return Json::object(Map([]))
  }
  let parsed = @json.parse(text) catch { _ => return Json::object(Map([])) }
  match parsed {
    Object(_) => parsed
    _ => Json::object(Map([]))
  }
}

///|
/// 写 manifest（先 tmp 再 rename；`ensure_ascii` 无意义但保持键序稳定便于人读）。
fn sync_save_manifest(path : String, manifest : Json) -> Result[Unit, String] {
  rhop_fs_write_text(path, canonical_json(manifest))
}

///|
/// 在 manifest 里写入/覆盖一条记录（返回新的 manifest 对象）。
fn sync_manifest_set(
  manifest : Json,
  name : String,
  sha256 : String,
  size : Int32,
) -> Json {
  let fields : Map[String, Json] = match manifest {
    Object(members) => {
      let copied : Map[String, Json] = Map([])
      for key in members.keys() {
        copied[key] = members.at(key)
      }
      copied
    }
    _ => Map([])
  }
  fields[name] = Json::object({
    "sha256": Json::string(sha256),
    "size": Json::number(size.to_double()),
  })
  Json::object(fields)
}

///|
/// 取 `name` 的最后一段（`/` 与 `\` 都算分隔符）。
///
/// 用 `get_view(start=, end=)` 逐字符比较（本版本无 `find_last` / `substring`）。
fn sync_basename(name : String) -> String {
  let n = name.length()
  let mut cut = 0
  let mut i = 0
  while i < n {
    if sync_char_at(name, i) == "/" || sync_char_at(name, i) == "\\" {
      cut = i + 1
    }
    i = i + 1
  }
  match name.get_view(start=cut) {
    Some(v) => v.to_owned()
    None => ""
  }
}

///|
/// 取第 `i` 个「字符」（按 UTF-16 码元切片，文件名比较场景足够）。
fn sync_char_at(s : String, i : Int32) -> String {
  match s.get_view(start=i, end=i + 1) {
    Some(v) => v.to_owned()
    None => ""
  }
}

///|
/// fnmatch 简化版：只支持 `*`（任意串）与 `?`（任意单字符），其余按字面比较。
///
/// 实现是经典双指针回溯算法（O(n·m) 最坏），对文件名足够。
pub fn sync_glob_match(pattern : String, text : String) -> Bool {
  let p = pattern
  let t = text
  let mut pi = 0
  let mut ti = 0
  let mut star_pi = -1
  let mut star_ti = 0
  while ti < t.length() {
    if pi < p.length() &&
      (sync_char_at(p, pi) == "?" || sync_char_at(p, pi) == sync_char_at(t, ti)) {
      pi = pi + 1
      ti = ti + 1
    } else if pi < p.length() && sync_char_at(p, pi) == "*" {
      star_pi = pi
      star_ti = ti
      pi = pi + 1
    } else if star_pi >= 0 {
      pi = star_pi + 1
      star_ti = star_ti + 1
      ti = star_ti
    } else {
      return false
    }
  }
  while pi < p.length() && sync_char_at(p, pi) == "*" {
    pi = pi + 1
  }
  pi == p.length()
}

///|
/// Json 对象取字符串字段（缺失返回 ""）。
fn sync_json_str(value : Json, key : String) -> String {
  match value {
    Object(members) =>
      match members.get(key) {
        Some(String(text)) => text
        _ => ""
      }
    _ => ""
  }
}

///|
/// Json 对象取整数字段（缺失返回 0）。
fn sync_json_int(value : Json, key : String) -> Int32 {
  match value {
    Object(members) =>
      match members.get(key) {
        Some(Number(n, ..)) => n.to_int()
        _ => 0
      }
    _ => 0
  }
}

///|
/// `Array[String]` → Json 数组。
fn sync_str_array(items : Array[String]) -> Json {
  let out : Array[Json] = []
  for item in items {
    out.push(Json::string(item))
  }
  Json::array(out)
}
