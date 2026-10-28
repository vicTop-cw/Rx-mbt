#!/usr/bin/env bash
# =============================================================================
# scripts/check_determinism.sh — C4 ③ 生成物确定性自检（可重复执行）
#
# 检查三件事：
#   1) `gen_conformance_vectors.py` 连续两次生成的 **逐字节一致**（这是契约要求的幂等）；
#   2) 互操作生产者（`moon test test-suit/rhop_vectors --target js`）连续两次产物的
#      **字段级差异集合** —— Fernet 密文含随机 IV/时间戳，必然不同；除此之外必须完全一致；
#   3) 打印跨平台比对指引（Windows vs WSL 的产物的非 crypto 字段应逐字段相同）。
#
# 用法：
#   bash scripts/check_determinism.sh                 # 默认跑 2 轮
#   bash scripts/check_determinism.sh --runs 3        # 跑 3 轮
#   bash scripts/check_determinism.sh --skip-producer # 只查 gen 幂等
#
# 退出码：0 = gen 逐字节一致 且 生产者差异仅限 crypto 随机字段；
#         1 = 出现非预期差异；2 = 用法/环境错误。
# =============================================================================
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
cd "$PROJECT_DIR" || { echo "FATAL: 无法进入项目目录" >&2; exit 2; }

RUNS=2
SKIP_PRODUCER=0
while [ $# -gt 0 ]; do
  case "$1" in
    --runs) RUNS="${2:-}"; shift 2 || exit 2 ;;
    --skip-producer) SKIP_PRODUCER=1; shift ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "FATAL: 未知参数 $1" >&2; exit 2 ;;
  esac
done
case "$RUNS" in ''|*[!0-9]*) echo "FATAL: --runs 需正整数" >&2; exit 2 ;; esac

# 先捕获 python 绝对路径（后面的最小组 PATH 里可能没有 python）
PY=""
for _py in python python3 py; do
  if command -v "$_py" >/dev/null 2>&1; then PY=$(command -v "$_py"); break; fi
done

# PATH（与 test_all.sh 一致的最小组）
if [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
  PLATFORM=wsl
  export PATH="${HOME:-/root}/.moon/bin:/usr/local/bin:/usr/bin:/bin"
else
  PLATFORM=windows
  NODE_DIR=""
  for d in "/c/Program Files/nodejs" "/c/Program Files (x86)/nodejs"; do
    [ -x "$d/node.exe" ] && { NODE_DIR="$d"; break; }
  done
  export PATH="${NODE_DIR:+$NODE_DIR:}${HOME:-${USERPROFILE:-}}/.moon/bin:/usr/bin:/bin"
fi
# python 解释器（若上面没找到，再做一次兜底）
if [ -z "$PY" ]; then echo "FATAL: 找不到 python/python3" >&2; exit 2; fi

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t c4det)
trap 'rm -rf "$TMP"' EXIT
TARGET_ARGS=()
[ "$PLATFORM" = "wsl" ] && TARGET_ARGS=(--target-dir "$PROJECT_DIR/_build/wsl")
LOCK="$PROJECT_DIR/scripts/with_moon_lock.sh"
MOON=$(command -v moon || true)
[ -n "$MOON" ] || { echo "FATAL: 找不到 moon" >&2; exit 2; }

fail=0
echo "============================================================================="
echo " 生成物确定性自检  scripts/check_determinism.sh"
echo "============================================================================="
printf ' platform : %s\n python   : %s\n runs     : %s\n' "$PLATFORM" "$PY" "$RUNS"

# ---------------------------------------------------------------- 1) gen 幂等
echo
printf ">>> [1/2] gen_conformance_vectors.py 逐字节幂等（%s 轮）
" "$RUNS"
i=1
while [ "$i" -le "$RUNS" ]; do
  "$PY" scripts/gen_conformance_vectors.py --output "$TMP/gen_$i.json" --no-determinism-check >/dev/null 2>&1 || {
    echo "  ✗ gen run$i 执行失败"; fail=1; break; }
  i=$((i + 1))
done
first=$(sha256sum "$TMP/gen_1.json" 2>/dev/null | cut -d' ' -f1)
all_same=1
i=2
while [ "$i" -le "$RUNS" ]; do
  one=$(sha256sum "$TMP/gen_$i.json" 2>/dev/null | cut -d' ' -f1)
  [ "$one" = "$first" ] || all_same=0
  printf '  run%d sha=%s\n' "$i" "$one"
  i=$((i + 1))
done
printf '  run1 sha=%s\n' "$first"
if [ "$all_same" = 1 ]; then echo "  ✓ gen 产物逐字节一致（sha256 $first）"
else echo "  ✗ gen 产物不一致"; fail=1; fi

# ------------------------------------------------- 2) 生产者产物的字段级确定性
if [ "$SKIP_PRODUCER" = 0 ] && [ -n "$MOON" ]; then
  echo
  echo ">>> [2/2] 互操作生产者产物字段级确定性（crypto 随机 IV 之外必须一致）"
  i=1
  while [ "$i" -le "$RUNS" ]; do
    if [ -f "$LOCK" ]; then
      bash "$LOCK" "$MOON" ${TARGET_ARGS[@]+"${TARGET_ARGS[@]}"} test test-suit/rhop_vectors --target js >/dev/null 2>&1
    else
      "$MOON" ${TARGET_ARGS[@]+"${TARGET_ARGS[@]}"} test test-suit/rhop_vectors --target js >/dev/null 2>&1
    fi
    if [ ! -f fist-mbt/reports/moonbit_vectors_full.json ]; then
      echo "  ✗ 未找到生产者产物 fist-mbt/reports/moonbit_vectors_full.json"; fail=1; break
    fi
    cp fist-mbt/reports/moonbit_vectors_full.json "$TMP/prod_$i.json"
    i=$((i + 1))
  done
  if [ "$fail" = 0 ]; then
    "$PY" - "$TMP" "$RUNS" <<'PYEOF'
import json, io, sys, os
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass
tmp, runs = sys.argv[1], int(sys.argv[2])
def load(i): return json.load(io.open(os.path.join(tmp, "prod_%d.json" % i), encoding="utf-8"))
def walk(x, y, path=""):
    d = []
    if type(x) != type(y): return [(path, "type")]
    if isinstance(x, dict):
        for k in sorted(set(x) | set(y)): d += walk(x.get(k), y.get(k), path + "/" + str(k))
    elif isinstance(x, list):
        if len(x) != len(y): d.append((path, "len"))
        for i, (xi, yi) in enumerate(zip(x, y)): d += walk(xi, yi, path + "[%d]" % i)
    else:
        if x != y: d.append((path, "val"))
    return d
base = load(1)
bad = 0
for i in range(2, runs + 1):
    cur = load(i)
    d = walk(base, cur)
    non_crypto = [p for p, _ in d if "/crypto/" not in p]
    crypto = [p for p, _ in d if "/crypto/" in p]
    print("  run1 vs run%d: 差异 %d 个（crypto 随机字段 %d / 非 crypto %d）"
          % (i, len(d), len(crypto), len(non_crypto)))
    for p in non_crypto[:8]: print("    FAIL unexpected diff:", p)
    if non_crypto: bad = 1
print("  OK 除 crypto 随机 IV/时间戳外逐字段一致" if not bad else "  FAIL 存在非 crypto 差异")
sys.exit(1 if bad else 0)
PYEOF
    [ $? -ne 0 ] && fail=1
  fi
fi

echo
echo "============================================================================="
if [ "$fail" -eq 0 ]; then
  echo " RESULT: PASS —— gen 幂等；生产者仅 crypto 随机字段变化（预期）"
  echo " 跨平台复核：在 Windows 与 WSL 各跑一次本脚本，比较两次的 non-crypto 字段应为 0 差异。"
else
  echo " RESULT: FAIL —— 存在非预期差异（见上）"
fi
echo "============================================================================="
exit "$fail"
