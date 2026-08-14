// FindCrewSheet — the "you're in, now bring people" moment, shown once right
// after the first-run tour.
//
// A night-out app with no friends in it is a calculator, so this is the most
// valuable screen in onboarding. Three routes, ordered so the ones that work
// immediately come first — the address book can run to hundreds of rows and
// pushes everything below it off the screen:
//
//   1. @username — instant, for when someone just told you theirs.
//   2. Invite link — works for everyone, no permission at all, and the only
//      route that pays off while the user base is small (matching needs your
//      friends to already be here).
//   3. Contacts — the people you already know, matched by digest. See
//      ContactDiscovery for why nothing about a non-user is uploaded. Last,
//      and it lists the whole book once scanned.
//
// Deliberately skippable and never shown twice: an onboarding wall that
// demands the address book before letting you in is how apps get deleted.

import SwiftUI
import MessageUI

struct FindCrewSheet: View {
    @ObservedObject var friends: FriendsService
    /// Personal join link, shared as-is.
    let inviteURL: URL
    /// Onboarding says "you're in"; reopened from the friends list it must
    /// not — same machinery, honest framing in both places.
    var kicker: String = "YOU'RE IN"
    var title: String = "Bring your crew"
    var blurb: String = "Sejdel is better with the people you actually go out with — group seshes, shared rounds, everyone's night in one feed."
    var dismissLabel: String = "I'll do this later"
    let onDone: () -> Void

    @StateObject private var contacts = ContactDiscovery()
    @State private var sentTo = Set<UUID>()
    @State private var username = ""
    @State private var searchNote: String?
    @State private var sharing = false
    @State private var composing: InvitableContact?

    private let sunny = Color(red: 1.0, green: 0.79, blue: 0.28)

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                header

                // Order matters here. Username search and the invite link
                // are the two routes that work RIGHT NOW, so they sit above
                // the contact list — which can run to hundreds of rows and
                // would otherwise bury them.
                usernameRow
                shareRow

                // Contacts. One button until it's been used, then results.
                if contacts.matched.isEmpty && !contacts.scanning && contacts.scanned == 0 {
                    contactsCTA
                } else {
                    contactResults
                }

                Button(action: onDone) {
                    Text(dismissLabel)
                        .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                        .tracking(1.1)
                        .foregroundStyle(Color.cream.opacity(0.5))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
            }
            .padding(20)
        }
        .background(Color.ink)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $sharing) {
            ShareLinkSheet(items: [
                "Get Sejdel — we're tracking the night, come find us: \(inviteURL.absoluteString)"
            ])
        }
        .sheet(item: $composing) { c in
            if MFMessageComposeViewController.canSendText(), let phone = c.phone {
                MessageComposer(
                    recipients: [phone],
                    body: "Get Sejdel so we can run the night together — \(inviteURL.absoluteString)"
                ) { composing = nil }
            } else {
                // No SMS on this device (iPad, simulator) — fall back to the
                // share sheet rather than a dead end.
                ShareLinkSheet(items: [
                    "Get Sejdel so we can run the night together — \(inviteURL.absoluteString)"
                ])
            }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(kicker)
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(1.8)
                .foregroundStyle(Color.whiskey)
            Text(title)
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .tracking(-1.0)
                .foregroundStyle(Color.cream)
            Text(blurb)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.62))
                .lineSpacing(2)
        }
    }

    private var contactsCTA: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                Task { await contacts.scan() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 17, weight: .bold))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Find friends from contacts")
                            .font(.system(size: 15, weight: .heavy, design: .rounded))
                        Text("We only send scrambled codes, never your contacts")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .opacity(0.75)
                    }
                    Spacer()
                    if contacts.scanning { ProgressView().tint(Color.ink) }
                }
                .foregroundStyle(Color.ink)
                .padding(.horizontal, 14).padding(.vertical, 13)
                .background(RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(sunny))
            }
            .buttonStyle(PressScaleStyle())
            .disabled(contacts.scanning)

            if contacts.denied {
                Text("Contacts are off for Sejdel. Settings › Privacy › Contacts if you change your mind — the invite link below works either way.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.bronze)
            }
            if let e = contacts.error {
                Text(e)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.91, green: 0.46, blue: 0.42))
            }
        }
    }

    private var contactResults: some View {
        VStack(alignment: .leading, spacing: 12) {
            if contacts.scanning {
                HStack(spacing: 8) {
                    ProgressView().tint(sunny)
                    Text("Checking your contacts…")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.7))
                }
            }

            if !contacts.matched.isEmpty {
                SectionLabel("Already on Sejdel")
                ForEach(contacts.matched) { p in
                    HStack(spacing: 12) {
                        AvatarView(urlString: p.avatarURL,
                                   initial: String(p.name.prefix(1)).uppercased(), size: 38)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name)
                                .font(.system(size: 15, weight: .heavy, design: .rounded))
                                .foregroundStyle(Color.cream)
                            if let u = p.username {
                                Text("@" + u)
                                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Color.bronze)
                            }
                        }
                        Spacer()
                        addButton(for: p)
                    }
                    .padding(.vertical, 2)
                }
            } else if !contacts.scanning {
                // "No matches" must read as an answer, not a failure — hence
                // the count, and the honest reason at this stage of the app.
                Text("None of your \(contacts.scanned) contacts are on Sejdel yet. Invite a few and you'll be the reason they join.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.6))
                    .lineSpacing(2)
            }

            if !contacts.invitable.isEmpty {
                HStack {
                    SectionLabel("Invite from contacts")
                    Spacer()
                    Text("\(contacts.invitable.count)")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundStyle(Color.bronze)
                }
                // The full book now that it's the last thing on the sheet —
                // it scrolls, and a truncated list hid people you wanted.
                ForEach(contacts.invitable) { c in
                    HStack(spacing: 12) {
                        AvatarView(urlString: nil,
                                   initial: String(c.name.prefix(1)).uppercased(), size: 34)
                        Text(c.name)
                            .font(.system(size: 14.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.cream)
                        Spacer()
                        Button { composing = c } label: {
                            Text("INVITE")
                                .font(.system(size: 10, weight: .black, design: .monospaced))
                                .tracking(1.1)
                                .foregroundStyle(Color.whiskey)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Capsule().strokeBorder(Color.whiskey.opacity(0.55), lineWidth: 1))
                        }
                        .buttonStyle(PressScaleStyle())
                    }
                }
            }
        }
    }

    private func addButton(for p: MatchedProfile) -> some View {
        let sent = sentTo.contains(p.id)
        return Button {
            guard let u = p.username, !sent else { return }
            sentTo.insert(p.id)
            Task {
                if await friends.sendRequest(username: u) != nil {
                    // Put it back so the user can retry rather than staring
                    // at a "Sent" that never arrived.
                    await MainActor.run { sentTo.remove(p.id) }
                }
            }
        } label: {
            Text(sent ? "SENT" : "ADD")
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(sent ? Color.cream.opacity(0.5) : Color.ink)
                .padding(.horizontal, 13).padding(.vertical, 7)
                .background(Capsule().fill(sent ? Color.cream.opacity(0.10) : sunny))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(sent || p.username == nil)
    }

    private var shareRow: some View {
        Button { sharing = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 15, weight: .bold))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Share your invite link")
                        .font(.system(size: 14.5, weight: .heavy, design: .rounded))
                    Text("Anywhere — no contacts needed")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .opacity(0.7)
                }
                Spacer()
            }
            .foregroundStyle(Color.cream)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color.cream.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Color.cream.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(PressScaleStyle())
    }

    private var usernameRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Know their username?")
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text("@").foregroundStyle(Color.bronze)
                    TextField("username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .foregroundStyle(Color.cream)
                }
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .padding(.horizontal, 12).padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.cream.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.cream.opacity(0.12), lineWidth: 1))

                Button {
                    let u = username.trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: "@", with: "")
                    guard !u.isEmpty else { return }
                    Task {
                        let note = await friends.sendRequest(username: u)
                        await MainActor.run {
                            searchNote = note ?? "Request sent to @\(u)."
                            if note == nil { username = "" }
                        }
                    }
                } label: {
                    Text("SEND")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .tracking(1.1)
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, 15).padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.whiskey))
                }
                .buttonStyle(PressScaleStyle())
            }
            if let n = searchNote {
                Text(n)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.65))
            }
        }
    }
}

// MARK: - UIKit bridges

/// The system share sheet. Simpler than SwiftUI's ShareLink here because the
/// payload is a composed string rather than a Transferable model.
struct ShareLinkSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// iMessage/SMS composer, pre-filled. Nothing sends without the user
/// tapping send in Apple's own UI — we never message anyone on their behalf.
struct MessageComposer: UIViewControllerRepresentable {
    let recipients: [String]
    let body: String
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.recipients = recipients
        vc.body = body
        vc.messageComposeDelegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ vc: MFMessageComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                          didFinishWith result: MessageComposeResult) {
            controller.dismiss(animated: true) { self.onFinish() }
        }
    }
}
