//
//  ShareCard.swift
//  sesh.app
//
//  Strava-style share for a night recap: SIX swipeable variants —
//  transparent ghost-map sticker, photo card, full map card, sejdel
//  branded card, and two extra transparent stickers (route-only and
//  big-stats). Shared via Instagram (clipboard-paste flow, the only way
//  Instagram keeps transparency), copy-to-clipboard, save to Photos, or
//  the system share sheet (Snapchat / WhatsApp / Messages / …).
//
//  Every transparent element carries a dark halo so it reads on light
//  AND dark story backgrounds.
//

import SwiftUI
import UIKit
import MapKit
import UniformTypeIdentifiers

// MARK: - Variants

enum ShareCardStyle: String, CaseIterable, Identifiable {
    case transparent   // ghost street map + stats (the classic sticker)
    case photo         // your night photo as the card
    case map           // full opaque map card
    case branded       // opaque sejdel-design card
    case route         // transparent, route only
    case stats         // transparent, big numbers only

    var id: String { rawValue }

    var label: String {
        switch self {
        case .transparent: return "TRANSPARENT"
        case .photo:       return "PHOTO"
        case .map:         return "MAP"
        case .branded:     return "SEJDEL"
        case .route:       return "ROUTE"
        case .stats:       return "STATS"
        }
    }

    /// Opaque cards flatten fine anywhere; transparent ones need the
    /// clipboard-paste flow to survive Instagram.
    var isTransparent: Bool {
        switch self {
        case .photo, .map, .branded: return false
        case .transparent, .route, .stats: return true
        }
    }
}

// MARK: - Ghost map snapshot

/// A dark map snapshot of the night's area plus each stop's EXACT pixel
/// position on it (converted by the snapshotter, so dots sit on the right
/// streets).
struct RouteMapSnapshot {
    let image: UIImage
    let points: [CGPoint]
    /// The actual WALKING route between the stops (Apple Maps directions),
    /// already projected into snapshot space — so the line follows streets
    /// instead of cutting straight through buildings. Falls back to the
    /// straight segment for any leg directions can't solve.
    let path: [CGPoint]
    let size: CGSize

    /// Ghost-strip size used inside the transparent sticker.
    static let ghostSize = CGSize(width: 308, height: 240)
    /// Full-card size used by the opaque MAP variant.
    static let cardSize = CGSize(width: 360, height: 560)

    static func load(for stops: [RecapStop], size: CGSize) async -> RouteMapSnapshot? {
        let coords: [CLLocationCoordinate2D] = stops.compactMap { s in
            guard let la = s.lat, let lo = s.lon else { return nil }
            return CLLocationCoordinate2D(latitude: la, longitude: lo)
        }
        guard !coords.isEmpty else { return nil }

        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        let midLat = (lats.min()! + lats.max()!) / 2
        let midLon = (lons.min()! + lons.max()!) / 2
        // 60% padding around the crawl; floor keeps one-stop nights at
        // neighbourhood zoom instead of a blank block.
        let spanLat = max((lats.max()! - lats.min()!) * 1.6, 0.008)
        let spanLon = max((lons.max()! - lons.min()!) * 1.6, 0.008)

        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: midLat, longitude: midLon),
            span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLon)
        )
        options.size = size
        options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)
        options.pointOfInterestFilter = .excludingAll
        options.showsBuildings = false

        let snap: MKMapSnapshotter.Snapshot? = await withCheckedContinuation { cont in
            MKMapSnapshotter(options: options).start { s, _ in cont.resume(returning: s) }
        }
        guard let snap else { return nil }

        // The crawl as actually walked: Apple Maps walking directions for
        // each leg, stitched together. Any failed leg degrades to its
        // straight segment.
        var path: [CGPoint] = []
        if coords.count > 1 {
            for i in 0..<(coords.count - 1) {
                let legCoords = await walkingLeg(from: coords[i], to: coords[i + 1])
                path.append(contentsOf: legCoords.map { snap.point(for: $0) })
            }
        }

        return RouteMapSnapshot(image: snap.image,
                                points: coords.map { snap.point(for: $0) },
                                path: path,
                                size: size)
    }

    /// One walking leg's coordinates — the routed polyline, or just the
    /// two endpoints when directions fail (offline, unroutable, …).
    private static func walkingLeg(
        from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D
    ) async -> [CLLocationCoordinate2D] {
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: a))
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: b))
        req.transportType = .walking
        let route: MKRoute? = await withCheckedContinuation { cont in
            MKDirections(request: req).calculate { resp, _ in
                cont.resume(returning: resp?.routes.first)
            }
        }
        guard let route else { return [a, b] }
        let poly = route.polyline
        var buf = [CLLocationCoordinate2D](
            repeating: kCLLocationCoordinate2DInvalid, count: poly.pointCount
        )
        poly.getCoordinates(&buf, range: NSRange(location: 0, length: poly.pointCount))
        // Pin the leg to the exact bar dots at both ends.
        return [a] + buf + [b]
    }
}

// MARK: - Assets (loaded once, shared by every variant)

struct ShareAssets {
    var vitals: HealthService.Vitals? = nil
    var ghostMap: RouteMapSnapshot? = nil
    var cardMap: RouteMapSnapshot? = nil
    var photo: UIImage? = nil

    static func load(for recap: NightRecap) async -> ShareAssets {
        async let v = HealthService.shared.vitals(from: recap.startedAt, to: recap.endedAt)
        async let g = RouteMapSnapshot.load(for: recap.locatedStops, size: RouteMapSnapshot.ghostSize)
        async let c = RouteMapSnapshot.load(for: recap.locatedStops, size: RouteMapSnapshot.cardSize)
        async let p = loadFirstPhoto(recap)
        return await ShareAssets(vitals: v, ghostMap: g, cardMap: c, photo: p)
    }

    /// First photo of the night — a remote URL on posted recaps, a bare
    /// filename under Documents/night-recaps on local ones.
    private static func loadFirstPhoto(_ recap: NightRecap) async -> UIImage? {
        let names = recap.stops.flatMap(\.photoFilenames)
        guard let first = names.first else { return nil }
        if first.hasPrefix("http"), let url = URL(string: first) {
            if let (data, _) = try? await URLSession.shared.data(from: url) {
                return UIImage(data: data)
            }
            return nil
        }
        // Local: filenames live somewhere under Documents/night-recaps.
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = docs.appendingPathComponent("night-recaps", isDirectory: true)
        let target = (first as NSString).lastPathComponent
        if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in e where url.lastPathComponent == target {
                return UIImage(contentsOfFile: url.path)
            }
        }
        return nil
    }
}

// MARK: - Formatted numbers, shared by every variant

struct ShareNightStats {
    let recap: NightRecap
    let vitals: HealthService.Vitals?

    var unit: BACUnit { BACUnitSetting.current() }

    var stopsLabel: String { "\(recap.locatedStops.count)" }

    /// Plain drink count — "9 drinks" reads honestly on a story;
    /// standard-unit math stays an in-app detail.
    var drinksLabel: String { "\(recap.totalDrinks)" }

    var bacLabel: String { "\(unit.formatted(recap.peakBAC))\(unit.symbol)" }

    var hours: Double {
        max(recap.endedAt.timeIntervalSince(recap.startedAt) / 3600, 0)
    }

    /// Drinks per hour — the night's pace, Strava-style. A ≥10-minute
    /// floor keeps a two-minute test from reading "30/hr".
    var paceLabel: String {
        guard recap.totalDrinks > 0 else { return "—" }
        return String(format: "%.1f/hr", Double(recap.totalDrinks) / max(hours, 1.0 / 6.0))
    }

    var durationLabel: String {
        let mins = max(0, Int(recap.endedAt.timeIntervalSince(recap.startedAt) / 60))
        return mins >= 60 ? "\(mins / 60)h \(mins % 60)m" : "\(mins)m"
    }

    var crawledLabel: String {
        guard recap.crawlMeters > 0 else { return "—" }
        return recap.crawlMeters >= 1000
            ? String(format: "%.1f km", recap.crawlMeters / 1000)
            : "\(Int(recap.crawlMeters.rounded())) m"
    }

    var stepsLabel: String {
        guard let s = vitals?.steps, s > 0 else { return "—" }
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: Int(s))) ?? "\(Int(s))"
    }

    var kcalLabel: String {
        guard let k = vitals?.activeKcal, k > 0 else { return "—" }
        return "\(Int(k.rounded()))"
    }

    var dateLabel: String {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f.string(from: recap.startedAt).uppercased()
    }
}

// MARK: - The renderable card, all variants

struct NightShareCard: View {
    let recap: NightRecap
    var style: ShareCardStyle = .transparent
    var assets: ShareAssets = ShareAssets()

    private var stats: ShareNightStats { ShareNightStats(recap: recap, vitals: assets.vitals) }

    /// Canvas size per variant (the renderer uses exactly this).
    static func size(for style: ShareCardStyle, recap: NightRecap) -> CGSize {
        switch style {
        case .transparent: return CGSize(width: 360, height: recap.hasMap ? 470 : 240)
        case .photo, .map, .branded: return CGSize(width: 360, height: 560)
        case .route: return CGSize(width: 360, height: 400)
        case .stats: return CGSize(width: 360, height: 430)
        }
    }

    var body: some View {
        let size = Self.size(for: style, recap: recap)
        Group {
            switch style {
            case .transparent: transparentCard
            case .photo:       photoCard
            case .map:         mapCard
            case .branded:     brandedCard
            case .route:       routeCard
            case .stats:       statsCard
            }
        }
        .frame(width: size.width, height: size.height)
    }

    // ---- shared pieces -------------------------------------------------

    private func wordmark(_ fontSize: CGFloat = 24) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color.whiskey)
                .frame(width: fontSize * 0.33, height: fontSize * 0.33)
                .shadow(color: Color.whiskey.opacity(0.9), radius: 5)
            Text("sejdel")
                .font(.system(size: fontSize, weight: .black, design: .rounded))
                .italic()
                .tracking(-0.8)
                .foregroundStyle(Color.cream)
        }
    }

    private func shareStat(_ value: String, _ label: String,
                           tint: Color = .cream, valueSize: CGFloat = 19) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: valueSize, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .tracking(-0.5)
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            Text(label)
                .font(.system(size: 7, weight: .black, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(Color.cream.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    /// The numbers block: stops · drinks · peak BAC over
    /// pace · crawled · duration.
    private var statGrid: some View {
        VStack(spacing: 13) {
            HStack(spacing: 0) {
                shareStat(stats.stopsLabel, "STOPS")
                shareStat(stats.drinksLabel, "DRINKS")
                shareStat(stats.bacLabel, "PEAK BAC", tint: .whiskey)
            }
            HStack(spacing: 0) {
                shareStat(stats.paceLabel, "PACE")
                shareStat(stats.crawledLabel, "CRAWLED")
                shareStat(stats.durationLabel, "TIME OUT")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            wordmark()
            Spacer()
            Text(stats.dateLabel)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(1.8)
                .foregroundStyle(Color.cream.opacity(0.85))
        }
    }

    // ---- 1. TRANSPARENT (ghost map) ------------------------------------

    private var transparentCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            header.legibleOnAnyStory()
            if recap.hasMap {
                ZStack {
                    if let snap = assets.ghostMap {
                        Image(uiImage: snap.image)
                            .resizable()
                            .frame(width: snap.size.width, height: snap.size.height)
                            .overlay(Color.ink.opacity(0.18))
                            .opacity(0.55)
                            .mask(RoundedRectangle(cornerRadius: 30).padding(12).blur(radius: 14))
                        RouteSketch(stops: recap.locatedStops, fixedPoints: snap.points, fixedPath: snap.path)
                    } else {
                        RouteSketch(stops: recap.locatedStops)
                    }
                }
                .frame(width: RouteMapSnapshot.ghostSize.width,
                       height: RouteMapSnapshot.ghostSize.height)
            }
            statGrid.legibleOnAnyStory()
        }
        .padding(26)
    }

    // ---- 2. PHOTO ------------------------------------------------------

    private var photoCard: some View {
        ZStack(alignment: .bottom) {
            if let photo = assets.photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 360, height: 560)
                    .clipped()
            } else {
                // No photo on this night — moody fallback so the card
                // still works.
                LinearGradient(colors: [Color(red: 0.16, green: 0.11, blue: 0.07), Color.ink],
                               startPoint: .top, endPoint: .bottom)
            }
            LinearGradient(colors: [.clear, Color.ink.opacity(0.55), Color.ink.opacity(0.92)],
                           startPoint: .center, endPoint: .bottom)
            VStack(spacing: 16) {
                statGrid
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 22)
        }
        .overlay(alignment: .topLeading) {
            header.padding(20)
        }
        .frame(width: 360, height: 560)
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }

    // ---- 3. MAP (opaque full-bleed) ------------------------------------

    private var mapCard: some View {
        ZStack(alignment: .bottom) {
            if let snap = assets.cardMap {
                Image(uiImage: snap.image)
                    .resizable()
                    .frame(width: snap.size.width, height: snap.size.height)
                RouteSketch(stops: recap.locatedStops, fixedPoints: snap.points, fixedPath: snap.path)
                    .frame(width: snap.size.width, height: snap.size.height)
            } else {
                Color.ink
                RouteSketch(stops: recap.locatedStops)
                    .frame(width: 320, height: 420)
                    .padding(.bottom, 90)
            }
            LinearGradient(colors: [.clear, Color.ink.opacity(0.6), Color.ink.opacity(0.95)],
                           startPoint: .center, endPoint: .bottom)
                .frame(height: 260)
            statGrid
                .padding(.horizontal, 20)
                .padding(.bottom, 22)
        }
        .overlay(alignment: .topLeading) {
            LinearGradient(colors: [Color.ink.opacity(0.75), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 90)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            header.padding(20)
        }
        .frame(width: 360, height: 560)
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }

    // ---- 4. SEJDEL (opaque branded) ------------------------------------

    private var brandedCard: some View {
        ZStack {
            Color.ink
            // The app's whiskey atmosphere, baked flat.
            RadialGradient(colors: [Color.whiskey.opacity(0.28), .clear],
                           center: .init(x: 0.85, y: 0.02), startRadius: 10, endRadius: 380)
            RadialGradient(colors: [Color.bronze.opacity(0.16), .clear],
                           center: .init(x: 0.0, y: 0.1), startRadius: 10, endRadius: 320)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    wordmark(34)
                    Spacer()
                    Text(stats.dateLabel)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(1.8)
                        .foregroundStyle(Color.bronze)
                }
                Text("THE SESH RECAP")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(3)
                    .foregroundStyle(Color.bronze)
                    .padding(.top, 6)

                Spacer(minLength: 12)
                RouteSketch(stops: recap.locatedStops, emphasized: true)
                    .frame(height: 250)
                Spacer(minLength: 12)

                statGrid
            }
            .padding(24)
        }
        .frame(width: 360, height: 560)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(Color.whiskey.opacity(0.35), lineWidth: 1)
        )
    }

    // ---- 5. ROUTE (transparent, route only) ----------------------------

    private var routeCard: some View {
        VStack(spacing: 10) {
            RouteSketch(stops: recap.locatedStops, emphasized: true)
                .frame(height: 300)
            HStack(spacing: 8) {
                wordmark(18)
                Spacer()
                Text("\(stats.stopsLabel) STOPS · \(stats.drinksLabel) DRINKS · \(stats.bacLabel)")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(Color.cream.opacity(0.9))
            }
            .legibleOnAnyStory()
        }
        .padding(26)
    }

    // ---- 6. STATS (transparent, big numbers) ---------------------------

    private var statsCard: some View {
        VStack(spacing: 18) {
            Text(stats.dateLabel)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(2.4)
                .foregroundStyle(Color.cream.opacity(0.85))
            VStack(spacing: 2) {
                Text(stats.bacLabel)
                    .font(.system(size: 54, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .tracking(-1.5)
                    .foregroundStyle(Color.whiskey)
                Text("PEAK BAC")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(Color.cream.opacity(0.75))
            }
            HStack(spacing: 0) {
                shareStat(stats.drinksLabel, "DRINKS", valueSize: 24)
                shareStat(stats.paceLabel, "PACE", valueSize: 24)
            }
            HStack(spacing: 0) {
                shareStat(stats.stopsLabel, "STOPS", valueSize: 24)
                shareStat(stats.durationLabel, "TIME OUT", valueSize: 24)
            }
            wordmark(18)
        }
        .padding(26)
        .legibleOnAnyStory()
    }
}

/// Dark halo behind content so transparent stickers read on any story.
private struct LegibleOnAnyStory: ViewModifier {
    func body(content: Content) -> some View {
        content
            .shadow(color: .black.opacity(0.65), radius: 2, y: 1)
            .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
    }
}
private extension View {
    func legibleOnAnyStory() -> some View { modifier(LegibleOnAnyStory()) }
}

// MARK: - Route sketch

/// The night's stops projected into the frame (north up, aspect-correct),
/// joined by a glowing whiskey line.
private struct RouteSketch: View {
    let stops: [RecapStop]
    /// When set (map mode), dots land on these exact snapshot points so
    /// they sit on the actual streets.
    var fixedPoints: [CGPoint]? = nil
    /// The walked street route (projected) — drawn instead of straight
    /// stop-to-stop segments when available.
    var fixedPath: [CGPoint]? = nil
    /// Fatter line + dots for the route-forward variants.
    var emphasized: Bool = false

    var body: some View {
        GeometryReader { geo in
            let inset: CGFloat = 34
            let rect = CGRect(x: inset, y: inset,
                              width: max(geo.size.width - inset * 2, 1),
                              height: max(geo.size.height - inset * 2, 1))
            let pts = fixedPoints ?? Self.project(stops, into: rect)
            let line = (fixedPath?.count ?? 0) > 1 ? fixedPath! : pts
            let lw: CGFloat = emphasized ? 4.5 : 3
            let dot: CGFloat = emphasized ? 13 : 11

            ZStack {
                if line.count > 1 {
                    routePath(line)
                        .stroke(Color.whiskey.opacity(0.55),
                                style: StrokeStyle(lineWidth: lw + 4, lineCap: .round, lineJoin: .round))
                        .blur(radius: 4)
                    routePath(line)
                        .stroke(Color.whiskey,
                                style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
                        .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                }
                ForEach(Array(zip(stops.indices, pts)), id: \.0) { i, p in
                    let stop = stops[i]
                    // Neighbouring stops (afters at the same bar, etc.)
                    // would stack their labels — flip every second close
                    // one below its dot instead.
                    let crowded = pts.prefix(i).contains {
                        hypot($0.x - p.x, $0.y - p.y) < 70
                    }
                    Circle()
                        .fill(stop.isPeak ? Color.whiskey : Color.cream)
                        .frame(width: dot, height: dot)
                        .overlay(Circle().strokeBorder(Color.ink.opacity(0.85), lineWidth: 2))
                        .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
                        .position(p)
                    Text(stop.name)
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .lineLimit(1)
                        .foregroundStyle(Color.cream)
                        .shadow(color: .black.opacity(0.75), radius: 2, y: 1)
                        .frame(maxWidth: 110)
                        .position(x: p.x,
                                  y: crowded
                                    ? min(geo.size.height - 8, p.y + 18)
                                    : max(10, p.y - 16))
                }
            }
        }
    }

    private func routePath(_ pts: [CGPoint]) -> Path {
        Path { p in
            guard let first = pts.first else { return }
            p.move(to: first)
            for pt in pts.dropFirst() { p.addLine(to: pt) }
        }
    }

    static func project(_ stops: [RecapStop], into rect: CGRect) -> [CGPoint] {
        let coords: [(x: Double, y: Double)] = stops.compactMap { s in
            guard let la = s.lat, let lo = s.lon else { return nil }
            return (lo, la)
        }
        guard !coords.isEmpty else { return [] }
        let midLat = (coords.map(\.y).min()! + coords.map(\.y).max()!) / 2
        let lonScale = max(cos(midLat * .pi / 180), 0.01)
        let xs = coords.map { $0.x * lonScale }
        let ys = coords.map(\.y)
        let minX = xs.min()!, maxX = xs.max()!
        let minY = ys.min()!, maxY = ys.max()!
        let dx = max(maxX - minX, 1e-9), dy = max(maxY - minY, 1e-9)
        let scale = min(rect.width / dx, rect.height / dy)
        let w = dx * scale, h = dy * scale
        let ox = rect.minX + (rect.width - w) / 2
        let oy = rect.minY + (rect.height - h) / 2
        return zip(xs, ys).map { x, y in
            CGPoint(x: ox + CGFloat(x - minX) * scale,
                    y: oy + CGFloat(maxY - y) * scale)
        }
    }
}

// MARK: - Share sheet (carousel + Strava-style actions)

struct NightShareSheet: View {
    let recap: NightRecap
    @Environment(\.dismiss) private var dismiss

    @State private var style: ShareCardStyle = .transparent
    @State private var assets = ShareAssets()
    @State private var assetsLoaded = false
    @State private var rendered: [ShareCardStyle: URL] = [:]
    @State private var toast: String? = nil

    var body: some View {
        ZStack {
            AtmosphereBackground(accent: .whiskey)
            VStack(spacing: 12) {
                Text("SHARE YOUR NIGHT")
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(Color.bronze)
                    .padding(.top, 20)

                // Variant carousel — swipe between the six looks.
                TabView(selection: $style) {
                    ForEach(ShareCardStyle.allCases) { s in
                        cardPreview(s)
                            .tag(s)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 452)

                // Style name + page dots.
                Text(style.label)
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(Color.whiskey)
                HStack(spacing: 6) {
                    ForEach(ShareCardStyle.allCases) { s in
                        Circle()
                            .fill(s == style ? Color.whiskey : Color.cream.opacity(0.25))
                            .frame(width: 6, height: 6)
                    }
                }

                if let toast {
                    Text(toast)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 36)
                        .transition(.opacity)
                } else {
                    Text(style.isTransparent
                         ? "Transparent sticker — use INSTAGRAM or COPY, then paste it onto your story."
                         : "A full card — share it anywhere as a photo.")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 36)
                }

                // Actions — Strava's row, honestly implemented.
                HStack(spacing: 22) {
                    actionButton("camera.fill", "INSTAGRAM") { shareToInstagram() }
                    actionButton("doc.on.doc.fill", "COPY") { copySticker() }
                    actionButton("arrow.down.to.line", "SAVE") { saveToPhotos() }
                    if let url = currentURL() {
                        ShareLink(item: url) {
                            actionLabel("square.and.arrow.up", "MORE")
                        }
                        .buttonStyle(PressScaleStyle())
                    } else {
                        actionLabel("square.and.arrow.up", "MORE").opacity(0.4)
                    }
                }
                .padding(.top, 2)

                Button { dismiss() } label: {
                    Text("DONE")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(1.8)
                        .foregroundStyle(Color.cream.opacity(0.65))
                        .padding(.vertical, 8)
                }
                .buttonStyle(PressScaleStyle())
                Spacer(minLength: 4)
            }
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: toast)
        .task {
            assets = await ShareAssets.load(for: recap)
            assetsLoaded = true
            _ = ensureRendered(style)
        }
        .onChange(of: style) { _, s in
            toast = nil
            _ = ensureRendered(s)
        }
    }

    // ---- carousel page -------------------------------------------------

    @ViewBuilder
    private func cardPreview(_ s: ShareCardStyle) -> some View {
        let size = NightShareCard.size(for: s, recap: recap)
        let scale = min(1, 440 / size.height, 330 / size.width)
        ZStack {
            NightShareCard(recap: recap, style: s, assets: assets)
                .background(
                    // Transparent variants preview over the brand's own
                    // surface — ink, a whiskey glow, and the concave
                    // sejdel-glass dimples (this backdrop is preview-only;
                    // the exported PNG stays fully transparent).
                    s.isTransparent
                    ? AnyView(ZStack {
                        Color.ink
                        DimpleDriftBackground(strength: 0.17, speed: 7, scale: 1.2)
                        RadialGradient(colors: [Color.whiskey.opacity(0.22), .clear],
                                       center: .init(x: 0.85, y: 0.0),
                                       startRadius: 10, endRadius: 360)
                    })
                    : AnyView(Color.clear)
                )
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .strokeBorder(Color.cream.opacity(0.12), lineWidth: 1)
                )
                .scaleEffect(scale)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // ---- actions -------------------------------------------------------

    private func actionButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { actionLabel(icon, label) }
            .buttonStyle(PressScaleStyle())
    }

    private func actionLabel(_ icon: String, _ label: String) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().fill(Color.cream.opacity(0.07)).frame(width: 52, height: 52)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.whiskey)
            }
            .overlay(Circle().strokeBorder(Color.cream.opacity(0.12), lineWidth: 1))
            Text(label)
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(Color.cream.opacity(0.7))
        }
    }

    private func currentURL() -> URL? { rendered[style] }

    private func pngData() -> Data? {
        guard let url = ensureRendered(style) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Instagram keeps transparency ONLY via paste — so: sticker onto the
    /// clipboard, then straight into the story camera.
    private func shareToInstagram() {
        guard let data = pngData() else { return }
        UIPasteboard.general.setData(data, forPasteboardType: UTType.png.identifier)
        let ig = URL(string: "instagram://story-camera")!
        UIApplication.shared.open(ig) { ok in
            toast = ok
                ? "Sticker copied — tap the sticker tool (or long-press) and PASTE."
                : "Sticker copied — open Instagram and paste it onto your story."
        }
    }

    private func copySticker() {
        guard let data = pngData() else { return }
        UIPasteboard.general.setData(data, forPasteboardType: UTType.png.identifier)
        toast = "Copied — paste it in any story or chat."
    }

    private func saveToPhotos() {
        guard let data = pngData(), let img = UIImage(data: data) else { return }
        UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
        toast = "Saved to Photos."
    }

    // ---- rendering -----------------------------------------------------

    @discardableResult
    private func ensureRendered(_ s: ShareCardStyle) -> URL? {
        if let u = rendered[s] { return u }
        guard assetsLoaded else { return nil }
        let u = Self.renderPNG(recap: recap, style: s, assets: assets)
        rendered[s] = u
        return u
    }

    /// Bake one variant into a PNG in tmp (transparent canvas — opaque
    /// variants simply fill theirs edge to edge).
    @MainActor
    static func renderPNG(recap: NightRecap, style: ShareCardStyle, assets: ShareAssets) -> URL? {
        let renderer = ImageRenderer(
            content: NightShareCard(recap: recap, style: style, assets: assets)
        )
        renderer.scale = 3
        renderer.isOpaque = false
        guard let ui = renderer.uiImage, let data = ui.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sejdel-night-\(style.rawValue)-\(recap.id.uuidString.prefix(8)).png")
        do { try data.write(to: url) } catch { return nil }
        return url
    }
}
