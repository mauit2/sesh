// Shared between the main app and the seshLiveActivity widget extension.
// Lives in BOTH target memberships — the app constructs the activity, the
// widget renders it, and ActivityKit serialises this struct across the
// process boundary.
//
// Design notes:
//
// • `bac` is the value at `lastUpdate`. The widget shows it as-is and
//   prints "as of HH:MM" so the user knows it's a snapshot. We update on
//   every drink + every 30s while the app is open; between updates the
//   number drifts by ~0.0075 per 30 min (linear elimination), which is
//   imperceptible at three-decimal display.
//
// • `soberAt` is a fixed Date so the widget can render a live-ticking
//   countdown via `Text(timerInterval:)` without any data plumbing.
//   That's what makes the Lock Screen feel alive between app updates.
//
// • `statusRaw` is a string (not the `Status` enum) because the enum
//   lives in content_view.swift behind a `private` extension. Keeping
//   the wire format primitive avoids dragging more files into the
//   shared target. The widget maps it back to a colour locally.
//
// • `quickDrinks` carries the user's 2–3 most-recent picks so the widget
//   can render them as `Button(intent:)` chips on the lock screen + in
//   the Dynamic Island expanded region. The whole DrinkOption is
//   denormalised here (name/detail/category/volumeML/abv) because the
//   widget process can't see DrinkCatalog, and because the App Intent
//   needs the same primitives in its perform() to log the drink without
//   re-resolving against a catalog the intent file can't import.

import ActivityKit
import Foundation

public struct SeshActivityAttributes: ActivityAttributes {

    /// One row in the group-mode roster shown on the lock-screen card
    /// and the Dynamic Island. Carries the rendered values at
    /// `lastUpdate` time — the widget doesn't do any BAC math itself,
    /// the app's `syncLockScreenActivity` computes per-member values
    /// from `SessionService.liveBAC(for:)` and embeds them here.
    /// Empty array in solo mode.
    public struct RosterMember: Codable, Hashable, Identifiable {
        public var profileId: UUID
        public var name: String
        public var bac: Double
        /// Raw of `Status` (sober/buzzed/impaired/drunk/danger).
        /// Plain string so the widget can decode without the enum.
        public var statusRaw: String
        public var drinkCount: Int
        /// 1–2 letter fallback shown in the avatar circle when we
        /// don't ship images into the activity payload (we don't —
        /// keeping the ContentState under the 4kB ActivityKit cap).
        public var initials: String
        /// True for the device owner — used to draw a whiskey ring on
        /// the avatar so the user can spot themselves at a glance in
        /// a roster of 3–4 people.
        public var isMe: Bool

        public var id: UUID { profileId }

        public init(
            profileId: UUID,
            name: String,
            bac: Double,
            statusRaw: String,
            drinkCount: Int,
            initials: String,
            isMe: Bool
        ) {
            self.profileId = profileId
            self.name = name
            self.bac = bac
            self.statusRaw = statusRaw
            self.drinkCount = drinkCount
            self.initials = initials
            self.isMe = isMe
        }
    }

    /// One drink option suitable for one-tap re-add from the lock screen.
    /// Carries the full primitives the App Intent needs — the widget
    /// reads `name` / `emoji` for rendering, the intent reads everything
    /// for Widmark math when it logs the drink.
    public struct QuickDrink: Codable, Hashable, Identifiable {
        public var name: String
        public var detail: String
        /// Raw of `DrinkCategory` (beer / wine / cocktail / etc.). Plain
        /// string so this struct doesn't need to import the enum.
        public var category: String
        public var volumeML: Double
        public var abv: Double
        /// Pre-resolved emoji for the chip glyph. We pass it through
        /// rather than mapping in the widget so a future catalog tweak
        /// (custom glyph, venue special icon) only has to touch the
        /// app-side code.
        public var emoji: String

        public var id: String { name }

        public init(
            name: String,
            detail: String,
            category: String,
            volumeML: Double,
            abv: Double,
            emoji: String
        ) {
            self.name = name
            self.detail = detail
            self.category = category
            self.volumeML = volumeML
            self.abv = abv
            self.emoji = emoji
        }
    }

    /// Mutable per-update state. Pushed to the system every time the
    /// user adds/removes a drink, plus on the 30s LiveSeshView tick.
    public struct ContentState: Codable, Hashable {
        /// BAC computed at `lastUpdate`. Renders as the headline numeric.
        public var bac: Double
        /// How many drinks have been logged this sesh — used as the
        /// secondary numeric on the lock screen card.
        public var drinkCount: Int
        /// Wall-clock time at which BAC will linearly hit 0 from the
        /// current value at the standard 0.015/hr elimination rate.
        /// The widget uses this to drive a live-ticking countdown.
        public var soberAt: Date
        /// When the sesh started — drives the elapsed-time chip on the
        /// expanded Dynamic Island view.
        public var startedAt: Date
        /// One of "sober" / "buzzed" / "impaired" / "drunk" / "danger".
        /// Plain string so we don't need to share the Status enum.
        public var statusRaw: String
        /// Wall-clock time at which the values above were computed.
        /// Surfaced as "as of HH:MM" on the card.
        public var lastUpdate: Date
        /// Up to three most-recent drinks for the lock-screen quick-add
        /// row. Empty in group mode (lock-screen logging is solo-only
        /// for v1) and on a brand-new account with no recent picks yet.
        public var quickDrinks: [QuickDrink]
        /// Up to four group members (including the user) for the
        /// roster row on the lock-screen card + Dynamic Island
        /// expanded view. Empty when solo. The 4-cap keeps the card
        /// under iOS's height budget; larger groups truncate to the
        /// drunkest 4 so the most "relevant" rows surface.
        public var roster: [RosterMember]

        public init(
            bac: Double,
            drinkCount: Int,
            soberAt: Date,
            startedAt: Date,
            statusRaw: String,
            lastUpdate: Date,
            quickDrinks: [QuickDrink] = [],
            roster: [RosterMember] = []
        ) {
            self.bac = bac
            self.drinkCount = drinkCount
            self.soberAt = soberAt
            self.startedAt = startedAt
            self.statusRaw = statusRaw
            self.lastUpdate = lastUpdate
            self.quickDrinks = quickDrinks
            self.roster = roster
        }
    }

    /// Static-for-the-lifetime-of-the-activity metadata. We use it to
    /// distinguish solo from group seshs in the lock-screen header
    /// without having to thread it through every update.
    public var heroLabel: String   // "LIVE SESH" or "GROUP SESH"
    public var inGroup: Bool

    public init(heroLabel: String, inGroup: Bool) {
        self.heroLabel = heroLabel
        self.inGroup = inGroup
    }
}
