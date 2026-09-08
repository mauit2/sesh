// Business.swift — Sejdel for Business.
//
// A bar claims its venue, an admin verifies it, and a monthly subscription
// puts it on the Deals map: Business = a pin, a profile people can follow and
// posts to followers; Business+ = the bar's photo as a poster, boosted posts
// (view packs that run as sponsored feed posts + map billboards), app-open
// cards and pushes. Deals go live on submit — the subscription is the
// approval. Cards and pushes are still reviewed and paid after approval.
// Every cap is enforced by the RPCs (migrations 113–117), never here.
//
// Three audiences in this file:
//   • bar owners   — BusinessHubView → claim, subscribe, profile, posts,
//                    deals, boosts, cards, pushes
//   • admins       — BusinessReviewView → verify bars, approve card / push
//                    orders, tune packs and limits
//   • everyone     — SponsoredCards.claim(near:) → the app-open card hook

import Combine
import CoreLocation
import MapKit
import PhotosUI
import StoreKit
import Supabase
import SwiftUI

// MARK: - Decoding

/// RPCs return jsonb with snake_case keys and Postgres timestamps
/// ("2026-09-06T11:10:20.36287+00:00" — one to six fractional digits).
enum BusinessJSON {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = parseDate(s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "bad date \(s)"))
        }
        return d
    }()

    static func parseDate(_ raw: String) -> Date? {
        // ISO8601DateFormatter wants exactly three fractional digits.
        let s = raw.replacing(#/\.(\d{1,9})/#) { m in
            "." + String(m.1).padding(toLength: 3, withPad: "0", startingAt: 0)
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = s.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return f.date(from: s)
    }
}

// MARK: - Models

struct BusinessSummary: Decodable, Identifiable {
    let id: UUID
    let name: String
    let username: String?
    let status: String
    let adminNote: String?
    let venueId: UUID
    let venueName: String
    let venueCity: String?
    let venueCountry: String?
    let contactEmail: String
    let createdAt: Date
    let tier: String
    let tierExpiresAt: Date?
    let followers: Int
    let liveCampaigns: Int
    let pendingOrders: Int
    let unpaidOrders: Int
    /// Who this account was before it became the bar — the holder's eyes only.
    let priorName: String?
    let priorUsername: String?
}

/// One App Store product: a subscription tier (`quantity` 1 = Business,
/// 2 = Business+), a boost (views) or a card / push pack (people). The SEK
/// amount is the display price before StoreKit loads.
struct BizProduct: Decodable, Identifiable, Hashable {
    let productId: String
    let kind: String
    let quantity: Int
    let amountSek: Int
    let label: String
    var id: String { productId }
}

/// The two monthly tiers. Business puts the bar on the map as a pin with a
/// profile people can follow; Business+ makes it a poster and unlocks
/// boosts, app-open cards and pushes.
enum BizTier {
    static let business = "sejdel.biz.business.monthly"
    static let plus = "sejdel.biz.plus.monthly"
    static let ids = [business, plus]
    static func label(_ tier: String) -> String {
        switch tier {
        case "plus":     return "BUSINESS+"
        case "business": return "BUSINESS"
        default:         return "NOT SUBSCRIBED"
        }
    }
}

/// The business tools in the ☰ menu — each opens one slice of the dashboard.
enum BizTool: String, Identifiable, CaseIterable {
    case profile, plan, stats, deals, boost, card, push, qr
    var id: String { rawValue }
    var title: String {
        switch self {
        case .profile: return "Edit business profile"
        case .plan:    return "Plan"
        case .stats:   return "Stats"
        case .deals:   return "Deals"
        case .boost:   return "Boost a post"
        case .card:    return "App-open card"
        case .push:    return "Push notification"
        case .qr:      return "QR codes"
        }
    }
    var icon: String {
        switch self {
        case .profile: return "storefront"
        case .plan:    return "creditcard"
        case .stats:   return "chart.bar.fill"
        case .deals:   return "tag.fill"
        case .boost:   return "bolt.fill"
        case .card:    return "rectangle.portrait.on.rectangle.portrait.angled"
        case .push:    return "bell.badge.fill"
        case .qr:      return "qrcode"
        }
    }
    var sheetTitle: String {
        switch self {
        case .profile: return "Your profile."
        case .plan:    return "Your plan."
        case .stats:   return "How it's going."
        case .deals:   return "Deals on your pin."
        case .boost:   return "Boost a post."
        case .card:    return "App-open card."
        case .push:    return "Push notification."
        case .qr:      return "QR codes."
        }
    }
}

struct BusinessOverview: Decodable {
    struct Info: Decodable {
        let id: UUID
        let name: String
        let status: String
        let adminNote: String?
        let venueId: UUID?
        let venueName: String
        let venueCity: String?
        let venueCountry: String?
        let venueLat: Double
        let venueLon: Double
        let contactEmail: String
        let tier: String
        let tierProductId: String?
        let tierExpiresAt: Date?
        let logoUrl: String?
        let posterUrl: String?
        let tagline: String?
        let followers: Int
        let username: String?
        let priorName: String?
        let priorUsername: String?
        /// The table check-in QR, once minted (subscribed bars only).
        let qrToken: String?
    }
    struct Event: Decodable, Identifiable {
        let id: UUID
        let title: String
        let startsAt: Date
        let imageUrl: String?
        let imageRatio: Double?
        let createdAt: Date
        var ratio: CGFloat { CampaignArt.clampFeed(CGFloat(imageRatio ?? 1)) }
    }
    /// A deal on the bar's pin. Live automatically while the bar is subscribed.
    struct Campaign: Decodable, Identifiable {
        let id: UUID
        let kind: String
        let title: String
        let description: String?
        let finePrint: String?
        let placement: String
        let imageUrl: String?
        let billboardImageUrl: String?
        let startsAt: Date?
        let endsAt: Date?
        let activeDays: [Int]?
        let startMinute: Int?
        let endMinute: Int?
        let approved: Bool
        let live: Bool
        let impressions: Int
        let taps: Int
        let weekImpressions: Int
        let weekTaps: Int
    }
    struct Boost: Decodable {
        let id: UUID
        let status: String
        let productId: String
        let goalViews: Int
        let views: Int
        let taps: Int
    }
    /// A post to followers. `imageRatio` is width / height, already clamped
    /// to Instagram's 4:5 … 1.91:1.
    struct Post: Decodable, Identifiable {
        let id: UUID
        let imageUrl: String
        let imageUrls: [String]?
        let imageRatio: Double
        let caption: String?
        let eventAt: Date?
        let offerId: UUID?
        let createdAt: Date
        let boost: Boost?
    }
    struct Card: Decodable, Identifiable {
        let id: UUID
        let offerId: UUID
        let offerTitle: String
        let audienceCap: Int
        let delivered: Int
        let tapped: Int
        let status: String
        let startsAt: Date?
        let endsAt: Date?
        let orderId: UUID?
        let orderStatus: String?
        let paid: Bool?
        let amountSek: Int?
        let productId: String?
        let quantity: Int?
        let rejectReason: String?
    }
    struct Push: Decodable, Identifiable {
        let id: UUID
        let offerId: UUID?
        let title: String
        let body: String
        let audienceCap: Int
        let sendAt: Date
        let status: String
        let recipientCount: Int
        let sentAt: Date?
        let orderId: UUID?
        let orderStatus: String?
        let paid: Bool?
        let amountSek: Int?
        let productId: String?
        let quantity: Int?
        let rejectReason: String?
    }
    let business: Info
    let campaigns: [Campaign]
    let posts: [Post]
    let events: [Event]
    let cards: [Card]
    let pushes: [Push]
    let nextPushAt: Date?
    let pushPending: Bool
    let cardPending: Bool
    let products: [BizProduct]
    let limits: [String: Int]

    var isSubscribed: Bool { business.tier != "none" }
    var isPlus: Bool { business.tier == "plus" }
    func limit(_ key: String, _ fallback: Int) -> Int { limits[key] ?? fallback }
    func packs(_ kind: String) -> [BizProduct] { products.filter { $0.kind == kind }.sorted { $0.quantity < $1.quantity } }
    func pack(_ kind: String, _ quantity: Int) -> BizProduct? { products.first { $0.kind == kind && $0.quantity == quantity } }
    func product(_ id: String) -> BizProduct? { products.first { $0.productId == id } }
    /// Every product id, so the App Store products can be fetched in one go.
    var productIds: [String] { products.map(\.productId) }

    /// The bar as the map's `Venue`, so previews draw with the real map views.
    var venue: Venue {
        var v = Venue(id: business.venueId ?? UUID(), name: business.venueName, address: nil, city: business.venueCity,
                      lat: business.venueLat, lon: business.venueLon, createdAt: Date())
        v.country = business.venueCountry
        return v
    }
}

extension BusinessOverview.Campaign {
    /// The deal as the guest-facing offer the Deals map renders.
    func asOffer(venueId: UUID) -> VenueOffer {
        VenueOffer(id: id, venueId: venueId, kind: kind, title: title, description: description, finePrint: finePrint,
                   redeem: "show", code: nil, startMinute: startMinute, endMinute: endMinute, activeDays: activeDays,
                   placement: placement, imageUrl: imageUrl, billboardImageUrl: billboardImageUrl,
                   interstitial: false, showOnValidOnly: false)
    }
}

/// One thing to preview — which guest surface to draw, and what the button
/// under it does (nothing, pay the approved order, or submit the draft).
struct BizPreview: Identifiable {
    enum Surface { case campaign, card, push(title: String, body: String) }
    enum Action {
        case look
        case pay(orderId: UUID, productId: String?, quantity: Int, amountSek: Int)
        case submit(label: String, run: () async throws -> Void)
    }
    let id = UUID()
    let offer: VenueOffer
    let venue: Venue
    let surface: Surface
    let action: Action
    /// Unsaved artwork from the composer, shown in place of the offer's URLs.
    var poster: UIImage? = nil
    var billboard: UIImage? = nil
}

struct AdminBusinessQueue: Decodable {
    struct Biz: Decodable, Identifiable {
        let id: UUID
        let name: String
        let status: String
        let orgNumber: String?
        let contactEmail: String
        let contactPhone: String?
        let venueName: String
        let venueCity: String?
        let venueCountry: String?
        let ownerName: String?
        let ownerUsername: String?
        let createdAt: Date
        let adminNote: String?
        let tier: String?
        let tierExpiresAt: Date?
        let followers: Int?
    }
    struct Order: Decodable, Identifiable {
        let id: UUID
        let kind: String
        let status: String
        let paid: Bool
        let amountSek: Int
        let productId: String?
        let quantity: Int?
        let appleTransactionId: String?
        let paidAt: Date?
        let detail: String?
        let createdAt: Date
        let businessName: String
        let venueName: String
        let venueCity: String?
        let title: String?
        let body: String?
        let imageUrl: String?
        let billboardImageUrl: String?
        let placement: String?
        let sendAt: Date?
        let audienceCap: Int?
        let rejectReason: String?
    }
    struct Limit: Decodable, Identifiable {
        let key: String
        let value: Int
        let label: String
        var id: String { key }
    }
    let businesses: [Biz]
    let orders: [Order]
    let products: [BizProduct]
    let limits: [Limit]
}

/// The state a card / push is in, folded down from its order — and a deal's,
/// which has no order: it's live while the bar is subscribed.
struct BizState {
    let label: String
    let color: Color

    static let liveGreen = Color(red: 0.51, green: 0.72, blue: 0.48)
    static let rejectRed = Color(red: 0.85, green: 0.40, blue: 0.34)

    static func of(orderStatus: String?, paid: Bool?, live: Bool, startsAt: Date?, endsAt: Date?, done: Bool = false) -> BizState {
        switch orderStatus ?? "pending" {
        case "rejected":  return BizState(label: "REJECTED", color: rejectRed)
        case "cancelled": return BizState(label: "CANCELLED", color: Color.cream.opacity(0.4))
        case "approved":
            if paid != true { return BizState(label: "AWAITING PAYMENT", color: .whiskey) }
            if done { return BizState(label: "DONE", color: Color.cream.opacity(0.5)) }
            if live { return BizState(label: "LIVE", color: liveGreen) }
            if let s = startsAt, s > Date() { return BizState(label: "SCHEDULED", color: liveGreen) }
            if let e = endsAt, e < Date() { return BizState(label: "ENDED", color: Color.cream.opacity(0.4)) }
            return BizState(label: "LIVE", color: liveGreen)
        default:          return BizState(label: "PENDING REVIEW", color: .bronze)
        }
    }

    static func ofDeal(_ c: BusinessOverview.Campaign) -> BizState {
        if c.live { return BizState(label: "LIVE", color: liveGreen) }
        if !c.approved { return BizState(label: "PAUSED", color: .whiskey) }
        if let s = c.startsAt, s > Date() { return BizState(label: "SCHEDULED", color: liveGreen) }
        return BizState(label: "ENDED", color: Color.cream.opacity(0.4))
    }
}

struct BizError: LocalizedError {
    let code: String
    var errorDescription: String? { code }
}

// MARK: - Service

@MainActor
final class BusinessService: ObservableObject {
    @Published private(set) var mine: [BusinessSummary] = []
    @Published private(set) var overview: BusinessOverview?
    /// Display prices by product id, for the pitch before a bar is claimed.
    @Published private(set) var pitchPrices: [String: Int] = [:]
    @Published private(set) var loaded = false

    func loadMine() async {
        defer { loaded = true }
        do {
            let data = try await supabase.rpc("business_mine").execute().data
            mine = try BusinessJSON.decoder.decode([BusinessSummary].self, from: data)
        } catch {
            // keep the last list on a transient failure
        }
        struct R: Decodable { let product_id: String; let amount_sek: Int }
        if let rows: [R] = try? await supabase.from("business_products").select("product_id,amount_sek").execute().value {
            pitchPrices = Dictionary(uniqueKeysWithValues: rows.map { ($0.product_id, $0.amount_sek) })
        }
    }

    func loadOverview(_ id: UUID) async {
        struct P: Encodable { let p_business: String }
        do {
            let data = try await supabase.rpc("business_overview", params: P(p_business: id.uuidString.lowercased())).execute().data
            overview = try BusinessJSON.decoder.decode(BusinessOverview.self, from: data)
        } catch {
            // keep the last overview
        }
    }

    func register(name: String, email: String, phone: String, orgNumber: String, venue: MapKitVenueResult) async throws {
        struct P: Encodable {
            let p_business_name: String
            let p_contact_email: String
            let p_contact_phone: String?
            let p_org_number: String?
            let p_venue_external_id: String?
            let p_venue_name: String
            let p_address: String?
            let p_city: String?
            let p_lat: Double
            let p_lon: Double
            let p_country: String?
        }
        _ = try await supabase.rpc("business_register", params: P(
            p_business_name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            p_contact_email: email.trimmingCharacters(in: .whitespacesAndNewlines),
            p_contact_phone: phone.isEmpty ? nil : phone,
            p_org_number: orgNumber.isEmpty ? nil : orgNumber,
            p_venue_external_id: venue.id,
            p_venue_name: venue.name,
            p_address: venue.address,
            p_city: venue.city,
            p_lat: venue.lat,
            p_lon: venue.lon,
            p_country: venue.isoCountry
        )).execute()
        await loadMine()
        NotificationCenter.default.post(name: .sejdelReloadProfile, object: nil)
    }

    /// Artwork lives under business/<id>/ in campaign-art — the storage policy
    /// only lets an approved owner write there.
    func uploadArt(businessId: UUID, data: Data, maxDim: CGFloat = 1400) async -> String? {
        guard let jpeg = ImageDownscale.jpeg(data, maxDim: maxDim, quality: 0.72) else { return nil }
        let path = "business/\(businessId.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
        do {
            try await StorageUploader.uploadImage(bucket: "campaign-art", path: path, data: jpeg, thumbnail: false)
            return try supabase.storage.from("campaign-art").getPublicURL(path: path).absoluteString
        } catch {
            return nil
        }
    }

    /// The bar's subscription as StoreKit sees it, reported to the server
    /// (product, renewal date). nil product = no active subscription — which
    /// reverts the account, so the profile is reloaded afterwards.
    func syncSubscription(business: UUID, productId: String?, originalTransactionId: String?,
                          expiresAt: Date?, transactionId: String?, jws: String?) async throws {
        defer { NotificationCenter.default.post(name: .sejdelReloadProfile, object: nil) }
        struct P: Encodable {
            let p_business: String
            let p_product_id: String?
            let p_original_transaction_id: String?
            let p_expires_at: String?
            let p_transaction_id: String?
            let p_jws: String?
        }
        _ = try await supabase.rpc("business_sync_subscription", params: P(
            p_business: business.uuidString.lowercased(), p_product_id: productId,
            p_original_transaction_id: originalTransactionId,
            p_expires_at: expiresAt.map { ISO8601DateFormatter().string(from: $0) },
            p_transaction_id: transactionId, p_jws: jws
        )).execute()
    }

    func updateProfile(business: UUID, logoData: Data?, posterData: Data?, tagline: String?) async throws {
        var logo: String? = nil, poster: String? = nil
        if let d = logoData {
            guard let url = await uploadArt(businessId: business, data: d, maxDim: 512) else { throw BizError(code: "upload_failed") }
            logo = url
        }
        if let d = posterData {
            guard let url = await uploadArt(businessId: business, data: d) else { throw BizError(code: "upload_failed") }
            poster = url
        }
        struct P: Encodable { let p_business: String; let p_logo_url: String?; let p_poster_url: String?; let p_tagline: String? }
        _ = try await supabase.rpc("business_update_profile", params: P(
            p_business: business.uuidString.lowercased(), p_logo_url: logo, p_poster_url: poster, p_tagline: tagline
        )).execute()
        await loadOverview(business)
    }

    func createDeal(
        business: UUID, kind: String, title: String, description: String, finePrint: String,
        startsAt: Date, endsAt: Date, activeDays: [Int]?, startMinute: Int?, endMinute: Int?,
        posterData: Data?, showOnValidOnly: Bool
    ) async throws {
        var poster: String? = nil
        if let d = posterData {
            guard let url = await uploadArt(businessId: business, data: d) else { throw BizError(code: "upload_failed") }
            poster = url
        }
        struct P: Encodable {
            let p_business: String
            let p_kind: String
            let p_title: String
            let p_description: String?
            let p_fine_print: String?
            let p_starts_at: String
            let p_ends_at: String
            let p_active_days: [Int]?
            let p_start_minute: Int?
            let p_end_minute: Int?
            let p_image_url: String?
            let p_show_on_valid_only: Bool
        }
        let iso = ISO8601DateFormatter()
        _ = try await supabase.rpc("business_create_deal", params: P(
            p_business: business.uuidString.lowercased(), p_kind: kind,
            p_title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            p_description: description.isEmpty ? nil : description,
            p_fine_print: finePrint.isEmpty ? nil : finePrint,
            p_starts_at: iso.string(from: startsAt), p_ends_at: iso.string(from: endsAt),
            p_active_days: activeDays, p_start_minute: startMinute, p_end_minute: endMinute,
            p_image_url: poster, p_show_on_valid_only: showOnValidOnly
        )).execute()
        await loadOverview(business)
    }

    func endDeal(_ offerId: UUID, business: UUID) async throws {
        struct P: Encodable { let p_offer: String }
        _ = try await supabase.rpc("business_end_deal", params: P(p_offer: offerId.uuidString.lowercased())).execute()
        await loadOverview(business)
    }

    /// One picture, or a slideshow on Business+ (the server enforces which).
    func createPost(business: UUID, images: [Data], ratio: CGFloat, caption: String, eventAt: Date?, offerId: UUID?) async throws {
        var urls: [String] = []
        for d in images {
            guard let url = await uploadArt(businessId: business, data: d) else { throw BizError(code: "upload_failed") }
            urls.append(url)
        }
        struct P: Encodable {
            let p_business: String
            let p_image_urls: [String]
            let p_image_ratio: Double
            let p_caption: String?
            let p_event_at: String?
            let p_offer: String?
        }
        _ = try await supabase.rpc("business_create_post", params: P(
            p_business: business.uuidString.lowercased(), p_image_urls: urls, p_image_ratio: Double(ratio),
            p_caption: caption.isEmpty ? nil : caption,
            p_event_at: eventAt.map { ISO8601DateFormatter().string(from: $0) },
            p_offer: offerId?.uuidString.lowercased()
        )).execute()
        await loadOverview(business)
    }

    func createEvent(business: UUID, title: String, startsAt: Date, imageData: Data?, ratio: CGFloat = 1) async throws {
        var url: String? = nil
        if let d = imageData {
            guard let u = await uploadArt(businessId: business, data: d) else { throw BizError(code: "upload_failed") }
            url = u
        }
        struct P: Encodable {
            let p_business: String; let p_title: String; let p_starts_at: String; let p_image_url: String?; let p_image_ratio: Double
        }
        _ = try await supabase.rpc("business_create_event", params: P(
            p_business: business.uuidString.lowercased(), p_title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            p_starts_at: ISO8601DateFormatter().string(from: startsAt), p_image_url: url, p_image_ratio: Double(ratio)
        )).execute()
        await loadOverview(business)
    }

    func cancelEvent(_ id: UUID, business: UUID) async throws {
        struct P: Encodable { let p_event: String }
        _ = try await supabase.rpc("business_cancel_event", params: P(p_event: id.uuidString.lowercased())).execute()
        await loadOverview(business)
    }

    /// Mint (or fetch) the bar's table QR token.
    func qrToken(business: UUID) async throws -> String {
        struct P: Encodable { let p_business: String }
        let data = try await supabase.rpc("business_qr_token", params: P(p_business: business.uuidString.lowercased())).execute().data
        let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))
        guard !raw.isEmpty else { throw BizError(code: "bad_response") }
        await loadOverview(business)
        return raw
    }

    func deletePost(_ id: UUID, business: UUID) async throws {
        struct P: Encodable { let p_post: String }
        _ = try await supabase.rpc("business_delete_post", params: P(p_post: id.uuidString.lowercased())).execute()
        await loadOverview(business)
    }

    /// Reserve a boost for a post (unpaid). Pay it through BusinessStore.
    func createBoost(post: UUID, productId: String) async throws -> UUID {
        struct P: Encodable { let p_post: String; let p_product_id: String }
        let data = try await supabase.rpc("business_create_boost", params: P(
            p_post: post.uuidString.lowercased(), p_product_id: productId
        )).execute().data
        let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))
        guard let id = UUID(uuidString: raw) else { throw BizError(code: "bad_response") }
        return id
    }

    func cancelBoost(_ id: UUID) async throws {
        struct P: Encodable { let p_boost: String }
        _ = try await supabase.rpc("business_cancel_boost", params: P(p_boost: id.uuidString.lowercased())).execute()
    }

    func requestCard(business: UUID, offer: UUID, cap: Int) async throws {
        struct P: Encodable { let p_business: String; let p_offer: String; let p_audience_cap: Int }
        _ = try await supabase.rpc("business_request_card", params: P(
            p_business: business.uuidString.lowercased(), p_offer: offer.uuidString.lowercased(), p_audience_cap: cap
        )).execute()
        await loadOverview(business)
    }

    func requestPush(business: UUID, offer: UUID, title: String, body: String, cap: Int, sendAt: Date) async throws {
        struct P: Encodable {
            let p_business: String; let p_offer: String; let p_title: String; let p_body: String
            let p_audience_cap: Int; let p_send_at: String
        }
        _ = try await supabase.rpc("business_request_push", params: P(
            p_business: business.uuidString.lowercased(), p_offer: offer.uuidString.lowercased(),
            p_title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            p_body: body.trimmingCharacters(in: .whitespacesAndNewlines),
            p_audience_cap: cap, p_send_at: ISO8601DateFormatter().string(from: sendAt)
        )).execute()
        await loadOverview(business)
    }

    func cancelOrder(_ id: UUID, business: UUID) async throws {
        struct P: Encodable { let p_order: String }
        _ = try await supabase.rpc("business_cancel_order", params: P(p_order: id.uuidString.lowercased())).execute()
        await loadOverview(business)
    }

    /// The RPCs raise short codes; turn them into something a bar owner can act on.
    static func friendly(_ error: Error) -> String {
        let s = String(describing: error)
        func has(_ code: String) -> Bool { s.contains(code) }
        if let r = s.range(of: "push_cooldown:") {
            let iso = String(s[r.upperBound...].prefix(20))
            if let d = BusinessJSON.parseDate(iso) {
                return "One push per week. Next one from \(d.formatted(date: .abbreviated, time: .shortened))."
            }
            return "One push per week — your next slot isn't open yet."
        }
        if has("already_business") { return "This account is already a business account." }
        if has("too_many_images") { return "Up to ten pictures in a slideshow." }
        if has("no_event") { return "That event is gone." }
        if has("subscription_required") { return "Subscribe to Sejdel Business first." }
        if has("plus_required") { return "That's a Business+ feature." }
        if has("boost_pending") { return "This post already has a boost running." }
        if has("boost_not_pending") { return "That boost was already paid or cancelled." }
        if has("no_post") || has("no_boost") { return "That post is gone." }
        if has("not_approved") { return "Your bar isn't approved yet — we'll email you when it is." }
        if has("not_owner") { return "That bar isn't yours." }
        if has("venue_taken") { return "That bar is already claimed. If it's yours, email contact@sejdel.com." }
        if has("email_invalid") { return "That email doesn't look right." }
        if has("name_required") { return "Add the business name." }
        if has("venue_required") { return "Pick the bar on the map." }
        if has("too_many_campaigns") { return "That's your limit of live deals — Business runs one, Business+ several. End one first." }
        if has("too_many") { return "You've claimed the maximum number of bars." }
        if has("image_required") { return "Add a photo first." }
        if has("end_required") || has("window_invalid") { return "Set when the deal ends." }
        if has("window_past") { return "That window is already over." }
        if has("too_long_window") { return "Deals run up to 90 days at a time." }
        if has("too_long") { return "Shorten the text." }
        if has("card_pending") { return "You already have a card pending or live. One at a time." }
        if has("push_pending") { return "You already have a push waiting to go out." }
        if has("cap_range") { return "Pick one of the packs." }
        if has("not_approved_order") { return "This order hasn't been approved yet — pay once it is." }
        if has("product_mismatch") { return "That purchase doesn't match. Email contact@sejdel.com." }
        if has("transaction_used") { return "That purchase is already used." }
        if has("no_product") { return "That isn't on sale right now." }
        if has("quiet_hours") { return "Pushes don't go out 04:00–10:00. Pick another time." }
        if has("send_at_range") { return "Schedule the push within the next 30 days." }
        if has("no_offer") { return "Pick one of your deals first." }
        if has("empty") { return "Add a title and a message." }
        if has("upload_failed") { return "Upload failed — try a smaller image." }
        if has("bad_kind") || has("bad_placement") { return "Something's off with the form. Try again." }
        return "Couldn't save. Check your connection and try again."
    }
}

@MainActor
final class BusinessAdminService: ObservableObject {
    @Published private(set) var queue: AdminBusinessQueue?
    @Published var toast: String?

    func load() async {
        do {
            let data = try await supabase.rpc("admin_business_queue").execute().data
            queue = try BusinessJSON.decoder.decode(AdminBusinessQueue.self, from: data)
        } catch {
            toast = "Couldn't load the queue."
        }
    }

    func setStatus(_ id: UUID, _ status: String, note: String?) async {
        struct P: Encodable { let p_business: String; let p_status: String; let p_note: String? }
        do {
            _ = try await supabase.rpc("admin_business_set_status", params: P(
                p_business: id.uuidString.lowercased(), p_status: status, p_note: note?.isEmpty == true ? nil : note
            )).execute()
            toast = "Business \(status)."
            await load()
        } catch { toast = BusinessService.friendly(error) }
    }

    func decide(_ id: UUID, _ action: String, reason: String? = nil) async {
        struct P: Encodable { let p_order: String; let p_action: String; let p_reason: String? }
        do {
            _ = try await supabase.rpc("admin_order_decide", params: P(
                p_order: id.uuidString.lowercased(), p_action: action, p_reason: reason
            )).execute()
            toast = action == "paid" ? "Marked paid — it's live." : "Order \(action)d."
            await load()
        } catch { toast = BusinessService.friendly(error) }
    }

    func setPrice(_ productId: String, _ amount: Int) async {
        struct P: Encodable { let p_product_id: String; let p_amount: Int }
        _ = try? await supabase.rpc("admin_set_business_product_price", params: P(p_product_id: productId, p_amount: amount)).execute()
        await load()
    }

    func setLimit(_ key: String, _ value: Int) async {
        struct P: Encodable { let p_key: String; let p_value: Int }
        _ = try? await supabase.rpc("admin_set_business_limit", params: P(p_key: key, p_value: value)).execute()
        await load()
    }
}

// MARK: - App Store

/// Everything a bar buys goes through here. The two tiers are auto-renewing
/// subscriptions (the business id rides along as the app account token and
/// the verified state is reported to the server); boosts, cards and pushes
/// are consumables recorded against their boost / order before they're
/// finished, so an interrupted purchase is matched up when StoreKit
/// redelivers it.
@MainActor
final class BusinessStore: ObservableObject {
    static let shared = BusinessStore()
    @Published private(set) var products: [String: Product] = [:]

    enum PayResult: Equatable { case paid, cancelled, pending, failed(String) }

    func load(ids: [String]) async {
        let missing = (ids + BizTier.ids).filter { products[$0] == nil }
        guard !missing.isEmpty, let got = try? await Product.products(for: missing) else { return }
        for p in got { products[p.id] = p }
    }

    /// Localised App Store price when loaded, else the server's SEK figure.
    func displayPrice(_ productId: String?, quantity: Int = 1, fallbackSek: Int) -> String {
        if let productId, let p = products[productId] {
            if quantity <= 1 { return p.displayPrice }
            return (p.price * Decimal(quantity)).formatted(p.priceFormatStyle)
        }
        return "\(fallbackSek.formatted()) kr"
    }

    private func product(_ id: String) async -> Product? {
        if let p = products[id] { return p }
        if let p = try? await Product.products(for: [id]).first { products[id] = p; return p }
        return nil
    }

    // ── subscriptions ──

    /// Subscribe (or switch tier — same group, StoreKit handles the upgrade).
    func subscribe(business: UUID, productId: String) async -> PayResult {
        guard let product = await product(productId) else { return .failed("That plan isn't in the App Store yet — try again later.") }
        do {
            switch try await product.purchase(options: [.appAccountToken(business)]) {
            case .success(let verification):
                guard case .verified(let txn) = verification else { return .failed("Apple couldn't verify the purchase.") }
                do {
                    try await report(business: business, txn, jws: verification.jwsRepresentation)
                } catch {
                    return .failed(BusinessService.friendly(error))
                }
                await txn.finish()
                return .paid
            case .userCancelled: return .cancelled
            case .pending: return .pending
            @unknown default: return .failed("The purchase didn't complete.")
            }
        } catch {
            return .failed("The purchase didn't complete. \(error.localizedDescription)")
        }
    }

    /// Re-check StoreKit's current entitlements for these bars and report
    /// them — on open, after "restore", and when a renewal lands. Only what
    /// StoreKit positively knows is reported: an empty answer (sandbox
    /// hiccup, a bar set up outside StoreKit) must never read as "cancelled"
    /// and revert an account. Lapses are the server's call, from the renewal
    /// date it was given.
    func syncSubscriptions(for businesses: [UUID]) async {
        guard !businesses.isEmpty else { return }
        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let txn) = entitlement, BizTier.ids.contains(txn.productID), txn.revocationDate == nil else { continue }
            let business = txn.appAccountToken.flatMap { businesses.contains($0) ? $0 : nil } ?? businesses[0]
            try? await report(business: business, txn, jws: entitlement.jwsRepresentation)
        }
    }

    private func report(business: UUID, _ txn: StoreKit.Transaction, jws: String) async throws {
        try await BusinessService().syncSubscription(
            business: business, productId: txn.productID, originalTransactionId: String(txn.originalID),
            expiresAt: txn.expirationDate, transactionId: String(txn.id), jws: jws)
    }

    // ── consumables ──

    /// Pay an approved card / push order.
    func pay(orderId: UUID, productId: String, quantity: Int) async -> PayResult {
        guard let product = await product(productId) else { return .failed("This pack isn't in the App Store yet — try again later.") }
        var options: Set<Product.PurchaseOption> = [.appAccountToken(orderId)]
        if quantity > 1 { options.insert(.quantity(quantity)) }
        return await buy(product, options: options) { txn, jws in
            try await self.recordOrder(orderId: orderId, txn, jws: jws)
        }
    }

    /// Pay a reserved boost; it goes live the moment it's recorded.
    func payBoost(boostId: UUID, productId: String) async -> PayResult {
        guard let product = await product(productId) else { return .failed("This boost isn't in the App Store yet — try again later.") }
        return await buy(product, options: [.appAccountToken(boostId)]) { txn, jws in
            try await self.recordBoost(boostId: boostId, txn, jws: jws)
        }
    }

    private func buy(_ product: Product, options: Set<Product.PurchaseOption>,
                     record: (StoreKit.Transaction, String) async throws -> Void) async -> PayResult {
        do {
            switch try await product.purchase(options: options) {
            case .success(let verification):
                guard case .verified(let txn) = verification else { return .failed("Apple couldn't verify the purchase.") }
                do {
                    try await record(txn, verification.jwsRepresentation)
                } catch {
                    // Leave it unfinished: StoreKit redelivers it and recover() retries.
                    return .failed(BusinessService.friendly(error))
                }
                await txn.finish()
                return .paid
            case .userCancelled: return .cancelled
            case .pending: return .pending
            @unknown default: return .failed("The purchase didn't complete.")
            }
        } catch {
            return .failed("The purchase didn't complete. \(error.localizedDescription)")
        }
    }

    /// A business transaction StoreKit redelivered (interrupted purchase, a
    /// renewal, or the record call failed last time). Match it up and finish.
    func recover(_ txn: StoreKit.Transaction, jws: String) async {
        if BizTier.ids.contains(txn.productID) {
            var business = txn.appAccountToken
            if business == nil {
                let svc = BusinessService()
                await svc.loadMine()
                business = svc.mine.first?.id
            }
            if let business, (try? await report(business: business, txn, jws: jws)) != nil {
                await txn.finish()
            }
            return
        }
        guard let token = txn.appAccountToken else { return }
        if txn.productID.hasPrefix("sejdel.biz.boost.") {
            if (try? await recordBoost(boostId: token, txn, jws: jws)) != nil { await txn.finish() }
        } else if (try? await recordOrder(orderId: token, txn, jws: jws)) != nil {
            await txn.finish()
        }
    }

    private func recordOrder(orderId: UUID, _ txn: StoreKit.Transaction, jws: String) async throws {
        struct P: Encodable {
            let p_order: String
            let p_transaction_id: String
            let p_product_id: String
            let p_original_transaction_id: String?
            let p_jws: String?
        }
        _ = try await supabase.rpc("business_mark_paid", params: P(
            p_order: orderId.uuidString.lowercased(), p_transaction_id: String(txn.id),
            p_product_id: txn.productID, p_original_transaction_id: String(txn.originalID), p_jws: jws
        )).execute()
    }

    private func recordBoost(boostId: UUID, _ txn: StoreKit.Transaction, jws: String) async throws {
        struct P: Encodable {
            let p_boost: String
            let p_transaction_id: String
            let p_product_id: String
            let p_original_transaction_id: String?
            let p_jws: String?
        }
        _ = try await supabase.rpc("business_boost_paid", params: P(
            p_boost: boostId.uuidString.lowercased(), p_transaction_id: String(txn.id),
            p_product_id: txn.productID, p_original_transaction_id: String(txn.originalID), p_jws: jws
        )).execute()
    }
}

// MARK: - Sponsored app-open cards (user side)

/// The paid app-open card. The server picks one card for this person (city
/// radius, never twice, at most one a day) and reserves the slot; the app just
/// shows it through the same InterstitialView as the free promo.
enum SponsoredCards {
    static let optOutKey = "sesh.sponsoredCards.optOut.v1"

    struct Hit {
        let cardId: UUID
        let offer: VenueOffer
        let venue: Venue
    }

    private struct Payload: Decodable {
        let card_id: UUID
        let offer: VenueOffer
        let venue: Venue
    }

    static func setOptOut(_ off: Bool) {
        UserDefaults.standard.set(off, forKey: optOutKey)
        struct P: Encodable { let p_off: Bool }
        Task { _ = try? await supabase.rpc("set_sponsored_cards_opt_out", params: P(p_off: off)).execute() }
    }

    static func claim(near loc: CLLocation) async -> Hit? {
        guard !UserDefaults.standard.bool(forKey: optOutKey) else { return nil }
        struct P: Encodable { let p_lat: Double; let p_lon: Double }
        // Coarse, like the deal-push location: ~1 km is all the radius check needs.
        let lat = (loc.coordinate.latitude * 100).rounded() / 100
        let lon = (loc.coordinate.longitude * 100).rounded() / 100
        // A JSON `null` means nothing for you today; a decode failure is the same.
        let value: Payload?? = try? await supabase.rpc("claim_sponsored_card", params: P(p_lat: lat, p_lon: lon)).execute().value
        guard let p = value ?? nil else { return nil }
        return Hit(cardId: p.card_id, offer: p.offer, venue: p.venue)
    }

    static func tapped(_ cardId: UUID) {
        struct P: Encodable { let p_card: String }
        Task { _ = try? await supabase.rpc("sponsored_card_tapped", params: P(p_card: cardId.uuidString.lowercased())).execute() }
    }
}

// MARK: - Shared bits

func kicker(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .tracking(2.0)
        .foregroundStyle(Color.bronze)
}

private func bizKindLabel(_ k: String) -> String {
    switch k {
    case "happy_hour": return "Happy hour"
    case "free_entry": return "Free entry"
    case "bundle":     return "Bundle"
    case "event":      return "Event"
    default:           return "Price deal"
    }
}

private func kr(_ n: Int) -> String { "\(n.formatted()) kr" }

struct BizCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.cream.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.cream.opacity(0.08), lineWidth: 1))
    }
}

private struct StatusPill: View {
    let state: BizState
    var body: some View {
        Text(state.label)
            .font(.system(size: 8, weight: .black, design: .monospaced))
            .tracking(1.0)
            .foregroundStyle(state.color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(state.color.opacity(0.14)))
    }
}

private struct BizField: View {
    let label: String
    @Binding var text: String
    let placeholder: String
    var multiline = false
    var keyboard: UIKeyboardType = .default
    var limit: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                kicker(label)
                Spacer()
                if let limit {
                    Text("\(text.count)/\(limit)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(text.count > limit ? BizState.rejectRed : Color.cream.opacity(0.35))
                }
            }
            TextField("", text: $text,
                      prompt: Text(placeholder).foregroundStyle(Color.cream.opacity(0.35)),
                      axis: multiline ? .vertical : .horizontal)
                .lineLimit(multiline ? 1...4 : 1...1)
                .keyboardType(keyboard)
                .textInputAutocapitalization(keyboard == .emailAddress ? .never : .sentences)
                .autocorrectionDisabled(keyboard == .emailAddress)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.cream)
                .tint(Color.whiskey)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.cream.opacity(0.05)))
        }
    }
}

struct BizPrimaryButton: View {
    let title: String
    var enabled = true
    var busy = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy { ProgressView().tint(Color.ink) }
                Text(busy ? "SENDING…" : title)
                    .font(.system(size: 13, weight: .black, design: .monospaced))
                    .tracking(1.8)
            }
            .foregroundStyle(Color.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(enabled && !busy ? Color.whiskey : Color.cream.opacity(0.12)))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!enabled || busy)
    }
}

struct BizSecondaryButton: View {
    let title: String
    let icon: String
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Text(title)
                    .font(.system(size: 13, weight: .black, design: .monospaced))
                    .tracking(1.4)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.bronze)
            }
            .foregroundStyle(enabled ? Color.whiskey : Color.cream.opacity(0.35))
            .padding(.vertical, 13).padding(.horizontal, 16)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.whiskey.opacity(enabled ? 0.08 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.whiskey.opacity(enabled ? 0.3 : 0.12), lineWidth: 1))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!enabled)
    }
}

private struct SheetHeader: View {
    let eyebrow: String
    let title: String
    let onClose: () -> Void
    /// The pitch: a headline, not a sheet title.
    var big = false
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                if !eyebrow.isEmpty { kicker(eyebrow) }
                Text(title)
                    .font(.system(size: big ? 34 : 26, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.6))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.cream.opacity(0.06)))
            }
            .buttonStyle(PressScaleStyle())
        }
    }
}

struct ErrorLine: View {
    let text: String?
    var body: some View {
        if let text {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(BizState.rejectRed)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Plans

/// One plan, sold big: what the bar gets, in plain words. The pitch shows
/// it without a button; the dashboard with SUBSCRIBE.
private struct PlanCard: View {
    let plus: Bool
    let price: String
    var cta: String? = nil
    var busy = false
    var enabled = true
    var action: () -> Void = {}

    private var name: String { plus ? "Sejdel Business+" : "Sejdel Business" }
    private var headline: String { plus ? "Own the night." : "Be where the night starts." }
    private var perks: [(icon: String, text: String)] {
        plus ? [
            ("checkmark.seal.fill", "Everything in Business."),
            ("photo.fill", "Poster, not a pin. Your photo on the map — impossible to miss."),
            ("bolt.fill", "Boost a post. Sponsored in every feed nearby, and a billboard on the map."),
            ("bell.badge.fill", "Push it. A notification to your city every time you drop a deal."),
            ("square.stack.3d.up.fill", "Several deals live at once, on your profile and your poster."),
            ("rectangle.portrait.on.rectangle.portrait.angled.fill", "App-open card. Full screen the moment someone nearby opens the app."),
        ] : [
            ("mappin.and.ellipse", "On the map. A pin at your bar with your deal, for everyone nearby."),
            ("person.2.fill", "A profile people follow. Your posts land straight in their feed."),
            ("chart.line.uptrend.xyaxis", "Build your crowd. Followers, views and taps, all in one place."),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .foregroundStyle(plus ? Color.whiskey : Color.cream)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(price)
                        .font(.system(size: 22, weight: .black, design: .rounded))
                        .foregroundStyle(Color.cream)
                    Text("/ month")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.5))
                }
            }
            Text(headline)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.9))
            VStack(alignment: .leading, spacing: 12) {
                ForEach(perks, id: \.text) { perk in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: perk.icon)
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.whiskey)
                            .frame(width: 26)
                        Text(perk.text)
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.9))
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let cta {
                BizPrimaryButton(title: cta, enabled: enabled, busy: busy, action: action)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(plus ? Color.whiskey.opacity(0.09) : Color.cream.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(plus ? Color.whiskey.opacity(0.4) : Color.cream.opacity(0.1), lineWidth: 1))
    }
}

// MARK: - Hub (owner entry point)

/// "Sejdel for Business" from the profile: claim a bar, or run the one you have.
struct BusinessHubView: View {
    @StateObject private var svc = BusinessService()
    @State private var registerOpen = false
    @State private var selected: UUID?
    @Environment(\.dismiss) private var dismiss

    private var current: BusinessSummary? {
        svc.mine.first { $0.id == selected } ?? svc.mine.first
    }

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    SheetHeader(eyebrow: svc.mine.isEmpty ? "" : "SEJDEL FOR BUSINESS",
                                title: svc.mine.isEmpty ? "Get your bar on the map." : (current?.name ?? "Your bar"),
                                onClose: { dismiss() }, big: svc.mine.isEmpty)
                    if !svc.loaded {
                        ProgressView().tint(Color.whiskey).frame(maxWidth: .infinity).padding(.vertical, 40)
                    } else if svc.mine.isEmpty {
                        pitch
                        BizPrimaryButton(title: "CLAIM YOUR BAR") { registerOpen = true }
                        howItWorks
                    } else {
                        if svc.mine.count > 1 { businessPicker }
                        if let b = current {
                            BusinessDashboard(summary: b, svc: svc)
                        }
                        Button { registerOpen = true } label: {
                            Text("Claim another bar")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.cream.opacity(0.5))
                                .underline()
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                    }
                    Spacer(minLength: 24)
                }
                .padding(20)
            }
        }
        .preferredColorScheme(.dark)
        .task { await svc.loadMine() }
        // StoreKit is the source of truth for the subscription — report it
        // every time the hub opens so a renewal or lapse shows up.
        .task(id: svc.mine.map(\.id)) {
            let ids = svc.mine.filter { $0.status == "approved" }.map(\.id)
            guard !ids.isEmpty else { return }
            await BusinessStore.shared.syncSubscriptions(for: ids)
            await svc.loadMine()
        }
        .sheet(isPresented: $registerOpen) {
            BusinessRegisterSheet(svc: svc) { registerOpen = false }
                .presentationBackground(Color.ink)
        }
    }

    private var businessPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(svc.mine) { b in
                    let on = b.id == current?.id
                    Button { selected = b.id } label: {
                        Text(b.venueName.uppercased())
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                            .tracking(1.2)
                            .foregroundStyle(on ? Color.ink : Color.cream.opacity(0.7))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Capsule().fill(on ? Color.whiskey : Color.cream.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var pitch: some View {
        VStack(alignment: .leading, spacing: 14) {
            PlanCard(plus: false, price: kr(svc.pitchPrices[BizTier.business] ?? 299))
            PlanCard(plus: true, price: kr(svc.pitchPrices[BizTier.plus] ?? 899))
        }
    }

    private func pitchRow(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(Color.whiskey)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(Color.cream)
                Text(text)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.whiskey.opacity(0.06)))
    }

    private var howItWorks: some View {
        BizCard {
            kicker("HOW IT WORKS")
            rule("1", "Claim your bar — we verify it.")
            rule("2", "Subscribe — you're on the map.")
            rule("3", "Post, run deals, boost.")
        }
    }

    private func rule(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(n)
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .foregroundStyle(Color.ink)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.whiskey))
            Text(text)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Register

/// Claim a bar: who you are + which bar on the map. Lands as "pending" for an
/// admin to verify.
private struct BusinessRegisterSheet: View {
    @ObservedObject var svc: BusinessService
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    @StateObject private var location = LocationService()
    @StateObject private var search = MapKitVenueSearch()
    @State private var query = ""
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var selected: MapKitVenueResult?

    @State private var name = ""
    @State private var email = supabase.auth.currentUser?.email ?? ""
    @State private var phone = ""
    @State private var org = ""
    @State private var saving = false
    @State private var error: String?

    private var canSubmit: Bool {
        selected != nil && !name.trimmingCharacters(in: .whitespaces).isEmpty && email.contains("@") && !saving
    }

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    SheetHeader(eyebrow: "CLAIM YOUR BAR", title: "Which bar is yours?", onClose: { dismiss() })
                    venuePicker
                    if selected != nil {
                        BizField(label: "BUSINESS NAME", text: $name, placeholder: "Bar Bistro Nord AB")
                        BizField(label: "CONTACT EMAIL", text: $email, placeholder: "you@yourbar.se", keyboard: .emailAddress)
                        BizField(label: "PHONE (optional)", text: $phone, placeholder: "+46 70 …", keyboard: .phonePad)
                        BizField(label: "ORG. NUMBER (optional, speeds up review)", text: $org, placeholder: "556677-8899", keyboard: .numbersAndPunctuation)
                        Text("We verify every claim before anything goes live — usually the same day. One business per bar.")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.5))
                            .fixedSize(horizontal: false, vertical: true)
                        ErrorLine(text: error)
                        BizPrimaryButton(title: "SEND FOR REVIEW", enabled: canSubmit, busy: saving, action: submit)
                    }
                    Spacer(minLength: 24)
                }
                .padding(20)
            }
        }
        .preferredColorScheme(.dark)
        .task { location.requestAccess() }
        .task(id: query) {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            search.search(query: query, origin: location.location)
        }
    }

    @ViewBuilder
    private var venuePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            kicker("THE BAR")
            if let v = selected {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(v.name)
                            .font(.system(size: 16, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color.cream)
                        if let a = v.address {
                            Text(a)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.cream.opacity(0.55))
                        }
                    }
                    Spacer()
                    Button("Change") { withAnimation { selected = nil } }
                        .font(.system(size: 12, weight: .black, design: .monospaced))
                        .foregroundStyle(Color.whiskey)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.whiskey.opacity(0.1)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.whiskey.opacity(0.4), lineWidth: 1))
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color.cream.opacity(0.5))
                    TextField("Search your bar…", text: $query)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream)
                        .tint(Color.whiskey)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cream.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.cream.opacity(0.1), lineWidth: 1))

                Map(position: $camera) {
                    UserAnnotation()
                    ForEach(search.results) { r in
                        Annotation(r.name, coordinate: r.coordinate) {
                            ZStack {
                                Circle().fill(Color.whiskey).frame(width: 30, height: 30)
                                    .shadow(color: Color.whiskey.opacity(0.6), radius: 5)
                                Image(systemName: "mappin").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(Color.ink)
                            }
                            .onTapGesture { withAnimation { selected = r } }
                        }
                    }
                }
                .mapStyle(.standard(elevation: .flat, pointsOfInterest: .including([.nightlife, .restaurant, .brewery, .winery])))
                .frame(height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                ForEach(search.results.prefix(6)) { r in
                    Button { withAnimation { selected = r } } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "mappin.circle.fill").font(.system(size: 16, design: .rounded)).foregroundStyle(Color.whiskey)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.name).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(Color.cream).lineLimit(1)
                                if let a = r.address {
                                    Text(a).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Color.cream.opacity(0.5)).lineLimit(1)
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.cream.opacity(0.03)))
                    }
                    .buttonStyle(PressScaleStyle())
                }
            }
        }
    }

    private func submit() {
        guard let venue = selected else { return }
        saving = true; error = nil
        Task {
            do {
                try await svc.register(name: name, email: email, phone: phone, orgNumber: org, venue: venue)
                onDone(); dismiss()
            } catch {
                self.error = BusinessService.friendly(error)
            }
            saving = false
        }
    }
}

// MARK: - Dashboard

struct BusinessDashboard: View {
    let summary: BusinessSummary
    @ObservedObject var svc: BusinessService
    /// One slice (from the ☰ tools) instead of the whole thing.
    var tool: BizTool? = nil
    @State private var mintingQR = false
    @State private var qrError: String?
    @State private var upgradeOpen = false

    @ObservedObject private var store = BusinessStore.shared
    @State private var dealOpen = false
    @State private var postOpen = false
    @State private var cardOpen = false
    @State private var pushOpen = false
    @State private var boosting: BusinessOverview.Post?
    @State private var cancelling: UUID?
    @State private var ending: UUID?
    @State private var deleting: UUID?
    @State private var preview: BizPreview?
    @State private var subscribing: String?
    @State private var subscribeNote: String?
    // profile editor
    @State private var logoItem: PhotosPickerItem?
    @State private var logoData: Data?
    @State private var posterItem: PhotosPickerItem?
    @State private var posterData: Data?
    @State private var tagline = ""
    @State private var taglineSeeded = false
    @State private var savingProfile = false
    @State private var profileError: String?
    @Environment(\.openURL) private var openURL

    private var ov: BusinessOverview? { svc.overview?.business.id == summary.id ? svc.overview : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let tool {
                if summary.status != "approved" {
                    statusCard
                } else if let ov {
                    toolBody(tool, ov)
                } else {
                    ProgressView().tint(Color.whiskey).frame(maxWidth: .infinity).padding(.vertical, 30)
                }
            } else {
                statusCard
                if summary.status == "approved" {
                    if let ov {
                        if ov.isSubscribed {
                            tierCard(ov)
                            statStrip(ov)
                            profileCard(ov)
                            postsSection(ov)
                            dealsSection(ov)
                            cardSection(ov)
                            pushSection(ov)
                            qrSection(ov)
                            rulesCard(ov)
                        } else {
                            subscribeCard(ov)
                        }
                    } else {
                        ProgressView().tint(Color.whiskey).frame(maxWidth: .infinity).padding(.vertical, 30)
                    }
                }
            }
        }
        .task(id: summary.id) { await svc.loadOverview(summary.id) }
        .task(id: ov?.productIds ?? []) { if let ov { await store.load(ids: ov.productIds) } }
        .onChange(of: ov?.business.tagline) { _, t in if !taglineSeeded || logoData == nil && posterData == nil { tagline = t ?? ""; taglineSeeded = true } }
        .onChange(of: logoItem) { _, item in
            guard let item else { return }
            Task { logoData = try? await item.loadTransferable(type: Data.self) }
        }
        .modifier(DashboardSheets(svc: svc, overview: ov, dealOpen: $dealOpen, postOpen: $postOpen,
                                  cardOpen: $cardOpen, pushOpen: $pushOpen, boosting: $boosting, preview: $preview,
                                  upgradeOpen: $upgradeOpen,
                                  reload: { Task { await svc.loadOverview(summary.id) } }))
    }

    /// One tool at a time. Anything but the plan needs a subscription first.
    @ViewBuilder
    private func toolBody(_ tool: BizTool, _ ov: BusinessOverview) -> some View {
        if !ov.isSubscribed {
            subscribeCard(ov)
        } else {
            switch tool {
            case .profile: profileCard(ov)
            case .plan:    tierCard(ov)
            case .stats:   statsBody(ov)
            case .deals:   dealsSection(ov)
            case .boost:   boostBody(ov)
            case .card:    cardSection(ov)
            case .push:    pushSection(ov)
            case .qr:      qrSection(ov)
            }
        }
    }

    // ── stats ──
    private func statsBody(_ ov: BusinessOverview) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            statStrip(ov)
            if !ov.campaigns.isEmpty {
                kicker("DEALS")
                ForEach(ov.campaigns) { c in
                    BizCard {
                        Text(c.title).font(.system(size: 15, weight: .heavy, design: .rounded)).foregroundStyle(Color.cream)
                        Text("\(c.weekImpressions) views · \(c.weekTaps) taps this week   ·   \(c.impressions) · \(c.taps) all time")
                            .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(Color.cream.opacity(0.6))
                    }
                }
            }
            let boosted = ov.posts.filter { $0.boost != nil && $0.boost?.status != "pending" }
            if !boosted.isEmpty {
                kicker("BOOSTS")
                ForEach(boosted) { p in
                    if let b = p.boost {
                        BizCard {
                            Text(p.caption ?? "Photo").font(.system(size: 15, weight: .heavy, design: .rounded)).foregroundStyle(Color.cream).lineLimit(1)
                            Text("\(b.views.formatted()) of \(b.goalViews.formatted()) views · \(b.taps) taps · \(b.status == "done" ? "done" : "running")")
                                .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(Color.cream.opacity(0.6))
                            ProgressView(value: Double(min(b.views, b.goalViews)), total: Double(max(b.goalViews, 1))).tint(Color.whiskey)
                        }
                    }
                }
            }
            if ov.campaigns.isEmpty && boosted.isEmpty {
                Text("Numbers show up here once a deal is on the map or a post is boosted.")
                    .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(Color.cream.opacity(0.5))
            }
        }
    }

    // ── boost: pick a post ──
    private func boostBody(_ ov: BusinessOverview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sponsored in every feed nearby, and a billboard on the Deals map, until it hits the views you buy.")
                .font(.system(size: 15, weight: .medium, design: .rounded)).foregroundStyle(Color.cream.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
            if ov.posts.isEmpty {
                Text("Post something first — it's the post that gets boosted.")
                    .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(Color.cream.opacity(0.5))
            }
            ForEach(ov.posts) { p in
                BizCard {
                    HStack(alignment: .top, spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.smoke)
                            if let u = URL(string: p.imageUrl) {
                                DownsampledAsyncImage(url: u, targetPoints: 120, fill: true, placeholder: Color.smoke)
                            }
                        }
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(p.caption ?? "Photo")
                                .font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(Color.cream).lineLimit(2)
                            Text(p.createdAt.formatted(date: .abbreviated, time: .omitted))
                                .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Color.cream.opacity(0.4))
                        }
                        Spacer(minLength: 0)
                    }
                    if let b = p.boost, b.status != "pending" {
                        Text(b.status == "done" ? "Boost done · \(b.views.formatted()) views" : "Boosted · \(b.views.formatted()) / \(b.goalViews.formatted()) views")
                            .font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(Color.whiskey)
                    } else {
                        BizPrimaryButton(title: p.boost?.status == "pending" ? "FINISH BOOST PAYMENT" : "BOOST") {
                            if ov.isPlus { boosting = p } else { upgradeOpen = true }
                        }
                    }
                }
            }
        }
    }

    // Approval state, front and centre.
    private var statusCard: some View {
        let (label, color, text): (String, Color, String) = {
            switch summary.status {
            case "approved":  return ("VERIFIED", BizState.liveGreen, "\(summary.venueName)\(summary.venueCity.map { " · \($0)" } ?? "")")
            case "rejected":  return ("NOT APPROVED", BizState.rejectRed, summary.adminNote ?? "We couldn't verify this claim. Email contact@sejdel.com and we'll sort it out.")
            case "suspended": return ("PAUSED", .whiskey, summary.adminNote ?? "This account is paused. Email contact@sejdel.com.")
            default:          return ("UNDER REVIEW", .bronze, "We're checking that \(summary.venueName) is yours. Usually the same day — we'll email \(summary.contactEmail).")
            }
        }()
        return BizCard {
            HStack {
                StatusPill(state: BizState(label: label, color: color))
                Spacer()
                if summary.pendingOrders > 0 {
                    Text("\(summary.pendingOrders) IN REVIEW")
                        .font(.system(size: 9, weight: .black, design: .monospaced)).tracking(1)
                        .foregroundStyle(Color.bronze)
                }
                if summary.unpaidOrders > 0 {
                    Text("\(summary.unpaidOrders) TO PAY")
                        .font(.system(size: 9, weight: .black, design: .monospaced)).tracking(1)
                        .foregroundStyle(Color.whiskey)
                }
            }
            Text(text)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // ── subscribe ──
    private func subscribeCard(_ ov: BusinessOverview) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pick your plan.")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.cream)
            PlanCard(plus: false, price: store.displayPrice(BizTier.business, fallbackSek: ov.product(BizTier.business)?.amountSek ?? 0),
                     cta: "START BUSINESS", busy: subscribing == BizTier.business, enabled: subscribing == nil) { subscribe(BizTier.business) }
            PlanCard(plus: true, price: store.displayPrice(BizTier.plus, fallbackSek: ov.product(BizTier.plus)?.amountSek ?? 0),
                     cta: "GO BUSINESS+", busy: subscribing == BizTier.plus, enabled: subscribing == nil) { subscribe(BizTier.plus) }
            if let n = subscribeNote {
                Text(n).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(Color.cream.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                Task { await store.syncSubscriptions(for: [summary.id]); await svc.loadOverview(summary.id); await svc.loadMine() }
            } label: {
                Text("Restore purchases").font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.5)).underline()
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
        }
    }

    private func subscribe(_ id: String) {
        subscribing = id; subscribeNote = nil
        Task {
            switch await store.subscribe(business: summary.id, productId: id) {
            case .paid: await svc.loadOverview(summary.id); await svc.loadMine()
            case .cancelled: break
            case .pending: subscribeNote = "Waiting for approval from your Apple account."
            case .failed(let why): subscribeNote = why
            }
            subscribing = nil
        }
    }

    // ── subscribed ──
    private func tierCard(_ ov: BusinessOverview) -> some View {
        BizCard {
            HStack {
                StatusPill(state: BizState(label: BizTier.label(ov.business.tier), color: ov.isPlus ? .whiskey : BizState.liveGreen))
                Spacer()
                if let e = ov.business.tierExpiresAt {
                    Text("Renews \(e.formatted(date: .abbreviated, time: .omitted))")
                        .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Color.cream.opacity(0.45))
                }
            }
            Text(ov.isPlus ? "Poster on the map · boosts · pushes · several deals at once" : "Pin on the map · profile · posts · one deal at a time")
                .font(.system(size: 14, weight: .medium, design: .rounded)).foregroundStyle(Color.cream.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            if !ov.isPlus {
                BizPrimaryButton(title: "GO BUSINESS+ · \(store.displayPrice(BizTier.plus, fallbackSek: ov.product(BizTier.plus)?.amountSek ?? 0)) / MO",
                                 enabled: subscribing == nil, busy: subscribing == BizTier.plus) { subscribe(BizTier.plus) }
            }
            if let n = subscribeNote {
                Text(n).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(Color.cream.opacity(0.7))
            }
            Button {
                if let u = URL(string: "https://apps.apple.com/account/subscriptions") { openURL(u) }
            } label: {
                Text("Manage subscription").font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.45)).underline()
            }
            .buttonStyle(.plain)
        }
    }

    private func statStrip(_ ov: BusinessOverview) -> some View {
        let views = ov.campaigns.reduce(0) { $0 + $1.weekImpressions }
        let taps = ov.campaigns.reduce(0) { $0 + $1.weekTaps }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                stat("FOLLOWERS", ov.business.followers)
                Rectangle().fill(Color.cream.opacity(0.08)).frame(width: 1, height: 34)
                stat("VIEWS", views)
                Rectangle().fill(Color.cream.opacity(0.08)).frame(width: 1, height: 34)
                stat("TAPS", taps)
            }
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.cream.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.cream.opacity(0.08), lineWidth: 1))
            Text("VIEWS & TAPS · THIS WEEK · on the Deals map")
                .font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.5)
                .foregroundStyle(Color.cream.opacity(0.4))
        }
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        VStack(spacing: 3) {
            Text("\(value)")
                .font(.system(size: 22, weight: .black, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.cream)
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.3)
                .foregroundStyle(Color.bronze)
        }
        .frame(maxWidth: .infinity)
    }

    // ── profile ──
    private var profileDirty: Bool {
        logoData != nil || posterData != nil || tagline != (ov?.business.tagline ?? "")
    }

    private func profileCard(_ ov: BusinessOverview) -> some View {
        BizCard {
            kicker("PROFILE")
            HStack(spacing: 14) {
                PhotosPicker(selection: $logoItem, matching: .images) {
                    ZStack {
                        Circle().fill(Color.smoke)
                        if let d = logoData, let img = UIImage(data: d) {
                            Image(uiImage: img).resizable().scaledToFill()
                        } else if let u = ov.business.logoUrl, let url = URL(string: u) {
                            DownsampledAsyncImage(url: url, targetPoints: 128)
                        } else {
                            Image(systemName: "camera.fill").font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.cream.opacity(0.6))
                        }
                    }
                    .frame(width: 64, height: 64)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Color.whiskey.opacity(0.5), lineWidth: 1.5))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(ov.business.name).font(.system(size: 16, weight: .heavy, design: .rounded)).foregroundStyle(Color.cream)
                    Text("Tap the circle to set your logo").font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.5))
                }
                Spacer()
            }
            BizField(label: "TAGLINE", text: $tagline, placeholder: "Craft beer & late nights", limit: 80)
            if ov.isPlus {
                ArtPicker(title: "PHOTO ON THE MAP (4:3)", ratio: CampaignArt.posterRatio, item: $posterItem, data: $posterData,
                          existing: ov.business.posterUrl.flatMap(URL.init(string:)))
            }
            ErrorLine(text: profileError)
            if profileDirty {
                BizPrimaryButton(title: "SAVE", busy: savingProfile) { saveProfile(ov) }
            }
        }
    }

    private func saveProfile(_ ov: BusinessOverview) {
        savingProfile = true; profileError = nil
        Task {
            do {
                try await svc.updateProfile(business: ov.business.id, logoData: logoData, posterData: posterData,
                                            tagline: tagline == (ov.business.tagline ?? "") ? nil : tagline)
                logoData = nil; posterData = nil; logoItem = nil; posterItem = nil
            } catch { profileError = BusinessService.friendly(error) }
            savingProfile = false
        }
    }

    // ── posts ──
    private func postsSection(_ ov: BusinessOverview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            kicker("POSTS")
            ForEach(ov.posts) { p in postRow(p, ov: ov) }
            if ov.posts.isEmpty {
                Text("Tell your followers what's on — events, new menus, tonight's DJ.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            BizSecondaryButton(title: "NEW POST", icon: "plus.circle.fill") { postOpen = true }
        }
    }

    private func postRow(_ p: BusinessOverview.Post, ov: BusinessOverview) -> some View {
        BizCard {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.smoke)
                    if let u = URL(string: p.imageUrl) {
                        DownsampledAsyncImage(url: u, targetPoints: 120, fill: true, placeholder: Color.smoke)
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.caption ?? "Photo")
                        .font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(Color.cream).lineLimit(2)
                    if let e = p.eventAt {
                        Label(e.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                            .font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Color.whiskey)
                    }
                    Text(p.createdAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Color.cream.opacity(0.4))
                }
                Spacer(minLength: 0)
            }
            if let b = p.boost, b.status != "pending" {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        StatusPill(state: BizState(label: b.status == "done" ? "BOOST DONE" : "BOOSTED",
                                                   color: b.status == "done" ? Color.cream.opacity(0.5) : BizState.liveGreen))
                        Spacer()
                        Text("\(b.views.formatted()) / \(b.goalViews.formatted()) views · \(b.taps) taps")
                            .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(Color.cream.opacity(0.6))
                    }
                    ProgressView(value: Double(min(b.views, b.goalViews)), total: Double(max(b.goalViews, 1))).tint(Color.whiskey)
                }
            } else {
                BizSecondaryButton(title: p.boost?.status == "pending" ? "FINISH BOOST PAYMENT" : "BOOST THIS POST",
                                   icon: "bolt.fill") { if ov.isPlus { boosting = p } else { upgradeOpen = true } }
            }
            Button {
                deleting = p.id
                Task { try? await svc.deletePost(p.id, business: summary.id); deleting = nil }
            } label: {
                Text(deleting == p.id ? "Deleting…" : "Delete post")
                    .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(Color.cream.opacity(0.5)).underline()
            }
            .buttonStyle(.plain)
        }
    }

    // ── deals ──
    private func dealsSection(_ ov: BusinessOverview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            kicker("DEALS ON YOUR PIN")
            ForEach(ov.campaigns) { c in dealRow(c, ov: ov) }
            let maxLive = ov.isPlus ? ov.limit("max_live_campaigns", 5) : ov.limit("max_live_campaigns_basic", 1)
            let liveNow = ov.campaigns.filter(\.live).count
            Text(ov.campaigns.isEmpty
                 ? "A deal is what guests see when they tap your pin. Happy hour, a price, free entry."
                 : ov.isPlus ? "\(liveNow) of \(maxLive) live at once." : "One deal at a time — Business+ runs several.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
            BizSecondaryButton(title: "NEW DEAL", icon: "plus.circle.fill", enabled: liveNow < maxLive) { dealOpen = true }
        }
    }

    private func dealRow(_ c: BusinessOverview.Campaign, ov: BusinessOverview) -> some View {
        BizCard {
            HStack(alignment: .top, spacing: 12) {
                artThumb(c.imageUrl)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(c.placement.uppercased())
                            .font(.system(size: 8, weight: .black, design: .monospaced)).tracking(0.8)
                            .foregroundStyle(c.placement == "pin" ? Color.cream.opacity(0.7) : Color.ink)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill(c.placement == "poster" ? Color.foam : Color.cream.opacity(0.12)))
                        StatusPill(state: BizState.ofDeal(c))
                    }
                    Text(c.title)
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.cream)
                        .lineLimit(2)
                    if let e = c.endsAt {
                        Text("Until \(e.formatted(date: .abbreviated, time: .omitted))")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.cream.opacity(0.5))
                    }
                }
                Spacer(minLength: 0)
            }
            Text("\(c.weekImpressions) views · \(c.weekTaps) taps this week")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.55))
            HStack {
                Button {
                    preview = BizPreview(offer: c.asOffer(venueId: ov.venue.id), venue: ov.venue, surface: .campaign, action: .look)
                } label: {
                    Label("See it as guests do", systemImage: "eye")
                        .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(Color.whiskey)
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    ending = c.id
                    Task { try? await svc.endDeal(c.id, business: summary.id); ending = nil }
                } label: {
                    Text(ending == c.id ? "Ending…" : "End deal")
                        .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(Color.cream.opacity(0.5)).underline()
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func artThumb(_ url: String?) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.smoke)
            if let s = url, let u = URL(string: s) {
                DownsampledAsyncImage(url: u, targetPoints: 120, fill: true, placeholder: Color.smoke)
            } else {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.whiskey)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // ── card (Business+) ──
    private func cardSection(_ ov: BusinessOverview) -> some View {
        let hasArt = ov.campaigns.contains { $0.imageUrl != nil }
        return VStack(alignment: .leading, spacing: 10) {
            kicker("APP-OPEN CARD")
            ForEach(ov.cards.prefix(3)) { c in cardRow(c, ov: ov) }
            Text(!ov.isPlus ? "Full screen the moment someone nearby opens the app. A Business+ thing."
                 : !hasArt ? "Needs a deal with a photo first."
                 : "Full screen the moment someone nearby opens the app, once per person.")
                .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(Color.cream.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            BizSecondaryButton(title: ov.cardPending ? "CARD IN PROGRESS" : "REQUEST A CARD",
                               icon: "rectangle.portrait.on.rectangle.portrait.angled",
                               enabled: !ov.isPlus || (hasArt && !ov.cardPending)) {
                if ov.isPlus { cardOpen = true } else { upgradeOpen = true }
            }
        }
    }

    private func cardRow(_ c: BusinessOverview.Card, ov: BusinessOverview) -> some View {
        let state = BizState.of(orderStatus: c.orderStatus, paid: c.paid, live: c.status == "live",
                                startsAt: c.startsAt, endsAt: c.endsAt, done: c.status == "done")
        let offer = ov.campaigns.first { $0.id == c.offerId }?.asOffer(venueId: ov.venue.id)
            ?? stubOffer(c.offerTitle, venueId: ov.venue.id)
        return BizCard {
            HStack {
                StatusPill(state: state)
                Spacer()
                if let a = c.amountSek { Text(kr(a)).font(.system(size: 12, weight: .black, design: .rounded)).foregroundStyle(Color.cream.opacity(0.8)) }
            }
            Text(c.offerTitle).font(.system(size: 15, weight: .heavy, design: .rounded)).foregroundStyle(Color.cream)
            Text("\(c.delivered) of \(c.audienceCap) people reached · \(c.tapped) opened the deal")
                .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(Color.cream.opacity(0.55))
            ProgressView(value: Double(c.delivered), total: Double(max(c.audienceCap, 1))).tint(Color.whiskey)
            if let r = c.rejectReason, c.orderStatus == "rejected" {
                Text("Reason: \(r)").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(BizState.rejectRed)
            }
            if c.orderStatus == "pending", let oid = c.orderId { cancelLink(oid) }
            previewButtons(offer: offer, venue: ov.venue, surface: .card,
                           orderId: c.orderId, status: c.orderStatus, paid: c.paid,
                           productId: c.productId, quantity: 1, amount: c.amountSek ?? 0)
        }
    }

    // ── push (Business+) ──
    private func pushSection(_ ov: BusinessOverview) -> some View {
        let cooling = (ov.nextPushAt ?? .distantPast) > Date()
        let hasLive = ov.campaigns.contains { $0.live }
        return VStack(alignment: .leading, spacing: 10) {
            kicker("PUSH NOTIFICATION")
            ForEach(ov.pushes.prefix(3)) { p in pushRow(p, ov: ov) }
            Text(!ov.isPlus ? "A notification to your city every time you drop a deal. A Business+ thing."
                 : !hasLive ? "A push points at a live deal — add one first."
                 : cooling ? "One push per bar every \(ov.limit("push_cooldown_days", 7)) days. Next slot opens \((ov.nextPushAt ?? Date()).formatted(date: .abbreviated, time: .shortened))."
                 : "One notification to people in \(ov.business.venueCity ?? "your city") who opted in to bar deals.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
            BizSecondaryButton(title: ov.pushPending ? "PUSH SCHEDULED" : "REQUEST A PUSH", icon: "bell.badge.fill",
                               enabled: !ov.isPlus || (hasLive && !ov.pushPending && !cooling)) {
                if ov.isPlus { pushOpen = true } else { upgradeOpen = true }
            }
        }
    }

    private func pushRow(_ p: BusinessOverview.Push, ov: BusinessOverview) -> some View {
        let offer = ov.campaigns.first { $0.id == p.offerId }?.asOffer(venueId: ov.venue.id)
            ?? stubOffer(p.title, venueId: ov.venue.id)
        let state: BizState = p.status == "sent"
            ? BizState(label: "SENT · \(p.recipientCount) PEOPLE", color: BizState.liveGreen)
            : p.status == "failed" ? BizState(label: "FAILED", color: BizState.rejectRed)
            : BizState.of(orderStatus: p.orderStatus, paid: p.paid, live: false, startsAt: p.sendAt, endsAt: nil)
        return BizCard {
            HStack {
                StatusPill(state: state)
                Spacer()
                if let a = p.amountSek { Text(kr(a)).font(.system(size: 12, weight: .black, design: .rounded)).foregroundStyle(Color.cream.opacity(0.8)) }
            }
            Text(p.title).font(.system(size: 15, weight: .heavy, design: .rounded)).foregroundStyle(Color.cream)
            Text(p.body).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(Color.cream.opacity(0.7))
            Text("\(p.sendAt.formatted(date: .abbreviated, time: .shortened)) · up to \(p.audienceCap) people")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.cream.opacity(0.5))
            if let r = p.rejectReason, p.orderStatus == "rejected" {
                Text("Reason: \(r)").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(BizState.rejectRed)
            }
            if p.orderStatus == "pending", let oid = p.orderId { cancelLink(oid) }
            if p.status != "sent" {
                previewButtons(offer: offer, venue: ov.venue, surface: .push(title: p.title, body: p.body),
                               orderId: p.orderId, status: p.orderStatus, paid: p.paid,
                               productId: p.productId, quantity: 1, amount: p.amountSek ?? 0)
            }
        }
    }

    /// APPROVED but unpaid rows get the pay button, which walks through the
    /// preview before the App Store sheet; everything else gets "see it".
    @ViewBuilder
    private func previewButtons(offer: VenueOffer, venue: Venue, surface: BizPreview.Surface,
                                orderId: UUID?, status: String?, paid: Bool?,
                                productId: String?, quantity: Int, amount: Int) -> some View {
        if let orderId, status == "approved", paid != true {
            Button {
                preview = BizPreview(offer: offer, venue: venue, surface: surface,
                                     action: .pay(orderId: orderId, productId: productId, quantity: quantity, amountSek: amount))
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "eye.fill")
                    Text("PREVIEW & PAY \(store.displayPrice(productId, quantity: quantity, fallbackSek: amount))")
                        .font(.system(size: 12, weight: .black, design: .monospaced)).tracking(1.4)
                }
                .foregroundStyle(Color.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.whiskey))
            }
            .buttonStyle(PressScaleStyle())
        } else if status != "rejected" && status != "cancelled" {
            Button {
                preview = BizPreview(offer: offer, venue: venue, surface: surface, action: .look)
            } label: {
                Label("See it as guests do", systemImage: "eye")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.whiskey)
            }
            .buttonStyle(.plain)
        }
    }

    /// A push or card whose deal is gone still needs something to draw.
    private func stubOffer(_ title: String, venueId: UUID) -> VenueOffer {
        VenueOffer(id: UUID(), venueId: venueId, kind: "price", title: title, description: nil, finePrint: nil,
                   redeem: "show", code: nil, startMinute: nil, endMinute: nil, activeDays: nil, placement: "pin",
                   imageUrl: nil, billboardImageUrl: nil, interstitial: false, showOnValidOnly: false)
    }

    private func cancelLink(_ orderId: UUID) -> some View {
        Button {
            cancelling = orderId
            Task {
                try? await svc.cancelOrder(orderId, business: summary.id)
                cancelling = nil
            }
        } label: {
            Text(cancelling == orderId ? "Cancelling…" : "Withdraw this request")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.5))
                .underline()
        }
        .buttonStyle(.plain)
    }

    // ── check-in QR ──
    private func qrSection(_ ov: BusinessOverview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let u = ov.business.username {
                kicker("FOLLOW QR")
                BizCard {
                    BusinessQRCard(payload: "https://sejdel.com/b/\(u)", code: "@\(u)",
                                   caption: "Scan to open \(ov.business.name) on Sejdel and follow. Put it on the menu, the door, the receipt.",
                                   shareName: "Follow \(ov.business.name) on Sejdel")
                }
            }
            kicker("CHECK-IN QR")
            BizCard {
                if let t = ov.business.qrToken {
                    BusinessQRCard(payload: "https://sejdel.com/qr/\(t)", code: t,
                                   caption: "Print it for the tables. Scanning checks guests in at \(ov.business.venueName); the code under it works if the camera won't.",
                                   shareName: "\(ov.business.venueName) check-in QR")
                } else {
                    Text("A QR for the tables. Guests scan it to check in at \(ov.business.venueName) — that's how a night lands here.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                    ErrorLine(text: qrError)
                    BizPrimaryButton(title: "CREATE MY QR", busy: mintingQR) {
                        mintingQR = true; qrError = nil
                        Task {
                            do { _ = try await svc.qrToken(business: ov.business.id) }
                            catch { qrError = BusinessService.friendly(error) }
                            mintingQR = false
                        }
                    }
                }
            }
        }
    }

    private func rulesCard(_ ov: BusinessOverview) -> some View {
        BizCard {
            kicker("THE RULES")
            Text("Everything is marked SPONSORED and only shown within \(ov.limit("radius_m", 25000) / 1000) km of the bar. Keep it moderate — nothing aimed under 25.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.6))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The dashboard's sheets, kept out of its body so the type-checker copes.
private struct DashboardSheets: ViewModifier {
    @ObservedObject var svc: BusinessService
    let overview: BusinessOverview?
    @Binding var dealOpen: Bool
    @Binding var postOpen: Bool
    @Binding var cardOpen: Bool
    @Binding var pushOpen: Bool
    @Binding var boosting: BusinessOverview.Post?
    @Binding var preview: BizPreview?
    @Binding var upgradeOpen: Bool
    let reload: () -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $upgradeOpen) {
                if let overview {
                    BusinessUpgradeSheet(svc: svc, overview: overview)
                        .presentationDragIndicator(.visible)
                        .presentationBackground(Color.ink)
                }
            }
            .sheet(isPresented: $dealOpen) {
                if let overview {
                    BusinessDealComposer(svc: svc, overview: overview) { dealOpen = false }
                        .presentationBackground(Color.ink)
                }
            }
            .sheet(isPresented: $postOpen) {
                if let overview {
                    BusinessPostComposer(svc: svc, overview: overview) { postOpen = false }
                        .presentationBackground(Color.ink)
                }
            }
            .sheet(item: $boosting) { post in
                if let overview {
                    BusinessBoostSheet(svc: svc, overview: overview, post: post) { boosting = nil }
                        .presentationDetents([.large])
                        .presentationBackground(Color.ink)
                }
            }
            .sheet(isPresented: $cardOpen) {
                if let overview {
                    BusinessCardSheet(svc: svc, overview: overview) { cardOpen = false }
                        .presentationDetents([.large])
                        .presentationBackground(Color.ink)
                }
            }
            .sheet(isPresented: $pushOpen) {
                if let overview {
                    BusinessPushSheet(svc: svc, overview: overview) { pushOpen = false }
                        .presentationBackground(Color.ink)
                }
            }
            .sheet(item: $preview) { p in
                BusinessPreviewSheet(request: p) { reload() }
                    .presentationBackground(Color.ink)
            }
    }
}

// MARK: - Post composer (owner)

/// A post to followers: one photo at an Instagram ratio, a caption, and
/// optionally when it happens and which deal it points at.
private struct BusinessPostComposer: View {
    @ObservedObject var svc: BusinessService
    let overview: BusinessOverview
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var item: PhotosPickerItem?
    @State private var data: Data?
    @State private var ratio: CGFloat = 1
    @State private var caption = ""
    @State private var offerId: UUID?
    @State private var saving = false
    @State private var error: String?

    private var canPost: Bool { data != nil && caption.count <= 300 && !saving }

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    SheetHeader(eyebrow: "", title: "What's on?", onClose: { dismiss() })
                    PhotosPicker(selection: $item, matching: .images) {
                        Color.clear
                            .aspectRatio(ratio, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .overlay {
                                ZStack {
                                    Color.smoke
                                    if let d = data, let img = UIImage(data: d) {
                                        Image(uiImage: img).resizable().scaledToFill()
                                    } else {
                                        VStack(spacing: 4) {
                                            Image(systemName: "photo.badge.plus").font(.system(size: 22, design: .rounded))
                                            Text("Pick a photo").font(.system(size: 12, weight: .semibold, design: .rounded))
                                        }
                                        .foregroundStyle(Color.cream.opacity(0.6))
                                    }
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.cream.opacity(0.12), lineWidth: 1))
                    }
                    BizField(label: "CAPTION", text: $caption, placeholder: "Quiz night Thursday. 20:00, free entry.", multiline: true, limit: 300)
                    let live = overview.campaigns.filter(\.live)
                    if !live.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            kicker("LINK A DEAL")
                            Menu {
                                Button("None") { offerId = nil }
                                ForEach(live) { c in Button(c.title) { offerId = c.id } }
                            } label: {
                                HStack {
                                    Text(live.first { $0.id == offerId }?.title ?? "None").foregroundStyle(Color.cream)
                                    Spacer()
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(Color.bronze)
                                }
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 14).padding(.vertical, 12)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.cream.opacity(0.05)))
                            }
                        }
                    }
                    ErrorLine(text: error)
                    BizPrimaryButton(title: "POST", enabled: canPost, busy: saving, action: post)
                    Spacer(minLength: 24)
                }
                .padding(20)
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: item) { _, newItem in
            guard let newItem else { return }
            Task {
                guard let d = try? await newItem.loadTransferable(type: Data.self), let img = UIImage(data: d) else { return }
                data = d
                ratio = CampaignArt.clampFeed(img.size.width / max(img.size.height, 1))
            }
        }
    }

    private func post() {
        guard let data else { return }
        saving = true; error = nil
        Task {
            do {
                try await svc.createPost(business: overview.business.id, images: [data], ratio: ratio,
                                         caption: caption.trimmingCharacters(in: .whitespacesAndNewlines),
                                         eventAt: nil, offerId: offerId)
                onDone(); dismiss()
            } catch { self.error = BusinessService.friendly(error) }
            saving = false
        }
    }
}

// MARK: - Boost (Business+)

/// Pick a view pack, pay, and the post runs as a sponsored feed post and a
/// billboard on the Deals map until it reaches that many views.
private struct BusinessBoostSheet: View {
    @ObservedObject var svc: BusinessService
    let overview: BusinessOverview
    let post: BusinessOverview.Post
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = BusinessStore.shared

    @State private var pack: BizProduct?
    @State private var busy = false
    @State private var note: String?
    @State private var failed = false

    init(svc: BusinessService, overview: BusinessOverview, post: BusinessOverview.Post, onDone: @escaping () -> Void) {
        self.svc = svc; self.overview = overview; self.post = post; self.onDone = onDone
        let pending = post.boost?.status == "pending" ? post.boost : nil
        _pack = State(initialValue: pending.flatMap { overview.product($0.productId) } ?? overview.packs("boost").first)
    }

    private var pendingBoost: BusinessOverview.Boost? { post.boost?.status == "pending" ? post.boost : nil }

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    SheetHeader(eyebrow: "", title: "Boost this post.", onClose: { dismiss() })
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.smoke)
                            if let u = URL(string: post.imageUrl) {
                                DownsampledAsyncImage(url: u, targetPoints: 120, fill: true, placeholder: Color.smoke)
                            }
                        }
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        Text(post.caption ?? "Photo")
                            .font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(Color.cream).lineLimit(2)
                        Spacer()
                    }
                    if pendingBoost == nil {
                        PackPicker(title: "VIEWS", packs: overview.packs("boost"), unit: "views", selected: $pack)
                    }
                    Text("Runs as a sponsored post in the Home feed and a billboard on the Deals map until it reaches the number. A view counts when it's actually on someone's screen.")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.cream.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                    priceRow(store.displayPrice(pack?.productId, fallbackSek: pack?.amountSek ?? 0), "Charged now · runs until done")
                    if let note {
                        if failed { ErrorLine(text: note) } else {
                            Text(note).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(Color.cream.opacity(0.7))
                        }
                    }
                    Button(action: boost) {
                        HStack(spacing: 8) {
                            if busy { ProgressView().tint(Color.ink) }
                            Image(systemName: "apple.logo")
                            Text(busy ? "PAYING…" : "BOOST · \(store.displayPrice(pack?.productId, fallbackSek: pack?.amountSek ?? 0))")
                                .font(.system(size: 13, weight: .black, design: .monospaced)).tracking(1.6)
                        }
                        .foregroundStyle(Color.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(busy || pack == nil ? Color.cream.opacity(0.12) : Color.whiskey))
                    }
                    .buttonStyle(PressScaleStyle())
                    .disabled(busy || pack == nil)
                    Spacer(minLength: 24)
                }
                .padding(20)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func boost() {
        guard let pack else { return }
        busy = true; note = nil; failed = false
        Task {
            do {
                let boostId: UUID
                if let pending = pendingBoost {
                    boostId = pending.id
                } else {
                    boostId = try await svc.createBoost(post: post.id, productId: pack.productId)
                }
                switch await store.payBoost(boostId: boostId, productId: pack.productId) {
                case .paid:
                    await svc.loadOverview(overview.business.id)
                    onDone(); dismiss()
                case .cancelled:
                    try? await svc.cancelBoost(boostId)
                    await svc.loadOverview(overview.business.id)
                case .pending:
                    note = "Waiting for approval from your Apple account. The boost starts as soon as that clears."
                case .failed(let why):
                    note = why; failed = true
                }
            } catch {
                note = BusinessService.friendly(error); failed = true
            }
            busy = false
        }
    }
}

// MARK: - Deal composer (owner)

/// A deal on the bar's pin. Live the moment it's submitted — the
/// subscription is the approval. Business+ bars can add a photo, which
/// makes the pin a poster.
private struct BusinessDealComposer: View {
    @ObservedObject var svc: BusinessService
    let overview: BusinessOverview
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var kind = "price"
    @State private var title = ""
    @State private var desc = ""
    @State private var finePrint = ""
    @State private var days: Set<Int> = []
    @State private var allDay = true
    @State private var startTime = Calendar.current.date(bySettingHour: 16, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var endTime = Calendar.current.date(bySettingHour: 19, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var showOnValidOnly = false
    @State private var startDate = Date()
    @State private var endDate = Date().addingTimeInterval(30 * 86400)
    @State private var posterItem: PhotosPickerItem?
    @State private var posterData: Data?
    @State private var saving = false
    @State private var error: String?
    @State private var preview: BizPreview?

    private let kinds = ["price", "happy_hour", "free_entry", "bundle", "event"]
    private let dayLabels = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && title.count <= 60 && desc.count <= 200
            && endDate > startDate && !saving
    }

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    SheetHeader(eyebrow: "", title: "New deal", onClose: { dismiss() })
                    if overview.isPlus {
                        ArtPicker(title: "PHOTO (4:3, optional)", ratio: CampaignArt.posterRatio, item: $posterItem, data: $posterData)
                    }
                    kindPicker
                    BizField(label: "HEADLINE", text: $title, placeholder: "39 kr stora stark", limit: 60)
                    BizField(label: "DESCRIPTION", text: $desc, placeholder: "Show this at the bar", multiline: true, limit: 200)
                    BizField(label: "FINE PRINT (optional)", text: $finePrint, placeholder: "20+ · one per guest", limit: 120)
                    validDays
                    window
                    ErrorLine(text: error)
                    BizPrimaryButton(title: "PREVIEW & GO LIVE", enabled: canSave, busy: saving, action: openPreview)
                    Spacer(minLength: 24)
                }
                .padding(20)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(item: $preview) { p in
            BusinessPreviewSheet(request: p) { onDone(); dismiss() }
                .presentationBackground(Color.ink)
        }
    }

    private var kindPicker: some View {
        VStack(alignment: .leading, spacing: 7) {
            kicker("TYPE")
            Menu {
                ForEach(kinds, id: \.self) { k in Button(bizKindLabel(k)) { kind = k } }
            } label: {
                HStack {
                    Text(bizKindLabel(kind)).foregroundStyle(Color.cream)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(Color.bronze)
                }
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.cream.opacity(0.05)))
            }
        }
    }

    private var validDays: some View {
        VStack(alignment: .leading, spacing: 8) {
            kicker("VALID ON THESE DAYS")
            HStack(spacing: 6) {
                ForEach(0..<7, id: \.self) { d in
                    Button {
                        if days.contains(d) { days.remove(d) } else { days.insert(d) }
                    } label: {
                        Text(dayLabels[d])
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .foregroundStyle(days.contains(d) ? Color.ink : Color.cream.opacity(0.6))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(Capsule().fill(days.contains(d) ? Color.whiskey : Color.cream.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                }
            }
            Toggle(isOn: $allDay) {
                Text("Runs all day").font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(Color.cream)
            }
            .tint(Color.whiskey)
            if !allDay {
                HStack(spacing: 14) {
                    DatePicker("From", selection: $startTime, displayedComponents: .hourAndMinute)
                    DatePicker("To", selection: $endTime, displayedComponents: .hourAndMinute)
                }
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.7))
                .tint(Color.whiskey)
                Toggle(isOn: $showOnValidOnly) {
                    Text("Only show on the valid days & times").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(Color.cream)
                }
                .tint(Color.whiskey)
            }
        }
    }

    private var window: some View {
        VStack(alignment: .leading, spacing: 8) {
            kicker("ON THE MAP")
            DatePicker("Starts", selection: $startDate, in: Date()..., displayedComponents: .date)
            DatePicker("Ends", selection: $endDate, in: startDate.addingTimeInterval(86400)...startDate.addingTimeInterval(Double(overview.limit("campaign_max_days", 90)) * 86400), displayedComponents: .date)
        }
        .font(.system(size: 13, weight: .medium, design: .rounded))
        .foregroundStyle(Color.cream.opacity(0.7))
        .tint(Color.whiskey)
    }

    private func minutes(_ d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private var draftOffer: VenueOffer {
        VenueOffer(id: UUID(), venueId: overview.venue.id, kind: kind,
                   title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                   description: desc.isEmpty ? nil : desc, finePrint: finePrint.isEmpty ? nil : finePrint,
                   redeem: "show", code: nil,
                   startMinute: allDay ? nil : minutes(startTime), endMinute: allDay ? nil : minutes(endTime),
                   activeDays: days.isEmpty ? nil : days.sorted(),
                   placement: overview.isPlus && posterData != nil ? "poster" : "pin",
                   imageUrl: nil, billboardImageUrl: nil, interstitial: false, showOnValidOnly: false)
    }

    private func openPreview() {
        error = nil
        preview = BizPreview(offer: draftOffer, venue: overview.venue, surface: .campaign,
                             action: .submit(label: "GO LIVE", run: { try await submit() }),
                             poster: posterData.flatMap { UIImage(data: $0) })
    }

    private func submit() async throws {
        try await svc.createDeal(
            business: overview.business.id, kind: kind,
            title: title, description: desc, finePrint: finePrint,
            startsAt: startDate, endsAt: endDate,
            activeDays: days.isEmpty ? nil : days.sorted(),
            startMinute: allDay ? nil : minutes(startTime), endMinute: allDay ? nil : minutes(endTime),
            posterData: overview.isPlus ? posterData : nil,
            showOnValidOnly: !allDay && showOnValidOnly
        )
    }
}

/// One artwork picker at a fixed ratio — same crop idiom as the map pin.
private struct ArtPicker: View {
    let title: String
    let ratio: CGFloat
    @Binding var item: PhotosPickerItem?
    @Binding var data: Data?
    /// What's saved already, shown until a new picture is picked.
    var existing: URL? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            kicker(title)
            PhotosPicker(selection: $item, matching: .images) {
                Color.clear
                    .aspectRatio(ratio, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        ZStack {
                            Color.smoke
                            if let d = data, let img = UIImage(data: d) {
                                Image(uiImage: img).resizable().scaledToFill()
                            } else if let existing {
                                DownsampledAsyncImage(url: existing, targetPoints: 360)
                            } else {
                                VStack(spacing: 4) {
                                    Image(systemName: "photo.badge.plus").font(.system(size: 20, design: .rounded))
                                    Text("Pick artwork").font(.system(size: 12, weight: .semibold, design: .rounded))
                                }
                                .foregroundStyle(Color.cream.opacity(0.6))
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.cream.opacity(0.12), lineWidth: 1))
            }
            .onChange(of: item) { _, newItem in
                guard let newItem else { return }
                Task { data = try? await newItem.loadTransferable(type: Data.self) }
            }
        }
    }
}

// MARK: - Card request (owner)

private struct BusinessCardSheet: View {
    @ObservedObject var svc: BusinessService
    let overview: BusinessOverview
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var offerId: UUID?
    @State private var pack: BizProduct?
    @State private var saving = false
    @State private var error: String?
    @ObservedObject private var store = BusinessStore.shared

    init(svc: BusinessService, overview: BusinessOverview, onDone: @escaping () -> Void) {
        self.svc = svc; self.overview = overview; self.onDone = onDone
        _offerId = State(initialValue: overview.campaigns.first { $0.imageUrl != nil }?.id)
        _pack = State(initialValue: overview.packs("card").first)
    }

    private var eligible: [BusinessOverview.Campaign] { overview.campaigns.filter { $0.imageUrl != nil } }

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    SheetHeader(eyebrow: "APP-OPEN CARD", title: "Who sees it?", onClose: { dismiss() })
                    CampaignPicker(campaigns: eligible, selected: $offerId)
                    PackPicker(title: "AUDIENCE", packs: overview.packs("card"), unit: "people", selected: $pack)
                    Text("Shown to people in \(overview.business.venueCity ?? "your city") when they open the app, once each, over up to \(overview.limit("card_window_days", 14)) days. Stops at your number.")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.cream.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                    priceRow(store.displayPrice(pack?.productId, fallbackSek: pack?.amountSek ?? 0), "Reviewed first · pay in the app once approved")
                    ErrorLine(text: error)
                    BizPrimaryButton(title: "SUBMIT FOR REVIEW", enabled: offerId != nil && pack != nil && !saving, busy: saving, action: submit)
                    Spacer(minLength: 24)
                }
                .padding(20)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func submit() {
        guard let offerId, let pack else { return }
        saving = true; error = nil
        Task {
            do {
                try await svc.requestCard(business: overview.business.id, offer: offerId, cap: pack.quantity)
                onDone(); dismiss()
            } catch { self.error = BusinessService.friendly(error) }
            saving = false
        }
    }
}

/// The audience / duration packs as pills — one App Store product each.
private struct PackPicker: View {
    let title: String
    let packs: [BizProduct]
    let unit: String
    @Binding var selected: BizProduct?
    @ObservedObject private var store = BusinessStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            kicker(title)
            HStack(spacing: 8) {
                ForEach(packs) { p in
                    let on = selected?.id == p.id
                    Button { selected = p } label: {
                        VStack(spacing: 2) {
                            Text("\(p.quantity.formatted())")
                                .font(.system(size: 15, weight: .black, design: .rounded))
                            Text(unit.uppercased())
                                .font(.system(size: 8, weight: .black, design: .monospaced)).tracking(1)
                            Text(store.displayPrice(p.productId, fallbackSek: p.amountSek))
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .padding(.top, 2)
                        }
                        .foregroundStyle(on ? Color.ink : Color.cream.opacity(0.75))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(on ? Color.whiskey : Color.cream.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private func priceRow(_ amount: String, _ note: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
            kicker("PRICE")
            Text(note)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.5))
        }
        Spacer()
        Text(amount)
            .font(.system(size: 24, weight: .black, design: .rounded))
            .foregroundStyle(Color.whiskey)
    }
    .padding(14)
    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.whiskey.opacity(0.08)))
}

private struct CampaignPicker: View {
    let campaigns: [BusinessOverview.Campaign]
    @Binding var selected: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            kicker("WHICH DEAL")
            ForEach(campaigns) { c in
                let on = c.id == selected
                Button { selected = c.id } label: {
                    HStack(spacing: 10) {
                        Image(systemName: on ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(on ? Color.whiskey : Color.cream.opacity(0.4))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.title).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(Color.cream).lineLimit(1)
                            Text(c.placement.uppercased() + (c.live ? " · LIVE" : " · PAUSED"))
                                .font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1)
                                .foregroundStyle(Color.cream.opacity(0.45))
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(on ? Color.whiskey.opacity(0.1) : Color.cream.opacity(0.03)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Push request (owner)

private struct BusinessPushSheet: View {
    @ObservedObject var svc: BusinessService
    let overview: BusinessOverview
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var offerId: UUID?
    @State private var title: String
    @State private var body_ = ""
    @State private var pack: BizProduct?
    @State private var sendAt = Date().addingTimeInterval(3600)
    @State private var saving = false
    @State private var error: String?
    @ObservedObject private var store = BusinessStore.shared

    init(svc: BusinessService, overview: BusinessOverview, onDone: @escaping () -> Void) {
        self.svc = svc; self.overview = overview; self.onDone = onDone
        _offerId = State(initialValue: overview.campaigns.first { $0.live }?.id)
        _title = State(initialValue: overview.business.venueName)
        _pack = State(initialValue: overview.packs("push").first)
    }

    private var quiet: Bool {
        let h = Calendar.current.component(.hour, from: sendAt)
        return h >= overview.limit("quiet_start_hour", 4) && h < overview.limit("quiet_end_hour", 10)
    }
    private var canSubmit: Bool {
        offerId != nil && !title.trimmingCharacters(in: .whitespaces).isEmpty && !body_.trimmingCharacters(in: .whitespaces).isEmpty
            && title.count <= 40 && body_.count <= 120 && !quiet && pack != nil && !saving
    }

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    SheetHeader(eyebrow: "PUSH NOTIFICATION", title: "Say it once.", onClose: { dismiss() })
                    CampaignPicker(campaigns: overview.campaigns.filter(\.live), selected: $offerId)
                    BizField(label: "TITLE", text: $title, placeholder: overview.business.venueName, limit: 40)
                    BizField(label: "MESSAGE", text: $body_, placeholder: "Happy hour's on — half price on tap until 19.", multiline: true, limit: 120)
                    preview
                    PackPicker(title: "AUDIENCE · UP TO", packs: overview.packs("push"), unit: "people", selected: $pack)
                    Text("People in \(overview.business.venueCity ?? "your city") who opted in to bar deals, least-recently-notified first, up to your pack size.")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.cream.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 8) {
                        kicker("WHEN")
                        DatePicker("Send at", selection: $sendAt, in: Date()...Date().addingTimeInterval(30 * 86400), displayedComponents: [.date, .hourAndMinute])
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.7))
                            .tint(Color.whiskey)
                        Text(quiet ? "Pushes don't go out 04:00–10:00. Pick another time." : "Goes out at this time once approved and paid. One push per bar every \(overview.limit("push_cooldown_days", 7)) days.")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(quiet ? BizState.rejectRed : Color.cream.opacity(0.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    priceRow(store.displayPrice(pack?.productId, fallbackSek: pack?.amountSek ?? 0), "Reviewed first · pay in the app once approved")
                    ErrorLine(text: error)
                    BizPrimaryButton(title: "SUBMIT FOR REVIEW", enabled: canSubmit, busy: saving, action: submit)
                    Spacer(minLength: 24)
                }
                .padding(20)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var preview: some View {
        PushBubble(title: title.isEmpty ? overview.business.venueName : title,
                   message: body_.isEmpty ? "Your message" : body_)
    }

    private func submit() {
        guard let offerId, let pack else { return }
        saving = true; error = nil
        Task {
            do {
                try await svc.requestPush(business: overview.business.id, offer: offerId, title: title, body: body_, cap: pack.quantity, sendAt: sendAt)
                onDone(); dismiss()
            } catch { self.error = BusinessService.friendly(error) }
            saving = false
        }
    }
}

// MARK: - Preview (what guests see)

/// The notification as it lands. Shared by the push sheet and the preview.
private struct PushBubble: View {
    let title: String
    let message: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.whiskey).frame(width: 34, height: 34)
                .overlay(Text("S").font(.system(size: 16, weight: .black, design: .rounded)).foregroundStyle(Color.ink))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(Color.cream).lineLimit(1)
                Text(message)
                    .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(Color.cream.opacity(0.75)).lineLimit(3)
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cream.opacity(0.08)))
    }
}

/// The campaign drawn with the very same views guests get — the pin on the
/// Deals map, the poster when they tap it, the billboard over Deals, the
/// app-open card, the push — with the pay or submit button underneath, so a
/// bar sees exactly what it's buying before the App Store sheet comes up.
/// Nothing rendered here counts as an impression (CampaignPreviewContext).
struct BusinessPreviewSheet: View {
    let request: BizPreview
    var onDone: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = BusinessStore.shared
    @State private var busy = false
    @State private var note: String?
    @State private var failed = false

    private var offer: VenueOffer { request.offer }
    private var venue: Venue { request.venue }
    private var hasArt: Bool { offer.imageURL != nil || request.poster != nil }
    private var showsPoster: Bool { hasArt && offer.placement != "pin" }

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    SheetHeader(eyebrow: "PREVIEW · " + venue.name.uppercased(), title: "What guests see", onClose: { dismiss() })
                    switch request.surface {
                    case .campaign: campaignPreview
                    case .card: cardPreview
                    case .push(let t, let b): pushPreview(t, b)
                    }
                    footer
                    Spacer(minLength: 24)
                }
                .padding(20)
            }
        }
        .preferredColorScheme(.dark)
        .environment(\.campaignPreview, CampaignPreviewContext(poster: request.poster, billboard: request.billboard))
    }

    // ── surfaces ──
    @ViewBuilder
    private var campaignPreview: some View {
        section("ON THE DEALS MAP",
                offer.placement == "pin" ? "A whiskey dot at your bar. Tap it and the deal opens."
                                         : "Your artwork is the pin — bigger than a dot, hard to miss.") {
            mapCard
        }
        if offer.placement == "billboard" {
            section("TOP OF DEALS", "Rotates with the other billboards in \(venue.city ?? "your city"), above the map.") {
                BillboardCard(offer: offer, venue: venue, onTap: {})
                    .allowsHitTesting(false)
            }
        }
        section("WHEN THEY TAP YOUR PIN",
                showsPoster ? "The bar's card: your poster on top, the deal underneath."
                            : "The bar's card, with your deal ready to show at the bar.") {
            venueCard
        }
    }

    private var cardPreview: some View {
        section("WHEN SOMEONE NEARBY OPENS THE APP", "Full screen, once per person, always marked sponsored.") {
            InterstitialView(offer: offer, venue: venue, onClose: {}, onSeeDeal: {}, embedded: true)
                .allowsHitTesting(false)
                .padding(.horizontal, 10).padding(.vertical, 18)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.black.opacity(0.55)))
        }
    }

    private func pushPreview(_ title: String, _ message: String) -> some View {
        Group {
            section("ON THEIR LOCK SCREEN", "People in \(venue.city ?? "your city") who opted in to bar deals.") {
                PushBubble(title: title, message: message)
            }
            section("TAPPING IT OPENS", "Straight to your deal on the map.") { venueCard }
        }
    }

    private var mapCard: some View {
        let coord = CLLocationCoordinate2D(latitude: venue.lat, longitude: venue.lon)
        return Map(initialPosition: .region(MKCoordinateRegion(center: coord, latitudinalMeters: 700, longitudinalMeters: 700)),
                   interactionModes: []) {
            Annotation(venue.name, coordinate: coord) {
                if showsPoster {
                    PosterPin(url: offer.imageURL, selected: false)
                } else {
                    OfferPin(count: 1, selected: false)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .including([.nightlife, .restaurant, .brewery, .winery])))
        .frame(height: 230)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.cream.opacity(0.1), lineWidth: 1))
    }

    private var venueCard: some View {
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
            if showsPoster { PosterBanner(offer: offer) }
            OfferRow(offer: offer)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.inkElev))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.cream.opacity(0.1), lineWidth: 1))
    }

    private func section<C: View>(_ title: String, _ sub: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            kicker(title)
            content()
            Text(sub)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.cream.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // ── the button underneath ──
    @ViewBuilder
    private var footer: some View {
        switch request.action {
        case .look:
            EmptyView()
        case .pay(let orderId, let productId, let quantity, let amount):
            let price = store.displayPrice(productId, quantity: quantity, fallbackSek: amount)
            priceRow(price, "Approved · goes live the moment you pay")
            noteLine
            Button { pay(orderId: orderId, productId: productId, quantity: quantity) } label: {
                HStack(spacing: 8) {
                    if busy { ProgressView().tint(Color.ink) }
                    Image(systemName: "apple.logo")
                    Text(busy ? "PAYING…" : "PAY \(price) · GO LIVE")
                        .font(.system(size: 13, weight: .black, design: .monospaced)).tracking(1.6)
                }
                .foregroundStyle(Color.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(busy || productId == nil ? Color.cream.opacity(0.12) : Color.whiskey))
            }
            .buttonStyle(PressScaleStyle())
            .disabled(busy || productId == nil)
        case .submit(let label, let run):
            Text("Happy with it? It goes live on the map the moment you tap.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            noteLine
            BizPrimaryButton(title: label, enabled: !busy, busy: busy) { submit(run) }
        }
    }

    @ViewBuilder
    private var noteLine: some View {
        if let note {
            if failed {
                ErrorLine(text: note)
            } else {
                Text(note)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func pay(orderId: UUID, productId: String?, quantity: Int) {
        guard let productId else { return }
        busy = true; note = nil; failed = false
        Task {
            switch await store.pay(orderId: orderId, productId: productId, quantity: quantity) {
            case .paid: dismiss(); onDone()
            case .cancelled: break
            case .pending: note = "Waiting for approval from your Apple account. It goes live as soon as that clears."
            case .failed(let why): note = why; failed = true
            }
            busy = false
        }
    }

    private func submit(_ run: @escaping () async throws -> Void) {
        busy = true; note = nil; failed = false
        Task {
            do { try await run(); dismiss(); onDone() }
            catch { note = BusinessService.friendly(error); failed = true }
            busy = false
        }
    }
}

// MARK: - Upgrade pop-up & tool sheets

/// What Business+ gets you, with the button. Opens whenever a Business bar
/// taps a Business+ thing: boost, events, card, push.
struct BusinessUpgradeSheet: View {
    @ObservedObject var svc: BusinessService
    let overview: BusinessOverview
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = BusinessStore.shared
    @State private var busy = false
    @State private var note: String?

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    SheetHeader(eyebrow: "", title: "Go Business+.", onClose: { dismiss() }, big: true)
                    PlanCard(plus: true,
                             price: store.displayPrice(BizTier.plus, fallbackSek: overview.product(BizTier.plus)?.amountSek ?? 0),
                             cta: "GO BUSINESS+", busy: busy, enabled: !busy) { upgrade() }
                    if let note {
                        Text(note).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(Color.cream.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Switches your plan through the App Store. Cancel any time.")
                        .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(Color.cream.opacity(0.5))
                    Spacer(minLength: 24)
                }
                .padding(20)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func upgrade() {
        busy = true; note = nil
        Task {
            switch await store.subscribe(business: overview.business.id, productId: BizTier.plus) {
            case .paid: await svc.loadOverview(overview.business.id); await svc.loadMine(); dismiss()
            case .cancelled: break
            case .pending: note = "Waiting for approval from your Apple account."
            case .failed(let why): note = why
            }
            busy = false
        }
    }
}

/// One business tool from the ☰ menu, as a sheet over whatever page is open.
struct BusinessToolSheet: View {
    let tool: BizTool
    @StateObject private var svc = BusinessService()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    SheetHeader(eyebrow: tool.title.uppercased(), title: tool.sheetTitle, onClose: { dismiss() })
                    if let b = svc.mine.first {
                        BusinessDashboard(summary: b, svc: svc, tool: tool)
                    } else if svc.loaded {
                        Text("No business account on this profile.")
                            .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(Color.cream.opacity(0.5))
                    } else {
                        ProgressView().tint(Color.whiskey).frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                    Spacer(minLength: 24)
                }
                .padding(20)
            }
        }
        .preferredColorScheme(.dark)
        .task { await svc.loadMine() }
    }
}

// MARK: - Admin review

/// The regulation desk: verify bars, approve and mark orders paid, tune
/// rates and limits. Admin only (the RPCs refuse everyone else).
struct BusinessReviewView: View {
    @StateObject private var svc = BusinessAdminService()
    @State private var tab = 0
    @State private var rejecting: AdminBusinessQueue.Order?
    @State private var reason = ""
    @State private var notes: [UUID: String] = [:]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    SheetHeader(eyebrow: "ADMIN", title: "Business desk", onClose: { dismiss() })
                    if let t = svc.toast {
                        Text(t).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Color.whiskey)
                    }
                    Picker("", selection: $tab) {
                        Text("Bars").tag(0)
                        Text("Orders").tag(1)
                        Text("Packs").tag(2)
                    }
                    .pickerStyle(.segmented)
                    if let q = svc.queue {
                        switch tab {
                        case 0: businesses(q)
                        case 1: orders(q)
                        default: products(q)
                        }
                    } else {
                        ProgressView().tint(Color.whiskey).frame(maxWidth: .infinity).padding(.vertical, 30)
                    }
                    Spacer(minLength: 24)
                }
                .padding(20)
            }
        }
        .preferredColorScheme(.dark)
        .task { await svc.load() }
        .alert("Reject this order?", isPresented: Binding(get: { rejecting != nil }, set: { if !$0 { rejecting = nil } })) {
            TextField("Reason the bar will see", text: $reason)
            Button("Reject", role: .destructive) {
                if let o = rejecting { Task { await svc.decide(o.id, "reject", reason: reason) } }
                rejecting = nil; reason = ""
            }
            Button("Cancel", role: .cancel) { rejecting = nil }
        }
    }

    // ── bars ──
    @ViewBuilder
    private func businesses(_ q: AdminBusinessQueue) -> some View {
        if q.businesses.isEmpty {
            Text("No bars claimed yet.").font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(Color.cream.opacity(0.5))
        }
        ForEach(q.businesses) { b in
            BizCard {
                HStack(spacing: 6) {
                    StatusPill(state: BizState(label: b.status.uppercased(),
                                               color: b.status == "approved" ? BizState.liveGreen : b.status == "pending" ? .bronze : .whiskey))
                    if let t = b.tier, t != "none" {
                        StatusPill(state: BizState(label: BizTier.label(t) + (b.followers.map { " · \($0) FOLLOWERS" } ?? ""), color: .whiskey))
                    }
                    Spacer()
                    Text(b.createdAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Color.cream.opacity(0.4))
                }
                Text(b.name).font(.system(size: 16, weight: .heavy, design: .rounded)).foregroundStyle(Color.cream)
                Text("\(b.venueName)\(b.venueCity.map { " · \($0)" } ?? "")\(b.venueCountry.map { " \($0)" } ?? "")")
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Color.cream.opacity(0.7))
                Text("Owner \(b.ownerName ?? "?")\(b.ownerUsername.map { " @\($0)" } ?? "") · \(b.contactEmail)\(b.contactPhone.map { " · \($0)" } ?? "")\(b.orgNumber.map { " · org \($0)" } ?? "")")
                    .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Color.cream.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                TextField("", text: Binding(get: { notes[b.id] ?? b.adminNote ?? "" }, set: { notes[b.id] = $0 }),
                          prompt: Text("Note to the bar (optional)").foregroundStyle(Color.cream.opacity(0.35)))
                    .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(Color.cream).tint(Color.whiskey)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.cream.opacity(0.05)))
                HStack(spacing: 8) {
                    if b.status != "approved" { adminButton("APPROVE", .fill) { Task { await svc.setStatus(b.id, "approved", note: notes[b.id]) } } }
                    if b.status == "approved" { adminButton("SUSPEND", .outline) { Task { await svc.setStatus(b.id, "suspended", note: notes[b.id]) } } }
                    if b.status == "pending" { adminButton("REJECT", .danger) { Task { await svc.setStatus(b.id, "rejected", note: notes[b.id]) } } }
                }
            }
        }
    }

    // ── orders ──
    @ViewBuilder
    private func orders(_ q: AdminBusinessQueue) -> some View {
        if q.orders.isEmpty {
            Text("Queue is empty.").font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(Color.cream.opacity(0.5))
        }
        ForEach(q.orders) { o in
            BizCard {
                HStack(spacing: 6) {
                    Text(o.kind.uppercased())
                        .font(.system(size: 8, weight: .black, design: .monospaced)).tracking(0.8)
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(Color.whiskey))
                    StatusPill(state: BizState.of(orderStatus: o.status, paid: o.paid, live: true, startsAt: nil, endsAt: nil))
                    Spacer()
                    Text(kr(o.amountSek)).font(.system(size: 13, weight: .black, design: .rounded)).foregroundStyle(Color.cream)
                }
                Text("\(o.businessName) · \(o.venueName)\(o.venueCity.map { " · \($0)" } ?? "")")
                    .font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(Color.cream.opacity(0.8))
                if let d = o.detail {
                    Text(d).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Color.cream.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let pid = o.productId {
                    Text("\(pid)\((o.quantity ?? 1) > 1 ? " × \(o.quantity ?? 1)" : "")\(o.appleTransactionId.map { " · txn \($0)" } ?? "")\(o.paidAt.map { " · paid \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")")
                        .font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(Color.cream.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .top, spacing: 10) {
                    if let s = o.billboardImageUrl ?? o.imageUrl, let u = URL(string: s) {
                        DownsampledAsyncImage(url: u, targetPoints: 160, fill: true, placeholder: Color.smoke)
                            .frame(width: 72, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        if let t = o.title { Text(t).font(.system(size: 14, weight: .heavy, design: .rounded)).foregroundStyle(Color.cream) }
                        if let b = o.body { Text(b).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(Color.cream.opacity(0.7)) }
                        if let s = o.sendAt {
                            Text("Send \(s.formatted(date: .abbreviated, time: .shortened)) · up to \(o.audienceCap ?? 0)")
                                .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Color.cream.opacity(0.5))
                        }
                    }
                }
                if o.status != "rejected" {
                    HStack(spacing: 8) {
                        if o.status == "pending" { adminButton("APPROVE", .outline) { Task { await svc.decide(o.id, "approve") } } }
                        if !o.paid { adminButton("PAID MANUALLY", .fill) { Task { await svc.decide(o.id, "paid") } } }
                        else { adminButton("UNPAID", .outline) { Task { await svc.decide(o.id, "unpaid") } } }
                        adminButton("REJECT", .danger) { rejecting = o }
                    }
                }
            }
        }
    }

    // ── packs & limits ──
    private func products(_ q: AdminBusinessQueue) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            kicker("PRODUCTS · DISPLAY PRICE, SEK")
            Text("Tiers, boosts, cards and pushes. The real price is whatever App Store Connect says — keep these in step so bars see the right number before StoreKit loads.")
                .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(Color.cream.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(q.products) { p in
                NumberRow(label: p.label, key: p.productId, value: p.amountSek, suffix: "kr") { v in Task { await svc.setPrice(p.productId, v) } }
            }
            kicker("LIMITS").padding(.top, 8)
            ForEach(q.limits) { l in
                NumberRow(label: l.label, key: l.key, value: l.value, suffix: "") { v in Task { await svc.setLimit(l.key, v) } }
            }
        }
    }

    private enum Style { case fill, outline, danger }
    private func adminButton(_ title: String, _ style: Style, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .black, design: .monospaced)).tracking(1.2)
                .foregroundStyle(style == .fill ? Color.ink : style == .danger ? BizState.rejectRed : Color.whiskey)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(style == .fill ? Color.whiskey : style == .danger ? BizState.rejectRed.opacity(0.1) : Color.whiskey.opacity(0.1)))
        }
        .buttonStyle(PressScaleStyle())
    }
}

private struct NumberRow: View {
    let label: String
    let key: String
    let value: Int
    let suffix: String
    let onSave: (Int) -> Void
    @State private var text: String = ""

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Color.cream)
                Text(key).font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(Color.cream.opacity(0.4))
            }
            Spacer()
            TextField("", text: $text)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 14, weight: .black, design: .rounded))
                .foregroundStyle(Color.whiskey)
                .tint(Color.whiskey)
                .frame(width: 80)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.cream.opacity(0.05)))
                .onSubmit { if let v = Int(text), v != value { onSave(v) } }
            if !suffix.isEmpty {
                Text(suffix).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(Color.cream.opacity(0.5))
            }
        }
        .onAppear { text = "\(value)" }
        .onChange(of: value) { _, v in text = "\(v)" }
    }
}
