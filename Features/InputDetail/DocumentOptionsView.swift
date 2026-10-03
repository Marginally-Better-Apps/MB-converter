import SwiftUI

struct DocumentOptionsView: View {
    @Bindable var viewModel: OutputConfigViewModel
    var body: some View {
        if viewModel.input.containerFormat == "pdf", viewModel.selectedFormat.category != .archive {
            VStack(spacing: 14) {
                HStack {
                    Text("Pages")
                    Spacer()
                    TextField("All", text: $viewModel.documentSettings.pages)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numbersAndPunctuation)
                        .frame(maxWidth: 180)
                        .accessibilityHint("Page numbers, for example 1-3, 5")
                }
                if [.pdf, .jpg, .png].contains(viewModel.selectedFormat) {
                    Divider()
                    Picker("Rotation", selection: $viewModel.documentSettings.rotation) {
                        ForEach(MediaRotation.allCases, id: \.self) { rotation in
                            Text("\(rotation.rawValue)°").tag(rotation)
                        }
                    }.pickerStyle(.segmented)
                }
                if viewModel.selectedFormat == .pdf {
                    Toggle("Compress", isOn: $viewModel.documentSettings.compress)
                    if viewModel.documentSettings.compress {
                        Text("Keeps the smaller result. Compression may turn text into images.").font(.caption).foregroundStyle(Theme.textMuted)
                    }
                } else if viewModel.selectedFormat.category == .document {
                    Toggle("Recognize scanned text", isOn: $viewModel.documentSettings.recognizeText)
                } else if [.jpg, .png].contains(viewModel.selectedFormat) {
                    Text("Multiple pages export as one ZIP.").font(.caption).foregroundStyle(Theme.textMuted)
                }
            }
            .tint(Theme.tint)
            .padding(16)
            .converterGlass(cornerRadius: 16)
        }
    }
}

struct ImageEnhancementOptions: View {
    @Bindable var viewModel: OutputConfigViewModel
    var body: some View {
        DisclosureGroup("Image tools") {
            VStack(spacing: 16) {
                Picker("Upscale", selection: $viewModel.imageEnhancement.scale) {
                    Text("Original").tag(1.0)
                    Text("2×").tag(2.0)
                    Text("4×").tag(4.0)
                }.pickerStyle(.segmented)
                Toggle("Remove background", isOn: $viewModel.imageEnhancement.removeBackground)
                    .disabled(![.png, .heic, .webpImage, .tiff].contains(viewModel.selectedFormat))
            }.padding(.top, 12)
        }
        .tint(Theme.tint)
        .padding(16)
        .converterGlass(cornerRadius: 16)
    }
}
