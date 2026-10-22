import PhotosUI
import SwiftUI

/// Renders one declarative `ToolOption` with the matching native control.
struct OptionControl: View {
    let option: ToolOption
    @Binding var values: ToolOptionValues
    let inputs: [ToolInputFile]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            control
            if let footnote = option.footnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var control: some View {
        switch option.kind {
        case .choice(let choices, let segmented):
            choicePicker(choices, segmented: segmented && choices.count <= 5)
        case .dynamicChoice(let provider):
            choicePicker(provider(inputs), segmented: false)
        case .toggle:
            Toggle(option.label, isOn: boolBinding)
                .tint(Theme.primary)
        case .slider(let range, let step, let format):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(option.label)
                    Spacer()
                    Text(format(values.double(option.key)))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(Theme.textMuted)
                }
                Slider(value: doubleBinding, in: range, step: step)
                    .tint(Theme.primary)
            }
        case .stepper(let range, let suffix):
            Stepper(value: intBinding, in: range, step: stepSize(for: range)) {
                HStack {
                    Text(option.label)
                    Spacer()
                    Text("\(values.int(option.key).formatted())\(suffix)")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(Theme.textMuted)
                }
            }
        case .text(let placeholder, let secure, let multiline, let keyboard):
            VStack(alignment: .leading, spacing: 6) {
                Text(option.label)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textMuted)
                Group {
                    if secure {
                        SecureField(placeholder, text: stringBinding)
                    } else if multiline {
                        TextField(placeholder, text: stringBinding, axis: .vertical)
                            .lineLimit(option.key == "body" ? 8 ... 24 : 2 ... 6)
                    } else {
                        TextField(placeholder, text: stringBinding)
                    }
                }
                .keyboardType(keyboard == .url ? .URL : (keyboard == .number ? .numbersAndPunctuation : .default))
                .textInputAutocapitalization(keyboard == .url || secure ? .never : .sentences)
                .autocorrectionDisabled(keyboard == .url || secure)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            }
        case .color:
            ColorPicker(option.label, selection: colorBinding, supportsOpacity: false)
        case .image:
            ImageOptionPicker(label: option.label, data: dataBinding)
        }
    }

    @ViewBuilder
    private func choicePicker(_ choices: [ToolChoice], segmented: Bool) -> some View {
        if segmented {
            VStack(alignment: .leading, spacing: 8) {
                Text(option.label)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textMuted)
                Picker(option.label, selection: stringBinding) {
                    ForEach(choices) { Text($0.label).tag($0.value) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        } else {
            HStack {
                Text(option.label)
                Spacer(minLength: Theme.Spacing.m)
                Picker(option.label, selection: stringBinding) {
                    ForEach(choices) { Text($0.label).tag($0.value) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(Theme.tint)
            }
        }
    }

    private func stepSize(for range: ClosedRange<Int>) -> Int {
        switch range.upperBound {
        case 100_000...: 100
        case 2_000...: 10
        default: 1
        }
    }

    // MARK: Bindings

    private var stringBinding: Binding<String> {
        Binding(get: { values.string(option.key) }, set: { values[option.key] = .string($0) })
    }

    private var boolBinding: Binding<Bool> {
        Binding(get: { values.bool(option.key) }, set: { values[option.key] = .bool($0); Haptics.selection() })
    }

    private var doubleBinding: Binding<Double> {
        Binding(get: { values.double(option.key) }, set: { values[option.key] = .number($0) })
    }

    private var intBinding: Binding<Int> {
        Binding(get: { values.int(option.key) }, set: { values[option.key] = .number(Double($0)) })
    }

    private var dataBinding: Binding<Data?> {
        Binding(get: { values.data(option.key) }, set: { values[option.key] = .data($0) })
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(uiColor: UIColor(hex: values.hex(option.key))) },
            set: { color in
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                let hex = (UInt32(max(0, min(1, red)) * 255) << 16) | (UInt32(max(0, min(1, green)) * 255) << 8) | UInt32(max(0, min(1, blue)) * 255)
                values[option.key] = .number(Double(hex))
            }
        )
    }
}

private struct ImageOptionPicker: View {
    let label: String
    @Binding var data: Data?
    @State private var item: PhotosPickerItem?

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Text(label)
            Spacer()
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    .background(Theme.surfaceSunken)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            PhotosPicker(selection: $item, matching: .images) {
                Text(data == nil ? "Choose…" : "Change")
                    .foregroundStyle(Theme.tint)
            }
        }
        .onChange(of: item) { _, newItem in
            guard let newItem else { return }
            Task { data = try? await newItem.loadTransferable(type: Data.self) }
        }
    }
}
