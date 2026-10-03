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
                if format.category == .archive { return "Compress file" }
                if inputCategory == .video { return format.category == .video ? "Video" : format.category == .audio ? "Extract audio" : "Frame" }
                if inputCategory == .document { return format.category == .image ? "Page images" : "Documents" }
                if inputCategory == .image {
                    if [.bmp, .ico, .jpeg2000, .tga, .psd, .exr, .icns].contains(format) { return "More formats" }
                    if format.category == .document { return "Document" }
                    return "Images"
                }
                return nil
            },
            isSelected: { $0 == selection },
            onSelect: { selection = $0 }
        )
    }

    private var orderedFormats: [OutputFormat] {
        guard inputCategory == .video else { return formats }
        return formats.filter { $0.category == .video }
            + formats.filter { $0.category == .audio }
            + formats.filter { $0.category == .image }
            + formats.filter { $0.category == .archive }
    }
}
