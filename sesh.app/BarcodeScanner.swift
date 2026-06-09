// Barcode → beverage spec scanning.
//
// The scan only yields a NUMBER (the barcode). Specs are resolved by
// looking that number up through three tiers, fastest/most-trusted first:
//
//   1. Our own Supabase `beverage_barcodes` catalog — crowd-sourced from
//      every prior confirmed scan. Instant + accurate once seeded.
//   2. Open Food Facts — free public product DB. Good for volume + name,
//      ABV is often missing (it's a contributed field).
//   3. Nothing → the confirm sheet opens in full-manual mode.
//
// The user ALWAYS confirms before logging (ABV drives BAC — we never
// trust a scrape blindly). On confirm we upsert back into the Supabase
// catalog so the next person who scans the same can gets it instantly.

import AVFoundation
import Combine
import Supabase
import SwiftUI
import Vision
import VisionKit

// MARK: - Resolved spec

/// Best-effort beverage spec from a barcode. Any field may be nil — the
/// confirm sheet fills the gaps. `abv` is a fraction (0…1) to match
/// `DrinkOption.abv`.
struct ScannedBeverage {
    let barcode: String
    var name: String?
    var category: DrinkCategory?
    var volumeML: Double?
    var abv: Double?
    var source: Source

    enum Source { case ownCatalog, localCache, openFoodFacts, unknown }
}

// MARK: - Local (device-only) cache

/// A user's own confirmed barcodes, stored on-device. Lets them re-scan a
/// can they've already entered and get instant specs even before that
/// entry has reached 5-user consensus in the shared catalog. Purely local;
/// never trusted by anyone else.
enum BeverageLocalCache {
    private static let key = "sesh.beverageBarcodes.local.v1"

    struct Entry: Codable {
        var name: String
        var category: String   // DrinkCategory rawValue
        var volumeML: Double
        var abv: Double
    }

    private static func all() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let dict = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return dict
    }

    static func lookup(barcode: String) -> ScannedBeverage? {
        guard !barcode.isEmpty, let e = all()[barcode] else { return nil }
        return ScannedBeverage(
            barcode: barcode,
            name: e.name,
            category: DrinkCategory(rawValue: e.category) ?? .beer,
            volumeML: e.volumeML,
            abv: e.abv,
            source: .localCache
        )
    }

    static func save(barcode: String, name: String, category: DrinkCategory, volumeML: Double, abv: Double) {
        guard !barcode.isEmpty else { return }
        var dict = all()
        dict[barcode] = Entry(name: name, category: category.rawValue, volumeML: volumeML, abv: abv)
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: - Lookup service

@MainActor
final class BeverageLookupService: ObservableObject {

    /// Resolve a barcode. Never throws — a total miss just returns an
    /// `.unknown` result carrying the barcode, so the confirm sheet can
    /// open in manual mode.
    ///
    /// Tiers, most-trusted first:
    ///   1. Verified shared catalog (5-user consensus).
    ///   2. This device's own prior confirmation (instant for the user,
    ///      even before consensus).
    ///   3. Open Food Facts.
    ///   4. Nothing → manual.
    func lookup(barcode: String) async -> ScannedBeverage {
        if let own = await lookupOwnCatalog(barcode: barcode) { return own }
        if let local = BeverageLocalCache.lookup(barcode: barcode) { return local }
        if let off = await lookupOpenFoodFacts(barcode: barcode) { return off }
        return ScannedBeverage(barcode: barcode, source: .unknown)
    }

    /// Result of casting a consensus vote.
    struct SubmitResult { let verified: Bool; let count: Int; let threshold: Int }

    /// Record the user's confirmed spec as a consensus vote AND cache it on
    /// this device. The spec only lands in the shared `beverage_barcodes`
    /// catalog once `threshold` distinct users have submitted the same
    /// content for this barcode — until then it's device-local only.
    /// Returns the running tally (or nil if the submit failed / barcode
    /// was empty, e.g. manual entry with no scan).
    @discardableResult
    func submit(barcode: String, name: String, category: DrinkCategory, volumeML: Double, abv: Double) async -> SubmitResult? {
        // Always cache locally first — works offline and regardless of
        // whether the vote reaches the server.
        BeverageLocalCache.save(barcode: barcode, name: name, category: category, volumeML: volumeML, abv: abv)

        // Manual entries with no scanned barcode can't be voted on.
        guard !barcode.isEmpty else { return nil }

        struct Params: Encodable {
            let p_barcode: String
            let p_name: String
            let p_category: String
            let p_volume_ml: Double
            let p_abv: Double
        }
        struct Response: Decodable { let verified: Bool; let count: Int; let threshold: Int }
        do {
            let resp: Response = try await supabase
                .rpc("submit_beverage_barcode", params: Params(
                    p_barcode: barcode,
                    p_name: name,
                    p_category: category.rawValue,
                    p_volume_ml: volumeML,
                    p_abv: abv
                ))
                .execute()
                .value
            return SubmitResult(verified: resp.verified, count: resp.count, threshold: resp.threshold)
        } catch {
            // Non-fatal: the drink still logs and the local cache already
            // holds the spec; the vote just didn't reach the server.
            print("Barcode submit failed:", error.localizedDescription)
            return nil
        }
    }

    // MARK: tier 1 — our catalog

    private func lookupOwnCatalog(barcode: String) async -> ScannedBeverage? {
        struct Row: Decodable {
            let name: String
            let category: String
            let volume_ml: Double
            let abv: Double
        }
        do {
            let rows: [Row] = try await supabase
                .from("beverage_barcodes")
                .select("name,category,volume_ml,abv")
                .eq("barcode", value: barcode)
                .limit(1)
                .execute()
                .value
            guard let r = rows.first else { return nil }
            return ScannedBeverage(
                barcode: barcode,
                name: r.name,
                category: DrinkCategory(rawValue: r.category) ?? .beer,
                volumeML: r.volume_ml,
                abv: r.abv,
                source: .ownCatalog
            )
        } catch {
            return nil
        }
    }

    // MARK: tier 2 — Open Food Facts

    private func lookupOpenFoodFacts(barcode: String) async -> ScannedBeverage? {
        guard let url = URL(string:
            "https://world.openfoodfacts.org/api/v2/product/\(barcode).json?fields=product_name,quantity,nutriments,categories_tags"
        ) else { return nil }
        do {
            var request = URLRequest(url: url)
            // OFF asks API clients to identify themselves.
            request.setValue("sesh-ios/1.0 (sesh app)", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            let resp = try JSONDecoder().decode(OFFResponse.self, from: data)
            guard resp.status == 1, let p = resp.product else { return nil }
            return ScannedBeverage(
                barcode: barcode,
                name: p.productName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                category: Self.category(from: p.categoriesTags),
                volumeML: Self.volumeML(from: p.quantity),
                abv: p.nutriments?.alcohol.map { $0 / 100.0 },
                source: .openFoodFacts
            )
        } catch {
            return nil
        }
    }

    // MARK: parsing helpers

    /// Parse a free-text quantity ("330 ml", "33 cl", "0,75 l", "75cl")
    /// into millilitres. Returns nil when it can't find a number+unit.
    static func volumeML(from quantity: String?) -> Double? {
        guard let q = quantity?.lowercased() else { return nil }
        // Grab the first number (comma or dot decimal) and the unit after.
        let pattern = #"([0-9]+[.,]?[0-9]*)\s*(ml|cl|dl|l|litre|liter)"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)),
              let numRange = Range(m.range(at: 1), in: q),
              let unitRange = Range(m.range(at: 2), in: q)
        else { return nil }
        let numStr = q[numRange].replacingOccurrences(of: ",", with: ".")
        guard let value = Double(numStr) else { return nil }
        switch q[unitRange] {
        case "ml":               return value
        case "cl":               return value * 10
        case "dl":               return value * 100
        case "l", "litre", "liter": return value * 1000
        default:                 return nil
        }
    }

    /// Map OFF category tags to one of our DrinkCategory cases. nil when
    /// nothing recognisable matches (user picks in the confirm sheet).
    static func category(from tags: [String]?) -> DrinkCategory? {
        guard let tags = tags?.map({ $0.lowercased() }) else { return nil }
        let joined = tags.joined(separator: " ")
        if joined.contains("whisk") { return .whisky }
        if joined.contains("vodka") { return .vodka }
        if joined.contains("gin") { return .gin }
        if joined.contains("cider") { return .cider }
        if joined.contains("champagne") || joined.contains("sparkling") || joined.contains("prosecco") { return .sparkling }
        if joined.contains("cocktail") { return .cocktail }
        if joined.contains("wine") { return .wine }
        if joined.contains("beer") || joined.contains("lager") || joined.contains("ale") || joined.contains("ipa") { return .beer }
        return nil
    }
}

// MARK: - Open Food Facts decode

private struct OFFResponse: Decodable {
    let status: Int
    let product: OFFProduct?
}

private struct OFFProduct: Decodable {
    let productName: String?
    let quantity: String?
    let categoriesTags: [String]?
    let nutriments: OFFNutriments?
    enum CodingKeys: String, CodingKey {
        case productName = "product_name"
        case quantity
        case categoriesTags = "categories_tags"
        case nutriments
    }
}

private struct OFFNutriments: Decodable {
    let alcohol: Double?
    enum CodingKeys: String, CodingKey { case alcohol }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // OFF sometimes encodes alcohol as a number, sometimes a string.
        if let d = try? c.decode(Double.self, forKey: .alcohol) {
            alcohol = d
        } else if let s = try? c.decode(String.self, forKey: .alcohol), let d = Double(s) {
            alcohol = d
        } else {
            alcohol = nil
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Camera (VisionKit DataScanner)

/// Thin SwiftUI wrapper over VisionKit's live barcode scanner. Calls
/// `onScan` exactly once with the first barcode it reads, then the parent
/// tears it down.
@available(iOS 16.0, *)
struct BarcodeCameraView: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce, .code128])],
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

// MARK: - Scan flow (scanner → lookup → confirm)

/// Full-screen flow: scan a barcode, resolve it, then confirm/correct the
/// spec before logging. `onComplete` hands the finished DrinkOption back
/// to the caller (which logs it like any catalog pick). `onCancel`
/// dismisses with nothing.
struct BarcodeScanFlow: View {
    let onComplete: (DrinkOption) -> Void
    let onCancel: () -> Void

    @StateObject private var lookup = BeverageLookupService()
    @State private var phase: Phase = .start

    private enum Phase {
        case start
        case scanning
        case resolving(String)
        case confirm(ScannedBeverage)
    }

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            switch phase {
            case .start:
                Color.clear.onAppear { phase = .scanning }
            case .scanning:
                scannerStage
            case .resolving(let code):
                resolvingStage(code: code)
            case .confirm(let beverage):
                BarcodeConfirmView(
                    beverage: beverage,
                    onLog: { option, edited in
                        // Cache locally + cast a consensus vote (the spec
                        // only joins the shared catalog after 5 distinct
                        // users agree). Fire-and-forget — the drink logs
                        // immediately either way.
                        Task {
                            await lookup.submit(
                                barcode: edited.barcode,
                                name: option.name,
                                category: option.category,
                                volumeML: option.volumeML,
                                abv: option.abv
                            )
                        }
                        onComplete(option)
                    },
                    onCancel: onCancel
                )
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: stages

    @ViewBuilder
    private var scannerStage: some View {
        if #available(iOS 16.0, *),
           DataScannerViewController.isSupported,
           DataScannerViewController.isAvailable {
            ZStack {
                BarcodeCameraView { code in
                    phase = .resolving(code)
                }
                .ignoresSafeArea()
                scannerOverlay
            }
        } else {
            // Simulator or unsupported hardware — skip straight to manual.
            unsupportedStage
        }
    }

    private var scannerOverlay: some View {
        VStack {
            HStack {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.cream)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color.ink.opacity(0.55)))
                }
                Spacer()
            }
            .padding()
            Spacer()
            Text("Point at a can or bottle barcode")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(Color.cream)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.ink.opacity(0.6)))
                .padding(.bottom, 60)
        }
    }

    private func resolvingStage(code: String) -> some View {
        VStack(spacing: 16) {
            ProgressView().tint(Color.whiskey)
            Text("Looking up barcode…")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(Color.cream)
            Text(code)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.bronze)
        }
        .task(id: code) {
            let result = await lookup.lookup(barcode: code)
            phase = .confirm(result)
        }
    }

    private var unsupportedStage: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.metering.unknown")
                .font(.system(size: 30))
                .foregroundStyle(Color.bronze)
            Text("Scanning isn't available here")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Color.cream)
            Text("Enter the drink manually instead.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.6))
            Button("Enter manually") {
                phase = .confirm(ScannedBeverage(barcode: "", source: .unknown))
            }
            .font(.system(size: 13, weight: .black, design: .monospaced))
            .foregroundStyle(Color.ink)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Capsule().fill(Color.whiskey))
            Button("Cancel", action: onCancel)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.6))
        }
        .padding(40)
    }
}

// MARK: - Confirm sheet

/// Confirm / correct the resolved spec, then log. Pre-filled from the
/// lookup; the user can fix anything (ABV especially, since it drives BAC).
private struct BarcodeConfirmView: View {
    let beverage: ScannedBeverage
    /// (option, sourceBeverage) — the caller logs the option and we use the
    /// barcode for the catalog contribution.
    let onLog: (DrinkOption, ScannedBeverage) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var category: DrinkCategory
    @State private var volumeText: String
    @State private var abvText: String

    private let volumePresets: [Double] = [330, 440, 500, 568, 750]

    init(beverage: ScannedBeverage,
         onLog: @escaping (DrinkOption, ScannedBeverage) -> Void,
         onCancel: @escaping () -> Void) {
        self.beverage = beverage
        self.onLog = onLog
        self.onCancel = onCancel
        _name = State(initialValue: beverage.name ?? "")
        _category = State(initialValue: beverage.category ?? .beer)
        _volumeText = State(initialValue: beverage.volumeML.map { String(Int($0.rounded())) } ?? "")
        _abvText = State(initialValue: beverage.abv.map { String(format: "%.1f", $0 * 100) } ?? "")
    }

    private var volumeML: Double? { Double(volumeText.replacingOccurrences(of: ",", with: ".")) }
    /// Parsed ABV percent (0…100), or nil if blank/non-numeric.
    private var abvPercent: Double? {
        Double(abvText.replacingOccurrences(of: ",", with: "."))
    }
    /// Valid only when 0 < % ≤ 100 — you can't have a drink stronger than
    /// pure alcohol.
    private var abvFraction: Double? {
        guard let v = abvPercent, v > 0, v <= 100 else { return nil }
        return v / 100.0
    }
    /// True when the user typed a number that's out of the 0–100 range, so
    /// we can show an inline warning rather than a silently-disabled button.
    private var abvOutOfRange: Bool {
        guard let v = abvPercent else { return false }
        return v <= 0 || v > 100
    }
    private var canLog: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && (volumeML ?? 0) > 0
            && abvFraction != nil
    }

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    field(label: "NAME") {
                        TextField("", text: $name, prompt: Text("e.g. Brewdog Punk IPA")
                            .foregroundStyle(Color.cream.opacity(0.4)))
                            .textFieldStyle(.plain)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.cream)
                    }
                    categoryField
                    volumeField
                    VStack(alignment: .leading, spacing: 6) {
                        field(label: "ALCOHOL %") {
                            HStack {
                                TextField("", text: $abvText, prompt: Text("5.0")
                                    .foregroundStyle(Color.cream.opacity(0.4)))
                                    .textFieldStyle(.plain)
                                    .keyboardType(.decimalPad)
                                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Color.cream)
                                Text("% ABV")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Color.bronze)
                            }
                        }
                        if abvOutOfRange {
                            Text("Alcohol % must be between 0 and 100.")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color(red: 0.85, green: 0.40, blue: 0.34))
                        }
                    }
                    logButton
                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(sourceLabel)
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(2.0)
                    .foregroundStyle(Color.bronze)
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.cream.opacity(0.6))
                }
            }
            Text("Confirm your drink")
                .font(.system(size: 24, weight: .black, design: .rounded))
                .foregroundStyle(Color.cream)
            Text("Double-check the alcohol % and size — they drive your BAC.")
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.55))
        }
        .padding(.top, 8)
    }

    private var sourceLabel: String {
        switch beverage.source {
        case .ownCatalog:    return "VERIFIED · SESH CATALOG"
        case .localCache:    return "SAVED ON THIS DEVICE"
        case .openFoodFacts: return "FROM OPEN FOOD FACTS"
        case .unknown:       return "NEW ENTRY"
        }
    }

    private var categoryField: some View {
        field(label: "TYPE") {
            Menu {
                ForEach(DrinkCategory.allCases) { c in
                    Button {
                        category = c
                    } label: {
                        Text("\(c.emoji)  \(c.label)")
                    }
                }
            } label: {
                HStack {
                    Text("\(category.emoji)  \(category.label)")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.cream)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.bronze)
                }
            }
        }
    }

    private var volumeField: some View {
        field(label: "SIZE") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("", text: $volumeText, prompt: Text("330")
                        .foregroundStyle(Color.cream.opacity(0.4)))
                        .textFieldStyle(.plain)
                        .keyboardType(.numberPad)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.cream)
                    Text("mL")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.bronze)
                }
                HStack(spacing: 6) {
                    ForEach(volumePresets, id: \.self) { v in
                        Button {
                            volumeText = String(Int(v))
                        } label: {
                            Text("\(Int(v))")
                                .font(.system(size: 11, weight: .black, design: .monospaced))
                                .foregroundStyle(volumeML == v ? Color.ink : Color.cream.opacity(0.8))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule().fill(volumeML == v ? Color.whiskey : Color.cream.opacity(0.06))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var logButton: some View {
        Button {
            guard let vol = volumeML, let abv = abvFraction else { return }
            let clean = name.trimmingCharacters(in: .whitespaces)
            let option = DrinkOption(
                category: category,
                name: clean,
                detail: "\(Int(vol)) ml · \(abvText)%",
                volumeML: vol,
                abv: abv
            )
            onLog(option, beverage)
        } label: {
            Text("LOG THIS DRINK")
                .font(.system(size: 13, weight: .black, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(Color.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(canLog ? Color.whiskey : Color.cream.opacity(0.12))
                )
                .shadow(color: canLog ? Color.whiskey.opacity(0.4) : .clear, radius: 14, y: 6)
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!canLog)
        .padding(.top, 6)
    }

    @ViewBuilder
    private func field<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(2.0)
                .foregroundStyle(Color.bronze)
            content()
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.inkElev.opacity(0.7))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.cream.opacity(0.08), lineWidth: 1)
                )
        }
    }
}
