// ============================================================================
// rhop_task · 配置层测试（js 专属：from_file / 主密钥密文解锁 / 读密钥文件）
//
// 覆盖：
//   1. from_file 读文件成功，base_dir 归到配置文件所在目录
//   2. 文件不存在 → 可诊断 Err
//   3. load_task_config 自动区分「JSON 文本」与「文件路径」
//   4. key.cipher + key.path 解锁主密钥（读密钥文件）
//   5. key.cipher + key.env 解锁主密钥（环境变量）
//   6. key 只有 path → 读文件作为明文密钥
// ============================================================================

// ---------------------------------------------------------------------------
// 测试用 JS 辅助
// ---------------------------------------------------------------------------

///|
extern "js" fn ffi_cfg_mkdtemp(prefix : String) -> String =
  #| (prefix) => { try { const fs = process.getBuiltinModule("node:fs"); const os = process.getBuiltinModule("node:os"); const path = process.getBuiltinModule("node:path"); return fs.mkdtempSync(path.join(os.tmpdir(), String(prefix) + "-")); } catch (_e) { return ""; } }

///|
extern "js" fn ffi_cfg_write(p : String, content : String) -> Bool =
  #| (p, content) => { try { process.getBuiltinModule("node:fs").writeFileSync(String(p), String(content), "utf8"); return true; } catch (_e) { return false; } }

///|
extern "js" fn ffi_cfg_join(dir : String, name : String) -> String =
  #| (dir, name) => { try { return process.getBuiltinModule("node:path").join(String(dir), String(name)); } catch (_e) { return String(dir) + "/" + String(name); } }

///|
extern "js" fn ffi_cfg_rmrf(p : String) -> Unit =
  #| (p) => { try { process.getBuiltinModule("node:fs").rmSync(String(p), { recursive: true, force: true }); } catch (_e) {} }

// ---------------------------------------------------------------------------
// 1+2. from_file
// ---------------------------------------------------------------------------

///|
test "config-js · from_file 读文件 + base_dir 归到文件所在目录" {
  let dir = ffi_cfg_mkdtemp("rhop-task-cfg")
  assert_true(dir != "")
  let path = ffi_cfg_join(dir, "rhop-task.json")
  assert_true(
    ffi_cfg_write(
      path, "{\"role\":\"B\",\"name\":\"from-file\",\"shared\":\"share\"}",
    ),
  )
  let cfg = match @rt.TaskConfig::from_file(path, false, false, None) {
    Ok(c) => c
    Err(e) => fail("from_file 失败: \{e}")
  }
  assert_eq(cfg.name(), "from-file")
  assert_eq(cfg.role_short(), "B")
  assert_eq(cfg.shared_write, Some("share"))
  // base_dir 应为配置文件所在目录（含临时目录名）
  assert_true(cfg.base_dir.contains("rhop-task-cfg"))
  ffi_cfg_rmrf(dir)
}

///|
test "config-js · from_file 文件不存在 → 可诊断 Err" {
  let dir = ffi_cfg_mkdtemp("rhop-task-cfg2")
  let ghost = ffi_cfg_join(dir, "nope.json")
  match @rt.TaskConfig::from_file(ghost, false, false, None) {
    Err(e) => {
      assert_true(e.contains("读取配置文件失败"))
      assert_true(e.contains("nope.json"))
    }
    Ok(_) => fail("不存在的配置文件应当 Err")
  }
  ffi_cfg_rmrf(dir)
}

///|
test "config-js · load_task_config 自动区分 JSON 文本与文件路径" {
  // JSON 文本
  let c1 = match @rt.load_task_config("{\"role\":\"A\"}", false, false, None) {
    Ok(c) => c
    Err(e) => fail("JSON 文本入口失败: \{e}")
  }
  assert_eq(c1.role_short(), "A")
  // 文件路径
  let dir = ffi_cfg_mkdtemp("rhop-task-cfg3")
  let path = ffi_cfg_join(dir, "c.json")
  assert_true(ffi_cfg_write(path, "{\"role\":\"C\"}"))
  let c2 = match @rt.load_task_config(path, false, false, None) {
    Ok(c) => c
    Err(e) => fail("文件路径入口失败: \{e}")
  }
  assert_eq(c2.role_short(), "C")
  ffi_cfg_rmrf(dir)
}

// ---------------------------------------------------------------------------
// 3. 主密钥来源：path / env / cipher
// ---------------------------------------------------------------------------

///|
test "config-js · key.path：读密钥文件作为明文密钥" {
  let dir = ffi_cfg_mkdtemp("rhop-task-key")
  let keyfile = ffi_cfg_join(dir, "rhop.key")
  assert_true(ffi_cfg_write(keyfile, "  file-master-key  \n"))
  let text = "{\"role\":\"A\",\"key\":{\"plain\":\"\",\"cipher\":\"\",\"path\":\"" +
    @rp.normalize_path(keyfile) +
    "\"}}"
  let cfg = match
    @rt.TaskConfig::from_json_text(text, None, false, false, None) {
    Ok(c) => c
    Err(e) => fail("key.path 失败: \{e}")
  }
  // Python 侧读取后 strip；密钥文本应为去空白后的内容
  assert_eq(cfg.key, "file-master-key")
  assert_eq(cfg.key_source, "path")
  assert_true(cfg.has_key())
  ffi_cfg_rmrf(dir)
}

///|
test "config-js · key.cipher + key.env：环境变量 unlocks 主密钥" {
  let master = @rp.RhopCrypto::from_key("outer-unlock-key")
  let cipher = master.encrypt_secret("inner-master-key")
  @env.set_env_var("RHOP_TASK_UNLOCK_CFG", "outer-unlock-key")
  let text = "{\"role\":\"A\",\"key\":{\"plain\":\"\",\"cipher\":\"" +
    cipher +
    "\",\"env\":\"RHOP_TASK_UNLOCK_CFG\"}}"
  let cfg = match
    @rt.TaskConfig::from_json_text(text, None, false, false, None) {
    Ok(c) => c
    Err(e) => fail("key.cipher 解锁失败: \{e}")
  }
  assert_eq(cfg.key, "inner-master-key")
  assert_eq(cfg.key_source, "cipher")
  @env.unset_env_var("RHOP_TASK_UNLOCK_CFG")
}

///|
test "config-js · key.cipher 但缺外层密钥 → 可诊断 Err" {
  @env.unset_env_var("RHOP_TASK_UNLOCK_ABSENT")
  let text = "{\"role\":\"A\",\"key\":{\"plain\":\"\",\"cipher\":\"RHOP-ENC:Zm9v\",\"env\":\"RHOP_TASK_UNLOCK_ABSENT\"}}"
  match @rt.TaskConfig::from_json_text(text, None, false, false, None) {
    Err(e) => {
      assert_true(e.contains("缺少解开它的外层密钥"))
      assert_true(e.contains("RHOP_TASK_UNLOCK_ABSENT"))
    }
    Ok(_) => fail("缺外层密钥应当 Err")
  }
}

///|
test "config-js · 全链路：主密钥解锁后能解配置里的业务密文" {
  let master = @rp.RhopCrypto::from_key("chain-master")
  let inner_cipher = master.encrypt_secret("chain-inner-key")
  @env.set_env_var("RHOP_TASK_CHAIN_UNLOCK", "chain-master")
  // 业务密文由 inner key 加密
  let inner = @rp.RhopCrypto::from_key("chain-inner-key")
  let biz_cipher = inner.encrypt_secret("sftp-real-password")
  let text = "{\"role\":\"A\",\"key\":{\"plain\":\"\",\"cipher\":\"" +
    inner_cipher +
    "\",\"env\":\"RHOP_TASK_CHAIN_UNLOCK\"},\"sftp\":{\"host\":\"h\",\"password\":\"" +
    biz_cipher +
    "\"}}"
  let cfg = match
    @rt.TaskConfig::from_json_text(text, None, false, false, None) {
    Ok(c) => c
    Err(e) => fail("全链路解密失败: \{e}")
  }
  assert_eq(cfg.key, "chain-inner-key")
  // 业务密文已被解析成明文
  match cfg.resolved {
    { "sftp": { "password": String(p), .. }, .. } =>
      assert_eq(p, "sftp-real-password")
    _ => fail("业务密文未解密: " + Json::stringify(cfg.resolved))
  }
  // 但 to_dict(mask=true) 不得泄漏
  let masked = Json::stringify(cfg.to_dict(true))
  assert_false(masked.contains("sftp-real-password"))
  assert_false(masked.contains("chain-inner-key"))
  @env.unset_env_var("RHOP_TASK_CHAIN_UNLOCK")
}
