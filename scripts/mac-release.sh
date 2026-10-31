#!/bin/sh
# Free Flow for Mac: Release build, Developer ID signature with the hardened runtime, DMG, notarization, staple, and
# Gatekeeper checks on the DMG and on the app inside it. Nothing account-specific lives in the repo:
# - the signing identity is the one "Developer ID Application" identity in the dedicated signing keychain
#   (FF_SIGN_KEYCHAIN, default ~/Library/Keychains/freeflow-signing.keychain-db);
# - notarization uses the App Store Connect API key in Configuration/release.env (ASC_KEY_ID, ASC_ISSUER_ID,
#   ASC_KEY_PATH, git-ignored), else the notarytool keychain profile named by FF_NOTARY_PROFILE (default
#   freeflow-notary) in the signing keychain.
#   scripts/mac-release.sh unsigned   # build only (artifacts/mac-<build>/Free Flow.app)
#   scripts/mac-release.sh            # build, sign, notarize and staple the app, DMG, notarize and staple it, check
#   BUILD_NUMBER=N scripts/mac-release.sh package   # the same from sign on, for artifacts/mac-N/Free Flow.app
# FF_MAC=catalyst (build 20 on): the iPhone app built for Mac Catalyst (FreeFlowCatalyst.xcodeproj) with its AppKit
# plug-in, which is signed first, then the app with Catalyst/FreeFlowCatalyst.entitlements.
# Logs under artifacts/mac-<build>/ name the signing identity: they stay on the build machine, never in anything public.
set -eu
cd "$(dirname "$0")/.."
mode=${1:-release}
kind=${FF_MAC:-native}
# FF_TEST_BUILD=1: the same commit built with the test modes (-D FF_TESTS) and signed, for our own checks on this Mac
# only: its own folder (artifacts/mac-<build>-test), never notarized, never a DMG, never shipped (security).
test=${FF_TEST_BUILD:-0}
if [ "$kind" = catalyst ]; then
  gen=scripts/generate-catalyst-project.py; proj=FreeFlowCatalyst.xcodeproj; dest="generic/platform=macOS,variant=Mac Catalyst"
  dd=artifacts/dd-catrel; [ "$test" = 1 ] && dd=artifacts/dd-catrel-test
  products=$dd/Build/Products/Release-maccatalyst; ent=Catalyst/FreeFlowCatalyst.entitlements
else
  gen=scripts/generate-mac-project.py; proj=FreeFlowMac.xcodeproj; dest="generic/platform=macOS"
  dd=artifacts/dd-mac; products=$dd/Build/Products/Release; ent=Mac/FreeFlowMac.entitlements
fi
plugin="Contents/PlugIns/FreeFlowMacBridge.bundle"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
free_gb() { df -k / | awk 'NR==2 {printf "%d", $4 / 1024 / 1024}'; }
# The build machine keeps 15 GB free or more; a release build with warm derived data takes well under 1 GB.
[ "$(free_gb)" -ge 16 ] || { echo "STOP: $(free_gb) GB free; this build needs the Mac at 16 GB or more first" >&2; exit 1; }
build=${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}
out=artifacts/mac-$build
[ "$test" = 1 ] && out=artifacts/mac-$build-test
testflag=""; [ "$test" = 1 ] && testflag="-D FF_TESTS"
app="$out/Free Flow.app"
if [ "$mode" = package ]; then
  [ -n "${BUILD_NUMBER:-}" ] && [ -d "$app" ] || { echo "STOP: package needs BUILD_NUMBER and $app from an earlier build" >&2; exit 1; }
else
scripts/build-engine.sh --check
python3 $gen
mkdir -p "$out"
# No build paths from the build machine in the app: Swift (#file, debug info) and C sources, the local packages and DerivedData all
# live under the repo, which maps to /freeflow. The app's executable is stripped below (debug and local symbols, so no
# object-file paths) and its dSYM stays here, never in the DMG. Packages' object files are not stripped (strip can't).
root=$PWD
xcodebuild -project $proj -scheme FreeFlowMac -configuration Release -destination "$dest" \
  -derivedDataPath $dd CURRENT_PROJECT_VERSION="$build" \
  OTHER_SWIFT_FLAGS="\$(inherited) -file-prefix-map $root=/freeflow $testflag" OTHER_CFLAGS="\$(inherited) -ffile-prefix-map=$root=/freeflow" \
  DEBUG_INFORMATION_FORMAT=dwarf-with-dsym \
  build > "$out/build.log" 2>&1 \
  || { grep -E "error:" "$out/build.log" | sort -u | head -30; exit 1; }
rm -rf "$app" "$out/Free Flow.app.dSYM"
[ -d "$products/Free Flow.app.dSYM" ] && ditto "$products/Free Flow.app.dSYM" "$out/Free Flow.app.dSYM"
ditto --norsrc --noextattr --noacl "$products/Free Flow.app" "$app"
chmod -R u+rwX,go+rX,go-w "$app"
xcrun strip -S -x "$app/Contents/MacOS/Free Flow"
[ -d "$app/$plugin" ] && xcrun strip -S -x "$app/$plugin/Contents/MacOS/FreeFlowMacBridge"
fi
ver=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
echo "built $app ($ver, build $build); $(free_gb) GB free"
[ "$mode" = unsigned ] && exit 0

K=${FF_SIGN_KEYCHAIN:-$HOME/Library/Keychains/freeflow-signing.keychain-db}
[ -f "$K" ] || { echo "STOP: no signing keychain at $K" >&2; exit 1; }
security unlock-keychain -p "" "$K" 2>/dev/null || true
id=$(security find-identity -v -p codesigning "$K" | awk '/Developer ID Application/ {print $2; exit}')
[ -n "$id" ] || { echo "STOP: no Developer ID Application identity in $K" >&2; exit 1; }
# codesign finds an identity only in a keychain on the search list: add the signing keychain for this run, then put the
# list back exactly as it was.
orig=$(security list-keychains -d user | tr -d '"' | xargs)
trap 'security list-keychains -d user -s $orig' EXIT
# shellcheck disable=SC2086
security list-keychains -d user -s $orig "$K"
: > "$out/sign.log"
# Inside out: the plug-in (it runs in the app's process, so the app's entitlements apply to it), then the app.
if [ -d "$app/$plugin" ]; then
  codesign --force --timestamp --options runtime --keychain "$K" --sign "$id" "$app/$plugin" >> "$out/sign.log" 2>&1
fi
codesign --force --timestamp --options runtime --keychain "$K" --entitlements $ent --sign "$id" "$app" >> "$out/sign.log" 2>&1
codesign --verify --strict --deep --verbose=2 "$app" >> "$out/sign.log" 2>&1
codesign -d --entitlements :- "$app" > "$out/entitlements.plist" 2>/dev/null
echo "signed (hardened runtime)"
[ "$test" = 1 ] && { echo "test build: signed, not notarized, not packaged ($app)"; exit 0; }

# notarize FILE TAG: the App Store Connect API key in Configuration/release.env, else the keychain profile; stops unless
# the notary service accepts it. The result is in $out/notary-TAG.json.
notarize() {
  how=no
  if [ -f Configuration/release.env ]; then
    # shellcheck disable=SC1091
    . Configuration/release.env
    if [ -n "${ASC_KEY_PATH:-}" ] && [ -f "${ASC_KEY_PATH:-}" ]; then
      if xcrun notarytool submit "$1" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait \
           --output-format json > "$out/notary-$2.json" 2> "$out/notary-$2.err" && grep -q '"status":"Accepted"' "$out/notary-$2.json"; then
        how=asc-key
      fi
    fi
  fi
  if [ "$how" = no ]; then
    xcrun notarytool submit "$1" --keychain-profile "${FF_NOTARY_PROFILE:-freeflow-notary}" --keychain "$K" --wait --output-format json \
      > "$out/notary-$2.json" 2>> "$out/notary-$2.err" || true
    grep -q '"status":"Accepted"' "$out/notary-$2.json" && how=keychain-profile
  fi
  [ "$how" != no ] || { echo "STOP: notarization of the $2 not accepted (see $out/notary-$2.json, notary-$2.err)" >&2; exit 1; }
  echo "notarized the $2 ($how)"
}

# The app gets its own stapled ticket before it goes in the DMG, so a copy dragged to Applications also opens offline
# on first launch (a ticket stapled only to the DMG covers the DMG).
zip="$out/FreeFlow-app.zip"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
notarize "$zip" app
rm -f "$zip"
xcrun stapler staple "$app" > "$out/staple.log" 2>&1
xcrun stapler validate "$app" >> "$out/staple.log" 2>&1

dmg="$out/FreeFlow-$ver.dmg"
stage="$out/dmg-stage"
rm -rf "$stage" "$dmg"
mkdir -p "$stage"
ditto --norsrc --noextattr --noacl "$app" "$stage/Free Flow.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "Free Flow" -srcfolder "$stage" -ov -format UDZO "$dmg" > "$out/hdiutil.log" 2>&1
rm -rf "$stage"
codesign --force --timestamp --keychain "$K" --sign "$id" "$dmg" >> "$out/sign.log" 2>&1

notarize "$dmg" dmg
xcrun stapler staple "$dmg" >> "$out/staple.log" 2>&1
xcrun stapler validate "$dmg" >> "$out/staple.log" 2>&1
spctl -a -vvv -t install "$dmg" > "$out/spctl.log" 2>&1
# The app as a user gets it: from the mounted DMG.
mnt="$out/mnt"
mkdir -p "$mnt"
hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mnt" "$dmg" > /dev/null
check=ok
spctl -a -vvv -t exec "$mnt/Free Flow.app" >> "$out/spctl.log" 2>&1 || check=fail
xcrun stapler validate "$mnt/Free Flow.app" >> "$out/spctl.log" 2>&1 || check=fail
codesign --verify --strict --deep "$mnt/Free Flow.app" >> "$out/spctl.log" 2>&1 || check=fail
hdiutil detach "$mnt" > /dev/null
rmdir "$mnt"
[ "$check" = ok ] || { echo "STOP: Gatekeeper refused the app inside the DMG (see $out/spctl.log)" >&2; exit 1; }
shasum -a 256 "$dmg" | tee "$out/FreeFlow-$ver.dmg.sha256"
echo "done: $dmg ($(free_gb) GB free)"
