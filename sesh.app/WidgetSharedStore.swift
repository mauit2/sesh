// Cross-process data store for the Home Screen widget.
//
// Why this exists:
//
//   The Live Activity App Intent runs in the main app's process and can
//   read UserDefaults.standard directly. The Home Screen widget DOES NOT
//   — it runs in the widget extension's process, which has its own
//   sandboxed UserDefaults. To share state between them you need an App
//   Group capability (configured in Xcode) and a `UserDefaults(suiteName:)`
//   pointing at the shared container.
//
// Architecture:
//
//   • The app writes a `WidgetSnapshot` to the shared store whenever
//     anything that should appear on the widget changes (drinks added,
//     30s tick in LiveSeshView, profile edits, etc.).
//   • The widget's TimelineProvider reads that snapshot once per
//     reload and generates a series of "future entries" by linearly
//     decaying BAC from `snapshotAt` at the standard 0.015%/hr.
//   • After writing, the app calls
//     `WidgetCenter.shared.reloadAllTimelines()` to nudge the widget
//     into picking up the fresh snapshot immediately rather than
//     waiting for the next scheduled reload.
//
// Xcode setup required:
//
//   • Add an App Group capability to BOTH the `sesh.app` target AND
//     the widget extension target, using the SAME group id —
//     `group.Mau.sesh-app`. (See AppGroupID below.)
//   • Without this, the suite-name UserDefaults silently falls back
//     to a per-process bucket and the widget will show "Open sesh".

import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// The single App Group id shared by app + widget extension. Change here
/// only if you change the capability id in Xcode for BOTH targets.
public enum AppGroupID {
    public static let value = "group.Mau.sesh-app"
}

/// Snapshot the widget reads. Carries everything needed to render a
/// frame at any time T ≥ snapshotAt without further app interaction:
/// the BAC at snapshot time + the elimination rate are enough to
/// project the BAC forward linearly. Per-member rows for group mode
/// follow the same pattern.
public struct WidgetSnapshot: Codable {
    /// When the values below were computed. The widget's TimelineProvider
    /// decays from here forward.
    public var snapshotAt: Date
    /// True when the live sesh is in-progress at snapshot time. False
    /// means "no active sesh" and the widget renders the empty state.
    public var hasActiveSesh: Bool
    /// True when the user is in a group at snapshot time. Drives the
    /// roster section visibility.
    public var inGroup: Bool

    // The "me" row — always shown when hasActiveSesh.
    public var meName: String
    public var meBac: Double
    public var meStatusRaw: String
    public var meDrinkCount: Int
    /// When the sesh started. Used to render the "X drinks · 2h 14m"
    /// duration line on the widget.
    public var meStartedAt: Date?
    /// Projected sober time, computed from `meBac` at snapshot. The
    /// widget shows this as an absolute time ("clear by 3:42") — not
    /// a ticking countdown like the Live Activity, since home-screen
    /// widgets don't get live-rendered timer text.
    public var meSoberAt: Date

    /// Group members (excluding me) at snapshot time. Empty when
    /// `inGroup` is false. Limited to a small N at write time so the
    /// snapshot file stays trivially small.
    public var roster: [Member]

    public struct Member: Codable, Hashable, Identifiable {
        public var profileId: UUID
        public var name: String
        public var bac: Double
        public var statusRaw: String
        public var drinkCount: Int
        public var initials: String

        public var id: UUID { profileId }

        public init(
            profileId: UUID,
            name: String,
            bac: Double,
            statusRaw: String,
            drinkCount: Int,
            initials: String
        ) {
            self.profileId = profileId
            self.name = name
            self.bac = bac
            self.statusRaw = statusRaw
            self.drinkCount = drinkCount
            self.initials = initials
        }
    }

    public init(
        snapshotAt: Date,
        hasActiveSesh: Bool,
        inGroup: Bool,
        meName: String,
        meBac: Double,
        meStatusRaw: String,
        meDrinkCount: Int,
        meStartedAt: Date?,
        meSoberAt: Date,
        roster: [Member]
    ) {
        self.snapshotAt = snapshotAt
        self.hasActiveSesh = hasActiveSesh
        self.inGroup = inGroup
        self.meName = meName
        self.meBac = meBac
        self.meStatusRaw = meStatusRaw
        self.meDrinkCount = meDrinkCount
        self.meStartedAt = meStartedAt
        self.meSoberAt = meSoberAt
        self.roster = roster
    }

    /// Empty state — written by the app on sign-out / when no sesh is
    /// active so the widget knows to show the "Open sesh" placeholder.
    public static func empty(at: Date = Date()) -> WidgetSnapshot {
        WidgetSnapshot(
            snapshotAt: at,
            hasActiveSesh: false,
            inGroup: false,
            meName: "",
            meBac: 0,
            meStatusRaw: "sober",
            meDrinkCount: 0,
            meStartedAt: nil,
            meSoberAt: at,
            roster: []
        )
    }

    /// Linearly decay a BAC value from the snapshot's reference point
    /// to an arbitrary time. The widget uses this to project per-row
    /// values at every entry on its timeline. Clamped at 0 — the body
    /// can't have negative BAC.
    public func decayedBAC(from referenceBAC: Double, at when: Date) -> Double {
        let hours = max(0, when.timeIntervalSince(snapshotAt) / 3600)
        return max(0, referenceBAC - 0.015 * hours)
    }
}

/// UserDefaults-backed read/write for the snapshot. Suite name resolves
/// to the App Group container when capability is configured; otherwise
/// it silently uses a per-process bucket so the app keeps working
/// while the user finishes the Xcode setup. The widget will just show
/// the empty state until the suite resolves to a real shared container.
public enum WidgetSharedStore {
    private static let snapshotKey = "sesh.widget.snapshot.v1"

    /// Shared `UserDefaults` — nil if the suite can't be opened (which
    /// in practice means the App Group capability isn't wired yet).
    private static var shared: UserDefaults? {
        UserDefaults(suiteName: AppGroupID.value)
    }

    /// Read the latest snapshot. Returns `nil` when nothing has been
    /// written yet (first launch, or app group not configured).
    public static func read() -> WidgetSnapshot? {
        guard let store = shared,
              let data = store.data(forKey: snapshotKey)
        else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(WidgetSnapshot.self, from: data)
    }

    /// Write a snapshot and nudge the widget to reload its timeline so
    /// it picks up the new values immediately rather than at its next
    /// scheduled refresh.
    public static func write(_ snapshot: WidgetSnapshot) {
        guard let store = shared else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(snapshot) else { return }
        store.set(data, forKey: snapshotKey)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// Convenience for writing the empty state — used on sign-out and
    /// when an active sesh auto-ends.
    public static func clear() {
        write(.empty())
    }
}
