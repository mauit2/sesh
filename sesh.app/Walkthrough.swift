// Full guided walkthrough — a step-by-step tour that dims the live app and
// steps through each real screen (switching tabs as it goes), annotating what
// every screen does and its key functions. Deeper than the first-run
// WelcomeTourView; launched from the profile ("Full walkthrough").

import SwiftUI

private struct WalkthroughStep {
    /// Tab to switch the live app to for this step (nil = intro/outro).
    let tab: TopTab?
    let kicker: String
    let title: String
    let blurb: String
    /// (SF Symbol, one-line explanation) for each function on this screen.
    let functions: [(icon: String, label: String)]
    /// Show the arrow pointing down at the tab bar.
    let arrow: Bool
}

private let walkthroughSteps: [WalkthroughStep] = [
    WalkthroughStep(
        tab: nil, kicker: "THE TOUR", title: "The whole app, quickly",
        blurb: "Five screens along the bottom. The real screen sits behind each card as we go — tap Next to move through.",
        functions: [], arrow: false),

    WalkthroughStep(
        tab: .plan, kicker: "PLAN", title: "Plan the night",
        blurb: "Everything before the first drink.",
        functions: [
            ("calendar", "Plan a party or trip — invite the crew, they RSVP"),
            ("function", "Supply calculator: how much to actually buy"),
            ("moon.stars.fill", "Tonight's own planner + your BAC target live here too"),
        ], arrow: true),

    WalkthroughStep(
        tab: .live, kicker: "LIVE", title: "Log as you go",
        blurb: "The night, in real time.",
        functions: [
            ("plus.circle.fill", "One tap per drink — your BAC updates instantly"),
            ("mappin.circle.fill", "Check in to a bar so the night has a place"),
            ("person.2.fill", "Group up — see everyone's BAC together, live"),
            ("flag.checkered", "End the night → a full recap of where you went"),
        ], arrow: true),

    WalkthroughStep(
        tab: .timeline, kicker: "NIGHTLINE", title: "Your friends' nights",
        blurb: "What everyone's up to.",
        functions: [
            ("square.stack.fill", "Friends' live stories + morning recaps"),
            ("dot.radiowaves.left.and.right", "See who's out right now"),
            ("heart.fill", "Like and reply without leaving the feed"),
        ], arrow: true),

    WalkthroughStep(
        tab: .chats, kicker: "CHATS", title: "Keep it going",
        blurb: "Where the plans actually happen.",
        functions: [
            ("bubble.left.and.bubble.right.fill", "DM friends one-to-one"),
            ("arrowshape.turn.up.left.fill", "Replies to stories land here"),
        ], arrow: true),

    WalkthroughStep(
        tab: .offers, kicker: "DEALS", title: "Pay less, drink smarter",
        blurb: "Tonight's specials, mapped.",
        functions: [
            ("map.fill", "Bar specials near you as pins on the map"),
            ("hand.tap.fill", "Tap a pin for the offer + when it's valid"),
            ("checkmark.seal.fill", "\"Show at the bar\" to redeem it"),
        ], arrow: true),

    WalkthroughStep(
        tab: .offers, kicker: "BEER PRICES", title: "Where's beer cheap?",
        blurb: "Switch the Deals map to \"Beer prices\".",
        functions: [
            ("dollarsign.circle.fill", "Every bar's price — green is cheap, red is pricey"),
            ("line.3.horizontal.decrease.circle.fill", "Filter by serving size (25cl → pint)"),
            ("plus.circle.fill", "Spot a price? Add it — that's how the map grows"),
        ], arrow: true),

    WalkthroughStep(
        tab: nil, kicker: "YOU'RE SET", title: "That's the tour",
        blurb: "Replay it anytime from your profile. Now go make a night of it. Skål!",
        functions: [], arrow: false),
]

/// The dim + annotated card overlay. Lives above the live app so each real
/// screen shows (dimmed) behind its explanation.
struct WalkthroughOverlay: View {
    @Binding var index: Int
    let onClose: () -> Void

    private var step: WalkthroughStep { walkthroughSteps[min(index, walkthroughSteps.count - 1)] }
    private var isLast: Bool { index >= walkthroughSteps.count - 1 }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.62).ignoresSafeArea()
                .contentShape(Rectangle())            // swallow taps to the app

            VStack(spacing: 8) {
                card
                if step.arrow {
                    Image(systemName: "chevron.compact.down")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(Color.whiskey)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, step.arrow ? 58 : 120)
            .id(index)                                 // re-run the transition each step
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: index)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                SectionLabel(step.kicker, color: .whiskey)
                Spacer()
                Text("\(index + 1)/\(walkthroughSteps.count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.cream.opacity(0.4))
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.5))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.cream.opacity(0.06)))
                }
                .buttonStyle(.plain)
            }

            Text(step.title)
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.cream)
            Text(step.blurb)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)

            if !step.functions.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(step.functions.enumerated()), id: \.offset) { _, f in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: f.icon)
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.whiskey)
                                .frame(width: 22)
                            Text(f.label)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.cream.opacity(0.88))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 2)
            }

            HStack {
                if index > 0 {
                    Button {
                        withAnimation { index -= 1 }
                    } label: {
                        Text("Back").font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button {
                    if isLast { onClose() } else { withAnimation { index += 1 } }
                } label: {
                    HStack(spacing: 6) {
                        Text(isLast ? "Done" : "Next")
                            .font(.system(size: 13, weight: .bold, design: .monospaced)).tracking(1)
                        Image(systemName: isLast ? "checkmark" : "arrow.right")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 18).padding(.vertical, 11)
                    .background(Capsule().fill(Color.whiskey))
                }
                .buttonStyle(PressScaleStyle())
            }
            .padding(.top, 4)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.ink))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(Color.whiskey.opacity(0.3), lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 24, y: 10)
    }
}

/// Drives the walkthrough: overlays the card and switches the live app's tab to
/// match each step. Bundled as a modifier so SessionView.body stays simple.
struct WalkthroughModifier: ViewModifier {
    @Binding var tab: TopTab
    @Binding var active: Bool
    @State private var index = 0

    func body(content: Content) -> some View {
        content
            .overlay {
                if active {
                    WalkthroughOverlay(index: $index) { active = false }
                        .transition(.opacity)
                }
            }
            .onChange(of: active) { _, on in if on { index = 0; applyTab() } }
            .onChange(of: index) { _, _ in applyTab() }
    }

    private func applyTab() {
        guard active, let t = walkthroughSteps[min(index, walkthroughSteps.count - 1)].tab else { return }
        withAnimation(.easeInOut(duration: 0.35)) { tab = t }
    }
}
