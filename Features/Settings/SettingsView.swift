import SwiftUI
import UIKit

/// App settings, presented as a sheet from the Convert and History tabs.
struct SettingsView: View {
    @AppStorage("appColorMode") private var appColorModeRawValue = AppColorMode.system.rawValue
    @AppStorage(ConversionHistoryUserDefaults.isEnabledKey) private var conversionHistoryEnabled = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openURL) private var openURL
    @State private var themeSelection: ThemeSelection = .system
    @State private var isConfirmDisableSavedHistoryPresented = false
    @State private var diagnosticsErrorCount = 0
    @State private var latestDiagnosticsErrorDate: Date?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    appHeader
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                Section("Appearance") {
                    if dynamicTypeSize.isAccessibilitySize {
                        PopoverDropdown(
                            title: themeSelection.title,
                            accessibilityLabel: "Appearance",
                            options: ThemeSelection.allCases,
                            optionTitle: { $0.title },
                            isSelected: { $0 == themeSelection },
                            onSelect: { themeSelection = $0 }
                        )
                    } else {
                        Picker("Appearance", selection: $themeSelection) {
                            ForEach(ThemeSelection.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Section {
                    Toggle(isOn: conversionHistoryEnabledBinding) {
                        settingsLabel("Save Conversion History", systemImage: "clock.arrow.circlepath")
                    }
                } header: {
                    Text("History")
                } footer: {
                    Text("When off, History only keeps conversions from this session.")
                }

                Section {
                    NavigationLink {
                        DiagnosticsLogView()
                    } label: {
                        HStack(spacing: 12) {
                            IconTile(
                                systemImage: diagnosticsErrorCount == 0 ? "checkmark" : "exclamationmark.triangle.fill"
                            )

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Error Log")
                                    .foregroundStyle(Theme.text)
                                Text(diagnosticsSummary)
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.textMuted)
                            }

                            Spacer(minLength: 8)
                            if diagnosticsErrorCount > 0 {
                                Text(String(diagnosticsErrorCount))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Theme.destructive, in: Capsule())
                            }
                        }
                    }
                    .accessibilityHint("Opens recorded errors with conversion context and technical details.")

                    Button("Clear Error Log", role: .destructive) {
                        Haptics.warning()
                        DiagnosticsLog.shared.clearErrors()
                        refreshDiagnosticsSummary()
                    }
                    .disabled(diagnosticsErrorCount == 0)
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("Errors are saved across launches and can be reviewed, copied, or exported.")
                }

                Section("About") {
                    NavigationLink {
                        OpenSourceLicensesView()
                    } label: {
                        settingsLabel("Open Source Licenses", systemImage: "doc.text")
                    }
                    Button {
                        Haptics.impact(.light)
                        if let url = URL(string: "https://github.com/Marginally-Better-Apps/MB-converter") {
                            openURL(url)
                        }
                    } label: {
                        HStack {
                            settingsLabel("View on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                            Spacer()
                            Image(systemName: "arrow.up.forward")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Theme.textTertiary)
                                .accessibilityHidden(true)
                        }
                    }
                    LabeledContent("Name", value: "Marginally Better Converter")
                    LabeledContent("Version", value: bundleVersion)
                    LabeledContent("Build", value: bundleBuild)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Haptics.impact(.light)
                        dismiss()
                    }
                }
            }
        }
        .tint(Theme.tint)
        .alert("Switch to session-only history?", isPresented: $isConfirmDisableSavedHistoryPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Switch", role: .destructive) {
                Haptics.warning()
                ConversionHistoryStore.shared.clearPersistedHistory()
                conversionHistoryEnabled = false
                ConversionHistoryStore.shared.refreshForCurrentSettings()
            }
        } message: {
            Text(
                "Turning off saved history removes every saved conversion from this device at once. "
                + "Afterward, History only keeps items from this session until you quit and reopen the app."
            )
        }
        .onAppear {
            themeSelection = resolvedThemeSelection
            refreshDiagnosticsSummary()
        }
        .onChange(of: themeSelection) { _, selection in
            let newValue = selection.rawValue
            if appColorModeRawValue != newValue {
                Haptics.selection()
                appColorModeRawValue = newValue
            }
        }
        .onChange(of: appColorModeRawValue) { _, _ in
            themeSelection = resolvedThemeSelection
        }
    }

    private var appHeader: some View {
        VStack(spacing: 10) {
            appIcon
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                .shadow(color: Theme.brandNavy.opacity(0.22), radius: 12, y: 6)
                .accessibilityHidden(true)

            VStack(spacing: 2) {
                Text("MB Converter")
                    .font(.title3.bold())
                    .foregroundStyle(Theme.text)
                Text("Version \(bundleVersion)")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var appIcon: some View {
        if let icon = Self.primaryAppIcon {
            Image(uiImage: icon)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Theme.brandGradient
                Image(systemName: "doc.text")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
    }

    private func settingsLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            IconTile(systemImage: systemImage)
            Text(title)
                .foregroundStyle(Theme.text)
        }
    }

    private var resolvedThemeSelection: ThemeSelection {
        ThemeSelection(rawValue: appColorModeRawValue) ?? .system
    }

    private var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var bundleBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    private var diagnosticsSummary: String {
        guard diagnosticsErrorCount > 0 else { return "No errors recorded" }
        guard let latestDiagnosticsErrorDate else {
            return "\(diagnosticsErrorCount) recorded"
        }
        return "Latest \(latestDiagnosticsErrorDate.formatted(date: .abbreviated, time: .shortened))"
    }

    private func refreshDiagnosticsSummary() {
        let errors = DiagnosticsLog.shared.entries().filter { $0.level == .error }
        diagnosticsErrorCount = errors.count
        latestDiagnosticsErrorDate = errors.first?.timestamp
    }

    private var conversionHistoryEnabledBinding: Binding<Bool> {
        Binding(
            get: { conversionHistoryEnabled },
            set: { newValue in
                if conversionHistoryEnabled, !newValue {
                    isConfirmDisableSavedHistoryPresented = true
                    return
                }
                if !conversionHistoryEnabled, newValue,
                   !ConversionHistoryStore.shared.persistSessionHistory() {
                    return
                }
                conversionHistoryEnabled = newValue
                ConversionHistoryStore.shared.refreshForCurrentSettings()
            }
        )
    }

    /// The asset catalog exposes the installed icon through the bundle's icon file names.
    private static let primaryAppIcon: UIImage? = {
        guard let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let name = files.last else { return nil }
        return UIImage(named: name)
    }()
}

private enum ThemeSelection: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            "System"
        case .light:
            "Light"
        case .dark:
            "Dark"
        }
    }
}

/// Adds the Settings button that Apple apps keep in the top trailing corner.
private struct SettingsToolbarButton: ViewModifier {
    @State private var isSettingsPresented = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.impact(.light)
                        isSettingsPresented = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Open settings")
                }
            }
            .sheet(isPresented: $isSettingsPresented) {
                SettingsView()
            }
    }
}

extension View {
    func settingsToolbarButton() -> some View {
        modifier(SettingsToolbarButton())
    }
}

#Preview("Settings") {
    SettingsView()
}
