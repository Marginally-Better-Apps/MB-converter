#!/bin/bash
# Puts real sample files where a person's would be, so UI tests can import them through the
# actual iOS pickers: PDFs/documents in Files ("On My iPhone/MB Converter Samples") and a photo
# and a video in the Photos library.
#
#   Scripts/SeedSimulator.sh [simulator-udid]     (defaults to the booted simulator)
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
udid="${1:-booted}"
samples="$repo_root/App/SelfTestSamples"
corpus="$repo_root/Tests/Fixtures/Corpus"

storage=$(xcrun simctl get_app_container "$udid" com.apple.DocumentsApp groups \
  | awk -F'\t' '$1 == "group.com.apple.FileProvider.LocalStorage" { print $2 }')
if [ -z "$storage" ]; then
  echo "Couldn't find the Files app's local storage on $udid (is it booted?)" >&2
  exit 1
fi
folder="$storage/File Provider Storage/MB Converter Samples"
mkdir -p "$folder"
cp "$corpus/irs-w9-form.pdf" "$corpus/irs-p1544.pdf" "$corpus/fda-nutrition-label.pdf" \
   "$samples/usgs-streamstats.pdf" "$samples/sample.docx" "$samples/sample.xlsx" "$folder/"
echo "Files → On My iPhone → MB Converter Samples: $(ls "$folder" | tr '\n' ' ')"

# Photos: a portrait and a short clip, imported once (re-running doesn't duplicate them).
marker="$storage/.mb-photos-seeded"
if [ ! -f "$marker" ]; then
  xcrun simctl addmedia "$udid" "$samples/astronaut-portrait.jpg" "$samples/test-pattern.mp4"
  touch "$marker"
  echo "Photos: astronaut-portrait.jpg, test-pattern.mp4"
fi
