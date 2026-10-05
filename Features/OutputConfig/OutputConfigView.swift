import SwiftUI

/// Output format and tuning controls shared by the convert screen.
struct OutputConfigForm: View {
    @Bindable var viewModel: OutputConfigViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var focusedDimension: CustomDimension?
    let isMenuInteractionDisabled: Bool
    var showsPrimaryControls = true
    var showsConvertButton = true
    var onConvert: () -> Void

    var body: some View {
        Form {
            if showsPrimaryControls, viewModel.shouldShowPNGDimensions {
                Section { PNGDimensionsSlider(viewModel: viewModel) }
            }

            if showsPrimaryControls, viewModel.shouldShowTargetSize, !viewModel.isAudioOutput {
                Section {
                    targetSizeSection
                }
            }

            if showsPrimaryControls
                || viewModel.shouldShowResolution
                || viewModel.shouldShowFPS
                || viewModel.shouldShowVideoOutputAudio {
                Section("Output Options") {
                    if showsPrimaryControls {
                        optionRow("Format") {
                            FormatPicker(
                                formats: viewModel.formats,
                                inputCategory: viewModel.input.category,
                                selection: $viewModel.selectedFormat
                            )
                            .disabled(isMenuInteractionDisabled)
                        }
                    }

                    if viewModel.shouldShowResolution {
                        optionRow("Resolution") {
                            resolutionPicker
                        }
                    }

                    if viewModel.shouldShowFPS {
                        optionRow("FPS") {
                            fpsPicker
                        }
                    }

                    if viewModel.shouldShowVideoOutputAudio {
                        optionRow("Audio") {
                            videoAudioQualitySection
                        }
                    }
                }
            }

            if viewModel.shouldShowResolution, viewModel.selectedResolutionID == "custom" {
                customSizeSection
            }

            if showsPrimaryControls, viewModel.shouldShowTargetSize, viewModel.isAudioOutput {
                Section {
                    targetSizeSection
                }
            }

            if !showsPrimaryControls, viewModel.shouldShowSinglePassVideoTargetToggle {
                Section("Encoding") {
                    singlePassVideoTargetToggle
                }
            }

            if showsPrimaryControls, viewModel.shouldShowWebPQuality {
                Section("Quality") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("WebP Quality")
                                .font(.headline)
                                .foregroundStyle(Theme.text)
                            Spacer()
                            Text("\(Int((viewModel.webpQuality * 100).rounded()))%")
                                .font(.title3.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.tint)
                        }

                        Slider(
                            value: $viewModel.webpQuality,
                            in: 0...1,
                            step: 0.01,
                            onEditingChanged: { isEditing in
                                if !isEditing {
                                    Haptics.selection()
                                }
                            }
                        )
                        .tint(Theme.tint)

                        Text("Single-pass encode. Faster than target-size tuning, but final file size is not guaranteed.")
                            .font(.footnote)
                            .foregroundStyle(Theme.textMuted)
                    }
                }
            } else if showsPrimaryControls, !viewModel.shouldShowPNGDimensions, let note = viewModel.losslessNote {
                Section("Target Size") {
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if showsConvertButton {
                Section {
                    Button {
                        Haptics.impact(.medium)
                        onConvert()
                    } label: {
                        PrimaryActionLabel(title: "Convert", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .glassButtonStyle(prominent: true)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .tint(Theme.tint)
                    .disabled(!viewModel.canConvert)
                    .accessibilityLabel("Convert")
                }
            }
        }
        .tint(Theme.tint)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            // The number pad has no return key.
            ToolbarItemGroup(placement: .keyboard) {
                if focusedDimension != nil {
                    Spacer()
                    Button("Done") { focusedDimension = nil }
                        .fontWeight(.semibold)
                }
            }
        }
        .task { await viewModel.loadDiscoveredMetadataIfNeeded() }
        .task(id: viewModel.pngBaselineRequest) { await viewModel.preparePNGBaseline() }
    }

    private var videoAudioQualitySection: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))

        return layout {
            PopoverDropdown(
                title: viewModel.videoAudioQualitySelectionLabel,
                accessibilityLabel: "Audio quality",
                options: viewModel.videoAudioQualityOptions,
                optionTitle: { $0 == .auto ? viewModel.videoAudioSourceLabel : $0.label },
                isSelected: { $0 == viewModel.videoOutputAudioQuality },
                onSelect: { viewModel.videoOutputAudioQuality = $0 }
            )
            .disabled(isMenuInteractionDisabled)
            .frame(maxWidth: .infinity, alignment: .leading)

            if viewModel.isAutoTargetMode {
                lockButton(
                    isLocked: $viewModel.isAudioQualityLocked,
                    label: "Lock audio quality"
                )
            }
        }
    }

    private var resolutionPicker: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))

        return layout {
            PopoverDropdown(
                title: viewModel.resolutionOptions.first(where: { $0.id == viewModel.selectedResolutionID })?.label ?? "Resolution",
                accessibilityLabel: "Resolution",
                options: viewModel.resolutionOptions,
                optionTitle: { $0.label },
                isSelected: { $0.id == viewModel.selectedResolutionID },
                onSelect: { viewModel.selectResolution($0) }
            )
            .disabled(isMenuInteractionDisabled)
            .frame(maxWidth: .infinity, alignment: .leading)

            if viewModel.isAutoTargetMode {
                lockButton(
                    isLocked: $viewModel.isResolutionLocked,
                    label: "Lock resolution"
                )
            }
        }
    }

    private var customSizeSection: some View {
        Section {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                : AnyLayout(HStackLayout(alignment: .bottom, spacing: 10))

            layout {
                customDimensionField("Width", value: viewModel.customWidthText,
                                     maximum: viewModel.customDimensionLimit?.width,
                                     onChange: viewModel.updateCustomWidth)
                    .focused($focusedDimension, equals: .width)

                if !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: viewModel.preservesCustomAspectRatio ? "link" : "multiply")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(viewModel.preservesCustomAspectRatio ? Theme.tint : Theme.textMuted)
                        .frame(height: 40)
                        .contentTransition(.symbolEffect(.replace))
                        .accessibilityHidden(true)
                }

                customDimensionField("Height", value: viewModel.customHeightText,
                                     maximum: viewModel.customDimensionLimit?.height,
                                     onChange: viewModel.updateCustomHeight)
                    .focused($focusedDimension, equals: .height)
            }
            .padding(.vertical, 4)

            Button {
                Haptics.selection()
                viewModel.preservesCustomAspectRatio.toggle()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: viewModel.preservesCustomAspectRatio ? "checkmark.square.fill" : "square")
                        .font(.title3)
                        .foregroundStyle(viewModel.preservesCustomAspectRatio ? Theme.tint : Theme.textMuted)
                        .contentTransition(.symbolEffect(.replace))
                        .accessibilityHidden(true)
                    Text("Preserve aspect ratio")
                        .foregroundStyle(Theme.text)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(viewModel.preservesCustomAspectRatio ? "On" : "Off")
            .accessibilityIdentifier("customResolutionPreserveAspectRatio")
        } header: {
            Text("Custom Size")
        } footer: {
            if let limit = viewModel.customDimensionLimit {
                Text("Up to \(Int(limit.width.rounded())) × \(Int(limit.height.rounded())), the original size.")
            }
        }
    }

    private var fpsPicker: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))

        return layout {
            PopoverDropdown(
                title: viewModel.fpsOptions.first(where: { $0.value == viewModel.selectedFPS })?.label ?? "Original",
                accessibilityLabel: "FPS",
                options: viewModel.fpsOptions,
                optionTitle: { $0.label },
                isSelected: { $0.value == viewModel.selectedFPS },
                onSelect: { viewModel.selectedFPS = $0.value }
            )
            .disabled(isMenuInteractionDisabled)
            .frame(maxWidth: .infinity, alignment: .leading)

            if viewModel.isAutoTargetMode {
                lockButton(
                    isLocked: $viewModel.isFPSLocked,
                    label: "Lock FPS"
                )
            }
        }
    }

    private func lockButton(isLocked: Binding<Bool>, label: String) -> some View {
        Button {
            Haptics.impact(.light)
            isLocked.wrappedValue.toggle()
        } label: {
            Image(systemName: isLocked.wrappedValue ? "lock.fill" : "lock.open")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isLocked.wrappedValue ? Color.white : Theme.tint)
                .frame(width: 40, height: 40)
                .background(isLocked.wrappedValue ? Theme.tint : Theme.secondaryFill, in: Circle())
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isLocked.wrappedValue ? "Locked" : "Unlocked")
    }

    private var targetSizeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            TargetSizeHeader(
                title: viewModel.targetControlTitle,
                suggestedMegabytes: viewModel.suggestedTargetSizesMB,
                targetSizeBytes: viewModel.targetSizeBytes,
                titleFont: .title3.bold(),
                onSelect: viewModel.applyTargetSizeSuggestion
            )

            if viewModel.shouldShowSinglePassVideoTargetToggle {
                singlePassVideoTargetToggle
            }

            VStack(alignment: .leading, spacing: 12) {
                TargetSizeSlider(
                    sourceSizeBytes: viewModel.targetSizeSliderReferenceBytes,
                    minimumSizeBytes: viewModel.targetMinimumSizeBytes,
                    valueLabel: viewModel.targetControlValueLabel,
                    minimumLabel: viewModel.targetControlMinimumLabel,
                    estimatedLabel: viewModel.shouldShowTargetSizeEstimate ? viewModel.estimatedLabel : nil,
                    showsRemuxBadge: viewModel.shouldShowRemuxBadgeOnTargetSize,
                    accessibilityLabel: viewModel.targetControlAccessibilityLabel,
                    targetFraction: $viewModel.targetFraction
                )
            }
        }
    }

    private var singlePassVideoTargetToggle: some View {
        Toggle("Two-pass", isOn: Binding(
            get: { viewModel.usesTwoPassVideoEncoding },
            set: { newValue in
                Haptics.impact(.light)
                viewModel.usesSinglePassVideoTargetEncode = !newValue
            }
        ))
        .font(.footnote.weight(.semibold))
        .toggleStyle(.switch)
        .tint(Theme.tint)
        .accessibilityLabel("Use two-pass target encode")
        .accessibilityValue(viewModel.usesTwoPassVideoEncoding ? "On" : "Off")
    }

    private func optionRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.text)

                    content()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(Theme.text)
                        .frame(width: 96, alignment: .leading)
                        .frame(minHeight: 44, alignment: .leading)

                    content()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func customDimensionField(_ title: String, value: String, maximum: CGFloat?,
                                      onChange: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Theme.textMuted)
                .padding(.leading, 4)
                .accessibilityHidden(true)
            CustomDimensionField(title: title, value: value, maximum: maximum, onChange: onChange)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum CustomDimension: Hashable {
    case width, height
}

/// Keeps its own text so a value clamped to the original size always
/// replaces what was typed, even when the stored value doesn't change.
private struct CustomDimensionField: View {
    let title: String
    let value: String
    let maximum: CGFloat?
    let onChange: (String) -> Void

    @State private var text = ""

    var body: some View {
        HStack(spacing: 6) {
            TextField(title, text: $text)
                .keyboardType(.numberPad)
                .font(.body.monospacedDigit())
                .foregroundStyle(Theme.text)
                .textFieldStyle(.plain)
            Text("px")
                .font(.subheadline)
                .foregroundStyle(Theme.textMuted)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .background(Theme.fieldFill, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
        .accessibilityLabel("Custom \(title.lowercased()) in pixels")
        .onAppear { text = value }
        .onChange(of: value) { _, value in
            if value != text { text = value }
        }
        .onChange(of: text) { _, typed in
            let clamped = OutputConfigViewModel.customDimensionText(typed, maximum: maximum)
            guard clamped == typed else {
                Haptics.selection()
                text = clamped
                return
            }
            if typed != value { onChange(typed) }
        }
    }
}

#Preview {
    NavigationStack {
        OutputConfigForm(
            viewModel: OutputConfigViewModel(
                input: MediaFile(
                    url: URL(fileURLWithPath: "/tmp/video.mp4"),
                    originalFilename: "video.mp4",
                    category: .video,
                    sizeOnDisk: 100_000_000,
                    dimensions: CGSize(width: 1920, height: 1080),
                    duration: 60,
                    fps: 30,
                    bitrate: 13_000_000,
                    audioBitrate: 128_000,
                    videoCodec: "avc1",
                    audioCodec: "mp4a",
                    containerFormat: "mp4"
                )
            ),
            isMenuInteractionDisabled: false,
            onConvert: {}
        )
    }
}
