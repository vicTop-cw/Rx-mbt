# PLAN-clipboard-input-monitor —— 剪贴板与鼠标键盘监控（待扩展）

> 日期：2026-11-15
> 状态：**draft（待 human_steward 定案后进入执行）**
> 依据：用户需求（剪贴板监控、鼠标键盘监控、用户 vs 程序区分）
> 范围：仅拟定计划，不实现

---

## 1. 背景与目标

### 1.1 需求来源

用户提出三个问题：
1. 剪贴板监控没做？需要做吧？
2. 鼠标键盘监控是否要做？
3. 如何区分是用户操作还是程序操作？

### 1.2 当前状态

- 剪贴板监控：❌ 未实现
- 鼠标键盘监控：❌ 未实现
- 用户 vs 程序区分：❌ 未实现

### 1.3 目标

拟定三个模块的实施计划：
1. 剪贴板监控模块
2. 鼠标键盘监控模块
3. 用户 vs 程序操作区分模块

---

## 2. 范围界定

### 2.1 目标

| 模块 | 功能 | 优先级 |
|------|------|--------|
| 剪贴板监控 | 监听剪贴板内容变化，获取文本/图像/文件 | P1 |
| 鼠标键盘监控 | 监听鼠标点击、移动、键盘输入 | P2 |
| 用户 vs 程序区分 | 判断操作来源（用户/程序） | P3 |

### 2.2 非目标

- 不在当前 PLAN-mcp-watcher-native-gaps.md 范围内
- 不与 mcp-watcher 文件系统监控冲突
- 不实现跨平台事件驱动后端（inotify/ReadDirectoryChangesW）

---

## 3. 技术方案

### 3.1 剪贴板监控

#### 3.1.1 Windows 实现

```c
// 使用 Windows API
#include <windows.h>

// 剪贴板监控方式：
// 1. AddClipboardFormatListener (Windows Vista+)
// 2. SetClipboardViewer (兼容旧版)

// 获取剪贴板文本
char* get_clipboard_text() {
    if (!OpenClipboard(NULL)) return NULL;
    HANDLE hData = GetClipboardData(CF_UNICODETEXT);
    if (!hData) {
        CloseClipboard();
        return NULL;
    }
    wchar_t* wide = (wchar_t*)GlobalLock(hData);
    // 转换为 UTF-8
    // ...
    GlobalUnlock(hData);
    CloseClipboard();
    return utf8_text;
}
```

#### 3.1.2 POSIX 实现

```c
// Linux: X11 或 Wayland
// macOS: NSPasteboard

// Linux X11 示例
#include <X11/Xlib.h>
#include <X11/Xatom.h>

// 监听 X11 剪贴板事件
// 需要 X11 开发库
```

#### 3.1.3 MoonBit FFI 绑定

```moonbit
// monitor/clipboard_native.mbt

///|
/// 剪贴板内容类型
pub enum ClipboardKind {
  Text(String)
  Image(Bytes)
  Files(Array[String])
  Unknown
}

///|
/// 剪贴板事件
pub struct ClipboardEvent {
  kind : ClipboardKind
  timestamp : Int64
  source : String  // 来源应用
}

///|
/// 启动剪贴板监控
/// 返回：Observable<ClipboardEvent, ClipboardError>
pub fn clipboard_monitor() -> @rx.Observable[ClipboardEvent, ClipboardError]

///|
/// 获取当前剪贴板内容
pub fn clipboard_get_text() -> Result[String, ClipboardError]
```

### 3.2 鼠标键盘监控

#### 3.2.1 Windows 实现

```c
// 使用 Windows 低级钩子
#include <windows.h>

// 鼠标钩子
HHOOK mouse_hook = SetWindowsHookEx(
    WH_MOUSE_LL, 
    LowLevelMouseProc, 
    NULL, 
    0
);

// 键盘钩子
HHOOK keyboard_hook = SetWindowsHookEx(
    WH_KEYBOARD_LL, 
    LowLevelKeyboardProc, 
    NULL, 
    0
);

// 钩子回调
LRESULT CALLBACK LowLevelMouseProc(int nCode, WPARAM wParam, LPARAM lParam) {
    if (nCode >= 0) {
        MSLLHOOKSTRUCT* p = (MSLLHOOKSTRUCT*)lParam;
        // 记录鼠标事件
        // wParam: WM_LBUTTONDOWN, WM_RBUTTONDOWN, WM_MOUSEMOVE, ...
    }
    return CallNextHookEx(NULL, nCode, wParam, lParam);
}
```

#### 3.2.2 POSIX 实现

```c
// Linux: /dev/input/event* (需要 root 权限)
// macOS: Accessibility API + CGEventTap

// Linux 示例
#include <linux/input.h>
#include <fcntl.h>

int fd = open("/dev/input/event0", O_RDONLY | O_NONBLOCK);
struct input_event ev;
read(fd, &ev, sizeof(ev));
// ev.type = EV_KEY (键盘) 或 EV_REL (鼠标)
```

#### 3.2.3 MoonBit FFI 绑定

```moonbit
// monitor/input_native.mbt

///|
/// 输入事件类型
pub enum InputEvent {
  MouseMove { x: Int32, y: Int32 }
  MouseClick { x: Int32, y: Int32, button: MouseButton }
  Keyboard { key: String, pressed: Bool }
}

///|
/// 鼠标按钮
pub enum MouseButton {
  Left
  Right
  Middle
  Unknown
}

///|
/// 启动鼠标键盘监控
pub fn input_monitor() -> @rx.Observable[InputEvent, InputError]
```

### 3.3 用户 vs 程序区分

#### 3.3.1 判断维度

| 维度 | 实现方法 | 准确性 |
|------|----------|--------|
| **硬件输入状态** | `GetAsyncKeyState` / `GetKeyState` | 高 |
| **输入序列模式** | 时间间隔分析（程序输入更规律） | 中 |
| **应用上下文** | `GetForegroundWindow` / 进程 ID | 中 |
| **进程/线程标识** | `GetWindowThreadProcessId` | 高 |

#### 3.3.2 实现策略

```c
// Windows 示例
BOOL is_user_input() {
    // 方法1：检查硬件状态
    SHORT state = GetAsyncKeyState(VK_LBUTTON);
    if (state & 0x8000) return TRUE;
    
    // 方法2：检查输入来源
    DWORD thread_id = GetWindowThreadProcessId(GetForegroundWindow(), NULL);
    DWORD current_thread = GetCurrentThreadId();
    if (thread_id != current_thread) {
        // 输入来自其他线程，可能是程序模拟
        return FALSE;
    }
    
    // 方法3：时间窗口分析
    // 程序模拟的输入通常更规律（固定间隔）
    // 用户输入通常有随机性
    
    return TRUE;  // 默认认为是用户输入
}
```

#### 3.3.3 MoonBit API

```moonbit
// monitor/input_classifier.mbt

///|
/// 操作来源
pub enum InputSource {
  User
  Program
  Unknown
}

///|
/// 分类输入事件来源
pub fn classify_input_source(event : InputEvent) -> InputSource

///|
/// 获取分类置信度
pub fn get_confidence(event : InputEvent) -> Float  // 0.0 ~ 1.0
```

---

## 4. 跨平台兼容性

| 平台 | 剪贴板 | 鼠标键盘 | 用户区分 |
|------|--------|----------|----------|
| Windows | ✅ 支持 | ✅ 支持 | ✅ 支持 |
| Linux | ⚠️ X11/Wayland | ⚠️ 需 root | ⚠️ 需 root |
| macOS | ⚠️ NSPasteboard | ⚠️ Accessibility | ⚠️ Accessibility |

**建议**：
- 优先实现 Windows 版本
- Linux/macOS 后续扩展
- 提供 `#[cfg(target_os = "windows")]` 条件编译

---

## 5. 安全与权限

### 5.1 权限需求

| 平台 | 权限 | 说明 |
|------|------|------|
| Windows | 无特殊权限 | 低级钩子需要 UIAccess 或管理员 |
| Linux | root 或 input 组 | /dev/input/event* 访问 |
| macOS | Accessibility API | 系统偏好设置授权 |

### 5.2 隐私考虑

- 剪贴板监控可能涉及敏感信息
- 鼠标键盘监控涉及用户隐私
- 需要明确告知用户并获取授权
- 提供关闭/禁用选项

---

## 6. 实施计划

### 6.1 阶段划分

| 阶段 | 内容 | 预计时间 |
|------|------|----------|
| P0 | 环境自检（确认 API 可用性） | 1 天 |
| P1 | 剪贴板监控（Windows） | 3 天 |
| P2 | 鼠标键盘监控（Windows） | 5 天 |
| P3 | 用户 vs 程序区分 | 3 天 |
| P4 | 跨平台扩展（Linux/macOS） | 5 天 |
| P5 | 测试与文档 | 2 天 |

### 6.2 验收标准

1. `moon test --target native` 全绿
2. 剪贴板监控：能实时监听剪贴板变化
3. 鼠标键盘监控：能记录事件序列
4. 用户区分：准确率 > 80%
5. 文档完整

---

## 7. 风险

| 风险 | 影响 | 缓解措施 |
|------|------|----------|
| 权限不足 | 无法运行 | 提供降级方案（仅监控自身进程） |
| 跨平台兼容 | 实现复杂 | 优先 Windows，后续扩展 |
| 性能影响 | 系统卡顿 | 限制监控频率，使用异步 |
| 隐私问题 | 用户抵触 | 明确告知，提供关闭选项 |

---

## 8. 参考资料

- Windows Clipboard: https://docs.microsoft.com/en-us/windows/win32/dataxchg/clipboard
- Windows Hooks: https://docs.microsoft.com/en-us/windows/win32/winmsg/hooks
- Linux Input: https://www.kernel.org/doc/html/latest/input/input.html
- macOS Accessibility: https://developer.apple.com/documentation/accessibility

---

**文档版本**：v1.0-draft  
**状态**：待确认  
**下一步**：等待用户确认后进入 P0 实施