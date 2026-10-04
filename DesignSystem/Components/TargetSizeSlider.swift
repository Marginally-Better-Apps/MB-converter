import SwiftUI

struct TargetSizeHeader: View {
    let title: String
    let suggestedMegabytes: [Int]
    let targetSizeBytes: Int64
    var titleFont: Font = .headline
    let onSelect: (Int) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ViewThatFits(in: .horizontal) {
            if !dynamicTypeSize.isAccessibilitySize {
                HStack(spacing: 12) {
                    heading
                    Spacer(minLength: 0)
                    suggestions
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                heading
                suggestions
            }
        }
    }

    private var heading: some View {
        Text(title)
            .font(titleFont)
            .foregroundStyle(Theme.text)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var suggestions: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 6))
        return layout {
            ForEach(suggestedMegabytes, id: \.self) { megabytes in
                let isSelected = abs(targetSizeBytes - Int64(megabytes) * 1_000_000) <= 1
                Button {
                    Haptics.selection()
                    onSelect(megabytes)
                } label: {
                    Text("\(megabytes) MB")
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                        .fixedSize()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .foregroundStyle(isSelected ? Color.white : Theme.tint)
                        .background(isSelected ? Theme.tint : Theme.secondaryFill, in: Capsule())
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Set target size to \(megabytes) megabytes")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

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
                            .font(.title2.weight(.bold))
                            .foregroundStyle(Theme.tint)
                        Button {
                            Haptics.impact(.light)
                            isRemuxInfoPresented = true
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.body)
                                .foregroundStyle(Theme.textMuted)
                                .frame(minWidth: 32, minHeight: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("What is remux?")
                    } else {
                        Text(valueLabel ?? MetadataFormatter.bytes(targetBytes))
                            .font(.title2.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.tint)
                    }
                }

                Spacer(minLength: 0)

                Text(minimumLabel ?? "Min: \(MetadataFormatter.bytes(minimumSizeBytes))")
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.trailing)
            }

            Slider(
                value: $targetFraction,
                in: minimumFraction < 1 ? minimumFraction...1.0 : 0...1,
                onEditingChanged: { isEditing in
                    if !isEditing {
                        Haptics.selection()
                    }
                }
            )
            .disabled(minimumFraction >= 1)
            .tint(Theme.tint)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(valueLabel ?? MetadataFormatter.bytes(targetBytes))

            if let estimatedLabel, !estimatedLabel.isEmpty {
                Text(estimatedLabel)
                    .font(.footnote)
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

/// PNG changes only dimensions. The byte estimate never drives encoding.
struct PNGDimensionsSlider: View {
    @Bindable var viewModel: OutputConfigViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dimensions")
                .font(.headline)
                .foregroundStyle(Theme.text)
            Text(viewModel.pngDimensionsLabel)
                .font(.title2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Theme.tint)
            Slider(value: $viewModel.pngDimensionScale,
                   in: viewModel.pngMinimumScale < 1 ? viewModel.pngMinimumScale...1 : 0...1,
                   onEditingChanged: { editing in if !editing { Haptics.selection() } })
                .disabled(viewModel.pngMinimumScale >= 1)
                .tint(Theme.tint)
                .accessibilityLabel("PNG dimensions")
                .accessibilityValue(viewModel.pngDimensionsLabel)
            Text(viewModel.pngSizeEstimateLabel)
                .font(.footnote)
                .foregroundStyle(Theme.textMuted)
        }
    }
}
