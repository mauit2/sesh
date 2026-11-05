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
                // Debug build on the production scheme: say so on every screen.
                .overlay(alignment: .top) {
                    if Secrets.pointsAtProduction {
                        Text("PRODUCTION DATA")
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                            .tracking(1.6)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(Color(red: 0.85, green: 0.2, blue: 0.2)))
                            .padding(.top, 2)
                            .allowsHitTesting(false)
                    }
                }
        }
    }
}
