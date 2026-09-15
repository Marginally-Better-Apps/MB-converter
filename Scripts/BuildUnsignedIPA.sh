#!/bin/bash
set -euo pipefail

# Build a device archive, then package an unsigned IPA for re-signing by a sideload tool.
# Usage: BUILD_NUMBER=123 bash Scripts/BuildUnsignedIPA.sh [output-directory]
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_directory="${1:-${project_root}/build/ipa-release}"
mkdir -p "$output_directory"
output_directory="$(cd "$output_directory" && pwd)"
work_directory="$(mktemp -d "${output_directory}/.staging.XXXXXX")"
trap 'rm -rf "$work_directory"' EXIT

build_settings=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=)
if [ -n "${BUILD_NUMBER:-}" ]; then
    if ! [[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
        echo "BUILD_NUMBER must be a positive integer." >&2
        exit 1
    fi
    build_settings+=("CURRENT_PROJECT_VERSION=${BUILD_NUMBER}")
fi

cd "$project_root"
xcodebuild \
    -project Converter.xcodeproj \
    -scheme Converter \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$work_directory/Converter.xcarchive" \
    -derivedDataPath "$project_root/build/DerivedData" \
    -clonedSourcePackagesDirPath "$project_root/build/SourcePackages" \
    -onlyUsePackageVersionsFromResolvedFile \
    "${build_settings[@]}" \
    archive 2>&1 | tee "$output_directory/build.log"

archived_app="$work_directory/Converter.xcarchive/Products/Applications/Converter.app"
payload_app="$work_directory/Payload/Converter.app"
test -d "$archived_app"
mkdir -p "$work_directory/Payload"
/usr/bin/ditto --norsrc --noextattr "$archived_app" "$payload_app"

# Prebuilt dependencies can retain signatures even when Xcode signing is disabled.
# Work only on the copied payload; the sideloading tool will sign every component.
while IFS= read -r -d '' code; do
    if /usr/bin/codesign -d "$code" >/dev/null 2>&1; then
        /usr/bin/codesign --remove-signature "$code"
    fi
done < <(find "$payload_app" -depth \( -name '*.framework' -o -name '*.dylib' -o -name '*.appex' -o -name '*.app' \) -print0)
find "$payload_app" -type d -name _CodeSignature -prune -exec rm -rf {} +
find "$payload_app" -type f -name embedded.mobileprovision -delete

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$payload_app/Info.plist")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$payload_app/Info.plist")"
if ! [[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ && "$build_number" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    echo "Unexpected app version or build number in the archive." >&2
    exit 1
fi
ipa_name="MB-Converter-${version}-${build_number}-unsigned.ipa"
staged_ipa="$work_directory/$ipa_name"
/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$work_directory/Payload" "$staged_ipa"

# Validate the deliverable itself before exposing it to the publishing job.
python3 - "$staged_ipa" <<'PY'
import plistlib
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as ipa:
    assert ipa.testzip() is None, 'IPA contains a corrupt ZIP entry'
    names = ipa.namelist()
    assert all(name.startswith('Payload/') for name in names), 'Unexpected IPA root'
    info = plistlib.loads(ipa.read('Payload/Converter.app/Info.plist'))
    assert info['CFBundleSupportedPlatforms'] == ['iPhoneOS'], 'IPA must contain a device build'
    assert info['CFBundleIdentifier'] == 'com.marginallybetter.converter', 'Wrong app identifier'
    assert ipa.getinfo('Payload/Converter.app/' + info['CFBundleExecutable']).file_size > 0
    plistlib.loads(ipa.read('Payload/Converter.app/PrivacyInfo.xcprivacy'))
    assert not any('/_CodeSignature/' in name or name.endswith('embedded.mobileprovision') for name in names)
    print(f"Validated unsigned IPA: {info['CFBundleShortVersionString']} ({info['CFBundleVersion']})")
PY

mv "$staged_ipa" "$output_directory/$ipa_name"
(
    cd "$output_directory"
    shasum -a 256 "$ipa_name" > "$ipa_name.sha256"
)
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "version=$version"
        echo "build_number=$build_number"
        echo "ipa_name=$ipa_name"
        echo "tag=v${version}-build.${build_number}"
    } >> "$GITHUB_OUTPUT"
fi
echo "IPA ready: $output_directory/$ipa_name"
