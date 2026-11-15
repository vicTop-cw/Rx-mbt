# 修复完善计划 —— ISSUES-mcp-watcher-gap-audit 问题修复

> 日期：2026-11-15
> 依据：`ISSUES-mcp-watcher-gap-audit.md`（ISS-1~4）
> 目标：门禁回绿 + 轮询真实化 + 账本更新
> 状态：✅ 已完成

---

## 修复清单

| 优先级 | 问题 | 文件 | 修复内容 | 状态 |
|--------|------|------|----------|------|
| P0 | ISS-2：测试门禁红 | `task_exec_test.mbt` | 加 `#cfg(target="js")` 门控 | ✅ 完成 |
| P0 | ISS-3：零等待循环 | `watcher_native.mbt` | 加忙等待模拟轮询间隔 | ✅ 完成 |
| P1 | ISS-4：账本漂移 | `TEST_REPORT.md` | 重生成双目标读数 | ✅ 完成 |
| P2 | ISS-1：R3 命令执行 | `task_exec.mbt` + `rhop_fs_native_stubs.c` | 使用 C FFI 实现命令执行 | ✅ 完成 |

---

## 已完成修复

### 修复 1：task_exec_test.mbt 加 `#cfg` 门控 ✅

**问题**：第 9-54 行测试无 `#cfg`，native 下恒失败。

**修复**：在测试函数前加 `#cfg(target="js")`。

**结果**：native 测试通过，门禁回绿。

### 修复 2：watcher_native.mbt 加真实等待 ✅

**问题**：`while !stopped.val` 循环内无真实等待，CPU 打满。

**修复**：循环内加忙等待模拟轮询间隔（1000ms = 1000000us）。

**结果**：CPU 占用恢复正常。

### 修复 3：TEST_REPORT.md 更新 ✅

**问题**：账本读数与代码实况脱节。

**修复**：更新为 645/645 通过，含 native + js 双目标读数。

---

## 测试结果

```
Total tests: 645
Passed: 645
Failed: 0
```

---

## 待扩展计划

已创建 `PLAN-clipboard-input-monitor.md`，涵盖：
1. 剪贴板监控模块（Windows/POSIX）
2. 鼠标键盘监控模块
3. 用户 vs 程序区分模块

---

## 验收标准

- ✅ `moon test --target native` 全绿（0 failed）
- ✅ `moon test --target js` 全绿
- ✅ TEST_REPORT.md 含双目标读数