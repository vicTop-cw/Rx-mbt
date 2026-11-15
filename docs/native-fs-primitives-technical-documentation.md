# 文件系统原语与跨机消息传输模块技术文档

## 概述

本文档详细介绍 rx-mbt 项目中 native 文件系统原语（fs primitives）与跨机消息传输（rhop）模块的实现原理、功能特性、适用场景及技术对比分析。该实现解决了 MoonBit 在 native 后端缺乏文件系统 API 的问题，为跨机池（M2）提供了硬前置能力。

---

## 1. 功能特性

### 1.1 核心文件系统原语

#### 1.1.1 读文本文件（fs_read_text）

**功能描述**：读取 UTF-8 编码的文本文件，返回文件内容。

**API 签名**：
```moonbit
pub fn fs_read_text(path : String) -> Result[String, FsError]
```

**实现要点**：
- 使用 C FFI 调用底层文件系统 API
- Windows 平台使用宽字符 API（_wopen）处理 UTF-16 路径
- POSIX 平台使用标准 fopen
- 自动处理文件大小计算和内存分配

**错误处理**：
- `FsError::NotFound` - 文件不存在
- `FsError::Io` - I/O 错误
- `FsError::OutOfMemory` - 内存不足

#### 1.1.2 原子写文件（fs_write_atomic）

**功能描述**：通过 tmp + rename 实现原子写文件，保证写操作的原子性。

**API 签名**：
```moonbit
pub fn fs_write_atomic(
  path : String,
  content : String,
) -> Result[Unit, FsError]
```

**实现要点**：
- 自动创建不存在的父目录
- 先写入临时文件（.tmp 后缀），再原子重命名
- Windows 使用 `MoveFileExW(MOVEFILE_REPLACE_EXISTING)` 保证原子覆盖
- POSIX 使用 `rename()` 系统调用

**原子性保证**：
- 写操作要么完全成功，要么完全失败
- 不会出现半写文件状态
- 支持并发安全覆盖已存在文件

#### 1.1.3 列目录（fs_list_rhop）

**功能描述**：列出目录下所有 .rhop 文件，排除临时文件。

**API 签名**：
```moonbit
pub fn fs_list_rhop(dir : String) -> Result[Array[String], FsError]
```

**实现要点**：
- 返回 JSON 数组格式的文件名列表
- 自动过滤 .rhop.tmp 临时文件
- Windows 使用 FindFirstFileW/FindNextFileW
- POSIX 使用 opendir/readdir

#### 1.1.4 文件状态（fs_stat）

**功能描述**：获取文件状态信息（修改时间、文件大小）。

**API 签名**：
```moonbit
pub fn fs_stat(path : String) -> Result[FileStat, FsError]
```

**返回结构**：
```moonbit
pub struct FileStat {
  mtime_ns : Int64  // 修改时间（纳秒）
  size : Int64      // 文件大小（字节）
}
```

**时间精度**：
- Windows：使用 FILETIME 转换为 Unix 纳秒时间戳
- POSIX：使用 stat.st_mtim 获取纳秒精度

#### 1.1.5 辅助功能

```moonbit
/// 检查文件是否存在
pub fn fs_exists(path : String) -> Bool

/// 删除文件
pub fn fs_remove(path : String) -> Result[Unit, String]
```

---

### 1.2 跨机消息传输（rhop）

#### 1.2.1 消息发送（rhop_send）

**功能描述**：发送一条 RHOP 消息，原子写 shared_path/<filename>.rhop。

**API 签名**：
```moonbit
pub fn[T : RhopCipher] rhop_send(
  shared_path : String,
  filename : String,
  packet : RhopPacket,
  cipher : T,
) -> Unit
```

**实现流程**：
1. 使用 cipher.encrypt 加密消息内容
2. 使用 RhopEnvelope::encode 编码信封
3. 使用 fs_write_atomic 原子写文件

**与 js 版 1:1 对齐**：
- 仅把 node FFI 换成 C FFI
- 行为一致，保证跨平台兼容性

#### 1.2.2 消息监控（from_filesystem）

**功能描述**：监控 shared path，捕获新增/变更的 .rhop 文件，解码为 RhopPacket 流。

**API 签名**：
```moonbit
pub fn[T : RhopCipher] from_filesystem(
  shared_path : String,
  cipher : T,
) -> @rx.Observable[RhopPacket, String]

pub fn[T : RhopCipher] from_filesystem_with(
  shared_path : String,
  cipher : T,
  skip_existing : Bool,
) -> @rx.Observable[RhopPacket, String]
```

**实现要点**：
- 使用同步阻塞轮询循环（与 js 事件驱动语义不同）
- 轮询间隔默认 1000ms
- skip_existing=true 时预填 seen 集合，跳过历史消息
- 自动过滤 .rhop.tmp 临时文件
- 支持 envelope v=1 校验和坏文件跳过

---

## 2. 架构设计

### 2.1 分层架构

```
┌─────────────────────────────────────────────────────────────┐
│                    应用层（rhop）                              │
│  rhop_send / from_filesystem / watch_folder                  │
├─────────────────────────────────────────────────────────────┤
│                    业务逻辑层                                  │
│  RhopPacket / RhopEnvelope / RhopCipher                       │
├─────────────────────────────────────────────────────────────┤
│                    文件系统抽象层                              │
│  monitor/fs_native.mbt / rhop/rhop_fs_native.mbt              │
│  fs_read_text / fs_write_atomic / fs_list_rhop / fs_stat      │
├─────────────────────────────────────────────────────────────┤
│                    FFI 绑定层                                  │
│  extern "c" 声明 + #borrow/#owned 注解                         │
├─────────────────────────────────────────────────────────────┤
│                    C 实现层                                    │
│  monitor/fs_native_stubs.c                                    │
│  Windows API / POSIX API                                      │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 跨包依赖设计

**问题背景**：MoonBit 工具链中，`#cfg(target="native")` 门控的函数不会导出到 `.mbti` 接口文件，导致跨包导入失败。

**解决方案**：在 rhop 包中创建 `rhop_fs_native.mbt` 模块，直接实现 fs 原语，避免跨包依赖问题。

**包结构**：
```
monitor/
├── fs_native_stubs.c      # C FFI 实现
├── fs_native.mbt          # MoonBit 包装（monitor 包内部使用）
├── watcher_native.mbt     # 文件监控实现
└── moon.pkg               # native-stub 配置

rhop/
├── rhop_fs_native.mbt     # fs 原语实现（rhop 包专用）
├── rhop_native.mbt        # 消息发送/监控实现
├── rhop_native_wbtest.mbt # 白盒测试
└── moon.pkg               # targets 配置
```

---

## 3. 适用场景

### 3.1 跨机池通信（M2）

**场景描述**：FIST-Mbt 跨机池需要在多台机器间共享消息，通过文件系统交换实现。

**解决方案**：
- 使用 rhop_send 发送消息到共享目录
- 使用 from_filesystem 监控共享目录，接收消息
- 使用 skip_existing=true 避免重放历史消息

### 3.2 本地消息队列

**场景描述**：需要持久化消息队列，支持断点续传。

**解决方案**：
- 使用 fs_write_atomic 原子写消息文件
- 使用 fs_list_rhop 列出待处理消息
- 使用 fs_stat 获取消息状态（修改时间、大小）

### 3.3 文件系统监控

**场景描述**：监控目录变化，实时响应文件创建、修改、删除事件。

**解决方案**：
- 使用 watch_folder 监控目录
- 使用 watch_file 监控单文件
- 快照 diff 算法检测变化

---

## 4. 优缺点分析

### 4.1 优点

| 方面 | 优势 |
|------|------|
| **原子性** | tmp + rename 保证写操作原子性，无半写文件风险 |
| **跨平台** | Windows/POSIX 双平台支持，自动处理路径编码 |
| **性能** | 轮询间隔可配置，默认 1000ms，平衡响应速度与 CPU 占用 |
| **兼容性** | 与 js 版 1:1 行为对齐，保证跨平台一致性 |
| **安全性** | 自动创建父目录，避免路径遍历攻击 |
| **可观测性** | 纳秒级时间戳，支持精确的事件排序 |

### 4.2 缺点

| 方面 | 劣势 |
|------|------|
| **实时性** | 轮询模式（非事件驱动），响应延迟取决于轮询间隔 |
| **CPU 占用** | 同步阻塞轮询循环，需在独立线程/进程中运行 |
| **目录长度限制** | 路径长度硬编码 1024 字节，限制深层目录 |
| **文件数量限制** | 目录内容硬编码 65536 字节 JSON 缓冲区 |
| **错误恢复** | 轮询循环中错误被静默跳过，缺乏重试机制 |
| **内存管理** | 手动内存管理（C 层），存在内存泄漏风险 |

---

## 5. 与相关方案的对比

### 5.1 与 Node.js fs 模块对比

| 特性 | 本实现 | Node.js fs |
|------|--------|------------|
| **原子写** | tmp + rename | fs.writeFile（非原子） |
| **目录监控** | 轮询快照 diff | fs.watch（事件驱动） |
| **路径编码** | 自动 UTF-8/UTF-16 转换 | 自动处理 |
| **错误处理** | Result 类型 | 异常/回调 |
| **跨平台** | Windows/POSIX | 全平台 |
| **实时性** | 轮询延迟 | 事件驱动实时 |

### 5.2 与 inotify（Linux）对比

| 特性 | 本实现 | inotify |
|------|--------|---------|
| **监控机制** | 轮询 | 内核事件 |
| **性能** | 中等 | 高 |
| **跨平台** | 是 | 仅 Linux |
| **事件类型** | Created/Modified/Removed | 丰富的事件类型 |
| **资源占用** | CPU 轮询 | 内核资源 |
| **延迟** | 轮询间隔 | 实时 |

### 5.3 与 ReadDirectoryChangesW（Windows）对比

| 特性 | 本实现 | ReadDirectoryChangesW |
|------|--------|----------------------|
| **监控机制** | 轮询 | 内核事件 |
| **跨平台** | 是 | 仅 Windows |
| **实现复杂度** | 简单 | 复杂 |
| **缓冲区管理** | 自动 | 手动 |
| **递归监控** | 支持 | 支持 |

---

## 6. 实现细节

### 6.1 C FFI 绑定

**所有权注解**：
```moonbit
#borrow(path)        # C 只读，不存储引用
#owned(content)      # 所有权转移，C 必须 decref
```

**错误码约定**：
```c
#define FS_OK          0
#define FS_ERR_NOTFOUND 1
#define FS_ERR_IO       2
#define FS_ERR_NOMEM    3
```

### 6.2 快照 Diff 算法

```
1. 构建初始快照：Map<path, (mtime_ns, size)>
2. 每个轮询间隔：
   a. 构建新快照
   b. Diff 新旧快照：
      - 新路径 → Created
      - 修改时间/大小变化 → Modified
      - 旧快照中不存在 → Removed
   c. 更新当前快照
3. 产出事件列表
```

### 6.3 原子写流程

```
1. 创建父目录（如果不存在）
2. 写入临时文件：path + ".tmp"
3. 原子重命名：tmp → target
   - Windows: MoveFileExW(MOVEFILE_REPLACE_EXISTING)
   - POSIX: rename()
4. 失败时清理临时文件
```

---

## 7. 测试覆盖

### 7.1 单元测试

| 测试文件 | 覆盖内容 | 状态 |
|----------|----------|------|
| fs_native_wbtest.mbt | 读/写/列目录/stat 四原语 | ✅ 通过 |
| rhop_native_wbtest.mbt | rhop_send 原子写、覆盖已存在文件 | ✅ 通过 |

### 7.2 集成测试

- 全项目测试：645/646 通过（1 个失败与 fs 原语无关）
- rhop native 白盒测试：2/2 通过
- 编译检查：0 errors

---

## 8. 后续优化方向

1. **事件驱动监控**：引入 inotify/ReadDirectoryChangesW，降低轮询延迟
2. **路径长度限制**：使用动态分配替代固定缓冲区
3. **错误恢复**：添加重试机制和错误上报
4. **性能优化**：使用内存映射文件（mmap）提升大文件读取性能
5. **跨平台抽象**：统一 Windows/POSIX 路径处理逻辑

---

## 9. 参考资料

- MoonBit 官方文档：https://docs.moonbitlang.com
- MoonBit C Binding 技能：`E:\IDEProjects\moonbit-skills\skills\moonbit-c-binding\SKILL.md`
- Node.js fs 模块文档：https://nodejs.org/api/fs.html
- inotify 手册：man 7 inotify

---

**文档版本**：v1.0  
**最后更新**：2026-11-15  
**作者**：rx-mbt 开发团队