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
                                isInteractionDisabled: isMenuInteractionDisabled,
                                selection: $viewModel.selectedFormat
                            )
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
            } else if showsPrimaryControls, let note = viewModel.losslessNote {
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
                    .appleGlassButton(prominent: true)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .tint(Theme.tint)
                    .accessibilityLabel("Convert")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
        .tint(.accentColor)
    }

    private var videoAudioQualitySection: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))

        return layout {
            Menu {
                ForEach(viewModel.videoAudioQualityOptions) { preset in
                    Button {
                        Haptics.selection()
                        viewModel.videoOutputAudioQuality = preset
                    } label: {
                        Text(preset == .auto ? viewModel.videoAudioSourceLabel : preset.label)
                    }
                }
            } label: {
                bubbleLabel(
                    text: viewModel.videoAudioQualitySelectionLabel,
                    accessibility: "Audio quality"
                )
            }
            .appleGlassButton()
            .buttonBorderShape(.capsule)
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
                Menu {
                    ForEach(viewModel.resolutionOptions) { option in
                        Button {
                            Haptics.selection()
                            viewModel.selectResolution(option)
                        } label: {
                            Text(option.label)
                        }
                    }
                } label: {
                    bubbleLabel(
                        text: viewModel.resolutionOptions.first(where: { $0.id == viewModel.selectedResolutionID })?.label ?? "Resolution",
                        accessibility: "Resolution"
                    )
                }
                .appleGlassButton()
                .buttonBorderShape(.capsule)
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
            Menu {
                ForEach(viewModel.fpsOptions) { option in
                    Button {
                        Haptics.selection()
                        viewModel.selectedFPS = option.value
                    } label: {
                        Text(option.label)
                    }
                }
            } label: {
                bubbleLabel(
                    text: viewModel.fpsOptions.first(where: { $0.value == viewModel.selectedFPS })?.label ?? "Original",
                    accessibility: "FPS"
                )
            }
            .appleGlassButton()
            .buttonBorderShape(.capsule)
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
        .appleGlassButton()
        .buttonBorderShape(.circle)
        .tint(Theme.tint)
        .accessibilityLabel(label)
        .accessibilityValue(isLocked.wrappedValue ? "Locked" : "Unlocked")
    }

    private func bubbleLabel(text: String, accessibility: String) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Theme.tint)
        .padding(.horizontal, 4)
        .frame(minHeight: 42)
        .accessibilityLabel(accessibility)
    }

    private var targetSizeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(viewModel.targetControlTitle)
                            .font(.title3.bold())
                            .foregroundStyle(Theme.text)

                        if viewModel.shouldShowSinglePassVideoTargetToggle {
                            singlePassVideoTargetToggle
                        }
                    }
                } else {
                    HStack(alignment: .center, spacing: 12) {
                        Text(viewModel.targetControlTitle)
                            .font(.title3.bold())
                            .foregroundStyle(Theme.text)

                        Spacer()

                        if viewModel.shouldShowSinglePassVideoTargetToggle {
                            singlePassVideoTargetToggle
                        }
                    }
                }
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
        Toggle("Fast", isOn: Binding(
            get: { viewModel.usesSinglePassVideoTargetEncode },
            set: { newValue in
                Haptics.impact(.light)
                viewModel.usesSinglePassVideoTargetEncode = newValue
            }
        ))
        .font(.footnote.weight(.semibold))
        .toggleStyle(.switch)
        .tint(Theme.tint)
        .accessibilityLabel("Use single-pass target encode")
        .accessibilityValue(viewModel.usesSinglePassVideoTargetEncode ? "On" : "Off")
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
                        .padding(.top, 10)

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
