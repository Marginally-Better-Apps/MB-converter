import PencilKit
import SwiftUI

/// Saved signatures live in Application Support so they can be reused across documents.
enum SignatureStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent("MBConverter/Signatures", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func all() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "png" }.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return da > db
        }
    }

    static func save(_ data: Data) {
        try? data.write(to: directory.appendingPathComponent("\(UUID().uuidString).png"))
    }

    static func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

struct SignaturePadView: View {
    let onUse: (Data) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var canvas = PKCanvasView()
    @State private var inkColor: UIColor = .black
    @State private var isEmpty = true
    @State private var saveForLater = true
    @State private var saved: [URL] = SignatureStore.all()

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Spacing.l) {
                if !saved.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        Text("Saved")
                            .font(.footnote.weight(.semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.textMuted)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Theme.Spacing.s) {
                                ForEach(saved, id: \.self) { url in
                                    Button {
                                        if let data = try? Data(contentsOf: url) {
                                            onUse(data)
                                            dismiss()
                                        }
                                    } label: {
                                        Image(uiImage: UIImage(contentsOfFile: url.path) ?? UIImage())
                                            .resizable()
                                            .scaledToFit()
                                            .frame(width: 120, height: 56)
                                            .padding(8)
                                            .background(Color.white, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
                                            .overlay { RoundedRectangle(cornerRadius: Theme.Radius.small).strokeBorder(Theme.separator) }
                                    }
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            SignatureStore.delete(url)
                                            saved = SignatureStore.all()
                                        } label: { Label("Delete", systemImage: "trash") }
                                    }
                                }
                            }
                        }
                    }
                }

                VStack(spacing: Theme.Spacing.s) {
                    ZStack(alignment: .bottom) {
                        CanvasRepresentable(canvas: canvas, color: inkColor) { isEmpty = $0 }
                            .background(Color.white)
                        Rectangle()
                            .fill(Color.gray.opacity(0.35))
                            .frame(height: 1)
                            .padding(.horizontal, 28)
                            .padding(.bottom, 44)
                            .allowsHitTesting(false)
                        if isEmpty {
                            Text("Sign here")
                                .font(.callout)
                                .foregroundStyle(.gray)
                                .padding(.bottom, 54)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).strokeBorder(Theme.separator) }

                    HStack {
                        ForEach([UIColor.black, UIColor(hex: 0x0B3D91), UIColor(hex: 0x1F4E79)], id: \.self) { color in
                            Button {
                                inkColor = color
                            } label: {
                                Circle()
                                    .fill(Color(uiColor: color))
                                    .frame(width: 26, height: 26)
                                    .overlay { Circle().strokeBorder(inkColor == color ? Theme.tint : .clear, lineWidth: 2).padding(-4) }
                            }
                            .accessibilityLabel(color == .black ? "Black ink" : "Blue ink")
                        }
                        Spacer()
                        Button("Clear") {
                            canvas.drawing = PKDrawing()
                            isEmpty = true
                        }
                        .disabled(isEmpty)
                    }
                    Toggle("Save for next time", isOn: $saveForLater)
                        .tint(Theme.primary)
                }
                Spacer()
            }
            .padding(Theme.Spacing.l)
            .screenBackground()
            .navigationTitle("Signature")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use") { use() }
                        .fontWeight(.semibold)
                        .disabled(isEmpty)
                }
            }
        }
    }

    private func use() {
        let drawing = canvas.drawing
        let bounds = drawing.bounds.insetBy(dx: -6, dy: -6)
        guard !bounds.isEmpty else { return }
        // Render in light mode so ink keeps its color on white paper.
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: bounds, scale: 3)
        }
        guard let data = image.pngData() else { return }
        if saveForLater { SignatureStore.save(data) }
        onUse(data)
        dismiss()
    }
}

private struct CanvasRepresentable: UIViewRepresentable {
    let canvas: PKCanvasView
    let color: UIColor
    let onChange: (Bool) -> Void

    func makeUIView(context: Context) -> PKCanvasView {
        canvas.drawingPolicy = .anyInput
        canvas.backgroundColor = .white
        canvas.isOpaque = true
        canvas.overrideUserInterfaceStyle = .light
        canvas.delegate = context.coordinator
        canvas.tool = PKInkingTool(.pen, color: color, width: 4)
        return canvas
    }

    func updateUIView(_ view: PKCanvasView, context: Context) {
        view.tool = PKInkingTool(.pen, color: color, width: 4)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let onChange: (Bool) -> Void
        init(onChange: @escaping (Bool) -> Void) { self.onChange = onChange }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            onChange(canvasView.drawing.strokes.isEmpty)
        }
    }
}
