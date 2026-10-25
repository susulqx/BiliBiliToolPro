#!/usr/bin/env python3
"""Get BiliBili web cookies and refresh_token by scanning a QR code locally.

Run it on a machine with a terminal:

    python scripts/get-refresh-token.py

It prints a QR code, waits for the BiliBili app to scan and confirm, then prints
the two values the GitHub workflow needs:

    COOKIESTR       full cookie header (SESSDATA / bili_jct / DedeUserID / ...)
    REFRESH_TOKEN   the persistent refresh_token returned by the QR login

Paste them into Settings -> Secrets and variables -> Actions. Only the standard
library is used, so no pip install is required.
"""

import json
import os
import sys
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import qrcodegen  # noqa: E402
from bilibili_cookie import dump_cookie, merge_set_cookie, request  # noqa: E402

GENERATE = "https://passport.bilibili.com/x/passport-login/web/qrcode/generate"
POLL = "https://passport.bilibili.com/x/passport-login/web/qrcode/poll"

# poll data.code values
DONE = 0
EXPIRED = 86038
SCANNED = 86090
WAITING = 86101

POLL_INTERVAL = 2  # seconds; the key itself lives for 180s


def log(msg):
    sys.stderr.write(msg + "\n")
    sys.stderr.flush()


def generate():
    raw, _ = request(GENERATE, "")
    data = json.loads(raw)
    if data.get("code") != 0:
        raise RuntimeError("申请二维码失败: %s %s" % (data.get("code"), data.get("message")))
    return data["data"]["url"], data["data"]["qrcode_key"]


def poll(qrcode_key):
    """Poll until the login finishes; return (cookie dict, refresh_token)."""
    url = POLL + "?" + urllib.parse.urlencode({"qrcode_key": qrcode_key})
    cookie = {}
    state = None
    deadline = time.time() + 180

    while time.time() < deadline:
        raw, headers = request(url, dump_cookie(cookie))
        data = json.loads(raw)
        if data.get("code") != 0:
            raise RuntimeError("轮询失败: %s %s" % (data.get("code"), data.get("message")))
        body = data["data"]
        code = body.get("code")

        if code == WAITING:
            if state != WAITING:
                log("等待扫码...")
                state = WAITING
        elif code == SCANNED:
            if state != SCANNED:
                log("已扫码，请在手机上确认...")
                state = SCANNED
        elif code == DONE:
            merge_set_cookie(cookie, headers, log)
            return cookie, (body.get("refresh_token") or "")
        elif code == EXPIRED:
            raise RuntimeError("二维码已失效，请重新运行脚本")
        else:
            raise RuntimeError("未预期的扫码状态: %s %s" % (code, body.get("message")))

        time.sleep(POLL_INTERVAL)

    raise RuntimeError("二维码超时（180 秒），请重新运行脚本")


def draw(url):
    """Return terminal art for url; pick a charset the console can actually print."""
    matrix = qrcodegen.make(url)
    encoding = sys.stdout.encoding or "ascii"
    try:
        art = qrcodegen.render(matrix, compact=True)
        art.encode(encoding)
    except (UnicodeEncodeError, LookupError):
        art = qrcodegen.render(matrix, compact=False, ascii_only=True)
    return art


def show(url):
    try:
        art = draw(url)
    except Exception as exc:
        log("[!] 无法生成二维码（%s）" % exc)
        print("请在任意二维码工具中生成下面内容的二维码，或直接打开链接：")
        print(url)
        sys.stdout.flush()
        return

    print()
    print(art)
    print()
    print("用哔哩哔哩手机客户端扫码，或直接打开下面的链接：")
    print(url)
    print()
    sys.stdout.flush()


def report(cookie, refresh_token):
    missing = [k for k in ("SESSDATA", "bili_jct", "DedeUserID") if k not in cookie]
    if missing:
        log("[!] 登录返回的 Cookie 缺少 %s，无法用于工作流" % ", ".join(missing))
        return 1

    line = dump_cookie(cookie)
    print("=" * 72)
    print("COOKIESTR")
    print(line)
    print()
    print("REFRESH_TOKEN")
    print(refresh_token or "(空 - 服务端未返回，刷新将退化为只续期 Cookie)")
    print("=" * 72)
    print()
    print("把上面两个值分别写入仓库的 Actions secrets：")
    print("  COOKIESTR      = 第一段完整 Cookie")
    print("  REFRESH_TOKEN  = 第二段 refresh_token")
    return 0


def main():
    log("申请二维码...")
    try:
        url, qrcode_key = generate()
        show(url)
        cookie, refresh_token = poll(qrcode_key)
    except Exception as exc:
        log("ERROR: %s" % exc)
        return 1

    log("登录成功。")
    return report(cookie, refresh_token)


if __name__ == "__main__":
    sys.exit(main())
