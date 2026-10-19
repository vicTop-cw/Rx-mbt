// ============================================================================
// rhop · 密码学抽象（跨平台 trait）+ 无加密实现
// ============================================================================

/// 信封密码学抽象：加密/解密 .rhop 的 ct 段
pub trait RhopCipher {
  /// 算法标识（写入信封 alg 字段）
  fn alg_name(Self) -> String
  /// 加密明文，返回密文段
  fn encrypt(Self, String) -> String
  /// 解密密文段，失败返回 None
  fn decrypt(Self, String) -> Option[String]
}

/// 无加密（测试 / 明文信道）：ct = base64(明文)
pub struct RhopCipherNone {}

pub fn RhopCipherNone::new() -> RhopCipherNone {
  RhopCipherNone::{ }
}

pub impl RhopCipher for RhopCipherNone with alg_name(self) {
  "none"
}

pub impl RhopCipher for RhopCipherNone with encrypt(self, plain) {
  @base64.encode(@utf8.encode(plain))
}

pub impl RhopCipher for RhopCipherNone with decrypt(self, token) {
  try {
    Some(@utf8.decode(@base64.decode(token)))
  } catch {
    _ => None
  }
}
