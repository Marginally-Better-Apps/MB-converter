#!/bin/bash
set -euo pipefail

# App Store validation rejects arm64e slices built with older iOS SDKs.
# Some prebuilt FFmpegKit binaries include arm64e even though arm64 is enough.
if [ "${PLATFORM_NAME:-}" != "iphoneos" ]; then
    exit 0
fi

strip_arm64e() {
    local binary="$1"

    if [ ! -f "$binary" ]; then
        return 1
    fi

    if ! /usr/bin/lipo -info "$binary" 2>/dev/null | /usr/bin/grep -qw "arm64e"; then
        return 1
    fi

    echo "Stripping arm64e from $binary"
    local stripped="${binary}.stripped"
    /usr/bin/lipo -remove arm64e "$binary" -output "$stripped"
    /bin/mv "$stripped" "$binary"
}

resign_framework() {
    local framework="$1"
    local signing_identity="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}"

    if [ "${CODE_SIGNING_ALLOWED:-NO}" != "YES" ] || [ -z "$signing_identity" ]; then
        return 0
    fi

    echo "Re-signing $framework"
    /usr/bin/codesign --force --sign "$signing_identity" --preserve-metadata=identifier,entitlements "$framework"
}

strip_frameworks() {
    local frameworks_dir="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"

    if [ ! -d "$frameworks_dir" ]; then
        return 0
    fi

    while IFS= read -r -d "" framework; do
        local info_plist="${framework}/Info.plist"
        local framework_name
        local executable
        local binary

        framework_name="$(/usr/bin/basename "$framework" .framework)"
        executable="$framework_name"

        if [ -f "$info_plist" ]; then
            executable="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$info_plist" 2>/dev/null || echo "$framework_name")"
        fi

        binary="${framework}/${executable}"

        if strip_arm64e "$binary"; then
            resign_framework "$framework"
        fi
    done < <(/usr/bin/find "$frameworks_dir" -maxdepth 1 -type d -name "*.framework" -print0)
}

strip_dsyms() {
    local dsym_dir="${DWARF_DSYM_FOLDER_PATH:-}"

    if [ -z "$dsym_dir" ] || [ ! -d "$dsym_dir" ]; then
        return 0
    fi

    while IFS= read -r -d "" dsym_binary; do
        strip_arm64e "$dsym_binary" || true
    done < <(/usr/bin/find "$dsym_dir" -path "*.framework.dSYM/Contents/Resources/DWARF/*" -type f -print0)
}

strip_frameworks
strip_dsyms
