import SwiftUI

/// Output format and tuning controls shared by the convert screen.
struct OutputConfigForm: View {
    @Bindable var viewModel: OutputConfigViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
                        HStack {
                            Text("WebP Quality")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.text)
                            Spacer()
                            Text("\(Int((viewModel.webpQuality * 100).rounded()))%")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(Theme.textMuted)
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
                        .tint(Theme.primary)

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
                        Text("Convert")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 14))
                    .controlSize(.large)
                    .tint(Theme.tint)
                    .disabled(!viewModel.canConvert)
                    .accessibilityLabel("Convert")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.groupedBackground)
        .tint(Theme.tint)
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
        VStack(alignment: .leading, spacing: 12) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                : AnyLayout(HStackLayout(spacing: 10))

            layout {
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

            if viewModel.selectedResolutionID == "custom" {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 10) {
                        customDimensionField(
                            "Width",
                            text: Binding(
                                get: { viewModel.customWidthText },
                                set: { viewModel.updateCustomWidth($0) }
                            )
                        )
                        customDimensionField(
                            "Height",
                            text: Binding(
                                get: { viewModel.customHeightText },
                                set: { viewModel.updateCustomHeight($0) }
                            )
                        )
                    }
                } else {
                    HStack {
                        customDimensionField(
                            "Width",
                            text: Binding(
                                get: { viewModel.customWidthText },
                                set: { viewModel.updateCustomWidth($0) }
                            )
                        )

                        Text("x")
                            .foregroundStyle(Theme.textMuted)

                        customDimensionField(
                            "Height",
                            text: Binding(
                                get: { viewModel.customHeightText },
                                set: { viewModel.updateCustomHeight($0) }
                            )
                        )
                    }
                }
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
                .frame(minWidth: 42, minHeight: 42)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .tint(Theme.tint)
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
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .frame(width: 96, alignment: .leading)
                        .frame(minHeight: 44, alignment: .leading)

                    content()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func customDimensionField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .keyboardType(.numberPad)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Custom \(title.lowercased())")
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
