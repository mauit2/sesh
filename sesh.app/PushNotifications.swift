// Push-notification plumbing for sesh invites.
//
// What this file does (the parts that work WITHOUT the paid Apple
// Developer account yet):
//
//   • Asks the user for notification permission and registers for remote
//     notifications.
//   • Receives the APNs device token and uploads it to Supabase via the
//     `register_device_token` RPC (migration 010), keyed to the signed-in
//     user. The server-side Edge Function (added later) reads that table
//     to know where to send an invite push.
//   • Handles a notification *tap* by routing the app to the invites
//     inbox, and shows a banner if a push arrives while the app is open.
//
// What still needs the paid account + Apple portal before pushes actually
// arrive (not in this file):
//
//   • The Push Notifications capability on the app target (adds the
//     `aps-environment` entitlement). Until that's present,
//     `registerForRemoteNotifications()` calls back into
//     `didFailToRegisterForRemoteNotificationsWithError` and we simply log
//     it — the app keeps working via the existing in-app invite poll.
//   • An APNs Auth Key (.p8) + a Supabase Edge Function that signs an APNs
//     JWT and POSTs the push. That's the sender side; this file is purely
//     the receiver + token-registration side.
//
// Degradation: every entry point here is best-effort. If permission is
// denied, registration fails, or the upload errors, nothing breaks — the
// 7-second InvitesService poll still surfaces invites whenever the app is
// open. Push is an enhancement layered on top, never a dependency.

import Combine
import Foundation
import Supabase
import SwiftUI
import UIKit
import UserNotifications

// MARK: - Router

/// App-wide coordinator the UI observes to react to push taps. Kept tiny
/// and `@MainActor` so the AppDelegate (which fires on the main thread)
/// can poke it directly. `RootView` / `SessionView` watch `openInvites`
/// and present the invites inbox when it flips true.
@MainActor
final class PushManager: ObservableObject {
    static let shared = PushManager()
    private init() {}

    /// Set true when the user taps a sesh-invite push. The UI flips this
    /// back to false once it has opened the inbox.
    @Published var openInvites = false

    /// The most recent device token, hex-encoded. Re-uploaded on each
    /// sign-in so a token that rotated while signed out still lands.
    private(set) var currentToken: String?

    // MARK: Permission + registration

    /// Idempotent: safe to call on every sign-in. Requests permission the
    /// first time, and registers for remote notifications whenever we're
    /// authorised. A denied user is left alone (no nagging) — the poll
    /// covers them.
    func requestAuthorizationAndRegister() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    guard granted else { return }
                    Task { @MainActor in
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                }
            case .authorized, .provisional, .ephemeral:
                Task { @MainActor in
                    UIApplication.shared.registerForRemoteNotifications()
                }
            case .denied:
                break          // respect the user's choice; poll still runs
            @unknown default:
                break
            }
        }
    }

    /// Called by the AppDelegate once APNs hands back a token. Stores it
    /// and pushes it to Supabase. Fire-and-forget; errors are swallowed
    /// (the next launch re-uploads).
    func handleDeviceToken(_ tokenData: Data) {
        let hex = tokenData.map { String(format: "%02x", $0) }.joined()
        currentToken = hex
        Task { await uploadToken(hex) }
    }

    /// Re-upload the cached token — call after sign-in so a token captured
    /// before the user authenticated gets associated with their account.
    func reuploadTokenIfAvailable() {
        guard let hex = currentToken else { return }
        Task { await uploadToken(hex) }
    }

    private func uploadToken(_ hex: String) async {
        // `supabase` is the shared client defined in content_view.swift.
        // The RPC stamps auth.uid() server-side, so an unauthenticated
        // call just raises and is ignored here.
        struct Params: Encodable { let p_token: String; let p_platform: String }
        do {
            _ = try await supabase
                .rpc("register_device_token", params: Params(p_token: hex, p_platform: "ios"))
                .execute()
        } catch {
            // Not signed in yet, offline, or migration not applied — all
            // recoverable on the next attempt. The poll keeps invites
            // working regardless.
            print("Device-token upload skipped:", error.localizedDescription)
        }
    }

    // MARK: Routing

    /// Inspect a notification payload and, if it's a sesh invite, ask the
    /// UI to open the inbox. The Edge Function will send
    /// `{ "type": "sesh_invite", ... }` in the payload's top level.
    func route(userInfo: [AnyHashable: Any]) {
        if let type = userInfo["type"] as? String, type == "sesh_invite" {
            openInvites = true
        }
    }
}

// MARK: - AppDelegate

/// Minimal UIKit delegate, bridged into SwiftUI via
/// `@UIApplicationDelegateAdaptor` in sesh_appApp.swift. Its only jobs are
/// the APNs callbacks UIKit insists on delivering here, plus foreground
/// banner presentation. All real logic lives in `PushManager`.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // APNs handed us a token — forward to the manager for upload.
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            PushManager.shared.handleDeviceToken(deviceToken)
        }
    }

    // Registration failed. Expected until the Push Notifications capability
    // (aps-environment entitlement) is added with the paid account — log
    // and carry on; the in-app poll still delivers invites.
    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("APNs registration failed (expected before capability is added):",
              error.localizedDescription)
    }

    // Push arrived while the app is foregrounded — still show it as a
    // banner so the user isn't left wondering why nothing happened.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // User tapped the notification — route into the invites inbox.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        Task { @MainActor in
            PushManager.shared.route(userInfo: userInfo)
            completionHandler()
        }
    }
}
