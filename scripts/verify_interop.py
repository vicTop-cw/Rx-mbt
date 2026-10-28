#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""scripts/verify_interop.py -- 用真实 Python vools-rhop 反向复核 MoonBit 侧产物

输入：MoonBit（test-suit/rhop_js，js 目标）写出的 JSON —— 形状见
``test-suit/rhop_js/fixtures/vools_vectors.json`` 的 ``moonbit_output_schema`` 分节。

逐项动作（全部由真实 vools 代码执行，不是字符串比对游戏）：

* ``canonical_json``：MoonBit 的 ``canonical_json`` 输出 vs Python
  ``json.dumps(x, ensure_ascii=False, sort_keys=True)`` 的期望值；
* ``digest``：sha256 / md5 / hmac_sha256 / pbkdf2_hmac_sha256 的 hex 比对；
* ``envelope``：把 MoonBit 的 ``to_rhop_bytes`` 字节喂给 vools
  ``Envelope.from_rhop_bytes``（checksum 校验 + 字段反序列化），要求 checksum 与
  字段都与 fixture 一致；
* ``crypto``：把 MoonBit 的 ``encrypt_json`` 密文喂给 vools
  ``RhopCrypto.decrypt_verify`` 真实解密，要求 payload 与 fixture 一致；
  MoonBit 若上报了 ``decrypt_payload``（它解 fixture 里 vools 密文的结果），同样比对；
* ``signer``：MoonBit 的签名 vs vools ``FileHashSigner().sign(...)``。

默认还做一次 **fixture 自检**（用 vools 复核 fixture 本身是否自洽），确保手里这份
向量不是被人改过的假货。

用法::

    python scripts/verify_interop.py <moonbit_output.json>
    python scripts/verify_interop.py <moonbit_output.json> --strict --out report.json

退出码：0 全部通过（允许 SKIP）；1 有 FAIL；2 用法/环境错误。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import warnings

for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")
    except (AttributeError, ValueError):
        pass

# C2 审计 Q13：导入 gen_conformance_vectors 会在 scripts/__pycache__ 落 .pyc（多余产物）
# 把这个副作用关掉（只影响本工具的字节码缓存，不影响行为）。
sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import gen_conformance_vectors as gen  # noqa: E402 - 复用 vools 定位/导入逻辑（单一真源）

REPO_ROOT = gen.REPO_ROOT
DEFAULT_FIXTURES = gen.DEFAULT_OUT


# ---------------------------------------------------------------------------
# 结果收集
# ---------------------------------------------------------------------------
class Report(object):
    def __init__(self):
        self.items = []

    def add(self, section, name, status, detail):
        self.items.append({"section": section, "name": name, "status": status, "detail": detail})

    def count(self, status):
        return len([i for i in self.items if i["status"] == status])

    @property
    def failed(self):
        return [i for i in self.items if i["status"] == "FAIL"]

    def render_console(self):
        order = {"FAIL": 0, "SKIP": 1, "PASS": 2}
        rows = sorted(self.items, key=lambda i: (order.get(i["status"], 3), i["section"], i["name"]))
        width = max([len("%s/%s" % (i["section"], i["name"])) for i in rows] + [16])
        for item in rows:
            label = ("%s/%s" % (item["section"], item["name"])).ljust(width)
            detail = item["detail"]
            if len(detail) > 150:
                detail = detail[:147] + "..."
            print("  [%-4s] %s  %s" % (item["status"], label, detail))
        print(
            "  ---------------------------------------------------------------------\n"
            "  PASS=%d  FAIL=%d  SKIP=%d  (total %d)"
            % (self.count("PASS"), self.count("FAIL"), self.count("SKIP"), len(self.items))
        )


def _payload_equal(a, b):
    """payload 比对：严格 JSON 语义相等（dict/list/str/int/bool/None）。"""
    try:
        return json.loads(json.dumps(a, ensure_ascii=False, sort_keys=True)) == json.loads(
            json.dumps(b, ensure_ascii=False, sort_keys=True)
        )
    except (TypeError, ValueError):
        return a == b


def _get_bytes(item):
    """从 MoonBit 产物条目里取信封字节：utf8 文本 / 显式 hex 两种写法都收。"""
    if isinstance(item.get("to_rhop_bytes_utf8"), str):
        return item["to_rhop_bytes_utf8"].encode("utf-8"), "to_rhop_bytes_utf8"
    if isinstance(item.get("bytes_utf8"), str):
        return item["bytes_utf8"].encode("utf-8"), "bytes_utf8"
    for key in ("to_rhop_bytes_utf8_hex", "bytes_utf8_hex", "bytes_hex"):
        if isinstance(item.get(key), str):
            try:
                return bytes.fromhex(item[key]), key
            except ValueError as exc:
                raise ValueError("字段 %s 不是合法 hex: %s" % (key, exc))
    raise ValueError("缺少信封字节字段（to_rhop_bytes_utf8 / bytes_utf8 / bytes_utf8_hex 任一）")


# ---------------------------------------------------------------------------
# fixture 自检
# ---------------------------------------------------------------------------
def self_check_fixture(fixtures, v, report):
    """用真实 vools 复核 fixture 自洽性：checksum / 解密 / 签名都要能对上。"""
    section = "fixture-self"
    for case in fixtures.get("canonical_json", []):
        got = gen.canonical_json_text(case["input"])
        params = "不应出现的差异"
        if got != case["expected"]:
            report.add(section, case["name"], "FAIL", "canonical_json 期望值不自洽：%s" % params)
        else:
            report.add(section, case["name"], "PASS", "canonical_json 期望值可复算")

    for case in fixtures.get("envelope", []):
        if "to_rhop_bytes_utf8_hex" not in case:
            continue
        raw = bytes.fromhex(case["to_rhop_bytes_utf8_hex"])
        if case.get("expect_error"):
            # 篡改用例：fixture 期望 vools 拒绝它——解成功才是 fixture 出错
            try:
                v.envelope.Envelope.from_rhop_bytes(raw)
                report.add(section, case["name"], "FAIL", "篡改用例竟然被 vools 接受了")
            except ValueError as exc:
                if case.get("expect_error_contains", "") in str(exc):
                    report.add(section, case["name"], "PASS", "vools 如预期拒绝：%s" % str(exc)[:48])
                else:
                    report.add(section, case["name"], "FAIL", "报错文本不符预期：%s" % str(exc)[:80])
            continue
        try:
            env = v.envelope.Envelope.from_rhop_bytes(raw)
        except ValueError as exc:
            report.add(section, case["name"], "FAIL", "fixture 信封反序列化失败: %s" % exc)
            continue
        if env.checksum == case["checksum"]:
            report.add(section, case["name"], "PASS", "checksum 自洽 %s" % env.checksum[:24])
        else:
            report.add(section, case["name"], "FAIL", "checksum 不自洽")

    crypto = fixtures.get("crypto") or {}
    if not crypto.get("skipped"):
        crypt = v.crypto.RhopCrypto(fixtures["key"])
        for case in crypto.get("encrypt_json_cases", []):
            with warnings.catch_warnings():
                warnings.simplefilter("ignore")
                vr = crypt.decrypt_verify(case["ciphertext_json_text"])
            if vr.ok and _payload_equal(vr.payload, case["payload"]):
                report.add(section, "crypto/" + case["name"], "PASS", "fixture 密文可被 vools 解回")
            else:
                report.add(section, "crypto/" + case["name"], "FAIL", "fixture 密文解不回来（reason=%s）" % vr.reason)

    signer = fixtures.get("signer", {}).get("file_hash", {})
    fhs = v.signer.FileHashSigner()
    for case in signer.get("cases", []):
        if fhs.sign(case["task_id"], case["result"]) == case["signature"]:
            report.add(section, "signer/" + case["name"], "PASS", "签名可复算")
        else:
            report.add(section, "signer/" + case["name"], "FAIL", "签名与 fixture 不一致")


# ---------------------------------------------------------------------------
# MoonBit 产物校验
# ---------------------------------------------------------------------------
def check_canonical_json(fixtures, produced, report):
    expected = {c["name"]: c for c in fixtures.get("canonical_json", [])}
    items = produced or []
    if not items:
        report.add("canonical_json", "*", "SKIP", "MoonBit 产物未包含 canonical_json 分节")
        return
    for item in items:
        name = item.get("name", "?")
        case = expected.get(name)
        if case is None:
            report.add("canonical_json", name, "FAIL", "fixture 里没有同名用例（名字必须逐字对应）")
            continue
        actual = item.get("actual")
        if not isinstance(actual, str):
            report.add("canonical_json", name, "FAIL", "缺少 actual 字符串字段")
        elif actual == case["expected"]:
            report.add("canonical_json", name, "PASS", "与 Python json.dumps(ensure_ascii=False, sort_keys=True) 一致")
        else:
            report.add(
                "canonical_json",
                name,
                "FAIL",
                "实际=%r 期望=%r" % (actual[:80], case["expected"][:80]),
            )
    missing = sorted(set(expected) - {i.get("name") for i in items})
    for name in missing:
        report.add("canonical_json", name, "SKIP", "MoonBit 未产出该用例")


def _check_digest_alg(key, algo_name, fixtures, produced, report):
    expected = {c["name"]: c for c in fixtures.get("digest", {}).get(key, [])}
    items = produced or []
    if not items:
        report.add(algo_name, "*", "SKIP", "MoonBit 产物未包含 %s 分节" % algo_name)
        return
    for item in items:
        name = item.get("name", "?")
        case = expected.get(name)
        if case is None:
            report.add(algo_name, name, "FAIL", "fixture 里没有同名用例")
            continue
        got = (item.get("hex") or "").lower()
        if got == case["hex"]:
            report.add(algo_name, name, "PASS", "%s 一致" % case["hex"][:16])
        else:
            report.add(algo_name, name, "FAIL", "实际=%s 期望=%s" % (got[:32], case["hex"][:32]))
    for name in sorted(set(expected) - {i.get("name") for i in items}):
        report.add(algo_name, name, "SKIP", "MoonBit 未产出该用例")


def check_digest(fixtures, produced, report):
    produced = produced or {}
    flat = {}
    if isinstance(produced, list):
        for item in produced:
            flat.setdefault(item.get("algo", "sha256"), []).append(item)
        produced = flat
    _check_digest_alg("sha256", "sha256", fixtures, produced.get("sha256"), report)
    _check_digest_alg("md5", "md5", fixtures, produced.get("md5"), report)
    _check_digest_alg("hmac_sha256", "hmac_sha256", fixtures, produced.get("hmac_sha256"), report)
    _check_digest_alg(
        "pbkdf2_hmac_sha256", "pbkdf2_hmac_sha256", fixtures, produced.get("pbkdf2_hmac_sha256"), report
    )


def check_envelope(fixtures, produced, v, report):
    all_cases = {c["name"]: c for c in fixtures.get("envelope", []) if "to_rhop_bytes_utf8_hex" in c}
    expected = {n: c for n, c in all_cases.items() if not c.get("expect_error")}
    tamper = {n: c for n, c in all_cases.items() if c.get("expect_error")}
    items = produced or []
    if not items:
        report.add("envelope", "*", "SKIP", "MoonBit 产物未包含 envelope 分节")
        return
    for item in items:
        name = item.get("name", "?")
        case = all_cases.get(name)
        if case is None:
            report.add("envelope", name, "FAIL", "fixture 里没有同名用例")
            continue
        try:
            raw, field = _get_bytes(item)
        except ValueError as exc:
            report.add("envelope", name, "FAIL", str(exc))
            continue
        if name in tamper:
            # 篡改用例：vools 必须拒绝，否则就是「损坏信封被静默接受」
            want = case.get("expect_error_contains", "checksum mismatch")
            try:
                v.envelope.Envelope.from_rhop_bytes(raw)
                report.add("envelope", name, "FAIL", "篡改信封被 vools 接受（完整性校验失效）")
            except ValueError as exc:
                if want in str(exc):
                    report.add("envelope", name, "PASS", "vools 如预期拒绝篡改信封：%s" % str(exc)[:40])
                else:
                    report.add("envelope", name, "FAIL", "拒绝理由不符：%s" % str(exc)[:80])
            continue
        claims = item.get("checksum")
        if claims and claims != case["checksum"]:
            report.add("envelope", name, "FAIL", "MoonBit 自报 checksum 与 fixture 不一致")
            continue
        try:
            env = v.envelope.Envelope.from_rhop_bytes(raw)
        except ValueError as exc:
            report.add("envelope", name, "FAIL", "vools from_rhop_bytes 拒绝（%s）: %s" % (field, exc))
            continue
        problems = []
        if env.checksum != case["checksum"]:
            problems.append("checksum 不一致")
        if not _payload_equal(env.to_dict(), case["fields"]):
            problems.append("字段不一致")
        if problems:
            report.add("envelope", name, "FAIL", "；".join(problems))
        else:
            report.add(
                "envelope",
                name,
                "PASS",
                "vools 反序列化通过、checksum+字段逐字段一致（%d bytes）" % len(raw),
            )
    for name in sorted(set(expected) - {i.get("name") for i in items}):
        report.add("envelope", name, "SKIP", "MoonBit 未产出该用例")


def check_crypto(fixtures, produced, v, report):
    crypto_fixture = fixtures.get("crypto") or {}
    if crypto_fixture.get("skipped"):
        report.add("crypto", "*", "SKIP", "fixture 未包含 crypto（生成时 --skip-crypto）")
        return
    crypt = v.crypto.RhopCrypto(fixtures["key"])
    produced = produced or {}
    if isinstance(produced, list):
        produced = {"encrypt_json": produced}

    encrypt_cases = {c["name"]: c for c in crypto_fixture.get("encrypt_json_cases", [])}
    enc_items = produced.get("encrypt_json") or []
    if not enc_items:
        report.add("crypto", "encrypt_json", "SKIP", "MoonBit 产物未包含 crypto.encrypt_json 分节")
    for item in enc_items:
        name = item.get("name", "?")
        case = encrypt_cases.get(name)
        if case is None:
            report.add("crypto", name, "FAIL", "fixture 里没有同名用例")
            continue
        ct_text = item.get("ciphertext_json_text")
        if not isinstance(ct_text, str):
            report.add("crypto", name, "FAIL", "缺少 ciphertext_json_text 字段")
            continue
        # 1) MoonBit 密文能否被 Python vools 真解密（跨实现的核心判据）
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            vr = crypt.decrypt_verify(ct_text)
        if not vr.ok:
            report.add("crypto", name, "FAIL", "vools 解不开 MoonBit 密文：reason=%s" % vr.reason)
            continue
        if not _payload_equal(vr.payload, case["payload"]):
            report.add("crypto", name, "FAIL", "解密成功但 payload 与期望不一致：%r" % (vr.payload,))
            continue
        # 2) 信封结构：v/alg 必须与 vools 口径一致
        try:
            parsed = json.loads(ct_text)
        except ValueError as exc:
            report.add("crypto", name, "FAIL", "密文 JSON 文本不合法：%s" % exc)
            continue
        if parsed.get("v") != case["v"] or parsed.get("alg") != case["alg"]:
            report.add("crypto", name, "FAIL", "v/alg 与 vools 不一致：%r" % ({k: parsed.get(k) for k in ("v", "alg")},))
            continue
        # 3) MoonBit 反向解密能力（若它上报了 decrypt_payload）
        decrypt_note = ""
        if "decrypt_payload" in item:
            if _payload_equal(item["decrypt_payload"], case["payload"]):
                decrypt_note = "；且 MoonBit 能解 vools 密文"
            else:
                report.add("crypto", "decrypt/" + name, "FAIL", "MoonBit 解 vools 密文得到的 payload 不对")
                continue
        report.add("crypto", name, "PASS", "vools 成功解密 MoonBit 密文%s" % decrypt_note)

    secret_cases = {c["name"]: c for c in crypto_fixture.get("encrypt_secret_cases", [])}
    secret_items = produced.get("encrypt_secret") or []
    if not secret_items:
        report.add("crypto", "encrypt_secret", "SKIP", "MoonBit 产物未包含 crypto.encrypt_secret 分节")
    prefix = crypto_fixture.get("secret_prefix", "RHOP-ENC:")
    for item in secret_items:
        name = item.get("name", "?")
        case = secret_cases.get(name)
        if case is None:
            report.add("crypto", "secret/" + name, "FAIL", "fixture 里没有同名用例")
            continue
        secret = item.get("secret")
        if not isinstance(secret, str) or not secret.startswith(prefix):
            report.add("crypto", "secret/" + name, "FAIL", "密文缺少 %s 前缀" % prefix)
            continue
        try:
            plain = crypt.decrypt_secret(secret)
        except ValueError as exc:
            report.add("crypto", "secret/" + name, "FAIL", "vools decrypt_secret 失败：%s" % exc)
            continue
        if plain == case["plaintext_utf8"]:
            report.add("crypto", "secret/" + name, "PASS", "vools 解密 RHOP-ENC 成功，明文一致")
        else:
            report.add("crypto", "secret/" + name, "FAIL", "明文不一致：%r" % (plain,))


def check_signer(fixtures, produced, v, report):
    fhs = v.signer.FileHashSigner()
    cases = {c["name"]: c for c in (fixtures.get("signer", {}).get("file_hash", {}) or {}).get("cases", [])}
    items = ((produced or {}).get("file_hash") or []) if isinstance(produced, dict) else (produced or [])
    if not items:
        report.add("signer", "file_hash", "SKIP", "MoonBit 产物未包含 signer.file_hash 分节")
        return
    for item in items:
        name = item.get("name", "?")
        case = cases.get(name)
        if case is None:
            report.add("signer", name, "FAIL", "fixture 里没有同名用例")
            continue
        expected = fhs.sign(case["task_id"], case["result"])
        got = item.get("signature")
        if got == expected:
            report.add("signer", name, "PASS", "签名与 vools FileHashSigner 一致")
        else:
            report.add("signer", name, "FAIL", "实际=%r 期望=%r" % (got, expected))


# 扁平产物形状（key/envelope_json/secret/...）天然不含分节，因此这些分节里的
# 检查点在扁平产物下永远没有机会被复核。--strict 模式下必须把它们逐个记成
# SKIP（strict 把 SKIP 当失败），否则「只交一个密文」就能拿到零 SKIP 的全绿。
FLAT_UNCHECKED_SECTIONS = (
    ("canonical_json", "扁平产物不含 canonical_json 分节，--strict 要求分节 schema"),
    ("digest", "扁平产物不含 digest 分节（sha256/md5/hmac/pbkdf2 均未复核）"),
    ("envelope", "扁平产物不含 envelope 分节（to_rhop_bytes/checksum 字节级未复核）"),
    ("crypto", "扁平产物不含 crypto 分节（encrypt_json/encrypt_secret 用例未复核）"),
    ("signer", "扁平产物不含 signer 分节（file_hash 签名未复核）"),
)


def check_flat_produced(produced, fixtures, v, report, strict=False):
    """兼容 impl-crypto 的「扁平」产物形状（test-suit/rhop_js/fixtures/moonbit_vectors.json）。

    那个文件的形态是 ``{key, payload_json, envelope_json, secret, secret_plain,
    envelope_nonjson, expect:{...}}`` —— 不是本脚本主推的分节 schema，但里面的密文
    照样能用 Python vools 真解密，所以这里做一次通用适配：

    * 值形如 ``{"v":1,"alg":"fernet","ct":...}`` 的字段 → ``decrypt_verify``；
    * 值带 ``RHOP-ENC:`` 前缀 → ``decrypt_secret``；
    * ``expect`` 里写 ``decrypt_verify -> NOT_JSON`` 这类断言时按断言核对 reason。
    """
    key = produced.get("key") or fixtures.get("key") or ""
    if not key:
        report.add("flat", "*", "FAIL", "产物既不是分节 schema，也没有 key 字段（无法解密）")
        return
    crypt = v.crypto.RhopCrypto(key)
    expect_map = produced.get("expect") if isinstance(produced.get("expect"), dict) else {}
    payload_json = produced.get("payload_json")
    expected_payload = None
    if isinstance(payload_json, str):
        try:
            expected_payload = json.loads(payload_json)
        except ValueError:
            expected_payload = None

    report.add("flat", "key", "PASS", "使用产物自带 key=%r 做真实解密复核" % key)

    found = 0
    for field, value in sorted(produced.items()):
        if not isinstance(value, str) or field in ("generated_by", "target", "alg", "key", "payload_json", "secret_plain"):
            continue
        # 1) RHOP-ENC 密文
        if value.startswith("RHOP-ENC:"):
            found += 1
            want_plain = produced.get("secret_plain") if field == "secret" else None
            try:
                plain = crypt.decrypt_secret(value)
            except ValueError as exc:
                report.add("flat", field, "FAIL", "vools decrypt_secret 失败：%s" % str(exc)[:100])
                continue
            if want_plain is not None and plain != want_plain:
                report.add("flat", field, "FAIL", "明文不一致：%r != %r" % (plain, want_plain))
            else:
                report.add("flat", field, "PASS", "vools 解密 RHOP-ENC 成功%s"
                           % ("，明文与 secret_plain 一致" if want_plain is not None else ""))
            continue
        # 2) 加密信封 JSON 文本
        try:
            parsed = json.loads(value)
        except ValueError:
            continue
        if not isinstance(parsed, dict) or "ct" not in parsed or "alg" not in parsed:
            continue
        found += 1
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            vr = crypt.decrypt_verify(value)
        want = expect_map.get(field) or ""
        if "NOT_JSON" in want:
            if not vr.ok and vr.reason == "NOT_JSON":
                report.add("flat", field, "PASS", "vools 解密得到非 JSON 明文，reason=NOT_JSON（符合断言）")
            else:
                report.add("flat", field, "FAIL", "期望 NOT_JSON，实测 ok=%s reason=%s" % (vr.ok, vr.reason))
            continue
        if not vr.ok:
            report.add("flat", field, "FAIL", "vools 解不开 MoonBit 密文：reason=%s" % vr.reason)
            continue
        if expected_payload is not None and field == "envelope_json" and not _payload_equal(vr.payload, expected_payload):
            report.add("flat", field, "FAIL", "解密成功但 payload 与 payload_json 不一致：%r" % (vr.payload,))
            continue
        report.add("flat", field, "PASS", "vools 成功解密 MoonBit 密文并解析出 payload")
    if found == 0:
        report.add("flat", "*", "SKIP", "扁平产物里没有可复核的密文字段")
    if strict:
        # 扁平产物下这些分节的检查点未被执行；--strict 必须让它们计为 SKIP（→ 非零退出），
        # 不允许「少交分节」因为形状扁平而静默通过。
        for _section, _why in FLAT_UNCHECKED_SECTIONS:
            report.add(_section, "*", "SKIP", _why + "（扁平产物未复核；--strict 判失败）")


def run_checks(produced, fixtures, v, do_self_check=True, strict=False):
    """按产物形状分派到对应校验器，返回 Report（main 与 --self-test 共用）。"""
    report = Report()
    if do_self_check:
        self_check_fixture(fixtures, v, report)

    cases = produced.get("cases") if isinstance(produced.get("cases"), dict) else produced
    is_flat = not any(
        k in cases for k in ("canonical_json", "digest", "envelope", "crypto", "signer")
    ) and any(k in produced for k in ("envelope_json", "secret", "payload_json", "envelope_nonjson"))

    if is_flat:
        check_flat_produced(produced, fixtures, v, report, strict=strict)
    else:
        check_canonical_json(fixtures, cases.get("canonical_json"), report)
        check_digest(fixtures, cases.get("digest"), report)
        check_envelope(fixtures, cases.get("envelope"), v, report)
        check_crypto(fixtures, cases.get("crypto"), v, report)
        check_signer(fixtures, cases.get("signer"), v, report)
    return report


# ---------------------------------------------------------------------------
# 工具自检（--self-test）：把 fixture 的值反向构造成「MoonBit 产物」再注入错误
# ---------------------------------------------------------------------------
def build_synthetic_from_fixture(fixtures):
    """用 fixture 自己的期望值拼一份「完全正确」的 MoonBit 产物（用于自检工具本身）。"""
    fx = fixtures
    cases = {
        "canonical_json": [{"name": c["name"], "actual": c["expected"]} for c in fx["canonical_json"]],
        "digest": {
            k: [{"name": c["name"], "hex": c["hex"]} for c in fx["digest"][k]]
            for k in ("sha256", "md5", "hmac_sha256", "pbkdf2_hmac_sha256")
            if k in fx["digest"]
        },
        "envelope": [
            {"name": c["name"], "to_rhop_bytes_utf8_hex": c["to_rhop_bytes_utf8_hex"]}
            for c in fx["envelope"]
            if "to_rhop_bytes_utf8_hex" in c
        ],
        "signer": {
            "file_hash": [
                {"name": c["name"], "signature": c["signature"]}
                for c in fx.get("signer", {}).get("file_hash", {}).get("cases", [])
            ]
        },
    }
    crypto = fx.get("crypto") or {}
    if not crypto.get("skipped"):
        cases["crypto"] = {
            "encrypt_json": [
                {
                    "name": c["name"],
                    "ciphertext_json_text": c["ciphertext_json_text"],
                    "decrypt_payload": c["payload"],
                }
                for c in crypto.get("encrypt_json_cases", [])
            ],
            "encrypt_secret": [
                {"name": c["name"], "secret": c["secret"]} for c in crypto.get("encrypt_secret_cases", [])
            ],
        }
    return {
        "schema": "rhop-moonbit-output",
        "schema_version": 1,
        "produced_by": "verify_interop.py --self-test（由 fixture 期望值反向构造，非真实 MoonBit 产物）",
        "cases": cases,
    }


def build_mutated(produced, fixtures):
    """注入 5 类典型错误，验证校验器真的会判红（防「永远绿」的假校验器）。"""
    import copy

    bad = copy.deepcopy(produced)
    injected = []
    cases = bad["cases"]
    if cases.get("canonical_json"):
        cases["canonical_json"][0]["actual"] = cases["canonical_json"][0]["actual"] + " "
        injected.append("canonical_json 尾部加空格")
    if cases.get("digest", {}).get("sha256"):
        cases["digest"]["sha256"][0]["hex"] = "0" * 64
        injected.append("sha256 hex 全 0")
    if cases.get("signer", {}).get("file_hash"):
        cases["signer"]["file_hash"][0]["signature"] = "sha256:" + "e" * 64
        injected.append("签名改 hex")
    if cases.get("crypto", {}).get("encrypt_json"):
        cases["crypto"]["encrypt_json"][0]["ciphertext_json_text"] = '{"v": 1, "alg": "fernet", "ct": "AAAA"}'
        injected.append("密文换成垃圾 ct")
    if cases.get("envelope"):
        # 用篡改用例的字节冒充正常信封（checksum 必然不符），确保 vools 会拒绝
        tampered = next((c for c in fixtures["envelope"] if c.get("expect_error")), None)
        if tampered:
            cases["envelope"][0]["to_rhop_bytes_utf8_hex"] = tampered["to_rhop_bytes_utf8_hex"]
            injected.append("正常信封换成篡改字节")
    return bad, injected


def self_test(fixtures, v):
    """工具自检：4 个场景都必须「按预期表现」。返回 exit code。"""
    print("=" * 77)
    print(" verify_interop.py 自检（--self-test）：校验器本身可不可信")
    print("=" * 77)
    scenarios = []

    ok_produced = build_synthetic_from_fixture(fixtures)
    rep_ok = run_checks(ok_produced, fixtures, v, do_self_check=True)
    scenarios.append(("正向：正确的 MoonBit 产物", rep_ok, "no-fail"))

    bad_produced, injected = build_mutated(ok_produced, fixtures)
    rep_bad = run_checks(bad_produced, fixtures, v, do_self_check=False)
    scenarios.append(("对抗：注入 %d 类错误（%s）" % (len(injected), "、".join(injected)), rep_bad, "has-fail"))

    partial = {"schema": "rhop-moonbit-output", "cases": {"canonical_json": ok_produced["cases"]["canonical_json"]}}
    rep_partial = run_checks(partial, fixtures, v, do_self_check=False)
    scenarios.append(("部分产物：只有 canonical_json", rep_partial, "has-skip-no-fail"))

    # F1 回归（4 组合：扁平/分节 × strict/非 strict）：
    #   扁平 × 非 strict：密文仍要真解密（允许缺失分节以 SKIP 提示）；
    #   扁平 × strict  ：缺失的 5 个分节必须记 SKIP（strict 下 → 非零退出）；
    #   分节 × strict  ：完整分节产物不得有任何 SKIP。
    flat_prod = {
        "schema": "rhop-moonbit-output",
        "key": fixtures.get("key"),
        "envelope_json": fixtures["crypto"]["encrypt_json_cases"][0]["ciphertext_json_text"],
    }
    rep_flat = run_checks(flat_prod, fixtures, v, do_self_check=False)
    scenarios.append(("扁平产物 × 非 strict（密文真解密，缺失分节不判红）", rep_flat, "no-fail"))
    rep_flat_strict = run_checks(flat_prod, fixtures, v, do_self_check=False, strict=True)
    scenarios.append(("扁平产物 × --strict（缺失分节必须记 SKIP）", rep_flat_strict, "strict-skip>=5"))
    rep_sec_strict = run_checks(ok_produced, fixtures, v, do_self_check=False, strict=True)
    scenarios.append(("分节产物 × --strict（完整产物零 SKIP）", rep_sec_strict, "strict-no-skip"))

    expected_fail_count = len(
        [1 for _ in injected]
    )
    rc = 0
    print()
    for title, rep, expect in scenarios:
        fails = rep.count("FAIL")
        skips = rep.count("SKIP")
        if expect == "no-fail":
            good = fails == 0 and rep.count("PASS") > 0
        elif expect == "has-fail":
            good = fails >= expected_fail_count
        elif expect == "strict-skip>=5":
            good = fails == 0 and skips >= 5
        elif expect == "strict-no-skip":
            good = fails == 0 and skips == 0
        else:
            good = fails == 0 and skips > 0
        print("  [%s] %s → PASS=%d FAIL=%d SKIP=%d（期望：%s）"
              % ("OK" if good else "BAD", title, rep.count("PASS"), fails, skips, expect))
        if not good:
            rc = 1

    print()
    print(" SELF-TEST: %s" % ("PASS —— 校验器对正确产物放行、对注入错误逐项判红" if rc == 0 else "FAIL"))
    print("=" * 77)
    return rc


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
def load_json(path, what):
    if not os.path.isfile(path):
        raise gen.GenError("%s 不存在：%s" % (what, path))
    with open(path, "r", encoding="utf-8") as fh:
        try:
            return json.load(fh)
        except ValueError as exc:
            raise gen.GenError("%s 不是合法 JSON（%s）：%s" % (what, exc, path))


class _FlatCryptoStub(object):
    """自测用的假 vools.crypto：flat 自测样例故意不含密文字段，解密路径不会被触达。"""

    @staticmethod
    def RhopCrypto(key):  # noqa: N802 - 对齐 vools 命名
        return object()


class _VoolsStub(object):
    crypto = _FlatCryptoStub()


def exit_code(report, strict):
    """失败优先；--strict 下任何 SKIP 也算失败（C1 审计 F1 的判绿口径）。"""
    if report.failed:
        return 1
    if strict and report.count("SKIP") > 0:
        return 1
    return 0


def self_test_shapes(fixtures, v):
    """C1 审计 F1 回归自测：产物形状 × --strict 四组合。

    关键断言：扁平产物在 --strict 下必须把 5 个未复核分节记成 SKIP（→ rc=1），
    不能因为形状扁平就"零 SKIP 全绿"；分节产物则绝不出现这些 sentinel SKIP。
    """
    sentinel = "扁平产物"
    results = []

    # (1) 扁平 + strict：必须有 5 条 sentinel SKIP，rc=1
    flat = {"key": "selftest-key", "payload_json": "{}", "note": "自测用扁平产物"}
    rep = check_flat_produced_and_collect(flat, {}, _VoolsStub(), strict=True)
    _want_sections = set(name for name, _why in FLAT_UNCHECKED_SECTIONS)
    flat_skips = [i for i in rep.items
                  if i["status"] == "SKIP" and sentinel in i["detail"] and i["section"] in _want_sections]
    results.append(("flat + --strict", set(i["section"] for i in flat_skips) == _want_sections,
                    "覆盖分节 %d/%d：%s"
                    % (len(set(i["section"] for i in flat_skips)), len(_want_sections),
                       ",".join(sorted(set(i["section"] for i in flat_skips))))))
    results.append(("flat + --strict rc", exit_code(rep, True) == 1,
                    "rc=%d" % exit_code(rep, True)))

    # (2) 扁平 + 非 strict：同样的 SKIP 仍在，但 rc 必须为 0（不误杀日常回归）
    rep2 = check_flat_produced_and_collect(flat, {}, _VoolsStub(), strict=False)
    results.append(("flat + 非 strict rc", exit_code(rep2, False) == 0,
                    "rc=%d SKIP=%d" % (exit_code(rep2, False), rep2.count("SKIP"))))
    results.append(("flat strict 增量", rep2.count("SKIP") + len(FLAT_UNCHECKED_SECTIONS) == rep.count("SKIP"),
                    "非 strict SKIP=%d + %d == strict SKIP=%d"
                    % (rep2.count("SKIP"), len(FLAT_UNCHECKED_SECTIONS), rep.count("SKIP"))))

    # (3)(4) 分节产物 + strict/非 strict：绝不出现 flat sentinel SKIP
    sectioned = {
        "schema": "rhop-moonbit-output",
        "produced_by": "self-test",
        "cases": {name: {} for name, _why in FLAT_UNCHECKED_SECTIONS},
    }
    for strict in (False, True):
        rep3 = run_checks(sectioned, fixtures, v, do_self_check=False, strict=strict)
        bad = [i for i in rep3.items if i["status"] == "SKIP" and sentinel in i["detail"]]
        results.append(("sectioned + %s：无 flat sentinel" % ("strict" if strict else "非 strict"),
                        not bad, "sentinel SKIP=%d" % len(bad)))

    print()
    print(" 自测：产物形状 × --strict 四组合")
    print("-" * 77)
    ok = True
    for name, passed, detail in results:
        ok = ok and passed
        print("  [%s] %-28s %s" % ("PASS" if passed else "FAIL", name, detail))
    print("-" * 77)
    print(" RESULT: %s -- 4 组合语义%s" % ("PASS" if ok else "FAIL", "正确" if ok else "不符合预期"))
    return 0 if ok else 1


def check_flat_produced_and_collect(produced, fixtures, v, strict):
    rep = Report()
    check_flat_produced(produced, fixtures, v, rep, strict=strict)
    return rep


def main(argv=None):
    parser = argparse.ArgumentParser(description="用真实 Python vools-rhop 反向复核 MoonBit 侧产物")
    parser.add_argument(
        "moonbit_output",
        nargs="?",
        help="MoonBit 侧写出的 JSON 文件（形状见 fixture 的 moonbit_output_schema）；用 --self-test 时可省略",
    )
    parser.add_argument("--fixtures", default=DEFAULT_FIXTURES, help="fixture 路径（默认 %(default)s）")
    parser.add_argument("--vools-root", default=None, help="vools-rhop 源码根")
    parser.add_argument("--strict", action="store_true", help="SKIP 也算失败（验收模式：要求每一项都有产物）")
    parser.add_argument("--no-self-check", action="store_true", help="跳过 fixture 自检")
    parser.add_argument("--self-test", action="store_true", help="自检校验器本身：正向放行 + 注入 5 类错误必须判红")
    parser.add_argument(
        "--self-test-shapes", action="store_true",
        help="C1-F1 回归自测：扁平/分节两种产物形状 × strict/非 strict 四组合",
    )
    parser.add_argument("--out", default=None, help="把逐项报告写成 JSON 文件")
    args = parser.parse_args(argv)

    try:
        fixtures = load_json(args.fixtures, "fixture")
        root = gen.locate_vools_root(args.vools_root)
        if root is None:
            raise gen.GenError("找不到 vools-rhop 源码，请用 --vools-root 指定")
        v = gen.import_vools(root)
        if args.self_test:
            return self_test(fixtures, v)
        if args.self_test_shapes:
            return self_test_shapes(fixtures, v)
        if not args.moonbit_output:
            sys.stderr.write("ERROR: 缺少 MoonBit 产物路径（或用 --self-test 自检校验器本身）\n")
            return 2
        produced = load_json(args.moonbit_output, "MoonBit 产物")
    except gen.GenError as exc:
        sys.stderr.write("ERROR: %s\n" % exc)
        return 2

    if produced.get("schema") not in (None, "rhop-moonbit-output"):
        sys.stderr.write(
            "WARN: 产物 schema=%r，期望 'rhop-moonbit-output'（继续按兼容方式解析）\n" % produced.get("schema")
        )

    print("=" * 77)
    print(" rx-mbt 跨实现互操作复核  scripts/verify_interop.py")
    print("=" * 77)
    print(" fixture     : %s" % os.path.abspath(args.fixtures))
    print(" moonbit out : %s" % os.path.abspath(args.moonbit_output))
    print(" vools       : %s%s" % (root, " (v%s)" % gen.read_vools_version(root) if gen.read_vools_version(root) else ""))
    print(" produced_by : %s" % (produced.get("produced_by") or "<未标注>"))
    print("-" * 77)

    # 产物可能是：
    #   (a) 主推的分节 schema（顶层或 "cases" 下）—— 见 fixture.moonbit_output_schema；
    #   (b) impl-crypto 的扁平形状（key/envelope_json/secret/...）—— 走通用适配器。
    cases = produced.get("cases") if isinstance(produced.get("cases"), dict) else produced
    is_flat = not any(
        k in cases for k in ("canonical_json", "digest", "envelope", "crypto", "signer")
    ) and any(k in produced for k in ("envelope_json", "secret", "payload_json", "envelope_nonjson"))
    if is_flat:
        print(" [!] 产物是扁平形状（非分节 schema），走通用适配器复核")

    report = run_checks(produced, fixtures, v, do_self_check=not args.no_self_check, strict=args.strict)

    print()
    report.render_console()

    failed = report.failed
    skipped = [i for i in report.items if i["status"] == "SKIP"]
    rc = exit_code(report, args.strict)

    print()
    if rc == 0:
        print(" RESULT: PASS -- 所有已产出项经 vools 复核一致%s"
              % ("" if not skipped else "（%d 项 SKIP；验收模式请加 --strict）" % len(skipped)))
    else:
        if failed:
            print(" RESULT: FAIL -- %d 项不一致，首项：%s/%s %s"
                  % (len(failed), failed[0]["section"], failed[0]["name"], failed[0]["detail"]))
        else:
            print(" RESULT: FAIL -- --strict 下存在 %d 项 SKIP（MoonBit 未产出）" % len(skipped))
    print("=" * 77)

    if args.out:
        with open(args.out, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(
                {
                    "schema": "rhop-interop-report",
                    "schema_version": 1,
                    "fixtures": os.path.abspath(args.fixtures),
                    "moonbit_output": os.path.abspath(args.moonbit_output),
                    "vools_root": root,
                    "strict": bool(args.strict),
                    "result": "PASS" if rc == 0 else "FAIL",
                    "counts": {
                        "pass": report.count("PASS"),
                        "fail": report.count("FAIL"),
                        "skip": report.count("SKIP"),
                        "total": len(report.items),
                    },
                    "items": report.items,
                },
                fh,
                ensure_ascii=False,
                sort_keys=True,
                indent=2,
            )
            fh.write("\n")
        print(" 报告已写入：%s" % os.path.abspath(args.out))

    return rc


if __name__ == "__main__":
    try:
        sys.exit(main())
    except gen.GenError as exc:  # 兜底：环境类错误统一 exit 2
        sys.stderr.write("ERROR: %s\n" % exc)
        sys.exit(2)
