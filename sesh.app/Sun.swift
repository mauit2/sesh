// Sun — the "where's the sun" mode on the Deals map.
//
// Terraces are ranked by whether they have direct sun *right now* and for how
// much longer, from a horizon profile computed server-side (migration 071 +
// the sun-horizon Edge Function, which reads building heights from Mapbox
// vector tiles). All the time maths happens on-device in SunMath, so dragging
// the hour slider re-evaluates a whole city instantly and offline.
//
// Attribution: building data © Mapbox, © OpenStreetMap contributors.

import SwiftUI
import CoreLocation
import Combine
import Supabase
import MapKit

// MARK: - Model

/// One venue's sun profile, as served by venue_sun_map.
struct SunVenue: Decodable, Identifiable, Equatable {
    let venueId: UUID
    let name: String
    let lat: Double
    let lon: Double
    /// Tenths of a degree, 72 bins — unpacked into `horizon` on demand.
    let horizonTenths: [Int]
    let confidence: Double
    /// OSM amenity for imported venues: bar / pub / nightclub / restaurant.
    let kind: String?
    /// How readily this venue is drawn on the map. See the 076 migration.
    let prominence: Int
    /// IANA zone from the venue row, when we know it.
    let timeZoneId: String?
    /// True when a human corrected this venue's horizon by hand — local
    /// knowledge that the building model can't derive (a terrace tucked into
    /// a courtyard corner, say). The UI must not present it as modelled.
    let isOverride: Bool
    /// Bearing the seating faces, agreed from user reports (migration 090).
    /// nil means nobody has said, so the sunniest-facade guess was used.
    let facadeBearing: Int?
    /// How many people have reported it.
    let facadeReports: Int
    /// True shows the card's "outdoor seating" note; false and nil show
    /// nothing, so absence of data never reads as absence of a terrace.
    let outdoorSeating: Bool?

    var id: UUID { venueId }

    /// True when the vantage point came from people rather than the optimistic
    /// sunniest-facade guess.
    var facadeFromPeople: Bool { facadeBearing != nil && facadeReports > 0 }

    /// The reported direction as a compass point, for the pin's label.
    var facadeCompass: String? {
        guard let b = facadeBearing else { return nil }
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return names[Int(((Double(b) / 45).rounded())) % 8]
    }

    /// The venue's OWN time zone. This is what makes the feature work
    /// worldwide: the sun maths is latitude-agnostic, but "today" and "sun till
    /// 20:05" are not. Resolving those with the phone's calendar would stamp a
    /// Singapore terrace's sun window in Swedish time.
    var timeZone: TimeZone {
        if let id = timeZoneId, let tz = TimeZone(identifier: id) { return tz }
        // Fallback: 15° of longitude per hour. Ignores DST and political
        // boundaries, so it can be an hour out — but it is far closer than the
        // phone's zone for a bar on the other side of the planet, and the
        // client fills the real zone in from MapKit when it resolves a venue.
        let hours = Int((lon / 15).rounded())
        return TimeZone(secondsFromGMT: hours * 3600) ?? .current
    }

    /// A calendar in the venue's zone — the day boundary the sun windows use.
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
    var horizon: SunHorizon { SunHorizon(packedTenths: horizonTenths) }
    /// Below this the height data was too sparse to promise much.
    var isEstimate: Bool { confidence < 0.75 }

    enum CodingKeys: String, CodingKey {
        case venueId = "venue_id"
        case name, lat, lon, confidence, kind, prominence
        case timeZoneId = "time_zone"
        case isOverride = "is_override"
        case horizonTenths = "horizon"
        case facadeBearing = "facade_bearing"
        case facadeReports = "facade_reports"
        case outdoorSeating = "outdoor_seating"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        venueId = try c.decode(UUID.self, forKey: .venueId)
        name = try c.decode(String.self, forKey: .name)
        lat = try c.decode(Double.self, forKey: .lat)
        lon = try c.decode(Double.self, forKey: .lon)
        horizonTenths = try c.decode([Int].self, forKey: .horizonTenths)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        // Tolerated as absent so an older RPC shape still decodes.
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        prominence = try c.decodeIfPresent(Int.self, forKey: .prominence) ?? 60
        timeZoneId = try c.decodeIfPresent(String.self, forKey: .timeZoneId)
        isOverride = try c.decodeIfPresent(Bool.self, forKey: .isOverride) ?? false
        facadeBearing = try c.decodeIfPresent(Int.self, forKey: .facadeBearing)
        facadeReports = try c.decodeIfPresent(Int.self, forKey: .facadeReports) ?? 0
        outdoorSeating = try c.decodeIfPresent(Bool.self, forKey: .outdoorSeating)
    }
}

/// A venue plus what the sun is doing there at the previewed time.
struct SunReading: Identifiable, Equatable {
    let venue: SunVenue
    let state: SunState
    let at: Date

    var id: UUID { venue.id }
    var isSunlit: Bool { state.isSunlitNow }
    /// Direct sun left after the previewed moment.
    var remaining: TimeInterval { state.remaining(after: at) }

    /// Total direct sun across the WHOLE day, not just what's left — the
    /// "how good is this terrace, generally?" number.
    var sunHoursToday: TimeInterval {
        state.windows.reduce(0) { $0 + $1.duration }
    }

    /// e.g. "6h 20m of sun today"
    var dayTotalLabel: String {
        let t = Int(sunHoursToday)
        if t == 0 { return "No direct sun today" }
        let h = t / 3600, m = (t % 3600) / 60
        return (h > 0 ? "\(h)h \(m)m" : "\(m)m") + " of sun today"
    }

    /// Whether it's sunny *right now*, independent of the previewed time.
    func isSunlitNow(_ now: Date = Date()) -> Bool {
        state.windows.contains { $0.start <= now && now < $0.end }
    }

    /// Is the slider parked on the present?
    var previewingNow: Bool { abs(at.timeIntervalSinceNow) < 300 }

    /// Sun/shade at the PREVIEWED moment, labelled with which moment that is.
    /// Reading one line off the real clock and the next off the slider produced
    /// callouts that said "IN THE SUN NOW" directly above "SHADE".
    var stateLabel: String {
        let word = isSunlit ? "IN THE SUN" : "IN SHADE"
        if previewingNow { return word + " NOW" }
        return word + " AT " + Self.hhmm(venue.timeZone).string(from: at)
    }

    /// Short chip text: what a thirsty person actually wants to know.
    var chip: String {
        if isSunlit {
            guard let until = state.changesAt else { return "SUN" }
            return "SUN TILL " + Self.hhmm(venue.timeZone).string(from: until)
        }
        if let next = state.changesAt {
            return "SUN AT " + Self.hhmm(venue.timeZone).string(from: next)
        }
        return "SHADE"
    }

    /// Formatters are cached per zone: `chip` is read once per visible pin, so
    /// building a DateFormatter each time would be wasteful. Main-actor only.
    private static var formatters: [String: DateFormatter] = [:]

    static func hhmm(_ tz: TimeZone) -> DateFormatter {
        if let f = formatters[tz.identifier] { return f }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = tz
        formatters[tz.identifier] = f
        return f
    }

    /// Set when the venue keeps a different clock than the phone, so the UI can
    /// say whose time it is quoting.
    var foreignZoneNote: String? {
        let tz = venue.timeZone
        guard tz.secondsFromGMT(for: at) != TimeZone.current.secondsFromGMT(for: at)
        else { return nil }
        let city = tz.identifier.split(separator: "/").last.map {
            $0.replacingOccurrences(of: "_", with: " ")
        }
        return "local time" + (city.map { " in \($0)" } ?? "")
    }
}

// MARK: - Service

@MainActor
final class SunService: ObservableObject {
    @Published private(set) var venues: [SunVenue] = [] {
        didSet { rebuildReadings() }
    }
    @Published private(set) var loading = false
    /// The moment being previewed — "now", or wherever the slider was dragged.
    /// Rebuilding is cheap here because it no-ops unless the previewed time
    /// crosses a 5-minute sample boundary.
    @Published var previewAt: Date = Date() {
        didSet { rebuildReadings() }
    }

    private var lastFetchCentre: CLLocationCoordinate2D?
    /// Horizons already fetched, keyed by venue id. The visible set is driven
    /// by the map (see setVisible), so panning only ever costs the venues that
    /// are newly on screen.
    private var horizonCache: [UUID: SunVenue] = [:]

    /// THE SUN MAP'S PINS ARE THE BEER MAP'S PINS.
    ///
    /// The caller passes the venues the Beer map would draw — priced bars in
    /// view — and this fills in their horizons and rebuilds the readings from
    /// exactly that set. Previously the map asked "what venue_sun rows are
    /// within 25 km of here", which produced a different, independently-derived
    /// set that drifted from the Beer map and, worse, never followed a pan.
    ///
    /// Cached by id, so a pan fetches only what is new and a switch back to Sun
    /// fetches nothing at all.
    func setVisible(_ wanted: [Venue]) async {
        // An empty set is a real answer — "no terraces near where you're
        // looking" — and must clear the map. Early-returning here left the
        // previous city's readings (and its "116 in the sun" header) published
        // while the user was on another continent.
        guard !wanted.isEmpty else {
            if !venues.isEmpty { venues = [] }
            return
        }
        let missing = wanted.map(\.id).filter { horizonCache[$0] == nil }
        if !missing.isEmpty {
            struct P: Encodable { let p_ids: [UUID] }
            if let rows: [SunVenue] = try? await supabase
                .rpc("venue_sun_by_ids", params: P(p_ids: missing))
                .execute().value {
                for r in rows { horizonCache[r.venueId] = r }
            }
        }
        let next = wanted.compactMap { horizonCache[$0.id] }
        // Identity check before publishing: this is called on every pin rebuild
        // and an unchanged set must not invalidate the map.
        if next.map(\.venueId) != venues.map(\.venueId) {
            venues = next
        }
        // Venues with no horizon yet (freshly added bars) get one computed.
        let unresolved = wanted.filter { horizonCache[$0.id] == nil }
        if !unresolved.isEmpty {
            Task { [weak self] in await self?.warmIds(unresolved.prefix(4).map(\.id)) }
        }
    }

    /// Kick the Edge Function for venues that have no stored horizon. Capped
    /// hard — each call fetches nine Mapbox tiles and ray-casts twelve facades.
    private func warmIds(_ ids: [UUID]) async {
        for id in ids {
            struct B: Encodable { let venue_id: String }
            _ = try? await supabase.functions.invoke(
                "sun-horizon", options: .init(body: B(venue_id: id.uuidString))
            ) as Data?
        }
    }

    /// Fetch horizons around a coordinate, then nudge the Edge Function to
    /// compute any venues nearby that don't have one yet (fire and forget —
    /// they'll appear on the next look).
    func load(near centre: CLLocationCoordinate2D, radiusMeters: Double = 25_000) async {
        loading = true
        defer { loading = false }
        struct P: Encodable {
            let p_lat: Double
            let p_lon: Double
            let p_radius_m: Double
        }
        let params = P(p_lat: centre.latitude, p_lon: centre.longitude, p_radius_m: radiusMeters)
        if let rows: [SunVenue] = try? await supabase
            .rpc("venue_sun_map", params: params).execute().value {
            venues = rows
            rebuildReadings()
        }
        lastFetchCentre = centre
        // NOT awaited. warmMissing invokes the sun-horizon function for venues
        // that have no profile yet, and each call fetches nine Mapbox tiles and
        // ray-casts twelve facades — 1-3 seconds apiece. Awaiting six of those
        // held `loading` true and made switching into Sun mode take 5-10
        // seconds. They fill themselves in and appear on the next pass.
        Task { [weak self] in
            await self?.warmMissing(near: centre, radiusMeters: radiusMeters)
        }
    }

    /// Ask for up to a handful of uncomputed venues and kick off their
    /// horizons. Deliberately capped — one pass shouldn't fan out to a
    /// hundred tile fetches.
    private func warmMissing(near centre: CLLocationCoordinate2D, radiusMeters: Double) async {
        struct P: Encodable {
            let p_lat: Double
            let p_lon: Double
            let p_radius_m: Double
            let p_limit: Int
        }
        struct Row: Decodable { let venue_id: UUID }
        guard let rows: [Row] = try? await supabase
            .rpc("venues_missing_sun",
                 params: P(p_lat: centre.latitude, p_lon: centre.longitude,
                           p_radius_m: radiusMeters, p_limit: 6))
            .execute().value, !rows.isEmpty else { return }

        // In parallel, not one after another: these are independent and each
        // takes a second or more.
        await withTaskGroup(of: Void.self) { group in
            for row in rows {
                group.addTask {
                    struct Body: Encodable { let venue_id: String }
                    _ = try? await supabase.functions.invoke(
                        "sun-horizon",
                        options: FunctionInvokeOptions(
                            body: Body(venue_id: row.venue_id.uuidString))
                    ) as Data?
                }
            }
        }
        // Pick up whatever landed.
        if let refreshed: [SunVenue] = try? await supabase
            .rpc("venue_sun_map",
                 params: ["p_lat": centre.latitude, "p_lon": centre.longitude,
                          "p_radius_m": radiusMeters])
            .execute().value {
            venues = refreshed
            rebuildReadings()
        }
    }

    // MARK: Search
    //
    // The map only draws prominent venues, otherwise a city of a thousand
    // restaurants is unreadable. Search reaches ALL of them, and whatever you
    // pick gets pinned so you can watch the sun cross that one terrace.

    @Published var searchQuery: String = ""
    @Published private(set) var searchResults: [SunVenue] = []
    @Published private(set) var searching = false
    /// A venue surfaced by search, kept on the map even if it's below the
    /// prominence cut-off.
    @Published var pinned: SunVenue? {
        didSet { rebuildReadings() }
    }

    private var searchTask: Task<Void, Never>?

    /// Debounced so typing doesn't fire a query per keystroke.
    func search(near centre: CLLocationCoordinate2D?) {
        searchTask?.cancel()
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { searchResults = []; searching = false; return }
        searching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled, let self else { return }
            struct P: Encodable {
                let p_query: String
                let p_lat: Double?
                let p_lon: Double?
                let p_limit: Int
            }
            let rows: [SunVenue]? = try? await supabase
                .rpc("search_sun_venues",
                     params: P(p_query: q, p_lat: centre?.latitude,
                               p_lon: centre?.longitude, p_limit: 20))
                .execute().value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.searchResults = rows ?? []
                self.searching = false
            }
        }
    }

    func clearSearch() {
        searchTask?.cancel()
        searchQuery = ""
        searchResults = []
        searching = false
    }

    // MARK: Worldwide lookup
    //
    // We only hold horizons for venues someone has already looked at. For a bar
    // in Singapore or Tokyo the flow is: Apple Maps resolves the place, we
    // create the venue row, the Edge Function computes its horizon from Mapbox
    // building tiles (which are global), and the same on-device maths then works
    // at any latitude. Nothing about the model is Gothenburg-specific.

    @Published private(set) var preparing = false
    @Published var lookupError: String?

    /// Compute-and-pin a venue we may never have seen before.
    /// - Parameter zone: the IANA zone MapKit reported, so times read in the
    ///   venue's own clock rather than the phone's.
    @discardableResult
    func prepareAndPin(venueId: UUID, zone: TimeZone?) async -> SunVenue? {
        preparing = true
        lookupError = nil
        defer { preparing = false }

        if let zone {
            struct Z: Encodable { let p_venue_id: String; let p_zone: String }
            _ = try? await supabase.rpc("set_venue_time_zone",
                                        params: Z(p_venue_id: venueId.uuidString,
                                                  p_zone: zone.identifier)).execute()
        }

        // Already computed? Then skip straight to it.
        if let existing = await fetchSunVenue(venueId) {
            pinned = existing
            return existing
        }

        struct Body: Encodable { let venue_id: String }
        _ = try? await supabase.functions.invoke(
            "sun-horizon",
            options: FunctionInvokeOptions(body: Body(venue_id: venueId.uuidString))
        ) as Data?

        guard let made = await fetchSunVenue(venueId) else {
            lookupError = "Couldn't work out the sun here yet. Try again in a moment."
            return nil
        }
        pinned = made
        return made
    }

    private func fetchSunVenue(_ id: UUID) async -> SunVenue? {
        struct P: Encodable { let p_venue_id: String }
        let rows: [SunVenue]? = try? await supabase
            .rpc("sun_venue", params: P(p_venue_id: id.uuidString))
            .execute().value
        return rows?.first
    }

    /// Sun readings for the previewed moment, sunniest first.
    ///
    /// CACHED, and that matters: the view reads this from several places per
    /// render, and recomputing 150 venues x 288 sun samples each time made the
    /// map crawl. Recomputed only when the inputs actually change, and off a
    /// single shared `SunTrack` rather than redoing the NOAA maths per venue.
    @Published private(set) var readings: [SunReading] = []

    private var cacheKey: String = ""

    private func rebuildReadings(calendar: Calendar = .current) {
        var shown = venues
        // A searched venue may be outside the prominence baseline entirely.
        if let p = pinned, !shown.contains(where: { $0.id == p.id }) {
            shown.append(p)
        }
        // Quantise the previewed time to the track's own resolution, so a slider
        // drag only rebuilds when it crosses a 5-minute sample.
        let bucket = Int(previewAt.timeIntervalSince1970 / 300)
        let key = "\(bucket)-\(shown.count)-\(shown.first?.id.uuidString ?? "")-\(pinned?.id.uuidString ?? "")"
        guard key != cacheKey else { return }
        cacheKey = key

        let at = previewAt
        var tracks: [String: SunTrack] = [:]
        readings = shown.compactMap { v -> SunReading? in
            // One track per ~55 km cell AND per time zone. Sharing a single
            // track across a city is what keeps this fast, but sharing it across
            // the planet would be wrong — a venue pinned from a worldwide search
            // can be in Singapore while the map is centred on Gothenburg.
            let key = "\(Int((v.lat * 2).rounded()))_\(Int((v.lon * 2).rounded()))_\(v.timeZone.identifier)"
            let track: SunTrack
            if let cached = tracks[key] {
                track = cached
            } else if let fresh = SunTrack.forDay(at, latitude: v.lat, longitude: v.lon,
                                                  calendar: v.calendar) {
                tracks[key] = fresh
                track = fresh
            } else {
                return nil
            }
            return SunReading(venue: v,
                              state: SunEngine.state(horizon: v.horizon, track: track, now: at),
                              at: at)
        }
        .sorted {
            if $0.isSunlit != $1.isSunlit { return $0.isSunlit }
            return $0.remaining > $1.remaining
        }
    }

    /// Call after anything that changes venues, the pin, or the previewed time.
    func refreshReadings() { rebuildReadings() }

    // MARK: - User corrections

    @Published var reportingFacade = false
    @Published var facadeError: String?

    /// Tell the server which way a venue's seating faces, then recompute its
    /// horizon from that side.
    ///
    /// This is NOT an override of the model — it feeds it. The building still
    /// blocks whatever it blocks; we just stop guessing the one fact vector
    /// tiles cannot carry (where the terrace is), which the sunniest-facade
    /// heuristic was getting wrong in an optimistic direction.
    func reportFacade(venueId: UUID, bearing: Int) async -> Bool {
        reportingFacade = true
        facadeError = nil
        defer { reportingFacade = false }
        struct P: Encodable { let p_venue: UUID; let p_bearing: Int }
        do {
            _ = try await supabase
                .rpc("report_sun_facade", params: P(p_venue: venueId, p_bearing: bearing))
                .execute()
        } catch {
            facadeError = "Couldn't save that — try again."
            return false
        }
        // Recompute with the new bearing. Awaited, unlike the background warms:
        // the user is watching for their correction to take effect.
        struct B: Encodable { let venue_id: String }
        _ = try? await supabase.functions.invoke(
            "sun-horizon", options: .init(body: B(venue_id: venueId.uuidString))
        ) as Data?
        // REFETCH NOW, not on the next pass. Dropping the cache entry and
        // waiting for the map to ask again meant the pin kept showing the old
        // sun until something else happened to trigger a rebuild — the
        // correction looked like it hadn't worked.
        horizonCache[venueId] = nil
        struct Q: Encodable { let p_ids: [UUID] }
        if let rows: [SunVenue] = try? await supabase
            .rpc("venue_sun_by_ids", params: Q(p_ids: [venueId]))
            .execute().value, let fresh = rows.first {
            horizonCache[venueId] = fresh
            // Swap it into the published set in place, so readings rebuild and
            // the pin redraws immediately.
            if let i = venues.firstIndex(where: { $0.venueId == venueId }) {
                var next = venues
                next[i] = fresh
                venues = next          // didSet -> rebuildReadings()
            } else {
                rebuildReadings()
            }
            // rebuildReadings caches on (time bucket, count, first id): a swap
            // changes none of those, so nudge it past the guard.
            cacheKey = ""
            rebuildReadings()
        }
        return true
    }
}

// MARK: - Map annotation

/// A sun pin: bright and warm when lit, muted when shaded, with the bar's
/// name attached under it and the timing spelled out on tap.
struct SunPin: View {
    let reading: SunReading
    let selected: Bool
    let onTap: () -> Void
    /// Shown only while selected: lets the person standing there tell us which
    /// way the seating faces, which is the one input the building model can't
    /// derive for itself.
    var onEdit: (() -> Void)? = nil
    @State private var glowing = false

    private var tint: Color {
        reading.isSunlit
            ? Color(red: 1.0, green: 0.79, blue: 0.28)     // sunlight
            : Color(red: 0.42, green: 0.46, blue: 0.56)     // shade
    }

    var body: some View {
        ZStack {
            if reading.isSunlit {
                // The glow only PULSES for the selected pin. A whole city of
                // pins each running a repeatForever animation is a lot of
                // concurrent animation for no extra information.
                Circle()
                    .fill(RadialGradient(colors: [tint.opacity(0.5), tint.opacity(0)],
                                         center: .center, startRadius: 2, endRadius: 34))
                    .frame(width: 68, height: 68)
                    .scaleEffect(selected ? (glowing ? 1.1 : 0.92) : 1.0)
                    .animation(selected
                        ? .easeInOut(duration: 2.2).repeatForever(autoreverses: true)
                        : .default, value: glowing)
            }
            Circle()
                .fill(tint)
                .frame(width: reading.isSunlit ? 20 : 13,
                       height: reading.isSunlit ? 20 : 13)
                .overlay(Circle().strokeBorder(Color.ink.opacity(0.55), lineWidth: 1))
                .shadow(color: tint.opacity(reading.isSunlit ? 0.9 : 0.3), radius: 6)
            if reading.isSunlit {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(Color(red: 0.35, green: 0.22, blue: 0.02))
            }
        }
        .frame(width: 68, height: 68)
        .overlay(alignment: .center) {
            Text(reading.venue.name)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(Color.cream)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Capsule().fill(Color.ink.opacity(0.78)))
                .overlay(Capsule().strokeBorder(tint.opacity(0.45), lineWidth: 1))
                .offset(y: 24)
        }
        .overlay(alignment: .center) {
            if selected {
                // Tapping a pin answers two questions: is it sunny there NOW,
                // and how much sun does that terrace get in a day at all.
                VStack(spacing: 3) {
                    Text(reading.stateLabel)
                        .font(.system(size: 8.5, weight: .black, design: .monospaced))
                        .tracking(1.1)
                        .foregroundStyle(reading.isSunlit ? tint : Color.cream.opacity(0.72))
                    Text(reading.chip)
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .tracking(1.1)
                        .foregroundStyle(Color.cream)
                    Text(reading.dayTotalLabel.uppercased())
                        .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(Color.cream.opacity(0.6))
                    // Orthogonal to the facade/override rows below — a bar can
                    // have both. Only TRUE draws; nil stays silent by design.
                    // Sized to be readable at a glance, not squinted at: this
                    // is the fact that decides whether you walk there.
                    if reading.venue.outdoorSeating == true {
                        Label("OUTDOOR SEATING", systemImage: "chair.lounge.fill")
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                            .tracking(1.1)
                            .foregroundStyle(Color(red: 1.0, green: 0.79, blue: 0.28))
                            .padding(.top, 1)
                    }
                    // Whose clock we're quoting, when it isn't the phone's.
                    if let note = reading.foreignZoneNote {
                        Text(note.uppercased())
                            .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                            .tracking(0.9)
                            .foregroundStyle(Color.cream.opacity(0.4))
                    }
                    if let onEdit {
                        Button(action: onEdit) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.trianglehead.turn.up.right.circle.fill")
                                    .font(.system(size: 10, weight: .bold))
                                Text(reading.venue.facadeFromPeople || reading.venue.isOverride
                                     ? "EDIT SPOT" : "WRONG SPOT?")
                                    .font(.system(size: 10, weight: .black, design: .monospaced))
                                    .tracking(0.8)
                            }
                            .foregroundStyle(Color.ink)
                            .padding(.horizontal, 11).padding(.vertical, 7)
                            .background(Capsule().fill(tint))
                            .shadow(color: Color.ink.opacity(0.5), radius: 3, y: 1)
                            // A 7pt capsule was under Apple's 44pt minimum and
                            // easy to miss entirely; this widens the tap target
                            // without letting the card dominate the map.
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                    }
                    if reading.venue.facadeFromPeople, let dir = reading.venue.facadeCompass {
                        // Checked before isOverride: a facade report is the
                        // route users actually have, and it was previously
                        // invisible — corrections showed no sign of landing.
                        Text(reading.venue.facadeReports == 1
                             ? "SEATS FACE \(dir) · 1 REPORT"
                             : "SEATS FACE \(dir) · \(reading.venue.facadeReports) REPORTS")
                            .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                            .tracking(1)
                            .foregroundStyle(Color(red: 1.0, green: 0.79, blue: 0.28))
                    } else if reading.venue.isOverride {
                        Text("SET BY HAND")
                            .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                            .tracking(1)
                            .foregroundStyle(Color.bronze)
                    } else if reading.venue.isEstimate {
                        Text("ESTIMATED")
                            .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                            .tracking(1)
                            .foregroundStyle(Color.bronze)
                    }
                }
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.ink.opacity(0.94)))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(tint.opacity(0.7), lineWidth: 1))
                .offset(y: -44)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .contentShape(Circle())
        .onTapGesture { withAnimation(.spring(duration: 0.32)) { onTap() } }
        .onAppear { glowing = true }
    }
}

// MARK: - Search

/// Find any venue by name — including the ~800 restaurants the map doesn't draw
/// by default — and pin it so the sun can be followed across it.
struct SunSearchSheet: View {
    @ObservedObject var sun: SunService
    let centre: CLLocationCoordinate2D?
    /// Called with the chosen venue so the map can fly to it.
    let onPick: (SunVenue) -> Void
    /// A place Apple Maps found that we hold no sun profile for yet. The caller
    /// creates the venue, has its horizon computed, and pins it.
    let onPickWorldwide: (MapKitVenueResult) -> Void
    @Environment(\.dismiss) private var dismiss

    /// Anywhere on earth, not just venues already in our database.
    @StateObject private var world = MapKitVenueSearch()

    private let sunny = Color(red: 1.0, green: 0.79, blue: 0.28)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("FIND A PLACE")
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .tracking(1.6)
                .foregroundStyle(Color.cream.opacity(0.6))
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 12)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.cream.opacity(0.45))
                TextField("Any bar, anywhere", text: $sun.searchQuery)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .onChange(of: sun.searchQuery) { _, _ in
                        sun.search(near: centre)
                        // Apple Maps in parallel, unbiased to the user's own
                        // location, so "Atlas Bar" finds Singapore from Sweden.
                        world.search(query: sun.searchQuery,
                                     origin: centre.map {
                                         CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                                     },
                                     biasToOrigin: false)
                    }
                if !sun.searchQuery.isEmpty {
                    Button { sun.clearSearch() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.cream.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.cream.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.cream.opacity(0.12), lineWidth: 1))
            .padding(.horizontal, 20)

            if sun.preparing {
                HStack(spacing: 8) {
                    ProgressView().tint(sunny)
                    Text("Working out the sun there…")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.6))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 22)
            } else if let err = sun.lookupError {
                Text(err)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.bronze)
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    // Venues we already hold a sun profile for: instant stats.
                    ForEach(sun.searchResults) { v in
                        let reading = SunReading(
                            venue: v,
                            state: SunEngine.state(horizon: v.horizon, track:
                                SunTrack.forDay(sun.previewAt, latitude: v.lat,
                                                longitude: v.lon, calendar: v.calendar)
                                ?? SunTrack(midnight: sun.previewAt, stepMinutes: 5,
                                            altitude: [], azimuth: []),
                                now: sun.previewAt),
                            at: sun.previewAt)
                        Button {
                            onPick(v)
                            dismiss()
                        } label: {
                            SunSearchRow(reading: reading)
                        }
                        .buttonStyle(PressScaleStyle())
                    }

                    // Anywhere else on earth. Picking one computes its horizon
                    // from global building data, then pins it.
                    let known = Set(sun.searchResults.map { $0.name.lowercased() })
                    let elsewhere = world.results.filter { !known.contains($0.name.lowercased()) }
                    if !elsewhere.isEmpty {
                        HStack {
                            Text("ANYWHERE ELSE")
                                .font(.system(size: 9, weight: .black, design: .monospaced))
                                .tracking(1.4)
                                .foregroundStyle(Color.cream.opacity(0.35))
                            Spacer()
                        }
                        .padding(.top, sun.searchResults.isEmpty ? 4 : 16)
                        .padding(.bottom, 2)

                        ForEach(elsewhere) { r in
                            Button {
                                onPickWorldwide(r)
                                dismiss()
                            } label: {
                                SunWorldRow(result: r)
                            }
                            .buttonStyle(PressScaleStyle())
                        }
                    }

                    if sun.searchQuery.count >= 2 && sun.searchResults.isEmpty
                        && elsewhere.isEmpty && !world.isSearching && !sun.searching {
                        Text("Nothing by that name.")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.45))
                            .padding(.top, 24)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 30)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.ink.ignoresSafeArea())
    }
}

/// A place from Apple Maps we don't have a sun profile for yet.
private struct SunWorldRow: View {
    let result: MapKitVenueResult

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "globe")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.cream.opacity(0.35))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .lineLimit(1)
                if let where_ = result.city ?? result.address {
                    Text(where_)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.45))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Text("GET SUN")
                .font(.system(size: 8.5, weight: .black, design: .monospaced))
                .tracking(0.9)
                .foregroundStyle(Color.cream.opacity(0.75))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().strokeBorder(Color.cream.opacity(0.22), lineWidth: 1))
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(Color.cream.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .strokeBorder(Color.cream.opacity(0.08), lineWidth: 1))
    }
}

private struct SunSearchRow: View {
    let reading: SunReading
    private var sunny: Color { Color(red: 1.0, green: 0.79, blue: 0.28) }

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: reading.isSunlit ? "sun.max.fill" : "cloud.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(reading.isSunlit ? sunny : Color.cream.opacity(0.3))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(reading.venue.name)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .lineLimit(1)
                Text(reading.dayTotalLabel)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.5))
            }
            Spacer(minLength: 6)
            Text(reading.chip)
                .font(.system(size: 8.5, weight: .black, design: .monospaced))
                .tracking(0.9)
                .foregroundStyle(reading.isSunlit ? Color.ink : Color.cream.opacity(0.7))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(reading.isSunlit
                    ? sunny : Color.cream.opacity(0.09)))
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(Color.cream.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .strokeBorder(Color.cream.opacity(0.1), lineWidth: 1))
    }
}

// MARK: - Time scrubber

/// Drag to see where the sun will be later — the thing that turns this from a
/// snapshot into "where should we go at eight?".
struct SunTimeSlider: View {
    @Binding var previewAt: Date
    /// A calendar in the zone of the PLACE BEING LOOKED AT, not the phone's.
    /// Scrubbing to "06:00" has to mean six in the morning where the bar is,
    /// otherwise the map's daylight and the slider disagree — which is exactly
    /// what happened looking up a Gothenburg bar from a San Francisco location.
    let calendar: Calendar
    /// e.g. "Gothenburg" — named so it's obvious whose clock this is.
    var zoneName: String? = nil

    private var minutesFromMidnight: Double {
        let c = calendar.dateComponents([.hour, .minute], from: previewAt)
        return Double((c.hour ?? 0) * 60 + (c.minute ?? 0))
    }

    /// The same instant on the phone's clock, when that differs.
    private var yourTime: String? {
        guard calendar.timeZone.secondsFromGMT(for: previewAt)
            != TimeZone.current.secondsFromGMT(for: previewAt) else { return nil }
        return SunReading.hhmm(.current).string(from: previewAt)
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(isNow ? "NOW"
                     : SunReading.hhmm(calendar.timeZone).string(from: previewAt))
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(Color(red: 1.0, green: 0.79, blue: 0.28))
                // Whose clock, and what that is on yours.
                if let zoneName {
                    Text("IN " + zoneName.uppercased())
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .tracking(0.9)
                        .foregroundStyle(Color.cream.opacity(0.5))
                        .lineLimit(1)
                }
                if let yourTime {
                    Text("· " + yourTime + " YOUR TIME")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .tracking(0.9)
                        .foregroundStyle(Color.cream.opacity(0.38))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if !isNow {
                    Button { previewAt = Date() } label: {
                        Text("BACK TO NOW")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .tracking(1.2)
                            .foregroundStyle(Color.bronze)
                    }
                    .buttonStyle(.plain)
                }
            }
            Slider(
                value: Binding(
                    get: { minutesFromMidnight },
                    set: { m in
                        guard let midnight = calendar.dateInterval(of: .day, for: Date())?.start
                        else { return }
                        previewAt = midnight.addingTimeInterval(m * 60)
                    }
                ),
                in: 0...(24 * 60 - 1), step: 15
            )
            .tint(Color(red: 1.0, green: 0.79, blue: 0.28))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.ink.opacity(0.88)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.cream.opacity(0.12), lineWidth: 1))
    }

    private var isNow: Bool { abs(previewAt.timeIntervalSinceNow) < 60 }
}

// MARK: - List

/// Sunniest-first list, the alternative to hunting the map.
struct SunListSheet: View {
    /// Already filtered to within `radiusKm` of the PHONE — a list mixing bars
    /// on two continents is not a "nearby" list, and neither is one centred on
    /// wherever the map was last dragged.
    let readings: [SunReading]
    /// False when there is no location fix, in which case the list cannot be
    /// answered at all and we say that rather than showing something arbitrary.
    var haveLocation: Bool = true
    var radiusKm: Int = 5
    /// Where "nearby" is centred, named for the empty state.
    var placeName: String? = nil
    @ObservedObject var sun: SunService
    var centre: CLLocationCoordinate2D? = nil
    var onPick: ((SunVenue) -> Void)? = nil
    var onPickWorldwide: ((MapKitVenueResult) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    /// Anywhere on earth, for the search field below.
    @StateObject private var world = MapKitVenueSearch()

    private var searching: Bool {
        sun.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            VStack(spacing: 10) {
                VStack(spacing: 3) {
                    Text(searching ? "ANY BAR, ANYWHERE"
                         : haveLocation ? "WITHIN \(radiusKm) KM OF YOU" : "AROUND THE MAP")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(3)
                        .foregroundStyle(Color.bronze)
                    Text(searching ? "Search results" : "Sunniest first")
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.cream)
                    if !searching {
                        Text(haveLocation
                             ? "Only bars near you — search below for anywhere else."
                             : "Turn on location to see the bars around you, or search below.")
                            .font(.system(size: 11.5, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.5))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                }
                .padding(.top, 20)

                // Look up a specific bar's sun without leaving the list.
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.cream.opacity(0.4))
                    TextField("Search any bar, anywhere", text: $sun.searchQuery)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.cream)
                        .onChange(of: sun.searchQuery) { _, _ in
                            sun.search(near: centre)
                            world.search(query: sun.searchQuery,
                                         origin: centre.map {
                                             CLLocation(latitude: $0.latitude,
                                                        longitude: $0.longitude)
                                         },
                                         biasToOrigin: false)
                        }
                    if !sun.searchQuery.isEmpty {
                        Button { sun.clearSearch() } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.cream.opacity(0.35))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 13).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.cream.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.cream.opacity(0.12), lineWidth: 1))
                .padding(.horizontal, 16)

                if sun.preparing {
                    HStack(spacing: 8) {
                        ProgressView().tint(Color(red: 1.0, green: 0.79, blue: 0.28))
                        Text("Working out the sun there…")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.6))
                    }
                }

                if !searching && readings.isEmpty {
                    // The San Francisco case: no data near you is not "all in
                    // shade", and saying so was misleading.
                    VStack(spacing: 6) {
                        Text("No sun data\(placeName.map { " near \($0)" } ?? " nearby") yet")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.7))
                        Text("Search for a bar above and its sun hours\nwill be worked out on the spot.")
                            .multilineTextAlignment(.center)
                            .font(.system(size: 11.5, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.45))
                    }
                    .padding(.top, 26)
                    .padding(.horizontal, 30)
                }

                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 8) {
                        if searching {
                            ForEach(sun.searchResults) { v in
                                let r = SunReading(
                                    venue: v,
                                    state: SunEngine.state(
                                        horizon: v.horizon, latitude: v.lat,
                                        longitude: v.lon, now: sun.previewAt,
                                        calendar: v.calendar),
                                    at: sun.previewAt)
                                Button { onPick?(v); dismiss() } label: {
                                    SunSearchRow(reading: r)
                                }
                                .buttonStyle(PressScaleStyle())
                            }
                            let known = Set(sun.searchResults.map { $0.name.lowercased() })
                            let elsewhere = world.results.filter {
                                !known.contains($0.name.lowercased())
                            }
                            if !elsewhere.isEmpty {
                                HStack {
                                    Text("ANYWHERE ELSE")
                                        .font(.system(size: 9, weight: .black, design: .monospaced))
                                        .tracking(1.4)
                                        .foregroundStyle(Color.cream.opacity(0.35))
                                    Spacer()
                                }
                                .padding(.top, sun.searchResults.isEmpty ? 2 : 14)
                                ForEach(elsewhere) { res in
                                    Button { onPickWorldwide?(res); dismiss() } label: {
                                        SunWorldRow(result: res)
                                    }
                                    .buttonStyle(PressScaleStyle())
                                }
                            }
                        }
                        ForEach(searching ? [] : readings) { r in
                            HStack(spacing: 10) {
                                Image(systemName: r.isSunlit ? "sun.max.fill" : "cloud.fill")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(r.isSunlit
                                        ? Color(red: 1.0, green: 0.79, blue: 0.28)
                                        : Color.cream.opacity(0.35))
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.venue.name)
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                        .foregroundStyle(Color.cream)
                                        .lineLimit(1)
                                    Text(r.venue.isEstimate ? "\(r.chip) · estimated" : r.chip)
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .tracking(0.8)
                                        .foregroundStyle(Color.cream.opacity(0.55))
                                }
                                Spacer()
                                if r.remaining > 0 {
                                    Text(Self.hours(r.remaining))
                                        .font(.system(size: 12, weight: .black, design: .monospaced))
                                        .foregroundStyle(Color.cream.opacity(0.8))
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.cream.opacity(0.04)))
                        }
                    }
                    .padding(.horizontal, 20)

                    Text("Sun times are modelled from building heights — © Mapbox, © OpenStreetMap contributors. Awnings, trees and umbrellas aren't in the model.")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.35))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                        .padding(.top, 14)
                        .padding(.bottom, 26)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private static func hours(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        return m >= 60 ? "\(m / 60)h\(String(format: "%02d", m % 60))" : "\(m)m"
    }
}

/// "Which way do you sit?" — the one fact the building model can't derive from
/// vector tiles, asked of the person actually standing there.
///
/// PRESENTED AS A COMPASS, NOT A LIST. The first version was a 4x2 grid of
/// "N NE E SE / S SW W NW" chips with little rotated arrows, which asks the user
/// to translate a physical direction into a bearing and then find that bearing
/// in reading order. Nobody thinks that way about a terrace. This lays the eight
/// points out where they actually are — north at the top, clockwise — so picking
/// one is spatial rather than lexical.
///
/// AND IT SAYS WHAT EACH CHOICE MEANS. "West" is an abstraction; "afternoon and
/// evening sun" is the thing the user can check against memory, which makes a
/// wrong tap obvious before they commit. That mapping flips below the equator,
/// so it is derived from the venue's own latitude rather than hardcoded.
/// The Sun map's "+": tell us a bar has outdoor seating, and which way it
/// faces. Two steps in one sheet — find the bar, then the same compass rose
/// the facade editor uses. The terrace flag is reported the moment a bar is
/// picked (that alone is worth having); the facing step can be skipped by a
/// user who doesn't remember which way the seats point.
struct AddOutdoorSheet: View {
    @ObservedObject var venues: VenueService
    @ObservedObject var sun: SunService
    let centre: CLLocationCoordinate2D?
    /// Called with the venue once it's been marked, so the map can pin it.
    let onAdded: (SunVenue) -> Void
    let onClose: () -> Void

    @State private var picked: SunVenue?
    @State private var saving = false
    @State private var saveFailed = false
    /// Apple Maps in parallel with our own catalog, unbiased to the user's
    /// location — so "Atlas Bar Singapore" finds Singapore from Sweden. MapKit
    /// parses the country straight out of the natural-language query.
    @StateObject private var world = MapKitVenueSearch()

    private let sunny = Color(red: 1.0, green: 0.79, blue: 0.28)

    var body: some View {
        Group {
            if let v = picked {
                // Facing step. SunFacadeSheet owns the rose and the recompute;
                // the terrace itself was already reported when the bar was
                // picked, so skipping here loses nothing.
                VStack(spacing: 0) {
                    SunFacadeSheet(venue: v, sun: sun) { onClose() }
                    Button { onClose() } label: {
                        Text("SKIP — JUST MARK THE TERRACE")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .tracking(1.1)
                            .foregroundStyle(Color.cream.opacity(0.55))
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 8)
                }
            } else {
                searchStep
            }
        }
        // A fresh sheet must not inherit the last sun search's query — it
        // opened once with "Ce La Vie" already typed and zero results, which
        // read as broken.
        .onAppear { sun.clearSearch(); world.clear() }
        .onDisappear { sun.clearSearch(); world.clear() }
    }

    private var searchStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ADD OUTDOOR SEATING")
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .tracking(1.6)
                .foregroundStyle(Color.cream.opacity(0.6))
                .padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 4)
            Text("Which bar has a terrace we're missing? Add the country to look abroad — \"Atlas Bar Singapore\".")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.55))
                .padding(.horizontal, 20).padding(.bottom, 12)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.cream.opacity(0.45))
                TextField("Bar name", text: $sun.searchQuery)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .onChange(of: sun.searchQuery) { _, _ in
                        sun.search(near: centre)
                        world.search(query: sun.searchQuery,
                                     origin: centre.map {
                                         CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                                     },
                                     biasToOrigin: false)
                    }
                if !sun.searchQuery.isEmpty {
                    Button { sun.clearSearch(); world.clear() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.cream.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.cream.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.cream.opacity(0.12), lineWidth: 1))
            .padding(.horizontal, 20)

            if saveFailed {
                Text("Couldn't save that just now — try again in a moment.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.91, green: 0.46, blue: 0.42))
                    .padding(.horizontal, 20).padding(.top, 12)
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(sun.searchResults) { v in
                        Button { pick(v) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: v.outdoorSeating == true
                                      ? "checkmark.circle.fill" : "chair.lounge.fill")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(v.outdoorSeating == true
                                                     ? Color.cream.opacity(0.35) : sunny)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(v.name)
                                        .font(.system(size: 14.5, weight: .bold, design: .rounded))
                                        .foregroundStyle(Color.cream)
                                    if v.outdoorSeating == true {
                                        Text("Already marked — tap to set which way it faces")
                                            .font(.system(size: 11, weight: .medium, design: .rounded))
                                            .foregroundStyle(Color.cream.opacity(0.45))
                                    }
                                }
                                Spacer()
                                if saving && picked == nil { ProgressView().tint(sunny) }
                            }
                            .padding(.horizontal, 14).padding(.vertical, 11)
                            .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(Color.cream.opacity(0.05)))
                        }
                        .buttonStyle(.plain)
                        .disabled(saving)
                    }

                    // Anywhere on earth. Shown under our own hits so a bar we
                    // already know always wins over creating a duplicate.
                    let known = Set(sun.searchResults.map(\.name))
                    let abroad = world.results.filter { !known.contains($0.name) }
                    if !abroad.isEmpty {
                        Text("ANYWHERE ON EARTH")
                            .font(.system(size: 9.5, weight: .black, design: .monospaced))
                            .tracking(1.6)
                            .foregroundStyle(Color.cream.opacity(0.4))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 10)
                        ForEach(abroad) { r in
                            Button { pickWorldwide(r) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "globe.europe.africa.fill")
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(Color.cream.opacity(0.5))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(r.name)
                                            .font(.system(size: 14.5, weight: .bold, design: .rounded))
                                            .foregroundStyle(Color.cream)
                                        let place = [r.address, r.city].compactMap { $0 }
                                            .joined(separator: ", ")
                                        if !place.isEmpty {
                                            Text(place)
                                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                                .foregroundStyle(Color.cream.opacity(0.45))
                                        }
                                    }
                                    Spacer()
                                    if saving { ProgressView().tint(sunny) }
                                }
                                .padding(.horizontal, 14).padding(.vertical, 11)
                                .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .fill(Color.cream.opacity(0.05)))
                            }
                            .buttonStyle(.plain)
                            .disabled(saving)
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 24)
            }
        }
    }

    /// A bar Apple Maps knows but we don't: create the venue, mark the
    /// terrace, compute its sun, then fall through to the facing step.
    private func pickWorldwide(_ r: MapKitVenueResult) {
        saving = true
        saveFailed = false
        Task {
            var made: SunVenue?
            if let venue = await venues.resolveOrCreateMapKitVenue(r),
               await venues.reportOutdoorSeating(venueId: venue.id) {
                made = await sun.prepareAndPin(venueId: venue.id,
                                               zone: r.mapItem?.timeZone)
            }
            await MainActor.run {
                saving = false
                if let sv = made { picked = sv; onAdded(sv) } else { saveFailed = true }
            }
        }
    }

    private func pick(_ v: SunVenue) {
        saving = true
        saveFailed = false
        Task {
            // Already-true bars skip the report (the RPC would no-op anyway)
            // and go straight to the facing step.
            var ok = v.outdoorSeating == true
            if !ok { ok = await venues.reportOutdoorSeating(venueId: v.venueId) }
            await MainActor.run {
                saving = false
                if ok { picked = v; onAdded(v) } else { saveFailed = true }
            }
        }
    }
}

struct SunFacadeSheet: View {
    let venue: SunVenue
    @ObservedObject var sun: SunService
    let onDone: () -> Void

    @State private var picked: Int?

    private static let points: [(String, Int)] = [
        ("N", 0), ("NE", 45), ("E", 90), ("SE", 135),
        ("S", 180), ("SW", 225), ("W", 270), ("NW", 315),
    ]

    /// What a facade in this direction means for sun, at this venue's latitude.
    /// North of the equator the sun swings through the south; south of it,
    /// through the north — so the whole mapping mirrors.
    private func meaning(_ bearing: Int) -> String {
        /// Smallest angle between two bearings, handling the 359/0 wrap.
        func gap(_ a: Double, _ b: Double) -> Double {
            abs(((a - b + 180).truncatingRemainder(dividingBy: 360) + 360)
                .truncatingRemainder(dividingBy: 360) - 180)
        }
        // The sun's arc runs through the south up here and through the north
        // below the equator, so THIS flips. East and west do not: the sun rises
        // in the east everywhere.
        let equatorward = venue.lat >= 0 ? 180.0 : 0.0
        let b = Double(bearing)
        if gap(b, equatorward) < 23 { return "Sun most of the day" }
        if gap(b, equatorward) > 157 { return "Little or no direct sun" }
        if gap(b, 90) < 68 { return "Morning sun" }
        if gap(b, 270) < 68 { return "Afternoon and evening sun" }
        return "Some sun, part of the day"
    }

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 3) {
                Text("WHICH WAY DO YOU SIT?")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(Color.bronze)
                Text(venue.name)
                    .font(.system(size: 19, weight: .black, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .multilineTextAlignment(.center)
            }
            Text("We read the sun off the buildings around each bar, but we can't tell which side the seats are on — so we assume the sunniest. Point us the right way and we'll redo it.")
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.62))
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.horizontal, 4)

            compassRose

            // What the current choice means, in words the user can check against
            // their own memory of the place.
            Group {
                if let p = picked {
                    Text(meaning(p).uppercased())
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .tracking(1.1)
                        .foregroundStyle(Color(red: 1.0, green: 0.79, blue: 0.28))
                } else {
                    Text("TAP THE DIRECTION THE SEATS FACE")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.1)
                        .foregroundStyle(Color.cream.opacity(0.42))
                }
            }
            .frame(height: 16)

            if let e = sun.facadeError {
                Text(e).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.91, green: 0.46, blue: 0.42))
            }

            Button {
                guard let b = picked else { return }
                Task { if await sun.reportFacade(venueId: venue.venueId, bearing: b) { onDone() } }
            } label: {
                HStack(spacing: 7) {
                    if sun.reportingFacade { ProgressView().tint(Color.ink) }
                    Text(sun.reportingFacade ? "REDOING THE SUN…" : "THAT'S THE SIDE")
                        .font(.system(size: 13, weight: .black, design: .monospaced))
                        .tracking(1.1)
                }
                .foregroundStyle(Color.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(red: 1.0, green: 0.79, blue: 0.28)))
            }
            .buttonStyle(.plain)
            .disabled(picked == nil || sun.reportingFacade)
            .opacity(picked == nil ? 0.4 : 1)

            Text("Still measured from real building heights — you're only telling us where to stand.")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.38))
                .multilineTextAlignment(.center)
        }
        .padding(20)
    }

    /// Eight points on a circle, north at the top, clockwise — the arrangement
    /// they have in the world. The label sits where the direction is.
    private var compassRose: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let r = side / 2 - 26
            ZStack {
                Circle()
                    .strokeBorder(Color.cream.opacity(0.1), lineWidth: 1)
                    .frame(width: r * 2, height: r * 2)
                Text("N")
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .foregroundStyle(Color.cream.opacity(0.28))
                    .offset(y: -r + 1)
                ForEach(Self.points, id: \.1) { p in
                    let on = picked == p.1
                    let a = Double(p.1) * .pi / 180
                    Button { picked = p.1 } label: {
                        Text(p.0)
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .foregroundStyle(on ? Color.ink : Color.cream.opacity(0.82))
                            .frame(width: 46, height: 46)
                            .background(
                                Circle().fill(on ? Color(red: 1.0, green: 0.79, blue: 0.28)
                                                 : Color.cream.opacity(0.07)))
                            .overlay(Circle().strokeBorder(
                                on ? Color.clear : Color.cream.opacity(0.12), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    // sin/cos this way round puts 0 deg at the top and runs
                    // clockwise, matching a compass rather than the unit circle.
                    .offset(x: sin(a) * r, y: -cos(a) * r)
                }
                Image(systemName: "chair.lounge.fill")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.cream.opacity(0.3))
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: 210)
    }
}
