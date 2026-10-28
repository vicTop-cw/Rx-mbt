#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""scripts/gen_conformance_vectors.py -- 用真实 Python vools-rhop 生成跨实现一致性向量

产物：``test-suit/rhop_js/fixtures/vools_vectors.json``

设计原则
--------
1. **不手写伪造**：每个期望值都由真实 ``vools.rhop`` 代码算出来（Envelope /
   RhopCrypto / FileHashSigner / hashlib / json.dumps），脚本只做「采集 + 排版」。
2. **可重复生成**：Fernet 的 token 里含随机 IV 与当前时间戳，直接生成每次都不一样。
   本脚本在生成窗口内固定 ``os.urandom``（确定性 IV 序列）与 ``time.time``
   （固定 ts），因此同一份 vools 源码在 Windows / WSL / 任何机器上产出**逐字节相同**
   的 fixture；默认还会自校验「连续生成两次结果一致」，不成立就报错退出。
3. **不静默跳过**：缺 vools、缺 cryptography、导入到别处的 vools，一律清晰报错退出；
   ``--skip-crypto`` 是显式降级开关（会在 fixture 里留下 ``skipped_reason``）。

用法
----
    python scripts/gen_conformance_vectors.py                # 生成并自校验幂等
    python scripts/gen_conformance_vectors.py --print-sha256  # 只打印产物指纹
    python scripts/gen_conformance_vectors.py --verify <moonbit_output.json>
                                                             # 反向校验 MoonBit 产物

退出码：0 成功；2 用法错误；3 环境缺失（vools / cryptography）；4 幂等自检失败。
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
import sys
import warnings

# 让输出在 Windows(cp936 控制台) / WSL(UTF-8) 上都能正确显示中文
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")
    except (AttributeError, ValueError):
        pass

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_OUT = os.path.join(REPO_ROOT, "test-suit", "rhop_js", "fixtures", "vools_vectors.json")
SCHEMA = "rhop-conformance-vectors"
SCHEMA_VERSION = 1
RHOP_KEY = "rhop-test-key-2026"
FIXED_TS = 1793000000  # 2026-10-26T04:53:20Z，仅用于让 Fernet token 可复现
IV_SEED = "rx-mbt-iv"

VOOLS_CANDIDATES = [
    os.path.join(os.path.dirname(REPO_ROOT), "vools", "rhop"),
    "E:/IDEProjects/AI/vools/rhop",
    "/mnt/e/IDEProjects/AI/vools/rhop",
    os.path.join(REPO_ROOT, "..", "vools", "rhop"),
]


class GenError(Exception):
    """环境/前置条件类错误（退出码 3）。"""


# ---------------------------------------------------------------------------
# 环境探测：vools-rhop 源码位置 + 导入
# ---------------------------------------------------------------------------
def locate_vools_root(explicit=None):
    cands = []
    if explicit:
        cands.append(explicit)
    if os.environ.get("VOOLS_RHOP_ROOT"):
        cands.append(os.environ["VOOLS_RHOP_ROOT"])
    cands.extend(VOOLS_CANDIDATES)
    for cand in cands:
        if not cand:
            continue
        root = os.path.abspath(cand)
        if os.path.isfile(os.path.join(root, "vools", "rhop", "envelope.py")):
            return root
    return None


def import_vools(root):
    """导入 vools.rhop.*，并确认导入的是 *这份源码* 而不是别处的安装副本。"""
    if root:
        sys.path.insert(0, root)
    try:
        from vools.rhop import core as rhop_core
        from vools.rhop import crypto as rhop_crypto
        from vools.rhop import envelope as rhop_envelope
        from vools.rhop import integrity as rhop_integrity
        from vools.rhop import signer as rhop_signer
    except Exception as exc:  # noqa: BLE001 - 需要把原始异常全文给用户
        raise GenError(
            "无法导入 vools.rhop：%s: %s\n"
            "  请确认 vools 源码路径（--vools-root / $VOOLS_RHOP_ROOT），"
            "其下应有 vools/rhop/envelope.py；\n"
            "  若缺的是 vools 主包，把 E:/IDEProjects/AI/vools 也加进 PYTHONPATH "
            "（vools 是 namespace package，需要 vools.core.dataclass_compat）。"
            % (type(exc).__name__, exc)
        )

    origin = os.path.abspath(rhop_envelope.__file__)
    if root:
        expected_dir = os.path.join(os.path.abspath(root), "vools", "rhop")
        if not origin.startswith(expected_dir + os.sep):
            raise GenError(
                "导入到的 vools.rhop 不是指定源码：\n  got      = %s\n  expected = %s%s"
                % (origin, expected_dir, os.sep)
            )

    class Bundle(object):
        pass

    bundle = Bundle()
    bundle.core = rhop_core
    bundle.crypto = rhop_crypto
    bundle.envelope = rhop_envelope
    bundle.integrity = rhop_integrity
    bundle.signer = rhop_signer
    bundle.origin = origin
    bundle.root = os.path.abspath(root) if root else os.path.dirname(os.path.dirname(origin))
    return bundle


def read_vools_version(root):
    """从 pyproject.toml 抓版本（拿不到就返回 ''，不猜）。"""
    path = os.path.join(root, "pyproject.toml")
    if not os.path.isfile(path):
        return ""
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line.startswith("version") and "=" in line:
                    return line.split("=", 1)[1].strip().strip('"').strip("'")
    except OSError:
        return ""
    return ""


# ---------------------------------------------------------------------------
# 确定性 Fernet：固定 os.urandom / time.time（仅生成窗口内）
# ---------------------------------------------------------------------------
class DeterministicFernet(object):
    """把 fernet 内部用到的 os.urandom / time.time 换成确定值，退出时严格还原。"""

    def __init__(self, fixed_ts=FIXED_TS):
        self.fixed_ts = fixed_ts
        self._real_urandom = None
        self._real_time = None
        self._fernet_mod = None
        self._calls = 0

    def _fake_urandom(self, n):
        self._calls += 1
        seed = ("%s:%d:%d" % (IV_SEED, self._calls, n)).encode("utf-8")
        digest = hashlib.sha256(seed).digest()
        return (digest * (n // len(digest) + 1))[:n]

    def __enter__(self):
        try:
            import cryptography.fernet as fernet_mod
        except ImportError as exc:
            raise GenError(
                "cryptography 不可用（%s）：Fernet 向量无法生成。\n"
                "  Windows: pip install cryptography；或改在 WSL 里跑（python3 + cryptography 已装）。"
                % exc
            )
        self._fernet_mod = fernet_mod
        # fernet 模块里 `import os` / `import time` 拿到的是模块对象本身，
        # 因此这里改的是 os.urandom / time.time 本身；finally 里无条件还原。
        self._real_urandom = os.urandom
        self._real_time = __import__("time").time
        os.urandom = self._fake_urandom
        __import__("time").time = lambda: self.fixed_ts
        return self

    def __exit__(self, exc_type, exc, tb):
        if self._real_urandom is not None:
            os.urandom = self._real_urandom
        if self._real_time is not None:
            __import__("time").time = self._real_time
        return False


# ---------------------------------------------------------------------------
# 工具
# ---------------------------------------------------------------------------
def canonical_json_text(value):
    """与 envelope.py 完全一致的口径：ensure_ascii=False + sort_keys=True。"""
    return json.dumps(value, ensure_ascii=False, sort_keys=True)


def b64url(data):
    return base64.urlsafe_b64encode(data).decode("ascii")


def parse_fernet_token(ct_b64url):
    """把 encrypt_json 里的 ct（= base64url(Fernet token 文本字节)）拆开。"""
    try:
        token_bytes = base64.urlsafe_b64decode(ct_b64url + "=" * (-len(ct_b64url) % 4))
        # VText 对 Fernet token 文本字节又做了一次 base64url
        token_text = token_bytes.decode("ascii")
        raw = base64.urlsafe_b64decode(token_text + "=" * (-len(token_text) % 4))
    except Exception as exc:  # noqa: BLE001
        return {"parse_error": "%s: %s" % (type(exc).__name__, exc)}
    if len(raw) < 1 + 8 + 16 + 32:
        return {"parse_error": "token 太短: %d bytes" % len(raw)}
    return {
        "version_byte": raw[0],
        "timestamp": int.from_bytes(raw[1:9], "big"),
        "iv_hex": raw[9:25].hex(),
        "ciphertext_hex": raw[25:-32].hex(),
        "hmac_hex": raw[-32:].hex(),
        "note": "raw = 0x80 | ts_be8 | iv16 | aes128-cbc 密文 | hmac-sha256(32)",
    }


# ---------------------------------------------------------------------------
# 向量构建
# ---------------------------------------------------------------------------
CANONICAL_CASES = [
    ("empty_object", {}),
    ("empty_array", []),
    (
        "nested_unicode",
        {
            "task_id": "task-001",
            "中文键": "中文值",
            "嵌套": {"目标": "测试机", "重试": 2, "启用": True, "空值": None},
            "数组": [1, 2, 3, "四", {"五": 5}],
        },
    ),
    (
        "escapes",
        {
            "quote": 'he said "hi"',
            "backslash": "a\\b",
            "newline": "line1\nline2",
            "tab": "a\tb",
            "cr": "a\rb",
            "backspace": "a\bb",
            "formfeed": "a\fb",
            "ctrl_0x01": "\u0001",
            "slash": "a/b",
            "emoji": "🚀",
        },
    ),
    (
        "scalars",
        {"null": None, "true": True, "false": False, "int": 42, "negative": -7, "zero": 0},
    ),
    (
        "key_order",
        {"z": 1, "a": 2, "A": 3, "1": 4, "中文a": 5, "b": 6},
    ),
    (
        "deep_nest",
        {"L1": {"L2": {"L3": {"L4": [{"L5": "底"}]}}}},
    ),
]

DIGEST_CASES = [
    ("empty", ""),
    ("abc", "abc"),
    ("unicode", "中文校验"),
    ("long", "rhop" * 50),
    ("json", '{"a": 1, "b": "中文"}'),
]

HMAC_CASES = [
    ("short", "rhop-hmac-key", "hello rhop"),
    ("unicode", "密钥", "消息内容"),
]

PBKDF2_CASES = [
    # 迭代 1000 次：跨实现（含 MoonBit 纯实现）可接受的测试代价，非生产参数
    ("basic", "password-123", "salt-abc", 1000, 32),
]

SIGNER_CASES = [
    (
        "ascii_result",
        "task-001",
        {"status": "done", "rows": 3, "elapsed_ms": 12},
    ),
    (
        "unicode_result",
        "task-002",
        {"结论": "完成", "指标": [1, 2]},
    ),
    (
        "nested_result",
        "task-003",
        {"result": {"items": ["a", "b"], "ok": True}, "error": None},
    ),
]

CRYPTO_CASES = [
    ("simple_obj", {"k": "v", "n": 1}),
    (
        "unicode_nested",
        {"中文": "值", "列表": [1, 2, 3], "嵌套": {"a": None, "b": True}},
    ),
    ("plain_string_payload", "just-a-string"),
]

CRYPTO_SECRET_CASES = [
    ("password_ascii", "s3cr3t-p@ss"),
    ("token_unicode", "令牌-中文-🔑"),
]


def build_status_flow(v):
    """TaskStatus 流转表（Batch A 的 can_transition 判据）。"""
    statuses = ["pending", "claimed", "running", "done", "failed", "cancelled"]
    enum = v.core.TaskStatus
    table = {}
    for name in statuses:
        cur = enum(name)
        allowed = [other for other in statuses if cur.can_transition(enum(other))]
        table[name] = {"allowed": sorted(allowed), "is_terminal": bool(cur.is_terminal)}
    sides = v.core.Side
    return {
        "table": table,
        "side": {
            "requester": sides.REQUESTER.value,
            "executor": sides.EXECUTOR.value,
            "other_of_requester": sides.REQUESTER.other.value,
            "other_of_executor": sides.EXECUTOR.other.value,
        },
    }


def build_canonical_json_vectors():
    cases = []
    for name, value in CANONICAL_CASES:
        expected = canonical_json_text(value)
        cases.append(
            {
                "name": name,
                "input": value,
                "expected": expected,
                "expected_utf8_hex": expected.encode("utf-8").hex(),
            }
        )
    return cases


def build_digest_vectors():
    sha256_cases = []
    md5_cases = []
    for name, text in DIGEST_CASES:
        raw = text.encode("utf-8")
        sha256_cases.append(
            {
                "name": name,
                "input_utf8": text,
                "input_utf8_hex": raw.hex(),
                "hex": hashlib.sha256(raw).hexdigest(),
            }
        )
        md5_cases.append(
            {
                "name": name,
                "input_utf8": text,
                "input_utf8_hex": raw.hex(),
                "hex": hashlib.md5(raw).hexdigest(),
            }
        )
    hmac_cases = []
    for name, key, msg in HMAC_CASES:
        hmac_cases.append(
            {
                "name": name,
                "key_utf8": key,
                "message_utf8": msg,
                "hex": hmac.new(key.encode("utf-8"), msg.encode("utf-8"), hashlib.sha256).hexdigest(),
            }
        )
    pbkdf2_cases = []
    for name, password, salt, iterations, dk_len in PBKDF2_CASES:
        dk = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt.encode("utf-8"), iterations, dk_len)
        pbkdf2_cases.append(
            {
                "name": name,
                "password_utf8": password,
                "salt_utf8": salt,
                "iterations": iterations,
                "dk_len": dk_len,
                "hex": dk.hex(),
            }
        )
    return {
        "sha256": sha256_cases,
        "md5": md5_cases,
        "hmac_sha256": hmac_cases,
        "pbkdf2_hmac_sha256": pbkdf2_cases,
        "note": "sha256/md5 对 UTF-8 字节；pbkdf2 迭代 1000 次（测试口径，非生产参数）",
    }


def build_envelope_vectors(v):
    TaskStatus = v.core.TaskStatus
    Side = v.core.Side
    Envelope = v.envelope.Envelope

    cases = []

    env_min = Envelope(
        task_id="task-001",
        status=TaskStatus.PENDING,
        payload={
            "cmd": "jump.probe",
            "参数": {"目标": "测试机", "重试": 2},
            "ok": True,
            "空": None,
            "数组": [1, "二", {"三": 3}],
        },
        side=Side.REQUESTER,
        version=1,
        created_at="2026-10-27T11:00:00Z",
        updated_at="2026-10-27T11:00:00Z",
    )

    env_full = Envelope(
        task_id="task-002",
        status=TaskStatus.DONE,
        payload={"cmd": "echo", "文本": "中文载荷"},
        result={"结论": "完成", "指标": [1, 2, 3], "ok": True},
        error=None,
        side=Side.EXECUTOR,
        version=3,
        created_at="2026-10-27T11:00:00Z",
        updated_at="2026-10-27T12:30:00Z",
        hops_seen=["requester", "executor"],
        signature="sha256:deadbeef",
    )

    for name, env, extra in (("minimal_pending", env_min, {"v": 1}), ("full_done", env_full, {"v": 1})):
        raw = env.to_rhop_bytes()
        text = raw.decode("utf-8")
        # 反序列化自证：生成器内部先跑一遍 roundtrip
        restored = Envelope.from_rhop_bytes(raw)
        assert restored.checksum == env.checksum, "roundtrip checksum 不一致: %s" % name
        assert restored.to_dict() == env.to_dict(), "roundtrip 字段不一致: %s" % name
        checksum_preimage = canonical_json_text(
            {
                "v": 1,
                "task_id": env.task_id,
                "status": env.status.value,
                "payload": env.payload,
                "result": env.result,
                "error": env.error,
                "side": env.side.value,
                "version": env.version,
                "created_at": env.created_at,
                "updated_at": env.updated_at,
                "hops_seen": list(env.hops_seen),
                "signature": env.signature,
            }
        )
        ok, msg = v.integrity.IntegrityChecker.verify(env, raw)
        case = {
            "name": name,
            "fields": env.to_dict(),
            "checksum": env.checksum,
            "checksum_preimage_utf8": checksum_preimage,
            "checksum_preimage_sha256": hashlib.sha256(checksum_preimage.encode("utf-8")).hexdigest(),
            "to_rhop_bytes_utf8": text,
            "to_rhop_bytes_utf8_hex": raw.hex(),
            "to_rhop_bytes_sha256": hashlib.sha256(raw).hexdigest(),
            "integrity_verify": [ok, msg],
            "checksum_match": v.integrity.IntegrityChecker.checksum_match(env),
        }
        case.update(extra)
        cases.append(case)

    # 篡改用例：改 checksum 最后一个字符 → from_rhop_bytes 必须报 checksum mismatch
    raw_min = env_min.to_rhop_bytes()
    data = json.loads(raw_min.decode("utf-8"))
    data["checksum"] = data["checksum"][:-1] + ("0" if data["checksum"][-1] != "0" else "1")
    tampered = canonical_json_text(data).encode("utf-8")
    try:
        Envelope.from_rhop_bytes(tampered)
        tamper_error = None
    except ValueError as exc:
        tamper_error = str(exc)
    cases.append(
        {
            "name": "tampered_checksum",
            "base": "minimal_pending",
            "to_rhop_bytes_utf8_hex": tampered.hex(),
            "expect_error": True,
            "expect_error_contains": "checksum mismatch",
            "vools_actual_error": tamper_error,
        }
    )
    return cases


def build_crypto_vectors(v, skip_crypto=False):
    case_objs = []
    if skip_crypto:
        return {
            "skipped": True,
            "skipped_reason": "生成时显式传了 --skip-crypto（cryptography 不可用时的降级路径）",
        }

    try:
        import cryptography  # noqa: F401
        from cryptography.fernet import Fernet  # noqa: F401
    except ImportError as exc:
        raise GenError(
            "cryptography 不可用，无法生成 Fernet / RHOP-ENC 向量：%s\n"
            "  处理：pip install cryptography，或改在 WSL（python3 已带 cryptography）里跑：\n"
            "    wsl.exe -e bash -lc \"cd /mnt/e/IDEProjects/AI/rhop && python3 scripts/gen_conformance_vectors.py\"\n"
            "  如确需降级，显式加 --skip-crypto（fixture 里会写明 skipped_reason）。" % exc
        )

    crypt = v.crypto.RhopCrypto(RHOP_KEY)
    key_bytes = RHOP_KEY.encode("utf-8")
    salt = hashlib.sha256(key_bytes).digest()[:16]
    fk = base64.urlsafe_b64encode(
        hashlib.pbkdf2_hmac("sha256", key_bytes, salt, 200000, 32)
    )

    kdf = {
        "scheme": "PBKDF2-HMAC-SHA256",
        "salt_rule": "sha256(key_bytes)[:16]",
        "salt_hex": salt.hex(),
        "iterations": 200000,
        "dk_len": 32,
        "fk_b64url": fk.decode("ascii"),
        "note": "FK = base64url(PBKDF2-SHA256(key, salt=sha256(key)[:16], iterations=200000, dkLen=32))",
    }

    for name, payload in CRYPTO_CASES:
        ct_text = crypt.encrypt_json(payload)
        parsed = json.loads(ct_text)
        vr = crypt.decrypt_verify(ct_text)
        if not vr.ok:
            raise GenError("自检失败：vools 自己加密的 %s 解不回来，reason=%s" % (name, vr.reason))
        # 明文口径：dict 走 json.dumps；str 若本身是合法 JSON 文本则原样；否则 vools 包成 {"__text__": ...}
        if isinstance(payload, str):
            plaintext = payload if _is_json_text(payload) else json.dumps({"__text__": payload}, ensure_ascii=False)
        else:
            plaintext = json.dumps(payload, ensure_ascii=False)
        if not _payload_equal(vr.payload, json.loads(plaintext)):
            raise GenError("自检失败：%s 解密 payload 与明文口径不一致：%r" % (name, vr.payload))
        case_objs.append(
            {
                "name": name,
                "input": payload,
                # payload 记的是 decrypt_verify 的返回值（= MoonBit 侧应当解出来的载荷）
                "payload": vr.payload,
                "plaintext_utf8": plaintext,
                "ciphertext_json_text": ct_text,
                "v": parsed["v"],
                "alg": parsed["alg"],
                "ct": parsed["ct"],
                "ct_token_parts": parse_fernet_token(parsed["ct"]),
                "vools_decrypt": {"ok": vr.ok, "reason": vr.reason, "payload": vr.payload},
            }
        )

    secret_cases = []
    for name, plaintext in CRYPTO_SECRET_CASES:
        secret = crypt.encrypt_secret(plaintext)
        recovered = crypt.decrypt_secret(secret)
        if recovered != plaintext:
            raise GenError("自检失败：RHOP-ENC 往返不一致（%s）" % name)
        secret_cases.append(
            {
                "name": name,
                "plaintext_utf8": plaintext,
                "secret": secret,
                "secret_prefix": v.crypto.SECRET_PREFIX,
                "ct_token_parts": parse_fernet_token(secret[len(v.crypto.SECRET_PREFIX):]),
            }
        )

    negative_cases = [
        {"name": "not_json", "input": "definitely-not-json", "expect": {"ok": False, "reason": "MALFORMED"}},
        {
            "name": "json_but_not_object",
            "input": json.dumps([1, 2], ensure_ascii=False),
            "expect": {"ok": False, "reason": "MALFORMED"},
        },
        {
            "name": "wrong_version",
            "input": json.dumps({"v": 2, "alg": "fernet", "ct": "x"}, ensure_ascii=False),
            "expect": {"ok": False, "reason": "MALFORMED"},
        },
        {
            "name": "wrong_alg",
            "input": json.dumps({"v": 1, "alg": "xor", "ct": "x"}, ensure_ascii=False),
            "expect": {"ok": False, "reason": "MALFORMED"},
        },
        {
            "name": "empty_ct",
            "input": json.dumps({"v": 1, "alg": "fernet", "ct": ""}, ensure_ascii=False),
            "expect": {"ok": False, "reason": "MALFORMED"},
        },
        {
            "name": "garbage_ct",
            "input": json.dumps({"v": 1, "alg": "fernet", "ct": "AAAA"}, ensure_ascii=False),
            "expect": {"ok": False, "reason": "BAD_TOKEN"},
        },
        {
            "name": "wrong_key",
            "input": v.crypto.RhopCrypto("another-key-2026").encrypt_json({"k": "v"}),
            "encrypted_with_key": "another-key-2026",
            "expect": {"ok": False, "reason": "BAD_TOKEN"},
            "note": "密文由 another-key-2026 加密，用 fixture 的标准 key 解密必须失败",
        },
    ]
    checked_negative = []
    for case in negative_cases:
        # 一律用标准 key 解密：wrong_key 用例的密文是「别人加密的」，标准化密钥必须解不开
        with warnings.catch_warnings():
            # vools 在解密失败时会发 RuntimeWarning 并回退；负向用例里这是预期噪声
            warnings.simplefilter("ignore")
            got = crypt.decrypt_verify(case["input"])
        if got.ok or got.reason != case["expect"]["reason"]:
            raise GenError(
                "自检失败：负向用例 %s 期望 %s，实测 ok=%s reason=%s"
                % (case["name"], case["expect"]["reason"], got.ok, got.reason)
            )
        item = dict(case)
        item["vools_actual_reason"] = got.reason
        checked_negative.append(item)

    return {
        "skipped": False,
        "key": RHOP_KEY,
        "env_alg": v.crypto._ENV_ALG if hasattr(v.crypto, "_ENV_ALG") else "fernet",
        "env_version": v.crypto._ENV_VERSION if hasattr(v.crypto, "_ENV_VERSION") else 1,
        "secret_prefix": v.crypto.SECRET_PREFIX,
        "kdf": kdf,
        "deterministic": True,
        "fernet_ts": FIXED_TS,
        "iv_rule": "sha256('rx-mbt-iv:<第n次os.urandom调用>:<n字节>')[:n]（仅生成窗口内的确定性替身，Fernet 算法本身完全是真实实现）",
        "encrypt_json_cases": case_objs,
        "encrypt_secret_cases": secret_cases,
        "negative_cases": checked_negative,
    }


def _is_json_text(text):
    try:
        json.loads(text)
        return True
    except (ValueError, TypeError):
        return False


def _payload_equal(a, b):
    """JSON 语义相等（dict/list/str/int/bool/None 的严格结构比较）。"""
    try:
        return json.loads(json.dumps(a, ensure_ascii=False, sort_keys=True)) == json.loads(
            json.dumps(b, ensure_ascii=False, sort_keys=True)
        )
    except (TypeError, ValueError):
        return a == b


def build_signer_vectors(v):
    FileHashSigner = v.signer.FileHashSigner
    NPUSigner = v.signer.NPUSigner
    signer = FileHashSigner()
    cases = []
    for name, task_id, result in SIGNER_CASES:
        sig = signer.sign(task_id, result)
        # vools 的 FileHashSigner 用的是 json.dumps(默认 ensure_ascii=True, sort_keys=True)
        preimage = json.dumps({"task_id": task_id, "result": result}, sort_keys=True)
        cases.append(
            {
                "name": name,
                "task_id": task_id,
                "result": result,
                "preimage": preimage,
                "signature": sig,
                "verify_ok": signer.verify(task_id, result, sig),
                "preimage_ensure_ascii": True,
            }
        )

    npu = NPUSigner()
    npu_sig = npu.sign("task-npu-001", {"status": "done"})
    return {
        "file_hash": {
            "algo": "sha256",
            "format": "sha256:<hex>",
            "preimage_rule": "json.dumps({'task_id': ..., 'result': ...}, sort_keys=True) —— vools 原实现用默认 ensure_ascii=True（非 ASCII 会转义成 \\uXXXX），分隔符为 Python 默认 ', ' / ': '",
            "cases": cases,
        },
        "npu": {
            "marker": "NPU_MARKER",
            "sign": npu_sig,
            "expect_sign_is_null": npu_sig is None,
            "note": "NPUSigner.sign 在拿不到 npu-smi 序列号时返回 None（本机无 npu-smi 即 None）；签名格式 <marker>:<serial>:<md5>",
        },
    }


def build_moonbit_output_schema():
    """把 verify_interop.py 期望的输入契约写进 fixture，供 MoonBit 侧照抄。"""
    return {
        "description": "MoonBit 侧（test-suit/rhop_js, js 目标）把实际产出写成这个形状的 JSON，再交给 scripts/verify_interop.py 用 Python vools 逐项复核。未产出的分节可以整节省略或置为 null。",
        "top_level": {
            "schema": "rhop-moonbit-output",
            "schema_version": 1,
            "produced_by": "自由文本，例如 'moon test --target js (test-suit/rhop_js)'",
        },
        "sections": {
            "canonical_json": [{"name": "<与 fixture.canonical_json[i].name 对应>", "actual": "<canonical_json 的实际输出>"}],
            "digest": {
                "sha256": [{"name": "<fixture.digest.sha256[i].name>", "hex": "<sha256_hex_of_utf8>"}],
                "md5": [{"name": "<fixture.digest.md5[i].name>", "hex": "<md5_hex>"}],
                "hmac_sha256": [{"name": "<fixture.digest.hmac_sha256[i].name>", "hex": "<hex>"}],
                "pbkdf2_hmac_sha256": [{"name": "<fixture.digest.pbkdf2_hmac_sha256[i].name>", "hex": "<hex>"}],
            },
            "envelope": [
                {
                    "name": "<fixture.envelope[i].name>",
                    "to_rhop_bytes_utf8": "<Envelope::to_rhop_bytes 解出的 utf8 文本>",
                    "bytes_utf8_hex": "<可选：同上字节的 hex>",
                    "checksum": "<Envelope.checksum>",
                }
            ],
            "crypto": {
                "encrypt_json": [
                    {
                        "name": "<fixture.crypto.encrypt_json_cases[i].name>",
                        "ciphertext_json_text": "<RhopCrypto::encrypt_json 的输出文本>",
                        "decrypt_payload": "<可选：用自己的 decrypt_verify 解 fixture 里的 vools 密文后得到的 payload>",
                    }
                ],
                "encrypt_secret": [{"name": "<...>", "secret": "<RHOP-ENC:...>"}],
            },
            "signer": {
                "file_hash": [{"name": "<fixture.signer.file_hash.cases[i].name>", "signature": "<FileHashSigner::sign 输出>"}]
            },
        },
        "verify_command": "python scripts/verify_interop.py <moonbit_output.json>",
    }


def build_parity_notes():
    """QA 判据（lead 2026-10-27 裁定）：vools 自身存在两套 JSON 口径，复刻事实而非改正。

    这一节是给 MoonBit 实现者看的一致性契约：不是建议，是本项目验收时判 GREEN/RED 的判据。
    """
    return {
        "summary": "vools 的 envelope checksum 与 FileHashSigner 用的**不是同一套** JSON 规范化；本项目按 vools 真实行为精确复刻，两侧口径都保留。",
        "canonicalizations": {
            "envelope_checksum": {
                "used_by": "vools.rhop.envelope.Envelope._compute_checksum / to_rhop_bytes",
                "python": "json.dumps(data, ensure_ascii=False, sort_keys=True)",
                "ensure_ascii": False,
                "separators": "Python 默认 ', ' / ': '",
                "unicode": "非 ASCII 原样输出（中文键值保持中文字面）",
                "moonbit_expect": "canonical_json(Json) / canonical_json_utf8(Json) 必须与之一致",
                "verified_by": "fixtures.canonical_json[*] + fixtures.envelope[*].checksum_preimage_utf8",
            },
            "file_hash_signature": {
                "used_by": "vools.rhop.signer.FileHashSigner.sign",
                "python": "json.dumps({'task_id': ..., 'result': ...}, sort_keys=True)",
                "ensure_ascii": True,
                "separators": "Python 默认 ', ' / ': '",
                "unicode": "非 ASCII 转义为 \\uXXXX（中文按键/值全部转义）",
                "moonbit_expect": "FileHashSigner 的 preimage 必须用 ensure_ascii=True 口径（如需新增 canonical_json_ascii），**不得**复用 envelope 的 ensure_ascii=False canonical_json",
                "verified_by": "fixtures.signer.file_hash.cases[*].preimage（含 unicode_result 反例）",
                "trap": "若 signer 复用 canonical_json(ensure_ascii=False)，ASCII result 仍然对，但含中文 result 的签名会与 vools 不一致 —— 这是最容易漏测的一类假 GREEN。",
            },
        },
        "decision": {
            "decided_by": "lead（人类指挥官授权代行）",
            "decided_at": "2026-10-27",
            "ruling": "按 vools 真实口径精确复刻：FileHashSigner preimage 用默认 ensure_ascii=True；envelope checksum 用 ensure_ascii=False。不把 vools 的不一致「改正」，因为跨实现互操作以既有 vools 行为为准。",
        },
        "other_notable_differences": [
            {
                "topic": "encrypt_json 输出文本分隔符",
                "detail": "vools 用 json.dumps 默认分隔符（冒号/逗号后带空格，如 {\"v\": 1, \"alg\": \"fernet\", \"ct\": \"...\"}）。解密方只做 JSON 解析，所以 MoonBit 侧输出文本不必逐字复刻；但若有「全文相等」断言，需按带空格形式写。",
            },
            {
                "topic": "字符串 payload 的非 JSON 包装",
                "detail": "RhopCrypto.encrypt_json 接受 str：若本身是合法 JSON 文本则原样加密；否则包成 {\"__text__\": \"...\"} 再加密。见 fixtures.crypto.encrypt_json_cases 的 plain_string_payload。",
            },
            {
                "topic": "解密失败的静默回退",
                "detail": "VText.decrypt 解密失败时回退原文/空串并发 RuntimeWarning；RhopCrypto.decrypt_verify 在其上做启发式，才区分出 BAD_TOKEN / NOT_JSON。MoonBit 侧需要显式实现这三态。见 fixtures.crypto.negative_cases。",
            },
        ],
    }


def build_vectors(v, skip_crypto=False):
    # 只记录“相对 vools 根”的模块路径：绝对路径在 Windows(E:\...) 与 WSL(/mnt/e/...)
    # 上不同，会把 fixture 变成不可跨平台比对的机器指纹。
    rel_module = os.path.relpath(v.origin, v.root).replace(os.sep, "/")
    return {
        "schema": SCHEMA,
        "schema_version": SCHEMA_VERSION,
        "key": RHOP_KEY,
        "source": {
            "impl": "vools-rhop",
            "version": read_vools_version(v.root),
            "module_relpath": rel_module,
            "python": "生成脚本只用标准库 + cryptography；同一份 vools 源码在 py3.10/py3.13 产出逐字节相同（绝对路径不入 fixture）",
        },
        "status_flow": build_status_flow(v),
        "parity_notes": build_parity_notes(),
        "canonical_json": build_canonical_json_vectors(),
        "digest": build_digest_vectors(),
        "envelope": build_envelope_vectors(v),
        "crypto": build_crypto_vectors(v, skip_crypto=skip_crypto),
        "signer": build_signer_vectors(v),
        "moonbit_output_schema": build_moonbit_output_schema(),
    }


def render(payload):
    """稳定排版：键排序 + 2 空格缩进 + LF 结尾（跨平台逐字节可比）。"""
    return json.dumps(payload, ensure_ascii=False, sort_keys=True, indent=2) + "\n"


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
def generate(explicit_root=None, skip_crypto=False, deterministic=True):
    """构建向量并渲染成文本；deterministic=False 时用真随机 IV（不推荐，用于对照）。"""
    root = locate_vools_root(explicit_root)
    if root is None:
        raise GenError(
            "找不到 vools-rhop 源码（应含 vools/rhop/envelope.py）。\n"
            "  已探测：%s\n"
            "  请用 --vools-root <dir> 或环境变量 VOOLS_RHOP_ROOT 指定。"
            % (["<explicit>"] + VOOLS_CANDIDATES if explicit_root else VOOLS_CANDIDATES)
        )
    v = import_vools(root)
    if deterministic:
        with DeterministicFernet():
            payload = build_vectors(v, skip_crypto=skip_crypto)
    else:
        payload = build_vectors(v, skip_crypto=skip_crypto)
    return payload, render(payload), v, root


def write_text(path, text):
    """原子写入：唯一临时名 + fsync + os.replace。

    C2 审计 Q7：原实现用固定的 `<path>.tmp`，两条并发生成会互相覆盖同一个临时文件
    （不同参数时就是 last-writer-wins / 潜在半截写）。改用同目录唯一临时名 + fsync，
    并发安全；失败路径必定清理临时文件。
    """
    import tempfile

    parent = os.path.dirname(os.path.abspath(path))
    if parent and not os.path.isdir(parent):
        os.makedirs(parent)
    fd, tmp = tempfile.mkstemp(prefix=".vools_vectors-", suffix=".tmp", dir=parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
        tmp = None
    finally:
        if tmp and os.path.exists(tmp):
            try:
                os.remove(tmp)
            except OSError:
                pass


def cmd_generate(args):
    # --random-iv 与「幂等自检」互斥：真随机 IV 本来就不可能两次一致。
    if args.random_iv and not args.no_determinism_check:
        print("WARN: --random-iv 与幂等自检互斥，自动跳过自检（产物不可复现）")
        args.no_determinism_check = True

    if not args.no_determinism_check:
        payload1, text1, v, root = generate(args.vools_root, args.skip_crypto, deterministic=True)
        payload2, text2, _v, _r = generate(args.vools_root, args.skip_crypto, deterministic=True)
        if text1 != text2:
            raise GenError(
                "幂等自检失败：连续两次生成的 fixture 不一致（说明还有非确定性来源）。\n"
                "  大概率是 Fernet 的随机 IV / 时间戳没被固定住。"
            )
        determinism = "verified (两次连续生成逐字节相同)"
    else:
        payload1, text1, v, root = generate(args.vools_root, args.skip_crypto, deterministic=not args.random_iv)
        determinism = "skipped (--no-determinism-check)"

    write_text(args.output, text1)
    digest = hashlib.sha256(text1.encode("utf-8")).hexdigest()

    print("vools source      : %s (v%s)" % (root, read_vools_version(root) or "?"))
    print("vools module file : %s" % v.origin)
    print("output            : %s (%d bytes)" % (os.path.abspath(args.output), len(text1.encode("utf-8"))))
    print("fixture sha256    : %s" % digest)
    print("determinism       : %s" % determinism)
    print("sections          : canonical_json=%d, digest={sha256:%d, md5:%d, hmac:%d, pbkdf2:%d}, envelope=%d, crypto_encrypt=%s, crypto_secret=%s, signer=%d"
          % (
              len(payload1["canonical_json"]),
              len(payload1["digest"]["sha256"]),
              len(payload1["digest"]["md5"]),
              len(payload1["digest"]["hmac_sha256"]),
              len(payload1["digest"]["pbkdf2_hmac_sha256"]),
              len(payload1["envelope"]),
              "skipped" if payload1["crypto"].get("skipped") else len(payload1["crypto"]["encrypt_json_cases"]),
              "skipped" if payload1["crypto"].get("skipped") else len(payload1["crypto"]["encrypt_secret_cases"]),
              len(payload1["signer"]["file_hash"]["cases"]),
          ))
    if payload1["crypto"].get("skipped"):
        print("WARN: cryptography 不可用，crypto 分节已显式跳过（skipped_reason 已写入 fixture）")
    return 0


def cmd_verify(args):
    """--verify：把 MoonBit 产物交给 verify_interop.py（同一份校验逻辑，单入口）。"""
    here = os.path.dirname(os.path.abspath(__file__))
    if here not in sys.path:
        sys.path.insert(0, here)
    import verify_interop  # noqa: WPS433 - 延迟导入，避免非 verify 模式多一个依赖

    return verify_interop.main(
        [
            args.verify,
            "--fixtures",
            args.output,
            "--vools-root",
            args.vools_root or "",
        ]
    )


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="用真实 Python vools-rhop 生成 rx-mbt 跨实现一致性向量",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--output", default=DEFAULT_OUT, help="输出路径（默认 %(default)s）")
    parser.add_argument("--vools-root", default=None, help="vools-rhop 源码根（含 vools/rhop/envelope.py）")
    parser.add_argument("--skip-crypto", action="store_true", help="显式跳过 crypto 分节（cryptography 缺失时的降级路径）")
    parser.add_argument("--random-iv", action="store_true", help="用真随机 IV/当前时间（产物不可复现，仅调试用）")
    parser.add_argument("--no-determinism-check", action="store_true", help="跳过连续两次生成的幂等自检")
    parser.add_argument("--print-sha256", action="store_true", help="只打印现有产物 sha256 后退出")
    parser.add_argument("--verify", metavar="MOONBIT_JSON", default=None, help="反向校验 MoonBit 产物（转交 verify_interop.py）")
    args = parser.parse_args(argv)

    if args.print_sha256:
        if not os.path.isfile(args.output):
            sys.stderr.write("ERROR: 产物不存在：%s\n" % args.output)
            return 3
        with open(args.output, "rb") as fh:
            data = fh.read()
        print("%s  %s" % (hashlib.sha256(data).hexdigest(), os.path.abspath(args.output)))
        return 0

    try:
        if args.verify:
            return cmd_verify(args)
        return cmd_generate(args)
    except GenError as exc:
        sys.stderr.write("ERROR: %s\n" % exc)
        return 3


if __name__ == "__main__":
    sys.exit(main())
