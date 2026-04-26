import SwiftUI

struct FormatPicker: View {
    let formats: [OutputFormat]
    let inputCategory: MediaCategory
    let isInteractionDisabled: Bool
    @Binding var selection: OutputFormat

    var body: some View {
        Menu {
            if inputCategory == .video {
                if !videoFormats.isEmpty {
                    Section("Video Output") {
                        ForEach(videoFormats) { format in
                            formatButton(format)
                        }
                    }
                }
                if !audioFormats.isEmpty {
                    Section("Audio Output") {
                        ForEach(audioFormats) { format in
                            formatButton(format)
                        }
                    }
                }
            } else {
                ForEach(formats) { format in
                    formatButton(format)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(selection.displayName)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.background)
            .padding(.horizontal, 14)
            .frame(minHeight: 42)
            .background(Theme.primary)
            .clipShape(Capsule())
        }
        .disabled(isInteractionDisabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var videoFormats: [OutputFormat] {
        formats.filter { $0.category == .video }
    }

    private var audioFormats: [OutputFormat] {
        formats.filter { $0.category == .audio }
    }

    @ViewBuilder
    private func formatButton(_ format: OutputFormat) -> some View {
        Button {
            Haptics.selection()
            selection = format
        } label: {
            Text(format.displayName)
        }
    }
}
