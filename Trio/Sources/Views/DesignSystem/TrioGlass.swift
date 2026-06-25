import SwiftUI

/// Liquid Glass design system for the Trio reskin (locked "System Blue" direction).
///
/// Tokens + reusable glass components, extracted exactly from the approved design
/// (Trio Apple - System Blue). This is a NEW, self-contained file: the reskinned
/// screens opt into these components while the stock upstream views stay untouched,
/// so future Trio merges remain clean.
///
/// Font mapping: the mockup used Nunito (for numbers/values) and Mulish (for text)
/// as stand-ins for SF Pro Rounded and SF Pro. We use the real system fonts:
/// `TrioGlass.rounded(...)` → SF Pro Rounded, `TrioGlass.text(...)` → SF Pro.
enum TrioGlass {
    // MARK: - Colors (exact hex from the spec)

    enum Colors {
        static let accent = Color(hexRGB: 0x0A84FF) // Apple System Blue
        static let accentText = Color.white

        // Glucose state — color is always paired with shape + label (colorblind-safe).
        static let inRange = Color(hexRGB: 0x2FD39A)
        static let high = Color(hexRGB: 0xF2B441)
        static let low = Color(hexRGB: 0xFF7E8A)
        static let urgent = Color(hexRGB: 0xFF4D6A)

        static let glucoseLine = Color(hexRGB: 0xEDF0F7)
        static let textPrimary = Color(hexRGB: 0xEEF1F8)

        /// Base label color — apply with opacity (0.45 caption … 0.85 value).
        static let labelBase = Color(.sRGB, red: 228 / 255, green: 232 / 255, blue: 244 / 255, opacity: 1)

        // Background field + the dark glass tint.
        static let bgTop = Color(hexRGB: 0x16181F)
        static let bgBottom = Color(hexRGB: 0x08090D)
        static let glassTint = Color(.sRGB, red: 26 / 255, green: 28 / 255, blue: 38 / 255, opacity: 1)

        /// Returns the state color for a glucose value against the user's limits.
        static func state(for value: Decimal, low: Decimal, high: Decimal) -> Color {
            if value <= low { return Colors.low }
            if value >= high { return Colors.high }
            return Colors.inRange
        }
    }

    /// Quiet label color at a given opacity (matches the spec's rgba(228,232,244,a)).
    static func label(_ opacity: Double) -> Color { Colors.labelBase.opacity(opacity) }

    // MARK: - Metrics

    enum Metric {
        static let cardRadius: CGFloat = 20
        static let chartCardRadius: CGFloat = 24
        static let tileRadius: CGFloat = 14
        static let cardStroke: Double = 0.08
        static let cardShadow = Color.black.opacity(0.45)
    }

    // MARK: - Type ramp

    /// SF Pro Rounded — for glucose numbers, values, titles (the mockup's Nunito).
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// SF Pro — for body/label text (the mockup's Mulish).
    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

extension Color {
    /// 0xRRGGBB literal → opaque Color.
    init(hexRGB: UInt) {
        self.init(
            .sRGB,
            red: Double((hexRGB >> 16) & 0xFF) / 255,
            green: Double((hexRGB >> 8) & 0xFF) / 255,
            blue: Double(hexRGB & 0xFF) / 255,
            opacity: 1
        )
    }
}

// MARK: - Animated background

/// The deep radial field with three slow-drifting accent blobs — the depth layer
/// every reskinned screen sits on.
struct TrioGlassBackground: View {
    @State private var drift = false

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [TrioGlass.Colors.bgTop, TrioGlass.Colors.bgBottom],
                center: UnitPoint(x: 0.5, y: 0.06),
                startRadius: 0,
                endRadius: 540
            )
            blob(TrioGlass.Colors.accent.opacity(0.16), 300).offset(x: drift ? 130 : 110, y: -60)
            blob(Color(hexRGB: 0x5A6E8C).opacity(0.10), 260).offset(x: -120, y: drift ? 342 : 360)
            blob(TrioGlass.Colors.accent.opacity(0.10), 280).offset(x: drift ? 96 : 110, y: 560)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 20).repeatForever(autoreverses: true)) { drift = true }
        }
    }

    private func blob(_ color: Color, _ size: CGFloat) -> some View {
        Circle().fill(color).frame(width: size, height: size).blur(radius: 72)
    }
}

// MARK: - Glass surfaces

/// A dark translucent Liquid Glass card: the spec's rgba(26,28,38,.5) tint over a
/// blurred material, with a hairline top-light border and a soft drop shadow.
struct GlassCard<Content: View>: View {
    var radius: CGFloat = TrioGlass.Metric.cardRadius
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(.ultraThinMaterial, in: shape)
            .background(TrioGlass.Colors.glassTint.opacity(0.5), in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(TrioGlass.Metric.cardStroke), lineWidth: 1))
            .overlay(alignment: .top) {
                shape
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.12), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: TrioGlass.Metric.cardShadow, radius: 15, x: 0, y: 14)
    }
}

/// Glanceable two-line stat with a leading icon tile (IOB / COB style): the icon
/// sits left of a label-over-value column.
struct GlassStat: View {
    let systemImage: String
    let label: String
    let value: String
    let unit: String
    var iconColor: Color = TrioGlass.Colors.accent

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: systemImage).font(.system(size: 15, weight: .semibold)).foregroundStyle(iconColor))
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(TrioGlass.text(11, .bold)).tracking(0.4)
                    .foregroundStyle(TrioGlass.label(0.45))
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value).font(TrioGlass.rounded(18, .heavy)).foregroundStyle(TrioGlass.Colors.textPrimary)
                    Text(unit).font(TrioGlass.text(11, .semibold)).foregroundStyle(TrioGlass.label(0.45))
                }
            }
        }
    }
}

/// The "IN RANGE" status pill — color + filled dot + word (never color alone).
struct GlassStatePill: View {
    let text: String
    var color: Color = TrioGlass.Colors.inRange

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(text).font(TrioGlass.rounded(13, .heavy)).tracking(0.3).foregroundStyle(color)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(color.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.38)))
    }
}

/// Section header (e.g. "LOOP & BASAL") — quiet heavy small-caps label.
struct GlassSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(TrioGlass.rounded(12, .heavy)).tracking(0.7)
            .foregroundStyle(TrioGlass.label(0.45))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
    }
}

/// System-Blue-tinted glass toggle matching the spec (on = accent + glow).
struct GlassToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 12)
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? AnyShapeStyle(TrioGlass.Colors.accent) : AnyShapeStyle(Color.white.opacity(0.08)))
                    .overlay(configuration.isOn ? nil : Capsule().strokeBorder(Color.white.opacity(0.12)))
                    .frame(width: 50, height: 30)
                    .shadow(color: configuration.isOn ? TrioGlass.Colors.accent.opacity(0.5) : .clear, radius: 7)
                Circle()
                    .fill(configuration.isOn ? Color.white : TrioGlass.label(0.6))
                    .frame(width: 24, height: 24)
                    .padding(3)
            }
            .onTapGesture { withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { configuration.isOn.toggle() } }
        }
    }
}
