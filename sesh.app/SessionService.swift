// SessionService — the group-sesh engine: join/create/leave/end, member
// + drink + ghost sync, per-mode (plan/live) lifecycle, route stops, and
// end-of-night recap capture. Extracted from content_view.swift; pure
// relocation (all private methods stay members of the class).

import SwiftUI
import Combine
import CoreLocation
import Foundation
import Supabase

// MARK: - Session service (group sesh)

@MainActor
final class SessionService: ObservableObject {
    @Published var session: SeshSession?
    @Published var members: [SessionMember] = []
    @Published var memberProfiles: [UUID: Profile] = [:]
    @Published var drinks: [SessionDrink] = []
    /// Manually-added guests, synced across every device in this session
    /// via the session row's JSONB `ghosts` column. Mirrored into the
    /// device-local GhostMembersStore by SessionView while a live group
    /// is active. Empty when there's no session.
    @Published var ghosts: [GhostMember] = []
    /// True while a guest-roster write is in flight, so a concurrent poll
    /// doesn't overwrite the optimistic local value with stale server data.
    private var ghostWriteInFlight = false
    /// The group's shared current venue (synced from `session.live_venue`).
    /// nil = the group is checked out.
    @Published var liveVenue: Venue? = nil
    /// Whether THIS device follows the group's location. Local + per-device:
    /// true (default) ⇒ adopt group check-ins; false ⇒ "broke away", manage
    /// my own venue. Reset to true on join.
    @Published var followingGroupVenue = true
    private var liveVenueWriteInFlight = false
    /// The group's shared pre-game / between location (synced).
    @Published var liveLooseSpot: LooseSpot? = nil
    private var liveLooseSpotWriteInFlight = false
    @Published var error: String?
    @Published var busy = false

    private var pollTask: Task<Void, Never>?

    /// Which mode this store powers. Two stores live in SessionView
    /// (one for PLAN, one for LIVE) so a user can be in two unrelated
    /// groups at the same time. Determines:
    ///   - the `live` flag stamped on every drink this store inserts,
    ///   - which slice of `drinks` the helpers below filter to,
    ///   - the UserDefaults key used to remember which session this
    ///     store was last in (so resumeIfAny picks the right one on
    ///     relaunch even when the user has different sessions per mode).
    let scope: SeshMode

    /// The OTHER store. Set by SessionView after both are constructed.
    /// Used by `leave()` to avoid deleting the shared session_members
    /// row when both stores happen to track the same session — without
    /// this, leaving one mode would yank the user out of the other too.
    weak var cousin: SessionService?

    init(scope: SeshMode) {
        self.scope = scope
    }

    /// True for live store, false for plan. Stamped on every drink this
    /// store inserts and used as the in-memory filter for ledger slices.
    private var scopeLive: Bool { scope == .live }

    // ---------------------------------------------------------------
    // Per-mode column helpers (migration 007). These keep the per-scope
    // querying code from sprouting `if scope == .plan` everywhere.
    // ---------------------------------------------------------------

    /// `active_plan` for plan store, `active_live` for live store. Used
    /// when the host ends "this mode" of a session — flips just this
    /// flag, leaving the OTHER mode's flag (and the legacy `active`
    /// flag) untouched so the cousin mode stays alive.
    private var activeColumnForScope: String {
        scopeLive ? "active_live" : "active_plan"
    }

    /// `in_plan` for plan store, `in_live` for live store. Used when:
    ///   - inserting/updating my own session_members row to mark
    ///     membership in this mode,
    ///   - filtering the members list to "people still in the sesh in
    ///     my mode".
    private var inColumnForScope: String {
        scopeLive ? "in_live" : "in_plan"
    }

    /// UserDefaults key for "which session was this store last in".
    /// Scoped so plan and live can persist different session IDs.
    private var persistKey: String { "sesh.lastSessionId.\(scope.rawValue)" }

    private func persistSessionID(_ id: UUID?) {
        if let id {
            UserDefaults.standard.set(id.uuidString, forKey: persistKey)
        } else {
            UserDefaults.standard.removeObject(forKey: persistKey)
        }
    }

    var isActive: Bool { session != nil }
    var myId: UUID? { supabase.auth.currentUser?.id }
    var isHost: Bool {
        guard let s = session, let uid = myId else { return false }
        return s.hostId == uid
    }

    // MARK: - Regular (manual-duration) ledger
    //
    // Everything below filters to `live == false`. The regular order card,
    // the duration-slider BAC calculation, and the host roster all read
    // from this slice so live-mode drinks never leak into the manual view.

    func myDrinks() -> [SessionDrink] {
        guard let uid = myId else { return [] }
        return drinks.filter { $0.profileId == uid && !$0.shared && !$0.live }
    }

    func mySharedDrinks() -> [SessionDrink] {
        guard let uid = myId else { return [] }
        return drinks.filter { $0.profileId == uid && $0.shared && !$0.live }
    }

    func sharedDrinks() -> [SessionDrink] {
        drinks.filter { $0.shared && !$0.live }
    }

    func drinks(for profileId: UUID) -> [SessionDrink] {
        drinks.filter { $0.profileId == profileId && !$0.shared && !$0.live }
    }

    /// Grams of ethanol attributable to a given member in the regular
    /// (non-live) ledger: their personal drinks plus their even share of
    /// any drinks marked `shared`. Live-mode drinks are excluded — they
    /// have their own per-drink Widmark calculation in `liveBAC(...)`.
    func effectiveGrams(for profileId: UUID) -> Double {
        let personal = drinks
            .filter { $0.profileId == profileId && !$0.shared && !$0.live }
            .reduce(0) { $0 + $1.grams }
        let shared = drinks
            .filter { $0.shared && !$0.live }
            .reduce(0) { $0 + $1.grams }
        let n = max(members.count, 1)
        return personal + shared / Double(n)
    }

    /// Synced duration (hours) for a given member. Prefers the value each
    /// member has set on their own slider and pushed to the DB; falls back
    /// to "time since their first relevant drink" so new members without a
    /// synced value still get a reasonable BAC read.
    /// Because every phone reads the same value from the DB, BACs now match
    /// across devices.
    func duration(for profileId: UUID, now: Date = Date()) -> Double {
        if let m = members.first(where: { $0.profileId == profileId }),
           let synced = m.durationHours {
            return max(0, synced)
        }
        let relevant = drinks.filter {
            ($0.profileId == profileId && !$0.shared) || $0.shared
        }
        guard let earliest = relevant.map({ $0.createdAt }).min() else { return 0 }
        return max(0, now.timeIntervalSince(earliest) / 3600)
    }

    /// Pushes the current user's duration slider value to the shared
    /// `session_members` row so other phones see the same number.
    func updateMyDuration(_ hours: Double) async {
        guard let sid = session?.id, let uid = myId else { return }
        // Optimistic local update so the roster reflects the change instantly.
        if let idx = members.firstIndex(where: { $0.profileId == uid }) {
            members[idx].durationHours = hours
        }
        struct Patch: Encodable { let duration_hours: Double }
        _ = try? await supabase.from("session_members")
            .update(Patch(duration_hours: hours))
            .eq("session_id", value: sid.uuidString.lowercased())
            .eq("profile_id", value: uid.uuidString.lowercased())
            .execute()
    }

    /// Returns the synced duration the current user has on record, if any.
    /// Lets the UI restore the slider position on launch / after polling.
    func myDuration() -> Double? {
        guard let uid = myId else { return nil }
        return members.first(where: { $0.profileId == uid })?.durationHours
    }

    // MARK: - Live ledger (per-drink Widmark)
    //
    // Everything below filters to `live == true`. The live timeline,
    // roster, roast card, and live BAC all read from this slice so the
    // regular calculator's drinks never bleed into the live view.

    /// All `live == true` drinks for the session. Convenience accessor so
    /// every live-side helper agrees on the same filtered slice.
    private var liveDrinks: [SessionDrink] {
        drinks.filter { $0.live }
    }

    /// Has anyone in the group started a Live Sesh yet? Used by the
    /// LiveSeshBar to decide whether to show the active "LIVE · N PEOPLE"
    /// pill or the idle CTA.
    var hasLiveActivity: Bool { !liveDrinks.isEmpty }

    /// Live group Widmark — chronological simulation over the slice of
    /// drinks that count for this member: their personal pours plus
    /// their share of every shared round. Per-drink gating is applied
    /// before the walk so the rest is the same single-timeline math the
    /// solo calculator uses (see LiveSeshState.bac for the rationale).
    /// Server-stamped `createdAt` keeps the result identical on every
    /// phone in the group.
    /// Total heads a shared round is split across — real members PLUS
    /// manually-added guests. Guests drink too, so a shared "round of
    /// shots" has to divide by everyone present, not just app users.
    private var sharedHeadCount: Int {
        max(members.count + ghosts.count, 1)
    }

    func liveBAC(for profileId: UUID, now: Date = Date()) -> Double {
        guard let profile = memberProfiles[profileId] else { return 0 }
        let bodyGrams = profile.weightKg * 1000
        let denom = bodyGrams * profile.sex.r
        guard denom > 0 else { return 0 }
        let n = sharedHeadCount

        // 1) Project each contributing drink to (timestamp, grams_to_me).
        //    Drinks that aren't mine and aren't shared drop out here.
        let events: [(Date, Double)] = liveDrinks.compactMap { d in
            let isMine = d.profileId == profileId && !d.shared
            let isShared = d.shared
            guard isMine || isShared else { return nil }
            let grams = isShared ? d.grams / Double(n) : d.grams
            return (d.createdAt, grams)
        }.sorted { $0.0 < $1.0 }

        // 2) Walk forward applying continuous decay between events.
        var bac: Double = 0
        var lastEvent: Date? = nil
        for (when, grams) in events where when <= now {
            if let last = lastEvent {
                let hours = when.timeIntervalSince(last) / 3600
                bac = max(0, bac - 0.015 * hours)
            }
            bac += (grams / denom) * 100
            lastEvent = when
        }
        if let last = lastEvent {
            let hours = max(0, now.timeIntervalSince(last) / 3600)
            bac = max(0, bac - 0.015 * hours)
        }
        return bac
    }

    /// Hours until a member reaches a BAC threshold under the live model.
    /// Uses the constant ~0.015 BAC%/hr metabolism rate.
    func liveHoursUntil(threshold: Double, for profileId: UUID, now: Date = Date()) -> Double {
        max(0, (liveBAC(for: profileId, now: now) - threshold) / 0.015)
    }

    /// The member's live drinks projected to timestamped recap events —
    /// the same (timestamp, grams-to-me) reduction `liveBAC` runs, plus
    /// the drink name for the recap's per-stop summaries. Shared rounds
    /// contribute their per-head share, exactly like the BAC math.
    func myLiveRecapEvents(for profileId: UUID) -> [RecapEvent] {
        myLiveRecapEvents(
            from: drinks, memberCount: members.count, ghostCount: ghosts.count, for: profileId
        )
    }

    /// Same projection from EXPLICIT inputs — used when a live group sesh
    /// is detected as ended mid-poll, before the freshly-fetched roster
    /// has been assigned to `self` (so `members`/`drinks` aren't current).
    func myLiveRecapEvents(
        from sourceDrinks: [SessionDrink],
        memberCount: Int,
        ghostCount: Int,
        for profileId: UUID
    ) -> [RecapEvent] {
        let n = max(memberCount + ghostCount, 1)
        return sourceDrinks.filter { $0.live }.compactMap { d in
            let isMine = d.profileId == profileId && !d.shared
            guard isMine || d.shared else { return nil }
            let grams = d.shared ? d.grams / Double(n) : d.grams
            return RecapEvent(when: d.createdAt, grams: grams, name: d.drinkName)
        }.sorted { $0.when < $1.when }
    }

    /// Handoff for the auto-recap: set to the user's projected events the
    /// instant a LIVE group sesh ends (host ended, self left, or kicked),
    /// just before `clearLocal` wipes the roster. SessionView observes
    /// this, builds + presents the recap, then resets it to nil. Only
    /// ever non-empty for the live-scope store.
    @Published var endedLiveEvents: [RecapEvent]? = nil
    /// The squad's per-member stats captured at the same instant, for the
    /// group recap's leaderboard. Nil for a solo sesh / single member.
    @Published var endedGroupLeaderboard: [GroupMemberStat]? = nil
    /// Raw materials for the SQUAD recap, captured at the same instant:
    /// the whole session ledger + everyone's profile, so SessionView can
    /// compute per-stop member stats and fetch the squad schnaps. Nil for
    /// solo nights / single-member groups.
    @Published var endedGroupContext: EndedGroupContext? = nil

    struct EndedGroupContext {
        let sessionId: UUID
        let drinks: [SessionDrink]
        let profiles: [UUID: Profile]
        let headCount: Int
        /// When the group was created — the group recap only tells the
        /// story from here on; anything a member logged before joining
        /// belongs to their INDIVIDUAL recap alone.
        let sessionStart: Date
        /// Host id — when several members logged the same marker, the
        /// host's naming wins in the group recap.
        let hostId: UUID?
    }

    /// True only when the session was just entered by the user tapping
    /// join/create — as opposed to resumeIfAny restoring it on launch.
    /// SessionView's session observer reads (and resets) this to decide
    /// whether to carry the solo night in: carrying on a mere resume
    /// would dump leftover solo drinks into the group on every relaunch.
    var entryWasUserInitiated = false
    /// Bumped whenever THIS device's live night TERMINALLY ends — host end,
    /// my end, poll-detected end, ended-while-away — but never on a
    /// keep-night leave or a group→group switch (those don't capture).
    /// SessionView observes it to check out of the current venue, even when
    /// no recap is produced (a drink-free night still leaves you "here"
    /// otherwise).
    @Published var liveEndedToken = 0

    /// The group's server-side route (session_stops), refreshed on every
    /// poll. SessionView merges it into the local journey so EVERY member
    /// sees every group stop live — check-ins, between-bars, food, puke,
    /// pre-game — not just the ones their own device witnessed.
    @Published var routeStops: [RouteStopRow] = []

    struct RouteStopRow: Decodable, Equatable {
        let id: UUID
        let name: String
        let lat: Double?
        let lon: Double?
        let kind: String
        let arrivedAt: Date
        let departedAt: Date?
        let profileId: UUID?
        enum CodingKeys: String, CodingKey {
            case id, name, lat, lon, kind
            case arrivedAt = "arrived_at"
            case departedAt = "departed_at"
            case profileId = "profile_id"
        }
    }

    /// Snapshot my events before a live-end clears them. No-op for the
    /// plan store, or when I logged nothing worth replaying.
    private func captureLiveEnd(
        drinks sourceDrinks: [SessionDrink],
        members memberList: [SessionMember],
        ghosts ghostList: [GhostMember],
        sessionIdOverride: UUID? = nil,
        sessionRowOverride: SeshSession? = nil
    ) {
        guard scopeLive, let uid = myId else { return }
        let memberCount = memberList.count
        let ghostCount = ghostList.count
        let events = myLiveRecapEvents(
            from: sourceDrinks, memberCount: memberCount, ghostCount: ghostCount, for: uid
        )
        if !events.isEmpty { endedLiveEvents = events }

        // The squad leaderboard — each member's peak BAC + drink count, for
        // the group recap. Only meaningful with 2+ heads.
        var board: [GroupMemberStat] = []
        for m in memberList {
            guard let p = memberProfiles[m.profileId] else { continue }
            let denom = p.weightKg * 1000 * p.sex.r
            guard denom > 0 else { continue }
            let evs = myLiveRecapEvents(
                from: sourceDrinks, memberCount: memberCount, ghostCount: ghostCount, for: m.profileId
            )
            board.append(GroupMemberStat(
                name: p.name,
                drinkCount: evs.count,
                peakBAC: Self.peakBAC(of: evs, bumpPerGram: 100 / denom),
                isMe: m.profileId == uid
            ))
        }
        for g in ghostList {
            let denom = g.weightKg * 1000 * g.sex.r
            guard denom > 0 else { continue }
            let evs = ghostRecapEvents(g, sharedDrinks: sourceDrinks, headCount: max(memberCount + ghostCount, 1))
            board.append(GroupMemberStat(
                name: g.name,
                drinkCount: evs.count,
                peakBAC: Self.peakBAC(of: evs, bumpPerGram: 100 / denom),
                isMe: false
            ))
        }
        if board.count >= 2 {
            endedGroupLeaderboard = board.sorted { $0.peakBAC > $1.peakBAC }
        }
        // Hand the raw ledger to SessionView so it can build the squad
        // recap (per-stop stats + schnap downloads). Must happen before
        // clearLocal wipes session/drinks/profiles.
        if memberCount >= 2, let sid = sessionIdOverride ?? session?.id {
            let row = sessionRowOverride ?? session
            endedGroupContext = EndedGroupContext(
                sessionId: sid,
                drinks: sourceDrinks,
                profiles: memberProfiles,
                headCount: max(memberCount + ghostCount, 1),
                sessionStart: row?.createdAt ?? .distantPast,
                hostId: row?.hostId
            )
        }
        // Terminal end → tell SessionView to check out, whether or not
        // there was anything to recap. (Switches never reach here — they
        // release the old group without capturing.)
        liveEndedToken &+= 1
    }

    /// The session ended while this device was away (app closed, or the
    /// user signed out) — the poll never saw the end, so no recap was ever
    /// captured. Pull the final ledger straight from the DB, hand off the
    /// recap materials, and release my membership flag so the next launch
    /// doesn't deliver the same night twice.
    private func captureEndedWhileAway(_ row: SeshSession) async {
        guard scopeLive, let uid = myId else { return }
        let sid = row.id.uuidString.lowercased()
        // The FULL roster, not just in_live=true: the session is over, and
        // other devices' own captures release their flags as they deliver —
        // filtering would shrink the leaderboard for whoever captures last.
        let ms: [SessionMember] = (try? await supabase.from("session_members")
            .select()
            .eq("session_id", value: sid)
            .execute()
            .value) ?? []
        let ds: [SessionDrink] = (try? await supabase.from("session_drinks")
            .select()
            .eq("session_id", value: sid)
            .execute()
            .value) ?? []
        let ids = ms.map { $0.profileId.uuidString.lowercased() }
        if !ids.isEmpty,
           let ps: [Profile] = try? await supabase.from("profiles")
            .select()
            .in("id", values: ids)
            .execute()
            .value {
            for p in ps { memberProfiles[p.id] = p }
        }
        captureLiveEnd(drinks: ds, members: ms, ghosts: row.ghosts,
                       sessionIdOverride: row.id, sessionRowOverride: row)
        // Delivered — flip my flag so the fallback scan stops finding it.
        struct InLivePatch: Encodable { let in_live: Bool }
        _ = try? await supabase.from("session_members")
            .update(InLivePatch(in_live: false))
            .eq("session_id", value: sid)
            .eq("profile_id", value: uid.uuidString.lowercased())
            .execute()
        memberProfiles = [:]
    }

    /// Peak of a chronological Widmark walk over the given events.
    private static func peakBAC(of events: [RecapEvent], bumpPerGram: Double) -> Double {
        let sorted = events.sorted { $0.when < $1.when }
        var bac = 0.0, peak = 0.0
        var last: Date? = nil
        for e in sorted {
            if let l = last { bac = max(0, bac - 0.015 * (e.when.timeIntervalSince(l) / 3600)) }
            bac += e.grams * bumpPerGram
            last = e.when
            peak = max(peak, bac)
        }
        return peak
    }

    /// A guest's recap events — their own logged drinks + their per-head
    /// share of shared rounds.
    private func ghostRecapEvents(_ ghost: GhostMember, sharedDrinks: [SessionDrink], headCount n: Int) -> [RecapEvent] {
        var evs: [RecapEvent] = ghost.drinks.map {
            RecapEvent(when: $0.consumedAt, grams: $0.volumeML * $0.abv * 0.789, name: $0.optionName)
        }
        for d in sharedDrinks where d.shared && d.live {
            evs.append(RecapEvent(when: d.createdAt, grams: d.grams / Double(n), name: d.drinkName))
        }
        return evs.sorted { $0.when < $1.when }
    }

    /// Live BAC for a manually-added guest: their own logged drinks PLUS
    /// their share of every shared round (split across all heads — members
    /// + guests). Same chronological Widmark walk the member version uses,
    /// run against the guest's own body params. Guests were previously
    /// getting zero from shared rounds.
    func liveBAC(forGhost ghost: GhostMember, now: Date = Date()) -> Double {
        let denom = ghost.weightKg * 1000 * ghost.sex.r
        guard denom > 0 else { return 0 }
        let n = sharedHeadCount

        var events: [(Date, Double)] = ghost.drinks.map { ($0.consumedAt, $0.grams) }
        for d in liveDrinks where d.shared {
            events.append((d.createdAt, d.grams / Double(n)))
        }
        events.sort { $0.0 < $1.0 }

        var bac: Double = 0
        var lastEvent: Date? = nil
        for (when, grams) in events where when <= now {
            if let last = lastEvent {
                bac = max(0, bac - 0.015 * (when.timeIntervalSince(last) / 3600))
            }
            bac += (grams / denom) * 100
            lastEvent = when
        }
        if let last = lastEvent {
            bac = max(0, bac - 0.015 * max(0, now.timeIntervalSince(last) / 3600))
        }
        return bac
    }

    /// All live drinks attributable to a member, sorted newest-first.
    /// Combines their personal live drinks with all live shared rounds.
    func liveTimeline(for profileId: UUID) -> [SessionDrink] {
        liveDrinks
            .filter { ($0.profileId == profileId && !$0.shared) || $0.shared }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Total live drink count for a member: personal + shared (each shared
    /// drink counts as one round even though it's split).
    func totalDrinkCount(for profileId: UUID) -> Int {
        liveTimeline(for: profileId).count
    }

    /// Earliest live drink time for a member — when their "live" night
    /// effectively started. Returns nil if no live drinks yet.
    func firstDrinkTime(for profileId: UUID) -> Date? {
        let relevant = liveDrinks.filter {
            ($0.profileId == profileId && !$0.shared) || $0.shared
        }
        return relevant.map { $0.createdAt }.min()
    }

    /// Earliest live drink across all members — the moment the live sesh
    /// effectively started for the group.
    func sessionFirstDrink() -> Date? {
        liveDrinks.map { $0.createdAt }.min()
    }

    /// On launch, restore whichever group this scope was last in. We
    /// prefer the persisted ID first — that's how plan and live can
    /// diverge over time (different sessions per scope) without one
    /// store clobbering the other's choice on next launch.
    ///
    /// If nothing is persisted (fresh install, or the user upgraded
    /// from a single-store version), fall back to scanning memberships
    /// and entering whatever's active. On a single-mode upgrade both
    /// stores will land on the same session, which matches legacy
    /// behaviour. Subsequent leaves/joins persist per scope and the
    /// two stores can diverge from there.
    func resumeIfAny() async {
        guard let uid = myId else { return }

        // 1. Persisted session for this scope. Fetched WITHOUT the active
        //    filter so a session that ENDED while this device was away
        //    (app closed / signed out) can still deliver its recap — the
        //    poll never saw the end, so nobody captured it.
        if let raw = UserDefaults.standard.string(forKey: persistKey),
           let sid = UUID(uuidString: raw) {
            if let row: SeshSession = try? await supabase
                .from("sessions")
                .select()
                .eq("id", value: sid.uuidString.lowercased())
                .single()
                .execute()
                .value,
               let _: SessionMember = try? await supabase
                .from("session_members")
                .select()
                .eq("session_id", value: sid.uuidString.lowercased())
                .eq("profile_id", value: uid.uuidString.lowercased())
                .eq(inColumnForScope, value: true)
                .single()
                .execute()
                .value
            {
                let activeForScope = scopeLive ? row.activeLive : row.activePlan
                if activeForScope && isFresh(row) {
                    await enter(session: row)
                    return
                }
                if !activeForScope && scopeLive && isFresh(row) {
                    // Ended while away → recap + release (never re-enter).
                    await captureEndedWhileAway(row)
                } else {
                    // The night is long over but the session was never
                    // ended (host killed the app, switched groups, etc.).
                    // Detach quietly instead of resurrecting a days-old
                    // sesh — and never recap it: entering + recapping
                    // stale sessions is exactly the phantom-recap bug.
                    await silentlyRelease(row)
                }
            }
            // Persisted session is dealt with either way — clear it so we
            // don't keep hitting the network for a dead row every launch.
            persistSessionID(nil)
        }

        // 2. Fallback: scan all my memberships in this mode, most recent
        //    first, and enter the first FRESH one whose session is still
        //    active in this mode. Fresh-but-ended ones deliver their recap
        //    (same as above); older leftovers get released as we go, so
        //    the scan doubles as launch-time garbage collection.
        do {
            let myMemberships: [SessionMember] = try await supabase
                .from("session_members")
                .select()
                .eq("profile_id", value: uid.uuidString.lowercased())
                .eq(inColumnForScope, value: true)
                .order("joined_at", ascending: false)
                .execute()
                .value
            var entered = false
            for m in myMemberships {
                if let row: SeshSession = try? await supabase
                    .from("sessions")
                    .select()
                    .eq("id", value: m.sessionId.uuidString.lowercased())
                    .single()
                    .execute()
                    .value {
                    let activeForScope = scopeLive ? row.activeLive : row.activePlan
                    if activeForScope && !entered && isFresh(row) {
                        await enter(session: row)
                        entered = true
                    } else if !activeForScope && scopeLive && isFresh(row) {
                        await captureEndedWhileAway(row)
                    } else {
                        await silentlyRelease(row)
                    }
                }
            }
        } catch {
            // no active sessions, stay idle
        }
    }

    func create() async {
        busy = true; defer { busy = false }
        error = nil
        do {
            guard let uid = myId else {
                error = "Not signed in"; return
            }
            struct Insert: Encodable { let host_id: String; let join_code: String }
            let code = Self.generateCode()
            let row: SeshSession = try await supabase.from("sessions")
                .insert(Insert(host_id: uid.uuidString.lowercased(), join_code: code))
                .select()
                .single()
                .execute()
                .value
            // Insert the host's membership row marked as "in this mode
            // only" — the OTHER mode's flag is FALSE so creating in
            // plan doesn't silently put the host in live too. They can
            // mirror later via the cousin's join affordance.
            struct M: Encodable {
                let session_id: String
                let profile_id: String
                let in_plan: Bool
                let in_live: Bool
            }
            _ = try await supabase.from("session_members")
                .insert(M(
                    session_id: row.id.uuidString.lowercased(),
                    profile_id: uid.uuidString.lowercased(),
                    in_plan: !scopeLive,
                    in_live: scopeLive
                ))
                .execute()
            // Creating a new group while still in another = a direct
            // switch. Detach from the old one so its membership can't
            // resurrect later. NO recap here — the night continues; the
            // single recap arrives at the night's terminal end.
            if let old = session, old.id != row.id {
                await silentlyRelease(old)
            }
            entryWasUserInitiated = true
            followingGroupVenue = true
            await enter(session: row)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func join(code: String) async {
        busy = true; defer { busy = false }
        error = nil
        do {
            // Pass the scope to the RPC so it sets the right in_<mode>
            // flag (and OR-merges with any existing flag from the
            // other mode — the user might already be a member in live
            // when they tap join in plan).
            struct P: Encodable { let code: String; let mode: String }
            let sid: UUID = try await supabase
                .rpc("join_session_by_code", params: P(code: code.uppercased(), mode: scope.rawValue))
                .execute()
                .value
            let row: SeshSession = try await supabase
                .from("sessions")
                .select()
                .eq("id", value: sid.uuidString.lowercased())
                .single()
                .execute()
                .value
            // Joining while still in another group = a direct switch.
            // Detach from the old one so its membership can't resurrect
            // later. NO recap here — the night continues in the new group;
            // the single recap arrives at the night's TERMINAL end and
            // covers every group along the way.
            if let old = session, old.id != row.id {
                await silentlyRelease(old)
            }
            entryWasUserInitiated = true
            // Joining a group means following it — a "broke away" state
            // left over from a previous group must not block adopting the
            // new group's venue / pre-game spot into my journey.
            followingGroupVenue = true
            await enter(session: row)
        } catch {
            // The join RPC may have SUCCEEDED even though the follow-up
            // session fetch failed — the membership then exists server-side
            // while this device looks like it never joined (and the invite
            // is already consumed). Let resume find and enter it before
            // declaring failure.
            entryWasUserInitiated = true
            await resumeIfAny()
            if session == nil {
                entryWasUserInitiated = false
                self.error = "Couldn't join. Check the code."
            }
        }
    }

    /// Enter an EVENT's auto-started session as a real JOIN, not a resume.
    /// Membership already exists server-side (the lifecycle enrolls going
    /// members at start; respond_to_event enrolls late RSVPs), so there's
    /// no join RPC — but the entry must behave like the user tapped JOIN:
    /// release any current group (direct switch) and flag the entry
    /// user-initiated so the drink-carry machinery moves the running
    /// night in (solo→group and group→group alike). A missing or
    /// released in_live membership means the user LEFT this sesh on
    /// purpose — never drag them back.
    func joinEventSession(id: UUID) async {
        guard session?.id != id, let uid = myId else { return }
        busy = true; defer { busy = false }
        do {
            struct MemberFlag: Decodable {
                let inLive: Bool
                enum CodingKeys: String, CodingKey { case inLive = "in_live" }
            }
            let membership: [MemberFlag] = try await supabase
                .from("session_members")
                .select("in_live")
                .eq("session_id", value: id.uuidString.lowercased())
                .eq("profile_id", value: uid.uuidString.lowercased())
                .eq("in_live", value: true)
                .execute()
                .value
            guard !membership.isEmpty else { return }

            let row: SeshSession = try await supabase
                .from("sessions")
                .select()
                .eq("id", value: id.uuidString.lowercased())
                .single()
                .execute()
                .value
            guard row.activeLive else { return }

            if let old = session, old.id != row.id {
                await silentlyRelease(old)
            }
            entryWasUserInitiated = true
            followingGroupVenue = true
            await enter(session: row)
        } catch {
            // The membership exists server-side; let resume find it so the
            // user at least lands in the sesh (without the drink carry).
            await resumeIfAny()
        }
    }

    /// Leave the group in this mode. Per-mode model (migration 007):
    /// flips just my `in_<scope>` flag on the session_members row,
    /// leaving `in_<other>` untouched. So:
    ///
    ///   - Other members polling for THIS mode see me disappear (their
    ///     refresh filters by `in_<scope>`).
    ///   - Other members polling for the OTHER mode still see me — I
    ///     remain in that mode for everyone, including myself.
    ///   - My cousin store stays put: it queries by `in_<other>`, so
    ///     this update is invisible to it. No cross-store coordination
    ///     needed.
    ///
    /// The `cousinSessionId` parameter is kept for ABI compatibility
    /// with the call sites — we don't actually use it anymore (the
    /// per-mode flags decouple the two stores at the DB level), but
    /// callers still pass it and that's fine.
    func leave(cousinSessionId: UUID? = nil, captureRecap: Bool = true) async {
        _ = cousinSessionId  // intentionally unused under the per-mode model
        guard let sid = session?.id, let uid = myId else { clearLocal(); return }
        // Two concrete Encodable patches so we match the rest of the
        // file's update style — Postgrest-Swift is happiest when the
        // body has a fixed shape it can serialize statically. We can't
        // share the chain via a ternary because `update(_:)` itself is
        // a throwing call, so the branches are inlined into the
        // try/await chain instead.
        struct InPlanPatch: Encodable { let in_plan: Bool }
        struct InLivePatch: Encodable { let in_live: Bool }
        do {
            if scopeLive {
                _ = try await supabase.from("session_members")
                    .update(InLivePatch(in_live: false))
                    .eq("session_id", value: sid.uuidString.lowercased())
                    .eq("profile_id", value: uid.uuidString.lowercased())
                    .execute()
            } else {
                _ = try await supabase.from("session_members")
                    .update(InPlanPatch(in_plan: false))
                    .eq("session_id", value: sid.uuidString.lowercased())
                    .eq("profile_id", value: uid.uuidString.lowercased())
                    .execute()
            }
        } catch {
            // Swallow — same semantics as the previous `try?`. We
            // still go idle locally; the user can retry next session.
        }
        // Ending → hand off the recap. "Just leaving" (to go join another
        // sesh) skips the recap; the night isn't saved.
        if captureRecap {
            captureLiveEnd(drinks: drinks, members: members, ghosts: ghosts)
        }
        clearLocal()
    }

    /// End the group in this mode (host-only flow — the UI only surfaces
    /// this button when `isHost` is true). Per-mode model: flips just
    /// `active_<scope>` on the sessions row, leaving `active_<other>`
    /// alone. Every member polling for THIS mode detects the flip in
    /// their next refresh tick (within ~3s) and goes idle locally. The
    /// OTHER mode keeps running as if nothing happened — the cousin
    /// store on every phone (including the host's) is none the wiser.
    func end(cousinSessionId: UUID? = nil, captureRecap: Bool = true) async {
        _ = cousinSessionId  // intentionally unused under the per-mode model
        guard let sid = session?.id else { clearLocal(); return }
        struct ActivePlanPatch: Encodable { let active_plan: Bool }
        struct ActiveLivePatch: Encodable { let active_live: Bool }
        do {
            if scopeLive {
                _ = try await supabase.from("sessions")
                    .update(ActiveLivePatch(active_live: false))
                    .eq("id", value: sid.uuidString.lowercased())
                    .execute()
            } else {
                _ = try await supabase.from("sessions")
                    .update(ActivePlanPatch(active_plan: false))
                    .eq("id", value: sid.uuidString.lowercased())
                    .execute()
            }
        } catch {
            // Swallow — same semantics as the previous `try?`.
        }
        // NOTE: squad schnaps are NOT purged here — every member's device
        // needs a window to download them into its group recap after the
        // end lands. The daily cleanup sweeps schnaps of ended sessions
        // (and anything past 48h) instead; the sesh being over already
        // hides them from every UI.
        // Host ending a live group ends everyone's night → recap for me too,
        // unless the host is just leaving to keep their night going elsewhere.
        // Capture → clearLocal must be atomic (no awaits between): the
        // recap observer fires on the capture, and if it runs while
        // `session` still looks alive it treats a TERMINAL end as "night
        // continues" and skips clearing the journey/check-in — that was
        // the "pre-game spot survives the end" bug.
        if captureRecap {
            captureLiveEnd(drinks: drinks, members: members, ghosts: ghosts)
        }
        clearLocal()
        // This night is over for me — release my flag so the launch scan
        // can't deliver it again as an "ended while away" recap.
        await markDelivered(sid)
    }

    /// Flip my `in_<scope>` membership flag after a recap has been
    /// captured on THIS device — the flag doubles as "recap not yet
    /// delivered" for the ended-while-away launch scan.
    private func markDelivered(_ sid: UUID) async {
        guard let uid = myId else { return }
        struct InPlanPatch: Encodable { let in_plan: Bool }
        struct InLivePatch: Encodable { let in_live: Bool }
        if scopeLive {
            _ = try? await supabase.from("session_members")
                .update(InLivePatch(in_live: false))
                .eq("session_id", value: sid.uuidString.lowercased())
                .eq("profile_id", value: uid.uuidString.lowercased())
                .execute()
        } else {
            _ = try? await supabase.from("session_members")
                .update(InPlanPatch(in_plan: false))
                .eq("session_id", value: sid.uuidString.lowercased())
                .eq("profile_id", value: uid.uuidString.lowercased())
                .execute()
        }
    }

    /// Remove MY personal (non-shared) drink rows from a session I'm
    /// walking away from. The rows have just been copied into whichever
    /// store the night continues in — leaving the originals behind would
    /// double-count them on a later rejoin (leave→rejoin used to double
    /// the count every cycle). Shared rounds stay; they belong to the
    /// whole group, not to me.
    func deleteMyPersonalDrinks(in sessionId: UUID) async {
        guard let uid = myId else { return }
        _ = try? await supabase.from("session_drinks")
            .delete()
            .eq("session_id", value: sessionId.uuidString.lowercased())
            .eq("profile_id", value: uid.uuidString.lowercased())
            .eq("shared", value: false)
            .eq("live", value: scopeLive)
            .execute()
    }

    /// A group session is only worth resuming for ~a night. Anything
    /// older is a leftover (host never pressed END, app was killed
    /// mid-switch, etc.) — resurrecting it produces phantom "seshes I
    /// never started" and surprise recaps on launch.
    private func isFresh(_ row: SeshSession) -> Bool {
        Date().timeIntervalSince(row.createdAt) < 24 * 3600
    }

    /// Quietly detach from a session without ending my night or handing
    /// off a recap: flip my `in_<scope>` flag, and if I host it, end it
    /// for this scope too (a hostless group would just linger). Used for
    /// garbage-collecting stale sessions on launch and for abandoning
    /// the old group during a direct group→group switch — neither is an
    /// END, so `captureLiveEnd` is deliberately never called here.
    private func silentlyRelease(_ row: SeshSession) async {
        guard let uid = myId else { return }
        struct InPlanPatch: Encodable { let in_plan: Bool }
        struct InLivePatch: Encodable { let in_live: Bool }
        struct ActivePlanPatch: Encodable { let active_plan: Bool }
        struct ActiveLivePatch: Encodable { let active_live: Bool }
        do {
            if scopeLive {
                _ = try await supabase.from("session_members")
                    .update(InLivePatch(in_live: false))
                    .eq("session_id", value: row.id.uuidString.lowercased())
                    .eq("profile_id", value: uid.uuidString.lowercased())
                    .execute()
                if row.hostId == uid {
                    _ = try await supabase.from("sessions")
                        .update(ActiveLivePatch(active_live: false))
                        .eq("id", value: row.id.uuidString.lowercased())
                        .execute()
                }
            } else {
                _ = try await supabase.from("session_members")
                    .update(InPlanPatch(in_plan: false))
                    .eq("session_id", value: row.id.uuidString.lowercased())
                    .eq("profile_id", value: uid.uuidString.lowercased())
                    .execute()
                if row.hostId == uid {
                    _ = try await supabase.from("sessions")
                        .update(ActivePlanPatch(active_plan: false))
                        .eq("id", value: row.id.uuidString.lowercased())
                        .execute()
                }
            }
        } catch {
            // Best-effort cleanup; a failure just means we try again on
            // the next launch's garbage-collection pass.
        }
    }

    /// Adds a drink to the session. The `live` flag is derived from the
    /// store's scope — plan store stamps `live = false`, live store
    /// stamps `live = true`. Plan and live drinks are mutually exclusive
    /// per row so the two ledgers never bleed into each other even when
    /// both stores happen to track the same underlying session.
    func addDrink(_ option: DrinkOption, shared: Bool = false, consumedAt: Date? = nil) async {
        guard let sid = session?.id, let uid = myId else { return }
        do {
            let inserted: SessionDrink
            if let consumedAt {
                // Carrying a drink across stores (joining a group with a night
                // already underway) — preserve its original time so BAC stays
                // accurate. A normal pour omits created_at and the DB stamps now().
                struct DT: Encodable {
                    let session_id: String
                    let profile_id: String
                    let drink_name: String
                    let volume_ml: Double
                    let abv: Double
                    let shared: Bool
                    let live: Bool
                    let created_at: String
                }
                inserted = try await supabase.from("session_drinks")
                    .insert(DT(
                        session_id: sid.uuidString.lowercased(),
                        profile_id: uid.uuidString.lowercased(),
                        drink_name: option.name,
                        volume_ml: option.volumeML,
                        abv: option.abv,
                        shared: shared,
                        live: scopeLive,
                        created_at: ISO8601DateFormatter().string(from: consumedAt)
                    ))
                    .select().single().execute().value
            } else {
                struct D: Encodable {
                    let session_id: String
                    let profile_id: String
                    let drink_name: String
                    let volume_ml: Double
                    let abv: Double
                    let shared: Bool
                    let live: Bool
                }
                inserted = try await supabase.from("session_drinks")
                    .insert(D(
                        session_id: sid.uuidString.lowercased(),
                        profile_id: uid.uuidString.lowercased(),
                        drink_name: option.name,
                        volume_ml: option.volumeML,
                        abv: option.abv,
                        shared: shared,
                        live: scopeLive
                    ))
                    .select().single().execute().value
            }
            drinks.append(inserted)
        } catch {
            await refresh()
        }
    }

    /// Removes the most recently added matching drink in this store's
    /// ledger. The store's scope decides which ledger we look at — plan
    /// store touches `live == false` rows, live store touches `live ==
    /// true` rows. This keeps the regular and live undo buttons isolated
    /// even when the two stores share a session.
    func removeMyLast(of option: DrinkOption, shared: Bool = false) async {
        guard let uid = myId else { return }
        let candidate: SessionDrink?
        if shared {
            candidate = drinks
                .filter { $0.drinkName == option.name && $0.shared && $0.live == scopeLive }
                .sorted { $0.createdAt > $1.createdAt }
                .first
        } else {
            candidate = drinks
                .filter { $0.profileId == uid && $0.drinkName == option.name && !$0.shared && $0.live == scopeLive }
                .sorted { $0.createdAt > $1.createdAt }
                .first
        }
        guard let target = candidate else { return }
        _ = try? await supabase.from("session_drinks").delete()
            .eq("id", value: target.id.uuidString.lowercased())
            .execute()
        drinks.removeAll { $0.id == target.id }
    }

    private func enter(session: SeshSession) async {
        self.session = session
        // Seed the guest roster from the row we just entered with, so the
        // first frame already shows shared guests instead of waiting for
        // the first poll.
        self.ghosts = session.ghosts
        // Persist so the next launch can restore THIS scope's session
        // independently of the cousin scope.
        persistSessionID(session.id)
        await refresh()
        startPolling()
    }

    /// Patch the current user's entry in `memberProfiles` immediately
    /// without waiting for the next 3-second poll. Called by SessionView
    /// when AuthService publishes a profile edit so the user sees their
    /// new weight/age/sex reflected in the live BAC the moment they
    /// hit Save, not three seconds later.
    func applyMyProfile(_ profile: Profile) {
        guard isActive else { return }
        memberProfiles[profile.id] = profile
    }

    /// Persist the full guest roster to the session row's JSONB column.
    /// Optimistically sets the local copy first so the UI is instant, then
    /// pushes — the next poll reconciles every other device. Last-write-
    /// wins: two people editing guests in the same second can clobber, but
    /// for manually-added guests that's a rare, low-stakes collision.
    func syncGhosts(_ newGhosts: [GhostMember]) async {
        guard let sid = session?.id else { return }
        ghosts = newGhosts
        session?.ghosts = newGhosts
        // Suppress the poll's ghost-overwrite while this write is in
        // flight, otherwise a refresh that lands before the write commits
        // reads the stale server value and wipes the just-added guest.
        ghostWriteInFlight = true
        defer { ghostWriteInFlight = false }
        // Write via a member-authorized RPC, NOT a direct UPDATE — the
        // sessions row's RLS update policy is host-only, so a non-host
        // member's direct update would silently fail and their guest
        // would vanish on the next poll.
        struct Params: Encodable { let p_session_id: String; let p_ghosts: [GhostMember] }
        do {
            _ = try await supabase
                .rpc("set_session_ghosts", params: Params(
                    p_session_id: sid.uuidString.lowercased(),
                    p_ghosts: newGhosts
                ))
                .execute()
        } catch {
            // Non-fatal — the local copy already updated and the next
            // successful edit (or another device's write) re-converges.
        }
    }

    /// Broadcast a group check-in/out — sets the session's shared venue so
    /// every following member adopts it. `nil` = check the group out.
    /// Member-authorized RPC (sessions' RLS update is host-only).
    func setGroupVenue(_ venue: Venue?) async {
        guard let sid = session?.id else { return }
        liveVenue = venue
        session?.liveVenue = venue
        liveVenueWriteInFlight = true
        defer { liveVenueWriteInFlight = false }
        // Explicit encode (not encodeIfPresent) so a checkout sends an
        // actual JSON `null` instead of omitting the param — PostgREST
        // would otherwise reject the call as missing a required argument.
        struct Params: Encodable {
            let p_session_id: String
            let p_venue: Venue?
            enum CodingKeys: String, CodingKey { case p_session_id, p_venue }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(p_session_id, forKey: .p_session_id)
                try c.encode(p_venue, forKey: .p_venue)
            }
        }
        do {
            _ = try await supabase
                .rpc("set_session_live_venue", params: Params(
                    p_session_id: sid.uuidString.lowercased(),
                    p_venue: venue
                ))
                .execute()
        } catch {
            // Non-fatal — local copy updated; the next write re-converges.
        }
        // Record the group's ROUTE server-side (migration 038): whoever
        // checks the group in/out writes it, so every member's group recap
        // can rebuild the night's stops — not just the members whose local
        // journey happened to witness them.
        await recordGroupStop(sessionId: sid, venue: venue)
    }

    /// Mirror my journey's MARKER entries (between-bars, food, puke stops +
    /// pre-game/loose spots) into the shared route while in a live group.
    /// The group recap builds from session_stops, so a marker only I
    /// witnessed still shows up for every member — including members who
    /// joined after it happened. Keyed by the journey entry's own uuid, so
    /// re-syncs are idempotent. Bars aren't synced here (the group
    /// check-in path owns those).
    func syncRouteMarkers(stops allStops: [SeshStop], spots allSpots: [LooseSpot]) async {
        guard scopeLive, let sid = session?.id, let uid = myId else { return }
        // Selection by IDENTITY: only entries stamped with THIS group's id.
        // Timestamps can't tell the group's story apart from a member's
        // parallel personal stops (they overlap in time); the tag can.
        let stops = allStops.filter { $0.sessionId == sid }
        let spots = allSpots.filter { $0.sessionId == sid }
        let iso = ISO8601DateFormatter()
        struct Row: Encodable {
            let id: String
            let session_id: String
            let name: String
            let lat: Double?
            let lon: Double?
            let kind: String
            let arrived_at: String
            let departed_at: String?
            let profile_id: String
            // Explicit encode (not encodeIfPresent): PostgREST rejects a
            // bulk upsert whose rows have MISMATCHED key sets — one open
            // stop (nil departure) next to a closed one silently failed
            // the whole batch, which is why markers went missing.
            enum CodingKeys: String, CodingKey {
                case id, session_id, name, lat, lon, kind, arrived_at, departed_at, profile_id
            }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(id, forKey: .id)
                try c.encode(session_id, forKey: .session_id)
                try c.encode(name, forKey: .name)
                try c.encode(lat, forKey: .lat)
                try c.encode(lon, forKey: .lon)
                try c.encode(kind, forKey: .kind)
                try c.encode(arrived_at, forKey: .arrived_at)
                try c.encode(departed_at, forKey: .departed_at)
                try c.encode(profile_id, forKey: .profile_id)
            }
        }
        var rows: [Row] = stops.filter { $0.kind != .bar }.map { s in
            Row(
                id: s.id.uuidString.lowercased(),
                session_id: sid.uuidString.lowercased(),
                name: s.name,
                lat: s.lat, lon: s.lon,
                kind: s.kind.rawValue,
                arrived_at: iso.string(from: s.arrivedAt),
                departed_at: s.departedAt.map { iso.string(from: $0) },
                profile_id: uid.uuidString.lowercased()
            )
        }
        rows += spots.map { sp in
            Row(
                id: sp.id.uuidString.lowercased(),
                session_id: sid.uuidString.lowercased(),
                name: sp.name ?? "Pre-game",
                lat: sp.lat, lon: sp.lon,
                kind: "preGame",
                arrived_at: iso.string(from: sp.at),
                departed_at: nil,
                profile_id: uid.uuidString.lowercased()
            )
        }
        guard !rows.isEmpty else { return }
        _ = try? await supabase.from("session_stops")
            .upsert(rows, onConflict: "id")
            .execute()
    }

    /// Close the open route entry and, when checking IN somewhere, open a
    /// new one. Best-effort — the recap falls back to the local journey.
    private func recordGroupStop(sessionId: UUID, venue: Venue?) async {
        let sid = sessionId.uuidString.lowercased()
        let iso = ISO8601DateFormatter()
        struct Close: Encodable { let departed_at: String }
        _ = try? await supabase.from("session_stops")
            .update(Close(departed_at: iso.string(from: Date())))
            .eq("session_id", value: sid)
            .eq("kind", value: "bar")   // markers are instants — closing them faked windows
            .filter("departed_at", operator: "is", value: "null")
            .execute()
        guard let venue else { return }
        struct Open: Encodable {
            let session_id: String
            let name: String
            let lat: Double?
            let lon: Double?
        }
        _ = try? await supabase.from("session_stops")
            .insert(Open(session_id: sid, name: venue.name, lat: venue.lat, lon: venue.lon))
            .execute()
    }

    /// Broadcast a group pre-game/between location (or nil to clear) so
    /// following members adopt it. Mirrors `setGroupVenue`.
    func setGroupLooseSpot(_ spot: LooseSpot?) async {
        guard let sid = session?.id else { return }
        liveLooseSpot = spot
        session?.liveLooseSpot = spot
        liveLooseSpotWriteInFlight = true
        defer { liveLooseSpotWriteInFlight = false }
        struct Params: Encodable {
            let p_session_id: String
            let p_spot: LooseSpot?
            enum CodingKeys: String, CodingKey { case p_session_id, p_spot }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(p_session_id, forKey: .p_session_id)
                try c.encode(p_spot, forKey: .p_spot)
            }
        }
        do {
            _ = try await supabase
                .rpc("set_session_live_loose_spot", params: Params(
                    p_session_id: sid.uuidString.lowercased(), p_spot: spot
                ))
                .execute()
        } catch {
            // Non-fatal — local copy updated; next write re-converges.
        }
    }

    private func clearLocal() {
        stopPolling()
        session = nil; members = []; memberProfiles = [:]; drinks = []; ghosts = []
        liveVenue = nil; liveLooseSpot = nil; followingGroupVenue = true
        routeStops = []
        // Note: endedGroupLeaderboard/endedLiveEvents are intentionally NOT
        // cleared here — clearLocal runs right after capture on group end,
        // and SessionView consumes them on the next tick.
        persistSessionID(nil)
    }

    func refresh() async {
        guard let sid = session?.id else { return }
        do {
            // Per-mode roster: only fetch members whose `in_<scope>`
            // flag is still TRUE. Anyone who left this mode (but might
            // still be in the other) gets filtered out server-side, so
            // they correctly disappear from this scope's UI without
            // affecting the cousin scope's roster.
            let ms: [SessionMember] = try await supabase
                .from("session_members")
                .select()
                .eq("session_id", value: sid.uuidString.lowercased())
                .eq(inColumnForScope, value: true)
                .execute()
                .value
            let ds: [SessionDrink] = try await supabase
                .from("session_drinks")
                .select()
                .eq("session_id", value: sid.uuidString.lowercased())
                .order("created_at", ascending: true)
                .execute()
                .value

            // Re-fetch every member's profile on each poll, not just new
            // ones. We used to only fetch on first sight, which left the
            // cache stale forever — so when the user (or any group
            // member) updated their weight/sex/age in profile settings,
            // the live Widmark formula kept reading the old values and
            // BAC didn't budge. Refreshing the lot keeps every member's
            // BAC in sync with whatever they last saved.
            let allIds = Set(ms.map(\.profileId))
            if !allIds.isEmpty {
                let ids = allIds.map { $0.uuidString.lowercased() }
                let ps: [Profile] = try await supabase
                    .from("profiles")
                    .select()
                    .in("id", values: ids)
                    .execute()
                    .value
                // Replace in-place so a removed-then-rejoined profile
                // doesn't keep its prior values.
                for p in ps { memberProfiles[p.id] = p }
            }

            // Has the host ended THIS mode of the session? Per-mode
            // model: we only care about `active_<scope>`, not the
            // legacy global `active` (which now stays TRUE forever)
            // and not the OTHER mode's flag (cousin scope handles that
            // independently). The legacy `active = false` check stays
            // as a fallback for environments that haven't run
            // migration 007 yet — there `activePlan`/`activeLive`
            // default to TRUE on decode and we'd otherwise miss a
            // host-end that flipped only `active`.
            if let row: SeshSession = try? await supabase
                .from("sessions")
                .select()
                .eq("id", value: sid.uuidString.lowercased())
                .single()
                .execute()
                .value {
                let endedForMyMode = scopeLive ? !row.activeLive : !row.activePlan
                if endedForMyMode || row.active == false {
                    // Capture my night for the auto-recap from the freshly
                    // fetched data (self.drinks/members aren't assigned on
                    // a launch poll yet); row.ghosts is the live guest set.
                    // Capture → clearLocal atomically (see end()) …
                    captureLiveEnd(drinks: ds, members: ms, ghosts: row.ghosts)
                    clearLocal()
                    // … then release my flag so the next launch's
                    // ended-while-away scan doesn't deliver it AGAIN.
                    await markDelivered(sid)
                    return
                }
                // Pull the shared guest roster from the session row so
                // every device converges on the same set + their drinks.
                // Skip while our own write is in flight, so a poll that
                // races the write doesn't wipe a just-added guest.
                if !ghostWriteInFlight, ghosts != row.ghosts {
                    ghosts = row.ghosts
                    session?.ghosts = row.ghosts
                }
                // Pull the group's shared venue so following members adopt
                // it. Skip while our own write is mid-flight.
                if !liveVenueWriteInFlight, liveVenue != row.liveVenue {
                    liveVenue = row.liveVenue
                    session?.liveVenue = row.liveVenue
                }
                if !liveLooseSpotWriteInFlight, liveLooseSpot != row.liveLooseSpot {
                    liveLooseSpot = row.liveLooseSpot
                    session?.liveLooseSpot = row.liveLooseSpot
                }
            }

            // Did I get kicked out of THIS mode (e.g. left from another
            // device, or — though we don't expose this yet — a host
            // removed me)? Detect via my own membership row's
            // `in_<scope>` flag. We already pulled the filtered list
            // above, so a missing self-row in `ms` means I'm out.
            if let uid = myId, !ms.contains(where: { $0.profileId == uid }) {
                captureLiveEnd(drinks: ds, members: ms, ghosts: ghosts)
                clearLocal()
                return
            }

            members = ms.sorted { $0.joinedAt < $1.joinedAt }
            drinks = ds

            // Pull the shared route so every member's journey converges on
            // the group's stops (live scope only — plan has no route).
            if scopeLive {
                let route: [RouteStopRow] = (try? await supabase
                    .from("session_stops")
                    .select()
                    .eq("session_id", value: sid.uuidString.lowercased())
                    .order("arrived_at", ascending: true)
                    .execute()
                    .value) ?? []
                if route != routeStops { routeStops = route }
            }
        } catch {
            // swallow; try again next tick
        }
    }

    private func startPolling() {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await self?.refresh()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    deinit { pollTask?.cancel() }

    static func generateCode(length: Int = 6) -> String {
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<length).map { _ in chars.randomElement()! })
    }

    static func bac(grams: Double, profile: Profile, hoursElapsed: Double) -> Double {
        let bodyGrams = profile.weightKg * 1000
        let raw = (grams / (bodyGrams * profile.sex.r)) * 100
        return max(0, raw - 0.015 * hoursElapsed)
    }
}

