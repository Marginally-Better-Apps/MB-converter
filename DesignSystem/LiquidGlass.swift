import SwiftUI

// Liquid Glass belongs to the control layer that floats above content:
// toolbars, floating buttons, and badges over media. Content itself sits on
// solid grouped surfaces. Before iOS 26 the same controls fall back to
// system materials so the hierarchy stays the same.

extension View {
    /// Places this view on Liquid Glass, or on a thin material before iOS 26.
    @ViewBuilder
    func glassSurface<S: Shape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(makeGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
                .background {
                    if let tint {
                        shape.fill(tint.opacity(0.85))
                    }
                }
                .overlay {
                    shape.stroke(Color.white.opacity(0.16), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
        }
    }

    /// The system glass button style, or its bordered equivalent before iOS 26.
    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else {
            if prominent {
                buttonStyle(.borderedProminent)
            } else {
                buttonStyle(.bordered)
            }
        }
    }

    /// A bar pinned to the bottom edge. On iOS 26 the scroll edge effect
    /// softens content beneath it; earlier versions fade the canvas in.
    @ViewBuilder
    func floatingBottomBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .bottom) {
                bar()
            }
        } else {
            safeAreaInset(edge: .bottom, spacing: 0) {
                bar()
                    .background {
                        LinearGradient(
                            colors: [Theme.background.opacity(0), Theme.background.opacity(0.94), Theme.background],
                            startPoint: .top,
                            endPoint: .center
                        )
                        .ignoresSafeArea()
                    }
            }
        }
    }

    /// Lets the tab bar collapse while reading long screens on iOS 26.
    @ViewBuilder
    func minimizesTabBarOnScroll() -> some View {
        if #available(iOS 26.0, *) {
            tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }

    /// A solid grouped card, matching iOS 26 inset lists.
    func surfaceCard(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

@available(iOS 26.0, *)
private func makeGlass(tint: Color?, interactive: Bool) -> Glass {
    var glass = Glass.regular
    if let tint {
        glass = glass.tint(tint)
    }
    if interactive {
        glass = glass.interactive()
    }
    return glass
}

/// Groups nearby glass shapes so they blend and morph together on iOS 26.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

/// A full-width primary action, like Play in Apple Music.
struct PrimaryActionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 30)
    }
}

/// Bold shelf heading used above grouped content.
struct SectionHeader: View {
    let title: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 8)

            if let actionTitle, let action {
                Button(actionTitle) {
                    Haptics.impact(.light)
                    action()
                }
                .font(.body)
                .foregroundStyle(Theme.tint)
            }
        }
    }
}

/// Small caption heading inside a grouped card, like an inset list header.
struct CardHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.textMuted)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A Settings-style rounded icon.
struct IconTile: View {
    let systemImage: String
    var isEnabled = true
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 30

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.5, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                isEnabled ? AnyShapeStyle(Theme.iconGradient) : AnyShapeStyle(Color(uiColor: .systemGray3)),
                in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

/// Gentle press feedback for large custom tiles.
struct PressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Row highlight for custom list rows inside a card.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color(uiColor: .systemFill) : Color.clear)
            .contentShape(Rectangle())
    }
}

/// A media editor slider. The title, value and options share one line so the
/// slider gets the card's full width below them.
struct EditorSliderRow<SliderContent: View, Accessory: View>: View {
    let title: String
    let systemImage: String
    let value: String
    let valueIdentifier: String
    @ViewBuilder let slider: SliderContent
    @ViewBuilder let accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(title)
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                Text(value)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textMuted)
                    .accessibilityIdentifier(valueIdentifier)
                accessory
            }
            .font(.subheadline)
            .frame(minHeight: 44)

            slider
                .tint(Theme.tint)
        }
    }
}

extension EditorSliderRow where Accessory == EmptyView {
    init(title: String, systemImage: String, value: String, valueIdentifier: String,
         @ViewBuilder slider: () -> SliderContent) {
        self.init(title: title, systemImage: systemImage, value: value, valueIdentifier: valueIdentifier,
                  slider: slider, accessory: { EmptyView() })
    }
}

/// App Store–style strip of short facts: caption over value, divided columns.
struct InfoStrip: View {
    let rows: [MetadataRow]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.label)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textMuted)
                        Text(row.value)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.text)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ViewThatFits(in: .horizontal) {
                columns(fill: true)
                ScrollView(.horizontal) {
                    columns(fill: false)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func columns(fill: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Rectangle()
                        .fill(Theme.separator)
                        .frame(width: 0.5, height: 30)
                        .accessibilityHidden(true)
                }
                VStack(spacing: 5) {
                    Text(row.label.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                    Text(row.value)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .monospacedDigit()
                }
                .fixedSize()
                .padding(.horizontal, 12)
                .frame(maxWidth: fill ? .infinity : nil)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Circular progress in the icon's blue, with an indeterminate spin.
struct ProgressRing: View {
    /// `nil` shows an indeterminate spinner.
    let progress: Double?
    var lineWidth: CGFloat = 14

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSpinning = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.tint.opacity(0.14), lineWidth: lineWidth)

            if let progress {
                Circle()
                    .trim(from: 0, to: max(0.001, min(1, progress)))
                    .stroke(ringStyle, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: progress)
            } else if reduceMotion {
                ProgressView()
                    .controlSize(.large)
                    .tint(Theme.tint)
            } else {
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(ringStyle, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(isSpinning ? 270 : -90))
                    .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: isSpinning)
                    .onAppear { isSpinning = true }
            }
        }
        .padding(lineWidth / 2)
        .accessibilityHidden(true)
    }

    private var ringStyle: Color {
        Theme.tint
    }
}
