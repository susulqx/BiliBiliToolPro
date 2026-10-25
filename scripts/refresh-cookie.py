#!/usr/bin/env python3
"""BiliBili web session refresh (rotates SESSDATA and refresh_token).

Modes:
  refresh-cookie.py <cookie> [refresh_token]                -> stdout: one JSON line
  refresh-cookie.py --confirm <cookie> <prev_refresh_token>  -> confirm only

Refresh mode prints exactly one JSON object and nothing else:
  {"cookie": "...", "refresh_token": "...", "prev_refresh_token": "..."}

prev_refresh_token is the token the caller must pass to --confirm once the new
pair is safely persisted. Confirm invalidates the old token, so it must never
run before the new values are stored.

Every log line goes to stderr; stdout stays machine-readable.
Standard library only.
"""

import base64
import hashlib
import json
import os
import re
import sys
import time
import urllib.parse

# Sibling module; no package install needed.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bilibili_cookie import (  # noqa: E402
    UA,
    dump_cookie,
    get_ci,
    merge_set_cookie,
    parse_cookie,
    request,
)

LOG = sys.stderr

# Published in the BiliBili web bundle; used to build correspondPath.
PUBKEY_B64 = (
    "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDLgd2OAkcGVtoE3ThUREbio0Eg"
    "Uc/prcajMKXvkCKFCWhJYJcLkcM2DKKcSeFpD/j6Boy538YXnR6VhcuUJOhH2x71"
    "nzPjfdTcqMz7djHum0qSZA0AyCBDABUqCrfNgCiJ00Ra7GmRj+YCK1NJEuewlb40"
    "JNrRuoEUXpabUzGB8QIDAQAB"
)


def log(msg):
    LOG.write(msg + "\n")
    LOG.flush()


# --- RSA-OAEP(SHA-256), no third-party crypto ---------------------------------


def _der_tlv(buf, pos):
    tag = buf[pos]
    pos += 1
    length = buf[pos]
    pos += 1
    if length & 0x80:
        count = length & 0x7F
        length = int.from_bytes(buf[pos:pos + count], "big")
        pos += count
    return tag, buf[pos:pos + length], pos + length


def parse_pubkey(b64):
    """Return (n, e) from a base64 PKCS#1 SubjectPublicKeyInfo."""
    _, spki, _ = _der_tlv(base64.b64decode(b64), 0)
    _, _, pos = _der_tlv(spki, 0)  # AlgorithmIdentifier
    tag, bits, _ = _der_tlv(spki, pos)
    if tag != 0x03:
        raise ValueError("公钥格式异常: 缺少 BIT STRING")
    _, rsa_key, _ = _der_tlv(bits[1:], 0)  # strip unused-bits byte
    _, modulus, pos = _der_tlv(rsa_key, 0)
    _, exponent, _ = _der_tlv(rsa_key, pos)
    return int.from_bytes(modulus, "big"), int.from_bytes(exponent, "big")


def mgf1(seed, length):
    out = b""
    counter = 0
    while len(out) < length:
        out += hashlib.sha256(seed + counter.to_bytes(4, "big")).digest()
        counter += 1
    return out[:length]


def oaep_encode(message, size, seed=None):
    """EME-OAEP encoding with SHA-256 and an empty label."""
    digest_len = hashlib.sha256().digest_size
    if len(message) > size - 2 * digest_len - 2:
        raise ValueError("明文过长，无法用该公钥加密")
    label_hash = hashlib.sha256(b"").digest()
    padding = b"\x00" * (size - len(message) - 2 * digest_len - 2)
    db = label_hash + padding + b"\x01" + message
    if seed is None:
        seed = hashlib.sha256(str(time.time_ns()).encode()).digest()
    db_mask = mgf1(seed, size - digest_len - 1)
    masked_db = bytes(a ^ b for a, b in zip(db, db_mask))
    seed_mask = mgf1(masked_db, digest_len)
    masked_seed = bytes(a ^ b for a, b in zip(seed, seed_mask))
    return b"\x00" + masked_seed + masked_db


def correspond_path(timestamp_ms):
    """RSA-OAEP(SHA-256) over "refresh_<ms>", lower-case hex."""
    modulus, exponent = parse_pubkey(PUBKEY_B64)
    size = (modulus.bit_length() + 7) // 8
    block = oaep_encode(b"refresh_%d" % timestamp_ms, size)
    return pow(int.from_bytes(block, "big"), exponent, modulus).to_bytes(size, "big").hex()


# --- BiliBili API -------------------------------------------------------------


def check_login(cookie):
    try:
        raw, _ = request("https://api.bilibili.com/x/web-interface/nav", dump_cookie(cookie))
        data = json.loads(raw)
        if data.get("code") == 0 and (data.get("data") or {}).get("isLogin"):
            info = data["data"]
            log("  [ok] 已登录: %s (UID: %s)" % (info.get("uname", "?"), info.get("mid", "?")))
            return True
        log("  [x] 未登录: code=%s msg=%s" % (data.get("code"), data.get("message")))
        return False
    except Exception as exc:
        log("  [!] 登录校验请求失败: %s" % exc)
        return False


def refresh(cookie, old_token):
    """Run the cookie/refresh handshake; mutate cookie in place, return the new token."""
    csrf = get_ci(cookie, "bili_jct")
    if not csrf:
        raise RuntimeError("Cookie 缺少 bili_jct，无法刷新")

    raw, _ = request(
        "https://passport.bilibili.com/x/passport-login/web/cookie/info?csrf="
        + urllib.parse.quote(csrf),
        dump_cookie(cookie),
    )
    info = json.loads(raw)
    if info.get("code") != 0:
        raise RuntimeError("cookie/info 失败: code=%s msg=%s" % (info.get("code"), info.get("message")))
    log("  [i] cookie/info: refresh=%s" % (info.get("data") or {}).get("refresh"))

    path = correspond_path(int(time.time() * 1000))
    html, _ = request("https://www.bilibili.com/correspond/1/" + path, dump_cookie(cookie))
    match = re.search(r"""id=["']1-name["'][^>]*>([^<]+)<""", html)
    if not match:
        raise RuntimeError("未取到 refresh_csrf，correspondPath 可能已过期")
    refresh_csrf = match.group(1).strip()

    raw, headers = request(
        "https://passport.bilibili.com/x/passport-login/web/cookie/refresh",
        dump_cookie(cookie),
        {
            "csrf": csrf,
            "refresh_csrf": refresh_csrf,
            "source": "main_web",
            "refresh_token": old_token,
        },
    )
    data = json.loads(raw)
    if data.get("code") != 0:
        raise RuntimeError(
            "cookie/refresh 失败: code=%s msg=%s" % (data.get("code"), data.get("message"))
        )

    updated = merge_set_cookie(cookie, headers, log)
    log("  [ok] Cookie 已刷新，更新字段: %s" % (", ".join(updated) or "无"))
    return (data.get("data") or {}).get("refresh_token") or old_token


def confirm(cookie, prev_token):
    csrf = get_ci(cookie, "bili_jct")
    if not csrf:
        log("  [!] Cookie 缺少 bili_jct，跳过 confirm")
        return False
    raw, _ = request(
        "https://passport.bilibili.com/x/passport-login/web/confirm/refresh",
        dump_cookie(cookie),
        {"csrf": csrf, "refresh_token": prev_token},
    )
    data = json.loads(raw)
    if data.get("code") == 0:
        log("  [ok] 旧 refresh_token 已作废")
        return True
    log("  [!] confirm 失败: code=%s msg=%s" % (data.get("code"), data.get("message")))
    return False


# --- entry point --------------------------------------------------------------


def main(argv=None):
    args = list(sys.argv[1:] if argv is None else argv)

    if args and args[0] == "--confirm":
        if len(args) < 3:
            log("ERROR: --confirm 需要 <cookie> <prev_refresh_token>")
            return 2
        ok = confirm(parse_cookie(args[1]), args[2].strip())
        return 0 if ok else 1

    if not args or not args[0].strip():
        log("ERROR: 未传入 Cookie")
        return 2

    cookie = parse_cookie(args[0])
    old_token = args[1].strip() if len(args) > 1 else ""

    missing = [f for f in ("sessdata", "bili_jct", "dedeuserid") if not get_ci(cookie, f)]
    if missing:
        log("ERROR: Cookie 缺少关键字段 %s，请重新获取后更新 COOKIESTR" % ", ".join(missing))
        return 1

    log("=== 登录状态校验 ===")
    check_login(cookie)

    new_token = ""
    prev_token = ""
    if old_token:
        log("=== 刷新 refresh_token ===")
        try:
            new_token = refresh(cookie, old_token)
            prev_token = old_token
        except Exception as exc:
            log("  [!] 刷新失败，沿用当前 Cookie: %s" % exc)
            new_token = ""
    else:
        log("=== 跳过刷新 ===")
        log("  [!] 未提供 REFRESH_TOKEN，只能沿用当前 Cookie")

    json.dump(
        {
            "cookie": dump_cookie(cookie),
            "refresh_token": new_token,
            "prev_refresh_token": prev_token,
        },
        sys.stdout,
    )
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
