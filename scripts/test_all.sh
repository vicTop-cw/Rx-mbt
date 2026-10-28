#!/usr/bin/env bash
# =============================================================================
# scripts/test_all.sh — rx-mbt 跨平台测试总入口（T0.6.1 / 契约 §4.2）
#
# 在 Windows(Git Bash) 与 WSL(Ubuntu-22.04) 上行为一致：自动判平台 → 修 PATH →
# 依次执行 moon check / moon test / moon test --target js / moon test --target native，
# 抓取每个目标的 `Total tests: N, passed: N, failed: 0` 汇总行并汇总判绿。
#
# 判绿纪律（契约 §0/§4.3）：
#   * `moon check`：退出码 0 且汇总里 `N errors` 为 0；
#   * 三个测试目标：退出码 0、汇总行存在、failed == 0、passed == total；
#   * 任一不满足 → 脚本 exit 1（不允许“看起来绿”）。
#
# 已知环境坑（脚本存在的理由）：
#   1) Windows：PATH 里 `...\.desktop-bin\node.cmd` 先于真 node ⇒ moon 用 cmd 批处理
#      spawn 长 JSON 参数被截断 → `failed to parse args`。必须把 `C:\Program Files\nodejs`
#      前置到 PATH。
#   2) WSL：PATH 里的 `/mnt/c/...` 会让 moon 选到 Windows 的 `node.cmd`
#      → `Exec format error`。必须净化 PATH 只留 Linux 侧目录（并且 /root/.moon/bin
#      默认不在 login PATH 里，moon 会 command not found）。
#
# 用法：
#   bash scripts/test_all.sh                 # 四步全跑
#   bash scripts/test_all.sh --skip=native   # 跳过指定步骤（逗号分隔）
#   bash scripts/test_all.sh --help
#
# 退出码（C2 审计 Q4/Q10 固化，两入口语义一致）：
#   0 = 全部判绿；1 = 有步骤真实失败；2 = 用法错误/环境缺失；
#   3 = 一步都没执行（--skip 全跳过，不能当 PASS）；4 = 构建锁等待超时（并发 moon，非产品红）。
#
# 跨平台构建目录隔离（C2 审计 Q12）：Windows 与 WSL 共用同一份 `_build/`，本脚本在 WSL 侧
# 自动加 `--target-dir <repo>/_build/wsl` 隔离；**请在 WSL 里用本脚本跑测试，不要裸跑 moon**
# （裸跑会写共享 `_build`，与 Windows 并发时会互相踩坏产物）。
# =============================================================================

set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
cd "$PROJECT_DIR" || { echo "FATAL: 无法进入项目目录 $PROJECT_DIR" >&2; exit 2; }

SKIP_LIST=""
QUIET=0
# C2 审计 Q2：默认允许挂死清理；需要人工保留现场可设 RX_MBT_NO_CLEANUP=1
NO_CLEANUP="${RX_MBT_NO_CLEANUP:-0}"
# C2 审计 Q5：失败现场保留策略（目录数 + 总量上限，两者都满足才停止裁剪）
RUNLOG_KEEP="${RX_MBT_RUNLOG_KEEP:-20}"
RUNLOG_MAXMB="${RX_MBT_RUNLOG_MAXMB:-50}"

usage() {
  sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  echo
  echo "可用步骤名：check wasm js native"
}

for arg in "$@"; do
  case "$arg" in
    --skip=*) SKIP_LIST="${arg#--skip=}" ;;
    --timeout=*) RX_MBT_STEP_TIMEOUT="${arg#--timeout=}" ;;
    --quiet|-q) QUIET=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "FATAL: 未知参数 $arg（用 --help 看用法）" >&2; exit 2 ;;
  esac
done

# ---- 参数校验（C1 审计 F4/F10）：非法值一律 usage error（rc=2），不得静默降级 ----
if [ -n "${RX_MBT_STEP_TIMEOUT:-}" ]; then
  case "$RX_MBT_STEP_TIMEOUT" in
    ''|*[!0-9]*) echo "FATAL: --timeout 需正整数（秒），收到「$RX_MBT_STEP_TIMEOUT」" >&2; exit 2 ;;
  esac
  if [ "$RX_MBT_STEP_TIMEOUT" -le 0 ]; then
    echo "FATAL: --timeout 必须 > 0（0 会关闭挂死保护，不允许）" >&2
    exit 2
  fi
fi
if [ -n "$SKIP_LIST" ]; then
  _valid_steps=" check wasm js native "
  for _tok in $(printf '%s' "$SKIP_LIST" | tr ',' ' '); do
    [ -z "$_tok" ] && continue
    case "$_valid_steps" in
      *" $_tok "*) : ;;
      *)
        echo "FATAL: --skip 含未知步骤名「$_tok」；可用：check/ wasm/ js/ native" >&2
        echo "       用法只支持等号形式：--skip=check,js（空格形式会被当成位置参数）" >&2
        exit 2
        ;;
    esac
  done
fi

is_skipped() {
  case ",$(echo "$SKIP_LIST" | tr -d ' ')," in
    *",$1,"*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# 平台探测：WSL_DISTRO_NAME / /proc/version / MSYSTEM / uname
# ---------------------------------------------------------------------------
detect_platform() {
  if [ -n "${WSL_DISTRO_NAME:-}" ]; then echo "wsl"; return; fi
  if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then echo "wsl"; return; fi
  if [ -n "${MSYSTEM:-}" ]; then echo "windows"; return; fi
  case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
    Darwin*)              echo "macos" ;;
    Linux*)               echo "linux" ;;
    *)                    echo "unknown" ;;
  esac
}

PLATFORM=$(detect_platform)

# C2 自测暴露：setup_path 会把 PATH 收敛成 node+moon+系统目录，之后 `command -v powershell`
# 必然失败 ⇒ cleanup_orphans 里的 `|| return 0` 变成静默 no-op。这里在改 PATH 之前先记下绝对路径。
PS_EXE=""
for _cand in "$(command -v powershell.exe 2>/dev/null || command -v powershell 2>/dev/null || true)"              "/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"; do
  if [ -n "$_cand" ] && [ -x "$_cand" ]; then PS_EXE="$_cand"; break; fi
done

# ---------------------------------------------------------------------------
# PATH 修复
# ---------------------------------------------------------------------------
PATH_NOTE=""
setup_path() {
  case "$PLATFORM" in
    windows)
      local node_dir=""
      local d
      for d in "/c/Program Files/nodejs" "/c/Program Files (x86)/nodejs"; do
        if [ -x "$d/node.exe" ]; then node_dir="$d"; break; fi
      done
      if [ -z "$node_dir" ]; then
        # 兜底：从现有 PATH 找一个非 .cmd 的 node（.cmd shim 会截断长 JSON 参数）
        local found
        found=$(command -v node 2>/dev/null || true)
        case "$found" in
          *.cmd|*.CMD) found="" ;;
        esac
        if [ -n "$found" ]; then node_dir=$(dirname "$found"); fi
      fi
      local moon_base="${HOME:-${USERPROFILE:-}}"
      local moon_dir="$moon_base/.moon/bin"
      if [ -n "$node_dir" ]; then
        export PATH="$node_dir:$moon_dir:/usr/bin:/bin"
        PATH_NOTE="已前置真 node 目录：$node_dir（规避 .desktop-bin/node.cmd 截断长 JSON 参数）"
      else
        export PATH="$moon_dir:/usr/bin:/bin"
        PATH_NOTE="未找到真 node.exe 目录，仅前置 moon；js 目标可能因 node.cmd 失败"
      fi
      ;;
    wsl)
      export PATH="${HOME:-${USERPROFILE:-}}/.moon/bin:/usr/local/bin:/usr/bin:/bin"
      PATH_NOTE="已净化 PATH，剔除所有 /mnt/c 路径（规避选到 Windows node.cmd 的 Exec format error）"
      ;;
    *)
      PATH_NOTE="非 Windows/WSL 平台，保持原 PATH"
      ;;
  esac
}
setup_path

# 超时守护：js/native 的测试二进制有可能挂死（实测 2026-10-27：test-suit/rhop_js
# 的 js 测试 node 进程无限循环，导致 gate 永远不返回）。这里给每步加硬超时。
TIMEOUT_SECS=${RX_MBT_STEP_TIMEOUT:-600}
HAVE_TIMEOUT=0
command -v timeout >/dev/null 2>&1 && HAVE_TIMEOUT=1

# 构建目录隔离：Windows 与 WSL **共用同一个 _build/**（都挂在 /mnt/e 上），
# 并发跑两平台会互相踩坏产物（实测：`Sys_error (... .mi: No such file or directory)`、
# native 目标同一份 _build/native 里混放 MSVC 与 gcc 产物）。
# 因此 WSL 侧改用 `_build/wsl`（仍在 .gitignore 的 `_build/` 之内），Windows 侧保持默认。
TARGET_DIR=${RX_MBT_TARGET_DIR:-}
case "$PLATFORM" in
  wsl) [ -n "$TARGET_DIR" ] || TARGET_DIR="$PROJECT_DIR/_build/wsl" ;;
esac
TARGET_ARGS=()
[ -n "$TARGET_DIR" ] && TARGET_ARGS=(--target-dir "$TARGET_DIR")

# 环境信息（判绿证据的一部分：平台 / moon 版本 / node 路径）
# ---------------------------------------------------------------------------
MOON_BIN=$(command -v moon 2>/dev/null || true)
NODE_BIN=$(command -v node 2>/dev/null || true)

if [ -z "$MOON_BIN" ]; then
  echo "FATAL: 找不到 moon（PATH=$PATH）" >&2
  echo "  提示：Windows 需 ${HOME:-${USERPROFILE:-~}}/.moon/bin；WSL 需 /root/.moon/bin 存在并已前置" >&2
  exit 2
fi

MOON_VERSION=$(moon version 2>&1 | head -1)
NODE_VERSION=$([ -n "$NODE_BIN" ] && node --version 2>&1 || echo "MISSING")

echo "============================================================================="
echo " rx-mbt 跨平台测试总入口  scripts/test_all.sh"
echo "============================================================================="
printf ' platform   : %s (%s)\n' "$PLATFORM" "$(uname -s 2>/dev/null || echo unknown)"
printf ' project    : %s\n' "$PROJECT_DIR"
printf ' moon       : %s -> %s\n' "$MOON_BIN" "$MOON_VERSION"
printf ' node       : %s -> %s\n' "${NODE_BIN:-<none>}" "$NODE_VERSION"
printf ' PATH       : %s\n' "$PATH"
printf ' PATH 说明  : %s\n' "$PATH_NOTE"
printf ' 单步超时   : %ss（--timeout=秒 或 RX_MBT_STEP_TIMEOUT 可改）\n' "$TIMEOUT_SECS"
printf ' 构建目录   : %s\n' "${TARGET_DIR:-<默认 _build>}"
[ "$HAVE_TIMEOUT" -eq 1 ] || echo "WARN: 本机没有 timeout 命令，挂死的步骤不会被自动中断" >&2
[ -n "$SKIP_LIST" ] && printf ' 跳过步骤   : %s\n' "$SKIP_LIST"
echo "============================================================================="

case "$NODE_BIN" in
  *.cmd|*.CMD)
    echo "WARN: node 解析到 Windows 批处理 shim（$NODE_BIN）——js 目标很可能报 'failed to parse args'" >&2
    ;;
esac

if [ -z "$NODE_BIN" ]; then
  echo "WARN: PATH 里没有 node，js 目标将失败" >&2
fi

# ---------------------------------------------------------------------------
# 步骤执行与判绿
# ---------------------------------------------------------------------------
TMPDIR_RUN=$(mktemp -d 2>/dev/null || mktemp -d -t rxmbt)
trap 'rm -rf "$TMPDIR_RUN"' EXIT

SUMMARY_ROWS=()
OVERALL_RC=0

now_ms() { date +%s%3N 2>/dev/null || date +%s; }

# parse_summary <file> → 输出 "total passed failed lines"
parse_summary() {
  local f="$1" t=0 p=0 fl=0 n=0 a b c
  while read -r a b c; do
    t=$((t + a)); p=$((p + b)); fl=$((fl + c)); n=$((n + 1))
  done < <(sed -nE 's/.*Total tests: *([0-9]+), *passed: *([0-9]+), *failed: *([0-9]+).*/\1 \2 \3/p' "$f" 2>/dev/null)
  echo "$t $p $fl $n"
}

# parse_check <file> → 输出错误数（拿不到则输出空）
# 汇总行形如：Finished. moon: ran 11 tasks, now up to date (29 warnings, 0 errors)
# 注意别写 `.*\((N) errors\)`：括号后紧跟的是 "29 warnings"，必须只锚 "N errors)"。
parse_check() {
  local f="$1"
  grep -oE '[0-9]+ errors?[)]' "$f" 2>/dev/null | tail -1 | grep -oE '^[0-9]+'
}

# run_with_timeout <secs> <cmd...>：超时返回 124（TERM）/137（KILL 后）
run_with_timeout() {
  local secs="$1"; shift
  if [ "$HAVE_TIMEOUT" -eq 1 ]; then
    timeout -k 15 "${secs}s" "$@"
    return $?
  fi
  "$@"
}

# 挂死清理（尽力而为）：杀掉本轮 spawn 出来的测试二进制
#
# C2 审计 Q1/Q2（P1）修法：
#   1) pattern 必须同时兼容两种路径分隔符与两种构建根：Windows 反斜杠形态
#      `E:\...\_build\js\debug\test\...`、WSL 隔离后的 `/…/_build/wsl/js/debug/test/…`；
#   2) pattern 必须**限定在本仓库**（含仓库目录名），绝不使用 `_build` 这种宽泛串
#      —— 实测 `_build` 会命中 FIST-Mbt 的 cli.js serve 与其它项目/其它 lane 的进程，
#      一旦 wasm/check 超时就会连 MCP server 一起 Stop-Process（误杀）。
#   3) check/wasm 步骤不再做兜底清理：那两步的挂死对象是 moon 本身，而 moon 的 cmdline
#      不含仓库路径，无法安全定位；宁可不杀也不误杀（打印提示）。
REPO_TOKEN=$(basename "$PROJECT_DIR")
# pattern 里用 `.` 表示「任意单个分隔符」：同时命中 Windows 的 `\` 与 POSIX 的 `/`，
# 免去 `[\\/]` 这种在 bash/PS/pkill 三层转义下极易写坏的写法（C2 实测：写坏后会恒 0 命中）。
CLEAN_PAT_JS="${REPO_TOKEN}._build.(wsl.)?js.debug.test"
CLEAN_PAT_NATIVE="${REPO_TOKEN}._build.(wsl.)?native"

cleanup_orphans() {
  local pattern="$1"
  local what="$2"
  if [ "$NO_CLEANUP" = "1" ]; then
    echo "    (cleanup: 已按 RX_MBT_NO_CLEANUP=1 跳过；pattern=$pattern)"
    return 0
  fi
  case "$PLATFORM" in
    windows)
      if [ -z "$PS_EXE" ]; then
        echo "    (cleanup: 找不到 powershell，无法清理残留进程；请手工检查 node/moon；pattern=$pattern)"
        return 0
      fi
      # 这里必须用 -match（正则）而不是 -like（通配符）：pattern 是正则形态。
      # 另：PS 5.1 的 Get-Process 没有 CommandLine 属性，必须走 CIM 取命令行。
      # 只杀 node.exe / moon.exe，且要求命令行命中本仓库 pattern（双重收窄）。
      local killed
      killed=$("$PS_EXE" -NoProfile -Command \
        "\$pat='${pattern}'; \$n=0; Get-CimInstance Win32_Process -Filter \"Name='node.exe' or Name='moon.exe'\" | Where-Object { \$_.CommandLine -match \$pat } | ForEach-Object { \$n++; Stop-Process -Id \$_.ProcessID -Force -ErrorAction SilentlyContinue }; \$n" \
        2>/dev/null | tr -d '\r' | tail -1)
      case "$killed" in ''|*[!0-9]*) killed=0 ;; esac
      if [ "$killed" -gt 0 ]; then
        echo "    (cleanup: 已清理 $killed 个残留进程（$what），pattern=$pattern)"
      else
        echo "    (cleanup: 0 命中（$what）——若无残留属正常；若确有挂死进程说明路径形态变了，pattern=$pattern)"
      fi
      ;;
    wsl|linux)
      if ! command -v pkill >/dev/null 2>&1; then
        echo "    (cleanup: 本机无 pkill，跳过；pattern=$pattern)"
        return 0
      fi
      local hits
      hits=$(pgrep -fc -- "$pattern" 2>/dev/null || true)
      case "$hits" in ''|*[!0-9]*) hits=0 ;; esac
      if [ "$hits" -gt 0 ]; then
        pkill -f -- "$pattern" >/dev/null 2>&1 || true
        echo "    (cleanup: 已清理 $hits 个残留进程（$what），pattern=$pattern)"
      else
        echo "    (cleanup: 0 命中（$what）；pattern=$pattern)"
      fi
      ;;
  esac
}

# ---- 并发纪律（lead 2026-10-28 裁示）：多个 lane 并行修，moon 并发会污染共享 _build
# （实测：Out of memory / "Package rx not found" / "written 未绑定"）。仓库里若已有
# scripts/with_moon_lock.sh，则本脚本的所有 moon 调用自动套锁（mkdir 锁 + 陈旧锁回收）。
MOON_LOCK_SH="$PROJECT_DIR/scripts/with_moon_lock.sh"
MOON_CMD=("$MOON_BIN")
if [ -f "$MOON_LOCK_SH" ]; then
  MOON_CMD=(bash "$MOON_LOCK_SH" "$MOON_BIN")
fi

# run_step <step-name> <label> <moon args...>
run_step() {
  local step="$1"; shift
  local label="$1"; shift
  local outfile="$TMPDIR_RUN/$step.log"

  if is_skipped "$step"; then
    printf '\n>>> [%s] SKIP（--skip 指定）\n' "$step"
    SUMMARY_ROWS+=("$step|SKIP|-- 按 --skip 跳过 --|0")
    return 0
  fi

  printf '\n>>> [%s] %s\n' "$step" "$label"
  printf '    $ moon %s   (单步超时 %ss)\n' "$*" "$TIMEOUT_SECS"
  local t0 t1 rc
  t0=$(now_ms)
  if [ "$QUIET" -eq 1 ]; then
    # --quiet：整段输出落盘，只回显末尾 40 行（MCP run_check 这类调用方更省时；
    # 汇总行仍从完整日志里解析，判绿不受影响）
    run_with_timeout "$TIMEOUT_SECS" ${MOON_CMD[@]+"${MOON_CMD[@]}"} ${TARGET_ARGS[@]+"${TARGET_ARGS[@]}"} "$@" > "$outfile" 2>&1
    rc=$?
    tail -n 40 "$outfile"
  else
    run_with_timeout "$TIMEOUT_SECS" ${MOON_CMD[@]+"${MOON_CMD[@]}"} ${TARGET_ARGS[@]+"${TARGET_ARGS[@]}"} "$@" 2>&1 | tee "$outfile"
    rc=${PIPESTATUS[0]}
  fi
  t1=$(now_ms)

  local timed_out=0
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    timed_out=1
    echo "    !! 步骤超时（${TIMEOUT_SECS}s 未返回）——大概率是测试二进制挂死，正在清理残留进程" >&2
    case "$step" in
      js)     cleanup_orphans "$CLEAN_PAT_JS" "js 测试二进制" ;;
      native) cleanup_orphans "$CLEAN_PAT_NATIVE" "native 测试二进制" ;;
      *)
        echo "    (cleanup: $step 步骤不做兜底清理——挂死对象是 moon 本身，其 cmdline 不含仓库路径，"
        echo "     按 pattern 杀会误伤其它 lane 的 moon；请人工确认 \`ps\` 后处理)" >&2
        ;;
    esac
  fi

  local verdict detail
  if [ "$timed_out" -eq 1 ]; then
    verdict="FAIL"
    detail="步骤超时 ${TIMEOUT_SECS}s（测试可能挂死；可用 RX_MBT_STEP_TIMEOUT=秒 调整）"
  elif [ "$rc" -eq 75 ]; then
    # C2 审计 Q4：锁等待超时不是产品红，必须有可区分的文案
    verdict="LOCK-TIMEOUT"
    detail="构建锁等待超时（有并发 moon 正在跑；非编译/测试失败，请重试或调 MOON_LOCK_TIMEOUT）"
  elif [ "$step" = "check" ]; then
    local errs
    errs=$(parse_check "$outfile")
    if [ "$rc" -ne 0 ]; then
      verdict="FAIL"; detail="moon check 退出码 $rc"
    elif [ -z "$errs" ]; then
      verdict="PASS"; detail="退出码 0（未解析到 'N errors' 行）"
    elif [ "$errs" -ne 0 ]; then
      verdict="FAIL"; detail="$errs errors"
    else
      verdict="PASS"; detail="0 errors"
    fi
  else
    local t p fl n
    read -r t p fl n <<< "$(parse_summary "$outfile")" || true
    t=${t:-0}; p=${p:-0}; fl=${fl:-0}; n=${n:-0}
    if [ "$rc" -ne 0 ]; then
      verdict="FAIL"; detail="退出码 $rc"
    elif [ "${n:-0}" -eq 0 ]; then
      verdict="FAIL"; detail="缺少 'Total tests: N, passed: N, failed: 0' 汇总行"
    elif [ "$fl" -ne 0 ]; then
      verdict="FAIL"; detail="Total tests: $t, passed: $p, failed: $fl"
    elif [ "$p" -ne "$t" ]; then
      verdict="FAIL"; detail="passed($p) != total($t)"
    else
      verdict="PASS"; detail="Total tests: $t, passed: $p, failed: 0"
    fi
  fi

  printf '    --> %s  %s  (%s ms)\n' "$verdict" "$detail" "$((t1 - t0))"
  SUMMARY_ROWS+=("$step|$verdict|$detail|$((t1 - t0))")
  # 退出码语义（C2 审计 Q4/Q10 固化；两入口一致）：
  #   0=PASS  1=真实 FAIL  2=用法/环境错误  3=一步都没执行（全 skip）  4=构建锁等待超时
  if [ "$verdict" = "LOCK-TIMEOUT" ]; then
    [ "$OVERALL_RC" -eq 1 ] || OVERALL_RC=4
  elif [ "$verdict" != "PASS" ]; then
    OVERALL_RC=1
  fi
  return 0
}

run_step "check"  "moon check（wasm 默认目标，0 error 判据）"            check
run_step "wasm"   "moon test（wasm，默认目标）"                          test
run_step "js"     "moon test --target js"                               test --target js
run_step "native" "moon test --target native"                           test --target native

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
echo
echo "============================================================================="
echo " SUMMARY  (platform=$PLATFORM, moon=$MOON_VERSION, node=${NODE_BIN:-<none>})"
echo "============================================================================="
printf ' %-8s %-6s %-46s %8s\n' "STEP" "VERDICT" "DETAIL" "MS"
EXECUTED_STEPS=0
for row in ${SUMMARY_ROWS[@]+"${SUMMARY_ROWS[@]}"}; do
  IFS='|' read -r s v d ms <<< "$row"
  s=${s:-?}; v=${v:-?}; d=${d:-}; ms=${ms:-0}
  [ "$v" = "SKIP" ] || EXECUTED_STEPS=$((EXECUTED_STEPS + 1))
  printf ' %-8s %-6s %-46s %8s\n' "$s" "$v" "$d" "$ms"
done
echo "-----------------------------------------------------------------------------"
if [ "$EXECUTED_STEPS" -eq 0 ]; then
  echo " RESULT: SKIP —— 没有任何步骤被执行（--skip 全跳过），以下结论不构成判绿"
  OVERALL_RC=3
elif [ "$OVERALL_RC" -eq 4 ]; then
  echo " RESULT: LOCK-TIMEOUT —— 有步骤因构建锁等待超时而未执行（并发 moon 抢锁；非产品红）"
elif [ "$OVERALL_RC" -eq 0 ]; then
  echo " RESULT: PASS —— 所有已执行步骤判绿（$EXECUTED_STEPS 步）"
else
  echo " RESULT: FAIL —— 见上表 FAIL 行"
fi
echo "============================================================================="

# ---- C2 审计 Q5：失败现场保留 + 保留策略（防无界增长） ----
# 每次失败新建一个时间戳目录；同时按「保留最近 N 个 + 总量上限 MB」裁剪旧目录。
prune_run_logs() {
  local base="$1"
  [ -d "$base" ] || return 0
  local keep="${RUNLOG_KEEP:-20}" maxmb="${RUNLOG_MAXMB:-50}"
  case "$keep" in ''|*[!0-9]*) keep=20 ;; esac
  case "$maxmb" in ''|*[!0-9]*) maxmb=50 ;; esac
  # 1) 目录数上限
  local dirs
  dirs=$(ls -1d "$base"/*/ 2>/dev/null | wc -l | tr -d ' ')
  case "$dirs" in ''|*[!0-9]*) dirs=0 ;; esac
  if [ "$dirs" -gt "$keep" ]; then
    local del=$((dirs - keep))
    ls -1dt "$base"/*/ 2>/dev/null | tail -n "$del" | while read -r d; do
      rm -rf -- "$d" 2>/dev/null || true
    done
    echo " (run-logs 裁剪：目录数 $dirs > $keep，已删最旧 $del 个)"
  fi
  # 2) 总量上限（KB → MB 比较）
  local kb
  kb=$(du -sk "$base" 2>/dev/null | awk '{print $1}')
  case "$kb" in ''|*[!0-9]*) kb=0 ;; esac
  local maxkb=$((maxmb * 1024))
  if [ "$kb" -gt "$maxkb" ]; then
    ls -1dt "$base"/*/ 2>/dev/null | tail -n +2 | while read -r d; do
      cur=$(du -sk "$base" 2>/dev/null | awk '{print $1}')
      case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
      [ "$cur" -le "$maxkb" ] && break
      rm -rf -- "$d" 2>/dev/null || true
    done
    echo " (run-logs 裁剪：总量曾超 ${maxmb}MB，已按最旧优先删除直到达标)"
  fi
}

if [ "$OVERALL_RC" -ne 0 ] && [ -d "$TMPDIR_RUN" ]; then
  _LOGDIR="$PROJECT_DIR/fist-mbt/reports/run-logs/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$_LOGDIR" 2>/dev/null || true
  cp "$TMPDIR_RUN"/*.log "$_LOGDIR"/ 2>/dev/null || true
  echo " 失败日志已保留：$_LOGDIR（保留策略：最近 ${RUNLOG_KEEP} 个目录 / 上限 ${RUNLOG_MAXMB}MB）"
  prune_run_logs "$PROJECT_DIR/fist-mbt/reports/run-logs"
fi

exit "$OVERALL_RC"
