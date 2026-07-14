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

echo "=> 正在访问 B 站首页刷新 Cookie..."

HEADERS=$(mktemp)
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -D "$HEADERS" \
    -H "Cookie: $OLD_COOKIE" \
    -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
    -H "Referer: https://www.bilibili.com" \
    "https://www.bilibili.com")

echo "=> 响应状态码: $HTTP_CODE"

if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "302" ] && [ "$HTTP_CODE" != "301" ]; then
    echo "ERROR: 访问 B 站首页失败，状态码 $HTTP_CODE" >&2
    rm "$HEADERS"
    exit 1
fi

# 提取所有 Set-Cookie 头
SET_COOKIES=$(grep -i '^set-cookie:' "$HEADERS" | sed 's/^set-cookie: //i' | tr -d '\r' | tr -d '\n')
rm "$HEADERS"

if [ -z "$SET_COOKIES" ]; then
    echo "=> 未收到 Set-Cookie 头，Cookie 无需更新"
    echo "$OLD_COOKIE"
    exit 0
fi

echo "=> 收到 Set-Cookie 头，开始合并..."

NEW_COOKIE="$OLD_COOKIE"
UPDATED_COUNT=0

# 逐个处理 Set-Cookie 中的 key=value
echo "$SET_COOKIES" | tr ';' '\n' | grep '=' | while IFS='=' read -r key value; do
    key=$(echo "$key" | tr -d ' ')
    value=$(echo "$value" | tr -d ' ')
    
    # 跳过元属性
    case "$key" in
        Domain|domain|Path|path|Expires|expires|Max-Age|max-age|HttpOnly|Secure|SameSite|samesite|partitioned|Priority|priority)
            continue
            ;;
    esac
    
    if [ -n "$key" ] && [ -n "$value" ]; then
        echo "  -> 更新 $key"
    fi
done

# 用实际方法做替换
NEW_COOKIE="$OLD_COOKIE"
while IFS= read -r sc_line; do
    [ -z "$sc_line" ] && continue
    first_part=$(echo "$sc_line" | cut -d';' -f1)
    key=$(echo "$first_part" | cut -d'=' -f1 | tr -d ' ')
    value=$(echo "$first_part" | cut -d'=' -f2-)
    
    [ -z "$key" ] && continue
    [ -z "$value" ] && continue
    
    case "$key" in
        Domain|domain|Path|path|Expires|expires|Max-Age|max-age|HttpOnly|Secure|SameSite|samesite|partitioned|Priority|priority)
            continue
            ;;
    esac
    
    if echo "$NEW_COOKIE" | grep -qi "$key="; then
        NEW_COOKIE=$(echo "$NEW_COOKIE" | sed -E "s/$key=[^;]*/$key=$value/I")
        echo "  [更新] $key"
        UPDATED_COUNT=$((UPDATED_COUNT + 1))
    else
        NEW_COOKIE="$NEW_COOKIE; $key=$value"
        echo "  [新增] $key"
        UPDATED_COUNT=$((UPDATED_COUNT + 1))
    fi
done <<< "$(echo "$SET_COOKIES" | tr '\n' ' ' | tr -d '\r')"

echo "=> 共更新 $UPDATED_COUNT 个字段"
echo "$NEW_COOKIE"
