// Tour — the first-run coach-marks. The live app stays underneath, dimmed,
// with a spotlight cut out around the thing being explained, a card that
// can sit anywhere on screen, and an arrow from the card to the target.
// The spotlight hole is real: taps go through to the app, so every step
// that says "try it" can actually be tried without leaving the tour. The
// tour switches tabs as it goes and follows the user if they wander.
//
// Targets register themselves with `.tourAnchor(.x)`; the overlay reads
// them through a preference so no view needs to know about the tour.

import SwiftUI

// MARK: - Anchors

enum TourAnchor: Hashable {
    case bacCard, drinkPill, stories, games, friends, dms, liveDock
    case tab(TopTab)
}

struct TourAnchorKey: PreferenceKey {
    static var defaultValue: [TourAnchor: Anchor<CGRect>] = [:]
    static func reduce(value: inout [TourAnchor: Anchor<CGRect>], nextValue: () -> [TourAnchor: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Mark a view as something the tour can spotlight. Uses the merging
    /// variant so an anchored view nested inside another (the + DRINK pill
    /// inside the BAC card) doesn't get swallowed by its parent's anchor.
    func tourAnchor(_ id: TourAnchor) -> some View {
        transformAnchorPreference(key: TourAnchorKey.self, value: .bounds) { $0[id] = $1 }
    }
}

// MARK: - Steps

struct TourStep {
    let tab: TopTab
    let anchor: TourAnchor?
    let title: String
    let text: String
    /// A nudge to try the highlighted thing right now (the hole is tappable).
    let tryIt: String?
}

let tourSteps: [TourStep] = [
    TourStep(tab: .timeline, anchor: .bacCard,
             title: "This is your night.",
             text: "Your BAC, live, from the first sip — and it ticks back down as you sober up. Everything else in sejdel feeds this number.",
             tryIt: nil),
    TourStep(tab: .timeline, anchor: .drinkPill,
             title: "Log a drink.",
             text: "One tap per drink. That's the whole job. Go on — it takes you to LIVE, where the night happens.",
             tryIt: "Tap + DRINK"),
    TourStep(tab: .live, anchor: .liveDock,
             title: "Live mode.",
             text: "Quick-add your usual drinks, check in to a bar, go live with a group and watch everyone's BAC side by side. End the night for a full recap you can share.",
             tryIt: "Tap a drink to log it"),
    TourStep(tab: .timeline, anchor: .stories,
             title: "Your friends' nights.",
             text: "Stories from tonight, who's out right now, and the friends map — all on the Home feed.",
             tryIt: nil),
    TourStep(tab: .timeline, anchor: .friends,
             title: "Bring your crew.",
             text: "Add friends here. Group seshes, the friends map and the games all get better with people in them.",
             tryIt: "Tap to add a friend"),
    TourStep(tab: .timeline, anchor: .games,
             title: "Game Night.",
             text: "Five drinking games for the table — Imposter, Never Have I Ever, Pandora's Box, Most Likely To and Speakeasy.",
             tryIt: "Tap the controller to peek"),
    TourStep(tab: .plan, anchor: .tab(.plan),
             title: "Events.",
             text: "Plan a party or a trip, invite the crew, and let the calculator tell you how much to buy.",
             tryIt: nil),
    TourStep(tab: .offers, anchor: .tab(.offers),
             title: "Maps.",
             text: "Bars, tonight's deals and beer prices around you — plus your friends' check-ins.",
             tryIt: nil),
    TourStep(tab: .profile, anchor: .tab(.profile),
             title: "You.",
             text: "Your nights, stats and settings. Connect Apple Health here to unlock Sesh Vitals.",
             tryIt: nil),
    TourStep(tab: .timeline, anchor: nil,
             title: "You're in.",
             text: "Log your first drink, add a friend, start a game. Skål — and never use sejdel to decide whether to drive.",
             tryIt: nil),
]

// MARK: - Modifier

/// Overlays the tour on the live app, switches tabs per step, and follows
/// the user if they tap their way somewhere else mid-tour.
struct TourModifier: ViewModifier {
    @Binding var tab: TopTab
    @Binding var active: Bool
    @State private var index = 0

    private var current: TourStep { tourSteps[min(index, tourSteps.count - 1)] }

    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(TourAnchorKey.self) { anchors in
                if active {
                    GeometryReader { geo in
                        TourOverlay(step: current, index: index, count: tourSteps.count,
                                    target: current.anchor.flatMap { anchors[$0] }.map { geo[$0] },
                                    size: geo.size,
                                    onNext: next, onSkip: finish)
                    }
                    .ignoresSafeArea()
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: active)
            .onChange(of: active) { _, on in
                if on { index = 0; applyTab() }
            }
            .onChange(of: index) { _, _ in applyTab() }
            .onChange(of: tab) { _, t in
                guard active, current.tab != t,
                      let i = tourSteps.firstIndex(where: { $0.tab == t && $0.anchor != nil }) else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { index = i }
            }
    }

    private func next() {
        if index >= tourSteps.count - 1 {
            finish()
        } else {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { index += 1 }
        }
    }

    private func finish() {
        withAnimation(.easeInOut(duration: 0.25)) { active = false }
    }

    private func applyTab() {
        guard active, tab != current.tab else { return }
        withAnimation(.easeInOut(duration: 0.35)) { tab = current.tab }
    }
}

// MARK: - Overlay

private struct TourOverlay: View {
    let step: TourStep
    let index: Int
    let count: Int
    let target: CGRect?
    let size: CGSize
    let onNext: () -> Void
    let onSkip: () -> Void

    @State private var cardHeight: CGFloat = 220

    private var hole: CGRect? { target.map { $0.insetBy(dx: -8, dy: -8) } }
    /// Card goes under a target in the top half, above one in the bottom half.
    private var cardBelow: Bool { (hole?.midY ?? size.height) < size.height * 0.5 }
    private var isLast: Bool { index >= count - 1 }

    private var cardCenterY: CGFloat {
        guard let hole else { return size.height / 2 }
        let gap: CGFloat = 46
        let y = cardBelow ? hole.maxY + gap + cardHeight / 2 : hole.minY - gap - cardHeight / 2
        return min(max(y, cardHeight / 2 + 70), size.height - cardHeight / 2 - 44)
    }
    private var arrowStart: CGPoint {
        CGPoint(x: size.width / 2, y: cardBelow ? cardCenterY - cardHeight / 2 : cardCenterY + cardHeight / 2)
    }
    private var arrowEnd: CGPoint {
        guard let hole else { return arrowStart }
        let x = min(max(hole.midX, 44), size.width - 44)
        return CGPoint(x: x, y: cardBelow ? hole.maxY + 6 : hole.minY - 6)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            dim
            if let hole {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.whiskey, lineWidth: 2)
                    .frame(width: hole.width, height: hole.height)
                    .position(x: hole.midX, y: hole.midY)
                    .shadow(color: Color.whiskey.opacity(0.55), radius: 12)
                    .allowsHitTesting(false)
                PointerArrow(from: arrowStart, to: arrowEnd)
                    .stroke(Color.whiskey, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .allowsHitTesting(false)
                ArrowHead(tip: arrowEnd, pointingUp: cardBelow)
                    .fill(Color.whiskey)
                    .allowsHitTesting(false)
            }
            card
                .frame(width: size.width - 40)
                .background(
                    GeometryReader { g in
                        Color.clear
                            .onAppear { cardHeight = g.size.height }
                            .onChange(of: g.size.height) { _, h in cardHeight = h }
                    }
                )
                .position(x: size.width / 2, y: cardCenterY)
        }
        .frame(width: size.width, height: size.height)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: target)
    }

    /// Four slabs around the spotlight so the hole itself stays tappable.
    private var dim: some View {
        let c = Color.black.opacity(0.74)
        return ZStack(alignment: .topLeading) {
            if let h = hole {
                let top = max(0, h.minY), bottom = max(0, size.height - h.maxY)
                let left = max(0, h.minX), right = max(0, size.width - h.maxX)
                Rectangle().fill(c).frame(width: size.width, height: top).position(x: size.width / 2, y: top / 2)
                Rectangle().fill(c).frame(width: size.width, height: bottom).position(x: size.width / 2, y: h.maxY + bottom / 2)
                Rectangle().fill(c).frame(width: left, height: h.height).position(x: left / 2, y: h.midY)
                Rectangle().fill(c).frame(width: right, height: h.height).position(x: h.maxX + right / 2, y: h.midY)
            } else {
                Rectangle().fill(c).frame(width: size.width, height: size.height).position(x: size.width / 2, y: size.height / 2)
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 5) {
                    ForEach(0..<count, id: \.self) { i in
                        Capsule()
                            .fill(i == index ? Color.whiskey : Color.cream.opacity(0.18))
                            .frame(width: i == index ? 18 : 6, height: 6)
                    }
                }
                Spacer()
                Button(action: onSkip) {
                    Text("SKIP")
                        .font(.system(size: 10, weight: .black, design: .monospaced)).tracking(2)
                        .foregroundStyle(Color.cream.opacity(0.5))
                        .padding(.vertical, 6).padding(.horizontal, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text(step.title)
                .font(.system(size: 26, weight: .heavy, design: .rounded))
                .italic().tracking(-0.8)
                .foregroundStyle(Color.cream)
            Text(step.text)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.8))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if let tryIt = step.tryIt {
                HStack(spacing: 8) {
                    Image(systemName: "hand.tap.fill").font(.system(size: 11, weight: .bold))
                    Text("TRY IT · \(tryIt.uppercased())")
                        .font(.system(size: 10, weight: .black, design: .monospaced)).tracking(1.6)
                }
                .foregroundStyle(Color.ink)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Capsule().fill(Color.whiskey))
            }
            HStack {
                Spacer()
                Button(action: onNext) {
                    HStack(spacing: 6) {
                        Text(isLast ? "LET'S GO" : "NEXT")
                            .font(.system(size: 12, weight: .black, design: .monospaced)).tracking(2)
                        Image(systemName: isLast ? "checkmark" : "arrow.right")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(Capsule().fill(Color.cream))
                }
                .buttonStyle(PressScaleStyle())
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.ink))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(Color.whiskey.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 24, y: 10)
    }
}

/// A gently curved line from the card to the spotlight.
private struct PointerArrow: Shape {
    let from: CGPoint
    let to: CGPoint
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: from)
        let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        let bend: CGFloat = to.x >= from.x ? -28 : 28
        p.addQuadCurve(to: to, control: CGPoint(x: mid.x + bend, y: mid.y))
        return p
    }
}

private struct ArrowHead: Shape {
    let tip: CGPoint
    let pointingUp: Bool
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let d: CGFloat = pointingUp ? 1 : -1
        p.move(to: tip)
        p.addLine(to: CGPoint(x: tip.x - 7, y: tip.y + 11 * d))
        p.addLine(to: CGPoint(x: tip.x + 7, y: tip.y + 11 * d))
        p.closeSubpath()
        return p
    }
}
