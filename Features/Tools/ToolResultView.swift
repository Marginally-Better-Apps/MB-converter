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
                if let text = run.output.text { textCard(text) }
                filesCard
                actions
                if let next = nextTools, !next.isEmpty { continueSection(next) }
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.s)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .screenBackground()
        .navigationTitle("Done")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Finish") {
                    Haptics.impact(.light)
                    path.removeAll()
                }
                .fontWeight(.semibold)
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

    private var actions: some View {
        VStack(spacing: Theme.Spacing.s) {
            Button {
                Haptics.impact(.light)
                share = IdentifiableURLs(urls: urls)
            } label: {
                Label(files.count > 1 ? "Share All" : "Share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(PrimaryButtonStyle())

            HStack(spacing: Theme.Spacing.s) {
                Button {
                    export = IdentifiableURLs(urls: urls)
                } label: {
                    Label("Save to Files", systemImage: "folder")
                }
                .buttonStyle(SecondaryButtonStyle())

                if files.count > 1 {
                    Button(action: shareZip) {
                        Label("ZIP", systemImage: "doc.zipper")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                } else if let file = files.first, file.format?.family == .image {
                    Button {
                        if let data = try? Data(contentsOf: file.url), let image = UIImage(data: data) {
                            UIPasteboard.general.image = image
                            Haptics.success()
                            showToast("Image copied")
                        }
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
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
        }
    }

    private var nextTools: [ToolDefinition]? {
        guard files.count == 1, let format = files.first?.format else { return nil }
        return Array(ToolCatalog.tools(accepting: format).filter { $0.id != run.toolID && !$0.opensMediaConverter }.prefix(6))
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
