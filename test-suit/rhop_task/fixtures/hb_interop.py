"""心跳文件跨实现互读 helper（C3 互操作证据）。

被 MoonBit 测试 test-suit/rhop_task/task_heartbeat_test.mbt 通过子进程调用，
用**真实 vools** 写入/读取 vools 格式的心跳文件，证明两平台两实现字节级互读。

用法：
    python hb_interop.py <dir> write     # 用 vools Heartbeat 写 <dir>/interop.heartbeat
    python hb_interop.py <dir> check     # 用 vools 读并判定，打印 JSON 结果

输出统一为单行 JSON（便于 MoonBit 侧解析）：
    {"ok": true, "action": "write", "content": "<写入的原文>", "path": "..."}
    {"ok": true, "action": "check", "state": "alive", "ts": "...", "worker_id": "...", "age_sec": 0.1}
    {"ok": false, "error": "<原因>"}
"""

import json
import sys


def _find_vools():
    """定位 vools 源码（Windows 与本机约定路径），失败返回 None。"""
    candidates = [
        "E:/IDEProjects/AI/vools/rhop",
        "/mnt/e/IDEProjects/AI/vools/rhop",
    ]
    for c in candidates:
        try:
            import os
            if os.path.isdir(os.path.join(c, "vools")):
                return c
        except Exception:
            continue
    return None


def main() -> int:
    if len(sys.argv) < 3:
        print(json.dumps({"ok": False, "error": "usage: hb_interop.py <dir> write|check"}))
        return 2
    target_dir = sys.argv[1]
    action = sys.argv[2]

    root = _find_vools()
    if root and root not in sys.path:
        sys.path.insert(0, root)
    try:
        # 真实 vools 实现
        from vools.rhop.task.heartbeat import Heartbeat  # type: ignore
    except Exception as exc:  # 环境缺 vools ⇒ 明确报不可用（测试侧软跳过）
        print(json.dumps({"ok": False, "error": "vools unavailable: %s" % exc}))
        return 3
    try:
        from vools.rhop.transport.local import LocalSharedPath  # type: ignore
    except Exception:
        LocalSharedPath = None

    try:
        if LocalSharedPath is not None:
            shared = LocalSharedPath(target_dir)
        else:
            # 老版本 vools 兜底：用 endpoint 视图
            from vools.rhop.transport.endpoint import LocalEndpoint  # type: ignore
            from vools.rhop.transport.shared import SharedPathView  # type: ignore
            shared = SharedPathView(LocalEndpoint(target_dir))
        hb = Heartbeat(
            shared=shared,
            filename="interop.heartbeat",
            interval_sec=5.0,
            stale_after_sec=600.0,
            closed_token="closed",
            worker_id="python-vools-worker",
            include_worker=True,   # 让文件内容为 `<ts> <worker>`，才能双向校验 worker 字段
        )

        if action == "write":
            result = hb.tick(force=True)
            raw = hb.read_raw()
            print(json.dumps({
                "ok": True,
                "action": "write",
                "content": raw,
                "path": result.get("path") if isinstance(result, dict) else None,
            }, ensure_ascii=False))
            return 0

        if action == "check":
            state = hb.read()
            print(json.dumps({
                "ok": True,
                "action": "check",
                "state": state.get("state"),
                "ts": state.get("ts"),
                "worker_id": state.get("worker_id"),
                "age_sec": state.get("age_sec"),
                "raw": state.get("raw"),
                "error": state.get("error"),
            }, ensure_ascii=False))
            return 0

        print(json.dumps({"ok": False, "error": "unknown action: %s" % action}))
        return 2
    except Exception as exc:
        print(json.dumps({"ok": False, "error": "%s: %s" % (type(exc).__name__, exc)}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
