// SideMenu.swift — the ☰ drawer.
//
// The section titles are gone from the top bar; in their place a hamburger
// slides the whole app aside — the app stays the top layer, pushed right
// with a shadow — to reveal this X-style menu page underneath. It gathers
// what used to be reachable only from the profile page: profile, settings,
// Sejdel Premium (After Dark), friends, Sejdel for Business, the admin
// desks, and — pinned at the bottom — replay the tour and contact support.

import SwiftUI

/// Wraps the whole root view (so the tab bar slides with it), keeps the menu
/// page underneath, and hosts the sheets its rows open. Applied once to
/// SessionView, like the tour.
struct SideMenuModifier: ViewModifier {
    @Binding var isOpen: Bool
    @Binding var tab: TopTab
    @Binding var friendsOpen: Bool
    /// The settings form (ProfileSheet) — name, age, weight, BAC units, alerts.
    @Binding var settingsOpen: Bool
    @Binding var tourOpen: Bool
    let profile: Profile
    @ObservedObject var admin: AdminService

    @State private var paywallOpen = false
    @State private var businessOpen = false
    @State private var businessDeskOpen = false
    @State private var specialsOpen = false
    @State private var adminPanelOpen = false
    @Environment(\.openURL) private var openURL

    /// How far the app slides over — the menu page's usable width.
    static let width: CGFloat = 300

    func body(content: Content) -> some View {
        ZStack(alignment: .leading) {
            // The menu page sits underneath, always mounted so it is still
            // there while the app slides back over it.
            SideMenu(
                width: Self.width,
                profile: profile, isAdmin: admin.isAdmin, isOwner: admin.isOwner,
                onProfile: { close(); tab = .profile },
                onSettings: { close(); settingsOpen = true },
                onPremium: { close(); paywallOpen = true },
                onFriends: { close(); friendsOpen = true },
                onBusiness: { close(); businessOpen = true },
                onBusinessDesk: { close(); businessDeskOpen = true },
                onSpecials: { close(); specialsOpen = true },
                onAdminPanel: { close(); adminPanelOpen = true },
                onReplayTour: {
                    close()
                    // Let the app slide back before the spotlights land.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { tourOpen = true }
                },
                onSupport: {
                    close()
                    if let url = URL(string: "mailto:contact@sejdel.com?subject=sejdel%20support") { openURL(url) }
                }
            )
            .opacity(isOpen ? 1 : 0)
            .allowsHitTesting(isOpen)
            .accessibilityHidden(!isOpen)

            // The app itself: the top layer, pushed aside. While the menu is
            // open the visible sliver is only a way back — tap it or swipe
            // left to close.
            content
                .overlay {
                    if isOpen {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { close() }
                            .gesture(
                                DragGesture(minimumDistance: 12)
                                    .onEnded { v in if v.translation.width < -40 { close() } }
                            )
                    }
                }
                // Rounded like a card while it's aside — the mask ignores the
                // safe area so at radius 0 it covers the whole screen and cuts
                // nothing off. Two shadows: a wide soft one and a tight one at
                // the edge, both black, so the menu ground below is lifted a
                // touch (see SideMenu) for them to read against.
                .mask(RoundedRectangle(cornerRadius: isOpen ? ScreenCorner.radius : 0, style: .continuous).ignoresSafeArea())
                .shadow(color: .black.opacity(isOpen ? 0.7 : 0), radius: 34, x: -16, y: 0)
                .shadow(color: .black.opacity(isOpen ? 0.5 : 0), radius: 8, x: -3, y: 0)
                .offset(x: isOpen ? Self.width : 0)
                .zIndex(1)
        }
        .sheet(isPresented: $paywallOpen) {
            AfterDarkPaywall()
                .environmentObject(AfterDarkStore.shared)
        }
        .sheet(isPresented: $businessOpen) {
            BusinessHubView()
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.ink)
        }
        .sheet(isPresented: $businessDeskOpen) {
            BusinessReviewView()
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.ink)
        }
        .sheet(isPresented: $specialsOpen) {
            OffersAdminView()
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.ink)
        }
        .sheet(isPresented: $adminPanelOpen) {
            AdminPanelView(admin: admin)
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.ink)
        }
    }

    private func close() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { isOpen = false }
    }
}

/// The device's own display corner radius, so the pushed-aside app is
/// rounded exactly like the screen it slid out of. Read once through KVC
/// (there is no public API for it); falls back to the modern-iPhone value.
enum ScreenCorner {
    static let radius: CGFloat = {
        let key = ["_display", "Corner", "Radius"].joined()
        if let r = UIScreen.main.value(forKey: key) as? CGFloat, r > 0 { return r }
        return 55
    }()
}

/// The menu page that sits underneath the app: who you are on top, the
/// big-text rows X uses, the utilities pinned at the bottom. Closing is the
/// app's job — tap or swipe the pushed-aside screen.
struct SideMenu: View {
    let width: CGFloat
    let profile: Profile
    let isAdmin: Bool
    let isOwner: Bool
    let onProfile: () -> Void
    let onSettings: () -> Void
    let onPremium: () -> Void
    let onFriends: () -> Void
    let onBusiness: () -> Void
    let onBusinessDesk: () -> Void
    let onSpecials: () -> Void
    let onAdminPanel: () -> Void
    let onReplayTour: () -> Void
    let onSupport: () -> Void

    @ObservedObject private var afterDark = AfterDarkStore.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Lifted slightly toward the right, where the app's shadow falls,
            // so the card edge reads as an edge and not a seam.
            LinearGradient(colors: [Color.ink, Color.inkElev], startPoint: .leading, endPoint: .trailing)
                .ignoresSafeArea()
            panel
                .frame(width: width)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                FriendAvatar(name: profile.name, avatarURL: profile.avatarURL, size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.cream)
                        .lineLimit(1)
                    if let u = profile.username {
                        Text("@\(u)")
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 18)

            // Big titles only — no sub-lines. The one exception is Premium,
            // which says "on" once it's active.
            row("person.crop.circle", "Profile", nil, onProfile)
            row("gearshape", "Settings", nil, onSettings)
            row("sparkles", "Sejdel Premium", afterDark.hasSpicy ? "After Dark is on" : nil, onPremium, accent: true)
            row("person.2", "Friends", nil, onFriends)
            row("storefront", "Sejdel for Business", nil, onBusiness)

            if isAdmin {
                rule
                Text(isOwner ? "OWNER" : "ADMIN")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(Color.bronze)
                    .padding(.horizontal, 22)
                    .padding(.top, 14)
                    .padding(.bottom, 4)
                row("checkmark.seal", isOwner ? "Owner panel" : "Admin panel", nil, onAdminPanel)
                row("tag", "Manage specials", nil, onSpecials)
                row("building.2", "Business desk", nil, onBusinessDesk)
            }

            Spacer(minLength: 12)

            rule
            row("questionmark.circle", "Replay the tour", nil, onReplayTour)
            row("envelope", "Contact support", nil, onSupport)
            if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                Text("Sejdel \(v)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.cream.opacity(0.3))
                    .padding(.horizontal, 22)
                    .padding(.top, 8)
                    .padding(.bottom, 14)
            }
        }
    }

    private var rule: some View {
        Rectangle().fill(Color.cream.opacity(0.08)).frame(height: 1).padding(.horizontal, 22)
    }

    private func row(_ icon: String, _ title: String, _ sub: String?, _ action: @escaping () -> Void,
                     accent: Bool = false) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(accent ? Color.whiskey : Color.cream)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.cream)
                    if let sub {
                        Text(sub)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
    }
}
