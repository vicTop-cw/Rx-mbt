#!/usr/bin/env python3
"""RQ-4 双进程物料验证编排（rx-mbt 侧自包含）。

流程：
  1. 建临时 watch 目录
  2. 起 watch_server（native 可执行，订阅 monitor.watch_folder_native）
  3. 等就绪哨兵
  4. 另一进程（本脚本）造文件变更：create/modify/rename/delete/mkdir/rmdir
  5. kill server，读 results.jsonl 对拍

用法：
  python run_harness.py --server <watch_server.exe> [--keep]
退出码：0 = 对拍通过；1 = 失败。
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

# 期望事件（子集断言）：(event, path_suffix)
EXPECTED = [
    ("create", "a.txt"),
    ("modify", "a.txt"),
    ("delete", "a.txt"),   # rename a.txt -> b.txt 的离开侧
    ("create", "b.txt"),   # rename 的进入侧
    ("delete", "b.txt"),
    ("create", "sub"),
    ("delete", "sub"),
]


def log(msg):
    print(f"[harness] {msg}", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", required=True, help="watch_server.exe 路径")
    ap.add_argument("--skip-launch", action="store_true",
                    help="跳过启动（server 已由外部启动，如 bash Start-Process；"
                         "Python 子进程树内 MoonBit main 不执行的环境限制）")
    ap.add_argument("--watch-dir", default=None,
                    help="skip-launch 模式下 server 监听的目录（须与外部启动一致）")
    ap.add_argument("--keep", action="store_true", help="保留临时目录便于排查")
    args = ap.parse_args()

    server_exe = Path(args.server)
    if not server_exe.exists():
        log(f"server 不存在: {server_exe}")
        return 1

    if args.skip_launch:
        if not args.watch_dir:
            log("--skip-launch 需要 --watch-dir 指定 server 监听目录")
            return 1
        tmp = Path(args.watch_dir).parent
        watch_dir = Path(args.watch_dir)
        results = tmp / "results.jsonl"
        ready = tmp / ".ready"
        log(f"skip-launch：watch_dir={watch_dir}")
        proc = None
    else:
        tmp = Path(tempfile.mkdtemp(prefix="rx-harness-"))
        watch_dir = tmp / "watch"
        watch_dir.mkdir()
        results = tmp / "results.jsonl"
        ready = tmp / ".ready"
        log(f"临时目录: {tmp}")

        # 1) 起 server（cmd 脚本 start /MIN：新窗口启动；注意 Python 子进程树内
        #    MoonBit main 不执行，--skip-launch 配合外部 bash 启动更稳）
        cmd_file = Path(__file__).parent / "start_server.cmd"
        proc = subprocess.Popen(
            ["cmd", "/c", str(cmd_file), str(server_exe), str(tmp)]
        )
        log(f"start_server.cmd pid={proc.pid}")

    try:
        # 2) 等就绪哨兵
        deadline = time.time() + 15
        while time.time() < deadline:
            if ready.exists():
                log("server 就绪")
                break
            time.sleep(0.05)
        else:
            log("等待就绪哨兵超时")
            dbg_file = tmp / "server.dbg"
            if dbg_file.exists():
                log("server 调试日志：")
                for line in dbg_file.read_text(encoding="utf-8").splitlines():
                    log("  dbg| " + line)
            log(f"临时目录保留待查: {tmp}")
            return 1

        # 3) 造事件（每步 sleep 超过轮询间隔 100ms，保证每轮 diff 独立）
        def touch(step):
            (watch_dir / "a.txt").write_text("v1")
            log("create a.txt")
            time.sleep(0.3)

            (watch_dir / "a.txt").write_text("v2")
            log("modify a.txt")
            time.sleep(0.3)

            (watch_dir / "a.txt").rename(watch_dir / "b.txt")
            log("rename a.txt -> b.txt")
            time.sleep(0.3)

            (watch_dir / "b.txt").unlink()
            log("delete b.txt")
            time.sleep(0.3)

            (watch_dir / "sub").mkdir()
            log("mkdir sub")
            time.sleep(0.3)

            (watch_dir / "sub").rmdir()
            log("rmdir sub")
            time.sleep(0.5)

        touch("events")

        # 4) 等 server 收敛
        time.sleep(1.0)
    finally:
        # 5) 停 server（bat 已退出，server 是 Start-Process 的子进程，按名杀）
        os.system("taskkill /F /IM watch_server.exe")
        log("server 已停止")

    # 6) 对拍
    if not results.exists():
        log("results.jsonl 不存在")
        return 1

    events = []
    for line in results.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            log(f"坏行: {line}")

    log(f"共收到 {len(events)} 条事件")
    for ev in events:
        log(f"  {ev.get('event')} {ev.get('path')}")

    # 对拍（name 前缀匹配：容忍 Windows 8.3 短名，如 sub -> subxt）
    def name_match(actual, expected):
        return actual == expected or actual.startswith(expected)

    got_pairs = [
        (ev.get("event"), Path(ev.get("path", "")).name) for ev in events
    ]
    missing = [
        (e, p) for (e, p) in EXPECTED
        if not any(e == ge and name_match(gn, p) for (ge, gn) in got_pairs)
    ]

    if missing:
        log(f"对拍失败，缺失: {missing}")
        if not args.keep:
            shutil.rmtree(tmp, ignore_errors=True)
        return 1

    log("对拍通过：全部期望事件命中")
    if not args.keep:
        shutil.rmtree(tmp, ignore_errors=True)
    else:
        log(f"临时目录保留: {tmp}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
