import SwiftUI

/// Drag captions anywhere on the image. Each caption is drawn by `CaptionRenderer`, the same code
/// that makes the final image, so what you place is exactly what you get.
struct CaptionLayoutEditorView: View {
    let url: URL
    let items: [CaptionItems.Item]
    let onDone: ([String: CGPoint]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var positions: [String: CGPoint]
    @State private var dragStart: [String: CGPoint] = [:]
    @State private var active: String?
    @State private var snapped = false

    init(url: URL, items: [CaptionItems.Item], initialPositions: [String: CGPoint], onDone: @escaping ([String: CGPoint]) -> Void) {
        self.url = url
        self.items = items
        self.onDone = onDone
        _positions = State(initialValue: initialPositions)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GeometryReader { geometry in
                    if let image {
                        let fitted = fittedSize(image.size, in: CGSize(width: geometry.size.width - 32, height: geometry.size.height - 32))
                        ZStack(alignment: .topLeading) {
                            Image(uiImage: image)
                                .resizable()
                                .frame(width: fitted.width, height: fitted.height)
                            if snapped {
                                Rectangle()
                                    .fill(Theme.tint)
                                    .frame(width: 1.5, height: fitted.height)
                                    .offset(x: fitted.width / 2 - 0.75)
                                    .allowsHitTesting(false)
                            }
                            ForEach(items, id: \.key) { item in
                                captionView(item, imageSize: image.size, fitted: fitted)
                            }
                        }
                        .frame(width: fitted.width, height: fitted.height)
                        .clipped()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                Text(items.isEmpty ? "Type some text first, then come back to place it." : "Drag the text to move it. It snaps to the center.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(Theme.Spacing.m)
                    .background(.bar)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Move Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .principal) {
                    Button("Reset") { withAnimation(.snappy) { positions = [:] } }
                        .disabled(positions.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onDone(positions)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("captions.done")
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            if image == nil, let cg = try? ImageToolkit.load(url, maxPixelSize: 1_600) { image = UIImage(cgImage: cg) }
        }
    }

    @ViewBuilder
    private func captionView(_ item: CaptionItems.Item, imageSize: CGSize, fitted: CGSize) -> some View {
        let scale = fitted.width / max(imageSize.width, 1)
        let center = center(of: item, imageSize: imageSize)
        if let rendered = CaptionRenderer.image(item.caption, imageSize: imageSize, scale: scale * displayScale) {
            let size = CGSize(width: rendered.size.width / displayScale, height: rendered.size.height / displayScale)
            Image(uiImage: rendered)
                .resizable()
                .frame(width: size.width, height: size.height)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .foregroundStyle(active == item.key ? Theme.tint : Color.white.opacity(0.55))
                }
                .rotationEffect(.degrees(item.caption.rotation))
                .contentShape(Rectangle())
                .position(x: center.x * fitted.width, y: center.y * fitted.height)
                .gesture(dragGesture(item, imageSize: imageSize, fitted: fitted))
                .accessibilityElement()
                .accessibilityLabel("\(item.label): \(item.caption.text)")
                .accessibilityHint("Drag to move")
                .accessibilityIdentifier("caption.\(item.key)")
        }
    }

    /// Where the caption sits now, as fractions of the image.
    private func center(of item: CaptionItems.Item, imageSize: CGSize) -> CGPoint {
        if let position = positions[item.key] { return position }
        var caption = item.caption
        caption.position = nil
        let layout = CaptionRenderer.layout(caption, imageSize: imageSize)
        let point = CaptionRenderer.center(caption, layout: layout, imageSize: imageSize)
        return CGPoint(x: point.x / max(imageSize.width, 1), y: point.y / max(imageSize.height, 1))
    }

    private func dragGesture(_ item: CaptionItems.Item, imageSize: CGSize, fitted: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStart[item.key] == nil {
                    dragStart[item.key] = center(of: item, imageSize: imageSize)
                    active = item.key
                    Haptics.selection()
                }
                guard let start = dragStart[item.key] else { return }
                var x = start.x + value.translation.width / fitted.width
                let y = start.y + value.translation.height / fitted.height
                let wasSnapped = snapped
                snapped = abs(x - 0.5) < 0.02
                if snapped {
                    x = 0.5
                    if !wasSnapped { Haptics.selection() }
                }
                positions[item.key] = CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
            }
            .onEnded { _ in
                dragStart[item.key] = nil
                active = nil
                snapped = false
            }
    }

    private func fittedSize(_ size: CGSize, in bounds: CGSize) -> CGSize {
        let scale = min(bounds.width / max(size.width, 1), bounds.height / max(size.height, 1))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}
