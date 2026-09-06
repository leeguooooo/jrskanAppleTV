#!/bin/bash
# 归档并上传到 TestFlight。
#
# 用 App Store Connect API 密钥做云端自动签名 + 上传，本机不需要在 Xcode 里登录账号，
# 也不需要手工维护证书和描述文件。密钥需要 Admin 或 App Manager 角色。
#
# tvOS / iOS 归档阶段故意不签名：Xcode 归档时的自动签名只会找「开发」描述文件，
# 团队里没有登记对应设备时它建不出来，直接报 "Your team has no devices"。发布签名
# 放到导出阶段做，那一步用 App Store 描述文件，跟设备无关。
#
# Mac Catalyst 相反，必须签名归档：App 沙盒 entitlements 只有在签名时才写进包，
# 无签名归档再导出会被商店打回 "App sandbox not enabled"。团队里登记了一台 Mac，
# 开发描述文件建得出来，所以这条能签。
#
# 环境变量：
#   ASC_KEY_ID      密钥 ID（默认取 ~/.appstoreconnect/private_keys 下唯一的 AuthKey_<ID>.p8）
#   ASC_ISSUER_ID   Issuer ID（默认是 LI GUO 团队的；换团队时覆盖）
#
# App Store Connect 里必须已存在 Bundle ID 为 com.leeguoo.jrskan.tv 的 App 记录，
# xcodebuild 不会替你建。
#
# 用法：Scripts/testflight.sh <tvos|ios|mac|all> [build-number]
#   build-number 缺省用当前 UTC 时间戳（本机与 CI 一致，避免时区导致倒退）；同一批两端用同一个号。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

PLATFORM="${1:?用法: testflight.sh <tvos|ios|all> [build-number]}"
BUILD_NUMBER="${2:-$(date -u +%Y%m%d%H%M)}"

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

# $1 scheme  $2 destination  $3 归档标签（同一 scheme 的两个平台要分开存档）
#                              $4 signed|unsigned
upload_one() {
  local scheme="$1" dest="$2" label="${3:-$1}" mode="${4:-unsigned}"
  local archive="$OUT/$label.xcarchive" log="$OUT/$label.log"
  rm -rf "$archive" "$OUT/$label-export"
  mkdir -p "$OUT"
  local sign=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
  [ "$mode" = signed ] && sign=("${AUTH[@]}")
  echo "==> [$label] 归档 (build $BUILD_NUMBER, $mode)"
  if ! xcodebuild -project JRKANApple.xcodeproj -scheme "$scheme" -configuration Release \
      -destination "$dest" -archivePath "$archive" \
      CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
      "${sign[@]}" archive > "$log" 2>&1; then
    grep -E 'error:' "$log" >&2; echo "[$label] 归档失败，完整日志 $log" >&2; return 1
  fi
  echo "==> [$label] 签名并上传 TestFlight"
  if ! xcodebuild -exportArchive -archivePath "$archive" \
      -exportOptionsPlist Scripts/ExportOptions-TestFlight.plist \
      -exportPath "$OUT/$label-export" "${AUTH[@]}" > "$log.export" 2>&1; then
    grep -E '^error:|error: exportArchive' "$log.export" | cut -c1-300 >&2
    echo "[$label] 上传失败，完整日志 $log.export" >&2; return 1
  fi
  grep -E 'Upload succeeded' "$log.export" | tail -1
}

echo "==> 生成工程"
xcodegen generate >/dev/null

case "$PLATFORM" in
  tvos) upload_one JRKANTV  'generic/platform=tvOS' JRKANTV  unsigned ;;
  ios)  upload_one JRKANiOS 'generic/platform=iOS'  JRKANiOS unsigned ;;
  mac)  upload_one JRKANiOS 'generic/platform=macOS,variant=Mac Catalyst' JRKANMac signed ;;
  all)  upload_one JRKANTV  'generic/platform=tvOS' JRKANTV  unsigned
        upload_one JRKANiOS 'generic/platform=iOS'  JRKANiOS unsigned
        upload_one JRKANiOS 'generic/platform=macOS,variant=Mac Catalyst' JRKANMac signed ;;
  *) echo "未知平台 $PLATFORM" >&2; exit 1 ;;
esac
echo "完成。到 App Store Connect → JRKAN → TestFlight 看处理进度（一般几分钟）。"
