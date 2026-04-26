import SwiftUI

/// Output format and tuning controls shared by the convert screen.
struct OutputConfigForm: View {
    @Bindable var viewModel: OutputConfigViewModel
    let isMenuInteractionDisabled: Bool
    var onConvert: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 18) {
                if viewModel.shouldShowTargetSize, !viewModel.isAudioOutput {
                    targetSizeSection
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                VStack(spacing: 14) {
                    optionRow("Format") {
                        FormatPicker(
                            formats: viewModel.formats,
                            inputCategory: viewModel.input.category,
                            isInteractionDisabled: isMenuInteractionDisabled,
                            selection: $viewModel.selectedFormat
                        )
                    }

                    if viewModel.shouldShowResolution {
                        optionRow("Resolution") {
                            resolutionPicker
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    if viewModel.shouldShowFPS {
                        optionRow("FPS") {
                            fpsPicker
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    if viewModel.shouldShowVideoOutputAudio {
                        optionRow("Audio") {
                            videoAudioQualitySection
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                }

                if viewModel.shouldShowTargetSize, viewModel.isAudioOutput {
                    targetSizeSection
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if viewModel.shouldShowWebPQuality {
                    section("Quality") {
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
                    .transition(.opacity.combined(with: .move(edge: .top)))
                } else if let note = viewModel.losslessNote {
                    section("Target Size") {
                        Text(note)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(18)
            .background(Theme.surface.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

            Button {
                Haptics.impact(.medium)
                onConvert()
            } label: {
                Text("Convert")
                    .font(.headline)
                    .foregroundStyle(Theme.background)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(Theme.primary)
                    .clipShape(Capsule())
            }
            .accessibilityLabel("Convert")
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var videoAudioQualitySection: some View {
        HStack(spacing: 10) {
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
            HStack(spacing: 10) {
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
                HStack {
                    TextField("Width", text: Binding(
                        get: { viewModel.customWidthText },
                        set: { viewModel.updateCustomWidth($0) }
                    ))
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Custom width")

                    Text("x")
                        .foregroundStyle(Theme.textMuted)

                    TextField("Height", text: Binding(
                        get: { viewModel.customHeightText },
                        set: { viewModel.updateCustomHeight($0) }
                    ))
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Custom height")
                }
            }
        }
    }

    private var fpsPicker: some View {
        HStack(spacing: 10) {
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
                .foregroundStyle(isLocked.wrappedValue ? Theme.background : Theme.primary)
                .frame(width: 42, height: 42)
                .background(
                    isLocked.wrappedValue
                    ? Theme.primary
                    : Theme.primary.opacity(0.12)
                )
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
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
        .foregroundStyle(Theme.background)
        .padding(.horizontal, 14)
        .frame(minHeight: 42)
        .background(Theme.primary)
        .clipShape(Capsule())
        .accessibilityLabel(accessibility)
    }

    private var targetSizeSection: some View {
        section(viewModel.targetControlTitle) {
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

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(Theme.text)
            content()
        }
    }

    private func optionRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
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

#Preview {
    NavigationStack {
        ScrollView {
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
            .padding(20)
        }
    }
}
