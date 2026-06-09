//
//  sesh_appApp.swift
//  sesh.app
//
//  Created by Mauritz Andersson on 2026-04-20.
//

import SwiftUI

@main
struct sesh_appApp: App {
    // Bridges UIKit's APNs callbacks (device token, notification taps) into
    // the SwiftUI lifecycle. See PushNotifications.swift. Harmless before
    // the Push capability exists — registration just fails gracefully and
    // the in-app invite poll keeps working.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
