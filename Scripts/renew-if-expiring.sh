#!/bin/bash
# TestFlight 构建 90 天过期。查 iOS / tvOS 各自最新一个处理通过的构建，
# 剩余不足 THRESHOLD_DAYS（默认 14）天、或者根本没有构建时，重新归档上传该平台。
# 两边都还早就什么都不做，所以可以每周跑一次而不浪费上传。
#
# 用法：Scripts/renew-if-expiring.sh            # 按到期日判断
#       FORCE=all|ios|tvos Scripts/renew-if-expiring.sh   # 不看到期日，直接上传
# 注意：$VAR 后面紧跟中文时要写成 ${VAR}，runner 上 bash 3.2 在 C locale 下会把中文字节吞进变量名。
# 依赖：Scripts/asc_api.py（python3 + cryptography）、Scripts/testflight.sh 的全部前提。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

APP_ID=6808947990
THRESHOLD_DAYS="${THRESHOLD_DAYS:-14}"
FORCE="${FORCE:-none}"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

# 打印剩余天数；没有可用构建打印 -1
days_left() {
  local platform="$1"
  python3 Scripts/asc_api.py GET \
    "/v1/builds?filter[app]=$APP_ID&filter[preReleaseVersion.platform]=$platform&filter[processingState]=VALID&sort=-uploadedDate&limit=1&fields[builds]=version,expirationDate,expired" \
  | python3 -c '
import json, sys
from datetime import datetime, timezone
d = json.load(sys.stdin)
if "error" in d:
    sys.exit("ASC 查询失败: " + str(d))
builds = [b for b in d.get("data", []) if not b["attributes"].get("expired")]
if not builds:
    print(-1); sys.exit()
exp = datetime.fromisoformat(builds[0]["attributes"]["expirationDate"])
left = (exp - datetime.now(timezone.utc)).total_seconds() / 86400
print(int(left))
print("build", builds[0]["attributes"]["version"], "expires", exp.isoformat(), file=sys.stderr)
'
}

needs_upload() {  # $1 平台名(ios|tvos) $2 ASC 平台枚举
  case "$FORCE" in all|"$1") echo "==> [$1] FORCE=${FORCE}，直接上传"; return 0;; esac
  local left; left=$(days_left "$2")
  if [ "$left" -lt 0 ]; then echo "==> [$1] 没有可用构建，上传"; return 0; fi
  if [ "$left" -le "$THRESHOLD_DAYS" ]; then echo "==> [$1] 剩余 ${left} 天 ≤ ${THRESHOLD_DAYS}，上传"; return 0; fi
  echo "==> [$1] 剩余 ${left} 天，跳过"; return 1
}

uploaded=0
if needs_upload tvos TV_OS; then Scripts/testflight.sh tvos "$BUILD_NUMBER"; uploaded=1; fi
if needs_upload ios IOS;    then Scripts/testflight.sh ios  "$BUILD_NUMBER"; uploaded=1; fi
[ "$uploaded" = 1 ] && echo "已上传构建 ${BUILD_NUMBER}" || echo "无需上传"
