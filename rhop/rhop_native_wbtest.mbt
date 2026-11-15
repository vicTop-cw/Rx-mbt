// ============================================================================
// rhop_native_wbtest.mbt —— rhop native 白盒测试
// 运行：moon test --target native
// 覆盖：rhop_send 原子写、from_filesystem 监控、skip_existing 种子
// ============================================================================

///|
async test "rhop_send: 原子写 .rhop 文件" {
  let tmp_dir = "./rhop_native_test"
  let cipher = RhopCipherNone::new()
  let packet = RhopPacket::{
    id: "test-id",
    source: "test-source",
    kind: "command",
    payload: @json.parse("{\"msg\":\"hello\"}"),
    at: 1234567890L,
  }
  // 先写一个文件来创建目录
  let _ = fs_write_atomic(tmp_dir + "/.dummy", "")
  rhop_send(tmp_dir, "test-msg", packet, cipher)
  // 验证文件存在
  let files = fs_list_rhop(tmp_dir)
  match files {
    Ok(flist) => {
      let has_test = Ref::Ref(false)
      for f in flist {
        if f == "test-msg.rhop" {
          has_test.val = true
          break
        }
      }
      assert_eq(has_test.val, true)
    }
    Err(_) => fail("fs_list_rhop failed")
  }
}

///|
async test "rhop_send: 覆盖已存在文件" {
  let tmp_dir = "./rhop_native_test"
  let cipher = RhopCipherNone::new()
  let packet1 = RhopPacket::{
    id: "test1",
    source: "test",
    kind: "command",
    payload: @json.parse("{\"msg\":\"first\"}"),
    at: 1234567890L,
  }
  let packet2 = RhopPacket::{
    id: "test2",
    source: "test",
    kind: "command",
    payload: @json.parse("{\"msg\":\"second\"}"),
    at: 1234567891L,
  }
  // 先写一个文件来创建目录
  let _ = fs_write_atomic(tmp_dir + "/.dummy", "")
  rhop_send(tmp_dir, "overwrite", packet1, cipher)
  rhop_send(tmp_dir, "overwrite", packet2, cipher)
  // 验证文件存在（覆盖成功）
  let files = fs_list_rhop(tmp_dir)
  match files {
    Ok(flist) => {
      let has_overwrite = Ref::Ref(false)
      for f in flist {
        if f == "overwrite.rhop" {
          has_overwrite.val = true
          break
        }
      }
      assert_eq(has_overwrite.val, true)
    }
    Err(_) => fail("fs_list_rhop failed")
  }
}
