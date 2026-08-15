// Crowdsourced beer-price map (migrations 061–063). Users report what a beer
// costs at a bar for a given serving size (25/33/40/50/pint); the map filters
// by serving and colours each bar green→red. This file holds the colour scale,
// the map pin, the tap-detail card, and the submit flow. The map-mode wiring
// lives in Venues.swift.

import SwiftUI
import MapKit
import CoreLocation

// MARK: - Colour scale

/// Maps a price to a traffic-light colour, RELATIVE to the cheapest beer in the
/// area (for the same serving + currency). The cheapest is always green; a beer
/// double that price is fully red; a gradient between. Currency- and
/// size-agnostic — it just compares like with like, whatever the local prices.
enum BeerPriceScale {
    /// The local price distribution the gradient hangs on: green at the
    /// cheapest, YELLOW AT THE MEDIAN, red at the dearest. The old ratio
    /// scale (2× the cheapest = full red) worked in Sweden's tight 50–80 kr
    /// band but painted most of a $1–$10 city red — one $2 dive made every
    /// normal $5 bar look like a ripoff. Anchoring the middle of the
    /// gradient to the median keeps "yellow = typical around here" true at
    /// any spread.
    struct Anchors: Equatable {
        var min: Double
        var median: Double
        var max: Double

        /// Distribution of a comparison set; `own` stands in when empty.
        static func over(_ prices: [Double], own: Double) -> Anchors {
            let ps = prices.isEmpty ? [own] : prices.sorted()
            let mid = ps.count % 2 == 1
                ? ps[ps.count / 2]
                : (ps[ps.count / 2 - 1] + ps[ps.count / 2]) / 2
            return Anchors(min: ps.first!, median: mid, max: ps.last!)
        }

        var rounded: Anchors {
            Anchors(min: min.rounded(), median: median.rounded(), max: max.rounded())
        }
    }

    /// 0 at the local minimum, 0.5 at the median, 1 at the maximum —
    /// piecewise linear so each half of the gradient covers its half of
    /// the distribution regardless of how lopsided the spread is.
    static func t(_ price: Double, anchors a: Anchors) -> Double {
        if price <= a.min { return 0 }
        if price >= a.max { return 1 }
        if price <= a.median {
            let span = a.median - a.min
            return span > 0 ? 0.5 * (price - a.min) / span : 0
        }
        let span = a.max - a.median
        return span > 0 ? 0.5 + 0.5 * (price - a.median) / span : 1
    }
    static func color(_ price: Double, anchors: Anchors) -> Color {
        Color(hue: (1 - t(price, anchors: anchors)) * 0.34, saturation: 0.78, brightness: 0.80)
    }
    /// Colour for a price the user sees ROUNDED. Judging the exact value
    /// while showing the rounded label painted two "$5" pins different
    /// colours whenever their true values differed by cents — the colour
    /// must grade the number on the pin, nothing else.
    static func displayColor(_ price: Double, anchors: Anchors) -> Color {
        color(price.rounded(), anchors: anchors.rounded)
    }
    static func verdict(_ price: Double, anchors: Anchors) -> String {
        let tt = t(price.rounded(), anchors: anchors.rounded)
        if tt <= 0.02 { return "Cheapest around" }
        if tt < 0.35 { return "Cheap for the area" }
        if tt < 0.65 { return "About average" }
        if tt < 0.98 { return "On the pricey side" }
        return "Top of the range"
    }
    /// A neutral "cheap/good" green for comparison callouts.
    static var good: Color { Color(hue: 0.34, saturation: 0.78, brightness: 0.80) }
}

extension BeerCurrency {
    /// ISO country for a coordinate, or nil when geocoding fails. Drives the
    /// region-adaptive default serving (16 oz over the US/Canada).
    static func isoNear(_ coordinate: CLLocationCoordinate2D) async -> String? {
        let geo = CLGeocoder()
        let loc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return try? await geo.reverseGeocodeLocation(loc).first?.isoCountryCode
    }

    /// Resolve the local currency for a coordinate by reverse-geocoding to its
    /// country. Falls back to the device currency on failure.
    static func near(_ coordinate: CLLocationCoordinate2D) async -> String {
        let geo = CLGeocoder()
        let loc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if let iso = try? await geo.reverseGeocodeLocation(loc).first?.isoCountryCode, !iso.isEmpty {
            return forCountry(iso)
        }
        return current
    }
}

/// A bar to price — from a Venue we already know, or a fresh MapKit result.
struct BeerPriceTarget: Identifiable, Equatable {
    let name: String
    let lat: Double
    let lon: Double
    let externalId: String?
    let city: String?
    let address: String?
    var id: String { externalId ?? "\(name)@\(lat),\(lon)" }
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }

    init(venue: Venue) {
        name = venue.name; lat = venue.lat; lon = venue.lon
        externalId = venue.externalId; city = venue.city; address = venue.address
    }
    init(result: MapKitVenueResult) {
        name = result.name; lat = result.lat; lon = result.lon
        externalId = result.id; city = result.city; address = result.address
    }
    var subtitle: String { [address, city].compactMap { $0 }.first ?? "" }
}

// MARK: - Map pin

/// The colour-coded price tag dropped on a bar in price mode (for the selected
/// serving).
struct BeerPricePin: View {
    let price: VenueBeerPrice
    /// Local distribution for this serving — green/yellow/red anchors.
    let anchors: BeerPriceScale.Anchors
    let selected: Bool

    var body: some View {
        Text(price.priceLabel)
            .font(.system(size: selected ? 15 : 13, weight: .black, design: .rounded))
            .foregroundStyle(Color.black.opacity(0.85))
            .padding(.horizontal, selected ? 12 : 9)
            .padding(.vertical, selected ? 6 : 4)
            .background(Capsule().fill(BeerPriceScale.displayColor(price.price, anchors: anchors)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.65), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.45), radius: selected ? 9 : 4, y: 2)
            .scaleEffect(selected ? 1.08 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selected)
    }
}

// MARK: - Tap detail

/// Shown when a bar is tapped in price mode: the selected serving's price, how
/// it compares to nearby bars, the other sizes reported here, and a way to
/// (re)report.
struct BeerPriceDetailCard: View {
    let venue: Venue
    @ObservedObject var venues: VenueService
    let serving: BeerServing
    let onReport: (BeerPriceTarget) -> Void
    let onPickServing: (BeerServing) -> Void

    /// Same-serving, same-currency distribution in this bar's region —
    /// the colour anchors, so a price reads against its own area.
    private func anchors(_ p: VenueBeerPrice) -> BeerPriceScale.Anchors {
        venues.localAnchors(serving: p.serving, currency: p.currency,
                            near: venues.coordinate(for: venue), own: p.price)
    }

    var body: some View {
        let all = venues.servingPrices(for: venue)
        let sel = venues.beerPrice(for: venue, serving: serving)
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(venue.name)
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.cream)
                    if !venue.displayLocation.isEmpty {
                        Text(venue.displayLocation)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.55))
                    }
                    // Only a TRUE flag renders; false and unknown look identical,
                    // so a bar with no data is never labelled as terrace-less.
                    if venue.outdoorSeating == true {
                        Label("Outdoor seating", systemImage: "sun.max.fill")
                            .font(.system(size: 14, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color.whiskey)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(Color.whiskey.opacity(0.14)))
                            .padding(.top, 5)
                    }
                }

                if let p = sel {
                    selectedPrice(p)
                } else {
                    Text("No \(serving.label) price here yet\(all.isEmpty ? " — be the first." : ". Other sizes below.")")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.6))
                }

                if all.count > (sel == nil ? 0 : 1) || (sel == nil && !all.isEmpty) {
                    allSizes(all)
                }

                Button { onReport(BeerPriceTarget(venue: venue)) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill").font(.system(size: 15, weight: .bold, design: .rounded))
                        Text(sel == nil ? "ADD A PRICE" : "UPDATE THE PRICE")
                            .font(.system(size: 13, weight: .bold, design: .monospaced)).tracking(1.2)
                    }
                    .foregroundStyle(Color.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.whiskey))
                }
                .buttonStyle(PressScaleStyle())
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 24)
        }
        .background(Color.ink)
    }

    @ViewBuilder
    private func selectedPrice(_ p: VenueBeerPrice) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(p.priceLabel)
                .font(.system(size: 42, weight: .black, design: .rounded))
                .foregroundStyle(BeerPriceScale.displayColor(p.price, anchors: anchors(p)))
            VStack(alignment: .leading, spacing: 2) {
                Text(p.servingSize.longLabel.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.2).foregroundStyle(Color.bronze)
                Text(BeerPriceScale.verdict(p.price, anchors: anchors(p)))
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.cream)
            }
        }
        HStack(spacing: 8) {
            confidenceChip(p)
            if p.hasSpread {
                chip("\(Int(p.low.rounded()))–\(Int(p.high.rounded())) kr", system: "arrow.left.and.right")
            }
        }
        if let a = venues.localAverage(serving: p.serving, currency: p.currency, near: venues.coordinate(for: venue)),
           abs(p.price - a) >= a * 0.03 {
            let cheaper = p.price < a
            Label("\(BeerCurrency.format(abs(p.price - a), p.currency)) \(cheaper ? "cheaper" : "pricier") than the \(p.servingSize.label) average nearby",
                  systemImage: cheaper ? "arrow.down.right" : "arrow.up.right")
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .foregroundStyle(cheaper ? BeerPriceScale.good : Color.cream.opacity(0.8))
        }
        if let d = p.lastReported {
            Text("Updated \(d.formatted(.relative(presentation: .named)))")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.4))
        }
    }

    @ViewBuilder
    private func allSizes(_ all: [VenueBeerPrice]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("SIZES REPORTED HERE")
            ForEach(all) { sp in
                Button { onPickServing(sp.servingSize) } label: {
                    HStack(spacing: 10) {
                        Circle().fill(BeerPriceScale.displayColor(sp.price, anchors: anchors(sp))).frame(width: 10, height: 10)
                        Text(sp.servingLabel)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.cream)
                        Spacer()
                        Text(sp.priceLabel)
                            .font(.system(size: 14, weight: .heavy, design: .rounded).monospacedDigit())
                            .foregroundStyle(Color.cream)
                        Text("· \(sp.reportCount)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.cream.opacity(0.4))
                    }
                    .padding(.vertical, 9).padding(.horizontal, 12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(sp.serving == serving.rawValue ? Color.whiskey.opacity(0.14) : Color.cream.opacity(0.04)))
                }
                .buttonStyle(PressScaleStyle())
            }
        }
    }

    private func confidenceChip(_ p: VenueBeerPrice) -> some View {
        let confirmed = p.reportCount >= 3
        return chip(confirmed ? p.reportsLabel : "Unconfirmed · \(p.reportsLabel)",
                    system: confirmed ? "checkmark.seal.fill" : "questionmark.circle",
                    tint: confirmed ? Color.whiskey : Color.bronze)
    }
    private func chip(_ text: String, system: String, tint: Color = .bronze) -> some View {
        HStack(spacing: 4) {
            Image(systemName: system).font(.system(size: 9, weight: .bold, design: .rounded))
            Text(text).font(.system(size: 10, weight: .bold, design: .monospaced))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(0.14)))
    }
}

// MARK: - Submit

/// Report a price: pick the bar (pre-filled or searched, with a confirm map),
/// the serving size, and the price.
struct BeerPriceSubmitSheet: View {
    @ObservedObject var venues: VenueService
    @ObservedObject var location: LocationService
    let preset: BeerPriceTarget?
    let initialServing: BeerServing
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    @StateObject private var search = MapKitVenueSearch()
    @State private var query = ""
    @State private var target: BeerPriceTarget?
    @State private var serving: BeerServing
    @State private var priceText = ""
    /// Currency for the submission — resolved from the chosen bar's country.
    @State private var currencyCode: String = BeerCurrency.current
    @State private var saving = false
    @State private var error: String?

    init(venues: VenueService, location: LocationService, preset: BeerPriceTarget?,
         initialServing: BeerServing, onDone: @escaping () -> Void) {
        self.venues = venues; self.location = location
        self.preset = preset; self.initialServing = initialServing; self.onDone = onDone
        _target = State(initialValue: preset)
        _serving = State(initialValue: initialServing)
    }

    private var price: Double? { Double(priceText.replacingOccurrences(of: ",", with: ".")) }
    private var canSave: Bool {
        guard target != nil, let p = price else { return false }
        return p > 0 && !saving   // the server enforces the per-currency band
    }

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if let t = target { chosenBar(t) } else { barPicker }
                    if target != nil {
                        servingPicker
                        priceEntry
                    }
                    if let e = error {
                        Label(e, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.red.opacity(0.9))
                    }
                    saveButton
                }
                .padding(20)
            }
        }
        .preferredColorScheme(.dark)
        .task { location.requestAccess() }
        .task(id: query) {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, target == nil else { return }
            search.search(query: query, origin: location.location)
        }
        // Currency follows the BAR's country — a Tokyo bar is priced in yen.
        .task(id: target?.id) {
            if let t = target { currencyCode = await BeerCurrency.near(t.coordinate) }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add a beer price")
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.cream)
                Text("What a beer costs — help the map stay honest.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.55))
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.6))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.cream.opacity(0.06)))
            }
            .buttonStyle(PressScaleStyle())
        }
    }

    private var barPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("WHICH BAR")
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.4))
                TextField("", text: $query, prompt: Text("Search a bar").foregroundStyle(Color.cream.opacity(0.4)))
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.cream.opacity(0.05)))

            ForEach(search.results) { r in
                Button { target = BeerPriceTarget(result: r); query = "" } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.name).font(.system(size: 15, weight: .heavy, design: .rounded)).foregroundStyle(Color.cream)
                        let sub = [r.address, r.city].compactMap { $0 }.first ?? ""
                        if !sub.isEmpty {
                            Text(sub).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(Color.cream.opacity(0.5))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.cream.opacity(0.04)))
                }
                .buttonStyle(PressScaleStyle())
            }
        }
    }

    private func chosenBar(_ t: BeerPriceTarget) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("BAR")
            // Confirm map — make sure it's the right place.
            Map(initialPosition: .region(MKCoordinateRegion(
                center: t.coordinate, latitudinalMeters: 400, longitudinalMeters: 400)),
                interactionModes: []) {
                Marker(t.name, coordinate: t.coordinate).tint(.orange)
            }
            .frame(height: 130)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .allowsHitTesting(false)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.name).font(.system(size: 16, weight: .heavy, design: .rounded)).foregroundStyle(Color.cream)
                    if !t.subtitle.isEmpty {
                        Text(t.subtitle).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(Color.cream.opacity(0.5))
                    }
                }
                Spacer()
                if preset == nil {
                    Button("Change") { target = nil }
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.whiskey)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.whiskey.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.whiskey.opacity(0.4), lineWidth: 1))
        }
    }

    private var servingPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("SERVING SIZE")
            HStack(spacing: 6) {
                ForEach(BeerServing.allCases) { s in
                    let on = serving == s
                    Button { serving = s } label: {
                        Text(s.label)
                            .font(.system(size: 12, weight: .black, design: .rounded))
                            .foregroundStyle(on ? Color.ink : Color.cream.opacity(0.7))
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(Capsule().fill(on ? Color.whiskey : Color.cream.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Every ISO currency, common ones first — so a user anywhere can pick the
    /// right one if auto-detection is off.
    private var currencyOptions: [String] {
        let common = ["SEK","NOK","DKK","EUR","GBP","USD","JPY","CHF","AUD","CAD","PLN","CZK"]
        let all = Locale.commonISOCurrencyCodes.sorted()
        return common + all.filter { !common.contains($0) }
    }

    private var priceEntry: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel("PRICE")
                Spacer()
                // Auto-detected from the bar's country; tap to override to any
                // currency (e.g. when the location couldn't be resolved).
                Menu {
                    ForEach(currencyOptions, id: \.self) { code in
                        Button { currencyCode = code } label: { Text("\(code)  \(BeerCurrency.symbol(code))") }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(currencyCode).font(.system(size: 11, weight: .heavy, design: .rounded))
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(Color.whiskey)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Color.whiskey.opacity(0.14)))
                }
            }
            HStack(spacing: 8) {
                TextField("", text: $priceText, prompt: Text("e.g. 65").foregroundStyle(Color.cream.opacity(0.35)))
                    .keyboardType(.decimalPad)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.cream)
                Text(BeerCurrency.symbol(currencyCode))
                    .font(.system(size: 15, weight: .bold, design: .monospaced)).foregroundStyle(Color.cream.opacity(0.5))
            }
            .padding(.horizontal, 14).padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.cream.opacity(0.05)))
        }
    }

    private var saveButton: some View {
        Button(action: submit) {
            HStack(spacing: 8) {
                if saving { ProgressView().tint(Color.ink) }
                Text(saving ? "ADDING…" : "ADD PRICE")
                    .font(.system(size: 14, weight: .bold, design: .monospaced)).tracking(1.4)
            }
            .foregroundStyle(Color.ink)
            .frame(maxWidth: .infinity).padding(.vertical, 15)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(canSave ? Color.whiskey : Color.cream.opacity(0.15)))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!canSave)
    }

    private func submit() {
        guard let t = target, let p = price else { return }
        saving = true; error = nil
        Task {
            let ok = await venues.submitBeerPrice(
                name: t.name, lat: t.lat, lon: t.lon,
                externalId: t.externalId, city: t.city, address: t.address,
                price: p, serving: serving, currency: currencyCode, note: nil)
            saving = false
            if ok { onDone(); dismiss() }
            else { error = "Couldn't save — check the price looks right and try again." }
        }
    }
}

// MARK: - Search / cheapest list

/// Searchable, price-sorted list of bars for a serving — "cheapest beer near
/// me" and "find a specific bar" in one. Tapping a row flies the map to it.
struct BeerPriceListSheet: View {
    @ObservedObject var venues: VenueService
    @ObservedObject var location: LocationService
    /// nil = "All": each bar's cheapest pour of any size.
    let serving: BeerServing?
    /// Browse-mode reference when there is no GPS fix — the map's viewport
    /// centre. Without it the list used to fail open to the whole planet.
    var fallbackOrigin: CLLocationCoordinate2D? = nil
    /// The map's viewport. The browse list is scoped to what the map shows:
    /// zoomed to a city → that city's bars, cheapest first; zoomed out to a
    /// whole country (the picker's "Entire country") → the whole catalog.
    /// nil keeps the old near-you radius.
    var viewport: MKCoordinateRegion? = nil
    let onSelect: (Venue) -> Void
    @State private var query = ""
    /// Reverse-geocoded name of the viewed city, stamped into the kicker.
    @State private var placeName: String?
    /// Apple Maps alongside the catalog, unbiased, so "Atlas Bar Singapore"
    /// jumps continents. Only consulted while the user is typing a query.
    @StateObject private var world = MapKitVenueSearch()
    @State private var resolving = false

    /// A viewport wider than ~2° of longitude is a country view, not a city.
    private var isCountryScope: Bool {
        (viewport?.span.longitudeDelta ?? 0) > 2.0
    }

    /// "CHEAPEST 40 CL · PARIS" — the list always names its own scope.
    private var kicker: String {
        let what = serving.map { "CHEAPEST \($0.label.uppercased())" }
            ?? "CHEAPEST POUR, ANY SIZE"
        guard query.trimmingCharacters(in: .whitespaces).isEmpty else { return what }
        if isCountryScope,
           let name = Locale.current.localizedString(forRegionCode: venues.activeCountry) {
            return "\(what) · \(name.uppercased())"
        }
        if let name = placeName ?? majorityCity { return "\(what) · \(name.uppercased())" }
        return what
    }

    /// The bars themselves know what city they're in — the most common city
    /// among the listed rows names the list without a network geocode (which
    /// is what `placeName` falls back to when city fields are empty).
    private var majorityCity: String? {
        var counts: [String: Int] = [:]
        for r in rows.prefix(40) {
            // City fields sometimes carry ", Country" — keep the city part.
            if let c = r.venue.city?.components(separatedBy: ",").first?
                .trimmingCharacters(in: .whitespaces), !c.isEmpty {
                counts[c, default: 0] += 1
            }
        }
        return counts.max { $0.value < $1.value }?.key
    }

    private var rows: [(venue: Venue, price: VenueBeerPrice)] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let here = location.location
            ?? fallbackOrigin.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        let pool = serving.map { venues.venuesWithDisplayablePrice(serving: $0) }
            ?? venues.venuesWithAnyBeerPrice
        return pool
            // The BROWSE list is bars near you (or, with no fix yet, near what
            // the map shows); a typed SEARCH reaches the whole catalog —
            // "Bar Etzy" should find Gothenburg from Stockholm, and "…Berlin"
            // should find Berlin (the worldwide section below covers bars we
            // hold no price for yet).
            .filter { v in
                guard q.isEmpty else { return true }   // typed search: whole catalog
                if let vp = viewport {
                    // Country view: whole (country-scoped) catalog qualifies.
                    if vp.span.longitudeDelta > 2.0 { return true }
                    // City view: what the map shows, with a little margin.
                    return abs(v.lat - vp.center.latitude) <= vp.span.latitudeDelta * 0.65
                        && abs(v.lon - vp.center.longitude) <= vp.span.longitudeDelta * 0.65
                }
                guard let here else { return true }
                let d = CLLocation(latitude: v.lat, longitude: v.lon).distance(from: here)
                return d <= VenueService.dealsRadiusMeters
            }
            .compactMap { v -> (Venue, VenueBeerPrice)? in
                let price = serving.map { venues.displayBeerPrice(for: v, serving: $0) }
                    ?? venues.cheapestAnyPrice(for: v)
                return price.map { (v, $0) }
            }
            .filter { q.isEmpty || $0.venue.name.lowercased().contains(q)
                         || $0.venue.displayLocation.lowercased().contains(q) }
            .sorted { $0.price.price < $1.price.price }
    }

    var body: some View {
        // Top 100 is plenty for browsing and keeps a whole-country list
        // (UK: 700+ bars) from rendering in one non-lazy stack.
        let list = Array(rows.prefix(100))
        let anchors = BeerPriceScale.Anchors.over(list.map(\.price.price), own: 0)
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                Text(kicker)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(2.4).foregroundStyle(Color.bronze)

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.4))
                    TextField("", text: $query,
                              prompt: Text("Search a bar — add a country to look abroad")
                                  .foregroundStyle(Color.cream.opacity(0.4)))
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream)
                        .autocorrectionDisabled()
                        .onChange(of: query) { _, _ in
                            world.search(query: query, origin: location.location,
                                         biasToOrigin: false)
                        }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.cream.opacity(0.05)))

                // Don't declare "no bars match" while the worldwide search is
                // about to answer right underneath.
                if list.isEmpty && !(!query.isEmpty && (world.isSearching || !world.results.isEmpty)) {
                    Text(query.isEmpty ? "No \(serving?.label ?? "beer") prices yet — add the first."
                                       : "No bars match “\(query)”.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.5))
                        .padding(.vertical, 20)
                }
                ForEach(list, id: \.venue.id) { entry in
                    Button { onSelect(entry.venue) } label: { row(entry.venue, entry.price, anchors) }
                        .buttonStyle(PressScaleStyle())
                }

                // Bars we hold no price for, from Apple Maps — pick one and the
                // map flies there; its card is where the first price gets added.
                let knownNames = Set(list.map(\.venue.name))
                let abroad = world.results.filter { !knownNames.contains($0.name) }
                if !query.isEmpty && !abroad.isEmpty {
                    Text("ANYWHERE ON EARTH · NO PRICE YET")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(Color.bronze)
                        .padding(.top, 10)
                    ForEach(abroad) { r in
                        Button {
                            guard !resolving else { return }
                            resolving = true
                            Task {
                                let v = await venues.resolveOrCreateMapKitVenue(r)
                                await MainActor.run {
                                    resolving = false
                                    if let v { onSelect(v) }
                                }
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "globe.europe.africa.fill")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(Color.cream.opacity(0.5))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.name)
                                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                                        .foregroundStyle(Color.cream).lineLimit(1)
                                    let place = [r.address, r.city].compactMap { $0 }
                                        .joined(separator: ", ")
                                    if !place.isEmpty {
                                        Text(place)
                                            .font(.system(size: 11, weight: .medium, design: .rounded))
                                            .foregroundStyle(Color.cream.opacity(0.45)).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 4)
                                if resolving {
                                    ProgressView().tint(Color.whiskey)
                                } else {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                        .foregroundStyle(Color.cream.opacity(0.35))
                                }
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.cream.opacity(0.04)))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Color.cream.opacity(0.08), lineWidth: 1))
                        }
                        .buttonStyle(PressScaleStyle())
                        .disabled(resolving)
                    }
                }
            }
            .padding(20)
        }
        .background(Color.ink)
        .preferredColorScheme(.dark)
        .task {
            guard !isCountryScope, let c = viewport?.center else { return }
            let loc = CLLocation(latitude: c.latitude, longitude: c.longitude)
            if let mark = try? await CLGeocoder().reverseGeocodeLocation(loc).first {
                placeName = mark.locality ?? mark.subAdministrativeArea ?? mark.administrativeArea
            }
        }
        .onDisappear { world.clear() }
    }

    private func row(_ v: Venue, _ p: VenueBeerPrice, _ anchors: BeerPriceScale.Anchors) -> some View {
        HStack(spacing: 12) {
            Text(p.priceLabel)
                .font(.system(size: 14, weight: .black, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.black.opacity(0.85))
                .frame(minWidth: 56)
                .padding(.horizontal, 8).padding(.vertical, 7)
                .background(Capsule().fill(BeerPriceScale.displayColor(p.price, anchors: anchors)))
            VStack(alignment: .leading, spacing: 2) {
                Text(v.name).font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.cream).lineLimit(1)
                if !v.displayLocation.isEmpty {
                    Text(v.displayLocation).font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.45)).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let d = venues.distance(from: location.location, to: v) {
                Text(d < 1000 ? "\(Int(d)) m" : String(format: "%.1f km", d / 1000))
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundStyle(Color.cream.opacity(0.5))
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
