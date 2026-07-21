// Night Recap — the end-of-sesh story.
//
// During a live sesh every venue check-in is recorded as a "stop" on the
// night's journey. When the user ends the sesh they get a full-screen,
// stage-by-stage recap: an animated MapKit flyover from bar to bar with
// per-stop stats (arrival time, what was drunk there, BAC range), and a
// final zoomed-out overview of the whole route with the night's totals.
//
// Recaps are saved to disk automatically and can be replayed later from
// the profile sheet's "Past nights" list. Each stop carries photos —
// snapped mid-night (camera or library) from the LIVE page, during the
// recap, or the morning after. Photos open full-screen in a lightbox.
//
// Pieces:
//
//   • NightJourneyStore — persists check-ins (UserDefaults) + stages
//     mid-night photos on disk so the journey survives app restarts.
//   • NightRecap / RecapStop — the computed story. Codable so a night
//     can be written to disk and replayed.
//   • RecapHistoryStore — JSON-per-recap in Documents/night-recaps,
//     plus a photo directory per recap.
//   • NightRecapView — the presentation: flyover + cards, with prev/next
//     navigation so any stop can be revisited without a full rewatch.
//   • LiveJourneyPhotosSection — the LIVE page's "Night snaps" card:
//     every stop so far, each with its own photo strip + add buttons.

import SwiftUI
import Combine
import MapKit
import CoreLocation
import PhotosUI
import UIKit
import ImageIO
import Supabase
import AVFoundation

// MARK: - Journey store

/// What a journey entry IS — a bar check-in, or a self-reported marker
/// the user drops mid-night (food run, tactical puke). Markers carry
/// photos like any stop but don't open a drink-attribution window.
enum JourneyStopKind: String, Codable {
    case bar
    case food
    case puke
    /// A "between bars" stop, auto-created on checkout — carries its own
    /// transit photos + (optional) location and is reorderable like any
    /// stop. Becomes the recap's refuel/afters leg.
    case between
}

/// One recorded entry on the night's route.
struct SeshStop: Codable, Identifiable, Equatable {
    let id: UUID
    let venueId: UUID
    let kind: JourneyStopKind
    let name: String
    /// nil for markers (food/puke) until a location is added. Mutable so a
    /// between/marker stop can be located after the fact.
    var lat: Double?
    var lon: Double?
    let arrivedAt: Date
    /// Set when the user taps CHECK OUT. Lets the recap carve "between
    /// bars" (refuel) and "after last bar" (afters) legs out of the night.
    var departedAt: Date? = nil
    /// Photos snapped while AT this stop, staged in the journey's photo
    /// directory until the recap adopts them at END time.
    var photoFilenames: [String] = []
    /// A short comment the user typed about this stop during the night.
    /// Carried into the recap + shown under the stop on a posted timeline.
    var note: String? = nil

    var coordinate: CLLocationCoordinate2D? {
        guard let lat, let lon else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Which GROUP session this entry belongs to. Stamped at creation when
    /// the user is in a live group; nil = personal (solo, or logged in
    /// parallel to a group before joining). The group recap is built from
    /// entries carrying its id — timestamps can't tell "the group's story"
    /// apart from a member's parallel prelude, identity can.
    var sessionId: UUID? = nil

    // Custom decode so journeys persisted by older builds (no kind /
    // departedAt / photoFilenames / note keys) still load instead of resetting.
    enum CodingKeys: String, CodingKey {
        case id, venueId, kind, name, lat, lon, arrivedAt, departedAt, photoFilenames, note, sessionId
    }

    init(
        id: UUID, venueId: UUID, kind: JourneyStopKind = .bar, name: String,
        lat: Double?, lon: Double?, arrivedAt: Date,
        departedAt: Date? = nil, photoFilenames: [String] = [], note: String? = nil,
        sessionId: UUID? = nil
    ) {
        self.id = id
        self.venueId = venueId
        self.kind = kind
        self.name = name
        self.lat = lat
        self.lon = lon
        self.arrivedAt = arrivedAt
        self.departedAt = departedAt
        self.photoFilenames = photoFilenames
        self.note = note
        self.sessionId = sessionId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        venueId = try c.decode(UUID.self, forKey: .venueId)
        kind = (try? c.decodeIfPresent(JourneyStopKind.self, forKey: .kind)) ?? .bar
        name = try c.decode(String.self, forKey: .name)
        lat = try c.decodeIfPresent(Double.self, forKey: .lat)
        lon = try c.decodeIfPresent(Double.self, forKey: .lon)
        arrivedAt = try c.decode(Date.self, forKey: .arrivedAt)
        departedAt = try? c.decodeIfPresent(Date.self, forKey: .departedAt)
        photoFilenames = (try? c.decodeIfPresent([String].self, forKey: .photoFilenames)) ?? []
        note = try? c.decodeIfPresent(String.self, forKey: .note)
        sessionId = try? c.decodeIfPresent(UUID.self, forKey: .sessionId)
    }
}

/// Persists the night's check-ins. Owned by SessionView (same lifetime
/// pattern as GhostMembersStore) and cleared when the sesh ends so a
/// stale Tuesday route never bleeds into Friday's recap.
/// A photo taken while NOT checked in anywhere — pre-game, between bars,
/// or at the afters. The timestamp lets the recap builder file it onto
/// whichever leg of the night it belongs to.
struct LooseTake: Codable, Equatable {
    let filename: String
    let takenAt: Date
}

/// A spot marked while NOT at a bar — the pre-game (before the first
/// check-in) or a between-bars/afters stop. Optional + opt-in. Stores the
/// EXACT coordinate (these are often a home), kept on-device only; the
/// UI warns before capturing and offers name-only. The timestamp files it
/// onto the right narrative leg at recap time, just like loose photos.
struct LooseSpot: Codable, Equatable, Hashable, Identifiable {
    let id: UUID
    var name: String?
    var lat: Double?
    var lon: Double?
    let at: Date
    /// Which GROUP session this spot belongs to (see SeshStop.sessionId).
    var sessionId: UUID? = nil
    var coordinate: CLLocationCoordinate2D? {
        guard let lat, let lon else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
    var hasLocation: Bool { lat != nil && lon != nil }
}

@MainActor
final class NightJourneyStore: ObservableObject {
    @Published private(set) var stops: [SeshStop] = []
    @Published private(set) var loosePhotos: [LooseTake] = []
    @Published private(set) var looseSpots: [LooseSpot] = []
    /// The user's comment on the pre-game (before the first check-in). The
    /// pre-game is a synthetic leg with no SeshStop, so its note lives here.
    @Published private(set) var preGameNote: String?

    // Per-ACCOUNT keys (suffix = signed-in user id). A single shared slot
    // meant one account's night silently OVERWROTE the other's on the same
    // phone — stops and photos vanished after an account switch. The owner
    // stamp only stopped cross-reading, not the overwrite; namespacing
    // gives every account its own journey that survives sign-in/sign-out.
    private let key: String
    private let looseKey: String
    private let looseSpotsKey: String
    private let preGameNoteKey: String

    /// Start of the current loose window — the last checkout (between bars
    /// / afters), or the dawn of time when no bar has been visited yet
    /// (pre-game). Used to scope "the spot for right now".
    private var currentWindowStart: Date {
        stops.last(where: { $0.kind == .bar })?.departedAt ?? .distantPast
    }

    /// The loose spot for the moment the user is in (pre-game, or the gap
    /// since their last checkout).
    var currentLooseSpot: LooseSpot? {
        looseSpots.last { $0.at >= currentWindowStart }
    }

    /// Loose photos belonging to the CURRENT loose moment only — pre-game
    /// (before any bar) or the gap since the last checkout. Scoping by the
    /// window keeps pre-game shots from resurfacing on a later between-bars
    /// page: each moment shows only its own photos.
    var currentWindowLoosePhotos: [LooseTake] {
        let start = currentWindowStart
        return loosePhotos.filter { $0.takenAt >= start }
    }

    /// When the first bar check-in happened (nil while still pre-gaming).
    var firstBarArrival: Date? {
        stops.first(where: { $0.kind == .bar })?.arrivedAt
    }

    /// Photos taken before the first check-in — the pre-game's own set,
    /// viewable on its dedicated page even after you've moved on to a bar.
    var preGamePhotos: [LooseTake] {
        let cutoff = firstBarArrival
        return loosePhotos.filter { cutoff == nil || $0.takenAt < cutoff! }
    }

    /// The pre-game's marked spot (latest before the first check-in).
    var preGameSpot: LooseSpot? {
        let cutoff = firstBarArrival
        return looseSpots.last { cutoff == nil || $0.at < cutoff! }
    }

    /// True once a bar has been visited — i.e. pre-game is now history.
    var hasCheckedInSomewhere: Bool { firstBarArrival != nil }

    /// Supplies the LIVE GROUP id the user is currently in (nil = solo).
    /// Set by SessionView; every new journey entry is stamped with it so
    /// the group recap can tell the group's story apart from a member's
    /// parallel personal stops by IDENTITY, not timestamps.
    var currentSessionProvider: (() -> UUID?)? = nil
    private var currentSessionId: UUID? { currentSessionProvider?() }

    /// Merge the group's server-side route into MY journey — the DOWNSTREAM
    /// half of route syncing, so every member's live view and personal
    /// recap contain every group stop, not just the ones this device
    /// witnessed. By-id for entries that round-tripped (mine come back with
    /// their own ids); name+time proximity for bars (my check-in and the
    /// group's route row are two records of one arrival); insertion keeps
    /// time order without disturbing existing entries.
    func mergeGroupRoute(stops incoming: [SeshStop], spots incomingSpots: [LooseSpot]) {
        var changed = false
        for s in incoming {
            if let i = stops.firstIndex(where: { $0.id == s.id }) {
                // Another member stamped the departure — adopt the window.
                if stops[i].departedAt == nil, let dep = s.departedAt {
                    stops[i].departedAt = dep
                    changed = true
                }
                continue
            }
            if s.kind == .bar, stops.contains(where: {
                $0.kind == .bar && $0.name == s.name
                    && abs($0.arrivedAt.timeIntervalSince(s.arrivedAt)) < 3 * 60
            }) {
                continue
            }
            if s.kind == .between, stops.contains(where: {
                $0.kind == .between && $0.name == s.name
                    && abs($0.arrivedAt.timeIntervalSince(s.arrivedAt)) < 3 * 60
            }) {
                continue
            }
            let at = stops.firstIndex(where: { $0.arrivedAt > s.arrivedAt }) ?? stops.endIndex
            stops.insert(s, at: at)
            changed = true
        }
        if changed { save() }
        var spotsChanged = false
        for sp in incomingSpots {
            // Id-only dedupe: the live broadcast adoption keeps the spot's
            // original id, so a round-trip matches here. (A same-minute
            // proximity guard used to sit here too — it silently swallowed
            // the group's pre-game whenever a member marked their own spot
            // within a minute of it.)
            guard !looseSpots.contains(where: { $0.id == sp.id }) else { continue }
            let at = looseSpots.firstIndex(where: { $0.at > sp.at }) ?? looseSpots.endIndex
            looseSpots.insert(sp, at: at)
            spotsChanged = true
        }
        if spotsChanged { saveLooseSpots() }
    }

    /// The moment a user CREATES a group, their running night becomes the
    /// group's opening chapter — retag everything not already claimed by
    /// another group (the host's pre-game spot typically predates the
    /// group row by a minute). Join does NOT do this: a joiner's earlier
    /// stops stay personal.
    func adoptNightIntoSession(_ sessionId: UUID) {
        for i in stops.indices where stops[i].sessionId == nil {
            stops[i].sessionId = sessionId
        }
        var changedSpots = false
        for i in looseSpots.indices where looseSpots[i].sessionId == nil {
            looseSpots[i].sessionId = sessionId
            changedSpots = true
        }
        save()
        if changedSpots { saveLooseSpots() }
    }

    /// Set (or replace) the loose spot for the current window. The exact
    /// coordinate is stored as-is — these stay on-device, and (once recap
    /// sharing exists) the user chooses per-share whether to include them.
    func setCurrentLooseSpot(name: String?, rawCoordinate: CLLocationCoordinate2D?) {
        let start = currentWindowStart
        looseSpots.removeAll { $0.at >= start }
        let trimmed = name?.trimmingCharacters(in: .whitespaces)
        looseSpots.append(LooseSpot(
            id: UUID(),
            name: (trimmed?.isEmpty == false) ? trimmed : nil,
            lat: rawCoordinate?.latitude,
            lon: rawCoordinate?.longitude,
            at: Date(),
            sessionId: currentSessionId
        ))
        saveLooseSpots()
    }

    /// `protectBefore` shields history: a GROUP's "current spot cleared"
    /// broadcast must only drop the follower's spot for the ongoing moment
    /// — never a spot from before the group existed (the host's adopted
    /// pre-game, or the member's own earlier night). Without the shield, a
    /// stale "current window" reaching back past old checkouts deleted the
    /// group's Partaj-style pre-game from followers' journeys.
    func clearCurrentLooseSpot(protectBefore: Date? = nil) {
        let start = currentWindowStart
        looseSpots.removeAll {
            $0.at >= start && ($0.at >= (protectBefore ?? .distantPast))
        }
        saveLooseSpots()
    }

    /// Adopt a loose spot broadcast by the group — inserted VERBATIM so its
    /// original timestamp files it onto the right leg (a group pre-game
    /// spot stays pre-game, not "between bars"). Replaces whatever spot the
    /// follower had in that same window.
    func adoptLooseSpot(_ spot: LooseSpot) {
        // The window containing spot.at is bounded by the bar checkout just
        // before it and the next bar arrival after it.
        let windowStart = stops
            .filter { $0.kind == .bar }
            .compactMap(\.departedAt)
            .filter { $0 <= spot.at }
            .max() ?? .distantPast
        let windowEnd = stops
            .filter { $0.kind == .bar && $0.arrivedAt > spot.at }
            .map(\.arrivedAt)
            .min() ?? .distantFuture
        looseSpots.removeAll {
            $0.id == spot.id || ($0.at >= windowStart && $0.at < windowEnd)
        }
        var stamped = spot
        stamped.sessionId = currentSessionId
        looseSpots.append(stamped)
        saveLooseSpots()
    }

    /// Set/replace the PRE-GAME spot specifically — used to add a location
    /// to pre-game after you've already moved on to a bar. Stamped just
    /// before the first check-in so it files into the pre-game leg.
    func setPreGameSpot(name: String?, rawCoordinate: CLLocationCoordinate2D?) {
        let cutoff = firstBarArrival
        looseSpots.removeAll { cutoff == nil || $0.at < cutoff! }
        let trimmed = name?.trimmingCharacters(in: .whitespaces)
        let at = cutoff.map { $0.addingTimeInterval(-1) } ?? Date()
        looseSpots.append(LooseSpot(
            id: UUID(),
            name: (trimmed?.isEmpty == false) ? trimmed : nil,
            lat: rawCoordinate?.latitude,
            lon: rawCoordinate?.longitude,
            at: at,
            sessionId: currentSessionId
        ))
        saveLooseSpots()
    }

    func clearPreGameSpot() {
        let cutoff = firstBarArrival
        looseSpots.removeAll { cutoff == nil || $0.at < cutoff! }
        saveLooseSpots()
    }

    /// Staging area for photos snapped during the night, before a recap
    /// (and its id) exists. At END time `RecapHistoryStore.adoptPhotos`
    /// moves these into the saved recap's own directory. Per-account, like
    /// the keys above.
    nonisolated let photosDirectory: URL

    init() {
        let ns = supabase.auth.currentUser?.id.uuidString.lowercased() ?? "anon"
        key = "sesh.nightJourney.v1.\(ns)"
        looseKey = "sesh.nightJourney.loose.v1.\(ns)"
        looseSpotsKey = "sesh.nightJourney.looseSpots.v1.\(ns)"
        preGameNoteKey = "sesh.nightJourney.preGameNote.v1.\(ns)"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        photosDirectory = docs.appendingPathComponent(
            "night-recaps/journey-photos-\(ns)", isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: photosDirectory, withIntermediateDirectories: true
        )
        migrateLegacySlotIfMine(ns: ns)
        load()
    }

    /// One-time adoption of the pre-namespace shared slot: if the legacy
    /// journey was last written by THIS account (its owner stamp), move its
    /// data + staged photos into the account's own namespace. Another
    /// account's legacy data is left untouched for its owner to adopt.
    private func migrateLegacySlotIfMine(ns: String) {
        let d = UserDefaults.standard
        guard d.string(forKey: "sesh.nightJourney.owner.v1") == ns else { return }
        let pairs = [
            ("sesh.nightJourney.v1", key),
            ("sesh.nightJourney.loose.v1", looseKey),
            ("sesh.nightJourney.looseSpots.v1", looseSpotsKey),
        ]
        for (old, new) in pairs {
            if d.object(forKey: new) == nil, let v = d.data(forKey: old) {
                d.set(v, forKey: new)
            }
            d.removeObject(forKey: old)
        }
        if let note = d.string(forKey: "sesh.nightJourney.preGameNote.v1") {
            if d.string(forKey: preGameNoteKey) == nil { d.set(note, forKey: preGameNoteKey) }
            d.removeObject(forKey: "sesh.nightJourney.preGameNote.v1")
        }
        d.removeObject(forKey: "sesh.nightJourney.owner.v1")
        let legacyDir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("night-recaps/journey-photos", isDirectory: true)
        if let files = try? FileManager.default.contentsOfDirectory(
            at: legacyDir, includingPropertiesForKeys: nil
        ) {
            for f in files {
                try? FileManager.default.moveItem(
                    at: f,
                    to: photosDirectory.appendingPathComponent(f.lastPathComponent)
                )
            }
        }
    }

    /// Attach a photo to a stop mid-night. Compressed and staged on disk;
    /// the filename rides on the stop straight into the recap later.
    func addPhoto(_ imageData: Data, toStop stopId: UUID) {
        guard let i = stops.firstIndex(where: { $0.id == stopId }),
              let jpeg = RecapPhotoUtil.compressedJPEG(imageData)
        else { return }
        let filename = "\(UUID().uuidString).jpg"
        do {
            try jpeg.write(to: photosDirectory.appendingPathComponent(filename), options: .atomic)
        } catch {
            return
        }
        stops[i].photoFilenames.append(filename)
        save()
    }

    func removePhoto(_ filename: String, fromStop stopId: UUID) {
        guard let i = stops.firstIndex(where: { $0.id == stopId }) else { return }
        try? FileManager.default.removeItem(
            at: photosDirectory.appendingPathComponent(filename)
        )
        stops[i].photoFilenames.removeAll { $0 == filename }
        save()
    }

    func photoURL(_ filename: String) -> URL {
        photosDirectory.appendingPathComponent(filename)
    }

    /// Photo taken while between stops (pre-game / transit / afters).
    /// Stamped with now; the recap files it onto the right leg later.
    func addLoosePhoto(_ imageData: Data, at date: Date = Date()) {
        guard let jpeg = RecapPhotoUtil.compressedJPEG(imageData) else { return }
        let filename = "\(UUID().uuidString).jpg"
        do {
            try jpeg.write(to: photosDirectory.appendingPathComponent(filename), options: .atomic)
        } catch {
            return
        }
        loosePhotos.append(LooseTake(filename: filename, takenAt: date))
        save()
    }

    func removeLoosePhoto(_ filename: String) {
        try? FileManager.default.removeItem(
            at: photosDirectory.appendingPathComponent(filename)
        )
        loosePhotos.removeAll { $0.filename == filename }
        save()
    }

    /// Sweep entries left behind by a previous night whose end never got
    /// captured on this device (ended-while-away, immediately resumed into
    /// a NEW session — the recap/clear for the old night is skipped, and
    /// its pre-game spot then haunted the next sesh). Anything older than
    /// 24h that also predates the current session can't belong to tonight.
    func purgeStale(before sessionStart: Date?) {
        let dayAgo = Date().addingTimeInterval(-24 * 3600)
        func isStale(_ at: Date) -> Bool {
            at < dayAgo && at < (sessionStart ?? Date())
        }

        for stop in stops where isStale(stop.arrivedAt) {
            for filename in stop.photoFilenames {
                try? FileManager.default.removeItem(
                    at: photosDirectory.appendingPathComponent(filename)
                )
            }
        }
        let staleStops = stops.contains { isStale($0.arrivedAt) }
        let staleSpots = looseSpots.contains { isStale($0.at) }
        let staleTakes = loosePhotos.contains { isStale($0.takenAt) }
        guard staleStops || staleSpots || staleTakes else { return }

        for take in loosePhotos where isStale(take.takenAt) {
            try? FileManager.default.removeItem(
                at: photosDirectory.appendingPathComponent(take.filename)
            )
        }
        stops.removeAll { isStale($0.arrivedAt) }
        looseSpots.removeAll { isStale($0.at) }
        loosePhotos.removeAll { isStale($0.takenAt) }
        save()
    }

    /// Record a check-in. Duplicates collapse while the user is still
    /// checked in at the same bar (launch-time re-validation re-sets
    /// currentVenue with the same venue — not a new stop, even if a food
    /// or puke marker landed in between). Returning to a bar AFTER
    /// checking out IS a new stop.
    func checkIn(_ venue: Venue, at date: Date = Date()) {
        // Same-name match too: a merged group-route row for this bar has a
        // different venueId but IS this arrival — don't double it.
        if let lastBar = stops.last(where: { $0.kind == .bar }),
           lastBar.venueId == venue.id || lastBar.name == venue.name,
           lastBar.departedAt == nil {
            return
        }
        // Arriving somewhere new means the previous bar is over — stamp it.
        // A bar left open forever swallowed everything that happened after
        // it (its drink window ran to the next arrival, and loose spots
        // inside it — like a group pre-game adopted mid-night — rendered
        // NOWHERE: not a page, not a leg, not in the recap).
        if let open = stops.lastIndex(where: { $0.kind == .bar && $0.departedAt == nil }) {
            stops[open].departedAt = date
        }
        stops.append(SeshStop(
            id: UUID(),
            venueId: venue.id,
            kind: .bar,
            name: venue.name,
            lat: venue.lat,
            lon: venue.lon,
            arrivedAt: date,
            sessionId: currentSessionId
        ))
        save()
    }

    /// Record leaving the current bar (the venue sheet's CHECK OUT, or
    /// the chip being cleared). Stamps the open bar stop and drops a
    /// "between bars" stop so the in-between moment is a real, navigable,
    /// reorderable page (photos attach to it) — not just something that
    /// appears in the recap. `coordinate` (when location is on) puts it on
    /// the map. No-op when there's no bar to leave.
    /// `recordBetween: false` = the night is OVER (END-triggered checkout):
    /// just stamp the departure — a post-sesh "between bars" page would be
    /// a phantom stop on a night that has already ended.
    func checkOut(
        at date: Date = Date(),
        coordinate: CLLocationCoordinate2D? = nil,
        recordBetween: Bool = true
    ) {
        guard let i = stops.lastIndex(where: { $0.kind == .bar && $0.departedAt == nil })
        else { return }
        stops[i].departedAt = date
        if recordBetween {
            stops.append(SeshStop(
                id: UUID(),
                venueId: UUID(),
                kind: .between,
                name: "Between bars",
                lat: coordinate?.latitude,
                lon: coordinate?.longitude,
                arrivedAt: date,
                sessionId: currentSessionId
            ))
        }
        save()
    }

    /// Drop a food / puke marker at the current moment. Markers are
    /// photo-carrying cards on the recap, not drink windows. `named`
    /// overrides the default title — used to pin a puke break on a
    /// specific group member ("Alex's puke break"). `coordinate` (when
    /// location is on) places it on the recap map.
    func addMarker(
        kind: JourneyStopKind,
        named name: String? = nil,
        at date: Date = Date(),
        coordinate: CLLocationCoordinate2D? = nil
    ) {
        guard kind != .bar else { return }
        stops.append(SeshStop(
            id: UUID(),
            venueId: UUID(),   // markers aren't venues; unique id keeps dedupe away
            kind: kind,
            name: name ?? (kind == .food ? "Food stop" : "Puke break"),
            lat: coordinate?.latitude,
            lon: coordinate?.longitude,
            arrivedAt: date,
            sessionId: currentSessionId
        ))
        save()
    }

    /// Remove a marker (mis-taps happen at 1am). Bar stops are derived
    /// from check-ins and stay.
    func removeMarker(_ stopId: UUID) {
        guard let i = stops.firstIndex(where: { $0.id == stopId }),
              stops[i].kind != .bar else { return }
        removeStopAt(i)
    }

    /// Remove ANY stop — including a bar check-in added by mistake. Drops
    /// its photos and the stop itself. The caller is responsible for any
    /// related check-out (clearing `currentVenue`) when removing the bar
    /// the user is currently at.
    func removeStop(_ stopId: UUID) {
        guard let i = stops.firstIndex(where: { $0.id == stopId }) else { return }
        removeStopAt(i)
    }

    /// Add (or clear) a location on a non-bar stop — between-bars, food, or
    /// puke — after the fact. Bars get their location from check-in.
    func setStopLocation(_ stopId: UUID, coordinate: CLLocationCoordinate2D?) {
        guard let i = stops.firstIndex(where: { $0.id == stopId }), stops[i].kind != .bar
        else { return }
        stops[i].lat = coordinate?.latitude
        stops[i].lon = coordinate?.longitude
        save()
    }

    /// Set (or clear) the user's comment on a stop, typed during the night.
    func setNote(_ stopId: UUID, _ note: String) {
        guard let i = stops.firstIndex(where: { $0.id == stopId }) else { return }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        stops[i].note = trimmed.isEmpty ? nil : trimmed
        save()
    }

    /// Swap a stop with its neighbour in the journey order. Purely a
    /// display reorder — timestamps (and therefore each bar's drinks/BAC)
    /// are untouched; only the sequence shown on the pager + recap changes.
    func moveStop(_ stopId: UUID, by offset: Int) {
        guard let i = stops.firstIndex(where: { $0.id == stopId }) else { return }
        let j = i + offset
        guard j >= 0, j < stops.count else { return }
        stops.swapAt(i, j)
        save()
    }

    private func removeStopAt(_ i: Int) {
        for filename in stops[i].photoFilenames {
            try? FileManager.default.removeItem(
                at: photosDirectory.appendingPathComponent(filename)
            )
        }
        stops.remove(at: i)
        save()
    }

    /// Set (or clear) the pre-game comment.
    func setPreGameNote(_ note: String) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        preGameNote = trimmed.isEmpty ? nil : trimmed
        if let preGameNote {
            UserDefaults.standard.set(preGameNote, forKey: preGameNoteKey)
        } else {
            UserDefaults.standard.removeObject(forKey: preGameNoteKey)
        }
    }

    func clear() {
        stops = []
        loosePhotos = []
        looseSpots = []
        preGameNote = nil
        UserDefaults.standard.removeObject(forKey: preGameNoteKey)
        save()
        saveLooseSpots()
        // Wipe any staged photos that never made it into a recap (the
        // adopted ones were already MOVED out, so this only catches
        // leftovers from abandoned seshs).
        try? FileManager.default.removeItem(at: photosDirectory)
        try? FileManager.default.createDirectory(
            at: photosDirectory, withIntermediateDirectories: true
        )
    }

    private func load() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let data = UserDefaults.standard.data(forKey: key) {
            stops = (try? dec.decode([SeshStop].self, from: data)) ?? []
        }
        if let data = UserDefaults.standard.data(forKey: looseKey) {
            loosePhotos = (try? dec.decode([LooseTake].self, from: data)) ?? []
        }
        if let data = UserDefaults.standard.data(forKey: looseSpotsKey) {
            looseSpots = (try? dec.decode([LooseSpot].self, from: data)) ?? []
        }
        preGameNote = UserDefaults.standard.string(forKey: preGameNoteKey)
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(stops) {
            UserDefaults.standard.set(data, forKey: key)
        }
        if let data = try? enc.encode(loosePhotos) {
            UserDefaults.standard.set(data, forKey: looseKey)
        }
    }

    private func saveLooseSpots() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(looseSpots) {
            UserDefaults.standard.set(data, forKey: looseSpotsKey)
        }
    }
}

// MARK: - Recap model

/// One timestamped drink event attributed to the user — already reduced
/// to "grams of ethanol to me" so solo drinks and group shared-round
/// shares flow through the same math.
struct RecapEvent: Codable, Equatable {
    let when: Date
    let grams: Double
    let name: String
}

/// What a recap leg IS — drives the badge, name, and styling on its card.
enum RecapStopKind: String, Codable {
    /// Drinks logged before the first check-in.
    case preGame
    /// A bar the user checked into.
    case bar
    /// Drinks logged between checking out of one bar and into the next.
    case refuel
    /// Drinks logged after checking out of the final bar.
    case afters
    /// Self-reported food marker.
    case food
    /// Self-reported puke marker.
    case puke
}

/// A leg of the night: one venue (or a synthetic leg / marker) plus
/// everything that happened while the user was there.
struct RecapStop: Codable, Identifiable {
    let id: UUID
    let kind: RecapStopKind
    /// nil for synthetic legs and markers — card but no map pin.
    let lat: Double?
    let lon: Double?
    let name: String
    let arrivedAt: Date
    let departedAt: Date
    let drinks: [RecapEvent]
    /// "2× Large beer · 1× Tequila" — grouped, order of first appearance.
    let drinkSummary: String
    let bacOnArrival: Double
    let bacOnDeparture: Double
    let isPeak: Bool
    /// Filenames (relative to the recap's photo directory) of photos the
    /// user attached to this stop. Mutated via RecapHistoryStore.
    var photoFilenames: [String] = []
    /// The user's comment about this stop, typed during the live sesh.
    var note: String? = nil
    /// GROUP recaps only: every member's BAC + drink count when the group
    /// left this spot, drunkest first. Nil on personal recaps.
    var squad: [SquadStopStat]? = nil

    var coordinate: CLLocationCoordinate2D? {
        guard let lat, let lon else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    // Tolerant decode — recaps saved before `kind` existed default to
    // .bar (their "Warm-up" legs map to .preGame by name).
    enum CodingKeys: String, CodingKey {
        case id, kind, lat, lon, name, arrivedAt, departedAt, drinks
        case drinkSummary, bacOnArrival, bacOnDeparture, isPeak, photoFilenames, note, squad
    }

    init(
        id: UUID, kind: RecapStopKind, lat: Double?, lon: Double?, name: String,
        arrivedAt: Date, departedAt: Date, drinks: [RecapEvent], drinkSummary: String,
        bacOnArrival: Double, bacOnDeparture: Double, isPeak: Bool,
        note: String? = nil, photoFilenames: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.lat = lat
        self.lon = lon
        self.name = name
        self.arrivedAt = arrivedAt
        self.departedAt = departedAt
        self.drinks = drinks
        self.drinkSummary = drinkSummary
        self.bacOnArrival = bacOnArrival
        self.bacOnDeparture = bacOnDeparture
        self.isPeak = isPeak
        self.note = note
        self.photoFilenames = photoFilenames
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        lat = try c.decodeIfPresent(Double.self, forKey: .lat)
        lon = try c.decodeIfPresent(Double.self, forKey: .lon)
        name = try c.decode(String.self, forKey: .name)
        kind = (try? c.decodeIfPresent(RecapStopKind.self, forKey: .kind))
            ?? (name == "Warm-up" || name == "Pre-game" ? .preGame : .bar)
        arrivedAt = try c.decode(Date.self, forKey: .arrivedAt)
        departedAt = try c.decode(Date.self, forKey: .departedAt)
        drinks = try c.decode([RecapEvent].self, forKey: .drinks)
        drinkSummary = try c.decode(String.self, forKey: .drinkSummary)
        bacOnArrival = try c.decode(Double.self, forKey: .bacOnArrival)
        bacOnDeparture = try c.decode(Double.self, forKey: .bacOnDeparture)
        isPeak = try c.decode(Bool.self, forKey: .isPeak)
        note = try? c.decodeIfPresent(String.self, forKey: .note)
        photoFilenames = (try? c.decodeIfPresent([String].self, forKey: .photoFilenames)) ?? []
        squad = try? c.decodeIfPresent([SquadStopStat].self, forKey: .squad)
    }
}

/// One member's line on the group recap leaderboard.
struct GroupMemberStat: Codable, Hashable, Identifiable {
    let name: String
    let drinkCount: Int
    let peakBAC: Double
    let isMe: Bool
    var id: String { name }
}

/// One member's state AT a specific stop of a group recap: BAC when the
/// group left the spot + how many drinks they'd had by then. Sorted
/// drunkest-first, so `first` wears the crown.
struct SquadStopStat: Codable, Hashable, Identifiable {
    let name: String
    let bac: Double
    let drinks: Int
    let isMe: Bool
    var id: String { name }
}

/// The whole computed story, built once at END time. Codable so it can
/// be saved and replayed from "Past nights".
struct NightRecap: Codable, Identifiable {
    let id: UUID
    var stops: [RecapStop]
    let startedAt: Date
    let endedAt: Date
    let totalDrinks: Int
    let peakBAC: Double
    let peakAt: Date
    /// Non-nil when this was a group sesh — the squad's per-member stats,
    /// drunkest first. Drives the group section on the overview.
    var groupLeaderboard: [GroupMemberStat]? = nil
    /// Straight-line meters between consecutive located stops. 0 when
    /// fewer than two stops had coordinates.
    let crawlMeters: Double
    /// TRUE for the squad recap built from a group sesh (squad schnaps +
    /// per-stop member stats). Group recaps can be saved but never posted.
    /// Optional so recaps saved before this existed still decode (nil = no).
    var isGroup: Bool? = nil

    var isGroupRecap: Bool { isGroup ?? false }

    var locatedStops: [RecapStop] { stops.filter { $0.coordinate != nil } }
    var hasMap: Bool { !locatedStops.isEmpty }

    /// Build the recap from raw inputs. Returns nil when there's nothing
    /// to tell (no drinks at all) — caller falls back to a plain END.
    ///
    /// `journeyStops` may contain check-ins from before the sesh (the
    /// store records whenever the user checks in); anything more than 90
    /// minutes before the first event is treated as stale and dropped.
    ///
    /// `bumpPerGram` is 100 / (weightKg × 1000 × r) — the BAC% added per
    /// gram of ethanol for this user's body. Matches `SessionService.bac`
    /// / `liveBAC` exactly.
    static func build(
        journeyStops: [SeshStop],
        events rawEvents: [RecapEvent],
        bumpPerGram: Double,
        loosePhotos: [LooseTake] = [],
        looseSpots: [LooseSpot] = [],
        preGameNote: String? = nil,
        endedAt: Date = Date()
    ) -> NightRecap? {
        let events = rawEvents.sorted { $0.when < $1.when }
        guard bumpPerGram > 0 else { return nil }
        // A drink-free night can still be a story (check-ins, photos,
        // spots) — ending it used to silently produce NOTHING, stranding
        // the photos. Anchor the grace window on the earliest activity
        // instead of the first drink; bail only when there's truly nothing.
        //
        // When drinks DO exist, the anchor still reaches back to journey
        // activity from the same night (within 12h of the first drink).
        // Anchoring on the first drink alone silently dropped any pre-game
        // spot or check-in more than 90 minutes older than it — the classic
        // event pre-game, marked hours before the first pour, vanished from
        // the personal recap while the group recap (built from the server
        // route, which has no grace filter) kept it.
        let activity = journeyStops.map(\.arrivedAt)
            + loosePhotos.map(\.takenAt)
            + looseSpots.map(\.at)
        let anchor: Date
        if let first = events.first {
            let sameNight = first.when.addingTimeInterval(-12 * 3600)
            anchor = activity
                .filter { $0 >= sameNight && $0 <= first.when }
                .min() ?? first.when
        } else {
            guard let earliest = activity.min() else { return nil }
            anchor = earliest
        }

        let graceStart = anchor.addingTimeInterval(-90 * 60)
        // Kept in JOURNEY (display) order — the user can reorder stops, and
        // the recap cards/map follow that order. Drink windows below are
        // computed from a time-sorted copy so each bar keeps its own drinks
        // regardless of where it's been moved.
        let nightStops = journeyStops
            .filter { $0.arrivedAt >= graceStart && $0.arrivedAt <= endedAt }
        let barsByTime = nightStops
            .filter { $0.kind == .bar }
            .sorted { $0.arrivedAt < $1.arrivedAt }
        let looseTakes = loosePhotos
            .filter { $0.takenAt >= graceStart && $0.takenAt <= endedAt }
            .sorted { $0.takenAt < $1.takenAt }
        let nightSpots = looseSpots
            .filter { $0.at >= graceStart && $0.at <= endedAt }
            .sorted { $0.at < $1.at }

        // The night starts at the earliest thing that happened — drink,
        // check-in, photo, OR a marked spot. Without the spot here, a
        // location set before the first drink would fall outside every
        // window and silently vanish from the recap.
        let startedAt = min(
            anchor,
            barsByTime.first?.arrivedAt ?? anchor,
            looseTakes.first?.takenAt ?? anchor,
            nightSpots.first?.at ?? anchor
        )

        // BAC at an arbitrary time + the night's peak. Peak can only occur
        // immediately after a drink lands, so scanning event times is exact.
        func bac(at when: Date) -> Double {
            var bac = 0.0
            var last: Date? = nil
            for e in events where e.when <= when {
                if let l = last { bac = max(0, bac - 0.015 * (e.when.timeIntervalSince(l) / 3600)) }
                bac += e.grams * bumpPerGram
                last = e.when
            }
            if let l = last { bac = max(0, bac - 0.015 * (when.timeIntervalSince(l) / 3600)) }
            return bac
        }
        var peakBAC = 0.0
        var peakAt = anchor
        for e in events {
            let v = bac(at: e.when)
            if v > peakBAC { peakBAC = v; peakAt = e.when }
        }

        // ---- Carve the night into legs.
        //
        // Bars open drink-attribution windows: arrival → checkout (or the
        // next bar's arrival, or END, whichever lands first). The spaces
        // around those windows become narrative legs when drinks landed
        // in them: before the first bar = PRE-GAME, between two bars =
        // REFUEL, after the final checkout = AFTERS. Food/puke markers
        // are instants woven in chronologically — photos, no window.
        struct Leg {
            let kind: RecapStopKind
            let stop: SeshStop?
            let name: String
            let from: Date
            let to: Date
            let isWindow: Bool   // false for instant markers
            var lat: Double? = nil   // explicit coord (pre-game spot)
            var lon: Double? = nil
        }
        var legs: [Leg] = []

        // The latest loose spot whose timestamp lands in a window — its
        // location + name decorate that narrative leg. The final window is
        // inclusive of `to` so a spot marked at the very end still lands.
        func spotIn(_ from: Date, _ to: Date) -> LooseSpot? {
            nightSpots.last { $0.at >= from && $0.at <= to }
        }
        // A gap becomes a leg if it has anything to show — a drink, a
        // loose photo, OR a marked location.
        func hasContent(from: Date, to: Date) -> Bool {
            events.contains(where: { $0.when >= from && $0.when < to })
                || looseTakes.contains(where: { $0.takenAt >= from && $0.takenAt < to })
                || spotIn(from, to) != nil
        }
        // Next bar AFTER this one IN TIME — windows always follow the
        // clock, so a bar keeps its own drinks even if it's been moved.
        func nextBarArrival(after bar: SeshStop) -> Date? {
            barsByTime.first { $0.arrivedAt > bar.arrivedAt }?.arrivedAt
        }

        // Leading leg: pre-game (before the earliest bar by time), or — if
        // no bars at all — a single "the night" card covering everything.
        if let firstBar = barsByTime.first {
            if hasContent(from: startedAt, to: firstBar.arrivedAt) {
                let spot = spotIn(startedAt, firstBar.arrivedAt)
                legs.append(Leg(
                    kind: .preGame, stop: nil,
                    name: spot?.name ?? "Pre-game",
                    from: startedAt, to: firstBar.arrivedAt, isWindow: true,
                    lat: spot?.lat, lon: spot?.lon
                ))
            }
        } else {
            let spot = spotIn(startedAt, endedAt)
            legs.append(Leg(
                kind: .preGame, stop: nil,
                name: spot?.name ?? "The night",
                from: startedAt, to: endedAt, isWindow: true,
                lat: spot?.lat, lon: spot?.lon
            ))
        }
        // Walk stops in DISPLAY order. Bars carry a time-computed window;
        // `.between` stops become refuel/afters legs (their own photos +
        // location, drinks from the gap that follows); food/puke are
        // instants.
        for s in nightStops {
            switch s.kind {
            case .bar:
                let nextArrival = nextBarArrival(after: s)
                let windowEnd = min(s.departedAt ?? endedAt, nextArrival ?? endedAt, endedAt)
                legs.append(Leg(
                    kind: .bar, stop: s, name: s.name,
                    from: s.arrivedAt, to: windowEnd, isWindow: true
                ))
            case .between:
                // Gap runs from checkout to the next bar (by time), or END.
                let nextArrival = barsByTime.first { $0.arrivedAt > s.arrivedAt }?.arrivedAt
                let gapEnd = max(nextArrival ?? endedAt, s.arrivedAt)
                let isLast = nextArrival == nil
                // Keep it only if something actually happened — a drink or
                // its own photos. An auto-captured coordinate alone (just a
                // checkout) isn't worth a card.
                if hasContent(from: s.arrivedAt, to: gapEnd) || !s.photoFilenames.isEmpty {
                    legs.append(Leg(
                        kind: isLast ? .afters : .refuel,
                        stop: s,
                        name: isLast ? "Afters" : "Refuel break",
                        from: s.arrivedAt, to: gapEnd, isWindow: true
                    ))
                }
            case .food, .puke:
                legs.append(Leg(
                    kind: s.kind == .food ? .food : .puke,
                    stop: s, name: s.name,
                    from: s.arrivedAt, to: s.arrivedAt, isWindow: false
                ))
            }
        }
        // No time-sort — assembly order IS the display order the user set.

        let stops: [RecapStop] = legs.map { leg in
            let here = leg.isWindow
                ? events.filter { $0.when >= leg.from && $0.when < leg.to }
                : []
            // Grouped summary, order of first appearance.
            var order: [String] = []
            var counts: [String: Int] = [:]
            for e in here {
                if counts[e.name] == nil { order.append(e.name) }
                counts[e.name, default: 0] += 1
            }
            let summary: String
            switch leg.kind {
            case .food:
                summary = "Something to soak it up. Smart."
            case .puke:
                summary = "Tactical reset. Respect."
            default:
                let joined = order
                    .map { "\(counts[$0] ?? 0)× \($0)" }
                    .joined(separator: " · ")
                summary = joined.isEmpty ? "No drinks logged here" : joined
            }
            // Stop-attached photos + any loose snaps whose timestamp falls
            // inside this leg's window (pre-game / refuel / afters pics).
            var photos = leg.stop?.photoFilenames ?? []
            if leg.isWindow {
                photos += looseTakes
                    .filter { $0.takenAt >= leg.from && $0.takenAt < leg.to }
                    .map(\.filename)
            }
            return RecapStop(
                id: UUID(),
                kind: leg.kind,
                lat: leg.stop?.lat ?? leg.lat,
                lon: leg.stop?.lon ?? leg.lon,
                name: leg.name,
                arrivedAt: leg.from,
                departedAt: leg.to,
                drinks: here,
                drinkSummary: summary,
                bacOnArrival: bac(at: leg.from),
                bacOnDeparture: bac(at: leg.to),
                isPeak: leg.isWindow && peakAt >= leg.from && peakAt < leg.to,
                note: leg.kind == .preGame ? preGameNote : leg.stop?.note,
                photoFilenames: photos
            )
        }

        // Crawl distance: straight-line between consecutive located stops.
        var meters = 0.0
        let coords = stops.compactMap { $0.coordinate }
        for i in 1..<max(coords.count, 1) {
            let a = CLLocation(latitude: coords[i - 1].latitude, longitude: coords[i - 1].longitude)
            let b = CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude)
            meters += b.distance(from: a)
        }

        return NightRecap(
            id: UUID(),
            stops: stops,
            startedAt: startedAt,
            endedAt: endedAt,
            totalDrinks: events.count,
            peakBAC: peakBAC,
            peakAt: peakAt,
            crawlMeters: meters
        )
    }
}

// MARK: - History store

/// Disk-backed archive of past nights. One JSON file per recap in
/// Documents/night-recaps, plus a photo directory per recap. Local-only
/// by design — a night out is personal data and stays on-device.
@MainActor
final class RecapHistoryStore: ObservableObject {
    /// Newest first.
    @Published private(set) var recaps: [NightRecap] = []

    /// Recap ids the user has posted to their friends timeline (per-user,
    /// persisted in UserDefaults). Drives the "Posted" vs "Post" UI.
    @Published private(set) var postedIds: Set<UUID> = []
    /// Recap ids the user keeps in "Past nights". A recap can be a post, a
    /// past night, both, or (transiently) just on disk. Posting no longer
    /// auto-adds to past nights — archiving (or saving at END) does.
    @Published private(set) var pastNightIds: Set<UUID> = []

    /// Recaps shown in the Past Nights list (newest first).
    var pastNights: [NightRecap] { recaps.filter { pastNightIds.contains($0.id) } }

    private let dir: URL
    private let enc: JSONEncoder
    private let dec: JSONDecoder
    private let postedKey: String
    private let pastNightKey: String

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // Scope saved nights per signed-in user, so accounts sharing a device
        // never see each other's recaps. Signed-out falls back to a throwaway
        // bucket (there's no recap UI while signed out anyway). Recaps written
        // before this scoping lived at the un-scoped root and are intentionally
        // left there — they can't be attributed to a specific account.
        let uid = supabase.auth.currentUser?.id.uuidString.lowercased() ?? "anon"
        dir = docs
            .appendingPathComponent("night-recaps", isDirectory: true)
            .appendingPathComponent(uid, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        postedKey = "posted-recaps-\(uid)"
        pastNightKey = "past-night-recaps-\(uid)"
        if let raw = UserDefaults.standard.stringArray(forKey: postedKey) {
            postedIds = Set(raw.compactMap(UUID.init))
        }
        load()
        // Migration: before past-night tracking existed, every saved recap
        // appeared in Past Nights. Seed the set with all current recaps EXCEPT
        // posted ones (posted recaps now live as posts, not past nights).
        if let raw = UserDefaults.standard.stringArray(forKey: pastNightKey) {
            pastNightIds = Set(raw.compactMap(UUID.init))
        } else {
            pastNightIds = Set(recaps.map(\.id)).subtracting(postedIds)
            persistPastNights()
        }
    }

    func isPosted(_ id: UUID) -> Bool { postedIds.contains(id) }
    func isPastNight(_ id: UUID) -> Bool { pastNightIds.contains(id) }
    func localRecap(for id: UUID) -> NightRecap? { recaps.first { $0.id == id } }

    private func persistPosted() {
        UserDefaults.standard.set(postedIds.map(\.uuidString), forKey: postedKey)
    }
    private func persistPastNights() {
        UserDefaults.standard.set(pastNightIds.map(\.uuidString), forKey: pastNightKey)
    }

    /// Record that a recap has been posted to the timeline (does NOT add it
    /// to Past Nights — posting and saving are independent).
    func markPosted(_ id: UUID) {
        postedIds.insert(id)
        persistPosted()
    }

    /// The post was deleted — drop the posted flag, and clean up the on-disk
    /// recap if it isn't also kept as a past night.
    func unmarkPosted(_ id: UUID) {
        postedIds.remove(id)
        persistPosted()
        if !pastNightIds.contains(id) { deleteFromDisk(id) }
    }

    /// Keep a recap in Past Nights (archive). Ensures it's on disk.
    func archive(_ recap: NightRecap) {
        if !recaps.contains(where: { $0.id == recap.id }) { save(recap) }
        pastNightIds.insert(recap.id)
        persistPastNights()
    }

    /// Remove a recap from Past Nights. Deletes the on-disk recap only if it
    /// isn't also a post (the post lives on independently).
    func removeFromPastNights(_ id: UUID) {
        pastNightIds.remove(id)
        persistPastNights()
        if !postedIds.contains(id) { deleteFromDisk(id) }
    }

    /// Insert or update a recap on disk and in memory.
    func save(_ recap: NightRecap) {
        guard let data = try? enc.encode(recap) else { return }
        try? data.write(to: fileURL(recap.id), options: .atomic)
        if let i = recaps.firstIndex(where: { $0.id == recap.id }) {
            recaps[i] = recap
        } else {
            recaps.insert(recap, at: 0)
            recaps.sort { $0.startedAt > $1.startedAt }
        }
    }

    private func deleteFromDisk(_ id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(id))
        try? FileManager.default.removeItem(at: photoDir(id))
        recaps.removeAll { $0.id == id }
    }

    /// Full delete: wipe the recap from disk and from both lists.
    func delete(_ recap: NightRecap) {
        pastNightIds.remove(recap.id); persistPastNights()
        postedIds.remove(recap.id); persistPosted()
        deleteFromDisk(recap.id)
    }

    /// Attach a photo to a stop: compress, write to the recap's photo
    /// directory, record the filename on the stop, persist, and return
    /// the updated recap (nil if anything failed).
    func addPhoto(_ imageData: Data, toStop stopId: UUID, in recapId: UUID) -> NightRecap? {
        guard var recap = recaps.first(where: { $0.id == recapId }),
              let si = recap.stops.firstIndex(where: { $0.id == stopId }),
              let jpeg = RecapPhotoUtil.compressedJPEG(imageData)
        else { return nil }

        let photos = photoDir(recapId)
        try? FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let filename = "\(UUID().uuidString).jpg"
        do {
            try jpeg.write(to: photos.appendingPathComponent(filename), options: .atomic)
        } catch {
            return nil
        }
        recap.stops[si].photoFilenames.append(filename)
        save(recap)
        return recap
    }

    func removePhoto(_ filename: String, fromStop stopId: UUID, in recapId: UUID) -> NightRecap? {
        guard var recap = recaps.first(where: { $0.id == recapId }),
              let si = recap.stops.firstIndex(where: { $0.id == stopId })
        else { return nil }
        try? FileManager.default.removeItem(at: photoDir(recapId).appendingPathComponent(filename))
        recap.stops[si].photoFilenames.removeAll { $0 == filename }
        save(recap)
        return recap
    }

    func photoURL(_ filename: String, in recapId: UUID) -> URL {
        photoDir(recapId).appendingPathComponent(filename)
    }

    /// Move photos staged during the night (journey directory) into this
    /// recap's own photo directory. The filenames already ride on the
    /// recap's stops (the builder copied them from the journey), so a
    /// plain move keeps every reference valid. Call before/around save —
    /// missing files are skipped silently.
    func adoptPhotos(from stagingDir: URL, for recap: NightRecap, copying: Bool = false) {
        let dest = photoDir(recap.id)
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        for stop in recap.stops {
            for filename in stop.photoFilenames {
                let src = stagingDir.appendingPathComponent(filename)
                guard FileManager.default.fileExists(atPath: src.path) else { continue }
                // `copying` = the journey continues (mid-night recap from a
                // group switch) — the staged file must survive for the
                // final recap's own adoption.
                if copying {
                    try? FileManager.default.copyItem(
                        at: src,
                        to: dest.appendingPathComponent(filename)
                    )
                } else {
                    try? FileManager.default.moveItem(
                        at: src,
                        to: dest.appendingPathComponent(filename)
                    )
                }
            }
        }
    }

    // ---- internals

    private func fileURL(_ id: UUID) -> URL {
        dir.appendingPathComponent("\(id.uuidString).json")
    }

    private func photoDir(_ id: UUID) -> URL {
        dir.appendingPathComponent("\(id.uuidString)-photos", isDirectory: true)
    }

    private func load() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        )) ?? []
        recaps = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> NightRecap? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? dec.decode(NightRecap.self, from: data)
            }
            .sorted { $0.startedAt > $1.startedAt }
    }
}

// MARK: - Photo utilities

/// Shared photo helpers — compression for writes, downsampled loading
/// for display. Loading goes through ImageIO so thumbnails never decode
/// the full-resolution JPEG on the main thread (that was the source of
/// hitching during the recap's camera flights).
enum RecapPhotoUtil {
    /// Downscale + JPEG so a night of photos doesn't balloon the app's
    /// container. ~1600px on the long edge keeps full-screen quality.
    static func compressedJPEG(
        _ data: Data,
        maxDimension: CGFloat = 1600,
        quality: CGFloat = 0.78
    ) -> Data? {
        guard let img = UIImage(data: data) else { return nil }
        let longest = max(img.size.width, img.size.height)
        guard longest > maxDimension else {
            return img.jpegData(compressionQuality: quality)
        }
        let scale = maxDimension / longest
        let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: size).image { _ in
            img.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: quality)
    }

    /// Load a downsampled image off the main thread. ImageIO decodes
    /// straight to the target size — tiny memory + no UI hitch.
    static func loadImage(at url: URL, maxDimension: CGFloat) async -> UIImage? {
        let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
            let opts = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDimension
            ] as CFDictionary
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts) {
                return UIImage(cgImage: cg)
            }
            // Fallback: plain decode — slower, but a photo should never
            // silently render as an empty box.
            return UIImage(contentsOfFile: url.path)
        }
        return await task.value
    }
}

// MARK: - Camera capture ("Schnap a pic")

/// Thin UIImagePickerController wrapper for in-the-moment camera shots.
/// Returns JPEG data via the callback; the presenter decides which stop
/// it lands on.
struct CameraCaptureView: UIViewControllerRepresentable {
    let onCapture: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraCaptureView
        init(_ parent: CameraCaptureView) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage,
               let data = image.jpegData(compressionQuality: 0.9) {
                parent.onCapture(data)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

/// Identifiable wrapper so a camera capture can be presented per-stop
/// via fullScreenCover(item:).
struct CameraTarget: Identifiable {
    let id: UUID   // the stop id the shot lands on
}

// MARK: - Sesh Cam
//
// The branded camera — a full-screen AVFoundation viewfinder with the
// app's own chrome (whiskey shutter ring, flash + flip pills, SESH CAM
// wordmark) instead of the stock system picker. Same contract as
// CameraCaptureView: presents full screen, calls back with JPEG data.

@MainActor
final class SeshCameraController: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var position: AVCaptureDevice.Position = .back
    @Published var flashOn = false
    @Published var denied = false
    private var completion: ((Data) -> Void)?

    func start() async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        guard granted else { denied = true; return }
        configure()
        let s = session
        Task.detached { s.startRunning() }
    }

    func stop() {
        let s = session
        Task.detached { s.stopRunning() }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .photo
        session.inputs.forEach(session.removeInput)
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }
        if !session.outputs.contains(where: { $0 === output }), session.canAddOutput(output) {
            session.addOutput(output)
        }
        // Selfies: capture exactly what the (mirrored) preview shows —
        // an unmirrored front-camera photo reads as a surprise flip.
        if let conn = output.connection(with: .video), conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = (position == .front)
        }
        session.commitConfiguration()
    }

    func flip() {
        position = position == .back ? .front : .back
        configure()
    }

    func capture(_ done: @escaping (Data) -> Void) {
        completion = done
        let settings = AVCapturePhotoSettings()
        if output.supportedFlashModes.contains(flashOn ? .on : .off) {
            settings.flashMode = flashOn ? .on : .off
        }
        output.capturePhoto(with: settings, delegate: self)
    }

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        Task { @MainActor in
            self.completion?(data)
            self.completion = nil
        }
    }
}

private struct SeshCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.videoPreviewLayer.session = session
        v.videoPreviewLayer.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

struct SeshCameraView: View {
    let onCapture: (Data) -> Void
    /// false = the PARENT owns navigation (e.g. the story flow swaps to
    /// the composer in place); true = classic behavior, dismiss on shot.
    var autoDismiss: Bool = true
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = SeshCameraController()
    @State private var shutterFlash = false
    @State private var rollItem: PhotosPickerItem? = nil

    static var isAvailable: Bool { CameraCaptureView.isAvailable }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            SeshCameraPreview(session: camera.session)
                .ignoresSafeArea()

            // Capture blink.
            Color.white
                .ignoresSafeArea()
                .opacity(shutterFlash ? 0.7 : 0)
                .allowsHitTesting(false)

            VStack {
                HStack {
                    chromeButton("xmark") { dismiss() }
                    Spacer()
                    Text("SESH CAM")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .tracking(3.2)
                        .foregroundStyle(Color.cream.opacity(0.85))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Capsule().fill(Color.ink.opacity(0.55)))
                    Spacer()
                    chromeButton(camera.flashOn ? "bolt.fill" : "bolt.slash",
                                 tint: camera.flashOn ? .whiskey : .cream) {
                        camera.flashOn.toggle()
                    }
                }
                .padding(.horizontal, 18)
                // Clear of the clock/battery — the cover can extend under
                // the status bar on some presentation paths.
                .padding(.top, 58)

                Spacer()

                if camera.denied {
                    Text("Allow camera access in Settings to use the Sesh Cam.")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.cream)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    Spacer()
                }

                // Shutter row: camera roll on the left, whiskey-ring
                // shutter center, flip on the right (Snapchat layout).
                ZStack {
                    HStack {
                        PhotosPicker(selection: $rollItem, matching: .images) {
                            Image(systemName: "photo.on.rectangle")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(Color.cream)
                                .frame(width: 42, height: 42)
                                .background(Circle().fill(Color.ink.opacity(0.55)))
                                .overlay(Circle().strokeBorder(Color.cream.opacity(0.15), lineWidth: 1))
                        }
                        Spacer()
                        chromeButton("arrow.triangle.2.circlepath.camera") { camera.flip() }
                    }
                    .padding(.horizontal, 26)

                    Button {
                        shutterFlash = true
                        withAnimation(.easeOut(duration: 0.3)) { shutterFlash = false }
                        camera.capture { data in
                            onCapture(data)
                            if autoDismiss { dismiss() }
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .strokeBorder(Color.whiskey, lineWidth: 4)
                                .frame(width: 78, height: 78)
                                .shadow(color: Color.whiskey.opacity(0.55), radius: 14)
                            Circle()
                                .fill(Color.cream)
                                .frame(width: 60, height: 60)
                        }
                    }
                    .buttonStyle(PressScaleStyle())
                }
                .padding(.bottom, 34)
            }
        }
        // Picking from the roll delivers through the same capture path.
        .onChange(of: rollItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    onCapture(data)
                    if autoDismiss { dismiss() }
                }
                rollItem = nil
            }
        }
        .task { await camera.start() }
        .onDisappear { camera.stop() }
        .preferredColorScheme(.dark)
    }

    private func chromeButton(
        _ icon: String, tint: Color = .cream, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(Circle().fill(Color.ink.opacity(0.55)))
                .overlay(Circle().strokeBorder(Color.cream.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(PressScaleStyle())
    }
}

// MARK: - Lightbox

/// Which photos to show full-screen, and where to start.
struct LightboxContext: Identifiable {
    let id = UUID()
    let urls: [URL]
    let startIndex: Int
    /// Deletes the photo at the given index from its backing store. When
    /// set, the lightbox shows a trash button — the visible counterpart to
    /// the strips' (hard-to-discover) long-press remove.
    var onDelete: ((Int) -> Void)? = nil
}

/// Full-screen photo viewer — swipe between a stop's photos, tap X (or
/// swipe down) to leave; trash deletes the current photo when the context
/// allows it.
struct PhotoLightbox: View {
    let context: LightboxContext
    let onClose: () -> Void

    @State private var current: Int
    @State private var dragOffset: CGFloat = 0

    init(context: LightboxContext, onClose: @escaping () -> Void) {
        self.context = context
        self.onClose = onClose
        _current = State(initialValue: context.startIndex)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            TabView(selection: $current) {
                ForEach(Array(context.urls.enumerated()), id: \.offset) { i, url in
                    LightboxImage(url: url)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: context.urls.count > 1 ? .automatic : .never))

            HStack(spacing: 10) {
                if let onDelete = context.onDelete {
                    Button {
                        onDelete(current)
                        onClose()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.white)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(Color.white.opacity(0.15)))
                    }
                    .buttonStyle(PressScaleStyle())
                }
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.white.opacity(0.15)))
                }
                .buttonStyle(PressScaleStyle())
            }
            .padding(18)
        }
        // Drag down to close, IG/Snap style — follows the finger, lets
        // go past the threshold, springs back otherwise.
        .offset(y: dragOffset)
        .gesture(
            DragGesture(minimumDistance: 25)
                .onChanged { v in dragOffset = max(0, v.translation.height) }
                .onEnded { v in
                    if v.translation.height > 130 {
                        onClose()
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            dragOffset = 0
                        }
                    }
                }
        )
        .preferredColorScheme(.dark)
    }
}

private struct LightboxImage: View {
    let url: URL
    @State private var image: UIImage? = nil

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
                    .tint(Color.white.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            image = await RecapPhotoUtil.loadImage(at: url, maxDimension: 2400)
        }
    }
}

// MARK: - Photo strip pieces

/// One photo thumbnail, decoded async + downsampled so strips never
/// hitch the UI. Tap → lightbox (wired by the parent).
struct RecapPhotoThumb: View {
    let url: URL
    var size: CGFloat = 54

    @State private var image: UIImage? = nil

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.cream.opacity(0.06))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.cream.opacity(0.15), lineWidth: 1)
        )
        .task(id: url) {
            image = await RecapPhotoUtil.loadImage(at: url, maxDimension: size * 3)
        }
    }
}

/// Reusable horizontal strip: a stop's photos (tap → lightbox, long
/// press → remove) plus the two add buttons — camera ("SCHNAP A PIC")
/// and library.
struct StopPhotoStrip: View {
    let photoURLs: [URL]
    let onTapPhoto: (Int) -> Void
    let onDeletePhoto: (Int) -> Void
    let onSchnap: () -> Void
    let onLibrary: () -> Void
    /// When false, the SCHNAP/LIBRARY buttons are hidden — used on a
    /// historical page (e.g. pre-game after you've checked in) where a new
    /// photo would be mis-stamped into the wrong moment. View + delete
    /// stay available.
    var allowAdd: Bool = true

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(photoURLs.enumerated()), id: \.element) { i, url in
                    Button {
                        onTapPhoto(i)
                    } label: {
                        RecapPhotoThumb(url: url)
                    }
                    .buttonStyle(PressScaleStyle())
                    .contextMenu {
                        Button(role: .destructive) {
                            onDeletePhoto(i)
                        } label: {
                            Label("Remove photo", systemImage: "trash")
                        }
                    }
                }

                if allowAdd {
                    if CameraCaptureView.isAvailable {
                        addButton(icon: "camera.fill", label: "SCHNAP", action: onSchnap)
                    }
                    addButton(icon: "photo.on.rectangle", label: "LIBRARY", action: onLibrary)
                } else if photoURLs.isEmpty {
                    Text("No pre-game photos")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.4))
                        .frame(height: 54)
                }
            }
        }
    }

    private func addButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.whiskey)
                Text(label)
                    .font(.system(size: 7, weight: .black, design: .monospaced))
                    .tracking(1.0)
                    .foregroundStyle(Color.bronze)
            }
            .frame(width: 54, height: 54)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.cream.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        Color.whiskey.opacity(0.4),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            )
        }
        .buttonStyle(PressScaleStyle())
    }
}

// MARK: - Recap view

/// Full-screen, staged recap. Auto-plays through intro → each stop →
/// overview; the nav bar (chevrons + jump dots) lets the user scrub back
/// and forth freely — touching it pauses the auto-advance. Serves both
/// the live END flow and replaying a saved night (`isReplay`).
// MARK: - Posting to the friends timeline

/// Uploads a recap's photos to the `recap-photos` bucket and writes a
/// friends-only `posts` row (migration 020). The full recap (real BAC) is
/// always stored; the `include_bac` flag controls whether the feed RPCs
/// expose BAC to friends (stripped server-side at read time), so the author
/// can toggle it later. Friends can't read posts rows directly (author-only
/// SELECT, migration 025).
@MainActor
final class PostService: ObservableObject {
    static let shared = PostService()
    @Published var posting = false

    func createPost(_ recap: NightRecap, includeBAC: Bool, caption: String, history: RecapHistoryStore) async throws {
        guard let uid = supabase.auth.currentUser?.id else { return }
        posting = true
        defer { posting = false }

        let uidStr = uid.uuidString.lowercased()
        let recapIdStr = recap.id.uuidString.lowercased()

        // Upload each stop's photos; rebuild the stop with public URLs in
        // place of local filenames. Real BAC is preserved either way.
        var serverStops: [RecapStop] = []
        var cover: String? = nil
        for stop in recap.stops {
            var urls: [String] = []
            for filename in stop.photoFilenames {
                let localURL = history.photoURL(filename, in: recap.id)
                guard let data = try? Data(contentsOf: localURL) else { continue }
                let path = "\(uidStr)/\(recapIdStr)/\(filename)"
                _ = try await supabase.storage.from("recap-photos")
                    .upload(path, data: data,
                            options: FileOptions(contentType: "image/jpeg", upsert: true))
                let pub = try supabase.storage.from("recap-photos")
                    .getPublicURL(path: path).absoluteString
                urls.append(pub)
                if cover == nil { cover = pub }
            }
            serverStops.append(RecapStop(
                id: stop.id, kind: stop.kind, lat: stop.lat, lon: stop.lon, name: stop.name,
                arrivedAt: stop.arrivedAt, departedAt: stop.departedAt, drinks: stop.drinks,
                drinkSummary: stop.drinkSummary,
                bacOnArrival: stop.bacOnArrival, bacOnDeparture: stop.bacOnDeparture,
                isPeak: stop.isPeak, note: stop.note, photoFilenames: urls))
        }

        let serverRecap = NightRecap(
            id: recap.id, stops: serverStops, startedAt: recap.startedAt, endedAt: recap.endedAt,
            totalDrinks: recap.totalDrinks, peakBAC: recap.peakBAC,
            peakAt: recap.peakAt, groupLeaderboard: recap.groupLeaderboard, crawlMeters: recap.crawlMeters)

        // Encode with ISO-8601 dates so the feed decodes the same way no
        // matter what date strategy the Postgrest client uses.
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let recapData = try enc.encode(serverRecap)
        let recapJSON = try JSONDecoder().decode(AnyJSON.self, from: recapData)

        let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        struct Insert: Encodable {
            let author_id: String
            let recap: AnyJSON
            let include_bac: Bool
            let caption: String?
            let cover_url: String?
            let started_at: String
        }
        let iso = ISO8601DateFormatter()
        try await supabase.from("posts").insert(Insert(
            author_id: uidStr, recap: recapJSON, include_bac: includeBAC,
            caption: trimmedCaption.isEmpty ? nil : trimmedCaption,
            cover_url: cover, started_at: iso.string(from: recap.startedAt)
        )).execute()

        // Posting MOVES the recap to the timeline: it's a post now, not a
        // past night. (No-op at END, where it was never a past night.)
        history.markPosted(recap.id)
        history.removeFromPastNights(recap.id)
    }
}

/// Sheet to post a saved recap to the friends timeline, with a per-post
/// "include my BAC" toggle (default off).
struct PostComposerView: View {
    let recap: NightRecap
    @ObservedObject var history: RecapHistoryStore
    let onPosted: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var includeBAC = false
    @State private var caption = ""
    @State private var posting = false
    @State private var errorMessage: String?

    private var photoCount: Int { recap.stops.reduce(0) { $0 + $1.photoFilenames.count } }

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                Text("POST TO NIGHTLINE")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .tracking(2.4).foregroundStyle(Color.bronze)
                Text("Share this night")
                    .font(.system(size: 26, weight: .black, design: .rounded))
                    .italic().foregroundStyle(Color.cream)
                Text("Your friends will see your route, stops\(photoCount > 0 ? " and \(photoCount) photo\(photoCount == 1 ? "" : "s")" : ""). Friends only — never public.")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.65)).lineSpacing(2)

                TextField("Add a caption…", text: $caption, axis: .vertical)
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .lineLimit(1...4)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.cream.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.cream.opacity(0.12), lineWidth: 1))

                Toggle(isOn: $includeBAC) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Include my BAC numbers")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.cream)
                        Text("Off by default — keeps your blood-alcohol private.")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.55))
                    }
                }
                .tint(Color.whiskey)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.cream.opacity(0.05)))

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Status.drunk.color)
                }

                Button { post() } label: {
                    HStack {
                        if posting { ProgressView().tint(Color.ink); Spacer() }
                        else {
                            Text("POST").font(.system(size: 13, weight: .bold, design: .monospaced)).tracking(3)
                            Spacer()
                            Image(systemName: "paperplane.fill").font(.system(size: 12, weight: .bold))
                        }
                    }
                    .foregroundStyle(Color.ink).padding(.vertical, 15).padding(.horizontal, 20)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.cream))
                }
                .disabled(posting)
                .buttonStyle(PressScaleStyle())

                Spacer()
            }
            .padding(24)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.height(470), .large])
        .presentationDragIndicator(.visible)
    }

    private func post() {
        posting = true; errorMessage = nil
        Task { @MainActor in
            do {
                try await PostService.shared.createPost(recap, includeBAC: includeBAC, caption: caption, history: history)
                dismiss()
                onPosted()
            } catch {
                errorMessage = "Couldn't post — check your connection and try again."
                posting = false
            }
        }
    }
}

struct NightRecapView: View {
    /// How this recap was reached — drives the closing buttons.
    enum Mode {
        /// Ending a live sesh now: SAVE & END / END WITHOUT SAVING.
        case liveEnd
        /// A sesh that wound down while away (stale / group end): same
        /// save-or-discard choice, but nothing to tear down.
        case autoEnd
        /// Replaying a saved night: just DONE.
        case replay
    }

    @ObservedObject var history: RecapHistoryStore
    /// Local working copy — photo additions update it in place (the
    /// store persists them and hands back the updated value).
    @State private var recap: NightRecap
    let mode: Mode
    /// Called from the closing button. The live END presenter performs the
    /// actual sesh teardown here; auto/replay just dismiss.
    let onFinish: () -> Void

    init(
        recap: NightRecap,
        history: RecapHistoryStore,
        mode: Mode = .liveEnd,
        onFinish: @escaping () -> Void
    ) {
        _recap = State(initialValue: recap)
        self.history = history
        self.mode = mode
        self.onFinish = onFinish
    }

    private enum Stage: Equatable {
        case intro
        case stop(Int)
        case overview
    }

    @State private var stage: Stage = .intro
    @State private var showPostComposer = false
    @State private var camera: MapCameraPosition = .automatic
    /// Set the first time the user navigates manually — kills the
    /// auto-advance so the story stays where they put it.
    @State private var manualNav = false

    // Photo flows. The target stop id is SEPARATE from the picker's
    // presentation flag — the picker dismisses (resetting presentation)
    // before the selection lands, so deriving the stop from the
    // presentation state silently dropped every photo.
    @State private var libraryPickerOpen = false
    @State private var libraryTargetStopId: UUID? = nil
    @State private var pickerItem: PhotosPickerItem? = nil
    @State private var cameraTarget: CameraTarget? = nil
    @State private var lightbox: LightboxContext? = nil

    @AppStorage(BACUnitSetting.key, store: BACUnitSetting.store) private var bacUnitMode = "auto"
    private var unit: BACUnit { BACUnitSetting.resolved(mode: bacUnitMode) }

    /// One spring for every stage swap so the cards, pins and polyline
    /// reveal move together.
    private let stageSpring = Animation.spring(response: 0.6, dampingFraction: 0.86)

    var body: some View {
        ZStack {
            if recap.hasMap {
                journeyMap
                    .ignoresSafeArea()
            } else {
                Color.ink.ignoresSafeArea()
            }

            // Ink veils so the cards read against any map imagery.
            LinearGradient(
                colors: [Color.ink.opacity(0.92), Color.ink.opacity(0.0)],
                startPoint: .top, endPoint: .center
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
            LinearGradient(
                colors: [Color.ink.opacity(0.0), Color.ink.opacity(0.96)],
                startPoint: .center, endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack {
                header
                Spacer()
                stageCard
                navBar
            }
            .padding(22)
        }
        .contentShape(Rectangle())
        .onTapGesture { advance() }
        .task(id: stage) { await autoAdvance() }
        .onAppear { aimCamera(for: .intro, animated: false) }
        .photosPicker(isPresented: $libraryPickerOpen, selection: $pickerItem, matching: .images)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let stopId = libraryTargetStopId,
                   let data = try? await item.loadTransferable(type: Data.self) {
                    applyPhoto(data, to: stopId)
                }
                pickerItem = nil
                libraryTargetStopId = nil
            }
        }
        .fullScreenCover(item: $cameraTarget) { target in
            SeshCameraView { data in
                applyPhoto(data, to: target.id)
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(item: $lightbox) { context in
            PhotoLightbox(context: context) { lightbox = nil }
        }
        .preferredColorScheme(.dark)
    }

    private func applyPhoto(_ data: Data, to stopId: UUID) {
        if let updated = history.addPhoto(data, toStop: stopId, in: recap.id) {
            withAnimation(stageSpring) { recap = updated }
        }
    }

    // ---- Map

    private var journeyMap: some View {
        Map(position: $camera, interactionModes: []) {
            // Route so far: grows stop by stop as the story advances.
            let visible = visibleCoordinates
            if visible.count >= 2 {
                MapPolyline(coordinates: visible)
                    .stroke(
                        Color.whiskey,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round, dash: [1, 9])
                    )
            }
            ForEach(Array(visibleLocatedStops.enumerated()), id: \.element.id) { i, stop in
                if let coord = stop.coordinate {
                    Annotation(stop.name, coordinate: coord) {
                        ZStack {
                            Circle()
                                .fill(stop.isPeak ? Color.whiskey : Color.cream)
                                .frame(width: 26, height: 26)
                                .shadow(color: Color.whiskey.opacity(0.6), radius: 8)
                            if stop.isPeak {
                                Text("🔥").font(.system(size: 12))
                            } else if stop.kind == .preGame {
                                Text("🏠").font(.system(size: 12))
                            } else if stop.kind == .food {
                                Text("🍔").font(.system(size: 12))
                            } else if stop.kind == .puke {
                                Text("🤮").font(.system(size: 12))
                            } else if stop.kind == .refuel || stop.kind == .afters {
                                Text("📍").font(.system(size: 12))
                            } else {
                                Text("\(i + 1)")
                                    .font(.system(size: 12, weight: .black, design: .rounded))
                                    .foregroundStyle(Color.ink)
                            }
                        }
                        .transition(.scale.combined(with: .opacity))
                    }
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
    }

    /// Located stops revealed so far (all of them on the overview).
    private var visibleLocatedStops: [RecapStop] {
        switch stage {
        case .intro:
            return []
        case .stop(let i):
            return Array(recap.stops.prefix(i + 1)).filter { $0.coordinate != nil }
        case .overview:
            return recap.locatedStops
        }
    }

    private var visibleCoordinates: [CLLocationCoordinate2D] {
        visibleLocatedStops.compactMap { $0.coordinate }
    }

    /// Pitched MapCamera flights (instead of flat region interpolation)
    /// give the bar-to-bar moves a cinematic swoop and animate noticeably
    /// smoother. The heading drifts a few degrees per stop so consecutive
    /// flights don't feel like the same straight slide.
    private func aimCamera(for stage: Stage, animated: Bool = true) {
        guard recap.hasMap else { return }
        switch stage {
        case .intro:
            if let c = recap.locatedStops.first?.coordinate {
                let cam = MapCamera(centerCoordinate: c, distance: 5200, heading: 0, pitch: 28)
                if animated {
                    withAnimation(.smooth(duration: 2.2)) { camera = .camera(cam) }
                } else {
                    camera = .camera(cam)
                }
            }
        case .stop(let i):
            guard i < recap.stops.count else { return }
            if let c = recap.stops[i].coordinate {
                let heading = Double((i * 38) % 80) - 40   // gentle drift, never disorienting
                withAnimation(.smooth(duration: 2.3)) {
                    camera = .camera(MapCamera(
                        centerCoordinate: c,
                        distance: 750,
                        heading: heading,
                        pitch: 55
                    ))
                }
            }
            // Warm-up leg (no coordinate): leave the camera where it is.
        case .overview:
            withAnimation(.smooth(duration: 2.5)) {
                camera = .region(regionFittingAllStops())
            }
        }
    }

    private func regionFittingAllStops() -> MKCoordinateRegion {
        let coords = recap.locatedStops.compactMap { $0.coordinate }
        guard let first = coords.first else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1)
            )
        }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in coords {
            minLat = min(minLat, c.latitude);  maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLat + maxLat) / 2,
                longitude: (minLon + maxLon) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLat - minLat) * 1.7, 0.012),
                longitudeDelta: max((maxLon - minLon) * 1.7, 0.012)
            )
        )
    }

    // ---- Stage flow

    /// Ordered tour: intro → stop 0…n → overview.
    private var stageSequence: [Stage] {
        [.intro] + recap.stops.indices.map { .stop($0) } + [.overview]
    }

    private var stageIndex: Int {
        stageSequence.firstIndex(of: stage) ?? 0
    }

    private func go(to newStage: Stage, manual: Bool) {
        if manual { manualNav = true }
        withAnimation(stageSpring) { stage = newStage }
        aimCamera(for: newStage)
    }

    /// Tap-anywhere progression (kept from the auto-play flow). Stops at
    /// the overview — leaving is the button's job.
    private func advance() {
        guard !libraryPickerOpen, cameraTarget == nil else { return }
        guard stage != .overview else { return }
        let next = stageSequence[min(stageIndex + 1, stageSequence.count - 1)]
        go(to: next, manual: false)
    }

    private func goNext() {
        guard stageIndex + 1 < stageSequence.count else { return }
        go(to: stageSequence[stageIndex + 1], manual: true)
    }

    private func goBack() {
        guard stageIndex > 0 else { return }
        go(to: stageSequence[stageIndex - 1], manual: true)
    }

    private func autoAdvance() async {
        guard !manualNav else { return }
        let delay: Double
        switch stage {
        case .intro:    delay = 2.8
        case .stop:     delay = 5.5
        case .overview: return
        }
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        guard !Task.isCancelled else { return }
        // User started doing something (photos, manual nav) → hold here.
        guard !manualNav, !libraryPickerOpen, libraryTargetStopId == nil,
              cameraTarget == nil, pickerItem == nil, lightbox == nil else { return }
        advance()
    }

    // ---- Pieces

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.whiskey)
                        .frame(width: 7, height: 7)
                        .shadow(color: Color.whiskey.opacity(0.8), radius: 5)
                    Text("THE SESH RECAP")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(3.0)
                        .foregroundStyle(Color.bronze)
                }
                Text(recap.startedAt, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.75))
            }
            Spacer()
            if stage != .overview && !manualNav {
                Text("TAP ›")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(Color.bronze.opacity(0.8))
            }
        }
    }

    @ViewBuilder
    private var stageCard: some View {
        switch stage {
        case .intro:
            introCard
        case .stop(let i):
            if i < recap.stops.count { stopCard(recap.stops[i], number: locatedNumber(for: i)) }
        case .overview:
            overviewCard
        }
    }

    /// Prev/next chevrons + one jump dot per stop (and a flag for the
    /// overview). Touching any of it pauses the auto-advance for good.
    private var navBar: some View {
        HStack(spacing: 14) {
            navChevron("chevron.left", enabled: stageIndex > 0) { goBack() }

            HStack(spacing: 7) {
                ForEach(recap.stops.indices, id: \.self) { i in
                    Button {
                        go(to: .stop(i), manual: true)
                    } label: {
                        Circle()
                            .fill(stage == .stop(i) ? Color.whiskey : Color.cream.opacity(0.25))
                            .frame(width: stage == .stop(i) ? 8 : 6,
                                   height: stage == .stop(i) ? 8 : 6)
                    }
                }
                Button {
                    go(to: .overview, manual: true)
                } label: {
                    Image(systemName: "flag.checkered")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(stage == .overview ? Color.whiskey : Color.cream.opacity(0.35))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.ink.opacity(0.75)))
            .overlay(Capsule().strokeBorder(Color.cream.opacity(0.1), lineWidth: 1))

            navChevron("chevron.right", enabled: stageIndex + 1 < stageSequence.count) { goNext() }
        }
        .padding(.top, 12)
    }

    private func navChevron(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(enabled ? Color.cream : Color.cream.opacity(0.2))
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.ink.opacity(0.75)))
                .overlay(Circle().strokeBorder(Color.cream.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!enabled)
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(recap.isGroupRecap ? "Group night," : "Your night,")
                .font(.system(size: 40, weight: .black, design: .rounded))
                .italic()
                .tracking(-1.6)
                .foregroundStyle(Color.cream)
            Text("replayed.")
                .font(.system(size: 40, weight: .black, design: .rounded))
                .italic()
                .tracking(-1.6)
                .foregroundStyle(Color.whiskey)
            Text("\(recap.locatedStops.count) \(recap.locatedStops.count == 1 ? "stop" : "stops") · \(recap.totalDrinks) \(recap.totalDrinks == 1 ? "drink" : "drinks") · peaked at \(unit.formatted(recap.peakBAC))\(unit.symbol)")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(Color.cream.opacity(0.7))
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(cardBackground)
        .transition(.asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .opacity.combined(with: .scale(scale: 0.96))
        ))
    }

    /// Map-pin number for the stop at `index` in `recap.stops` (warm-up
    /// legs carry no pin so they don't consume a number).
    private func locatedNumber(for index: Int) -> Int? {
        guard recap.stops[index].coordinate != nil else { return nil }
        return recap.stops.prefix(index + 1).filter { $0.coordinate != nil }.count
    }

    /// Badge label + capsule tint per leg kind. Bars get their pin number.
    private func badge(for stop: RecapStop, number: Int?) -> (String, Color) {
        switch stop.kind {
        case .bar:     return (number.map { "STOP \($0)" } ?? "STOP", Color.cream)
        case .preGame: return ("PRE-GAME", Color.bronze)
        case .refuel:  return ("REFUEL", Color.bronze)
        case .afters:  return ("AFTERS", Color.whiskey)
        case .food:    return ("FOOD STOP", Color.bronze)
        case .puke:    return ("PUKE BREAK", Color.whiskey)
        }
    }

    private func displayName(for stop: RecapStop) -> String {
        switch stop.kind {
        case .food: return "🍔 \(stop.name)"
        case .puke: return "🤮 \(stop.name)"
        default:    return stop.name
        }
    }

    private func stopCard(_ stop: RecapStop, number: Int?) -> some View {
        let (badgeLabel, badgeTint) = badge(for: stop, number: number)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(badgeLabel)
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(2.0)
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(badgeTint))
                Spacer()
                Text("\(stop.kind == .bar ? "ARRIVED " : "")\(stop.arrivedAt, format: .dateTime.hour().minute())")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(Color.bronze)
            }

            Text(displayName(for: stop))
                .font(.system(size: 30, weight: .black, design: .rounded))
                .italic()
                .tracking(-1.2)
                .foregroundStyle(Color.cream)
                .lineLimit(2)
                .minimumScaleFactor(0.7)

            Text(stop.drinkSummary)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)

            if let squad = stop.squad, !squad.isEmpty {
                squadAtStop(squad)
            }

            StopPhotoStrip(
                photoURLs: stop.photoFilenames.map { history.photoURL($0, in: recap.id) },
                onTapPhoto: { index in
                    lightbox = LightboxContext(
                        urls: stop.photoFilenames.map { history.photoURL($0, in: recap.id) },
                        startIndex: index,
                        onDelete: { i in
                            guard i < stop.photoFilenames.count else { return }
                            if let updated = history.removePhoto(
                                stop.photoFilenames[i], fromStop: stop.id, in: recap.id
                            ) {
                                withAnimation(stageSpring) { recap = updated }
                            }
                        }
                    )
                },
                onDeletePhoto: { index in
                    guard index < stop.photoFilenames.count else { return }
                    if let updated = history.removePhoto(
                        stop.photoFilenames[index], fromStop: stop.id, in: recap.id
                    ) {
                        withAnimation(stageSpring) { recap = updated }
                    }
                },
                onSchnap: { cameraTarget = CameraTarget(id: stop.id) },
                onLibrary: {
                    libraryTargetStopId = stop.id
                    libraryPickerOpen = true
                }
            )

            HStack(spacing: 10) {
                // Markers are instants — one reading, not a range.
                Text(stop.arrivedAt == stop.departedAt
                     ? "BAC \(unit.formatted(stop.bacOnArrival)) \(unit.symbol)"
                     : "\(unit.formatted(stop.bacOnArrival)) → \(unit.formatted(stop.bacOnDeparture)) \(unit.symbol)")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.cream.opacity(0.8))
                if stop.isPeak {
                    Text("🔥 PEAKED HERE")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.whiskey))
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(cardBackground)
        .id(stop.id)   // forces the transition per stop
        .transition(.asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .opacity.combined(with: .scale(scale: 0.96))
        ))
    }

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("That's a wrap.")
                .font(.system(size: 32, weight: .black, design: .rounded))
                .italic()
                .tracking(-1.4)
                .foregroundStyle(Color.cream)

            HStack(spacing: 0) {
                stat(value: "\(recap.locatedStops.count)", label: recap.locatedStops.count == 1 ? "STOP" : "STOPS")
                stat(value: "\(recap.totalDrinks)", label: recap.totalDrinks == 1 ? "DRINK" : "DRINKS")
                stat(value: "\(unit.formatted(recap.peakBAC))", label: "PEAK \(unit.symbol)", tint: .whiskey)
                stat(value: durationLabel, label: "ON THE TOWN")
            }

            if recap.crawlMeters > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "figure.walk")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.whiskey)
                    Text("Crawled \(distanceLabel) between bars")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.75))
                }
            }

            if let board = recap.groupLeaderboard, !board.isEmpty {
                squadLeaderboard(board)
            }

            switch mode {
            case .replay:
                VStack(spacing: 10) {
                    postOrPostedButton
                    Button {
                        onFinish()
                    } label: {
                        Text("DONE")
                            .font(.system(size: 13, weight: .black, design: .monospaced))
                            .tracking(2.4)
                            .foregroundStyle(Color.cream.opacity(0.85))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Capsule().fill(Color.cream.opacity(0.06)))
                            .overlay(Capsule().strokeBorder(Color.cream.opacity(0.15), lineWidth: 1))
                    }
                    .buttonStyle(PressScaleStyle())

                    // Remove from Past nights. The post (if any) is untouched.
                    Button {
                        history.removeFromPastNights(recap.id)
                        onFinish()
                    } label: {
                        Text("DELETE FROM PAST NIGHTS")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .tracking(1.6)
                            .foregroundStyle(Status.drunk.color)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                    }
                    .buttonStyle(PressScaleStyle())
                }
            case .liveEnd, .autoEnd:
                // The night is already on disk (saved up front so a crash
                // can't lose it). POST shares it to friends; "save" keeps it
                // in Past nights (postable later); the quiet option deletes it.
                VStack(spacing: 10) {
                    postOrPostedButton

                    Button {
                        history.archive(recap)   // keep it in Past nights
                        onFinish()
                    } label: {
                        VStack(spacing: 2) {
                            Text(recap.isGroupRecap
                                 ? (mode == .liveEnd ? "SAVE TO GROUP NIGHTS & END" : "SAVE TO GROUP NIGHTS")
                                 : (mode == .liveEnd ? "SAVE TO PAST NIGHTS & END" : "SAVE TO PAST NIGHTS"))
                                .font(.system(size: 13, weight: .black, design: .monospaced))
                                .tracking(2.0)
                            if !recap.isGroupRecap {
                                Text("(can be posted later)")
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .tracking(1.0)
                                    .opacity(0.6)
                            }
                        }
                        .foregroundStyle(Color.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Capsule().fill(Color.cream))
                    }
                    .buttonStyle(PressScaleStyle())

                    Button {
                        history.delete(recap)
                        onFinish()
                    } label: {
                        Text(mode == .liveEnd ? "END WITHOUT SAVING" : "DISCARD RECAP")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .tracking(1.8)
                            .foregroundStyle(Color.cream.opacity(0.65))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(Color.cream.opacity(0.05)))
                            .overlay(Capsule().strokeBorder(Color.cream.opacity(0.15), lineWidth: 1))
                    }
                    .buttonStyle(PressScaleStyle())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(cardBackground)
        .transition(.asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .opacity.combined(with: .scale(scale: 0.96))
        ))
        .sheet(isPresented: $showPostComposer) {
            PostComposerView(recap: recap, history: history, onPosted: {
                // Posting from the END screen concludes the flow; in replay
                // it just closes the composer (the recap stays open).
                if mode != .replay { onFinish() }
            })
        }
    }

    /// POST button (whiskey) — or a "Posted" confirmation if this recap has
    /// already been shared to the timeline.
    @ViewBuilder
    private var postOrPostedButton: some View {
        if recap.isGroupRecap {
            // Group recaps are keepsakes, not posts — they contain the
            // whole squad's photos and stats, which aren't the user's
            // alone to publish.
            HStack(spacing: 6) {
                Image(systemName: "person.3.fill").font(.system(size: 12, weight: .bold))
                Text("SQUAD RECAP · SAVE ONLY")
                    .font(.system(size: 12, weight: .black, design: .monospaced)).tracking(1.6)
            }
            .foregroundStyle(Color.bronze)
            .frame(maxWidth: .infinity).padding(.vertical, 13)
            .background(Capsule().fill(Color.bronze.opacity(0.1)))
            .overlay(Capsule().strokeBorder(Color.bronze.opacity(0.35), lineWidth: 1))
        } else if history.isPosted(recap.id) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 13, weight: .bold))
                Text("POSTED TO NIGHTLINE")
                    .font(.system(size: 12, weight: .black, design: .monospaced)).tracking(1.6)
            }
            .foregroundStyle(Color.whiskey)
            .frame(maxWidth: .infinity).padding(.vertical, 13)
            .background(Capsule().fill(Color.whiskey.opacity(0.12)))
            .overlay(Capsule().strokeBorder(Color.whiskey.opacity(0.4), lineWidth: 1))
        } else {
            Button {
                showPostComposer = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "paperplane.fill").font(.system(size: 12, weight: .bold))
                    Text("POST TO NIGHTLINE")
                        .font(.system(size: 13, weight: .black, design: .monospaced)).tracking(1.6)
                }
                .foregroundStyle(Color.ink)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(Capsule().fill(Color.whiskey))
                .shadow(color: Color.whiskey.opacity(0.45), radius: 14, y: 5)
            }
            .buttonStyle(PressScaleStyle())
        }
    }

    /// GROUP recap, per stop: everyone's BAC + drink tally as the group
    /// left this spot — the drunkest wears the crown.
    private func squadAtStop(_ squad: [SquadStopStat]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("THE SQUAD HERE")
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .tracking(2)
                .foregroundStyle(Color.bronze)
            ForEach(Array(squad.enumerated()), id: \.element.id) { i, m in
                HStack(spacing: 8) {
                    Text(i == 0 ? "👑" : "\(i + 1).")
                        .font(.system(size: i == 0 ? 13 : 11, weight: .black, design: .monospaced))
                        .foregroundStyle(Color.cream.opacity(0.6))
                        .frame(width: 22, alignment: .leading)
                    Text(m.name)
                        .font(.system(size: 13, weight: m.isMe ? .heavy : .semibold, design: .rounded))
                        .foregroundStyle(m.isMe ? Color.whiskey : Color.cream)
                        .lineLimit(1)
                    Spacer()
                    Text("\(m.drinks) \(m.drinks == 1 ? "drink" : "drinks") here")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.5))
                    Text(unit.formatted(m.bac))
                        .font(.system(size: 12, weight: .black, design: .monospaced))
                        .foregroundStyle(i == 0 ? Color.whiskey : Color.cream.opacity(0.8))
                        .frame(width: 46, alignment: .trailing)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.cream.opacity(0.04)))
    }

    /// The group recap's squad table — drunkest first, MVP crowned, you
    /// highlighted. Shown on the overview when this was a group sesh.
    private func squadLeaderboard(_ board: [GroupMemberStat]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "person.3.fill")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(Color.whiskey)
                Text("THE SQUAD")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(2.2)
                    .foregroundStyle(Color.whiskey)
                Rectangle().fill(Color.whiskey.opacity(0.25)).frame(height: 1)
            }
            ForEach(Array(board.enumerated()), id: \.element.id) { i, m in
                HStack(spacing: 10) {
                    Text(i == 0 ? "👑" : "\(i + 1)")
                        .font(.system(size: 12, weight: .black, design: .rounded))
                        .frame(width: 20)
                    Text(m.isMe ? "\(m.name) (you)" : m.name)
                        .font(.system(size: 13, weight: m.isMe ? .heavy : .semibold, design: .rounded))
                        .foregroundStyle(m.isMe ? Color.whiskey : Color.cream)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text("\(m.drinkCount) \(m.drinkCount == 1 ? "drink" : "drinks")")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.cream.opacity(0.5))
                    Text("\(unit.formatted(m.peakBAC))\(unit.symbol)")
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(i == 0 ? Color.whiskey : Color.cream.opacity(0.85))
                }
            }
        }
        .padding(.top, 2)
    }

    private func stat(value: String, label: String, tint: Color = .cream) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 20, weight: .black, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(1.0)
                .foregroundStyle(Color.bronze)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var durationLabel: String {
        let hours = recap.endedAt.timeIntervalSince(recap.startedAt) / 3600
        let h = Int(hours)
        let m = Int((hours - Double(h)) * 60)
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private var distanceLabel: String {
        recap.crawlMeters >= 1000
            ? String(format: "%.1f km", recap.crawlMeters / 1000)
            : "\(Int(recap.crawlMeters)) m"
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(Color.ink.opacity(0.88))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.cream.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
    }
}

// MARK: - Mid-night photos section

/// Lives on the LIVE page, right under the venue chip. Lists EVERY stop
/// of the night (newest first) so the user can browse and add photos to
/// earlier bars too — snapped here they ride straight into the recap.
/// Hidden until the first check-in.
struct LiveJourneyPhotosSection: View {
    @ObservedObject var journey: NightJourneyStore
    /// Group members + guests a puke break can be pinned on ("Alex's
    /// puke break"). Empty in a solo sesh with no guests — the 🤮 button
    /// then marks the user's own without asking.
    var pukeCandidates: [String] = []
    /// Remove a stop the user added by mistake. Routed up so the owner can
    /// also check out of `currentVenue` when it's the bar being removed.
    var onRemoveStop: (SeshStop) -> Void = { _ in }
    /// Current device coordinate, stored exactly as the marked spot. Nil
    /// when location is off; the "use my location" option then hides.
    var userCoordinate: CLLocationCoordinate2D? = nil
    /// Whether a live group is running + this device follows it — drives
    /// the "shared with group" hint and whether the owner broadcasts a
    /// loose spot.
    var inFollowingGroup: Bool = false
    /// A live group is running (regardless of follow state) — drives the
    /// "just you" tag on personal food/puke markers so it's clear they
    /// aren't shared with the group.
    var inGroup: Bool = false
    /// Fired when the CURRENT-moment loose spot changes, so the owner can
    /// broadcast it to the group (no-op when solo / broken away).
    var onLooseSpotChanged: (LooseSpot?) -> Void = { _ in }

    /// Which page is showing. Follows new stops automatically (jumps to
    /// the newest) until the user swipes elsewhere.
    @State private var page = 0
    @State private var pukePickerOpen = false
    /// A bar stop pending a remove confirmation (markers remove instantly).
    @State private var pendingRemoval: SeshStop? = nil
    // Loose-spot (pre-game / between-bars location) flows. `spotTarget`
    // says whether the dialog edits the CURRENT moment or pre-game
    // (revisited from its history page to add a location after the fact).
    private enum SpotTarget { case current, preGame }
    @State private var spotTarget: SpotTarget = .current
    @State private var spotOptionsOpen = false
    @State private var spotNaming = false
    @State private var spotNameText = ""

    // Photo flows — target id kept separate from picker presentation so
    // the dismissal can't clear it before the selection lands.
    @State private var libraryPickerOpen = false
    @State private var libraryTargetStopId: UUID? = nil
    @State private var pickerItem: PhotosPickerItem? = nil
    @State private var cameraTarget: CameraTarget? = nil
    @State private var lightbox: LightboxContext? = nil

    /// Sentinel target: photos routed here are "loose" (between stops) —
    /// the recap files them by timestamp onto pre-game/refuel/afters.
    private static let looseTargetId = UUID()

    /// True while the user is checked in at a bar. When false the pager
    /// grows the current "in-between" page that collects loose photos.
    private var checkedIn: Bool {
        journey.stops.last(where: { $0.kind == .bar && $0.departedAt == nil }) != nil
    }

    private enum PagerPage: Hashable {
        case preGameHistory   // revisit pre-game after moving on to a bar
        case stop(Int)        // index into journey.stops
        case looseNow         // the live "right now, between places" page
    }

    /// Ordered pager pages. A dedicated pre-game page is kept up front once
    /// you've checked into a bar (so you can swipe back to its photos), the
    /// stops follow, and the live between-places page trails when you're
    /// not at a bar.
    private var pages: [PagerPage] {
        var result: [PagerPage] = []
        if journey.hasCheckedInSomewhere {
            if !journey.preGamePhotos.isEmpty || journey.preGameSpot != nil {
                result.append(.preGameHistory)
            }
            for i in journey.stops.indices { result.append(.stop(i)) }
        } else {
            // Pre-gaming (before the first check-in): the pre-game page
            // leads, then any food/puke markers dropped during it — so a
            // marker never sits before pre-game.
            result.append(.looseNow)
            for i in journey.stops.indices { result.append(.stop(i)) }
        }
        return result
    }

    private func isTall(_ pg: PagerPage) -> Bool {
        // Bars are compact; pre-game, loose, and non-bar stops (between /
        // food / puke) carry an extra location row, so they need more room.
        if case .stop(let i) = pg {
            return i < journey.stops.count && journey.stops[i].kind != .bar
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.whiskey)
                Text("NIGHT SCHNAPS")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(Color.bronze)
                Spacer()
                // Drop a marker on the night — shows up in the pager and
                // the recap (on the map too, when location is on), photos
                // attachable like any stop.
                markerButton("🍔") { journey.addMarker(kind: .food, coordinate: userCoordinate) }
                markerButton("🤮") {
                    if pukeCandidates.isEmpty {
                        journey.addMarker(kind: .puke, coordinate: userCoordinate)
                    } else {
                        pukePickerOpen = true
                    }
                }
            }

            // Swipe (or chevrons) between pre-game, each stop, and the
            // live between-places page.
            let pages = pages
            TabView(selection: $page) {
                ForEach(Array(pages.enumerated()), id: \.offset) { i, pg in
                    pageContent(pg).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // Sized to fit the title + photo strip + comment field (pre-game /
            // loose / non-bar stops also carry a location row → taller). Pages
            // top-align inside this frame so the title is never clipped.
            .frame(height: (page < pages.count && isTall(pages[page])) ? 224 : 184)
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: page)

            if pages.count > 1 {
                HStack(spacing: 10) {
                    pagerChevron("chevron.left", enabled: page > 0) { page -= 1 }
                    HStack(spacing: 5) {
                        ForEach(0..<pages.count, id: \.self) { i in
                            Circle()
                                .fill(i == page ? Color.whiskey : Color.cream.opacity(0.25))
                                .frame(width: i == page ? 7 : 5, height: i == page ? 7 : 5)
                                .onTapGesture { page = i }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    pagerChevron("chevron.right", enabled: page < pages.count - 1) { page += 1 }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.cream.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.cream.opacity(0.07), lineWidth: 1)
        )
        .onAppear { page = max(0, pages.count - 1) }
        .onChange(of: pages.count) { _, count in
            // New stop / check-in-out → slide to the freshest moment (the
            // current page is always last). Also clamps if a page vanished.
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                page = max(0, count - 1)
            }
        }
        .confirmationDialog("Whose puke break?", isPresented: $pukePickerOpen, titleVisibility: .visible) {
            Button("Mine 🫡") { journey.addMarker(kind: .puke, coordinate: userCoordinate) }
            ForEach(pukeCandidates, id: \.self) { name in
                Button(name) {
                    journey.addMarker(kind: .puke, named: "\(name)'s puke break", coordinate: userCoordinate)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(spotTitle, isPresented: $spotOptionsOpen, titleVisibility: .visible) {
            if userCoordinate != nil {
                Button("Use my exact location") {
                    // Commit the location now, then immediately prompt for
                    // a name so it's one fluid step.
                    applySpot(name: targetSpot?.name, coordinate: userCoordinate)
                    spotNameText = targetSpot?.name ?? ""
                    spotNaming = true
                }
            }
            Button("Name only (no location)") {
                spotNameText = targetSpot?.name ?? ""
                spotNaming = true
            }
            if targetSpot != nil {
                Button("Remove spot", role: .destructive) { clearSpot() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This pins your exact location — often a home. It stays on your device, and if recap sharing ever arrives you'll choose whether to include these spots. Prefer not to? Use a name only.")
        }
        .alert("Name this spot", isPresented: $spotNaming) {
            TextField(spotTarget == .preGame ? "e.g. Anna's place" : (journey.hasCheckedInSomewhere ? "e.g. taxi, kebab line" : "e.g. Anna's place"), text: $spotNameText)
            Button("Save") {
                applySpot(name: spotNameText, coordinate: targetSpot?.coordinate)
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Remove this check-in?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove stop", role: .destructive) {
                if let stop = pendingRemoval {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                        page = max(0, page - 1)
                        onRemoveStop(stop)
                    }
                }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            if let stop = pendingRemoval {
                Text("\(stop.name) and its photos will be removed from tonight's recap.")
            }
        }
        .photosPicker(isPresented: $libraryPickerOpen, selection: $pickerItem, matching: .images)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let stopId = libraryTargetStopId,
                   let data = try? await item.loadTransferable(type: Data.self) {
                    if stopId == Self.looseTargetId {
                        journey.addLoosePhoto(data)
                    } else {
                        journey.addPhoto(data, toStop: stopId)
                    }
                }
                pickerItem = nil
                libraryTargetStopId = nil
            }
        }
        .fullScreenCover(item: $cameraTarget) { target in
            SeshCameraView { data in
                if target.id == Self.looseTargetId {
                    journey.addLoosePhoto(data)
                } else {
                    journey.addPhoto(data, toStop: target.id)
                }
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(item: $lightbox) { context in
            PhotoLightbox(context: context) { lightbox = nil }
        }
    }

    @ViewBuilder
    private func pageContent(_ pg: PagerPage) -> some View {
        switch pg {
        case .preGameHistory:
            preGameHistoryPage
        case .stop(let idx):
            if idx < journey.stops.count {
                stopPage(journey.stops[idx], isCurrent: idx == journey.stops.count - 1)
            }
        case .looseNow:
            loosePage
        }
    }

    /// Pre-game revisited — view its photos + the marked spot after you've
    /// moved on. Read-only: adding here would mis-stamp into a later
    /// window, so the add buttons are hidden (delete + lightbox stay).
    private var preGameHistoryPage: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("🏠 Pre-game")
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .lineLimit(1)
                Text("EARLIER")
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.cream.opacity(0.5)))
                Spacer()
            }

            // Editable location — add a pre-game spot even after you've
            // moved on to a bar.
            spotRow(target: .preGame)

            StopPhotoStrip(
                photoURLs: journey.preGamePhotos.map { journey.photoURL($0.filename) },
                onTapPhoto: { index in
                    lightbox = LightboxContext(
                        urls: journey.preGamePhotos.map { journey.photoURL($0.filename) },
                        startIndex: index,
                        onDelete: { i in
                            guard i < journey.preGamePhotos.count else { return }
                            journey.removeLoosePhoto(journey.preGamePhotos[i].filename)
                        }
                    )
                },
                onDeletePhoto: { index in
                    guard index < journey.preGamePhotos.count else { return }
                    journey.removeLoosePhoto(journey.preGamePhotos[index].filename)
                },
                onSchnap: {},
                onLibrary: {},
                allowAdd: false
            )

            // The pre-game comment stays editable even after moving on.
            StopNoteEditor(note: journey.preGameNote) { journey.setPreGameNote($0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The "right now, between places" page — pre-game before the first
    /// check-in, transit/afters later. Loose photos collect here and the
    /// recap files them onto the right leg by timestamp.
    private var loosePage: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(journey.hasCheckedInSomewhere ? "🌃 Between bars" : "🏠 Pre-game")
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .lineLimit(1)
                Text("NOW")
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.bronze))
                Spacer()
            }

            // Optional location for this moment — pre-game before the
            // first check-in, or the gap between bars / afters. Privacy-
            // safe + opt-in.
            looseSpotRow
            if inFollowingGroup {
                Text("Applies to the whole group · you're following")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.bronze)
            }

            // Only THIS moment's photos — pre-game shots don't leak onto a
            // later between-bars page, and vice-versa.
            let windowPhotos = journey.currentWindowLoosePhotos
            StopPhotoStrip(
                photoURLs: windowPhotos.map { journey.photoURL($0.filename) },
                onTapPhoto: { index in
                    lightbox = LightboxContext(
                        urls: windowPhotos.map { journey.photoURL($0.filename) },
                        startIndex: index,
                        onDelete: { i in
                            guard i < windowPhotos.count else { return }
                            journey.removeLoosePhoto(windowPhotos[i].filename)
                        }
                    )
                },
                onDeletePhoto: { index in
                    guard index < windowPhotos.count else { return }
                    journey.removeLoosePhoto(windowPhotos[index].filename)
                },
                onSchnap: { cameraTarget = CameraTarget(id: Self.looseTargetId) },
                onLibrary: {
                    libraryTargetStopId = Self.looseTargetId
                    libraryPickerOpen = true
                }
            )

            // Pre-game comment (only before the first check-in — that's the
            // pre-game window the note maps to in the recap).
            if !journey.hasCheckedInSomewhere {
                StopNoteEditor(note: journey.preGameNote) { journey.setPreGameNote($0) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Dialog/button title — depends on which spot the dialog is editing.
    private var spotTitle: String {
        if spotTarget == .preGame { return "Pre-game spot" }
        return journey.hasCheckedInSomewhere ? "Mark this spot" : "Pre-game spot"
    }

    /// The spot the open dialog is editing.
    private var targetSpot: LooseSpot? {
        spotTarget == .preGame ? journey.preGameSpot : journey.currentLooseSpot
    }

    private func applySpot(name: String?, coordinate: CLLocationCoordinate2D?) {
        if spotTarget == .preGame {
            journey.setPreGameSpot(name: name, rawCoordinate: coordinate)
        } else {
            journey.setCurrentLooseSpot(name: name, rawCoordinate: coordinate)
            // Broadcast the live moment's spot to the group.
            onLooseSpotChanged(journey.currentLooseSpot)
        }
    }

    private func clearSpot() {
        if spotTarget == .preGame {
            journey.clearPreGameSpot()
        } else {
            journey.clearCurrentLooseSpot()
            onLooseSpotChanged(nil)
        }
    }

    /// Open the spot editor for a given target (current moment, or pre-game
    /// revisited from its history page).
    private func openSpotEditor(_ target: SpotTarget) {
        spotTarget = target
        spotOptionsOpen = true
    }

    /// The opt-in location/name control for the current loose moment.
    /// Location is exact + stays on-device; the confirm dialog spells out
    /// the privacy trade-off, and name-only is offered for anyone who'd
    /// rather not pin a home.
    /// The current moment's spot control (pre-game when no bars, else
    /// between-bars).
    private var looseSpotRow: some View { spotRow(target: .current) }

    /// Reusable spot row for a given target. `.preGame` is used on the
    /// pre-game history page so a location can be added after the fact.
    @ViewBuilder
    private func spotRow(target: SpotTarget) -> some View {
        let spot = target == .preGame ? journey.preGameSpot : journey.currentLooseSpot
        let setLabel = (target == .preGame || !journey.hasCheckedInSomewhere)
            ? "SET PRE-GAME SPOT" : "MARK THIS SPOT"
        if let spot {
            HStack(spacing: 6) {
                Image(systemName: spot.hasLocation ? "mappin.circle.fill" : "house.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.whiskey)
                Text(spot.name ?? "Marked spot")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.85))
                    .lineLimit(1)
                if spot.hasLocation {
                    Image(systemName: "location.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.bronze)
                }
                Spacer(minLength: 4)
                Button { openSpotEditor(target) } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.cream.opacity(0.6))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(PressScaleStyle())
                Button {
                    if target == .preGame { journey.clearPreGameSpot() }
                    else { journey.clearCurrentLooseSpot() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.cream.opacity(0.5))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(PressScaleStyle())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.cream.opacity(0.05)))
            .overlay(Capsule().strokeBorder(Color.whiskey.opacity(0.25), lineWidth: 1))
        } else {
            Button { openSpotEditor(target) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 10, weight: .bold))
                    Text(setLabel)
                        .font(.system(size: 9.5, weight: .black, design: .monospaced))
                        .tracking(1.2)
                }
                .foregroundStyle(Color.whiskey)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.whiskey.opacity(0.1)))
                .overlay(Capsule().strokeBorder(Color.whiskey.opacity(0.35), lineWidth: 1))
            }
            .buttonStyle(PressScaleStyle())
        }
    }

    private func moveButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { action() }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(enabled ? Color.cream.opacity(0.7) : Color.cream.opacity(0.2))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.cream.opacity(0.06)))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!enabled)
        .accessibilityLabel(icon == "chevron.left" ? "Move stop earlier" : "Move stop later")
    }

    private func markerButton(_ emoji: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(emoji)
                .font(.system(size: 13))
                .frame(width: 30, height: 26)
                .background(Capsule().fill(Color.cream.opacity(0.05)))
                .overlay(Capsule().strokeBorder(Color.cream.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(PressScaleStyle())
    }

    /// Add / clear a location on a non-bar stop. Only offered when device
    /// location is available; tapping "set" drops the current coordinate.
    @ViewBuilder
    private func stopLocationRow(_ stop: SeshStop) -> some View {
        if stop.coordinate != nil {
            HStack(spacing: 6) {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.whiskey)
                Text("Location added")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.85))
                Spacer(minLength: 4)
                Button { journey.setStopLocation(stop.id, coordinate: nil) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.cream.opacity(0.5))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(PressScaleStyle())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.cream.opacity(0.05)))
            .overlay(Capsule().strokeBorder(Color.whiskey.opacity(0.25), lineWidth: 1))
        } else if userCoordinate != nil {
            Button {
                journey.setStopLocation(stop.id, coordinate: userCoordinate)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 10, weight: .bold))
                    Text("ADD LOCATION")
                        .font(.system(size: 9.5, weight: .black, design: .monospaced))
                        .tracking(1.2)
                }
                .foregroundStyle(Color.whiskey)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.whiskey.opacity(0.1)))
                .overlay(Capsule().strokeBorder(Color.whiskey.opacity(0.35), lineWidth: 1))
            }
            .buttonStyle(PressScaleStyle())
        }
    }

    private func stopPage(_ stop: SeshStop, isCurrent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Row 1 — stop name with its status badge pushed to the right
            // (where the × used to sit).
            HStack(spacing: 8) {
                Text(stop.kind == .food ? "🍔 \(stop.name)"
                     : stop.kind == .puke ? "🤮 \(stop.name)"
                     : stop.kind == .between ? "🌃 \(stop.name)"
                     : stop.name)
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isCurrent && stop.kind == .bar && checkedIn {
                    Text("HERE NOW")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.whiskey))
                } else if isCurrent && stop.kind == .between && !checkedIn {
                    Text("NOW")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.bronze))
                } else if inGroup && (stop.kind == .food || stop.kind == .puke) {
                    // Markers are personal — make it clear they aren't the
                    // group's shared check-in.
                    Text("JUST YOU")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(Color.cream.opacity(0.7))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.cream.opacity(0.08)))
                        .overlay(Capsule().strokeBorder(Color.cream.opacity(0.15), lineWidth: 1))
                }
            }

            // Row 2 — nav chrome (arrival time, remove) shifted down off
            // the title row so name + badge read cleanly. The reorder
            // arrows that used to sit here were dropped — they mirrored
            // the pager's chevrons and just confused navigation.
            HStack(spacing: 8) {
                Spacer(minLength: 8)
                Text(stop.arrivedAt, format: .dateTime.hour().minute())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.0)
                    .foregroundStyle(Color.bronze)
                // Remove a stop added by mistake. Markers vanish instantly;
                // a bar check-in confirms first (it carries more weight).
                Button {
                    if stop.kind == .bar {
                        pendingRemoval = stop
                    } else {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                            page = max(0, page - 1)
                            onRemoveStop(stop)
                        }
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.cream.opacity(0.5))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.cream.opacity(0.06)))
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("Remove this stop")
            }

            // Non-bar stops (between bars / food / puke) can be located
            // after the fact — bars get theirs from check-in.
            if stop.kind != .bar {
                stopLocationRow(stop)
            }

            StopPhotoStrip(
                photoURLs: stop.photoFilenames.map { journey.photoURL($0) },
                onTapPhoto: { index in
                    lightbox = LightboxContext(
                        urls: stop.photoFilenames.map { journey.photoURL($0) },
                        startIndex: index,
                        onDelete: { i in
                            guard i < stop.photoFilenames.count else { return }
                            journey.removePhoto(stop.photoFilenames[i], fromStop: stop.id)
                        }
                    )
                },
                onDeletePhoto: { index in
                    guard index < stop.photoFilenames.count else { return }
                    journey.removePhoto(stop.photoFilenames[index], fromStop: stop.id)
                },
                onSchnap: { cameraTarget = CameraTarget(id: stop.id) },
                onLibrary: {
                    libraryTargetStopId = stop.id
                    libraryPickerOpen = true
                }
            )

            // A comment about this stop — saved to the recap and shown on
            // the timeline if the night gets posted.
            StopNoteEditor(note: stop.note) { journey.setNote(stop.id, $0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func pagerChevron(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { action() }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(enabled ? Color.cream : Color.cream.opacity(0.2))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.cream.opacity(0.05)))
                .overlay(Circle().strokeBorder(Color.cream.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!enabled)
    }
}

/// A compact, inline comment field for a stop. Commits on return or when
/// focus leaves, calling `onCommit` with the latest text.
private struct StopNoteEditor: View {
    @State private var text: String
    let onCommit: (String) -> Void
    @FocusState private var focused: Bool

    init(note: String?, onCommit: @escaping (String) -> Void) {
        _text = State(initialValue: note ?? "")
        self.onCommit = onCommit
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.bronze)
            TextField("Add a comment about this stop…", text: $text, axis: .vertical)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream)
                // Starts as a single compact line and grows as you type.
                .lineLimit(1...5)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit { focused = false; onCommit(text) }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.cream.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.bronze.opacity(0.2), lineWidth: 1))
        .onChange(of: focused) { _, isFocused in
            if !isFocused { onCommit(text) }
        }
    }
}

// MARK: - Past nights list row

/// Compact row for the profile sheet's "Past nights" section.
struct PastNightRow: View {
    let recap: NightRecap
    let unit: BACUnit

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(recap.startedAt, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.cream)
                Text("\(recap.locatedStops.count) \(recap.locatedStops.count == 1 ? "stop" : "stops") · \(recap.totalDrinks) \(recap.totalDrinks == 1 ? "drink" : "drinks") · peak \(unit.formatted(recap.peakBAC))\(unit.symbol)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(0.4)
                    .foregroundStyle(Color.bronze)
            }
            Spacer(minLength: 8)
            let photoCount = recap.stops.reduce(0) { $0 + $1.photoFilenames.count }
            if photoCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "photo.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text("\(photoCount)")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                }
                .foregroundStyle(Color.cream.opacity(0.6))
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.bronze)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.cream.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.cream.opacity(0.08), lineWidth: 1)
        )
    }
}
