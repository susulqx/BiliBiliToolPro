#!/bin/bash
# BiliBili Cookie 续命 & 完整性检测脚本
# stdout: 只输出最终 Cookie（单行）
# stderr: 所有日志

set -euo pipefail

OLD_COOKIE="$1"
if [ -z "$OLD_COOKIE" ]; then
    echo "ERROR: 未传入 Cookie" >&2
    exit 1
fi

USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

# Python 做所有 Cookie 解析和检测
python3 - "$OLD_COOKIE" "$USER_AGENT" << 'PYEOF'
import sys
import json
import subprocess
from http.cookies import SimpleCookie

old_cookie_str = sys.argv[1]
ua = sys.argv[2]
log = sys.stderr

# ---- 1. 解析现有 Cookie ----
cookie = SimpleCookie()
for item in old_cookie_str.split(';'):
    item = item.strip()
    if '=' in item:
        try:
            cookie.load(item)
        except:
            pass

fields = {k.lower(): m.value for k, m in cookie.items()}

# ---- 2. 完整性检测 ----
REQUIRED = ['sessdata', 'bili_jct', 'dedeuserid']
NICE = ['buvid3', 'buvid4']

log.write("=== Cookie 完整性检测 ===\n")
missing = []
for f in REQUIRED:
    if f in fields:
        log.write(f"  [√] {f}: {fields[f][:8]}...\n")
    else:
        log.write(f"  [×] {f}: 缺失！\n")
        missing.append(f)

for f in NICE:
    if f in fields:
        log.write(f"  [√] {f}: {fields[f][:8]}...\n")
    else:
        log.write(f"  [!] {f}: 缺失（非关键）\n")

if missing:
    log.write(f"\n  !!! 缺少关键字段: {', '.join(missing)}\n")
    log.write("  !!! 请在浏览器 F12 → Application → Cookies 获取完整 Cookie\n")
    log.write("  !!! 或运行 dotnet run --runTasks=Login 扫码登录\n")
    # 即使缺失，也输出原 cookie（让下游报错而不是静默）
    print('; '.join(f"{k}={m.value}" for k, m in cookie.items()))
    sys.exit(0)

log.write("  => Cookie 完整性通过\n")

# ---- 3. 调用 B 站 API 验证登录有效性 ----
log.write("\n=== 登录状态验证 ===\n")
try:
    result = subprocess.run(
        ['curl', '-s', '-w', '\n%{http_code}',
         '-H', f'Cookie: {old_cookie_str}',
         '-H', f'User-Agent: {ua}',
         '-H', 'Referer: https://www.bilibili.com',
         'https://api.bilibili.com/x/web-interface/nav'],
        capture_output=True, text=True, timeout=15
    )
    output = result.stdout.strip()
    lines = output.rsplit('\n', 1)
    body = lines[0] if len(lines) > 1 else output
    status = lines[-1] if len(lines) > 1 else '0'

    data = json.loads(body)
    code = data.get('code', -1)
    
    if code == 0 and data.get('data', {}).get('isLogin'):
        uname = data['data'].get('uname', '?')
        mid = data['data'].get('mid', '?')
        log.write(f"  [√] 已登录: {uname} (UID: {mid})\n")
    elif code == -101:
        log.write(f"  [×] 未登录！SESSDATA 已过期或无效\n")
        log.write("  => 请重新获取 Cookie 后更新 COOKIESTR Secret\n")
        log.write("  => F12 → Application → Cookies → 复制 SESSDATA 等字段\n")
    else:
        log.write(f"  [?] 状态异常: code={code}, msg={data.get('message','?')}\n")
except Exception as e:
    log.write(f"  [!] 验证请求失败: {e}\n")

# ---- 4. 访问首页获取 Set-Cookie 刷新 ----
log.write("\n=== Cookie 续命 ===\n")
HEADERS_FILE = '/tmp/bili_headers'

subprocess.run(
    ['curl', '-s', '-o', '/dev/null', '-w', '%{http_code}',
     '-D', HEADERS_FILE,
     '-H', f'Cookie: {old_cookie_str}',
     '-H', f'User-Agent: {ua}',
     '-H', 'Referer: https://www.bilibili.com',
     'https://www.bilibili.com'],
    capture_output=True, timeout=15
)

set_cookie_lines = []
try:
    with open(HEADERS_FILE, 'r', encoding='utf-8', errors='ignore') as f:
        for line in f:
            if line.lower().startswith('set-cookie:'):
                set_cookie_lines.append(line.split(':', 1)[1].strip())
except:
    pass

if not set_cookie_lines:
    log.write("=> 未收到 Set-Cookie 头\n")
    print('; '.join(f"{k}={m.value}" for k, m in cookie.items()))
    sys.exit(0)

log.write("=> 收到 Set-Cookie 头，合并...\n")
updated = 0
for sc in set_cookie_lines:
    try:
        new = SimpleCookie()
        new.load(sc)
        for key, morsel in new.items():
            val = morsel.value
            if key.lower() in ('domain', 'path', 'expires', 'max-age', 'httponly', 'secure', 'samesite', 'partitioned', 'priority'):
                continue
            if cookie.get(key) and cookie[key].value != val:
                log.write(f"  [更新] {key}: {cookie[key].value[:8]}... → {val[:8]}...\n")
                updated += 1
            elif not cookie.get(key):
                log.write(f"  [新增] {key}: {val[:8]}...\n")
                updated += 1
            cookie[key] = val
    except Exception as e:
        log.write(f"  [跳过] 解析失败: {e}\n")

log.write(f"=> 共更新 {updated} 个字段\n")

# 输出最终 cookie
print('; '.join(f"{k}={m.value}" for k, m in cookie.items()))
PYEOF
