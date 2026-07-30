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
    /// (so printed QRs can point at https://seshapp.xyz/qr/<CODE> and still
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

/// Admin-side half of QR check-in: pick a bar, get its table QR. The token is
/// minted once per venue (ensure_qr_token) and encoded as
/// https://seshapp.xyz/qr/<CODE> so the printed code also works as a plain
/// web link for people without the app.
struct QRAdminSheet: View {
    @Environment(\.dismiss) private var dismiss

    private struct VenueLite: Decodable, Identifiable {
        let id: UUID
        let name: String
        let city: String?
    }

    @State private var venues: [VenueLite] = []
    @State private var search = ""
    @State private var picked: VenueLite?
    @State private var token: String?
    @State private var loading = false

    private var filtered: [VenueLite] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return venues }
        return venues.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            if let picked, let token {
                qrDetail(venue: picked, token: token)
            } else {
                venueList
            }
        }
        .preferredColorScheme(.dark)
        .task {
            venues = (try? await supabase
                .from("venues")
                .select("id, name, city")
                .order("name")
                .execute().value) ?? []
        }
    }

    private var venueList: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text("CHECK-IN QR")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(3)
                    .foregroundStyle(Color.bronze)
                Text("Pick a bar to print its code")
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.cream)
            }
            .padding(.top, 22)

            TextField("Search bars", text: $search)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.cream)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.cream.opacity(0.06)))
                .padding(.horizontal, 20)

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 8) {
                    ForEach(filtered) { v in
                        Button {
                            fetchToken(for: v)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(v.name)
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                        .foregroundStyle(Color.cream)
                                    if let city = v.city, !city.isEmpty {
                                        Text(city)
                                            .font(.system(size: 11, weight: .medium, design: .rounded))
                                            .foregroundStyle(Color.cream.opacity(0.5))
                                    }
                                }
                                Spacer()
                                Image(systemName: "qrcode")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(Color.whiskey)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.cream.opacity(0.04)))
                        }
                        .buttonStyle(PressScaleStyle())
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
        }
    }

    private func qrDetail(venue: VenueLite, token: String) -> some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text("TABLE QR")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(3)
                    .foregroundStyle(Color.bronze)
                Text(venue.name)
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.cream)
            }
            .padding(.top, 24)

            if let img = Self.qrImage(for: token) {
                Image(uiImage: img)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 240, height: 240)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.cream))
            }

            Text(token)
                .font(.system(size: 20, weight: .black, design: .monospaced))
                .tracking(5)
                .foregroundStyle(Color.whiskey)

            Text("Print this for the tables. Scanning checks guests in at \(venue.name) — the code under it works if the camera won't.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)

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

    private func fetchToken(for venue: VenueLite) {
        guard !loading else { return }
        loading = true
        Task { @MainActor in
            struct P: Encodable { let p_venue: UUID }
            let t: String? = try? await supabase
                .rpc("ensure_qr_token", params: P(p_venue: venue.id))
                .execute().value
            loading = false
            if let t {
                picked = venue
                token = t
            }
        }
    }

    /// High-error-correction QR of the public check-in URL, scaled crisp.
    private static func qrImage(for token: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data("https://seshapp.xyz/qr/\(token)".utf8)
        filter.correctionLevel = "Q"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
