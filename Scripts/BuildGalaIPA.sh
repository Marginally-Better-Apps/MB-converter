#!/bin/bash
# Builds a development IPA for Gala preview builds: Release optimizations, but with the in-app
# Self-Test (Settings → Diagnostics) and its sample files. Production builds (App Store archives,
# plain Release) leave SELF_TEST off and contain neither.
#
#   Scripts/BuildGalaIPA.sh [build-number] [--publish <gala-app-name>]
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_number="${1:-$(date +%Y%m%d%H%M)}"
publish_name=""
if [ "${2:-}" = "--publish" ]; then publish_name="${3:?--publish needs the Gala app name}"; fi

derived="$repo_root/.build/ReleaseGala"
xcodebuild -project "$repo_root/Converter.xcodeproj" -scheme Converter -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$derived" \
  CODE_SIGNING_ALLOWED=NO SELF_TEST=YES build | tail -1

app="$derived/Build/Products/Release-iphoneos/Converter.app"
[ -d "$app/SelfTestSamples" ] || { echo "Self-test samples missing from the dev build" >&2; exit 1; }

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
mkdir -p "$staging/Payload"
cp -R "$app" "$staging/Payload/"
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $build_number" "$staging/Payload/Converter.app/Info.plist"
ipa="$repo_root/.build/MBConverter-dev-$build_number.ipa"
(cd "$staging" && zip -qry "$ipa" Payload)
echo "Dev IPA (with Self-Test): $ipa"

if [ -n "$publish_name" ]; then
  gala publish "$ipa" --name "$publish_name"
fi
