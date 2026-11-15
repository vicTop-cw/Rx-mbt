// ============================================================================
// watch_native_stubs.c —— monitor 包 native 事件驱动文件监控 FFI 实现
// 平台：Windows（ReadDirectoryChangesW）
// 编译：由 MoonBit 工具链通过 native-stub 自动编译
//
// 架构：C 侧后台线程跑 ReadDirectoryChangesW（内核事件驱动，非轮询全量扫描），
//       事件写入固定容量环形缓冲；MoonBit 侧低频（如 50ms）拉取缓冲并
//       on_next 派发。内核事件真实、CPU 占用极低（仅拉取循环的低频 sleep）。
//
// 事件编码格式（MoonBit 侧解析）：
//   每条 = kind(1 字节) + path_len(4 字节大端) + path 字节
//   kind: 1=created 2=modified 3=deleted 4=renamed(旧名→新名，两条事件)
// ============================================================================

#include <moonbit.h>
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

// ---------------------------------------------------------------------------
// 环形缓冲
// ---------------------------------------------------------------------------
#define WATCH_BUF_CAP 256
#define WATCH_PATH_MAX 1024

typedef struct {
  uint8_t kind;          // 1=created 2=modified 3=deleted 4=renamed
  uint32_t path_len;
  char path[WATCH_PATH_MAX];
} watch_event_t;

static watch_event_t g_buf[WATCH_BUF_CAP];
static volatile int g_head = 0;   // 写位置（后台线程）
static volatile int g_tail = 0;   // 读位置（MoonBit 侧）

static CRITICAL_SECTION g_cs;
static HANDLE g_stop_event = NULL;
static HANDLE g_thread = NULL;
static HANDLE g_dir_handle = NULL;
static char g_watch_path[WATCH_PATH_MAX];
static int g_recursive = 1;

// ---------------------------------------------------------------------------
// 环形缓冲写入（满则丢弃最旧）
// ---------------------------------------------------------------------------
static void buf_push(uint8_t kind, const char *path) {
  EnterCriticalSection(&g_cs);
  int next = (g_head + 1) % WATCH_BUF_CAP;
  if (next == g_tail) {
    // 满：丢弃最旧（tail 前进）
    g_tail = (g_tail + 1) % WATCH_BUF_CAP;
  }
  g_buf[g_head].kind = kind;
  uint32_t len = (uint32_t)strlen(path);
  if (len >= WATCH_PATH_MAX) len = WATCH_PATH_MAX - 1;
  g_buf[g_head].path_len = len;
  memcpy(g_buf[g_head].path, path, len);
  g_buf[g_head].path[len] = '\0';
  g_head = next;
  LeaveCriticalSection(&g_cs);
}

// ---------------------------------------------------------------------------
// 宽字符 → UTF-8（用于拼接完整路径后转回 char）
// ---------------------------------------------------------------------------
static int wtoa(const wchar_t *w, char *out, int out_cap) {
  int len = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
  if (len <= 0 || len > out_cap) return -1;
  WideCharToMultiByte(CP_UTF8, 0, w, -1, out, len, NULL, NULL);
  return len;
}

// ---------------------------------------------------------------------------
// 后台线程：ReadDirectoryChangesW 阻塞循环
// ---------------------------------------------------------------------------
static DWORD WINAPI watch_thread(LPVOID arg) {
  // 打开目录句柄（FILE_FLAG_BACKUP_SEMANTICS 才能监听目录）
  int wide_len = MultiByteToWideChar(CP_UTF8, 0, g_watch_path, -1, NULL, 0);
  wchar_t *wide_path = (wchar_t *)malloc(wide_len * sizeof(wchar_t));
  if (!wide_path) return 1;
  MultiByteToWideChar(CP_UTF8, 0, g_watch_path, -1, wide_path, wide_len);

  HANDLE hDir = CreateFileW(
      wide_path,
      GENERIC_READ,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
      NULL, OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS,
      NULL);
  free(wide_path);
  if (hDir == INVALID_HANDLE_VALUE) {
    return 2;
  }
  g_dir_handle = hDir;

  // 同步阻塞读循环（后台线程内阻塞安全）
  char raw[65536];
  while (TRUE) {
    DWORD bytes = 0;
    DWORD ok = ReadDirectoryChangesW(
        hDir, raw, sizeof(raw),
        g_recursive ? TRUE : FALSE,
        FILE_NOTIFY_CHANGE_FILE_NAME |
        FILE_NOTIFY_CHANGE_DIR_NAME |
        FILE_NOTIFY_CHANGE_LAST_WRITE |
        FILE_NOTIFY_CHANGE_SIZE,
        &bytes, NULL, NULL);
    if (!ok || bytes == 0) {
      // 出错或停止：检查 stop 事件
      if (WaitForSingleObject(g_stop_event, 0) == WAIT_OBJECT_0) break;
      Sleep(100);
      continue;
    }

    // 解析 FILE_NOTIFY_INFORMATION 链表（全程宽字符拼接，避免 char/wchar 混用）
    FILE_NOTIFY_INFORMATION *fi = (FILE_NOTIFY_INFORMATION *)raw;
    while (TRUE) {
      // 根路径去尾部斜杠 + FileName 长度（字节数 / 2 = 宽字符数）
      int root_len = (int)strlen(g_watch_path);
      while (root_len > 0 &&
          (g_watch_path[root_len - 1] == '\\' || g_watch_path[root_len - 1] == '/')) {
        root_len--;
      }
      int fname_wlen = (int)(fi->FileNameLength / sizeof(WCHAR));
      wchar_t full_w[WATCH_PATH_MAX];
      int w = MultiByteToWideChar(CP_UTF8, 0, g_watch_path, root_len,
          full_w, WATCH_PATH_MAX);
      if (w <= 0) { w = 0; full_w[0] = L'\0'; }
      if (w + 1 + fname_wlen < WATCH_PATH_MAX) {
        full_w[w] = L'\\';
        w++;
        memcpy(full_w + w, fi->FileName, fname_wlen * sizeof(WCHAR));
        w += fname_wlen;
        full_w[w] = L'\0';
      } else {
        full_w[w] = L'\0';
      }

      // 宽字符转 UTF-8
      char full[WATCH_PATH_MAX];
      int fname_len = WideCharToMultiByte(CP_UTF8, 0, full_w, w,
          full, WATCH_PATH_MAX, NULL, NULL);
      if (fname_len <= 0) {
        fname_len = 0;
        full[0] = '\0';
      }

      uint8_t kind = 0;
      switch (fi->Action) {
        case FILE_ACTION_ADDED: kind = 1; break;
        case FILE_ACTION_MODIFIED: kind = 2; break;
        case FILE_ACTION_REMOVED: kind = 3; break;
        case FILE_ACTION_RENAMED_OLD_NAME: kind = 3; break;  // 旧名消失
        case FILE_ACTION_RENAMED_NEW_NAME: kind = 1; break;  // 新名出现
        default: kind = 0; break;
      }
      if (kind != 0) {
        buf_push(kind, full);
      }

      if (fi->NextEntryOffset == 0) break;
      fi = (FILE_NOTIFY_INFORMATION *)((char *)fi + fi->NextEntryOffset);
    }
  }

  if (g_dir_handle) {
    CloseHandle(g_dir_handle);
    g_dir_handle = NULL;
  }
  return 0;
}

// ---------------------------------------------------------------------------
// FFI：启动 / 拉取 / 停止
// ---------------------------------------------------------------------------

///|
/// 启动事件驱动监控（后台线程跑 ReadDirectoryChangesW）。
/// path：UTF-8 目录路径；recursive：是否递归子目录。
MOONBIT_FFI_EXPORT
void moonbit_watch_start(moonbit_bytes_t path, int32_t recursive) {
  InitializeCriticalSection(&g_cs);
  g_head = 0;
  g_tail = 0;

  int path_len = Moonbit_array_length(path);
  if (!path || path_len <= 0 || path_len >= WATCH_PATH_MAX) {
    return;
  }
  memcpy(g_watch_path, path, path_len);
  g_watch_path[path_len] = '\0';
  g_recursive = recursive ? 1 : 0;

  g_stop_event = CreateEvent(NULL, TRUE, FALSE, NULL);
  if (!g_stop_event) return;

  g_thread = CreateThread(NULL, 0, watch_thread, NULL, 0, NULL);
}

///|
/// 拉取一批事件（编码字节流写入 out）。
/// 返回编码后总字节数；0 表示无事件。
/// 编码：每条 = kind(1) + path_len(4 大端) + path
MOONBIT_FFI_EXPORT
int32_t moonbit_watch_poll(moonbit_bytes_t out, int32_t out_cap) {
  if (!out || out_cap <= 0) return 0;
  int32_t pos = 0;
  EnterCriticalSection(&g_cs);
  while (g_tail != g_head) {
    watch_event_t *ev = &g_buf[g_tail];
    int need = 1 + 4 + (int)ev->path_len;
    if (pos + need > out_cap) break;  // 缓冲不足，留待下次
    out[pos++] = ev->kind;
    out[pos++] = (ev->path_len >> 24) & 0xFF;
    out[pos++] = (ev->path_len >> 16) & 0xFF;
    out[pos++] = (ev->path_len >> 8) & 0xFF;
    out[pos++] = ev->path_len & 0xFF;
    memcpy(out + pos, ev->path, ev->path_len);
    pos += ev->path_len;
    g_tail = (g_tail + 1) % WATCH_BUF_CAP;
  }
  LeaveCriticalSection(&g_cs);
  return pos;
}

///|
/// 停止监控（置停止事件、等线程退出、清理句柄）。
MOONBIT_FFI_EXPORT
void moonbit_watch_stop() {
  if (g_stop_event) {
    SetEvent(g_stop_event);
    if (g_thread) {
      WaitForSingleObject(g_thread, 2000);
      CloseHandle(g_thread);
      g_thread = NULL;
    }
    CloseHandle(g_stop_event);
    g_stop_event = NULL;
  }
  DeleteCriticalSection(&g_cs);
  g_head = 0;
  g_tail = 0;
}
