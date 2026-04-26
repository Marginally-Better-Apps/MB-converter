import SwiftUI

struct TargetSizeSlider: View {
    let sourceSizeBytes: Int64
    let minimumSizeBytes: Int64
    var valueLabel: String? = nil
    var minimumLabel: String? = nil
    let estimatedLabel: String?
    let showsRemuxBadge: Bool
    var accessibilityLabel: String = "Target size"
    @Binding var targetFraction: Double
    @State private var isRemuxInfoPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if showsRemuxBadge {
                        Text("Remux")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.primary)
                        Button {
                            Haptics.impact(.light)
                            isRemuxInfoPresented = true
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.textMuted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("What is remux?")
                    } else {
                        Text(valueLabel ?? MetadataFormatter.bytes(targetBytes))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.primary)
                    }
                }

                Spacer(minLength: 0)

                Text(minimumLabel ?? "Target: \(MetadataFormatter.bytes(minimumSizeBytes))")
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.trailing)
            }

            Slider(
                value: $targetFraction,
                in: minimumFraction...1.0,
                onEditingChanged: { isEditing in
                    if !isEditing {
                        Haptics.selection()
                    }
                }
            )
            .tint(Theme.primary)
            .accessibilityLabel(accessibilityLabel)

            if let estimatedLabel, !estimatedLabel.isEmpty {
                Text(estimatedLabel)
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .alert("What is remux?", isPresented: $isRemuxInfoPresented) {
            Button("OK", role: .cancel) {
                Haptics.impact(.light)
            }
        } message: {
            Text("Remux copies compatible streams into the new container without re-encoding (faster, no generation loss). For video, that’s usually the same H.264/HEVC and AAC. For audio output, it applies when the existing codec can live in the target container.")
        }
    }

    private var targetBytes: Int64 {
        max(minimumSizeBytes, Int64(Double(sourceSizeBytes) * targetFraction))
    }

    private var minimumFraction: Double {
        guard sourceSizeBytes > 0 else { return 1 }
        return min(1, max(0, Double(minimumSizeBytes) / Double(sourceSizeBytes)))
    }
}
