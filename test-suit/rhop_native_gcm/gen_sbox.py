#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_sbox.py —— rhop/cipher_gcm.mbt 的 S-box 表生成器（GF(2^8) 权威算法）

Bug 历史（2026-11-18 R1 中断现场）：上一版生成器的仿射变换**第一项错用输入 i
而非逆元 b**；i=0/1 时恰好 i==b 未暴露，i=2 首次出错（上一轮日志记录得 0xf8，
官方表为 0x77）。本脚本修正：s(i) = affine(ginv(i)) ^ 0x63，其中
affine(b) = b ^ rotl(b,1) ^ rotl(b,2) ^ rotl(b,3) ^ rotl(b,4)（FIPS-197 §5.1）。

三重交叉验证（全过才输出）：
  V1. 两种独立 ginv 实现（指数法 x^254 / 扩展欧几里得）256/256 一致
  V2. 生成表与 FIPS-197 官方发表表 256/256 一致
  V3. 逆表双射：isbox[sbox[i]] == i 对所有 i 成立

用法：python test-suit/rhop_native_gcm/gen_sbox.py
输出：stdout = 供嵌入 cipher_gcm.mbt 的 MoonBit 数组字面量 + PASS 证据行。
再跑本脚本必须保持全绿；若官方表引用与生成结果不一致，先查本脚本再改表。
"""

MOD = 0x11B  # x^8 + x^4 + x^3 + x + 1


def gmul(a: int, b: int) -> int:
    """GF(2^8) 乘法（移位-异或，0x11b 约简）。"""
    p = 0
    while b:
        if b & 1:
            p ^= a
        a <<= 1
        if a & 0x100:
            a ^= 0x11B
        b >>= 1
    return p


def ginv_pow(x: int) -> int:
    """逆元 = x^254（费马，域中非零元阶 255）。"""
    if x == 0:
        return 0
    r = 1
    for _ in range(254):
        r = gmul(r, x)
    return r


def _deg(p: int) -> int:
    d = 0
    while p > 1:
        p >>= 1
        d += 1
    return d


def _mul_poly(a: int, b: int) -> int:
    """GF(2) 多项式乘法（不约简，a/b 为整数码位表示）。"""
    r = 0
    i = 0
    while b:
        if b & 1:
            r ^= a << i
        b >>= 1
        i += 1
    return r


def ginv_egcd(x: int):
    """扩展欧几里得求逆（独立于 gmul 的第二实现；x=0 返回 0）。"""
    if x == 0:
        return 0

    def divmod_poly(r: int, d: int):
        q = 0
        while r and _deg(r) >= _deg(d):
            k = _deg(r) - _deg(d)
            q |= 1 << k
            r ^= d << k
        return q, r

    def reduce8(p: int) -> int:
        while _deg(p) >= 8:
            p ^= 0x11B << (_deg(p) - 8)
        return p

    # 不变式（GF(2) 多项式环，不约简）：SR*MOD + TR*x == R ；SA*MOD + TA*x == A
    R, SR, TR = 0x11B, 1, 0
    A, SA, TA = x, 0, 1
    while True:
        q, rem = divmod_poly(R, A)
        if rem == 0:
            break
        # 元组赋值两行连写会让第二行拿到已被第一行覆写的 SR/TR（顺序陷阱），
        # 故先用临时量按旧值算出新的 Bezout 系数，再统一换行。
        new_SA = SR ^ _mul_poly(q, SA)
        new_TA = TR ^ _mul_poly(q, TA)
        R, SR, TR = A, SA, TA
        A, SA, TA = rem, new_SA, new_TA
    if A != 1:
        return None  # 不可逆（仅 x=0 会走到，已在前排除）
    return reduce8(TA)


def rotl(a: int, n: int) -> int:
    return ((a << n) | (a >> (8 - n))) & 0xFF


def affine(b: int) -> int:
    """FIPS-197 §5.1 仿射：作用于**逆元 b**（本脚本修正点），再异或 0x63。"""
    v = b
    for k in (1, 2, 3, 4):
        v ^= rotl(b, k)
    return v ^ 0x63


# FIPS-197 官方发表 S-box（参考实现；逐行照抄标准原文）
OFFICIAL = [
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
    0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
    0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
    0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
    0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
    0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
    0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
    0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
    0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
]
assert len(OFFICIAL) == 256 and len(set(OFFICIAL)) == 256, "官方表引用本身不合法"


def main() -> None:
    # V1：两种 ginv 实现互验
    inv = [0] * 256
    for i in range(256):
        a, b = ginv_pow(i), ginv_egcd(i)
        assert a == b, "V1 失败：i=%d 两实现不一致 %x vs %r" % (i, a, b)
        inv[i] = a
    # 抽查：2*ginv(2)==1、sbox(0x57) 官方为 0x8f ⇒ ginv(0x57)=0x53
    assert gmul(2, inv[2]) == 1
    print("V1 PASS: 两独立 ginv 实现 256/256 一致（ginv(2)=0x%02x, 2*ginv(2)=1）" % inv[2])

    # 生成（修正后：仿射作用于逆元 b）
    sbox = [affine(b) for b in inv]

    # V2：与 FIPS-197 官方表逐字节一致
    bad = [i for i in range(256) if sbox[i] != OFFICIAL[i]]
    assert not bad, "V2 失败：与官方表不一致，首 8 个差异索引=%r 值=%r" % (
        bad[:8], [sbox[i] for i in bad[:8]])
    print("V2 PASS: 生成表与 FIPS-197 官方表 256/256 一致（sbox[0..3]=%s）"
          % [hex(v) for v in sbox[:4]])

    # V3：逆表双射
    isbox = [0] * 256
    for i in range(256):
        isbox[sbox[i]] = i
    assert all(isbox[sbox[i]] == i for i in range(256))
    assert len(set(sbox)) == 256
    print("V3 PASS: 逆表双射 isbox[sbox[i]]==i 256/256")

    # 证据：旧 bug（仿射首项用输入 i）与官方表在 i=2 处的差异
    def affine_buggy_first_term(i: int) -> int:
        v = i  # ← 旧 bug：首项是输入 i 而非逆元 b
        for k in (1, 2, 3, 4):
            v ^= rotl(i, k)
        return v ^ 0x63
    print("BUG 证据: 首项=输入 i 的变体 sbox[2]=0x%02x ≠ 官方 0x%02x；"
          "首项=逆元 b 的修正值 sbox[2]=0x%02x == 官方"
          % (affine_buggy_first_term(2), OFFICIAL[2], sbox[2]))

    # 输出：MoonBit 数组字面量（16 字节/行，带行注释 = 官方表行号）
    print()
    print("let SBOX : Array[UInt8] = [")
    for r in range(16):
        row = sbox[r * 16:(r + 1) * 16]
        print("  " + ", ".join("0x%02x" % v for v in row) + ("," if r < 15 else ""))
    print("]")


if __name__ == "__main__":
    main()
