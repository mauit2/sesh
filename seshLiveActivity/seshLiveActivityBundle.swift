//
//  seshLiveActivityBundle.swift
//  seshLiveActivity
//
//  Created by Mauritz Andersson on 2026-05-02.
//

import WidgetKit
import SwiftUI

// The widget extension's entry point. Two widgets are registered:
//
//   • seshLiveActivityLiveActivity — the lock-screen card + Dynamic
//     Island shown during an in-progress live sesh. Event-driven;
//     the app pushes updates as state changes.
//
//   • SeshHomeWidget — the Home Screen widget. Timeline-driven: it
//     reads a snapshot from the App Group container and projects BAC
//     decay forward on its own schedule, so the number ticks down
//     even when the app is closed.
//
// The Control Center toggle stub the Xcode template generated remains
// unregistered — there's no useful single-tap action to expose for a
// BAC tracker.
@main
struct seshLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        seshLiveActivityLiveActivity()
        SeshHomeWidget()
    }
}
