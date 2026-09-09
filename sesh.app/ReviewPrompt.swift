import SwiftUI
import Combine
import Supabase
import StoreKit

/// The "enjoying Sejdel?" ask.
///
/// Only after a proper first night: three drinks over ninety minutes, or a
/// posted night, or the app opened on three different days. "Love it" hands
/// straight to Apple's own star sheet, the only thing that can post a rating
/// from inside the app. Apple never says whether the person actually rated,
/// so that tap does NOT end the asking: the prompt comes back at most once
/// every 30 days until they open the App Store review page from the thanks
/// card, which is the strongest signal we can get and is stamped on the
/// profile so no device asks again. "Not yet" opens a box whose contents go
/// to the owner only, never to Apple.
@MainActor
final class ReviewPrompt: ObservableObject {
    static let shared = ReviewPrompt()

    enum Stage { case ask, feedback, thanks }
    @Published var showing = false
    @Published var stage: Stage = .ask
    /// True once "Love it" was tapped this time — the thanks card then offers
    /// the full App Store review link.
    @Published var lovedIt = false

    /// App Store Connect → Sejdel → App Information → Apple ID.
    static let appStoreID = "6780926501"

    private let d = UserDefaults.standard
    private let doneKey = "sejdel.review.done.v1"
    private let askedKey = "sejdel.review.askedAt.v1"
    private let qualifiedKey = "sejdel.review.qualified.v1"
    private let daysKey = "sejdel.review.days.v1"
    private static let gap: TimeInterval = 30 * 86400

    var isDone: Bool { d.bool(forKey: doneKey) }
    private var askedAt: Date? { d.object(forKey: askedKey) as? Date }
    private var qualified: Bool { d.bool(forKey: qualifiedKey) }

    /// Pull the profile's answer so a reinstall or a second phone agrees.
    func bootstrap() async {
        struct S: Decodable { let asked_at: String?; let done_at: String? }
        guard let s: S = try? await supabase.rpc("review_prompt_state").execute().value else { return }
        if s.done_at != nil { d.set(true, forKey: doneKey) }
        if let a = s.asked_at.flatMap(Self.parse), (askedAt ?? .distantPast) < a { d.set(a, forKey: askedKey) }
    }

    // ── what counts as "a real first sesh" ──
    func noteAppOpened() {
        let stamp = Self.dayStamp(Date())
        var days = d.stringArray(forKey: daysKey) ?? []
        if !days.contains(stamp) { days.append(stamp); d.set(days, forKey: daysKey) }
        if days.count >= 3 { qualify() }
    }
    func noteRecap(_ r: NightRecap) {
        if r.totalDrinks >= 3 && r.endedAt.timeIntervalSince(r.startedAt) >= 90 * 60 { qualify() }
    }
    func notePosted() { qualify() }
    private func qualify() { d.set(true, forKey: qualifiedKey) }

    /// Show the card if it has earned the right to. Called when the app comes
    /// to the front, so it never lands in the middle of something.
    func considerShowing() {
        #if DEBUG
        // Launch with SIMCTL_CHILD_SEJDEL_FORCE_REVIEW=1 to see the card
        // regardless of history. Nothing is stamped anywhere.
        // "1" opens the ask; "feedback" opens the not-yet box straight away.
        if let force = ProcessInfo.processInfo.environment["SEJDEL_FORCE_REVIEW"], !force.isEmpty, !showing {
            lovedIt = false; stage = force == "feedback" ? .feedback : .ask
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { showing = true }
            return
        }
        #endif
        guard qualified, !isDone, !showing else { return }
        if let a = askedAt, Date().timeIntervalSince(a) < Self.gap { return }
        d.set(Date(), forKey: askedKey)
        lovedIt = false
        stage = .ask
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { showing = true }
        Task { _ = try? await supabase.rpc("review_prompt_touch", params: ["p_done": false]).execute() }
    }

    func loveIt(_ request: RequestReviewAction) {
        lovedIt = true
        request()
        withAnimation { stage = .thanks }
        dismissSoon(after: Self.writeReviewURL == nil ? 1.8 : 6)
    }

    /// They went to the App Store review page. That is the only thing that
    /// ends the asking.
    func wentToAppStore() {
        d.set(true, forKey: doneKey)
        Task { _ = try? await supabase.rpc("review_prompt_touch", params: ["p_done": true]).execute() }
        skip()
    }

    func notYet() { withAnimation { stage = .feedback } }

    func sendFeedback(_ text: String) async {
        struct P: Encodable { let p_message: String; let p_build: String? }
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        _ = try? await supabase.rpc("app_feedback_add", params: P(p_message: text, p_build: build)).execute()
        withAnimation { stage = .thanks }
        dismissSoon(after: 1.8)
    }

    func skip() { withAnimation(.easeOut(duration: 0.25)) { showing = false } }

    private func dismissSoon(after s: Double) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
            skip()
        }
    }

    static var writeReviewURL: URL? {
        appStoreID.isEmpty ? nil : URL(string: "https://apps.apple.com/app/id\(appStoreID)?action=write-review")
    }
    private static func dayStamp(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }
    private static func parse(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

/// The card itself. Sits over everything at the bottom of the screen.
struct ReviewPromptCard: View {
    @ObservedObject private var prompt = ReviewPrompt.shared
    @Environment(\.requestReview) private var requestReview
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var text = ""
    @FocusState private var focused: Bool
    /// The keyboard's top edge in screen coordinates, when it is up. The
    /// container ignores the keyboard's own safe-area inset (so the dim
    /// stays full-screen and nothing else jumps) and the card is lifted by
    /// the measured overlap instead.
    @State private var keyboardTop: CGFloat? = nil

    var body: some View {
        GeometryReader { geo in
            let bottom = geo.frame(in: .global).maxY
            let lift: CGFloat = keyboardTop.map { max(0, bottom - $0) + 10 } ?? 28
            ZStack(alignment: .bottom) {
                if prompt.showing {
                    Color.black.opacity(0.5).ignoresSafeArea()
                        .onTapGesture { if prompt.stage != .feedback { prompt.skip() } }
                    card
                        .padding(.horizontal, 16)
                        .padding(.bottom, lift)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        }
        .ignoresSafeArea(.keyboard)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { n in
            guard let end = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let offscreen = end.origin.y >= UIScreen.main.bounds.height
            withAnimation(.easeOut(duration: 0.25)) { keyboardTop = offscreen ? nil : end.origin.y }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.25)) { keyboardTop = nil }
        }
        .zIndex(50)
        // Mounted for the whole signed-in life of the app, so this runs on
        // every launch — after the home screen has had a moment to settle.
        .task {
            prompt.noteAppOpened()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            prompt.considerShowing()
        }
        // Coming back to the front is the other calm moment to ask.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { prompt.noteAppOpened(); prompt.considerShowing() }
        }
    }

    private var card: some View {
        VStack(spacing: 14) {
            switch prompt.stage {
            case .ask: ask
            case .feedback: feedback
            case .thanks: thanks
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color.inkElev))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.cream.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
    }

    private var ask: some View {
        VStack(spacing: 14) {
            Text("🍻").font(.system(size: 34))
            Text("Enjoying Sejdel?")
                .font(.system(size: 22, weight: .black, design: .rounded))
                .foregroundStyle(Color.cream)
            Text("You've had a proper night with it now. Two seconds of your opinion goes a long way.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.65))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            pill("LOVE IT", fill: true) { prompt.loveIt(requestReview) }
                .padding(.top, 4)
            Button { prompt.notYet() } label: {
                Text("Not yet")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.5))
                    .padding(.vertical, 4)
                    .padding(.horizontal, 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var feedback: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What's missing?")
                .font(.system(size: 20, weight: .black, design: .rounded))
                .foregroundStyle(Color.cream)
            TextEditor(text: $text)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream)
                .tint(Color.whiskey)
                .frame(minHeight: 96, maxHeight: 140)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cream.opacity(0.06)))
                .onAppear { focused = true }
            HStack(spacing: 10) {
                pill("SKIP", fill: false) { prompt.skip() }
                pill("SEND", fill: true, disabled: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    let t = text; text = ""
                    Task { await prompt.sendFeedback(t) }
                }
            }
        }
    }

    private var thanks: some View {
        VStack(spacing: 10) {
            Text("Thanks.")
                .font(.system(size: 22, weight: .black, design: .rounded))
                .foregroundStyle(Color.cream)
            Text("That helps more than you'd think.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.65))
            if prompt.lovedIt, let url = ReviewPrompt.writeReviewURL {
                Button { openURL(url); prompt.wentToAppStore() } label: {
                    Text("Write a full review on the App Store")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.whiskey)
                        .underline()
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
    }

    private func pill(_ title: String, fill: Bool, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .tracking(1.6)
                .foregroundStyle(fill ? Color.ink : Color.cream.opacity(0.85))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Capsule().fill(fill ? Color.whiskey : Color.cream.opacity(0.08)))
                .overlay(Capsule().strokeBorder(Color.cream.opacity(fill ? 0 : 0.18), lineWidth: 1))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }
}
