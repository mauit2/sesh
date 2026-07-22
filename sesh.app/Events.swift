// Events — plan-ahead parties & trips: models, the provisioning
// calculator (EventProvisioning), EventsService, and all the event UI
// (composer, detail sheet with supply calculator + night report, cards,
// location picker). Extracted from content_view.swift; migrations 042–050.
// Pure relocation.

import SwiftUI
import Combine
import PhotosUI
import MapKit
import CoreLocation
import Foundation
import Supabase

// MARK: - Events (plan-ahead parties & trips, migration 042)

/// What kind of thing is being planned — drives the glyph and whether the
/// nights stepper shows (trips span several nights, the rest default to 1).
enum EventKind: String, CaseIterable, Identifiable {
    case party, trip, pregame, other
    var id: String { rawValue }

    var label: String {
        switch self {
        case .party:   return "Party"
        case .trip:    return "Trip"
        case .pregame: return "Pregame"
        case .other:   return "Other"
        }
    }

    var icon: String {
        switch self {
        case .party:   return "party.popper.fill"
        case .trip:    return "suitcase.fill"
        case .pregame: return "flame.fill"
        case .other:   return "calendar"
        }
    }
}

struct SeshEvent: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let hostId: UUID
    var title: String
    var kind: String
    var startsAt: Date
    var durationHours: Double
    var nights: Int
    var targetBAC: Double
    /// Shopping list keyed by SupplyContainer raw values.
    var supplies: [String: Int]
    /// Off-app guests — same GhostMember shape the session ghosts use.
    var ghosts: [GhostMember]
    /// 'calc' = host-built calculated list · 'byob' = everyone brings.
    var planMode: String
    /// 'host' = only the host edits the plan · 'everyone' = any going member.
    var editMode: String
    /// BYOB contributions: profile uuid string → {container: count}.
    var byo: [String: [String: Int]]
    /// Host-set cover photo (event-covers bucket).
    var coverURL: String?
    /// Arm the server to start a live group sesh at starts_at.
    var autoLive: Bool
    /// The linked live session once the event has gone live.
    var liveSessionId: UUID?
    var liveStartedAt: Date?
    var liveEndedAt: Date?
    /// Event location: 'venue' = the group auto-checks-in when live
    /// starts; 'spot' = becomes the group pre-game location. The raw
    /// payload jsonb stays server-side (copied verbatim onto the session);
    /// the client only needs kind + display name.
    var locationKind: String?
    var locationName: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case hostId = "host_id"
        case title, kind
        case startsAt = "starts_at"
        case durationHours = "duration_hours"
        case nights
        case targetBAC = "target_bac"
        case supplies, ghosts
        case planMode = "plan_mode"
        case editMode = "edit_mode"
        case byo
        case coverURL = "cover_url"
        case autoLive = "auto_live"
        case liveSessionId = "live_session_id"
        case liveStartedAt = "live_started_at"
        case liveEndedAt = "live_ended_at"
        case locationKind = "location_kind"
        case locationName = "location_name"
        case createdAt = "created_at"
    }

    var kindValue: EventKind { EventKind(rawValue: kind) ?? .other }
    var isBYOB: Bool { planMode == "byob" }
    /// The event's linked sesh is running right now.
    var isLiveNow: Bool { liveSessionId != nil && liveEndedAt == nil && liveStartedAt != nil }

    /// Scheduled end: last day's drinking window closes.
    var scheduledEnd: Date {
        startsAt
            .addingTimeInterval(Double(max(nights, 1) - 1) * 86_400)
            .addingTimeInterval(durationHours * 3_600)
    }

    /// Done and dusted — its night ended (or its window passed without
    /// ever going live). These move to the PAST EVENTS shelf.
    var isPast: Bool {
        if isLiveNow { return false }
        if liveEndedAt != nil { return true }
        return scheduledEnd < Date()
    }

    /// Everyone's contributions pooled into one shopping list.
    var pooledBYO: [String: Int] {
        var out: [String: Int] = [:]
        for slice in byo.values {
            for (k, v) in slice { out[k, default: 0] += v }
        }
        return out
    }
}

struct EventMember: Codable, Equatable, Hashable {
    let eventId: UUID
    let profileId: UUID
    var status: String            // "pending" | "going" | "declined"
    var invitedBy: UUID?
    var respondedAt: Date?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case profileId = "profile_id"
        case status
        case invitedBy = "invited_by"
        case respondedAt = "responded_at"
        case createdAt = "created_at"
    }
}

/// Real, purchasable containers for the provisioning calculator — the
/// shopping list speaks in bottles and cans, not serving sizes.
enum SupplyContainer: String, CaseIterable, Codable, Identifiable {
    case beerCan, ciderCan, wineBottle, bubblyBottle, vodkaBottle, ginBottle, whiskyBottle
    var id: String { rawValue }

    var label: String {
        switch self {
        case .beerCan:      return "Beer"
        case .ciderCan:     return "Cider"
        case .wineBottle:   return "Wine"
        case .bubblyBottle: return "Bubbles"
        case .vodkaBottle:  return "Vodka"
        case .ginBottle:    return "Gin"
        case .whiskyBottle: return "Whisky"
        }
    }

    /// "33 cl can" / "75 cl bottle" — the unit the count refers to.
    var unit: String {
        switch self {
        case .beerCan, .ciderCan:                       return "33 cl can"
        case .wineBottle, .bubblyBottle:                return "75 cl bottle"
        case .vodkaBottle, .ginBottle, .whiskyBottle:   return "70 cl bottle"
        }
    }

    var volumeML: Double {
        switch self {
        case .beerCan, .ciderCan:                     return 330
        case .wineBottle, .bubblyBottle:              return 750
        case .vodkaBottle, .ginBottle, .whiskyBottle: return 700
        }
    }

    var abv: Double {
        switch self {
        case .beerCan:      return 0.05
        case .ciderCan:     return 0.045
        case .wineBottle:   return 0.12
        case .bubblyBottle: return 0.12
        case .vodkaBottle, .ginBottle, .whiskyBottle: return 0.40
        }
    }

    /// Grams of pure alcohol per container — same formula as DrinkOption.
    var grams: Double { volumeML * abv * 0.789 }

    /// Category mapping so the drink glyphs render in the shopping list.
    var category: DrinkCategory {
        switch self {
        case .beerCan:      return .beer
        case .ciderCan:     return .cider
        case .wineBottle:   return .wine
        case .bubblyBottle: return .sparkling
        case .vodkaBottle:  return .vodka
        case .ginBottle:    return .gin
        case .whiskyBottle: return .whisky
        }
    }
}

/// Pure Widmark provisioning math. Model: everyone drinks steadily over
/// the event's window (H hours) and lands on the target BAC at the end,
/// so per person `grams = (target + 0.015·H) · weightKg·1000·r / 100`.
/// Everything is linear in the target, so the inverse (counts → level)
/// is exact — no iteration.
enum EventProvisioning {
    static let decayPerHour = 0.015
    static let gramsPerStandardDrink = 12.0

    /// One attendee's contribution to the shared denominator:
    /// weightKg·1000·r / 100.
    static func spread(weightKg: Double, sex: Sex) -> Double {
        weightKg * 1000 * sex.r / 100
    }

    /// Total grams of alcohol for the whole crew to hit `target` after
    /// `hours` of steady drinking, per night, times `nights`.
    static func gramsNeeded(target: Double, hours: Double, nights: Int, totalSpread: Double) -> Double {
        max(0, (target + decayPerHour * hours) * totalSpread * Double(max(nights, 1)))
    }

    /// Inverse: the level everyone lands at if the crew shares
    /// `totalGrams` evenly (weight-proportionally) per night.
    static func resultingBAC(totalGrams: Double, hours: Double, nights: Int, totalSpread: Double) -> Double {
        guard totalSpread > 0 else { return 0 }
        let perNight = totalGrams / Double(max(nights, 1))
        return max(0, perNight / totalSpread - decayPerHour * hours)
    }

    /// Split the needed grams across the chosen container types WITHOUT
    /// overshooting the target level. Naive per-type ceil rounding blows
    /// straight past the target for small crews (one 70cl vodka bottle is
    /// ~221 g — almost a whole 3-person night by itself), so: round each
    /// type's even share to the NEAREST whole container (big bottles can
    /// round to zero), then top the total up or trim it down with the
    /// smallest-container type until the pool sits within half a unit of
    /// the need.
    static func suggestion(gramsNeeded: Double, types: [SupplyContainer]) -> [String: Int] {
        guard !types.isEmpty, gramsNeeded > 0 else { return [:] }
        let share = gramsNeeded / Double(types.count)
        var counts: [SupplyContainer: Int] = [:]
        for t in types {
            counts[t] = max(0, Int((share / t.grams).rounded()))
        }
        guard let finest = types.min(by: { $0.grams < $1.grams }) else { return [:] }

        var total = counts.reduce(0.0) { $0 + $1.key.grams * Double($1.value) }
        while total < gramsNeeded - finest.grams / 2 {
            counts[finest, default: 0] += 1
            total += finest.grams
        }
        while let c = counts[finest], c > 0, total > gramsNeeded + finest.grams / 2 {
            counts[finest] = c - 1
            total -= finest.grams
        }
        // Degenerate case (only huge bottles picked, tiny need): make sure
        // the list isn't empty.
        if counts.values.allSatisfy({ $0 == 0 }) {
            counts[finest] = max(1, Int((gramsNeeded / finest.grams).rounded()))
        }

        var out: [String: Int] = [:]
        for (t, c) in counts { out[t.rawValue] = c }
        return out
    }

    /// Total grams represented by a shopping list.
    static func grams(of supplies: [String: Int]) -> Double {
        supplies.reduce(0) { acc, entry in
            guard let c = SupplyContainer(rawValue: entry.key) else { return acc }
            return acc + c.grams * Double(max(entry.value, 0))
        }
    }

    /// Reserved supplies key carrying the driver fingerprint (ignored by
    /// grams(of:) and the UI since it's not a SupplyContainer raw value).
    static let fingerprintKey = "_fp"

    /// Deterministic fingerprint of everything the suggestion depends on.
    /// Stored inside the supplies dict; when the crew/target/window drift
    /// away from it, editors' devices recalculate automatically — while
    /// manual count edits (same drivers) are left alone.
    static func fingerprint(target: Double, hours: Double, nights: Int, totalSpread: Double, types: [SupplyContainer]) -> Int {
        let s = "\(Int((target * 1000).rounded()))|\(Int((hours * 10).rounded()))|\(nights)|\(Int(totalSpread.rounded()))|\(types.map(\.rawValue).sorted().joined(separator: ","))"
        // djb2 — stable across launches/devices (unlike Hasher).
        var h = 5381
        for b in s.utf8 { h = (h &* 33) &+ Int(b) }
        return h
    }

    /// Suggestion with the fingerprint baked in.
    static func fingerprintedSuggestion(target: Double, hours: Double, nights: Int, totalSpread: Double, types: [SupplyContainer]) -> [String: Int] {
        let need = gramsNeeded(target: target, hours: hours, nights: nights, totalSpread: totalSpread)
        var out = suggestion(gramsNeeded: need, types: types)
        out[fingerprintKey] = fingerprint(target: target, hours: hours, nights: nights, totalSpread: totalSpread, types: types)
        return out
    }

    /// Chronological peak BAC from timestamped gram events — same walk
    /// as the live Widmark simulation (accumulate per drink, decay
    /// between drinks, track the max).
    static func peakBAC(events: [(at: Date, grams: Double)], weightKg: Double, sex: Sex) -> Double {
        guard !events.isEmpty, weightKg > 0 else { return 0 }
        let body = weightKg * 1000 * sex.r
        var bac = 0.0
        var peak = 0.0
        var last = events.map(\.at).min() ?? Date()
        for e in events.sorted(by: { $0.at < $1.at }) {
            bac = max(0, bac - decayPerHour * e.at.timeIntervalSince(last) / 3600)
            bac += e.grams / body * 100
            peak = max(peak, bac)
            last = e.at
        }
        return peak
    }
}

/// Fetch + mutate events. Same shape as InvitesService: a slow polling
/// loop (events change rarely), RLS-scoped selects, all writes through
/// the SECURITY DEFINER RPCs from migration 042.
@MainActor
final class EventsService: ObservableObject {
    @Published private(set) var events: [SeshEvent] = []
    @Published private(set) var membersByEvent: [UUID: [EventMember]] = [:]
    @Published private(set) var profilesById: [UUID: Profile] = [:]
    @Published var error: String?

    private var pollTask: Task<Void, Never>?

    /// Events awaiting my RSVP — drives the PLAN tab badge. Past events
    /// don't nag.
    func pendingCount(for uid: UUID) -> Int {
        events.filter { ev in
            !ev.isPast && (membersByEvent[ev.id]?.contains {
                $0.profileId == uid && $0.status == "pending"
            } ?? false)
        }.count
    }

    func myStatus(in event: SeshEvent, uid: UUID) -> String? {
        membersByEvent[event.id]?.first { $0.profileId == uid }?.status
    }

    func goingProfiles(for event: SeshEvent) -> [Profile] {
        (membersByEvent[event.id] ?? [])
            .filter { $0.status == "going" }
            .compactMap { profilesById[$0.profileId] }
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                // 45s — event invites also push; no need to poll every 15s.
                try? await Task.sleep(nanoseconds: 45_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        events = []
        membersByEvent = [:]
    }

    func refresh() async {
        guard supabase.auth.currentUser != nil else { return }
        do {
            // RLS scopes this to events I host or am invited to. Reach
            // back 90 days so finished events live on in PAST EVENTS.
            let cutoff = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-90 * 86_400))
            let evs: [SeshEvent] = try await supabase
                .from("events")
                .select()
                .gte("starts_at", value: cutoff)
                .order("starts_at", ascending: true)
                .execute()
                .value
            self.events = evs

            let ids = evs.map { $0.id.uuidString.lowercased() }
            guard !ids.isEmpty else {
                membersByEvent = [:]
                return
            }
            let members: [EventMember] = try await supabase
                .from("event_members")
                .select()
                .in("event_id", values: ids)
                .execute()
                .value
            membersByEvent = Dictionary(grouping: members, by: \.eventId)

            // Hydrate any attendee profiles we haven't cached yet — the
            // calculator needs weight/sex, the roster needs name/avatar.
            let missing = Set(members.map(\.profileId)).subtracting(profilesById.keys)
            if !missing.isEmpty {
                let ps: [Profile] = try await supabase
                    .from("profiles")
                    .select()
                    .in("id", values: missing.map { $0.uuidString.lowercased() })
                    .execute()
                    .value
                for p in ps { profilesById[p.id] = p }
            }

            if let uid = supabase.auth.currentUser?.id {
                await autoRecalcStaleLists(uid: uid)
            }

            // An armed event whose start time has passed but whose sesh
            // hasn't spun up yet: kick the (idempotent) server lifecycle
            // now instead of waiting for the next cron tick, then reload
            // so the LIVE banner and auto-join land immediately.
            let due = evs.contains {
                $0.autoLive && $0.liveSessionId == nil && $0.startsAt <= Date()
            }
            if due {
                _ = try? await supabase.rpc("run_event_live_lifecycle").execute()
                let fresh: [SeshEvent] = try await supabase
                    .from("events")
                    .select()
                    .gte("starts_at", value: cutoff)
                    .order("starts_at", ascending: true)
                    .execute()
                    .value
                self.events = fresh
            }
        } catch {
            // Transient blip — next poll recovers; stale list is fine.
        }
    }

    /// Create → returns the new event id (already refreshed) or nil.
    func create(
        title: String, kind: EventKind, startsAt: Date,
        durationHours: Double, nights: Int, targetBAC: Double,
        autoLive: Bool = false
    ) async -> UUID? {
        struct P: Encodable {
            let p_title: String
            let p_kind: String
            let p_starts_at: String
            let p_duration_hours: Double
            let p_nights: Int
            let p_target_bac: Double
            let p_auto_live: Bool
        }
        do {
            let id: UUID = try await supabase.rpc("create_event", params: P(
                p_title: title,
                p_kind: kind.rawValue,
                p_starts_at: ISO8601DateFormatter().string(from: startsAt),
                p_duration_hours: durationHours,
                p_nights: nights,
                p_target_bac: targetBAC,
                p_auto_live: autoLive
            )).execute().value
            await refresh()
            return id
        } catch {
            self.error = "Couldn't create the event."
            return nil
        }
    }

    /// Host-only: set the event's location as a real venue — the group
    /// gets checked in there automatically when the live sesh starts.
    func setLocation(eventId: UUID, venue: Venue) async {
        patch(eventId) { $0.locationKind = "venue"; $0.locationName = venue.name }
        struct P: Encodable {
            let p_event: String
            let p_kind: String
            let p_name: String
            let p_payload: Venue
        }
        _ = try? await supabase.rpc("set_event_location", params: P(
            p_event: eventId.uuidString.lowercased(),
            p_kind: "venue",
            p_name: venue.name,
            p_payload: venue
        )).execute()
    }

    /// Host-only: set the event's location as a free spot/address — it
    /// becomes the group's pre-game location when the live sesh starts.
    func setLocation(eventId: UUID, spot: LooseSpot) async {
        patch(eventId) { $0.locationKind = "spot"; $0.locationName = spot.name }
        struct P: Encodable {
            let p_event: String
            let p_kind: String
            let p_name: String
            let p_payload: LooseSpot
        }
        _ = try? await supabase.rpc("set_event_location", params: P(
            p_event: eventId.uuidString.lowercased(),
            p_kind: "spot",
            p_name: spot.name ?? "Pre-game",
            p_payload: spot
        )).execute()
    }

    func clearLocation(eventId: UUID) async {
        patch(eventId) { $0.locationKind = nil; $0.locationName = nil }
        struct P: Encodable {
            let p_event: String
            let p_kind: String?
            let p_name: String?
            let p_payload: String?
        }
        _ = try? await supabase.rpc("set_event_location", params: P(
            p_event: eventId.uuidString.lowercased(),
            p_kind: nil, p_name: nil, p_payload: nil
        )).execute()
    }

    /// Host-only: arm/disarm the automatic live start.
    func setAutoLive(eventId: UUID, _ on: Bool) async {
        patch(eventId) { $0.autoLive = on }
        struct P: Encodable { let p_event: String; let p_on: Bool }
        _ = try? await supabase.rpc("set_event_auto_live", params: P(
            p_event: eventId.uuidString.lowercased(),
            p_on: on
        )).execute()
    }

    /// Host-only: upload a cover photo (event-covers bucket, upsert) and
    /// record its public URL on the event. Cache-busted with a version
    /// query so AsyncImage picks up replacements.
    func uploadCover(eventId: UUID, jpeg: Data) async {
        let path = "\(eventId.uuidString.lowercased())/cover.jpg"
        do {
            try await StorageUploader.uploadImage(
                bucket: "event-covers", path: path, data: jpeg, upsert: true)
            let base = try supabase.storage.from("event-covers").getPublicURL(path: path)
            let url = "\(base.absoluteString)?v=\(Int(Date().timeIntervalSince1970))"
            patch(eventId) { $0.coverURL = url }
            struct P: Encodable { let p_event: String; let p_url: String }
            _ = try? await supabase.rpc("set_event_cover", params: P(
                p_event: eventId.uuidString.lowercased(),
                p_url: url
            )).execute()
        } catch {
            self.error = "Couldn't upload the photo."
        }
    }

    /// Σ weight·r/100 over an event's going members + ghosts.
    func totalSpread(for event: SeshEvent) -> Double {
        let going = (membersByEvent[event.id] ?? [])
            .filter { $0.status == "going" }
            .compactMap { profilesById[$0.profileId] }
        let p = going.reduce(0.0) { $0 + EventProvisioning.spread(weightKg: $1.weightKg, sex: $1.sex) }
        let g = event.ghosts.reduce(0.0) { $0 + EventProvisioning.spread(weightKg: $1.weightKg, sex: $1.sex) }
        return p + g
    }

    /// Auto-recalculate calculated lists whose drivers (crew, target,
    /// window, container types) changed since the list was built. The
    /// recalculation is deterministic, so ANY going member's device may
    /// perform it (through its own permissive RPC) — otherwise a stale
    /// one-person list sat frozen whenever the host's phone was closed.
    /// Manual count edits keep the stored fingerprint, so they're never
    /// clobbered.
    private func autoRecalcStaleLists(uid: UUID) async {
        for ev in events {
            guard !ev.isBYOB, !ev.isPast else { continue }
            let mine = membersByEvent[ev.id]?.first { $0.profileId == uid }
            guard ev.hostId == uid || mine?.status == "going" else { continue }

            let spread = totalSpread(for: ev)
            guard spread > 0 else { continue }
            // An empty list initializes itself with the default container
            // mix the moment there's a crew — nobody should have to press
            // "calculate" for the plan to exist, and every crew change
            // (RSVP, manual guest) re-derives it from the fingerprint.
            let types: [SupplyContainer] = ev.supplies.isEmpty
                ? [.beerCan, .wineBottle, .vodkaBottle]
                : SupplyContainer.allCases.filter { ev.supplies.keys.contains($0.rawValue) }
            guard !types.isEmpty else { continue }

            let fp = EventProvisioning.fingerprint(
                target: ev.targetBAC, hours: ev.durationHours,
                nights: ev.nights, totalSpread: spread, types: types
            )
            if ev.supplies[EventProvisioning.fingerprintKey] != fp {
                let fresh = EventProvisioning.fingerprintedSuggestion(
                    target: ev.targetBAC, hours: ev.durationHours,
                    nights: ev.nights, totalSpread: spread, types: types
                )
                patch(ev.id) { $0.supplies = fresh }
                struct P: Encodable { let p_event: String; let p_supplies: [String: Int] }
                _ = try? await supabase.rpc("auto_recalc_event_supplies", params: P(
                    p_event: ev.id.uuidString.lowercased(),
                    p_supplies: fresh
                )).execute()
            }
        }
    }

    func invite(eventId: UUID, recipientIds: [UUID]) async {
        guard !recipientIds.isEmpty else { return }
        struct P: Encodable { let p_event: String; let p_recipients: [String] }
        do {
            _ = try await supabase.rpc("invite_to_event", params: P(
                p_event: eventId.uuidString.lowercased(),
                p_recipients: recipientIds.map { $0.uuidString.lowercased() }
            )).execute()
            await refresh()
        } catch {
            self.error = "Couldn't send invites."
        }
    }

    func respond(eventId: UUID, going: Bool) async {
        struct P: Encodable { let p_event: String; let p_status: String }
        do {
            _ = try await supabase.rpc("respond_to_event", params: P(
                p_event: eventId.uuidString.lowercased(),
                p_status: going ? "going" : "declined"
            )).execute()
            await refresh()
        } catch {
            self.error = "Couldn't save your RSVP."
        }
    }

    func leave(eventId: UUID) async {
        struct P: Encodable { let p_event: String }
        _ = try? await supabase.rpc("leave_event", params: P(
            p_event: eventId.uuidString.lowercased()
        )).execute()
        await refresh()
    }

    func cancel(eventId: UUID) async {
        struct P: Encodable { let p_event: String }
        _ = try? await supabase.rpc("cancel_event", params: P(
            p_event: eventId.uuidString.lowercased()
        )).execute()
        await refresh()
    }

    /// Host-only writes. Optimistic local patch first so steppers feel
    /// instant; the poll self-heals if the server rejects.
    func setSupplies(eventId: UUID, _ supplies: [String: Int]) async {
        patch(eventId) { $0.supplies = supplies }
        struct P: Encodable { let p_event: String; let p_supplies: [String: Int] }
        _ = try? await supabase.rpc("set_event_supplies", params: P(
            p_event: eventId.uuidString.lowercased(),
            p_supplies: supplies
        )).execute()
    }

    func updatePlan(eventId: UUID, targetBAC: Double? = nil, durationHours: Double? = nil, nights: Int? = nil) async {
        patch(eventId) { ev in
            if let targetBAC { ev.targetBAC = targetBAC }
            if let durationHours { ev.durationHours = durationHours }
            if let nights { ev.nights = nights }
        }
        struct P: Encodable {
            let p_event: String
            let p_target_bac: Double?
            let p_duration_hours: Double?
            let p_nights: Int?
        }
        _ = try? await supabase.rpc("update_event_plan", params: P(
            p_event: eventId.uuidString.lowercased(),
            p_target_bac: targetBAC,
            p_duration_hours: durationHours,
            p_nights: nights
        )).execute()
    }

    func setGhosts(eventId: UUID, _ ghosts: [GhostMember]) async {
        patch(eventId) { $0.ghosts = ghosts }
        struct P: Encodable { let p_event: String; let p_ghosts: [GhostMember] }
        _ = try? await supabase.rpc("set_event_ghosts", params: P(
            p_event: eventId.uuidString.lowercased(),
            p_ghosts: ghosts
        )).execute()
        // A guest changes the crew's spread — recalc the shopping list
        // right away instead of waiting for the next poll.
        await refresh()
    }

    /// Host-only: flip planning mode (calc/byob) or edit permission.
    func setModes(eventId: UUID, planMode: String? = nil, editMode: String? = nil) async {
        patch(eventId) { ev in
            if let planMode { ev.planMode = planMode }
            if let editMode { ev.editMode = editMode }
        }
        struct P: Encodable { let p_event: String; let p_plan_mode: String?; let p_edit_mode: String? }
        _ = try? await supabase.rpc("set_event_modes", params: P(
            p_event: eventId.uuidString.lowercased(),
            p_plan_mode: planMode,
            p_edit_mode: editMode
        )).execute()
    }

    /// Write MY bring-list slice (BYOB mode).
    func setMyBYO(eventId: UUID, uid: UUID, _ items: [String: Int]) async {
        patch(eventId) { $0.byo[uid.uuidString.lowercased()] = items }
        struct P: Encodable { let p_event: String; let p_items: [String: Int] }
        _ = try? await supabase.rpc("set_event_byo", params: P(
            p_event: eventId.uuidString.lowercased(),
            p_items: items
        )).execute()
    }

    private func patch(_ id: UUID, _ mutate: (inout SeshEvent) -> Void) {
        guard let idx = events.firstIndex(where: { $0.id == id }) else { return }
        var ev = events[idx]
        mutate(&ev)
        events[idx] = ev
    }
}

@MainActor
final class InvitesService: ObservableObject {
    /// Pending invites for the signed-in user, newest first. Drives the
    /// banner pinned at the top of SessionView and the inbox sheet.
    @Published private(set) var pending: [Invite] = []
    /// Sender profiles, keyed by sender_id, populated alongside `pending`
    /// so the banner / sheet can render avatar + name without a second
    /// round trip per row.
    @Published private(set) var senderProfiles: [UUID: Profile] = [:]
    /// Surfaced in the sheet when an accept / decline fails; nil otherwise.
    @Published var error: String?

    /// Invite ids whose floating banner the user swiped away this session.
    /// The invite stays `pending` (still in the inbox / bell badge) — only
    /// the attention-grabbing banner is suppressed. Cleared naturally when
    /// the invite leaves `pending` (accepted / declined / withdrawn), and a
    /// brand-new invite isn't in this set so its banner still drops in.
    @Published private(set) var snoozedBannerIds: Set<UUID> = []

    /// Pending invites minus the ones whose banner was swiped away. Drives
    /// the floating banner; the bell badge keeps using `pending` so a
    /// snoozed invite is still findable.
    var bannerInvites: [Invite] {
        pending.filter { !snoozedBannerIds.contains($0.id) }
    }

    /// Swipe-to-dismiss: snooze the banner for everything currently shown.
    /// Idempotent and instant — the invites remain in the inbox.
    func snoozeBanner() {
        snoozedBannerIds.formUnion(pending.map(\.id))
    }

    private var pollTask: Task<Void, Never>?

    /// Start the polling loop. Idempotent — calling twice is a no-op.
    /// RootView calls this once auth lands, and stops it on sign-out.
    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                // 30s — sesh invites also push; 7s was needlessly aggressive.
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        pending = []
        senderProfiles = [:]
    }

    /// Single fetch + sender-profile hydration. Public so the UI can poke
    /// it after an accept / decline to refresh without waiting up to 7 s.
    func refresh() async {
        guard let uid = supabase.auth.currentUser?.id else { return }
        do {
            // Explicit column list (instead of `*`) so a stale PostgREST
            // schema cache can't silently drop the `mode` field on us —
            // a missing mode would default to "plan" in the decoder and
            // route live invites to plan mode of the same session, which
            // is the wrong half of the per-mode split.
            let rows: [Invite] = try await supabase
                .from("invites")
                .select("id,session_id,sender_id,recipient_id,join_code,created_at,responded_at,status,mode")
                .eq("recipient_id", value: uid.uuidString.lowercased())
                .eq("status", value: "pending")
                .order("created_at", ascending: false)
                .execute()
                .value
            self.pending = rows
            // Drop snooze entries for invites that are no longer pending so
            // the set can't grow without bound and a re-sent invite (same
            // recipient, new row id) reappears as a fresh banner.
            let liveIds = Set(rows.map(\.id))
            snoozedBannerIds.formIntersection(liveIds)

            // Hydrate sender profiles for every row we don't already have.
            // We never drop entries from the cache here — a sender whose
            // invite was just accepted (and therefore disappears from
            // `pending`) might still need to be rendered by a sheet that's
            // already on screen for one extra frame.
            let missing = Set(rows.map(\.senderId)).subtracting(senderProfiles.keys)
            if !missing.isEmpty {
                let ids = missing.map { $0.uuidString.lowercased() }
                let ps: [Profile] = try await supabase
                    .from("profiles")
                    .select()
                    .in("id", values: ids)
                    .execute()
                    .value
                for p in ps { senderProfiles[p.id] = p }
            }
        } catch {
            // Swallow — empty inbox is a fine fallback, and we don't want a
            // transient network blip to flash a red banner. The next poll
            // recovers automatically.
        }
    }

    /// Send an invite to each of `recipientIds` for the given session +
    /// snapshot of its join code. Uses an upsert with `ignoreDuplicates`
    /// so a re-tap (or two devices both firing on the same crew) collapses
    /// to one row per (session, recipient) thanks to the unique index.
    /// Returns the number of rows accepted by the server, useful for a
    /// "Sent to N friends" toast in the UI.
    @discardableResult
    func send(sessionId: UUID, joinCode: String, mode: SeshMode, recipientIds: [UUID]) async -> Int {
        guard let uid = supabase.auth.currentUser?.id else { return 0 }
        let unique = Array(Set(recipientIds)).filter { $0 != uid }
        guard !unique.isEmpty else { return 0 }
        struct Row: Encodable {
            let session_id: String
            let sender_id: String
            let recipient_id: String
            let join_code: String
            let mode: String
            let status: String
        }
        let rows: [Row] = unique.map { rid in
            Row(
                session_id: sessionId.uuidString.lowercased(),
                sender_id: uid.uuidString.lowercased(),
                recipient_id: rid.uuidString.lowercased(),
                join_code: joinCode,
                mode: mode.rawValue,
                status: "pending"
            )
        }
        do {
            // A real upsert (NOT ignoreDuplicates): re-inviting someone who
            // already accepted/declined for this session resets their row
            // to `pending`, so the invite actually reappears in their inbox.
            // A silent skip here was exactly the "resent the invite and they
            // never got it" bug.
            _ = try await supabase
                .from("invites")
                .upsert(rows, onConflict: "session_id,recipient_id")
                .execute()
            return rows.count
        } catch {
            self.error = "Couldn't send invite"
            return 0
        }
    }

    /// Flip an invite to `accepted` or `declined`. We update by id (RLS
    /// already pins to recipient_id = auth.uid(), so a malicious id from
    /// another inbox can't sneak through). The local row is removed
    /// optimistically so the banner/sheet collapse instantly — the next
    /// poll re-confirms.
    func updateStatus(_ inviteId: UUID, to status: String) async {
        struct Patch: Encodable {
            let status: String
            let responded_at: String
        }
        let patch = Patch(status: status, responded_at: ISO8601DateFormatter().string(from: Date()))
        // Optimistic removal — the row is no longer "pending" by definition.
        pending.removeAll { $0.id == inviteId }
        do {
            _ = try await supabase
                .from("invites")
                .update(patch)
                .eq("id", value: inviteId.uuidString.lowercased())
                .execute()
        } catch {
            // Rollback isn't worth the complexity — the next refresh will
            // restore the row if the update truly failed. Surface a soft
            // error string so the inbox sheet can show a retry hint.
            self.error = "Couldn't update invite"
            await refresh()
        }
    }
}


// MARK: - Events UI

/// Identifiable wrapper so `.sheet(item:)` can present an event by id
/// while the sheet itself stays live against the polling service.
struct EventRef: Identifiable, Equatable {
    let id: UUID
}

/// The three plannable levels. Friendlier than raw BAC, mapped to a peak
/// target under the hood — capped well below the danger tier by design.
enum EventTier: String, CaseIterable, Identifiable {
    case mellow, merry, lit
    var id: String { rawValue }

    var target: Double {
        switch self {
        case .mellow: return 0.04
        case .merry:  return 0.065
        case .lit:    return 0.10
        }
    }

    var label: String {
        switch self {
        case .mellow: return "MELLOW"
        case .merry:  return "MERRY"
        case .lit:    return "LIT"
        }
    }

    var blurb: String {
        switch self {
        case .mellow: return "easy buzz"
        case .merry:  return "party pace"
        case .lit:    return "big night"
        }
    }

    static func nearest(to bac: Double) -> EventTier {
        allCases.min { abs($0.target - bac) < abs($1.target - bac) } ?? .merry
    }
}

/// Three-segment target level picker used by the composer and the
/// event's supply calculator.
private struct EventTierPicker: View {
    @Binding var tier: EventTier
    var enabled: Bool = true

    var body: some View {
        HStack(spacing: 8) {
            ForEach(EventTier.allCases) { t in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        tier = t
                    }
                } label: {
                    VStack(spacing: 3) {
                        Text(t.label)
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .tracking(1.6)
                            .foregroundStyle(tier == t ? Color.whiskey : Color.bronze)
                        Text(t.blurb)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(tier == t ? 0.7 : 0.4))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(tier == t ? Color.cream.opacity(0.08) : Color.cream.opacity(0.02))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                tier == t ? Color.whiskey.opacity(0.45) : Color.cream.opacity(0.06),
                                lineWidth: 1
                            )
                    )
                }
                .buttonStyle(PressScaleStyle())
                .disabled(!enabled)
            }
        }
    }
}

/// One event in the PLAN tab's UPCOMING list. Pending invites carry
/// inline GOING / CAN'T buttons so RSVPing never requires a detour.
struct EventCard: View {
    let event: SeshEvent
    let goingCount: Int
    let myStatus: String?
    /// Rendered in the PAST EVENTS shelf: dimmed, no RSVP, "ran live" line.
    var isPastShelf: Bool = false
    let onTap: () -> Void
    let onRSVP: (Bool) -> Void

    private var dateLine: String {
        if isPastShelf {
            let day = event.startsAt.formatted(.dateTime.day().month(.abbreviated))
            return event.liveEndedAt != nil ? "RAN LIVE · \(day)".uppercased() : day.uppercased()
        }
        let day = event.startsAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        let time = event.startsAt.formatted(date: .omitted, time: .shortened)
        return "\(day) · \(time)".uppercased()
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    if let cover = event.coverURL, let url = URL(string: cover) {
                        DownsampledAsyncImage(url: url, targetPoints: 44,
                                              placeholder: Color.whiskey.opacity(0.12))
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.cream.opacity(0.1), lineWidth: 1)
                        )
                    } else {
                        ZStack {
                            Circle()
                                .fill(Color.whiskey.opacity(0.12))
                                .frame(width: 38, height: 38)
                            Image(systemName: event.kindValue.icon)
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.whiskey)
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(event.title)
                            .font(.system(size: 16, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color.cream)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            if event.isLiveNow {
                                HStack(spacing: 4) {
                                    SonarDot(size: 5, color: .whiskey)
                                    Text("LIVE NOW")
                                        .font(.system(size: 9.5, weight: .black, design: .monospaced))
                                        .tracking(1.4)
                                        .foregroundStyle(Color.whiskey)
                                }
                            } else {
                                Text(dateLine)
                                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                    .tracking(1.2)
                                    .foregroundStyle(Color.bronze)
                                if !isPastShelf {
                                    Text("· \(event.startsAt.formatted(.relative(presentation: .named)))".uppercased())
                                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                        .tracking(1.0)
                                        .foregroundStyle(Color.cream.opacity(0.45))
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(goingCount)")
                            .font(.system(size: 20, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color.cream)
                            .monospacedDigit()
                        SectionLabel("Going")
                    }
                }

                if myStatus == "pending" && !isPastShelf {
                    HStack(spacing: 8) {
                        Button {
                            onRSVP(true)
                        } label: {
                            Text("I'M GOING")
                                .font(.system(size: 11, weight: .black, design: .monospaced))
                                .tracking(1.6)
                                .foregroundStyle(Color.ink)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color.whiskey)
                                )
                        }
                        .buttonStyle(PressScaleStyle())

                        Button {
                            onRSVP(false)
                        } label: {
                            Text("CAN'T")
                                .font(.system(size: 11, weight: .black, design: .monospaced))
                                .tracking(1.6)
                                .foregroundStyle(Color.cream.opacity(0.7))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color.cream.opacity(0.06))
                                )
                        }
                        .buttonStyle(PressScaleStyle())
                    }
                } else if myStatus == "declined" {
                    Text("You declined — tap to change your mind")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.bronze)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.inkElev)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(
                                myStatus == "pending" ? Color.whiskey.opacity(0.35) : Color.cream.opacity(0.06),
                                lineWidth: 1
                            )
                    )
            )
            .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
            .opacity(isPastShelf ? 0.72 : (myStatus == "declined" ? 0.6 : 1))
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// Full event screen: who's coming (RSVP + ghosts) and the supply
/// calculator — how much to buy for everyone to land on the target level.
struct EventDetailSheet: View {
    let eventId: UUID
    @ObservedObject var events: EventsService
    @ObservedObject var friends: FriendsService
    let profile: Profile
    @Environment(\.dismiss) private var dismiss
    @AppStorage(BACUnitSetting.key, store: BACUnitSetting.store) private var bacUnitMode = "auto"

    @State private var invitePickerOpen = false
    @State private var addGuestOpen = false
    @State private var confirmCancel = false
    @State private var confirmLeave = false
    /// Local mirror of the target tier so the picker feels instant; the
    /// authoritative value lives on the event row.
    @State private var tier: EventTier = .merry
    /// Which container types the shopping list uses.
    @State private var selectedTypes: [SupplyContainer] = [.beerCan, .wineBottle, .vodkaBottle]
    /// Local mirrors of the window controls.
    @State private var days: Int = 1
    @State private var hoursPerDay: Double = 6
    /// Cover photo picker selection (host only).
    @State private var coverItem: PhotosPickerItem?
    @State private var locationSheetOpen = false
    /// Night report data for ended events: what was actually drunk (the
    /// linked session's ledger), the squad schnaps, and the route.
    @State private var nightDrinks: [SessionDrink] = []
    @State private var nightSnaps: [SessionSnap] = []
    @State private var nightRoute: [NightRouteStop] = []
    @State private var nightLoaded = false
    /// Tapped schnap → full-screen gallery, opened at this index.
    struct SnapLightboxContext: Identifiable {
        let id = UUID()
        let start: Int
    }
    @State private var snapLightbox: SnapLightboxContext?

    struct NightRouteStop: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let lat: Double
        let lon: Double
        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }

    private var bacUnit: BACUnit { BACUnitSetting.resolved(mode: bacUnitMode) }
    private var event: SeshEvent? { events.events.first { $0.id == eventId } }
    private var members: [EventMember] { events.membersByEvent[eventId] ?? [] }
    private var isHost: Bool { event?.hostId == profile.id }
    private var myStatus: String? { members.first { $0.profileId == profile.id }?.status }
    /// Host always edits; going members too when the host allows it.
    private var canEdit: Bool {
        guard let ev = event else { return false }
        return isHost || (ev.editMode == "everyone" && myStatus == "going")
    }
    /// Postgres writes byo keys as lowercase uuid text.
    private var myUidKey: String { profile.id.uuidString.lowercased() }

    private var goingProfiles: [Profile] {
        members.filter { $0.status == "going" }
            .compactMap { events.profilesById[$0.profileId] }
    }

    private var headcount: Int { goingProfiles.count + (event?.ghosts.count ?? 0) }

    /// Σ weight·r/100 over everyone who drinks — the calculator's
    /// denominator.
    private var totalSpread: Double {
        let p = goingProfiles.reduce(0.0) {
            $0 + EventProvisioning.spread(weightKg: $1.weightKg, sex: $1.sex)
        }
        let g = (event?.ghosts ?? []).reduce(0.0) {
            $0 + EventProvisioning.spread(weightKg: $1.weightKg, sex: $1.sex)
        }
        return p + g
    }

    var body: some View {
        ZStack {
            AtmosphereBackground(accent: .whiskey)
            if let ev = event {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        coverBanner(ev)
                        header(ev)
                        liveStateRow(ev)
                        locationRow(ev)
                        if myStatus == "pending" && ev.liveEndedAt == nil {
                            rsvpButtons(ev)
                        }
                        squadSection(ev)
                        if ev.liveEndedAt != nil {
                            nightReportSection(ev)
                        } else {
                            calculatorSection(ev)
                        }
                        dangerZone(ev)
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 32)
                }
            } else {
                VStack(spacing: 10) {
                    Text("This event is gone")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.cream)
                    Text("The host may have cancelled it.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.bronze)
                }
            }
        }
        .onAppear { syncLocalState() }
        .onChange(of: event) { _, _ in syncLocalState() }
        .task(id: eventId) {
            // Load the night report once for ended events: what everyone
            // actually drank + the squad schnaps from the linked sesh.
            guard let ev = event, ev.liveEndedAt != nil,
                  let sid = ev.liveSessionId, !nightLoaded else { return }
            nightLoaded = true
            let sidStr = sid.uuidString.lowercased()
            if let drinks: [SessionDrink] = try? await supabase
                .from("session_drinks")
                .select()
                .eq("session_id", value: sidStr)
                .order("created_at", ascending: true)
                .execute()
                .value {
                nightDrinks = drinks
            }
            if let snaps: [SessionSnap] = try? await supabase
                .from("session_snaps")
                .select()
                .eq("session_id", value: sidStr)
                .order("created_at", ascending: true)
                .execute()
                .value {
                nightSnaps = snaps
            }
            // The group's route (bars + pre-game markers) for the map —
            // same table the group recap builds from.
            struct RouteRow: Decodable {
                let name: String
                let lat: Double?
                let lon: Double?
            }
            if let rows: [RouteRow] = try? await supabase
                .from("session_stops")
                .select("name, lat, lon, arrived_at")
                .eq("session_id", value: sidStr)
                .order("arrived_at", ascending: true)
                .execute()
                .value {
                nightRoute = rows.compactMap { r in
                    guard let lat = r.lat, let lon = r.lon else { return nil }
                    return NightRouteStop(name: r.name, lat: lat, lon: lon)
                }
            }
        }
        .onChange(of: coverItem) { _, item in
            guard let item, let ev = event, isHost else { return }
            let t: Task<Void, Never> = Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let jpeg = Self.downscaledJPEG(data) {
                    await events.uploadCover(eventId: ev.id, jpeg: jpeg)
                }
                coverItem = nil
            }
            _ = t
        }
        .sheet(isPresented: $invitePickerOpen) {
            EventFriendPicker(
                friends: friends,
                alreadyIn: Set(members.map(\.profileId))
            ) { ids in
                let t: Task<Void, Never> = Task {
                    await events.invite(eventId: eventId, recipientIds: ids)
                }
                _ = t
            }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.ink)
        }
        .sheet(isPresented: $addGuestOpen) {
            AddPersonSheet { name, sex, age, weightKg in
                guard let ev = event else { return }
                let ghost = GhostMember(name: name, sex: sex, age: age, weightKg: weightKg)
                let t: Task<Void, Never> = Task {
                    await events.setGhosts(eventId: ev.id, ev.ghosts + [ghost])
                }
                _ = t
            }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.ink)
        }
        .fullScreenCover(item: $snapLightbox) { ctx in
            GalleryLightbox(
                urls: nightSnaps.compactMap(\.url),
                start: ctx.start,
                onClose: { snapLightbox = nil }
            )
        }
        .sheet(isPresented: $locationSheetOpen) {
            EventLocationSheet(
                startsAt: event?.startsAt ?? Date(),
                currentName: event?.locationName,
                onPickVenue: { venue in
                    let t: Task<Void, Never> = Task {
                        await events.setLocation(eventId: eventId, venue: venue)
                    }
                    _ = t
                },
                onPickSpot: { spot in
                    let t: Task<Void, Never> = Task {
                        await events.setLocation(eventId: eventId, spot: spot)
                    }
                    _ = t
                },
                onClear: {
                    let t: Task<Void, Never> = Task {
                        await events.clearLocation(eventId: eventId)
                    }
                    _ = t
                }
            )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.ink)
        }
    }

    /// Event location: tappable for the host while the event is upcoming,
    /// read-only for everyone else, hidden entirely when unset and locked.
    @ViewBuilder
    private func locationRow(_ ev: SeshEvent) -> some View {
        let editable = isHost && ev.liveEndedAt == nil
        if let name = ev.locationName {
            Button {
                if editable { locationSheetOpen = true }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: ev.locationKind == "venue" ? "mappin.circle.fill" : "house.fill")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.whiskey)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.cream)
                            .lineLimit(1)
                        Text(ev.locationKind == "venue"
                             ? "Everyone checks in here when the sesh starts"
                             : "Group pre-game location when the sesh starts")
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.bronze)
                    }
                    Spacer(minLength: 8)
                    if editable {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.bronze)
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.inkElev)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.cream.opacity(0.08), lineWidth: 1)
                )
            }
            .buttonStyle(PressScaleStyle())
            .disabled(!editable)
        } else if editable {
            Button {
                locationSheetOpen = true
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.whiskey.opacity(0.12))
                            .frame(width: 34, height: 34)
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.whiskey)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Set a location")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.cream)
                        Text("A bar to check into, or a pre-game address")
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.bronze)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.bronze)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.inkElev)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.cream.opacity(0.1), lineWidth: 1)
                )
            }
            .buttonStyle(PressScaleStyle())
        }
    }

    /// Downscale to ≤1400px and recompress — covers don't need originals.
    private static func downscaledJPEG(_ data: Data, maxDim: CGFloat = 1400) -> Data? {
        guard let img = UIImage(data: data) else { return nil }
        let scale = min(1, maxDim / max(img.size.width, img.size.height))
        let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.72)
    }

    /// Pull the event's persisted tier + container selection into local
    /// state (first appear and whenever another device changes them).
    private func syncLocalState() {
        guard let ev = event else { return }
        tier = EventTier.nearest(to: ev.targetBAC)
        days = ev.nights
        hoursPerDay = ev.durationHours
        if !ev.supplies.isEmpty {
            let types = ev.supplies.keys.compactMap(SupplyContainer.init(rawValue:))
            if !types.isEmpty {
                selectedTypes = SupplyContainer.allCases.filter { types.contains($0) }
            }
        }
    }

    // MARK: header

    /// Cover photo banner (host can add/replace; everyone sees it).
    @ViewBuilder
    private func coverBanner(_ ev: SeshEvent) -> some View {
        if let cover = ev.coverURL, let url = URL(string: cover) {
            ZStack(alignment: .bottomTrailing) {
                DownsampledAsyncImage(url: url, targetPoints: 430, placeholder: Color.inkElev)
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.clear, Color.ink.opacity(0.45)],
                                startPoint: .center, endPoint: .bottom
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.cream.opacity(0.08), lineWidth: 1)
                )

                if isHost {
                    coverPickerButton(compact: true)
                        .padding(10)
                }
            }
            .padding(.top, 20)
        } else if isHost {
            coverPickerButton(compact: false)
                .padding(.top, 20)
        }
    }

    private func coverPickerButton(compact: Bool) -> some View {
        PhotosPicker(selection: $coverItem, matching: .images) {
            HStack(spacing: 6) {
                Image(systemName: "photo.fill")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                Text(compact ? "CHANGE" : "ADD A COVER PHOTO")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.4)
            }
            .foregroundStyle(compact ? Color.cream : Color.bronze)
            .padding(.horizontal, compact ? 10 : 14)
            .padding(.vertical, compact ? 7 : 12)
            .frame(maxWidth: compact ? nil : .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(compact ? Color.ink.opacity(0.6) : Color.cream.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.cream.opacity(0.1), lineWidth: 1)
            )
        }
    }

    /// LIVE banner while the linked sesh runs; quiet receipt afterwards.
    @ViewBuilder
    private func liveStateRow(_ ev: SeshEvent) -> some View {
        if ev.isLiveNow {
            HStack(spacing: 10) {
                SonarDot(size: 7, color: .whiskey)
                VStack(alignment: .leading, spacing: 1) {
                    Text("LIVE NOW")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(Color.whiskey)
                    Text("The group sesh is running — log your drinks on the LIVE tab.")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.7))
                }
                Spacer()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.whiskey.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.whiskey.opacity(0.3), lineWidth: 1)
            )
        } else if let ended = ev.liveEndedAt {
            StatRow(icon: "checkmark.seal.fill",
                    title: "This night ran live",
                    value: ended.formatted(.dateTime.day().month(.abbreviated)))
        }
    }

    private func header(_ ev: SeshEvent) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.whiskey.opacity(0.12))
                    .frame(width: 52, height: 52)
                Image(systemName: ev.kindValue.icon)
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.whiskey)
            }
            VStack(alignment: .leading, spacing: 3) {
                SectionLabel(ev.kindValue.label)
                Text(ev.title)
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .tracking(-0.8)
                    .foregroundStyle(Color.cream)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(ev.startsAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()).uppercased())
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(Color.bronze)
                    Text("· \(ev.startsAt.formatted(.relative(presentation: .named)))".uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.0)
                        .foregroundStyle(Color.cream.opacity(0.45))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 20)
    }

    private func rsvpButtons(_ ev: SeshEvent) -> some View {
        HStack(spacing: 8) {
            Button {
                let t: Task<Void, Never> = Task {
                    await events.respond(eventId: ev.id, going: true)
                }
                _ = t
            } label: {
                Text("I'M GOING")
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .tracking(1.8)
                    .foregroundStyle(Color.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.whiskey)
                    )
                    .shadow(color: Color.whiskey.opacity(0.4), radius: 14, y: 7)
            }
            .buttonStyle(PressScaleStyle())

            Button {
                let t: Task<Void, Never> = Task {
                    await events.respond(eventId: ev.id, going: false)
                }
                _ = t
            } label: {
                Text("CAN'T MAKE IT")
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .tracking(1.8)
                    .foregroundStyle(Color.cream.opacity(0.7))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.cream.opacity(0.06))
                    )
            }
            .buttonStyle(PressScaleStyle())
        }
    }

    // MARK: squad

    private func squadSection(_ ev: SeshEvent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Squad · \(headcount) going")

            VStack(spacing: 6) {
                ForEach(members.sorted(by: memberSort), id: \.profileId) { m in
                    memberRow(m, ev: ev)
                }
                ForEach(ev.ghosts) { ghost in
                    ghostRow(ghost, ev: ev)
                }
            }

            if isHost {
                Button {
                    invitePickerOpen = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                        Text("INVITE FRIENDS")
                            .font(.system(size: 13, weight: .black, design: .monospaced))
                            .tracking(2)
                    }
                    .foregroundStyle(Color.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.whiskey)
                    )
                    .shadow(color: Color.whiskey.opacity(0.35), radius: 12, y: 6)
                }
                .buttonStyle(PressScaleStyle())

                // A guest can't retroactively join a night that already
                // happened — the add affordance disappears once it ran.
                if ev.liveEndedAt == nil {
                    Button {
                        addGuestOpen = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                            Text("Add a guest who's not on sesh")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(Color.bronze)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScaleStyle())
                }
            }
        }
    }

    private func memberSort(_ a: EventMember, _ b: EventMember) -> Bool {
        func rank(_ s: String) -> Int { s == "going" ? 0 : (s == "pending" ? 1 : 2) }
        if rank(a.status) != rank(b.status) { return rank(a.status) < rank(b.status) }
        return a.createdAt < b.createdAt
    }

    private func memberRow(_ m: EventMember, ev: SeshEvent) -> some View {
        let prof = events.profilesById[m.profileId]
        return HStack(spacing: 10) {
            AvatarView(
                urlString: prof?.avatarURL,
                initial: String((prof?.name ?? "?").prefix(1)).uppercased(),
                size: 28
            )
            Text(prof?.name ?? "Friend")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.cream)
            if ev.hostId == m.profileId {
                Text("HOST")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(Color.whiskey)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .overlay(Capsule().strokeBorder(Color.whiskey.opacity(0.6), lineWidth: 1))
            }
            Spacer()
            Text(m.status.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(
                    m.status == "going" ? Color.whiskey
                    : (m.status == "pending" ? Color.bronze : Color.cream.opacity(0.35))
                )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.cream.opacity(0.04))
        )
        .opacity(m.status == "declined" ? 0.55 : 1)
    }

    private func ghostRow(_ ghost: GhostMember, ev: SeshEvent) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.cream.opacity(0.07)).frame(width: 28, height: 28)
                Image(systemName: "person.fill.questionmark")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.bronze)
            }
            Text(ghost.name)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.cream)
            Text("GUEST")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(Color.bronze)
            Spacer()
            if isHost {
                Button {
                    let remaining = ev.ghosts.filter { $0.id != ghost.id }
                    let t: Task<Void, Never> = Task {
                        await events.setGhosts(eventId: ev.id, remaining)
                    }
                    _ = t
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.bronze)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.cream.opacity(0.04))
        )
    }

    // MARK: supply calculator

    private func calculatorSection(_ ev: SeshEvent) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(ev.isBYOB ? "Who brings what" : "Supply calculator")

            VStack(alignment: .leading, spacing: 12) {
                if isHost {
                    modeToggles(ev)
                    CalmDivider()
                }

                EventTierPicker(tier: Binding(
                    get: { tier },
                    set: { newTier in
                        tier = newTier
                        if !ev.isBYOB {
                            applySuggestion(ev, tierOverride: newTier)
                        }
                        let t: Task<Void, Never> = Task {
                            await events.updatePlan(eventId: ev.id, targetBAC: newTier.target)
                        }
                        _ = t
                    }
                ), enabled: canEdit)

                StatRow(icon: "person.2.fill", title: "Drinking crew", value: "\(headcount)")
                windowControls(ev)

                CalmDivider()

                if ev.isBYOB {
                    byobContent(ev)
                } else {
                    calcContent(ev)
                }

                if !canEdit && !ev.isBYOB {
                    Text("Only \(events.profilesById[ev.hostId]?.name ?? "the host") can edit the list.")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.4))
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.inkElev)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.cream.opacity(0.06), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.35), radius: 12, y: 6)

            Disclaimer()
        }
    }

    /// Host settings: how is this event planned, and who may edit it.
    private func modeToggles(_ ev: SeshEvent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Auto-start: the server opens a live group sesh at start time
            // with everyone who RSVP'd going. Locked once it has fired.
            HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(ev.autoLive ? Color.whiskey : Color.bronze)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Start LIVE automatically")
                        .font(CalmType.body())
                        .foregroundStyle(Color.cream.opacity(0.85))
                    Text("Everyone going joins a group sesh at \(ev.startsAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.bronze)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(
                    get: { ev.autoLive },
                    set: { on in
                        let t: Task<Void, Never> = Task {
                            await events.setAutoLive(eventId: ev.id, on)
                        }
                        _ = t
                    }
                ))
                    .labelsHidden()
                    .tint(Color.whiskey)
                    .disabled(ev.liveSessionId != nil)
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Planning")
                HStack(spacing: 8) {
                    modeChip("CALCULATED", on: !ev.isBYOB) {
                        let t: Task<Void, Never> = Task {
                            await events.setModes(eventId: ev.id, planMode: "calc")
                        }
                        _ = t
                    }
                    modeChip("EVERYONE BRINGS", on: ev.isBYOB) {
                        let t: Task<Void, Never> = Task {
                            await events.setModes(eventId: ev.id, planMode: "byob")
                        }
                        _ = t
                    }
                }
            }
            if !ev.isBYOB {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Who can edit")
                    HStack(spacing: 8) {
                        modeChip("ONLY ME", on: ev.editMode == "host") {
                            let t: Task<Void, Never> = Task {
                                await events.setModes(eventId: ev.id, editMode: "host")
                            }
                            _ = t
                        }
                        modeChip("EVERYONE GOING", on: ev.editMode == "everyone") {
                            let t: Task<Void, Never> = Task {
                                await events.setModes(eventId: ev.id, editMode: "everyone")
                            }
                            _ = t
                        }
                    }
                }
            }
        }
    }

    private func modeChip(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(on ? Color.whiskey : Color.bronze)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    Capsule().fill(on ? Color.cream.opacity(0.08) : Color.cream.opacity(0.02))
                )
                .overlay(
                    Capsule().strokeBorder(
                        on ? Color.whiskey.opacity(0.45) : Color.cream.opacity(0.06),
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(PressScaleStyle())
    }

    /// Days + hours-per-day. Editable for anyone with edit rights,
    /// read-only StatRow otherwise.
    @ViewBuilder
    private func windowControls(_ ev: SeshEvent) -> some View {
        if canEdit {
            HStack {
                HStack(spacing: 10) {
                    Image(systemName: "calendar")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.bronze)
                        .frame(width: 20)
                    Text("Days")
                        .font(CalmType.body())
                        .foregroundStyle(Color.cream.opacity(0.85))
                }
                Spacer()
                miniStepper(
                    value: days, range: 1...14,
                    onChange: { newDays in
                        days = newDays
                        if !ev.supplies.isEmpty {
                            applySuggestion(ev, nightsOverride: newDays)
                        }
                        let t: Task<Void, Never> = Task {
                            await events.updatePlan(eventId: ev.id, nights: newDays)
                        }
                        _ = t
                    }
                )
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HStack(spacing: 10) {
                        Image(systemName: "hourglass")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.bronze)
                            .frame(width: 20)
                        Text("Hours per day")
                            .font(CalmType.body())
                            .foregroundStyle(Color.cream.opacity(0.85))
                    }
                    Spacer()
                    Text("\(formatHours(hoursPerDay)) h")
                        .font(CalmType.body(14, weight: .bold).monospacedDigit())
                        .foregroundStyle(Color.cream)
                        .contentTransition(.numericText())
                }
                TintedSlider(value: Binding(
                    get: { hoursPerDay },
                    set: { newHours in
                        hoursPerDay = newHours
                        if !ev.supplies.isEmpty {
                            applySuggestion(ev, hoursOverride: newHours)
                        }
                        let t: Task<Void, Never> = Task {
                            await events.updatePlan(eventId: ev.id, durationHours: newHours)
                        }
                        _ = t
                    }
                ), range: 2...12, step: 0.5, accent: .whiskey)
            }
        } else {
            StatRow(icon: "hourglass", title: "Window",
                    value: ev.nights > 1
                        ? "\(formatHours(ev.durationHours)) h × \(ev.nights) days"
                        : "\(formatHours(ev.durationHours)) h")
        }
    }

    private func miniStepper(value: Int, range: ClosedRange<Int>, onChange: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 0) {
            Button {
                if value > range.lowerBound { onChange(value - 1) }
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 12, weight: .black, design: .rounded))
                    .foregroundStyle(value > range.lowerBound ? Color.cream.opacity(0.8) : Color.cream.opacity(0.25))
                    .frame(width: 34, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleStyle())
            .disabled(value <= range.lowerBound)

            Text("\(value)")
                .font(.system(size: 15, weight: .black, design: .rounded))
                .foregroundStyle(Color.cream)
                .monospacedDigit()
                .frame(minWidth: 26)
                .contentTransition(.numericText(value: Double(value)))

            Button {
                if value < range.upperBound { onChange(value + 1) }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .black, design: .rounded))
                    .foregroundStyle(Color.ink)
                    .frame(width: 34, height: 30)
                    .background(Color.whiskey)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleStyle())
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.cream.opacity(0.05))
        )
    }

    // MARK: calculated-list mode

    @ViewBuilder
    private func calcContent(_ ev: SeshEvent) -> some View {
        let gramsNeeded = EventProvisioning.gramsNeeded(
            target: tier.target, hours: ev.durationHours,
            nights: ev.nights, totalSpread: totalSpread
        )
        let currentGrams = EventProvisioning.grams(of: ev.supplies)
        let resulting = EventProvisioning.resultingBAC(
            totalGrams: currentGrams, hours: ev.durationHours,
            nights: ev.nights, totalSpread: totalSpread
        )
        let perPersonDrinks = headcount > 0
            ? currentGrams / Double(headcount) / Double(max(ev.nights, 1)) / EventProvisioning.gramsPerStandardDrink
            : 0
        // Editors' devices recalculate stale lists automatically (driver
        // fingerprint, EventsService.autoRecalcStaleLists). A viewer can
        // still catch the brief gap before an editor's next poll — show
        // them why the number looks off.
        let fpNow = EventProvisioning.fingerprint(
            target: tier.target, hours: ev.durationHours,
            nights: ev.nights, totalSpread: totalSpread, types: selectedTypes
        )
        let stale = !canEdit && currentGrams > 0
            && ev.supplies[EventProvisioning.fingerprintKey] != fpNow

        SectionLabel("What are you buying?")
        supplyTypeChips(ev)

        if headcount == 0 {
            Text("Add someone to the squad and the calculator wakes up.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.bronze)
        } else if ev.supplies.isEmpty {
            if canEdit {
                Button {
                    applySuggestion(ev)
                } label: {
                    Text("CALCULATE THE LIST")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .tracking(1.8)
                        .foregroundStyle(Color.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.whiskey)
                        )
                }
                .buttonStyle(PressScaleStyle())
            } else {
                Text("The list hasn't been built yet.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.bronze)
            }
        } else {
            VStack(spacing: 6) {
                ForEach(selectedTypes) { type in
                    supplyRow(type, ev: ev)
                }
            }

            if stale {
                staleNotice(ev, needed: gramsNeeded, current: currentGrams)
            }

            resultLine(resulting: resulting, perPersonDrinks: perPersonDrinks, needed: gramsNeeded, current: currentGrams)

            if canEdit {
                Button {
                    applySuggestion(ev)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                        Text("RECALCULATE THE LIST")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(1.4)
                    }
                    .foregroundStyle(Color.bronze)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.cream.opacity(0.03))
                    )
                }
                .buttonStyle(PressScaleStyle())
            }
        }
    }

    /// Amber note a viewer sees in the moment between the crew changing
    /// and an editor's device auto-recalculating the list.
    private func staleNotice(_ ev: SeshEvent, needed: Double, current: Double) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.91, green: 0.58, blue: 0.29))
            Text("The crew changed — this list is being recalculated. It currently covers \(Int((current / max(needed, 1) * 100).rounded()))% of the \(tier.label) target.")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(red: 0.91, green: 0.58, blue: 0.29).opacity(0.08))
        )
    }

    // MARK: everyone-brings mode

    @ViewBuilder
    private func byobContent(_ ev: SeshEvent) -> some View {
        let pooled = ev.pooledBYO
        let pooledGrams = EventProvisioning.grams(of: pooled)
        let resulting = EventProvisioning.resultingBAC(
            totalGrams: pooledGrams, hours: ev.durationHours,
            nights: ev.nights, totalSpread: totalSpread
        )
        let perPersonDrinks = headcount > 0
            ? pooledGrams / Double(headcount) / Double(max(ev.nights, 1)) / EventProvisioning.gramsPerStandardDrink
            : 0

        if myStatus == "going" {
            SectionLabel("What are you bringing?")
            myBringChips(ev)
            let mine = ev.byo[myUidKey] ?? [:]
            let myTypes = SupplyContainer.allCases.filter { (mine[$0.rawValue] ?? 0) > 0 }
            if !myTypes.isEmpty {
                VStack(spacing: 6) {
                    ForEach(myTypes) { type in
                        byoRow(type, ev: ev, mine: mine)
                    }
                }
            }
            CalmDivider()
        }

        SectionLabel("The pool")
        if pooled.isEmpty {
            Text("Nobody has added anything yet — tap a drink above to claim what you're bringing.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.bronze)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: 6) {
                ForEach(byoContributors(ev), id: \.0) { key, name, summary in
                    HStack(spacing: 10) {
                        Text(name)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.cream)
                        Spacer(minLength: 8)
                        Text(summary)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.bronze)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.cream.opacity(key == myUidKey ? 0.06 : 0.03))
                    )
                }
            }

            resultLine(resulting: resulting, perPersonDrinks: perPersonDrinks,
                       needed: EventProvisioning.gramsNeeded(
                           target: tier.target, hours: ev.durationHours,
                           nights: ev.nights, totalSpread: totalSpread
                       ),
                       current: pooledGrams)
        }
    }

    /// (uid-key, display name, "5× Beer · 1× Wine") per contributor.
    private func byoContributors(_ ev: SeshEvent) -> [(String, String, String)] {
        ev.byo.compactMap { key, slice -> (String, String, String)? in
            let items = slice.filter { $0.value > 0 }
            guard !items.isEmpty else { return nil }
            let name: String
            if key == myUidKey {
                name = "You"
            } else if let uid = UUID(uuidString: key), let p = events.profilesById[uid] {
                name = p.name
            } else {
                name = "Someone"
            }
            let summary = items
                .compactMap { k, v -> (SupplyContainer, Int)? in
                    guard let c = SupplyContainer(rawValue: k) else { return nil }
                    return (c, v)
                }
                .sorted { $0.0.rawValue < $1.0.rawValue }
                .map { "\($1)× \($0.label)" }
                .joined(separator: " · ")
            return (key, name, summary)
        }
        .sorted { $0.1 < $1.1 }
    }

    /// Tap a type to start bringing it (adds one); tap again to drop it.
    private func myBringChips(_ ev: SeshEvent) -> some View {
        let mine = ev.byo[myUidKey] ?? [:]
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SupplyContainer.allCases) { type in
                    let on = (mine[type.rawValue] ?? 0) > 0
                    Button {
                        var items = mine
                        items[type.rawValue] = on ? 0 : 1
                        let t: Task<Void, Never> = Task {
                            await events.setMyBYO(eventId: ev.id, uid: profile.id, items)
                        }
                        _ = t
                    } label: {
                        HStack(spacing: 6) {
                            DrinkGlyph(
                                option: DrinkOption(
                                    category: type.category, name: type.label,
                                    detail: type.unit, volumeML: type.volumeML, abv: type.abv
                                ),
                                size: 16
                            )
                            Text(type.label.uppercased())
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .tracking(1.0)
                                .foregroundStyle(on ? Color.whiskey : Color.bronze)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(on ? Color.cream.opacity(0.08) : Color.cream.opacity(0.02))
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                on ? Color.whiskey.opacity(0.45) : Color.cream.opacity(0.06),
                                lineWidth: 1
                            )
                        )
                    }
                    .buttonStyle(PressScaleStyle())
                }
            }
        }
    }

    /// One of MY bring-list rows — stepper always live for my own items.
    private func byoRow(_ type: SupplyContainer, ev: SeshEvent, mine: [String: Int]) -> some View {
        let count = mine[type.rawValue] ?? 0
        return HStack(spacing: 12) {
            DrinkGlyph(
                option: DrinkOption(
                    category: type.category, name: type.label,
                    detail: type.unit, volumeML: type.volumeML, abv: type.abv
                ),
                size: 24
            )
            .frame(width: 36, height: 36)
            .background(Circle().fill(Color.smoke))
            .overlay(Circle().strokeBorder(Color.cream.opacity(0.1), lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                Text(type.label)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.cream)
                Text(type.unit.uppercased())
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(1.0)
                    .foregroundStyle(Color.bronze)
            }
            Spacer(minLength: 8)

            miniStepper(value: count, range: 0...99) { newCount in
                var items = mine
                items[type.rawValue] = newCount
                let t: Task<Void, Never> = Task {
                    await events.setMyBYO(eventId: ev.id, uid: profile.id, items)
                }
                _ = t
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.cream.opacity(0.03))
        )
    }

    private func supplyTypeChips(_ ev: SeshEvent) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SupplyContainer.allCases) { type in
                    let on = selectedTypes.contains(type)
                    Button {
                        guard canEdit else { return }
                        var types = selectedTypes
                        if on {
                            guard types.count > 1 else { return }
                            types.removeAll { $0 == type }
                        } else {
                            types = SupplyContainer.allCases.filter { types.contains($0) || $0 == type }
                        }
                        selectedTypes = types
                        applySuggestion(ev, typesOverride: types)
                    } label: {
                        HStack(spacing: 6) {
                            DrinkGlyph(
                                option: DrinkOption(
                                    category: type.category, name: type.label,
                                    detail: type.unit, volumeML: type.volumeML, abv: type.abv
                                ),
                                size: 16
                            )
                            Text(type.label.uppercased())
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .tracking(1.0)
                                .foregroundStyle(on ? Color.whiskey : Color.bronze)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(on ? Color.cream.opacity(0.08) : Color.cream.opacity(0.02))
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                on ? Color.whiskey.opacity(0.45) : Color.cream.opacity(0.06),
                                lineWidth: 1
                            )
                        )
                    }
                    .buttonStyle(PressScaleStyle())
                }
            }
        }
    }

    private func supplyRow(_ type: SupplyContainer, ev: SeshEvent) -> some View {
        let count = ev.supplies[type.rawValue] ?? 0
        return HStack(spacing: 12) {
            DrinkGlyph(
                option: DrinkOption(
                    category: type.category, name: type.label,
                    detail: type.unit, volumeML: type.volumeML, abv: type.abv
                ),
                size: 24
            )
            .frame(width: 36, height: 36)
            .background(Circle().fill(Color.smoke))
            .overlay(Circle().strokeBorder(Color.cream.opacity(0.1), lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                Text(type.label)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.cream)
                Text(type.unit.uppercased())
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(1.0)
                    .foregroundStyle(Color.bronze)
            }
            Spacer(minLength: 8)

            if canEdit {
                miniStepper(value: count, range: 0...999) { newCount in
                    setCount(newCount, for: type, ev: ev)
                }
            } else {
                Text("× \(count)")
                    .font(.system(size: 15, weight: .black, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.cream.opacity(0.03))
        )
    }

    private func resultLine(resulting: Double, perPersonDrinks: Double, needed: Double, current: Double) -> some View {
        let landedTier = EventTier.nearest(to: resulting)
        let danger = resulting >= 0.15
        let hot = resulting > 0.12 && !danger
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Lands everyone at")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.7))
                Text("≈ \(bacUnit.formatted(resulting))\(bacUnit.symbol)")
                    .font(.system(size: 16, weight: .black, design: .rounded).monospacedDigit())
                    .foregroundStyle(danger ? Color(red: 0.85, green: 0.32, blue: 0.23) : Color.whiskey)
                    .contentTransition(.numericText())
                Text("· \(landedTier.label)")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(danger ? Color(red: 0.85, green: 0.32, blue: 0.23) : Color.bronze)
            }
            Text("≈ \(perPersonDrinks.formatted(.number.precision(.fractionLength(0)))) standard drinks each\(current > 0 && needed > 0 ? "" : "")")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.5))
            if danger {
                Text("That's blackout territory — cut the list down.")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.85, green: 0.32, blue: 0.23))
            } else if hot {
                Text("Above the LIT target — heavy night, pace it.")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.91, green: 0.58, blue: 0.29))
            }
        }
        .padding(.top, 4)
    }

    private func setCount(_ count: Int, for type: SupplyContainer, ev: SeshEvent) {
        var supplies = ev.supplies
        supplies[type.rawValue] = count
        let t: Task<Void, Never> = Task {
            await events.setSupplies(eventId: ev.id, supplies)
        }
        _ = t
    }

    /// Rebuild the whole list from the calculator (tier + selected types),
    /// stamping the driver fingerprint so other devices know it's fresh.
    private func applySuggestion(
        _ ev: SeshEvent,
        tierOverride: EventTier? = nil,
        typesOverride: [SupplyContainer]? = nil,
        hoursOverride: Double? = nil,
        nightsOverride: Int? = nil
    ) {
        guard canEdit, !ev.isBYOB else { return }
        let t = tierOverride ?? tier
        let types = typesOverride ?? selectedTypes
        let suggestion = EventProvisioning.fingerprintedSuggestion(
            target: t.target,
            hours: hoursOverride ?? ev.durationHours,
            nights: nightsOverride ?? ev.nights,
            totalSpread: totalSpread,
            types: types
        )
        let task: Task<Void, Never> = Task {
            await events.setSupplies(eventId: ev.id, suggestion)
        }
        _ = task
    }

    // MARK: night report (ended events)

    private struct MemberNightStat {
        let profile: Profile
        let plannedSummary: String?
        let stdDrinks: Double
        let peak: Double
    }

    /// "5× Beer · 1× Wine" from a BYOB slice.
    private func byoSummary(_ slice: [String: Int]?) -> String? {
        guard let slice else { return nil }
        let items = slice.filter { $0.value > 0 }
        guard !items.isEmpty else { return nil }
        return items
            .compactMap { k, v -> (SupplyContainer, Int)? in
                guard let c = SupplyContainer(rawValue: k) else { return nil }
                return (c, v)
            }
            .sorted { $0.0.rawValue < $1.0.rawValue }
            .map { "\($1)× \($0.label)" }
            .joined(separator: " · ")
    }

    /// Per-member actuals from the linked session's ledger: personal
    /// drinks in full, shared rounds split across the going crew — the
    /// same arithmetic the live group used that night.
    private func nightStats(_ ev: SeshEvent) -> [MemberNightStat] {
        let going = members.filter { $0.status == "going" }
            .compactMap { events.profilesById[$0.profileId] }
        let n = max(going.count, 1)
        let sharedRows = nightDrinks.filter(\.shared)
        return going.map { p in
            var gramEvents: [(at: Date, grams: Double)] =
                nightDrinks
                    .filter { $0.profileId == p.id && !$0.shared }
                    .map { (at: $0.createdAt, grams: $0.grams) }
            gramEvents += sharedRows.map { (at: $0.createdAt, grams: $0.grams / Double(n)) }
            let total = gramEvents.reduce(0.0) { $0 + $1.grams }
            return MemberNightStat(
                profile: p,
                plannedSummary: ev.isBYOB
                    ? byoSummary(ev.byo[p.id.uuidString.lowercased()])
                    : nil,
                stdDrinks: total / EventProvisioning.gramsPerStandardDrink,
                peak: EventProvisioning.peakBAC(events: gramEvents, weightKg: p.weightKg, sex: p.sex)
            )
        }
        .sorted { $0.peak > $1.peak }
    }

    private func nightReportSection(_ ev: SeshEvent) -> some View {
        let stats = nightStats(ev)
        let avgPeak = stats.isEmpty ? 0 : stats.map(\.peak).reduce(0, +) / Double(stats.count)

        return VStack(alignment: .leading, spacing: 12) {
            SectionLabel("How it went")

            VStack(alignment: .leading, spacing: 12) {
                StatRow(icon: "scope", title: "Target level",
                        value: "\(EventTier.nearest(to: ev.targetBAC).label) · \(bacUnit.formatted(ev.targetBAC))\(bacUnit.symbol)")
                StatRow(icon: "flame.fill", title: "Group peak (avg)",
                        value: stats.isEmpty
                            ? "—"
                            : "\(EventTier.nearest(to: avgPeak).label) · \(bacUnit.formatted(avgPeak))\(bacUnit.symbol)",
                        valueColor: .whiskey)
                if !nightRoute.isEmpty {
                    StatRow(icon: "mappin.and.ellipse", title: "Stops",
                            value: "\(nightRoute.count)")
                }

                if !ev.isBYOB, let plan = shoppingSummary(ev.supplies) {
                    VStack(alignment: .leading, spacing: 3) {
                        SectionLabel("The plan said")
                        Text(plan)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.cream.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !nightRoute.isEmpty {
                    nightRouteMap
                }

                CalmDivider()

                SectionLabel(ev.isBYOB ? "Brought vs drunk" : "Who drank what")
                if stats.isEmpty || nightDrinks.isEmpty {
                    Text(nightLoaded
                         ? "No drinks were logged during this night."
                         : "Loading the night…")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.bronze)
                } else {
                    VStack(spacing: 6) {
                        ForEach(stats, id: \.profile.id) { s in
                            memberNightRow(s)
                        }
                    }
                }

            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.inkElev)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.cream.opacity(0.06), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.35), radius: 12, y: 6)

            if !nightSnaps.isEmpty {
                nightSnapsSection
            }

            Disclaimer()
        }
    }

    /// The night's squad schnaps — a section of its own with big
    /// two-column tiles (they were buried as thumbnails inside the stats
    /// card), each tappable into the full-screen swipeable gallery.
    private var nightSnapsSection: some View {
        let urls = nightSnaps.compactMap(\.url)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Squad schnaps")
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .tracking(-0.5)
                    .foregroundStyle(Color.cream)
                Text("\(urls.count)")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.bronze)
                Spacer()
            }
            Text("Tap a photo to see it full screen — swipe to flick through the night.")
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(Color.bronze)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                ForEach(Array(urls.enumerated()), id: \.offset) { i, url in
                    Button {
                        snapLightbox = SnapLightboxContext(start: i)
                    } label: {
                        // Square base first, image as an overlay: a bare
                        // scaledToFill AsyncImage feeds its own size into
                        // the grid and the tiles go wonky.
                        Rectangle()
                            .fill(Color.smoke)
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(
                                DownsampledAsyncImage(url: url, targetPoints: 170, placeholder: .clear)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Color.cream.opacity(0.08), lineWidth: 1)
                            )
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .padding(7)
                                    .background(Circle().fill(Color.ink.opacity(0.55)))
                                    .padding(7)
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScaleStyle())
                }
            }
        }
    }

    /// Where the group went — markers + route line, same treatment as a
    /// posted night on the timeline.
    private var nightRouteMap: some View {
        let coords = nightRoute.map(\.coordinate)
        // A single stop has no bounding box, so `.automatic` zooms to the
        // max — frame the neighbourhood instead (same trick as posts).
        let initialCamera: MapCameraPosition = coords.count == 1
            ? .region(MKCoordinateRegion(
                center: coords[0],
                latitudinalMeters: 1500,
                longitudinalMeters: 1500))
            : .automatic
        return VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Where the night went")
            Map(initialPosition: initialCamera) {
                ForEach(nightRoute) { stop in
                    Marker(stop.name, systemImage: "mappin", coordinate: stop.coordinate)
                        .tint(Color.whiskey)
                }
                if coords.count > 1 {
                    MapPolyline(coordinates: coords)
                        .stroke(Color.whiskey, lineWidth: 3)
                }
            }
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.cream.opacity(0.08), lineWidth: 1)
            )
            // The route in words, in arrival order.
            Text(nightRoute.map(\.name).joined(separator: "  →  "))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.cream.opacity(0.65))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "24× Beer · 3× Wine · 1× Vodka" from the calculated list.
    private func shoppingSummary(_ supplies: [String: Int]) -> String? {
        let items = supplies
            .compactMap { k, v -> (SupplyContainer, Int)? in
                guard let c = SupplyContainer(rawValue: k), v > 0 else { return nil }
                return (c, v)
            }
            .sorted { $0.0.rawValue < $1.0.rawValue }
        guard !items.isEmpty else { return nil }
        return items.map { "\($1)× \($0.label)" }.joined(separator: " · ")
    }

    private func memberNightRow(_ s: MemberNightStat) -> some View {
        HStack(spacing: 10) {
            AvatarView(
                urlString: s.profile.avatarURL,
                initial: String(s.profile.name.prefix(1)).uppercased(),
                size: 28
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(s.profile.name)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .lineLimit(1)
                if let planned = s.plannedSummary {
                    Text("brought \(planned)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.bronze)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("≈ \(Int(s.stdDrinks.rounded())) \(Int(s.stdDrinks.rounded()) == 1 ? "drink" : "drinks")")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.7))
                Text("peak \(bacUnit.formatted(s.peak))\(bacUnit.symbol) · \(EventTier.nearest(to: s.peak).label)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced).monospacedDigit())
                    .foregroundStyle(s.peak >= 0.15
                        ? Color(red: 0.85, green: 0.32, blue: 0.23)
                        : Color.whiskey)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.cream.opacity(0.04))
        )
    }

    // MARK: danger zone

    @ViewBuilder
    private func dangerZone(_ ev: SeshEvent) -> some View {
        if isHost {
            Button {
                confirmCancel = true
            } label: {
                Text("CANCEL EVENT")
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .tracking(1.8)
                    .foregroundStyle(Color(red: 0.85, green: 0.32, blue: 0.23))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(red: 0.85, green: 0.32, blue: 0.23).opacity(0.1))
                    )
            }
            .buttonStyle(PressScaleStyle())
            .confirmationDialog("Cancel \(ev.title)?", isPresented: $confirmCancel, titleVisibility: .visible) {
                Button("Cancel the event", role: .destructive) {
                    let t: Task<Void, Never> = Task {
                        await events.cancel(eventId: ev.id)
                    }
                    _ = t
                    dismiss()
                }
                Button("Keep it", role: .cancel) {}
            }
        } else if myStatus != nil {
            Button {
                confirmLeave = true
            } label: {
                Text("LEAVE EVENT")
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .tracking(1.8)
                    .foregroundStyle(Color.cream.opacity(0.6))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.cream.opacity(0.05))
                    )
            }
            .buttonStyle(PressScaleStyle())
            .confirmationDialog("Leave \(ev.title)?", isPresented: $confirmLeave, titleVisibility: .visible) {
                Button("Leave event", role: .destructive) {
                    let t: Task<Void, Never> = Task {
                        await events.leave(eventId: ev.id)
                    }
                    _ = t
                    dismiss()
                }
                Button("Stay", role: .cancel) {}
            }
        }
    }
}

/// Lean multi-select friend picker for event invites (the session picker
/// is welded to join codes + the invites table, so events get their own).
private struct EventFriendPicker: View {
    @ObservedObject var friends: FriendsService
    let alreadyIn: Set<UUID>
    var onInvite: ([UUID]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel("Invite friends")
                    Text("Who's coming?")
                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.cream)
                }
                .padding(.top, 22)

                if friends.friends.isEmpty {
                    Text("Add friends first — the friends tab lives behind your profile.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.bronze)
                }

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(friends.friends) { f in
                            let inEvent = alreadyIn.contains(f.id)
                            let on = selected.contains(f.id)
                            Button {
                                guard !inEvent else { return }
                                if on { selected.remove(f.id) } else { selected.insert(f.id) }
                            } label: {
                                HStack(spacing: 10) {
                                    AvatarView(
                                        urlString: f.avatarURL,
                                        initial: String(f.name.prefix(1)).uppercased(),
                                        size: 30
                                    )
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(f.name)
                                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                                            .foregroundStyle(Color.cream)
                                        if let u = f.username {
                                            Text("@\(u)")
                                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                                .foregroundStyle(Color.bronze)
                                        }
                                    }
                                    Spacer()
                                    if inEvent {
                                        Text("IN")
                                            .font(.system(size: 9, weight: .black, design: .monospaced))
                                            .tracking(1.2)
                                            .foregroundStyle(Color.bronze)
                                    } else {
                                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                                            .foregroundStyle(on ? Color.whiskey : Color.cream.opacity(0.25))
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color.cream.opacity(on ? 0.06 : 0.03))
                                )
                            }
                            .buttonStyle(PressScaleStyle())
                            .opacity(inEvent ? 0.5 : 1)
                        }
                    }
                    .padding(.bottom, 90)
                }
            }
            .padding(.horizontal, 22)

            VStack {
                Spacer()
                PrimaryGlowButton(
                    title: selected.isEmpty ? "Pick friends" : "Send \(selected.count) invite\(selected.count == 1 ? "" : "s")",
                    systemImage: "paperplane.fill"
                ) {
                    onInvite(Array(selected))
                    dismiss()
                }
                .disabled(selected.isEmpty)
                .opacity(selected.isEmpty ? 0.5 : 1)
                .padding(.horizontal, 22)
                .padding(.bottom, 20)
            }
        }
    }
}

/// Dual-mode place search for event locations: bar mode reuses the same
/// POI bias as the check-in sheet; spot mode searches anything, including
/// street addresses, so a pre-game at someone's flat works.
@MainActor
private final class EventPlaceSearch: ObservableObject {
    struct Hit: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let detail: String
        let lat: Double
        let lon: Double
    }

    @Published private(set) var hits: [Hit] = []
    private var current: MKLocalSearch?

    func search(_ query: String, barsOnly: Bool) {
        current?.cancel()
        current = nil
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            hits = []
            return
        }
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = q
        if barsOnly {
            req.resultTypes = [.pointOfInterest]
            req.pointOfInterestFilter = MKPointOfInterestFilter(
                including: [.nightlife, .restaurant, .brewery, .winery]
            )
        } else {
            req.resultTypes = [.address, .pointOfInterest]
        }
        let s = MKLocalSearch(request: req)
        current = s
        s.start { [weak self] resp, _ in
            let items = (resp?.mapItems ?? []).prefix(12).map { item in
                Hit(
                    name: item.name ?? "Unknown place",
                    detail: item.placemark.title ?? "",
                    lat: item.placemark.coordinate.latitude,
                    lon: item.placemark.coordinate.longitude
                )
            }
            Task { @MainActor [weak self] in
                self?.hits = Array(items)
            }
        }
    }
}

/// Pick the event's location: a bar (auto check-in at live start) or any
/// place/address (becomes the group pre-game spot at live start).
private struct EventLocationSheet: View {
    let startsAt: Date
    let currentName: String?
    var onPickVenue: (Venue) -> Void
    var onPickSpot: (LooseSpot) -> Void
    var onClear: () -> Void
    @Environment(\.dismiss) private var dismiss

    @StateObject private var search = EventPlaceSearch()
    @State private var query = ""
    @State private var isVenue = true

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel("Event location")
                    Text("Where's it happening?")
                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.cream)
                }
                .padding(.top, 22)

                HStack(spacing: 8) {
                    kindChip("BAR · CHECK-IN", on: isVenue) { isVenue = true }
                    kindChip("SPOT · PRE-GAME", on: !isVenue) { isVenue = false }
                }

                Text(isVenue
                     ? "The whole group gets checked in here the moment the sesh starts."
                     : "Search a place or a street address — it becomes the group's pre-game location when the sesh starts.")
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)

                TextField(
                    "", text: $query,
                    prompt: Text(isVenue ? "Search bars…" : "Bar, flat, address…")
                        .foregroundColor(Color.cream.opacity(0.3))
                )
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.inkElev)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.cream.opacity(0.1), lineWidth: 1)
                    )
                    .onChange(of: query) { _, q in
                        search.search(q, barsOnly: isVenue)
                    }
                    .onChange(of: isVenue) { _, bars in
                        search.search(query, barsOnly: bars)
                    }

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(search.hits) { hit in
                            Button {
                                if isVenue {
                                    // source .user: this venue never lives
                                    // in the venues table, so VenueService's
                                    // reconcile pass must not drop it (that
                                    // was the phantom-stops loop).
                                    onPickVenue(Venue(
                                        id: UUID(),
                                        name: hit.name,
                                        address: hit.detail.isEmpty ? nil : hit.detail,
                                        city: nil,
                                        lat: hit.lat,
                                        lon: hit.lon,
                                        source: .user,
                                        createdAt: Date()
                                    ))
                                } else {
                                    onPickSpot(LooseSpot(
                                        id: UUID(),
                                        name: hit.name,
                                        lat: hit.lat,
                                        lon: hit.lon,
                                        at: startsAt
                                    ))
                                }
                                dismiss()
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: isVenue ? "mappin.circle.fill" : "mappin")
                                        .font(.system(size: 13, weight: .bold, design: .rounded))
                                        .foregroundStyle(Color.whiskey)
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(hit.name)
                                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                                            .foregroundStyle(Color.cream)
                                            .lineLimit(1)
                                        if !hit.detail.isEmpty {
                                            Text(hit.detail)
                                                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                                                .foregroundStyle(Color.bronze)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color.cream.opacity(0.03))
                                )
                            }
                            .buttonStyle(PressScaleStyle())
                        }
                    }
                    .padding(.bottom, 24)
                }

                if currentName != nil {
                    Button {
                        onClear()
                        dismiss()
                    } label: {
                        Text("REMOVE LOCATION")
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .tracking(1.6)
                            .foregroundStyle(Color.cream.opacity(0.6))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.cream.opacity(0.05))
                            )
                    }
                    .buttonStyle(PressScaleStyle())
                    .padding(.bottom, 16)
                }
            }
            .padding(.horizontal, 22)
        }
    }

    private func kindChip(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { action() }
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(on ? Color.whiskey : Color.bronze)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(on ? Color.cream.opacity(0.08) : Color.cream.opacity(0.02))
                )
                .overlay(
                    Capsule().strokeBorder(
                        on ? Color.whiskey.opacity(0.45) : Color.cream.opacity(0.06),
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// Create a new event: what, when, how long, how hard.
struct EventComposerSheet: View {
    @ObservedObject var events: EventsService
    var onCreated: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var kind: EventKind = .party
    @State private var startsAt = Calendar.current.date(
        bySettingHour: 20, minute: 0, second: 0,
        of: Date().addingTimeInterval(86400)
    ) ?? Date().addingTimeInterval(86400)
    @State private var hours: Double = 6
    @State private var nights: Int = 1
    @State private var tier: EventTier = .merry
    @State private var autoLive = false
    @State private var creating = false
    /// Optional event location, picked right in the composer.
    @State private var locationSheetOpen = false
    @State private var pickedVenue: Venue?
    @State private var pickedSpot: LooseSpot?

    private var pickedLocationName: String? {
        pickedVenue?.name ?? pickedSpot?.name
    }

    var body: some View {
        ZStack {
            AtmosphereBackground(accent: .whiskey)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionLabel("New event")
                        Text("Plan something")
                            .font(.system(size: 32, weight: .heavy, design: .rounded))
                            .tracking(-1.2)
                            .foregroundStyle(Color.cream)
                    }
                    .padding(.top, 18)

                    TextField(
                        "", text: $title,
                        prompt: Text("Sara's birthday, Åre trip…")
                            .foregroundColor(Color.cream.opacity(0.3))
                    )
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.cream)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.inkElev)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.cream.opacity(0.1), lineWidth: 1)
                        )

                    HStack(spacing: 8) {
                        ForEach(EventKind.allCases) { k in
                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    kind = k
                                    // A trip usually spans a weekend —
                                    // nudge the default, never override
                                    // an explicit choice.
                                    if k == .trip && nights == 1 { nights = 2 }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: k.icon)
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                    Text(k.label.uppercased())
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .tracking(1.1)
                                }
                                .foregroundStyle(kind == k ? Color.whiskey : Color.bronze)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(
                                    Capsule().fill(kind == k ? Color.cream.opacity(0.08) : Color.cream.opacity(0.02))
                                )
                                .overlay(
                                    Capsule().strokeBorder(
                                        kind == k ? Color.whiskey.opacity(0.45) : Color.cream.opacity(0.06),
                                        lineWidth: 1
                                    )
                                )
                            }
                            .buttonStyle(PressScaleStyle())
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel("When")
                        DatePicker(
                            "", selection: $startsAt,
                            in: Date()...,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                            .datePickerStyle(.compact)
                            .labelsHidden()
                            .tint(Color.whiskey)
                            .colorScheme(.dark)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.inkElev)
                    )

                    Button {
                        locationSheetOpen = true
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Color.whiskey.opacity(pickedLocationName == nil ? 0.12 : 0.2))
                                    .frame(width: 34, height: 34)
                                Image(systemName: "mappin.and.ellipse")
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.whiskey)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                SectionLabel("Where")
                                Text(pickedLocationName ?? "Set a location")
                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Color.cream)
                                    .lineLimit(1)
                                Text(pickedVenue != nil
                                     ? "Everyone checks in here when the sesh starts"
                                     : (pickedSpot != nil
                                        ? "Group pre-game location when the sesh starts"
                                        : "A bar to check into, or a pre-game address"))
                                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.bronze)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.bronze)
                        }
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.inkElev)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(
                                    pickedLocationName == nil ? Color.cream.opacity(0.1) : Color.whiskey.opacity(0.4),
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(PressScaleStyle())

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            SectionLabel("Hours per day")
                            Spacer()
                            Text("\(formatHours(hours)) h")
                                .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(Color.cream)
                                .contentTransition(.numericText())
                        }
                        TintedSlider(value: $hours, range: 2...12, step: 0.5, accent: .whiskey)
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.inkElev)
                    )

                    HStack {
                        SectionLabel("Days")
                        Spacer()
                        HStack(spacing: 0) {
                            Button {
                                if nights > 1 { nights -= 1 }
                            } label: {
                                Image(systemName: "minus")
                                    .font(.system(size: 12, weight: .black, design: .rounded))
                                    .foregroundStyle(Color.cream.opacity(nights > 1 ? 0.8 : 0.25))
                                    .frame(width: 34, height: 30)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PressScaleStyle())

                            Text("\(nights)")
                                .font(.system(size: 15, weight: .black, design: .rounded))
                                .foregroundStyle(Color.cream)
                                .monospacedDigit()
                                .frame(minWidth: 22)
                                .contentTransition(.numericText(value: Double(nights)))

                            Button {
                                if nights < 14 { nights += 1 }
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 12, weight: .black, design: .rounded))
                                    .foregroundStyle(Color.ink)
                                    .frame(width: 34, height: 30)
                                    .background(Color.whiskey)
                                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PressScaleStyle())
                        }
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.inkElev)
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel("Target level")
                        EventTierPicker(tier: $tier)
                        Text("Used by the supply calculator — everyone lands here, based on their own body.")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.45))
                    }

                    HStack(spacing: 10) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(autoLive ? Color.whiskey : Color.bronze)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Start LIVE automatically")
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.cream.opacity(0.85))
                            Text("Everyone going joins a group sesh at start time")
                                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.bronze)
                        }
                        Spacer(minLength: 8)
                        Toggle("", isOn: $autoLive)
                            .labelsHidden()
                            .tint(Color.whiskey)
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.inkElev)
                    )

                    PrimaryGlowButton(
                        title: creating ? "Creating…" : "Create event",
                        systemImage: "sparkles"
                    ) {
                        guard !creating else { return }
                        creating = true
                        Task {
                            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                            if let id = await events.create(
                                title: trimmed,
                                kind: kind,
                                startsAt: startsAt,
                                durationHours: hours,
                                nights: nights,
                                targetBAC: tier.target,
                                autoLive: autoLive
                            ) {
                                if let v = pickedVenue {
                                    await events.setLocation(eventId: id, venue: v)
                                } else if let s = pickedSpot {
                                    // Re-stamp the spot with the final start
                                    // time — the user may have changed the
                                    // date after picking the place.
                                    await events.setLocation(eventId: id, spot: LooseSpot(
                                        id: s.id, name: s.name,
                                        lat: s.lat, lon: s.lon, at: startsAt
                                    ))
                                }
                                dismiss()
                                onCreated(id)
                            }
                            creating = false
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || creating)
                    .opacity(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
                    .padding(.bottom, 24)
                }
                .padding(.horizontal, 22)
            }
        }
        .sheet(isPresented: $locationSheetOpen) {
            EventLocationSheet(
                startsAt: startsAt,
                currentName: pickedLocationName,
                onPickVenue: { pickedVenue = $0; pickedSpot = nil },
                onPickSpot: { pickedSpot = $0; pickedVenue = nil },
                onClear: { pickedVenue = nil; pickedSpot = nil }
            )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.ink)
        }
    }
}

