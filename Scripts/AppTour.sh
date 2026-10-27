#!/bin/zsh
# AppTour.sh <simulator udid> <output dir> [light|dark|bigtext]
# Screenshots of the app's main screens through the debug launch routes (DEBUG builds only), for
# reviewing the whole app at a glance. Install a Debug build on the simulator first. Make contact
# sheets with: build/AuditSheet <sheet.png> <dir>/*.png (see Scripts/AuditSheets.sh).
set -u
U=${1:?usage: AppTour.sh <udid> <outdir> [light|dark|bigtext]}; OUT=${2:?outdir}; LOOK=${3:-light}
ROOT=${0:A:h}/..
C=$ROOT/Tests/Fixtures/Corpus
S=$ROOT/App/SelfTestSamples
mkdir -p $OUT
xcrun simctl boot $U 2>/dev/null
case $LOOK in
  dark) xcrun simctl ui $U appearance dark ;;
  bigtext) xcrun simctl ui $U content_size accessibility-extra-large ;;
esac
shot() {
  local name=$1; shift
  xcrun simctl terminate $U com.marginallybetter.converter 2>/dev/null
  xcrun simctl launch $U com.marginallybetter.converter -MBNoAnimations 1 "$@" >/dev/null
  sleep 8
  xcrun simctl io $U screenshot $OUT/$name.png >/dev/null 2>&1
}
shot 01-home -MBResetState 1
shot 02-tools-tab -MBRoute tab:tools
shot 03-category-pdf -MBRoute category:pdf
shot 04-history-empty -MBResetState 1 -MBSavedHistory 0 -MBRoute tab:history
shot 05-result-compress -MBResetState 1 -MBSavedHistory 1 -MBRoute result:pdf.compress -MBInputs $C/irs-p1544.pdf
shot 06-history-full -MBSavedHistory 1 -MBRoute tab:history
shot 07-hub-pdf -MBRoute hub -MBInputs $C/usgs-streamstats.pdf
shot 08-hub-docx -MBRoute hub -MBInputs $S/sample.docx
shot 09-media-photo -MBRoute media -MBInputs $C/astronaut-portrait.jpg
shot 10-media-video -MBRoute media -MBInputs $C/test-pattern.mp4
shot 11-tool-meme -MBRoute tool:image.meme -MBInputs $C/astronaut-portrait.jpg
shot 12-tool-organize -MBRoute tool:pdf.organize -MBInputs $C/irs-p1544.pdf
shot 13-tool-compress -MBRoute tool:pdf.compress -MBInputs $C/usgs-streamstats.pdf
shot 14-tool-docx-pdf -MBRoute tool:convert.docx.pdf -MBInputs $S/sample.docx
shot 15-tool-trim -MBRoute tool:video.trim -MBInputs $C/test-pattern.mp4
shot 16-tool-sign -MBRoute tool:pdf.sign -MBInputs $C/irs-w9-form.pdf
shot 17-tool-empty-merge -MBRoute tool:pdf.merge
shot 18-tool-crop -MBRoute tool:image.crop -MBInputs $C/astronaut-portrait.jpg
shot 19-result-photo -MBResetState 1 -MBRoute result:image.compress -MBInputs $C/astronaut-portrait.jpg
shot 20-tool-qr -MBRoute tool:util.qr
shot 21-convert-any -MBRoute tool:convert.any -MBInputs $C/irs-w9-form.pdf
shot 22-split -MBRoute tool:pdf.split -MBInputs $C/irs-p1544.pdf
shot 23-merge-two -MBRoute tool:pdf.merge -MBInputs $C/irs-p1544.pdf,$C/irs-w9-form.pdf
shot 24-protect -MBRoute tool:pdf.protect -MBInputs $C/irs-w9-form.pdf
shot 25-delete -MBRoute tool:pdf.delete -MBInputs $C/irs-p1544.pdf
shot 26-redact -MBRoute tool:pdf.redact -MBInputs $C/irs-w9-form.pdf
shot 27-result-text -MBResetState 1 -MBRoute result:convert.pdf.txt -MBInputs $C/irs-w9-form.pdf
shot 28-opened-file -MBResetState 1 -MBOpenFile $C/irs-w9-form.pdf
xcrun simctl ui $U appearance light
xcrun simctl ui $U content_size large
