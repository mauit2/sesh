import SwiftUI
import Combine
import Supabase

/// The safety disclaimer, shown once before anyone reaches the app.
///
/// For a new account that is the moment after sign-up. For an account that
/// existed before this shipped it is the next launch — the point is that every
/// user has seen it, not that the paperwork looks tidy for new ones.
///
/// The acknowledgement is stamped on the profile with a timestamp and the
/// version of the wording accepted (migration 128). A disclaimer nobody can
/// prove was shown is worth very little, and the server record is the part
/// that makes it evidence rather than a claim.
@MainActor
final class SafetyDisclaimer: ObservableObject {
    static let shared = SafetyDisclaimer()

    /// Bump when the wording changes materially; everyone is asked again.
    static let version = "v1"

    @Published var showing = false
    @Published private(set) var acknowledged = false

    private let key = "sejdel.disclaimer.ack.v1"

    /// Ask the server whether this account has accepted the current wording.
    /// The local flag only avoids a flash of the sheet while that call is in
    /// flight; the server is the record.
    func load() async {
        if UserDefaults.standard.string(forKey: key) == Self.version {
            acknowledged = true
            return
        }
        struct S: Decodable { let ack_at: String?; let version: String? }
        guard let s: S = try? await supabase.rpc("disclaimer_state").execute().value else { return }
        if s.ack_at != nil, s.version == Self.version {
            acknowledged = true
            UserDefaults.standard.set(Self.version, forKey: key)
        } else {
            withAnimation(.easeOut(duration: 0.25)) { showing = true }
        }
    }

    func accept() {
        acknowledged = true
        UserDefaults.standard.set(Self.version, forKey: key)
        withAnimation(.easeOut(duration: 0.25)) { showing = false }
        struct P: Encodable { let p_version: String }
        Task { _ = try? await supabase.rpc("disclaimer_ack", params: P(p_version: Self.version)).execute() }
    }
}

/// Mounted once inside the signed-in app. Presents the sheet when the account
/// has not accepted the current wording.
struct SafetyDisclaimerGate: View {
    @ObservedObject private var state = SafetyDisclaimer.shared

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .task { await state.load() }
            .fullScreenCover(isPresented: $state.showing) {
                SafetyDisclaimerSheet { state.accept() }
                    .interactiveDismissDisabled(true)
            }
    }
}

/// Deliberately not dismissible by swipe or by tapping away. There is one way
/// out and it is the button that records the acknowledgement.
struct SafetyDisclaimerSheet: View {
    let onAccept: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var appeared = false

    private var warningRed: Color { Color(red: 0.902, green: 0.325, blue: 0.267) }

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    Text("Sejdel does not provide medical advice. Any health, fitness, or blood alcohol information shown in the app is provided for general informational and entertainment purposes only, and is not a substitute for professional medical advice, diagnosis, or treatment.")
                    Text("Sejdel estimates blood alcohol content using the Widmark formula applied to information you enter. These figures are estimates, not measurements. They cannot account for individual physiology, food, medication, or health conditions, and they can differ substantially from your actual blood alcohol content.")
                    driveBox
                    Text("Calorie, step, and heart rate figures from Apple Health come from your own device and are not verified by us. Always seek the advice of a qualified health provider with any questions about alcohol consumption or a medical condition.")
                    Button {
                        if let u = URL(string: "https://sejdel.com/disclaimer/") { openURL(u) }
                    } label: {
                        Text("Read the full disclaimer")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.whiskey)
                            .underline()
                    }
                    .buttonStyle(.plain)
                    Color.clear.frame(height: 96)
                }
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.75))
                .lineSpacing(4)
                .padding(.horizontal, 26)
                .padding(.top, 44)
            }
            VStack {
                Spacer()
                acceptButton
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { withAnimation(.easeOut(duration: 0.5)) { appeared = true } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("BEFORE YOU START")
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(2.4)
                .foregroundStyle(Color.bronze)
            Text("Sejdel estimates. It never measures.")
                .font(.system(size: 30, weight: .black, design: .rounded))
                .foregroundStyle(Color.cream)
                .fixedSize(horizontal: false, vertical: true)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 10)
    }

    private var driveBox: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(warningRed)
            VStack(alignment: .leading, spacing: 4) {
                Text("NEVER DRINK AND DRIVE")
                    .font(.system(size: 15, weight: .black, design: .rounded))
                    .foregroundStyle(warningRed)
                Text("Never use Sejdel to decide whether to drive, to operate machinery, or for any other decision where impairment matters. If you have been drinking, do not drive.")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.stout.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(warningRed.opacity(0.5), lineWidth: 1))
    }

    private var acceptButton: some View {
        Button(action: onAccept) {
            Text("I UNDERSTAND")
                .font(.system(size: 12, weight: .black, design: .monospaced))
                .tracking(1.8)
                .foregroundStyle(Color.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 17)
                .background(Capsule().fill(Color.whiskey))
        }
        .buttonStyle(PressScaleStyle())
        .padding(.horizontal, 26)
        .padding(.bottom, 34)
        .background(
            LinearGradient(colors: [Color.ink.opacity(0), Color.ink, Color.ink],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 150)
                .allowsHitTesting(false),
            alignment: .bottom
        )
    }
}
