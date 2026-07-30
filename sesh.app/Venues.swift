// Venues & location — LocationService, MapKit venue search, VenueService
// (curated + specials), the deals map, and the check-in chip/sheet.
// Extracted from content_view.swift; pure relocation.

import SwiftUI
import Combine
import MapKit
import CoreLocation
import Foundation
import Supabase

// MARK: - Location & Venues
//
// Two small services backing the venue/check-in feature:
//
//   - LocationService — thin CLLocationManager wrapper. WhenInUse only,
//     never background. One-shot fixes triggered by the UI (battery-friendly)
//     instead of continuous tracking.
//
//   - VenueService — fetches venues + per-venue specials from Supabase,
//     and overlays name-matched local specials (see LocalSpecialsCatalog)
//     so a venue the user finds via Apple Maps still gets its secret
//     menu without a curated DB row. Tracks the user's chosen venue
//     and persists it across launches via UserDefaults.

@MainActor
final class LocationService: NSObject, ObservableObject {
    enum AuthState: Equatable {
        case notDetermined
        case denied
        case restricted
        case authorized
    }

    @Published private(set) var authState: AuthState = .notDetermined
    @Published private(set) var location: CLLocation?
    @Published private(set) var lastError: String?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        // Hundred-meter accuracy is plenty for "what bar are you at" — and
        // it dodges the GPS-warmup latency you get with kCLLocationAccuracyBest.
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        sync()
    }

    /// Called from UI: prompts for permission if we haven't asked yet,
    /// otherwise kicks off a one-shot fix when we already have access.
    func requestAccess() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            refresh()
        default:
            break
        }
        sync()
    }

    /// One-shot location fix. We don't keep updating in the background —
    /// saves battery and we don't need real-time tracking for venue picks.
    func refresh() {
        guard authState == .authorized else { return }
        manager.requestLocation()
    }

    private func sync() {
        switch manager.authorizationStatus {
        case .notDetermined:
            authState = .notDetermined
        case .denied:
            authState = .denied
        case .restricted:
            authState = .restricted
        case .authorizedAlways, .authorizedWhenInUse:
            authState = .authorized
        @unknown default:
            authState = .notDetermined
        }
    }
}

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.sync()
            if self.authState == .authorized { self.refresh() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            self.location = loc
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.lastError = error.localizedDescription
        }
    }
}

/// One row in the MapKit-backed search results. We don't reuse `Venue`
/// here because a result is "potential venue" — until the user actually
/// checks in we never write it to the DB. Keeping the type distinct
/// makes the call sites obvious and prevents accidentally seeding our
/// venues table with random taps.
struct MapKitVenueResult: Identifiable, Hashable {
    /// Stable id derived from `MKMapItem.identifier` (iOS 18+) when
    /// present, otherwise a synthetic "lat,lon|name" key. Used both as
    /// the SwiftUI list id AND as the dedupe key against `external_id`.
    let id: String
    let name: String
    let address: String?
    let city: String?
    let lat: Double
    let lon: Double

    /// Distance in metres from the search center, when known. Surfaced
    /// so the UI can show "0.4 km" next to each result without doing
    /// the arithmetic in the view.
    let distance: CLLocationDistance?

    /// The backing map item — used to render a selectable map marker.
    /// Nil for results synthesised from a tapped built-in POI (those
    /// already render as the map's own feature).
    let mapItem: MKMapItem?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    // Identity is the stable `id` — two results for the same place dedupe
    // even if MapKit handed back different `MKMapItem` instances.
    static func == (a: MapKitVenueResult, b: MapKitVenueResult) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Build from a coordinate + name — used when the user taps one of
    /// the map's built-in bar POIs (we only have its title + location).
    init(name: String, coordinate: CLLocationCoordinate2D, origin: CLLocation?) {
        self.id = "\(coordinate.latitude),\(coordinate.longitude)|\(name)"
        self.name = name
        self.address = nil
        self.city = nil
        self.lat = coordinate.latitude
        self.lon = coordinate.longitude
        self.mapItem = nil
        self.distance = origin.map {
            CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude).distance(from: $0)
        }
    }

    init(mapItem: MKMapItem, from origin: CLLocation?) {
        self.mapItem = mapItem
        // Read location + address from the placemark (available since iOS 9)
        // rather than the iOS-26-only `location` / `address` accessors, so the
        // app can deploy back to iOS 18.
        let placemark = mapItem.placemark
        let coord = placemark.coordinate
        let extID = mapItem.identifier?.rawValue
        self.id = extID
            ?? "\(coord.latitude),\(coord.longitude)|\(mapItem.name ?? "")"
        self.name = mapItem.name ?? "Unknown"
        // Compact street line ("Järntorgsgatan 12") from the placemark.
        if let street = placemark.thoroughfare {
            self.address = placemark.subThoroughfare.map { "\(street) \($0)" } ?? street
        } else {
            self.address = nil
        }
        self.city = placemark.locality
        self.lat = coord.latitude
        self.lon = coord.longitude
        if let origin {
            self.distance = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                .distance(from: origin)
        } else {
            self.distance = nil
        }
    }
}

/// Wraps `MKLocalSearch` so the venue sheet can offer "search any bar
/// nearby" without hard-coding a global venue list. Single in-flight
/// request: starting a new search cancels the previous one so a fast
/// typist doesn't get stale results.
@MainActor
final class MapKitVenueSearch: ObservableObject {
    @Published private(set) var results: [MapKitVenueResult] = []
    @Published private(set) var isSearching = false
    @Published private(set) var lastError: String? = nil

    private var current: MKLocalSearch?

    /// Run a search. `query` is the user's text; `origin` (when known)
    /// is used to bias the region and compute distances. We restrict
    /// to bar/restaurant POI categories so a search for "vasa" doesn't
    /// pollute the list with bus stops.
    func search(query: String, origin: CLLocation?, biasToOrigin: Bool = true) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Cancel any in-flight search first — typing a new char shouldn't
        // race the previous one.
        current?.cancel()
        current = nil
        guard !trimmed.isEmpty else {
            results = []
            isSearching = false
            return
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        request.resultTypes = [.pointOfInterest]
        // Bias to bars/nightlife/restaurants — the universe of places
        // someone would meaningfully "check into" for the sesh. Brewery /
        // winery cover dedicated drinking spots that aren't tagged
        // .nightlife.
        request.pointOfInterestFilter = MKPointOfInterestFilter(
            including: [.nightlife, .restaurant, .brewery, .winery]
        )
        // ~20 km radius around the user's location when we have it,
        // otherwise let MapKit pick a default. The radius is a soft
        // bias, not a hard filter, so we still get hits if the user
        // wandered slightly outside it.
        if let origin, biasToOrigin {
            request.region = MKCoordinateRegion(
                center: origin.coordinate,
                latitudinalMeters: 20_000,
                longitudinalMeters: 20_000
            )
        }

        let search = MKLocalSearch(request: request)
        current = search
        isSearching = true
        lastError = nil

        search.start { [weak self] response, error in
            Task { @MainActor in
                guard let self else { return }
                // If we got cancelled by a newer query, ignore — the
                // newer call already replaced `current` and reset state.
                guard self.current === search else { return }
                self.isSearching = false
                self.current = nil
                if let error {
                    let ns = error as NSError
                    // MKError.unknown / cancelled — quiet failure.
                    if ns.domain == MKErrorDomain, ns.code == MKError.Code.unknown.rawValue {
                        self.results = []
                        return
                    }
                    self.lastError = error.localizedDescription
                    self.results = []
                    return
                }
                let items = response?.mapItems ?? []
                let mapped = items.map { MapKitVenueResult(mapItem: $0, from: origin) }
                // Closest first when we know where the user is — so two
                // bars sharing a name surface the nearer one at the top.
                self.results = origin == nil ? mapped : mapped.sorted {
                    ($0.distance ?? .greatestFiniteMagnitude) < ($1.distance ?? .greatestFiniteMagnitude)
                }
            }
        }
    }

    /// Clear the result list — used when the sheet closes or the user
    /// empties the search field.
    func clear() {
        current?.cancel()
        current = nil
        results = []
        isSearching = false
        lastError = nil
    }
}

@MainActor
final class VenueService: ObservableObject {
    @Published private(set) var venues: [Venue] = []
    @Published private(set) var specialsByVenue: [UUID: [VenueSpecial]] = [:]
    /// Live promotional offers grouped by venue (Phase A "deals near you").
    /// Since migration 054 each offer carries its paid placement level
    /// (pin/poster/billboard) + optional artwork — offers ARE the campaigns.
    @Published private(set) var offersByVenue: [UUID: [VenueOffer]] = [:]
    /// Real Apple Maps coordinates resolved per venue (the seeded lat/lon can
    /// be approximate). Resolved once and cached to disk — see
    /// resolveOfferCoordinates() — so map pins are accurate without paying a
    /// MapKit lookup (or its memory) on every open.
    @Published private(set) var resolvedCoords: [UUID: CLLocationCoordinate2D] = [:]
    @Published private(set) var loading = false
    /// Set by deep entry points (the app-open interstitial) to ask the Deals
    /// map to fly to + open a specific venue when it next appears. The map
    /// consumes and clears it.
    @Published var pendingFocusVenueId: UUID? = nil
    /// Crowdsourced beer prices per venue (migrations 061–063): all reported
    /// serving sizes for each venue, for the price map.
    @Published private(set) var beerPricesByVenue: [UUID: [VenueBeerPrice]] = [:]
    private let coordCacheKey = "sesh.venueCoords.v1"

    /// User-selected current venue. Persisted across launches via
    /// UserDefaults so a "check-in" survives an app restart. The chip in
    /// the main view reads this; the menu sheet reads `specials(for:)`
    /// to show pinned drinks.
    @Published var currentVenue: Venue? {
        didSet {
            persistCurrent()
            // Whenever the user checks into a venue (curated, MapKit,
            // or stub), make sure any name-matched local specials are
            // attached to its id. Cheap and idempotent — the merge
            // dedupes on name, so repeated calls don't double up.
            if let v = currentVenue {
                mergeLocalSpecials(for: v)
            }
        }
    }

    // Per-ACCOUNT key: a shared slot let one account's check-in overwrite
    // the other's on the same phone. Legacy slot adopted by its stamped
    // owner on first load.
    private let currentKey: String = {
        let ns = supabase.auth.currentUser?.id.uuidString.lowercased() ?? "anon"
        let namespaced = "sesh.currentVenue.v1.\(ns)"
        let d = UserDefaults.standard
        if d.string(forKey: "sesh.currentVenue.owner.v1") == ns {
            if d.object(forKey: namespaced) == nil, let v = d.data(forKey: "sesh.currentVenue.v1") {
                d.set(v, forKey: namespaced)
            }
            d.removeObject(forKey: "sesh.currentVenue.v1")
            d.removeObject(forKey: "sesh.currentVenue.owner.v1")
        }
        return namespaced
    }()

    init() {
        loadCurrent()
    }

    // MARK: - Public reads

    /// Venues sorted by distance to a given user location, closest first.
    /// Falls back to alphabetical/server order when no location is known.
    func sortedByDistance(from location: CLLocation?) -> [Venue] {
        guard let loc = location else { return venues }
        return venues.sorted { a, b in
            let da = CLLocation(latitude: a.lat, longitude: a.lon).distance(from: loc)
            let db = CLLocation(latitude: b.lat, longitude: b.lon).distance(from: loc)
            return da < db
        }
    }

    /// Distance in metres from a user location to a venue. nil if no fix.
    func distance(from location: CLLocation?, to venue: Venue) -> CLLocationDistance? {
        guard let loc = location else { return nil }
        return CLLocation(latitude: venue.lat, longitude: venue.lon).distance(from: loc)
    }

    /// Specials at a venue, ready to drop into the picker.
    func specials(for venue: Venue) -> [VenueSpecial] {
        specialsByVenue[venue.id] ?? []
    }

    /// Live + currently-VISIBLE offers at a venue. "Show on valid days only"
    /// campaigns are hidden outside their day/time window (isVisibleNow).
    func offers(for venue: Venue) -> [VenueOffer] {
        (offersByVenue[venue.id] ?? []).filter { $0.isVisibleNow() }
    }

    // MARK: - Crowdsourced beer prices (migration 061)

    /// Pull the median-recent price per venue+serving for the beer-price map.
    func loadBeerPrices() async {
        do {
            let rows: [VenueBeerPrice] = try await supabase
                .rpc("venue_beer_prices").execute().value
            var map: [UUID: [VenueBeerPrice]] = [:]
            for r in rows { map[r.venueId, default: []].append(r) }
            beerPricesByVenue = map
            rebuildPriceIndex()
        } catch {
            // keep whatever we had; a transient failure shouldn't blank the map
        }
    }

    /// This venue's price for a specific serving, if reported.
    func beerPrice(for venue: Venue, serving: BeerServing) -> VenueBeerPrice? {
        beerPricesByVenue[venue.id]?.first { $0.serving == serving.rawValue }
    }

    /// All reported servings for a venue, smallest first.
    func servingPrices(for venue: Venue) -> [VenueBeerPrice] {
        (beerPricesByVenue[venue.id] ?? []).sorted { $0.servingSize.cl < $1.servingSize.cl }
    }

    /// Venues that have a price for the given serving — the dots on the price
    /// map for that filter.
    func venuesWithBeerPrice(serving: BeerServing) -> [Venue] {
        venues.filter { beerPricesByVenue[$0.id]?.contains { $0.serving == serving.rawValue } ?? false }
    }

    /// Any venue that has at least one reported price (any serving).
    var venuesWithAnyBeerPrice: [Venue] {
        venues.filter { !(beerPricesByVenue[$0.id]?.isEmpty ?? true) }
    }

    /// How far "this area" reaches when comparing prices — a region/country
    /// scale. Colours anchor to the cheapest beer WITHIN this radius (and same
    /// currency), so a bar reads cheap/pricey relative to its own area, not the
    /// whole world.
    static let beerRegionMeters: CLLocationDistance = 200_000

    /// Prices of the same serving + currency at bars within `beerRegionMeters`
    /// of a coordinate — the local comparison set.
    /// Flattened (lat, lon, serving, currency, price) for every PRICED venue.
    /// Rebuilt when prices or venues change.
    private struct PricePoint { let lat: Double; let lon: Double
                                let serving: String; let currency: String; let price: Double }
    private var priceIndex: [PricePoint] = []
    private var regionPriceMemo: [String: [Double]] = [:]

    func rebuildPriceIndex() {
        var idx: [PricePoint] = []
        for v in venues {
            guard let arr = beerPricesByVenue[v.id], !arr.isEmpty else { continue }
            let c = coordinate(for: v)
            for p in arr {
                idx.append(PricePoint(lat: c.latitude, lon: c.longitude,
                                      serving: p.serving, currency: p.currency, price: p.price))
            }
        }
        priceIndex = idx
        regionPriceMemo = [:]
    }

    /// Same-serving, same-currency prices within `beerRegionMeters`.
    ///
    /// This used to walk ALL venues and allocate a CLLocation per venue, once
    /// per price pin being coloured — around 420k distance computations per
    /// render at 1100 venues, which is what made switching map modes crawl.
    /// Now it walks only priced venues (a couple of hundred), uses plain
    /// arithmetic, and memoises per ~11 km cell so a city collapses to one scan.
    private func localBeerPrices(serving: String, currency: String,
                                 near coord: CLLocationCoordinate2D) -> [Double] {
        let key = "\(serving)|\(currency)|\((coord.latitude * 10).rounded())|\((coord.longitude * 10).rounded())"
        if let hit = regionPriceMemo[key] { return hit }

        let limit = Self.beerRegionMeters
        // Cheap bounding box first; only the survivors get real distance maths.
        let dLat = limit / 111_320.0
        let dLon = limit / (111_320.0 * max(0.2, cos(coord.latitude * .pi / 180)))
        var out: [Double] = []
        for p in priceIndex where p.serving == serving && p.currency == currency {
            if abs(p.lat - coord.latitude) > dLat || abs(p.lon - coord.longitude) > dLon { continue }
            let la1 = coord.latitude * .pi / 180, la2 = p.lat * .pi / 180
            let dp = la2 - la1, dl = (p.lon - coord.longitude) * .pi / 180
            let h = sin(dp / 2) * sin(dp / 2) + cos(la1) * cos(la2) * sin(dl / 2) * sin(dl / 2)
            if 2 * 6_371_000 * asin(min(1, sqrt(h))) <= limit { out.append(p.price) }
        }
        regionPriceMemo[key] = out
        return out
    }

    /// Cheapest same-serving, same-currency beer in this bar's region — the
    /// green anchor for its colour. Falls back to the bar's own price.
    func localCheapest(serving: String, currency: String, near coord: CLLocationCoordinate2D, own: Double) -> Double {
        localBeerPrices(serving: serving, currency: currency, near: coord).min() ?? own
    }

    /// Regional average for a serving + currency — the "vs typical" baseline.
    func localAverage(serving: String, currency: String, near coord: CLLocationCoordinate2D) -> Double? {
        let ps = localBeerPrices(serving: serving, currency: currency, near: coord)
        guard ps.count > 1 else { return nil }
        return ps.reduce(0, +) / Double(ps.count)
    }

    /// Record a price for a serving. Finds-or-creates the bar server-side, then
    /// refreshes the map. `name/lat/lon/externalId` carry the MapKit identity
    /// when the bar isn't in our DB yet.
    @discardableResult
    func submitBeerPrice(name: String, lat: Double, lon: Double,
                         externalId: String?, city: String?, address: String?,
                         price: Double, serving: BeerServing, currency: String, note: String?) async -> Bool {
        struct P: Encodable {
            let p_name: String
            let p_lat: Double
            let p_lon: Double
            let p_external_id: String?
            let p_city: String?
            let p_address: String?
            let p_price: Double
            let p_note: String?
            let p_serving: String
            let p_currency: String
        }
        do {
            _ = try await supabase.rpc("submit_beer_price", params: P(
                p_name: name, p_lat: lat, p_lon: lon,
                p_external_id: externalId, p_city: city, p_address: address,
                p_price: price, p_note: (note?.isEmpty ?? true) ? nil : note,
                p_serving: serving.rawValue, p_currency: currency
            )).execute()
            await refresh()          // pull the (maybe new) venue into `venues`
            await loadBeerPrices()
            return true
        } catch {
            return false
        }
    }

    /// Venues that currently have at least one VISIBLE offer — the pins shown
    /// on the deals map.
    var venuesWithOffers: [Venue] {
        venues.filter { (offersByVenue[$0.id] ?? []).contains { $0.isVisibleNow() } }
    }

    /// A venue's artwork-carrying campaign, if any (poster or billboard
    /// placement) — drives the branded map pin + the poster banner.
    func posterOffer(for venue: Venue) -> VenueOffer? {
        offersByVenue[venue.id]?.first { $0.hasArtPlacement && $0.isVisibleNow() }
    }

    /// City-scale radius. Deals — pins, billboards, and the list — are all
    /// scoped to bars near the user; a global catalog shouldn't surface a bar
    /// on another continent. Shared so every surface uses the same cutoff.
    static let dealsRadiusMeters: CLLocationDistance = 50_000
    /// City-scale promo radius — used for the app-open interstitial and, on the
    /// server, for deal-push targeting (migrations 059/060). Covers a whole
    /// city + inner suburbs so promotions reach the city, not just a small
    /// circle around the bar.
    static let dealsProximityMeters: CLLocationDistance = 25_000

    private func meters(from location: CLLocation?, to venue: Venue) -> CLLocationDistance? {
        guard let here = location else { return nil }
        let c = coordinate(for: venue)
        return CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: here)
    }

    private func isNearby(_ venue: Venue, to location: CLLocation?) -> Bool {
        guard let d = meters(from: location, to: venue) else { return true }   // no fix → show all
        return d <= Self.dealsRadiusMeters
    }

    /// All live billboard campaigns with their venues, for the carousel —
    /// restricted to the user's city. Uses the dedicated billboard image,
    /// falling back to the poster image.
    func billboardEntries(near location: CLLocation?) -> [(offer: VenueOffer, venue: Venue)] {
        venues.compactMap { v in
            guard isNearby(v, to: location) else { return nil }
            return offersByVenue[v.id]?
                .first { $0.placement == "billboard" && $0.isVisibleNow() && ($0.billboardImageURL ?? $0.imageURL) != nil }
                .map { ($0, v) }
        }
    }

    /// One eligible app-open interstitial for the user, or nil: an offer
    /// flagged `interstitial`, carrying poster artwork, at a bar within the
    /// tight "near the bar" radius, that the user hasn't already been shown
    /// (`seen`). Requires a location fix — proximity is the whole point — and
    /// the nearest bar wins. Returns the offer + its venue.
    func interstitialCandidate(near location: CLLocation?,
                               excluding seen: Set<UUID>) -> (offer: VenueOffer, venue: Venue)? {
        guard location != nil else { return nil }   // no fix → can't confirm proximity
        var best: (offer: VenueOffer, venue: Venue, dist: CLLocationDistance)? = nil
        for v in venues {
            guard let d = meters(from: location, to: v), d <= Self.dealsProximityMeters else { continue }
            guard let offer = offersByVenue[v.id]?.first(where: {
                $0.interstitial && $0.isVisibleNow() && $0.imageURL != nil && !seen.contains($0.id)
            }) else { continue }
            if best == nil || d < best!.dist { best = (offer, v, d) }
        }
        return best.map { ($0.offer, $0.venue) }
    }

    /// Venues with a live campaign in the user's city, nearest first — for the
    /// Deals list sheet.
    func dealsList(near location: CLLocation?) -> [Venue] {
        let all = venuesWithOffers.filter { isNearby($0, to: location) }
        guard let here = location else { return all.sorted { $0.name < $1.name } }
        return all.sorted {
            CLLocation(latitude: coordinate(for: $0).latitude, longitude: coordinate(for: $0).longitude).distance(from: here)
              < CLLocation(latitude: coordinate(for: $1).latitude, longitude: coordinate(for: $1).longitude).distance(from: here)
        }
    }

    /// Where to pin a venue — the MapKit-resolved coordinate if we have it,
    /// else the stored (possibly approximate) lat/lon.
    func coordinate(for venue: Venue) -> CLLocationCoordinate2D {
        resolvedCoords[venue.id] ?? CLLocationCoordinate2D(latitude: venue.lat, longitude: venue.lon)
    }

    /// Resolve real Apple Maps coordinates for every venue with a live offer,
    /// once, cached to disk. Idempotent + cheap after the first run (cache
    /// hit), so both the deals map and the check-in map can call it freely.
    func resolveOfferCoordinates() async {
        loadCoordCache()
        for venue in venuesWithOffers where resolvedCoords[venue.id] == nil {
            if let c = await geocode(venue) {
                resolvedCoords[venue.id] = c
                saveCoordCache()
            }
        }
    }

    private func geocode(_ venue: Venue) async -> CLLocationCoordinate2D? {
        let request = MKLocalSearch.Request()
        let parts = [venue.name] + [venue.address, venue.city].compactMap { $0 }
        request.naturalLanguageQuery = parts.joined(separator: ", ")
        request.resultTypes = [.pointOfInterest, .address]
        // Bias to the seeded area so a common bar name resolves to the right
        // city.
        request.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: venue.lat, longitude: venue.lon),
            latitudinalMeters: 30_000, longitudinalMeters: 30_000)
        guard let response = try? await MKLocalSearch(request: request).start() else { return nil }
        return response.mapItems.first?.placemark.coordinate
    }

    private func loadCoordCache() {
        guard resolvedCoords.isEmpty,
              let dict = UserDefaults.standard.dictionary(forKey: coordCacheKey) as? [String: [Double]]
        else { return }
        for (key, pair) in dict where pair.count == 2 {
            if let id = UUID(uuidString: key) {
                resolvedCoords[id] = CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1])
            }
        }
    }

    private func saveCoordCache() {
        var dict: [String: [Double]] = [:]
        for (id, c) in resolvedCoords { dict[id.uuidString] = [c.latitude, c.longitude] }
        UserDefaults.standard.set(dict, forKey: coordCacheKey)
    }

    /// Specials for the currently-checked-in venue, mapped to DrinkOptions
    /// so the picker can render them with the same row component as the
    /// regular catalog. Empty when no venue is selected.
    func currentSpecialsAsOptions() -> [DrinkOption] {
        guard let v = currentVenue else { return [] }
        return specials(for: v).map { $0.asDrinkOption() }
    }

    /// Resolves a `SessionDrink` row back into a `DrinkOption` for display.
    /// Tries the standard catalog first, then any known venue special
    /// (across every venue, not just the current one — so a drink logged
    /// at a different bar earlier in the night still renders correctly),
    /// and finally synthesises one from the row's own `volumeMl`/`abv`
    /// fields. The synthesis path means a drink whose source has been
    /// retired (catalog updated, special pulled) still shows up in the
    /// timeline / order card instead of silently vanishing.
    func resolveOption(for drink: SessionDrink) -> DrinkOption {
        if let std = DrinkCatalog.allOptions.first(where: { $0.name == drink.drinkName }) {
            return std
        }
        let allSpecials = specialsByVenue.values.flatMap { $0 }
        if let special = allSpecials.first(where: { $0.name == drink.drinkName }) {
            return special.asDrinkOption()
        }
        return DrinkOption(
            category: .cocktail,
            name: drink.drinkName,
            detail: "\(Int(drink.volumeMl)) ml · \(Int((drink.abv * 100).rounded()))%",
            volumeML: drink.volumeMl,
            abv: drink.abv
        )
    }

    // MARK: - Network

    /// Loads every venue + special from Supabase. On failure or empty
    /// result we still apply local name-matched specials to whatever
    /// venues we do know about (currently just the user's checked-in
    /// MapKit venue, if any), so a venue like Handelspuben that the
    /// user found via Apple Maps keeps its secret menu even when the
    /// DB is empty or offline.
    func refresh() async {
        loading = true; defer { loading = false }
        do {
            // PostgREST caps ANY response at 1000 rows. Once the venue table
            // passed that, a bare select() silently returned the first 1000 by
            // name and dropped the rest — so bars late in the alphabet vanished
            // from the app while the website (which reads through an RPC
            // returning far fewer rows) still showed them. Page until short.
            var vs: [Venue] = []
            let pageSize = 1000
            var offset = 0
            while true {
                let page: [Venue] = try await supabase
                    .from("venues")
                    .select()
                    .order("name", ascending: true)
                    .range(from: offset, to: offset + pageSize - 1)
                    .execute()
                    .value
                vs.append(contentsOf: page)
                if page.count < pageSize { break }
                offset += pageSize
                if offset > 50_000 { break }   // sanity stop
            }
            let ss: [VenueSpecial] = try await supabase
                .from("venue_specials")
                .select()
                .execute()
                .value
            // RLS filters venue_offers to live (active + approved + unexpired)
            // offers, so a plain select returns exactly what's safe to show.
            let os: [VenueOffer] = try await supabase
                .from("venue_offers")
                .select()
                .execute()
                .value
            venues = vs
            rebuildPriceIndex()
            var grouped: [UUID: [VenueSpecial]] = [:]
            for s in ss {
                grouped[s.venueId, default: []].append(s)
            }
            specialsByVenue = grouped
            var groupedOffers: [UUID: [VenueOffer]] = [:]
            for o in os {
                groupedOffers[o.venueId, default: []].append(o)
            }
            offersByVenue = groupedOffers
            attachLocalSpecials()
            reconcileCurrent()
            lastRefreshedAt = Date()
        } catch {
            // Network or schema problem. Don't seed any venues —
            // discovery is MapKit-driven. Still attach local specials
            // to anything already in `venues` (e.g., a previously
            // checked-in MapKit row that we've kept locally).
            attachLocalSpecials()
        }
    }

    /// When the catalog was pulled successfully; nil until the first fetch.
    private var lastRefreshedAt: Date? = nil

    /// Skip the round-trip when the catalog is recent. Entering the DEALS
    /// tab is a hot path — it fires mid page-swipe, and an unconditional
    /// refetch there both janks the transition and hammers the DB on every
    /// visit. Offers change on the order of days, not seconds.
    func refreshIfStale(maxAge: TimeInterval = 5 * 60) async {
        if let last = lastRefreshedAt, Date().timeIntervalSince(last) < maxAge { return }
        await refresh()
    }

    // MARK: - MapKit check-in

    /// Check the user into a venue surfaced by `MapKitVenueSearch`. If we
    /// already know about it (matched by `external_id`) we just point
    /// `currentVenue` at the existing row — no DB write. Otherwise we
    /// insert a new `mapkit`-tier venue and use the returned row.
    ///
    /// The DB enforces the curated-only rule on specials via trigger, so
    /// even if this method's source value were wrong the moderation
    /// guarantee would still hold.
    func checkIn(mapKitResult result: MapKitVenueResult) async {
        if let venue = await resolveOrCreateMapKitVenue(result) {
            currentVenue = venue
            return
        }
        // Last resort: local-only stub, so the user's check-in still works
        // this session even if it never persisted. Stable id from
        // external_id so a later real insert dedupes via reconcileCurrent().
        let stub = Venue(
            id: UUID(),
            name: result.name,
            address: result.address,
            city: result.city,
            lat: result.lat,
            lon: result.lon,
            isFeatured: false,
            source: .mapkit,
            externalId: result.id,
            createdAt: Date()
        )
        venues.append(stub)
        currentVenue = stub
    }

    /// Get the `venues` row for an Apple Maps result, creating it if this is
    /// the first time anyone picked that place. Shared by check-in and the
    /// admin QR sheet so there is exactly one way a mapkit venue comes into
    /// existence. Returns nil only if the row could be neither found nor
    /// written. No side effects on `currentVenue` — callers decide that.
    @discardableResult
    func resolveOrCreateMapKitVenue(_ result: MapKitVenueResult) async -> Venue? {
        // 1. Fast path: already in our local list.
        //
        // Checks mapkit_id as well as external_id. The Apple Maps Server API
        // backfill writes the place id to mapkit_id (external_id still holds
        // 'osm:node/123' on imported rows, and the OSM importer dedupes on it),
        // so a venue linked server-side must still match one resolved here —
        // otherwise tapping a bar would create a second copy of it.
        if let existing = venues.first(where: {
            $0.mapkitId == result.id
                || ($0.externalId == result.id && $0.source == .mapkit)
        }) { return existing }

        // 2. Re-check the DB in case another device beat us to the insert
        //    (or our local list is stale). Look up by (source, external_id),
        //    which is the same shape as the unique index.
        if let hit = await fetchMapKitVenue(externalId: result.id) {
            if !venues.contains(where: { $0.id == hit.id }) { venues.append(hit) }
            return hit
        }

        // 3. Insert a new mapkit row. RLS allows it because source != 'curated'.
        //    The DB enforces the curated-only rule on specials via trigger, so
        //    the moderation guarantee holds regardless of this source value.
        struct NewMapKitVenue: Encodable {
            let name: String
            let address: String?
            let city: String?
            let lat: Double
            let lon: Double
            let is_featured: Bool
            let source: String
            let external_id: String
        }
        let payload = NewMapKitVenue(
            name: result.name,
            address: result.address,
            city: result.city,
            lat: result.lat,
            lon: result.lon,
            is_featured: false,
            source: "mapkit",
            external_id: result.id
        )
        do {
            let inserted: [Venue] = try await supabase
                .from("venues")
                .insert(payload)
                .select()
                .execute()
                .value
            if let row = inserted.first {
                venues.append(row)
                return row
            }
        } catch {
            // Lost a race with another device — re-read and use the winner.
            if let hit = await fetchMapKitVenue(externalId: result.id) {
                if !venues.contains(where: { $0.id == hit.id }) { venues.append(hit) }
                return hit
            }
        }
        return nil
    }

    private func fetchMapKitVenue(externalId: String) async -> Venue? {
        let matches: [Venue]? = try? await supabase
            .from("venues")
            .select()
            .eq("source", value: "mapkit")
            .eq("external_id", value: externalId)
            .limit(1)
            .execute()
            .value
        return matches?.first
    }

    /// Walk every known venue and, for each, look up locally-defined
    /// specials by name pattern (see `LocalSpecialsCatalog`). Merges
    /// into `specialsByVenue` without clobbering anything that was
    /// already loaded from the DB — if a venue has both DB-defined
    /// specials and local ones, both surface. Dedupe on `name` so a
    /// freshly-migrated DB row doesn't double up with the in-memory
    /// template after a refresh.
    private func attachLocalSpecials() {
        for venue in venues {
            mergeLocalSpecials(for: venue)
        }
    }

    /// Single-venue version of `attachLocalSpecials`. Called from the
    /// `currentVenue` didSet so a fresh MapKit check-in gets its
    /// secret menu the same tick the chip flips over — no waiting for
    /// the next periodic refresh.
    private func mergeLocalSpecials(for venue: Venue) {
        let local = LocalSpecialsCatalog.specials(forVenueNamed: venue.name, venueId: venue.id)
        guard !local.isEmpty else { return }
        var existing = specialsByVenue[venue.id] ?? []
        let existingNames = Set(existing.map { $0.name })
        for s in local where !existingNames.contains(s.name) {
            existing.append(s)
        }
        specialsByVenue[venue.id] = existing
    }

    /// If the user is checked into a venue whose row no longer exists in
    /// the fetched list (deleted, renamed), drop the check-in so the chip
    /// doesn't show a ghost. ONLY table-managed (curated) venues get this
    /// treatment: a check-in that never came from the table — an event's
    /// auto check-in place (source .user) — must not be dropped just
    /// because the fetch doesn't contain it. Doing so during a live sesh
    /// minted a phantom checkout + "between bars" stop on EVERY venues
    /// refresh, then the group broadcast re-checked everyone in — an
    /// endless loop of phantom stops nobody created.
    private func reconcileCurrent() {
        guard let cur = currentVenue, cur.source == .curated else { return }
        if !venues.contains(where: { $0.id == cur.id }) {
            currentVenue = nil
        } else if let fresh = venues.first(where: { $0.id == cur.id }), fresh != cur {
            // Pick up renames / featured-flag changes.
            currentVenue = fresh
        }
    }

    // MARK: - Persistence

    private func persistCurrent() {
        guard let v = currentVenue else {
            UserDefaults.standard.removeObject(forKey: currentKey)
            return
        }
        if let data = try? JSONEncoder().encode(v) {
            UserDefaults.standard.set(data, forKey: currentKey)
        }
    }

    private func loadCurrent() {
        guard let data = UserDefaults.standard.data(forKey: currentKey),
              let v = try? JSONDecoder().decode(Venue.self, from: data)
        else { return }
        currentVenue = v
    }
}


// MARK: - Venue Offers (deals map)
//
// Phase A of venue marketing: a read-only "deals near you" map. Pins are
// venues with live offers (venue_offers, migration 029, loaded by
// VenueService). Tap a pin → that venue's offers; tap "Show at the bar" →
// a live-ticking redeem card (no server validation yet — staff eyeball it).
// Entry point is the DealsCard on the plan page.

/// Hosts the DEALS map inside the paged TabView without hitching the page
/// swipe. A SwiftUI Map is the heaviest view in the app, and both building
/// and tearing it down synchronously with the tab change landed exactly in
/// the middle of the swipe animation — the source of the "deals tab is
/// laggy" jank. So the map mounts a beat AFTER the swipe settles (behind a
/// cheap ink placeholder) and unmounts a beat after leaving, keeping the
/// transition itself at full frame rate. The memory gating survives: the
/// map is still torn down whenever the user is off the tab.
/// Shared "take me back to where I am" affordance.
///
/// Every interactive map in the app uses this one button and this one zoom, so
/// tapping locate feels identical whether you are on Deals, Beer, Sun or the
/// Nightline map — landing at the same scale each time rather than wherever the
/// map happened to be.
enum MapLocate {
    /// MapKit span. ~1.2 km shows a few blocks: near enough to read bar names,
    /// wide enough that your own dot isn't the only thing on screen.
    static let spanMeters: CLLocationDistance = 1200
    /// The Mapbox equivalent of the same scale, for the Sun map.
    static let mapboxZoom: Double = 15.4
    static let animation: Animation = .easeInOut(duration: 0.5)
}

/// The locate button itself. Dimmed and non-tappable until Core Location has
/// actually produced a fix, so it can't silently do nothing.
struct LocateMeButton: View {
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "location.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(enabled ? Color.cream : Color.cream.opacity(0.3))
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.ink.opacity(0.85)))
                .overlay(Circle().strokeBorder(Color.cream.opacity(0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!enabled)
        .accessibilityLabel("Centre on my location")
    }
}

struct DeferredOffersPage: View {
    let active: Bool
    @ObservedObject var venues: VenueService
    @ObservedObject var location: LocationService
    /// Forwarded to the map so it can stop the tab pager stealing a pinch.
    @Binding var pagingLocked: Bool
    let onBack: () -> Void

    @State private var mounted = false
    /// Debounce token: bumped on every activation flip so a stale sleep
    /// (user swiped in and straight back out) can't apply an old decision.
    @State private var generation = 0

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            if mounted {
                OffersMapView(venues: venues, location: location,
                              pagingLocked: $pagingLocked)
                    // The interactive map swallows the TabView's horizontal
                    // page swipe, so a thin left-edge strip provides the
                    // "grab the edge to go back" gesture → back to Nightline.
                    .overlay(alignment: .leading) { backEdge }
                    .transition(.opacity)
            } else {
                ProgressView()
                    .tint(Color.bronze)
            }
        }
        .onChange(of: active) { _, isActive in
            generation += 1
            let g = generation
            if isActive {
                // Let the page-swipe spring (~0.4s response) land first.
                Task {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard g == generation else { return }
                    withAnimation(.easeIn(duration: 0.15)) { mounted = true }
                }
            } else {
                Task {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    guard g == generation else { return }
                    mounted = false
                }
            }
        }
    }

    private var backEdge: some View {
        Color.clear
            .frame(width: 24)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onEnded { value in
                        if value.translation.width > 40,
                           abs(value.translation.height) < 70 {
                            onBack()
                        }
                    }
            )
            .ignoresSafeArea()
    }
}

/// The two Deals-map layers: paid campaigns, or crowdsourced beer prices.
private enum DealsMapMode { case deals, prices, sun }

private struct OffersMapView: View {
    @ObservedObject var venues: VenueService
    @ObservedObject var location: LocationService
    /// nil when embedded as a tab (navigation is the bottom bar); set when
    /// presented modally so the header shows a close button.
    var onClose: (() -> Void)? = nil

    @State private var camera: MapCameraPosition = .automatic
    /// The venue whose card is presented (as a real sheet).
    @State private var selectedVenue: Venue? = nil
    /// The "all deals" list sheet.
    @State private var listOpen = false
    /// Which map layer is showing.
    @State private var mapMode: DealsMapMode = .deals
    @StateObject private var sun = SunService()
    @State private var selectedSunId: UUID?
    @State private var sunListOpen = false
    /// Raised while a finger is on the Sun map, so the tab pager stops
    /// competing for the horizontal part of a pinch.
    @Binding var pagingLocked: Bool
    /// Bumped on every locate tap. The Sun map watches this rather than the
    /// coordinate, so tapping twice from the same spot still re-centres.
    @State private var locateTick = 0
    /// What the map is actually showing. Pins are filtered to this rather than
    /// to a radius around YOU: the maps are deliberately global (zoom out to
    /// browse another city), but handing MapKit venues on another continent
    /// made it clamp them into the corner of the screen.
    @State private var visibleRegion: MKCoordinateRegion?
    /// Where search asked the camera to go.
    @State private var sunFocus: CLLocationCoordinate2D?
    /// The serving size the price map is filtered to.
    @State private var selectedServing: BeerServing = .canonical
    /// Beer-price submit sheet + its optional pre-filled bar.
    @State private var submitOpen = false
    @State private var submitPreset: BeerPriceTarget? = nil
    /// The searchable price list sheet.
    @State private var priceListOpen = false

    /// Fly the camera to a venue and open its card. The center is nudged SOUTH
    /// so the pin sits in the top half, visible ABOVE the medium sheet.
    private func focus(_ venue: Venue) {
        let c = venues.coordinate(for: venue)
        let shifted = CLLocationCoordinate2D(latitude: c.latitude - 0.005, longitude: c.longitude)
        withAnimation(.easeInOut(duration: 0.5)) {
            camera = .region(MKCoordinateRegion(center: shifted,
                                                latitudinalMeters: 1600, longitudinalMeters: 1600))
        }
        selectedVenue = venue
    }

    /// If something asked for a specific bar (interstitial "see this deal"),
    /// fly to it and open its card, then clear the request.
    private func consumePendingFocus() {
        guard let id = venues.pendingFocusVenueId,
              let venue = venues.venues.first(where: { $0.id == id }) else { return }
        venues.pendingFocusVenueId = nil
        // Small delay lets the tab-switch settle before the camera animates.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focus(venue) }
    }

    /// Only surface offers within this radius of the user — a global dataset
    /// shouldn't dump bars on the other side of the planet onto the map.
    /// (Server-side geo-filtering is a Phase B concern; client-side is fine
    /// for the small Phase A catalog.) Falls back to showing all when we have
    /// no location fix yet. Shared with the list + billboards.
    private let radiusMeters = VenueService.dealsRadiusMeters

    private var pins: [Venue] {
        // Still global — zoom out and another city's deals appear — but only
        // the ones actually in view are handed to MapKit. Passing it venues
        // thousands of km off-screen made it pile them into the corner.
        venues.venuesWithOffers.filter(onScreen)
    }

    /// Bars with a price for the selected serving — shown EVERYWHERE, not just
    /// near you. Zoom out to see prices across the whole world.
    /// Priced bars to draw, NEAREST FIRST AND CAPPED.
    ///
    /// Every priced venue used to be handed to the map at once. At 40-odd bars
    /// that was fine; after the OSM import it is 217 live MapKit annotations
    /// built in one pass, which is what made switching into Beer mode hang for
    /// several seconds. The Sun map already caps at 80 for the same reason.
    /// A cheap bounding-box pre-filter keeps this from doing trig 1115 times.
    private var pricePins: [Venue] {
        let all = venues.venuesWithBeerPrice(serving: selectedServing).filter(onScreen)
        guard let here = location.location, all.count > Self.maxPricePins else { return all }
        let lat = here.coordinate.latitude, lon = here.coordinate.longitude
        let box = 0.75   // degrees; generous, just to avoid sorting the world
        let near = all.filter { abs($0.lat - lat) < box && abs($0.lon - lon) < box }
        let pool = near.count >= Self.maxPricePins ? near : all
        return pool
            .map { ($0, ($0.lat - lat) * ($0.lat - lat) + ($0.lon - lon) * ($0.lon - lon)) }
            .sorted { $0.1 < $1.1 }
            .prefix(Self.maxPricePins)
            .map(\.0)
    }

    /// Enough to fill a city, few enough that the map builds them quickly.
    private static let maxPricePins = 120

    /// Is this venue inside (a padded version of) what's on screen?
    /// Padding means panning reveals pins that are already there rather than
    /// popping them in at the edge.
    private func onScreen(_ v: Venue) -> Bool {
        guard let r = visibleRegion else { return true }
        let padLat = r.span.latitudeDelta, padLon = r.span.longitudeDelta
        return abs(v.lat - r.center.latitude) <= padLat
            && abs(v.lon - r.center.longitude) <= padLon
    }

    private func withinRadius(_ list: [Venue]) -> [Venue] {
        guard let here = location.location else { return list }
        return list.filter {
            let c = venues.coordinate(for: $0)
            return CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: here) <= radiusMeters
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.ink.ignoresSafeArea()

            if mapMode == .sun {
                sunLayer
            } else {
            Map(position: $camera) {
                UserAnnotation()
                if mapMode == .deals {
                    ForEach(pins) { venue in
                        Annotation(venue.name, coordinate: venues.coordinate(for: venue)) {
                            // Poster/billboard artwork → branded pin; pins keep
                            // the classic whiskey dot.
                            Group {
                                if let art = venues.posterOffer(for: venue)?.imageURL {
                                    PosterPin(url: art, selected: selectedVenue?.id == venue.id)
                                } else {
                                    OfferPin(count: venues.offers(for: venue).count,
                                             selected: selectedVenue?.id == venue.id)
                                }
                            }
                            .onTapGesture { selectedVenue = venue }
                        }
                    }
                } else {
                    ForEach(pricePins) { venue in
                        Annotation(venue.name, coordinate: venues.coordinate(for: venue)) {
                            if let p = venues.beerPrice(for: venue, serving: selectedServing) {
                                BeerPricePin(price: p,
                                             cheapest: venues.localCheapest(serving: p.serving, currency: p.currency,
                                                                            near: venues.coordinate(for: venue), own: p.price),
                                             selected: selectedVenue?.id == venue.id)
                                    .onTapGesture { selectedVenue = venue }
                            }
                        }
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .including([.nightlife, .restaurant, .brewery, .winery])))
            .onMapCameraChange(frequency: .onEnd) { ctx in
                visibleRegion = ctx.region
            }
            }

            header

            // Floating locate button, same place and same resulting zoom on
            // every mode. Sits above the mode's own bottom controls.
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    LocateMeButton(enabled: location.location != nil) { locateMe() }
                        .padding(.trailing, 16)
                        .padding(.bottom, mapMode == .sun ? 132 : 24)
                }
            }

            if mapMode == .sun {
                VStack(spacing: 8) {
                    Spacer()
                    HStack(spacing: 8) {
                        Button { sunListOpen = true } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "list.bullet")
                                    .font(.system(size: 11, weight: .bold))
                                Text("SUNNIEST FIRST")
                                    .font(.system(size: 10, weight: .black, design: .monospaced))
                                    .tracking(1.2)
                            }
                            .foregroundStyle(Color.ink)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(Capsule().fill(Color(red: 1.0, green: 0.79, blue: 0.28)))
                        }
                        .buttonStyle(PressScaleStyle())

                    }
                    SunTimeSlider(previewAt: $sun.previewAt,
                                  calendar: sunCalendar,
                                  zoneName: sunReference.name)
                    Text("Modelled from building heights · © Mapbox © OpenStreetMap")
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.35))
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }

            // Billboard carousel — deals mode only, hidden while a card is up.
            if mapMode == .deals, selectedVenue == nil {
                let billboards = venues.billboardEntries(near: location.location)
                if !billboards.isEmpty {
                    VStack {
                        Spacer()
                        BillboardCarousel(entries: billboards) { venue in focus(venue) }
                            .padding(.bottom, 40)   // clears Apple's attribution
                    }
                }
            }

            // Contribute nudge — the price map is only as good as the crowd, so
            // when there's nothing nearby yet, invite the user to seed it.
            if mapMode == .prices, selectedVenue == nil, pricePins.isEmpty {
                VStack {
                    Spacer()
                    contributeCard
                    Spacer()
                }
            }
        }
        // The venue card is a real sheet — reliable buttons + dismiss, and the
        // medium detent leaves the pin visible on the map above it.
        .sheet(item: $selectedVenue) { venue in
            // A normal modal sheet keeps every button working; the map + pin
            // stay visible (dimmed) in the top half at the medium detent.
            Group {
                if mapMode == .deals {
                    VenueOfferCard(venue: venue, venues: venues)
                } else {
                    BeerPriceDetailCard(
                        venue: venue, venues: venues,
                        serving: selectedServing,
                        onReport: { target in
                            selectedVenue = nil
                            submitPreset = target
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { submitOpen = true }
                        },
                        onPickServing: { selectedServing = $0 }
                    )
                }
            }
            .presentationDetents([.fraction(0.58), .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.ink)
        }
        // Report / add a beer price.
        .sheet(isPresented: $submitOpen, onDismiss: { submitPreset = nil }) {
            BeerPriceSubmitSheet(venues: venues, location: location,
                                 preset: submitPreset, initialServing: selectedServing) {
                submitOpen = false
            }
            .presentationDetents([.large])
            .presentationBackground(Color.ink)
        }
        // Searchable, price-sorted list of bars for the selected serving.
        .sheet(isPresented: $priceListOpen) {
            BeerPriceListSheet(venues: venues, location: location, serving: selectedServing) { venue in
                priceListOpen = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focus(venue) }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.ink)
        }
        .task {
            recenter()
            await venues.refreshIfStale()
            await venues.resolveOfferCoordinates()
            await venues.loadBeerPrices()
            recenter()
            consumePendingFocus()
        }
        // The app-open interstitial (or any deep link) can request a bar; fly
        // to it once the Deals tab is showing.
        .onChange(of: venues.pendingFocusVenueId) { _, _ in consumePendingFocus() }
        // Horizons load lazily — the Sun mode is opt-in, so nobody pays for it
        // unless they ask, and once loaded a whole day scrubs offline.
        .onChange(of: mapMode) { _, mode in
            guard mode == .sun, sun.venues.isEmpty else { return }
            Task {
                await sun.load(near: location.location?.coordinate
                    ?? CLLocationCoordinate2D(latitude: 57.7016, longitude: 11.9668))
            }
        }
        .sheet(isPresented: $sunListOpen) {
            SunListSheet(
                readings: sunNearbyReadings,
                placeName: sunReference.name,
                sun: sun,
                centre: sunReference.coord,
                onPick: { venue in
                    sun.pinned = venue
                    selectedSunId = venue.id
                    sunFocus = venue.coordinate
                },
                onPickWorldwide: { result in
                    Task {
                        guard let venue = await venues.resolveOrCreateMapKitVenue(result)
                        else { return }
                        if let sv = await sun.prepareAndPin(venueId: venue.id,
                                                           zone: result.mapItem?.timeZone) {
                            selectedSunId = sv.id
                            sunFocus = sv.coordinate
                        }
                    }
                })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.ink)
        }
        .sheet(isPresented: $listOpen) {
            DealsListSheet(venues: venues, location: location) { venue in
                listOpen = false
                // Defer so the list sheet fully dismisses before the card
                // sheet presents (SwiftUI drops back-to-back presentations).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focus(venue) }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.ink)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(mapMode == .deals ? "DEALS NEARBY" : mapMode == .prices ? "BEER PRICES" : "WHERE'S THE SUN")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(2.4)
                        // Bronze on a daylit map was nearly invisible; the sun
                        // mode's own gold reads at any brightness.
                        .foregroundStyle(mapMode == .sun
                            ? Color(red: 1.0, green: 0.82, blue: 0.36) : Color.bronze)
                    Text(headerValue)
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.cream)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Capsule().fill(Color.ink.opacity(0.88)))
                .overlay(Capsule().strokeBorder(Color.cream.opacity(0.1), lineWidth: 1))
                Spacer()
                if mapMode == .deals {
                    circleButton("list.bullet") { listOpen = true }
                } else if mapMode == .sun {
                    // Same corner, but it searches SUN here. Previously this was
                    // wired to beer prices, so the obvious place to look up a
                    // bar's sunlight silently searched for its beer price.
                    circleButton("magnifyingglass") { sunListOpen = true }
                } else {
                    circleButton("magnifyingglass") { priceListOpen = true }
                    circleButton("plus") { submitPreset = nil; submitOpen = true }
                }
                if let onClose { circleButton("xmark", action: onClose) }
            }
            modeToggle
            if mapMode == .prices { servingFilter }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// Serving-size filter for the price map.
    private var servingFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(BeerServing.allCases) { s in
                    let on = selectedServing == s
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { selectedServing = s }
                    } label: {
                        Text(s.label)
                            .font(.system(size: 11, weight: .black, design: .rounded))
                            .foregroundStyle(on ? Color.ink : Color.cream.opacity(0.8))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(on ? Color.whiskey : Color.ink.opacity(0.6)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollClipDisabled()
    }

    private var headerValue: String {
        if mapMode == .sun {
            // "all in shade" with nothing loaded is a lie — that's the case when
            // you're far from any venue we hold data for (a simulator in San
            // Francisco, say), and it read as "every bar around here is shaded".
            if sunNearbyReadings.isEmpty { return "nothing nearby yet" }
            let lit = sunNearbyReadings.filter(\.isSunlit).count
            return lit == 0 ? "all in shade" : "\(lit) in the sun"
        }
        if mapMode == .deals { return "\(pins.count) \(pins.count == 1 ? "spot" : "spots")" }
        // Global map now, mixed currencies — a single "cheapest" is meaningless,
        // so just count the priced bars.
        return pricePins.isEmpty ? "tap ＋ to add" : "\(pricePins.count) \(pricePins.count == 1 ? "bar" : "bars")"
    }

    // Cached in the service. Calling a recomputing function here meant
    // 150 venues x 288 sun samples, several times per render.
    private var sunReadings: [SunReading] { sun.readings }

    /// "Sunniest first" means nearby, not everything we happen to have loaded.
    /// Without this the list mixed San Francisco bars with a pinned Gothenburg
    /// one — a nearby list spanning two continents.
    private var sunNearbyReadings: [SunReading] {
        let c = sunReference.coord
        let here = CLLocation(latitude: c.latitude, longitude: c.longitude)
        return sunReadings.filter { r in
            here.distance(from: CLLocation(latitude: r.venue.lat,
                                           longitude: r.venue.lon)) <= 30_000
        }
    }

    /// The place the Sun screen is ABOUT — the venue you searched for, else
    /// wherever you are. Everything on this screen keys off it: the scene's
    /// lighting, the slider's clock, and the zone label.
    ///
    /// Getting this wrong is very confusing: with the simulator in San
    /// Francisco and the phone on Swedish time, looking up a Gothenburg bar lit
    /// the map from San Francisco's sun while the slider read Swedish hours, so
    /// the map was bright at 03:00 and dark from 06:00 to 15:00.
    private var sunReference: (coord: CLLocationCoordinate2D, zone: TimeZone, name: String?) {
        // Priority: the pin you tapped, the venue you searched for, then whatever
        // the map is actually showing. Falling straight through to GPS was the
        // bug — the venues on screen can be a continent away from the phone.
        let anchor = sunReadings.first(where: { $0.id == selectedSunId })?.venue
            ?? sun.pinned
            ?? sunReadings.first?.venue
        if let anchor {
            return (anchor.coordinate, anchor.timeZone, Self.zoneCity(anchor.timeZone))
        }
        let here = location.location?.coordinate
            ?? CLLocationCoordinate2D(latitude: 57.7016, longitude: 11.9668)
        return (here, .current, nil)
    }

    private var sunCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = sunReference.zone
        return c
    }

    /// "Europe/Stockholm" -> "Stockholm"
    private static func zoneCity(_ tz: TimeZone) -> String? {
        guard tz.identifier != TimeZone.current.identifier else { return nil }
        return tz.identifier.split(separator: "/").last
            .map { $0.replacingOccurrences(of: "_", with: " ") }
    }

    /// The Sun mode swaps the whole map surface for Mapbox — it is the only
    /// renderer that draws 3D buildings AND lets us relight them, which is
    /// what makes the hour slider legible. Everything else stays on MapKit.
    @ViewBuilder
    private var sunLayer: some View {
        SunMapboxView(
            readings: sunReadings,
            previewAt: sun.previewAt,
            selectedId: $selectedSunId,
            // The lighting reference: whatever you're looking at.
            centre: sunReference.coord,
            focus: sunFocus,
            pagingLocked: $pagingLocked,
            locateTick: locateTick
        )
    }

    private var modeToggle: some View {
        HStack(spacing: 0) {
            segButton("Deals", .deals)
            segButton("Beer", .prices)
            segButton("Sun", .sun)
        }
        .padding(3)
        .background(Capsule().fill(Color.ink.opacity(0.65)))
        .frame(maxWidth: 290)
    }

    private func segButton(_ title: String, _ mode: DealsMapMode) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                mapMode = mode; selectedVenue = nil
            }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(mapMode == mode ? Color.ink : Color.cream.opacity(0.7))
                .frame(maxWidth: .infinity).padding(.vertical, 7)
                .background(Capsule().fill(mapMode == mode ? Color.whiskey : .clear))
        }
        .buttonStyle(.plain)
    }

    /// Empty-state nudge to seed the beer-price map.
    private var contributeCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "mug.fill")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.whiskey)
            Text("Help build the beer map")
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.cream)
            Text("No prices near you yet. Add what a beer costs at a bar you know — it takes 10 seconds and helps everyone find the cheap ones.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.65))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button { submitPreset = nil; submitOpen = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill").font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("ADD A PRICE").font(.system(size: 13, weight: .bold, design: .monospaced)).tracking(1.4)
                }
                .foregroundStyle(Color.ink)
                .padding(.horizontal, 22).padding(.vertical, 13)
                .background(Capsule().fill(Color.whiskey))
                .shadow(color: Color.whiskey.opacity(0.4), radius: 14, y: 6)
            }
            .buttonStyle(PressScaleStyle())
        }
        .padding(24)
        .frame(maxWidth: 320)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.ink.opacity(0.9)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.whiskey.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
        .padding(.horizontal, 24)
    }

    private func circleButton(_ system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Color.cream)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.ink.opacity(0.7)))
                .overlay(Circle().strokeBorder(Color.cream.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(PressScaleStyle())
    }

    /// Centre on the user, at the same scale on every map.
    private func locateMe() {
        guard let loc = location.location else { return }
        if mapMode == .sun {
            // The Sun map is Mapbox and owns its own viewport, so it recentres
            // itself when the tick changes.
            sunFocus = loc.coordinate
            locateTick += 1
        } else {
            withAnimation(MapLocate.animation) {
                camera = .region(MKCoordinateRegion(
                    center: loc.coordinate,
                    latitudinalMeters: MapLocate.spanMeters,
                    longitudinalMeters: MapLocate.spanMeters))
            }
        }
    }

    private func recenter() {
        let span: CLLocationDistance = 4000
        if let loc = location.location {
            camera = .region(MKCoordinateRegion(center: loc.coordinate,
                                                latitudinalMeters: span, longitudinalMeters: span))
        } else if let first = pins.first {
            camera = .region(MKCoordinateRegion(
                center: venues.coordinate(for: first),
                latitudinalMeters: span, longitudinalMeters: span))
        } else {
            camera = .automatic
        }
    }
}

/// The venue's offer card, presented as a real sheet (medium detent) so the
/// map + pin stay visible above it and every button/dismiss works reliably.
private struct VenueOfferCard: View {
    let venue: Venue
    @ObservedObject var venues: VenueService

    var body: some View {
        // No close button: the top-of-sheet spot is contested by the
        // ScrollView pan + the sheet's drag gesture, so a tap there never
        // lands. Dismissal is swipe-down or a tap on the dimmed map above.
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(venue.name)
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.cream)
                    if !venue.displayLocation.isEmpty {
                        Text(venue.displayLocation)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.55))
                    }
                }
                if let poster = venues.posterOffer(for: venue) {
                    PosterBanner(offer: poster)
                }
                ForEach(venues.offers(for: venue)) { offer in
                    OfferRow(offer: offer)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .background(Color.ink)
    }
}

/// The "all deals" list — every bar with a live campaign, nearest first.
/// Tapping a row flies the map to it and opens its card.
private struct DealsListSheet: View {
    @ObservedObject var venues: VenueService
    @ObservedObject var location: LocationService
    let onSelect: (Venue) -> Void

    @State private var query = ""

    /// Nearby deals, then narrowed by the search text (name, offer, or area).
    private var list: [Venue] {
        let nearby = venues.dealsList(near: location.location)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return nearby }
        return nearby.filter { v in
            if v.name.lowercased().contains(q) { return true }
            if v.displayLocation.lowercased().contains(q) { return true }
            return venues.offers(for: v).contains { $0.title.lowercased().contains(q) }
        }
    }

    var body: some View {
        let list = self.list
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                Text("ALL DEALS")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(Color.bronze)
                    .padding(.bottom, 2)

                searchField

                if list.isEmpty {
                    Text(query.isEmpty ? "No live deals near you right now."
                                       : "No deals match “\(query)”.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.5))
                        .padding(.vertical, 20)
                }
                ForEach(list) { v in
                    Button { onSelect(v) } label: { row(v) }
                        .buttonStyle(PressScaleStyle())
                }
            }
            .padding(20)
        }
        .background(Color.ink)
        .preferredColorScheme(.dark)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.4))
            TextField("", text: $query, prompt:
                Text("Search bars or deals")
                    .foregroundStyle(Color.cream.opacity(0.4)))
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.35))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cream.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.cream.opacity(0.08), lineWidth: 1))
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func row(_ v: Venue) -> some View {
        let offers = venues.offers(for: v)
        HStack(spacing: 12) {
            Group {
                if let art = venues.posterOffer(for: v)?.imageURL {
                    DownsampledAsyncImage(url: art, targetPoints: 52)
                } else {
                    Color.whiskey.opacity(0.15)
                        .overlay(Image(systemName: "wineglass.fill")
                            .font(.system(size: 16, design: .rounded))
                            .foregroundStyle(Color.whiskey))
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(v.name)
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .lineLimit(1)
                if let top = offers.first {
                    Text(top.title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.whiskey)
                        .lineLimit(1)
                }
                if !v.displayLocation.isEmpty {
                    Text(v.displayLocation)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.45))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let d = venues.distance(from: location.location, to: v) {
                Text(d < 1000 ? "\(Int(d)) m" : String(format: "%.1f km", d / 1000))
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundStyle(Color.cream.opacity(0.6))
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.35))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.cream.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.cream.opacity(0.08), lineWidth: 1))
    }
}

/// Whiskey map pin; grows + shows a count badge when a venue has >1 offer.
private struct OfferPin: View {
    let count: Int
    let selected: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.whiskey)
                .frame(width: selected ? 42 : 34, height: selected ? 42 : 34)
                .shadow(color: Color.whiskey.opacity(0.6), radius: selected ? 10 : 5)
            Image(systemName: "wineglass.fill")
                .font(.system(size: selected ? 18 : 14, weight: .bold, design: .rounded))
                .foregroundStyle(Color.ink)
        }
        .overlay(alignment: .topTrailing) {
            if count > 1 {
                Text("\(count)")
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .foregroundStyle(Color.ink)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.cream))
                    .offset(x: 5, y: -5)
            }
        }
    }
}

// MARK: - Paid placements (migration 053)

/// Fire-and-forget impression/tap counters for paid creative. Impressions
/// dedupe per campaign per app session so scroll jitter can't inflate the
/// numbers the bars are paying to see.
enum CampaignStats {
    private static var seenThisSession = Set<UUID>()

    static func impression(_ id: UUID) {
        guard !seenThisSession.contains(id) else { return }
        seenThisSession.insert(id)
        bump(id, impressions: 1, taps: 0)
    }

    static func tap(_ id: UUID) {
        bump(id, impressions: 0, taps: 1)
    }

    private static func bump(_ id: UUID, impressions: Int, taps: Int) {
        struct P: Encodable {
            let p_campaign: String
            let p_impressions: Int
            let p_taps: Int
        }
        Task {
            _ = try? await supabase.rpc("bump_campaign_stats", params: P(
                p_campaign: id.uuidString.lowercased(),
                p_impressions: impressions,
                p_taps: taps
            )).execute()
        }
    }
}

/// Remembers which app-open interstitials a device has already seen
/// (persisted) and enforces at most one per launch (in-memory). A given
/// campaign shows once, ever, per device — the promo never nags. Local-only,
/// so it costs no server writes / egress.
enum DealsInterstitial {
    private static let key = "sesh.deals.interstitialSeen.v1"
    /// One promo per app launch; also set the moment we decide to show one.
    static var shownThisLaunch = false

    static func seenIDs() -> Set<UUID> {
        Set((UserDefaults.standard.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:)))
    }

    static func markSeen(_ id: UUID) {
        var arr = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard !arr.contains(id.uuidString) else { return }
        arr.append(id.uuidString)
        if arr.count > 200 { arr.removeFirst(arr.count - 200) }   // bound the history
        UserDefaults.standard.set(arr, forKey: key)
    }
}

/// Client side of the opt-in nearby-bar deal-push preference (migration 058).
/// Stored locally for instant UI and mirrored to the server so send_venue_push
/// knows the audience.
enum DealsPush {
    static let optInKey = "sesh.deals.pushOptIn.v1"
    /// Whether we've shown the one-time "want deals from nearby bars?" ask.
    static let promptedKey = "sesh.deals.pushPrompted.v1"
    private static let locSentKey = "sesh.deals.locSentAt.v1"

    static var isOptedIn: Bool { UserDefaults.standard.bool(forKey: optInKey) }
    static var wasPrompted: Bool { UserDefaults.standard.bool(forKey: promptedKey) }

    static func setOptIn(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: optInKey)
        // Force the next location report through so a fresh opt-in can be
        // targeted right away.
        if on { UserDefaults.standard.removeObject(forKey: locSentKey) }
        struct P: Encodable { let p_on: Bool }
        Task { _ = try? await supabase.rpc("set_deals_push_opt_in", params: P(p_on: on)).execute() }
    }

    static func markPrompted() { UserDefaults.standard.set(true, forKey: promptedKey) }

    /// Report a COARSE recent location so nearby-bar pushes can target the
    /// user — only when opted in, throttled to once an hour, and rounded to
    /// ~1 km (2 decimals) for privacy. No-op otherwise.
    static func reportLocation(_ loc: CLLocation) {
        guard isOptedIn else { return }
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: locSentKey)
        guard now - last > 3600 else { return }
        UserDefaults.standard.set(now, forKey: locSentKey)
        let lat = (loc.coordinate.latitude * 100).rounded() / 100
        let lon = (loc.coordinate.longitude * 100).rounded() / 100
        struct P: Encodable { let p_lat: Double; let p_lon: Double }
        Task { _ = try? await supabase.rpc("set_deals_location", params: P(p_lat: lat, p_lon: lon)).execute() }
    }
}

/// Pairs an interstitial offer with its venue for `.fullScreenCover(item:)`.
struct InterstitialPayload: Identifiable {
    let offer: VenueOffer
    let venue: Venue
    var id: UUID { offer.id }
}

/// App-open promo — the top "interstitial" add-on. A contained card (like the
/// poster pop-up, not full-screen) floating over a dimmed backdrop: the bar's
/// 4:3 POSTER image up top, then the offer and a "see this deal" CTA that flies
/// the Deals map to the bar. Marked SPONSORED — paid placement is never
/// disguised. Shown once per campaign per device, only near the bar. Tap the
/// backdrop, the ✕, or "Maybe later" to dismiss.
struct InterstitialView: View {
    let offer: VenueOffer
    let venue: Venue
    let onClose: () -> Void
    let onSeeDeal: () -> Void

    var body: some View {
        ZStack {
            // Dimmed backdrop — tap anywhere outside the card to dismiss.
            Color.black.opacity(0.7)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }

            card
                .padding(.horizontal, 22)
        }
        .onAppear { CampaignStats.impression(offer.id) }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 4:3 poster image — same ratio + fill-crop idiom as the poster
            // pin/card so artwork never reflows or overflows.
            Color.clear
                .aspectRatio(CampaignArt.posterRatio, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    ZStack {
                        Color.smoke
                        if let url = offer.imageURL {
                            DownsampledAsyncImage(url: url, targetPoints: 700, fill: true, placeholder: Color.smoke)
                        }
                    }
                }
                .clipped()
                .overlay(alignment: .topLeading) {
                    Text("SPONSORED")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(Color.cream.opacity(0.9))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color.black.opacity(0.45)))
                        .padding(10)
                }
                .overlay(alignment: .topTrailing) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.cream)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Color.black.opacity(0.5)))
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                }

            VStack(alignment: .leading, spacing: 10) {
                Text(venue.name.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(Color.whiskey)
                Text(offer.title)
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .lineLimit(2)
                if let d = offer.description, !d.isEmpty {
                    Text(d)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.8))
                        .lineLimit(2)
                }
                if let valid = offer.validDaysLabel {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar").font(.system(size: 11, weight: .bold, design: .rounded))
                        Text(valid).font(.system(size: 12, weight: .black, design: .rounded))
                    }
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(Color.whiskey))
                }

                Button(action: onSeeDeal) {
                    HStack(spacing: 8) {
                        Text("SEE THIS DEAL")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .tracking(1.5)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(Color.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.whiskey))
                    .shadow(color: Color.whiskey.opacity(0.45), radius: 14, y: 6)
                }
                .buttonStyle(PressScaleStyle())
                .padding(.top, 4)

                Button(action: onClose) {
                    Text("Maybe later")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.5))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
            .padding(18)
        }
        .background(Color.ink)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color.cream.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
    }
}

/// Poster-tier map pin: the bar's artwork in a rounded 4:3 frame — big enough
/// to stand out on the map, and the SAME ratio as the expanded poster card so
/// the image doesn't reflow when you tap it.
private struct PosterPin: View {
    let url: URL
    let selected: Bool

    /// Poster pins are large + prominent (the paid difference). 4:3.
    private var width: CGFloat { selected ? 108 : 92 }
    private var height: CGFloat { width / CampaignArt.posterRatio }

    var body: some View {
        ZStack {
            Color.smoke
            DownsampledAsyncImage(url: url, targetPoints: 220)  // fill the 4:3 pin
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.whiskey, lineWidth: selected ? 3 : 2)
        )
        .shadow(color: Color.whiskey.opacity(0.6), radius: selected ? 12 : 7, y: 2)
        .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selected)
    }
}

/// Poster creative at the top of a venue's offer card: artwork with a
/// bottom gradient carrying the campaign title/description. Marked
/// "Sponsored" — paid placement is never disguised as editorial content.
private struct PosterBanner: View {
    let offer: VenueOffer

    var body: some View {
        // Color.clear drives the 4:3 box size (same ratio as the map pin);
        // the greedy scaledToFill image lives in an overlay so it can't push
        // the box past the ratio.
        Color.clear
            .aspectRatio(CampaignArt.posterRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                ZStack(alignment: .bottomLeading) {
                    Color.smoke
                    if let url = offer.imageURL {
                        DownsampledAsyncImage(url: url, targetPoints: 360)
                    }
                    LinearGradient(colors: [.clear, Color.ink.opacity(0.85)],
                                   startPoint: .center, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(offer.title)
                            .font(.system(size: 17, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color.cream)
                        if let desc = offer.description {
                            Text(desc)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.cream.opacity(0.75))
                                .lineLimit(2)
                        }
                    }
                    .padding(12)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Text("SPONSORED")
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(Color.cream.opacity(0.75))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.ink.opacity(0.65)))
                    .padding(8)
            }
            .onAppear { CampaignStats.impression(offer.id) }
    }
}

/// Billboard tier: full-width rotating hero cards over the Deals map — a
/// strict 3:1 image banner with an info + CTA bar beneath it.
private struct BillboardCarousel: View {
    let entries: [(offer: VenueOffer, venue: Venue)]
    let onOpen: (Venue) -> Void

    @State private var index = 0
    /// Auto-advance between bars roughly every 3 seconds.
    private let rotate = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView(selection: $index) {
            ForEach(Array(entries.enumerated()), id: \.element.offer.id) { i, entry in
                BillboardCard(offer: entry.offer, venue: entry.venue) {
                    CampaignStats.tap(entry.offer.id)
                    onOpen(entry.venue)
                }
                .padding(.horizontal, 16)
                .tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: entries.count > 1 ? .automatic : .never))
        // image (3:1 of ~345 ≈ 115) + info bar (~62) + page-dot room.
        .frame(height: 200)
        .onReceive(rotate) { _ in
            guard entries.count > 1 else { return }
            withAnimation(.easeInOut(duration: 0.6)) {
                index = (index + 1) % entries.count
            }
        }
        // Keep the selection valid if the campaign set shrinks under us.
        .onChange(of: entries.count) { _, n in
            if index >= n { index = 0 }
        }
    }
}

private struct BillboardCard: View {
    let offer: VenueOffer
    let venue: Venue
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                // Strict 3:1 banner — Color.clear fixes the height, the greedy
                // fill image lives in an overlay so it can't stretch the box.
                Color.clear
                    .aspectRatio(CampaignArt.billboardRatio, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        ZStack {
                            Color.smoke
                            if let url = offer.billboardImageURL ?? offer.imageURL {
                                DownsampledAsyncImage(url: url, targetPoints: 400)
                            }
                        }
                    }
                    .clipped()
                    .overlay(alignment: .topLeading) {
                    Text("SPONSORED")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(Color.cream.opacity(0.85))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Color.ink.opacity(0.7)))
                        .padding(8)
                }
                    // Which days it's valid — pinned to the banner's top-right
                    // so it reads even in the compact billboard.
                    .overlay(alignment: .topTrailing) {
                        if let vd = offer.validDaysPill {
                            HStack(spacing: 3) {
                                Image(systemName: "calendar").font(.system(size: 8, weight: .bold, design: .rounded))
                                Text(vd).font(.system(size: 9, weight: .black, design: .monospaced)).tracking(0.6)
                            }
                            .foregroundStyle(Color.ink)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Color.whiskey))
                            .padding(8)
                        }
                    }

                // Info + CTA bar beneath the banner.
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(venue.name.uppercased())
                            .font(.system(size: 9, weight: .black, design: .monospaced))
                            .tracking(1.4)
                            .foregroundStyle(Color.whiskey)
                            .lineLimit(1)
                        Text(offer.title)
                            .font(.system(size: 15, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color.cream)
                            .lineLimit(1)
                        if let desc = offer.description {
                            Text(desc)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.cream.opacity(0.65))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 6)
                    HStack(spacing: 5) {
                        Text("SEE DEAL")
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .tracking(0.8)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .black, design: .rounded))
                    }
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Capsule().fill(Color.whiskey))
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(Color.inkElev)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.whiskey.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
        }
        .buttonStyle(PressScaleStyle())
        .onAppear { CampaignStats.impression(offer.id) }
    }
}

/// One offer inside the venue card, with a tap-to-reveal "show at the bar"
/// redeem state. No server validation in Phase A — the live clock just lets
/// staff see it's genuine and not a screenshot.
private struct OfferRow: View {
    let offer: VenueOffer
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: offer.glyph)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.whiskey)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text(offer.title)
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.cream)
                    if let d = offer.description {
                        Text(d)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Which days/times the deal is actually redeemable — made
                    // loud so a "valid Wednesdays" deal reads at a glance, even
                    // when it's marketed all week.
                    HStack(spacing: 8) {
                        if let vd = offer.validDaysLabel { validPill(vd) }
                        if let w = offer.windowLabel { tag(w, system: "clock") }
                    }
                    .padding(.top, 2)
                    if let fp = offer.finePrint {
                        Text(fp)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.bronze)
                    }
                }
                Spacer(minLength: 0)
            }

            if revealed {
                redeemBanner
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { revealed = true }
                } label: {
                    Text("SHOW AT THE BAR")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(Color.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.whiskey))
                }
                .buttonStyle(PressScaleStyle())
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cream.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.cream.opacity(0.08), lineWidth: 1))
    }

    private var redeemBanner: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(offer.code ?? "SHOW THIS TO STAFF")
                        .font(.system(size: 14, weight: .black, design: .monospaced))
                        .foregroundStyle(Color.ink)
                    Text(context.date, format: .dateTime.weekday().hour().minute().second())
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.ink.opacity(0.7))
                }
                Spacer()
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.ink)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.whiskey))
        }
    }

    private func tag(_ text: String, system: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: system).font(.system(size: 9, weight: .bold, design: .rounded))
            Text(text).font(.system(size: 10, weight: .black, design: .monospaced))
        }
        .foregroundStyle(Color.whiskey)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(Color.whiskey.opacity(0.12)))
    }

    /// The prominent validity pill — solid whiskey so the redeemable days
    /// can't be missed ("Valid Wednesdays", "Valid Fri–Sat").
    private func validPill(_ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "calendar").font(.system(size: 10, weight: .bold, design: .rounded))
            Text(text).font(.system(size: 11, weight: .black, design: .rounded))
        }
        .foregroundStyle(Color.ink)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(Color.whiskey))
    }
}

// MARK: - Venue Chip / Sheet
//
// The chip is the user's persistent "Tonight at: <bar>" marker — shown
// in the home view header. Tap → VenueSheet → search Apple Maps and
// check in to any bar, or check out. When a venue is selected the chip
// glows whiskey, otherwise it's a discreet "find bars near you" CTA.

struct VenueChip: View {
    @ObservedObject var location: LocationService
    @ObservedObject var venues: VenueService
    /// Compact = side-by-side variant under the BAC readout (see GroupBar).
    var compact: Bool = false
    /// When the venue name is already shown elsewhere (the LIVE Night Snaps
    /// card), this chip drops the name and becomes a plain "change location"
    /// control instead of repeating "TONIGHT AT · <venue>".
    var nameShownElsewhere: Bool = false
    var onTap: () -> Void

    /// Subtitle shown when no venue is checked in. Matches whatever state
    /// the user is in so the CTA always tells them what tapping does.
    private var prompt: String {
        switch location.authState {
        case .notDetermined: return "Find bars near you"
        case .denied:        return "Choose a bar"
        case .restricted:    return "Choose a bar"
        case .authorized:    return "Tap to check in"
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: compact ? 9 : 12) {
                ZStack {
                    Circle()
                        .fill(venues.currentVenue == nil ? Color.cream.opacity(0.05) : Color.whiskey.opacity(0.18))
                        .frame(width: compact ? 28 : 32, height: compact ? 28 : 32)
                    Image(systemName: venues.currentVenue == nil
                          ? "mappin.and.ellipse"
                          : "mappin.circle.fill")
                        .font(.system(size: compact ? 12 : 13, weight: .bold, design: .rounded))
                        .foregroundStyle(venues.currentVenue == nil ? Color.bronze : Color.whiskey)
                }

                if let v = venues.currentVenue {
                    if nameShownElsewhere {
                        // Name lives in the Night Snaps card — here we're just
                        // a "change location" control.
                        VStack(alignment: .leading, spacing: 2) {
                            Text("LOCATION")
                                .font(.system(size: compact ? 9 : 10, weight: .semibold, design: .monospaced))
                                .tracking(compact ? 1.6 : 2.2)
                                .foregroundStyle(Color.whiskey)
                            Text("Change location")
                                .font(.system(size: compact ? 13 : 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.cream)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("TONIGHT AT")
                                    .font(.system(size: compact ? 9 : 10, weight: .semibold, design: .monospaced))
                                    .tracking(compact ? 1.6 : 2.2)
                                    .foregroundStyle(Color.whiskey)
                                if v.isFeatured {
                                    Text("★")
                                        .font(.system(size: 10, weight: .black, design: .rounded))
                                        .foregroundStyle(Color.whiskey)
                                }
                            }
                            if compact {
                                Text(v.name)
                                    .font(.system(size: 14, weight: .black, design: .rounded))
                                    .foregroundStyle(Color.cream)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            } else {
                                HStack(spacing: 8) {
                                    Text(v.name)
                                        .font(.system(size: 15, weight: .black, design: .rounded))
                                        .foregroundStyle(Color.cream)
                                        .lineLimit(1)
                                    if !v.displayLocation.isEmpty {
                                        Text("·")
                                            .foregroundStyle(Color.bronze)
                                        Text(v.displayLocation)
                                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                                            .tracking(0.4)
                                            .foregroundStyle(Color.cream.opacity(0.6))
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("LOCATION")
                            .font(.system(size: compact ? 9 : 10, weight: .semibold, design: .monospaced))
                            .tracking(compact ? 1.6 : 2.2)
                            .foregroundStyle(Color.bronze)
                        Text(compact ? "Check in" : prompt)
                            .font(.system(size: compact ? 13 : 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.cream)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }

                Spacer(minLength: 0)

                if !compact {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.bronze)
                }
            }
            .padding(.horizontal, compact ? 12 : 14)
            .padding(.vertical, compact ? 10 : 12)
            .background(
                RoundedRectangle(cornerRadius: compact ? 14 : 18, style: .continuous)
                    .fill(Color.inkElev.opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 14 : 18, style: .continuous)
                    .strokeBorder(
                        venues.currentVenue == nil
                            ? Color.cream.opacity(0.08)
                            : Color.whiskey.opacity(0.45),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
        }
        .buttonStyle(PressScaleStyle())
    }
}

struct VenueSheet: View {
    @ObservedObject var location: LocationService
    @ObservedObject var venues: VenueService
    /// The live group, when one is running — enables "check in the whole
    /// group" so not everyone has to check in. nil ⇒ solo (no group UI).
    @ObservedObject var group: SessionService
    @StateObject private var search = MapKitVenueSearch()
    @State private var query: String = ""
    @State private var checkInInFlight: String? = nil
    @State private var qrOpen = false
    /// "Move the whole group" vs "just me" for this check-in. Defaults to
    /// the group when one is active.
    @State private var applyToGroup = true
    @Environment(\.dismiss) private var dismiss

    /// True when a live group is running — gates all the group-check-in UI.
    private var inLiveGroup: Bool { group.isActive }
    /// Map camera + the tapped bar. Selecting any bar (our search pins OR
    /// the map's own built-in POIs) recenters to show it alongside the
    /// user and surfaces a check-in card.
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var mapSelection: MapSelection<MKMapItem>?
    @State private var selectedVenue: SelectedVenue? = nil

    /// A bar the user tapped on the map. `result`/`venue` are set when the
    /// pin maps back to a known place; otherwise it's a built-in POI we
    /// check into by name + coordinate.
    private struct SelectedVenue: Equatable {
        let name: String
        let lat: Double
        let lon: Double
        let result: MapKitVenueResult?
        let venue: Venue?
        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }

    /// Featured/curated venues only. MapKit-tier rows that the user has
    /// previously checked into are omitted here — they surface via search,
    /// not via this curated list.
    private var featuredVenues: [Venue] {
        venues.sortedByDistance(from: location.location)
            .filter { $0.source == .curated }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func distanceLabel(for venue: Venue) -> String? {
        guard let m = venues.distance(from: location.location, to: venue) else { return nil }
        if m < 1000 { return "\(Int(m.rounded())) m away" }
        return String(format: "%.1f km away", m / 1000)
    }

    private func distanceLabel(metres: CLLocationDistance?) -> String? {
        guard let m = metres else { return nil }
        if m < 1000 { return "\(Int(m.rounded())) m away" }
        return String(format: "%.1f km away", m / 1000)
    }

    /// The curated offer-venue a search hit corresponds to (matched by being
    /// at essentially the same spot as the venue's resolved coordinate), if
    /// any. Lets us flag the search row as having a special and suppress the
    /// duplicate plain pin on the map (the offer pin already covers it).
    private func offerVenue(for result: MapKitVenueResult) -> Venue? {
        let hit = CLLocation(latitude: result.lat, longitude: result.lon)
        return venues.venuesWithOffers.first { venue in
            let c = venues.coordinate(for: venue)
            return CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: hit) < 100
        }
    }

    /// True when an offer-venue is one of the current search hits — so its
    /// deal pin can enlarge to point out "this is the bar you searched".
    private func matchesSearch(_ venue: Venue) -> Bool {
        guard !search.results.isEmpty else { return false }
        let c = venues.coordinate(for: venue)
        let vLoc = CLLocation(latitude: c.latitude, longitude: c.longitude)
        return search.results.contains {
            CLLocation(latitude: $0.lat, longitude: $0.lon).distance(from: vLoc) < 100
        }
    }

    var body: some View {
        ZStack {
            AtmosphereBackground(accent: .whiskey)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionLabel("Check in")
                        Text("Tonight at…")
                            .font(.system(size: 32, weight: .heavy, design: .rounded))
                            .tracking(-1.2)
                            .foregroundStyle(Color.cream)
                    }

                    permissionStripe

                    groupCheckInBar

                    if venues.currentVenue != nil {
                        Button {
                            Task {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    venues.currentVenue = nil
                                }
                                if inLiveGroup {
                                    if applyToGroup { await group.setGroupVenue(nil) }
                                    else { group.followingGroupVenue = false }
                                }
                                dismiss()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                Text(inLiveGroup && applyToGroup ? "CHECK GROUP OUT" : "CHECK OUT")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .tracking(2.0)
                            }
                            .foregroundStyle(Color.cream.opacity(0.7))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Capsule().fill(Color.cream.opacity(0.06)))
                            .overlay(Capsule().strokeBorder(Color.cream.opacity(0.18), lineWidth: 1))
                        }
                        .buttonStyle(PressScaleStyle())
                    }

                    searchField

                    qrCheckInRow

                    venueMapSection

                    // Curated specials are NOT listed here (that would crowd
                    // the check-in sheet) — bars with offers show as deal pins
                    // on the map above, and the DEALS tab is the place to
                    // browse all nearby offers. Only the live Apple Maps search
                    // results list below, when the user is searching.
                    if !trimmedQuery.isEmpty {
                        searchSection
                    }

                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await venues.refresh()
            location.requestAccess()
            // Accurate pins for bars with specials (cached after first run).
            await venues.resolveOfferCoordinates()
        }
        // Default the toggle to whatever the user is currently doing —
        // following ⇒ "whole group", broken away ⇒ "just me".
        .onAppear { applyToGroup = group.followingGroupVenue }
        // New search hits → drop any stale selection and frame the pins
        // (plus the user) so "where am I / where's the bar" is answered.
        .onChange(of: search.results) { _, _ in
            mapSelection = nil
            selectedVenue = nil
            if let region = regionFittingAllPins() {
                withAnimation(.easeInOut(duration: 0.5)) { camera = .region(region) }
            }
        }
        // Tapping a bar on the map (our pin or a built-in POI) → resolve
        // it and recenter to show it alongside the user.
        .onChange(of: mapSelection) { _, sel in
            let resolved = resolveSelection(sel)
            selectedVenue = resolved
            if let resolved {
                withAnimation(.easeInOut(duration: 0.5)) {
                    camera = .region(regionFitting(coordinate: resolved.coordinate))
                }
            }
        }
        // Debounced re-search: 300ms after the user stops typing. .task(id:)
        // cancels the previous Task whenever `query` changes, so the sleep
        // gets thrown away and only the latest keystroke runs MKLocalSearch.
        .task(id: query) {
            let snapshot = trimmedQuery
            guard !snapshot.isEmpty else {
                search.clear()
                return
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            // biasToOrigin: false — reach any bar anywhere, the same as the sun
            // search. `origin` is still passed so results carry a distance, but
            // it no longer restricts the region: reporting a beer price for a bar
            // in Tokyo shouldn't require standing in Tokyo.
            search.search(query: snapshot, origin: location.location,
                          biasToOrigin: false)
        }
    }

    /// The map + a check-in card for the tapped bar. Shows your live
    /// location (blue dot), your search-result pins, and the map's own
    /// bar POIs — tap any of them to pick a venue visually.
    private var venueMapSection: some View {
        VStack(spacing: 10) {
            Map(position: $camera, selection: $mapSelection) {
                UserAnnotation()
                // Bars with live specials — a deal pin (same as the DEALS map)
                // so you can spot, at a glance, which bars have an offer. Tap
                // to preview + check in from the card.
                ForEach(venues.venuesWithOffers) { venue in
                    Annotation(
                        venue.name,
                        coordinate: venues.coordinate(for: venue)
                    ) {
                        OfferPin(count: venues.offers(for: venue).count,
                                 selected: selectedVenue?.venue?.id == venue.id
                                     || matchesSearch(venue))
                            .onTapGesture { selectVenue(venue) }
                    }
                }
                // Search-result pins — selectable (Marker(item:) feeds the
                // MapSelection binding). Skip any hit that's already a curated
                // offer venue: the deal pin above covers it, so a special bar
                // shows ONE (special) pin, not a duplicate plain one.
                ForEach(search.results) { result in
                    if let item = result.mapItem, offerVenue(for: result) == nil {
                        Marker(result.name, systemImage: "wineglass.fill", coordinate: result.coordinate)
                            .tint(venues.currentVenue?.externalId == result.id ? Color.green : Color.whiskey)
                            .tag(MapSelection(item))
                    }
                }
                // The active check-in, always highlighted green.
                if let cur = venues.currentVenue {
                    Marker(cur.name, systemImage: "checkmark", coordinate:
                        CLLocationCoordinate2D(latitude: cur.lat, longitude: cur.lon))
                        .tint(Color.green)
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .including([.nightlife, .restaurant, .brewery, .winery])))
            .mapControls { MapCompass() }
            .frame(height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            // Our own locate button rather than MapUserLocationButton, so this
            // map lands at the same scale as every other one. Apple's control
            // gives no control over the resulting zoom.
            .overlay(alignment: .bottomTrailing) {
                LocateMeButton(enabled: location.location != nil) {
                    guard let loc = location.location else { return }
                    withAnimation(MapLocate.animation) {
                        camera = .region(MKCoordinateRegion(
                            center: loc.coordinate,
                            latitudinalMeters: MapLocate.spanMeters,
                            longitudinalMeters: MapLocate.spanMeters))
                    }
                }
                .padding(10)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.cream.opacity(0.1), lineWidth: 1)
            )

            if let selected = selectedVenue {
                selectedPinCard(selected)
            } else {
                Text("Tap any bar on the map to check in there.")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .tracking(0.4)
                    .foregroundStyle(Color.cream.opacity(0.45))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Resolve a map tap into a venue. Our own pins arrive as `.value`
    /// (the tagged MKMapItem); the map's built-in POIs arrive as
    /// `.feature` (title + coordinate only).
    private func resolveSelection(_ sel: MapSelection<MKMapItem>?) -> SelectedVenue? {
        guard let sel else { return nil }
        if let item = sel.value {
            if let r = search.results.first(where: { $0.mapItem == item }) {
                return SelectedVenue(name: r.name, lat: r.lat, lon: r.lon, result: r, venue: nil)
            }
            let c = item.placemark.coordinate
            return SelectedVenue(name: item.name ?? "Bar", lat: c.latitude, lon: c.longitude, result: nil, venue: nil)
        }
        if let feature = sel.feature {
            let c = feature.coordinate
            return SelectedVenue(name: feature.title ?? "Bar", lat: c.latitude, lon: c.longitude, result: nil, venue: nil)
        }
        return nil
    }

    private func isCurrent(_ sel: SelectedVenue) -> Bool {
        if let r = sel.result { return venues.currentVenue?.externalId == r.id }
        if let v = sel.venue { return venues.currentVenue?.id == v.id }
        return false
    }

    private func selectedPinCard(_ sel: SelectedVenue) -> some View {
        let current = isCurrent(sel)
        return HStack(spacing: 12) {
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(current ? Color.green : Color.whiskey)
            VStack(alignment: .leading, spacing: 2) {
                Text(sel.name)
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .lineLimit(1)
                if let d = distanceLabel(metres: distanceTo(sel.coordinate)) {
                    Text(d)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.cream.opacity(0.55))
                }
            }
            Spacer(minLength: 8)
            Button {
                Task { await checkIn(sel) }
            } label: {
                Text(current ? "CHECKED IN" : (checkInInFlight != nil ? "…" : "CHECK IN"))
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(current ? Color.cream.opacity(0.5) : Color.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(current ? Color.cream.opacity(0.08) : Color.whiskey))
            }
            .buttonStyle(PressScaleStyle())
            .disabled(current || checkInInFlight != nil)

            // ✕ — drop this pick and choose another bar.
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { clearSelection() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.5))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.cream.opacity(0.06)))
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel("Clear selection")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.cream.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.whiskey.opacity(0.3), lineWidth: 1)
        )
    }

    private func distanceTo(_ coordinate: CLLocationCoordinate2D) -> CLLocationDistance? {
        guard let origin = location.location else { return nil }
        return CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude).distance(from: origin)
    }

    /// QR fast-path: scan the table code (or type it) and skip the search.
    private var qrCheckInRow: some View {
        Button { qrOpen = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.whiskey)
                VStack(alignment: .leading, spacing: 1) {
                    Text("SCAN THE TABLE CODE")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(1.8)
                        .foregroundStyle(Color.cream)
                    Text("Bars with a sesh QR check you in instantly.")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.55))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.bronze)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.whiskey.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.whiskey.opacity(0.28), lineWidth: 1)
            )
        }
        .buttonStyle(PressScaleStyle())
        .sheet(isPresented: $qrOpen) {
            QRCheckInSheet { resolved in
                Task { await checkIn(qrVenue: resolved) }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.ink)
        }
    }

    /// A QR-resolved bar is a curated venues-table row: prefer the loaded
    /// Venue (keeps ids consistent), else fall back to the MapKit pipeline
    /// with a synthetic result.
    @MainActor
    private func checkIn(qrVenue resolved: QRVenue) async {
        if let known = venues.venues.first(where: { $0.id == resolved.id }) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                venues.currentVenue = known
            }
            await broadcastCheckIn()
            dismiss()
        } else {
            await performCheckIn(MapKitVenueResult(
                name: resolved.name,
                coordinate: CLLocationCoordinate2D(latitude: resolved.lat, longitude: resolved.lon),
                origin: location.location
            ))
        }
    }

    /// Check in from a map tap — known search result / curated venue go
    /// through their own paths; a tapped built-in POI becomes a synthetic
    /// MapKit result so it writes through the same check-in pipeline.
    @MainActor
    private func checkIn(_ sel: SelectedVenue) async {
        if let result = sel.result {
            await performCheckIn(result)
        } else if let venue = sel.venue {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                venues.currentVenue = venue
            }
            await broadcastCheckIn()
            dismiss()
        } else {
            await performCheckIn(MapKitVenueResult(
                name: sel.name, coordinate: sel.coordinate, origin: location.location
            ))
        }
    }

    /// Select a search-result row → highlight it on the map + show the
    /// confirm card (no check-in yet). Routing through `mapSelection`
    /// lets the existing onChange recenter + resolve.
    private func selectResult(_ result: MapKitVenueResult) {
        if let item = result.mapItem {
            mapSelection = MapSelection(item)
        } else {
            selectedVenue = SelectedVenue(
                name: result.name, lat: result.lat, lon: result.lon, result: result, venue: nil
            )
            withAnimation(.easeInOut(duration: 0.5)) {
                camera = .region(regionFitting(coordinate: result.coordinate))
            }
        }
    }

    /// Select a curated venue row → preview on the map + confirm card.
    private func selectVenue(_ venue: Venue) {
        mapSelection = nil
        // Use the resolved (real Apple Maps) coordinate — the same spot the
        // deal pin is drawn at — so the camera centres on the pin instead of
        // the seeded approximate point.
        let coord = venues.coordinate(for: venue)
        selectedVenue = SelectedVenue(
            name: venue.name, lat: coord.latitude, lon: coord.longitude, result: nil, venue: venue
        )
        withAnimation(.easeInOut(duration: 0.5)) {
            camera = .region(regionFitting(coordinate: coord))
        }
    }

    /// Clear the current preview — the card's ✕, "pick another bar".
    private func clearSelection() {
        mapSelection = nil
        selectedVenue = nil
    }

    /// Region containing a coordinate and (when known) the user, so both
    /// are on screen.
    private func regionFitting(coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        var coords = [coordinate]
        if let loc = location.location { coords.append(loc.coordinate) }
        return region(around: coords) ?? MKCoordinateRegion(
            center: coordinate, latitudinalMeters: 600, longitudinalMeters: 600
        )
    }

    private func regionFittingAllPins() -> MKCoordinateRegion? {
        var coords = search.results.map(\.coordinate)
        if let loc = location.location { coords.append(loc.coordinate) }
        return region(around: coords)
    }

    private func region(around coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard !coords.isEmpty else { return nil }
        let lats = coords.map(\.latitude)
        let lons = coords.map(\.longitude)
        let minLat = lats.min()!, maxLat = lats.max()!
        let minLon = lons.min()!, maxLon = lons.max()!
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.6, 0.006),
            longitudeDelta: max((maxLon - minLon) * 1.6, 0.006)
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Color.bronze)
            TextField("", text: $query, prompt:
                Text("Search any bar nearby…")
                    .foregroundStyle(Color.cream.opacity(0.45))
            )
            .textFieldStyle(.plain)
            .autocorrectionDisabled(true)
            .textInputAutocapitalization(.words)
            .submitLabel(.search)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.cream)
            if !trimmedQuery.isEmpty {
                Button {
                    query = ""
                    search.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.cream.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.cream.opacity(0.1), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var featuredSection: some View {
        if !featuredVenues.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("FEATURED", caption: "Curated bars with specials")
                ForEach(featuredVenues) { venue in
                    VenueRow(
                        venue: venue,
                        distance: distanceLabel(for: venue),
                        specialsCount: venues.specials(for: venue).count,
                        isCurrent: venues.currentVenue?.id == venue.id
                            || selectedVenue?.venue?.id == venue.id
                    ) {
                        // Preview on the map first; confirm from the card.
                        selectVenue(venue)
                    }
                }
            }
        } else {
            emptyState
        }
    }

    @ViewBuilder
    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                "ANY BAR",
                caption: search.isSearching ? "Searching…" : "From Apple Maps"
            )
            if search.isSearching && search.results.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().tint(Color.whiskey)
                    Text("Looking for places near you…")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.55))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 18)
            } else if search.results.isEmpty {
                Text("No bars matched “\(trimmedQuery)”.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.55))
                    .padding(.vertical, 14)
            } else {
                ForEach(search.results) { result in
                    let offer = offerVenue(for: result)
                    MapKitResultRow(
                        result: result,
                        distance: distanceLabel(metres: result.distance),
                        isPending: checkInInFlight == result.id,
                        isCurrent: venues.currentVenue?.externalId == result.id
                            || selectedVenue?.result?.id == result.id
                            || (offer != nil && selectedVenue?.venue?.id == offer?.id),
                        offerCount: offer.map { venues.offers(for: $0).count } ?? 0
                    ) {
                        // Preview on the map first — don't check in yet.
                        // A curated offer bar previews the curated venue (so
                        // its specials attach on check-in); anything else
                        // previews the raw Apple Maps hit.
                        if let offer {
                            selectVenue(offer)
                        } else {
                            selectResult(result)
                        }
                    }
                }
            }
        }
    }

    @MainActor
    private func performCheckIn(_ result: MapKitVenueResult) async {
        checkInInFlight = result.id
        await venues.checkIn(mapKitResult: result)
        await broadcastCheckIn()
        checkInInFlight = nil
        dismiss()
    }

    /// After a local check-in, propagate it to the group (or peel off).
    /// No-op when solo.
    private func broadcastCheckIn() async {
        guard inLiveGroup else { return }
        if applyToGroup {
            group.followingGroupVenue = true
            await group.setGroupVenue(venues.currentVenue)
        } else {
            // "Just me" → stop following so the group's moves don't pull
            // me along.
            group.followingGroupVenue = false
        }
    }

    /// Group check-in controls — "whole group vs just me" + a rejoin
    /// affordance once you've broken away. Only shown in a live group.
    @ViewBuilder
    private var groupCheckInBar: some View {
        if inLiveGroup {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .foregroundStyle(Color.whiskey)
                    Text("CHECK IN APPLIES TO")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .tracking(2.0)
                        .foregroundStyle(Color.whiskey)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    groupSegment(title: "WHOLE GROUP", icon: "person.2.fill", active: applyToGroup) {
                        applyToGroup = true
                    }
                    groupSegment(title: "JUST ME", icon: "person.fill", active: !applyToGroup) {
                        applyToGroup = false
                    }
                }
                if !group.followingGroupVenue {
                    // Prominent rejoin — you've peeled off, big tap target
                    // to snap back to wherever the group is now.
                    Button {
                        group.followingGroupVenue = true
                        applyToGroup = true
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                            venues.currentVenue = group.liveVenue
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.triangle.merge")
                                .font(.system(size: 15, weight: .black, design: .rounded))
                            VStack(alignment: .leading, spacing: 1) {
                                Text("REJOIN THE GROUP")
                                    .font(.system(size: 13, weight: .black, design: .monospaced))
                                    .tracking(1.6)
                                if let lv = group.liveVenue {
                                    Text("They're at \(lv.name)")
                                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                                        .opacity(0.85)
                                        .lineLimit(1)
                                } else {
                                    Text("You're on your own right now")
                                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                                        .opacity(0.85)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.whiskey)
                        )
                        .shadow(color: Color.whiskey.opacity(0.4), radius: 12, y: 4)
                    }
                    .buttonStyle(PressScaleStyle())
                } else if let lv = group.liveVenue {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.whiskey)
                        Text("Following the group · \(lv.name)")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.7))
                            .lineLimit(1)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.whiskey.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.whiskey.opacity(0.25), lineWidth: 1)
            )
        }
    }

    private func groupSegment(title: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { action() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                Text(title)
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(1.2)
            }
            .foregroundStyle(active ? Color.ink : Color.cream.opacity(0.7))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                Capsule().fill(active ? Color.whiskey : Color.cream.opacity(0.05))
            )
            .overlay(
                Capsule().strokeBorder(Color.cream.opacity(active ? 0 : 0.1), lineWidth: 1)
            )
        }
        .buttonStyle(PressScaleStyle())
    }

    private func sectionHeader(_ title: String, caption: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(2.2)
                .foregroundStyle(Color.whiskey)
            Text(caption)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(Color.cream.opacity(0.45))
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var permissionStripe: some View {
        switch location.authState {
        case .notDetermined:
            permissionRow(
                title: "Enable location",
                detail: "Sesh uses location only while open, to find bars near you.",
                cta: "ALLOW"
            ) {
                location.requestAccess()
            }
        case .denied, .restricted:
            permissionRow(
                title: "Location is off",
                detail: "Open Settings to enable, or pick a bar manually below.",
                cta: "SETTINGS"
            ) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        case .authorized:
            EmptyView()
        }
    }

    private func permissionRow(title: String, detail: String, cta: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.cream)
                Text(detail)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.6))
            }
            Spacer(minLength: 8)
            Button(action: action) {
                Text(cta)
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.whiskey))
            }
            .buttonStyle(PressScaleStyle())
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.cream.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.whiskey.opacity(0.25), lineWidth: 1)
        )
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, design: .rounded))
                .foregroundStyle(Color.bronze)
            Text("Find your bar")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(Color.cream)
            Text("Search above to check in to any bar on Apple Maps. Specials attach automatically for venues we know.")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

private struct VenueRow: View {
    let venue: Venue
    let distance: String?
    let specialsCount: Int
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(isCurrent ? Color.whiskey.opacity(0.35) : Color.cream.opacity(0.06))
                        .frame(width: 44, height: 44)
                    Image(systemName: venue.isFeatured ? "star.fill" : "mappin.circle.fill")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(venue.isFeatured ? Color.whiskey : Color.cream.opacity(0.7))
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(venue.name)
                            .font(.system(size: 16, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color.cream)
                        if venue.isFeatured {
                            Text("FEATURED")
                                .font(.system(size: 8.5, weight: .black, design: .monospaced))
                                .tracking(1.4)
                                .foregroundStyle(Color.ink)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.whiskey))
                        }
                    }
                    HStack(spacing: 8) {
                        if !venue.displayLocation.isEmpty {
                            Text(venue.displayLocation)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .tracking(0.4)
                                .foregroundStyle(Color.cream.opacity(0.55))
                                .lineLimit(1)
                        }
                        if let d = distance {
                            Text("·")
                                .foregroundStyle(Color.cream.opacity(0.3))
                            Text(d)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .tracking(0.4)
                                .foregroundStyle(Color.cream.opacity(0.55))
                        }
                    }
                    if specialsCount > 0 {
                        Text("\(specialsCount) special\(specialsCount == 1 ? "" : "s")")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(1.2)
                            .foregroundStyle(Color.whiskey)
                    }
                }
                Spacer(minLength: 0)
                if isCurrent {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.whiskey)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isCurrent ? Color.whiskey.opacity(0.12) : Color.cream.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        isCurrent ? Color.whiskey.opacity(0.55) : Color.cream.opacity(0.08),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// Row for a MapKit search hit. Visually muted compared to VenueRow so
/// the user reads "this is not a curated bar, just any place that exists
/// on the map" — UNLESS the hit is one of our curated offer venues, in
/// which case it gets the whiskey treatment + a SPECIAL badge. Tapping
/// triggers a check-in flow that may need a network round-trip, hence the
/// spinner state.
private struct MapKitResultRow: View {
    let result: MapKitVenueResult
    let distance: String?
    let isPending: Bool
    let isCurrent: Bool
    /// >0 when this hit is a curated offer venue — drives the special styling.
    var offerCount: Int = 0
    let action: () -> Void

    private var hasOffer: Bool { offerCount > 0 }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(hasOffer ? Color.whiskey
                              : (isCurrent ? Color.whiskey.opacity(0.32) : Color.cream.opacity(0.05)))
                        .frame(width: 44, height: 44)
                    if isPending {
                        ProgressView().tint(Color.cream.opacity(0.8))
                    } else {
                        Image(systemName: hasOffer ? "wineglass.fill" : "mappin")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(hasOffer ? Color.ink
                                             : (isCurrent ? Color.whiskey : Color.cream.opacity(0.6)))
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(result.name)
                            .font(.system(size: 15, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color.cream)
                            .lineLimit(1)
                        if hasOffer {
                            HStack(spacing: 3) {
                                Image(systemName: "tag.fill")
                                    .font(.system(size: 8, weight: .black, design: .rounded))
                                Text(offerCount == 1 ? "SPECIAL" : "\(offerCount) SPECIALS")
                                    .font(.system(size: 9, weight: .black, design: .monospaced))
                                    .tracking(1.0)
                            }
                            .foregroundStyle(Color.ink)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Color.whiskey))
                            .shadow(color: Color.whiskey.opacity(0.5), radius: 4)
                        }
                    }
                    HStack(spacing: 8) {
                        if let addr = result.address, !addr.isEmpty {
                            Text(addr)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .tracking(0.4)
                                .foregroundStyle(Color.cream.opacity(0.5))
                                .lineLimit(1)
                        } else if let city = result.city {
                            Text(city)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .tracking(0.4)
                                .foregroundStyle(Color.cream.opacity(0.5))
                                .lineLimit(1)
                        }
                        if let d = distance {
                            Text("·")
                                .foregroundStyle(Color.cream.opacity(0.25))
                            Text(d)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .tracking(0.4)
                                .foregroundStyle(Color.cream.opacity(0.5))
                        }
                    }
                }
                Spacer(minLength: 0)
                if isCurrent {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.whiskey)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.bronze.opacity(0.55))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(hasOffer ? Color.whiskey.opacity(0.15)
                          : (isCurrent ? Color.whiskey.opacity(0.10) : Color.cream.opacity(0.025)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        hasOffer ? Color.whiskey.opacity(0.5)
                        : (isCurrent ? Color.whiskey.opacity(0.45) : Color.cream.opacity(0.06)),
                        lineWidth: 1
                    )
            )
            .opacity(isPending ? 0.7 : 1)
        }
        .buttonStyle(PressScaleStyle())
        .disabled(isPending)
    }
}

