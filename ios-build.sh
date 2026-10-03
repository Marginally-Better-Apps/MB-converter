#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
recipe_build_dir="${GALA_BUILD_DIR:-$PWD/build/gala}"
recipe_artifact_dir="${GALA_ARTIFACT_DIR:-$PWD/build/gala-artifacts}"
mkdir -p "$recipe_build_dir" "$recipe_artifact_dir"
python3 Scripts/BuildFFmpeg.py --platform ios --jobs 4
python3 Scripts/VerifyFFmpeg.py
python3 Scripts/VerifyWebP.py
xcodebuild -project Converter.xcodeproj -scheme Converter -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$recipe_build_dir/DerivedData" \
  -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO build
recipe_app="$recipe_build_dir/DerivedData/Build/Products/Release-iphoneos/Converter.app"
recipe_payload="$recipe_build_dir/package"
rm -rf "$recipe_payload"
mkdir -p "$recipe_payload/Payload"
cp -R "$recipe_app" "$recipe_payload/Payload/"
(cd "$recipe_payload" && /usr/bin/zip -qry "$recipe_artifact_dir/MBConverter.ipa" Payload)
