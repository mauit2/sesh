// One-tap "log a drink from the lock screen" plumbing.
//
// Architecture:
//
//   • The widget renders `Button(intent: AddDrinkFromLockScreenIntent(...))`
//     for each `QuickDrink` carried in the activity's ContentState.
//   • Tap fires the intent. iOS, by virtue of `LiveActivityIntent`, runs
//     `perform()` in the MAIN APP'S process (not the widget extension).
//     This is the whole reason we picked LiveActivityIntent over
//     AppIntent — we get full access to UserDefaults that the running
//     app uses for LiveSeshState, and we can call ActivityKit directly
//     to push a fresh frame.
//   • `perform()` mutates the same UserDefaults keys LiveSeshState uses
//     for persistence. It then computes a fresh BAC + soberAt + status
//     and calls `Activity.update(...)` so the lock-screen card reflects
//     the new drink within ~50ms.
//   • A `Notification` is posted so any in-memory `LiveSeshState` reloads
//     from disk — otherwise the user would unlock the phone and see the
//     in-app timeline without the drink they just tapped on.
//
// Why this file is in BOTH target memberships:
//
//   The widget needs the intent TYPE so it can attach it to a Button.
//   The main app needs the same TYPE because the runtime resolves
//   `perform()` against the app-process implementation. Sharing one
//   file guarantees the two stay in lockstep on parameter shape.
//
// Why we duplicate Widmark math here instead of calling LiveSeshState:
//
//   `LiveSeshState` is `@MainActor` and held as a `@StateObject` by
//   the SwiftUI hierarchy. When iOS wakes the app to run an intent,
//   the SwiftUI scene may not yet exist — so there's no live instance
//   to mutate. Going through UserDefaults directly is the most robust
//   path. The math is short (~10 lines) and unambiguous (linear
//   elimination per drink), so duplicating it costs less than the
//   coordination machinery the alternative would need.

import ActivityKit
import AppIntents
import Foundation

// MARK: - Storage keys (shared with LiveSeshState in content_view.swift)

/// UserDefaults keys the intent reads/writes. Keeping them on a single
/// enum means a future move to App Groups only has to touch one site
/// (swap `UserDefaults.standard` for a suite). Solo-mode only — group
/// drinks go through SessionService over the network and aren't safe
/// to write from a quick lock-screen tap.
public enum LockScreenStorageKeys {
    public static let drinks  = "sesh.live.drinks.v1"
    public static let started = "sesh.live.startedAt.v1"
    /// The signed-in account's namespace suffix, written by LiveSeshState.
    /// Solo drinks live in per-account keys (`drinks`.`<ns>`) so accounts
    /// sharing a phone can't overwrite each other's night; the intent
    /// resolves the ACTIVE account's keys through this pointer.
    public static let liveNS = "sesh.live.ns.v1"

    /// The active account's drinks key (falls back to the legacy shared
    /// slot when no account has signed in since the namespacing shipped).
    public static var drinksResolved: String {
        if let ns = UserDefaults.standard.string(forKey: liveNS), !ns.isEmpty {
            return "\(drinks).\(ns)"
        }
        return drinks
    }

    /// The active account's started-at key (same resolution rule).
    public static var startedResolved: String {
        if let ns = UserDefaults.standard.string(forKey: liveNS), !ns.isEmpty {
            return "\(started).\(ns)"
        }
        return started
    }
    /// Legacy name-only recents (migrated away from by RecentDrinksStore).
    public static let recents = "sesh.recentDrinks.v1"
    /// Full-option recents (JSON-encoded [RecentDrink]) — scanned/custom
    /// drinks survive here. Written by both the app and this intent.
    public static let recentsV2 = "sesh.recentDrinks.v2"
    /// Cached profile primitives (weightKg + sex raw). Written by
    /// AuthService when the user signs in; read by `perform()` so we
    /// can run Widmark without booting the SwiftUI hierarchy.
    public static let profileWeightKg = "sesh.profileCache.weightKg"
    public static let profileSexRaw   = "sesh.profileCache.sexRaw"
    /// True while the user is in a live GROUP. The intent can't reach
    /// Supabase (this file compiles into the widget extension too), so in
    /// group mode it queues the add into `pendingGroupDrinks` and the app
    /// drains it to the session. False ⇒ solo, write straight to the local
    /// live store.
    public static let liveGroupActive = "sesh.live.groupActive"
    /// JSON [StoredRecentDrink] queued by the lock-screen intent in group
    /// mode, drained by the app into the group session.
    public static let pendingGroupDrinks = "sesh.live.pendingGroupDrinks"
}

/// Posted whenever the lock-screen intent has appended a drink. The
/// running `LiveSeshState` listens for this and reloads from disk so
/// the in-app timeline catches up. Posted on the main thread.
public extension Notification.Name {
    static let liveSeshLockScreenDidAddDrink = Notification.Name("sesh.lockScreen.didAddDrink")
}

// MARK: - Stored shape (mirrors LiveDrink in content_view.swift)

/// On-disk representation of a logged drink. Matches the `LiveDrink`
/// struct in the main app so writes here decode cleanly when
/// `LiveSeshState.load()` runs next. Keep these two in sync.
fileprivate struct StoredLiveDrink: Codable {
    let id: UUID
    let optionName: String
    let detail: String
    let category: String
    let volumeML: Double
    let abv: Double
    let consumedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, optionName, detail, category, volumeML, abv, consumedAt
    }
}

// MARK: - The intent

@available(iOS 17.0, *)
public struct AddDrinkFromLockScreenIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "Log a drink"
    public static var description = IntentDescription(
        "Adds a drink to your live sesh straight from the lock screen."
    )

    /// The full DrinkOption fields are passed through as primitives.
    /// We can't refer to DrinkCatalog from here (catalog lives in the
    /// main-app-only content_view.swift), and we don't want to gamble on
    /// a name lookup either — if the catalog gets reshuffled between
    /// app builds, an intent embedded in an in-flight activity would
    /// silently no-op. Carrying the primitives makes the intent
    /// self-sufficient.
    @Parameter(title: "Name") public var drinkName: String
    @Parameter(title: "Detail") public var detail: String
    @Parameter(title: "Category") public var category: String
    @Parameter(title: "Volume mL") public var volumeML: Double
    @Parameter(title: "ABV") public var abv: Double

    public init() {}

    public init(drink: SeshActivityAttributes.QuickDrink) {
        self.drinkName = drink.name
        self.detail = drink.detail
        self.category = drink.category
        self.volumeML = drink.volumeML
        self.abv = drink.abv
    }

    public func perform() async throws -> some IntentResult {
        await LockScreenDrinkLogger.append(
            name: drinkName,
            detail: detail,
            category: category,
            volumeML: volumeML,
            abv: abv
        )
        return .result()
    }
}

// MARK: - Logger (shared logic, callable from the intent)

/// All of the side-effects for the lock-screen tap. Pulled into its own
/// type so the intent's `perform()` stays a one-liner and so unit tests
/// (if we add them later) can drive the logic without spinning up the
/// AppIntents runtime.
public enum LockScreenDrinkLogger {

    /// Standard ethanol elimination rate (Widmark, % BAC per hour).
    /// Same constant LiveSeshState uses — duplicated here so this file
    /// has no main-app dependency.
    fileprivate static let eliminationRate: Double = 0.015

    /// Append a drink, recompute BAC across the full timeline, and push
    /// the new state to the running activity. Safe to call from any
    /// task — internally hops to the main actor for ActivityKit.
    public static func append(
        name: String,
        detail: String,
        category: String,
        volumeML: Double,
        abv: Double
    ) async {
        let now = Date()

        // Group mode: this file can't reach Supabase (it also compiles
        // into the widget extension), so queue the add for the app to
        // sync to the session, optimistically bump the activity, and
        // bail out of the solo path.
        if UserDefaults.standard.bool(forKey: LockScreenStorageKeys.liveGroupActive) {
            await appendGroupQueued(
                name: name, detail: detail, category: category,
                volumeML: volumeML, abv: abv, now: now
            )
            return
        }

        // 1) Append to the on-disk drink log. We decode the existing
        //    array, append, re-encode. Same encoder settings as
        //    LiveSeshState (ISO-8601 dates) so the running app reads
        //    these back identically.
        var drinks = loadDrinks()
        drinks.append(
            StoredLiveDrink(
                id: UUID(),
                optionName: name,
                detail: detail,
                category: category,
                volumeML: volumeML,
                abv: abv,
                consumedAt: now
            )
        )
        saveDrinks(drinks)

        // 2) Stamp the start time if this is the very first drink of
        //    the sesh. LiveSeshState's `add(_:)` does the same dance.
        let raw = UserDefaults.standard.double(forKey: LockScreenStorageKeys.startedResolved)
        if raw <= 0 {
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: LockScreenStorageKeys.startedResolved)
        }

        // 3) Move this option to the front of the recents list.
        bumpRecents(name: name, detail: detail, category: category, volumeML: volumeML, abv: abv)

        // 4) Compute new BAC chronologically over the whole timeline.
        //    Same single-timeline simulation LiveSeshState.bac uses —
        //    BAC accumulates instantly with each drink and decays
        //    continuously at `eliminationRate` between events,
        //    clamped at 0. Walking event-by-event (rather than
        //    summing per-drink contributions independently and
        //    clamping each) is the difference between counting a
        //    drink for its full metabolisation window vs. silently
        //    dropping it the moment its individual contribution
        //    would go negative.
        let (weightKg, sexR) = loadCachedBodyParams()
        let bodyGrams = weightKg * 1000
        let denom = bodyGrams * sexR
        var bac: Double = 0
        if denom > 0 {
            let sorted = drinks.sorted { $0.consumedAt < $1.consumedAt }
            var lastEvent: Date? = nil
            for d in sorted where d.consumedAt <= now {
                if let last = lastEvent {
                    let hours = d.consumedAt.timeIntervalSince(last) / 3600
                    bac = max(0, bac - eliminationRate * hours)
                }
                let grams = d.volumeML * d.abv * 0.789
                bac += (grams / denom) * 100
                lastEvent = d.consumedAt
            }
            if let last = lastEvent {
                let hours = max(0, now.timeIntervalSince(last) / 3600)
                bac = max(0, bac - eliminationRate * hours)
            }
        }
        let hoursToSober = max(0, bac / eliminationRate)
        let soberAt = now.addingTimeInterval(hoursToSober * 3600)

        // 5) Push fresh state to the running activity. We preserve the
        //    activity's existing `quickDrinks` so the buttons don't
        //    flicker out — the next foreground tick will reorder them
        //    correctly. (We could reorder here too, but reading the
        //    catalog requires app-side types we don't have access to.)
        await pushActivityUpdate(
            bac: bac,
            drinkCount: drinks.count,
            soberAt: soberAt,
            statusRaw: statusRaw(forBAC: bac),
            now: now
        )

        // 6) Tell any running SwiftUI hierarchy to reload its
        //    @StateObject LiveSeshState from disk so the in-app
        //    timeline shows the new drink the moment the user
        //    unlocks.
        await MainActor.run {
            NotificationCenter.default.post(
                name: .liveSeshLockScreenDidAddDrink,
                object: nil
            )
        }
    }

    // MARK: - Recents (shared by solo + group paths)

    /// On-disk recents entry. JSON keys match the main app's RecentDrink
    /// so the app reads/writes the same list.
    fileprivate struct StoredRecentDrink: Codable {
        var name: String
        var detail: String
        var category: String
        var volumeML: Double
        var abv: Double
    }

    /// Move an option to the front of the v2 recents list (deduped by
    /// name, capped at 6), so the quick-add tiles reflect what was just
    /// tapped.
    fileprivate static func bumpRecents(name: String, detail: String, category: String, volumeML: Double, abv: Double) {
        var recents: [StoredRecentDrink] = []
        if let data = UserDefaults.standard.data(forKey: LockScreenStorageKeys.recentsV2),
           let arr = try? JSONDecoder().decode([StoredRecentDrink].self, from: data) {
            recents = arr
        }
        recents.removeAll { $0.name == name }
        recents.insert(
            StoredRecentDrink(name: name, detail: detail, category: category, volumeML: volumeML, abv: abv),
            at: 0
        )
        if recents.count > 6 { recents = Array(recents.prefix(6)) }
        if let data = try? JSONEncoder().encode(recents) {
            UserDefaults.standard.set(data, forKey: LockScreenStorageKeys.recentsV2)
        }
    }

    // MARK: - Group path (queue + optimistic activity bump)

    /// In a live group the intent can't write to Supabase, so it queues
    /// the add for the app to sync to the session, optimistically bumps
    /// the running activity (the lock-screen card shows YOUR BAC, so a
    /// personal drink just adds its full contribution), and updates the
    /// recents list. The app drains the queue + reconciles the exact
    /// group BAC on its next sync.
    fileprivate static func appendGroupQueued(
        name: String, detail: String, category: String,
        volumeML: Double, abv: Double, now: Date
    ) async {
        // 1) Queue for the app to insert into the session.
        var queue: [StoredRecentDrink] = []
        if let data = UserDefaults.standard.data(forKey: LockScreenStorageKeys.pendingGroupDrinks),
           let arr = try? JSONDecoder().decode([StoredRecentDrink].self, from: data) {
            queue = arr
        }
        queue.append(StoredRecentDrink(name: name, detail: detail, category: category, volumeML: volumeML, abv: abv))
        if let data = try? JSONEncoder().encode(queue) {
            UserDefaults.standard.set(data, forKey: LockScreenStorageKeys.pendingGroupDrinks)
        }

        // 2) Keep recents fresh.
        bumpRecents(name: name, detail: detail, category: category, volumeML: volumeML, abv: abv)

        // 3) Optimistically bump the activity. Adding one personal drink
        //    raises your BAC by (grams / (mass × r)) × 100; the app
        //    reconciles the precise group value on its next poll.
        let (weightKg, sexR) = loadCachedBodyParams()
        let denom = weightKg * 1000 * sexR
        let grams = volumeML * abv * 0.789
        let bump = denom > 0 ? (grams / denom) * 100 : 0

        await MainActor.run {
            guard let activity = Activity<SeshActivityAttributes>.activities.first else { return }
            let prev = activity.content.state
            let newBAC = max(0, prev.bac + bump)
            let hoursToSober = max(0, newBAC / eliminationRate)
            let soberAt = now.addingTimeInterval(hoursToSober * 3600)
            let next = SeshActivityAttributes.ContentState(
                bac: newBAC,
                drinkCount: prev.drinkCount + 1,
                soberAt: soberAt,
                startedAt: prev.startedAt,
                statusRaw: statusRaw(forBAC: newBAC),
                lastUpdate: now,
                quickDrinks: prev.quickDrinks,
                roster: prev.roster,
                topRoast: prev.topRoast
            )
            Task { await activity.update(ActivityContent(state: next, staleDate: nil)) }
            NotificationCenter.default.post(name: .liveSeshLockScreenDidAddDrink, object: nil)
        }
    }

    // MARK: - I/O helpers

    fileprivate static func loadDrinks() -> [StoredLiveDrink] {
        guard let data = UserDefaults.standard.data(forKey: LockScreenStorageKeys.drinksResolved)
        else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([StoredLiveDrink].self, from: data)) ?? []
    }

    fileprivate static func saveDrinks(_ drinks: [StoredLiveDrink]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(drinks) {
            UserDefaults.standard.set(data, forKey: LockScreenStorageKeys.drinksResolved)
        }
    }

    /// Returns (weightKg, r) for Widmark. Falls back to a 75 kg male
    /// profile if no profile has been cached yet — the only time this
    /// matters is the first drink ever, before AuthService has
    /// finished resolving the profile, and even then the lock-screen
    /// buttons would be hidden because there'd be no recent drinks
    /// to render. Defensive default just keeps a stray edge case from
    /// dividing by zero.
    fileprivate static func loadCachedBodyParams() -> (Double, Double) {
        let weight = UserDefaults.standard.double(forKey: LockScreenStorageKeys.profileWeightKg)
        let sexRaw = UserDefaults.standard.string(forKey: LockScreenStorageKeys.profileSexRaw) ?? "male"
        let r = sexRaw == "female" ? 0.55 : 0.68
        return (weight > 0 ? weight : 75, r)
    }

    /// String form of the in-app `Status` enum. Kept in sync with
    /// `statusFor(bac:)` in content_view.swift. Plain string so the
    /// widget can decode without importing the enum.
    fileprivate static func statusRaw(forBAC bac: Double) -> String {
        switch bac {
        case ..<0.02: return "sober"
        case 0.02..<0.05: return "buzzed"
        case 0.05..<0.08: return "impaired"
        case 0.08..<0.15: return "drunk"
        default: return "danger"
        }
    }

    /// Push a fresh ContentState to the in-flight activity. Preserves
    /// the existing `quickDrinks` so the buttons don't blip while
    /// we're re-rendering from a tap.
    @MainActor
    fileprivate static func pushActivityUpdate(
        bac: Double,
        drinkCount: Int,
        soberAt: Date,
        statusRaw: String,
        now: Date
    ) async {
        guard let activity = Activity<SeshActivityAttributes>.activities.first
        else { return }
        let prev = activity.content.state
        let next = SeshActivityAttributes.ContentState(
            bac: max(0, bac),
            drinkCount: drinkCount,
            soberAt: soberAt,
            startedAt: prev.startedAt,
            statusRaw: statusRaw,
            lastUpdate: now,
            quickDrinks: prev.quickDrinks,
            roster: prev.roster,
            topRoast: prev.topRoast
        )
        await activity.update(ActivityContent(state: next, staleDate: nil))
    }
}
