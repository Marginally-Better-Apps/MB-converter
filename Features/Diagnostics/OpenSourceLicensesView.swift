import SwiftUI

/// The notices come from the exact framework being distributed, including when
/// a recipient rebuilds it with different codec versions.
struct OpenSourceLicensesView: View {
    private struct Notice: Identifiable {
        let id: String
        let text: String
    }

    private var notices: [Notice] {
        ["MBFFmpegBridge", "MBImageMagickBridge"].flatMap { framework -> [Notice] in
            guard let root = Bundle.main.privateFrameworksURL?
                .appendingPathComponent("\(framework).framework/Licenses"),
                  let enumerator = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: [.isRegularFileKey]
                  ) else { return [] }
            return enumerator.compactMap { element -> Notice? in
                guard let url = element as? URL,
                      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      let text = (try? String(contentsOf: url, encoding: .utf8))
                        ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else { return nil }
                let relativePath = String(url.path.dropFirst(root.path.count + 1))
                return Notice(id: relativePath, text: text)
            }
        }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    var body: some View {
        List {
            Section {
                Text("MB Converter is free software under the GNU General Public License version 3 or later. You can get its complete source code, and the source and build recipes for every bundled library, from the project page below.")
                Text("Video and audio use FFmpeg and x264 under the GNU General Public License version 2 or later, together with LAME, Opus, Vorbis, Ogg, Theora, libvpx, SVT-AV1, libwebp, dav1d and zimg under their own licenses.")
                Text("Image formats use ImageMagick (ImageMagick License) with libpng, libjpeg-turbo, libtiff, libwebp, OpenJPEG, Little CMS, libjxl, Highway and Brotli, each under its own permissive license.")
                Text("This software is based in part on the work of the Independent JPEG Group.")
                Text("Office, OpenDocument and EPUB packages are read and written with ZIPFoundation (MIT License, © Thomas Zoechling).")
                linkRow("FFmpeg project", destination: URL(string: "https://ffmpeg.org")!)
                linkRow("ZIPFoundation", destination: URL(string: "https://github.com/weichsel/ZIPFoundation")!)
                linkRow("App source and build instructions", destination: URL(string: "https://github.com/Marginally-Better-Apps/MB-converter")!)
            }
            Section("Bundled licenses") {
                ForEach(notices) { notice in
                    NavigationLink(notice.id) {
                        ScrollView {
                            Text(notice.text)
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        }
                        .navigationTitle(notice.id)
                        .navigationBarTitleDisplayMode(.inline)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .tint(Theme.tint)
        .navigationTitle("Open Source Licenses")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// An external link styled like Settings: tinted title, trailing arrow.
    private func linkRow(_ title: String, destination: URL) -> some View {
        Link(destination: destination) {
            HStack(spacing: 8) {
                Text(title)
                    .foregroundStyle(Theme.tint)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
    }
}
