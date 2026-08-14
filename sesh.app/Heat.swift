// Heat — "where's it hot tonight" on the friends map, and QR check-in.
//
// Two halves of one loop: the heat layer gives bars a visible reason to want
// check-ins, and a QR code on the table makes checking in one scan. Heat is
// fetched from the venue_heat RPC (migration 070), which only ever returns a
// BAND (warming / busy / hot) for clusters of 3+ distinct people in the last
// 8 hours — never counts, never identities. Clusters under the k-floor don't
// exist as far as the client knows.

import SwiftUI
import MapKit
import CoreImage.CIFilterBuiltins
import CoreLocation
import Combine
import Supabase
import Vision
import VisionKit

// MARK: - Model + service

struct HeatSpot: Decodable, Identifiable, Equatable {
    let name: String
    /// Mutable: the server sends the check-in centroid (GPS-jittered); the
    /// client snaps it to the bar's real Apple Maps position after fetch.
    var lat: Double
    var lon: Double
    /// 1 warming · 2 busy · 3 hot. The server decides; the client only styles.
    let band: Int
    /// 0.25…1.0, relative to the busiest bar in view (quantized server-side so
    /// head-counts can't be reconstructed). Drives dot size, glow and colour.
    let intensity: Double

    var id: String { "\(lat),\(lon)" }
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var label: String {
        switch band {
        case 3: return "HOT TONIGHT"
        case 2: return "BUSY"
        default: return "WARMING UP"
        }
    }

    /// Green (quiet) → red (hot), same hue ramp as the beer-price scale.
    var color: Color {
        Color(hue: 0.34 * (1 - intensity), saturation: 0.78, brightness: 0.92)
    }

    /// The dot itself grows with relative crowd size.
    var dotSize: CGFloat { 9 + 11 * intensity }
    /// Glow halo diameter — bigger reads busier before any label is legible.
    var glowSize: CGFloat { 46 + 72 * intensity }
}

@MainActor
final class HeatService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var spots: [HeatSpot] = []

    private let manager = CLLocationManager()
    private var waiters: [(CLLocationCoordinate2D?) -> Void] = []

    override init() {
        super.init()
        manager.delegate = self
    }

    /// Fetch heat around a coordinate, or around the device when nil.
    func refresh(near coordinate: CLLocationCoordinate2D? = nil) async {
        let center: CLLocationCoordinate2D?
        if let coordinate { center = coordinate } else { center = await oneShotLocation() }
        guard let c = center else { return }
        struct P: Encodable { let p_lat: Double; let p_lon: Double }
        let fetched: [HeatSpot]? = try? await supabase
            .rpc("venue_heat", params: P(p_lat: c.latitude, p_lon: c.longitude))
            .execute().value
        if let fetched { spots = await snapToMapKit(fetched) }
    }

    /// Check-in coordinates carry phone-GPS jitter, so a cluster centroid can
    /// land a street off. Snap each spot to the bar's real Apple Maps
    /// position (the same trick the deals pins use), keeping the centroid
    /// when MapKit misses or disagrees wildly — >400 m away almost certainly
    /// means a same-named bar somewhere else.
    private var resolvedByName: [String: CLLocationCoordinate2D] = [:]

    private func snapToMapKit(_ raw: [HeatSpot]) async -> [HeatSpot] {
        var out: [HeatSpot] = []
        for var spot in raw {
            let key = spot.name.lowercased()
            var coord = resolvedByName[key]
            if coord == nil {
                let req = MKLocalSearch.Request()
                req.naturalLanguageQuery = spot.name
                req.resultTypes = .pointOfInterest
                req.region = MKCoordinateRegion(
                    center: spot.coordinate,
                    latitudinalMeters: 3_000, longitudinalMeters: 3_000)
                coord = (try? await MKLocalSearch(request: req).start())?
                    .mapItems.first?.placemark.coordinate
            }
            if let c = coord {
                let drift = CLLocation(latitude: c.latitude, longitude: c.longitude)
                    .distance(from: CLLocation(latitude: spot.lat, longitude: spot.lon))
                if drift <= 400 {
                    resolvedByName[key] = c
                    spot.lat = c.latitude
                    spot.lon = c.longitude
                }
            }
            out.append(spot)
        }
        return out
    }

    private func oneShotLocation() async -> CLLocationCoordinate2D? {
        if let cached = manager.location { return cached.coordinate }
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        return await withCheckedContinuation { cont in
            waiters.append { cont.resume(returning: $0) }
            manager.requestLocation()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let coord = locations.first?.coordinate
        Task { @MainActor in
            waiters.forEach { $0(coord) }
            waiters.removeAll()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            waiters.forEach { $0(nil) }
            waiters.removeAll()
        }
    }
}

// MARK: - Map annotation

/// A soft glow + the bar's name tight under the dot. Deliberately vague: no
/// numbers, no avatars — just "this block has a pulse". The dot sits exactly
/// on the venue (labels hang as overlays so they never shift the anchor);
/// tapping pops the band chip above it. Sits UNDER friend pins in z-order.
struct HeatGlow: View {
    let spot: HeatSpot
    let selected: Bool
    let onTap: () -> Void
    @State private var breathing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [spot.color.opacity(0.42), spot.color.opacity(0)],
                        center: .center,
                        startRadius: 2,
                        endRadius: spot.glowSize / 2
                    )
                )
                .frame(width: spot.glowSize, height: spot.glowSize)
                .scaleEffect(breathing ? 1.12 : 0.94)
                .animation(.easeInOut(duration: 1.9).repeatForever(autoreverses: true),
                           value: breathing)
            Circle()
                .fill(spot.color)
                .frame(width: spot.dotSize, height: spot.dotSize)
                .overlay(Circle().strokeBorder(Color.ink.opacity(0.55), lineWidth: 1))
                .shadow(color: spot.color.opacity(0.9), radius: 6)
        }
        .frame(width: spot.glowSize, height: spot.glowSize)
        // the name is always attached, hanging just under the dot
        .overlay(alignment: .center) {
            Text(spot.name)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(Color.cream)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Capsule().fill(Color.ink.opacity(0.78)))
                .overlay(Capsule().strokeBorder(spot.color.opacity(0.45), lineWidth: 1))
                .offset(y: spot.dotSize / 2 + 15)
        }
        // tap → the band chip pops above the dot
        .overlay(alignment: .center) {
            if selected {
                HStack(spacing: 3) {
                    if spot.band == 3 { Text("🔥").font(.system(size: 9)) }
                    Text(spot.label)
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(Color.cream)
                }
                .fixedSize()
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.ink.opacity(0.92)))
                .overlay(Capsule().strokeBorder(spot.color.opacity(0.7), lineWidth: 1))
                .offset(y: -(spot.dotSize / 2 + 20))
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .contentShape(Circle())
        .onTapGesture { withAnimation(.spring(duration: 0.32)) { onTap() } }
        .onAppear { breathing = true }
    }
}

/// Green→red scale chip, mirroring the beer map's legend language.
struct HeatLegend: View {
    var body: some View {
        HStack(spacing: 7) {
            Text("QUIET")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(Color.cream.opacity(0.65))
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(hue: 0.34, saturation: 0.78, brightness: 0.92),
                            Color(hue: 0.17, saturation: 0.78, brightness: 0.92),
                            Color(hue: 0.08, saturation: 0.78, brightness: 0.92),
                            Color(hue: 0.00, saturation: 0.78, brightness: 0.92)
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .frame(width: 78, height: 5)
            Text("HOT")
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(Color(hue: 0, saturation: 0.7, brightness: 1))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color.ink.opacity(0.85)))
        .overlay(Capsule().strokeBorder(Color.cream.opacity(0.12), lineWidth: 1))
        .allowsHitTesting(false)
    }
}

// MARK: - QR check-in

/// What a resolved QR hands back — enough to run the normal check-in path.
struct QRVenue: Decodable, Identifiable {
    let id: UUID
    let name: String
    let address: String?
    let city: String?
    let lat: Double
    let lon: Double
}

/// Scan a table QR (or type its short code) → resolve to a bar → hand it to
/// the check-in sheet. Mirrors BarcodeScanFlow's look; the camera portion
/// needs a real device — the simulator (and denied-camera phones) get the
/// code field, which is also the accessibility path.
struct QRCheckInSheet: View {
    let onResolved: (QRVenue) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var manualCode = ""
    @State private var resolving = false
    @State private var errorText: String?
    @FocusState private var codeFocused: Bool

    private var scannerAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            VStack(spacing: 16) {
                VStack(spacing: 4) {
                    Text("SCAN TO CHECK IN")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(3)
                        .foregroundStyle(Color.bronze)
                    Text("Find the sesh code on the table")
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.cream)
                }
                .padding(.top, 22)

                if scannerAvailable {
                    QRCameraView { payload in handle(payload: payload) }
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .strokeBorder(Color.whiskey.opacity(0.4), lineWidth: 1)
                        )
                        .frame(maxHeight: 320)
                        .padding(.horizontal, 20)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(Color.bronze)
                        Text("Camera scanning needs a real device — type the code under the QR instead.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .frame(maxHeight: 200)
                }

                HStack(spacing: 8) {
                    TextField("CODE", text: $manualCode)
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .tracking(3)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($codeFocused)
                        .foregroundStyle(Color.cream)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.cream.opacity(0.06))
                        )
                    Button {
                        handle(payload: manualCode)
                    } label: {
                        Text(resolving ? "…" : "GO")
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .tracking(1.5)
                            .foregroundStyle(Color.ink)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 13)
                            .background(Capsule().fill(Color.whiskey))
                    }
                    .buttonStyle(PressScaleStyle())
                    .disabled(resolving || manualCode.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 20)

                if let errorText {
                    Text(errorText)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Status.danger.color)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                Spacer(minLength: 8)
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Accept a raw code or any URL whose last path segment is the code
    /// (so printed QRs can point at https://sejdel.com/qr/<CODE> and still
    /// work as a plain web link for people without the app).
    private func handle(payload: String) {
        guard !resolving else { return }
        let raw = payload.split(separator: "/").last.map(String.init) ?? payload
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !token.isEmpty else { return }
        resolving = true
        errorText = nil
        Task { @MainActor in
            struct P: Encodable { let p_token: String }
            let rows: [QRVenue]? = try? await supabase
                .rpc("venue_for_qr", params: P(p_token: token))
                .execute().value
            resolving = false
            if let venue = rows?.first {
                dismiss()
                onResolved(venue)
            } else {
                errorText = "No bar found for that code. Double-check it, or search for the bar instead."
            }
        }
    }
}

/// DataScanner narrowed to QR only — the barcode scanner's sibling.
struct QRCameraView: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        try? scanner.startScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        private var fired = false
        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard !fired else { return }
            for item in addedItems {
                if case let .barcode(barcode) = item,
                   let payload = barcode.payloadStringValue,
                   !payload.isEmpty {
                    fired = true
                    onScan(payload)
                    break
                }
            }
        }
    }
}


// MARK: - Admin: printable check-in QR

/// Admin-side half of QR check-in: find any bar on Earth via Apple Maps, get
/// its table QR. Uses the same MapKitVenueSearch the check-in sheet and the
/// campaign composer use — unbiased by the admin's own location, so a bar in
/// Singapore is as reachable as one down the street — and the same
/// resolveOrCreateMapKitVenue path, so a QR never mints a duplicate venue.
struct QRAdminSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var search = MapKitVenueSearch()
    @StateObject private var venues = VenueService()

    @State private var query = ""
    @State private var picked: Venue?
    @State private var token: String?
    @State private var working = false
    @State private var errorText: String?
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var queryFocused: Bool

    /// Venues that already have a code — the common "reprint it" case.
    private var coded: [Venue] {
        venues.venues.filter { $0.qrToken != nil }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            if let picked, let token {
                qrDetail(venue: picked, token: token)
            } else {
                finder
            }
        }
        .preferredColorScheme(.dark)
        .task { await venues.refresh() }
    }

    private var finder: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text("CHECK-IN QR")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(3)
                    .foregroundStyle(Color.bronze)
                Text("Find any bar, anywhere")
                    .font(.system(size: 19, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.cream)
                Text("Apple Maps search — try a name and a city.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.5))
            }
            .padding(.top, 20)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.bronze)
                TextField("e.g. Atlas Bar Singapore", text: $query)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .autocorrectionDisabled()
                    .focused($queryFocused)
                    .submitLabel(.search)
                    .onSubmit { runSearch(now: true) }
                    .onChange(of: query) { _, _ in runSearch(now: false) }
                if search.isSearching {
                    ProgressView().controlSize(.small).tint(Color.bronze)
                } else if !query.isEmpty {
                    Button { query = ""; search.clear() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.cream.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.cream.opacity(0.06)))
            .padding(.horizontal, 20)

            if let errorText {
                Text(errorText)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Status.danger.color)
                    .padding(.horizontal, 24)
            }

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 8) {
                    if !search.results.isEmpty {
                        sectionLabel("APPLE MAPS")
                        ForEach(search.results) { r in
                            row(name: r.name,
                                sub: [r.address, r.city].compactMap { $0 }.first,
                                glyph: "mappin.and.ellipse") {
                                mint(from: r)
                            }
                        }
                    } else if query.trimmingCharacters(in: .whitespaces).isEmpty,
                              !coded.isEmpty {
                        sectionLabel("ALREADY HAS A CODE")
                        ForEach(coded) { v in
                            row(name: v.name, sub: v.city, glyph: "qrcode") {
                                picked = v
                                token = v.qrToken
                            }
                        }
                    } else if !search.isSearching,
                              !query.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("No bars found. Try adding the city.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.5))
                            .padding(.top, 18)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(Color.bronze)
            Spacer()
        }
        .padding(.top, 6)
    }

    private func row(name: String, sub: String?, glyph: String,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.cream)
                        .lineLimit(1)
                    if let sub, !sub.isEmpty {
                        Text(sub)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                Spacer()
                if working {
                    ProgressView().controlSize(.small).tint(Color.whiskey)
                } else {
                    Image(systemName: glyph)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.whiskey)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.cream.opacity(0.04)))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(working)
    }

    /// Debounced so a fast typist doesn't fire a request per keystroke.
    private func runSearch(now: Bool) {
        searchTask?.cancel()
        let q = query
        searchTask = Task { @MainActor in
            if !now { try? await Task.sleep(nanoseconds: 320_000_000) }
            guard !Task.isCancelled else { return }
            // biasToOrigin: false — this is a global finder, not "near me".
            search.search(query: q, origin: nil, biasToOrigin: false)
        }
    }

    /// Turn an Apple Maps hit into a real venue row, then mint its token.
    private func mint(from result: MapKitVenueResult) {
        guard !working else { return }
        working = true
        errorText = nil
        Task { @MainActor in
            guard let venue = await venues.resolveOrCreateMapKitVenue(result) else {
                working = false
                errorText = "Couldn't save that bar. Check your connection and try again."
                return
            }
            struct P: Encodable { let p_venue: UUID }
            let t: String? = try? await supabase
                .rpc("ensure_qr_token", params: P(p_venue: venue.id))
                .execute().value
            working = false
            if let t {
                picked = venue
                token = t
            } else {
                errorText = "Couldn't create a code for that bar."
            }
        }
    }

    private func qrDetail(venue: Venue, token: String) -> some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text("TABLE QR")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(3)
                    .foregroundStyle(Color.bronze)
                Text(venue.name)
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .multilineTextAlignment(.center)
                if let city = venue.city, !city.isEmpty {
                    Text(city)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.5))
                }
            }
            .padding(.top, 22)

            if let img = Self.qrImage(for: token) {
                Image(uiImage: img)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 230, height: 230)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.cream))
            }

            Text(token)
                .font(.system(size: 19, weight: .black, design: .monospaced))
                .tracking(5)
                .foregroundStyle(Color.whiskey)

            Text("Print this for the tables. Scanning checks guests in here — the code under it works if the camera won't.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 34)

            if let img = Self.qrImage(for: token) {
                ShareLink(
                    item: Image(uiImage: img),
                    preview: SharePreview("\(venue.name) check-in QR", image: Image(uiImage: img))
                ) {
                    Label("Share / print", systemImage: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .background(Capsule().fill(Color.whiskey))
                }
                .buttonStyle(PressScaleStyle())
            }

            Button {
                picked = nil
                self.token = nil
            } label: {
                Text("ANOTHER BAR")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(Color.bronze)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 10)
        }
    }

    /// High-error-correction QR of the public check-in URL, scaled crisp.
    private static func qrImage(for token: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data("https://sejdel.com/qr/\(token)".utf8)
        filter.correctionLevel = "Q"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
