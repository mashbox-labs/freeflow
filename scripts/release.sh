#!/bin/bash
# Archive a signed Release build and (with "upload") send it to App Store Connect for TestFlight.
# Nothing account-specific lives in the repo: Configuration/Local.xcconfig sets FF_BUNDLE_PREFIX and
# DEVELOPMENT_TEAM, and Configuration/release.env (git-ignored) sets ASC_KEY_ID, ASC_ISSUER_ID and
# ASC_KEY_PATH (an App Store Connect API key .p8 that this script passes to xcodebuild, never reads).
#   scripts/release.sh check    # archive + export an App Store .ipa locally
#   scripts/release.sh upload   # the same, then upload to App Store Connect
set -euo pipefail
cd "$(dirname "$0")/.."
mode=${1:-check}
[[ "$mode" == check || "$mode" == upload ]] || { echo "Usage: scripts/release.sh check|upload" >&2; exit 2; }
# shellcheck disable=SC1091
source Configuration/release.env
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
# The C++ engine is built from pinned sources (not stored in git) and must match its committed sha256 list.
mkdir -p artifacts
scripts/build-engine.sh ios sim mac > artifacts/build-engine-release.log 2>&1 || { tail -20 artifacts/build-engine-release.log; exit 1; }
scripts/build-engine.sh --check
python3 scripts/generate-project.py
# From build 18 (version 1.1) the build number is the plain build count (TestFlight shows "1.1 (18)"); pass it.
build=${BUILD_NUMBER:?set BUILD_NUMBER to the build count, e.g. BUILD_NUMBER=18}
out=artifacts/release-$build
mkdir -p "$out"
# FF_AUTH=xcode uses the Apple account signed in to Xcode (it can register the App Group, which an API key cannot).
if [[ "${FF_AUTH:-key}" == xcode ]]; then
  auth=(-allowProvisioningUpdates)
else
  auth=(-allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi
xcodebuild -project FreeFlow.xcodeproj -scheme FreeFlow -configuration Release -destination "generic/platform=iOS" \
  -archivePath "$out/FreeFlow.xcarchive" -derivedDataPath artifacts/dd-release CURRENT_PROJECT_VERSION="$build" \
  "${auth[@]}" archive > "$out/archive.log" 2>&1 || { grep -E "error:" "$out/archive.log" | sort -u | head -20; exit 1; }
destination=export
[[ "$mode" == upload ]] && destination=upload
cat > "$out/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>destination</key><string>$destination</string>
<key>signingStyle</key><string>automatic</string>
<key>uploadSymbols</key><true/>
<key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$out/FreeFlow.xcarchive" -exportPath "$out/export" \
  -exportOptionsPlist "$out/ExportOptions.plist" "${auth[@]}" > "$out/export.log" 2>&1 || { grep -E "error|Error" "$out/export.log" | sort -u | head -20; exit 1; }
echo "OK $mode build $build -> $out"
