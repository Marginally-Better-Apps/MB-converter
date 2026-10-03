#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/mb-document-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
cat > "$test_dir/Support.swift" <<'SWIFT'
import Foundation
struct FFmpegEncodingDisplayStats { var activity: String? }
protocol Converter: AnyObject {
    func convert(input: MediaFile, config: ConversionConfig, progress: @escaping @Sendable (Double) -> Void, encodingStats: (@Sendable (FFmpegEncodingDisplayStats) -> Void)?) async throws -> ConversionResult
    func cancel()
}
enum ConversionError: Error { case unsupportedConversion, invalidInput(String), engineFailed(String), cancelled }
enum TempStorage { static func url(for format: OutputFormat) -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(format.fileExtension) } }
SWIFT
xcrun swiftc -swift-version 5 -module-cache-path "$test_dir/module-cache" \
  "$repo_root/Core/Models/VideoColorInfo.swift" "$repo_root/Core/Models/MediaModels.swift" \
  "$repo_root/Core/Documents/FileArchive.swift" "$repo_root/Core/Documents/DocumentConverter.swift" \
  "$repo_root/Core/Documents/DataConverter.swift" "$test_dir/Support.swift" \
  "$repo_root/Tests/ExtendedConversionTests.swift" -o "$test_dir/document-tests"
"$test_dir/document-tests"
xcrun swiftc -swift-version 5 -module-cache-path "$test_dir/module-cache" \
  "$repo_root/Core/Models/VideoColorInfo.swift" "$repo_root/Core/Models/MediaModels.swift" \
  "$repo_root/Core/IO/ConversionDraftStore.swift" "$repo_root/Tests/DraftPersistenceTests.swift" -o "$test_dir/draft-tests"
"$test_dir/draft-tests"
xcrun clang "$repo_root/Tests/ResourcePolicyTests.c" -o "$test_dir/resource-tests"
"$test_dir/resource-tests"
