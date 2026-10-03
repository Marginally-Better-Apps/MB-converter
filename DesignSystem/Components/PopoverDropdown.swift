import SwiftUI

/// A dropdown whose button stays in the page while its options are presented.
struct PopoverDropdown<Option: Identifiable>: View {
    let title: String
    let accessibilityLabel: String
    let options: [Option]
    let optionTitle: (Option) -> String
    var optionSection: (Option) -> String? = { _ in nil }
    var optionSymbol: (Option) -> String? = { _ in nil }
    var isSelected: ((Option) -> Bool)? = nil
    var leadingSymbol: String? = nil
    var badge: String? = nil
    var expandsLabel = false
    let onSelect: (Option) -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isPresented = false
    @ScaledMetric(relativeTo: .body) private var optionHeight = 44

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 8) {
                if let leadingSymbol {
                    Image(systemName: leadingSymbol)
                }
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if expandsLabel {
                    Spacer(minLength: 8)
                }
                if let badge {
                    Text(badge)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textMuted)
                }
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isEnabled ? Theme.tint : Theme.textMuted)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .converterGlass(cornerRadius: 10)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(options.isEmpty)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isSelected == nil ? (badge ?? "") : title)
        // Let the system place the menu above the button when space below is limited.
        .popover(isPresented: $isPresented) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                        if let heading = sectionHeading(at: index) {
                            Text(heading)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.textMuted)
                                .padding(.horizontal, 12)
                                .frame(minHeight: optionHeight, alignment: .leading)
                                .accessibilityAddTraits(.isHeader)
                        }
                        optionButton(option)
                    }
                }
                .padding(8)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(idealWidth: 280, maxWidth: 320, idealHeight: menuHeight, maxHeight: menuHeight)
            .presentationCompactAdaptation(.popover)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionHeading(at index: Int) -> String? {
        let heading = optionSection(options[index])
        return index == 0 || heading != optionSection(options[index - 1]) ? heading : nil
    }

    private var menuHeight: CGFloat {
        let sectionCount = options.indices.filter { sectionHeading(at: $0) != nil }.count
        return min(420, CGFloat(options.count + sectionCount) * optionHeight + 16)
    }

    private func optionButton(_ option: Option) -> some View {
        Button {
            Haptics.selection()
            // Close immediately, before selection can change the page layout.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isPresented = false
                onSelect(option)
            }
        } label: {
            HStack(spacing: 12) {
                if let symbol = optionSymbol(option) {
                    Image(systemName: symbol)
                        .accessibilityHidden(true)
                }
                Text(optionTitle(option))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .opacity(isSelected(option) ? 1 : 0)
                        .accessibilityHidden(true)
                }
            }
            .font(.body)
            .foregroundStyle(Theme.tint)
            .padding(.horizontal, 12)
            .frame(minHeight: optionHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected?(option) == true ? .isSelected : [])
    }
}
