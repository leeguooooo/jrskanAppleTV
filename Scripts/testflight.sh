#!/bin/bash
# 归档并上传到 TestFlight。
#
# 用 App Store Connect API 密钥做云端自动签名 + 上传，本机不需要在 Xcode 里登录账号，
# 也不需要手工维护证书和描述文件。密钥需要 Admin 或 App Manager 角色。
#
# 归档阶段不依赖当前机器的开发描述文件。Xcode 27 对 tvOS 的 ad-hoc
# 构建仍会要求 profile，所以先跳过构建签名，再用对应的 entitlements
# 对归档 App 做临时签名；导出时才用 API 密钥取得正式分发签名。
# 必须检查 Apple 登录权限；Mac Catalyst 还要保留沙盒和网络权限。
# 只生成无签名归档会丢失这些权限，不能直接上传。
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

# iPhone Duo 只有用 iOS 27.1+ SDK 构建才会铺满屏幕、工具栏竖排；播放器的半折布局
# （ArrangementView）也只在这个 SDK 里有。旧 SDK 打出来的包在 Duo 上是居中缩着的。
if [ "$PLATFORM" != tvos ]; then
  IOS_SDK=$(xcrun --sdk iphoneos --show-sdk-version)
  if [ "$(printf '%s\n27.1\n' "$IOS_SDK" | sort -V | head -1)" != 27.1 ]; then
    echo "iOS SDK 是 ${IOS_SDK}，iPhone Duo 适配需要 27.1 以上：换 Xcode 27.1+ 或设 DEVELOPER_DIR" >&2
    exit 1
  fi
fi

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
#                              $4 signed|unsigned（unsigned 会在归档后临时签名）
upload_one() {
  local scheme="$1" dest="$2" label="${3:-$1}" mode="${4:-unsigned}"
  local archive="$OUT/$label.xcarchive" log="$OUT/$label.log"
  rm -rf "$archive" "$OUT/$label-export"
  mkdir -p "$OUT"
  local sign=(CODE_SIGNING_ALLOWED=NO)
  [ "$mode" = signed ] && sign=("${AUTH[@]}")
  echo "==> [$label] 归档 (build $BUILD_NUMBER, $mode)"
  if ! xcodebuild -project JRKANApple.xcodeproj -scheme "$scheme" -configuration Release \
      -destination "$dest" -archivePath "$archive" \
      -jobs "${XCODE_JOBS:-2}" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
      "${sign[@]}" archive > "$log" 2>&1; then
    grep -E 'error:' "$log" >&2; echo "[$label] 归档失败，完整日志 $log" >&2; return 1
  fi
  if [ "$mode" = unsigned ]; then
    local app="$archive/Products/Applications/$scheme.app" entitlements="App/JRKANTV.entitlements"
    [ "$label" = JRKANiOS ] && entitlements="App/JRKANiOS.entitlements"
    [ "$label" = JRKANMac ] && entitlements="App/JRKANMac.entitlements"
    /usr/bin/codesign --force --sign - --entitlements "$entitlements" "$app"
    /usr/bin/codesign --verify --strict "$app"
    /usr/bin/codesign -d --entitlements :- "$app" > "$OUT/$label-entitlements.plist" 2>/dev/null
    python3 - "$entitlements" "$OUT/$label-entitlements.plist" <<'PY_VERIFY'
import plistlib, sys
expected, actual = (plistlib.load(open(p, "rb")) for p in sys.argv[1:])
for key, value in expected.items():
    if actual.get(key) != value:
        raise SystemExit("归档签名缺失权限: " + key)
print("归档权限检查通过")
PY_VERIFY
  fi
  echo "==> [$label] 签名并上传 TestFlight"
  # Apple's openrsync launches its peer through PATH; mixing in Homebrew
  # rsync breaks Xcode's --extended-attributes packaging step.
  if ! PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH" xcodebuild -exportArchive -archivePath "$archive" \
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
  mac)  upload_one JRKANiOS 'generic/platform=macOS,variant=Mac Catalyst' JRKANMac unsigned ;;
  all)  upload_one JRKANTV  'generic/platform=tvOS' JRKANTV  unsigned
        upload_one JRKANiOS 'generic/platform=iOS'  JRKANiOS unsigned
        upload_one JRKANiOS 'generic/platform=macOS,variant=Mac Catalyst' JRKANMac unsigned ;;
  *) echo "未知平台 $PLATFORM" >&2; exit 1 ;;
esac
echo "完成。到 App Store Connect → JRKAN → TestFlight 看处理进度（一般几分钟）。"
