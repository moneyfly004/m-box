#!/bin/bash
# 验证「后端认不认 MBox 这个客户端」。
#
# 背景：后端按 UA 前缀查软件名映射表（internal/services/ua_parser.go 的 rules），
# 认不出来就记成 software_name=Unknown —— 后台「软件」列一片 Unknown，
# 设备指纹还会退化成整串 UA 的哈希（升级版本就多一台幽灵设备）。
#
# 用法：
#   MBOX_EMAIL=你的账号 MBOX_PASSWORD=你的密码 bash tool/verify_backend_recognizes_mbox.sh
#   可选 MBOX_BASE=https://dy.moneyfly.top/api/v1（默认值）
#
# 依赖：curl + python3。不改任何数据，只登录一次 + 查一次设备列表。
set -euo pipefail

BASE="${MBOX_BASE:-https://dy.moneyfly.top/api/v1}"
EMAIL="${MBOX_EMAIL:?需要 MBOX_EMAIL}"
PASS="${MBOX_PASSWORD:?需要 MBOX_PASSWORD}"
UA="${MBOX_UA:-MBox/0.0.1 (Macintosh; Mac OS X 26_6)}"

echo "后端: $BASE"
echo "UA  : $UA"

TOKEN=$(curl -s --max-time 25 -X POST "$BASE/auth/login" \
  -H 'Content-Type: application/json' -H "User-Agent: $UA" \
  -d "$(python3 -c 'import json,os,sys; print(json.dumps({"email": os.environ["MBOX_EMAIL"], "password": os.environ["MBOX_PASSWORD"]}))')" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("data") or {}).get("access_token",""))')

if [ -z "$TOKEN" ]; then
  echo "✗ 登录失败（检查账号密码/后端地址）"
  exit 1
fi
echo "✓ 登录成功"

curl -s --max-time 25 -H "Authorization: Bearer $TOKEN" -H "User-Agent: $UA" \
  "$BASE/devices" | python3 -c '
import json, sys
rows = json.load(sys.stdin).get("data") or []
if not rows:
    print("✗ 设备列表为空"); sys.exit(1)
def key(r): return r.get("last_seen") or ""
rows.sort(key=key, reverse=True)
print(f"设备数: {len(rows)}")
for r in rows[:6]:
    sw = r.get("software_name"); ver = r.get("software_version")
    ua = (r.get("user_agent") or "")[:58]
    flag = "✓" if sw and sw != "Unknown" else "✗"
    print("  %s software_name=%-12r version=%-8r last_seen=%s  ua=%s" % (flag, sw, ver, r.get("last_seen"), ua))

# 判定只看**最新一次** MBox 请求的结果：
# 部署之前就已经登记过的老行会一直是 Unknown（那是历史数据，
# 要等对应设备下次拉订阅才会被就地更新），不能拿它判「后端没生效」。
mbox_rows = [r for r in rows if (r.get("user_agent") or "").lower().startswith("mbox")]
if not mbox_rows:
    print("\n? 设备里没有 MBox 记录（先用客户端拉一次订阅再跑本脚本）")
    sys.exit(0)
newest = mbox_rows[0]
sw = newest.get("software_name")
if sw and sw != "Unknown":
    stale = [r for r in mbox_rows if (r.get("software_name") or "Unknown") == "Unknown"]
    print(f"\n✓ 后端已识别 MBox（最新一条 software_name={sw!r}）")
    if stale:
        print(f"  另有 {len(stale)} 条历史行仍是 Unknown —— 那些设备下次拉订阅时会被就地更新，"
              f"也可以在后台手动删掉")
    sys.exit(0)
print("\n✗ 最新的 MBox 请求仍被记成 Unknown —— 后端还没更新（UA 解析里没有 mbox 规则）")
sys.exit(2)
'
