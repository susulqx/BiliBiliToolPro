#!/bin/bash
# BiliBili Cookie 续命脚本
# stdout: 只输出最终 Cookie（单行）
# stderr: 所有日志

set -euo pipefail

OLD_COOKIE="$1"
if [ -z "$OLD_COOKIE" ]; then
    echo "ERROR: 未传入 Cookie" >&2
    exit 1
fi

echo "=> 正在访问 B 站首页..." >&2

HEADERS=$(mktemp)
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -D "$HEADERS" \
    -H "Cookie: $OLD_COOKIE" \
    -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
    -H "Referer: https://www.bilibili.com" \
    "https://www.bilibili.com")

echo "=> 响应状态码: $HTTP_CODE" >&2

if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "302" ] && [ "$HTTP_CODE" != "301" ] && [ "$HTTP_CODE" != "000" ]; then
    echo "ERROR: 访问失败" >&2
    rm "$HEADERS"
    # cookie 没变，返回原值
    echo "$OLD_COOKIE"
    exit 0
fi

# Python 解析: stderr=日志, stdout=最终cookie(单行)
python3 - "$OLD_COOKIE" "$HEADERS" << 'PYEOF'
import sys
from http.cookies import SimpleCookie

old_cookie_str = sys.argv[1]
headers_file = sys.argv[2]
log = sys.stderr

old = SimpleCookie()
for item in old_cookie_str.split(';'):
    item = item.strip()
    if '=' in item:
        try:
            old.load(item)
        except:
            pass

set_cookies = []
with open(headers_file, 'r', encoding='utf-8', errors='ignore') as f:
    for line in f:
        if line.lower().startswith('set-cookie:'):
            set_cookies.append(line.split(':', 1)[1].strip())

if not set_cookies:
    log.write("=> 未收到 Set-Cookie 头\n")
    # 输出原 cookie
    print('; '.join(f"{k}={m.value}" for k, m in old.items()))
    sys.exit(0)

log.write("=> 收到 Set-Cookie 头，开始合并...\n")
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
                log.write(f"  [更新] {key}\n")
                updated += 1
            elif not old.get(key):
                log.write(f"  [新增] {key}\n")
                updated += 1
            old[key] = val
    except Exception as e:
        log.write(f"  [跳过] 解析失败: {e}\n")

log.write(f"=> 共更新 {updated} 个字段\n")
# 仅输出 cookie 到 stdout
print('; '.join(f"{k}={m.value}" for k, m in old.items()))
PYEOF

rm "$HEADERS"
