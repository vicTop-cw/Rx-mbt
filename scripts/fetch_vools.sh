#!/bin/bash
# 拉取 vicTop-cw/vools 仓库结构，定位 Itor 相关 API
set -e
BASE="https://api.github.com/repos/vicTop-cw/vools"
echo "=== 默认分支 ==="
curl -s -m 20 "$BASE" | grep -E '"default_branch"' | head -2
BRANCH=$(curl -s -m 20 "$BASE" | grep '"default_branch"' | sed -E 's/.*"default_branch": "([^"]+)".*/\1/' | head -1)
echo "BRANCH=$BRANCH"
echo "=== 完整文件树 ==="
curl -s -m 30 "${BASE}/git/trees/${BRANCH}?recursive=1" > /tmp/vools_tree.json
grep -oE '"path": "[^"]+"' /tmp/vools_tree.json > /tmp/vools_paths.txt
wc -l /tmp/vools_paths.txt
echo "=== 含 itor/iter 的路径 ==="
grep -iE 'itor|iter' /tmp/vools_paths.txt || echo "(无)"
echo "=== 前 60 个路径 ==="
head -60 /tmp/vools_paths.txt
