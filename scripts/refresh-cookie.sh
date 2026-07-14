#!/bin/bash
# BiliBili Cookie 续命脚本
# 访问 B 站首页，从响应 Set-Cookie 头中提取新字段，合并到现有 Cookie
# 原理同 LoginDomainService.SetCookieAsync

set -euo pipefail

OLD_COOKIE="$1"
if [ -z "$OLD_COOKIE" ]; then
    echo "ERROR: 未传入 Cookie" >&2
    exit 1
fi

echo "=> 正在访问 B 站首页..."
HEADERS=$(mktemp)
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -D "$HEADERS" \
    -H "Cookie: $OLD_COOKIE" \
    -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
    -H "Referer: https://www.bilibili.com" \
    "https://www.bilibili.com")

echo "=> 响应状态码: $HTTP_CODE"

if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "302" ] && [ "$HTTP_CODE" != "301" ] && [ "$HTTP_CODE" != "000" ]; then
    echo "ERROR: 访问失败" >&2
    rm "$HEADERS"
    exit 1
fi

# 提取 Set-Cookie 头并用 Python 解析合并
python3 - "$OLD_COOKIE" "$HEADERS" << 'PYEOF'
import sys
from http.cookies import SimpleCookie

old_cookie_str = sys.argv[1]
headers_file = sys.argv[2]

# 解析现有 cookie
old = SimpleCookie()
for item in old_cookie_str.split(';'):
    item = item.strip()
    if '=' in item:
        try:
            old.load(item)
        except:
            pass

# 读取 Set-Cookie 头
set_cookies = []
with open(headers_file, 'r', encoding='utf-8', errors='ignore') as f:
    for line in f:
        if line.lower().startswith('set-cookie:'):
            set_cookies.append(line.split(':', 1)[1].strip())

updated = 0
for sc in set_cookies:
    try:
        new = SimpleCookie()
        new.load(sc)
        for key, morsel in new.items():
            val = morsel.value
            if key.lower() in ('domain', 'path', 'expires', 'max-age', 'httponly', 'secure', 'samesite', 'partitioned', 'priority'):
                continue
            if old.get(key) and old[key].value != val:
                print(f"  [更新] {key}")
                updated += 1
            elif not old.get(key):
                print(f"  [新增] {key}")
                updated += 1
            old[key] = val
    except:
        pass

# 重建 cookie 字符串
new_cookie_str = '; '.join(f"{k}={m.value}" for k, m in old.items())
print(f"=> 共更新 {updated} 个字段")
print(new_cookie_str)
PYEOF

rm "$HEADERS"
