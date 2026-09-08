// Search any bar. If it is on Sejdel, open its profile and follow it. If it
// isn't, ask for it — and the owner sees which bars are wanted and how badly,
// which is the pitch to those bars. Migration 126.

import SwiftUI
import MapKit
import CoreLocation
import Combine
import Supabase

// MARK: - Requests ("I want this bar on Sejdel")

@MainActor
final class VenueRequestStore: ObservableObject {
    static let shared = VenueRequestStore()
    /// Venues this user has asked for.
    @Published private(set) var mine: Set<UUID> = []
    /// How many people asked, per venue we have looked at.
    @Published private(set) var counts: [UUID: Int] = [:]
    private var loadedMine = false

    func loadMine() async {
        guard !loadedMine else { return }
        // Decoded as strings first: a uuid[] over PostgREST did not decode
        // straight into [UUID], and a silently empty set showed "1 ASKED"
        // where it should have said "you asked".
        if let raw: [String] = try? await supabase.rpc("venue_requests_mine").execute().value {
            mine = Set(raw.compactMap(UUID.init(uuidString:))); loadedMine = true
        }
    }

    func loadCounts(_ ids: [UUID]) async {
        let missing = ids.filter { counts[$0] == nil }
        guard !missing.isEmpty else { return }
        struct P: Encodable { let p_venues: [String] }
        if let m: [String: Int] = try? await supabase.rpc("venue_request_counts",
            params: P(p_venues: missing.map { $0.uuidString.lowercased() })).execute().value {
            for id in missing { counts[id] = m[id.uuidString.lowercased()] ?? m[id.uuidString] ?? 0 }
        }
    }

    func set(_ venue: UUID, on: Bool) async throws {
        struct P: Encodable { let p_venue: String; let p_on: Bool }
        let n: Int = try await supabase.rpc("venue_request_set",
            params: P(p_venue: venue.uuidString.lowercased(), p_on: on)).execute().value
        if on { mine.insert(venue) } else { mine.remove(venue) }
        counts[venue] = n
    }

    /// The owner's view: every bar anyone asked for, most wanted first.
    struct Wanted: Decodable, Identifiable {
        let venueId: UUID
        let name: String
        let city: String?
        let country: String?
        let address: String?
        let asks: Int
        let lastAt: String?
        let onSejdel: Bool
        var id: UUID { venueId }
        enum CodingKeys: String, CodingKey {
            case name, city, country, address, asks
            case venueId = "venue_id"
            case lastAt = "last_at"
            case onSejdel = "on_sejdel"
        }
    }

    func adminList() async throws -> [Wanted] {
        try await supabase.rpc("admin_venue_requests").execute().value
    }

    static func friendly(_ error: Error) -> String {
        let s = String(describing: error)
        if s.contains("already_on_sejdel") { return "This bar is already on Sejdel." }
        if s.contains("no_venue") || s.contains("noVenue") { return "Couldn't place that bar. Try again." }
        return "Couldn't do that. Try again."
    }
}

/// Raised when Apple's result could not be turned into one of our venues.
enum BarSearchError: Error { case noVenue }

// MARK: - A bar in the results, wherever it came from

/// One row: a bar we know (with or without an account) or one Apple Maps
/// knows. Both render the same; only what you can do with it differs.
struct BarHit: Identifiable, Equatable {
    let id: String
    let name: String
    let address: String?
    let city: String?
    let coordinate: CLLocationCoordinate2D
    let distance: CLLocationDistance?
    /// Our row, when we have one — needed to ask for the bar or count asks.
    var venue: Venue?
    /// Apple's result, when that's where it came from.
    var mapkit: MapKitVenueResult?
    /// The account behind it, when the bar is on Sejdel.
    var business: BusinessPublicProfile?

    var onSejdel: Bool { business != nil }
    var subtitle: String {
        var parts: [String] = []
        if let a = address, !a.isEmpty { parts.append(a) } else if let c = city, !c.isEmpty { parts.append(c) }
        if let d = distance {
            parts.append(d < 950 ? "\(Int(d.rounded(.up) / 50) * 50) m" : String(format: "%.1f km", d / 1000))
        }
        return parts.joined(separator: " · ")
    }
    static func == (a: BarHit, b: BarHit) -> Bool { a.id == b.id }
}

// MARK: - The search

/// The BARS side of the search sheet: type a name, see the matches on a map,
/// tap one to follow it or ask for it.
struct BarSearchView: View {
    @ObservedObject var venues: VenueService
    var origin: CLLocation?
    @StateObject private var search = MapKitVenueSearch()
    @ObservedObject private var requests = VenueRequestStore.shared
    @State private var query = ""
    @State private var camera: MapCameraPosition = .automatic
    @State private var selected: BarHit?

    /// Bars on Sejdel whose name matches come first, then Apple's results
    /// that aren't already one of ours.
    private var hits: [BarHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        var out: [BarHit] = []
        var seen: Set<UUID> = []
        for v in venues.venues where v.name.lowercased().contains(q) {
            guard let b = venues.business(for: v) else { continue }
            seen.insert(v.id)
            out.append(BarHit(id: v.id.uuidString, name: v.name, address: v.address, city: v.city,
                              coordinate: CLLocationCoordinate2D(latitude: v.lat, longitude: v.lon),
                              distance: origin.map { $0.distance(from: CLLocation(latitude: v.lat, longitude: v.lon)) },
                              venue: v, mapkit: nil, business: b))
        }
        for r in search.results {
            let known = venues.venues.first { $0.mapkitId == r.id || ($0.externalId == r.id && $0.source == .mapkit) }
            if let k = known, seen.contains(k.id) { continue }
            if let k = known { seen.insert(k.id) }
            out.append(BarHit(id: r.id, name: r.name, address: r.address, city: r.city,
                              coordinate: r.coordinate, distance: r.distance,
                              venue: known, mapkit: r, business: known.flatMap { venues.business(for: $0) }))
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LoungeField(label: "BAR", text: $query, placeholder: "search for a bar", autocapitalize: true)

            if !hits.isEmpty {
                // The map is how you tell two bars with the same name apart.
                Map(position: $camera) {
                    ForEach(hits) { h in
                        Marker(h.name, systemImage: h.onSejdel ? "checkmark.seal.fill" : "wineglass.fill", coordinate: h.coordinate)
                            .tint(h.onSejdel ? Color.whiskey : Color.bronze)
                    }
                }
                .mapStyle(.standard(pointsOfInterest: .excludingAll))
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.cream.opacity(0.1), lineWidth: 1))

                VStack(spacing: 8) {
                    ForEach(hits) { h in
                        Button { selected = h; focus(h) } label: { row(h) }
                            .buttonStyle(PressScaleStyle())
                    }
                }
            } else if search.isSearching {
                ProgressView().tint(Color.whiskey).frame(maxWidth: .infinity).padding(.top, 20)
            } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("No bar by that name nearby. Try the full name, or the street.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.55))
            } else {
                Text("Any bar, on Sejdel or not. Follow the ones that are here, ask for the ones that aren't.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await requests.loadMine() }
        .task(id: query) {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            search.search(query: query, origin: origin)
        }
        .onChange(of: hits) { _, h in
            withAnimation(.easeInOut(duration: 0.35)) { camera = .region(Self.fit(h)) }
            Task { await requests.loadCounts(h.compactMap { $0.venue?.id }) }
        }
        // Full height on purpose: a half sheet would leave this map peeking
        // out above the detail's own map.
        .sheet(item: $selected) { h in
            BarDetailSheet(hit: h, venues: venues)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.ink)
        }
    }

    /// Everything on screen, but never tighter than a neighbourhood — a lone
    /// result zoomed to its doorstep tells you nothing about where it is.
    static func fit(_ hits: [BarHit]) -> MKCoordinateRegion {
        guard let first = hits.first else { return MKCoordinateRegion(.world) }
        var minLat = first.coordinate.latitude, maxLat = minLat
        var minLon = first.coordinate.longitude, maxLon = minLon
        for h in hits {
            minLat = min(minLat, h.coordinate.latitude); maxLat = max(maxLat, h.coordinate.latitude)
            minLon = min(minLon, h.coordinate.longitude); maxLon = max(maxLon, h.coordinate.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let minSpan = 0.022   // ≈ 2.4 km north–south
        let span = MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.6, minSpan),
                                    longitudeDelta: max((maxLon - minLon) * 1.6, minSpan * 1.3))
        return MKCoordinateRegion(center: center, span: span)
    }

    private func focus(_ h: BarHit) {
        withAnimation(.easeInOut(duration: 0.4)) {
            camera = .region(MKCoordinateRegion(center: h.coordinate, latitudinalMeters: 1800, longitudinalMeters: 1800))
        }
    }

    private func row(_ h: BarHit) -> some View {
        HStack(spacing: 12) {
            Image(systemName: h.onSejdel ? "checkmark.seal.fill" : "wineglass")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(h.onSejdel ? Color.whiskey : Color.bronze)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(h.name)
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .lineLimit(1)
                Text(h.subtitle)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if h.onSejdel {
                pill("ON SEJDEL", Color.whiskey)
            } else if let v = h.venue, let n = requests.counts[v.id], n > 0 {
                pill(requests.mine.contains(v.id) ? "YOU +\(max(n - 1, 0)) ASKED" : "\(n) ASKED", Color.bronze)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.bronze)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cream.opacity(0.04)))
    }

    private func pill(_ t: String, _ c: Color) -> some View {
        Text(t)
            .font(.system(size: 9, weight: .black, design: .monospaced)).tracking(1)
            .foregroundStyle(c)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Capsule().fill(c.opacity(0.12)))
    }
}

// MARK: - One bar

/// The bar, on its own map, and the one thing you can do about it.
struct BarDetailSheet: View {
    let hit: BarHit
    @ObservedObject var venues: VenueService
    @ObservedObject private var requests = VenueRequestStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var camera: MapCameraPosition
    @State private var venue: Venue?
    @State private var busy = false
    @State private var error: String?
    @State private var profileOpen: BizRef?

    init(hit: BarHit, venues: VenueService) {
        self.hit = hit; self.venues = venues
        _venue = State(initialValue: hit.venue)
        // Wide enough to place the bar in its part of town, not just its block.
        _camera = State(initialValue: .region(MKCoordinateRegion(center: hit.coordinate, latitudinalMeters: 2200, longitudinalMeters: 2200)))
    }

    private var asked: Bool { venue.map { requests.mine.contains($0.id) } ?? false }
    private var asks: Int { venue.flatMap { requests.counts[$0.id] } ?? 0 }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.ink.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    Map(position: $camera) {
                        Marker(hit.name, systemImage: hit.onSejdel ? "checkmark.seal.fill" : "wineglass.fill", coordinate: hit.coordinate)
                            .tint(hit.onSejdel ? Color.whiskey : Color.bronze)
                    }
                    .mapStyle(.standard(pointsOfInterest: .excludingAll))
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .allowsHitTesting(false)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(hit.name)
                                .font(.system(size: 26, weight: .black, design: .rounded))
                                .foregroundStyle(Color.cream)
                            if hit.onSejdel { VerifiedBadge(size: 18) }
                        }
                        Text([hit.address, hit.city].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.6))
                    }

                    if let b = hit.business {
                        Text("On Sejdel. Follow it and its posts, deals and nights land in your feed.")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                        BizPrimaryButton(title: "OPEN \(hit.name.uppercased())") { profileOpen = BizRef(id: b.id) }
                    } else {
                        Text(asks == 0
                             ? "Not on Sejdel yet. Ask for it — every ask is one more reason for them to join."
                             : "Not on Sejdel yet. \(asks == 1 ? "One person has" : "\(asks) people have") asked for it.")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                        ErrorLine(text: error)
                        if asked {
                            BizSecondaryButton(title: "YOU ASKED · TAP TO TAKE IT BACK", icon: "hand.raised.fill") { toggle(false) }
                        } else {
                            BizPrimaryButton(title: "I WANT THIS BAR ON SEJDEL", busy: busy) { toggle(true) }
                        }
                    }
                    Spacer(minLength: 12)
                }
                .padding(20)
                .padding(.top, 8)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.85))
                    .padding(12).background(Circle().fill(Color.ink.opacity(0.7)))
            }
            .padding(.top, 28).padding(.trailing, 28)
            .buttonStyle(PressScaleStyle())
        }
        .preferredColorScheme(.dark)
        .task { if let v = venue { await requests.loadCounts([v.id]) } }
        .sheet(item: $profileOpen) { ref in
            BusinessProfileView(businessId: ref.id)
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.ink)
        }
    }

    private func toggle(_ on: Bool) {
        busy = true; error = nil
        Task {
            do {
                // A bar Apple knows but we don't becomes one of ours the first
                // time someone asks for it.
                if venue == nil, let r = hit.mapkit { venue = await venues.resolveOrCreateMapKitVenue(r) }
                guard let v = venue else { throw BarSearchError.noVenue }
                try await requests.set(v.id, on: on)
            } catch {
                self.error = VenueRequestStore.friendly(error)
            }
            busy = false
        }
    }
}

// MARK: - Owner side: which bars people want

/// Business desk → Wanted. The pitch, in numbers — grouped by city so a trip
/// to one town has its list ready, and filterable by name, city or country.
struct WantedBarsSection: View {
    @State private var rows: [VenueRequestStore.Wanted] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var filter = ""

    private struct Group: Identifiable {
        let id: String
        let city: String
        let country: String
        let rows: [VenueRequestStore.Wanted]
        var asks: Int { rows.reduce(0) { $0 + $1.asks } }
    }

    private var filtered: [VenueRequestStore.Wanted] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter {
            $0.name.lowercased().contains(q)
                || ($0.city ?? "").lowercased().contains(q)
                || ($0.country ?? "").lowercased().contains(q)
        }
    }

    /// One block per city, most-wanted city first.
    private var groups: [Group] {
        var byKey: [String: [VenueRequestStore.Wanted]] = [:]
        for r in filtered {
            let key = "\(r.country ?? "")|\(r.city ?? "")"
            byKey[key, default: []].append(r)
        }
        return byKey.map { key, rs in
            let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            return Group(id: key, city: parts.count > 1 && !parts[1].isEmpty ? parts[1] : "Unknown city",
                         country: parts.first ?? "", rows: rs.sorted { $0.asks > $1.asks })
        }
        .sorted { $0.asks == $1.asks ? $0.city < $1.city : $0.asks > $1.asks }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            kicker("BARS PEOPLE ASKED FOR")
            Text("Every tap on “I want this bar on Sejdel”, by bar. Take the number to the bar: this many of their guests asked for them.")
                .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Color.cream.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            if !rows.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.bronze)
                    TextField("", text: $filter, prompt: Text("Bar, city or country").foregroundStyle(Color.cream.opacity(0.35)))
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream)
                        .tint(Color.whiskey)
                        .autocorrectionDisabled()
                    if !filter.isEmpty {
                        Button { filter = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Color.cream.opacity(0.4))
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cream.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.cream.opacity(0.1), lineWidth: 1))
            }
            if !loaded {
                ProgressView().tint(Color.whiskey).frame(maxWidth: .infinity).padding(.vertical, 20)
            } else if rows.isEmpty {
                Text("Nobody has asked for a bar yet.")
                    .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(Color.cream.opacity(0.5))
            } else if groups.isEmpty {
                Text("Nothing matches “\(filter)”.")
                    .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(Color.cream.opacity(0.5))
            } else {
                ForEach(groups) { g in
                    HStack(alignment: .firstTextBaseline) {
                        Text([g.city, g.country].filter { !$0.isEmpty }.joined(separator: " · ").uppercased())
                            .font(.system(size: 10, weight: .black, design: .monospaced)).tracking(1.6)
                            .foregroundStyle(Color.bronze)
                        Spacer()
                        Text("\(g.rows.count) \(g.rows.count == 1 ? "BAR" : "BARS") · \(g.asks) \(g.asks == 1 ? "ASK" : "ASKS")")
                            .font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1)
                            .foregroundStyle(Color.cream.opacity(0.45))
                    }
                    .padding(.top, 6)
                    ForEach(g.rows) { w in wantedRow(w) }
                }
            }
            ErrorLine(text: error)
        }
        .task {
            do { rows = try await VenueRequestStore.shared.adminList() } catch { self.error = "Couldn't load." }
            loaded = true
        }
    }

    private func wantedRow(_ w: VenueRequestStore.Wanted) -> some View {
        BizCard {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(w.name).font(.system(size: 16, weight: .heavy, design: .rounded)).foregroundStyle(Color.cream)
                    if let a = w.address, !a.isEmpty {
                        Text(a).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(Color.cream.opacity(0.5))
                    }
                    if let l = w.lastAt {
                        Text("last ask \(RelativeTime.short(l))")
                            .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Color.bronze)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(w.asks)").font(.system(size: 26, weight: .black, design: .rounded)).foregroundStyle(Color.whiskey)
                    Text(w.asks == 1 ? "ASK" : "ASKS").font(.system(size: 9, weight: .black, design: .monospaced)).tracking(1.2).foregroundStyle(Color.bronze)
                    if w.onSejdel {
                        Text("ON SEJDEL").font(.system(size: 8, weight: .black, design: .monospaced)).tracking(1).foregroundStyle(Color.whiskey.opacity(0.7))
                    }
                }
            }
        }
    }
}
