#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/mb-format-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -swift-version 5 -module-cache-path "$test_dir/module-cache" \
  "$repo_root/Core/Models/VideoColorInfo.swift" \
  "$repo_root/Core/Models/MediaModels.swift" \
  "$repo_root/Core/Compatibility/CodecCapability.swift" \
  "$repo_root/Core/Compatibility/FormatMatrix.swift" \
  "$repo_root/Tests/CodecCapabilityTests.swift" \
  -o "$test_dir/format-tests"
"$test_dir/format-tests"
