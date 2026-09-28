import SwiftUI

struct FormatPicker: View {
    let formats: [OutputFormat]
    let inputCategory: MediaCategory
    @Binding var selection: OutputFormat

    var body: some View {
        PopoverDropdown(
            title: selection.displayName,
            accessibilityLabel: "Output format",
            options: orderedFormats,
            optionTitle: { $0.displayName },
            optionSection: { format in
                guard inputCategory == .video else { return nil }
                return format.category == .video ? "Video Output" : "Extract audio"
            },
            isSelected: { $0 == selection },
            onSelect: { selection = $0 }
        )
    }

    private var orderedFormats: [OutputFormat] {
        guard inputCategory == .video else { return formats }
        return formats.filter { $0.category == .video }
            + formats.filter { $0.category == .audio }
    }
}
