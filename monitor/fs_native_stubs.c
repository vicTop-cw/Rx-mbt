// fs_native_stubs.c —— monitor 包 native 文件系统 FFI 实现
// 平台：Windows (MSVC cl.exe) / POSIX (gcc/clang)
// 编译：由 MoonBit 工具链通过 native-stub 自动编译
//
// 注意：moonbit_bytes_t 是 uint8_t*，直接指向数据；
// 长度通过 Moonbit_array_length 宏从对象头获取。

#include <moonbit.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

// ---------------------------------------------------------------------------
// 平台检测
// ---------------------------------------------------------------------------
#ifdef _WIN32
  #include <windows.h>
  #define PLATFORM_WINDOWS 1
  #define PLATFORM_POSIX   0
#else
  #include <sys/stat.h>
  #include <dirent.h>
  #include <unistd.h>
  #define PLATFORM_WINDOWS 0
  #define PLATFORM_POSIX   1
#endif

// ---------------------------------------------------------------------------
// 错误码约定
// ---------------------------------------------------------------------------
#define FS_OK          0
#define FS_ERR_NOTFOUND 1
#define FS_ERR_IO       2
#define FS_ERR_NOMEM    3

// ---------------------------------------------------------------------------
// fs_read_text: 读 UTF-8 文本文件
// ---------------------------------------------------------------------------
MOONBIT_FFI_EXPORT
moonbit_bytes_t moonbit_fs_read_text(moonbit_bytes_t path) {
  const char *path_str = (const char *)path;
  int32_t path_len = Moonbit_array_length(path);

  if (!path_str || path_len <= 0) {
    return moonbit_make_bytes(0, 0);
  }

#if PLATFORM_WINDOWS
  int wide_len = MultiByteToWideChar(CP_UTF8, 0, path_str, path_len, NULL, 0);
  if (wide_len <= 0) {
    return moonbit_make_bytes(0, 0);
  }
  wchar_t *wide_path = (wchar_t *)malloc((wide_len + 1) * sizeof(wchar_t));
  if (!wide_path) {
    return moonbit_make_bytes(0, 0);
  }
  MultiByteToWideChar(CP_UTF8, 0, path_str, path_len, wide_path, wide_len);
  wide_path[wide_len] = L'\0';

  FILE *f = _wfopen(wide_path, L"rb");
  free(wide_path);
  if (!f) {
    return moonbit_make_bytes(0, 0);
  }

  fseek(f, 0, SEEK_END);
  long file_size = ftell(f);
  fseek(f, 0, SEEK_SET);

  if (file_size < 0) {
    fclose(f);
    return moonbit_make_bytes(0, 0);
  }

  moonbit_bytes_t result = moonbit_make_bytes((int32_t)file_size, 0);
  if (!result) {
    fclose(f);
    return moonbit_make_bytes(0, 0);
  }

  size_t read_len = fread(result, 1, file_size, f);
  fclose(f);

  if (read_len != (size_t)file_size) {
    return moonbit_make_bytes(0, 0);
  }

  return result;
#else
  FILE *f = fopen(path_str, "rb");
  if (!f) {
    return moonbit_make_bytes(0, 0);
  }

  fseek(f, 0, SEEK_END);
  long file_size = ftell(f);
  fseek(f, 0, SEEK_SET);

  if (file_size < 0) {
    fclose(f);
    return moonbit_make_bytes(0, 0);
  }

  moonbit_bytes_t result = moonbit_make_bytes((int32_t)file_size, 0);
  if (!result) {
    fclose(f);
    return moonbit_make_bytes(0, 0);
  }

  size_t read_len = fread(result, 1, file_size, f);
  fclose(f);

  if (read_len != (size_t)file_size) {
    return moonbit_make_bytes(0, 0);
  }

  return result;
#endif
}

// ---------------------------------------------------------------------------
// fs_write_atomic: 原子写文件（tmp + rename）
// 自动创建不存在的父目录
// ---------------------------------------------------------------------------
MOONBIT_FFI_EXPORT
int32_t moonbit_fs_write_atomic(moonbit_bytes_t path, moonbit_bytes_t content) {
  const char *path_str = (const char *)path;
  int32_t path_len = Moonbit_array_length(path);

  if (!path_str || path_len <= 0) {
    return FS_ERR_IO;
  }

  // 创建父目录
  char dir_path[1024];
  if (path_len >= 1000) {
    return FS_ERR_IO;
  }
  memcpy(dir_path, path_str, path_len);
  dir_path[path_len] = '\0';
  // 找到最后一个斜杠
  for (int32_t i = path_len - 1; i >= 0; i--) {
    if (dir_path[i] == '/' || dir_path[i] == '\\') {
      dir_path[i] = '\0';
      break;
    }
  }

#if PLATFORM_WINDOWS
  // Windows: 创建目录
  int wide_dir_len = MultiByteToWideChar(CP_UTF8, 0, dir_path, -1, NULL, 0);
  if (wide_dir_len > 0) {
    wchar_t *wide_dir = (wchar_t *)malloc(wide_dir_len * sizeof(wchar_t));
    if (wide_dir) {
      MultiByteToWideChar(CP_UTF8, 0, dir_path, -1, wide_dir, wide_dir_len);
      CreateDirectoryW(wide_dir, NULL);
      free(wide_dir);
    }
  }
#else
  // POSIX: 创建目录
  mkdir(dir_path, 0755);
#endif

  char tmp_path[1024];
  if (path_len >= 1000) {
    return FS_ERR_IO;
  }
  memcpy(tmp_path, path_str, path_len);
  tmp_path[path_len] = '\0';
  strcat(tmp_path, ".tmp");

#if PLATFORM_WINDOWS
  int wide_len = MultiByteToWideChar(CP_UTF8, 0, tmp_path, -1, NULL, 0);
  wchar_t *wide_tmp = (wchar_t *)malloc(wide_len * sizeof(wchar_t));
  if (!wide_tmp) return FS_ERR_NOMEM;
  MultiByteToWideChar(CP_UTF8, 0, tmp_path, -1, wide_tmp, wide_len);

  FILE *f = _wfopen(wide_tmp, L"wb");
  if (!f) {
    free(wide_tmp);
    return FS_ERR_IO;
  }

  const void *data = content;
  int32_t data_len = Moonbit_array_length(content);
  if (data && data_len > 0) {
    fwrite(data, 1, data_len, f);
  }
  fclose(f);

  int target_len = MultiByteToWideChar(CP_UTF8, 0, path_str, -1, NULL, 0);
  wchar_t *wide_target = (wchar_t *)malloc(target_len * sizeof(wchar_t));
  if (!wide_target) {
    free(wide_tmp);
    return FS_ERR_NOMEM;
  }
  MultiByteToWideChar(CP_UTF8, 0, path_str, -1, wide_target, target_len);

  BOOL ok = MoveFileExW(wide_tmp, wide_target, MOVEFILE_REPLACE_EXISTING);
  free(wide_tmp);
  free(wide_target);
  if (!ok) {
    DeleteFileA(tmp_path);
    return FS_ERR_IO;
  }
  return FS_OK;
#else
  FILE *f = fopen(tmp_path, "wb");
  if (!f) return FS_ERR_IO;

  const void *data = content;
  int32_t data_len = Moonbit_array_length(content);
  if (data && data_len > 0) {
    fwrite(data, 1, data_len, f);
  }
  fclose(f);

  if (rename(tmp_path, path_str) != 0) {
    unlink(tmp_path);
    return FS_ERR_IO;
  }
  return FS_OK;
#endif
}

// ---------------------------------------------------------------------------
// fs_list_rhop: 列目录下 *.rhop 文件（排除 .rhop.tmp）
// 返回 JSON 数组：["file1.rhop", "file2.rhop", ...]
// ---------------------------------------------------------------------------
MOONBIT_FFI_EXPORT
moonbit_bytes_t moonbit_fs_list_rhop(moonbit_bytes_t dir) {
  const char *dir_str = (const char *)dir;
  int32_t dir_len = Moonbit_array_length(dir);
  char dir_path[1024];
  char json[65536];
  int json_len = 1;
  int first = 1;

  if (!dir_str || dir_len <= 0) {
    return moonbit_make_bytes(0, 0);
  }

  if (dir_len >= 1000) {
    return moonbit_make_bytes(0, 0);
  }
  memcpy(dir_path, dir_str, dir_len);
  dir_path[dir_len] = '\0';

  json[0] = '[';

#if PLATFORM_WINDOWS
  int wide_len = MultiByteToWideChar(CP_UTF8, 0, dir_path, -1, NULL, 0);
  if (wide_len <= 0) {
    return moonbit_make_bytes(0, 0);
  }
  wchar_t *wide_dir = (wchar_t *)malloc(wide_len * sizeof(wchar_t));
  if (!wide_dir) {
    return moonbit_make_bytes(0, 0);
  }
  MultiByteToWideChar(CP_UTF8, 0, dir_path, -1, wide_dir, wide_len);

  wchar_t search_path[1024];
  swprintf(search_path, 1024, L"%s\\*.rhop", wide_dir);

  WIN32_FIND_DATAW find_data;
  HANDLE hFind = FindFirstFileW(search_path, &find_data);
  if (hFind == INVALID_HANDLE_VALUE) {
    free(wide_dir);
    return moonbit_make_bytes(0, 0);
  }

  char utf8_name[256];
  int utf8_len;

  do {
    const wchar_t *fname = find_data.cFileName;
    int fname_len = (int)wcslen(fname);
    if (fname_len < 5) continue;

    if (fname_len >= 9 && wcscmp(fname + fname_len - 9, L".rhop.tmp") == 0) continue;

    if (fname_len >= 5 && wcscmp(fname + fname_len - 5, L".rhop") == 0) {
      utf8_len = WideCharToMultiByte(CP_UTF8, 0, fname, fname_len, utf8_name, 255, NULL, NULL);
      if (utf8_len > 0) {
        utf8_name[utf8_len] = '\0';
        if (!first) {
          json[json_len++] = ',';
        }
        first = 0;
        json[json_len++] = '"';
        memcpy(json + json_len, utf8_name, utf8_len);
        json_len += utf8_len;
        json[json_len++] = '"';
      }
    }
  } while (FindNextFileW(hFind, &find_data));

  FindClose(hFind);
  free(wide_dir);
#else
  DIR *dirp = opendir(dir_path);
  if (!dirp) {
    return moonbit_make_bytes(0, 0);
  }

  struct dirent *entry;
  int fname_len;
  const char *fname;

  while ((entry = readdir(dirp)) != NULL) {
    fname = entry->d_name;
    fname_len = (int)strlen(fname);
    if (fname_len < 5) continue;

    if (fname_len >= 9 && strcmp(fname + fname_len - 9, ".rhop.tmp") == 0) continue;

    if (fname_len >= 5 && strcmp(fname + fname_len - 5, ".rhop") == 0) {
      if (!first) {
        json[json_len++] = ',';
      }
      first = 0;
      json[json_len++] = '"';
      memcpy(json + json_len, fname, fname_len);
      json_len += fname_len;
      json[json_len++] = '"';
    }
  }

  closedir(dirp);
#endif

  json[json_len++] = ']';
  json[json_len] = '\0';

  moonbit_bytes_t bytes = moonbit_make_bytes(json_len, 0);
  if (bytes) {
    memcpy(bytes, json, json_len);
  }
  return bytes;
}


// ---------------------------------------------------------------------------
// fs_stat: 获取文件状态（mtime_ns, size）
// ---------------------------------------------------------------------------
MOONBIT_FFI_EXPORT
int32_t moonbit_fs_stat(moonbit_bytes_t path, int64_t *mtime_ns_ptr, int64_t *size_ptr) {
  const char *path_str = (const char *)path;
  int32_t path_len = Moonbit_array_length(path);

  if (!path_str || path_len <= 0) {
    return FS_ERR_IO;
  }

#if PLATFORM_WINDOWS
  int wide_len = MultiByteToWideChar(CP_UTF8, 0, path_str, -1, NULL, 0);
  wchar_t *wide_path = (wchar_t *)malloc(wide_len * sizeof(wchar_t));
  if (!wide_path) return FS_ERR_NOMEM;
  MultiByteToWideChar(CP_UTF8, 0, path_str, -1, wide_path, wide_len);

  WIN32_FILE_ATTRIBUTE_DATA fad;
  if (!GetFileAttributesExW(wide_path, GetFileExInfoStandard, &fad)) {
    free(wide_path);
    return FS_ERR_NOTFOUND;
  }
  free(wide_path);

  LARGE_INTEGER li;
  li.HighPart = fad.ftLastWriteTime.dwHighDateTime;
  li.LowPart = fad.ftLastWriteTime.dwLowDateTime;
  int64_t unix_sec = li.QuadPart / 10000000 - 11644473600LL;
  int64_t unix_nsec = (li.QuadPart % 10000000) * 100;
  *mtime_ns_ptr = unix_sec * 1000000000LL + unix_nsec;
  *size_ptr = ((int64_t)fad.nFileSizeHigh << 32) | fad.nFileSizeLow;
  return FS_OK;
#else
  struct stat st;
  if (stat(path_str, &st) != 0) {
    return FS_ERR_NOTFOUND;
  }
  *mtime_ns_ptr = (int64_t)st.st_mtim.tv_sec * 1000000000LL + (int64_t)st.st_mtim.tv_nsec;
  *size_ptr = (int64_t)st.st_size;
  return FS_OK;
#endif
}
// ---------------------------------------------------------------------------
// fs_exists: 检查文件是否存在
// ---------------------------------------------------------------------------
MOONBIT_FFI_EXPORT
int32_t moonbit_fs_exists(moonbit_bytes_t path) {
  const char *path_str = (const char *)path;
  int32_t path_len = Moonbit_array_length(path);

  if (!path_str || path_len <= 0) {
    return 0;
  }

#if PLATFORM_WINDOWS
  int wide_len = MultiByteToWideChar(CP_UTF8, 0, path_str, -1, NULL, 0);
  if (wide_len <= 0) {
    return 0;
  }
  wchar_t *wide_path = (wchar_t *)malloc((wide_len + 1) * sizeof(wchar_t));
  if (!wide_path) {
    return 0;
  }
  MultiByteToWideChar(CP_UTF8, 0, path_str, -1, wide_path, wide_len);
  wide_path[wide_len] = L'\0';

  DWORD attrs = GetFileAttributesW(wide_path);
  free(wide_path);
  return (attrs != INVALID_FILE_ATTRIBUTES) ? 1 : 0;
#else
  struct stat st;
  return (stat(path_str, &st) == 0) ? 1 : 0;
#endif
}

// ---------------------------------------------------------------------------
// fs_remove: 删除文件
// ---------------------------------------------------------------------------
MOONBIT_FFI_EXPORT
int32_t moonbit_fs_remove(moonbit_bytes_t path) {
  const char *path_str = (const char *)path;
  int32_t path_len = Moonbit_array_length(path);

  if (!path_str || path_len <= 0) {
    return FS_ERR_IO;
  }

#if PLATFORM_WINDOWS
  int wide_len = MultiByteToWideChar(CP_UTF8, 0, path_str, -1, NULL, 0);
  if (wide_len <= 0) {
    return FS_ERR_IO;
  }
  wchar_t *wide_path = (wchar_t *)malloc((wide_len + 1) * sizeof(wchar_t));
  if (!wide_path) {
    return FS_ERR_NOMEM;
  }
  MultiByteToWideChar(CP_UTF8, 0, path_str, -1, wide_path, wide_len);
  wide_path[wide_len] = L'\0';

  BOOL ok = DeleteFileW(wide_path);
  free(wide_path);
  return ok ? FS_OK : FS_ERR_IO;
#else
  if (unlink(path_str) == 0) {
    return FS_OK;
  }
  return FS_ERR_IO;
#endif
}

// ---------------------------------------------------------------------------
// sleep_ms: 真实毫秒睡眠（轮询间隔真实等待，替代忙等待空转）
// ---------------------------------------------------------------------------
MOONBIT_FFI_EXPORT
void moonbit_sleep_ms(int32_t ms) {
#if PLATFORM_WINDOWS
  Sleep((DWORD)ms);
#else
  if (ms > 0) {
    usleep((useconds_t)ms * 1000);
  }
#endif
}