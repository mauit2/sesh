//
//  ContentView.swift
//  sesh.app
//
//  SETUP:
//  1. Fill in Secrets.supabaseURL and Secrets.supabaseAnonKey below with your
//     Supabase project's values (Settings → API).
//  2. Make sure the `profiles` table + RLS policies exist (see setup guide).
//  3. Turn OFF email confirmation in Auth → Providers → Email while developing.
//

import SwiftUI
import Combine
import PhotosUI
import UIKit
import CoreLocation
import MapKit
import Supabase

// MARK: - Secrets (replace with your values)

enum Secrets {
    static let supabaseURL = URL(string: "https://lltuozmbxacxiepardys.supabase.co")!
    static let supabaseAnonKey = "sb_publishable_CXlmRXTLRfX0pYysE7vbKw_vC88ny42"
}

let supabase = SupabaseClient(
    supabaseURL: Secrets.supabaseURL,
    supabaseKey: Secrets.supabaseAnonKey
)

// MARK: - Sex

enum Sex: String, CaseIterable, Identifiable, Codable {
    case male, female
    var id: String { rawValue }
    var short: String { self == .male ? "M" : "F" }
    var label: String { self == .male ? "Male" : "Female" }
    var r: Double { self == .male ? 0.68 : 0.55 }
}

// MARK: - Profile

struct Profile: Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var age: Int
    var sex: Sex
    var weightKg: Double
    var avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case id, name, age, sex
        case weightKg = "weight_kg"
        case avatarURL = "avatar_url"
    }
}

// MARK: - Status + messages

struct VibeMessage: Hashable {
    let headline: String
    let advice: String
}

enum Status: String {
    case sober, buzzed, impaired, drunk, danger

    var label: String {
        switch self {
        case .sober:    return "Clear"
        case .buzzed:   return "Warming"
        case .impaired: return "Impaired"
        case .drunk:    return "Lit"
        case .danger:   return "Danger"
        }
    }

    var heroLabel: String {
        switch self {
        case .sober:    return "You're good"
        case .buzzed:   return "Warming up"
        case .impaired: return "Feeling it"
        case .drunk:    return "You're lit"
        case .danger:   return "Slow down"
        }
    }

    var heroSubtitle: String {
        switch self {
        case .sober:    return "Barely a trace. Still sharp."
        case .buzzed:   return "A little glow. Hydrate."
        case .impaired: return "Reflexes are slowing down."
        case .drunk:    return "You're in the zone — don't drive."
        case .danger:   return "This is too much. Water + food."
        }
    }

    var color: Color {
        switch self {
        case .sober:    return Color(red: 0.51, green: 0.72, blue: 0.48)
        case .buzzed:   return Color(red: 0.91, green: 0.69, blue: 0.29)
        case .impaired: return Color(red: 0.91, green: 0.58, blue: 0.29)
        case .drunk:    return Color(red: 0.85, green: 0.32, blue: 0.23)
        case .danger:   return Color(red: 0.72, green: 0.18, blue: 0.12)
        }
    }

    var messages: [VibeMessage] {
        switch self {
        case .sober:
            return [
                VibeMessage(headline: "Weak. You're practically sipping sparkling water.",
                            advice: "Pace the night. Keep water nearby."),
                VibeMessage(headline: "Warm-up round. The night hasn't started yet.",
                            advice: "Eat before round two. Water on the side."),
                VibeMessage(headline: "Honestly? You should probably have a cig — this round doesn't count.",
                            advice: "Set the pace. Hydration is a personality trait."),
                VibeMessage(headline: "Dead sober behaviour. Your liver is filing for unemployment.",
                            advice: "Eat now or pace later. Water saves the night."),
                VibeMessage(headline: "Reading the menu like a sommelier. Adorable.",
                            advice: "Take it easy. The night is long."),
            ]
        case .buzzed:
            return [
                VibeMessage(headline: "Warmed up. Smooth-talker mode unlocked.",
                            advice: "Eat something solid. Water between rounds."),
                VibeMessage(headline: "Confidence rising. Keep your phone in your pocket.",
                            advice: "Nibble on food. Alternate with water."),
                VibeMessage(headline: "You're funnier now. Statistically, only to yourself.",
                            advice: "Snack break. One water before the next drink."),
                VibeMessage(headline: "Tipsy. Your texts are about to get unhinged.",
                            advice: "Eat carbs. Stay with the group."),
                VibeMessage(headline: "Officially flirty. Sober-you would cringe.",
                            advice: "Slow it down. Hydrate."),
            ]
        case .impaired:
            return [
                VibeMessage(headline: "Your moves are sick. Dance like nobody's filming.",
                            advice: "Hand over your car keys now. No driving — not even a block."),
                VibeMessage(headline: "Main-character energy. You're over the EU limit.",
                            advice: "Slow the pace. Double up on water."),
                VibeMessage(headline: "You're explaining your dissertation to strangers. Please stop.",
                            advice: "Water round. Eat. No driving — period."),
                VibeMessage(headline: "Convinced you can sing. You cannot.",
                            advice: "Hand the keys to a friend. Water now."),
                VibeMessage(headline: "Buying shots for the bar. Your bank account just sighed.",
                            advice: "Pace the next hour. Eat something."),
            ]
        case .drunk:
            return [
                VibeMessage(headline: "Lit. Great time to confess your love for someone.",
                            advice: "Never drive. Eat carbs. Text your safety buddy."),
                VibeMessage(headline: "Peak charisma, worst judgment. Enjoy the ride.",
                            advice: "Rideshare only. Zero steering. Phone in pocket."),
                VibeMessage(headline: "Your body wants to call your ex. DON'T.",
                            advice: "Water. Bread. Friends. In that order."),
                VibeMessage(headline: "You think you're whispering. You are not.",
                            advice: "Cab home. Big glass of water. Sleep on your side."),
                VibeMessage(headline: "Future-you is already cringing at present-you.",
                            advice: "Stop drinking. Get food. Stay with friends."),
                VibeMessage(headline: "Forming opinions on geopolitics. Nobody asked.",
                            advice: "Water now. Cab — never the wheel."),
            ]
        case .danger:
            return [
                VibeMessage(headline: "Blackout zone. Step AWAY from the phone.",
                            advice: "Water, not drinks. Stay with a sober friend."),
                VibeMessage(headline: "You're cooked. Do NOT text your ex.",
                            advice: "Above 0.30 consider medical help. Never alone."),
                VibeMessage(headline: "Beyond lit. Time to become a water champion.",
                            advice: "Stop drinking. Eat. Tell someone trustworthy where you are."),
                VibeMessage(headline: "This is a tomorrow problem becoming a tonight problem.",
                            advice: "Stop. Water. Stay upright. Tell a friend."),
                VibeMessage(headline: "Officially in 'whose bed is this' territory.",
                            advice: "No more drinks. Sober adult on standby."),
            ]
        }
    }
}

// MARK: - Palette

private extension Color {
    static let ink     = Color(red: 0.043, green: 0.039, blue: 0.031)
    static let inkElev = Color(red: 0.075, green: 0.067, blue: 0.055)
    static let whiskey = Color(red: 0.910, green: 0.659, blue: 0.290)
    static let cream   = Color(red: 0.961, green: 0.929, blue: 0.878)
    static let bronze  = Color(red: 0.541, green: 0.498, blue: 0.431)
    static let smoke   = Color(red: 0.192, green: 0.176, blue: 0.149)
    static let stout   = Color(red: 0.035, green: 0.020, blue: 0.010)
    static let foam    = Color(red: 0.975, green: 0.915, blue: 0.810)
}

// MARK: - Drinks catalog

enum DrinkCategory: String, CaseIterable, Identifiable, Codable {
    case beer, wine, sparkling, whisky, vodka, gin, cocktail, cider
    var id: String { rawValue }

    var label: String {
        switch self {
        case .beer:      return "Beer"
        case .wine:      return "Wine"
        case .sparkling: return "Sparkling"
        case .whisky:    return "Whisky"
        case .vodka:     return "Vodka"
        case .gin:       return "Gin"
        case .cocktail:  return "Cocktail"
        case .cider:     return "Cider"
        }
    }

    var emoji: String {
        switch self {
        case .beer:      return "🍺"
        case .wine:      return "🍷"
        case .sparkling: return "🥂"
        case .whisky:    return "🥃"
        case .vodka:     return "👙"
        case .gin:       return "🍹"
        case .cocktail:  return "🍸"
        case .cider:     return "🐱"
        }
    }
}

enum GlyphOverride: Hashable {
    case guinness
}

struct DrinkOption: Hashable {
    let category: DrinkCategory
    let name: String
    let detail: String
    let volumeML: Double
    let abv: Double
    var customGlyph: GlyphOverride? = nil
    var grams: Double { volumeML * abv * 0.789 }
}

struct OrderItem: Identifiable {
    let id: UUID
    let option: DrinkOption
    var shared: Bool
    init(id: UUID = UUID(), option: DrinkOption, shared: Bool = false) {
        self.id = id
        self.option = option
        self.shared = shared
    }
}

struct OrderKey: Hashable {
    let option: DrinkOption
    let shared: Bool
}

struct OrderGroup: Identifiable {
    let option: DrinkOption
    let shared: Bool
    let itemIDs: [OrderItem.ID]
    var count: Int { itemIDs.count }
    var id: OrderKey { OrderKey(option: option, shared: shared) }
}

func aggregateOrder(_ order: [OrderItem]) -> [OrderGroup] {
    var keyOrder: [OrderKey] = []
    var groups: [OrderKey: [OrderItem.ID]] = [:]
    for item in order {
        let k = OrderKey(option: item.option, shared: item.shared)
        if groups[k] == nil { keyOrder.append(k) }
        groups[k, default: []].append(item.id)
    }
    return keyOrder.map { key in
        OrderGroup(option: key.option, shared: key.shared, itemIDs: groups[key] ?? [])
    }
}

enum DrinkCatalog {
    static var allOptions: [DrinkOption] {
        DrinkCategory.allCases.flatMap { options(for: $0) }
    }

    static func options(for category: DrinkCategory) -> [DrinkOption] {
        switch category {
        case .beer:
            return [
                .init(category: .beer, name: "Small beer", detail: "33 cl · 5%",  volumeML: 330, abv: 0.05),
                .init(category: .beer, name: "Large beer", detail: "50 cl · 5%",  volumeML: 500, abv: 0.05),
                .init(category: .beer, name: "Pint",       detail: "57 cl · 5%",  volumeML: 568, abv: 0.05),
                .init(category: .beer, name: "Guinness",   detail: "Pint · 4.2%", volumeML: 568, abv: 0.042, customGlyph: .guinness),
            ]
        case .wine:
            return [
                .init(category: .wine, name: "Glass of wine",  detail: "15 cl · 12%", volumeML: 150, abv: 0.12),
                .init(category: .wine, name: "Large glass",    detail: "25 cl · 12%", volumeML: 250, abv: 0.12),
                .init(category: .wine, name: "Bottle of wine", detail: "75 cl · 12%", volumeML: 750, abv: 0.12),
            ]
        case .sparkling:
            return [
                .init(category: .sparkling, name: "Champagne flute",     detail: "12 cl · 12%", volumeML: 120, abv: 0.12),
                .init(category: .sparkling, name: "Bottle of champagne", detail: "75 cl · 12%", volumeML: 750, abv: 0.12),
            ]
        case .whisky:
            return [
                .init(category: .whisky, name: "Single whisky", detail: "2.5 cl · 40%", volumeML: 25, abv: 0.40),
                .init(category: .whisky, name: "Double whisky", detail: "5 cl · 40%",   volumeML: 50, abv: 0.40),
            ]
        case .vodka:
            return [
                .init(category: .vodka, name: "Shot of vodka",   detail: "4 cl · 40%",  volumeML: 40,  abv: 0.40),
                .init(category: .vodka, name: "Double shot",     detail: "8 cl · 40%",  volumeML: 80,  abv: 0.40),
                .init(category: .vodka, name: "Bottle of vodka", detail: "70 cl · 40%", volumeML: 700, abv: 0.40),
            ]
        case .gin:
            return [
                .init(category: .gin, name: "Single gin",  detail: "2.5 cl · 40%", volumeML: 25, abv: 0.40),
                .init(category: .gin, name: "Double gin",  detail: "5 cl · 40%",   volumeML: 50, abv: 0.40),
                .init(category: .gin, name: "Gin & tonic", detail: "4 cl · 40%",   volumeML: 40, abv: 0.40),
            ]
        case .cocktail:
            return [
                .init(category: .cocktail, name: "Cocktail",        detail: "1.5 shots equiv", volumeML: 60,  abv: 0.40),
                .init(category: .cocktail, name: "Strong cocktail", detail: "2.5 shots equiv", volumeML: 100, abv: 0.40),
            ]
        case .cider:
            return [
                .init(category: .cider, name: "Bottle of cider", detail: "33 cl · 4.5%", volumeML: 330, abv: 0.045),
                .init(category: .cider, name: "Pint of cider",   detail: "50 cl · 4.5%", volumeML: 500, abv: 0.045),
            ]
        }
    }
}

// MARK: - Group sesh models

struct SeshSession: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let hostId: UUID
    let joinCode: String
    let createdAt: Date
    /// Legacy "is this session alive at all?" flag. Per-mode end now
    /// drives the actual lifecycle (see `activePlan`/`activeLive`); we
    /// leave `active` permanently TRUE on every row from migration 007
    /// onward. Reads still tolerate it being either value so this
    /// struct keeps decoding regardless of when the host's row was
    /// last touched.
    var active: Bool
    /// Per-mode liveness flags introduced in migration 007. Default to
    /// TRUE for back-compat decoding so a fetch against an environment
    /// that hasn't run the migration yet still produces a sensible
    /// session struct (it'll behave as if both modes are alive, which
    /// matches the legacy single-`active` semantics).
    var activePlan: Bool
    var activeLive: Bool
    enum CodingKeys: String, CodingKey {
        case id
        case hostId = "host_id"
        case joinCode = "join_code"
        case createdAt = "created_at"
        case active
        case activePlan = "active_plan"
        case activeLive = "active_live"
    }
    init(
        id: UUID,
        hostId: UUID,
        joinCode: String,
        createdAt: Date,
        active: Bool,
        activePlan: Bool = true,
        activeLive: Bool = true
    ) {
        self.id = id
        self.hostId = hostId
        self.joinCode = joinCode
        self.createdAt = createdAt
        self.active = active
        self.activePlan = activePlan
        self.activeLive = activeLive
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.hostId = try c.decode(UUID.self, forKey: .hostId)
        self.joinCode = try c.decode(String.self, forKey: .joinCode)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.active = (try c.decodeIfPresent(Bool.self, forKey: .active)) ?? true
        self.activePlan = (try c.decodeIfPresent(Bool.self, forKey: .activePlan)) ?? true
        self.activeLive = (try c.decodeIfPresent(Bool.self, forKey: .activeLive)) ?? true
    }
}

struct SessionMember: Codable, Equatable, Hashable {
    let sessionId: UUID
    let profileId: UUID
    let joinedAt: Date
    /// Per-member duration slider value (hours), synced across phones.
    /// `nil` means the member hasn't set one yet — callers should fall back
    /// to a derived value (e.g. time since their first drink).
    var durationHours: Double?
    /// Per-mode "is this user still in the session in <mode>?" flags.
    /// Introduced in migration 007 so plan and live can be left/joined
    /// independently when both modes happen to track the same session.
    /// Default to TRUE on decode for back-compat with environments that
    /// haven't run the migration yet — the fallback matches legacy
    /// behaviour ("if you're a member at all, you're a member in both
    /// modes").
    var inPlan: Bool
    var inLive: Bool
    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case profileId = "profile_id"
        case joinedAt = "joined_at"
        case durationHours = "duration_hours"
        case inPlan = "in_plan"
        case inLive = "in_live"
    }
    init(
        sessionId: UUID,
        profileId: UUID,
        joinedAt: Date,
        durationHours: Double? = nil,
        inPlan: Bool = true,
        inLive: Bool = true
    ) {
        self.sessionId = sessionId
        self.profileId = profileId
        self.joinedAt = joinedAt
        self.durationHours = durationHours
        self.inPlan = inPlan
        self.inLive = inLive
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionId = try c.decode(UUID.self, forKey: .sessionId)
        self.profileId = try c.decode(UUID.self, forKey: .profileId)
        self.joinedAt = try c.decode(Date.self, forKey: .joinedAt)
        self.durationHours = try c.decodeIfPresent(Double.self, forKey: .durationHours)
        self.inPlan = (try c.decodeIfPresent(Bool.self, forKey: .inPlan)) ?? true
        self.inLive = (try c.decodeIfPresent(Bool.self, forKey: .inLive)) ?? true
    }
}

// MARK: - Invites
//
// In-app invite row, mirrors the `invites` table from migration 008. Status
// is a string instead of an enum so that future server-side additions to the
// state machine (e.g. `expired`) don't break decoding on older clients —
// the UI only branches on `pending` and otherwise treats the row as inert.
struct Invite: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let sessionId: UUID
    let senderId: UUID
    let recipientId: UUID
    let joinCode: String
    let createdAt: Date
    var status: String
    var respondedAt: Date?
    /// Which mode the sender was in when they fired this invite. The
    /// recipient's "Accept" handler reads this to decide whether to call
    /// planGroup.join or liveGroup.join — without it, a live host's
    /// invite would drop the recipient into the plan half of the session
    /// and they'd never see the live activity. String-typed (not an
    /// enum) for the same forward-compat reason as `status`. Defaults to
    /// "plan" via the DB-side default, so legacy rows decode cleanly.
    var mode: String = "plan"
    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case senderId = "sender_id"
        case recipientId = "recipient_id"
        case joinCode = "join_code"
        case createdAt = "created_at"
        case status
        case respondedAt = "responded_at"
        case mode
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.sessionId = try c.decode(UUID.self, forKey: .sessionId)
        self.senderId = try c.decode(UUID.self, forKey: .senderId)
        self.recipientId = try c.decode(UUID.self, forKey: .recipientId)
        self.joinCode = try c.decode(String.self, forKey: .joinCode)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.status = try c.decode(String.self, forKey: .status)
        self.respondedAt = try c.decodeIfPresent(Date.self, forKey: .respondedAt)
        self.mode = (try c.decodeIfPresent(String.self, forKey: .mode)) ?? "plan"
    }
}

struct SessionDrink: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let sessionId: UUID
    let profileId: UUID
    let drinkName: String
    let volumeMl: Double
    let abv: Double
    let createdAt: Date
    var shared: Bool = false
    /// Whether this drink belongs to the Live Sesh ledger or the regular
    /// (manual-duration) ledger. The two are intentionally separate so
    /// numbers in one mode don't bleed into the other. Defaults to false
    /// for backwards-compat with rows inserted before this column existed.
    var live: Bool = false
    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case profileId = "profile_id"
        case drinkName = "drink_name"
        case volumeMl = "volume_ml"
        case abv
        case createdAt = "created_at"
        case shared
        case live
    }
    var grams: Double { volumeMl * abv * 0.789 }
}

// MARK: - Venues
//
// Phase 1 of the location feature: a `Venue` is a real-world bar/place
// with coordinates and (optionally) a list of "specials" — drinks that
// only show up in the picker while the user is checked in there.
// Phase 2 (later) will layer in featured curation, photos, and richer
// proximity-based UI; for now the app only needs name + coordinates +
// specials.

/// Trust tier for a venue. Mirrors `venues.source` in the DB.
/// - curated: vetted by us. Only tier allowed to carry specials.
/// - mapkit:  created on-the-fly from MKLocalSearch when a user checks in.
/// - user:    reserved for a future "add a place we missed" flow.
enum VenueSource: String, Codable, Equatable, Hashable {
    case curated
    case mapkit
    case user
}

struct Venue: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let name: String
    let address: String?
    let city: String?
    let lat: Double
    let lon: Double
    var isFeatured: Bool = false
    var source: VenueSource = .curated
    var externalId: String? = nil
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, address, city, lat, lon
        case isFeatured = "is_featured"
        case source
        case externalId = "external_id"
        case createdAt  = "created_at"
    }

    init(
        id: UUID,
        name: String,
        address: String?,
        city: String?,
        lat: Double,
        lon: Double,
        isFeatured: Bool = false,
        source: VenueSource = .curated,
        externalId: String? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.city = city
        self.lat = lat
        self.lon = lon
        self.isFeatured = isFeatured
        self.source = source
        self.externalId = externalId
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id         = try c.decode(UUID.self,   forKey: .id)
        name       = try c.decode(String.self, forKey: .name)
        address    = try c.decodeIfPresent(String.self, forKey: .address)
        city       = try c.decodeIfPresent(String.self, forKey: .city)
        lat        = try c.decode(Double.self, forKey: .lat)
        lon        = try c.decode(Double.self, forKey: .lon)
        isFeatured = (try c.decodeIfPresent(Bool.self, forKey: .isFeatured)) ?? false
        source     = (try c.decodeIfPresent(VenueSource.self, forKey: .source)) ?? .curated
        externalId = try c.decodeIfPresent(String.self, forKey: .externalId)
        createdAt  = try c.decode(Date.self,   forKey: .createdAt)
    }

    /// Human-readable single-line location: "Vasagatan 1, Göteborg".
    var displayLocation: String {
        [address, city].compactMap { $0 }.joined(separator: ", ")
    }
}

/// A drink that only exists at a specific venue. Plugs into the existing
/// BAC math by exposing the same `volumeML` / `abv` shape as DrinkOption,
/// so the rest of the picker / order / Widmark code doesn't need to know
/// venue specials are a different table.
struct VenueSpecial: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let venueId: UUID
    let name: String
    let detail: String?
    let volumeMl: Double
    let abv: Double
    let category: String
    let emoji: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case venueId   = "venue_id"
        case name, detail
        case volumeMl  = "volume_ml"
        case abv, category, emoji
        case createdAt = "created_at"
    }

    /// Convert to a DrinkOption so the rest of the UI / BAC math can
    /// treat specials identically to catalog drinks. Unknown category
    /// strings fall back to .cocktail (the closest catch-all).
    func asDrinkOption() -> DrinkOption {
        let cat = DrinkCategory(rawValue: category) ?? .cocktail
        let derivedDetail = detail
            ?? "\(Int(volumeMl)) ml · \(Int((abv * 100).rounded()))%"
        return DrinkOption(
            category: cat,
            name: name,
            detail: derivedDetail,
            volumeML: volumeMl,
            abv: abv
        )
    }
}

/// Name-matched local "secret menu" — when a user checks in to a venue
/// whose name matches one of the patterns below, these specials are
/// attached to that venue in memory and surface in the drink picker.
///
/// Why this isn't a curated featured-venue list anymore:
///   • The app no longer ships a seeded venue catalog. Users find their
///     bar via Apple Maps search (MKLocalSearch) like they would any
///     other place — search "Handelspuben", tap it, you're checked in.
///   • The specials still attach automatically because we recognise the
///     venue by name after check-in. The user gets the same result
///     without us pretending to curate a venue we don't run.
///
/// Each pattern is a case-insensitive substring match against
/// `Venue.name`. The matcher returns `VenueSpecial` rows bound to the
/// caller's venue id (we don't persist them to Supabase — they're
/// recognised locally on every checkout/check-in, so the venue id is
/// whatever the MapKit insert produced).
private struct LocalSpecialTemplate {
    let name: String
    let detail: String
    let volumeMl: Double
    let abv: Double
    let category: String
    let emoji: String
}

enum LocalSpecialsCatalog {
    /// Pattern → templates. Add a new bar here and any MapKit pick of
    /// that bar instantly gets its menu, no migration required.
    private static let byNamePattern: [(pattern: String, templates: [LocalSpecialTemplate])] = [
        ("handelspuben", [
            LocalSpecialTemplate(
                name: "Fittkittlaren",
                detail: "50 cl jug · 18 cl @ 40%",
                volumeMl: 500,
                abv: 0.144,
                category: "cocktail",
                emoji: "🍹"
            ),
            LocalSpecialTemplate(
                name: "Döda mig",
                detail: "50 cl jug · 18 cl @ 40%",
                volumeMl: 500,
                abv: 0.144,
                category: "cocktail",
                emoji: "☠️"
            ),
        ]),
    ]

    /// Specials for any venue whose name contains a known pattern,
    /// bound to the caller's `venueId`. Empty when no pattern matches.
    /// Synthesised UUIDs (each call is local-only, never persisted) —
    /// the picker only reads `name` / `detail` / `emoji` / volume / abv,
    /// so id stability doesn't matter for rendering.
    static func specials(forVenueNamed name: String, venueId: UUID) -> [VenueSpecial] {
        let lower = name.lowercased()
        for entry in byNamePattern where lower.contains(entry.pattern) {
            return entry.templates.map { tpl in
                VenueSpecial(
                    id: UUID(),
                    venueId: venueId,
                    name: tpl.name,
                    detail: tpl.detail,
                    volumeMl: tpl.volumeMl,
                    abv: tpl.abv,
                    category: tpl.category,
                    emoji: tpl.emoji,
                    createdAt: Date(timeIntervalSince1970: 0)
                )
            }
        }
        return []
    }
}

// MARK: - Auth

enum AuthError: LocalizedError {
    case emailConfirmationRequired
    case profileMissing

    var errorDescription: String? {
        switch self {
        case .emailConfirmationRequired:
            return "Check your email to confirm the account, then sign in."
        case .profileMissing:
            return "We couldn't find your profile. Try signing up again."
        }
    }
}

@MainActor
final class AuthService: ObservableObject {
    enum State: Equatable {
        case loading
        case signedOut
        case signedIn(Profile)
    }

    @Published var state: State = .loading {
        didSet { syncProfileCacheForLockScreen() }
    }

    /// Mirror the user's BAC-relevant profile primitives into
    /// UserDefaults so the lock-screen App Intent can run Widmark
    /// without booting the SwiftUI hierarchy. See `LockScreenStorageKeys`
    /// — those keys are the contract between this method and
    /// `LockScreenDrinkLogger.append`. Cleared on sign-out so the
    /// next user doesn't inherit the previous user's body weight.
    private func syncProfileCacheForLockScreen() {
        switch state {
        case .signedIn(let p):
            UserDefaults.standard.set(p.weightKg, forKey: LockScreenStorageKeys.profileWeightKg)
            UserDefaults.standard.set(p.sex.rawValue, forKey: LockScreenStorageKeys.profileSexRaw)
        case .signedOut, .loading:
            UserDefaults.standard.removeObject(forKey: LockScreenStorageKeys.profileWeightKg)
            UserDefaults.standard.removeObject(forKey: LockScreenStorageKeys.profileSexRaw)
        }
    }

    init() {
        Task { [weak self] in
            guard let self else { return }
            for await (event, session) in supabase.auth.authStateChanges {
                await self.handle(event: event, session: session)
            }
        }
    }

    private func handle(event: AuthChangeEvent, session: Session?) async {
        switch event {
        case .initialSession, .signedIn, .tokenRefreshed, .userUpdated:
            if let userId = session?.user.id,
               let profile = try? await loadProfile(userId: userId) {
                state = .signedIn(profile)
            } else {
                state = .signedOut
            }
        case .signedOut:
            state = .signedOut
        default:
            break
        }
    }

    func signUp(email: String, password: String, name: String, age: Int, sex: Sex, weightKg: Double, avatarData: Data? = nil) async throws {
        let response = try await supabase.auth.signUp(email: email, password: password)
        guard response.session != nil else {
            throw AuthError.emailConfirmationRequired
        }
        let userId = response.user.id

        let avatarURL = try? await uploadAvatar(data: avatarData, userId: userId)

        struct InsertProfile: Encodable {
            let id: String
            let name: String
            let age: Int
            let sex: String
            let weight_kg: Double
            let avatar_url: String?
        }

        let payload = InsertProfile(
            id: userId.uuidString.lowercased(),
            name: name,
            age: age,
            sex: sex.rawValue,
            weight_kg: weightKg,
            avatar_url: avatarURL
        )
        try await supabase.from("profiles").insert(payload).execute()

        let profile = try await loadProfile(userId: userId)
        state = .signedIn(profile)
    }

    func signIn(email: String, password: String) async throws {
        let session = try await supabase.auth.signIn(email: email, password: password)
        let profile = try await loadProfile(userId: session.user.id)
        state = .signedIn(profile)
    }

    func signOut() async throws {
        try await supabase.auth.signOut()
        // Tear down any in-flight lock-screen activity AND wipe the
        // home-screen widget snapshot. The next user to sign in
        // shouldn't inherit the previous user's BAC card OR see
        // their roster on the home-screen widget. Local LiveSeshState
        // gets cleared by the auth state transition anyway — these
        // calls keep the cross-process surfaces in lockstep.
        await MainActor.run {
            LiveActivityController.shared.end()
            WidgetSharedStore.clear()
        }
        state = .signedOut
    }

    func updateProfile(_ profile: Profile, newAvatarData: Data? = nil, removeAvatar: Bool = false) async throws {
        var finalURL = profile.avatarURL
        if let data = newAvatarData {
            finalURL = try await uploadAvatar(data: data, userId: profile.id)
        } else if removeAvatar {
            finalURL = nil
            _ = try? await supabase.storage.from("avatars").remove(paths: ["\(profile.id.uuidString.lowercased())/avatar.jpg"])
        }

        struct UpdatePayload: Encodable {
            let name: String
            let age: Int
            let sex: String
            let weight_kg: Double
            let avatar_url: String?
        }
        let payload = UpdatePayload(
            name: profile.name,
            age: profile.age,
            sex: profile.sex.rawValue,
            weight_kg: profile.weightKg,
            avatar_url: finalURL
        )
        try await supabase
            .from("profiles")
            .update(payload)
            .eq("id", value: profile.id.uuidString.lowercased())
            .execute()

        var updated = profile
        updated.avatarURL = finalURL
        state = .signedIn(updated)
    }

    private func uploadAvatar(data: Data?, userId: UUID) async throws -> String? {
        guard let data else { return nil }
        let path = "\(userId.uuidString.lowercased())/avatar.jpg"
        _ = try await supabase.storage
            .from("avatars")
            .upload(
                path,
                data: data,
                options: FileOptions(contentType: "image/jpeg", upsert: true)
            )
        let url = try supabase.storage.from("avatars").getPublicURL(path: path)
        // Add a cache-buster so AsyncImage re-fetches after replace
        return url.absoluteString + "?v=\(Int(Date().timeIntervalSince1970))"
    }

    private func loadProfile(userId: UUID) async throws -> Profile {
        let profile: Profile = try await supabase
            .from("profiles")
            .select()
            .eq("id", value: userId.uuidString.lowercased())
            .single()
            .execute()
            .value
        return profile
    }
}

// MARK: - Session service (group sesh)

@MainActor
final class SessionService: ObservableObject {
    @Published var session: SeshSession?
    @Published var members: [SessionMember] = []
    @Published var memberProfiles: [UUID: Profile] = [:]
    @Published var drinks: [SessionDrink] = []
    @Published var error: String?
    @Published var busy = false

    private var pollTask: Task<Void, Never>?

    /// Which mode this store powers. Two stores live in SessionView
    /// (one for PLAN, one for LIVE) so a user can be in two unrelated
    /// groups at the same time. Determines:
    ///   - the `live` flag stamped on every drink this store inserts,
    ///   - which slice of `drinks` the helpers below filter to,
    ///   - the UserDefaults key used to remember which session this
    ///     store was last in (so resumeIfAny picks the right one on
    ///     relaunch even when the user has different sessions per mode).
    let scope: SeshMode

    /// The OTHER store. Set by SessionView after both are constructed.
    /// Used by `leave()` to avoid deleting the shared session_members
    /// row when both stores happen to track the same session — without
    /// this, leaving one mode would yank the user out of the other too.
    weak var cousin: SessionService?

    init(scope: SeshMode) {
        self.scope = scope
    }

    /// True for live store, false for plan. Stamped on every drink this
    /// store inserts and used as the in-memory filter for ledger slices.
    private var scopeLive: Bool { scope == .live }

    // ---------------------------------------------------------------
    // Per-mode column helpers (migration 007). These keep the per-scope
    // querying code from sprouting `if scope == .plan` everywhere.
    // ---------------------------------------------------------------

    /// `active_plan` for plan store, `active_live` for live store. Used
    /// when the host ends "this mode" of a session — flips just this
    /// flag, leaving the OTHER mode's flag (and the legacy `active`
    /// flag) untouched so the cousin mode stays alive.
    private var activeColumnForScope: String {
        scopeLive ? "active_live" : "active_plan"
    }

    /// `in_plan` for plan store, `in_live` for live store. Used when:
    ///   - inserting/updating my own session_members row to mark
    ///     membership in this mode,
    ///   - filtering the members list to "people still in the sesh in
    ///     my mode".
    private var inColumnForScope: String {
        scopeLive ? "in_live" : "in_plan"
    }

    /// UserDefaults key for "which session was this store last in".
    /// Scoped so plan and live can persist different session IDs.
    private var persistKey: String { "sesh.lastSessionId.\(scope.rawValue)" }

    private func persistSessionID(_ id: UUID?) {
        if let id {
            UserDefaults.standard.set(id.uuidString, forKey: persistKey)
        } else {
            UserDefaults.standard.removeObject(forKey: persistKey)
        }
    }

    var isActive: Bool { session != nil }
    var myId: UUID? { supabase.auth.currentUser?.id }
    var isHost: Bool {
        guard let s = session, let uid = myId else { return false }
        return s.hostId == uid
    }

    // MARK: - Regular (manual-duration) ledger
    //
    // Everything below filters to `live == false`. The regular order card,
    // the duration-slider BAC calculation, and the host roster all read
    // from this slice so live-mode drinks never leak into the manual view.

    func myDrinks() -> [SessionDrink] {
        guard let uid = myId else { return [] }
        return drinks.filter { $0.profileId == uid && !$0.shared && !$0.live }
    }

    func mySharedDrinks() -> [SessionDrink] {
        guard let uid = myId else { return [] }
        return drinks.filter { $0.profileId == uid && $0.shared && !$0.live }
    }

    func sharedDrinks() -> [SessionDrink] {
        drinks.filter { $0.shared && !$0.live }
    }

    func drinks(for profileId: UUID) -> [SessionDrink] {
        drinks.filter { $0.profileId == profileId && !$0.shared && !$0.live }
    }

    /// Grams of ethanol attributable to a given member in the regular
    /// (non-live) ledger: their personal drinks plus their even share of
    /// any drinks marked `shared`. Live-mode drinks are excluded — they
    /// have their own per-drink Widmark calculation in `liveBAC(...)`.
    func effectiveGrams(for profileId: UUID) -> Double {
        let personal = drinks
            .filter { $0.profileId == profileId && !$0.shared && !$0.live }
            .reduce(0) { $0 + $1.grams }
        let shared = drinks
            .filter { $0.shared && !$0.live }
            .reduce(0) { $0 + $1.grams }
        let n = max(members.count, 1)
        return personal + shared / Double(n)
    }

    /// Synced duration (hours) for a given member. Prefers the value each
    /// member has set on their own slider and pushed to the DB; falls back
    /// to "time since their first relevant drink" so new members without a
    /// synced value still get a reasonable BAC read.
    /// Because every phone reads the same value from the DB, BACs now match
    /// across devices.
    func duration(for profileId: UUID, now: Date = Date()) -> Double {
        if let m = members.first(where: { $0.profileId == profileId }),
           let synced = m.durationHours {
            return max(0, synced)
        }
        let relevant = drinks.filter {
            ($0.profileId == profileId && !$0.shared) || $0.shared
        }
        guard let earliest = relevant.map({ $0.createdAt }).min() else { return 0 }
        return max(0, now.timeIntervalSince(earliest) / 3600)
    }

    /// Pushes the current user's duration slider value to the shared
    /// `session_members` row so other phones see the same number.
    func updateMyDuration(_ hours: Double) async {
        guard let sid = session?.id, let uid = myId else { return }
        // Optimistic local update so the roster reflects the change instantly.
        if let idx = members.firstIndex(where: { $0.profileId == uid }) {
            members[idx].durationHours = hours
        }
        struct Patch: Encodable { let duration_hours: Double }
        _ = try? await supabase.from("session_members")
            .update(Patch(duration_hours: hours))
            .eq("session_id", value: sid.uuidString.lowercased())
            .eq("profile_id", value: uid.uuidString.lowercased())
            .execute()
    }

    /// Returns the synced duration the current user has on record, if any.
    /// Lets the UI restore the slider position on launch / after polling.
    func myDuration() -> Double? {
        guard let uid = myId else { return nil }
        return members.first(where: { $0.profileId == uid })?.durationHours
    }

    // MARK: - Live ledger (per-drink Widmark)
    //
    // Everything below filters to `live == true`. The live timeline,
    // roster, roast card, and live BAC all read from this slice so the
    // regular calculator's drinks never bleed into the live view.

    /// All `live == true` drinks for the session. Convenience accessor so
    /// every live-side helper agrees on the same filtered slice.
    private var liveDrinks: [SessionDrink] {
        drinks.filter { $0.live }
    }

    /// Has anyone in the group started a Live Sesh yet? Used by the
    /// LiveSeshBar to decide whether to show the active "LIVE · N PEOPLE"
    /// pill or the idle CTA.
    var hasLiveActivity: Bool { !liveDrinks.isEmpty }

    /// Live group Widmark — chronological simulation over the slice of
    /// drinks that count for this member: their personal pours plus
    /// their share of every shared round. Per-drink gating is applied
    /// before the walk so the rest is the same single-timeline math the
    /// solo calculator uses (see LiveSeshState.bac for the rationale).
    /// Server-stamped `createdAt` keeps the result identical on every
    /// phone in the group.
    func liveBAC(for profileId: UUID, now: Date = Date()) -> Double {
        guard let profile = memberProfiles[profileId] else { return 0 }
        let bodyGrams = profile.weightKg * 1000
        let denom = bodyGrams * profile.sex.r
        guard denom > 0 else { return 0 }
        let n = max(members.count, 1)

        // 1) Project each contributing drink to (timestamp, grams_to_me).
        //    Drinks that aren't mine and aren't shared drop out here.
        let events: [(Date, Double)] = liveDrinks.compactMap { d in
            let isMine = d.profileId == profileId && !d.shared
            let isShared = d.shared
            guard isMine || isShared else { return nil }
            let grams = isShared ? d.grams / Double(n) : d.grams
            return (d.createdAt, grams)
        }.sorted { $0.0 < $1.0 }

        // 2) Walk forward applying continuous decay between events.
        var bac: Double = 0
        var lastEvent: Date? = nil
        for (when, grams) in events where when <= now {
            if let last = lastEvent {
                let hours = when.timeIntervalSince(last) / 3600
                bac = max(0, bac - 0.015 * hours)
            }
            bac += (grams / denom) * 100
            lastEvent = when
        }
        if let last = lastEvent {
            let hours = max(0, now.timeIntervalSince(last) / 3600)
            bac = max(0, bac - 0.015 * hours)
        }
        return bac
    }

    /// Hours until a member reaches a BAC threshold under the live model.
    /// Uses the constant ~0.015 BAC%/hr metabolism rate.
    func liveHoursUntil(threshold: Double, for profileId: UUID, now: Date = Date()) -> Double {
        max(0, (liveBAC(for: profileId, now: now) - threshold) / 0.015)
    }

    /// All live drinks attributable to a member, sorted newest-first.
    /// Combines their personal live drinks with all live shared rounds.
    func liveTimeline(for profileId: UUID) -> [SessionDrink] {
        liveDrinks
            .filter { ($0.profileId == profileId && !$0.shared) || $0.shared }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Total live drink count for a member: personal + shared (each shared
    /// drink counts as one round even though it's split).
    func totalDrinkCount(for profileId: UUID) -> Int {
        liveTimeline(for: profileId).count
    }

    /// Earliest live drink time for a member — when their "live" night
    /// effectively started. Returns nil if no live drinks yet.
    func firstDrinkTime(for profileId: UUID) -> Date? {
        let relevant = liveDrinks.filter {
            ($0.profileId == profileId && !$0.shared) || $0.shared
        }
        return relevant.map { $0.createdAt }.min()
    }

    /// Earliest live drink across all members — the moment the live sesh
    /// effectively started for the group.
    func sessionFirstDrink() -> Date? {
        liveDrinks.map { $0.createdAt }.min()
    }

    /// On launch, restore whichever group this scope was last in. We
    /// prefer the persisted ID first — that's how plan and live can
    /// diverge over time (different sessions per scope) without one
    /// store clobbering the other's choice on next launch.
    ///
    /// If nothing is persisted (fresh install, or the user upgraded
    /// from a single-store version), fall back to scanning memberships
    /// and entering whatever's active. On a single-mode upgrade both
    /// stores will land on the same session, which matches legacy
    /// behaviour. Subsequent leaves/joins persist per scope and the
    /// two stores can diverge from there.
    func resumeIfAny() async {
        guard let uid = myId else { return }

        // 1. Persisted session for this scope.
        if let raw = UserDefaults.standard.string(forKey: persistKey),
           let sid = UUID(uuidString: raw) {
            // Only resume if the session is still active in MY mode
            // (per-mode end means `active_<other>` is irrelevant) AND
            // I'm still a member in MY mode. The two `.eq(...)`
            // filters do that cleanly server-side.
            if let row: SeshSession = try? await supabase
                .from("sessions")
                .select()
                .eq("id", value: sid.uuidString.lowercased())
                .eq(activeColumnForScope, value: true)
                .single()
                .execute()
                .value,
               let _: SessionMember = try? await supabase
                .from("session_members")
                .select()
                .eq("session_id", value: sid.uuidString.lowercased())
                .eq("profile_id", value: uid.uuidString.lowercased())
                .eq(inColumnForScope, value: true)
                .single()
                .execute()
                .value
            {
                await enter(session: row)
                return
            }
            // Persisted session is stale (ended for my mode, or I left
            // from another device) — clear it so we don't keep hitting
            // the network for a dead row on every launch.
            persistSessionID(nil)
        }

        // 2. Fallback: scan all my memberships in this mode, enter the
        //    first one whose session is still active in this mode.
        //    Single-mode users land here on first launch after upgrade.
        do {
            let myMemberships: [SessionMember] = try await supabase
                .from("session_members")
                .select()
                .eq("profile_id", value: uid.uuidString.lowercased())
                .eq(inColumnForScope, value: true)
                .execute()
                .value
            for m in myMemberships {
                if let row: SeshSession = try? await supabase
                    .from("sessions")
                    .select()
                    .eq("id", value: m.sessionId.uuidString.lowercased())
                    .eq(activeColumnForScope, value: true)
                    .single()
                    .execute()
                    .value {
                    await enter(session: row)
                    return
                }
            }
        } catch {
            // no active sessions, stay idle
        }
    }

    func create() async {
        busy = true; defer { busy = false }
        error = nil
        do {
            guard let uid = myId else {
                error = "Not signed in"; return
            }
            struct Insert: Encodable { let host_id: String; let join_code: String }
            let code = Self.generateCode()
            let row: SeshSession = try await supabase.from("sessions")
                .insert(Insert(host_id: uid.uuidString.lowercased(), join_code: code))
                .select()
                .single()
                .execute()
                .value
            // Insert the host's membership row marked as "in this mode
            // only" — the OTHER mode's flag is FALSE so creating in
            // plan doesn't silently put the host in live too. They can
            // mirror later via the cousin's join affordance.
            struct M: Encodable {
                let session_id: String
                let profile_id: String
                let in_plan: Bool
                let in_live: Bool
            }
            _ = try await supabase.from("session_members")
                .insert(M(
                    session_id: row.id.uuidString.lowercased(),
                    profile_id: uid.uuidString.lowercased(),
                    in_plan: !scopeLive,
                    in_live: scopeLive
                ))
                .execute()
            await enter(session: row)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func join(code: String) async {
        busy = true; defer { busy = false }
        error = nil
        do {
            // Pass the scope to the RPC so it sets the right in_<mode>
            // flag (and OR-merges with any existing flag from the
            // other mode — the user might already be a member in live
            // when they tap join in plan).
            struct P: Encodable { let code: String; let mode: String }
            let sid: UUID = try await supabase
                .rpc("join_session_by_code", params: P(code: code.uppercased(), mode: scope.rawValue))
                .execute()
                .value
            let row: SeshSession = try await supabase
                .from("sessions")
                .select()
                .eq("id", value: sid.uuidString.lowercased())
                .single()
                .execute()
                .value
            await enter(session: row)
        } catch {
            self.error = "Couldn't join. Check the code."
        }
    }

    /// Leave the group in this mode. Per-mode model (migration 007):
    /// flips just my `in_<scope>` flag on the session_members row,
    /// leaving `in_<other>` untouched. So:
    ///
    ///   - Other members polling for THIS mode see me disappear (their
    ///     refresh filters by `in_<scope>`).
    ///   - Other members polling for the OTHER mode still see me — I
    ///     remain in that mode for everyone, including myself.
    ///   - My cousin store stays put: it queries by `in_<other>`, so
    ///     this update is invisible to it. No cross-store coordination
    ///     needed.
    ///
    /// The `cousinSessionId` parameter is kept for ABI compatibility
    /// with the call sites — we don't actually use it anymore (the
    /// per-mode flags decouple the two stores at the DB level), but
    /// callers still pass it and that's fine.
    func leave(cousinSessionId: UUID? = nil) async {
        _ = cousinSessionId  // intentionally unused under the per-mode model
        guard let sid = session?.id, let uid = myId else { clearLocal(); return }
        // Two concrete Encodable patches so we match the rest of the
        // file's update style — Postgrest-Swift is happiest when the
        // body has a fixed shape it can serialize statically. We can't
        // share the chain via a ternary because `update(_:)` itself is
        // a throwing call, so the branches are inlined into the
        // try/await chain instead.
        struct InPlanPatch: Encodable { let in_plan: Bool }
        struct InLivePatch: Encodable { let in_live: Bool }
        do {
            if scopeLive {
                _ = try await supabase.from("session_members")
                    .update(InLivePatch(in_live: false))
                    .eq("session_id", value: sid.uuidString.lowercased())
                    .eq("profile_id", value: uid.uuidString.lowercased())
                    .execute()
            } else {
                _ = try await supabase.from("session_members")
                    .update(InPlanPatch(in_plan: false))
                    .eq("session_id", value: sid.uuidString.lowercased())
                    .eq("profile_id", value: uid.uuidString.lowercased())
                    .execute()
            }
        } catch {
            // Swallow — same semantics as the previous `try?`. We
            // still go idle locally; the user can retry next session.
        }
        clearLocal()
    }

    /// End the group in this mode (host-only flow — the UI only surfaces
    /// this button when `isHost` is true). Per-mode model: flips just
    /// `active_<scope>` on the sessions row, leaving `active_<other>`
    /// alone. Every member polling for THIS mode detects the flip in
    /// their next refresh tick (within ~3s) and goes idle locally. The
    /// OTHER mode keeps running as if nothing happened — the cousin
    /// store on every phone (including the host's) is none the wiser.
    func end(cousinSessionId: UUID? = nil) async {
        _ = cousinSessionId  // intentionally unused under the per-mode model
        guard let sid = session?.id else { clearLocal(); return }
        struct ActivePlanPatch: Encodable { let active_plan: Bool }
        struct ActiveLivePatch: Encodable { let active_live: Bool }
        do {
            if scopeLive {
                _ = try await supabase.from("sessions")
                    .update(ActiveLivePatch(active_live: false))
                    .eq("id", value: sid.uuidString.lowercased())
                    .execute()
            } else {
                _ = try await supabase.from("sessions")
                    .update(ActivePlanPatch(active_plan: false))
                    .eq("id", value: sid.uuidString.lowercased())
                    .execute()
            }
        } catch {
            // Swallow — same semantics as the previous `try?`.
        }
        clearLocal()
    }

    /// Adds a drink to the session. The `live` flag is derived from the
    /// store's scope — plan store stamps `live = false`, live store
    /// stamps `live = true`. Plan and live drinks are mutually exclusive
    /// per row so the two ledgers never bleed into each other even when
    /// both stores happen to track the same underlying session.
    func addDrink(_ option: DrinkOption, shared: Bool = false) async {
        guard let sid = session?.id, let uid = myId else { return }
        struct D: Encodable {
            let session_id: String
            let profile_id: String
            let drink_name: String
            let volume_ml: Double
            let abv: Double
            let shared: Bool
            let live: Bool
        }
        let payload = D(
            session_id: sid.uuidString.lowercased(),
            profile_id: uid.uuidString.lowercased(),
            drink_name: option.name,
            volume_ml: option.volumeML,
            abv: option.abv,
            shared: shared,
            live: scopeLive
        )
        do {
            let inserted: SessionDrink = try await supabase.from("session_drinks")
                .insert(payload)
                .select()
                .single()
                .execute()
                .value
            drinks.append(inserted)
        } catch {
            await refresh()
        }
    }

    /// Removes the most recently added matching drink in this store's
    /// ledger. The store's scope decides which ledger we look at — plan
    /// store touches `live == false` rows, live store touches `live ==
    /// true` rows. This keeps the regular and live undo buttons isolated
    /// even when the two stores share a session.
    func removeMyLast(of option: DrinkOption, shared: Bool = false) async {
        guard let uid = myId else { return }
        let candidate: SessionDrink?
        if shared {
            candidate = drinks
                .filter { $0.drinkName == option.name && $0.shared && $0.live == scopeLive }
                .sorted { $0.createdAt > $1.createdAt }
                .first
        } else {
            candidate = drinks
                .filter { $0.profileId == uid && $0.drinkName == option.name && !$0.shared && $0.live == scopeLive }
                .sorted { $0.createdAt > $1.createdAt }
                .first
        }
        guard let target = candidate else { return }
        _ = try? await supabase.from("session_drinks").delete()
            .eq("id", value: target.id.uuidString.lowercased())
            .execute()
        drinks.removeAll { $0.id == target.id }
    }

    private func enter(session: SeshSession) async {
        self.session = session
        // Persist so the next launch can restore THIS scope's session
        // independently of the cousin scope.
        persistSessionID(session.id)
        await refresh()
        startPolling()
    }

    /// Patch the current user's entry in `memberProfiles` immediately
    /// without waiting for the next 3-second poll. Called by SessionView
    /// when AuthService publishes a profile edit so the user sees their
    /// new weight/age/sex reflected in the live BAC the moment they
    /// hit Save, not three seconds later.
    func applyMyProfile(_ profile: Profile) {
        guard isActive else { return }
        memberProfiles[profile.id] = profile
    }

    private func clearLocal() {
        stopPolling()
        session = nil; members = []; memberProfiles = [:]; drinks = []
        persistSessionID(nil)
    }

    private func refresh() async {
        guard let sid = session?.id else { return }
        do {
            // Per-mode roster: only fetch members whose `in_<scope>`
            // flag is still TRUE. Anyone who left this mode (but might
            // still be in the other) gets filtered out server-side, so
            // they correctly disappear from this scope's UI without
            // affecting the cousin scope's roster.
            let ms: [SessionMember] = try await supabase
                .from("session_members")
                .select()
                .eq("session_id", value: sid.uuidString.lowercased())
                .eq(inColumnForScope, value: true)
                .execute()
                .value
            let ds: [SessionDrink] = try await supabase
                .from("session_drinks")
                .select()
                .eq("session_id", value: sid.uuidString.lowercased())
                .order("created_at", ascending: true)
                .execute()
                .value

            // Re-fetch every member's profile on each poll, not just new
            // ones. We used to only fetch on first sight, which left the
            // cache stale forever — so when the user (or any group
            // member) updated their weight/sex/age in profile settings,
            // the live Widmark formula kept reading the old values and
            // BAC didn't budge. Refreshing the lot keeps every member's
            // BAC in sync with whatever they last saved.
            let allIds = Set(ms.map(\.profileId))
            if !allIds.isEmpty {
                let ids = allIds.map { $0.uuidString.lowercased() }
                let ps: [Profile] = try await supabase
                    .from("profiles")
                    .select()
                    .in("id", values: ids)
                    .execute()
                    .value
                // Replace in-place so a removed-then-rejoined profile
                // doesn't keep its prior values.
                for p in ps { memberProfiles[p.id] = p }
            }

            // Has the host ended THIS mode of the session? Per-mode
            // model: we only care about `active_<scope>`, not the
            // legacy global `active` (which now stays TRUE forever)
            // and not the OTHER mode's flag (cousin scope handles that
            // independently). The legacy `active = false` check stays
            // as a fallback for environments that haven't run
            // migration 007 yet — there `activePlan`/`activeLive`
            // default to TRUE on decode and we'd otherwise miss a
            // host-end that flipped only `active`.
            if let row: SeshSession = try? await supabase
                .from("sessions")
                .select()
                .eq("id", value: sid.uuidString.lowercased())
                .single()
                .execute()
                .value {
                let endedForMyMode = scopeLive ? !row.activeLive : !row.activePlan
                if endedForMyMode || row.active == false {
                    clearLocal()
                    return
                }
            }

            // Did I get kicked out of THIS mode (e.g. left from another
            // device, or — though we don't expose this yet — a host
            // removed me)? Detect via my own membership row's
            // `in_<scope>` flag. We already pulled the filtered list
            // above, so a missing self-row in `ms` means I'm out.
            if let uid = myId, !ms.contains(where: { $0.profileId == uid }) {
                clearLocal()
                return
            }

            members = ms.sorted { $0.joinedAt < $1.joinedAt }
            drinks = ds
        } catch {
            // swallow; try again next tick
        }
    }

    private func startPolling() {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await self?.refresh()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    deinit { pollTask?.cancel() }

    static func generateCode(length: Int = 6) -> String {
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<length).map { _ in chars.randomElement()! })
    }

    static func bac(grams: Double, profile: Profile, hoursElapsed: Double) -> Double {
        let bodyGrams = profile.weightKg * 1000
        let raw = (grams / (bodyGrams * profile.sex.r)) * 100
        return max(0, raw - 0.015 * hoursElapsed)
    }
}

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

    init(mapItem: MKMapItem, from origin: CLLocation?) {
        // iOS 26+ APIs: `location` for coordinates, `address` for the
        // short street line, `addressRepresentations` for structured
        // city/region. Replaces the deprecated `placemark` accessors.
        let coord = mapItem.location.coordinate
        let extID = mapItem.identifier?.rawValue
        self.id = extID
            ?? "\(coord.latitude),\(coord.longitude)|\(mapItem.name ?? "")"
        self.name = mapItem.name ?? "Unknown"
        // shortAddress is the compact "Vasagatan 1" form when available;
        // fall back to fullAddress so we never show nothing on rows that
        // do have an address.
        if let addr = mapItem.address {
            self.address = addr.shortAddress ?? addr.fullAddress
        } else {
            self.address = nil
        }
        self.city = mapItem.addressRepresentations?.cityName
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
    func search(query: String, origin: CLLocation?) {
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
        if let origin {
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
                self.results = items.map { MapKitVenueResult(mapItem: $0, from: origin) }
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
    @Published private(set) var loading = false

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

    private let currentKey = "sesh.currentVenue.v1"

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
            let vs: [Venue] = try await supabase
                .from("venues")
                .select()
                .order("name", ascending: true)
                .execute()
                .value
            let ss: [VenueSpecial] = try await supabase
                .from("venue_specials")
                .select()
                .execute()
                .value
            venues = vs
            var grouped: [UUID: [VenueSpecial]] = [:]
            for s in ss {
                grouped[s.venueId, default: []].append(s)
            }
            specialsByVenue = grouped
            attachLocalSpecials()
            reconcileCurrent()
        } catch {
            // Network or schema problem. Don't seed any venues —
            // discovery is MapKit-driven. Still attach local specials
            // to anything already in `venues` (e.g., a previously
            // checked-in MapKit row that we've kept locally).
            attachLocalSpecials()
        }
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
        // 1. Fast path: already in our local list.
        if let existing = venues.first(where: {
            $0.externalId == result.id && $0.source == .mapkit
        }) {
            currentVenue = existing
            return
        }

        // 2. Re-check the DB in case another device beat us to the insert
        //    (or our local list is stale). Look up by (source, external_id),
        //    which is the same shape as the unique index.
        do {
            let matches: [Venue] = try await supabase
                .from("venues")
                .select()
                .eq("source", value: "mapkit")
                .eq("external_id", value: result.id)
                .limit(1)
                .execute()
                .value
            if let hit = matches.first {
                if !venues.contains(where: { $0.id == hit.id }) {
                    venues.append(hit)
                }
                currentVenue = hit
                return
            }
        } catch {
            // Read failure is non-fatal — fall through and try insert.
            // Worst case the unique index rejects us and we surface that.
        }

        // 3. Insert a new mapkit row. RLS allows it because source != 'curated'.
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
                currentVenue = row
                return
            }
        } catch {
            // Insert lost a race with another device — re-read by external_id
            // and use the winner. If that also fails we fall through to a
            // local-only stub so the user's check-in still works for this
            // session even if it doesn't get persisted.
            do {
                let matches: [Venue] = try await supabase
                    .from("venues")
                    .select()
                    .eq("source", value: "mapkit")
                    .eq("external_id", value: result.id)
                    .limit(1)
                    .execute()
                    .value
                if let hit = matches.first {
                    if !venues.contains(where: { $0.id == hit.id }) {
                        venues.append(hit)
                    }
                    currentVenue = hit
                    return
                }
            } catch {
                // fall through
            }
        }

        // 4. Last resort: local-only stub. Stable id from external_id so
        //    a later real insert dedupes cleanly via reconcileCurrent().
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
    /// doesn't show a ghost.
    private func reconcileCurrent() {
        guard let cur = currentVenue else { return }
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

// MARK: - Invites
//
// Polling-based "in-app inbox" for invites. There is intentionally no push
// notification path yet — the recipient has to have the app open (or
// foreground it) to see the invite. The trade-off is acceptable for the
// first cut: a friend tapping an invite while the app is backgrounded just
// sees it on next foreground. Push can be layered on later by reading from
// the same `invites` table this service polls.
//
// Polling cadence is deliberately slower than SessionService's 3 s loop —
// invites are rare events, and burning a query every 3 s for an empty
// inbox is wasteful. 7 s is fast enough that "host taps send → recipient
// sees banner" still feels live (typically <10 s end-to-end).
@MainActor
final class InvitesService: ObservableObject {
    /// Pending invites for the signed-in user, newest first. Drives the
    /// banner pinned at the top of SessionView and the inbox sheet.
    @Published private(set) var pending: [Invite] = []
    /// Sender profiles, keyed by sender_id, populated alongside `pending`
    /// so the banner / sheet can render avatar + name without a second
    /// round trip per row.
    @Published private(set) var senderProfiles: [UUID: Profile] = [:]
    /// Surfaced in the sheet when an accept / decline fails; nil otherwise.
    @Published var error: String?

    private var pollTask: Task<Void, Never>?

    /// Start the polling loop. Idempotent — calling twice is a no-op.
    /// RootView calls this once auth lands, and stops it on sign-out.
    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 7_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        pending = []
        senderProfiles = [:]
    }

    /// Single fetch + sender-profile hydration. Public so the UI can poke
    /// it after an accept / decline to refresh without waiting up to 7 s.
    func refresh() async {
        guard let uid = supabase.auth.currentUser?.id else { return }
        do {
            // Explicit column list (instead of `*`) so a stale PostgREST
            // schema cache can't silently drop the `mode` field on us —
            // a missing mode would default to "plan" in the decoder and
            // route live invites to plan mode of the same session, which
            // is the wrong half of the per-mode split.
            let rows: [Invite] = try await supabase
                .from("invites")
                .select("id,session_id,sender_id,recipient_id,join_code,created_at,responded_at,status,mode")
                .eq("recipient_id", value: uid.uuidString.lowercased())
                .eq("status", value: "pending")
                .order("created_at", ascending: false)
                .execute()
                .value
            self.pending = rows

            // Hydrate sender profiles for every row we don't already have.
            // We never drop entries from the cache here — a sender whose
            // invite was just accepted (and therefore disappears from
            // `pending`) might still need to be rendered by a sheet that's
            // already on screen for one extra frame.
            let missing = Set(rows.map(\.senderId)).subtracting(senderProfiles.keys)
            if !missing.isEmpty {
                let ids = missing.map { $0.uuidString.lowercased() }
                let ps: [Profile] = try await supabase
                    .from("profiles")
                    .select()
                    .in("id", values: ids)
                    .execute()
                    .value
                for p in ps { senderProfiles[p.id] = p }
            }
        } catch {
            // Swallow — empty inbox is a fine fallback, and we don't want a
            // transient network blip to flash a red banner. The next poll
            // recovers automatically.
        }
    }

    /// Send an invite to each of `recipientIds` for the given session +
    /// snapshot of its join code. Uses an upsert with `ignoreDuplicates`
    /// so a re-tap (or two devices both firing on the same crew) collapses
    /// to one row per (session, recipient) thanks to the unique index.
    /// Returns the number of rows accepted by the server, useful for a
    /// "Sent to N friends" toast in the UI.
    @discardableResult
    func send(sessionId: UUID, joinCode: String, mode: SeshMode, recipientIds: [UUID]) async -> Int {
        guard let uid = supabase.auth.currentUser?.id else { return 0 }
        let unique = Array(Set(recipientIds)).filter { $0 != uid }
        guard !unique.isEmpty else { return 0 }
        struct Row: Encodable {
            let session_id: String
            let sender_id: String
            let recipient_id: String
            let join_code: String
            let mode: String
        }
        let rows: [Row] = unique.map { rid in
            Row(
                session_id: sessionId.uuidString.lowercased(),
                sender_id: uid.uuidString.lowercased(),
                recipient_id: rid.uuidString.lowercased(),
                join_code: joinCode,
                mode: mode.rawValue
            )
        }
        do {
            // `ignoreDuplicates` makes the unique-key collision a soft no-op
            // instead of a 409 — a host re-sending to the same crew gets a
            // silent success rather than an error toast.
            _ = try await supabase
                .from("invites")
                .upsert(rows, onConflict: "session_id,recipient_id", ignoreDuplicates: true)
                .execute()
            return rows.count
        } catch {
            self.error = "Couldn't send invite"
            return 0
        }
    }

    /// Flip an invite to `accepted` or `declined`. We update by id (RLS
    /// already pins to recipient_id = auth.uid(), so a malicious id from
    /// another inbox can't sneak through). The local row is removed
    /// optimistically so the banner/sheet collapse instantly — the next
    /// poll re-confirms.
    func updateStatus(_ inviteId: UUID, to status: String) async {
        struct Patch: Encodable {
            let status: String
            let responded_at: String
        }
        let patch = Patch(status: status, responded_at: ISO8601DateFormatter().string(from: Date()))
        // Optimistic removal — the row is no longer "pending" by definition.
        pending.removeAll { $0.id == inviteId }
        do {
            _ = try await supabase
                .from("invites")
                .update(patch)
                .eq("id", value: inviteId.uuidString.lowercased())
                .execute()
        } catch {
            // Rollback isn't worth the complexity — the next refresh will
            // restore the row if the update truly failed. Surface a soft
            // error string so the inbox sheet can show a retry hint.
            self.error = "Couldn't update invite"
            await refresh()
        }
    }
}

// MARK: - Live Sesh — Group Roast

/// A roast: a punchy headline aimed at the most-drunk member of the group,
/// with a soft "look out for them" advice line. Picked deterministically
/// from a small bank that varies with group size + total drinks consumed
/// so the line shifts as the night progresses (without being random and
/// flickering on every poll).
struct LiveRoast: Hashable {
    let headline: String
    let advice: String
}

/// Whose roast is this — and which grammar to use. Lines targeting the
/// current user need second-person verbs ("you are"), while lines about
/// another player use third-person ("Mauritz is"). The helpers below let
/// each roast template stay readable instead of branching at every word.
enum RoastSubject: Equatable {
    case you            // current user — speak in second person
    case name(String)   // another member — third person, by first name

    var isYou: Bool { if case .you = self { return true }; return false }

    /// Sentence-leading subject. "You" or the first name.
    var title: String {
        switch self {
        case .you:         return "You"
        case .name(let n): return n
        }
    }

    /// Mid-sentence subject — lowercased pronoun, names stay capitalised.
    var mid: String {
        switch self {
        case .you:         return "you"
        case .name(let n): return n
        }
    }

    /// Subject + contracted "be": "You're" / "Mauritz is". The bread and
    /// butter — most roast lines use this shape.
    var titleIs: String {
        switch self {
        case .you:         return "You're"
        case .name(let n): return "\(n) is"
        }
    }

    /// "are" / "is".
    var areIs: String { isYou ? "are" : "is" }

    /// Possessive determiner: "your" / "their".
    var poss: String { isYou ? "your" : "their" }

    /// Object pronoun: "you" / "them".
    var obj: String { isYou ? "you" : "them" }

    /// Subject pronoun: "you" / "they".
    var subjectPronoun: String { isYou ? "you" : "they" }

    /// Subject pronoun + contracted "be": "you're" / "they're".
    var pronounIs: String { isYou ? "you're" : "they're" }

    /// "You are" / "They are" — capitalised, uncontracted (for end-of-line
    /// emphasis like "…They are not.").
    var capPronounAre: String { isYou ? "You are" : "They are" }

    /// Conjugate a base verb for the subject. "think" → "think" / "thinks";
    /// "need" → "need" / "needs"; "have" → "have" / "has"; "be" → "are" / "is".
    func verb(_ base: String) -> String {
        if isYou {
            switch base {
            case "be": return "are"
            default:   return base
            }
        }
        switch base {
        case "have": return "has"
        case "be":   return "is"
        case "do":   return "does"
        default:
            if base.hasSuffix("s") || base.hasSuffix("x")
                || base.hasSuffix("ch") || base.hasSuffix("sh")
                || base.hasSuffix("z") {
                return base + "es"
            }
            if base.hasSuffix("y"),
               let prev = base.dropLast().last,
               !"aeiou".contains(prev) {
                return base.dropLast() + "ies"
            }
            return base + "s"
        }
    }

    /// Pick one of two phrasings depending on subject — used for lines
    /// that don't translate cleanly via the standard helpers
    /// (e.g. "Beware of Mauritz" → "Heads up" in 2nd person).
    func choose(you youText: String, them themText: String) -> String {
        isYou ? youText : themText
    }
}

enum LiveRoastBook {
    /// Picks a roast for the leader. `subject` carries both the name (for
    /// third-person lines) and a flag for second-person grammar when the
    /// leader IS the current user. `bac` selects the tier; `seed` rotates
    /// within the tier.
    static func roast(subject: RoastSubject, bac: Double, seed: Int) -> LiveRoast {
        let bank = candidates(for: bac, subject: subject)
        guard !bank.isEmpty else {
            return LiveRoast(
                headline: "\(subject.titleIs) in the lead.",
                advice: "Keep an eye on \(subject.obj). Water, food, friends."
            )
        }
        return bank[abs(seed) % bank.count]
    }

    /// A "calm group" roast for when nobody has actually started drinking
    /// yet (or everyone is below 0.02). Encourages the sesh without
    /// punching down at any specific person.
    static func warmup(seed: Int) -> LiveRoast {
        let bank = [
            LiveRoast(headline: "The sesh is too quiet. Someone needs to commit.",
                      advice: "First sip is a personality choice."),
            LiveRoast(headline: "Group sobriety is concerning. Are we on a hike?",
                      advice: "Pace yourselves. Eat first."),
            LiveRoast(headline: "Nobody is even close to drunk. Disappointing.",
                      advice: "Hydration is still mandatory."),
        ]
        return bank[abs(seed) % bank.count]
    }

    private static func candidates(for bac: Double, subject s: RoastSubject) -> [LiveRoast] {
        switch bac {
        case ..<0.02:
            return [
                LiveRoast(headline: "\(s.titleIs) leading the pack — barely a sip in.",
                          advice: "Pace yourselves. Eat. Hydrate."),
                LiveRoast(headline: "\(s.title) \(s.verb("lead")). Honestly that's embarrassing for everyone.",
                          advice: "Pick up the pace, gently. Water first."),
            ]
        case 0.02..<0.05:
            return [
                LiveRoast(headline: "\(s.titleIs) the front-runner. The night has potential.",
                          advice: "Snack break. Water between rounds."),
                LiveRoast(headline: "\(s.titleIs) warming up. Texts about to get spicy.",
                          advice: "Hide \(s.poss) phone. Eat carbs."),
            ]
        case 0.05..<0.08:
            return [
                LiveRoast(headline: s.choose(
                              you:  "Heads up — obnoxious mode incoming.",
                              them: "Beware of \(s.mid) — obnoxious mode incoming."),
                          advice: "Strap in. Hand \(s.obj) water."),
                LiveRoast(headline: "\(s.title) just hit talkative tier. Brace for life advice.",
                          advice: "Nod politely. Refill \(s.poss) water."),
                LiveRoast(headline: "\(s.titleIs) now the loudest in the group. Statistically.",
                          advice: "Encourage food. Start tracking shots."),
            ]
        case 0.08..<0.15:
            return [
                LiveRoast(headline: "\(s.titleIs) officially the entertainment. Document everything.",
                          advice: s.choose(
                              you:  "Do NOT drive. No exceptions.",
                              them: "Do NOT let \(s.mid) drive. No exceptions.")),
                LiveRoast(headline: "\(s.title) \(s.verb("think")) \(s.pronounIs) whispering. \(s.capPronounAre) not.",
                          advice: "Cab money on standby. Big water."),
                LiveRoast(headline: "\(s.title) just challenged the bartender to a debate. Help.",
                          advice: "Steer \(s.obj) toward food. Keep \(s.poss) phone."),
                LiveRoast(headline: "\(s.titleIs) forming opinions on geopolitics. Nobody asked.",
                          advice: "Water. Carbs. Light topics only."),
            ]
        case 0.15..<0.25:
            return [
                LiveRoast(headline: "\(s.titleIs) a problem. Hide \(s.poss) phone. NOW.",
                          advice: "Water, food, friend nearby. \(s.titleIs) the group's responsibility."),
                LiveRoast(headline: "\(s.title) just confessed something \(s.subjectPronoun) can't take back.",
                          advice: "Stop pouring for \(s.obj). Buddy up. Cab home."),
                LiveRoast(headline: "\(s.titleIs) one drink from declaring love for a stranger.",
                          advice: "Cut \(s.obj) off gently. Stay close. No driving."),
            ]
        default:
            return [
                LiveRoast(headline: "Critical: \(s.mid) \(s.verb("need")) supervision tonight.",
                          advice: "Stop pouring. Stay close. Above 0.30 — get help."),
                LiveRoast(headline: "\(s.titleIs) in 'whose bed is this' territory.",
                          advice: "Water. Sober adult. Side-sleep when home."),
                LiveRoast(headline: "\(s.titleIs) officially a tomorrow problem.",
                          advice: "End the sesh for \(s.obj). Stay close until safe."),
            ]
        }
    }
}

// MARK: - Recent drinks store

/// Tracks the user's recent drink picks so the Live Sesh quick-add tiles
/// can adapt to what they actually drink. Stored in UserDefaults so it
/// persists across sessions, cold launches, and group/solo mode swaps.
/// Each call to `record` moves the option to the front of the list and
/// dedupes, so the order reflects "most recent unique pick first".
@MainActor
final class RecentDrinksStore: ObservableObject {
    /// Option names, newest-first, deduped. Capped at `cap` so the file
    /// doesn't grow indefinitely — the dock only ever shows the first 3.
    @Published private(set) var recents: [String] = []

    private let key = "sesh.recentDrinks.v1"
    private let cap = 6

    init() {
        load()
        // The lock-screen App Intent also writes to `key` when it
        // appends a drink. Same notification LiveSeshState listens
        // for — re-loading from disk here keeps the quick-add tiles
        // (and the next syncLockScreenActivity push) in step with
        // what the user actually tapped on their lock screen.
        NotificationCenter.default.addObserver(
            forName: .liveSeshLockScreenDidAddDrink,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.load() }
        }
    }

    /// Records a pick. Moves the option to the front of the list, removing
    /// any prior occurrence so the same drink doesn't take multiple slots.
    func record(_ option: DrinkOption) {
        var list = recents.filter { $0 != option.name }
        list.insert(option.name, at: 0)
        if list.count > cap { list = Array(list.prefix(cap)) }
        recents = list
        save()
    }

    /// Resolves the stored option names back to full `DrinkOption`s by
    /// looking them up in the catalog. Names that no longer exist in the
    /// catalog (e.g. catalog changed between app versions) are skipped.
    func resolved() -> [DrinkOption] {
        recents.compactMap { name in
            DrinkCatalog.allOptions.first(where: { $0.name == name })
        }
    }

    private func load() {
        if let arr = UserDefaults.standard.stringArray(forKey: key) {
            recents = arr
        }
    }

    private func save() {
        UserDefaults.standard.set(recents, forKey: key)
    }
}

// MARK: - Live Sesh

/// A drink consumed at a known moment. Distinct from `OrderItem` (untimed)
/// and `SessionDrink` (server-synced) because Live Sesh is intentionally
/// device-local and grounded in real timestamps for accurate per-drink
/// metabolism.
struct LiveDrink: Identifiable, Codable, Equatable {
    let id: UUID
    let optionName: String
    let detail: String
    let category: DrinkCategory
    let volumeML: Double
    let abv: Double
    let consumedAt: Date

    init(id: UUID = UUID(), option: DrinkOption, consumedAt: Date = Date()) {
        self.id = id
        self.optionName = option.name
        self.detail = option.detail
        self.category = option.category
        self.volumeML = option.volumeML
        self.abv = option.abv
        self.consumedAt = consumedAt
    }

    var grams: Double { volumeML * abv * 0.789 }

    /// Best-effort lookup back to the original DrinkOption for glyph rendering.
    /// Falls back to a synthesised option if the catalog has changed since
    /// the drink was logged (e.g. user updated the app mid-sesh).
    func option() -> DrinkOption {
        if let match = DrinkCatalog.allOptions.first(where: { $0.name == optionName }) {
            return match
        }
        return DrinkOption(
            category: category,
            name: optionName,
            detail: detail,
            volumeML: volumeML,
            abv: abv
        )
    }
}

/// Holds the user's currently-running Live Sesh: a list of timestamped
/// drinks and a start time. State persists across app launches via
/// UserDefaults so the user doesn't lose context if they background the
/// app or get interrupted (a real risk on a live drinking night).
@MainActor
final class LiveSeshState: ObservableObject {
    @Published var drinks: [LiveDrink] = []
    @Published var startedAt: Date? = nil

    private let drinksKey = "sesh.live.drinks.v1"
    private let startKey  = "sesh.live.startedAt.v1"
    private let eliminationRate = 0.015

    var isActive: Bool { startedAt != nil }

    init() {
        load()
        // Reload from disk whenever the lock-screen App Intent has
        // appended a drink behind our back. The intent writes through
        // the same UserDefaults keys we use for persistence — but the
        // running @StateObject doesn't observe UserDefaults, so we'd
        // otherwise show a stale timeline until the app is killed and
        // relaunched. The closure hops to the main actor explicitly
        // because LiveSeshState is @MainActor-isolated.
        NotificationCenter.default.addObserver(
            forName: .liveSeshLockScreenDidAddDrink,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.load() }
        }
    }

    func start() {
        startedAt = Date()
        drinks = []
        save()
    }

    func add(_ option: DrinkOption, at consumedAt: Date = Date()) {
        if startedAt == nil { startedAt = consumedAt }
        drinks.append(LiveDrink(option: option, consumedAt: consumedAt))
        save()
    }

    func removeLast() {
        guard !drinks.isEmpty else { return }
        drinks.removeLast()
        save()
    }

    func remove(_ id: UUID) {
        drinks.removeAll { $0.id == id }
        save()
    }

    func end() {
        drinks = []
        startedAt = nil
        save()
    }

    /// Chronological Widmark simulation. BAC accumulates instantly with
    /// each drink (`(grams / (mass × r)) × 100`) and decays continuously
    /// at `eliminationRate` between events, clamped to 0 (you can't have
    /// negative BAC).
    ///
    /// Walking chronologically — rather than summing per-drink
    /// contributions independently — is the difference between counting
    /// a drink for the full ~2.5h it raises BAC versus silently dropping
    /// it from the calculator once its individual contribution would go
    /// negative. The per-drink-clamp approach undercounts dramatically
    /// in long sessions because early drinks vanish from the sum well
    /// before the body has actually processed them.
    func bac(profile: Profile, now: Date = Date()) -> Double {
        let bodyGrams = profile.weightKg * 1000
        let denom = bodyGrams * profile.sex.r
        guard denom > 0 else { return 0 }
        let sorted = drinks.sorted { $0.consumedAt < $1.consumedAt }
        var bac: Double = 0
        var lastEvent: Date? = nil
        for d in sorted where d.consumedAt <= now {
            if let last = lastEvent {
                let hours = d.consumedAt.timeIntervalSince(last) / 3600
                bac = max(0, bac - eliminationRate * hours)
            }
            bac += (d.grams / denom) * 100
            lastEvent = d.consumedAt
        }
        if let last = lastEvent {
            let hours = max(0, now.timeIntervalSince(last) / 3600)
            bac = max(0, bac - eliminationRate * hours)
        }
        return bac
    }

    func hoursUntil(threshold: Double, profile: Profile, now: Date = Date()) -> Double {
        max(0, (bac(profile: profile, now: now) - threshold) / eliminationRate)
    }

    /// Auto-end the sesh if it's gone stale. Two staleness paths:
    ///
    ///   • Drinks exist → end when BAC has decayed to 0 AND the last
    ///     drink was consumed more than `staleAfter` seconds ago. The
    ///     12h default gives the user the whole "morning after" window
    ///     to glance at their timeline before we clean up, while still
    ///     killing the "logged 1 drink and forgot to end" case the
    ///     next time anything touches LiveSeshState.
    ///   • No drinks (user pressed start by accident) → end after
    ///     `emptyStaleAfter` seconds from startedAt. 1h is plenty —
    ///     a deliberate sesh logs a drink within minutes.
    ///
    /// Cheap to call: returns immediately when the sesh isn't active
    /// or BAC is still > 0, so it's safe to fire on every TimelineView
    /// tick + every appear without doing real work most of the time.
    /// Returns true when the sesh was auto-ended so callers can chain
    /// cleanup (e.g., tearing down the lock-screen activity).
    @discardableResult
    func endIfStale(
        profile: Profile,
        now: Date = Date(),
        staleAfter: TimeInterval = 12 * 3600,
        emptyStaleAfter: TimeInterval = 1 * 3600
    ) -> Bool {
        guard isActive else { return false }
        guard bac(profile: profile, now: now) == 0 else { return false }

        if let last = drinks.map({ $0.consumedAt }).max() {
            guard now.timeIntervalSince(last) > staleAfter else { return false }
        } else if let started = startedAt {
            guard now.timeIntervalSince(started) > emptyStaleAfter else { return false }
        } else {
            return false
        }

        end()
        return true
    }

    // MARK: persistence

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(drinks) {
            UserDefaults.standard.set(data, forKey: drinksKey)
        }
        if let s = startedAt {
            UserDefaults.standard.set(s.timeIntervalSince1970, forKey: startKey)
        } else {
            UserDefaults.standard.removeObject(forKey: startKey)
        }
    }

    private func load() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let data = UserDefaults.standard.data(forKey: drinksKey),
           let restored = try? dec.decode([LiveDrink].self, from: data) {
            drinks = restored
        }
        let raw = UserDefaults.standard.double(forKey: startKey)
        if raw > 0 {
            startedAt = Date(timeIntervalSince1970: raw)
        }
    }
}

// MARK: - Ghost members (manually-added live sesh participants)
//
// Sometimes the people you're drinking with don't have the app. Rather
// than leaving them off the leaderboard entirely, the host can add them
// by hand: name + sex + age + weight is enough to drive the same Widmark
// BAC math we use for real members. Each ghost has their own drink log,
// updated by tapping their row and picking from the catalog.
//
// Storage scope: device-local only. Ghosts never hit Supabase — they're
// not real users and we don't want to invent fake auth identities for
// them. Persisted in UserDefaults so a backgrounded app doesn't lose
// the night's tab.
//
// Lifecycle: scoped to live mode (the user requested it there
// explicitly). The store hangs off SessionView and is passed into
// LiveSeshView; PLAN never sees these.

/// One drink consumed by a ghost member. Mirrors `LiveDrink`'s shape so
/// we can reuse the same per-drink Widmark contribution math, but stays
/// a separate type because ghosts don't have UUID-based identity in the
/// same namespace as real session drinks.
struct GhostDrink: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let optionName: String
    let detail: String
    let category: DrinkCategory
    let volumeML: Double
    let abv: Double
    let consumedAt: Date

    init(id: UUID = UUID(), option: DrinkOption, consumedAt: Date = Date()) {
        self.id = id
        self.optionName = option.name
        self.detail = option.detail
        self.category = option.category
        self.volumeML = option.volumeML
        self.abv = option.abv
        self.consumedAt = consumedAt
    }

    var grams: Double { volumeML * abv * 0.789 }

    /// Best-effort lookup back to the original DrinkOption for glyph rendering.
    func option() -> DrinkOption {
        if let match = DrinkCatalog.allOptions.first(where: { $0.name == optionName }) {
            return match
        }
        return DrinkOption(
            category: category,
            name: optionName,
            detail: detail,
            volumeML: volumeML,
            abv: abv
        )
    }
}

/// A manually-added participant in the live sesh. `weightKg` + `sex`
/// are everything BAC math needs; `age` is captured because the rest of
/// the app collects it as part of any drinker profile (and might use it
/// later for tier-based warnings) — even if Widmark itself ignores it.
struct GhostMember: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var name: String
    var sex: Sex
    var age: Int
    var weightKg: Double
    var drinks: [GhostDrink]
    let createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        sex: Sex,
        age: Int,
        weightKg: Double,
        drinks: [GhostDrink] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.sex = sex
        self.age = age
        self.weightKg = weightKg
        self.drinks = drinks
        self.createdAt = createdAt
    }
}

/// On-device store for ghost members. Same persistence pattern as
/// `LiveSeshState` (JSONEncoder + iso8601), keyed under a stable v1 key
/// so future schema changes can migrate without colliding.
@MainActor
final class GhostMembersStore: ObservableObject {
    @Published var members: [GhostMember] = []

    private let storeKey = "sesh.live.ghosts.v1"
    private let eliminationRate = 0.015

    init() { load() }

    func add(name: String, sex: Sex, age: Int, weightKg: Double) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let g = GhostMember(name: trimmed, sex: sex, age: age, weightKg: weightKg)
        members.append(g)
        save()
    }

    func remove(_ id: UUID) {
        members.removeAll { $0.id == id }
        save()
    }

    /// Wipe the entire ghost roster. Called when the user ends their
    /// live sesh — the BAC math is meaningless across nights, and
    /// keeping stale ghosts around would silently inflate tomorrow's
    /// numbers when the user opens the app again.
    func clearAll() {
        guard !members.isEmpty else { return }
        members.removeAll()
        save()
    }

    func addDrink(_ option: DrinkOption, to ghostId: UUID, at consumedAt: Date = Date()) {
        guard let idx = members.firstIndex(where: { $0.id == ghostId }) else { return }
        members[idx].drinks.append(GhostDrink(option: option, consumedAt: consumedAt))
        save()
    }

    func removeLastDrink(from ghostId: UUID) {
        guard let idx = members.firstIndex(where: { $0.id == ghostId }) else { return }
        guard !members[idx].drinks.isEmpty else { return }
        members[idx].drinks.removeLast()
        save()
    }

    func removeDrink(_ drinkId: UUID, from ghostId: UUID) {
        guard let idx = members.firstIndex(where: { $0.id == ghostId }) else { return }
        members[idx].drinks.removeAll { $0.id == drinkId }
        save()
    }

    /// Per-drink Widmark, identical to `LiveSeshState.bac` so a ghost and
    /// a real user with matching stats and drinks read the same BAC.
    /// Chronological simulation: BAC accumulates with each drink and
    /// decays continuously at the elimination rate between events,
    /// clamped at 0. (Per-drink-independent decay with a clamp would
    /// silently drop early drinks from the calculator long before the
    /// body had finished processing them — see LiveSeshState.bac for
    /// the longer rationale.)
    func bac(for ghost: GhostMember, now: Date = Date()) -> Double {
        let bodyGrams = ghost.weightKg * 1000
        let denom = bodyGrams * ghost.sex.r
        guard denom > 0 else { return 0 }
        let sorted = ghost.drinks.sorted { $0.consumedAt < $1.consumedAt }
        var bac: Double = 0
        var lastEvent: Date? = nil
        for d in sorted where d.consumedAt <= now {
            if let last = lastEvent {
                let hours = d.consumedAt.timeIntervalSince(last) / 3600
                bac = max(0, bac - eliminationRate * hours)
            }
            bac += (d.grams / denom) * 100
            lastEvent = d.consumedAt
        }
        if let last = lastEvent {
            let hours = max(0, now.timeIntervalSince(last) / 3600)
            bac = max(0, bac - eliminationRate * hours)
        }
        return bac
    }

    // MARK: persistence

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(members) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }

    private func load() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let data = UserDefaults.standard.data(forKey: storeKey),
           let restored = try? dec.decode([GhostMember].self, from: data) {
            members = restored
        }
    }
}

// MARK: - Saved groups
//
// User-curated, on-device list of groups they want to keep around for
// one-tap rejoin. Surfaces in GroupSheet's idle view as "SAVED GROUPS"
// and is toggled from the active view's star button.
//
// Two write paths:
//   • `save(...)` — explicit, fired by the user tapping the star while
//     they're in a group. Adds an entry (or refreshes its snapshot if
//     one already exists).
//   • `refreshSnapshotIfSaved(...)` — silent, fired on every member
//     refresh from SessionService. Only touches entries the user has
//     already explicitly saved, so we never auto-add anything they
//     didn't ask for, but the snapshot fields (member count, host name,
//     last-joined timestamp) stay current.
//
// Stored in UserDefaults — these aren't sensitive (just a 6-char join
// code + a name) and we don't want a network round-trip on every sheet
// open. The list is bounded to keep storage and the UI in check.

/// A single previously-seen crew member, snapshotted at save time so we
/// can re-list them in the "invite crew" share card without needing the
/// network. Identified by Supabase profile id (which is also the auth
/// user id — same UUID flow as `SessionMember.profileId`).
struct SavedMember: Codable, Equatable, Hashable, Identifiable {
    let id: UUID
    var name: String
    var avatarURL: String?
}

struct SavedGroup: Codable, Identifiable, Equatable, Hashable {
    /// Session id — the dedupe key. Two stores hitting the same session
    /// (mirrored plan↔live) collapse to one saved entry.
    let id: UUID
    var joinCode: String
    var lastJoinedAt: Date
    var lastMemberCount: Int
    /// Host's display name when last seen. Optional — on the first save
    /// the host's profile may not have made it into memberProfiles yet,
    /// in which case we leave this blank and fill it in on a later
    /// refresh tick.
    var lastHostName: String?
    /// Snapshot of the crew (excluding the current user) at save time.
    /// Drives the "tap saved group → start new sesh + invite previous
    /// members" flow. We snapshot the whole roster so the share message
    /// can name people even if their profiles aren't cached anymore.
    /// May be empty for entries saved before this field existed — the
    /// custom `init(from:)` defaults missing values to `[]`.
    var savedMembers: [SavedMember]

    init(
        id: UUID,
        joinCode: String,
        lastJoinedAt: Date,
        lastMemberCount: Int,
        lastHostName: String?,
        savedMembers: [SavedMember]
    ) {
        self.id = id
        self.joinCode = joinCode
        self.lastJoinedAt = lastJoinedAt
        self.lastMemberCount = lastMemberCount
        self.lastHostName = lastHostName
        self.savedMembers = savedMembers
    }

    enum CodingKeys: String, CodingKey {
        case id, joinCode, lastJoinedAt, lastMemberCount, lastHostName, savedMembers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.joinCode = try c.decode(String.self, forKey: .joinCode)
        self.lastJoinedAt = try c.decode(Date.self, forKey: .lastJoinedAt)
        self.lastMemberCount = try c.decode(Int.self, forKey: .lastMemberCount)
        self.lastHostName = try c.decodeIfPresent(String.self, forKey: .lastHostName)
        // Older v1 entries didn't carry a member roster. Default to []
        // so they still decode cleanly — they just won't contribute to
        // the invite card until the user re-saves them.
        self.savedMembers = (try c.decodeIfPresent([SavedMember].self, forKey: .savedMembers)) ?? []
    }
}

@MainActor
final class SavedGroupsStore: ObservableObject {
    @Published private(set) var groups: [SavedGroup] = []

    /// Storage key. Bumped to v1 from the start so we have a clean lane
    /// to migrate from later (delete-on-decode-failure is the policy if
    /// we ever change the schema incompatibly).
    private let key = "sesh.savedGroups.v1"

    /// Soft cap on how many entries we keep. Anything older falls off
    /// the bottom of the list. 12 is enough to cover a busy month of
    /// sesh-going without turning the idle sheet into a wall of codes.
    private let maxEntries = 12

    init() { load() }

    /// Has the user explicitly saved this session? Drives the star
    /// toggle in the active view (filled vs. outlined).
    func isSaved(id: UUID) -> Bool {
        groups.contains(where: { $0.id == id })
    }

    /// Explicit save (or snapshot-refresh, if already present). Called
    /// from the active-view star button. Idempotent — re-saving an
    /// already-saved group just refreshes its metadata and bumps it to
    /// the top of the list.
    func save(session: SeshSession, memberCount: Int, hostName: String?, members: [SavedMember]) {
        upsert(session: session, memberCount: memberCount, hostName: hostName, members: members, allowInsert: true)
    }

    /// Silent snapshot refresh. Updates `lastMemberCount`, `lastHostName`,
    /// `lastJoinedAt`, and the saved-members roster on entries the user
    /// has already saved, but never inserts a new one. This keeps
    /// automatic recording (driven off SessionService refresh ticks)
    /// from sneaking groups into the list behind the user's back while
    /// still making sure a saved entry's metadata reflects the most
    /// recent visit — including the "previous crew" snapshot used by
    /// the invite share card.
    func refreshSnapshotIfSaved(session: SeshSession, memberCount: Int, hostName: String?, members: [SavedMember]) {
        guard isSaved(id: session.id) else { return }
        upsert(session: session, memberCount: memberCount, hostName: hostName, members: members, allowInsert: false)
    }

    /// Remove an entry by session id. Used by the X button on each row
    /// and by the active-view star toggle when going from saved → not.
    func remove(id: UUID) {
        guard groups.contains(where: { $0.id == id }) else { return }
        groups.removeAll { $0.id == id }
        persist()
    }

    /// Shared upsert path used by both `save` and `refreshSnapshotIfSaved`.
    /// `allowInsert == false` is what makes the silent refresh safe: it
    /// never adds an entry the user didn't explicitly save.
    private func upsert(session: SeshSession, memberCount: Int, hostName: String?, members: [SavedMember], allowInsert: Bool) {
        let existing = groups.first(where: { $0.id == session.id })
        // Preserve the previously-known host name when this refresh
        // hasn't loaded the host's profile yet — otherwise a transient
        // nil would clobber a perfectly good label.
        let preservedHostName: String? = {
            if let incoming = hostName, !incoming.isEmpty { return incoming }
            return existing?.lastHostName
        }()
        // Same defensive carve-out for the member roster: if the
        // refresh tick happens before profiles are cached, `members`
        // can come in empty. Don't overwrite a perfectly good roster
        // with an empty one.
        let preservedMembers: [SavedMember] = {
            if !members.isEmpty { return members }
            return existing?.savedMembers ?? []
        }()
        let entry = SavedGroup(
            id: session.id,
            joinCode: session.joinCode,
            lastJoinedAt: Date(),
            lastMemberCount: max(memberCount, 1),
            lastHostName: preservedHostName,
            savedMembers: preservedMembers
        )
        if let idx = groups.firstIndex(where: { $0.id == session.id }) {
            groups[idx] = entry
        } else if allowInsert {
            groups.append(entry)
        } else {
            return
        }
        groups.sort { $0.lastJoinedAt > $1.lastJoinedAt }
        if groups.count > maxEntries {
            groups = Array(groups.prefix(maxEntries))
        }
        persist()
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(groups) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let decoded = try? dec.decode([SavedGroup].self, from: data) else {
            // Schema drift — drop the cache rather than wedging on it.
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        groups = decoded.sorted { $0.lastJoinedAt > $1.lastJoinedAt }
    }
}

// MARK: - Invite UI
//
// Two pieces sit on top of `InvitesService`:
//
//   - `InviteBanner` — pinned card under the ModeTopBar whenever there's
//     at least one pending invite. Renders the most recent sender's avatar
//     + a "+N more" affordance when the inbox has more than one row.
//   - `InvitesSheet` — full inbox, presented when the banner is tapped.
//     Each row has Accept / Decline buttons that delegate back to the
//     SessionView so the accept path can hop straight into the session.
//
// The two views are intentionally read-only over `pending` (no local
// state) so polling-driven updates flow through unmodified.

private struct InviteBanner: View {
    let count: Int
    let latest: Invite?
    let senderProfiles: [UUID: Profile]
    let onTap: () -> Void

    /// Pulsing glow ring + subtle scale. Drives both the outer shadow and
    /// the leading "NEW" pip so the banner feels alive — important for an
    /// alert that doesn't have a push notification behind it.
    @State private var pulse = false
    /// Springy entrance — the banner drops in then settles with a tiny
    /// over-shoot. Triggered on first appear so each new invite gets the
    /// "look at me" beat without re-running on every parent re-render.
    @State private var hasAppeared = false

    private var senderName: String {
        guard let latest else { return "Someone" }
        return senderProfiles[latest.senderId]?.name ?? "Someone"
    }

    private var senderAvatarURL: String? {
        guard let latest else { return nil }
        return senderProfiles[latest.senderId]?.avatarURL
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                ZStack {
                    // Pulsing ring behind the avatar — reads as a "live"
                    // indicator without needing a separate dot.
                    Circle()
                        .stroke(Color.whiskey.opacity(pulse ? 0.0 : 0.55), lineWidth: 2)
                        .scaleEffect(pulse ? 1.55 : 1.0)
                        .frame(width: 44, height: 44)
                    Circle()
                        .stroke(Color.whiskey.opacity(pulse ? 0.0 : 0.35), lineWidth: 2)
                        .scaleEffect(pulse ? 1.85 : 1.0)
                        .frame(width: 44, height: 44)
                    AvatarView(
                        urlString: senderAvatarURL,
                        initial: String(senderName.prefix(1)).uppercased(),
                        size: 44
                    )
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.ink)
                            .frame(width: 6, height: 6)
                            .shadow(color: Color.ink.opacity(0.6), radius: 2)
                        Text(count > 1 ? "\(count) NEW INVITES" : "NEW INVITE")
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .tracking(2.4)
                            .foregroundStyle(Color.ink)
                    }
                    Text(count > 1
                         ? "\(senderName) and \(count - 1) other\(count - 1 == 1 ? "" : "s") want you in"
                         : "\(senderName) wants you to join the sesh")
                        .font(.system(size: 14, weight: .black, design: .rounded))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                ZStack {
                    Circle()
                        .fill(Color.ink.opacity(0.18))
                        .frame(width: 30, height: 30)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(Color.ink)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(
                ZStack {
                    // Solid whiskey base + a soft top-highlight gradient
                    // for depth — without it the card reads flat.
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.whiskey)
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.cream.opacity(0.18), .clear],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.cream.opacity(0.35), lineWidth: 1)
            )
            // Layered glow: a tight whiskey halo for color, plus a wider
            // soft black shadow for depth. Together the banner lifts off
            // the page hard enough to read as "ALERT" not "card".
            .shadow(color: Color.whiskey.opacity(pulse ? 0.85 : 0.55), radius: pulse ? 22 : 14, y: 8)
            .shadow(color: Color.black.opacity(0.45), radius: 18, y: 12)
            .scaleEffect(hasAppeared ? 1.0 : 0.85)
            .opacity(hasAppeared ? 1.0 : 0)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(count > 1 ? "\(count) new sesh invites" : "New sesh invite")
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.7)) {
                hasAppeared = true
            }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

private struct InvitesSheet: View {
    @ObservedObject var invites: InvitesService
    let onAccept: (Invite) -> Void
    let onDecline: (Invite) -> Void

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("INVITES")
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .tracking(2.4)
                            .foregroundStyle(Color.bronze)
                        Text(invites.pending.isEmpty
                             ? "All caught up"
                             : "Tap accept to drop straight into the sesh")
                            .font(.system(size: 22, weight: .black, design: .rounded))
                            .foregroundStyle(Color.cream)
                            .lineLimit(2)
                    }
                    .padding(.top, 8)

                    if invites.pending.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "tray")
                                .font(.system(size: 32, weight: .light))
                                .foregroundStyle(Color.cream.opacity(0.45))
                            Text("Your inbox is empty.")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.cream.opacity(0.55))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(invites.pending) { invite in
                                InviteRow(
                                    invite: invite,
                                    sender: invites.senderProfiles[invite.senderId],
                                    onAccept: { onAccept(invite) },
                                    onDecline: { onDecline(invite) }
                                )
                            }
                        }
                    }

                    if let err = invites.error {
                        Text(err)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(Color(red: 0.85, green: 0.32, blue: 0.23))
                    }

                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct InviteRow: View {
    let invite: Invite
    let sender: Profile?
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                AvatarView(
                    urlString: sender?.avatarURL,
                    initial: String((sender?.name ?? "?").prefix(1)).uppercased(),
                    size: 40
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(sender?.name ?? "Someone")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.cream)
                    Text("Sent you a sesh — code \(invite.joinCode)")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.65))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Button(action: onDecline) {
                    Text("DECLINE")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .tracking(1.6)
                        .foregroundStyle(Color.cream.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.cream.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.cream.opacity(0.18), lineWidth: 1)
                        )
                }
                .buttonStyle(PressScaleStyle())

                Button(action: onAccept) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .black))
                        Text("ACCEPT")
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .tracking(1.6)
                    }
                    .foregroundStyle(Color.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.whiskey)
                    )
                    .shadow(color: Color.whiskey.opacity(0.45), radius: 12, y: 5)
                }
                .buttonStyle(PressScaleStyle())
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.inkElev)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.cream.opacity(0.10), lineWidth: 1)
        )
    }
}

// MARK: - Root

struct RootView: View {
    @StateObject private var auth = AuthService()
    /// One invites inbox per signed-in user, owned at the root so the
    /// poller survives Sheet/TabView churn lower in the tree. Started in
    /// `.onChange(of: auth.state)` and stopped on sign-out so the loop
    /// only runs while there's actually a user to fetch invites for.
    @StateObject private var invites = InvitesService()

    var body: some View {
        ZStack {
            switch auth.state {
            case .loading:
                LoadingView()
                    .transition(.opacity)
            case .signedOut:
                AuthView(auth: auth)
                    .transition(.opacity)
            case .signedIn(let profile):
                SessionView(profile: profile, auth: auth, invites: invites)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: auth.state)
        .onChange(of: auth.state) { _, new in
            switch new {
            case .signedIn:
                invites.start()
                // Ask for notification permission (first time) and register
                // / re-upload the APNs token now that there's a user to key
                // it to. No-op + graceful if the Push capability isn't on
                // the target yet — see PushNotifications.swift.
                PushManager.shared.requestAuthorizationAndRegister()
                PushManager.shared.reuploadTokenIfAvailable()
            case .signedOut, .loading:
                invites.stop()
            }
        }
    }
}

// MARK: - Loading screen

private struct LoadingView: View {
    var body: some View {
        ZStack {
            AtmosphereBackground(accent: .whiskey)
            VStack(spacing: 14) {
                Circle()
                    .fill(Color.whiskey)
                    .frame(width: 10, height: 10)
                    .shadow(color: Color.whiskey.opacity(0.9), radius: 12)
                Text("sesh")
                    .font(.system(size: 40, weight: .black, design: .rounded))
                    .italic()
                    .tracking(-1.5)
                    .foregroundStyle(Color.cream)
                ProgressView()
                    .tint(Color.whiskey)
                    .padding(.top, 6)
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Auth screen

private struct AuthView: View {
    @ObservedObject var auth: AuthService

    enum Mode: String { case signIn, signUp }
    @State private var mode: Mode = .signIn

    @State private var email = ""
    @State private var password = ""

    @State private var name = ""
    @State private var age: Double = 25
    @State private var sex: Sex = .male
    @State private var weightKg: Double = 75
    @State private var avatarData: Data?

    @State private var loading = false
    @State private var errorMessage: String?
    @FocusState private var focus: Field?

    enum Field { case email, password, name }

    private var canSubmit: Bool {
        guard email.contains("@"), password.count >= 6 else { return false }
        if mode == .signUp {
            return !name.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }

    var body: some View {
        ZStack {
            AtmosphereBackground(accent: .whiskey)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    modeSwitcher
                    fields
                    if let errorMessage {
                        errorBanner(errorMessage)
                    }
                    submitButton
                    footnote
                }
                .padding(.horizontal, 28)
                .padding(.top, 56)
                .padding(.bottom, 48)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.whiskey)
                    .frame(width: 8, height: 8)
                    .shadow(color: Color.whiskey.opacity(0.9), radius: 8)
                Text("EST. TONIGHT")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(Color.bronze)
            }
            Text("sesh")
                .font(.system(size: 72, weight: .black, design: .rounded))
                .italic()
                .tracking(-3)
                .foregroundStyle(Color.cream)
            Text(mode == .signIn ? "Welcome back." : "Join the tab.")
                .font(.system(size: 20, weight: .regular, design: .rounded))
                .italic()
                .foregroundStyle(Color.cream.opacity(0.7))
                .padding(.top, 2)
        }
    }

    private var modeSwitcher: some View {
        HStack(spacing: 8) {
            ModePill(label: "Sign in", selected: mode == .signIn) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                    mode = .signIn
                    errorMessage = nil
                }
            }
            ModePill(label: "Create account", selected: mode == .signUp) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                    mode = .signUp
                    errorMessage = nil
                }
            }
        }
    }

    @ViewBuilder
    private var fields: some View {
        VStack(spacing: 10) {
            LoungeField(
                label: "EMAIL",
                text: $email,
                placeholder: "you@nightly.com",
                keyboard: .emailAddress,
                autocapitalize: false
            )
            .focused($focus, equals: .email)

            LoungeSecureField(
                label: "PASSWORD",
                text: $password,
                placeholder: "at least 6 characters"
            )
            .focused($focus, equals: .password)

            if mode == .signUp {
                HStack(spacing: 14) {
                    AvatarPicker(
                        existingURL: nil,
                        initial: name.isEmpty ? "?" : String(name.prefix(1)).uppercased(),
                        size: 72,
                        imageData: $avatarData,
                        onRemove: { avatarData = nil }
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PHOTO")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(2)
                            .foregroundStyle(Color.bronze)
                        Text("Optional — tap to add.")
                            .font(.system(size: 12, weight: .regular, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.65))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 4)

                LoungeField(
                    label: "NAME",
                    text: $name,
                    placeholder: "What should we call you?"
                )
                .focused($focus, equals: .name)

                LoungeNumberField(
                    label: "AGE",
                    value: $age,
                    range: 18...100,
                    step: 1,
                    unit: "years"
                )

                LoungePickerField(label: "SEX") {
                    SexToggle(sex: $sex, accent: .whiskey)
                }

                LoungeNumberField(
                    label: "WEIGHT",
                    value: $weightKg,
                    range: 40...160,
                    step: 1,
                    unit: "kg"
                )
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Status.drunk.color)
                .padding(.top, 1)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.cream.opacity(0.9))
                .lineSpacing(2)
            Spacer()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Status.drunk.color.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Status.drunk.color.opacity(0.35), lineWidth: 1))
    }

    private var submitButton: some View {
        Button {
            focus = nil
            submit()
        } label: {
            HStack {
                if loading {
                    ProgressView().tint(Color.ink)
                    Spacer()
                } else {
                    Text(mode == .signIn ? "SIGN IN" : "CREATE ACCOUNT")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .tracking(3)
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .bold))
                }
            }
            .foregroundStyle(Color.ink)
            .padding(.vertical, 16)
            .padding(.horizontal, 20)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(canSubmit ? Color.cream : Color.cream.opacity(0.4))
            )
            .shadow(color: Color.whiskey.opacity(canSubmit ? 0.5 : 0), radius: 20, y: 10)
        }
        .disabled(!canSubmit || loading)
        .buttonStyle(PressScaleStyle())
    }

    private var footnote: some View {
        Text("By continuing you accept that sesh is a fun BAC estimate, not a legal or medical reference. Never use it to decide whether to drive.")
            .font(.system(size: 10))
            .lineSpacing(3)
            .foregroundStyle(Color.bronze)
            .padding(.top, 4)
    }

    private func submit() {
        loading = true
        errorMessage = nil
        Task { @MainActor in
            do {
                switch mode {
                case .signIn:
                    try await auth.signIn(email: email, password: password)
                case .signUp:
                    try await auth.signUp(
                        email: email,
                        password: password,
                        name: name.trimmingCharacters(in: .whitespaces),
                        age: Int(age),
                        sex: sex,
                        weightKg: weightKg,
                        avatarData: avatarData
                    )
                }
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            loading = false
        }
    }
}

private struct ModePill: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(2.2)
                .foregroundStyle(selected ? Color.ink : Color.cream.opacity(0.7))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(selected ? Color.cream : Color.cream.opacity(0.04))
                )
                .overlay(
                    Capsule().strokeBorder(selected ? Color.clear : Color.cream.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: selected ? Color.whiskey.opacity(0.4) : .clear, radius: 12)
        }
        .buttonStyle(PressScaleStyle())
    }
}

// MARK: - Lounge form fields

private struct LoungeField: View {
    let label: String
    @Binding var text: String
    let placeholder: String
    var keyboard: UIKeyboardType = .default
    var autocapitalize: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(Color.bronze)
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Color.cream.opacity(0.3)))
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.cream)
                .tint(Color.whiskey)
                .keyboardType(keyboard)
                .textInputAutocapitalization(autocapitalize ? .words : .never)
                .autocorrectionDisabled(!autocapitalize)
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cream.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.cream.opacity(0.08), lineWidth: 1))
        }
    }
}

private struct LoungeSecureField: View {
    let label: String
    @Binding var text: String
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(Color.bronze)
            SecureField("", text: $text, prompt: Text(placeholder).foregroundStyle(Color.cream.opacity(0.3)))
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.cream)
                .tint(Color.whiskey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cream.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.cream.opacity(0.08), lineWidth: 1))
        }
    }
}

private struct LoungeNumberField: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(Color.bronze)
            HStack(spacing: 14) {
                Button { dec() } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.cream)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.smoke))
                        .overlay(Circle().strokeBorder(Color.cream.opacity(0.08), lineWidth: 1))
                }
                .buttonStyle(PressScaleStyle())

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Int(value))")
                        .font(.system(size: 26, weight: .heavy, design: .rounded))
                        .italic()
                        .foregroundStyle(Color.cream)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: value))
                    Text(unit)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .tracking(1.6)
                        .foregroundStyle(Color.bronze)
                }
                .frame(maxWidth: .infinity)

                Button { inc() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.cream)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.smoke))
                        .overlay(Circle().strokeBorder(Color.cream.opacity(0.08), lineWidth: 1))
                }
                .buttonStyle(PressScaleStyle())
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cream.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.cream.opacity(0.08), lineWidth: 1))
        }
    }

    private func inc() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            value = min(range.upperBound, value + step)
        }
    }
    private func dec() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            value = max(range.lowerBound, value - step)
        }
    }
}

private struct LoungePickerField<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(Color.bronze)
            content()
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cream.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.cream.opacity(0.08), lineWidth: 1))
        }
    }
}

// MARK: - Mode switching
//
// Two top-level modes — PLAN and LIVE — are presented as a paged TabView
// (iPhone-home-style swipe). The user picks a side either by tapping the
// pill switcher or by swiping horizontally. PLAN is the calculator-with-
// duration-slider experience: "I'll drink X over Y hours, what's my BAC?"
// LIVE is real-time tracking with timestamped drinks and decay between
// pours. Keeping the names short and oppositional makes the switcher
// readable at a glance.

enum SeshMode: String, Hashable, Identifiable {
    case plan, live

    /// Self-identity is fine for `.sheet(item:)` — there are only two
    /// values and they're each their own identity.
    var id: String { rawValue }

    /// Human-facing label used in the mirror button ("Continue with PLAN
    /// group …"). Uppercase to match the switcher pill typography.
    var label: String {
        switch self {
        case .plan: return "PLAN"
        case .live: return "LIVE"
        }
    }

    var other: SeshMode {
        self == .plan ? .live : .plan
    }
}

/// Top bar shown above the paged TabView. Houses the mode switcher and
/// the profile chip — replaces the old Masthead + LiveSeshBar split.
/// Pinned to the top of the screen so it doesn't scroll with content.
private struct ModeTopBar: View {
    @Binding var mode: SeshMode
    let profile: Profile
    /// True when there's something happening in LIVE that the user should
    /// notice from the PLAN side (live timeline running, group has live
    /// drinks, etc.). Drives the pulsing dot on the LIVE segment.
    let liveActive: Bool
    let onTapProfile: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ModeSwitcher(mode: $mode, liveActive: liveActive)
            Spacer(minLength: 8)
            Button(action: onTapProfile) {
                AvatarView(
                    urlString: profile.avatarURL,
                    initial: String(profile.name.prefix(1)).uppercased(),
                    size: 32
                )
                .overlay(
                    Circle()
                        .strokeBorder(Color.cream.opacity(0.18), lineWidth: 1)
                )
            }
            .buttonStyle(PressScaleStyle())
        }
    }
}

/// Pill-shaped two-segment switcher. Tapping a segment animates the
/// thumb across to the new selection. The thumb is filled with whiskey
/// for LIVE and a more neutral cream tint for PLAN — visually
/// reinforcing the energy difference between the two modes.
private struct ModeSwitcher: View {
    @Binding var mode: SeshMode
    let liveActive: Bool

    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 0) {
            segment(.plan, label: "PLAN")
            segment(.live, label: "LIVE", showLiveDot: liveActive)
        }
        .padding(3)
        .background(
            Capsule()
                .fill(Color.cream.opacity(0.05))
        )
        .overlay(
            Capsule()
                .strokeBorder(Color.cream.opacity(0.1), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mode")
        .accessibilityValue(mode == .plan ? "Plan" : "Live")
    }

    @ViewBuilder
    private func segment(_ value: SeshMode, label: String, showLiveDot: Bool = false) -> some View {
        let isOn = mode == value
        let isLive = value == .live
        Button {
            // Spring matches the TabView page swipe so the thumb and the
            // page transition feel like one motion.
            withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                mode = value
            }
        } label: {
            HStack(spacing: 6) {
                if showLiveDot {
                    LivePulseDot()
                        .frame(width: 7, height: 7)
                }
                Text(label)
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .tracking(2.2)
                    .foregroundStyle(textColor(isOn: isOn, isLive: isLive))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .padding(.horizontal, 14)
            .background(
                ZStack {
                    if isOn {
                        Capsule()
                            .fill(thumbFill(isLive: isLive))
                            .matchedGeometryEffect(id: "thumb", in: thumb)
                            .shadow(
                                color: (isLive ? Color.whiskey : Color.cream).opacity(isLive ? 0.45 : 0.15),
                                radius: 10, y: 4
                            )
                    }
                }
            )
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityLabel(label)
    }

    private func thumbFill(isLive: Bool) -> Color {
        isLive ? Color.whiskey : Color.cream.opacity(0.92)
    }

    private func textColor(isOn: Bool, isLive: Bool) -> Color {
        if isOn {
            return isLive ? Color.ink : Color.ink
        }
        return Color.cream.opacity(0.55)
    }
}

/// Slowly-pulsing dot used on the LIVE segment when the live timeline is
/// running. Pure CSS-style: scaleEffect + opacity tied to a repeating
/// animation. No timer, no @State — SwiftUI repeats it for free.
private struct LivePulseDot: View {
    @State private var on = false

    var body: some View {
        Circle()
            .fill(Color.whiskey)
            .shadow(color: Color.whiskey.opacity(0.85), radius: on ? 5 : 2)
            .scaleEffect(on ? 1.12 : 0.9)
            .opacity(on ? 1.0 : 0.55)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true)) {
                    on = true
                }
            }
    }
}

// MARK: - Session view (the former ContentView)

private struct SessionView: View {
    let profile: Profile
    @ObservedObject var auth: AuthService
    /// In-app invite inbox, owned by RootView so the polling loop is
    /// scoped to the auth lifecycle rather than this view's lifetime.
    @ObservedObject var invites: InvitesService
    /// Two independent group stores — one per mode. A user can be in
    /// different groups across PLAN and LIVE, in only one, or in
    /// neither. Each store remembers its own session across launches
    /// (UserDefaults, keyed by scope). The cousin reference is wired in
    /// `.task` below so each store can avoid clobbering the other when
    /// they happen to point at the same session (the "mirror" case).
    @StateObject private var planGroup = SessionService(scope: .plan)
    @StateObject private var liveGroup = SessionService(scope: .live)
    @StateObject private var live = LiveSeshState()
    @StateObject private var recents = RecentDrinksStore()
    /// Manually-added live-mode participants. Live-only by design — see
    /// the GhostMembersStore comment for the reasoning. Lives in
    /// SessionView so it survives mode switches and tab gestures (a
    /// store on LiveSeshView would re-init every time the user swiped
    /// back to PLAN and over again).
    @StateObject private var ghosts = GhostMembersStore()
    /// On-device cache of groups the user has been in. Updated whenever a
    /// SessionService refresh lands on a session it's tracking. Surfaces
    /// in GroupSheet's idle view so rejoining a previous group is a tap
    /// rather than another round of "what was the code again?".
    @StateObject private var savedGroups = SavedGroupsStore()
    /// Location + venue services. Owned here (the topmost user-facing
    /// view) and passed into LiveSeshView so both modes share one source
    /// of truth for "where am I tonight?" and "what specials apply?".
    @StateObject private var location = LocationService()
    @StateObject private var venues = VenueService()

    @State private var localOrder: [OrderItem] = []
    @State private var hours: Double = 1
    @State private var menuOpen = false
    @State private var profileOpen = false
    /// Which group sheet is open, if any. Driven by GroupBar taps in
    /// each page. Using a scope-tagged value lets one `.sheet` handle
    /// both modes — fewer state vars, no chance of both sheets fighting.
    @State private var groupSheetScope: SeshMode? = nil
    @State private var shareMode = false
    @State private var venueOpen = false
    /// Whether the invites inbox sheet is open. Pinned-banner tap opens
    /// it; accept/decline inside the sheet drains the banner naturally
    /// because each action removes the row from `invites.pending`.
    @State private var invitesSheetOpen = false
    /// Observes push taps. When a sesh-invite notification is tapped,
    /// `push.openInvites` flips true and we present the inbox + refresh.
    @ObservedObject private var push = PushManager.shared
    /// Which page the user is on. Driven by both the segmented switcher
    /// at the top and the swipe gesture on the underlying TabView.
    @State private var mode: SeshMode = .plan

    private let eliminationRate = 0.015

    private var personalOrder: [OrderItem] {
        if planGroup.isActive {
            // Resolve via VenueService so venue specials (Fittkittlaren etc.)
            // — which aren't in DrinkCatalog — still render in the order card.
            return planGroup.myDrinks().map { d in
                OrderItem(id: d.id, option: venues.resolveOption(for: d), shared: false)
            }
        }
        return localOrder
    }

    private var sharedOrder: [OrderItem] {
        guard planGroup.isActive else { return [] }
        return planGroup.sharedDrinks().map { d in
            OrderItem(id: d.id, option: venues.resolveOption(for: d), shared: true)
        }
    }

    /// Combined view: your drinks + any shared rounds the group has going.
    private var combinedOrder: [OrderItem] {
        personalOrder + sharedOrder
    }

    /// The list shown in the menu sheet (what +/- operates on there). In share mode this is the shared pool.
    private var order: [OrderItem] {
        (planGroup.isActive && shareMode) ? sharedOrder : personalOrder
    }

    private func orderBinding() -> Binding<[OrderItem]> {
        Binding(
            get: { order },
            set: { newValue in
                if !planGroup.isActive { localOrder = newValue }
                // group changes are driven through MenuSheet callbacks
            }
        )
    }

    /// Ethanol grams attributed to me for BAC: personal + even share of the group's shared pool.
    private var totalAlcoholGrams: Double {
        if planGroup.isActive {
            return planGroup.effectiveGrams(for: profile.id)
        }
        return localOrder.reduce(0) { $0 + $1.option.grams }
    }

    /// Use the manual hours slider in every mode.
    private var effectiveHours: Double { hours }

    private var bac: Double {
        let bodyGrams = profile.weightKg * 1000
        let raw = (totalAlcoholGrams / (bodyGrams * profile.sex.r)) * 100
        return max(0, raw - eliminationRate * effectiveHours)
    }

    /// Hours until BAC reaches the given threshold (default 0.0 = fully sober).
    /// Liver clears ethanol at ~0.015 BAC%/hr regardless of how much you've
    /// drunk, so this is a straight linear projection from the current BAC.
    private func hoursUntil(bacThreshold: Double) -> Double {
        max(0, (bac - bacThreshold) / eliminationRate)
    }

    private var status: Status {
        switch bac {
        case ..<0.02: return .sober
        case 0.02..<0.05: return .buzzed
        case 0.05..<0.08: return .impaired
        case 0.08..<0.15: return .drunk
        default: return .danger
        }
    }

    private var vibe: VibeMessage {
        let msgs = status.messages
        return msgs[max(0, order.count) % msgs.count]
    }

    private func addLocal(_ option: DrinkOption) {
        recents.record(option)
        if planGroup.isActive {
            let shared = shareMode
            // Plan ledger: store stamps live=false from its scope.
            let t: Task<Void, Never> = Task { await planGroup.addDrink(option, shared: shared) }
            _ = t
        } else {
            localOrder.append(OrderItem(option: option))
        }
    }

    /// Bridge from a SessionService into the SavedGroupsStore. This is
    /// the *silent* refresh path: it only updates entries the user has
    /// already explicitly saved (via the active-view star toggle) so
    /// poll ticks don't sneak random groups into the saved list.
    ///
    /// Called on every member-change tick (and on first appear) so the
    /// snapshot fields on already-saved entries — host name, member
    /// count, "last joined" timestamp — stay current as the user
    /// re-visits a group.
    ///
    /// Quietly no-ops when the store has no active session (common
    /// during the resume window before resumeIfAny lands) or when the
    /// session isn't in the saved list.
    private func recordSavedGroup(from store: SessionService) {
        guard let session = store.session else { return }
        let hostName = store.memberProfiles[session.hostId]?.name
        let myId = profile.id
        // Snapshot everyone *except* the current user — the invite
        // share card lists "the previous crew" from the host's POV, so
        // their own name shouldn't show up there. Members whose
        // profiles haven't been cached yet are dropped (they'll fill in
        // on a later poll tick once the profile lands).
        let snapshot: [SavedMember] = store.members.compactMap { member in
            guard member.profileId != myId,
                  let prof = store.memberProfiles[member.profileId] else { return nil }
            return SavedMember(id: prof.id, name: prof.name, avatarURL: prof.avatarURL)
        }
        savedGroups.refreshSnapshotIfSaved(
            session: session,
            memberCount: store.members.count,
            hostName: hostName,
            members: snapshot
        )
    }

    private func removeOneLocal(_ option: DrinkOption) {
        if planGroup.isActive {
            let shared = shareMode
            let t: Task<Void, Never> = Task { await planGroup.removeMyLast(of: option, shared: shared) }
            _ = t
        } else if let idx = localOrder.lastIndex(where: { $0.option == option }) {
            localOrder.remove(at: idx)
        }
    }

    /// True when something live is happening that the user should notice
    /// from PLAN — drives the pulsing dot on the LIVE pill. Looks at the
    /// LIVE store specifically (not plan) so a quiet plan group with no
    /// live drinks doesn't pulse the LIVE pill needlessly.
    private var liveActive: Bool {
        if liveGroup.isActive { return liveGroup.hasLiveActivity }
        return live.isActive
    }

    var body: some View {
        ZStack {
            // The atmosphere accent shifts when the user is on LIVE so
            // the whole screen reads "this is the live experience" even
            // before any content swipes in.
            AtmosphereBackground(accent: mode == .live ? Color.whiskey : status.color)
                .animation(.easeInOut(duration: 0.45), value: mode)

            VStack(spacing: 0) {
                ModeTopBar(
                    mode: $mode,
                    profile: profile,
                    liveActive: liveActive,
                    onTapProfile: { profileOpen = true }
                )
                .padding(.horizontal, 22)
                .padding(.top, 4)
                .padding(.bottom, 8)

                TabView(selection: $mode) {
                    planPage.tag(SeshMode.plan)
                    livePage.tag(SeshMode.live)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                // Smooth horizontal swipe between modes; matches the
                // ModeSwitcher's spring so tapping the pill and dragging
                // the page feel like the same animation.
                .animation(.spring(response: 0.4, dampingFraction: 0.82), value: mode)
            }

            // Floating invite banner — pinned just below the ModeTopBar.
            // Drops in from the top whenever a new pending invite arrives
            // and snaps out the moment the inbox empties (accept,
            // decline, or sender flipped status server-side).
            if !invites.pending.isEmpty {
                VStack {
                    InviteBanner(
                        count: invites.pending.count,
                        latest: invites.pending.first,
                        senderProfiles: invites.senderProfiles,
                        onTap: { invitesSheetOpen = true }
                    )
                    .padding(.horizontal, 22)
                    .padding(.top, 56)   // clears ModeTopBar
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(20)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: invites.pending.count)
        // A tapped invite push asks us to open the inbox. Refresh first so
        // the just-arrived invite is present even if the 7s poll hasn't
        // come around yet, then present the sheet and reset the flag.
        .onChange(of: push.openInvites) { _, shouldOpen in
            guard shouldOpen else { return }
            Task { await invites.refresh() }
            invitesSheetOpen = true
            push.openInvites = false
        }
        .sheet(isPresented: $invitesSheetOpen) {
            InvitesSheet(
                invites: invites,
                onAccept: { invite in
                    // Accept = join in the SAME mode the sender was in
                    // when they fired this invite. A live host's invite
                    // has to drop the recipient into live, otherwise
                    // they'd land in plan mode of the same session and
                    // miss every drink the host is logging live-side.
                    Task {
                        await invites.updateStatus(invite.id, to: "accepted")
                        if invite.mode == "live" {
                            await liveGroup.join(code: invite.joinCode)
                            // Make sure the user actually lands on the
                            // LIVE page so they SEE the group they just
                            // joined — without this they'd accept and
                            // then wonder where it went.
                            mode = .live
                        } else {
                            await planGroup.join(code: invite.joinCode)
                            mode = .plan
                        }
                        invitesSheetOpen = false
                    }
                },
                onDecline: { invite in
                    Task { await invites.updateStatus(invite.id, to: "declined") }
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .preferredColorScheme(.dark)
        .onChange(of: mode) { _, new in
            // Auto-start the solo live timeline the first time the user
            // swipes into LIVE — saves them from a "Start" → "Add" two-step.
            // In a live group, the group itself is the live backing so we
            // don't touch LiveSeshState.
            if new == .live, !liveGroup.isActive, !live.isActive {
                live.start()
            }
        }
        .animation(.spring(response: 0.55, dampingFraction: 0.82), value: status)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: planGroup.isActive)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: liveGroup.isActive)
        // Wire each store's cousin reference so leave() doesn't yank the
        // shared session_members row when both stores happen to track the
        // same session. Has to happen before resumeIfAny so leaves issued
        // during resume (e.g. stale persisted session) check correctly.
        .task {
            planGroup.cousin = liveGroup
            liveGroup.cousin = planGroup
            // Resume both in parallel — independent network calls, no
            // ordering requirement between them.
            await withTaskGroup(of: Void.self) { tg in
                tg.addTask { await planGroup.resumeIfAny() }
                tg.addTask { await liveGroup.resumeIfAny() }
            }
            // Garbage-collect any stale solo sesh that was abandoned
            // without an explicit END (e.g., user logged a drink
            // weeks ago and never reopened the app). The check is a
            // no-op when BAC is still > 0, so a legitimately long
            // night isn't affected — only sessions that have
            // biologically wound down get cleaned up. If we did end
            // it, also tear down the lock-screen activity so the
            // dead card stops following the user around.
            if live.endIfStale(profile: profile) {
                LiveActivityController.shared.end()
            }
        }
        // Pull venue + specials catalog on first launch so the chip /
        // picker have something to render. With no curated seed list,
        // an empty DB just means "Featured" stays empty and the user
        // discovers their bar via the search field.
        .task { await venues.refresh() }
        // When the plan members list refreshes (entry or 3s poll), pull
        // my synced duration from the DB into the local slider so the
        // slider position matches what other phones see.
        .onChange(of: planGroup.members) { _, _ in
            guard planGroup.isActive, let synced = planGroup.myDuration() else { return }
            // Avoid jitter when the local value already matches.
            if abs(synced - hours) > 0.01 {
                hours = synced
            }
            recordSavedGroup(from: planGroup)
        }
        // Same recording hook for live so a group joined only in live
        // mode still ends up in the saved-groups list. The two `.onChange`
        // calls dedupe naturally — `record` keys on session id, so a
        // mirrored group only ever produces one entry.
        .onChange(of: liveGroup.members) { _, _ in
            recordSavedGroup(from: liveGroup)
        }
        // First-frame seed: if either store resumed into an existing
        // session before the .onChange observers were wired, record it
        // now so the saved-groups list reflects "where I am right now"
        // even if the user never refreshes the roster.
        .onAppear {
            recordSavedGroup(from: planGroup)
            recordSavedGroup(from: liveGroup)
        }
        // Profile edits (weight/age/sex) need to flow into the live
        // Widmark formula immediately. Otherwise the per-drink BAC
        // stays anchored to the cached profile until the next 3-second
        // poll fetches the new row from the DB. Patch both stores'
        // memberProfiles so PLAN and LIVE reflect the change in lockstep.
        .onChange(of: profile) { _, new in
            planGroup.applyMyProfile(new)
            liveGroup.applyMyProfile(new)
        }
        .sheet(isPresented: $menuOpen) {
            MenuSheet(
                order: orderBinding(),
                shareMode: $shareMode,
                showShareToggle: planGroup.isActive,
                venueSpecials: venues.currentSpecialsAsOptions(),
                venueName: venues.currentVenue?.name,
                onAdd: { addLocal($0) },
                onRemove: { removeOneLocal($0) }
            )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.ink)
        }
        .sheet(isPresented: $profileOpen) {
            ProfileSheet(profile: profile, auth: auth)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.ink)
        }
        .sheet(item: $groupSheetScope) { scope in
            // One sheet, two scopes. The store + cousin pair flips
            // depending on which page asked to open it. Mirror button
            // inside reads from `cousin` to offer "Continue with [other]
            // group · CODE".
            GroupSheet(
                group: scope == .plan ? planGroup : liveGroup,
                cousin: scope == .plan ? liveGroup : planGroup,
                savedGroups: savedGroups,
                invites: invites
            )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.ink)
        }
        .sheet(isPresented: $venueOpen) {
            VenueSheet(location: location, venues: venues)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.ink)
        }
    }

    // MARK: - Pages
    //
    // Two pages, one TabView. Both rely on shared SessionView state
    // (group, live, venues, recents) so swiping between them is just a
    // visual change — no data has to migrate.

    private var planPage: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                GroupBar(
                    scope: .plan,
                    session: planGroup.session,
                    memberCount: planGroup.members.count,
                    onTap: { groupSheetScope = .plan }
                )

                VenueChip(
                    location: location,
                    venues: venues,
                    onTap: { venueOpen = true }
                )

                BACReadout(
                    bac: bac,
                    status: status,
                    hoursUntilSober: hoursUntil(bacThreshold: 0.0),
                    hoursUntilEULimit: hoursUntil(bacThreshold: 0.02),
                    hoursUntilUSLimit: hoursUntil(bacThreshold: 0.08)
                )

                if planGroup.isActive {
                    GroupRoster(group: planGroup, selfId: profile.id, hours: hours)
                }

                VibeCard(status: status, message: vibe)

                VStack(spacing: 12) {
                    OrderCard(
                        order: combinedOrder,
                        memberCount: max(planGroup.members.count, 1),
                        groupActive: planGroup.isActive,
                        onOpen: {
                            shareMode = false
                            menuOpen = true
                        },
                        onOpenShared: planGroup.isActive ? {
                            shareMode = true
                            menuOpen = true
                        } : nil,
                        onRemoveOne: { option, shared in
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                                if planGroup.isActive {
                                    let t: Task<Void, Never> = Task { await planGroup.removeMyLast(of: option, shared: shared) }
                                    _ = t
                                } else if let idx = localOrder.lastIndex(where: { $0.option == option }) {
                                    localOrder.remove(at: idx)
                                }
                            }
                        },
                        onAddOne: { option, shared in
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                                recents.record(option)
                                if planGroup.isActive {
                                    let t: Task<Void, Never> = Task { await planGroup.addDrink(option, shared: shared) }
                                    _ = t
                                } else {
                                    localOrder.append(OrderItem(option: option))
                                }
                            }
                        }
                    )

                    InputRow(
                        kicker: "02",
                        title: "Duration",
                        valueText: formatHours(hours),
                        unit: "hours",
                        accent: status.color
                    ) {
                        TintedSlider(value: $hours, range: 0...12, step: 0.25, accent: status.color)
                            .onChange(of: hours) { _, newValue in
                                guard planGroup.isActive else { return }
                                let t: Task<Void, Never> = Task {
                                    await planGroup.updateMyDuration(newValue)
                                }
                                _ = t
                            }
                    }

                    // YouRow (sex/weight/age stats row) intentionally
                    // removed — those values are personal data and the
                    // profile sheet (top-bar avatar tap) already exposes
                    // them in an editable form. Keeping a duplicate at
                    // the bottom of the plan page just put a private
                    // readout in the line of sight of anyone glancing
                    // at the host's phone.
                }

                Disclaimer()
                    .padding(.top, 4)
            }
            .padding(.horizontal, 24)
            .padding(.top, 6)
            .padding(.bottom, 72)
        }
        .animation(.spring(response: 0.55, dampingFraction: 0.82), value: status)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: planGroup.isActive)
    }

    /// LIVE page — the existing LiveSeshView, embedded inline. The
    /// `embedded` flag tells it to skip its own header (the ModeTopBar
    /// above the TabView is shared) and to route the END action to the
    /// solo-live "clear timeline" flow rather than dismissing a modal.
    private var livePage: some View {
        LiveSeshView(
            live: live,
            group: liveGroup,
            recents: recents,
            location: location,
            venues: venues,
            ghosts: ghosts,
            profile: profile,
            embedded: true,
            onOpenGroupSheet: { groupSheetScope = .live },
            onExitLiveTimeline: {
                // Solo END handler: clear the timeline and slide back to
                // PLAN. In a group there's nothing to end here — the
                // group's lifecycle is owned by GroupSheet. Ghost members
                // also reset — they're scoped to the night, not the
                // app install (a stale ghost roster would silently
                // inflate tomorrow's roster + leaderboard). The
                // lock-screen activity is torn down here too — the
                // child view's confirmation handler does the same on
                // its path, this one covers parent-driven exits.
                ghosts.clearAll()
                LiveActivityController.shared.end()
                withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                    mode = .plan
                }
            }
        )
    }
}

// MARK: - Background

private struct AtmosphereBackground: View {
    let accent: Color

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()

            RadialGradient(
                colors: [accent.opacity(0.28), .clear],
                center: .init(x: 0.8, y: -0.05),
                startRadius: 20, endRadius: 520
            )
            .blendMode(.screen)
            .ignoresSafeArea()

            RadialGradient(
                colors: [Color.whiskey.opacity(0.14), .clear],
                center: .init(x: 0.1, y: 0.25),
                startRadius: 10, endRadius: 420
            )
            .blendMode(.screen)
            .ignoresSafeArea()

            LinearGradient(
                colors: [.clear, .ink.opacity(0.85)],
                startPoint: .center, endPoint: .bottom
            )
            .ignoresSafeArea()

            GrainOverlay()
                .opacity(0.07)
                .blendMode(.overlay)
                .allowsHitTesting(false)
                .ignoresSafeArea()
        }
    }
}

private struct GrainOverlay: View {
    var body: some View {
        Canvas { ctx, size in
            var rng = SystemRandomNumberGenerator()
            let count = Int((size.width * size.height) / 900)
            for _ in 0..<count {
                let x = Double.random(in: 0...size.width, using: &rng)
                let y = Double.random(in: 0...size.height, using: &rng)
                let a = Double.random(in: 0.02...0.18, using: &rng)
                let rect = CGRect(x: x, y: y, width: 1, height: 1)
                ctx.fill(Path(rect), with: .color(.white.opacity(a)))
            }
        }
    }
}

// MARK: - Header with profile chip

private struct Masthead: View {
    let profile: Profile
    let onTapProfile: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.whiskey)
                    .frame(width: 7, height: 7)
                    .shadow(color: Color.whiskey.opacity(0.9), radius: 8)
                Text("sesh")
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .italic()
                    .foregroundStyle(Color.cream)
                    .tracking(-0.5)
            }
            Spacer()
            Button(action: onTapProfile) {
                HStack(spacing: 8) {
                    AvatarView(
                        urlString: profile.avatarURL,
                        initial: String(profile.name.prefix(1)).uppercased(),
                        size: 26
                    )
                    Text(profile.name.split(separator: " ").first.map(String.init) ?? profile.name)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(Color.cream)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.cream.opacity(0.05)))
                .overlay(Capsule().strokeBorder(Color.cream.opacity(0.1), lineWidth: 1))
            }
            .buttonStyle(PressScaleStyle())
        }
    }
}

// MARK: - BAC readout

private struct BACReadout: View {
    let bac: Double
    let status: Status
    let hoursUntilSober: Double
    let hoursUntilEULimit: Double
    let hoursUntilUSLimit: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("HOW YOU'RE DOING")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(3.0)
                    .foregroundStyle(Color.bronze)
                Spacer()
                StatusPill(status: status)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(String(format: "%.3f", bac))
                        .font(.system(size: 68, weight: .black, design: .rounded))
                        .tracking(-2.2)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.cream, status.color.opacity(0.92)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: status.color.opacity(0.45), radius: 24, y: 8)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: bac))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    Text("%BAC")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(Color.bronze)
                        .padding(.bottom, 10)
                }

                Text(status.heroLabel)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.cream)

                Text(status.heroSubtitle)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.72))
            }

            BACScale(bac: bac, status: status)
                .padding(.top, 4)

            TimeToSoberRow(
                hoursUntilSober: hoursUntilSober,
                hoursUntilEULimit: hoursUntilEULimit,
                hoursUntilUSLimit: hoursUntilUSLimit,
                accent: status.color
            )
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 22)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.cream.opacity(0.045), Color.cream.opacity(0.012)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            status.color.opacity(0.35),
                            Color.white.opacity(0.04),
                            status.color.opacity(0.15)
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: status.color.opacity(0.28), radius: 40, y: 18)
        .shadow(color: .black.opacity(0.55), radius: 24, y: 12)
    }
}

// MARK: - Time to Sober

/// Shows the projected time until BAC reaches 0.0, with secondary milestones
/// for the EU (0.02) and US (0.08) drive limits when currently above them.
/// Uses the standard ~0.015 BAC%/hr metabolism rate. Displayed below the
/// BAC scale so it reads as a natural extension of "where you are now".
private struct TimeToSoberRow: View {
    let hoursUntilSober: Double
    let hoursUntilEULimit: Double
    let hoursUntilUSLimit: Double
    let accent: Color

    private var soberETA: Date {
        Date().addingTimeInterval(hoursUntilSober * 3600)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("TIME TO SOBER")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(Color.bronze)
                Spacer()
                if hoursUntilSober > 0 {
                    Text("≈ \(soberETA, formatter: Self.clock)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(Color.cream.opacity(0.5))
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(formatDuration(hoursUntilSober))
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .italic()
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.cream, accent.opacity(0.85)],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .monospacedDigit()
                    .contentTransition(.numericText(value: hoursUntilSober))
                if hoursUntilSober > 0 {
                    Text("until 0.000")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(Color.bronze)
                }
            }

            if hoursUntilEULimit > 0 || hoursUntilUSLimit > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    if hoursUntilEULimit > 0 {
                        milestoneRow(
                            label: "EU LIMIT (0.02)",
                            hours: hoursUntilEULimit,
                            tint: accent.opacity(0.9)
                        )
                    }
                    if hoursUntilUSLimit > 0 {
                        milestoneRow(
                            label: "US LIMIT (0.08)",
                            hours: hoursUntilUSLimit,
                            tint: accent.opacity(0.7)
                        )
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.cream.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(accent.opacity(0.18), lineWidth: 1)
        )
    }

    private func milestoneRow(label: String, hours: Double, tint: Color) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)
                .shadow(color: tint.opacity(0.6), radius: 3)
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(Color.cream.opacity(0.55))
            Spacer(minLength: 8)
            Text(formatDuration(hours))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(tint)
                .monospacedDigit()
        }
    }

    /// Compact duration formatter:
    /// 0 → "Sober", 0.4 → "24 min", 1.5 → "1h 30m", 12.25 → "12h 15m"
    private func formatDuration(_ hours: Double) -> String {
        guard hours > 0 else { return "Sober" }
        let totalMinutes = Int((hours * 60).rounded())
        if totalMinutes < 60 {
            return "\(totalMinutes) min"
        }
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}

private struct StatusPill: View {
    let status: Status
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status.color)
                .frame(width: 6, height: 6)
                .shadow(color: status.color.opacity(0.9), radius: 5)
            Text(status.label.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(Color.cream)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.cream.opacity(0.06)))
        .overlay(Capsule().strokeBorder(status.color.opacity(0.45), lineWidth: 1))
    }
}

private struct BACScale: View {
    let bac: Double
    let status: Status
    private let maxDisplay: Double = 0.20

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let pct = min(bac / maxDisplay, 1.0)
            let p02 = 0.02 / maxDisplay
            let p08 = 0.08 / maxDisplay
            let trackY: CGFloat = 6

            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(Color.cream.opacity(0.08))
                    .frame(width: w, height: 3)
                    .position(x: w / 2, y: trackY)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Status.sober.color,
                                Status.buzzed.color,
                                Status.impaired.color,
                                Status.drunk.color,
                                Status.danger.color
                            ],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: max(4, CGFloat(pct) * w), height: 3)
                    .position(x: max(2, CGFloat(pct) * w / 2), y: trackY)
                    .shadow(color: status.color.opacity(0.6), radius: 6)

                LimitTick(x: CGFloat(p02) * w, label: "0.02", sub: "EU LIMIT")
                LimitTick(x: CGFloat(p08) * w, label: "0.08", sub: "US LIMIT")

                Circle()
                    .fill(Color.cream)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(status.color, lineWidth: 2))
                    .shadow(color: status.color.opacity(0.8), radius: 8)
                    .position(x: CGFloat(pct) * w, y: trackY)
            }
        }
        .frame(height: 38)
    }
}

private struct LimitTick: View {
    let x: CGFloat
    let label: String
    let sub: String

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.cream.opacity(0.55))
                .frame(width: 1, height: 11)
                .position(x: x, y: 6)

            VStack(spacing: 1) {
                Text(label)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.cream.opacity(0.8))
                Text(sub)
                    .font(.system(size: 7, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Color.bronze)
            }
            .fixedSize()
            .position(x: x, y: 24)
        }
    }
}

// MARK: - Vibe card

private struct VibeCard: View {
    let status: Status
    let message: VibeMessage

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Rectangle()
                .fill(status.color)
                .frame(width: 3)
                .shadow(color: status.color.opacity(0.8), radius: 8)

            VStack(alignment: .leading, spacing: 12) {
                Text("TONIGHT'S VIBE")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(Color.bronze)

                Text(message.headline)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .italic()
                    .foregroundStyle(Color.cream)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "drop.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(status.color)
                            .frame(width: 14)
                        Text(message.advice)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.cream.opacity(0.82))
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "car.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.whiskey)
                            .frame(width: 14)
                        Text("Never drink and drive. Call a cab.")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .tracking(1.1)
                            .foregroundStyle(Color.whiskey)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.cream.opacity(0.028))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [status.color.opacity(0.35), Color.cream.opacity(0.04)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
    }
}

// MARK: - Drink glyph

private struct DrinkGlyph: View {
    let option: DrinkOption
    let size: CGFloat

    var body: some View {
        Group {
            if case .guinness = option.customGlyph {
                GuinnessIcon(size: size)
            } else {
                categoryGlyph(option.category, size: size)
            }
        }
        .frame(width: size, height: size)
    }
}

private struct GuinnessIcon: View {
    let size: CGFloat

    var body: some View {
        let glassW = size * 0.62
        let glassH = size * 0.90
        let headH  = glassH * 0.24
        let radius = size * 0.08

        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.09, green: 0.05, blue: 0.02),
                            Color.stout
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(width: glassW, height: glassH)

            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.foam)
                    .frame(width: glassW, height: headH)
                Spacer(minLength: 0)
            }
            .frame(width: glassW, height: glassH)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))

            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.cream.opacity(0.25), lineWidth: 0.5)
                .frame(width: glassW, height: glassH)
        }
        .frame(width: size, height: size)
    }
}

/// Hand-drawn gin & tonic: tall clear highball with a pale tonic tint,
/// two ice cubes, and a cucumber wheel garnish poking over the rim. Built
/// out of SwiftUI shapes so it stays crisp at any size and reads well
/// even at the small chip/tile sizes used in category pickers.
private struct GinTonicIcon: View {
    let size: CGFloat

    var body: some View {
        let glassW = size * 0.58
        let glassH = size * 0.86
        let glassRadius = size * 0.06
        let liquidInset = size * 0.04
        let liquidH = glassH * 0.66

        // Cucumber slice geometry — sits on the rim, half inside the glass.
        let cucumberSize = size * 0.30
        let cucumberOffsetX = size * 0.16
        let cucumberOffsetY = -glassH * 0.42

        ZStack {
            // 1) Tonic liquid inside the glass — pale icy blue gradient.
            //    Sits in the lower portion of the glass so the rim shows
            //    above it. Slightly inset from the glass walls so the
            //    glass outline is visible around the liquid.
            RoundedRectangle(cornerRadius: glassRadius * 0.7, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.74, green: 0.92, blue: 1.00).opacity(0.55),
                            Color(red: 0.46, green: 0.78, blue: 0.98).opacity(0.62)
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(width: glassW - liquidInset * 2, height: liquidH)
                .offset(y: (glassH - liquidH) / 2 - liquidInset)

            // 2) Ice cubes — two translucent rounded squares floating in
            //    the liquid, rotated for a casual "just dropped in" feel.
            iceCube(size: size * 0.20, opacity: 0.85)
                .rotationEffect(.degrees(14))
                .offset(x: -size * 0.09, y: size * 0.04)

            iceCube(size: size * 0.16, opacity: 0.65)
                .rotationEffect(.degrees(-22))
                .offset(x: size * 0.07, y: size * 0.18)

            // 3) Glass outline — drawn LAST so it sits on top of liquid
            //    and ice, giving the "looking through glass" effect at
            //    the edges. Stroke only — no fill, so it stays clear.
            RoundedRectangle(cornerRadius: glassRadius, style: .continuous)
                .strokeBorder(Color.cream.opacity(0.92), lineWidth: max(0.8, size * 0.035))
                .frame(width: glassW, height: glassH)

            // 4) Subtle highlight stripe down the left side of the glass
            //    — sells the "this is glass" read at small sizes.
            RoundedRectangle(cornerRadius: glassRadius * 0.5, style: .continuous)
                .fill(Color.cream.opacity(0.22))
                .frame(width: max(0.6, size * 0.025), height: glassH * 0.55)
                .offset(x: -glassW * 0.36, y: -glassH * 0.08)

            // 5) Cucumber wheel — green disc with a paler inner core
            //    (the pith) and a hint of darker rind.
            CucumberWheel()
                .frame(width: cucumberSize, height: cucumberSize)
                .offset(x: cucumberOffsetX, y: cucumberOffsetY)
                .rotationEffect(.degrees(-12), anchor: .center)
        }
        .frame(width: size, height: size)
    }

    private func iceCube(size: CGFloat, opacity: Double) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                .fill(Color.cream.opacity(opacity))
            RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                .strokeBorder(Color.cream.opacity(opacity * 0.6), lineWidth: 0.6)
            // Inner reflective glint
            RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)
                .fill(Color.white.opacity(0.5))
                .frame(width: size * 0.32, height: size * 0.32)
                .offset(x: -size * 0.18, y: -size * 0.18)
        }
        .frame(width: size, height: size)
    }
}

/// Stylised top-down cucumber slice for the gin garnish. Three concentric
/// circles: dark green rind, light green flesh, pale green seed core,
/// with a few tiny dots to suggest seeds.
private struct CucumberWheel: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                // Outer rind — darker green ring
                Circle()
                    .fill(Color(red: 0.30, green: 0.55, blue: 0.28))
                // Flesh — lighter green
                Circle()
                    .fill(Color(red: 0.74, green: 0.88, blue: 0.62))
                    .frame(width: s * 0.78, height: s * 0.78)
                // Pale core
                Circle()
                    .fill(Color(red: 0.92, green: 0.97, blue: 0.84))
                    .frame(width: s * 0.42, height: s * 0.42)
                // Seeds — three small dark dots in a triangle
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color(red: 0.45, green: 0.62, blue: 0.32).opacity(0.7))
                        .frame(width: s * 0.07, height: s * 0.07)
                        .offset(
                            x: cos(Double(i) * 2.094 - .pi / 2) * Double(s) * 0.13,
                            y: sin(Double(i) * 2.094 - .pi / 2) * Double(s) * 0.13
                        )
                }
            }
        }
    }
}

/// Renders a category's glyph at the requested outer size. Categories
/// with hand-drawn icons (currently: gin) get the custom view; the rest
/// fall back to the standard emoji at 0.62× of the outer size — matching
/// the convention `DrinkGlyph` uses for its emoji fallback.
@ViewBuilder
func categoryGlyph(_ category: DrinkCategory, size: CGFloat) -> some View {
    switch category {
    case .gin:
        GinTonicIcon(size: size)
    default:
        Text(category.emoji)
            .font(.system(size: size * 0.62))
            .frame(width: size, height: size)
    }
}

// MARK: - Order card

private struct OrderCard: View {
    let order: [OrderItem]
    var memberCount: Int = 1
    var groupActive: Bool = false
    let onOpen: () -> Void
    let onOpenShared: (() -> Void)?
    let onRemoveOne: (DrinkOption, Bool) -> Void
    let onAddOne: (DrinkOption, Bool) -> Void

    private var groups: [OrderGroup] { aggregateOrder(order) }
    private var personalCount: Int { order.filter { !$0.shared }.count }
    private var sharedCount: Int { order.filter { $0.shared }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 10) {
                    Text("01")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(Color.bronze)
                    Text(groupActive ? "YOUR TAB" : "DRINKS")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(2.4)
                        .foregroundStyle(Color.cream.opacity(0.78))
                }
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(order.count)")
                        .font(.system(size: 38, weight: .heavy, design: .rounded))
                        .italic()
                        .foregroundStyle(Color.cream)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(order.count)))
                    Text(order.count == 1 ? "drink" : "drinks")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .tracking(1.6)
                        .foregroundStyle(Color.bronze)
                }
            }

            if groupActive && sharedCount > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.whiskey)
                    Text("\(personalCount) yours · \(sharedCount) shared ÷\(max(memberCount, 1))")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(Color.cream.opacity(0.65))
                }
                .padding(.top, -4)
            }

            if order.isEmpty {
                Button(action: onOpen) {
                    HStack(spacing: 12) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.ink)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.whiskey))
                            .shadow(color: Color.whiskey.opacity(0.6), radius: 10)
                        Text("ORDER YOUR FIRST DRINK")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .tracking(2.2)
                            .foregroundStyle(Color.cream)
                        Spacer()
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.whiskey.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                Color.whiskey.opacity(0.28),
                                style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                            )
                    )
                }
                .buttonStyle(PressScaleStyle())
            } else {
                VStack(spacing: 6) {
                    ForEach(groups) { group in
                        DrinkLine(
                            group: group,
                            memberCount: memberCount,
                            onRemoveOne: { onRemoveOne(group.option, group.shared) },
                            onAddOne: { onAddOne(group.option, group.shared) }
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }

                HStack(spacing: 8) {
                    Button(action: onOpen) {
                        HStack(spacing: 10) {
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Color.ink)
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(Color.whiskey))
                            Text(groupActive ? "FOR ME" : "ADD ANOTHER DRINK")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .tracking(1.8)
                                .foregroundStyle(Color.cream)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.whiskey.opacity(0.12))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.whiskey.opacity(0.45), lineWidth: 1)
                        )
                    }
                    .buttonStyle(PressScaleStyle())

                    if groupActive, let onOpenShared {
                        Button(action: onOpenShared) {
                            HStack(spacing: 8) {
                                Image(systemName: "person.2.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Color.ink)
                                    .frame(width: 28, height: 28)
                                    .background(Circle().fill(Color.whiskey))
                                Text("FOR GROUP")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .tracking(1.8)
                                    .foregroundStyle(Color.whiskey)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 10)
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.whiskey.opacity(0.04))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(
                                        Color.whiskey.opacity(0.4),
                                        style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                                    )
                            )
                        }
                        .buttonStyle(PressScaleStyle())
                    }
                }
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.cream.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.cream.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct DrinkChip: View {
    let group: OrderGroup
    let onRemoveOne: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                DrinkGlyph(option: group.option, size: 22)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.smoke))
                    .overlay(Circle().strokeBorder(Color.whiskey.opacity(0.22), lineWidth: 1))

                if group.count > 1 {
                    Text("\(group.count)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.ink)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.whiskey))
                        .overlay(Circle().strokeBorder(Color.ink, lineWidth: 1.5))
                        .offset(x: 4, y: -4)
                        .contentTransition(.numericText(value: Double(group.count)))
                }
            }

            Text(group.option.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.cream)
                .lineLimit(1)

            Button(action: onRemoveOne) {
                Image(systemName: "minus")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.bronze)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.cream.opacity(0.07)))
            }
            .buttonStyle(PressScaleStyle())
        }
        .padding(.leading, 6)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.cream.opacity(0.04)))
        .overlay(Capsule().strokeBorder(Color.cream.opacity(0.08), lineWidth: 1))
    }
}

private struct DrinkLine: View {
    let group: OrderGroup
    var memberCount: Int = 1
    let onRemoveOne: () -> Void
    let onAddOne: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(group.option.name)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .lineLimit(1)
                if group.shared {
                    HStack(spacing: 4) {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 8, weight: .bold))
                        Text("SHARED ÷\(max(memberCount, 1))")
                            .font(.system(size: 9, weight: .black, design: .monospaced))
                            .tracking(1.4)
                    }
                    .foregroundStyle(Color.whiskey)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.whiskey.opacity(0.12)))
                    .overlay(Capsule().strokeBorder(Color.whiskey.opacity(0.45), lineWidth: 0.75))
                }
            }

            Spacer()

            HStack(spacing: 0) {
                Button(action: onRemoveOne) {
                    Image(systemName: "minus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.cream)
                        .frame(width: 32, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle())

                Text("\(group.count)")
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .monospacedDigit()
                    .frame(minWidth: 22)
                    .contentTransition(.numericText(value: Double(group.count)))

                Button(action: onAddOne) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.ink)
                        .frame(width: 32, height: 28)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.whiskey)
                                .padding(.vertical, 2)
                                .padding(.horizontal, 2)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle())
            }
            .background(Capsule(style: .continuous).fill(Color.cream.opacity(0.06)))
            .overlay(Capsule(style: .continuous).strokeBorder(Color.whiskey.opacity(0.4), lineWidth: 1))
        }
        .padding(.vertical, 4)
    }
}

// MARK: - You row

private struct YouRow: View {
    let profile: Profile
    let onEdit: () -> Void

    var body: some View {
        Button(action: onEdit) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 10) {
                    Text("03")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(Color.bronze)
                    Text("YOU")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(2.4)
                        .foregroundStyle(Color.cream.opacity(0.78))
                }
                Spacer()
                HStack(spacing: 10) {
                    stat(profile.sex.short, unit: profile.sex.label.lowercased())
                    divider
                    stat("\(Int(profile.weightKg))", unit: "kg")
                    divider
                    stat("\(profile.age)", unit: "yo")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.bronze)
                        .padding(.leading, 4)
                }
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 18)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.cream.opacity(0.025))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.cream.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(PressScaleStyle())
    }

    private func stat(_ value: String, unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .italic()
                .foregroundStyle(Color.cream)
                .monospacedDigit()
            Text(unit)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(Color.bronze)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.cream.opacity(0.1))
            .frame(width: 1, height: 14)
    }
}

// MARK: - Profile sheet

private struct ProfileSheet: View {
    let profile: Profile
    @ObservedObject var auth: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var age: Double
    @State private var sex: Sex
    @State private var weightKg: Double

    @State private var newAvatarData: Data?
    @State private var avatarRemoved = false

    @State private var saving = false
    @State private var errorMessage: String?

    init(profile: Profile, auth: AuthService) {
        self.profile = profile
        self.auth = auth
        _name = State(initialValue: profile.name)
        _age = State(initialValue: Double(profile.age))
        _sex = State(initialValue: profile.sex)
        _weightKg = State(initialValue: profile.weightKg)
    }

    private var dirty: Bool {
        name != profile.name
            || Int(age) != profile.age
            || sex != profile.sex
            || weightKg != profile.weightKg
            || newAvatarData != nil
            || avatarRemoved
    }

    var body: some View {
        ZStack {
            AtmosphereBackground(accent: .whiskey)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PROFILE")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(2.4)
                            .foregroundStyle(Color.bronze)
                        Text(profile.name)
                            .font(.system(size: 42, weight: .heavy, design: .rounded))
                            .italic()
                            .tracking(-1.8)
                            .foregroundStyle(Color.cream)
                    }

                    HStack(spacing: 16) {
                        AvatarPicker(
                            existingURL: avatarRemoved ? nil : profile.avatarURL,
                            initial: String(name.prefix(1)).uppercased(),
                            size: 84,
                            imageData: $newAvatarData,
                            onRemove: {
                                avatarRemoved = true
                                newAvatarData = nil
                            }
                        )
                        VStack(alignment: .leading, spacing: 4) {
                            Text("PHOTO")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .tracking(2)
                                .foregroundStyle(Color.bronze)
                            Text("Tap the circle to add or change. Optional.")
                                .font(.system(size: 12, weight: .regular, design: .rounded))
                                .foregroundStyle(Color.cream.opacity(0.65))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }

                    VStack(spacing: 10) {
                        LoungeField(label: "NAME", text: $name, placeholder: "Your name")
                        LoungeNumberField(label: "AGE", value: $age, range: 18...100, step: 1, unit: "years")
                        LoungePickerField(label: "SEX") {
                            SexToggle(sex: $sex, accent: .whiskey)
                        }
                        LoungeNumberField(label: "WEIGHT", value: $weightKg, range: 40...160, step: 1, unit: "kg")
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(Status.drunk.color)
                    }

                    Button {
                        Task {
                            saving = true
                            errorMessage = nil
                            do {
                                let updated = Profile(
                                    id: profile.id,
                                    name: name.trimmingCharacters(in: .whitespaces),
                                    age: Int(age),
                                    sex: sex,
                                    weightKg: weightKg,
                                    avatarURL: profile.avatarURL
                                )
                                try await auth.updateProfile(
                                    updated,
                                    newAvatarData: newAvatarData,
                                    removeAvatar: avatarRemoved
                                )
                                dismiss()
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                            saving = false
                        }
                    } label: {
                        HStack {
                            Text(saving ? "SAVING…" : "SAVE CHANGES")
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .tracking(3)
                            Spacer()
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .foregroundStyle(Color.ink)
                        .padding(.vertical, 16)
                        .padding(.horizontal, 20)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(dirty ? Color.cream : Color.cream.opacity(0.35))
                        )
                        .shadow(color: Color.whiskey.opacity(dirty ? 0.5 : 0), radius: 20, y: 10)
                    }
                    .disabled(!dirty || saving)
                    .buttonStyle(PressScaleStyle())

                    Button {
                        Task {
                            try? await auth.signOut()
                            dismiss()
                        }
                    } label: {
                        HStack {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .font(.system(size: 12, weight: .bold))
                            Text("SIGN OUT")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .tracking(2.4)
                            Spacer()
                        }
                        .foregroundStyle(Status.drunk.color)
                        .padding(.vertical, 14)
                        .padding(.horizontal, 18)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Status.drunk.color.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Status.drunk.color.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(PressScaleStyle())

                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 40)
            }
        }
    }
}

// MARK: - Menu sheet (compact)

private struct MenuSheet: View {
    @Binding var order: [OrderItem]
    @Binding var shareMode: Bool
    var showShareToggle: Bool = false
    /// Drinks pinned to the top of the menu — these are the "Specials at
    /// <Venue>" rows that only show when the user is checked into a bar.
    /// Empty when no venue is selected.
    var venueSpecials: [DrinkOption] = []
    /// Display name shown in the specials section header.
    var venueName: String? = nil
    var onAdd: (DrinkOption) -> Void
    var onRemove: (DrinkOption) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var category: DrinkCategory = .beer
    @State private var addedTick: Int = 0

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    private var groups: [OrderGroup] { aggregateOrder(order) }

    private var specialsHeader: String {
        if let n = venueName, !n.isEmpty { return "Specials at \(n)" }
        return "Specials"
    }

    private func count(for option: DrinkOption) -> Int {
        order.reduce(0) { $0 + ($1.option == option ? 1 : 0) }
    }

    var body: some View {
        ZStack {
            AtmosphereBackground(accent: .whiskey)

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("MENU")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(2.4)
                            .foregroundStyle(Color.bronze)
                        Text("Order")
                            .font(.system(size: 38, weight: .heavy, design: .rounded))
                            .italic()
                            .tracking(-1.8)
                            .foregroundStyle(Color.cream)
                    }
                    Spacer()
                    if !order.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(order.count)")
                                .font(.system(size: 32, weight: .heavy, design: .rounded))
                                .italic()
                                .foregroundStyle(Color.cream)
                                .monospacedDigit()
                                .contentTransition(.numericText(value: Double(order.count)))
                            Text(order.count == 1 ? "on tab" : "on tab")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .tracking(1.6)
                                .foregroundStyle(Color.bronze)
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)

                if showShareToggle {
                    ShareModePicker(shareMode: $shareMode)
                        .padding(.horizontal, 22)
                }

                if !venueSpecials.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9, weight: .black))
                                .foregroundStyle(Color.whiskey)
                            Text(specialsHeader.uppercased())
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .tracking(2.4)
                                .foregroundStyle(Color.whiskey)
                            Rectangle()
                                .fill(Color.whiskey.opacity(0.25))
                                .frame(height: 1)
                        }
                        VStack(spacing: 6) {
                            ForEach(venueSpecials, id: \.name) { option in
                                OptionRow(
                                    option: option,
                                    count: count(for: option),
                                    onAdd: {
                                        withAnimation(.spring(response: 0.4, dampingFraction: 0.72)) {
                                            onAdd(option)
                                            addedTick &+= 1
                                        }
                                    },
                                    onRemove: {
                                        withAnimation(.spring(response: 0.4, dampingFraction: 0.72)) {
                                            onRemove(option)
                                        }
                                    }
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 2)
                }

                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(DrinkCategory.allCases) { cat in
                        CategoryTile(category: cat, selected: category == cat) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                category = cat
                            }
                        }
                    }
                }
                .padding(.horizontal, 22)

                HStack(spacing: 8) {
                    Text(category.label.uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(2.4)
                        .foregroundStyle(Color.cream.opacity(0.7))
                    Rectangle()
                        .fill(Color.cream.opacity(0.12))
                        .frame(height: 1)
                }
                .padding(.horizontal, 22)
                .padding(.top, 4)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 7) {
                        ForEach(DrinkCatalog.options(for: category), id: \.self) { option in
                            OptionRow(
                                option: option,
                                count: count(for: option),
                                onAdd: {
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.72)) {
                                        onAdd(option)
                                        addedTick &+= 1
                                    }
                                },
                                onRemove: {
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.72)) {
                                        onRemove(option)
                                    }
                                }
                            )
                            .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 2)
                    .padding(.bottom, 110)
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: category)
                }

                Spacer(minLength: 0)
            }

            VStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    HStack {
                        Text("DONE")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .tracking(3)
                        Spacer()
                        Text("BACK TO SESH")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(2)
                            .opacity(0.55)
                    }
                    .foregroundStyle(Color.ink)
                    .padding(.vertical, 16)
                    .padding(.horizontal, 20)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.cream)
                    )
                    .shadow(color: Color.whiskey.opacity(0.55), radius: 22, y: 10)
                    .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
                }
                .buttonStyle(PressScaleStyle())
                .padding(.horizontal, 22)
                .padding(.bottom, 22)
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: addedTick)
    }
}

private struct CategoryTile: View {
    let category: DrinkCategory
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                // 24pt emoji equivalence: outer size = 24 / 0.62 ≈ 38.7
                // so the custom icon matches the emoji's optical size.
                categoryGlyph(category, size: 38)
                Text(category.label.uppercased())
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(selected ? Color.cream : Color.bronze)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? Color.cream.opacity(0.08) : Color.cream.opacity(0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        selected ? Color.whiskey.opacity(0.5) : Color.cream.opacity(0.06),
                        lineWidth: 1
                    )
            )
            .shadow(color: selected ? Color.whiskey.opacity(0.35) : .clear, radius: 10, y: 4)
        }
        .buttonStyle(PressScaleStyle())
    }
}

private struct OptionRow: View {
    let option: DrinkOption
    let count: Int
    let onAdd: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            DrinkGlyph(option: option, size: 30)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.smoke))
                .overlay(
                    Circle().strokeBorder(
                        count > 0 ? Color.whiskey.opacity(0.7) : Color.whiskey.opacity(0.22),
                        lineWidth: 1
                    )
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(option.name)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.cream)
                Text(option.detail)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(Color.bronze)
            }

            Spacer()

            if count == 0 {
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.ink)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.whiskey))
                        .shadow(color: Color.whiskey.opacity(0.45), radius: 8)
                }
                .buttonStyle(PressScaleStyle())
                .transition(.scale.combined(with: .opacity))
            } else {
                HStack(spacing: 0) {
                    Button(action: onRemove) {
                        Image(systemName: "minus")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.cream)
                            .frame(width: 34, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScaleStyle())

                    Text("\(count)")
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .italic()
                        .foregroundStyle(Color.cream)
                        .monospacedDigit()
                        .frame(minWidth: 22)
                        .contentTransition(.numericText(value: Double(count)))

                    Button(action: onAdd) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.ink)
                            .frame(width: 34, height: 30)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.whiskey)
                                    .padding(.vertical, 2)
                                    .padding(.horizontal, 2)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScaleStyle())
                }
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.cream.opacity(0.06))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.whiskey.opacity(0.4), lineWidth: 1)
                )
                .shadow(color: Color.whiskey.opacity(0.25), radius: 8)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(count > 0 ? Color.whiskey.opacity(0.05) : Color.cream.opacity(0.028))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    count > 0 ? Color.whiskey.opacity(0.25) : Color.cream.opacity(0.06),
                    lineWidth: 1
                )
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: count)
    }
}

// MARK: - Generic input row

private struct InputRow<Control: View>: View {
    let kicker: String
    let title: String
    let valueText: String
    let unit: String
    let accent: Color
    @ViewBuilder var control: () -> Control

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 10) {
                    Text(kicker)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(Color.bronze)
                    Text(title.uppercased())
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(2.4)
                        .foregroundStyle(Color.cream.opacity(0.78))
                }
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(valueText)
                        .font(.system(size: 26, weight: .heavy, design: .rounded))
                        .italic()
                        .foregroundStyle(Color.cream)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(unit)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .tracking(1.6)
                        .foregroundStyle(Color.bronze)
                }
            }

            control()
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.cream.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.cream.opacity(0.06), lineWidth: 1)
        )
    }
}

// MARK: - Controls

private struct TintedSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let accent: Color

    var body: some View {
        GeometryReader { geo in
            let pct = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let w = geo.size.width
            let knobX = max(10, min(w - 10, CGFloat(pct) * w))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.cream.opacity(0.08))
                    .frame(height: 3)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.6), accent],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: knobX, height: 3)
                    .shadow(color: accent.opacity(0.6), radius: 6)

                Circle()
                    .fill(Color.cream)
                    .frame(width: 18, height: 18)
                    .overlay(Circle().stroke(accent, lineWidth: 2))
                    .shadow(color: accent.opacity(0.7), radius: 10)
                    .position(x: knobX, y: geo.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let raw = Double(max(0, min(w, g.location.x)) / max(w, 1))
                        let v = range.lowerBound + raw * (range.upperBound - range.lowerBound)
                        let snapped = (v / step).rounded() * step
                        value = min(range.upperBound, max(range.lowerBound, snapped))
                    }
            )
        }
        .frame(height: 24)
    }
}

private struct SexToggle: View {
    @Binding var sex: Sex
    let accent: Color

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Sex.allCases) { option in
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                        sex = option
                    }
                } label: {
                    Text(option.label.uppercased())
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(2.2)
                        .foregroundStyle(sex == option ? Color.ink : Color.cream.opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            ZStack {
                                if sex == option {
                                    Capsule().fill(Color.cream)
                                        .shadow(color: accent.opacity(0.5), radius: 12)
                                } else {
                                    Capsule().fill(Color.cream.opacity(0.04))
                                }
                            }
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                Color.cream.opacity(sex == option ? 0 : 0.08),
                                lineWidth: 1
                            )
                        )
                }
                .buttonStyle(PressScaleStyle())
            }
        }
    }
}

private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Disclaimer

private struct Disclaimer: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(Color.whiskey.opacity(0.6))
                .frame(width: 2)
                .frame(maxHeight: .infinity)

            Text("Widmark estimate based on drink volume, ABV, body weight and time. Legal limits vary: 0.02 in much of the EU, 0.08 in the US & UK. Not a legal or medical reference. Never use to decide whether to drive.")
                .font(.system(size: 11, weight: .regular))
                .lineSpacing(4)
                .foregroundStyle(Color.bronze)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 4)
    }
}

// MARK: - Helpers

private func formatHours(_ h: Double) -> String {
    if h.truncatingRemainder(dividingBy: 1) == 0 {
        return String(Int(h))
    }
    if (h * 2).truncatingRemainder(dividingBy: 1) == 0 {
        return String(format: "%.1f", h)
    }
    return String(format: "%.2f", h)
}

// MARK: - Avatar

struct AvatarView: View {
    let urlString: String?
    let initial: String
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.whiskey)
                .shadow(color: Color.whiskey.opacity(0.5), radius: size * 0.22)

            if let urlString, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        initialText
                    }
                }
                .clipShape(Circle())
            } else {
                initialText
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(Color.cream.opacity(0.15), lineWidth: 1))
    }

    private var initialText: some View {
        Text(initial)
            .font(.system(size: size * 0.42, weight: .black, design: .rounded))
            .foregroundStyle(Color.ink)
    }
}

struct AvatarPicker: View {
    let existingURL: String?
    let initial: String
    let size: CGFloat
    @Binding var imageData: Data?
    var onRemove: () -> Void = {}

    @State private var showOptions = false
    @State private var cameraOpen = false
    @State private var pickerVisible = false
    @State private var pickerItem: PhotosPickerItem?

    private var previewImage: UIImage? {
        guard let imageData else { return nil }
        return UIImage(data: imageData)
    }

    var body: some View {
        Button {
            showOptions = true
        } label: {
            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    if let preview = previewImage {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFill()
                            .frame(width: size, height: size)
                            .clipShape(Circle())
                            .overlay(Circle().strokeBorder(Color.cream.opacity(0.2), lineWidth: 1))
                    } else {
                        AvatarView(urlString: existingURL, initial: initial, size: size)
                    }
                }

                Image(systemName: "camera.fill")
                    .font(.system(size: size * 0.18, weight: .bold))
                    .foregroundStyle(Color.ink)
                    .frame(width: size * 0.32, height: size * 0.32)
                    .background(Circle().fill(Color.cream))
                    .overlay(Circle().strokeBorder(Color.ink, lineWidth: 2))
                    .offset(x: 2, y: 2)
            }
        }
        .buttonStyle(PressScaleStyle())
        .confirmationDialog("Profile photo", isPresented: $showOptions, titleVisibility: .hidden) {
            Button("Choose from Library") { pickerVisible = true }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take Photo") { cameraOpen = true }
            }
            if previewImage != nil || existingURL != nil {
                Button("Remove Photo", role: .destructive) {
                    imageData = nil
                    onRemove()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .photosPicker(isPresented: $pickerVisible, selection: $pickerItem, matching: .images)
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let normalized = normalize(data: data) {
                    imageData = normalized
                }
                pickerItem = nil
            }
        }
        .sheet(isPresented: $cameraOpen) {
            CameraPicker { data in
                if let data, let normalized = normalize(data: data) {
                    imageData = normalized
                }
            }
            .ignoresSafeArea()
        }
    }

    private func normalize(data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let maxDim: CGFloat = 768
        let scale = min(maxDim / max(image.size.width, image.size.height), 1)
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return resized.jpegData(compressionQuality: 0.82)
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    var onCapture: (Data?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraDevice = .front
        picker.allowsEditing = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (Data?) -> Void
        init(onCapture: @escaping (Data?) -> Void) { self.onCapture = onCapture }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]
        ) {
            let image = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage)
            picker.dismiss(animated: true) { [onCapture] in
                onCapture(image?.jpegData(compressionQuality: 0.9))
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true) { [onCapture] in
                onCapture(nil)
            }
        }
    }
}

// MARK: - Group Bar

private struct GroupBar: View {
    /// Which mode this bar represents — drives the kicker label so the
    /// user always knows whether the active group they see is their PLAN
    /// or LIVE one (they can be different).
    let scope: SeshMode
    let session: SeshSession?
    let memberCount: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.whiskey.opacity(session == nil ? 0.12 : 0.22))
                        .frame(width: 32, height: 32)
                    Image(systemName: session == nil ? "person.2" : "person.2.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.whiskey)
                }

                if let s = session {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(scope.label) GROUP")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(2.2)
                            .foregroundStyle(Color.whiskey)
                        HStack(spacing: 8) {
                            Text(s.joinCode)
                                .font(.system(size: 15, weight: .black, design: .monospaced))
                                .tracking(2.5)
                                .foregroundStyle(Color.cream)
                            Text("·")
                                .foregroundStyle(Color.bronze)
                            Text("\(memberCount) \(memberCount == 1 ? "person" : "people")")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.cream.opacity(0.72))
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(scope.label) GROUP")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(2.2)
                            .foregroundStyle(Color.bronze)
                        Text("Drink together in \(scope.label.lowercased())")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.cream)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.bronze)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.inkElev.opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        session == nil
                            ? Color.cream.opacity(0.08)
                            : Color.whiskey.opacity(0.35),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: (session == nil ? Color.black : Color.whiskey).opacity(0.18),
                radius: 18, y: 10
            )
        }
        .buttonStyle(PressScaleStyle())
    }
}

// MARK: - Venue Chip / Sheet
//
// The chip is the user's persistent "Tonight at: <bar>" marker — shown
// in the home view header. Tap → VenueSheet → search Apple Maps and
// check in to any bar, or check out. When a venue is selected the chip
// glows whiskey, otherwise it's a discreet "find bars near you" CTA.

private struct VenueChip: View {
    @ObservedObject var location: LocationService
    @ObservedObject var venues: VenueService
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
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.whiskey.opacity(venues.currentVenue == nil ? 0.14 : 0.32))
                        .frame(width: 32, height: 32)
                    Image(systemName: venues.currentVenue == nil
                          ? "mappin.and.ellipse"
                          : "mappin.circle.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.whiskey)
                }

                if let v = venues.currentVenue {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("TONIGHT AT")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .tracking(2.2)
                                .foregroundStyle(Color.whiskey)
                            if v.isFeatured {
                                Text("★")
                                    .font(.system(size: 10, weight: .black))
                                    .foregroundStyle(Color.whiskey)
                            }
                        }
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
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("LOCATION")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(2.2)
                            .foregroundStyle(Color.bronze)
                        Text(prompt)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.cream)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.bronze)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.inkElev.opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        venues.currentVenue == nil
                            ? Color.cream.opacity(0.08)
                            : Color.whiskey.opacity(0.45),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: (venues.currentVenue == nil ? Color.black : Color.whiskey).opacity(0.18),
                radius: 18, y: 10
            )
        }
        .buttonStyle(PressScaleStyle())
    }
}

private struct VenueSheet: View {
    @ObservedObject var location: LocationService
    @ObservedObject var venues: VenueService
    @StateObject private var search = MapKitVenueSearch()
    @State private var query: String = ""
    @State private var checkInInFlight: String? = nil
    @Environment(\.dismiss) private var dismiss

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

    var body: some View {
        ZStack {
            AtmosphereBackground(accent: .whiskey)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("CHECK IN")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(2.4)
                            .foregroundStyle(Color.bronze)
                        Text("Tonight at…")
                            .font(.system(size: 34, weight: .heavy, design: .rounded))
                            .italic()
                            .tracking(-1.4)
                            .foregroundStyle(Color.cream)
                    }

                    permissionStripe

                    if venues.currentVenue != nil {
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                venues.currentVenue = nil
                            }
                            dismiss()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 13, weight: .bold))
                                Text("CHECK OUT")
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

                    if !trimmedQuery.isEmpty {
                        searchSection
                    } else {
                        featuredSection
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
            search.search(query: snapshot, origin: location.location)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .bold))
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
                        .font(.system(size: 14, weight: .bold))
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
                    ) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            venues.currentVenue = venue
                        }
                        dismiss()
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
                caption: search.isSearching ? "Searching…" : "From Apple Maps · no specials"
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
                    MapKitResultRow(
                        result: result,
                        distance: distanceLabel(metres: result.distance),
                        isPending: checkInInFlight == result.id,
                        isCurrent: venues.currentVenue?.externalId == result.id
                    ) {
                        Task { await performCheckIn(result) }
                    }
                }
            }
        }
    }

    @MainActor
    private func performCheckIn(_ result: MapKitVenueResult) async {
        checkInInFlight = result.id
        await venues.checkIn(mapKitResult: result)
        checkInInFlight = nil
        dismiss()
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
                .font(.system(size: 28))
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
                        .font(.system(size: 18, weight: .bold))
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
                        .font(.system(size: 18, weight: .bold))
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
/// on the map." No FEATURED badge, no specials affordance, no star —
/// just name, address, and distance. Tapping triggers a check-in flow
/// that may need a network round-trip, hence the spinner state.
private struct MapKitResultRow: View {
    let result: MapKitVenueResult
    let distance: String?
    let isPending: Bool
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(isCurrent ? Color.whiskey.opacity(0.32) : Color.cream.opacity(0.05))
                        .frame(width: 44, height: 44)
                    if isPending {
                        ProgressView().tint(Color.cream.opacity(0.8))
                    } else {
                        Image(systemName: "mappin")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(isCurrent ? Color.whiskey : Color.cream.opacity(0.6))
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.name)
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.cream)
                        .lineLimit(1)
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
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color.whiskey)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.bronze.opacity(0.55))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isCurrent ? Color.whiskey.opacity(0.10) : Color.cream.opacity(0.025))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        isCurrent ? Color.whiskey.opacity(0.45) : Color.cream.opacity(0.06),
                        lineWidth: 1
                    )
            )
            .opacity(isPending ? 0.7 : 1)
        }
        .buttonStyle(PressScaleStyle())
        .disabled(isPending)
    }
}

// MARK: - Group Roster

private struct GroupRoster: View {
    @ObservedObject var group: SessionService
    let selfId: UUID
    let hours: Double

    private var sortedMembers: [SessionMember] {
        group.members.sorted { a, b in
            if a.profileId == selfId { return true }
            if b.profileId == selfId { return false }
            return a.joinedAt < b.joinedAt
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("THE GROUP")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(3.0)
                    .foregroundStyle(Color.bronze)
                Spacer()
                Text("\(group.members.count) \(group.members.count == 1 ? "person" : "people")")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(Color.cream.opacity(0.55))
            }

            VStack(spacing: 10) {
                ForEach(sortedMembers, id: \.profileId) { member in
                    // Every member — including self — reads from the synced
                    // duration value in the DB. That way both phones render
                    // identical BAC numbers. (The local `hours` slider writes
                    // to this synced field via updateMyDuration.)
                    MemberRow(
                        member: member,
                        profile: group.memberProfiles[member.profileId],
                        personalCount: group.drinks(for: member.profileId).count,
                        sharedCount: group.sharedDrinks().count,
                        memberCount: max(group.members.count, 1),
                        effectiveGrams: group.effectiveGrams(for: member.profileId),
                        hoursElapsed: group.duration(for: member.profileId),
                        isSelf: member.profileId == selfId,
                        isHost: group.session?.hostId == member.profileId
                    )
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.inkElev.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.cream.opacity(0.07), lineWidth: 1)
        )
    }
}

private struct MemberRow: View {
    let member: SessionMember
    let profile: Profile?
    let personalCount: Int
    let sharedCount: Int
    let memberCount: Int
    let effectiveGrams: Double
    let hoursElapsed: Double
    let isSelf: Bool
    let isHost: Bool

    private var bac: Double {
        guard let profile else { return 0 }
        return SessionService.bac(grams: effectiveGrams, profile: profile, hoursElapsed: hoursElapsed)
    }

    private var status: Status {
        switch bac {
        case ..<0.02: return .sober
        case 0.02..<0.05: return .buzzed
        case 0.05..<0.08: return .impaired
        case 0.08..<0.15: return .drunk
        default: return .danger
        }
    }

    private var name: String {
        profile?.name ?? "Guest"
    }

    private var initial: String {
        String(name.prefix(1)).uppercased()
    }

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(urlString: profile?.avatarURL, initial: initial, size: 36)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.cream)
                        .lineLimit(1)
                    if isSelf {
                        Text("YOU")
                            .font(.system(size: 9, weight: .black, design: .monospaced))
                            .tracking(1.5)
                            .foregroundStyle(Color.ink)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.whiskey))
                    } else if isHost {
                        Text("HOST")
                            .font(.system(size: 9, weight: .black, design: .monospaced))
                            .tracking(1.5)
                            .foregroundStyle(Color.whiskey)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .overlay(Capsule().strokeBorder(Color.whiskey.opacity(0.6), lineWidth: 1))
                    }
                }

                // BAC bar is privacy-sensitive in plan mode — only the
                // user sees their own. For other members we render a
                // subtle "they're in the sesh" line instead, so the row
                // still feels populated without leaking their numbers.
                if isSelf {
                    GeometryReader { geo in
                        let fraction = min(max(bac / 0.20, 0), 1)
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.cream.opacity(0.08))
                            Capsule()
                                .fill(status.color)
                                .frame(width: geo.size.width * CGFloat(fraction))
                                .shadow(color: status.color.opacity(0.5), radius: 4)
                        }
                    }
                    .frame(height: 5)
                } else {
                    Text("In the sesh")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.45))
                }
            }

            Spacer(minLength: 8)

            // Trailing column: numeric BAC + drink count. Self only —
            // a teammate's BAC and drink count are personal data and
            // shouldn't leak into the host's roster view.
            if isSelf {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.3f", bac))
                        .font(.system(size: 16, weight: .black, design: .rounded))
                        .foregroundStyle(Color.cream)
                        .contentTransition(.numericText(value: bac))
                    HStack(spacing: 4) {
                        Text("\(personalCount) \(personalCount == 1 ? "drink" : "drinks")")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(1.4)
                            .foregroundStyle(status.color)
                        if sharedCount > 0 {
                            Text("· +\(sharedCount)÷\(max(memberCount, 1))")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .tracking(1.0)
                                .foregroundStyle(Color.whiskey.opacity(0.85))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Group Sheet

private struct GroupSheet: View {
    @ObservedObject var group: SessionService
    /// The OTHER mode's store. Used to surface a "Continue with [other]
    /// group · CODE" affordance when this scope is idle but the cousin
    /// has an active group — one tap mirrors that group into this scope
    /// without making the user re-type the code.
    @ObservedObject var cousin: SessionService
    /// On-device cache of previously-joined groups. Drives the "RECENT
    /// GROUPS" list shown in the idle view so rejoining is one tap.
    /// Filtered down to "not the cousin's current group" before display
    /// so we don't dangle a saved entry next to a live mirror affordance
    /// for the same code.
    @ObservedObject var savedGroups: SavedGroupsStore
    /// In-app invite sender. Used by `previousCrewCard` so the host can
    /// fire invites at every saved-crew member with one tap, instead of
    /// kicking out to iMessage.
    @ObservedObject var invites: InvitesService
    @Environment(\.dismiss) private var dismiss

    @State private var joinCode: String = ""
    @State private var showCopied = false
    @State private var confirmLeave = false
    @State private var confirmEnd = false
    /// "Sent to N friends" / "Already invited" toast shown after the
    /// in-app invite button fires. Cleared on a short timer so the card
    /// returns to its idle state for re-sends.
    @State private var inviteSendToast: String?
    /// Set when the user taps a saved-group row, which kicks off a
    /// brand-new session and queues up an invite for the previous crew.
    /// Drives the "bring back the crew" share card at the top of the
    /// active view. Cleared when the user dismisses the card or leaves
    /// the group.
    @State private var pendingInvite: PendingCrewInvite?

    /// What we know about a pending invite: just the saved roster. The
    /// new session's join code comes from `group.session?.joinCode` at
    /// render time, so the share message stays in sync if the host
    /// regenerates the code (not currently a flow, but cheap insurance).
    private struct PendingCrewInvite: Equatable {
        let crew: [SavedMember]
        /// The saved entry's id (which == its previous session id).
        /// Only used so the active view can wipe the card if the user
        /// somehow ends up in a different session than the one we
        /// just created (shouldn't happen, but defensive).
        let sourceSavedId: UUID
    }

    /// Returns the cousin's join code only when (a) the cousin is in a
    /// group, and (b) we're not already in the same one. Both conditions
    /// matter — without (b) the mirror button would show even after the
    /// user mirrored, which would be confusing.
    private var mirrorableCode: String? {
        guard let cousinSession = cousin.session else { return nil }
        if group.session?.id == cousinSession.id { return nil }
        return cousinSession.joinCode
    }

    /// True when this scope and the cousin scope are tracking the same
    /// underlying session (mirrored). Used by the host-end flow to swap
    /// the dialog copy for one that promises only a per-mode leave —
    /// otherwise "End for everyone" would be a lie, since the carve-out
    /// in `SessionService.end(cousinSessionId:)` keeps the session alive
    /// for the cousin scope and the rest of the group in this case.
    private var cousinSharesSession: Bool {
        guard let mine = group.session?.id, let theirs = cousin.session?.id else {
            return false
        }
        return mine == theirs
    }

    /// Saved groups, filtered for what's worth showing in this sheet's
    /// idle view. We trim the cousin's current group out of the list so
    /// the mirror affordance (which already covers that exact join with
    /// richer copy) doesn't get a visual duplicate. We also trim
    /// whatever this scope is currently in, just defensively — the idle
    /// view never renders while `group.isActive`, but the guard makes
    /// the intent explicit.
    private var visibleSavedGroups: [SavedGroup] {
        let mineID = group.session?.id
        let cousinID = cousin.session?.id
        return savedGroups.groups.filter { entry in
            entry.id != mineID && entry.id != cousinID
        }
    }

    /// The pill-shaped save/saved toggle shown in the active view. Lets
    /// the user pin the current group to the SAVED GROUPS list (or pop
    /// it back off). Not strictly required to rejoin later — they could
    /// always type the code — but it's the only way to surface a group
    /// in this sheet's idle list.
    /// Build the SavedMember roster from the current SessionService —
    /// used by both `saveToggleButton` and the silent refresh path. We
    /// drop the current user (the share message is from their POV) and
    /// drop members whose profile rows haven't been cached yet (they
    /// fill in on a later poll once the profile lands).
    private func crewSnapshot() -> [SavedMember] {
        let myId = group.myId
        return group.members.compactMap { m in
            guard m.profileId != myId,
                  let prof = group.memberProfiles[m.profileId] else { return nil }
            return SavedMember(id: prof.id, name: prof.name, avatarURL: prof.avatarURL)
        }
    }

    @ViewBuilder
    private func saveToggleButton(session: SeshSession) -> some View {
        let isSaved = savedGroups.isSaved(id: session.id)
        Button {
            if isSaved {
                savedGroups.remove(id: session.id)
            } else {
                let hostName = group.memberProfiles[session.hostId]?.name
                savedGroups.save(
                    session: session,
                    memberCount: group.members.count,
                    hostName: hostName,
                    members: crewSnapshot()
                )
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSaved ? "star.fill" : "star")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(isSaved ? Color.whiskey : Color.cream.opacity(0.85))
                VStack(alignment: .leading, spacing: 2) {
                    Text(isSaved ? "SAVED CREW" : "SAVE THIS CREW")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .tracking(1.8)
                        .foregroundStyle(Color.cream)
                    Text(isSaved
                         ? "Tap to remove from your list"
                         : "Pin the crew so you can re-invite them later")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.65))
                }
                Spacer()
                if isSaved {
                    // A tiny "Saved" pill on the trailing edge so the
                    // active state reads at a glance without leaning on
                    // the icon alone.
                    Text("ON")
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(Color.whiskey)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .overlay(Capsule().strokeBorder(Color.whiskey.opacity(0.55), lineWidth: 1))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSaved
                          ? Color.whiskey.opacity(0.14)
                          : Color.cream.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isSaved ? Color.whiskey.opacity(0.45) : Color.cream.opacity(0.12),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(isSaved ? "Remove from saved groups" : "Save this group")
    }

    @ViewBuilder
    private var savedGroupsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("SAVED CREWS")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(Color.bronze)
                Spacer()
                Text("Tap to start a new sesh")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.45))
            }

            VStack(spacing: 8) {
                ForEach(visibleSavedGroups) { entry in
                    SavedGroupRow(
                        entry: entry,
                        busy: group.busy,
                        onTap: {
                            // Saved groups don't rejoin the *old*
                            // session anymore — that one almost always
                            // ended already, and the user's intent
                            // ("get the crew back together") is better
                            // served by spinning up a fresh session
                            // and surfacing a one-tap share affordance
                            // that names the previous crew. The host
                            // sends the share via iMessage; previous
                            // members tap the code to drop in.
                            Task {
                                await group.create()
                                if group.isActive {
                                    pendingInvite = PendingCrewInvite(
                                        crew: entry.savedMembers,
                                        sourceSavedId: entry.id
                                    )
                                    // We deliberately do NOT dismiss
                                    // the sheet here — the active
                                    // view's "bring back the crew"
                                    // card is the whole point of the
                                    // tap. The user can dismiss the
                                    // sheet themselves once they've
                                    // shared the code (or skipped).
                                }
                                // If create() fails the SessionService
                                // surfaces the error in `group.error`,
                                // which the sheet already renders below.
                            }
                        },
                        onRemove: { savedGroups.remove(id: entry.id) }
                    )
                }
            }
        }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                header

                if group.isActive {
                    activeView
                } else {
                    idleView
                }

                if let err = group.error {
                    Text(err)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(red: 0.85, green: 0.32, blue: 0.23))
                }

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .preferredColorScheme(.dark)
        // Clear the pending-invite card when the user leaves the
        // group, so a future create()-or-join doesn't inherit a stale
        // "bring back the crew" prompt. We deliberately don't clear
        // on every session-id change — the saved-group tap path goes
        // nil → newId and we want the card to survive that exact
        // transition (the assignment that *sets* pendingInvite happens
        // immediately after `create()` resolves, but the onChange
        // observer would race that assignment if we cleared on every
        // flip).
        .onChange(of: group.session?.id) { _, newValue in
            if newValue == nil { pendingInvite = nil }
        }
    }

    private var header: some View {
        HStack {
            // Always name the scope so the user can tell at a glance
            // which mode's group they're managing. Important now that
            // PLAN and LIVE can hold different groups.
            Text(group.isActive
                 ? "YOUR \(group.scope.label) GROUP"
                 : "\(group.scope.label) GROUP")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(3.0)
                .foregroundStyle(Color.bronze)
            Spacer()
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var idleView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Drink together")
                .font(.system(size: 28, weight: .black, design: .rounded))
                .foregroundStyle(Color.cream)
                .tracking(-0.6)
            Text("\(group.scope == .plan ? "Plan" : "Live") groups are independent — start a sesh here, share the code, and see everyone's BAC in real time. The other mode keeps its own group.")
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.7))
                .lineSpacing(3)
        }

        // Mirror affordance: if the OTHER mode already has a group, the
        // shortest path to "be in the same one here" is one tap. We
        // pre-fill the code instead of auto-joining so the user has a
        // moment to reconsider — joining is irreversible from inside
        // this sheet (you'd have to leave again).
        if let code = mirrorableCode {
            Button {
                Task {
                    await group.join(code: code)
                    if group.isActive { dismiss() }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 14, weight: .bold))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CONTINUE WITH \(group.scope.other.label) GROUP")
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .tracking(1.6)
                        Text("Code \(code) · join in \(group.scope.label.lowercased()) too")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.7))
                    }
                    Spacer()
                    if group.busy {
                        ProgressView().tint(Color.cream)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.bronze)
                    }
                }
                .foregroundStyle(Color.cream)
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.whiskey.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.whiskey.opacity(0.45), lineWidth: 1)
                )
            }
            .buttonStyle(PressScaleStyle())
            .disabled(group.busy)
        }

        Button {
            Task {
                await group.create()
                if group.isActive { dismiss() }
            }
        } label: {
            HStack {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16, weight: .bold))
                Text("START NEW GROUP SESH")
                    .font(.system(size: 13, weight: .black, design: .monospaced))
                    .tracking(1.8)
                Spacer()
                if group.busy {
                    ProgressView().tint(Color.ink)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                }
            }
            .foregroundStyle(Color.ink)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.whiskey)
            )
            .shadow(color: Color.whiskey.opacity(0.5), radius: 18, y: 8)
        }
        .buttonStyle(PressScaleStyle())
        .disabled(group.busy)

        // Saved groups — one-tap rejoin for anything the user has
        // explicitly starred via the active-view save toggle. We hide
        // the cousin's current group from the list so it doesn't
        // overlap with the mirror affordance above (which already
        // offers that exact join with richer copy). When the user
        // hasn't saved anything yet we just skip the section entirely
        // rather than render an empty-state — the join-code field
        // below is the natural fallback.
        if !visibleSavedGroups.isEmpty {
            savedGroupsSection
        }

        VStack(alignment: .leading, spacing: 10) {
            Text("OR JOIN WITH A CODE")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(2.4)
                .foregroundStyle(Color.bronze)

            HStack(spacing: 10) {
                TextField("", text: $joinCode, prompt: Text("ABCDEF").foregroundColor(Color.cream.opacity(0.3)))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.system(size: 20, weight: .black, design: .monospaced))
                    .tracking(4)
                    .foregroundStyle(Color.cream)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.inkElev)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.cream.opacity(0.1), lineWidth: 1)
                    )
                    .onChange(of: joinCode) { _, newValue in
                        let cleaned = newValue.uppercased().filter { $0.isLetter || $0.isNumber }
                        if cleaned != newValue { joinCode = String(cleaned.prefix(6)) }
                        else if newValue.count > 6 { joinCode = String(newValue.prefix(6)) }
                    }

                Button {
                    Task {
                        await group.join(code: joinCode)
                        if group.isActive { dismiss() }
                    }
                } label: {
                    Group {
                        if group.busy {
                            ProgressView().tint(Color.ink)
                        } else {
                            Text("JOIN")
                                .font(.system(size: 12, weight: .black, design: .monospaced))
                                .tracking(1.8)
                        }
                    }
                    .foregroundStyle(Color.ink)
                    .frame(width: 72, height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(joinCode.count == 6 ? Color.whiskey : Color.whiskey.opacity(0.3))
                    )
                }
                .buttonStyle(PressScaleStyle())
                .disabled(joinCode.count != 6 || group.busy)
            }
        }
    }

    /// Build the "round 2" share message: warm, name-checks the
    /// previous crew, includes the new join code. Falls back to a plain
    /// invite if the saved roster was empty (older saves without a
    /// snapshot, or solo-saved groups).
    private func crewInviteMessage(crew: [SavedMember], code: String) -> String {
        let names = crew.map { $0.name }.filter { !$0.isEmpty }
        guard !names.isEmpty else {
            return "Round 2! Drop in with code \(code)."
        }
        let listed: String
        switch names.count {
        case 1: listed = names[0]
        case 2: listed = "\(names[0]) & \(names[1])"
        default:
            let head = names.dropLast().joined(separator: ", ")
            listed = "\(head) & \(names.last!)"
        }
        return "Hey \(listed) — round 2! Drop in with code \(code)."
    }

    /// One-tap "bring back the crew" affordance shown at the top of the
    /// active view immediately after the user taps a saved-group row.
    /// The saved roster powers both the avatar list (so the crew is
    /// recognizable at a glance) and the share message body. Dismissing
    /// the card is non-destructive — it just hides the affordance for
    /// this session; the user can still use the regular SHARE button
    /// below to send the bare code.
    @ViewBuilder
    private func previousCrewCard(session: SeshSession, invite: PendingCrewInvite) -> some View {
        let message = crewInviteMessage(crew: invite.crew, code: session.joinCode)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("BRING BACK THE CREW")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(Color.whiskey)
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        pendingInvite = nil
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.cream.opacity(0.55))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.cream.opacity(0.06)))
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("Dismiss invite reminder")
            }

            Text("New session is up. Send your last crew the code and they'll be in.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.78))
                .lineSpacing(2)

            // Crew strip — overlapping avatars on the leading edge,
            // up to four names on the trailing side. Anything past
            // four collapses into a "+N" pill so the row never wraps.
            if !invite.crew.isEmpty {
                HStack(spacing: 10) {
                    HStack(spacing: -8) {
                        ForEach(invite.crew.prefix(5)) { m in
                            AvatarView(
                                urlString: m.avatarURL,
                                initial: String(m.name.prefix(1)).uppercased(),
                                size: 28
                            )
                            .overlay(
                                Circle().strokeBorder(Color.inkElev, lineWidth: 2)
                            )
                        }
                    }
                    let displayed = Array(invite.crew.prefix(3).map { $0.name })
                    let remaining = invite.crew.count - displayed.count
                    Text(displayed.joined(separator: ", ") + (remaining > 0 ? " +\(remaining)" : ""))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.85))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }

            // PRIMARY action: fire an in-app invite to every saved-crew
            // member at once. Recipients see a banner appear in their app
            // on the next poll and can tap Accept to drop straight into
            // this session — no copy-paste, no iMessage round trip. The
            // ShareLink below stays as a secondary fallback for friends
            // who don't have the app open right now.
            Button {
                Task {
                    let recipients = invite.crew.map(\.id)
                    let sent = await invites.send(
                        sessionId: session.id,
                        joinCode: session.joinCode,
                        mode: group.scope,
                        recipientIds: recipients
                    )
                    inviteSendToast = sent > 0
                        ? "Sent to \(sent) friend\(sent == 1 ? "" : "s")"
                        : "Already invited"
                    // Hold the toast briefly, then dismiss the card —
                    // the card has done its job and the active view can
                    // settle back into its normal layout.
                    try? await Task.sleep(nanoseconds: 1_400_000_000)
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                        pendingInvite = nil
                        inviteSendToast = nil
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: inviteSendToast == nil ? "paperplane.fill" : "checkmark")
                        .font(.system(size: 12, weight: .bold))
                    Text(inviteSendToast ?? "SEND INVITE")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .tracking(1.6)
                    Spacer()
                    if inviteSendToast == nil {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.ink.opacity(0.55))
                    }
                }
                .foregroundStyle(Color.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.whiskey)
                )
                .shadow(color: Color.whiskey.opacity(0.45), radius: 14, y: 6)
            }
            .buttonStyle(PressScaleStyle())
            .disabled(inviteSendToast != nil)

            // SECONDARY: iMessage share, in case any of the saved crew
            // doesn't have the app open right now. Compact treatment so
            // it reads as a fallback rather than a sibling.
            ShareLink(item: message) {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 11, weight: .bold))
                    Text("Or share via Messages")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                }
                .foregroundStyle(Color.cream.opacity(0.6))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(PressScaleStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.whiskey.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.whiskey.opacity(0.45), lineWidth: 1)
        )
        .transition(.asymmetric(
            insertion: .scale(scale: 0.95).combined(with: .opacity),
            removal: .opacity
        ))
    }

    @ViewBuilder
    private var activeView: some View {
        if let session = group.session {
            // "Bring back the crew" share card — only shows when the
            // user just spun this session up by tapping a saved-group
            // row. Sits at the top of the active view so it's the
            // first thing they see post-create, but is dismissible
            // and non-blocking.
            if let invite = pendingInvite {
                previousCrewCard(session: session, invite: invite)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("SHARE THIS CODE")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(Color.bronze)

                HStack {
                    Text(session.joinCode)
                        .font(.system(size: 40, weight: .black, design: .monospaced))
                        .tracking(8)
                        .foregroundStyle(Color.cream)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 22)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.inkElev)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.whiskey.opacity(0.4), lineWidth: 1)
                )

                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = session.joinCode
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                            showCopied = true
                        }
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            withAnimation { showCopied = false }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 12, weight: .bold))
                            Text(showCopied ? "COPIED" : "COPY CODE")
                                .font(.system(size: 11, weight: .black, design: .monospaced))
                                .tracking(1.6)
                        }
                        .foregroundStyle(Color.cream)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.cream.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.cream.opacity(0.14), lineWidth: 1)
                        )
                    }
                    .buttonStyle(PressScaleStyle())

                    ShareLink(item: "Join my sesh — code \(session.joinCode)") {
                        HStack(spacing: 8) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 12, weight: .bold))
                            Text("SHARE")
                                .font(.system(size: 11, weight: .black, design: .monospaced))
                                .tracking(1.6)
                        }
                        .foregroundStyle(Color.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.whiskey)
                        )
                    }
                    .buttonStyle(PressScaleStyle())
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("IN THE SESH")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(Color.bronze)

                ForEach(group.members.sorted(by: { $0.joinedAt < $1.joinedAt }), id: \.profileId) { m in
                    HStack(spacing: 10) {
                        let prof = group.memberProfiles[m.profileId]
                        AvatarView(
                            urlString: prof?.avatarURL,
                            initial: String((prof?.name ?? "?").prefix(1)).uppercased(),
                            size: 28
                        )
                        Text(prof?.name ?? "Guest")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.cream)
                        if session.hostId == m.profileId {
                            Text("HOST")
                                .font(.system(size: 9, weight: .black, design: .monospaced))
                                .tracking(1.4)
                                .foregroundStyle(Color.whiskey)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .overlay(Capsule().strokeBorder(Color.whiskey.opacity(0.6), lineWidth: 1))
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.cream.opacity(0.04))
                    )
                }
            }

            // Save toggle — adds the current group to the saved list (or
            // removes it if already there). The store keys on session id,
            // so saving here is what causes this group to show up in the
            // idle-view "SAVED GROUPS" list next time the user comes back.
            // We pass the live member count + host name so the snapshot
            // looks right immediately, without waiting for the next poll.
            saveToggleButton(session: session)

            if group.isHost {
                Button {
                    confirmEnd = true
                } label: {
                    Text("END GROUP SESH")
                        .font(.system(size: 12, weight: .black, design: .monospaced))
                        .tracking(1.8)
                        .foregroundStyle(Color(red: 0.85, green: 0.32, blue: 0.23))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color(red: 0.85, green: 0.32, blue: 0.23).opacity(0.1))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color(red: 0.85, green: 0.32, blue: 0.23).opacity(0.4), lineWidth: 1)
                        )
                }
                .buttonStyle(PressScaleStyle())
                // End now truly ends for everyone — the previous
                // "mirrored = per-mode leave" carve-out shipped a silent
                // no-op for the rest of the group when the host had the
                // session in both modes, so it's gone. If the cousin
                // shares the session, `end()` also clears the cousin's
                // local state so both modes on the host's phone go idle
                // together.
                .confirmationDialog(
                    "End \(group.scope.label.lowercased()) sesh for everyone?",
                    isPresented: $confirmEnd,
                    titleVisibility: .visible
                ) {
                    Button("End \(group.scope.label.lowercased()) for everyone", role: .destructive) {
                        Task {
                            await group.end(cousinSessionId: cousin.session?.id)
                            dismiss()
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    if cousinSharesSession {
                        // Per-mode end (migration 007): plan and live
                        // are independent even when they track the
                        // same session. Reassure the host that ending
                        // here doesn't yank their other mode.
                        Text("Only \(group.scope.label.lowercased()) ends. Your \(group.scope.other.label.lowercased()) mode stays in the group.")
                    } else {
                        Text("Everyone in \(group.scope.label.lowercased()) mode will go idle. The session stays alive for any \(group.scope.other.label.lowercased())-mode members.")
                    }
                }
            } else {
                Button {
                    confirmLeave = true
                } label: {
                    Text("LEAVE SESH")
                        .font(.system(size: 12, weight: .black, design: .monospaced))
                        .tracking(1.8)
                        .foregroundStyle(Color.cream.opacity(0.72))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.cream.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.cream.opacity(0.12), lineWidth: 1)
                        )
                }
                .buttonStyle(PressScaleStyle())
                .confirmationDialog(
                    "Leave \(group.scope.label.lowercased()) sesh?",
                    isPresented: $confirmLeave,
                    titleVisibility: .visible
                ) {
                    Button("Leave \(group.scope.label.lowercased())", role: .destructive) {
                        Task {
                            // The cousin id is no longer used by
                            // `leave()` under the per-mode model — the
                            // DB-level `in_<scope>` flag decouples the
                            // two stores. Kept in the call for ABI
                            // compatibility; the parameter is ignored.
                            await group.leave(cousinSessionId: cousin.session?.id)
                            dismiss()
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    if cousinSharesSession {
                        Text("Only \(group.scope.label.lowercased()) leaves. Your \(group.scope.other.label.lowercased()) mode stays in the group.")
                    }
                }
            }
        }
    }
}

// MARK: - Saved-group row
//
// One row in the "RECENT GROUPS" list. The whole card is a tap target
// (rejoin via the cached join code), with an inline trash button on the
// trailing edge for "I don't actually want this in my list anymore".
//
// Layout note: the join code is the headline, set in the same heavy
// monospaced face the active-view code badge uses. The secondary line
// blends host name (when known) and member count, and we render a
// soft "n d ago" timestamp on the trailing side so the user can tell at
// a glance which entries are stale.

private struct SavedGroupRow: View {
    let entry: SavedGroup
    /// True while the parent SessionService is busy joining/creating
    /// something. Used to grey out and disable the row so we don't fire
    /// a second join while the first one is in flight.
    let busy: Bool
    let onTap: () -> Void
    let onRemove: () -> Void

    /// Compact "joined N {unit} ago" formatter. Falls back to a short
    /// date for anything older than a week so the strings don't grow
    /// ridiculous ("joined 47d ago").
    private var lastJoinedLabel: String {
        let interval = Date().timeIntervalSince(entry.lastJoinedAt)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86_400 { return "\(Int(interval / 3600))h ago" }
        if interval < 86_400 * 7 { return "\(Int(interval / 86_400))d ago" }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: entry.lastJoinedAt)
    }

    /// "Hosted by Mauritz · 4 people" / "4 people" when the host name
    /// hasn't been cached yet. Single people gets a singular noun so
    /// "1 people" doesn't slip into the UI.
    private var detailLabel: String {
        let memberPart = "\(entry.lastMemberCount) \(entry.lastMemberCount == 1 ? "person" : "people")"
        if let host = entry.lastHostName, !host.isEmpty {
            return "Hosted by \(host) · \(memberPart)"
        }
        return memberPart
    }

    var body: some View {
        HStack(spacing: 12) {
            // Tap target: the whole card minus the trash button. We
            // wrap it in a Button so SwiftUI gives us hit-testing and
            // press feedback for free.
            Button(action: onTap) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.whiskey.opacity(0.16))
                            .frame(width: 44, height: 44)
                        Text(String(entry.joinCode.prefix(2)))
                            .font(.system(size: 14, weight: .black, design: .monospaced))
                            .tracking(1.5)
                            .foregroundStyle(Color.whiskey)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(entry.joinCode)
                                .font(.system(size: 15, weight: .black, design: .monospaced))
                                .tracking(2.4)
                                .foregroundStyle(Color.cream)
                            Text("·")
                                .foregroundStyle(Color.bronze.opacity(0.7))
                            Text(lastJoinedLabel)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .tracking(0.6)
                                .foregroundStyle(Color.cream.opacity(0.55))
                        }
                        Text(detailLabel)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.7))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.bronze)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleStyle())
            .disabled(busy)

            // Trash affordance — destructive enough to want a discrete
            // tap target, subtle enough not to dominate the row. We use
            // a slightly larger hit area than the icon so it's easy to
            // hit on a phone.
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.cream.opacity(0.55))
                    .frame(width: 32, height: 32)
                    .background(
                        Circle().fill(Color.cream.opacity(0.05))
                    )
                    .overlay(
                        Circle().strokeBorder(Color.cream.opacity(0.1), lineWidth: 1)
                    )
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel("Remove \(entry.joinCode) from recent groups")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.inkElev.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.cream.opacity(0.08), lineWidth: 1)
        )
        .opacity(busy ? 0.55 : 1.0)
    }
}

// MARK: - Live Sesh Bar (entry point shown in main session view)

/// Compact entry-point card. When no live sesh is running it acts as a CTA;
/// when one is active it surfaces the current BAC + time-to-sober at a
/// glance and taps through to reopen the live experience.
private struct LiveSeshBar: View {
    @ObservedObject var live: LiveSeshState
    @ObservedObject var group: SessionService
    let profile: Profile
    let onTap: () -> Void

    /// Group-live "is active" means: there's a session AND somebody has
    /// logged a *live* drink (regular order-card drinks don't count). We
    /// treat the first live pour as the trigger so everyone in the group
    /// sees the live experience the moment anyone starts tracking live —
    /// no separate "go live" handshake required.
    private var groupLive: Bool { group.isActive && group.hasLiveActivity }
    private var inGroup: Bool { group.isActive }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if groupLive {
            groupActivePill(now: now)
        } else if live.isActive {
            activePill(now: now)
        } else if inGroup {
            groupIdleCTA
        } else {
            idleCTA
        }
    }

    private var idleCTA: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.whiskey.opacity(0.18))
                        .frame(width: 34, height: 34)
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.whiskey)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("GO LIVE")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(2.4)
                        .foregroundStyle(Color.cream)
                    Text("Track each drink as you go")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.55))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.bronze)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.cream.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        Color.whiskey.opacity(0.28),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                    )
            )
        }
        .buttonStyle(PressScaleStyle())
    }

    private func activePill(now: Date) -> some View {
        let bac = live.bac(profile: profile, now: now)
        let hours = live.hoursUntil(threshold: 0.0, profile: profile, now: now)
        return Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.whiskey)
                        .frame(width: 34, height: 34)
                    Circle()
                        .stroke(Color.whiskey.opacity(0.4), lineWidth: 4)
                        .frame(width: 46, height: 46)
                        .opacity(0.7)
                    Image(systemName: "waveform")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.ink)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("LIVE SESH")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(2.0)
                            .foregroundStyle(Color.whiskey)
                        Circle()
                            .fill(Color.whiskey)
                            .frame(width: 5, height: 5)
                            .shadow(color: Color.whiskey.opacity(0.8), radius: 4)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(String(format: "%.3f", bac))
                            .font(.system(size: 18, weight: .heavy, design: .rounded))
                            .italic()
                            .foregroundStyle(Color.cream)
                            .monospacedDigit()
                        Text("·")
                            .foregroundStyle(Color.cream.opacity(0.4))
                        Text(formatHM(hours, prefix: "sober in "))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .tracking(0.6)
                            .foregroundStyle(Color.cream.opacity(0.7))
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.bronze)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.whiskey.opacity(0.16), Color.whiskey.opacity(0.04)],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.whiskey.opacity(0.5), lineWidth: 1)
            )
            .shadow(color: Color.whiskey.opacity(0.25), radius: 14, y: 6)
        }
        .buttonStyle(PressScaleStyle())
    }

    private func formatHM(_ hours: Double, prefix: String = "") -> String {
        guard hours > 0 else { return "sober" }
        let mins = Int((hours * 60).rounded())
        if mins < 60 { return "\(prefix)\(mins)m" }
        let h = mins / 60, m = mins % 60
        return m == 0 ? "\(prefix)\(h)h" : "\(prefix)\(h)h \(m)m"
    }

    /// "GO LIVE" CTA shown when in a group session but nobody has logged a
    /// drink yet. Tapping opens the group-aware live experience.
    private var groupIdleCTA: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.whiskey.opacity(0.18))
                        .frame(width: 34, height: 34)
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.whiskey)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("GO LIVE WITH THE GROUP")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(2.0)
                        .foregroundStyle(Color.cream)
                    Text("\(group.members.count) \(group.members.count == 1 ? "person" : "people") · track each pour together")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.55))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.bronze)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.cream.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        Color.whiskey.opacity(0.32),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                    )
            )
        }
        .buttonStyle(PressScaleStyle())
    }

    /// Live pill shown when a group is mid-sesh. Renders MY current live BAC
    /// (per-drink Widmark, same number across phones) plus the people count.
    private func groupActivePill(now: Date) -> some View {
        let bac = group.liveBAC(for: profile.id, now: now)
        let hours = group.liveHoursUntil(threshold: 0.0, for: profile.id, now: now)
        return Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.whiskey)
                        .frame(width: 34, height: 34)
                    Circle()
                        .stroke(Color.whiskey.opacity(0.4), lineWidth: 4)
                        .frame(width: 46, height: 46)
                        .opacity(0.7)
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.ink)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("LIVE · \(group.members.count) \(group.members.count == 1 ? "PERSON" : "PEOPLE")")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(2.0)
                            .foregroundStyle(Color.whiskey)
                        Circle()
                            .fill(Color.whiskey)
                            .frame(width: 5, height: 5)
                            .shadow(color: Color.whiskey.opacity(0.8), radius: 4)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(String(format: "%.3f", bac))
                            .font(.system(size: 18, weight: .heavy, design: .rounded))
                            .italic()
                            .foregroundStyle(Color.cream)
                            .monospacedDigit()
                        Text("·")
                            .foregroundStyle(Color.cream.opacity(0.4))
                        Text(formatHM(hours, prefix: "sober in "))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .tracking(0.6)
                            .foregroundStyle(Color.cream.opacity(0.7))
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.bronze)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.whiskey.opacity(0.22), Color.whiskey.opacity(0.05)],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.whiskey.opacity(0.55), lineWidth: 1)
            )
            .shadow(color: Color.whiskey.opacity(0.3), radius: 16, y: 6)
        }
        .buttonStyle(PressScaleStyle())
    }
}

// MARK: - Live Sesh View (the live tracking experience)

/// Unified timeline row data: collapses LiveDrink (solo) and SessionDrink
/// (group) into one shape so the renderer is identical. The `removable`
/// flag suppresses the minus button on shared drinks the user can't
/// delete (they're owned by another member).
fileprivate struct TimelineEntry: Identifiable {
    let id: UUID
    let optionName: String
    let detail: String
    let option: DrinkOption
    let consumedAt: Date
    let isShared: Bool
    let removable: Bool
}

/// Identifiable wrapper around a ghost id so we can drive
/// `.sheet(item:)` with it. SwiftUI requires an `Identifiable` payload
/// (not an `Optional<UUID>`) — wrapping keeps the call site readable.
private struct GhostPickerTarget: Identifiable {
    let id: UUID
}

/// Full-screen Live Sesh. A `TimelineView` re-evaluates the body every 30s
/// so BAC, time-to-sober, and the drink-history "X minutes ago" labels all
/// stay current without manual refresh. Quick-add tiles live at the bottom
/// so logging a drink is one tap from the most likely candidates.
private struct LiveSeshView: View {
    @ObservedObject var live: LiveSeshState
    /// Optional group context. When the user is in a group session AND has
    /// hit GO LIVE, this is non-nil and the view becomes a group experience:
    /// drinks are written to the DB, the roster is shown, and a roast card
    /// surfaces gamified commentary on the drunkest member.
    @ObservedObject var group: SessionService
    /// Persistent record of the user's recent drink picks. Drives the
    /// adaptive quick-add tiles — picks bubble to the top so the most
    /// likely next pour is always one tap away.
    @ObservedObject var recents: RecentDrinksStore
    /// Shared with SessionView so both modes use the same chip + venue
    /// selection. Live Sesh uses these to pin the current bar's specials
    /// to the top of the picker.
    @ObservedObject var location: LocationService
    @ObservedObject var venues: VenueService
    /// Manually-added live-mode participants. Owned by SessionView so
    /// it survives mode swipes; injected here to render the roster
    /// section and accept new drinks.
    @ObservedObject var ghosts: GhostMembersStore
    let profile: Profile
    /// True when this view is hosted inline as a TabView page (not a
    /// modal). Suppresses the duplicate close header and the "Started…"
    /// chrome that the parent ModeTopBar already covers.
    var embedded: Bool = false
    /// Tap-handler for the live GroupBar — opens the parent's group
    /// sheet bound to scope = .live. Only used when embedded; the modal
    /// presentation has no group sheet of its own.
    var onOpenGroupSheet: (() -> Void)? = nil
    /// Called by the END action when running embedded — the parent uses
    /// this to slide back to PLAN after clearing the live timeline. nil
    /// when the view is presented modally (the close button uses dismiss
    /// instead).
    var onExitLiveTimeline: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var menuOpen = false
    @State private var confirmEnd = false
    @State private var venueOpen = false
    /// Whether the add-person form is up. One global `@State` is enough
    /// because we only ever add one ghost at a time.
    @State private var addPersonOpen = false
    /// When non-nil, the catalog sheet is up scoped to this ghost (the
    /// next pick goes onto their tab, not the user's). nil ⇒ the
    /// regular `menuOpen` flow runs and picks land on the user.
    @State private var pickingForGhostId: UUID? = nil
    /// When in a group, controls whether new drinks are added as shared
    /// rounds (split across all members) or as personal drinks. Ignored
    /// in solo mode. Persists between taps so a "round of shots" doesn't
    /// require flipping back and forth for each one.
    @State private var shareMode = false

    private var inGroup: Bool { group.isActive }

    /// Quick-add tiles — adaptive. Default lineup is small beer / large
    /// beer / glass of wine. As the user logs drinks, the tiles shift to
    /// reflect their three most-recent unique picks (newest leftmost).
    /// If the user has fewer than 3 unique picks, the remaining slots are
    /// filled from the defaults so we always show 3 tiles.
    private var quickAdd: [DrinkOption] {
        let defaultNames = ["Small beer", "Large beer", "Glass of wine"]
        var picks: [DrinkOption] = []
        var seen = Set<String>()

        // Recent uniques first (newest leftmost), capped at 3.
        for opt in recents.resolved() {
            if picks.count >= 3 { break }
            guard !seen.contains(opt.name) else { continue }
            picks.append(opt)
            seen.insert(opt.name)
        }

        // Fill any remaining slots with defaults the user hasn't already
        // picked — ensures we always show 3 distinct tiles even for a
        // brand-new user with empty history.
        for name in defaultNames {
            if picks.count >= 3 { break }
            guard !seen.contains(name),
                  let opt = DrinkCatalog.allOptions.first(where: { $0.name == name })
            else { continue }
            picks.append(opt)
            seen.insert(name)
        }

        return picks
    }

    // MARK: data accessors (solo vs. group)

    private func currentBAC(now: Date) -> Double {
        if inGroup {
            return group.liveBAC(for: profile.id, now: now)
        }
        return live.bac(profile: profile, now: now)
    }

    private func hoursUntil(threshold: Double, now: Date) -> Double {
        if inGroup {
            return group.liveHoursUntil(threshold: threshold, for: profile.id, now: now)
        }
        return live.hoursUntil(threshold: threshold, profile: profile, now: now)
    }

    private var startTime: Date? {
        if inGroup {
            return group.firstDrinkTime(for: profile.id) ?? group.session?.createdAt
        }
        return live.startedAt
    }

    private var totalDrinkCount: Int {
        inGroup ? group.totalDrinkCount(for: profile.id) : live.drinks.count
    }

    /// Logs a drink in the right backing store. Optimistic UI is built in
    /// to both paths (LiveSeshState + SessionService). In group mode the
    /// `shareMode` toggle decides whether the drink goes onto the user's
    /// personal tab or into the shared round pool. Always records the
    /// pick in `recents` so quick-add can adapt.
    private func logDrink(_ option: DrinkOption) {
        recents.record(option)
        if inGroup {
            let isShared = shareMode
            // Live store stamps live=true from its scope.
            let t: Task<Void, Never> = Task { await group.addDrink(option, shared: isShared) }
            _ = t
        } else {
            live.add(option)
        }
    }

    /// Removes the most recent drink of an option (group: my drinks only).
    /// Solo path is by id; group path delegates to SessionService.
    private func removeDrink(id: UUID) {
        if inGroup {
            // Group removal is by lookup of "my last of this option";
            // we keep it simple here — the timeline rows still work because
            // the underlying SessionService refresh will re-emit the list.
            // resolveOption keeps this working for venue specials too —
            // otherwise the catalog-only path silently no-op'd on a
            // Fittkittlaren tap and the row would never disappear.
            if let drink = group.drinks.first(where: { $0.id == id }) {
                let opt = venues.resolveOption(for: drink)
                let t: Task<Void, Never> = Task {
                    // Live store knows its own scope — no need to pass live.
                    await group.removeMyLast(of: opt, shared: drink.shared)
                }
                _ = t
            }
        } else {
            live.remove(id)
        }
    }

    var body: some View {
        ZStack {
            AtmosphereBackground(accent: Color.whiskey)
            ScrollView(showsIndicators: false) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    content(now: context.date)
                }
            }
            .safeAreaInset(edge: .bottom) {
                quickAddDock
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $menuOpen) {
            LiveMenuSheet(
                venueSpecials: venues.currentSpecialsAsOptions(),
                venueName: venues.currentVenue?.name,
                onPick: { option in
                    logDrink(option)
                    menuOpen = false
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.ink)
        }
        .sheet(isPresented: $venueOpen) {
            VenueSheet(location: location, venues: venues)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.ink)
        }
        // Per-ghost drink picker. Reuses LiveMenuSheet — same catalog
        // and venue-specials surface the user gets — but routes the
        // pick into the ghost's drink log instead of the user's. The
        // bound id doubles as the dismissal flag (nil ⇒ closed).
        .sheet(item: Binding(
            get: { pickingForGhostId.map(GhostPickerTarget.init) },
            set: { pickingForGhostId = $0?.id }
        )) { target in
            LiveMenuSheet(
                venueSpecials: venues.currentSpecialsAsOptions(),
                venueName: venues.currentVenue?.name,
                onPick: { option in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                        ghosts.addDrink(option, to: target.id)
                    }
                    pickingForGhostId = nil
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.ink)
        }
        .sheet(isPresented: $addPersonOpen) {
            AddPersonSheet { name, sex, age, weightKg in
                ghosts.add(name: name, sex: sex, age: age, weightKg: weightKg)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.ink)
        }
        .confirmationDialog(
            "End Live Sesh?",
            isPresented: $confirmEnd,
            titleVisibility: .visible
        ) {
            Button("End sesh", role: .destructive) {
                live.end()
                // Tear down the lock-screen card alongside the in-app
                // timeline. Same intent as the END handler upstream:
                // a stale BAC reading on a locked phone is creepy.
                LiveActivityController.shared.end()
                // When embedded, hand control back to the parent so it
                // can swipe to PLAN. When presented modally, fall back
                // to environment-driven dismissal.
                if let onExitLiveTimeline {
                    onExitLiveTimeline()
                } else {
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears the timeline. Your regular session is unaffected.")
        }
        // ---- Lock-screen Live Activity sync ----
        // The activity is keyed off the user's current BAC, drink count,
        // and group/solo mode. We re-fire on every change so the
        // lock-screen + Dynamic Island always reflect the latest snap.
        // start() is idempotent — calling it on an already-running
        // activity just updates it, so we don't need to track "is it
        // started" state here.
        .onAppear { syncLockScreenActivity() }
        .onChange(of: liveSnapshotKey) { _, _ in syncLockScreenActivity() }
        .onChange(of: inGroup) { _, _ in
            // Switching between solo and group means the heroLabel
            // ("LIVE SESH" vs "GROUP SESH") needs to change. Easiest
            // way: tear down and let the next sync rebuild it with
            // the right attributes.
            LiveActivityController.shared.end()
            syncLockScreenActivity()
        }
    }

    // MARK: - Live Activity sync

    /// Composite key that flips whenever any field the lock-screen
    /// activity cares about has changed. Bound to `.onChange` so
    /// SwiftUI fires our update closure exactly when the lock-screen
    /// card would render differently.
    private var liveSnapshotKey: String {
        let now = Date()
        let bac = currentBAC(now: now)
        var key = "\(totalDrinkCount)-\(String(format: "%.4f", bac))-\(startTime?.timeIntervalSince1970 ?? 0)"
        if inGroup {
            // Include every member's drink count + bac so the
            // activity pushes a refresh the moment somebody else's
            // row would render differently. The poll-driven group
            // store updates `members` every 3s; this key turns those
            // changes into a re-publish to the lock screen.
            let parts = group.members.map { m -> String in
                let mb = group.liveBAC(for: m.profileId, now: now)
                let mc = group.totalDrinkCount(for: m.profileId)
                return "\(m.profileId.uuidString.prefix(8)):\(mc):\(String(format: "%.3f", mb))"
            }
            key += "|" + parts.joined(separator: ",")
        }
        return key
    }

    /// Decide whether to start, update, or end the lock-screen activity
    /// based on the current state. Single source of truth for activity
    /// lifecycle — the END action handler is the only other place that
    /// tears it down explicitly (because it has to fire before the
    /// view disappears).
    private func syncLockScreenActivity() {
        let now = Date()
        // Garbage-collect a stale solo sesh before reading state for
        // the activity. `endIfStale` is a no-op unless BAC has hit 0
        // AND the last drink was >12h ago, so this only fires for
        // genuinely abandoned sessions. Group seshs aren't touched
        // (group lifecycle lives in the DB via SessionService).
        if !inGroup {
            _ = live.endIfStale(profile: profile, now: now)
        }
        let bac = currentBAC(now: now)
        let count = totalDrinkCount
        let started = startTime ?? now
        let status = statusFor(bac: bac)
        let roster = lockScreenRoster(now: now)

        // No drinks AND no started time AND BAC has decayed to zero ⇒
        // there's nothing to surface. End any leftover activity from a
        // prior sesh that the user re-entered.
        if count == 0 && bac == 0 && !inGroup && !live.isActive {
            LiveActivityController.shared.end()
            // Wipe the home-screen widget's snapshot too so the widget
            // flips to its empty state instead of clinging to a stale
            // BAC from a previous night.
            WidgetSharedStore.clear()
            return
        }

        LiveActivityController.shared.start(
            bac: bac,
            drinkCount: count,
            startedAt: started,
            inGroup: inGroup,
            statusRaw: status.rawValue,
            quickDrinks: lockScreenQuickDrinks,
            roster: roster,
            now: now
        )

        // Mirror the same data into the home-screen widget's shared
        // store. The widget projects BAC forward from this snapshot
        // on its own timeline (every 5 min for an hour) so the
        // number actually ticks down on the home screen without
        // requiring the app to be open.
        writeWidgetSnapshot(
            bac: bac,
            count: count,
            started: started,
            status: status,
            roster: roster,
            now: now
        )
    }

    /// Translate the in-memory live state into a `WidgetSnapshot` and
    /// hand it to the App Group store. Called from every
    /// `syncLockScreenActivity` invocation so the widget always
    /// reflects what the lock-screen activity reflects, plus
    /// continues to decay BAC linearly between writes.
    private func writeWidgetSnapshot(
        bac: Double,
        count: Int,
        started: Date,
        status: Status,
        roster: [SeshActivityAttributes.RosterMember],
        now: Date
    ) {
        let hoursToSober = max(0, bac / 0.015)
        let soberAt = now.addingTimeInterval(hoursToSober * 3600)
        let widgetRoster: [WidgetSnapshot.Member] = roster
            .filter { !$0.isMe }   // me is rendered as the headline value
            .map { m in
                WidgetSnapshot.Member(
                    profileId: m.profileId,
                    name: m.name,
                    bac: m.bac,
                    statusRaw: m.statusRaw,
                    drinkCount: m.drinkCount,
                    initials: m.initials
                )
            }
        let snap = WidgetSnapshot(
            snapshotAt: now,
            hasActiveSesh: true,
            inGroup: inGroup,
            meName: profile.name,
            meBac: max(0, bac),
            meStatusRaw: status.rawValue,
            meDrinkCount: count,
            meStartedAt: started,
            meSoberAt: soberAt,
            roster: widgetRoster
        )
        WidgetSharedStore.write(snap)
    }

    /// Up to three of the user's most-recent drinks, projected into
    /// the wire format the activity carries. Empty in group mode —
    /// lock-screen logging hits Supabase, which we don't gate on a
    /// single tap for v1. Empty for a brand-new account too; the
    /// widget hides the row when this is empty so it doesn't render
    /// as dead space.
    private var lockScreenQuickDrinks: [SeshActivityAttributes.QuickDrink] {
        guard !inGroup else { return [] }
        return quickAdd.prefix(3).map { opt in
            SeshActivityAttributes.QuickDrink(
                name: opt.name,
                detail: opt.detail,
                category: opt.category.rawValue,
                volumeML: opt.volumeML,
                abv: opt.abv,
                emoji: opt.category.emoji
            )
        }
    }

    /// Project the group's live roster into the wire format the
    /// activity carries. Empty in solo mode (the widget hides the
    /// roster section when empty). Capped at 4 members — sorted by
    /// BAC descending so the most "interesting" (drunkest) rows
    /// surface in a large group. The user is always included even
    /// if they're sober and bottom of the BAC list, so they can
    /// always find themselves on the card.
    private func lockScreenRoster(now: Date) -> [SeshActivityAttributes.RosterMember] {
        guard inGroup else { return [] }
        let me = profile.id
        let scored: [(SeshActivityAttributes.RosterMember, Double)] = group.members.map { m in
            let prof = group.memberProfiles[m.profileId]
            let name = prof?.name ?? "Member"
            let bac = group.liveBAC(for: m.profileId, now: now)
            let status = statusFor(bac: bac)
            let count = group.totalDrinkCount(for: m.profileId)
            return (
                SeshActivityAttributes.RosterMember(
                    profileId: m.profileId,
                    name: name,
                    bac: bac,
                    statusRaw: status.rawValue,
                    drinkCount: count,
                    initials: initialsFor(name: name),
                    isMe: m.profileId == me
                ),
                bac
            )
        }
        // Sort by BAC desc, but pin "me" so the user is always shown
        // even if a 5+ person group would otherwise truncate them.
        let myRow = scored.first { $0.0.isMe }
        let othersSorted = scored
            .filter { !$0.0.isMe }
            .sorted { $0.1 > $1.1 }
        var out: [SeshActivityAttributes.RosterMember] = []
        if let myRow { out.append(myRow.0) }
        for (row, _) in othersSorted {
            if out.count >= 4 { break }
            out.append(row)
        }
        return out
    }

    /// Cheap 1–2 character initials from a display name. Falls back
    /// to "?" so the avatar circle is never empty. Used by the
    /// roster rows on the lock-screen card.
    private func initialsFor(name: String) -> String {
        let parts = name
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(2)
        let letters = parts.compactMap { $0.first }
        let joined = String(letters).uppercased()
        return joined.isEmpty ? "?" : joined
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let bac = currentBAC(now: now)
        let status = statusFor(bac: bac)
        VStack(alignment: .leading, spacing: 22) {
            header(bac: bac, status: status, now: now)
            // Live mode has its own group, independent of plan. Surfacing
            // a GroupBar here lets the user join/leave/mirror without
            // jumping back to PLAN. Only shown when embedded (i.e. as a
            // tab page) — the legacy modal presentation has no parent
            // group sheet to open.
            if embedded, let onOpenGroupSheet {
                GroupBar(
                    scope: .live,
                    session: group.session,
                    memberCount: group.members.count,
                    onTap: onOpenGroupSheet
                )
            }
            VenueChip(
                location: location,
                venues: venues,
                onTap: { venueOpen = true }
            )
            liveBACCard(bac: bac, status: status, now: now)
            timeToSoberCard(bac: bac, status: status, now: now)
            if inGroup {
                LiveGroupRoster(group: group, selfId: profile.id, now: now)
                LiveRoastCard(group: group, profile: profile, now: now)
            }
            // Manually-added ghost members — always shown in live mode.
            // Acts as the "+ Add person" entry point even when there are
            // no ghosts yet, so the affordance is always discoverable.
            LiveGhostSection(
                ghosts: ghosts,
                now: now,
                onPickDrink: { ghostId in
                    pickingForGhostId = ghostId
                },
                onAddPerson: {
                    addPersonOpen = true
                }
            )
            VibeCard(status: status, message: vibeMessage(for: status))
            timelineSection(now: now)
            Disclaimer()
                .padding(.top, 4)
            Spacer(minLength: 24)
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 16)
    }

    /// Picks one of the status's funny lines, rotated by drink count so the
    /// message changes as the night progresses (and doesn't feel stuck).
    private func vibeMessage(for status: Status) -> VibeMessage {
        let msgs = status.messages
        guard !msgs.isEmpty else {
            return VibeMessage(headline: "Sesh on.", advice: "Drink water.")
        }
        return msgs[max(0, totalDrinkCount) % msgs.count]
    }

    // MARK: header

    private func header(bac: Double, status: Status, now: Date) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.whiskey)
                        .frame(width: 7, height: 7)
                        .shadow(color: Color.whiskey.opacity(0.8), radius: 5)
                    Text(inGroup ? "LIVE GROUP" : "LIVE SESH")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(2.6)
                        .foregroundStyle(Color.whiskey)
                    if inGroup {
                        Text("· \(group.members.count) people")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .tracking(1.2)
                            .foregroundStyle(Color.cream.opacity(0.55))
                    }
                }
                if let started = startTime {
                    Text(elapsedString(from: started, to: now))
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(Color.cream.opacity(0.55))
                        .contentTransition(.numericText())
                } else {
                    Text("Ready when you are")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.55))
                }
            }
            Spacer()
            // Close affordance:
            // - Embedded + solo + live.isActive: keep END so the user
            //   can clear the timeline (only action with meaning).
            // - Embedded otherwise: hide — swiping back to PLAN is the
            //   way out, which is what the parent ModeTopBar provides.
            // - Modal: full set (DONE / END / CLOSE) since there's no
            //   other way to dismiss.
            if !embedded || (!inGroup && live.isActive) {
                Button {
                    if inGroup {
                        dismiss()
                    } else if live.isActive {
                        confirmEnd = true
                    } else {
                        dismiss()
                    }
                } label: {
                    Text(inGroup ? "DONE" : (live.isActive ? "END" : "CLOSE"))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(2.0)
                        .foregroundStyle(Color.cream)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.cream.opacity(0.06)))
                        .overlay(Capsule().strokeBorder(Color.cream.opacity(0.2), lineWidth: 1))
                }
                .buttonStyle(PressScaleStyle())
            }
        }
    }

    // MARK: live BAC card

    private func liveBACCard(bac: Double, status: Status, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("RIGHT NOW")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(Color.bronze)
                Spacer()
                StatusPill(status: status)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(format: "%.3f", bac))
                    .font(.system(size: 76, weight: .black, design: .rounded))
                    .tracking(-2.5)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.cream, status.color.opacity(0.92)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: status.color.opacity(0.5), radius: 28, y: 10)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: bac))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("%BAC")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(Color.bronze)
                    .padding(.bottom, 12)
            }
            BACScale(bac: bac, status: status)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.cream.opacity(0.05), Color.cream.opacity(0.012)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(status.color.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: status.color.opacity(0.3), radius: 36, y: 16)
    }

    // MARK: time-to-sober card

    private func timeToSoberCard(bac: Double, status: Status, now: Date) -> some View {
        let hoursSober = hoursUntil(threshold: 0.0, now: now)
        let hoursEU    = hoursUntil(threshold: 0.02, now: now)
        let hoursUS    = hoursUntil(threshold: 0.08, now: now)
        let soberAt = now.addingTimeInterval(hoursSober * 3600)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("SOBER BY")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(Color.bronze)
                Spacer()
                if hoursSober > 0 {
                    Text(soberAt, format: .dateTime.hour().minute())
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(1.0)
                        .foregroundStyle(status.color)
                        .contentTransition(.numericText())
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(formatDuration(hoursSober))
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .italic()
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.cream, status.color.opacity(0.85)],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .monospacedDigit()
                    .contentTransition(.numericText(value: hoursSober))
                if hoursSober > 0 {
                    Text("to 0.000")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(Color.bronze)
                }
            }
            if hoursEU > 0 || hoursUS > 0 {
                VStack(spacing: 4) {
                    if hoursEU > 0 {
                        limitRow(label: "EU LIMIT (0.02)", hours: hoursEU, tint: status.color.opacity(0.95))
                    }
                    if hoursUS > 0 {
                        limitRow(label: "US LIMIT (0.08)", hours: hoursUS, tint: status.color.opacity(0.7))
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.cream.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(status.color.opacity(0.22), lineWidth: 1)
        )
    }

    private func limitRow(label: String, hours: Double, tint: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 5, height: 5).shadow(color: tint.opacity(0.6), radius: 3)
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(Color.cream.opacity(0.55))
            Spacer(minLength: 8)
            Text(formatDuration(hours))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(tint)
                .monospacedDigit()
        }
    }

    // MARK: timeline of drinks

    private func timelineEntries() -> [TimelineEntry] {
        if inGroup {
            // Resolve via VenueService — the standard-catalog-only lookup
            // we used to do here silently dropped venue specials from the
            // timeline (BAC still counted them, so the row count diverged
            // from reality). resolveOption always returns something.
            return group.liveTimeline(for: profile.id).map { d in
                let opt = venues.resolveOption(for: d)
                let mine = d.profileId == profile.id
                return TimelineEntry(
                    id: d.id,
                    optionName: d.drinkName,
                    detail: opt.detail,
                    option: opt,
                    consumedAt: d.createdAt,
                    isShared: d.shared,
                    // Personal drinks: removable. Shared rounds: also removable
                    // (anyone can wind them back since they affect everyone).
                    // Other members' personal drinks: not yours to delete.
                    removable: mine || d.shared
                )
            }
        } else {
            return live.drinks
                .sorted { $0.consumedAt > $1.consumedAt }
                .map { d in
                    TimelineEntry(
                        id: d.id,
                        optionName: d.optionName,
                        detail: d.detail,
                        option: d.option(),
                        consumedAt: d.consumedAt,
                        isShared: false,
                        removable: true
                    )
                }
        }
    }

    private func timelineSection(now: Date) -> some View {
        let entries = timelineEntries()
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(inGroup ? "YOUR TIMELINE" : "YOUR TIMELINE")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(Color.bronze)
                Spacer()
                Text("\(entries.count) \(entries.count == 1 ? "drink" : "drinks")")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(Color.cream.opacity(0.55))
            }

            if entries.isEmpty {
                emptyTimeline
            } else {
                VStack(spacing: 8) {
                    ForEach(entries) { entry in
                        DrinkTimelineRow(entry: entry, now: now) {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                                removeDrink(id: entry.id)
                            }
                        }
                    }
                }
            }
        }
    }

    private var emptyTimeline: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nothing yet")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(Color.cream)
            Text("Tap a drink below the moment you take your first sip. Each one is timestamped — your BAC and time-to-sober update from there.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.cream.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    Color.whiskey.opacity(0.18),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                )
        )
    }

    // MARK: quick-add dock

    private var quickAddDock: some View {
        VStack(spacing: 10) {
            // Share-mode toggle: only visible in a group. Lets the user
            // switch quick-add behaviour between "just me" and "shared
            // round" without having to dive into the menu sheet.
            if inGroup {
                LiveShareModePicker(shareMode: $shareMode, memberCount: group.members.count)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            HStack(spacing: 8) {
                ForEach(quickAdd, id: \.name) { option in
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                            logDrink(option)
                        }
                    } label: {
                        VStack(spacing: 6) {
                            ZStack(alignment: .topTrailing) {
                                DrinkGlyph(option: option, size: 22)
                                    .frame(width: 36, height: 36)
                                    .background(Circle().fill(Color.whiskey.opacity(shareModeActive ? 0.22 : 0.14)))
                                    .overlay(Circle().strokeBorder(Color.whiskey.opacity(shareModeActive ? 0.7 : 0.35), lineWidth: 1))
                                if shareModeActive {
                                    Image(systemName: "person.2.fill")
                                        .font(.system(size: 7.5, weight: .bold))
                                        .foregroundStyle(Color.ink)
                                        .frame(width: 14, height: 14)
                                        .background(Circle().fill(Color.whiskey))
                                        .offset(x: 4, y: -2)
                                }
                            }
                            Text(option.name.uppercased())
                                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                .tracking(0.8)
                                .foregroundStyle(Color.cream.opacity(0.78))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(shareModeActive ? Color.whiskey.opacity(0.10) : Color.cream.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(
                                    shareModeActive ? Color.whiskey.opacity(0.45) : Color.cream.opacity(0.08),
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(PressScaleStyle())
                }
            }
            Button {
                menuOpen = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: shareModeActive ? "person.2.fill" : "plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.ink)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.whiskey))
                    Text(shareModeActive ? "MORE SHARED DRINKS" : "MORE DRINKS")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(2.0)
                        .foregroundStyle(Color.cream)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.bronze)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.whiskey.opacity(shareModeActive ? 0.18 : 0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.whiskey.opacity(shareModeActive ? 0.55 : 0.4), lineWidth: 1)
                )
            }
            .buttonStyle(PressScaleStyle())
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 18)
        .background(
            LinearGradient(
                colors: [Color.ink.opacity(0.0), Color.ink.opacity(0.85), Color.ink],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: shareMode)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: inGroup)
    }

    /// True when the share-mode treatment should apply — only meaningful
    /// in a group session, suppressed in solo mode even if the toggle
    /// lingered in state from a prior group sesh.
    private var shareModeActive: Bool { inGroup && shareMode }

    // MARK: helpers

    private func statusFor(bac: Double) -> Status {
        switch bac {
        case ..<0.02: return .sober
        case 0.02..<0.05: return .buzzed
        case 0.05..<0.08: return .impaired
        case 0.08..<0.15: return .drunk
        default: return .danger
        }
    }

    private func elapsedString(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "Started \(h)h \(m)m ago" }
        return "Started \(m)m ago"
    }

    private func formatDuration(_ hours: Double) -> String {
        guard hours > 0 else { return "Sober" }
        let mins = Int((hours * 60).rounded())
        if mins < 60 { return "\(mins) min" }
        let h = mins / 60, m = mins % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}

// MARK: - Live Share Mode Picker

/// Two-segment toggle shown in the Live Sesh dock when the user is in a
/// group. Decides whether new drinks added from the dock go onto the
/// user's personal tab ("JUST ME") or into the shared round pool that
/// gets split across everyone ("SHARED"). The shared segment surfaces
/// the split arithmetic ("÷ N") so users see what shared actually means.
private struct LiveShareModePicker: View {
    @Binding var shareMode: Bool
    let memberCount: Int

    var body: some View {
        HStack(spacing: 0) {
            segment(
                title: "JUST ME",
                icon: "person.fill",
                active: !shareMode,
                trailing: nil
            ) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                    shareMode = false
                }
            }
            segment(
                title: "SHARED",
                icon: "person.2.fill",
                active: shareMode,
                trailing: memberCount > 1 ? "÷\(memberCount)" : nil
            ) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                    shareMode = true
                }
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.cream.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    shareMode ? Color.whiskey.opacity(0.5) : Color.cream.opacity(0.08),
                    lineWidth: 1
                )
        )
    }

    private func segment(
        title: String,
        icon: String,
        active: Bool,
        trailing: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                Text(title)
                    .font(.system(size: 10.5, weight: .black, design: .monospaced))
                    .tracking(1.6)
                if let t = trailing {
                    Text(t)
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        .opacity(0.75)
                }
            }
            .foregroundStyle(active ? Color.ink : Color.cream.opacity(0.6))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(active ? Color.whiskey : Color.clear)
            )
        }
        .buttonStyle(PressScaleStyle())
    }
}

// MARK: - Live Group Roster (drunkest first, with leader crown)

/// Group leaderboard for the live experience. Sorts by per-drink Widmark BAC
/// (drunkest first), so the leader bubbles to the top and the roast card
/// below has a clear target. Each row ticks live via the shared `now` Date.
private struct LiveGroupRoster: View {
    @ObservedObject var group: SessionService
    let selfId: UUID
    let now: Date

    fileprivate struct Row: Identifiable {
        let id: UUID
        let profile: Profile?
        let bac: Double
        let drinkCount: Int
        let isSelf: Bool
        let isHost: Bool
    }

    private var rows: [Row] {
        group.members.map { m in
            Row(
                id: m.profileId,
                profile: group.memberProfiles[m.profileId],
                bac: group.liveBAC(for: m.profileId, now: now),
                drinkCount: group.totalDrinkCount(for: m.profileId),
                isSelf: m.profileId == selfId,
                isHost: group.session?.hostId == m.profileId
            )
        }
        .sorted { a, b in
            if a.bac != b.bac { return a.bac > b.bac }
            // Tie-breaker: more drinks first, then self last so the leader
            // is unambiguous when nobody is drinking.
            if a.drinkCount != b.drinkCount { return a.drinkCount > b.drinkCount }
            return !a.isSelf && b.isSelf
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("THE GROUP · LIVE")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(Color.bronze)
                Spacer()
                Text("\(group.members.count) \(group.members.count == 1 ? "person" : "people")")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(Color.cream.opacity(0.55))
            }

            VStack(spacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                    LiveRosterRow(row: row, rank: idx, isLeader: idx == 0 && row.bac > 0)
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.cream.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.cream.opacity(0.07), lineWidth: 1)
        )
    }
}

private struct LiveRosterRow: View {
    let row: LiveGroupRoster.Row
    let rank: Int
    let isLeader: Bool

    private var status: Status {
        switch row.bac {
        case ..<0.02: return .sober
        case 0.02..<0.05: return .buzzed
        case 0.05..<0.08: return .impaired
        case 0.08..<0.15: return .drunk
        default: return .danger
        }
    }

    private var name: String { row.profile?.name ?? "Guest" }
    private var initial: String { String(name.prefix(1)).uppercased() }

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .topTrailing) {
                AvatarView(urlString: row.profile?.avatarURL, initial: initial, size: 38)
                    .overlay(
                        Circle()
                            .strokeBorder(isLeader ? Color.whiskey : Color.clear, lineWidth: 2)
                    )
                if isLeader {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.whiskey)
                        .padding(3)
                        .background(Circle().fill(Color.ink))
                        .offset(x: 4, y: -4)
                        .shadow(color: Color.whiskey.opacity(0.5), radius: 6)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.cream)
                        .lineLimit(1)
                    if row.isSelf {
                        Text("YOU")
                            .font(.system(size: 8.5, weight: .black, design: .monospaced))
                            .tracking(1.4)
                            .foregroundStyle(Color.ink)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.whiskey))
                    } else if row.isHost {
                        Text("HOST")
                            .font(.system(size: 8.5, weight: .black, design: .monospaced))
                            .tracking(1.4)
                            .foregroundStyle(Color.whiskey)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .overlay(Capsule().strokeBorder(Color.whiskey.opacity(0.6), lineWidth: 1))
                    }
                }

                GeometryReader { geo in
                    let fraction = min(max(row.bac / 0.20, 0), 1)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.cream.opacity(0.08))
                        Capsule()
                            .fill(status.color)
                            .frame(width: geo.size.width * CGFloat(fraction))
                            .shadow(color: status.color.opacity(0.5), radius: 4)
                    }
                }
                .frame(height: 4)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.3f", row.bac))
                    .font(.system(size: 16, weight: .black, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: row.bac))
                Text("\(row.drinkCount) \(row.drinkCount == 1 ? "drink" : "drinks")")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(status.color)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isLeader ? Color.whiskey.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isLeader ? Color.whiskey.opacity(0.45) : Color.cream.opacity(0.06),
                    lineWidth: 1
                )
        )
    }
}

// MARK: - Ghost roster (manually-added members in live mode)

/// Section that lists every locally-added ghost member, plus a tappable
/// "+ Add person" affordance. Lives below `LiveGroupRoster` (or stands
/// alone in solo mode) and ticks on the same `now: Date` so BACs update
/// in lockstep with everything else on the page.
///
/// Per-row tap → opens the parent's drink picker scoped to that ghost
/// (the parent owns the sheet because it already owns one for the user's
/// own drinks; reusing it keeps catalog state aligned).
/// Per-row trailing menu → wind back last drink / remove the ghost.
private struct LiveGhostSection: View {
    @ObservedObject var ghosts: GhostMembersStore
    let now: Date
    var onPickDrink: (UUID) -> Void
    var onAddPerson: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("MANUALLY ADDED")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(Color.bronze)
                Spacer()
                if !ghosts.members.isEmpty {
                    Text("\(ghosts.members.count) \(ghosts.members.count == 1 ? "guest" : "guests")")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(Color.cream.opacity(0.55))
                }
            }

            if ghosts.members.isEmpty {
                emptyState
            } else {
                VStack(spacing: 8) {
                    ForEach(ghosts.members) { ghost in
                        LiveGhostRow(
                            ghost: ghost,
                            bac: ghosts.bac(for: ghost, now: now),
                            onTap: { onPickDrink(ghost.id) },
                            onUndo: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                                    ghosts.removeLastDrink(from: ghost.id)
                                }
                            },
                            onRemove: {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                    ghosts.remove(ghost.id)
                                }
                            }
                        )
                    }
                }
            }

            Button(action: onAddPerson) {
                HStack(spacing: 10) {
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.whiskey)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.whiskey.opacity(0.14)))
                        .overlay(Circle().strokeBorder(Color.whiskey.opacity(0.5), lineWidth: 1))
                    Text("ADD PERSON")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(2.0)
                        .foregroundStyle(Color.cream)
                    Spacer()
                    Text("No app needed")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .tracking(1.0)
                        .foregroundStyle(Color.cream.opacity(0.45))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.bronze)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.cream.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            Color.whiskey.opacity(0.35),
                            style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                        )
                )
            }
            .buttonStyle(PressScaleStyle())
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.cream.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.cream.opacity(0.06), lineWidth: 1)
        )
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nobody added yet")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(Color.cream)
            Text("Add the people you're drinking with who don't have the app. Tap their row to log their drinks.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
    }
}

private struct LiveGhostRow: View {
    let ghost: GhostMember
    let bac: Double
    var onTap: () -> Void
    var onUndo: () -> Void
    var onRemove: () -> Void

    private var status: Status {
        switch bac {
        case ..<0.02: return .sober
        case 0.02..<0.05: return .buzzed
        case 0.05..<0.08: return .impaired
        case 0.08..<0.15: return .drunk
        default: return .danger
        }
    }

    private var initial: String { String(ghost.name.prefix(1)).uppercased() }
    private var drinkCount: Int { ghost.drinks.count }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.cream.opacity(0.06))
                            .frame(width: 38, height: 38)
                        Circle()
                            .strokeBorder(
                                Color.whiskey.opacity(0.55),
                                style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])
                            )
                            .frame(width: 38, height: 38)
                        Text(initial)
                            .font(.system(size: 14, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.85))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(ghost.name)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.cream)
                                .lineLimit(1)
                            Text("GUEST")
                                .font(.system(size: 8.5, weight: .black, design: .monospaced))
                                .tracking(1.4)
                                .foregroundStyle(Color.bronze)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .overlay(Capsule().strokeBorder(Color.bronze.opacity(0.55), lineWidth: 1))
                        }
                        GeometryReader { geo in
                            let fraction = min(max(bac / 0.20, 0), 1)
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.cream.opacity(0.08))
                                Capsule()
                                    .fill(status.color)
                                    .frame(width: geo.size.width * CGFloat(fraction))
                                    .shadow(color: status.color.opacity(0.5), radius: 4)
                            }
                        }
                        .frame(height: 4)
                    }

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%.3f", bac))
                            .font(.system(size: 16, weight: .black, design: .rounded))
                            .foregroundStyle(Color.cream)
                            .monospacedDigit()
                            .contentTransition(.numericText(value: bac))
                        Text("\(drinkCount) \(drinkCount == 1 ? "drink" : "drinks")")
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .tracking(1.2)
                            .foregroundStyle(status.color)
                    }
                }
            }
            .buttonStyle(PressScaleStyle())

            // Per-row overflow: undo last drink / remove the ghost.
            // Kept compact so the BAC numeric stays the visual anchor of
            // the row; the menu button is opt-in chrome.
            Menu {
                if drinkCount > 0 {
                    Button {
                        onUndo()
                    } label: {
                        Label("Undo last drink", systemImage: "arrow.uturn.backward")
                    }
                }
                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Label("Remove \(ghost.name)", systemImage: "person.fill.xmark")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.cream.opacity(0.55))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.cream.opacity(0.05)))
                    .overlay(Circle().strokeBorder(Color.cream.opacity(0.08), lineWidth: 1))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.cream.opacity(0.06), lineWidth: 1)
        )
    }
}

// MARK: - Add Person Sheet (creates a ghost member)

/// Form for capturing a ghost member's stats. Modeled on the auth
/// signup form (`SexToggle` + `TintedSlider`) so it feels consistent
/// with how the user entered their own profile. The save button is
/// disabled until there's a non-empty name — everything else has a
/// reasonable default.
private struct AddPersonSheet: View {
    var onSave: (_ name: String, _ sex: Sex, _ age: Int, _ weightKg: Double) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var sex: Sex = .male
    @State private var age: Double = 28
    @State private var weight: Double = 75
    @FocusState private var nameFocused: Bool

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            AtmosphereBackground(accent: Color.whiskey)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    nameField

                    InputRow(
                        kicker: "01",
                        title: "Sex",
                        valueText: sex.short,
                        unit: "",
                        accent: Color.whiskey
                    ) {
                        SexToggle(sex: $sex, accent: Color.whiskey)
                    }

                    InputRow(
                        kicker: "02",
                        title: "Age",
                        valueText: "\(Int(age))",
                        unit: "yrs",
                        accent: Color.whiskey
                    ) {
                        TintedSlider(value: $age, range: 18...80, step: 1, accent: Color.whiskey)
                    }

                    InputRow(
                        kicker: "03",
                        title: "Weight",
                        valueText: "\(Int(weight))",
                        unit: "kg",
                        accent: Color.whiskey
                    ) {
                        TintedSlider(value: $weight, range: 40...160, step: 1, accent: Color.whiskey)
                    }

                    saveButton

                    Text("Stats stay on your phone. We use them to estimate this person's BAC the same way we do yours.")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)

                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 22)
                .padding(.top, 10)
                .padding(.bottom, 28)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { nameFocused = true }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.whiskey)
                        .frame(width: 7, height: 7)
                        .shadow(color: Color.whiskey.opacity(0.8), radius: 5)
                    Text("ADD PERSON")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(2.6)
                        .foregroundStyle(Color.whiskey)
                }
                Text("New guest")
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .italic()
                    .foregroundStyle(Color.cream)
                    .tracking(-0.6)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Text("CANCEL")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(2.0)
                    .foregroundStyle(Color.cream)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.cream.opacity(0.06)))
                    .overlay(Capsule().strokeBorder(Color.cream.opacity(0.2), lineWidth: 1))
            }
            .buttonStyle(PressScaleStyle())
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("00")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(Color.bronze)
                Text("NAME")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(Color.cream.opacity(0.78))
            }
            TextField("", text: $name, prompt: Text("e.g. Alex").foregroundStyle(Color.cream.opacity(0.3)))
                .focused($nameFocused)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled(true)
                .submitLabel(.done)
                .onSubmit { if canSave { commit() } }
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .italic()
                .foregroundStyle(Color.cream)
                .tracking(-0.3)
                .padding(.vertical, 12)
                .padding(.horizontal, 4)
                .overlay(
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [Color.whiskey, Color.whiskey.opacity(0.2)],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(height: 1)
                        .shadow(color: Color.whiskey.opacity(0.6), radius: 4),
                    alignment: .bottom
                )
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.cream.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.cream.opacity(0.06), lineWidth: 1)
        )
    }

    private var saveButton: some View {
        Button(action: commit) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.ink)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.cream))
                Text("ADD TO LIVE SESH")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .tracking(2.0)
                    .foregroundStyle(Color.ink)
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.ink.opacity(0.55))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(canSave ? Color.whiskey : Color.cream.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.whiskey.opacity(canSave ? 0.6 : 0), lineWidth: 1)
            )
            .shadow(color: Color.whiskey.opacity(canSave ? 0.45 : 0), radius: 18, y: 8)
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!canSave)
        .opacity(canSave ? 1.0 : 0.6)
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed, sex, Int(age), weight)
        dismiss()
    }
}

// MARK: - Live Roast Card (gamified line about the drunkest member)

/// Surfaces a funny line about whoever's currently in the lead. Picks the
/// leader by per-drink BAC (matches the roster), pulls a tier-appropriate
/// roast from `LiveRoastBook`, and rotates within the tier based on the
/// total drink count so the line evolves as the night progresses without
/// flickering on every poll.
private struct LiveRoastCard: View {
    @ObservedObject var group: SessionService
    let profile: Profile
    let now: Date

    private struct Leader {
        let name: String
        let bac: Double
        let isSelf: Bool
    }

    private var totalDrinks: Int {
        group.drinks.count
    }

    private var leader: Leader? {
        let candidates: [Leader] = group.members.compactMap { m in
            let p = group.memberProfiles[m.profileId]
            let n = p?.name ?? "Guest"
            return Leader(
                name: firstName(n),
                bac: group.liveBAC(for: m.profileId, now: now),
                isSelf: m.profileId == profile.id
            )
        }
        return candidates.max(by: { $0.bac < $1.bac })
    }

    private var roast: LiveRoast {
        let seed = totalDrinks + (leader.map { Int($0.bac * 100) } ?? 0)
        guard let lead = leader, lead.bac >= 0.02 else {
            return LiveRoastBook.warmup(seed: seed)
        }
        // Second-person grammar when the user IS the leader, third-person
        // by first name otherwise. Keeps "You're a problem. Hide your phone."
        // from coming out as "You is a problem. Hide their phone."
        let subject: RoastSubject = lead.isSelf ? .you : .name(lead.name)
        return LiveRoastBook.roast(subject: subject, bac: lead.bac, seed: seed)
    }

    private func firstName(_ full: String) -> String {
        full.split(separator: " ").first.map(String.init) ?? full
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.whiskey)
                Text("THE ROAST")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(Color.bronze)
                Spacer()
                if let lead = leader, lead.bac >= 0.02 {
                    Text("LEADER · \(String(format: "%.3f", lead.bac))")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(Color.whiskey)
                }
            }

            Text(roast.headline)
                .font(.system(size: 19, weight: .black, design: .rounded))
                .italic()
                .foregroundStyle(Color.cream)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.whiskey.opacity(0.85))
                    .padding(.top, 3)
                Text(roast.advice)
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.whiskey.opacity(0.16), Color.whiskey.opacity(0.04)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.whiskey.opacity(0.32), lineWidth: 1)
        )
        .shadow(color: Color.whiskey.opacity(0.18), radius: 18, y: 8)
    }
}

// MARK: - Drink Timeline Row

private struct DrinkTimelineRow: View {
    let entry: TimelineEntry
    let now: Date
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            DrinkGlyph(option: entry.option, size: 22)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.smoke))
                .overlay(Circle().strokeBorder(Color.whiskey.opacity(0.25), lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.optionName)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.cream)
                    if entry.isShared {
                        sharedPill
                    }
                }
                Text(entry.detail)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .tracking(0.4)
                    .foregroundStyle(Color.cream.opacity(0.5))
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(entry.consumedAt, format: .dateTime.hour().minute())
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.cream)
                Text(relativeAgo)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(Color.bronze)
                    .contentTransition(.numericText())
            }
            if entry.removable {
                Button(action: onRemove) {
                    Image(systemName: "minus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.cream.opacity(0.6))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.cream.opacity(0.06)))
                        .overlay(Circle().strokeBorder(Color.cream.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(PressScaleStyle())
            } else {
                // Visual placeholder so other-members' rows align with mine.
                Image(systemName: "lock.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.cream.opacity(0.25))
                    .frame(width: 26, height: 26)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.cream.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    entry.isShared ? Color.whiskey.opacity(0.28) : Color.cream.opacity(0.07),
                    lineWidth: 1
                )
        )
    }

    private var sharedPill: some View {
        HStack(spacing: 3) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 7.5, weight: .bold))
            Text("SHARED")
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .tracking(1.0)
        }
        .foregroundStyle(Color.whiskey)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(Color.whiskey.opacity(0.16)))
        .overlay(Capsule().strokeBorder(Color.whiskey.opacity(0.42), lineWidth: 0.8))
    }

    private var relativeAgo: String {
        let seconds = Int(now.timeIntervalSince(entry.consumedAt))
        if seconds < 60 { return "JUST NOW" }
        let m = seconds / 60
        if m < 60 { return "\(m)M AGO" }
        let h = m / 60, mm = m % 60
        return mm == 0 ? "\(h)H AGO" : "\(h)H \(mm)M AGO"
    }
}

// MARK: - Live Menu Sheet (catalog picker, no quantity steppers)

/// Slimmed-down catalog browser for Live Sesh: tap a drink → it's instantly
/// added with the current timestamp, then dismisses. No share/quantity logic
/// because every tap is one drink at "now".
private struct LiveMenuSheet: View {
    /// Specials pinned to the top — only non-empty when checked into a
    /// venue. Each tap fires `onPick` and the sheet dismisses, same as
    /// the regular catalog rows below.
    var venueSpecials: [DrinkOption] = []
    var venueName: String? = nil
    let onPick: (DrinkOption) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedCategory: DrinkCategory = .beer

    private var specialsHeader: String {
        if let n = venueName, !n.isEmpty { return "Specials at \(n)" }
        return "Specials"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Pick a drink")
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .padding(.top, 14)

                if !venueSpecials.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9, weight: .black))
                                .foregroundStyle(Color.whiskey)
                            Text(specialsHeader.uppercased())
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .tracking(2.4)
                                .foregroundStyle(Color.whiskey)
                            Rectangle()
                                .fill(Color.whiskey.opacity(0.25))
                                .frame(height: 1)
                        }
                        VStack(spacing: 8) {
                            ForEach(venueSpecials, id: \.name) { option in
                                Button {
                                    onPick(option)
                                } label: {
                                    HStack(spacing: 12) {
                                        DrinkGlyph(option: option, size: 24)
                                            .frame(width: 40, height: 40)
                                            .background(Circle().fill(Color.smoke))
                                            .overlay(Circle().strokeBorder(Color.whiskey.opacity(0.55), lineWidth: 1))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(option.name)
                                                .font(.system(size: 15, weight: .heavy, design: .rounded))
                                                .foregroundStyle(Color.cream)
                                            Text(option.detail)
                                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                                .tracking(0.4)
                                                .foregroundStyle(Color.cream.opacity(0.55))
                                        }
                                        Spacer()
                                        Image(systemName: "plus")
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(Color.ink)
                                            .frame(width: 30, height: 30)
                                            .background(Circle().fill(Color.whiskey))
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .fill(Color.whiskey.opacity(0.10))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .strokeBorder(Color.whiskey.opacity(0.45), lineWidth: 1)
                                    )
                                }
                                .buttonStyle(PressScaleStyle())
                            }
                        }
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(DrinkCategory.allCases) { cat in
                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    selectedCategory = cat
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    // Default body font is ~17pt; size 26
                                    // gives matching optical size for the
                                    // custom icon (gin) inline with text.
                                    categoryGlyph(cat, size: 26)
                                    Text(cat.label.uppercased())
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .tracking(1.4)
                                }
                                .foregroundStyle(selectedCategory == cat ? Color.ink : Color.cream.opacity(0.7))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule().fill(selectedCategory == cat ? Color.whiskey : Color.cream.opacity(0.06))
                                )
                                .overlay(
                                    Capsule().strokeBorder(Color.cream.opacity(0.08), lineWidth: 1)
                                )
                            }
                            .buttonStyle(PressScaleStyle())
                        }
                    }
                    .padding(.horizontal, 22)
                }
                .padding(.horizontal, -22)

                VStack(spacing: 8) {
                    ForEach(DrinkCatalog.options(for: selectedCategory), id: \.name) { option in
                        Button {
                            onPick(option)
                        } label: {
                            HStack(spacing: 12) {
                                DrinkGlyph(option: option, size: 24)
                                    .frame(width: 40, height: 40)
                                    .background(Circle().fill(Color.smoke))
                                    .overlay(Circle().strokeBorder(Color.whiskey.opacity(0.25), lineWidth: 1))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.name)
                                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                                        .foregroundStyle(Color.cream)
                                    Text(option.detail)
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .tracking(0.4)
                                        .foregroundStyle(Color.cream.opacity(0.5))
                                }
                                Spacer()
                                Image(systemName: "plus")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(Color.ink)
                                    .frame(width: 30, height: 30)
                                    .background(Circle().fill(Color.whiskey))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color.cream.opacity(0.035))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(Color.cream.opacity(0.07), lineWidth: 1)
                            )
                        }
                        .buttonStyle(PressScaleStyle())
                    }
                }

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 28)
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Share Mode Picker

private struct ShareModePicker: View {
    @Binding var shareMode: Bool

    var body: some View {
        HStack(spacing: 0) {
            segment(title: "JUST ME", icon: "person.fill", active: !shareMode) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                    shareMode = false
                }
            }
            segment(title: "SHARE", icon: "person.2.fill", active: shareMode) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                    shareMode = true
                }
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.cream.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.cream.opacity(0.08), lineWidth: 1)
        )
    }

    private func segment(title: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                Text(title)
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .tracking(1.8)
            }
            .foregroundStyle(active ? Color.ink : Color.cream.opacity(0.6))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(active ? Color.whiskey : Color.clear)
            )
        }
        .buttonStyle(PressScaleStyle())
    }
}

