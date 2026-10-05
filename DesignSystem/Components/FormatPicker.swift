import SwiftUI

struct FormatPicker: View {
    let formats: [OutputFormat]
    let inputCategory: MediaCategory
    var isLivePhoto = false
    @Binding var selection: OutputFormat

    var body: some View {
        PopoverDropdown(
            title: selection.displayName,
            accessibilityLabel: "Output format",
            options: orderedFormats,
            optionTitle: { $0.displayName },
            optionSection: { format in
                if isLivePhoto {
                    return format.category == .video ? "Live Photo Video" : "Still Photo"
                }
                guard inputCategory == .video else { return nil }
                return format.category == .video ? "Video Output" : "Extract audio"
            },
            isSelected: { $0 == selection },
            onSelect: { selection = $0 }
        )
    }

    private var orderedFormats: [OutputFormat] {
        if isLivePhoto {
            return formats.filter { $0.category == .image } + formats.filter { $0.category == .video }
        }
        guard inputCategory == .video else { return formats }
        return formats.filter { $0.category == .video }
            + formats.filter { $0.category == .audio }
    }
}
