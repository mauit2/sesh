// Tour — the first-run coach-marks. The live app stays underneath, dimmed,
// with a spotlight cut out around the thing being explained, a compact card
// seated right next to it, and a straight arrow from card to target.
// The spotlight hole is real: taps go through to the app. Steps with a
// call to action have no NEXT — the tour waits until the user actually
// does the thing (or taps "skip this one"), then moves on by itself.
//
// Targets register with `.tourAnchor(.x)`; the overlay reads them through
// a preference. App code that wants to tell the tour "they did it" posts a
// `TourAction`. `TourDemo` lets the tour steer the LIVE sub-tabs and show a
// sample Vitals card while the tour is on that step.

import SwiftUI
import Combine

// MARK: - Anchors

enum TourAnchor: Hashable {
    case bacCard, drinkPill, stories, games, friends, dms, liveDock, mapModes
    case livePane(LiveTab)
    /// The content under the LIVE segment control — lit up with the segment.
    case livePanel
    case tab(TopTab)
}

struct TourAnchorKey: PreferenceKey {
    static var defaultValue: [TourAnchor: Anchor<CGRect>] = [:]
    static func reduce(value: inout [TourAnchor: Anchor<CGRect>], nextValue: () -> [TourAnchor: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Mark a view as something the tour can spotlight. Merging variant, so a
    /// target nested inside another target isn't swallowed by its parent.
    func tourAnchor(_ id: TourAnchor) -> some View {
        transformAnchorPreference(key: TourAnchorKey.self, value: .bounds) { $0[id] = $1 }
    }
}

// MARK: - Signals from the app

/// Things the user can do that a tour step may be waiting for.
enum TourAction: Equatable {
    case liveOpened, drinkLogged, friendsOpened, gamesOpened

    func post() {
        NotificationCenter.default.post(name: .tourAction, object: self)
    }
}

extension Notification.Name {
    static let tourAction = Notification.Name("sejdel.tour.action")
}

/// What the tour asks the live app to show while a step is up.
@MainActor
final class TourDemo: ObservableObject {
    static let shared = TourDemo()
    /// LIVE sub-tab the tour wants on screen (nil = leave it alone).
    @Published var livePane: LiveTab? = nil
    /// Show sample calories/steps/heart-rate in Sesh Vitals.
    @Published var vitalsSample = false
}

// MARK: - Steps

struct TourStep {
    let tab: TopTab
    let anchor: TourAnchor?
    let title: String
    let text: String
    /// Call to action — with one, NEXT disappears and the step waits.
    let tryIt: String?
    let waitFor: TourAction?
    let livePane: LiveTab?
    /// A second region folded into the spotlight so its content stays readable.
    let showcase: TourAnchor?
    /// Pin the card to the bottom of the screen instead of hugging the target.
    let bottomCard: Bool

    init(tab: TopTab, anchor: TourAnchor?, title: String, text: String,
         tryIt: String? = nil, waitFor: TourAction? = nil, livePane: LiveTab? = nil,
         showcase: TourAnchor? = nil, bottomCard: Bool = false) {
        self.showcase = showcase; self.bottomCard = bottomCard
        self.tab = tab; self.anchor = anchor; self.title = title; self.text = text
        self.tryIt = tryIt; self.waitFor = waitFor; self.livePane = livePane
    }
}

let tourSteps: [TourStep] = [
    TourStep(tab: .timeline, anchor: .bacCard,
             title: "This is your night.",
             text: "Your BAC, live, from the first sip — and it ticks back down as you sober up."),
    TourStep(tab: .timeline, anchor: .stories,
             title: "Your friends' nights.",
             text: "Stories from tonight, who's out right now, and the friends map."),
    TourStep(tab: .timeline, anchor: .friends,
             title: "Bring your crew.",
             text: "Group seshes, the friends map and the games all get better with people in them.",
             tryIt: "Tap to add a friend", waitFor: .friendsOpened),
    TourStep(tab: .timeline, anchor: .games,
             title: "Game Night.",
             text: "Five drinking games for the table — Imposter, Never Have I Ever, Pandora's Box, Most Likely To and Speakeasy.",
             tryIt: "Tap the controller", waitFor: .gamesOpened),
    TourStep(tab: .timeline, anchor: .drinkPill,
             title: "Log a drink.",
             text: "One tap per drink. That's the whole job.",
             tryIt: "Tap + DRINK", waitFor: .liveOpened),
    TourStep(tab: .live, anchor: .liveDock,
             title: "Live mode.",
             text: "Your usual drinks, one tap away. Log one now and watch the number move.",
             tryIt: "Tap a drink", waitFor: .drinkLogged),
    TourStep(tab: .live, anchor: .livePane(.group),
             title: "Your group.",
             text: "Everyone's BAC side by side. Start a group sesh or join with a code, and the whole table shows up here.",
             livePane: .group, showcase: .livePanel, bottomCard: true),
    TourStep(tab: .live, anchor: .livePane(.recap),
             title: "Your drinks.",
             text: "Every drink tonight, in order. Fix a count, remove a mistake, see when you had what.",
             livePane: .recap, showcase: .livePanel, bottomCard: true),
    TourStep(tab: .live, anchor: .livePane(.vitals),
             title: "Sesh Vitals.",
             text: "Calories in vs burned, steps and heart rate — live, with Apple Health connected. This is what a night looks like.",
             livePane: .vitals, showcase: .livePanel, bottomCard: true),
    TourStep(tab: .plan, anchor: .tab(.plan),
             title: "Events.",
             text: "Plan a party or a trip, invite the crew, and let the calculator tell you how much to buy."),
    TourStep(tab: .offers, anchor: .mapModes,
             title: "Three maps.",
             text: "DEALS — tonight's specials around you. BEER — every bar's price, green is cheap. SUN — where a terrace still catches it."),
    TourStep(tab: .timeline, anchor: nil,
             title: "You're in.",
             text: "Log your first drink, add a friend, start a game. Skål — and never use sejdel to decide whether to drive."),
]

// MARK: - Modifier

/// Overlays the tour on the live app, switches tabs and LIVE panes per step,
/// waits on call-to-action steps, and follows the user if they wander.
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
                                    showcase: current.showcase.flatMap { anchors[$0] }.map { geo[$0] },
                                    size: geo.size,
                                    onNext: next, onSkip: finish)
                    }
                    .ignoresSafeArea()
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: active)
            .onChange(of: active) { _, on in
                if on { index = 0; apply() } else { release() }
            }
            .onChange(of: index) { _, _ in apply() }
            .onChange(of: tab) { _, t in
                guard active else { return }
                if current.waitFor == .liveOpened, t == .live { next(); return }
                guard current.tab != t,
                      let i = tourSteps.firstIndex(where: { $0.tab == t && $0.anchor != nil }) else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { index = i }
            }
            .onReceive(NotificationCenter.default.publisher(for: .tourAction)) { note in
                guard active, let action = note.object as? TourAction, current.waitFor == action else { return }
                next()
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

    private func apply() {
        guard active else { return }
        if tab != current.tab {
            withAnimation(.easeInOut(duration: 0.35)) { tab = current.tab }
        }
        TourDemo.shared.livePane = current.livePane
        TourDemo.shared.vitalsSample = current.livePane == .vitals
    }

    private func release() {
        TourDemo.shared.livePane = nil
        TourDemo.shared.vitalsSample = false
    }
}

// MARK: - Overlay

private struct TourOverlay: View {
    let step: TourStep
    let index: Int
    let count: Int
    let target: CGRect?
    let showcase: CGRect?
    let size: CGSize
    let onNext: () -> Void
    let onSkip: () -> Void

    @State private var cardHeight: CGFloat = 180

    private let cardInset: CGFloat = 20
    /// Standoff between spotlight and card — room for a real arrow shaft.
    private let gap: CGFloat = 48

    private var screen: CGRect { CGRect(x: 6, y: 6, width: size.width - 12, height: size.height - 12) }

    /// The thing the arrow points at — the target, kept on screen.
    private var pointer: CGRect? {
        guard let target else { return nil }
        let r = target.insetBy(dx: -8, dy: -8).intersection(screen)
        guard !r.isNull, r.width > 4, r.height > 4 else { return nil }
        return r
    }
    /// The lit region: the pointer plus any showcase content, clipped to the
    /// screen and — for a bottom-pinned card — to the space above the card.
    private var hole: CGRect? {
        guard var r = pointer else { return nil }
        if let showcase {
            r = r.union(showcase.insetBy(dx: -8, dy: -8)).intersection(screen)
        }
        if step.bottomCard {
            let limit = bottomCardCenterY - cardHeight / 2 - 14
            if r.maxY > limit { r.size.height = max(0, limit - r.minY) }
        }
        guard !r.isNull, r.width > 4, r.height > 4 else { return nil }
        return r
    }
    private var bottomCardCenterY: CGFloat { size.height - cardHeight / 2 - 24 }
    private var holeRadius: CGFloat {
        guard let hole else { return 18 }
        return min(18, min(hole.width, hole.height) / 2)
    }
    /// Card sits under a target in the top half, above one in the bottom half.
    private var cardBelow: Bool { step.bottomCard || (hole?.midY ?? size.height) < size.height * 0.5 }
    private var isLast: Bool { index >= count - 1 }

    private var cardCenterY: CGFloat {
        if step.bottomCard { return bottomCardCenterY }
        guard let hole else { return size.height / 2 }
        let y = cardBelow ? hole.maxY + gap + cardHeight / 2 : hole.minY - gap - cardHeight / 2
        return min(max(y, cardHeight / 2 + 64), size.height - cardHeight / 2 - 40)
    }
    private var arrowStart: CGPoint {
        let x = min(max(pointer?.midX ?? size.width / 2, cardInset + 34), size.width - cardInset - 34)
        return CGPoint(x: x, y: cardBelow ? cardCenterY - cardHeight / 2 : cardCenterY + cardHeight / 2)
    }
    /// Where the head's tip lands — a hair off the pointer's edge.
    private var arrowEnd: CGPoint {
        guard let pointer else { return arrowStart }
        let x = min(max(pointer.midX, 30), size.width - 30)
        return CGPoint(x: x, y: cardBelow ? pointer.maxY + 3 : pointer.minY - 3)
    }
    /// No stub arrows: skip it when card and target nearly touch.
    private var showArrow: Bool { abs(arrowEnd.y - arrowStart.y) > 34 }
    /// Gentle bend, proportional to length, so it reads as drawn.
    private var arrowControl: CGPoint {
        let s = arrowStart, e = arrowEnd
        let mid = CGPoint(x: (s.x + e.x) / 2, y: (s.y + e.y) / 2)
        let length = hypot(e.x - s.x, e.y - s.y)
        let bend = min(26, length * 0.22)
        return CGPoint(x: mid.x + (e.x >= s.x ? -bend : bend), y: mid.y)
    }
    /// Direction the curve is travelling as it arrives at the tip.
    private var arrowAngle: CGFloat {
        atan2(arrowEnd.y - arrowControl.y, arrowEnd.x - arrowControl.x)
    }
    /// The shaft ends inside the head so the round cap never pokes past it.
    private var shaftEnd: CGPoint {
        let back: CGFloat = 9
        return CGPoint(x: arrowEnd.x - cos(arrowAngle) * back, y: arrowEnd.y - sin(arrowAngle) * back)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            dim
            if let hole {
                RoundedRectangle(cornerRadius: holeRadius, style: .continuous)
                    .strokeBorder(Color.whiskey, lineWidth: 2)
                    .frame(width: hole.width, height: hole.height)
                    .position(x: hole.midX, y: hole.midY)
                    .shadow(color: Color.whiskey.opacity(0.55), radius: 12)
                    .allowsHitTesting(false)
                if showArrow {
                    PointerArrow(from: arrowStart, to: shaftEnd, control: arrowControl)
                        .stroke(Color.whiskey, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .allowsHitTesting(false)
                    ArrowHead(tip: arrowEnd, angle: arrowAngle)
                        .fill(Color.whiskey)
                        .allowsHitTesting(false)
                }
            }
            card
                .frame(width: size.width - cardInset * 2)
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
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: [target, showcase])
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
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 4) {
                    ForEach(0..<count, id: \.self) { i in
                        Capsule()
                            .fill(i == index ? Color.whiskey : Color.cream.opacity(0.18))
                            .frame(width: i == index ? 16 : 5, height: 5)
                    }
                }
                Spacer()
                Button(action: onSkip) {
                    Text("SKIP TOUR")
                        .font(.system(size: 9, weight: .black, design: .monospaced)).tracking(1.8)
                        .foregroundStyle(Color.cream.opacity(0.45))
                        .padding(.vertical, 6).padding(.horizontal, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text(step.title)
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .italic().tracking(-0.6)
                .foregroundStyle(Color.cream)
            Text(step.text)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.8))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if let tryIt = step.tryIt {
                // A call to action: the step waits for the tap, no NEXT.
                HStack(alignment: .center) {
                    HStack(spacing: 8) {
                        Image(systemName: "hand.tap.fill").font(.system(size: 12, weight: .bold))
                        Text(tryIt.uppercased())
                            .font(.system(size: 11, weight: .black, design: .monospaced)).tracking(1.6)
                    }
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Capsule().fill(Color.whiskey))
                    .shadow(color: Color.whiskey.opacity(0.45), radius: 10, y: 4)
                    Spacer()
                    Button(action: onNext) {
                        Text("skip this one")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.45))
                            .padding(.vertical, 8).padding(.horizontal, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 2)
            } else {
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
                        .padding(.horizontal, 18).padding(.vertical, 11)
                        .background(Capsule().fill(Color.cream))
                    }
                    .buttonStyle(PressScaleStyle())
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.ink))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color.whiskey.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 24, y: 10)
    }
}

/// Card → target, nearly straight.
private struct PointerArrow: Shape {
    let from: CGPoint
    let to: CGPoint
    let control: CGPoint
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: from)
        p.addQuadCurve(to: to, control: control)
        return p
    }
}

/// A clean isosceles head, pointing along `angle`, tip exactly at `tip`.
private struct ArrowHead: Shape {
    let tip: CGPoint
    let angle: CGFloat
    func path(in rect: CGRect) -> Path {
        let length: CGFloat = 15, half: CGFloat = 7.5
        let c = cos(angle), s = sin(angle)
        // Base corners: back along the direction, then out to each side.
        let base = CGPoint(x: tip.x - c * length, y: tip.y - s * length)
        let left = CGPoint(x: base.x - s * half, y: base.y + c * half)
        let right = CGPoint(x: base.x + s * half, y: base.y - c * half)
        var p = Path()
        p.move(to: tip)
        p.addLine(to: left)
        p.addLine(to: right)
        p.closeSubpath()
        return p
    }
}
