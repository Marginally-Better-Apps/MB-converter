import SwiftUI

struct ImageCropEditorView: View {
    let url: URL
    /// Shown inline on the tool screen: no navigation bar or Done/Cancel; every change is reported.
    var embedded = false
    let onDone: (CGRect) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var rect: CGRect
    @State private var aspect: AspectPreset = .free
    @State private var dragStart: CGRect?

    init(url: URL, initialRect: CGRect?, embedded: Bool = false, onDone: @escaping (CGRect) -> Void) {
        self.url = url
        self.embedded = embedded
        self.onDone = onDone
        _rect = State(initialValue: initialRect ?? CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    enum AspectPreset: String, CaseIterable, Identifiable {
        case free, original, square, portrait45, landscape32, wide169, story916

        var id: String { rawValue }

        var label: String {
            switch self {
            case .free: "Free"
            case .original: "Original"
            case .square: "1:1"
            case .portrait45: "4:5"
            case .landscape32: "3:2"
            case .wide169: "16:9"
            case .story916: "9:16"
            }
        }

        func ratio(imageSize: CGSize) -> CGFloat? {
            switch self {
            case .free: nil
            case .original: imageSize.width / max(imageSize.height, 1)
            case .square: 1
            case .portrait45: 4.0 / 5.0
            case .landscape32: 3.0 / 2.0
            case .wide169: 16.0 / 9.0
            case .story916: 9.0 / 16.0
            }
        }
    }

    var body: some View {
        if embedded {
            VStack(spacing: 0) {
                cropArea
                HStack(spacing: Theme.Spacing.s) {
                    aspectChips
                    Button("Reset") { reset() }
                        .font(.subheadline.weight(.medium))
                        .disabled(rect == CGRect(x: 0, y: 0, width: 1, height: 1))
                        .padding(.trailing, Theme.Spacing.l)
                }
            }
            .task { loadImage() }
            .onChange(of: rect) { _, rect in onDone(rect) }
        } else {
            sheet
        }
    }

    private var cropArea: some View {
        GeometryReader { geometry in
            if let image {
                let fitted = fittedSize(image.size, in: CGSize(width: geometry.size.width - 40, height: geometry.size.height - 40))
                ZStack(alignment: .topLeading) {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: fitted.width, height: fitted.height)
                    cropOverlay(size: fitted)
                }
                .frame(width: fitted.width, height: fitted.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var aspectChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.s) {
                ForEach(AspectPreset.allCases) { preset in
                    FilterChip(title: preset.label, isSelected: aspect == preset) {
                        aspect = preset
                        applyAspect()
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.m)
        }
    }

    private func reset() {
        aspect = .free
        withAnimation(.snappy) { rect = CGRect(x: 0, y: 0, width: 1, height: 1) }
    }

    private func loadImage() {
        if image == nil, let cg = try? ImageToolkit.load(url, maxPixelSize: 2_000) { image = UIImage(cgImage: cg) }
    }

    private var sheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GeometryReader { geometry in
                    if let image {
                        let fitted = fittedSize(image.size, in: CGSize(width: geometry.size.width - 40, height: geometry.size.height - 40))
                        ZStack(alignment: .topLeading) {
                            Image(uiImage: image)
                                .resizable()
                                .frame(width: fitted.width, height: fitted.height)
                            cropOverlay(size: fitted)
                        }
                        .frame(width: fitted.width, height: fitted.height)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.s) {
                        ForEach(AspectPreset.allCases) { preset in
                            FilterChip(title: preset.label, isSelected: aspect == preset) {
                                aspect = preset
                                applyAspect()
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.l)
                    .padding(.vertical, Theme.Spacing.m)
                }
                .background(.bar)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Crop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .principal) {
                    Button("Reset") {
                        aspect = .free
                        withAnimation(.snappy) { rect = CGRect(x: 0, y: 0, width: 1, height: 1) }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onDone(rect)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            if image == nil, let cg = try? ImageToolkit.load(url, maxPixelSize: 2_000) { image = UIImage(cgImage: cg) }
        }
    }

    private func fittedSize(_ size: CGSize, in bounds: CGSize) -> CGSize {
        let scale = min(bounds.width / max(size.width, 1), bounds.height / max(size.height, 1))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private func cropOverlay(size: CGSize) -> some View {
        let pixel = CGRect(x: rect.minX * size.width, y: rect.minY * size.height, width: rect.width * size.width, height: rect.height * size.height)
        return ZStack(alignment: .topLeading) {
            // Dim everything outside the crop.
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                path.addRect(pixel)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Rectangle()
                .strokeBorder(Color.white, lineWidth: 1.5)
                .overlay {
                    // Rule-of-thirds guides.
                    GeometryReader { box in
                        Path { path in
                            for fraction in [1.0 / 3.0, 2.0 / 3.0] {
                                path.move(to: CGPoint(x: box.size.width * fraction, y: 0))
                                path.addLine(to: CGPoint(x: box.size.width * fraction, y: box.size.height))
                                path.move(to: CGPoint(x: 0, y: box.size.height * fraction))
                                path.addLine(to: CGPoint(x: box.size.width, y: box.size.height * fraction))
                            }
                        }
                        .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                    }
                }
                .frame(width: pixel.width, height: pixel.height)
                .contentShape(Rectangle())
                .offset(x: pixel.minX, y: pixel.minY)
                .gesture(moveGesture(size: size))

            ForEach(Corner.allCases, id: \.self) { corner in
                Circle()
                    .fill(Color.white)
                    .frame(width: 22, height: 22)
                    .shadow(radius: 2)
                    .position(corner.point(in: pixel))
                    .gesture(resizeGesture(corner, size: size))
                    .accessibilityLabel("Crop handle")
            }
        }
    }

    enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        func point(in rect: CGRect) -> CGPoint {
            switch self {
            case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
            case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
            case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
            case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
            }
        }
    }

    private func moveGesture(size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStart == nil { dragStart = rect }
                guard let start = dragStart else { return }
                rect.origin.x = min(max(0, start.minX + value.translation.width / size.width), 1 - start.width)
                rect.origin.y = min(max(0, start.minY + value.translation.height / size.height), 1 - start.height)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resizeGesture(_ corner: Corner, size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStart == nil { dragStart = rect }
                guard let start = dragStart else { return }
                let dx = value.translation.width / size.width
                let dy = value.translation.height / size.height
                var minX = start.minX, minY = start.minY, maxX = start.maxX, maxY = start.maxY
                switch corner {
                case .topLeft: minX += dx; minY += dy
                case .topRight: maxX += dx; minY += dy
                case .bottomLeft: minX += dx; maxY += dy
                case .bottomRight: maxX += dx; maxY += dy
                }
                minX = max(0, min(minX, maxX - 0.05)); maxX = min(1, max(maxX, minX + 0.05))
                minY = max(0, min(minY, maxY - 0.05)); maxY = min(1, max(maxY, minY + 0.05))
                var next = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                if let ratio = aspect.ratio(imageSize: image?.size ?? size) {
                    next = constrained(next, ratio: ratio, anchor: corner, imageSize: image?.size ?? size)
                }
                rect = next
            }
            .onEnded { _ in dragStart = nil }
    }

    /// Adjusts height to match the aspect ratio (in pixel space), anchored at the opposite corner.
    private func constrained(_ next: CGRect, ratio: CGFloat, anchor corner: Corner, imageSize: CGSize) -> CGRect {
        let imageAspect = imageSize.width / max(imageSize.height, 1)
        var width = next.width
        var height = width * imageAspect / ratio
        if height > 1 { height = 1; width = height * ratio / imageAspect }
        var result = next
        result.size = CGSize(width: width, height: height)
        if corner == .topLeft || corner == .topRight { result.origin.y = next.maxY - height }
        if corner == .topLeft || corner == .bottomLeft { result.origin.x = next.maxX - width }
        result.origin.x = min(max(0, result.minX), 1 - width)
        result.origin.y = min(max(0, result.minY), 1 - height)
        return result
    }

    private func applyAspect() {
        guard let ratio = aspect.ratio(imageSize: image?.size ?? CGSize(width: 1, height: 1)) else { return }
        withAnimation(.snappy) {
            rect = ImageToolkit.centeredCrop(aspect: ratio, imageSize: image?.size ?? CGSize(width: 1, height: 1))
        }
    }
}
