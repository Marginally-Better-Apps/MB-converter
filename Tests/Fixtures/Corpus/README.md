# Real-world PDF corpus

Public-domain works of the U.S. Government (17 U.S.C. § 105), downloaded unmodified on 2026-10-23.
`CorpusTests.swift` runs every PDF tool and conversion against them and checks the output content.

| File | Source | Why it's here |
| --- | --- | --- |
| `fda-nutrition-label.pdf` | https://www.fda.gov/media/99331/download | Adobe PDF Library; dense vector art, small type, two-column layout |
| `usgs-streamstats.pdf` | https://pubs.usgs.gov/fs/2017/3046/fs20173046.pdf | CMYK **JPEG 2000** photos and maps, transparency groups, multi-column |
| `usgs-east-carroll.pdf` | https://pubs.usgs.gov/fs/2019/3014/fs20193014.pdf | Print layout with CMYK figures and tables |
| `irs-w4-form.pdf` | https://www.irs.gov/pub/irs-pdf/fw4.pdf | Fillable AcroForm (LiveCycle Designer) |
| `irs-w9-form.pdf` | https://www.irs.gov/pub/irs-pdf/fw9.pdf | Fillable AcroForm, long multi-page instructions |
| `irs-p1544.pdf` | https://www.irs.gov/pub/irs-pdf/p1544.pdf | Antenna House output post-processed by iText |
| `test-pattern.mp4` | Generated: `ffmpeg -f lavfi -i testsrc2=size=480x270:rate=24 -f lavfi -i sine=frequency=330 -t 3` | 3 s H.264/AAC clip for the media flow in the UI tests |

Add a file by dropping it in this folder and adding its expectations to `CorpusTests.swift`.
Only add documents whose license allows redistribution.
