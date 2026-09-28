#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/mb-planner-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -swift-version 5 -module-cache-path "$test_dir/module-cache" \
  "$repo_root/Core/Models/VideoColorInfo.swift" \
  "$repo_root/Core/Models/MediaModels.swift" \
  "$repo_root/Core/Conversion/FFmpegEncodingStats.swift" \
  "$repo_root/Core/Conversion/ConversionCore.swift" \
  "$repo_root/Tests/AutoTargetPlannerTests.swift" \
  -o "$test_dir/planner-tests"
"$test_dir/planner-tests"
