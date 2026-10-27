import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ToolResultView: View {
    let run: ToolRun
    @Binding var path: [AppRoute]

    @State private var files: [ToolOutputFile]
    @State private var preview: IdentifiableURLs?
    @State private var share: IdentifiableURLs?
    @State private var export: IdentifiableURLs?
    @State private var renaming: ToolOutputFile?
    @State private var renameText = ""
    @State private var toast: String?
    @State private var errorMessage: String?

    init(run: ToolRun, path: Binding<[AppRoute]>) {
        self.run = run
        _path = path
        _files = State(initialValue: run.output.files)
    }

    private var tool: ToolDefinition? { ToolCatalog.tool(run.toolID) }
    private var urls: [URL] { files.map(\.url) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                header
                if let file = files.first, files.count == 1, showsLargePreview(file) { largePreview(file) }
                if let text = run.output.text ?? plainTextResult { textCard(text) }
                filesCard
                actions
                Label("You'll also find this in History.", systemImage: "clock.arrow.circlepath")
                    .font(.footnote)
                    .foregroundStyle(Theme.textMuted)
                    .frame(maxWidth: .infinity)
                if let next = nextTools, !next.isEmpty { continueSection(next) }
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.s)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .screenBackground()
        .navigationTitle("Ready")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    Haptics.impact(.light)
                    path.removeAll()
                }
                .fontWeight(.semibold)
                .accessibilityIdentifier("result.finish")
            }
        }
        .sheet(item: $preview) { item in
            QuickLookPreview(urls: item.urls, initialIndex: item.index).ignoresSafeArea()
        }
        .sheet(item: $share) { item in
            ActivityView(items: item.urls).presentationDetents([.medium, .large])
        }
        .sheet(item: $export) { item in
            DocumentExporter(urls: item.urls) { saved in
                if saved { showToast(item.urls.count == 1 ? "Saved to Files" : "Saved \(item.urls.count) files") }
            }
            .ignoresSafeArea()
        }
        .alert("Rename File", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Rename") { applyRename() }
        }
        .alert("Couldn't Complete", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.onPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.primary, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: Theme.Spacing.m) {
            ZStack {
                Circle().fill(Theme.success.opacity(0.12)).frame(width: 48, height: 48)
                Image(systemName: "checkmark")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.success)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(tool?.title ?? "Finished")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.text)
                Text(run.output.summary ?? "\(files.count) file\(files.count == 1 ? "" : "s") ready")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, Theme.Spacing.s)
        .accessibilityElement(children: .combine)
    }

    /// A single small text result (PDF to Text, CSV, Markdown…) is shown with a Copy button,
    /// so you don't have to save a file just to paste its words somewhere.
    private var plainTextResult: String? {
        guard files.count == 1, let file = files.first,
              let format = file.format, [.txt, .markdown, .csv, .json].contains(format),
              file.byteCount < 256_000 else { return nil }
        return (try? String(contentsOf: file.url, encoding: .utf8))?.nilIfBlank
    }

    private func showsLargePreview(_ file: ToolOutputFile) -> Bool {
        guard let family = file.format?.family else { return false }
        return [.image, .pdf, .video].contains(family)
    }

    /// The result itself, big enough to check at a glance; tap for full screen.
    private func largePreview(_ file: ToolOutputFile) -> some View {
        Button {
            preview = IdentifiableURLs(urls: urls, index: 0)
        } label: {
            FileThumbnail(url: file.url, size: CGSize(width: 320, height: 260), format: file.format)
                .frame(maxWidth: .infinity)
                .frame(height: 260)
                .padding(Theme.Spacing.s)
                .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Preview \(file.name)")
        .accessibilityIdentifier("result.preview")
    }

    private func textCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack {
                Text("Text").font(.headline).foregroundStyle(Theme.text)
                Spacer()
                Button {
                    UIPasteboard.general.string = text
                    Haptics.success()
                    showToast("Text copied")
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.subheadline.weight(.medium))
                }
            }
            ScrollView {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
        }
        .card()
    }

    private var filesCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                Button {
                    preview = IdentifiableURLs(urls: urls, index: index)
                } label: {
                    HStack(spacing: Theme.Spacing.m) {
                        FileThumbnail(url: file.url, size: CGSize(width: 48, height: 48), format: file.format)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(file.name)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.text)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .multilineTextAlignment(.leading)
                            HStack(spacing: 6) {
                                if let format = file.format { FormatBadge(text: format.badge) }
                                Text(file.byteCount.formattedBytes)
                                    .font(.caption)
                                    .foregroundStyle(Theme.textMuted)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "eye")
                            .font(.footnote)
                            .foregroundStyle(Theme.textFaint)
                    }
                    .padding(.horizontal, Theme.Spacing.l)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityIdentifier("result.file")
                .contextMenu {
                    Button { preview = IdentifiableURLs(urls: urls, index: index) } label: { Label("Preview", systemImage: "eye") }
                    Button { share = IdentifiableURLs(urls: [file.url]) } label: { Label("Share", systemImage: "square.and.arrow.up") }
                    Button { export = IdentifiableURLs(urls: [file.url]) } label: { Label("Save to Files", systemImage: "folder") }
                    Button {
                        renameText = (file.name as NSString).deletingPathExtension
                        renaming = file
                    } label: { Label("Rename", systemImage: "pencil") }
                }
                if index < files.count - 1 {
                    Divider().overlay(Theme.separator).padding(.leading, 76)
                }
            }
        }
        .card(padding: 0)
    }

    private var canSaveToPhotos: Bool { PhotoLibrarySaver.canSave(files) }

    /// Photos and videos go to Photos first; documents to Files. Share is always one tap away.
    private var actions: some View {
        VStack(spacing: Theme.Spacing.s) {
            if canSaveToPhotos {
                Button(action: saveToPhotos) {
                    Label(files.count > 1 ? "Save All to Photos" : "Save to Photos", systemImage: "photo.badge.plus")
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("result.savePhotos")
            } else {
                Button {
                    export = IdentifiableURLs(urls: urls)
                } label: {
                    Label(files.count > 1 ? "Save All to Files" : "Save to Files", systemImage: "folder")
                }
                .buttonStyle(PrimaryButtonStyle())
            }

            HStack(spacing: Theme.Spacing.s) {
                Button {
                    Haptics.impact(.light)
                    share = IdentifiableURLs(urls: urls)
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(SecondaryButtonStyle())

                if canSaveToPhotos {
                    Button {
                        export = IdentifiableURLs(urls: urls)
                    } label: {
                        Label("Files", systemImage: "folder")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                } else if files.count > 1 {
                    Button(action: shareZip) {
                        Label("ZIP", systemImage: "doc.zipper")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                } else if let file = files.first {
                    Button {
                        renameText = (file.name as NSString).deletingPathExtension
                        renaming = file
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }

            if tool?.input.acceptsFiles == true {
                Button {
                    Haptics.impact(.light)
                    // Back to the tool with its file and settings, to make another version.
                    if !path.isEmpty { path.removeLast() }
                } label: {
                    Label("Make Another", systemImage: "arrow.uturn.backward")
                        .font(.subheadline.weight(.medium))
                }
                .padding(.top, 4)
                .accessibilityIdentifier("result.again")
            }
        }
    }

    private var nextTools: [ToolDefinition]? {
        guard files.count == 1, let format = files.first?.format else { return nil }
        return Array(ToolCatalog.tools(accepting: format).filter { $0.id != run.toolID && !$0.opensMediaConverter }.prefix(3))
    }

    private func continueSection(_ tools: [ToolDefinition]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("Keep going")
                .font(.footnote.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.4)
                .foregroundStyle(Theme.textMuted)
                .padding(.leading, Theme.Spacing.xs)
            VStack(spacing: 0) {
                ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                    Button {
                        if let file = files.first, let input = try? ToolInputFile(url: file.url) {
                            path.append(.tool(tool.id, inputs: [input]))
                        }
                    } label: {
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

    // MARK: Actions

    private func saveToPhotos() {
        Haptics.impact(.light)
        let urls = urls
        Task {
            do {
                try await PhotoLibrarySaver.save(urls)
                Haptics.success()
                showToast(urls.count == 1 ? "Saved to Photos" : "Saved \(urls.count) to Photos")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func shareZip() {
        do {
            let base = files.first.map { ($0.name as NSString).deletingPathExtension } ?? "Files"
            // Never write the archive into History's folder.
            let directory = ToolStorage.newRunDirectory()
            let zip = try ToolStorage.zip(urls, named: tool.map { "\($0.title)" } ?? base, in: directory)
            share = IdentifiableURLs(urls: [zip])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyRename() {
        guard let file = renaming, let name = renameText.nilIfBlank else { return }
        let destination = ToolStorage.uniqueURL(in: file.url.deletingLastPathComponent(), baseName: name, ext: file.url.pathExtension)
        do {
            try FileManager.default.moveItem(at: file.url, to: destination)
            if let index = files.firstIndex(of: file) { files[index] = ToolOutputFile(url: destination) }
            ConversionHistoryStore.shared.renameToolOutput(runID: run.id, from: file.name, to: destination.lastPathComponent)
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func showToast(_ message: String) {
        withAnimation(.snappy) { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            withAnimation(.snappy) { toast = nil }
        }
    }
}
