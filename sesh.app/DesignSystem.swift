// Calm design system — the shared visual primitives (type scale, card
// surface, section label, primary button, stat row) every screen builds
// on. Extracted from content_view.swift; pure relocation.

import SwiftUI

// MARK: - Calm design system
//
// One visual voice for the whole app. Rules the components below enforce:
//  - Cards carry exactly ONE soft shadow; the whiskey glow belongs to the
//    single primary action per screen (PrimaryGlowButton) and nothing else.
//  - Mono-caps labels exist only via SectionLabel (tracking capped at +2).
//  - Type scale: hero 40 / title 20 / body 14 / label 10.

enum CalmType {
    static func hero(_ size: CGFloat = 40) -> Font {
        .system(size: size, weight: .black, design: .rounded)
    }
    static func title(_ size: CGFloat = 20) -> Font {
        .system(size: size, weight: .heavy, design: .rounded)
    }
    static func body(_ size: CGFloat = 14, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
    static func label(_ size: CGFloat = 10) -> Font {
        .system(size: size, weight: .semibold, design: .monospaced)
    }
}

/// The single card surface. Quiet by design: elevated ink, hairline stroke,
/// one soft shadow — no glows, no tints.
struct CalmCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.inkElev)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.cream.opacity(0.06), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
    }
}

/// The one sanctioned mono-caps section label.
struct SectionLabel: View {
    let text: String
    var color: Color = .bronze

    init(_ text: String, color: Color = .bronze) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(CalmType.label())
            .tracking(2)
            .foregroundStyle(color)
    }
}

/// The only component allowed the whiskey glow — one per screen.
struct PrimaryGlowButton: View {
    let title: String
    var systemImage: String? = nil
    var tint: Color = .whiskey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                }
                Text(title.uppercased())
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .tracking(2)
            }
            .foregroundStyle(Color.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(tint)
            )
            .shadow(color: tint.opacity(0.45), radius: 16, y: 8)
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// Quiet key-value row — replaces what used to be its own mini-card.
struct StatRow: View {
    let icon: String
    let title: String
    var value: String? = nil
    var valueColor: Color = .cream

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.bronze)
                .frame(width: 20)
            Text(title)
                .font(CalmType.body())
                .foregroundStyle(Color.cream.opacity(0.85))
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .font(CalmType.body(14, weight: .bold).monospacedDigit())
                    .foregroundStyle(valueColor)
            }
        }
        .padding(.vertical, 6)
    }
}

/// Thin separator for rows inside a CalmCard.
struct CalmDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.cream.opacity(0.06))
            .frame(height: 1)
    }
}


// MARK: - Palette

// Internal (not fileprivate) so sibling files in the app target — e.g.
// BarcodeScanner.swift — can use the same palette without duplicating the
// hex values. The widget extension is a separate module and keeps its own
// local copy.
extension Color {
    static let ink     = Color(red: 0.043, green: 0.039, blue: 0.031)
    static let inkElev = Color(red: 0.075, green: 0.067, blue: 0.055)
    static let whiskey = Color(red: 0.910, green: 0.659, blue: 0.290)
    static let cream   = Color(red: 0.961, green: 0.929, blue: 0.878)
    static let bronze  = Color(red: 0.541, green: 0.498, blue: 0.431)
    static let smoke   = Color(red: 0.192, green: 0.176, blue: 0.149)
    static let stout   = Color(red: 0.035, green: 0.020, blue: 0.010)
    static let foam    = Color(red: 0.975, green: 0.915, blue: 0.810)
}


// MARK: - Sejdel dimples

/// The dimpled glass of a sejdel as a living surface: a staggered grid of
/// glassy dents drifting slowly diagonally, like holding the mug up to the
/// light and turning it. Sits UNDER content at very low opacity — texture,
/// not decoration. Freezes (offset zero) when Reduce Motion is on.
struct DimpleDriftBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Overall strength of the texture. 0.10 reads on ink; lower for busy screens.
    var strength: Double = 0.10
    /// Drift speed in points/second. Keep gentle — this is ambience.
    var speed: Double = 5
    /// Scales dimple size and pitch: <1 reads as a farther glass layer.
    var scale: CGFloat = 1

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            Canvas { ctx, size in
                let tileW: CGFloat = 92 * scale  // horizontal dimple pitch
                let tileH: CGFloat = 52 * scale  // row pitch (staggered)
                let r: CGFloat = 19 * scale
                let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                let dx = CGFloat((t * speed).truncatingRemainder(dividingBy: Double(tileW)))
                let dy = CGFloat((t * speed * 1.13).truncatingRemainder(dividingBy: Double(tileH * 2)))

                var row = 0
                var y = -tileH * 2 + dy
                while y < size.height + tileH {
                    let stagger = row.isMultiple(of: 2) ? 0 : tileW / 2
                    var x = -tileW + stagger + dx
                    while x < size.width + tileW {
                        let c = CGPoint(x: x, y: y)
                        // Glass dent: faint amber body, bright crescent where
                        // light enters (top-left), dark crescent opposite.
                        let body = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                        ctx.fill(body, with: .radialGradient(
                            Gradient(colors: [Color.whiskey.opacity(0.28), Color.whiskey.opacity(0.02)]),
                            center: CGPoint(x: c.x - r * 0.25, y: c.y - r * 0.3),
                            startRadius: 0, endRadius: r * 1.15))
                        var lit = Path()
                        lit.addArc(center: c, radius: r - 1,
                                   startAngle: .degrees(120), endAngle: .degrees(255), clockwise: false)
                        ctx.stroke(lit, with: .color(Color.foam.opacity(0.5)),
                                   style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                        var shade = Path()
                        shade.addArc(center: c, radius: r - 0.5,
                                     startAngle: .degrees(300), endAngle: .degrees(75), clockwise: false)
                        ctx.stroke(shade, with: .color(Color.stout.opacity(0.8)),
                                   style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                        x += tileW
                    }
                    row += 1
                    y += tileH
                }
            }
            .opacity(strength)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}
