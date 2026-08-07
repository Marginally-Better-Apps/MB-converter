#!/usr/bin/env bash
# Download tylerjonesio/ffmpeg-kit-spm min.v5.1.2.6 xcframeworks (same binaries as legacy Swift).
# SHA256 checksums are pinned from:
# https://github.com/tylerjonesio/ffmpeg-kit-spm/blob/min.v5.1.2.6/Package.swift
#
# Usage:
#   ./scripts/download-ffmpeg-frameworks.sh
#   FF_FRAMEWORKS_DIR=/custom/path ./scripts/download-ffmpeg-frameworks.sh
set -euo pipefail

RELEASE="min.v5.1.2.6"
BASE_URL="https://github.com/tylerjonesio/ffmpeg-kit-spm/releases/download/${RELEASE}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_DIR="${FF_FRAMEWORKS_DIR:-${ROOT_DIR}/modules/ffmpeg-module/ios/Frameworks}"
CACHE_DIR="${FF_FRAMEWORKS_CACHE:-${ROOT_DIR}/.cache/ffmpeg-kit-spm/${RELEASE}}"

# name|sha256
FRAMEWORKS=(
  "ffmpegkit|eb3fa0a08fa7477ab38a8c43af7061e257f623ee58818f397f2db9aba31ef335"
  "libavcodec|10ff17871015a75a83e1d9572d159b3752d47d78a94561ad14805a67b2660684"
  "libavdevice|3dad9b09ba13553e1be34df5ce266a7b2b69c193e15eae3e6f5d5403c34f465a"
  "libavfilter|17159b2cc5a91e7a47b9650f55f55eded9943745b880c90a2a7c4c6ac901abb4"
  "libavformat|ebc5e8ae76a4f5a47a3141abbad562a64a76c4d47d9460ecbcfab84f20487179"
  "libavutil|3b9f6a744ea0c2a5c3b571afac3956616efddfada67b77229830ce0c1c8336d7"
  "libswresample|514647ce7c334dbae57c8fa0892130d4d19bf11b26acac85d750c5842a54e2c7"
  "libswscale|6a93db66a432f1daf38080a5eaff0de93eecc11ffa0d709e07637dc8804fd1f0"
)

sha256_file() {
  local file="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk 'NR==1{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk 'NR==1{print $1}'
  else
    echo "error: need shasum or sha256sum" >&2
    exit 1
  fi
}

mkdir -p "$DEST_DIR" "$CACHE_DIR"

all_present=true
for entry in "${FRAMEWORKS[@]}"; do
  name="${entry%%|*}"
  if [[ ! -d "${DEST_DIR}/${name}.xcframework" ]]; then
    all_present=false
    break
  fi
done

if [[ "$all_present" == true ]]; then
  echo "FFmpeg frameworks already present in ${DEST_DIR}"
  exit 0
fi

echo "Downloading FFmpegKit ${RELEASE} xcframeworks → ${DEST_DIR}"

for entry in "${FRAMEWORKS[@]}"; do
  name="${entry%%|*}"
  expected="${entry##*|}"
  zip_name="${name}.xcframework.zip"
  zip_path="${CACHE_DIR}/${zip_name}"
  out_dir="${DEST_DIR}/${name}.xcframework"

  if [[ -d "$out_dir" ]]; then
    echo "  skip ${name} (already extracted)"
    continue
  fi

  if [[ -f "$zip_path" ]]; then
    actual="$(sha256_file "$zip_path")"
    if [[ "$actual" != "$expected" ]]; then
      echo "  cached ${zip_name} checksum mismatch; re-downloading"
      rm -f "$zip_path"
    fi
  fi

  if [[ ! -f "$zip_path" ]]; then
    echo "  downloading ${zip_name}"
    curl -fL --retry 3 --retry-delay 2 -o "${zip_path}.partial" "${BASE_URL}/${zip_name}"
    mv "${zip_path}.partial" "$zip_path"
  fi

  actual="$(sha256_file "$zip_path")"
  if [[ "$actual" != "$expected" ]]; then
    echo "error: SHA256 mismatch for ${zip_name}" >&2
    echo "  expected: ${expected}" >&2
    echo "  actual:   ${actual}" >&2
    rm -f "$zip_path"
    exit 1
  fi

  echo "  extracting ${zip_name}"
  tmp_extract="${CACHE_DIR}/extract-${name}"
  rm -rf "$tmp_extract"
  mkdir -p "$tmp_extract"
  unzip -q "$zip_path" -d "$tmp_extract"

  extracted="$(find "$tmp_extract" -maxdepth 2 -type d -name "${name}.xcframework" | head -1)"
  if [[ -z "$extracted" ]]; then
    echo "error: ${name}.xcframework not found inside ${zip_name}" >&2
    exit 1
  fi
  rm -rf "$out_dir"
  mv "$extracted" "$out_dir"
  rm -rf "$tmp_extract"
done

echo "Done. Frameworks ready under ${DEST_DIR}"
