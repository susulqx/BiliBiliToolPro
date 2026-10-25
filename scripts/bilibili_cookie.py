"""Cookie header helpers shared by the BiliBili scripts.

A cookie is kept as an ordered dict of raw name -> value, exactly as it appears
in a "Set-Cookie" / "Cookie" header. Order is preserved so the header we send
stays close to what the browser would send.
"""

import sys
import urllib.parse
import urllib.request
from http.cookies import SimpleCookie

# Set-Cookie attributes that must never be treated as cookie fields.
ATTRS = {
    "domain",
    "path",
    "expires",
    "max-age",
    "httponly",
    "secure",
    "samesite",
    "partitioned",
    "priority",
}


def parse_cookie(raw):
    """Parse a "a=1; b=2" cookie header into an ordered dict of raw values."""
    cookie = {}
    for item in raw.split(";"):
        item = item.strip()
        if not item or "=" not in item:
            continue
        key, value = item.split("=", 1)
        key = key.strip()
        if key:
            cookie[key] = value.strip()
    return cookie


def dump_cookie(cookie):
    return "; ".join("%s=%s" % (k, v) for k, v in cookie.items())


def get_ci(cookie, name):
    """Case-insensitive lookup; BiliBili mixes buvid3/Buvid3."""
    for key, value in cookie.items():
        if key.lower() == name.lower():
            return value
    return None


def set_ci(cookie, name, value):
    """Write through the existing key so the header keeps its original case."""
    for key in cookie:
        if key.lower() == name.lower():
            cookie[key] = value
            return
    cookie[name] = value


def merge_set_cookie(cookie, raw_headers, log=None):
    """Apply Set-Cookie lines onto the cookie dict; return the changed names."""
    updated = []
    for raw in raw_headers:
        one = SimpleCookie()
        try:
            one.load(raw)
        except Exception as exc:
            if log:
                log("  [skip] Set-Cookie 解析失败: %s" % exc)
            continue
        for key, morsel in one.items():
            if key.lower() in ATTRS or morsel.value == "":
                continue
            if get_ci(cookie, key) != morsel.value:
                updated.append(key)
            set_ci(cookie, key, morsel.value)
    return updated


# --- HTTP ---------------------------------------------------------------------

UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 Edg/124.0.0.0"
)


def request(url, cookie_str, form=None):
    """GET (or POST when form is given); return (body text, Set-Cookie lines)."""
    data = urllib.parse.urlencode(form).encode() if form is not None else None
    req = urllib.request.Request(url, data=data, method="POST" if data is not None else "GET")
    if cookie_str:
        req.add_header("Cookie", cookie_str)
    req.add_header("User-Agent", UA)
    req.add_header("Referer", "https://www.bilibili.com")
    if data is not None:
        req.add_header("Content-Type", "application/x-www-form-urlencoded")
    with urllib.request.urlopen(req, timeout=20) as resp:
        raw = resp.read().decode("utf-8", "replace")
        headers = resp.headers.get_all("Set-Cookie") or []
    return raw, headers


def stderr_log(msg):
    sys.stderr.write(msg + "\n")
    sys.stderr.flush()
