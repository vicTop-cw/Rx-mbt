# GHASH 对拍真值 fixture（ghash_ref.js）

来源：2026-11-21 BUG-4（k4 诊断残留转正）排查期间，为 native GHASH 实现写的
node 参考实现（node:crypto 为权威真值）。

## 背景（k4 移位回绕坑实录）

k4 测试曾长期红，node 对拍实锤 native ghash 无罪（对坏输入算出 b79be1f1 与参考
一致）——真凶是 k4 测试自身 fa 构造 1:1 拷贝了修复前 gcm_tag 的 32 位 Int 移位
mod 32 回绕坑（`128 >> 32` → `128 >> 0` = 0x80 误写 fa[27]，双 0x80）+ 末尾恒红
fail()。即：**native 是「坏输入的正确答案」**。

## 用法

```bash
node test-suit/ghash/ghash_ref.js   # 按脚本内内建的用例输出 GHASH 真值
```

对拍口径：以 node:crypto 输出为权威真值，native/js 两实现与之逐字节比对；
坏输入的"正确答案"也是真值的一部分（防止用实现修测试、或用测试迁就实现）。

## 纪律

- 本 fixture 只进 `test-suit/ghash/`（tracked），不放 `temp/`（gitignored，
  证据链会丢——BUG-4 排查时曾因此只剩记忆没有锚点）。
- 修改 GHASH 实现前先跑本脚本生成期望值，改完逐字节比对。
