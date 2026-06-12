// Lifecycle wrapper around ActivityKit. The main app talks to this
// singleton; the singleton owns the in-flight `Activity<...>` and
// pushes updates / starts / ends. Centralising this keeps the call
// sites in content_view.swift tiny and ensures we never have two
// activities racing each other.
//
// When to call:
//
//   • start(...)       — first drink in a live mode session, OR when the
//                        user enters a live group session that already
//                        has drinks. Idempotent: calling again with an
//                        existing activity just updates it.
//   • update(...)      — every drink add/remove, plus the 30s
//                        TimelineView tick in LiveSeshView.
//   • end()            — solo END / leaving a live group / sesh ended
//                        by host / BAC reaches 0 and stays there.
//
// Robustness:
//
//   • Authorisation may be off (user declined Live Activities in
//     Settings). All entry points return early in that case rather
//     than throwing — a missing lock-screen card is a cosmetic loss,
//     not a functional one.
//   • The activity is held weakly to a single in-flight instance.
//     iOS allows multiple but for this app one per user is the right
//     mental model — the alternative would be juggling solo + group
//     activities simultaneously, which the user can't even produce
//     (live mode is single-session).

import ActivityKit
import Foundation

@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()

    /// The currently-running activity, if any. nil between sessions.
    private var activity: Activity<SeshActivityAttributes>? = nil

    private let eliminationRate = 0.015

    private init() {
        // On launch, try to attach to any pre-existing activity from a
        // prior app run. iOS keeps the activity alive across app
        // restarts (within the 8h budget) so we want subsequent
        // updates to land on the same one rather than spawning a new
        // card on the lock screen.
        if let existing = Activity<SeshActivityAttributes>.activities.first {
            self.activity = existing
        }
    }

    /// True when Live Activities are enabled at the OS level. Off ⇒
    /// every entry point is a no-op. The user toggles this in
    /// Settings → sesh → Live Activities.
    private var enabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    // MARK: - Lifecycle

    /// Start (or replace) the activity. Idempotent in spirit: if an
    /// activity already exists, this updates it rather than spawning
    /// a duplicate.
    ///
    /// `quickDrinks` carries the user's most-recent picks and renders
    /// as one-tap re-add buttons on the lock screen. Pass an empty
    /// array in group mode (we don't surface lock-screen logging
    /// there for v1 — group writes need network).
    func start(
        bac: Double,
        drinkCount: Int,
        startedAt: Date,
        inGroup: Bool,
        statusRaw: String,
        quickDrinks: [SeshActivityAttributes.QuickDrink] = [],
        roster: [SeshActivityAttributes.RosterMember] = [],
        topRoast: String? = nil,
        now: Date = Date()
    ) {
        guard enabled else { return }

        let state = makeState(
            bac: bac,
            drinkCount: drinkCount,
            startedAt: startedAt,
            statusRaw: statusRaw,
            quickDrinks: quickDrinks,
            roster: roster,
            topRoast: topRoast,
            now: now
        )

        if let activity = activity {
            // Already running — just push fresh content. start() can
            // be called from "first drink ever" and from "first drink
            // after re-launch"; the second case lands here.
            Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
            return
        }

        let attributes = SeshActivityAttributes(
            heroLabel: inGroup ? "GROUP SESH" : "LIVE SESH",
            inGroup: inGroup
        )

        do {
            self.activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
        } catch {
            // Most failures here are "not authorised" or "too many
            // activities" — both recoverable next time. We swallow
            // and log instead of surfacing because the in-app UI
            // works regardless of whether the activity exists.
            print("LiveActivity start failed:", error)
        }
    }

    /// Push a fresh snapshot to the running activity. No-op if there
    /// isn't one — letting the caller fire-and-forget on every tick.
    func update(
        bac: Double,
        drinkCount: Int,
        startedAt: Date,
        statusRaw: String,
        quickDrinks: [SeshActivityAttributes.QuickDrink] = [],
        roster: [SeshActivityAttributes.RosterMember] = [],
        topRoast: String? = nil,
        now: Date = Date()
    ) {
        guard enabled, let activity = activity else { return }

        let state = makeState(
            bac: bac,
            drinkCount: drinkCount,
            startedAt: startedAt,
            statusRaw: statusRaw,
            quickDrinks: quickDrinks,
            roster: roster,
            topRoast: topRoast,
            now: now
        )
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    /// End the activity and clear local state. The dismissal policy
    /// `.immediate` removes the card from the lock screen at once;
    /// the alternative `.after(date)` would leave the snapshot
    /// hanging around for a while, which is creepy for an alcohol
    /// readout (someone glancing at the phone an hour later would
    /// see a stale BAC).
    func end() {
        guard let activity = activity else { return }
        self.activity = nil

        let finalState = SeshActivityAttributes.ContentState(
            bac: 0,
            drinkCount: 0,
            soberAt: Date(),
            startedAt: Date(),
            statusRaw: "sober",
            lastUpdate: Date(),
            quickDrinks: []
        )
        Task {
            await activity.end(
                ActivityContent(state: finalState, staleDate: nil),
                dismissalPolicy: .immediate
            )
        }
    }

    /// Re-push the current state so the Live Activity views re-render
    /// without otherwise changing anything — used when a display
    /// preference (e.g. the BAC unit) changes mid-sesh. No-op if there's
    /// no running activity.
    func refresh() {
        guard enabled, let activity = activity else { return }
        let state = activity.content.state
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    // MARK: - Helpers

    private func makeState(
        bac: Double,
        drinkCount: Int,
        startedAt: Date,
        statusRaw: String,
        quickDrinks: [SeshActivityAttributes.QuickDrink],
        roster: [SeshActivityAttributes.RosterMember],
        topRoast: String? = nil,
        now: Date
    ) -> SeshActivityAttributes.ContentState {
        let hoursToSober = max(0, bac / eliminationRate)
        let soberAt = now.addingTimeInterval(hoursToSober * 3600)
        return SeshActivityAttributes.ContentState(
            bac: max(0, bac),
            drinkCount: drinkCount,
            soberAt: soberAt,
            startedAt: startedAt,
            statusRaw: statusRaw,
            lastUpdate: now,
            quickDrinks: quickDrinks,
            roster: roster,
            topRoast: topRoast
        )
    }
}
