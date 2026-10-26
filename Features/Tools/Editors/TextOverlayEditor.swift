import SwiftUI

/// Type and arrange text boxes right on the photo: tap a box to type, drag to move, pinch and twist
/// to resize and rotate, "Add text" for more. Every box is drawn by `CaptionRenderer`, the same code
/// that makes the output, so the canvas is exactly what you'll get.
struct TextOverlayEditor: View {
    let url: URL
    let preset: TextOverlay.Preset
    /// Photos the text goes on (it's placed the same on each).
    let imageCount: Int
    @Binding var overlays: [TextOverlay]

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var selectedID: UUID?
    @State private var dragStart: CGPoint?
    @State private var isDragging = false
    @State private var pinchStart: (size: Double, rotation: Double)?
    @State private var snapped = false
    @State private var renders = RenderCache()
    @FocusState private var isTyping: Bool

    private static let colors: [UInt32] = [0xFFFFFF, 0x000000, 0xFFD60A, 0xFF453A, 0x0A84FF, 0x30D158]

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                if let image {
                    let fitted = fittedSize(image.size, in: CGSize(width: geometry.size.width - 24, height: geometry.size.height - 16))
                    canvas(image: image, fitted: fitted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            controls
        }
        .task(id: url) {
            if let cg = try? ImageToolkit.load(url, maxPixelSize: 1_600) { image = UIImage(cgImage: cg) }
        }
    }

    // MARK: Canvas

    private func canvas(image: UIImage, fitted: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Image(uiImage: image)
                .resizable()
                .frame(width: fitted.width, height: fitted.height)
                .contentShape(Rectangle())
                .onTapGesture { deselect() }
            if snapped {
                Rectangle()
                    .fill(Theme.tint)
                    .frame(width: 1.5, height: fitted.height)
                    .offset(x: fitted.width / 2 - 0.75)
                    .allowsHitTesting(false)
            }
            ForEach(Array(overlays.enumerated()), id: \.element.id) { index, box in
                boxView(box, index: index, imageSize: image.size, fitted: fitted)
            }
        }
        .frame(width: fitted.width, height: fitted.height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        // Pinch and twist anywhere on the photo to size and turn the selected box (only while one
        // is selected, so they never get in the way of tapping a box).
        .simultaneousGesture(MagnifyGesture()
            .onChanged { value in
                guard let index = selectedIndex else { return }
                if pinchStart == nil { pinchStart = (overlays[index].relativeSize, overlays[index].rotation) }
                overlays[index].relativeSize = min(max(pinchStart!.size * value.magnification, 0.02), 0.4)
            }
            .onEnded { _ in pinchStart = nil }, including: selectedID == nil ? .subviews : .all)
        .simultaneousGesture(RotateGesture()
            .onChanged { value in
                guard let index = selectedIndex else { return }
                if pinchStart == nil { pinchStart = (overlays[index].relativeSize, overlays[index].rotation) }
                var degrees = pinchStart!.rotation + value.rotation.degrees
                if abs(degrees.remainder(dividingBy: 90)) < 4 { degrees = (degrees / 90).rounded() * 90 }
                overlays[index].rotation = degrees
            }
            .onEnded { _ in pinchStart = nil }, including: selectedID == nil ? .subviews : .all)
    }

    @ViewBuilder
    private func boxView(_ box: TextOverlay, index: Int, imageSize: CGSize, fitted: CGSize) -> some View {
        let scale = fitted.width / max(imageSize.width, 1)
        let center = center(of: box, imageSize: imageSize)
        let isSelected = selectedID == box.id
        Group {
            if box.isEmpty {
                // Not drawn in the output: just shows where the words will go.
                Text("Tap to type")
                    .font(.system(size: max(13, box.relativeSize * min(imageSize.width, imageSize.height) * scale * 0.7), weight: .heavy))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            } else if let rendered = renders.image(for: box, imageSize: imageSize, scale: scale * displayScale) {
                Image(uiImage: rendered)
                    .resizable()
                    .frame(width: rendered.size.width / displayScale, height: rendered.size.height / displayScale)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(style: StrokeStyle(lineWidth: isSelected ? 2 : 1.2, dash: [5, 4]))
                .foregroundStyle(isSelected ? Theme.tint : Color.white.opacity(box.isEmpty ? 0.9 : 0.5))
        }
        .rotationEffect(.degrees(box.rotation))
        .contentShape(Rectangle())
        .position(x: center.x * fitted.width, y: center.y * fitted.height)
        // One gesture for both: a press that doesn't move is a tap (type), one that moves drags.
        .gesture(dragGesture(box, imageSize: imageSize, fitted: fitted))
        .accessibilityAction { select(box.id, typing: true) }
        .accessibilityElement()
        .accessibilityLabel(box.isEmpty ? "Empty text box \(index + 1)" : "Text: \(box.text)")
        .accessibilityHint("Double-tap to type. Drag to move.")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("text.box.\(index)")
    }

    private func dragGesture(_ box: TextOverlay, imageSize: CGSize, fitted: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let index = overlays.firstIndex(where: { $0.id == box.id }) else { return }
                guard isDragging || hypot(value.translation.width, value.translation.height) > 6 else { return }
                isDragging = true
                if dragStart == nil {
                    dragStart = center(of: overlays[index], imageSize: imageSize)
                    select(box.id, typing: false)
                }
                guard let start = dragStart else { return }
                var x = start.x + value.translation.width / fitted.width
                let y = start.y + value.translation.height / fitted.height
                let wasSnapped = snapped
                snapped = abs(x - 0.5) < 0.02
                if snapped {
                    x = 0.5
                    if !wasSnapped { Haptics.selection() }
                }
                overlays[index].center = CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
            }
            .onEnded { _ in
                if !isDragging { select(box.id, typing: true) }
                isDragging = false
                dragStart = nil
                snapped = false
            }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: Theme.Spacing.s) {
            if let index = selectedIndex {
                HStack(spacing: Theme.Spacing.s) {
                    TextField("Type here", text: $overlays[index].text)
                        .focused($isTyping)
                        .submitLabel(.done)
                        .onSubmit { isTyping = false }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                        .accessibilityIdentifier("text.field")
                    Button(role: .destructive) {
                        withAnimation(.snappy) { delete(at: index) }
                    } label: {
                        Image(systemName: "trash").frame(width: 36, height: 36)
                    }
                    .accessibilityLabel("Delete this text")
                }
                styleRow(index)
            } else {
                Text(overlays.contains { !$0.isEmpty } ? "Tap text to change it · drag to move · pinch to resize" : "Tap a box on the photo and type")
                    .font(.footnote)
                    .foregroundStyle(Theme.textMuted)
            }
            if !isTyping {
            HStack {
                Button {
                    withAnimation(.snappy) { addBox() }
                } label: {
                    Label("Add text", systemImage: "plus")
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("text.add")
                if imageCount > 1 {
                    Text("Same text on all \(imageCount) photos")
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                }
            }
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.s)
    }

    private func styleRow(_ index: Int) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.s) {
                ForEach(CaptionRenderer.Font.allCases, id: \.self) { font in
                    FilterChip(title: font.label, isSelected: overlays[index].font == font) { overlays[index].font = font }
                }
                Divider().frame(height: 24)
                ForEach(Self.colors, id: \.self) { hex in
                    Button { overlays[index].colorHex = hex } label: {
                        Circle()
                            .fill(Color(uiColor: UIColor(hex: hex)))
                            .frame(width: 26, height: 26)
                            .overlay { Circle().strokeBorder(Theme.separator, lineWidth: 1) }
                            .overlay {
                                if overlays[index].colorHex == hex {
                                    Circle().strokeBorder(Theme.tint, lineWidth: 3).padding(-4)
                                }
                            }
                    }
                    .accessibilityLabel("Color")
                }
                Divider().frame(height: 24)
                FilterChip(title: "Outline", isSelected: overlays[index].outlined) { overlays[index].outlined.toggle() }
                FilterChip(title: "ALL CAPS", isSelected: overlays[index].allCaps) { overlays[index].allCaps.toggle() }
                if preset == .watermark {
                    Divider().frame(height: 24)
                    Image(systemName: "circle.lefthalf.filled").foregroundStyle(Theme.textMuted)
                    Slider(value: $overlays[index].opacity, in: 0.15 ... 1)
                        .frame(width: 120)
                        .accessibilityLabel("Opacity")
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: Actions

    private var selectedIndex: Int? {
        selectedID.flatMap { id in overlays.firstIndex { $0.id == id } }
    }

    private func select(_ id: UUID, typing: Bool) {
        if selectedID != id { Haptics.selection() }
        selectedID = id
        if typing { isTyping = true }
    }

    private func deselect() {
        selectedID = nil
        isTyping = false
    }

    private func addBox() {
        let box = TextOverlay.added(after: overlays, preset: preset)
        overlays.append(box)
        select(box.id, typing: true)
    }

    private func delete(at index: Int) {
        overlays.remove(at: index)
        deselect()
    }

    /// Where a box sits now, as fractions of the image.
    private func center(of box: TextOverlay, imageSize: CGSize) -> CGPoint {
        if let center = box.center { return center }
        var caption = box.caption
        if box.isEmpty { caption.text = "TAP TO TYPE" }
        caption.position = nil
        let layout = CaptionRenderer.layout(caption, imageSize: imageSize)
        let point = CaptionRenderer.center(caption, layout: layout, imageSize: imageSize)
        return CGPoint(x: point.x / max(imageSize.width, 1), y: point.y / max(imageSize.height, 1))
    }

    private func fittedSize(_ size: CGSize, in bounds: CGSize) -> CGSize {
        let scale = min(bounds.width / max(size.width, 1), bounds.height / max(size.height, 1))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

/// Renders each box once per look (text, font, size, color…) rather than on every drag frame.
private final class RenderCache {
    private struct Key: Hashable {
        let caption: ImageToolkit.Caption
        let scale: CGFloat
    }

    private var images: [Key: UIImage] = [:]

    func image(for box: TextOverlay, imageSize: CGSize, scale: CGFloat) -> UIImage? {
        var caption = box.caption
        caption.position = nil
        caption.rotation = 0
        let key = Key(caption: caption, scale: (scale * 100).rounded() / 100)
        if let cached = images[key] { return cached }
        if images.count > 64 { images.removeAll() }
        let image = CaptionRenderer.image(caption, imageSize: imageSize, scale: key.scale)
        images[key] = image
        return image
    }
}
