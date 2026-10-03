#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
bash Scripts/TestFormatCapabilities.sh
bash Scripts/TestExtendedConversion.sh
python3 Scripts/TestImageConversion.py
python3 Scripts/TestFFmpegSwiftAdapter.py
