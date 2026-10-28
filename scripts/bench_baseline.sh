#!/usr/bin/env bash
# =============================================================================
# scripts/bench_baseline.sh — C4 性能基线固化（可重复执行，跨平台）
#
# 目的：给「关键路径」留下**可对比的墙钟基线**，后续改动前后各跑一次即可看回归。
#   * 每个用例先 warm（同一命令跑一次不计时）再计时，减少编译/缓存噪声；
#   * 统一包在 scripts/with_moon_lock.sh 里跑（多 lane 并行时也稳定）；
#   * 只测量既有测试文件/整包，不新增任何产品代码或测试代码；
#   * 输出 Markdown 表格（默认）+ `--json <path>` 机器可读。
#
# 覆盖（与 C4 任务 ② 对齐）：
#   pbkdf2/crypto   : test-suit/rhop_js/crypto_test.mbt（Fernet KDF=PBKDF2 200k 每次加/解密）
#   canonical 深嵌套 : test-suit/rhop/json_canonical_test.mbt（深 5000 / 20000）
#   envelope 往返    : test-suit/rhop/envelope_test.mbt
#   relay 收发       : test-suit/rhop_js/relay_test.mbt（js）
#   sqlite claim 并发 : test-suit/rhop_business（js，整包；含 claim/并发用例）
#   全量墙钟         : moon test / --target js / --target native（项目级）
#
# 用法：
#   bash scripts/bench_baseline.sh                 # 全部（约 2-4 分钟）
#   bash scripts/bench_baseline.sh --quick         # 跳过全量三目标
#   bash scripts/bench_baseline.sh --json out.json
#
# 退出码：0 全部步骤跑完（**不判绿**，性能基线不是门禁）；2 用法/环境错误。
# 注意：基线数字受机器负载影响；同一机器上「改动前/后」对比才有意义。
# =============================================================================
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
cd "$PROJECT_DIR" || { echo "FATAL: 无法进入项目目录" >&2; exit 2; }

QUICK=0
JSON_OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --quick) QUICK=1; shift ;;
    --json) JSON_OUT="${2:-}"; shift 2 || { echo "FATAL: --json 需要路径" >&2; exit 2; } ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "FATAL: 未知参数 $1" >&2; exit 2 ;;
  esac
done

# ---- 平台/工具链（与 test_all.sh 一致的最小 PATH） ----
detect_platform() {
  if [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then echo wsl; return; fi
  if [ -n "${MSYSTEM:-}" ]; then echo windows; return; fi
  case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*) echo windows ;;
    Linux*) echo linux ;;
    Darwin*) echo macos ;;
    *) echo unknown ;;
  esac
}
PLATFORM=$(detect_platform)
if [ "$PLATFORM" = "windows" ]; then
  NODE_DIR=""
  for d in "/c/Program Files/nodejs" "/c/Program Files (x86)/nodejs"; do
    [ -x "$d/node.exe" ] && { NODE_DIR="$d"; break; }
  done
  export PATH="${NODE_DIR:+$NODE_DIR:}${HOME:-${USERPROFILE:-}}/.moon/bin:/usr/bin:/bin"
elif [ "$PLATFORM" = "wsl" ]; then
  export PATH="${HOME:-/root}/.moon/bin:/usr/local/bin:/usr/bin:/bin"
fi

MOON_BIN=$(command -v moon || true)
[ -n "$MOON_BIN" ] || { echo "FATAL: 找不到 moon（PATH=$PATH）" >&2; exit 2; }

TARGET_ARGS=()
if [ "$PLATFORM" = "wsl" ]; then TARGET_ARGS=(--target-dir "$PROJECT_DIR/_build/wsl"); fi

MOON_LOCK="$PROJECT_DIR/scripts/with_moon_lock.sh"
run_moon() {  # run_moon <args...>
  if [ -f "$MOON_LOCK" ]; then
    bash "$MOON_LOCK" "$MOON_BIN" ${TARGET_ARGS[@]+"${TARGET_ARGS[@]}"} "$@"
  else
    "$MOON_BIN" ${TARGET_ARGS[@]+"${TARGET_ARGS[@]}"} "$@"
  fi
}

now_ms() { date +%s%3N 2>/dev/null || echo $(( $(date +%s) * 1000 )); }

ROWS=()   # name|target|cmd|ms|summary
measure() {  # measure <name> <target> <args...>
  local name="$1" target="$2"; shift 2
  printf '  · %-28s (%s) warm...' "$name" "$target"
  local out
  out=$(run_moon "$@" 2>&1) || true          # warm（不计时）
  local sum
  sum=$(printf '%s' "$out" | grep -oE "Total tests: [0-9]+, passed: [0-9]+, failed: [0-9]+" | tail -1)
  printf 'timed...'
  local t0 t1 rc attempt
  t0=$(now_ms)
  out=$(run_moon "$@" 2>&1); rc=$?
  # C4：并发构建窗口里 moon 偶发 `cannot find binary path`（rc=127）——这是瞬时环境污染，
  # 重试一次再判定，避免基线数字被这种瞬时空转污染。
  for attempt in 1 2; do
    if [ "$rc" -ne 127 ] && ! printf '%s' "$out" | grep -q "cannot find binary path"; then break; fi
    sleep 2
    out=$(run_moon "$@" 2>&1); rc=$?
  done
  t1=$(now_ms)
  sum=$(printf '%s' "$out" | grep -oE "Total tests: [0-9]+, passed: [0-9]+, failed: [0-9]+" | tail -1)
  echo " $((t1 - t0))ms"
  ROWS+=("${name}|${target}|${*}|$((t1 - t0))|${sum:-rc=$rc}")
}

echo "============================================================================="
echo " rx-mbt 性能基线  scripts/bench_baseline.sh"
echo "============================================================================="
printf ' platform   : %s\n' "$PLATFORM"
printf ' moon       : %s -> %s\n' "$MOON_BIN" "$("$MOON_BIN" version 2>&1 | head -1)"
printf ' node       : %s -> %s\n' "$(command -v node || echo '<none>')" "$(node --version 2>/dev/null || echo MISSING)"
printf ' build dir  : %s\n' "${TARGET_ARGS[1]:-<默认 _build>}"
printf ' machine    : %s / %s\n' "$(hostname 2>/dev/null || echo '?')" "$(date '+%Y-%m-%d %H:%M')"
echo "============================================================================="

echo ">>> 关键路径用例（每组先 warm 再计时）"
measure "pbkdf2/kdf (Fernet 200k)" js   test test-suit/rhop_js/crypto_test.mbt --target js
measure "canonical 深嵌套 5k/20k"  wasm test test-suit/rhop/json_canonical_test.mbt
measure "envelope 往返/校验"       wasm test test-suit/rhop/envelope_test.mbt
measure "relay 单次收发"           js   test test-suit/rhop_js/relay_test.mbt --target js
measure "sqlite claim 并发"        js   test -p test-suit/rhop_business --target js
measure "digest(含 pbkdf2 小轮)"   wasm test test-suit/rhop/digest_test.mbt

if [ "$QUICK" -eq 0 ]; then
  echo ">>> 全量墙钟（项目级三目标）"
  measure "全量 wasm"   wasm   test
  measure "全量 js"     js     test --target js
  measure "全量 native" native test --target native
fi

echo
echo "============================================================================="
echo " BASELINE（墙钟，含测试夹具开销；同机前后对比才有意义）"
echo "============================================================================="
printf ' %-28s %-7s %-10s %s\n' "CASE" "TARGET" "WALL(ms)" "SUMMARY"
for row in ${ROWS[@]+"${ROWS[@]}"}; do
  IFS='|' read -r n t c ms s <<< "$row"
  printf ' %-28s %-7s %-10s %s\n' "$n" "$t" "$ms" "$s"
done
echo "============================================================================="
echo " 说明：PBKDF2 200k 内嵌在 Fernet 加/解密中（每次操作一次 KDF），故用 crypto_test 墙钟作代理；"
echo "       canonical 5000 键场景当前无既有用例（只有深 5000/20000），见 C4 报告「基线缺口」。"
echo "============================================================================="

if [ -n "$JSON_OUT" ]; then
  {
    printf '{"platform":"%s","moon":"%s","node":"%s","machine":"%s","generated_at":"%s","rows":[' \
      "$PLATFORM" "$("$MOON_BIN" version 2>&1 | head -1)" "$(node --version 2>/dev/null || echo MISSING)" \
      "$(hostname 2>/dev/null || echo '?')" "$(date -Iseconds 2>/dev/null || date)"
    first=1
    for row in ${ROWS[@]+"${ROWS[@]}"}; do
      IFS='|' read -r n t c ms s <<< "$row"
      [ "$first" -eq 1 ] || printf ','
      first=0
      printf '{"case":"%s","target":"%s","cmd":"%s","wall_ms":%s,"summary":"%s"}' \
        "$n" "$t" "$(printf '%s' "$c" | sed 's/"/\\"/g')" "$ms" "${s//\"/}"
    done
    printf ']}\n'
  } > "$JSON_OUT"
  echo " JSON 已写入：$JSON_OUT"
fi
exit 0
