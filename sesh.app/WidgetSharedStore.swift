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
    /// snapshot file stays trivially small. Still carried so the widget
    /// can pick the drunkest member; only that one row is rendered now.
    public var roster: [Member]

    /// A short, funny one-liner about the drunkest group member (the
    /// `roster` row with the highest BAC). Computed app-side via the
    /// roast book — the widget extension can't see that code — and shown
    /// next to the leader instead of a full roster list. Nil when solo
    /// or when there are no other members yet.
    public var topRoast: String?

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
        roster: [Member],
        topRoast: String? = nil
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
        self.topRoast = topRoast
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

    /// Nudge the widget to re-render without changing the snapshot —
    /// used when a display preference (e.g. the BAC unit) changes so the
    /// home-screen widget reformats immediately.
    public static func reload() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}

// MARK: - BAC display unit

/// How a raw Widmark BAC value (always stored in %-by-volume, e.g.
/// `0.082`) is rendered to the user. The two conventions in common use:
///
///   • `.percent`  — "0.082 %BAC" (US, UK, Ireland, much of the
///                   Commonwealth).
///   • `.promille` — "0.82 ‰" (Scandinavia + most of continental
///                   Europe). Promille is exactly ten times the percent
///                   value, so the conversion is a pure ×10 with one
///                   fewer decimal place.
///
/// Both the app and the widget extension format BAC, so this type lives
/// in the shared store and is the single source of truth for the maths
/// and the symbol.
public enum BACUnit: String, Codable, Hashable {
    case percent
    case promille

    /// The raw %-scale value scaled into the display unit.
    public func scaled(_ bac: Double) -> Double {
        switch self {
        case .percent:  return bac
        case .promille: return bac * 10
        }
    }

    /// Decimal places. Promille uses one fewer than percent because the
    /// ×10 shifts the point — `0.082%` ↔ `0.82‰` carry the same precision.
    public var decimals: Int {
        switch self {
        case .percent:  return 3
        case .promille: return 2
        }
    }

    /// The numeric portion only, e.g. "0.082" or "0.82". Clamped at 0.
    public func formatted(_ bac: Double) -> String {
        String(format: "%.\(decimals)f", scaled(max(0, bac)))
    }

    /// Compact rendering for fixed threshold labels (drive limits). Strips
    /// trailing zeros so 0.02% reads "0.02" and the same limit in promille
    /// reads "0.2". Not clamped — thresholds are always positive.
    public func formattedLimit(_ bac: Double) -> String {
        var s = String(format: "%.\(decimals)f", scaled(bac))
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    /// Label shown beneath/around the big number, e.g. the "%BAC" caption.
    public var caption: String {
        switch self {
        case .percent:  return "%BAC"
        case .promille: return "‰ BAC"
        }
    }

    /// Bare unit symbol for inline use after a number.
    public var symbol: String {
        switch self {
        case .percent:  return "%"
        case .promille: return "‰"
        }
    }
}

/// Persisted display-unit preference. Stored in the App Group so the
/// widget extension reads the same value the app writes. The stored
/// string is one of "auto" / "percent" / "promille"; "auto" resolves
/// from the device region at render time.
public enum BACUnitSetting {
    /// UserDefaults key for the stored mode string.
    public static let key = "sesh.bac.unitMode.v1"

    /// Shared store so app + widget agree. Falls back to `.standard` if
    /// the App Group can't be opened (same degradation as the snapshot).
    public static let store: UserDefaults =
        UserDefaults(suiteName: AppGroupID.value) ?? .standard

    /// Regions that conventionally express BAC in promille (or g/L, which
    /// is numerically identical). Everything not listed defaults to
    /// percent. Users can always override in Settings.
    private static let promilleRegions: Set<String> = [
        // Nordics
        "SE", "NO", "DK", "FI", "IS",
        // DACH + neighbours
        "DE", "AT", "CH", "LI",
        // Benelux
        "NL", "BE", "LU",
        // Central / Eastern / SE Europe
        "PL", "CZ", "SK", "HU", "SI", "HR", "RS", "BA", "ME", "MK",
        "AL", "BG", "RO", "MD",
        // Baltics
        "EE", "LV", "LT",
        // Southern Europe (g/L, shown as promille)
        "FR", "IT", "ES", "PT", "GR",
        // Other promille jurisdictions
        "RU", "UA", "BY", "TR",
    ]

    /// Region-based default when the mode is "auto".
    public static func autoUnit(regionCode: String?) -> BACUnit {
        guard let code = regionCode?.uppercased(),
              promilleRegions.contains(code) else { return .percent }
        return .promille
    }

    /// Resolve a stored mode string into a concrete unit. Unknown / nil /
    /// "auto" all fall back to the region-derived default.
    public static func resolved(mode: String?) -> BACUnit {
        switch mode {
        case "percent":  return .percent
        case "promille": return .promille
        default:
            if #available(iOS 16, *) {
                return autoUnit(regionCode: Locale.current.region?.identifier)
            } else {
                return autoUnit(regionCode: Locale.current.regionCode)
            }
        }
    }

    /// The currently-stored mode string ("auto" if unset).
    public static func currentMode() -> String {
        store.string(forKey: key) ?? "auto"
    }

    /// The resolved unit right now — used by the widget extension, which
    /// reads it fresh on every timeline render.
    public static func current() -> BACUnit {
        resolved(mode: currentMode())
    }
}
