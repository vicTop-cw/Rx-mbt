// ============================================================================
// rhop_fs_native_stubs.c —— rhop 包 native 命令执行 FFI 实现
// 平台：Windows (MSVC cl.exe) / POSIX (gcc/clang)
// 编译：由 MoonBit 工具链通过 native-stub 自动编译
// ============================================================================

#include <moonbit.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

// ---------------------------------------------------------------------------
// 平台检测
// ---------------------------------------------------------------------------
#ifdef _WIN32
  #include <windows.h>
  #include <process.h>
  #define PLATFORM_WINDOWS 1
  #define PLATFORM_POSIX   0
#else
  #include <sys/wait.h>
  #include <unistd.h>
  #define PLATFORM_WINDOWS 0
  #define PLATFORM_POSIX   1
#endif

// ---------------------------------------------------------------------------
// 错误码约定
// ---------------------------------------------------------------------------
#define CMD_OK          0
#define CMD_ERR_SPAWN   1
#define CMD_ERR_TIMEOUT 2
#define CMD_ERR_READ    3

// ---------------------------------------------------------------------------
// 命令执行：运行外部程序，返回 (exit_code, stdout, stderr)
// ---------------------------------------------------------------------------
MOONBIT_FFI_EXPORT
moonbit_bytes_t moonbit_cmd_run(
    moonbit_bytes_t prog_bytes,
    moonbit_bytes_t args_bytes,
    int32_t args_count,
    int32_t timeout_ms
) {
  const char *prog = (const char *)prog_bytes;
  int32_t prog_len = Moonbit_array_length(prog_bytes);

  if (!prog || prog_len <= 0) {
    return moonbit_make_bytes(0, 0);
  }

  // 解析参数数组（FixedArray[Bytes] → moonbit_bytes_t*，元素连续，无对象头；
  // 长度由 MoonBit 侧显式传入，不可用 Moonbit_array_length 读取）
  
#if PLATFORM_WINDOWS
  // Windows 实现：使用 CreateProcess
  // 构建命令行
  char cmdline[4096] = {0};
  int pos = 0;
  
  // 添加程序名
  memcpy(cmdline + pos, prog, prog_len);
  pos += prog_len;
  
  // 添加参数
  for (int32_t i = 0; i < args_count; i++) {
    moonbit_bytes_t arg_bytes = ((moonbit_bytes_t *)args_bytes)[i];
    const char *arg = (const char *)arg_bytes;
    int32_t arg_len = Moonbit_array_length(arg_bytes);
    
    cmdline[pos++] = ' ';
    memcpy(cmdline + pos, arg, arg_len);
    pos += arg_len;
  }
  
  // 转换为宽字符
  int wide_len = MultiByteToWideChar(CP_UTF8, 0, cmdline, -1, NULL, 0);
  if (wide_len <= 0) {
    return moonbit_make_bytes(0, 0);
  }
  wchar_t *wide_cmdline = (wchar_t *)malloc(wide_len * sizeof(wchar_t));
  if (!wide_cmdline) {
    return moonbit_make_bytes(0, 0);
  }
  MultiByteToWideChar(CP_UTF8, 0, cmdline, -1, wide_cmdline, wide_len);
  
  // 创建进程
  STARTUPINFOW si = {0};
  PROCESS_INFORMATION pi = {0};
  si.cb = sizeof(si);
  
  HANDLE stdout_read = NULL, stdout_write = NULL;
  HANDLE stderr_read = NULL, stderr_write = NULL;
  
  // 创建管道
  SECURITY_ATTRIBUTES sa = {0};
  sa.bInheritHandle = TRUE;
  sa.lpSecurityDescriptor = NULL;
  
  CreatePipe(&stdout_read, &stdout_write, &sa, 0);
  CreatePipe(&stderr_read, &stderr_write, &sa, 0);
  SetHandleInformation(stdout_read, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(stderr_read, HANDLE_FLAG_INHERIT, 0);
  
  si.hStdOutput = stdout_write;
  si.hStdError = stderr_write;
  si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
  si.dwFlags = STARTF_USESTDHANDLES;
  
  BOOL ok = CreateProcessW(
      NULL,           // 应用程序名
      wide_cmdline,   // 命令行
      NULL,           // 进程安全属性
      NULL,           // 线程安全属性
      TRUE,           // 继承句柄
      0,              // 创建标志
      NULL,           // 环境变量
      NULL,           // 当前目录
      &si,            // STARTUPINFO
      &pi             // PROCESS_INFORMATION
  );

  free(wide_cmdline);
  CloseHandle(stdout_write);
  CloseHandle(stderr_write);
  
  if (!ok) {
    CloseHandle(stdout_read);
    CloseHandle(stderr_read);
    return moonbit_make_bytes(0, 0);
  }
  
  // 等待进程结束或超时
  DWORD exit_code = 0;
  DWORD wait_result = WaitForSingleObject(pi.hProcess, 
      timeout_ms < 0 ? INFINITE : (DWORD)timeout_ms);
  
  if (wait_result == WAIT_TIMEOUT) {
    TerminateProcess(pi.hProcess, 1);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    CloseHandle(stdout_read);
    CloseHandle(stderr_read);
    // 返回超时错误（7 字节哨兵 "timeout"，与 POSIX 分支一致）
    moonbit_bytes_t result = moonbit_make_bytes(7, 0);
    if (result) {
      memcpy(result, "timeout", 7);
    }
    return result;
  }
  
  GetExitCodeProcess(pi.hProcess, &exit_code);
  CloseHandle(pi.hProcess);
  CloseHandle(pi.hThread);
  
  // 读取输出
  char stdout_buf[65536] = {0};
  char stderr_buf[65536] = {0};
  DWORD stdout_len = 0, stderr_len = 0;
  
  ReadFile(stdout_read, stdout_buf, sizeof(stdout_buf) - 1, &stdout_len, NULL);
  ReadFile(stderr_read, stderr_buf, sizeof(stderr_buf) - 1, &stderr_len, NULL);
  CloseHandle(stdout_read);
  CloseHandle(stderr_read);
  
  // 构建返回结果：exit_code(4) + stdout_len(4) + stdout + stderr
  int total_len = 8 + stdout_len + stderr_len;
  moonbit_bytes_t result = moonbit_make_bytes(total_len, 0);
  if (!result) {
    return moonbit_make_bytes(0, 0);
  }

  // 写入 exit_code (4 bytes, 大端)
  result[0] = (exit_code >> 24) & 0xFF;
  result[1] = (exit_code >> 16) & 0xFF;
  result[2] = (exit_code >> 8) & 0xFF;
  result[3] = exit_code & 0xFF;

  // 写入 stdout_len (4 bytes, 大端)
  result[4] = (stdout_len >> 24) & 0xFF;
  result[5] = (stdout_len >> 16) & 0xFF;
  result[6] = (stdout_len >> 8) & 0xFF;
  result[7] = stdout_len & 0xFF;

  // 写入 stdout
  if (stdout_len > 0) {
    memcpy(result + 8, stdout_buf, stdout_len);
  }

  // 写入 stderr
  if (stderr_len > 0) {
    memcpy(result + 8 + stdout_len, stderr_buf, stderr_len);
  }

  return result;

#else
  // POSIX 实现：使用 fork/exec
  // 构建参数数组
  char **argv = (char **)malloc((args_count + 2) * sizeof(char *));
  if (!argv) {
    return moonbit_make_bytes(0, 0);
  }
  
  argv[0] = (char *)malloc(prog_len + 1);
  if (!argv[0]) {
    free(argv);
    return moonbit_make_bytes(0, 0);
  }
  memcpy(argv[0], prog, prog_len);
  argv[0][prog_len] = '\0';
  
  for (int32_t i = 0; i < args_count; i++) {
    moonbit_bytes_t arg_bytes = ((moonbit_bytes_t *)args_bytes)[i];
    const char *arg = (const char *)arg_bytes;
    int32_t arg_len = Moonbit_array_length(arg_bytes);
    
    argv[i + 1] = (char *)malloc(arg_len + 1);
    if (!argv[i + 1]) {
      for (int32_t j = 0; j <= i; j++) {
        free(argv[j]);
      }
      free(argv);
      return moonbit_make_bytes(0, 0);
    }
    memcpy(argv[i + 1], arg, arg_len);
    argv[i + 1][arg_len] = '\0';
  }
  argv[args_count + 1] = NULL;
  
  // 创建管道
  int stdout_pipe[2], stderr_pipe[2];
  if (pipe(stdout_pipe) < 0 || pipe(stderr_pipe) < 0) {
    for (int32_t i = 0; i <= args_count; i++) {
      free(argv[i]);
    }
    free(argv);
    return moonbit_make_bytes(0, 0);
  }
  
  // fork 进程
  pid_t pid = fork();
  if (pid < 0) {
    close(stdout_pipe[0]); close(stdout_pipe[1]);
    close(stderr_pipe[0]); close(stderr_pipe[1]);
    for (int32_t i = 0; i <= args_count; i++) {
      free(argv[i]);
    }
    free(argv);
    return moonbit_make_bytes(0, 0);
  }
  
  if (pid == 0) {
    // 子进程
    close(stdout_pipe[0]);
    close(stderr_pipe[0]);
    dup2(stdout_pipe[1], STDOUT_FILENO);
    dup2(stderr_pipe[1], STDERR_FILENO);
    close(stdout_pipe[1]);
    close(stderr_pipe[1]);
    
    execvp(argv[0], argv);
    _exit(1);
  }
  
  // 父进程
  close(stdout_pipe[1]);
  close(stderr_pipe[1]);
  
  for (int32_t i = 0; i <= args_count; i++) {
    free(argv[i]);
  }
  free(argv);
  
  // 等待进程结束或超时
  int status;
  pid_t wait_result;
  if (timeout_ms < 0) {
    wait_result = waitpid(pid, &status, 0);
  } else {
    // 非阻塞等待
    struct timespec ts = {0};
    ts.tv_sec = timeout_ms / 1000;
    ts.tv_nsec = (timeout_ms % 1000) * 1000000;
    
    // 简单实现：轮询等待
    int elapsed = 0;
    while (elapsed < timeout_ms) {
      wait_result = waitpid(pid, &status, WNOHANG);
      if (wait_result > 0) {
        break;
      }
      usleep(10000);  // 10ms
      elapsed += 10;
    }
    
    if (elapsed >= timeout_ms && wait_result == 0) {
      // 超时
      kill(pid, SIGKILL);
      waitpid(pid, &status, 0);
      close(stdout_pipe[0]);
      close(stderr_pipe[0]);
      // 返回超时错误
      moonbit_bytes_t result = moonbit_make_bytes(7, 0);
      if (result) {
        memcpy(result, "timeout", 7);
      }
      return result;
    }
  }
  
  // 读取输出
  char stdout_buf[65536] = {0};
  char stderr_buf[65536] = {0};
  int stdout_len = 0, stderr_len = 0;
  
  if (wait_result > 0) {
    stdout_len = read(stdout_pipe[0], stdout_buf, sizeof(stdout_buf) - 1);
    stderr_len = read(stderr_pipe[0], stderr_buf, sizeof(stderr_buf) - 1);
  }
  
  close(stdout_pipe[0]);
  close(stderr_pipe[0]);
  
  int exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
  
  // 构建返回结果：exit_code(4) + stdout_len(4) + stdout + stderr
  int out_len = stdout_len > 0 ? stdout_len : 0;
  int err_len = stderr_len > 0 ? stderr_len : 0;
  int total_len = 8 + out_len + err_len;
  moonbit_bytes_t result = moonbit_make_bytes(total_len, 0);
  if (!result) {
    return moonbit_make_bytes(0, 0);
  }

  // 写入 exit_code (4 bytes, 大端)
  result[0] = (exit_code >> 24) & 0xFF;
  result[1] = (exit_code >> 16) & 0xFF;
  result[2] = (exit_code >> 8) & 0xFF;
  result[3] = exit_code & 0xFF;

  // 写入 stdout_len (4 bytes, 大端)
  result[4] = (out_len >> 24) & 0xFF;
  result[5] = (out_len >> 16) & 0xFF;
  result[6] = (out_len >> 8) & 0xFF;
  result[7] = out_len & 0xFF;

  // 写入 stdout
  if (out_len > 0) {
    memcpy(result + 8, stdout_buf, out_len);
  }

  // 写入 stderr
  if (err_len > 0) {
    memcpy(result + 8 + out_len, stderr_buf, err_len);
  }

  return result;
#endif
}