#!/bin/zsh
# 发布：编译 → Developer ID 签名 → 公证并装订 app → 打包 DMG → 签名、公证并装订 DMG
# 产物在 dist/字幕提词器-<版本>.dmg
#
# 第一次用之前：
#   1. 钥匙串里装好「Developer ID Application」证书
#   2. 在终端运行一次（会提示输入 Apple ID、Team ID 和 App 专用密码，存进钥匙串）：
#        xcrun notarytool store-credentials subtitle-prompter-notary
#
# 用法：
#   ./release.sh              正式发布（签名 + 公证）
#   ./release.sh --unsigned   只试打包：临时签名、不公证，用来检查 DMG 能不能正常生成
#
# 可用环境变量：
#   SIGN_ID         指定签名证书（默认自动找钥匙串里第一张 Developer ID Application）
#   NOTARY_PROFILE  公证凭据在钥匙串里的名字（默认 subtitle-prompter-notary）
set -e
cd "$(dirname "$0")"

APP="字幕提词器.app"
NAME="字幕提词器"
NOTARY_PROFILE="${NOTARY_PROFILE:-subtitle-prompter-notary}"
UNSIGNED=0
[[ "$1" == "--unsigned" ]] && UNSIGNED=1

step() { print -P "\n%F{green}▶ $1%f" }
fail() { print -P "\n%F{red}✗ $1%f"; exit 1 }

# ---------- 检查 ----------
if (( ! UNSIGNED )); then
  step "检查签名证书"
  if [[ -z "$SIGN_ID" ]]; then
    SIGN_ID=$(security find-identity -v -p codesigning | grep -m1 '"Developer ID Application' | sed -E 's/.*"(.*)"/\1/')
  fi
  [[ -n "$SIGN_ID" ]] || fail "钥匙串里没有「Developer ID Application」证书。
  到 developer.apple.com → Certificates 申请并安装后再运行。"
  echo "使用证书：$SIGN_ID"

  step "检查公证凭据"
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || fail "钥匙串里没有公证凭据「$NOTARY_PROFILE」。先在终端运行：
  xcrun notarytool store-credentials $NOTARY_PROFILE"
  echo "公证凭据可用"
fi

# ---------- 编译 ----------
step "编译"
./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="dist/$NAME-$VERSION.dmg"
mkdir -p dist
echo "版本：$VERSION"

# 提交公证并等待结果；失败时打印苹果返回的日志
notarize() {
  local file="$1" out
  out=$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)
  local sid=$(print -r -- "$out" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')
  local result=$(print -r -- "$out" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')
  echo "公证结果：$result（$sid）"
  if [[ "$result" != "Accepted" ]]; then
    [[ -n "$sid" ]] && xcrun notarytool log "$sid" --keychain-profile "$NOTARY_PROFILE"
    fail "公证没有通过，见上面的日志"
  fi
}

# ---------- 签名并公证 app ----------
if (( UNSIGNED )); then
  step "临时签名（不公证）"
  codesign --force --deep -s - "$APP"
else
  step "签名 app（强化运行时 + 时间戳）"
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
  codesign --verify --strict --verbose=2 "$APP"

  step "公证 app"
  ZIP="dist/$NAME-$VERSION-notarize.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarize "$ZIP"
  rm -f "$ZIP"
  xcrun stapler staple "$APP"
fi

# ---------- 打包 DMG ----------
step "打包 DMG"
STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/$APP"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"

if (( ! UNSIGNED )); then
  step "签名并公证 DMG"
  codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"

  step "Gatekeeper 检查"
  spctl -a -vv --type install "$DMG"
  spctl -a -vv "$APP"
fi

step "完成：$(pwd)/$DMG"
ls -lh "$DMG"
