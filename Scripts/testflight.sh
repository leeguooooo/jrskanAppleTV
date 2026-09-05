#!/bin/bash
# 归档并上传到 TestFlight。
#
# 用 App Store Connect API 密钥做云端自动签名 + 上传，本机不需要在 Xcode 里登录账号，
# 也不需要手工维护证书和描述文件。密钥需要 Admin 或 App Manager 角色。
#
# 归档阶段故意不签名：Xcode 归档时的自动签名只会找「开发」描述文件，团队里没有
# 登记 Apple TV 设备时它建不出来，直接报 "Your team has no devices"。发布签名放到
# 导出阶段做，那一步用 App Store 描述文件，跟设备无关。
#
# 环境变量：
#   ASC_KEY_ID      密钥 ID（默认取 ~/.appstoreconnect/private_keys 下唯一的 AuthKey_<ID>.p8）
#   ASC_ISSUER_ID   Issuer ID（默认是 LI GUO 团队的；换团队时覆盖）
#
# App Store Connect 里必须已存在 Bundle ID 为 com.leeguoo.jrskan.tv 的 App 记录，
# xcodebuild 不会替你建。
#
# 用法：Scripts/testflight.sh [build-number]
#   build-number 缺省用当前时间戳，保证每次上传都递增。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

BUILD_NUMBER="${1:-$(date +%Y%m%d%H%M)}"

KEY_DIR="$HOME/.appstoreconnect/private_keys"
if [ -z "${ASC_KEY_ID:-}" ]; then
  KEYS=("$KEY_DIR"/AuthKey_*.p8)
  [ ${#KEYS[@]} -eq 1 ] || { echo "ASC_KEY_ID 未设置且 $KEY_DIR 下不止一个密钥" >&2; exit 1; }
  ASC_KEY_ID=$(basename "${KEYS[0]}" .p8); ASC_KEY_ID=${ASC_KEY_ID#AuthKey_}
fi
KEY_PATH="$KEY_DIR/AuthKey_${ASC_KEY_ID}.p8"
[ -f "$KEY_PATH" ] || { echo "找不到密钥 $KEY_PATH" >&2; exit 1; }
ASC_ISSUER_ID="${ASC_ISSUER_ID:-8f41f165-4ec4-46b7-a529-634b024931f6}"

AUTH=(-allowProvisioningUpdates
      -authenticationKeyPath "$KEY_PATH"
      -authenticationKeyID "$ASC_KEY_ID"
      -authenticationKeyIssuerID "$ASC_ISSUER_ID")
OUT="${TF_OUT:-build/testflight}"
SCHEME=JRKANTV
ARCHIVE="$OUT/$SCHEME.xcarchive"
LOG="$OUT/$SCHEME.log"

echo "==> 生成工程"
xcodegen generate >/dev/null

rm -rf "$ARCHIVE" "$OUT/export"
mkdir -p "$OUT"

echo "==> 归档 (build $BUILD_NUMBER, 未签名)"
if ! xcodebuild -project JRKANApple.xcodeproj -scheme "$SCHEME" -configuration Release \
    -destination 'generic/platform=tvOS' -archivePath "$ARCHIVE" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO archive > "$LOG" 2>&1; then
  grep -E 'error:' "$LOG" >&2; echo "归档失败，完整日志 $LOG" >&2; exit 1
fi

echo "==> 签名并上传 TestFlight"
if ! xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist Scripts/ExportOptions-TestFlight.plist \
    -exportPath "$OUT/export" "${AUTH[@]}" > "$LOG.export" 2>&1; then
  grep -E '^error:|error: exportArchive' "$LOG.export" | cut -c1-300 >&2
  echo "上传失败，完整日志 $LOG.export" >&2; exit 1
fi
grep -E 'Upload succeeded' "$LOG.export" | tail -1
echo "完成。到 App Store Connect → JRKAN → TestFlight 看处理进度（一般几分钟）。"
