import SwiftUI

struct ToolBrowserView: View {
    @Binding var path: [AppRoute]
    @State private var searchText = ""
    @State private var category: ToolCategory?

    var body: some View {
        ScrollView {
            if searchText.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    filterBar
                    ForEach(category.map { [$0] } ?? ToolCategory.allCases) { category in
                        ToolSection(category: category, tools: ToolCatalog.tools(in: category))
                    }
                    PrivacyNote().padding(.vertical, Theme.Spacing.l)
                }
                .padding(.horizontal, Theme.Spacing.l)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            } else {
                ToolSearchResults(query: searchText, path: $path)
                    .padding(.horizontal, Theme.Spacing.l)
                    .padding(.top, Theme.Spacing.s)
            }
        }
        .screenBackground()
        .navigationTitle("Tools")
        .searchable(text: $searchText, prompt: "Search tools, like “PDF to Word”")
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.s) {
                FilterChip(title: "All", isSelected: category == nil) { category = nil }
                ForEach(ToolCategory.allCases) { item in
                    FilterChip(title: item.shortTitle, isSelected: category == item) {
                        category = category == item ? nil : item
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }
}

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.selection()
            withAnimation(.snappy(duration: 0.2)) { action() }
        } label: {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isSelected ? Theme.onPrimary : Theme.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isSelected ? AnyShapeStyle(Theme.primary) : AnyShapeStyle(Theme.surface), in: Capsule())
                .overlay { Capsule().strokeBorder(isSelected ? Color.clear : Theme.separator, lineWidth: 0.75) }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct ToolSection: View {
    let category: ToolCategory
    let tools: [ToolDefinition]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(category.title)
                .font(.footnote.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.4)
                .foregroundStyle(Theme.textMuted)
                .padding(.leading, Theme.Spacing.xs)
                .padding(.top, Theme.Spacing.s)
            ToolList(tools: tools)
        }
    }
}

struct ToolList: View {
    let tools: [ToolDefinition]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                NavigationLink(value: AppRoute.tool(tool.id, inputs: [])) {
                    ToolRowLabel(tool: tool)
                        .padding(.horizontal, Theme.Spacing.l)
                        .padding(.vertical, 11)
                }
                .buttonStyle(PressableStyle())
                if index < tools.count - 1 {
                    Divider().overlay(Theme.separator).padding(.leading, 62)
                }
            }
        }
        .card(padding: 0)
    }
}

struct CategoryView: View {
    let category: ToolCategory
    @Binding var path: [AppRoute]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                HStack(spacing: Theme.Spacing.m) {
                    ToolGlyph(symbol: category.symbol, category: category, size: 44)
                    Text(category.summary)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textMuted)
                }
                .padding(.top, Theme.Spacing.s)
                let tools = ToolCatalog.tools(in: category)
                let conversions = tools.filter { $0.id.rawValue.hasPrefix("convert.") }
                let others = tools.filter { !$0.id.rawValue.hasPrefix("convert.") }
                if !others.isEmpty {
                    ToolList(tools: others)
                }
                if !conversions.isEmpty {
                    Text("Conversions")
                        .font(.footnote.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(0.4)
                        .foregroundStyle(Theme.textMuted)
                        .padding(.leading, Theme.Spacing.xs)
                        .padding(.top, Theme.Spacing.s)
                    ToolList(tools: conversions)
                }
                PrivacyNote().padding(.vertical, Theme.Spacing.l)
            }
            .padding(.horizontal, Theme.Spacing.l)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .screenBackground()
        .navigationTitle(category.title)
    }
}

/// Live search results for the tool browser.
struct ToolSearchResults: View {
    let query: String
    @Binding var path: [AppRoute]

    var body: some View {
        let results = ToolCatalog.search(query)
        if results.isEmpty {
            ContentUnavailableView.search(text: query)
                .padding(.top, 60)
        } else {
            ToolList(tools: results)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
        }
    }
}
