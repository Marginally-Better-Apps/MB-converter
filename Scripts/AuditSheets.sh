#!/bin/zsh
# Turns an audit dump (Tests/AuditTests.swift) into labeled contact sheets, one per tool category,
# so every output can be checked by eye. Documents, PDFs, HTML and video are drawn with Quick Look.
#   Scripts/AuditSheets.sh /tmp/mbaudit
set -eu
dump=${1:?usage: AuditSheets.sh <audit dir>}
thumbs="$dump/.thumbs"
rm -rf "$thumbs"; mkdir -p "$thumbs" "${0:A:h}/../build"
for helper in AuditThumb AuditSheet; do
    binary="${0:A:h}/../build/$helper"
    [[ -x $binary && ! ${0:A:h}/$helper.swift -nt $binary ]] || swiftc -O "${0:A:h}/$helper.swift" -o "$binary"
done
: > "$dump/no-preview.txt"
for tool in "$dump"/*(/); do
    name=${tool:t}
    [[ $name == memes || $name == ui || $name == ui-tour ]] && continue
    index=0
    for file in "$tool"/out-*(N); do
        index=$((index + 1))
        perl -e "alarm 30; exec @ARGV" "${0:A:h}/../build/AuditThumb" "$file" "$thumbs/${name}--$index.png" 2>/dev/null \
            || echo "$name: no preview for ${file:t}" >> "$dump/no-preview.txt"
    done
done
sheet="${0:A:h}/../build/AuditSheet"
for category in pdf image convert video audio util doc sheet data; do
    files=("$thumbs"/${category}.*(N.))
    (( ${#files} )) && $sheet "$dump/sheet-$category.png" $files
done
# Tool screens from UITests ToolTourUITests, larger cells so text stays readable.
if [[ -d "$dump/ui-tour" ]]; then
    for category in pdf image convert video audio util; do
        files=("$dump/ui-tour"/${category}.*.png(N))
        (( ${#files} )) && AUDIT_CELL=560 $sheet "$dump/screens-$category.png" $files
    done
fi
echo "Sheets in $dump"; ls "$dump"/sheet-*.png
