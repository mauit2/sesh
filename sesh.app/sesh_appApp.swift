//
//  sesh_appApp.swift
//  sesh.app
//
//  Created by Mauritz Andersson on 2026-04-20.
//

import SwiftUI
import MapboxMaps

@main
struct sesh_appApp: App {
    // Bridges UIKit's APNs callbacks (device token, notification taps) into
    // the SwiftUI lifecycle. See PushNotifications.swift. Harmless before
    // the Push capability exists — registration just fails gracefully and
    // the in-app invite poll keeps working.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Enlarge the HTTP cache + trim the on-disk image cache so photos stop
        // being re-downloaded on every launch (the main egress driver).
        ImageInfra.configure()
        // Mapbox renders the Deals tab's Sun mode (3D buildings + relightable
        // scene). A public token by design — it ships inside every copy of the
        // app, which is why the Tilequery/vector-tile calls that build the sun
        // horizons happen server-side with the same token held as a secret.
        MapboxOptions.accessToken = Secrets.mapboxPublicToken
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
