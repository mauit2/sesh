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

// MARK: - Journey store

/// What a journey entry IS — a bar check-in, or a self-reported marker
/// the user drops mid-night (food run, tactical puke). Markers carry
/// photos like any stop but don't open a drink-attribution window.
enum JourneyStopKind: String, Codable {
    case bar
    case food
    case puke
}

/// One recorded entry on the night's route.
struct SeshStop: Codable, Identifiable, Equatable {
    let id: UUID
    let venueId: UUID
    let kind: JourneyStopKind
    let name: String
    /// nil for markers (food/puke) — they get cards but no map pin.
    let lat: Double?
    let lon: Double?
    let arrivedAt: Date
    /// Set when the user taps CHECK OUT. Lets the recap carve "between
    /// bars" (refuel) and "after last bar" (afters) legs out of the night.
    var departedAt: Date? = nil
    /// Photos snapped while AT this stop, staged in the journey's photo
    /// directory until the recap adopts them at END time.
    var photoFilenames: [String] = []

    var coordinate: CLLocationCoordinate2D? {
        guard let lat, let lon else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    // Custom decode so journeys persisted by older builds (no kind /
    // departedAt / photoFilenames keys) still load instead of resetting.
    enum CodingKeys: String, CodingKey {
        case id, venueId, kind, name, lat, lon, arrivedAt, departedAt, photoFilenames
    }

    init(
        id: UUID, venueId: UUID, kind: JourneyStopKind = .bar, name: String,
        lat: Double?, lon: Double?, arrivedAt: Date,
        departedAt: Date? = nil, photoFilenames: [String] = []
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

@MainActor
final class NightJourneyStore: ObservableObject {
    @Published private(set) var stops: [SeshStop] = []
    @Published private(set) var loosePhotos: [LooseTake] = []

    private let key = "sesh.nightJourney.v1"
    private let looseKey = "sesh.nightJourney.loose.v1"

    /// Staging area for photos snapped during the night, before a recap
    /// (and its id) exists. At END time `RecapHistoryStore.adoptPhotos`
    /// moves these into the saved recap's own directory.
    nonisolated let photosDirectory: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("night-recaps/journey-photos", isDirectory: true)
    }()

    init() {
        try? FileManager.default.createDirectory(
            at: photosDirectory, withIntermediateDirectories: true
        )
        load()
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

    /// Record a check-in. Duplicates collapse while the user is still
    /// checked in at the same bar (launch-time re-validation re-sets
    /// currentVenue with the same venue — not a new stop, even if a food
    /// or puke marker landed in between). Returning to a bar AFTER
    /// checking out IS a new stop.
    func checkIn(_ venue: Venue, at date: Date = Date()) {
        if let lastBar = stops.last(where: { $0.kind == .bar }),
           lastBar.venueId == venue.id,
           lastBar.departedAt == nil {
            return
        }
        stops.append(SeshStop(
            id: UUID(),
            venueId: venue.id,
            kind: .bar,
            name: venue.name,
            lat: venue.lat,
            lon: venue.lon,
            arrivedAt: date
        ))
        save()
    }

    /// Record leaving the current bar (the venue sheet's CHECK OUT, or
    /// the chip being cleared). Stamps the open bar stop so the recap
    /// can carve refuel / afters legs from the time that follows.
    func checkOut(at date: Date = Date()) {
        guard let i = stops.lastIndex(where: { $0.kind == .bar && $0.departedAt == nil })
        else { return }
        stops[i].departedAt = date
        save()
    }

    /// Drop a food / puke marker at the current moment. Markers are
    /// photo-carrying cards on the recap, not drink windows. `named`
    /// overrides the default title — used to pin a puke break on a
    /// specific group member ("Alex's puke break").
    func addMarker(kind: JourneyStopKind, named name: String? = nil, at date: Date = Date()) {
        guard kind != .bar else { return }
        stops.append(SeshStop(
            id: UUID(),
            venueId: UUID(),   // markers aren't venues; unique id keeps dedupe away
            kind: kind,
            name: name ?? (kind == .food ? "Food stop" : "Puke break"),
            lat: nil,
            lon: nil,
            arrivedAt: date
        ))
        save()
    }

    /// Remove a marker (mis-taps happen at 1am). Bar stops are derived
    /// from check-ins and stay.
    func removeMarker(_ stopId: UUID) {
        guard let i = stops.firstIndex(where: { $0.id == stopId }),
              stops[i].kind != .bar else { return }
        for filename in stops[i].photoFilenames {
            try? FileManager.default.removeItem(
                at: photosDirectory.appendingPathComponent(filename)
            )
        }
        stops.remove(at: i)
        save()
    }

    func clear() {
        stops = []
        loosePhotos = []
        save()
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
}

// MARK: - Recap model

/// One timestamped drink event attributed to the user — already reduced
/// to "grams of ethanol to me" so solo drinks and group shared-round
/// shares flow through the same math.
struct RecapEvent: Codable {
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

    var coordinate: CLLocationCoordinate2D? {
        guard let lat, let lon else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    // Tolerant decode — recaps saved before `kind` existed default to
    // .bar (their "Warm-up" legs map to .preGame by name).
    enum CodingKeys: String, CodingKey {
        case id, kind, lat, lon, name, arrivedAt, departedAt, drinks
        case drinkSummary, bacOnArrival, bacOnDeparture, isPeak, photoFilenames
    }

    init(
        id: UUID, kind: RecapStopKind, lat: Double?, lon: Double?, name: String,
        arrivedAt: Date, departedAt: Date, drinks: [RecapEvent], drinkSummary: String,
        bacOnArrival: Double, bacOnDeparture: Double, isPeak: Bool,
        photoFilenames: [String] = []
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
        photoFilenames = (try? c.decodeIfPresent([String].self, forKey: .photoFilenames)) ?? []
    }
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
    /// Straight-line meters between consecutive located stops. 0 when
    /// fewer than two stops had coordinates.
    let crawlMeters: Double

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
        endedAt: Date = Date()
    ) -> NightRecap? {
        let events = rawEvents.sorted { $0.when < $1.when }
        guard let firstEvent = events.first, bumpPerGram > 0 else { return nil }

        let graceStart = firstEvent.when.addingTimeInterval(-90 * 60)
        let nightStops = journeyStops
            .filter { $0.arrivedAt >= graceStart && $0.arrivedAt <= endedAt }
            .sorted { $0.arrivedAt < $1.arrivedAt }
        let looseTakes = loosePhotos
            .filter { $0.takenAt >= graceStart && $0.takenAt <= endedAt }
            .sorted { $0.takenAt < $1.takenAt }

        let startedAt = min(
            firstEvent.when,
            nightStops.first?.arrivedAt ?? firstEvent.when,
            looseTakes.first?.takenAt ?? firstEvent.when
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
        var peakAt = firstEvent.when
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
        }
        let bars = nightStops.filter { $0.kind == .bar }
        let markers = nightStops.filter { $0.kind != .bar }
        var legs: [Leg] = []

        // A gap becomes a leg if it has anything to show — a drink OR a
        // loose photo taken during it.
        func hasContent(from: Date, to: Date) -> Bool {
            events.contains(where: { $0.when >= from && $0.when < to })
                || looseTakes.contains(where: { $0.takenAt >= from && $0.takenAt < to })
        }

        if let firstBar = bars.first, hasContent(from: startedAt, to: firstBar.arrivedAt) {
            legs.append(Leg(
                kind: .preGame, stop: nil, name: "Pre-game",
                from: startedAt, to: firstBar.arrivedAt, isWindow: true
            ))
        }
        for (i, bar) in bars.enumerated() {
            let nextArrival = i + 1 < bars.count ? bars[i + 1].arrivedAt : nil
            // Residency ends at checkout, but never past the next bar
            // (forgot to check out) or the end of the sesh.
            let windowEnd = min(bar.departedAt ?? endedAt, nextArrival ?? endedAt, endedAt)
            legs.append(Leg(
                kind: .bar, stop: bar, name: bar.name,
                from: bar.arrivedAt, to: windowEnd, isWindow: true
            ))
            // The gap after this bar — a leg if anything happened there.
            let gapEnd = nextArrival ?? endedAt
            if windowEnd < gapEnd, hasContent(from: windowEnd, to: gapEnd) {
                let isLast = nextArrival == nil
                legs.append(Leg(
                    kind: isLast ? .afters : .refuel,
                    stop: nil,
                    name: isLast ? "Afters" : "Refuel break",
                    from: windowEnd, to: gapEnd, isWindow: true
                ))
            }
        }
        if bars.isEmpty {
            // No check-ins at all — one card covering the whole night.
            legs.append(Leg(
                kind: .preGame, stop: nil, name: "The night",
                from: startedAt, to: endedAt, isWindow: true
            ))
        }
        for m in markers {
            legs.append(Leg(
                kind: m.kind == .food ? .food : .puke,
                stop: m, name: m.name,
                from: m.arrivedAt, to: m.arrivedAt, isWindow: false
            ))
        }
        legs.sort { $0.from < $1.from }

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
                lat: leg.stop?.lat,
                lon: leg.stop?.lon,
                name: leg.name,
                arrivedAt: leg.from,
                departedAt: leg.to,
                drinks: here,
                drinkSummary: summary,
                bacOnArrival: bac(at: leg.from),
                bacOnDeparture: bac(at: leg.to),
                isPeak: leg.isWindow && peakAt >= leg.from && peakAt < leg.to,
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

    private let dir: URL
    private let enc: JSONEncoder
    private let dec: JSONDecoder

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = docs.appendingPathComponent("night-recaps", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        load()
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

    func delete(_ recap: NightRecap) {
        try? FileManager.default.removeItem(at: fileURL(recap.id))
        try? FileManager.default.removeItem(at: photoDir(recap.id))
        recaps.removeAll { $0.id == recap.id }
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
    func adoptPhotos(from stagingDir: URL, for recap: NightRecap) {
        let dest = photoDir(recap.id)
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        for stop in recap.stops {
            for filename in stop.photoFilenames {
                let src = stagingDir.appendingPathComponent(filename)
                guard FileManager.default.fileExists(atPath: src.path) else { continue }
                try? FileManager.default.moveItem(
                    at: src,
                    to: dest.appendingPathComponent(filename)
                )
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

// MARK: - Lightbox

/// Which photos to show full-screen, and where to start.
struct LightboxContext: Identifiable {
    let id = UUID()
    let urls: [URL]
    let startIndex: Int
}

/// Full-screen photo viewer — swipe between a stop's photos, tap X (or
/// swipe down) to leave.
struct PhotoLightbox: View {
    let context: LightboxContext
    let onClose: () -> Void

    @State private var current: Int

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
            .padding(18)
        }
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

                if CameraCaptureView.isAvailable {
                    addButton(icon: "camera.fill", label: "SCHNAP", action: onSchnap)
                }
                addButton(icon: "photo.on.rectangle", label: "LIBRARY", action: onLibrary)
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
struct NightRecapView: View {
    @ObservedObject var history: RecapHistoryStore
    /// Local working copy — photo additions update it in place (the
    /// store persists them and hands back the updated value).
    @State private var recap: NightRecap
    let isReplay: Bool
    /// Called from the closing button. The live END presenter performs
    /// the actual sesh teardown here; replay just dismisses.
    let onFinish: () -> Void

    init(
        recap: NightRecap,
        history: RecapHistoryStore,
        isReplay: Bool = false,
        onFinish: @escaping () -> Void
    ) {
        _recap = State(initialValue: recap)
        self.history = history
        self.isReplay = isReplay
        self.onFinish = onFinish
    }

    private enum Stage: Equatable {
        case intro
        case stop(Int)
        case overview
    }

    @State private var stage: Stage = .intro
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
            CameraCaptureView { data in
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
            Text("Your night,")
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

            StopPhotoStrip(
                photoURLs: stop.photoFilenames.map { history.photoURL($0, in: recap.id) },
                onTapPhoto: { index in
                    lightbox = LightboxContext(
                        urls: stop.photoFilenames.map { history.photoURL($0, in: recap.id) },
                        startIndex: index
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

            if isReplay {
                Button {
                    onFinish()
                } label: {
                    Text("DONE")
                        .font(.system(size: 13, weight: .black, design: .monospaced))
                        .tracking(2.4)
                        .foregroundStyle(Color.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Capsule().fill(Color.cream))
                }
                .buttonStyle(PressScaleStyle())
            } else {
                // The night is already on disk (saved at END-confirm so a
                // crash can't lose it) — "save" keeps it in Past nights,
                // the quieter option deletes it (photos included) on the
                // way out.
                VStack(spacing: 10) {
                    Button {
                        onFinish()
                    } label: {
                        Text("SAVE RECAP & END SESH")
                            .font(.system(size: 13, weight: .black, design: .monospaced))
                            .tracking(2.0)
                            .foregroundStyle(Color.ink)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(Capsule().fill(Color.cream))
                    }
                    .buttonStyle(PressScaleStyle())

                    Button {
                        history.delete(recap)
                        onFinish()
                    } label: {
                        Text("END WITHOUT SAVING")
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

    /// Which page is showing. Follows new stops automatically (jumps to
    /// the newest) until the user swipes elsewhere.
    @State private var page = 0
    @State private var pukePickerOpen = false

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
    /// grows an extra "in-between" page that collects loose photos.
    private var checkedIn: Bool {
        journey.stops.last(where: { $0.kind == .bar && $0.departedAt == nil }) != nil
    }
    private var showLoosePage: Bool { !checkedIn }
    private var pageCount: Int { journey.stops.count + (showLoosePage ? 1 : 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.whiskey)
                Text("NIGHT SNAPS")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(Color.bronze)
                Spacer()
                // Drop a marker on the night — shows up in the pager
                // and the recap, photos attachable like any stop.
                markerButton("🍔") { journey.addMarker(kind: .food) }
                markerButton("🤮") {
                    if pukeCandidates.isEmpty {
                        journey.addMarker(kind: .puke)
                    } else {
                        pukePickerOpen = true
                    }
                }
            }

            // One page per stop (+ the in-between page when not checked
            // in anywhere) — swipe, or use the chevrons.
            TabView(selection: $page) {
                ForEach(Array(journey.stops.enumerated()), id: \.element.id) { i, stop in
                    stopPage(stop, isCurrent: i == journey.stops.count - 1)
                        .tag(i)
                }
                if showLoosePage {
                    loosePage.tag(journey.stops.count)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 112)
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: page)

            if pageCount > 1 {
                HStack(spacing: 10) {
                    pagerChevron("chevron.left", enabled: page > 0) { page -= 1 }
                    HStack(spacing: 5) {
                        ForEach(0..<pageCount, id: \.self) { i in
                            Circle()
                                .fill(i == page ? Color.whiskey : Color.cream.opacity(0.25))
                                .frame(width: i == page ? 7 : 5, height: i == page ? 7 : 5)
                                .onTapGesture { page = i }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    pagerChevron("chevron.right", enabled: page < pageCount - 1) { page += 1 }
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
        .onAppear { page = pageCount - 1 }
        .onChange(of: pageCount) { _, count in
            // New stop or check-in/out flipping the loose page → slide to
            // the freshest moment (also clamps if the loose page vanished).
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                page = max(0, count - 1)
            }
        }
        .confirmationDialog("Whose puke break?", isPresented: $pukePickerOpen, titleVisibility: .visible) {
            Button("Mine 🫡") { journey.addMarker(kind: .puke) }
            ForEach(pukeCandidates, id: \.self) { name in
                Button(name) {
                    journey.addMarker(kind: .puke, named: "\(name)'s puke break")
                }
            }
            Button("Cancel", role: .cancel) {}
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
            CameraCaptureView { data in
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

    /// The "right now, between places" page — pre-game before the first
    /// check-in, transit/afters later. Loose photos collect here and the
    /// recap files them onto the right leg by timestamp.
    private var loosePage: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(journey.stops.isEmpty ? "🏠 Pre-game" : "🌃 Between bars")
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

            StopPhotoStrip(
                photoURLs: journey.loosePhotos.map { journey.photoURL($0.filename) },
                onTapPhoto: { index in
                    lightbox = LightboxContext(
                        urls: journey.loosePhotos.map { journey.photoURL($0.filename) },
                        startIndex: index
                    )
                },
                onDeletePhoto: { index in
                    guard index < journey.loosePhotos.count else { return }
                    journey.removeLoosePhoto(journey.loosePhotos[index].filename)
                },
                onSchnap: { cameraTarget = CameraTarget(id: Self.looseTargetId) },
                onLibrary: {
                    libraryTargetStopId = Self.looseTargetId
                    libraryPickerOpen = true
                }
            )
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
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

    private func stopPage(_ stop: SeshStop, isCurrent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(stop.kind == .food ? "🍔 \(stop.name)"
                     : stop.kind == .puke ? "🤮 \(stop.name)"
                     : stop.name)
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .lineLimit(1)
                if isCurrent && stop.kind == .bar && checkedIn {
                    Text("HERE NOW")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.whiskey))
                }
                Spacer()
                Text(stop.arrivedAt, format: .dateTime.hour().minute())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.0)
                    .foregroundStyle(Color.bronze)
                if stop.kind != .bar {
                    // Markers are user-added — let a 1am mis-tap be undone.
                    Button {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                            page = max(0, page - 1)
                            journey.removeMarker(stop.id)
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.cream.opacity(0.5))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.cream.opacity(0.06)))
                    }
                    .buttonStyle(PressScaleStyle())
                }
            }

            StopPhotoStrip(
                photoURLs: stop.photoFilenames.map { journey.photoURL($0) },
                onTapPhoto: { index in
                    lightbox = LightboxContext(
                        urls: stop.photoFilenames.map { journey.photoURL($0) },
                        startIndex: index
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
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
