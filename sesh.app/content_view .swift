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
    /// Unique @handle (lowercased) used to find + friend this user. Nil until
    /// the user picks one. Added in migration 018.
    var username: String?

    enum CodingKeys: String, CodingKey {
        case id, name, age, sex, username
        case weightKg = "weight_kg"
        case avatarURL = "avatar_url"
    }

    /// Tolerate rows that predate the username column.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        age = try c.decode(Int.self, forKey: .age)
        sex = try c.decode(Sex.self, forKey: .sex)
        weightKg = try c.decode(Double.self, forKey: .weightKg)
        avatarURL = try c.decodeIfPresent(String.self, forKey: .avatarURL)
        username = try c.decodeIfPresent(String.self, forKey: .username)
    }

    /// Explicit memberwise init (the custom decoder init suppresses the
    /// synthesized one). username defaults to nil for existing call sites.
    init(id: UUID, name: String, age: Int, sex: Sex, weightKg: Double,
         avatarURL: String? = nil, username: String? = nil) {
        self.id = id
        self.name = name
        self.age = age
        self.sex = sex
        self.weightKg = weightKg
        self.avatarURL = avatarURL
        self.username = username
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

// Internal (not fileprivate) so sibling files in the app target — e.g.
// BarcodeScanner.swift — can use the same palette without duplicating the
// hex values. The widget extension is a separate module and keeps its own
// local copy.
extension Color {
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
    /// Manually-added guests for this session, synced via the JSONB
    /// `ghosts` column (migration 011). Lets every device in a group see
    /// the same guest roster + their drinks. Defaults to [] for legacy
    /// rows / environments that haven't run the migration.
    var ghosts: [GhostMember]
    /// The group's shared current venue (migration 016). Set when a member
    /// checks the whole group in; nil = the group is checked out. Members
    /// who are "following the group" adopt it. Default nil for legacy rows.
    var liveVenue: Venue? = nil
    /// The group's shared pre-game / between-bars location (migration 017),
    /// adopted by following members. nil = none.
    var liveLooseSpot: LooseSpot? = nil
    enum CodingKeys: String, CodingKey {
        case id
        case hostId = "host_id"
        case joinCode = "join_code"
        case createdAt = "created_at"
        case active
        case activePlan = "active_plan"
        case activeLive = "active_live"
        case ghosts
        case liveVenue = "live_venue"
        case liveLooseSpot = "live_loose_spot"
    }
    init(
        id: UUID,
        hostId: UUID,
        joinCode: String,
        createdAt: Date,
        active: Bool,
        activePlan: Bool = true,
        activeLive: Bool = true,
        ghosts: [GhostMember] = []
    ) {
        self.id = id
        self.hostId = hostId
        self.joinCode = joinCode
        self.createdAt = createdAt
        self.active = active
        self.activePlan = activePlan
        self.activeLive = activeLive
        self.ghosts = ghosts
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
        self.ghosts = (try c.decodeIfPresent([GhostMember].self, forKey: .ghosts)) ?? []
        self.liveVenue = try c.decodeIfPresent(Venue.self, forKey: .liveVenue)
        self.liveLooseSpot = try c.decodeIfPresent(LooseSpot.self, forKey: .liveLooseSpot)
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

/// A promotional OFFER at a venue — surfaced on the "deals near you" map
/// (Phase A) and, later, at check-in. Marketing, not a menu item: unlike
/// VenueSpecial it never feeds the BAC math. See migration 029_venue_offers.
/// Only the display columns are decoded; RLS already filters the table to
/// live (active + approved + unexpired) offers, so the client trusts what it
/// gets.
struct VenueOffer: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let venueId: UUID
    let kind: String            // price | free_entry | bundle | happy_hour | event
    let title: String
    let description: String?
    let finePrint: String?
    let redeem: String          // show | code | scan
    let code: String?
    let startMinute: Int?       // local minutes from midnight; nil = all day
    let endMinute: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case venueId     = "venue_id"
        case kind, title, description
        case finePrint   = "fine_print"
        case redeem, code
        case startMinute = "start_minute"
        case endMinute   = "end_minute"
    }

    /// SF Symbol for the offer kind — drives the pin/row glyph.
    var glyph: String {
        switch kind {
        case "free_entry": return "ticket.fill"
        case "happy_hour": return "clock.fill"
        case "bundle":     return "gift.fill"
        case "event":      return "music.note"
        default:           return "tag.fill"      // price
        }
    }

    /// "16:00–19:00" window, or nil when the offer runs all day.
    var windowLabel: String? {
        guard let s = startMinute, let e = endMinute,
              !(s == 0 && e >= 24 * 60 - 1) else { return nil }
        func hhmm(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }
        return "\(hhmm(s))–\(hhmm(e))"
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
    case emailAlreadyRegistered
    case invalidLogin

    var errorDescription: String? {
        switch self {
        case .emailConfirmationRequired:
            return "Check your email to confirm the account, then sign in."
        case .profileMissing:
            return "We couldn't find your profile. Try signing up again."
        case .emailAlreadyRegistered:
            return "This email already has an account. Try signing in instead."
        case .invalidLogin:
            return "Wrong username/email or password."
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

    /// Stashed sign-up details, kept between requesting the email code and
    /// verifying it (when email confirmation is on and there's no session yet).
    private struct PendingSignUp {
        let email: String
        let password: String
        let name: String
        let username: String
        let age: Int
        let sex: Sex
        let weightKg: Double
        let avatarData: Data?
    }
    private var pendingSignUp: PendingSignUp?

    /// True while we're verifying a code + inserting the profile. The auth
    /// state listener checks this so it doesn't briefly flip to .signedOut
    /// when it sees the new session before the profile row exists.
    private var profileCreationInFlight = false

    /// Result of a sign-up attempt.
    enum SignUpOutcome { case completed, needsEmailCode }

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
            // A sign-up confirmation is mid-flight (session exists but the
            // profile row hasn't been inserted yet) — let confirmSignUp drive
            // the state instead of prematurely flipping to .signedOut.
            if profileCreationInFlight { return }
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

    /// Create the auth user. If email confirmation is on (no session yet),
    /// stash the profile details and signal that a 6-digit code is needed;
    /// confirmSignUp finishes the job once the code is verified. If
    /// confirmation is off, the profile is created immediately.
    @discardableResult
    func signUp(email: String, password: String, name: String, username: String, age: Int, sex: Sex, weightKg: Double, avatarData: Data? = nil) async throws -> SignUpOutcome {
        let cleanEmail = email.trimmingCharacters(in: .whitespaces).lowercased()
        let response = try await supabase.auth.signUp(email: cleanEmail, password: password)
        let pending = PendingSignUp(email: cleanEmail, password: password, name: name,
                                    username: username.trimmingCharacters(in: .whitespaces).lowercased(),
                                    age: age, sex: sex, weightKg: weightKg, avatarData: avatarData)
        if response.session != nil {
            try await createProfile(userId: response.user.id, from: pending)
            return .completed
        }
        // Anti-enumeration: when the email already belongs to a registered
        // account, Supabase returns an obfuscated user with NO identities and
        // no session (rather than erroring). Surface that as a clear message
        // instead of dead-ending on the confirm-code screen.
        if let identities = response.user.identities, identities.isEmpty {
            throw AuthError.emailAlreadyRegistered
        }
        pendingSignUp = pending
        return .needsEmailCode
    }

    /// Verify the emailed 6-digit signup code, then — now that we have a
    /// session — create the profile and sign the user in.
    func confirmSignUp(code: String) async throws {
        guard let pending = pendingSignUp else { throw AuthError.profileMissing }
        try await supabase.auth.verifyOTP(
            email: pending.email,
            token: code.trimmingCharacters(in: .whitespaces),
            type: .signup
        )
        guard let userId = supabase.auth.currentUser?.id else { throw AuthError.profileMissing }
        try await createProfile(userId: userId, from: pending)
        pendingSignUp = nil
    }

    /// Re-send the signup confirmation email (Supabase resends for an
    /// existing unconfirmed user when signUp is called again).
    func resendSignUpCode() async throws {
        guard let pending = pendingSignUp else { return }
        _ = try await supabase.auth.signUp(email: pending.email, password: pending.password)
    }

    /// Insert the profile row + optional avatar and flip to signed-in. Shared
    /// by the confirmation-off and code-verified paths.
    private func createProfile(userId: UUID, from p: PendingSignUp) async throws {
        profileCreationInFlight = true
        defer { profileCreationInFlight = false }

        let avatarURL = try? await uploadAvatar(data: p.avatarData, userId: userId)

        struct InsertProfile: Encodable {
            let id: String
            let name: String
            let username: String?
            let age: Int
            let sex: String
            let weight_kg: Double
            let avatar_url: String?
        }

        let payload = InsertProfile(
            id: userId.uuidString.lowercased(),
            name: p.name,
            username: p.username.isEmpty ? nil : p.username,
            age: p.age,
            sex: p.sex.rawValue,
            weight_kg: p.weightKg,
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

    /// Live username-availability check for the sign-up form (works while
    /// signed out — the RPC is granted to anon). Returns true only for a
    /// well-formed, unclaimed username.
    func isUsernameAvailable(_ username: String) async -> Bool {
        struct P: Encodable { let p_username: String }
        do {
            return try await supabase
                .rpc("username_available", params: P(p_username: username))
                .execute().value
        } catch {
            return false
        }
    }

    /// Sign in with a @username instead of email. The `username-login` Edge
    /// Function resolves the email server-side (never exposed) and returns
    /// session tokens, which we install locally.
    func signInWithUsername(username: String, password: String) async throws {
        struct Body: Encodable { let username: String; let password: String }
        struct Resp: Decodable { let access_token: String?; let refresh_token: String? }
        let resp: Resp
        do {
            resp = try await supabase.functions.invoke(
                "username-login",
                options: FunctionInvokeOptions(body: Body(
                    username: username.trimmingCharacters(in: .whitespaces),
                    password: password
                ))
            )
        } catch {
            // 400 from the function (bad username/password) surfaces here.
            throw AuthError.invalidLogin
        }
        guard let at = resp.access_token, let rt = resp.refresh_token else {
            throw AuthError.invalidLogin
        }
        let session = try await supabase.auth.setSession(accessToken: at, refreshToken: rt)
        let profile = try await loadProfile(userId: session.user.id)
        state = .signedIn(profile)
    }

    /// Step 1 of password recovery: email the user a 6-digit recovery code.
    /// (The Supabase "Reset Password" email template must include `{{ .Token }}`
    /// for the code to be delivered.) We don't reveal whether the email exists.
    func sendPasswordReset(email: String) async throws {
        try await supabase.auth.resetPasswordForEmail(
            email.trimmingCharacters(in: .whitespaces).lowercased()
        )
    }

    /// Step 2 of password recovery: verify the emailed code, which yields a
    /// short-lived recovery session, then set the new password. On success the
    /// user is signed in with the new password (authStateChanges → .signedIn).
    func confirmPasswordReset(email: String, code: String, newPassword: String) async throws {
        try await supabase.auth.verifyOTP(
            email: email.trimmingCharacters(in: .whitespaces).lowercased(),
            token: code.trimmingCharacters(in: .whitespaces),
            type: .recovery
        )
        try await supabase.auth.update(user: UserAttributes(password: newPassword))
    }

    /// Set / change the signed-in user's @username via the migration-018 RPC.
    /// Returns nil on success, or a short user-facing error string.
    func setUsername(_ username: String) async -> String? {
        struct P: Encodable { let p_username: String }
        struct R: Decodable { let ok: Bool; let username: String?; let reason: String? }
        do {
            let r: R = try await supabase
                .rpc("set_username", params: P(p_username: username))
                .execute().value
            if r.ok {
                if case .signedIn(var p) = state {
                    p.username = r.username
                    state = .signedIn(p)
                }
                return nil
            }
            switch r.reason {
            case "taken":   return "That username is taken."
            case "invalid": return "3–20 chars: lowercase letters, numbers, underscore."
            default:        return "Couldn't save username."
            }
        } catch {
            return "Couldn't save username."
        }
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
    /// Manually-added guests, synced across every device in this session
    /// via the session row's JSONB `ghosts` column. Mirrored into the
    /// device-local GhostMembersStore by SessionView while a live group
    /// is active. Empty when there's no session.
    @Published var ghosts: [GhostMember] = []
    /// True while a guest-roster write is in flight, so a concurrent poll
    /// doesn't overwrite the optimistic local value with stale server data.
    private var ghostWriteInFlight = false
    /// The group's shared current venue (synced from `session.live_venue`).
    /// nil = the group is checked out.
    @Published var liveVenue: Venue? = nil
    /// Whether THIS device follows the group's location. Local + per-device:
    /// true (default) ⇒ adopt group check-ins; false ⇒ "broke away", manage
    /// my own venue. Reset to true on join.
    @Published var followingGroupVenue = true
    private var liveVenueWriteInFlight = false
    /// The group's shared pre-game / between location (synced).
    @Published var liveLooseSpot: LooseSpot? = nil
    private var liveLooseSpotWriteInFlight = false
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
    /// Total heads a shared round is split across — real members PLUS
    /// manually-added guests. Guests drink too, so a shared "round of
    /// shots" has to divide by everyone present, not just app users.
    private var sharedHeadCount: Int {
        max(members.count + ghosts.count, 1)
    }

    func liveBAC(for profileId: UUID, now: Date = Date()) -> Double {
        guard let profile = memberProfiles[profileId] else { return 0 }
        let bodyGrams = profile.weightKg * 1000
        let denom = bodyGrams * profile.sex.r
        guard denom > 0 else { return 0 }
        let n = sharedHeadCount

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

    /// The member's live drinks projected to timestamped recap events —
    /// the same (timestamp, grams-to-me) reduction `liveBAC` runs, plus
    /// the drink name for the recap's per-stop summaries. Shared rounds
    /// contribute their per-head share, exactly like the BAC math.
    func myLiveRecapEvents(for profileId: UUID) -> [RecapEvent] {
        myLiveRecapEvents(
            from: drinks, memberCount: members.count, ghostCount: ghosts.count, for: profileId
        )
    }

    /// Same projection from EXPLICIT inputs — used when a live group sesh
    /// is detected as ended mid-poll, before the freshly-fetched roster
    /// has been assigned to `self` (so `members`/`drinks` aren't current).
    func myLiveRecapEvents(
        from sourceDrinks: [SessionDrink],
        memberCount: Int,
        ghostCount: Int,
        for profileId: UUID
    ) -> [RecapEvent] {
        let n = max(memberCount + ghostCount, 1)
        return sourceDrinks.filter { $0.live }.compactMap { d in
            let isMine = d.profileId == profileId && !d.shared
            guard isMine || d.shared else { return nil }
            let grams = d.shared ? d.grams / Double(n) : d.grams
            return RecapEvent(when: d.createdAt, grams: grams, name: d.drinkName)
        }.sorted { $0.when < $1.when }
    }

    /// Handoff for the auto-recap: set to the user's projected events the
    /// instant a LIVE group sesh ends (host ended, self left, or kicked),
    /// just before `clearLocal` wipes the roster. SessionView observes
    /// this, builds + presents the recap, then resets it to nil. Only
    /// ever non-empty for the live-scope store.
    @Published var endedLiveEvents: [RecapEvent]? = nil
    /// The squad's per-member stats captured at the same instant, for the
    /// group recap's leaderboard. Nil for a solo sesh / single member.
    @Published var endedGroupLeaderboard: [GroupMemberStat]? = nil
    /// Raw materials for the SQUAD recap, captured at the same instant:
    /// the whole session ledger + everyone's profile, so SessionView can
    /// compute per-stop member stats and fetch the squad schnaps. Nil for
    /// solo nights / single-member groups.
    @Published var endedGroupContext: EndedGroupContext? = nil

    struct EndedGroupContext {
        let sessionId: UUID
        let drinks: [SessionDrink]
        let profiles: [UUID: Profile]
        let headCount: Int
        /// When the group was created — the group recap only tells the
        /// story from here on; anything a member logged before joining
        /// belongs to their INDIVIDUAL recap alone.
        let sessionStart: Date
        /// Host id — when several members logged the same marker, the
        /// host's naming wins in the group recap.
        let hostId: UUID?
    }

    /// True only when the session was just entered by the user tapping
    /// join/create — as opposed to resumeIfAny restoring it on launch.
    /// SessionView's session observer reads (and resets) this to decide
    /// whether to carry the solo night in: carrying on a mere resume
    /// would dump leftover solo drinks into the group on every relaunch.
    var entryWasUserInitiated = false
    /// Bumped whenever THIS device's live night TERMINALLY ends — host end,
    /// my end, poll-detected end, ended-while-away — but never on a
    /// keep-night leave or a group→group switch (those don't capture).
    /// SessionView observes it to check out of the current venue, even when
    /// no recap is produced (a drink-free night still leaves you "here"
    /// otherwise).
    @Published var liveEndedToken = 0

    /// The group's server-side route (session_stops), refreshed on every
    /// poll. SessionView merges it into the local journey so EVERY member
    /// sees every group stop live — check-ins, between-bars, food, puke,
    /// pre-game — not just the ones their own device witnessed.
    @Published var routeStops: [RouteStopRow] = []

    struct RouteStopRow: Decodable, Equatable {
        let id: UUID
        let name: String
        let lat: Double?
        let lon: Double?
        let kind: String
        let arrivedAt: Date
        let departedAt: Date?
        let profileId: UUID?
        enum CodingKeys: String, CodingKey {
            case id, name, lat, lon, kind
            case arrivedAt = "arrived_at"
            case departedAt = "departed_at"
            case profileId = "profile_id"
        }
    }

    /// Snapshot my events before a live-end clears them. No-op for the
    /// plan store, or when I logged nothing worth replaying.
    private func captureLiveEnd(
        drinks sourceDrinks: [SessionDrink],
        members memberList: [SessionMember],
        ghosts ghostList: [GhostMember],
        sessionIdOverride: UUID? = nil,
        sessionRowOverride: SeshSession? = nil
    ) {
        guard scopeLive, let uid = myId else { return }
        let memberCount = memberList.count
        let ghostCount = ghostList.count
        let events = myLiveRecapEvents(
            from: sourceDrinks, memberCount: memberCount, ghostCount: ghostCount, for: uid
        )
        if !events.isEmpty { endedLiveEvents = events }

        // The squad leaderboard — each member's peak BAC + drink count, for
        // the group recap. Only meaningful with 2+ heads.
        var board: [GroupMemberStat] = []
        for m in memberList {
            guard let p = memberProfiles[m.profileId] else { continue }
            let denom = p.weightKg * 1000 * p.sex.r
            guard denom > 0 else { continue }
            let evs = myLiveRecapEvents(
                from: sourceDrinks, memberCount: memberCount, ghostCount: ghostCount, for: m.profileId
            )
            board.append(GroupMemberStat(
                name: p.name,
                drinkCount: evs.count,
                peakBAC: Self.peakBAC(of: evs, bumpPerGram: 100 / denom),
                isMe: m.profileId == uid
            ))
        }
        for g in ghostList {
            let denom = g.weightKg * 1000 * g.sex.r
            guard denom > 0 else { continue }
            let evs = ghostRecapEvents(g, sharedDrinks: sourceDrinks, headCount: max(memberCount + ghostCount, 1))
            board.append(GroupMemberStat(
                name: g.name,
                drinkCount: evs.count,
                peakBAC: Self.peakBAC(of: evs, bumpPerGram: 100 / denom),
                isMe: false
            ))
        }
        if board.count >= 2 {
            endedGroupLeaderboard = board.sorted { $0.peakBAC > $1.peakBAC }
        }
        // Hand the raw ledger to SessionView so it can build the squad
        // recap (per-stop stats + schnap downloads). Must happen before
        // clearLocal wipes session/drinks/profiles.
        if memberCount >= 2, let sid = sessionIdOverride ?? session?.id {
            let row = sessionRowOverride ?? session
            endedGroupContext = EndedGroupContext(
                sessionId: sid,
                drinks: sourceDrinks,
                profiles: memberProfiles,
                headCount: max(memberCount + ghostCount, 1),
                sessionStart: row?.createdAt ?? .distantPast,
                hostId: row?.hostId
            )
        }
        // Terminal end → tell SessionView to check out, whether or not
        // there was anything to recap. (Switches never reach here — they
        // release the old group without capturing.)
        liveEndedToken &+= 1
    }

    /// The session ended while this device was away (app closed, or the
    /// user signed out) — the poll never saw the end, so no recap was ever
    /// captured. Pull the final ledger straight from the DB, hand off the
    /// recap materials, and release my membership flag so the next launch
    /// doesn't deliver the same night twice.
    private func captureEndedWhileAway(_ row: SeshSession) async {
        guard scopeLive, let uid = myId else { return }
        let sid = row.id.uuidString.lowercased()
        // The FULL roster, not just in_live=true: the session is over, and
        // other devices' own captures release their flags as they deliver —
        // filtering would shrink the leaderboard for whoever captures last.
        let ms: [SessionMember] = (try? await supabase.from("session_members")
            .select()
            .eq("session_id", value: sid)
            .execute()
            .value) ?? []
        let ds: [SessionDrink] = (try? await supabase.from("session_drinks")
            .select()
            .eq("session_id", value: sid)
            .execute()
            .value) ?? []
        let ids = ms.map { $0.profileId.uuidString.lowercased() }
        if !ids.isEmpty,
           let ps: [Profile] = try? await supabase.from("profiles")
            .select()
            .in("id", values: ids)
            .execute()
            .value {
            for p in ps { memberProfiles[p.id] = p }
        }
        captureLiveEnd(drinks: ds, members: ms, ghosts: row.ghosts,
                       sessionIdOverride: row.id, sessionRowOverride: row)
        // Delivered — flip my flag so the fallback scan stops finding it.
        struct InLivePatch: Encodable { let in_live: Bool }
        _ = try? await supabase.from("session_members")
            .update(InLivePatch(in_live: false))
            .eq("session_id", value: sid)
            .eq("profile_id", value: uid.uuidString.lowercased())
            .execute()
        memberProfiles = [:]
    }

    /// Peak of a chronological Widmark walk over the given events.
    private static func peakBAC(of events: [RecapEvent], bumpPerGram: Double) -> Double {
        let sorted = events.sorted { $0.when < $1.when }
        var bac = 0.0, peak = 0.0
        var last: Date? = nil
        for e in sorted {
            if let l = last { bac = max(0, bac - 0.015 * (e.when.timeIntervalSince(l) / 3600)) }
            bac += e.grams * bumpPerGram
            last = e.when
            peak = max(peak, bac)
        }
        return peak
    }

    /// A guest's recap events — their own logged drinks + their per-head
    /// share of shared rounds.
    private func ghostRecapEvents(_ ghost: GhostMember, sharedDrinks: [SessionDrink], headCount n: Int) -> [RecapEvent] {
        var evs: [RecapEvent] = ghost.drinks.map {
            RecapEvent(when: $0.consumedAt, grams: $0.volumeML * $0.abv * 0.789, name: $0.optionName)
        }
        for d in sharedDrinks where d.shared && d.live {
            evs.append(RecapEvent(when: d.createdAt, grams: d.grams / Double(n), name: d.drinkName))
        }
        return evs.sorted { $0.when < $1.when }
    }

    /// Live BAC for a manually-added guest: their own logged drinks PLUS
    /// their share of every shared round (split across all heads — members
    /// + guests). Same chronological Widmark walk the member version uses,
    /// run against the guest's own body params. Guests were previously
    /// getting zero from shared rounds.
    func liveBAC(forGhost ghost: GhostMember, now: Date = Date()) -> Double {
        let denom = ghost.weightKg * 1000 * ghost.sex.r
        guard denom > 0 else { return 0 }
        let n = sharedHeadCount

        var events: [(Date, Double)] = ghost.drinks.map { ($0.consumedAt, $0.grams) }
        for d in liveDrinks where d.shared {
            events.append((d.createdAt, d.grams / Double(n)))
        }
        events.sort { $0.0 < $1.0 }

        var bac: Double = 0
        var lastEvent: Date? = nil
        for (when, grams) in events where when <= now {
            if let last = lastEvent {
                bac = max(0, bac - 0.015 * (when.timeIntervalSince(last) / 3600))
            }
            bac += (grams / denom) * 100
            lastEvent = when
        }
        if let last = lastEvent {
            bac = max(0, bac - 0.015 * max(0, now.timeIntervalSince(last) / 3600))
        }
        return bac
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

        // 1. Persisted session for this scope. Fetched WITHOUT the active
        //    filter so a session that ENDED while this device was away
        //    (app closed / signed out) can still deliver its recap — the
        //    poll never saw the end, so nobody captured it.
        if let raw = UserDefaults.standard.string(forKey: persistKey),
           let sid = UUID(uuidString: raw) {
            if let row: SeshSession = try? await supabase
                .from("sessions")
                .select()
                .eq("id", value: sid.uuidString.lowercased())
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
                let activeForScope = scopeLive ? row.activeLive : row.activePlan
                if activeForScope && isFresh(row) {
                    await enter(session: row)
                    return
                }
                if !activeForScope && scopeLive && isFresh(row) {
                    // Ended while away → recap + release (never re-enter).
                    await captureEndedWhileAway(row)
                } else {
                    // The night is long over but the session was never
                    // ended (host killed the app, switched groups, etc.).
                    // Detach quietly instead of resurrecting a days-old
                    // sesh — and never recap it: entering + recapping
                    // stale sessions is exactly the phantom-recap bug.
                    await silentlyRelease(row)
                }
            }
            // Persisted session is dealt with either way — clear it so we
            // don't keep hitting the network for a dead row every launch.
            persistSessionID(nil)
        }

        // 2. Fallback: scan all my memberships in this mode, most recent
        //    first, and enter the first FRESH one whose session is still
        //    active in this mode. Fresh-but-ended ones deliver their recap
        //    (same as above); older leftovers get released as we go, so
        //    the scan doubles as launch-time garbage collection.
        do {
            let myMemberships: [SessionMember] = try await supabase
                .from("session_members")
                .select()
                .eq("profile_id", value: uid.uuidString.lowercased())
                .eq(inColumnForScope, value: true)
                .order("joined_at", ascending: false)
                .execute()
                .value
            var entered = false
            for m in myMemberships {
                if let row: SeshSession = try? await supabase
                    .from("sessions")
                    .select()
                    .eq("id", value: m.sessionId.uuidString.lowercased())
                    .single()
                    .execute()
                    .value {
                    let activeForScope = scopeLive ? row.activeLive : row.activePlan
                    if activeForScope && !entered && isFresh(row) {
                        await enter(session: row)
                        entered = true
                    } else if !activeForScope && scopeLive && isFresh(row) {
                        await captureEndedWhileAway(row)
                    } else {
                        await silentlyRelease(row)
                    }
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
            // Creating a new group while still in another = a direct
            // switch. Detach from the old one so its membership can't
            // resurrect later. NO recap here — the night continues; the
            // single recap arrives at the night's terminal end.
            if let old = session, old.id != row.id {
                await silentlyRelease(old)
            }
            entryWasUserInitiated = true
            followingGroupVenue = true
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
            // Joining while still in another group = a direct switch.
            // Detach from the old one so its membership can't resurrect
            // later. NO recap here — the night continues in the new group;
            // the single recap arrives at the night's TERMINAL end and
            // covers every group along the way.
            if let old = session, old.id != row.id {
                await silentlyRelease(old)
            }
            entryWasUserInitiated = true
            // Joining a group means following it — a "broke away" state
            // left over from a previous group must not block adopting the
            // new group's venue / pre-game spot into my journey.
            followingGroupVenue = true
            await enter(session: row)
        } catch {
            // The join RPC may have SUCCEEDED even though the follow-up
            // session fetch failed — the membership then exists server-side
            // while this device looks like it never joined (and the invite
            // is already consumed). Let resume find and enter it before
            // declaring failure.
            entryWasUserInitiated = true
            await resumeIfAny()
            if session == nil {
                entryWasUserInitiated = false
                self.error = "Couldn't join. Check the code."
            }
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
    func leave(cousinSessionId: UUID? = nil, captureRecap: Bool = true) async {
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
        // Ending → hand off the recap. "Just leaving" (to go join another
        // sesh) skips the recap; the night isn't saved.
        if captureRecap {
            captureLiveEnd(drinks: drinks, members: members, ghosts: ghosts)
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
    func end(cousinSessionId: UUID? = nil, captureRecap: Bool = true) async {
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
        // NOTE: squad schnaps are NOT purged here — every member's device
        // needs a window to download them into its group recap after the
        // end lands. The daily cleanup sweeps schnaps of ended sessions
        // (and anything past 48h) instead; the sesh being over already
        // hides them from every UI.
        // Host ending a live group ends everyone's night → recap for me too,
        // unless the host is just leaving to keep their night going elsewhere.
        // Capture → clearLocal must be atomic (no awaits between): the
        // recap observer fires on the capture, and if it runs while
        // `session` still looks alive it treats a TERMINAL end as "night
        // continues" and skips clearing the journey/check-in — that was
        // the "pre-game spot survives the end" bug.
        if captureRecap {
            captureLiveEnd(drinks: drinks, members: members, ghosts: ghosts)
        }
        clearLocal()
        // This night is over for me — release my flag so the launch scan
        // can't deliver it again as an "ended while away" recap.
        await markDelivered(sid)
    }

    /// Flip my `in_<scope>` membership flag after a recap has been
    /// captured on THIS device — the flag doubles as "recap not yet
    /// delivered" for the ended-while-away launch scan.
    private func markDelivered(_ sid: UUID) async {
        guard let uid = myId else { return }
        struct InPlanPatch: Encodable { let in_plan: Bool }
        struct InLivePatch: Encodable { let in_live: Bool }
        if scopeLive {
            _ = try? await supabase.from("session_members")
                .update(InLivePatch(in_live: false))
                .eq("session_id", value: sid.uuidString.lowercased())
                .eq("profile_id", value: uid.uuidString.lowercased())
                .execute()
        } else {
            _ = try? await supabase.from("session_members")
                .update(InPlanPatch(in_plan: false))
                .eq("session_id", value: sid.uuidString.lowercased())
                .eq("profile_id", value: uid.uuidString.lowercased())
                .execute()
        }
    }

    /// Remove MY personal (non-shared) drink rows from a session I'm
    /// walking away from. The rows have just been copied into whichever
    /// store the night continues in — leaving the originals behind would
    /// double-count them on a later rejoin (leave→rejoin used to double
    /// the count every cycle). Shared rounds stay; they belong to the
    /// whole group, not to me.
    func deleteMyPersonalDrinks(in sessionId: UUID) async {
        guard let uid = myId else { return }
        _ = try? await supabase.from("session_drinks")
            .delete()
            .eq("session_id", value: sessionId.uuidString.lowercased())
            .eq("profile_id", value: uid.uuidString.lowercased())
            .eq("shared", value: false)
            .eq("live", value: scopeLive)
            .execute()
    }

    /// A group session is only worth resuming for ~a night. Anything
    /// older is a leftover (host never pressed END, app was killed
    /// mid-switch, etc.) — resurrecting it produces phantom "seshes I
    /// never started" and surprise recaps on launch.
    private func isFresh(_ row: SeshSession) -> Bool {
        Date().timeIntervalSince(row.createdAt) < 24 * 3600
    }

    /// Quietly detach from a session without ending my night or handing
    /// off a recap: flip my `in_<scope>` flag, and if I host it, end it
    /// for this scope too (a hostless group would just linger). Used for
    /// garbage-collecting stale sessions on launch and for abandoning
    /// the old group during a direct group→group switch — neither is an
    /// END, so `captureLiveEnd` is deliberately never called here.
    private func silentlyRelease(_ row: SeshSession) async {
        guard let uid = myId else { return }
        struct InPlanPatch: Encodable { let in_plan: Bool }
        struct InLivePatch: Encodable { let in_live: Bool }
        struct ActivePlanPatch: Encodable { let active_plan: Bool }
        struct ActiveLivePatch: Encodable { let active_live: Bool }
        do {
            if scopeLive {
                _ = try await supabase.from("session_members")
                    .update(InLivePatch(in_live: false))
                    .eq("session_id", value: row.id.uuidString.lowercased())
                    .eq("profile_id", value: uid.uuidString.lowercased())
                    .execute()
                if row.hostId == uid {
                    _ = try await supabase.from("sessions")
                        .update(ActiveLivePatch(active_live: false))
                        .eq("id", value: row.id.uuidString.lowercased())
                        .execute()
                }
            } else {
                _ = try await supabase.from("session_members")
                    .update(InPlanPatch(in_plan: false))
                    .eq("session_id", value: row.id.uuidString.lowercased())
                    .eq("profile_id", value: uid.uuidString.lowercased())
                    .execute()
                if row.hostId == uid {
                    _ = try await supabase.from("sessions")
                        .update(ActivePlanPatch(active_plan: false))
                        .eq("id", value: row.id.uuidString.lowercased())
                        .execute()
                }
            }
        } catch {
            // Best-effort cleanup; a failure just means we try again on
            // the next launch's garbage-collection pass.
        }
    }

    /// Adds a drink to the session. The `live` flag is derived from the
    /// store's scope — plan store stamps `live = false`, live store
    /// stamps `live = true`. Plan and live drinks are mutually exclusive
    /// per row so the two ledgers never bleed into each other even when
    /// both stores happen to track the same underlying session.
    func addDrink(_ option: DrinkOption, shared: Bool = false, consumedAt: Date? = nil) async {
        guard let sid = session?.id, let uid = myId else { return }
        do {
            let inserted: SessionDrink
            if let consumedAt {
                // Carrying a drink across stores (joining a group with a night
                // already underway) — preserve its original time so BAC stays
                // accurate. A normal pour omits created_at and the DB stamps now().
                struct DT: Encodable {
                    let session_id: String
                    let profile_id: String
                    let drink_name: String
                    let volume_ml: Double
                    let abv: Double
                    let shared: Bool
                    let live: Bool
                    let created_at: String
                }
                inserted = try await supabase.from("session_drinks")
                    .insert(DT(
                        session_id: sid.uuidString.lowercased(),
                        profile_id: uid.uuidString.lowercased(),
                        drink_name: option.name,
                        volume_ml: option.volumeML,
                        abv: option.abv,
                        shared: shared,
                        live: scopeLive,
                        created_at: ISO8601DateFormatter().string(from: consumedAt)
                    ))
                    .select().single().execute().value
            } else {
                struct D: Encodable {
                    let session_id: String
                    let profile_id: String
                    let drink_name: String
                    let volume_ml: Double
                    let abv: Double
                    let shared: Bool
                    let live: Bool
                }
                inserted = try await supabase.from("session_drinks")
                    .insert(D(
                        session_id: sid.uuidString.lowercased(),
                        profile_id: uid.uuidString.lowercased(),
                        drink_name: option.name,
                        volume_ml: option.volumeML,
                        abv: option.abv,
                        shared: shared,
                        live: scopeLive
                    ))
                    .select().single().execute().value
            }
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
        // Seed the guest roster from the row we just entered with, so the
        // first frame already shows shared guests instead of waiting for
        // the first poll.
        self.ghosts = session.ghosts
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

    /// Persist the full guest roster to the session row's JSONB column.
    /// Optimistically sets the local copy first so the UI is instant, then
    /// pushes — the next poll reconciles every other device. Last-write-
    /// wins: two people editing guests in the same second can clobber, but
    /// for manually-added guests that's a rare, low-stakes collision.
    func syncGhosts(_ newGhosts: [GhostMember]) async {
        guard let sid = session?.id else { return }
        ghosts = newGhosts
        session?.ghosts = newGhosts
        // Suppress the poll's ghost-overwrite while this write is in
        // flight, otherwise a refresh that lands before the write commits
        // reads the stale server value and wipes the just-added guest.
        ghostWriteInFlight = true
        defer { ghostWriteInFlight = false }
        // Write via a member-authorized RPC, NOT a direct UPDATE — the
        // sessions row's RLS update policy is host-only, so a non-host
        // member's direct update would silently fail and their guest
        // would vanish on the next poll.
        struct Params: Encodable { let p_session_id: String; let p_ghosts: [GhostMember] }
        do {
            _ = try await supabase
                .rpc("set_session_ghosts", params: Params(
                    p_session_id: sid.uuidString.lowercased(),
                    p_ghosts: newGhosts
                ))
                .execute()
        } catch {
            // Non-fatal — the local copy already updated and the next
            // successful edit (or another device's write) re-converges.
        }
    }

    /// Broadcast a group check-in/out — sets the session's shared venue so
    /// every following member adopts it. `nil` = check the group out.
    /// Member-authorized RPC (sessions' RLS update is host-only).
    func setGroupVenue(_ venue: Venue?) async {
        guard let sid = session?.id else { return }
        liveVenue = venue
        session?.liveVenue = venue
        liveVenueWriteInFlight = true
        defer { liveVenueWriteInFlight = false }
        // Explicit encode (not encodeIfPresent) so a checkout sends an
        // actual JSON `null` instead of omitting the param — PostgREST
        // would otherwise reject the call as missing a required argument.
        struct Params: Encodable {
            let p_session_id: String
            let p_venue: Venue?
            enum CodingKeys: String, CodingKey { case p_session_id, p_venue }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(p_session_id, forKey: .p_session_id)
                try c.encode(p_venue, forKey: .p_venue)
            }
        }
        do {
            _ = try await supabase
                .rpc("set_session_live_venue", params: Params(
                    p_session_id: sid.uuidString.lowercased(),
                    p_venue: venue
                ))
                .execute()
        } catch {
            // Non-fatal — local copy updated; the next write re-converges.
        }
        // Record the group's ROUTE server-side (migration 038): whoever
        // checks the group in/out writes it, so every member's group recap
        // can rebuild the night's stops — not just the members whose local
        // journey happened to witness them.
        await recordGroupStop(sessionId: sid, venue: venue)
    }

    /// Mirror my journey's MARKER entries (between-bars, food, puke stops +
    /// pre-game/loose spots) into the shared route while in a live group.
    /// The group recap builds from session_stops, so a marker only I
    /// witnessed still shows up for every member — including members who
    /// joined after it happened. Keyed by the journey entry's own uuid, so
    /// re-syncs are idempotent. Bars aren't synced here (the group
    /// check-in path owns those).
    func syncRouteMarkers(stops allStops: [SeshStop], spots allSpots: [LooseSpot]) async {
        guard scopeLive, let sid = session?.id, let uid = myId else { return }
        // Selection by IDENTITY: only entries stamped with THIS group's id.
        // Timestamps can't tell the group's story apart from a member's
        // parallel personal stops (they overlap in time); the tag can.
        let stops = allStops.filter { $0.sessionId == sid }
        let spots = allSpots.filter { $0.sessionId == sid }
        let iso = ISO8601DateFormatter()
        struct Row: Encodable {
            let id: String
            let session_id: String
            let name: String
            let lat: Double?
            let lon: Double?
            let kind: String
            let arrived_at: String
            let departed_at: String?
            let profile_id: String
            // Explicit encode (not encodeIfPresent): PostgREST rejects a
            // bulk upsert whose rows have MISMATCHED key sets — one open
            // stop (nil departure) next to a closed one silently failed
            // the whole batch, which is why markers went missing.
            enum CodingKeys: String, CodingKey {
                case id, session_id, name, lat, lon, kind, arrived_at, departed_at, profile_id
            }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(id, forKey: .id)
                try c.encode(session_id, forKey: .session_id)
                try c.encode(name, forKey: .name)
                try c.encode(lat, forKey: .lat)
                try c.encode(lon, forKey: .lon)
                try c.encode(kind, forKey: .kind)
                try c.encode(arrived_at, forKey: .arrived_at)
                try c.encode(departed_at, forKey: .departed_at)
                try c.encode(profile_id, forKey: .profile_id)
            }
        }
        var rows: [Row] = stops.filter { $0.kind != .bar }.map { s in
            Row(
                id: s.id.uuidString.lowercased(),
                session_id: sid.uuidString.lowercased(),
                name: s.name,
                lat: s.lat, lon: s.lon,
                kind: s.kind.rawValue,
                arrived_at: iso.string(from: s.arrivedAt),
                departed_at: s.departedAt.map { iso.string(from: $0) },
                profile_id: uid.uuidString.lowercased()
            )
        }
        rows += spots.map { sp in
            Row(
                id: sp.id.uuidString.lowercased(),
                session_id: sid.uuidString.lowercased(),
                name: sp.name ?? "Pre-game",
                lat: sp.lat, lon: sp.lon,
                kind: "preGame",
                arrived_at: iso.string(from: sp.at),
                departed_at: nil,
                profile_id: uid.uuidString.lowercased()
            )
        }
        guard !rows.isEmpty else { return }
        _ = try? await supabase.from("session_stops")
            .upsert(rows, onConflict: "id")
            .execute()
    }

    /// Close the open route entry and, when checking IN somewhere, open a
    /// new one. Best-effort — the recap falls back to the local journey.
    private func recordGroupStop(sessionId: UUID, venue: Venue?) async {
        let sid = sessionId.uuidString.lowercased()
        let iso = ISO8601DateFormatter()
        struct Close: Encodable { let departed_at: String }
        _ = try? await supabase.from("session_stops")
            .update(Close(departed_at: iso.string(from: Date())))
            .eq("session_id", value: sid)
            .eq("kind", value: "bar")   // markers are instants — closing them faked windows
            .filter("departed_at", operator: "is", value: "null")
            .execute()
        guard let venue else { return }
        struct Open: Encodable {
            let session_id: String
            let name: String
            let lat: Double?
            let lon: Double?
        }
        _ = try? await supabase.from("session_stops")
            .insert(Open(session_id: sid, name: venue.name, lat: venue.lat, lon: venue.lon))
            .execute()
    }

    /// Broadcast a group pre-game/between location (or nil to clear) so
    /// following members adopt it. Mirrors `setGroupVenue`.
    func setGroupLooseSpot(_ spot: LooseSpot?) async {
        guard let sid = session?.id else { return }
        liveLooseSpot = spot
        session?.liveLooseSpot = spot
        liveLooseSpotWriteInFlight = true
        defer { liveLooseSpotWriteInFlight = false }
        struct Params: Encodable {
            let p_session_id: String
            let p_spot: LooseSpot?
            enum CodingKeys: String, CodingKey { case p_session_id, p_spot }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(p_session_id, forKey: .p_session_id)
                try c.encode(p_spot, forKey: .p_spot)
            }
        }
        do {
            _ = try await supabase
                .rpc("set_session_live_loose_spot", params: Params(
                    p_session_id: sid.uuidString.lowercased(), p_spot: spot
                ))
                .execute()
        } catch {
            // Non-fatal — local copy updated; next write re-converges.
        }
    }

    private func clearLocal() {
        stopPolling()
        session = nil; members = []; memberProfiles = [:]; drinks = []; ghosts = []
        liveVenue = nil; liveLooseSpot = nil; followingGroupVenue = true
        routeStops = []
        // Note: endedGroupLeaderboard/endedLiveEvents are intentionally NOT
        // cleared here — clearLocal runs right after capture on group end,
        // and SessionView consumes them on the next tick.
        persistSessionID(nil)
    }

    func refresh() async {
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
                    // Capture my night for the auto-recap from the freshly
                    // fetched data (self.drinks/members aren't assigned on
                    // a launch poll yet); row.ghosts is the live guest set.
                    // Capture → clearLocal atomically (see end()) …
                    captureLiveEnd(drinks: ds, members: ms, ghosts: row.ghosts)
                    clearLocal()
                    // … then release my flag so the next launch's
                    // ended-while-away scan doesn't deliver it AGAIN.
                    await markDelivered(sid)
                    return
                }
                // Pull the shared guest roster from the session row so
                // every device converges on the same set + their drinks.
                // Skip while our own write is in flight, so a poll that
                // races the write doesn't wipe a just-added guest.
                if !ghostWriteInFlight, ghosts != row.ghosts {
                    ghosts = row.ghosts
                    session?.ghosts = row.ghosts
                }
                // Pull the group's shared venue so following members adopt
                // it. Skip while our own write is mid-flight.
                if !liveVenueWriteInFlight, liveVenue != row.liveVenue {
                    liveVenue = row.liveVenue
                    session?.liveVenue = row.liveVenue
                }
                if !liveLooseSpotWriteInFlight, liveLooseSpot != row.liveLooseSpot {
                    liveLooseSpot = row.liveLooseSpot
                    session?.liveLooseSpot = row.liveLooseSpot
                }
            }

            // Did I get kicked out of THIS mode (e.g. left from another
            // device, or — though we don't expose this yet — a host
            // removed me)? Detect via my own membership row's
            // `in_<scope>` flag. We already pulled the filtered list
            // above, so a missing self-row in `ms` means I'm out.
            if let uid = myId, !ms.contains(where: { $0.profileId == uid }) {
                captureLiveEnd(drinks: ds, members: ms, ghosts: ghosts)
                clearLocal()
                return
            }

            members = ms.sorted { $0.joinedAt < $1.joinedAt }
            drinks = ds

            // Pull the shared route so every member's journey converges on
            // the group's stops (live scope only — plan has no route).
            if scopeLive {
                let route: [RouteStopRow] = (try? await supabase
                    .from("session_stops")
                    .select()
                    .eq("session_id", value: sid.uuidString.lowercased())
                    .order("arrived_at", ascending: true)
                    .execute()
                    .value) ?? []
                if route != routeStops { routeStops = route }
            }
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
    @Published private(set) var offersByVenue: [UUID: [VenueOffer]] = [:]
    /// Real Apple Maps coordinates resolved per venue (the seeded lat/lon can
    /// be approximate). Resolved once and cached to disk — see
    /// resolveOfferCoordinates() — so map pins are accurate without paying a
    /// MapKit lookup (or its memory) on every open.
    @Published private(set) var resolvedCoords: [UUID: CLLocationCoordinate2D] = [:]
    @Published private(set) var loading = false
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

    /// Live offers at a venue (Phase A deals map).
    func offers(for venue: Venue) -> [VenueOffer] {
        offersByVenue[venue.id] ?? []
    }

    /// Venues that currently have at least one live offer — the pins shown on
    /// the deals map.
    var venuesWithOffers: [Venue] {
        venues.filter { !(offersByVenue[$0.id]?.isEmpty ?? true) }
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
            // RLS filters venue_offers to live (active + approved + unexpired)
            // offers, so a plain select returns exactly what's safe to show.
            let os: [VenueOffer] = try await supabase
                .from("venue_offers")
                .select()
                .execute()
                .value
            venues = vs
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

    /// Invite ids whose floating banner the user swiped away this session.
    /// The invite stays `pending` (still in the inbox / bell badge) — only
    /// the attention-grabbing banner is suppressed. Cleared naturally when
    /// the invite leaves `pending` (accepted / declined / withdrawn), and a
    /// brand-new invite isn't in this set so its banner still drops in.
    @Published private(set) var snoozedBannerIds: Set<UUID> = []

    /// Pending invites minus the ones whose banner was swiped away. Drives
    /// the floating banner; the bell badge keeps using `pending` so a
    /// snoozed invite is still findable.
    var bannerInvites: [Invite] {
        pending.filter { !snoozedBannerIds.contains($0.id) }
    }

    /// Swipe-to-dismiss: snooze the banner for everything currently shown.
    /// Idempotent and instant — the invites remain in the inbox.
    func snoozeBanner() {
        snoozedBannerIds.formUnion(pending.map(\.id))
    }

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
            // Drop snooze entries for invites that are no longer pending so
            // the set can't grow without bound and a re-sent invite (same
            // recipient, new row id) reappears as a fresh banner.
            let liveIds = Set(rows.map(\.id))
            snoozedBannerIds.formIntersection(liveIds)

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
            let status: String
        }
        let rows: [Row] = unique.map { rid in
            Row(
                session_id: sessionId.uuidString.lowercased(),
                sender_id: uid.uuidString.lowercased(),
                recipient_id: rid.uuidString.lowercased(),
                join_code: joinCode,
                mode: mode.rawValue,
                status: "pending"
            )
        }
        do {
            // A real upsert (NOT ignoreDuplicates): re-inviting someone who
            // already accepted/declined for this session resets their row
            // to `pending`, so the invite actually reappears in their inbox.
            // A silent skip here was exactly the "resent the invite and they
            // never got it" bug.
            _ = try await supabase
                .from("invites")
                .upsert(rows, onConflict: "session_id,recipient_id")
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

// MARK: - Friends

/// A user you can friend / invite: minimal public fields returned by the
/// friends RPCs (migration 018). `username` is the @handle.
struct FriendProfile: Identifiable, Equatable, Hashable, Decodable {
    let id: UUID            // the other user's profile id
    let name: String
    let username: String?
    let avatarURL: String?
}

/// An accepted friend (carries the friendship row id for removal).
struct Friend: Identifiable, Equatable, Hashable, Decodable {
    let friendshipId: UUID
    let id: UUID
    let name: String
    let username: String?
    let avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case friendshipId = "friendship_id"
        case id, name, username
        case avatarURL = "avatar_url"
    }
}

/// A pending incoming friend request (carries the request id to respond).
struct FriendRequest: Identifiable, Equatable, Hashable, Decodable {
    let requestId: UUID
    let id: UUID            // requester's profile id
    let name: String
    let username: String?
    let avatarURL: String?

    var id_: UUID { requestId }
    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case id, name, username
        case avatarURL = "avatar_url"
    }
}

/// A username-search hit, annotated with our relationship to them.
struct UserSearchHit: Identifiable, Equatable, Hashable, Decodable {
    let id: UUID
    let name: String
    let username: String?
    let avatarURL: String?
    let relation: String    // none | friend | outgoing | incoming

    enum CodingKeys: String, CodingKey {
        case id, name, username, relation
        case avatarURL = "avatar_url"
    }
}

/// Someone who liked or commented on your post.
struct ActivityActor: Identifiable, Decodable, Hashable {
    let id: UUID
    let name: String
    let username: String?
    let avatar: String?
}

/// A condensed bell notification: all the likers (or commenters) on one of
/// your posts within the last 24h.
struct ActivityNotification: Identifiable, Decodable {
    let postId: UUID
    let kind: String          // "like" | "comment"
    let actorCount: Int
    let latestAt: String
    let actors: [ActivityActor]
    let coverURL: String?

    var id: String { "\(postId.uuidString)-\(kind)" }
    var isLike: Bool { kind == "like" }

    enum CodingKeys: String, CodingKey {
        case postId = "post_id", kind, latestAt = "latest_at", actors, coverURL = "cover_url"
        case actorCount = "actor_count"
    }

    var latestDate: Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: latestAt) ?? ISO8601DateFormatter().date(from: latestAt)
    }

    /// "Alex liked your night" / "Alex & Sam commented" / "Alex, Sam +3 liked".
    var summary: String {
        let verb = isLike ? "liked" : "commented on"
        let names = actors.map(\.name)
        let who: String
        switch names.count {
        case 0: who = "Someone"
        case 1: who = names[0]
        case 2: who = "\(names[0]) & \(names[1])"
        default: who = "\(names[0]), \(names[1]) +\(names.count - 2)"
        }
        return "\(who) \(verb) your night"
    }
}

/// Loads + manages the signed-in user's friends and incoming friend
/// requests. All cross-user reads/writes go through the SECURITY DEFINER
/// RPCs from migration 018. Polls every 8s for new requests (rare events).
@MainActor
final class FriendsService: ObservableObject {
    @Published private(set) var friends: [Friend] = []
    @Published private(set) var incoming: [FriendRequest] = []
    /// Likes/comments on the user's own posts in the last 24h, condensed per
    /// post — drives the bell's activity notifications.
    @Published private(set) var activity: [ActivityNotification] = []
    /// Notification id -> the latest-activity time it was dismissed at. A
    /// notification reappears only if NEW activity arrives after that.
    @Published private var dismissedActivity: [String: Double] = [:]
    private var dismissedLoaded = false
    @Published var error: String?

    private var pollTask: Task<Void, Never>?

    private var uidKey: String { supabase.auth.currentUser?.id.uuidString.lowercased() ?? "anon" }
    private var lastSeenKey: String { "activity-seen-\(uidKey)" }
    private var dismissedKey: String { "activity-dismissed-\(uidKey)" }

    private var lastSeenActivity: Date {
        get { Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: lastSeenKey)) }
        set { UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: lastSeenKey) }
    }

    private func loadDismissedIfNeeded() {
        guard !dismissedLoaded else { return }
        dismissedLoaded = true
        dismissedActivity = UserDefaults.standard.dictionary(forKey: dismissedKey) as? [String: Double] ?? [:]
    }

    /// Activity not dismissed (or dismissed but with newer activity since).
    var visibleActivity: [ActivityNotification] {
        activity.filter { n in
            guard let d = dismissedActivity[n.id] else { return true }
            return (n.latestDate?.timeIntervalSince1970 ?? 0) > d
        }
    }

    /// New activity since the bell was last opened — drives the badge.
    var unseenActivityCount: Int {
        let seen = lastSeenActivity
        return visibleActivity.filter { ($0.latestDate ?? .distantPast) > seen }.count
    }
    func markActivitySeen() { lastSeenActivity = Date() }

    /// Swipe-to-dismiss a notification from the bell.
    func dismissActivity(_ n: ActivityNotification) {
        dismissedActivity[n.id] = n.latestDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
        UserDefaults.standard.set(dismissedActivity, forKey: dismissedKey)
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 8_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        guard supabase.auth.currentUser != nil else {
            friends = []; incoming = []; activity = []; return
        }
        loadDismissedIfNeeded()
        do {
            async let f: [Friend] = supabase.rpc("list_friends").execute().value
            async let r: [FriendRequest] = supabase.rpc("list_incoming_requests").execute().value
            async let a: [ActivityNotification] = supabase.rpc("my_post_activity").execute().value
            let (loadedFriends, loadedRequests, loadedActivity) = try await (f, r, a)
            friends = loadedFriends
            incoming = loadedRequests
            activity = loadedActivity
        } catch {
            // Leave the last good lists in place on a transient failure.
        }
    }

    /// Prefix-search usernames for the add-friend screen.
    func search(_ query: String) async -> [UserSearchHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        struct P: Encodable { let p_query: String }
        do {
            return try await supabase.rpc("search_usernames", params: P(p_query: q)).execute().value
        } catch {
            return []
        }
    }

    /// Send a friend request by username. Returns a user-facing result string
    /// (nil = success, otherwise a short reason to show).
    func sendRequest(username: String) async -> String? {
        struct P: Encodable { let p_username: String }
        struct R: Decodable { let ok: Bool; let status: String?; let reason: String? }
        do {
            let r: R = try await supabase
                .rpc("send_friend_request", params: P(p_username: username))
                .execute().value
            if r.ok {
                await refresh()
                return nil
            }
            switch r.reason {
            case "not_found":      return "No one with that username."
            case "self":           return "That's you 🙂"
            case "already_friends": return "You're already friends."
            default:                return "Couldn't send request."
            }
        } catch {
            return "Couldn't send request."
        }
    }

    func respond(requestId: UUID, accept: Bool) async {
        struct P: Encodable { let p_request_id: String; let p_accept: Bool }
        incoming.removeAll { $0.requestId == requestId }   // optimistic
        do {
            _ = try await supabase
                .rpc("respond_friend_request", params: P(p_request_id: requestId.uuidString.lowercased(), p_accept: accept))
                .execute()
            await refresh()
        } catch {
            self.error = "Couldn't update request"
            await refresh()
        }
    }

    func remove(userId: UUID) async {
        struct P: Encodable { let p_other: String }
        friends.removeAll { $0.id == userId }              // optimistic
        do {
            _ = try await supabase
                .rpc("remove_friend", params: P(p_other: userId.uuidString.lowercased()))
                .execute()
            await refresh()
        } catch {
            self.error = "Couldn't remove friend"
            await refresh()
        }
    }
}

// MARK: - Timeline feed

/// A friend's posted night, decoded for the timeline.
struct TimelinePost: Identifiable {
    let id: UUID
    let authorId: UUID
    let authorName: String
    let authorUsername: String?
    let authorAvatar: String?
    let recap: NightRecap
    let includeBAC: Bool
    let caption: String?
    let coverURL: String?
    let createdAt: String
    var likeCount: Int = 0
    var likedByMe: Bool = false
    var commentCount: Int = 0

    var isMine: Bool { authorId == supabase.auth.currentUser?.id }
}

/// A comment on a Nightline post.
struct PostComment: Identifiable, Decodable {
    let id: UUID
    let authorId: UUID
    let authorName: String
    let authorUsername: String?
    let authorAvatar: String?
    let body: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, body
        case authorId = "author_id"
        case authorName = "author_name"
        case authorUsername = "author_username"
        case authorAvatar = "author_avatar"
        case createdAt = "created_at"
    }
    var isMine: Bool { authorId == supabase.auth.currentUser?.id }
}

/// Loads the friends timeline via the `friends_feed` RPC (migration 020).
/// Recaps come back as JSON; we re-decode them with an ISO-8601 decoder so
/// dates round-trip exactly the way PostService wrote them.
@MainActor
final class FeedService: ObservableObject {
    @Published private(set) var posts: [TimelinePost] = []
    @Published var loading = false
    private var started = false

    private let dec: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    func start() {
        guard !started else { return }
        started = true
        Task { await refresh() }
    }

    private struct FeedRow: Decodable {
        let id: UUID
        let author_id: UUID
        let author_name: String
        let author_username: String?
        let author_avatar: String?
        let recap: AnyJSON
        let include_bac: Bool
        let caption: String?
        let cover_url: String?
        let created_at: String
        let like_count: Int?
        let liked_by_me: Bool?
        let comment_count: Int?
    }

    private func map(_ rows: [FeedRow]) -> [TimelinePost] {
        rows.compactMap { row in
            guard let data = try? JSONEncoder().encode(row.recap),
                  let recap = try? dec.decode(NightRecap.self, from: data) else { return nil }
            return TimelinePost(
                id: row.id, authorId: row.author_id, authorName: row.author_name,
                authorUsername: row.author_username, authorAvatar: row.author_avatar,
                recap: recap, includeBAC: row.include_bac, caption: row.caption,
                coverURL: row.cover_url, createdAt: row.created_at,
                likeCount: row.like_count ?? 0, likedByMe: row.liked_by_me ?? false,
                commentCount: row.comment_count ?? 0
            )
        }
    }

    /// Like / unlike a post. Updates the in-memory feed optimistically.
    func toggleLike(_ postId: UUID) async {
        if let i = posts.firstIndex(where: { $0.id == postId }) {
            let nowLiked = !posts[i].likedByMe
            posts[i].likedByMe = nowLiked
            posts[i].likeCount += nowLiked ? 1 : -1
        }
        let liked = posts.first(where: { $0.id == postId })?.likedByMe ?? true
        struct P: Encodable { let p_post_id: String; let p_like: Bool }
        do {
            _ = try await supabase.rpc("set_like",
                params: P(p_post_id: postId.uuidString.lowercased(), p_like: liked)).execute()
        } catch {
            await refresh()
        }
    }

    func comments(_ postId: UUID) async -> [PostComment] {
        struct P: Encodable { let p_post_id: String }
        do {
            return try await supabase.rpc("list_comments",
                params: P(p_post_id: postId.uuidString.lowercased())).execute().value
        } catch { return [] }
    }

    func addComment(_ postId: UUID, body: String) async {
        struct P: Encodable { let p_post_id: String; let p_body: String }
        _ = try? await supabase.rpc("add_comment",
            params: P(p_post_id: postId.uuidString.lowercased(), p_body: body)).execute()
        if let i = posts.firstIndex(where: { $0.id == postId }) { posts[i].commentCount += 1 }
    }

    func deleteComment(_ id: UUID, postId: UUID) async {
        struct P: Encodable { let p_id: String }
        _ = try? await supabase.rpc("delete_comment",
            params: P(p_id: id.uuidString.lowercased())).execute()
        if let i = posts.firstIndex(where: { $0.id == postId }), posts[i].commentCount > 0 {
            posts[i].commentCount -= 1
        }
    }

    /// Delete one of the caller's own posts (RLS enforces ownership).
    func deletePost(_ id: UUID) async {
        posts.removeAll { $0.id == id }   // optimistic
        do {
            _ = try await supabase.from("posts")
                .delete().eq("id", value: id.uuidString.lowercased()).execute()
        } catch {
            await refresh()
        }
    }

    /// Toggle whether a post's BAC is shared (author only). The full recap is
    /// always stored; this just flips the read-time visibility flag.
    func setBAC(postId: UUID, include: Bool) async {
        struct Patch: Encodable { let include_bac: Bool }
        do {
            _ = try await supabase.from("posts")
                .update(Patch(include_bac: include))
                .eq("id", value: postId.uuidString.lowercased())
                .execute()
            await refresh()
        } catch { }
    }

    /// The last-7-days friends feed (server-windowed).
    func refresh() async {
        guard supabase.auth.currentUser != nil else { posts = []; return }
        loading = true
        defer { loading = false }
        struct P: Encodable { let p_limit: Int }
        do {
            let rows: [FeedRow] = try await supabase
                .rpc("friends_feed", params: P(p_limit: 40))
                .execute().value
            posts = map(rows)
        } catch {
            // Leave the last good feed in place on a transient failure.
        }
    }

    /// One user's full post archive (no time window) — for profile grids.
    func userPosts(_ userId: UUID) async -> [TimelinePost] {
        struct P: Encodable { let p_user: String }
        do {
            let rows: [FeedRow] = try await supabase
                .rpc("user_posts", params: P(p_user: userId.uuidString.lowercased()))
                .execute().value
            return map(rows)
        } catch {
            return []
        }
    }

    /// Fetch one of the caller's own posts by id (for opening from a bell
    /// notification — activity is always on your own posts).
    func myPost(_ postId: UUID) async -> TimelinePost? {
        guard let uid = supabase.auth.currentUser?.id else { return nil }
        return await userPosts(uid).first { $0.id == postId }
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
/// A recent pick, stored in full so a scanned / custom beverage (which
/// isn't in `DrinkCatalog`) survives — the old name-only store dropped
/// anything it couldn't find in the catalog. Codable so it round-trips
/// through UserDefaults and the lock-screen App Intent.
struct RecentDrink: Codable, Equatable {
    var name: String
    var detail: String
    var category: String   // DrinkCategory rawValue
    var volumeML: Double
    var abv: Double

    init(option: DrinkOption) {
        name = option.name
        detail = option.detail
        category = option.category.rawValue
        volumeML = option.volumeML
        abv = option.abv
    }

    var option: DrinkOption {
        DrinkOption(
            category: DrinkCategory(rawValue: category) ?? .beer,
            name: name,
            detail: detail,
            volumeML: volumeML,
            abv: abv
        )
    }
}

final class RecentDrinksStore: ObservableObject {
    /// Recent picks, newest-first, deduped by name. Capped so the file
    /// doesn't grow — the dock only ever shows the first 3.
    @Published private(set) var recents: [RecentDrink] = []

    /// v2 stores full options (scanned drinks survive); v1 was names only.
    private let key = LockScreenStorageKeys.recentsV2
    private let legacyKey = LockScreenStorageKeys.recents
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

    /// Records a pick. Moves the option to the front, removing any prior
    /// occurrence (by name) so the same drink doesn't take multiple slots.
    func record(_ option: DrinkOption) {
        var list = recents.filter { $0.name != option.name }
        list.insert(RecentDrink(option: option), at: 0)
        if list.count > cap { list = Array(list.prefix(cap)) }
        recents = list
        save()
    }

    /// Full `DrinkOption`s, newest-first — including scanned/custom drinks.
    func resolved() -> [DrinkOption] {
        recents.map { $0.option }
    }

    private let ownerKey = "sesh.recents.owner.v1"

    private func load() {
        guard StoreOwner.mayLoad(ownerKey) else { return }
        if let data = UserDefaults.standard.data(forKey: key),
           let arr = try? JSONDecoder().decode([RecentDrink].self, from: data) {
            recents = arr
            return
        }
        // Migrate the old name-only v1 list by resolving against the
        // catalog (custom/scanned names simply drop, which is fine — they
        // weren't recoverable from a name anyway).
        if let names = UserDefaults.standard.stringArray(forKey: legacyKey) {
            recents = names
                .compactMap { n in DrinkCatalog.allOptions.first(where: { $0.name == n }) }
                .map { RecentDrink(option: $0) }
            if !recents.isEmpty { save() }
        }
    }

    private func save() {
        StoreOwner.stamp(ownerKey)
        if let data = try? JSONEncoder().encode(recents) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// The user's saved drinks library — scanned cans/bottles (and any pick
/// they explicitly keep) that should be reusable forever, not just while
/// they're still "recent". Device-local, newest-first, deduped by name.
/// Reuses `RecentDrink` for storage since it captures the full spec.
@MainActor
final class SavedDrinksStore: ObservableObject {
    @Published private(set) var items: [RecentDrink] = []

    private let key = "sesh.savedDrinks.v1"

    init() { load() }

    /// Full `DrinkOption`s, newest-first.
    var drinks: [DrinkOption] { items.map(\.option) }

    func isSaved(_ option: DrinkOption) -> Bool {
        items.contains { $0.name == option.name }
    }

    /// Save (or refresh) a drink. Moves it to the front so the most
    /// recently saved spec wins if the same name is scanned again.
    func save(_ option: DrinkOption) {
        var list = items.filter { $0.name != option.name }
        list.insert(RecentDrink(option: option), at: 0)
        items = list
        persist()
    }

    func remove(_ option: DrinkOption) {
        items.removeAll { $0.name == option.name }
        persist()
    }

    func toggle(_ option: DrinkOption) {
        isSaved(option) ? remove(option) : save(option)
    }

    private let ownerKey = "sesh.savedDrinks.owner.v1"

    private func load() {
        guard StoreOwner.mayLoad(ownerKey) else { return }
        if let data = UserDefaults.standard.data(forKey: key),
           let arr = try? JSONDecoder().decode([RecentDrink].self, from: data) {
            items = arr
        }
    }

    private func persist() {
        StoreOwner.stamp(ownerKey)
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
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

/// Per-account ownership stamp for device-local stores. UserDefaults is
/// device-global, so every persisted store records which account wrote it;
/// a different account signing in on the same phone sees an empty store
/// instead of inheriting the previous user's night (drinks, check-in,
/// photos, guests, saved groups, …). The data itself stays on disk
/// untouched, so the original owner gets it back on their next sign-in —
/// until the new account's first save takes ownership and overwrites.
enum StoreOwner {
    static var currentUID: String? {
        supabase.auth.currentUser?.id.uuidString.lowercased()
    }

    /// True when the current account may read the store stamped at `key`
    /// (no stamp yet, no signed-in user, or the stamp matches). Claims
    /// unstamped data for the current account as a side effect — pre-stamp
    /// legacy data can't be attributed, so the first account to load it
    /// after the update owns it; every other account then sees it empty
    /// immediately instead of waiting for someone's first save.
    static func mayLoad(_ key: String) -> Bool {
        guard let uid = currentUID else { return true }
        guard let owner = UserDefaults.standard.string(forKey: key) else {
            UserDefaults.standard.set(uid, forKey: key)
            return true
        }
        return owner == uid
    }

    static func stamp(_ key: String) {
        if let uid = currentUID {
            UserDefaults.standard.set(uid, forKey: key)
        }
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

    // Per-ACCOUNT keys (see NightJourneyStore) — the shared slot let one
    // account's solo drinks OVERWRITE the other's on the same phone. The
    // lock-screen intent follows via the `liveNS` pointer key, so quick
    // adds land in the signed-in account's slot.
    private let drinksKey: String
    private let startKey: String
    private let eliminationRate = 0.015

    var isActive: Bool { startedAt != nil }

    init() {
        let ns = supabase.auth.currentUser?.id.uuidString.lowercased() ?? "anon"
        drinksKey = "\(LockScreenStorageKeys.drinks).\(ns)"
        startKey = "\(LockScreenStorageKeys.started).\(ns)"
        let d = UserDefaults.standard
        // Point the lock-screen intent at MY slot.
        d.set(ns, forKey: LockScreenStorageKeys.liveNS)
        // One-time adoption of the pre-namespace shared slot, if its
        // owner stamp says it was mine. Another account's data is left
        // for its owner.
        if d.string(forKey: "sesh.live.owner.v1") == ns {
            if d.object(forKey: drinksKey) == nil,
               let v = d.data(forKey: LockScreenStorageKeys.drinks) {
                d.set(v, forKey: drinksKey)
            }
            let raw = d.double(forKey: LockScreenStorageKeys.started)
            if raw > 0, d.object(forKey: startKey) == nil {
                d.set(raw, forKey: startKey)
            }
            d.removeObject(forKey: LockScreenStorageKeys.drinks)
            d.removeObject(forKey: LockScreenStorageKeys.started)
            d.removeObject(forKey: "sesh.live.owner.v1")
        }
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
        drinks = []
        startedAt = nil
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

    // Per-ACCOUNT key (see NightJourneyStore) — legacy slot adopted by its
    // stamped owner on first load.
    private let storeKey: String = {
        let ns = supabase.auth.currentUser?.id.uuidString.lowercased() ?? "anon"
        let namespaced = "sesh.live.ghosts.v1.\(ns)"
        let d = UserDefaults.standard
        if d.string(forKey: "sesh.live.ghosts.owner.v1") == ns {
            if d.object(forKey: namespaced) == nil, let v = d.data(forKey: "sesh.live.ghosts.v1") {
                d.set(v, forKey: namespaced)
            }
            d.removeObject(forKey: "sesh.live.ghosts.v1")
            d.removeObject(forKey: "sesh.live.ghosts.owner.v1")
        }
        return namespaced
    }()
    private let eliminationRate = 0.015

    /// When set (by SessionView while a live GROUP is active), every local
    /// mutation is mirrored up to the shared session row so all devices
    /// converge. nil in solo live mode, where guests stay device-local.
    /// Set/cleared alongside group entry/exit.
    var syncSink: (([GhostMember]) -> Void)?
    /// Guards against an echo loop: `hydrate(_:)` (server → local) must not
    /// re-fire `syncSink` (local → server).
    private var isHydrating = false

    init() { load() }

    /// Replace the roster from an authoritative server snapshot without
    /// bouncing it straight back to the server. Used by the group poll.
    func hydrate(_ newMembers: [GhostMember]) {
        guard members != newMembers else { return }
        isHydrating = true
        members = newMembers
        persist()
        isHydrating = false
    }

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

    /// Local persist + (in group mode) mirror to the shared session row.
    /// `hydrate(_:)` bypasses the sink via `isHydrating` so a server-driven
    /// update doesn't echo straight back.
    private func save() {
        persist()
        if !isHydrating { syncSink?(members) }
    }

    private func persist() {
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

    private let ownerKey = "sesh.savedGroups.owner.v1"

    private func persist() {
        StoreOwner.stamp(ownerKey)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(groups) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func load() {
        guard StoreOwner.mayLoad(ownerKey) else { return }
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
    /// Swipe-up (or tap the ×) to snooze this banner without accepting or
    /// declining. The invite stays in the inbox behind the bell.
    let onDismiss: () -> Void

    /// Pulsing glow ring + subtle scale. Drives both the outer shadow and
    /// the leading "NEW" pip so the banner feels alive — important for an
    /// alert that doesn't have a push notification behind it.
    @State private var pulse = false
    /// Springy entrance — the banner drops in then settles with a tiny
    /// over-shoot. Triggered on first appear so each new invite gets the
    /// "look at me" beat without re-running on every parent re-render.
    @State private var hasAppeared = false
    /// Live vertical drag while the user swipes the banner away. Negative
    /// values (upward) follow the finger; release past the threshold
    /// commits the dismiss.
    @State private var dragY: CGFloat = 0

    private var senderName: String {
        guard let latest else { return "Someone" }
        return senderProfiles[latest.senderId]?.name ?? "Someone"
    }

    private var senderAvatarURL: String? {
        guard let latest else { return nil }
        return senderProfiles[latest.senderId]?.avatarURL
    }

    var body: some View {
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
            // Explicit dismiss affordance (alongside swipe-up). Snoozes
            // the banner without touching the invite — it stays in the
            // inbox behind the bell.
            Button(action: dismiss) {
                ZStack {
                    Circle()
                        .fill(Color.ink.opacity(0.18))
                        .frame(width: 30, height: 30)
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Color.ink)
                }
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel("Dismiss banner")
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
        .offset(y: dragY)
        // Tap the card body → open the inbox. The × button and swipe
        // gesture both route to dismiss instead.
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture { onTap() }
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in
                    // Follow upward drags only; resist downward so the
                    // banner doesn't get yanked into the content below.
                    dragY = min(0, value.translation.height)
                }
                .onEnded { value in
                    if value.translation.height < -44 {
                        dismiss()
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            dragY = 0
                        }
                    }
                }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(count > 1 ? "\(count) new sesh invites" : "New sesh invite")
        .accessibilityHint("Double-tap to open the inbox, or swipe up to dismiss")
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.7)) {
                hasAppeared = true
            }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }

    /// Snooze the banner. The parent removes it (its `.transition` plays
    /// the slide-out); the invite itself stays pending in the inbox.
    private func dismiss() {
        onDismiss()
    }
}

private struct InvitesSheet: View {
    @ObservedObject var invites: InvitesService
    @ObservedObject var friends: FriendsService
    let onAccept: (Invite) -> Void
    let onDecline: (Invite) -> Void
    let onOpenPost: (UUID) -> Void

    private var isEmpty: Bool {
        invites.pending.isEmpty && friends.incoming.isEmpty && friends.visibleActivity.isEmpty
    }

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    Text(isEmpty ? "All caught up" : "Notifications")
                        .font(.system(size: 26, weight: .black, design: .rounded))
                        .foregroundStyle(Color.cream)
                        .padding(.top, 8)

                    if isEmpty {
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
                    }

                    // Friend requests
                    if !friends.incoming.isEmpty {
                        Text("FRIEND REQUESTS")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(2).foregroundStyle(Color.bronze)
                        VStack(spacing: 10) {
                            ForEach(friends.incoming) { req in
                                FriendRequestRow(
                                    request: req,
                                    onAccept: { Task { await friends.respond(requestId: req.requestId, accept: true) } },
                                    onDecline: { Task { await friends.respond(requestId: req.requestId, accept: false) } }
                                )
                            }
                        }
                    }

                    // Activity on your posts (condensed per post, last 24h)
                    if !friends.visibleActivity.isEmpty {
                        VStack(spacing: 10) {
                            ForEach(friends.visibleActivity) { act in
                                ActivityRow(
                                    activity: act,
                                    onOpen: { onOpenPost(act.postId) },
                                    onDelete: { withAnimation { friends.dismissActivity(act) } }
                                )
                            }
                        }
                        .padding(.top, friends.incoming.isEmpty ? 0 : 6)
                    }

                    // Sesh invites
                    if !invites.pending.isEmpty {
                        Text("SESH INVITES")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(2).foregroundStyle(Color.bronze)
                            .padding(.top, (friends.incoming.isEmpty && friends.visibleActivity.isEmpty) ? 0 : 6)
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

                    if let err = invites.error ?? friends.error {
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

/// A condensed like/comment notification. Tap to open the post, the chevron
/// to expand the people, or swipe left to dismiss (Apple-Mail style).
private struct ActivityRow: View {
    let activity: ActivityNotification
    let onOpen: () -> Void
    let onDelete: () -> Void
    @State private var expanded = false
    @State private var offsetX: CGFloat = 0

    private let revealWidth: CGFloat = 76

    var body: some View {
        ZStack(alignment: .trailing) {
            // Delete action revealed behind the card on left-swipe.
            Button { onDelete() } label: {
                Image(systemName: "trash")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: revealWidth)
                    .frame(maxHeight: .infinity)
                    .background(Status.drunk.color)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))

            card
                .offset(x: offsetX)
                .gesture(
                    DragGesture(minimumDistance: 14)
                        .onChanged { v in
                            if v.translation.width < 0 {
                                offsetX = max(v.translation.width, -revealWidth)
                            } else if offsetX < 0 {
                                offsetX = min(0, -revealWidth + v.translation.width)
                            }
                        }
                        .onEnded { v in
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                offsetX = v.translation.width < -40 ? -revealWidth : 0
                            }
                        }
                )
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button { onOpen() } label: {
                    HStack(spacing: 12) {
                        Image(systemName: activity.isLike ? "heart.fill" : "bubble.right.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(activity.isLike ? Status.drunk.color : Color.whiskey)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(activity.summary)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.cream)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Text(RelativeTime.short(activity.latestAt))
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(Color.cream.opacity(0.5))
                        }
                        Spacer(minLength: 8)
                        if let cover = activity.coverURL, let url = URL(string: cover) {
                            DownsampledAsyncImage(url: url, targetPoints: 48)
                                .frame(width: 40, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle())

                Button { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(Color.bronze)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(PressScaleStyle())
            }

            if expanded {
                VStack(spacing: 8) {
                    ForEach(activity.actors) { actor in
                        HStack(spacing: 8) {
                            FriendAvatar(name: actor.name, avatarURL: actor.avatar, size: 26)
                            Text(actor.name)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.cream)
                            if let u = actor.username {
                                Text("@\(u)").font(.system(size: 11, design: .rounded))
                                    .foregroundStyle(Color.cream.opacity(0.5))
                            }
                            Spacer()
                        }
                    }
                }
                .padding(.leading, 4)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.inkElev))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.cream.opacity(0.1), lineWidth: 1))
    }
}

/// A friend request row inside the unified inbox.
private struct FriendRequestRow: View {
    let request: FriendRequest
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            FriendAvatar(name: request.name, avatarURL: request.avatarURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.name)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.cream)
                Text(request.username.map { "@\($0) wants to be friends" } ?? "wants to be friends")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.65))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(action: onAccept) {
                Text("ACCEPT")
                    .font(.system(size: 10, weight: .black, design: .monospaced)).tracking(1.4)
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Capsule().fill(Color.whiskey))
            }
            .buttonStyle(PressScaleStyle())
            Button(action: onDecline) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.bronze).padding(8)
                    .background(Circle().fill(Color.cream.opacity(0.06)))
            }
            .buttonStyle(PressScaleStyle())
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.whiskey.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.whiskey.opacity(0.25), lineWidth: 1))
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
    /// Current user's catalog role (owner / admin / user) + the owner's
    /// management roster. Refreshed on sign-in.
    @StateObject private var admin = AdminService()

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
                SessionView(profile: profile, auth: auth, invites: invites, admin: admin)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: auth.state)
        .onChange(of: auth.state) { _, new in
            switch new {
            case .signedIn:
                invites.start()
                Task { await admin.refresh() }
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
    @State private var username = ""
    @State private var age: Double = 25
    @State private var sex: Sex = .male
    @State private var weightKg: Double = 75
    @State private var avatarData: Data?

    @State private var loading = false
    @State private var errorMessage: String?
    @State private var showReset = false
    @State private var showSignupConfirm = false
    /// Live username availability for sign-up: nil = unknown/checking,
    /// true = free, false = taken/invalid. Debounced via usernameCheckTask.
    @State private var usernameAvailable: Bool? = nil
    @State private var checkingUsername = false
    @State private var usernameCheckTask: Task<Void, Never>?
    @FocusState private var focus: Field?

    enum Field { case email, password, name, username }

    private var cleanUsername: String { username.lowercased().trimmingCharacters(in: .whitespaces) }
    private var usernameFormatValid: Bool {
        cleanUsername.range(of: "^[a-z0-9_]{3,20}$", options: .regularExpression) != nil
    }

    /// A single password requirement and whether the current input meets it.
    /// Mirrors the server-side rules configured in Supabase Auth
    /// (min length 8 + lower/upper/digit/symbol) so users get instant
    /// feedback instead of a round-trip rejection on submit.
    struct PasswordRule: Identifiable {
        let id: String
        let label: String
        let satisfied: Bool
    }

    private var passwordRules: [PasswordRule] {
        func has(_ pattern: String) -> Bool {
            password.range(of: pattern, options: .regularExpression) != nil
        }
        return [
            PasswordRule(id: "len", label: "At least 8 characters", satisfied: password.count >= 8),
            PasswordRule(id: "case", label: "Upper & lowercase letters", satisfied: has("[a-z]") && has("[A-Z]")),
            PasswordRule(id: "digit", label: "A number", satisfied: has("[0-9]")),
            PasswordRule(id: "symbol", label: "A symbol (!@#$…)", satisfied: has("[^A-Za-z0-9]"))
        ]
    }

    /// True when every sign-up password rule is satisfied.
    private var passwordMeetsRules: Bool { passwordRules.allSatisfy(\.satisfied) }

    private var canSubmit: Bool {
        if mode == .signUp {
            return email.contains("@")
                && passwordMeetsRules
                && !name.trimmingCharacters(in: .whitespaces).isEmpty
                && usernameFormatValid
                && usernameAvailable == true
        }
        // Sign-in accepts an email OR a username as the identifier; the
        // server validates the actual password.
        return !email.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
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
                    if mode == .signIn {
                        forgotPasswordLink
                    }
                    footnote
                }
                .padding(.horizontal, 28)
                .padding(.top, 56)
                .padding(.bottom, 48)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .preferredColorScheme(.dark)
        .onChange(of: username) { _, _ in scheduleUsernameCheck() }
        .sheet(isPresented: $showReset) {
            PasswordResetView(auth: auth, prefillEmail: email)
        }
        .sheet(isPresented: $showSignupConfirm) {
            SignUpConfirmView(auth: auth, email: email)
        }
    }

    private var forgotPasswordLink: some View {
        Button {
            focus = nil
            showReset = true
        } label: {
            Text("Forgot your password?")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.bronze)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(PressScaleStyle())
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
                label: mode == .signUp ? "EMAIL" : "EMAIL OR USERNAME",
                text: $email,
                placeholder: mode == .signUp ? "you@seshapp.xyz" : "you@seshapp.xyz or yourname",
                keyboard: mode == .signUp ? .emailAddress : .default,
                autocapitalize: false
            )
            .focused($focus, equals: .email)

            LoungeSecureField(
                label: "PASSWORD",
                text: $password,
                placeholder: mode == .signUp ? "8+ with a number & symbol" : "your password"
            )
            .focused($focus, equals: .password)

            passwordRequirements

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

                LoungeField(
                    label: "USERNAME",
                    text: $username,
                    placeholder: "pick a @handle",
                    autocapitalize: false
                )
                .focused($focus, equals: .username)
                usernameStatus

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

    /// Live checklist of password requirements, shown only while creating an
    /// account and only once the user has started typing a password.
    @ViewBuilder
    private var passwordRequirements: some View {
        if mode == .signUp, !password.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(passwordRules) { rule in
                    HStack(spacing: 8) {
                        Image(systemName: rule.satisfied ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(rule.satisfied ? Color.whiskey : Color.bronze.opacity(0.55))
                        Text(rule.label)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(rule.satisfied ? Color.cream.opacity(0.9) : Color.cream.opacity(0.5))
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.cream.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.bronze.opacity(0.2), lineWidth: 1))
            .animation(.easeInOut(duration: 0.2), value: password)
            .transition(.opacity)
        }
    }

    /// Inline availability/format feedback under the sign-up username field.
    @ViewBuilder
    private var usernameStatus: some View {
        if mode == .signUp, !username.isEmpty {
            HStack(spacing: 8) {
                if !usernameFormatValid {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.bronze)
                    Text("3–20 chars: lowercase letters, numbers, underscore")
                        .foregroundStyle(Color.cream.opacity(0.6))
                } else if checkingUsername {
                    ProgressView().controlSize(.mini).tint(Color.bronze)
                    Text("Checking…").foregroundStyle(Color.cream.opacity(0.6))
                } else if usernameAvailable == true {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.whiskey)
                    Text("@\(cleanUsername) is available").foregroundStyle(Color.cream.opacity(0.85))
                } else if usernameAvailable == false {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Status.drunk.color)
                    Text("That username is taken").foregroundStyle(Color.cream.opacity(0.85))
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .padding(.horizontal, 4)
        }
    }

    /// Debounced availability check, called from the body's onChange.
    private func scheduleUsernameCheck() {
        usernameCheckTask?.cancel()
        usernameAvailable = nil
        guard mode == .signUp, usernameFormatValid else { return }
        let candidate = cleanUsername
        checkingUsername = true
        usernameCheckTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            let ok = await auth.isUsernameAvailable(candidate)
            if Task.isCancelled || candidate != cleanUsername { return }
            usernameAvailable = ok
            checkingUsername = false
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
                    let identifier = email.trimmingCharacters(in: .whitespaces)
                    if identifier.contains("@") {
                        try await auth.signIn(email: identifier, password: password)
                    } else {
                        try await auth.signInWithUsername(username: identifier, password: password)
                    }
                case .signUp:
                    let outcome = try await auth.signUp(
                        email: email,
                        password: password,
                        name: name.trimmingCharacters(in: .whitespaces),
                        username: cleanUsername,
                        age: Int(age),
                        sex: sex,
                        weightKg: weightKg,
                        avatarData: avatarData
                    )
                    if outcome == .needsEmailCode {
                        showSignupConfirm = true
                    }
                }
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            loading = false
        }
    }
}

// MARK: - Password reset (OTP code flow)

/// Two-step in-app password recovery: request a 6-digit code by email, then
/// enter the code + a new password. Uses the same strength rules as sign-up.
/// On success the user is signed in with the new password.
private struct PasswordResetView: View {
    @ObservedObject var auth: AuthService
    let prefillEmail: String
    @Environment(\.dismiss) private var dismiss

    enum Phase { case request, verify }
    @State private var phase: Phase = .request
    @State private var email: String
    @State private var code = ""
    @State private var newPassword = ""
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var info: String?

    init(auth: AuthService, prefillEmail: String) {
        self.auth = auth
        self.prefillEmail = prefillEmail
        _email = State(initialValue: prefillEmail)
    }

    private func has(_ pattern: String) -> Bool {
        newPassword.range(of: pattern, options: .regularExpression) != nil
    }
    private var newPasswordValid: Bool {
        newPassword.count >= 8 && has("[a-z]") && has("[A-Z]") && has("[0-9]") && has("[^A-Za-z0-9]")
    }
    private var canAct: Bool {
        switch phase {
        case .request: return email.contains("@")
        case .verify:  return code.trimmingCharacters(in: .whitespaces).count >= 8 && newPasswordValid
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AtmosphereBackground(accent: .whiskey)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if phase == .request {
                        LoungeField(label: "EMAIL", text: $email,
                                    placeholder: "you@seshapp.xyz",
                                    keyboard: .emailAddress, autocapitalize: false)
                    } else {
                        LoungeField(label: "8-DIGIT CODE", text: $code,
                                    placeholder: "12345678", keyboard: .numberPad)
                        LoungeSecureField(label: "NEW PASSWORD", text: $newPassword,
                                          placeholder: "8+ with a number & symbol")
                        if !newPassword.isEmpty { rules }
                    }
                    if let errorMessage { banner(errorMessage, bad: true) }
                    if let info { banner(info, bad: false) }
                    actionButton
                    if phase == .verify { resendRow }
                }
                .padding(.horizontal, 28)
                .padding(.top, 52)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.cream.opacity(0.8))
                    .padding(12)
                    .background(Circle().fill(Color.cream.opacity(0.08)))
            }
            .padding(.top, 16)
            .padding(.trailing, 20)
            .buttonStyle(PressScaleStyle())
        }
        .preferredColorScheme(.dark)
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(phase == .request ? "RESET PASSWORD" : "ENTER CODE")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(2.4)
                .foregroundStyle(Color.bronze)
            Text(phase == .request ? "Forgot it? Happens." : "Check your email.")
                .font(.system(size: 30, weight: .black, design: .rounded))
                .italic()
                .tracking(-1)
                .foregroundStyle(Color.cream)
            Text(phase == .request
                 ? "Enter your email and we'll send an 8-digit code to reset your password."
                 : "We sent an 8-digit code to \(email). Enter it below with your new password.")
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.65))
                .lineSpacing(2)
        }
    }

    private var rules: some View {
        let items: [(String, Bool)] = [
            ("At least 8 characters", newPassword.count >= 8),
            ("Upper & lowercase letters", has("[a-z]") && has("[A-Z]")),
            ("A number", has("[0-9]")),
            ("A symbol (!@#$…)", has("[^A-Za-z0-9]"))
        ]
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.0) { label, ok in
                HStack(spacing: 8) {
                    Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ok ? Color.whiskey : Color.bronze.opacity(0.55))
                    Text(label)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(ok ? Color.cream.opacity(0.9) : Color.cream.opacity(0.5))
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.cream.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.bronze.opacity(0.2), lineWidth: 1))
        .animation(.easeInOut(duration: 0.2), value: newPassword)
    }

    private func banner(_ message: String, bad: Bool) -> some View {
        let tint = bad ? Status.drunk.color : Color.whiskey
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: bad ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 11)).foregroundStyle(tint).padding(.top, 1)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.cream.opacity(0.9)).lineSpacing(2)
            Spacer()
        }
        .padding(.vertical, 12).padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 12).fill(tint.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.35), lineWidth: 1))
    }

    private var actionButton: some View {
        Button { act() } label: {
            HStack {
                if loading { ProgressView().tint(Color.ink); Spacer() }
                else {
                    Text(phase == .request ? "SEND CODE" : "SET NEW PASSWORD")
                        .font(.system(size: 13, weight: .bold, design: .monospaced)).tracking(3)
                    Spacer()
                    Image(systemName: "arrow.right").font(.system(size: 12, weight: .bold))
                }
            }
            .foregroundStyle(Color.ink)
            .padding(.vertical, 16).padding(.horizontal, 20)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(canAct ? Color.cream : Color.cream.opacity(0.4)))
            .shadow(color: Color.whiskey.opacity(canAct ? 0.5 : 0), radius: 20, y: 10)
        }
        .disabled(!canAct || loading)
        .buttonStyle(PressScaleStyle())
    }

    private var resendRow: some View {
        Button {
            phase = .request
            code = ""; newPassword = ""; errorMessage = nil; info = nil
        } label: {
            Text("Didn't get a code? Send again")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.bronze)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(PressScaleStyle())
    }

    private func act() {
        loading = true; errorMessage = nil; info = nil
        Task { @MainActor in
            do {
                switch phase {
                case .request:
                    try await auth.sendPasswordReset(email: email)
                    info = "If an account exists for that email, a code is on its way."
                    phase = .verify
                case .verify:
                    try await auth.confirmPasswordReset(email: email, code: code, newPassword: newPassword)
                    dismiss() // auth state flips to .signedIn with the new password
                }
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            loading = false
        }
    }
}

// MARK: - Sign-up email confirmation (OTP code flow)

/// Shown after creating an account when email confirmation is on. The user
/// enters the 6-digit code from their email; on success their profile is
/// created and they're signed in. No web link / redirect involved.
private struct SignUpConfirmView: View {
    @ObservedObject var auth: AuthService
    let email: String
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var loading = false
    @State private var resending = false
    @State private var errorMessage: String?
    @State private var info: String?

    private var canVerify: Bool { code.trimmingCharacters(in: .whitespaces).count >= 8 }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AtmosphereBackground(accent: .whiskey)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    LoungeField(label: "8-DIGIT CODE", text: $code,
                                placeholder: "12345678", keyboard: .numberPad)
                    if let errorMessage { banner(errorMessage, bad: true) }
                    if let info { banner(info, bad: false) }
                    verifyButton
                    resendRow
                }
                .padding(.horizontal, 28)
                .padding(.top, 52)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.cream.opacity(0.8))
                    .padding(12)
                    .background(Circle().fill(Color.cream.opacity(0.08)))
            }
            .padding(.top, 16).padding(.trailing, 20)
            .buttonStyle(PressScaleStyle())
        }
        .preferredColorScheme(.dark)
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CONFIRM EMAIL")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(2.4)
                .foregroundStyle(Color.bronze)
            Text("One last thing.")
                .font(.system(size: 30, weight: .black, design: .rounded))
                .italic().tracking(-1)
                .foregroundStyle(Color.cream)
            Text("We sent an 8-digit code to \(email). Enter it to finish creating your account.")
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.65))
                .lineSpacing(2)
        }
    }

    private func banner(_ message: String, bad: Bool) -> some View {
        let tint = bad ? Status.drunk.color : Color.whiskey
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: bad ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 11)).foregroundStyle(tint).padding(.top, 1)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.cream.opacity(0.9)).lineSpacing(2)
            Spacer()
        }
        .padding(.vertical, 12).padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 12).fill(tint.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.35), lineWidth: 1))
    }

    private var verifyButton: some View {
        Button { verify() } label: {
            HStack {
                if loading { ProgressView().tint(Color.ink); Spacer() }
                else {
                    Text("CONFIRM & ENTER")
                        .font(.system(size: 13, weight: .bold, design: .monospaced)).tracking(3)
                    Spacer()
                    Image(systemName: "arrow.right").font(.system(size: 12, weight: .bold))
                }
            }
            .foregroundStyle(Color.ink)
            .padding(.vertical, 16).padding(.horizontal, 20)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(canVerify ? Color.cream : Color.cream.opacity(0.4)))
            .shadow(color: Color.whiskey.opacity(canVerify ? 0.5 : 0), radius: 20, y: 10)
        }
        .disabled(!canVerify || loading)
        .buttonStyle(PressScaleStyle())
    }

    private var resendRow: some View {
        Button { resend() } label: {
            Text(resending ? "Sending…" : "Didn't get a code? Send again")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.bronze)
                .frame(maxWidth: .infinity)
        }
        .disabled(resending)
        .buttonStyle(PressScaleStyle())
    }

    private func verify() {
        loading = true; errorMessage = nil; info = nil
        Task { @MainActor in
            do {
                try await auth.confirmSignUp(code: code)
                dismiss() // auth state flips to .signedIn
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            loading = false
        }
    }

    private func resend() {
        resending = true; errorMessage = nil; info = nil
        Task { @MainActor in
            do {
                try await auth.resendSignUpCode()
                info = "Sent a new code to \(email)."
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            resending = false
        }
    }
}

// MARK: - Friends

/// Small round avatar: remote image if present, else a tinted initial.
private struct FriendAvatar: View {
    let name: String
    let avatarURL: String?
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Circle().fill(Color.whiskey.opacity(0.18))
            initial
            if let s = avatarURL, let url = URL(string: s) {
                DownsampledAsyncImage(url: url, targetPoints: size, placeholder: .clear)
                    .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(Color.cream.opacity(0.12), lineWidth: 1))
    }

    private var initial: some View {
        Text(name.isEmpty ? "?" : String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
            .foregroundStyle(Color.cream.opacity(0.85))
    }
}

/// Friends hub: set your @username, search + add friends, accept incoming
/// requests, and see your roster. Backed by FriendsService (migration 018).
private struct FriendsView: View {
    @ObservedObject var friends: FriendsService
    @ObservedObject var auth: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [UserSearchHit] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var banner: String?
    @State private var showUsernameEditor = false

    private var myUsername: String? {
        if case .signedIn(let p) = auth.state { return p.username }
        return nil
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AtmosphereBackground(accent: .whiskey)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    usernameCard
                    addFriendSection
                    if !results.isEmpty { resultsSection }
                    if !friends.incoming.isEmpty { requestsSection }
                    friendsSection
                }
                .padding(.horizontal, 24)
                .padding(.top, 52)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.cream.opacity(0.8))
                    .padding(12)
                    .background(Circle().fill(Color.cream.opacity(0.08)))
            }
            .padding(.top, 16).padding(.trailing, 20)
            .buttonStyle(PressScaleStyle())
        }
        .preferredColorScheme(.dark)
        .presentationDragIndicator(.visible)
        .onAppear { Task { await friends.refresh() } }
        .onChange(of: query) { _, q in
            searchTask?.cancel()
            let trimmed = q.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { results = []; return }
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
                let hits = await friends.search(trimmed)
                if !Task.isCancelled { results = hits }
            }
        }
        .sheet(isPresented: $showUsernameEditor) {
            UsernameEditorView(auth: auth)
                .presentationDetents([.height(340)])
                .presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("YOUR CREW")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(2.4).foregroundStyle(Color.bronze)
            Text("Friends")
                .font(.system(size: 32, weight: .black, design: .rounded))
                .italic().tracking(-1).foregroundStyle(Color.cream)
        }
    }

    // Your handle — prompts to set one if missing (you can't be found without it).
    private var usernameCard: some View {
        Button { showUsernameEditor = true } label: {
            HStack(spacing: 12) {
                Image(systemName: myUsername == nil ? "exclamationmark.circle.fill" : "at")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.whiskey)
                VStack(alignment: .leading, spacing: 2) {
                    Text(myUsername == nil ? "Pick a username" : "@\(myUsername!)")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.cream)
                    Text(myUsername == nil ? "So friends can find and add you." : "Tap to change your handle.")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.6))
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.bronze)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.whiskey.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.whiskey.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(PressScaleStyle())
    }

    private var addFriendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ADD A FRIEND")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(2).foregroundStyle(Color.bronze)
            LoungeField(label: "USERNAME", text: $query,
                        placeholder: "search by @username", autocapitalize: false)
            if let banner {
                Text(banner)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.8))
            }
        }
    }

    private var resultsSection: some View {
        VStack(spacing: 8) {
            ForEach(results) { hit in
                HStack(spacing: 12) {
                    FriendAvatar(name: hit.name, avatarURL: hit.avatarURL)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(hit.name).font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.cream)
                        if let u = hit.username {
                            Text("@\(u)").font(.system(size: 12, design: .rounded))
                                .foregroundStyle(Color.cream.opacity(0.55))
                        }
                    }
                    Spacer()
                    relationButton(hit)
                }
                .padding(.vertical, 8).padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.cream.opacity(0.04)))
            }
        }
    }

    @ViewBuilder
    private func relationButton(_ hit: UserSearchHit) -> some View {
        switch hit.relation {
        case "friend":
            tag("FRIENDS", filled: false)
        case "outgoing":
            tag("REQUESTED", filled: false)
        case "incoming":
            Button { Task { await act(username: hit.username) } } label: { tag("ACCEPT", filled: true) }
                .buttonStyle(PressScaleStyle())
        default:
            Button { Task { await act(username: hit.username) } } label: { tag("ADD", filled: true) }
                .buttonStyle(PressScaleStyle())
        }
    }

    private func tag(_ text: String, filled: Bool) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .black, design: .monospaced)).tracking(1.4)
            .foregroundStyle(filled ? Color.ink : Color.bronze)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(filled ? Color.cream : Color.clear))
            .overlay(Capsule().strokeBorder(filled ? Color.clear : Color.bronze.opacity(0.5), lineWidth: 1))
    }

    private func act(username: String?) async {
        guard let username else { return }
        banner = nil
        if let err = await friends.sendRequest(username: username) {
            banner = err
        }
        // Refresh search annotations so the row flips to Requested/Friends.
        results = await friends.search(query.trimmingCharacters(in: .whitespaces))
    }

    private var requestsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("REQUESTS")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(2).foregroundStyle(Color.bronze)
            ForEach(friends.incoming) { req in
                HStack(spacing: 12) {
                    FriendAvatar(name: req.name, avatarURL: req.avatarURL)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(req.name).font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.cream)
                        if let u = req.username {
                            Text("@\(u)").font(.system(size: 12, design: .rounded))
                                .foregroundStyle(Color.cream.opacity(0.55))
                        }
                    }
                    Spacer()
                    Button { Task { await friends.respond(requestId: req.requestId, accept: true) } } label: {
                        tag("ACCEPT", filled: true)
                    }.buttonStyle(PressScaleStyle())
                    Button { Task { await friends.respond(requestId: req.requestId, accept: false) } } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.bronze).padding(8)
                            .background(Circle().fill(Color.cream.opacity(0.06)))
                    }.buttonStyle(PressScaleStyle())
                }
                .padding(.vertical, 8).padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.whiskey.opacity(0.06)))
            }
        }
    }

    private var friendsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FRIENDS · \(friends.friends.count)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(2).foregroundStyle(Color.bronze)
            if friends.friends.isEmpty {
                Text("No friends yet. Search a username above to add someone.")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.5))
                    .padding(.vertical, 8)
            } else {
                ForEach(friends.friends) { friend in
                    HStack(spacing: 12) {
                        FriendAvatar(name: friend.name, avatarURL: friend.avatarURL)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(friend.name).font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.cream)
                            if let u = friend.username {
                                Text("@\(u)").font(.system(size: 12, design: .rounded))
                                    .foregroundStyle(Color.cream.opacity(0.55))
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8).padding(.horizontal, 12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.cream.opacity(0.04)))
                    .contextMenu {
                        Button(role: .destructive) {
                            Task { await friends.remove(userId: friend.id) }
                        } label: { Label("Remove friend", systemImage: "person.badge.minus") }
                    }
                }
            }
        }
    }
}

/// Sheet to set / change your @username.
private struct UsernameEditorView: View {
    @ObservedObject var auth: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var saving = false
    @State private var errorMessage: String?

    private var cleaned: String { username.lowercased().trimmingCharacters(in: .whitespaces) }
    private var valid: Bool { cleaned.range(of: "^[a-z0-9_]{3,20}$", options: .regularExpression) != nil }

    init(auth: AuthService) {
        self.auth = auth
        if case .signedIn(let p) = auth.state, let u = p.username {
            _username = State(initialValue: u)
        }
    }

    var body: some View {
        ZStack {
            AtmosphereBackground(accent: .whiskey)
            VStack(alignment: .leading, spacing: 16) {
                Text("YOUR USERNAME")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(2.4).foregroundStyle(Color.bronze)
                Text("Pick a handle")
                    .font(.system(size: 26, weight: .black, design: .rounded))
                    .italic().foregroundStyle(Color.cream)
                LoungeField(label: "USERNAME", text: $username,
                            placeholder: "yourname", autocapitalize: false)
                Text("3–20 characters · lowercase letters, numbers, underscore")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.5))
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Status.drunk.color)
                }
                Button { save() } label: {
                    HStack {
                        if saving { ProgressView().tint(Color.ink); Spacer() }
                        else {
                            Text("SAVE").font(.system(size: 13, weight: .bold, design: .monospaced)).tracking(3)
                            Spacer()
                            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                        }
                    }
                    .foregroundStyle(Color.ink).padding(.vertical, 15).padding(.horizontal, 20)
                    .background(RoundedRectangle(cornerRadius: 16).fill(valid ? Color.cream : Color.cream.opacity(0.4)))
                }
                .disabled(!valid || saving)
                .buttonStyle(PressScaleStyle())
            }
            .padding(24)
        }
        .preferredColorScheme(.dark)
    }

    private func save() {
        saving = true; errorMessage = nil
        Task { @MainActor in
            if let err = await auth.setUsername(cleaned) {
                errorMessage = err
            } else {
                dismiss()
            }
            saving = false
        }
    }
}

/// Invite people to the current sesh: search anyone by @username (display
/// name shown too) or multi-select from your friends. Sends in-app invites
/// directly via InvitesService.
private struct FriendPickerSheet: View {
    @ObservedObject var friends: FriendsService
    @ObservedObject var invites: InvitesService
    let session: SeshSession
    let scope: SeshMode
    let alreadyIn: Set<UUID>
    @Environment(\.dismiss) private var dismiss

    @State private var selected: Set<UUID> = []
    @State private var query = ""
    @State private var results: [UserSearchHit] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var invited: Set<UUID> = []

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("INVITE TO SESH")
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .tracking(2.4).foregroundStyle(Color.bronze)
                        Text("Search a username or pick friends")
                            .font(.system(size: 22, weight: .black, design: .rounded))
                            .foregroundStyle(Color.cream)
                    }
                    .padding(.top, 8)

                    LoungeField(label: "FIND BY USERNAME", text: $query,
                                placeholder: "search @username", autocapitalize: false)

                    if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                        // Search results — display name + @username.
                        VStack(spacing: 8) {
                            if results.isEmpty {
                                Text("No one with that username.")
                                    .font(.system(size: 12, design: .rounded))
                                    .foregroundStyle(Color.cream.opacity(0.5))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 6)
                            }
                            ForEach(results) { hit in
                                personRow(id: hit.id, name: hit.name, username: hit.username,
                                          avatarURL: hit.avatarURL, trailing: .invite)
                            }
                        }
                    } else {
                        // Friends multi-select.
                        Text("YOUR FRIENDS")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(2).foregroundStyle(Color.bronze)
                        if friends.friends.isEmpty {
                            Text("No friends yet — search a username above, or add friends from the Friends screen.")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.cream.opacity(0.55))
                                .padding(.vertical, 8)
                        } else {
                            VStack(spacing: 8) {
                                ForEach(friends.friends) { friend in
                                    personRow(id: friend.id, name: friend.name, username: friend.username,
                                              avatarURL: friend.avatarURL, trailing: .select)
                                }
                            }
                        }
                    }

                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 24).padding(.bottom, 40)
            }
        }
        // Pinned send bar — always in reach instead of buried below a long
        // friends list.
        .safeAreaInset(edge: .bottom) {
            if query.trimmingCharacters(in: .whitespaces).isEmpty, !friends.friends.isEmpty {
                Button {
                    Task { await invite(Array(selected)) ; dismiss() }
                } label: {
                    HStack {
                        Text(selected.isEmpty ? "SELECT FRIENDS" : "SEND \(selected.count) INVITE\(selected.count == 1 ? "" : "S")")
                            .font(.system(size: 13, weight: .bold, design: .monospaced)).tracking(2)
                        Spacer()
                        Image(systemName: "paperplane.fill").font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(Color.ink)
                    .padding(.vertical, 15).padding(.horizontal, 20)
                    .background(RoundedRectangle(cornerRadius: 16).fill(selected.isEmpty ? Color.cream.opacity(0.4) : Color.cream))
                }
                .disabled(selected.isEmpty)
                .buttonStyle(PressScaleStyle())
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 10)
                .background(Color.ink.opacity(0.97))
            }
        }
        .preferredColorScheme(.dark)
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: query) { _, q in
            searchTask?.cancel()
            let trimmed = q.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { results = []; return }
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
                let hits = await friends.search(trimmed)
                if !Task.isCancelled { results = hits }
            }
        }
    }

    private enum Trailing { case select, invite }

    @ViewBuilder
    private func personRow(id: UUID, name: String, username: String?, avatarURL: String?, trailing: Trailing) -> some View {
        let isIn = alreadyIn.contains(id)
        let isSel = selected.contains(id)
        let isInvited = invited.contains(id)
        Button {
            guard !isIn, !isInvited else { return }
            switch trailing {
            case .select:
                if isSel { selected.remove(id) } else { selected.insert(id) }
            case .invite:
                Task { await invite([id]) }
            }
        } label: {
            HStack(spacing: 12) {
                FriendAvatar(name: name, avatarURL: avatarURL)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.cream)
                    if let u = username {
                        Text("@\(u)").font(.system(size: 12, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.55))
                    }
                }
                Spacer()
                if isIn {
                    Text("IN").font(.system(size: 9, weight: .black, design: .monospaced))
                        .tracking(1.2).foregroundStyle(Color.bronze)
                } else if isInvited {
                    Text("INVITED").font(.system(size: 9, weight: .black, design: .monospaced))
                        .tracking(1.2).foregroundStyle(Color.whiskey)
                } else if trailing == .select {
                    Image(systemName: isSel ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(isSel ? Color.whiskey : Color.cream.opacity(0.4))
                } else {
                    Text("INVITE").font(.system(size: 10, weight: .black, design: .monospaced))
                        .tracking(1.2).foregroundStyle(Color.ink)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().fill(Color.cream))
                }
            }
            .padding(.vertical, 8).padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.cream.opacity(isSel ? 0.07 : 0.04)))
            .opacity(isIn ? 0.5 : 1)
        }
        .buttonStyle(PressScaleStyle())
        .disabled(isIn || isInvited)
    }

    private func invite(_ ids: [UUID]) async {
        guard !ids.isEmpty else { return }
        _ = await invites.send(sessionId: session.id, joinCode: session.joinCode,
                               mode: scope, recipientIds: ids)
        invited.formUnion(ids)
    }
}

// MARK: - Timeline feed UI

private enum RelativeTime {
    static func short(_ iso: String) -> String {
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let date = withFrac.date(from: iso) ?? plain.date(from: iso)
        guard let date else { return "" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

private func recapStopEmoji(_ kind: RecapStopKind) -> String {
    switch kind {
    case .bar:     return "🍻"
    case .preGame: return "🏠"
    case .refuel:  return "🚕"
    case .afters:  return "🌙"
    case .food:    return "🍔"
    case .puke:    return "🤮"
    }
}

// MARK: - Friends live pulse
//
// Friends see each other's night in real time: live or not, drink count,
// current BAC, check-in venue, and — for group seshes — who they're with
// and those people's BACs. Solo sesh data is device-local, so PresenceService
// publishes a compact presence row while a night runs; FriendsPulseService
// reads everyone back through one SECURITY DEFINER RPC that computes all
// BACs server-side (no one's weight/sex ever leaves the database).

/// One friend's live status as returned by the friends_live_pulse RPC.
struct FriendPulse: Decodable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let username: String?
    let avatarUrl: String?
    let live: Bool
    var bac: Double? = nil
    var drinks: Int? = nil
    var venue: String? = nil
    var venueLat: Double? = nil
    var venueLon: Double? = nil
    var startedEpoch: Double? = nil
    var members: [PulseMember]? = nil

    var startedAt: Date? { startedEpoch.map { Date(timeIntervalSince1970: $0) } }
    var venueCoordinate: CLLocationCoordinate2D? {
        guard let lat = venueLat, let lon = venueLon else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, username, live, bac, drinks, venue, members
        case avatarUrl = "avatar_url"
        case venueLat = "venue_lat"
        case venueLon = "venue_lon"
        case startedEpoch = "started_epoch"
    }
}

/// A co-member of a friend's group sesh (name + their BAC + drink count).
struct PulseMember: Decodable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let avatarUrl: String?
    let bac: Double
    let drinks: Int
    enum CodingKeys: String, CodingKey {
        case id, name, bac, drinks
        case avatarUrl = "avatar_url"
    }
}

/// Publishes MY live status so friends can see it. Solo nights upload a
/// compact [{t, g}] drink array (they exist only on-device otherwise);
/// group nights just point at the session — the drinks are already
/// server-side. The row is deleted the moment the night ends. Payloads
/// are deduped so poll-driven onChange storms don't spam the table.
@MainActor
final class PresenceService: ObservableObject {
    private var lastKey = ""
    private var myId: UUID? { supabase.auth.currentUser?.id }

    private struct DrinkEvent: Encodable { let t: String; let g: Double }
    private struct Row: Encodable {
        let user_id: String
        let started_at: String
        let venue_name: String?
        let venue_lat: Double?
        let venue_lon: Double?
        let session_id: String?
        let drinks: [DrinkEvent]
        let updated_at: String
    }

    func publish(startedAt: Date?, drinks: [LiveDrink], venueName: String?,
                 venueLat: Double? = nil, venueLon: Double? = nil, sessionId: UUID?) async {
        guard let uid = myId else { return }
        // Not live in any form → tear the presence row down.
        guard startedAt != nil || sessionId != nil else {
            if lastKey != "off" {
                lastKey = "off"
                _ = try? await supabase.from("live_presence").delete()
                    .eq("user_id", value: uid.uuidString.lowercased())
                    .execute()
            }
            return
        }
        let started = startedAt ?? Date()
        let key = "\(started.timeIntervalSince1970)|\(drinks.count)|\(venueName ?? "")|\(sessionId?.uuidString ?? "")"
        guard key != lastKey else { return }
        lastKey = key
        let iso = ISO8601DateFormatter()
        let row = Row(
            user_id: uid.uuidString.lowercased(),
            started_at: iso.string(from: started),
            venue_name: venueName,
            venue_lat: venueLat,
            venue_lon: venueLon,
            session_id: sessionId?.uuidString.lowercased(),
            drinks: drinks.map { DrinkEvent(t: iso.string(from: $0.consumedAt), g: $0.grams) },
            updated_at: iso.string(from: Date())
        )
        _ = try? await supabase.from("live_presence").upsert(row).execute()
    }
}

/// Pulls every friend's pulse. Polled while the Nightline tab is visible
/// (BACs decay, drinks land) and stopped the moment the user swipes away.
@MainActor
final class FriendsPulseService: ObservableObject {
    @Published private(set) var pulses: [FriendPulse] = []
    private var pollTask: Task<Void, Never>? = nil

    func refresh() async {
        do {
            let all: [FriendPulse] = try await supabase
                .rpc("friends_live_pulse")
                .execute()
                .value
            // Live friends first (highest BAC leading), then the rest A–Z.
            pulses = all.sorted { a, b in
                if a.live != b.live { return a.live }
                if a.live { return (a.bac ?? 0) > (b.bac ?? 0) }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        } catch {
            // Keep the previous pulse on a transient failure.
        }
    }

    func startPolling(every seconds: TimeInterval = 30) {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}

/// Stories-style strip at the top of Nightline: your own story bubble
/// first (post with the +), then friends — live ones glow with their BAC,
/// story-holders get a bronze ring, everyone else sits dimmed. Tapping a
/// friend opens their stories when they have any, else their live pulse.
private struct FriendsPulseStrip: View {
    @ObservedObject var pulse: FriendsPulseService
    @ObservedObject var stories: StoriesService
    let profile: Profile
    /// My BAC / location at the moment of posting (nil = nothing to stamp).
    let storyBAC: () -> Double?
    let storyStamp: () -> String?
    let onOpen: (FriendPulse) -> Void

    @State private var cameraOpen = false
    @State private var libraryOpen = false
    @State private var pickerItem: PhotosPickerItem? = nil
    @State private var staged: StagedStoryImage? = nil
    @State private var viewerCtx: StoryViewerContext? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TONIGHT")
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(2.4)
                .foregroundStyle(Color.bronze)
                .padding(.horizontal, 22)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    myBubble
                    ForEach(pulse.pulses) { p in
                        let theirStories = stories.stories(for: p.id)
                        PulseAvatar(pulse: p, hasStory: !theirStories.isEmpty)
                            .onTapGesture {
                                if !theirStories.isEmpty {
                                    viewerCtx = StoryViewerContext(
                                        stories: theirStories, name: p.name,
                                        avatarUrl: p.avatarUrl, canDelete: false
                                    )
                                } else if p.live {
                                    onOpen(p)
                                }
                            }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 2)
            }
        }
        .fullScreenCover(isPresented: $cameraOpen) {
            CameraCaptureView { data in staged = StagedStoryImage(data: data) }
                .ignoresSafeArea()
        }
        .photosPicker(isPresented: $libraryOpen, selection: $pickerItem, matching: .images)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    staged = StagedStoryImage(data: data)
                }
                pickerItem = nil
            }
        }
        .sheet(item: $staged) { img in
            StoryComposer(
                imageData: img.data,
                bac: storyBAC(),
                stamp: storyStamp(),
                onPost: { caption, bac, stamp in
                    staged = nil
                    Task { await stories.post(imageData: img.data, caption: caption, bac: bac, stamp: stamp) }
                },
                onCancel: { staged = nil }
            )
            .presentationDetents([.large])
            .presentationBackground(Color.ink)
        }
        .fullScreenCover(item: $viewerCtx) { ctx in
            StoryViewer(
                ctx: ctx,
                onDelete: { story in Task { await stories.delete(story) } },
                onClose: { viewerCtx = nil }
            )
        }
    }

    /// My avatar: bronze ring when I have live stories (tap to review /
    /// delete), whiskey "+" badge to post a new one (camera, else library).
    private var myBubble: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                AvatarView(urlString: profile.avatarURL,
                           initial: String(profile.name.prefix(1)).uppercased(),
                           size: 54)
                    .overlay(
                        Circle().strokeBorder(
                            stories.mine.isEmpty ? Color.clear : Color.bronze,
                            lineWidth: 2.5
                        )
                        .padding(-3)
                    )
                    .onTapGesture {
                        let mine = stories.mine
                        if mine.isEmpty {
                            openCapture()
                        } else {
                            viewerCtx = StoryViewerContext(
                                stories: mine, name: profile.name,
                                avatarUrl: profile.avatarURL, canDelete: true
                            )
                        }
                    }
                Button(action: openCapture) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(Color.ink)
                        .frame(width: 19, height: 19)
                        .background(Circle().fill(Color.whiskey))
                        .overlay(Circle().strokeBorder(Color.ink, lineWidth: 2))
                }
                .buttonStyle(PressScaleStyle())
                .offset(x: 4, y: 4)
            }
            .padding(.top, 4)
            .padding(.horizontal, 8)
            .padding(.bottom, 9)
            Text("Your story")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.6))
                .lineLimit(1)
        }
        .frame(width: 72)
    }

    private func openCapture() {
        if CameraCaptureView.isAvailable { cameraOpen = true } else { libraryOpen = true }
    }
}

/// One avatar in the strip: live friends get a status-coloured ring +
/// BAC pill; offline friends are dimmed with no badge.
private struct PulseAvatar: View {
    let pulse: FriendPulse
    /// They have fresh stories → bronze ring, full opacity, tappable even
    /// when not live.
    var hasStory: Bool = false
    /// BAC arrives on the raw %-scale; display follows the VIEWER's unit
    /// preference (percent vs promille), same as everywhere else in the app.
    @AppStorage(BACUnitSetting.key, store: BACUnitSetting.store) private var bacUnitMode = "auto"
    private var unit: BACUnit { BACUnitSetting.resolved(mode: bacUnitMode) }

    private var status: Status {
        switch pulse.bac ?? 0 {
        case ..<0.02: return .sober
        case 0.02..<0.05: return .buzzed
        case 0.05..<0.08: return .impaired
        case 0.08..<0.15: return .drunk
        default: return .danger
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                AvatarView(urlString: pulse.avatarUrl,
                           initial: String(pulse.name.prefix(1)).uppercased(),
                           size: 54)
                    .overlay(
                        Circle().strokeBorder(
                            pulse.live ? status.color : (hasStory ? Color.bronze : Color.clear),
                            lineWidth: 2.5
                        )
                        .padding(-3)
                    )
                    .opacity((pulse.live || hasStory) ? 1 : 0.45)
                if pulse.live {
                    Text(unit.formatted(pulse.bac ?? 0))
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(status.color))
                        .offset(x: 6, y: 6)
                }
            }
            // Breathing room for the parts that render OUTSIDE the 54pt
            // circle — the ring (3pt up/sides) and the BAC pill (below,
            // right) — so the ScrollView doesn't crop them.
            .padding(.top, 4)
            .padding(.horizontal, 8)
            .padding(.bottom, 9)
            Text(pulse.name.split(separator: " ").first.map(String.init) ?? pulse.name)
                .font(.system(size: 11, weight: pulse.live ? .bold : .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(pulse.live ? 0.95 : 0.45))
                .lineLimit(1)
        }
        .frame(width: 72)
    }
}

/// Detail sheet for a live friend: BAC + status, drinks, venue, elapsed
/// time — and, for a group sesh, everyone they're with + those BACs.
private struct FriendPulseSheet: View {
    let pulse: FriendPulse
    /// Display in the VIEWER's unit (percent vs promille) — the RPC always
    /// sends the raw %-scale value.
    @AppStorage(BACUnitSetting.key, store: BACUnitSetting.store) private var bacUnitMode = "auto"
    private var unit: BACUnit { BACUnitSetting.resolved(mode: bacUnitMode) }
    /// Expanded mini-map for the check-in venue.
    @State private var venueMapOpen = false

    private func statusFor(_ bac: Double) -> Status {
        switch bac {
        case ..<0.02: return .sober
        case 0.02..<0.05: return .buzzed
        case 0.05..<0.08: return .impaired
        case 0.08..<0.15: return .drunk
        default: return .danger
        }
    }

    var body: some View {
        let bac = pulse.bac ?? 0
        let status = statusFor(bac)
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    AvatarView(urlString: pulse.avatarUrl,
                               initial: String(pulse.name.prefix(1)).uppercased(),
                               size: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pulse.name)
                            .font(.system(size: 19, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color.cream)
                        HStack(spacing: 5) {
                            Circle().fill(status.color).frame(width: 7, height: 7)
                            Text(liveLine)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.cream.opacity(0.6))
                        }
                    }
                    Spacer()
                }

                // The number you opened this for.
                VStack(alignment: .leading, spacing: 2) {
                    Text("BAC NOW")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .tracking(2.2).foregroundStyle(Color.bronze)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(unit.formatted(bac))
                            .font(.system(size: 46, weight: .black, design: .rounded))
                            .foregroundStyle(status.color)
                        Text(unit.caption)
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .tracking(1.6)
                            .foregroundStyle(status.color.opacity(0.6))
                        Text(status.label.uppercased())
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .tracking(1.6)
                            .foregroundStyle(status.color.opacity(0.85))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.cream.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.cream.opacity(0.08), lineWidth: 1))

                HStack(spacing: 10) {
                    statChip(icon: "wineglass.fill", label: "\(pulse.drinks ?? 0) \(pulse.drinks == 1 ? "drink" : "drinks")")
                    if let venue = pulse.venue, !venue.isEmpty {
                        if pulse.venueCoordinate != nil {
                            Button {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                                    venueMapOpen.toggle()
                                }
                            } label: {
                                statChip(icon: "mappin.circle.fill", label: venue,
                                         trailing: venueMapOpen ? "chevron.up" : "chevron.down")
                            }
                            .buttonStyle(PressScaleStyle())
                        } else {
                            statChip(icon: "mappin.circle.fill", label: venue)
                        }
                    }
                }

                if venueMapOpen, let coord = pulse.venueCoordinate {
                    Map(initialPosition: .region(MKCoordinateRegion(
                        center: coord,
                        latitudinalMeters: 900, longitudinalMeters: 900
                    ))) {
                        Marker(pulse.venue ?? "", systemImage: "wineglass.fill", coordinate: coord)
                            .tint(Color.whiskey)
                    }
                    .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
                    .frame(height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.cream.opacity(0.1), lineWidth: 1))
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if let members = pulse.members, !members.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("GROUP SESH · WITH \(members.count)")
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                            .tracking(2.2).foregroundStyle(Color.bronze)
                        ForEach(members) { m in
                            let ms = statusFor(m.bac)
                            HStack(spacing: 10) {
                                AvatarView(urlString: m.avatarUrl,
                                           initial: String(m.name.prefix(1)).uppercased(),
                                           size: 34)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(m.name)
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                        .foregroundStyle(Color.cream)
                                    Text("\(m.drinks) \(m.drinks == 1 ? "drink" : "drinks")")
                                        .font(.system(size: 11, weight: .medium, design: .rounded))
                                        .foregroundStyle(Color.cream.opacity(0.5))
                                }
                                Spacer()
                                Text(unit.formatted(m.bac))
                                    .font(.system(size: 14, weight: .black, design: .monospaced))
                                    .foregroundStyle(ms.color)
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cream.opacity(0.04)))
                        }
                    }
                }
            }
            .padding(20)
            .padding(.top, 6)
        }
        .background(Color.ink)
    }

    private var liveLine: String {
        guard let started = pulse.startedAt else { return "Live now" }
        let mins = max(0, Int(Date().timeIntervalSince(started) / 60))
        if mins < 60 { return "Live · started \(mins)m ago" }
        return "Live · started \(mins / 60)h \(mins % 60)m ago"
    }

    private func statChip(icon: String, label: String, trailing: String? = nil) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.whiskey)
            Text(label)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Color.cream)
                .lineLimit(1)
            if let trailing {
                Image(systemName: trailing)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.cream.opacity(0.5))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Capsule().fill(Color.cream.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.cream.opacity(0.1), lineWidth: 1))
    }
}

// MARK: - Group snaps
//
// Members of a live group sesh share their Night Snaps photos with the
// group. Uploads are heavily compressed (~1280px JPEG) and EPHEMERAL —
// a daily server job purges anything older than 48h — so the feature
// stays nearly free on storage (a big night ≈ a few MB, gone in two days).

struct SessionSnap: Decodable, Identifiable, Equatable {
    let id: UUID
    let sessionId: UUID
    let profileId: UUID
    let stopName: String?
    let storagePath: String
    let createdAt: Date

    var url: URL? {
        try? supabase.storage.from("session-snaps").getPublicURL(path: storagePath)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case profileId = "profile_id"
        case stopName = "stop_name"
        case storagePath = "storage_path"
        case createdAt = "created_at"
    }
}

@MainActor
final class SessionSnapsService: ObservableObject {
    @Published private(set) var snaps: [SessionSnap] = []
    private var myId: UUID? { supabase.auth.currentUser?.id }

    func refresh(sessionId: UUID) async {
        do {
            let rows: [SessionSnap] = try await supabase.from("session_snaps")
                .select()
                .eq("session_id", value: sessionId.uuidString.lowercased())
                .order("created_at", ascending: false)
                .execute()
                .value
            snaps = rows
        } catch {
            // Keep the previous list on a transient failure.
        }
    }

    func clear() { snaps = [] }

    /// Compress + upload one photo and register it for the group. The
    /// 1280px/q0.62 target lands around 150–250 KB per snap — the lever
    /// that keeps the whole feature nearly free on storage.
    func upload(imageData: Data, stopName: String?, sessionId: UUID) async {
        guard let uid = myId,
              let jpeg = RecapPhotoUtil.compressedJPEG(imageData, maxDimension: 1280, quality: 0.62)
        else { return }
        let path = "\(sessionId.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
        struct Row: Encodable {
            let session_id: String
            let profile_id: String
            let stop_name: String?
            let storage_path: String
        }
        do {
            _ = try await supabase.storage.from("session-snaps")
                .upload(path, data: jpeg, options: FileOptions(contentType: "image/jpeg"))
            let inserted: SessionSnap = try await supabase.from("session_snaps")
                .insert(Row(
                    session_id: sessionId.uuidString.lowercased(),
                    profile_id: uid.uuidString.lowercased(),
                    stop_name: stopName,
                    storage_path: path
                ))
                .select()
                .single()
                .execute()
                .value
            snaps.insert(inserted, at: 0)
        } catch {
            // Nothing local to roll back; the next schnap tries again.
        }
    }

    /// Only the uploader can delete their schnap (RLS enforces the same
    /// rule server-side on both the row and the storage object).
    func canDelete(_ snap: SessionSnap) -> Bool {
        snap.profileId == myId
    }

    func delete(_ snap: SessionSnap) async {
        guard canDelete(snap) else { return }
        _ = try? await supabase.storage.from("session-snaps").remove(paths: [snap.storagePath])
        _ = try? await supabase.from("session_snaps").delete()
            .eq("id", value: snap.id.uuidString.lowercased())
            .execute()
        snaps.removeAll { $0.id == snap.id }
    }
}

/// Horizontal strip of the group's shared snaps, shown on the LIVE page
/// while in a group. Squad schnaps are captured HERE (camera/library) and
/// go only to the group — deliberately separate from the personal Night
/// Schnaps journey so they never appear in recaps or Nightline posts.
/// Polls while visible; tap a snap for the full-screen viewer.
struct GroupSnapsStrip: View {
    @ObservedObject var snaps: SessionSnapsService
    let sessionId: UUID
    /// Current check-in label stamped onto uploads (nil = between bars).
    let stopName: () -> String?
    /// Resolves an uploader id to a display name (group roster lookup).
    let nameFor: (UUID) -> String
    /// Resolves an uploader id to their avatar URL (nil → initial shows).
    let avatarFor: (UUID) -> String?
    /// Copies a schnap (image data + its original timestamp) into MY night
    /// journey — squad schnaps are purged when the sesh ends, so saving is
    /// how a member keeps one for their recap.
    let saveToJourney: (Data, Date) -> Void
    @State private var viewer: SessionSnap? = nil
    @State private var cameraOpen = false
    @State private var libraryOpen = false
    @State private var pickerItem: PhotosPickerItem? = nil
    /// Schnaps already saved this session — hides the save affordance so a
    /// double-tap can't duplicate the photo in the journey.
    @State private var savedIds: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "photo.stack.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.whiskey)
                Text("SQUAD SCHNAPS")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(2.2)
                    .foregroundStyle(Color.bronze)
                Spacer()
                captureButton(icon: "camera.fill") {
                    if CameraCaptureView.isAvailable { cameraOpen = true } else { libraryOpen = true }
                }
                captureButton(icon: "photo.on.rectangle") { libraryOpen = true }
            }
            if snaps.snaps.isEmpty {
                Text("Schnap one here to share it with the group. Save the ones you want to keep — the rest vanish when the sesh ends.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.45))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(snaps.snaps) { snap in
                            Button { viewer = snap } label: {
                                // Uniform square tiles (same format as the
                                // NIGHT SCHNAPS strip above) — mixed aspect
                                // ratios made the strip look ragged. The
                                // full uncropped photo is one tap away.
                                DownsampledAsyncImage(url: snap.url, targetPoints: 96)
                                    .frame(width: 96, height: 96)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .overlay(alignment: .bottomLeading) {
                                        // Uploader badge: their profile
                                        // photo, falling back to their
                                        // initial (AvatarView's built-in
                                        // fallback).
                                        AvatarView(
                                            urlString: avatarFor(snap.profileId),
                                            initial: String(nameFor(snap.profileId).prefix(1)).uppercased(),
                                            size: 20
                                        )
                                        .padding(5)
                                    }
                                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(Color.cream.opacity(0.1), lineWidth: 1))
                            }
                            .buttonStyle(PressScaleStyle())
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.cream.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.cream.opacity(0.08), lineWidth: 1))
        // Structured poll: starts on appear / session change, dies with the
        // view — no dangling timers when the group ends or the tab unloads.
        .task(id: sessionId) {
            while !Task.isCancelled {
                await snaps.refresh(sessionId: sessionId)
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
        .fullScreenCover(item: $viewer) { snap in
            GroupSnapViewer(
                snap: snap,
                name: nameFor(snap.profileId),
                isSaved: savedIds.contains(snap.id),
                onSave: {
                    guard !savedIds.contains(snap.id), let url = snap.url else { return }
                    savedIds.insert(snap.id)
                    Task {
                        if let (data, _) = try? await URLSession.shared.data(from: url) {
                            saveToJourney(data, snap.createdAt)
                        } else {
                            // Download failed — let them try again.
                            savedIds.remove(snap.id)
                        }
                    }
                },
                onDelete: snaps.canDelete(snap) ? {
                    Task { await snaps.delete(snap) }
                    viewer = nil
                } : nil,
                onClose: { viewer = nil }
            )
        }
        .fullScreenCover(isPresented: $cameraOpen) {
            CameraCaptureView { data in
                Task { await snaps.upload(imageData: data, stopName: stopName(), sessionId: sessionId) }
            }
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $libraryOpen, selection: $pickerItem, matching: .images)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await snaps.upload(imageData: data, stopName: stopName(), sessionId: sessionId)
                }
                pickerItem = nil
            }
        }
    }

    private func captureButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.whiskey)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.cream.opacity(0.07)))
                .overlay(Circle().strokeBorder(Color.whiskey.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// Full-screen viewer for one shared snap. `onDelete` is non-nil only for
/// the uploader's own schnaps; `onSave` copies the schnap into MY journey
/// (squad schnaps vanish when the sesh ends — saving is how you keep one).
private struct GroupSnapViewer: View {
    let snap: SessionSnap
    let name: String
    var isSaved: Bool = false
    var onSave: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    let onClose: () -> Void

    @State private var saved = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            DownsampledAsyncImage(url: snap.url, targetPoints: 700, fill: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    Text(name)
                        .font(.system(size: 14, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.cream)
                    if let stop = snap.stopName, !stop.isEmpty {
                        Text("· \(stop)")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.6))
                    }
                    Text(snap.createdAt, style: .time)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.cream.opacity(0.5))
                }
                .padding(.bottom, 26)
            }
            HStack(spacing: 10) {
                if let onSave {
                    Button {
                        guard !saved && !isSaved else { return }
                        saved = true
                        onSave()
                    } label: {
                        Image(systemName: (saved || isSaved) ? "checkmark" : "square.and.arrow.down")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle((saved || isSaved) ? Color.ink : Color.cream)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill((saved || isSaved) ? Color.whiskey : Color.ink.opacity(0.7)))
                    }
                    .buttonStyle(PressScaleStyle())
                }
                if let onDelete {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.cream)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.ink.opacity(0.7)))
                    }
                    .buttonStyle(PressScaleStyle())
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.cream)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color.ink.opacity(0.7)))
                }
                .buttonStyle(PressScaleStyle())
            }
            .padding(16)
        }
    }
}

// MARK: - Live stories
//
// A photo posted to the TONIGHT strip for your friends, optionally stamped
// with your at-the-moment BAC, a caption, and where you are (check-in,
// pre-game, or between-bars). Ephemeral: visible for 24h (RLS filters
// reads), then purged by the daily cleanup job (rows + storage).

struct LiveStory: Decodable, Identifiable, Equatable {
    let id: UUID
    let profileId: UUID
    let storagePath: String
    let caption: String?
    let bac: Double?
    let stamp: String?
    let createdAt: Date

    var url: URL? {
        try? supabase.storage.from("stories").getPublicURL(path: storagePath)
    }

    enum CodingKeys: String, CodingKey {
        case id, caption, bac, stamp
        case profileId = "profile_id"
        case storagePath = "storage_path"
        case createdAt = "created_at"
    }
}

@MainActor
final class StoriesService: ObservableObject {
    /// Every fresh story visible to me (mine + friends'), newest first.
    /// RLS enforces both the friendship gate and the 24h window.
    @Published private(set) var stories: [LiveStory] = []
    private var myId: UUID? { supabase.auth.currentUser?.id }

    var mine: [LiveStory] {
        guard let uid = myId else { return [] }
        return stories(for: uid)
    }

    /// One user's fresh stories, oldest first (viewing order).
    func stories(for profileId: UUID) -> [LiveStory] {
        stories.filter { $0.profileId == profileId }.sorted { $0.createdAt < $1.createdAt }
    }

    func refresh() async {
        do {
            let rows: [LiveStory] = try await supabase.from("live_stories")
                .select()
                .order("created_at", ascending: false)
                .execute()
                .value
            stories = rows
        } catch {
            // Keep the previous list on a transient failure.
        }
    }

    /// Compress + upload + register one story. Same storage discipline as
    /// group schnaps (~1280px JPEG, a couple hundred KB).
    func post(imageData: Data, caption: String?, bac: Double?, stamp: String?) async {
        guard let uid = myId,
              let jpeg = RecapPhotoUtil.compressedJPEG(imageData, maxDimension: 1280, quality: 0.65)
        else { return }
        let path = "\(uid.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
        struct Row: Encodable {
            let profile_id: String
            let storage_path: String
            let caption: String?
            let bac: Double?
            let stamp: String?
        }
        let trimmed = caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await supabase.storage.from("stories")
                .upload(path, data: jpeg, options: FileOptions(contentType: "image/jpeg"))
            let inserted: LiveStory = try await supabase.from("live_stories")
                .insert(Row(
                    profile_id: uid.uuidString.lowercased(),
                    storage_path: path,
                    caption: (trimmed?.isEmpty ?? true) ? nil : trimmed,
                    bac: bac,
                    stamp: stamp
                ))
                .select()
                .single()
                .execute()
                .value
            stories.insert(inserted, at: 0)
        } catch {
            // Next post retries; nothing local to roll back.
        }
    }

    func delete(_ story: LiveStory) async {
        guard story.profileId == myId else { return }
        _ = try? await supabase.storage.from("stories").remove(paths: [story.storagePath])
        _ = try? await supabase.from("live_stories").delete()
            .eq("id", value: story.id.uuidString.lowercased())
            .execute()
        stories.removeAll { $0.id == story.id }
    }
}

/// Image staged for the story composer (Identifiable for sheet(item:)).
private struct StagedStoryImage: Identifiable {
    let id = UUID()
    let data: Data
}

/// Everything the full-screen story viewer needs.
private struct StoryViewerContext: Identifiable {
    let id = UUID()
    let stories: [LiveStory]
    let name: String
    let avatarUrl: String?
    let canDelete: Bool
}

/// Compose sheet: photo preview + caption + toggleable BAC / location
/// stamps captured at post time.
private struct StoryComposer: View {
    let imageData: Data
    let bac: Double?
    let stamp: String?
    let onPost: (_ caption: String?, _ bac: Double?, _ stamp: String?) -> Void
    let onCancel: () -> Void

    @State private var caption = ""
    @State private var includeBAC = true
    @State private var includeStamp = true
    @AppStorage(BACUnitSetting.key, store: BACUnitSetting.store) private var bacUnitMode = "auto"
    private var unit: BACUnit { BACUnitSetting.resolved(mode: bacUnitMode) }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Button("Cancel", action: onCancel)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.6))
                Spacer()
                Text("YOUR STORY")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .tracking(2.2)
                    .foregroundStyle(Color.bronze)
                Spacer()
                Button {
                    onPost(caption,
                           includeBAC ? bac : nil,
                           includeStamp ? stamp : nil)
                } label: {
                    Text("POST")
                        .font(.system(size: 13, weight: .black, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Capsule().fill(Color.whiskey))
                }
                .buttonStyle(PressScaleStyle())
            }

            if let img = UIImage(data: imageData) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 340)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }

            // What gets stamped on the story — tap to include/exclude.
            HStack(spacing: 10) {
                if let bac {
                    stampChip(
                        icon: "gauge.medium",
                        label: "\(unit.formatted(bac))\(unit.symbol)",
                        on: includeBAC
                    ) { includeBAC.toggle() }
                }
                if let stamp, !stamp.isEmpty {
                    stampChip(icon: "mappin.circle.fill", label: stamp, on: includeStamp) {
                        includeStamp.toggle()
                    }
                }
                Spacer()
            }

            TextField("Add a caption…", text: $caption, axis: .vertical)
                .lineLimit(1...3)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cream.opacity(0.06)))

            Spacer()
        }
        .padding(18)
        .background(Color.ink)
    }

    private func stampChip(icon: String, label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: on ? "checkmark.circle.fill" : icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(on ? Color.ink : Color.whiskey)
                Text(label)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(on ? Color.ink : Color.cream.opacity(0.7))
                    .lineLimit(1)
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(Capsule().fill(on ? Color.whiskey : Color.cream.opacity(0.06)))
            .overlay(Capsule().strokeBorder(Color.whiskey.opacity(on ? 0 : 0.4), lineWidth: 1))
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// Full-screen story pager: swipe through one user's fresh stories with
/// their caption, BAC (in the VIEWER's unit) and location stamp.
private struct StoryViewer: View {
    let ctx: StoryViewerContext
    let onDelete: (LiveStory) -> Void
    let onClose: () -> Void

    @State private var index = 0
    @AppStorage(BACUnitSetting.key, store: BACUnitSetting.store) private var bacUnitMode = "auto"
    private var unit: BACUnit { BACUnitSetting.resolved(mode: bacUnitMode) }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(ctx.stories.enumerated()), id: \.element.id) { i, story in
                    storyPage(story).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: ctx.stories.count > 1 ? .automatic : .never))

            HStack(spacing: 10) {
                AvatarView(urlString: ctx.avatarUrl,
                           initial: String(ctx.name.prefix(1)).uppercased(),
                           size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ctx.name)
                        .font(.system(size: 14, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.cream)
                    if ctx.stories.indices.contains(index) {
                        Text(timeAgo(ctx.stories[index].createdAt))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.cream.opacity(0.55))
                    }
                }
                Spacer()
                if ctx.canDelete, ctx.stories.indices.contains(index) {
                    Button {
                        let victim = ctx.stories[index]
                        onDelete(victim)
                        onClose()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.cream)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(Color.ink.opacity(0.7)))
                    }
                    .buttonStyle(PressScaleStyle())
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.cream)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.ink.opacity(0.7)))
                }
                .buttonStyle(PressScaleStyle())
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func storyPage(_ story: LiveStory) -> some View {
        ZStack {
            DownsampledAsyncImage(url: story.url, targetPoints: 700, fill: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack {
                Spacer()
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        if let bac = story.bac {
                            storyBadge(icon: "gauge.medium",
                                       text: "\(unit.formatted(bac))\(unit.symbol)")
                        }
                        if let stamp = story.stamp, !stamp.isEmpty {
                            storyBadge(icon: "mappin.circle.fill", text: stamp)
                        }
                    }
                    if let caption = story.caption, !caption.isEmpty {
                        Text(caption)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.cream)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Capsule().fill(Color.ink.opacity(0.65)))
                    }
                }
                .padding(.bottom, 42)
            }
        }
    }

    private func storyBadge(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.whiskey)
            Text(text)
                .font(.system(size: 12, weight: .black, design: .monospaced))
                .foregroundStyle(Color.cream)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(Color.ink.opacity(0.7)))
    }

    private func timeAgo(_ date: Date) -> String {
        let mins = max(0, Int(Date().timeIntervalSince(date) / 60))
        if mins < 60 { return "\(mins)m ago" }
        return "\(mins / 60)h \(mins % 60)m ago"
    }
}

/// Wires the friends-pulse feature into SessionView as ONE modifier:
/// publishes my presence on anything a friend could notice (drink logged,
/// sesh started/ended, group joined/left, check-in), polls friends' pulse
/// only while the Nightline tab is on screen, and hosts the detail sheet.
private struct PulseWiringModifier: ViewModifier {
    @ObservedObject var live: LiveSeshState
    @ObservedObject var liveGroup: SessionService
    @ObservedObject var venues: VenueService
    @ObservedObject var friendsPulse: FriendsPulseService
    @ObservedObject var stories: StoriesService
    @Binding var openPulse: FriendPulse?
    let tab: TopTab
    let publish: () -> Void
    /// A live sesh terminally ended → SessionView checks out of the venue.
    let onLiveEnded: () -> Void
    /// Journey markers changed (or a group was entered) → mirror them into
    /// the shared route so the group recap sees everyone's stops.
    @ObservedObject var journey: NightJourneyStore
    let syncMarkers: () -> Void
    /// The group's server route changed → merge it into my journey.
    let mergeRoute: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: live.drinks) { _, _ in publish() }
            .onChange(of: live.startedAt) { _, _ in publish() }
            .onChange(of: liveGroup.session?.id) { _, _ in
                publish()
                syncMarkers()
            }
            .onChange(of: venues.currentVenue?.id) { _, _ in publish() }
            .onChange(of: liveGroup.liveEndedToken) { _, _ in onLiveEnded() }
            .onChange(of: journey.stops) { _, _ in syncMarkers() }
            .onChange(of: journey.looseSpots) { _, _ in syncMarkers() }
            .onChange(of: liveGroup.routeStops) { _, _ in mergeRoute() }
            .task {
                publish()
                // Slow app-wide poll so the NIGHTLINE tab dot can light up
                // when a friend goes live, wherever the user is.
                friendsPulse.startPolling(every: 120)
                await stories.refresh()
            }
            .onChange(of: tab) { _, newTab in
                // Fast while the TONIGHT strip is on screen, slow otherwise.
                friendsPulse.startPolling(every: newTab == .timeline ? 30 : 120)
                if newTab == .timeline {
                    Task { await stories.refresh() }
                }
            }
            .sheet(item: $openPulse) { p in
                FriendPulseSheet(pulse: p)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(Color.ink)
            }
    }
}

/// The TIMELINE tab — a scrollable feed of friends' posted nights.
private struct TimelineFeedView: View {
    @ObservedObject var feed: FeedService
    @ObservedObject var pulse: FriendsPulseService
    @ObservedObject var stories: StoriesService
    let profile: Profile
    let storyBAC: () -> Double?
    let storyStamp: () -> String?
    let onOpenPost: (TimelinePost) -> Void
    let onOpenAuthor: (TimelinePost) -> Void
    let onOpenPulse: (FriendPulse) -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                Text("NIGHTLINE")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .tracking(2.4).foregroundStyle(Color.bronze)
                    .padding(.horizontal, 22).padding(.top, 6)

                FriendsPulseStrip(
                    pulse: pulse,
                    stories: stories,
                    profile: profile,
                    storyBAC: storyBAC,
                    storyStamp: storyStamp,
                    onOpen: onOpenPulse
                )

                if feed.posts.isEmpty {
                    emptyState
                } else {
                    ForEach(feed.posts) { post in
                        PostCard(post: post,
                                 onOpenPost: { onOpenPost(post) },
                                 onOpenAuthor: { onOpenAuthor(post) },
                                 onLike: { Task { await feed.toggleLike(post.id) } })
                            .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.bottom, 40)
        }
        .refreshable {
            await feed.refresh()
            await pulse.refresh()
            await stories.refresh()
        }
        // Re-fetch whenever the timeline appears so newly posted (or deleted)
        // nights show up. Stable post/photo ids keep this from resetting the
        // carousels, and downsampled images keep it cheap.
        .onAppear { feed.start(); Task { await feed.refresh() } }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.whiskey.opacity(0.7))
            Text("No posts yet")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(Color.cream)
            Text("When your friends post their nights, they show up here. Add friends, then share your own recap after a night out.")
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.6))
                .multilineTextAlignment(.center).lineSpacing(2)
        }
        .frame(maxWidth: .infinity).padding(.horizontal, 36).padding(.top, 90)
    }
}

/// All of a night's photos paired with the stop they were taken at.
/// `id` is the URL (stable) so SwiftUI doesn't rebuild the carousel — a
/// fresh UUID each render was resetting the pager and reloading every image.
private struct NightPhoto: Identifiable {
    var id: String { url.absoluteString }
    let stop: String
    let url: URL
}

/// Compact straight-line crawl distance, e.g. "820 m" or "1.4 km".
private func crawlDistanceString(_ meters: Double) -> String {
    meters >= 1000
        ? String(format: "%.1f km", meters / 1000)
        : "\(Int(meters.rounded())) m"
}

private func nightPhotos(_ recap: NightRecap) -> [NightPhoto] {
    recap.stops.flatMap { stop in
        stop.photoFilenames.compactMap { s in
            URL(string: s).map { NightPhoto(stop: stop.name, url: $0) }
        }
    }
}

/// Small in-memory cache of already-downsampled images (keyed by URL+size).
private enum RemoteImageCache {
    static let shared: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 80
        // Hard ceiling on decoded-image memory regardless of count — without a
        // cost limit the cache can balloon well past what the count implies.
        c.totalCostLimit = 48 * 1024 * 1024   // 48 MB
        return c
    }()
}

/// Loads a remote image and **downsamples it to the displayed size** via
/// ImageIO before decoding — so a 4000px photo shown at 130px costs ~0.5 MB
/// instead of ~48 MB. Caches the small result. This is the main lever for
/// keeping memory sane across the feed + profile grids.
private struct DownsampledAsyncImage: View {
    let url: URL?
    /// Max dimension in points; multiplied by screen scale for pixels.
    let targetPoints: CGFloat
    var fill: Bool = true
    var placeholder: Color = Color.cream.opacity(0.06)

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                if fill {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(uiImage: image).resizable().scaledToFit()
                }
            } else {
                placeholder
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { return }
        let maxPixels = Int(targetPoints * UIScreen.main.scale)
        let key = "\(url.absoluteString)@\(maxPixels)" as NSString
        if let cached = RemoteImageCache.shared.object(forKey: key) {
            image = cached; return
        }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let down = Self.downsample(data: data, maxPixels: maxPixels) else { return }
        let cost = down.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        RemoteImageCache.shared.setObject(down, forKey: key, cost: cost)
        if !Task.isCancelled { image = down }
    }

    private static func downsample(data: Data, maxPixels: Int) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// One night in the feed. Tapping the author header opens their profile;
/// the photos swipe through the whole night (each tagged with its stop);
/// tapping a photo or the stats opens the full post.
private struct PostCard: View {
    let post: TimelinePost
    let onOpenPost: () -> Void
    let onOpenAuthor: () -> Void
    let onLike: () -> Void

    private var barCount: Int { post.recap.stops.filter { $0.kind == .bar }.count }
    private var photos: [NightPhoto] { nightPhotos(post.recap) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onOpenAuthor) {
                HStack(spacing: 10) {
                    FriendAvatar(name: post.authorName, avatarURL: post.authorAvatar, size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(post.authorName)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.cream)
                        if let u = post.authorUsername {
                            Text("@\(u)").font(.system(size: 11, design: .rounded))
                                .foregroundStyle(Color.cream.opacity(0.5))
                        }
                    }
                    Spacer()
                    Text(RelativeTime.short(post.createdAt))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.bronze)
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleStyle())

            // Swipeable photo carousel — each photo tagged with its stop.
            if !photos.isEmpty {
                TabView {
                    ForEach(photos) { photo in
                        ZStack(alignment: .bottomLeading) {
                            DownsampledAsyncImage(url: photo.url, targetPoints: 420)
                            .frame(maxWidth: .infinity).frame(height: 260).clipped()
                            .overlay(LinearGradient(colors: [.clear, Color.ink.opacity(0.5)],
                                                    startPoint: .center, endPoint: .bottom))

                            HStack(spacing: 5) {
                                Image(systemName: "mappin.circle.fill").font(.system(size: 11))
                                Text(photo.stop)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(Color.cream)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(Color.ink.opacity(0.55)))
                            .padding(12)
                            .padding(.bottom, photos.count > 1 ? 16 : 0) // clear the page dots
                            .contentShape(Rectangle())
                            .onTapGesture { onOpenPost() }
                        }
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: photos.count > 1 ? .automatic : .never))
                .frame(height: 260)
            }

            // Like + comment bar.
            HStack(spacing: 18) {
                Button(action: onLike) {
                    HStack(spacing: 6) {
                        Image(systemName: post.likedByMe ? "heart.fill" : "heart")
                            .font(.system(size: 23, weight: .semibold))
                            .foregroundStyle(post.likedByMe ? Status.drunk.color : Color.cream.opacity(0.85))
                        if post.likeCount > 0 {
                            Text("\(post.likeCount)").foregroundStyle(Color.cream.opacity(0.85))
                        }
                    }
                    // Bigger, more forgiving tap target than the bare icon.
                    .padding(.vertical, 6)
                    .padding(.trailing, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle())
                Button(action: onOpenPost) {
                    HStack(spacing: 6) {
                        Image(systemName: "bubble.right").foregroundStyle(Color.cream.opacity(0.85))
                        if post.commentCount > 0 {
                            Text("\(post.commentCount)").foregroundStyle(Color.cream.opacity(0.85))
                        }
                    }
                }
                .buttonStyle(PressScaleStyle())
                Spacer()
            }
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .padding(.horizontal, 14).padding(.top, 12)

            Button(action: onOpenPost) {
                VStack(alignment: .leading, spacing: 8) {
                    if let caption = post.caption, !caption.isEmpty {
                        Text(caption)
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.92))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack(spacing: 12) {
                        Label("\(barCount) stop\(barCount == 1 ? "" : "s")", systemImage: "mappin.and.ellipse")
                        Label("\(post.recap.totalDrinks)", systemImage: "wineglass")
                        Label(crawlDistanceString(post.recap.crawlMeters), systemImage: "figure.walk")
                        if post.includeBAC {
                            let unit = BACUnitSetting.current()
                            Label("\(unit.formatted(post.recap.peakBAC))\(unit.symbol)", systemImage: "flame.fill")
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.bronze)
                    }
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.8))
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleStyle())
        }
        .background(Color.cream.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.cream.opacity(0.1), lineWidth: 1))
    }
}

/// Lightweight reference to a profile we can open a post grid for.
struct ProfileRef: Identifiable, Equatable {
    let id: UUID
    let name: String
    let username: String?
    let avatar: String?
}

/// Square cover thumbnail for the profile grids. Falls back to a tinted
/// tile with the drink count when a post has no photo.
private struct PostThumb: View {
    let post: TimelinePost
    var body: some View {
        Color.cream.opacity(0.06)
            .overlay {
                if let cover = post.coverURL, let url = URL(string: cover) {
                    DownsampledAsyncImage(url: url, targetPoints: 160)
                } else {
                    VStack(spacing: 4) {
                        Text("🍻").font(.system(size: 22))
                        Text("\(post.recap.totalDrinks)")
                            .font(.system(size: 12, weight: .black, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.8))
                    }
                }
            }
            // Force a strict square cell so the grid is uniform (Instagram-style).
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipped()
            .overlay(Rectangle().strokeBorder(Color.ink, lineWidth: 1))
    }
}

/// A profile page: avatar + name + posted-sesh count, with a grid of that
/// user's posts (their full archive). Tap a tile to open the night.
private struct ProfileFeedView: View {
    let user: ProfileRef
    @ObservedObject var feed: FeedService
    @Environment(\.dismiss) private var dismiss

    @State private var posts: [TimelinePost] = []
    @State private var loading = true
    @State private var selectedPost: TimelinePost?

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.ink.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    VStack(spacing: 8) {
                        FriendAvatar(name: user.name, avatarURL: user.avatar, size: 78)
                        Text(user.name)
                            .font(.system(size: 20, weight: .black, design: .rounded))
                            .foregroundStyle(Color.cream)
                        if let u = user.username {
                            Text("@\(u)").font(.system(size: 13, design: .rounded))
                                .foregroundStyle(Color.cream.opacity(0.55))
                        }
                        Text("\(posts.count) sesh\(posts.count == 1 ? "" : "s") posted")
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .tracking(1.6).foregroundStyle(Color.bronze)
                            .padding(.top, 2)
                    }
                    .padding(.top, 40)

                    if loading {
                        ProgressView().tint(Color.whiskey).padding(.top, 40)
                    } else if posts.isEmpty {
                        Text("No posted seshs yet.")
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.5))
                            .padding(.top, 40)
                    } else {
                        LazyVGrid(columns: cols, spacing: 3) {
                            ForEach(posts) { p in
                                Button { selectedPost = p } label: { PostThumb(post: p) }
                                    .buttonStyle(PressScaleStyle())
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 40)
            }

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.cream.opacity(0.85))
                    .padding(12).background(Circle().fill(Color.cream.opacity(0.08)))
            }
            .padding(.top, 16).padding(.trailing, 20)
            .buttonStyle(PressScaleStyle())
        }
        .preferredColorScheme(.dark)
        .task {
            posts = await feed.userPosts(user.id)
            loading = false
        }
        .fullScreenCover(item: $selectedPost, onDismiss: {
            // A delete or BAC toggle in the detail may have changed things.
            Task { posts = await feed.userPosts(user.id) }
        }) { p in
            PostDetailView(post: p, feed: feed) { selectedPost = nil }
        }
    }
}

/// A friend's posted night, full-screen and read-only (remote photos).
/// BAC is shown only if the poster opted to include it.
private struct PostDetailView: View {
    let post: TimelinePost
    var feed: FeedService? = nil
    var history: RecapHistoryStore? = nil
    let onClose: () -> Void

    @State private var gallery: PhotoGallery?
    @State private var liked = false
    @State private var likeCount = 0
    @State private var loadedLike = false
    @State private var comments: [PostComment] = []
    @State private var commentText = ""
    @FocusState private var commentFocused: Bool

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.ink.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        FriendAvatar(name: post.authorName, avatarURL: post.authorAvatar, size: 46)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(post.authorName)
                                .font(.system(size: 18, weight: .black, design: .rounded))
                                .foregroundStyle(Color.cream)
                            Text((post.authorUsername.map { "@\($0)" } ?? "") + " · " + RelativeTime.short(post.createdAt))
                                .font(.system(size: 12, design: .rounded))
                                .foregroundStyle(Color.cream.opacity(0.55))
                        }
                        Spacer()
                        if post.isMine, let feed {
                            Menu {
                                Button {
                                    Task { await feed.setBAC(postId: post.id, include: !post.includeBAC); onClose() }
                                } label: {
                                    Label(post.includeBAC ? "Hide my BAC" : "Show my BAC",
                                          systemImage: post.includeBAC ? "eye.slash" : "eye")
                                }
                                // Archive MOVES the post to Past nights: it's
                                // taken off the timeline and kept privately.
                                // Local recap is keyed by the recap id (which
                                // lives inside the post), not the posts row id.
                                if let history, let local = history.localRecap(for: post.recap.id) {
                                    Button {
                                        Task {
                                            history.archive(local)             // -> Past nights
                                            history.unmarkPosted(post.recap.id)
                                            await feed.deletePost(post.id)     // off the timeline
                                            onClose()
                                        }
                                    } label: {
                                        Label("Move to Past nights", systemImage: "tray.and.arrow.down")
                                    }
                                }
                                Button(role: .destructive) {
                                    Task {
                                        await feed.deletePost(post.id)
                                        history?.unmarkPosted(post.recap.id)
                                        onClose()
                                    }
                                } label: {
                                    Label("Delete post", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(Color.cream.opacity(0.8))
                                    .frame(width: 34, height: 34)
                                    .background(Circle().fill(Color.cream.opacity(0.08)))
                            }
                            .padding(.trailing, 44) // clear the close button
                        }
                    }

                    if let caption = post.caption, !caption.isEmpty {
                        Text(caption)
                            .font(.system(size: 15, design: .rounded))
                            .foregroundStyle(Color.cream)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineSpacing(2)
                    }

                    HStack(spacing: 10) {
                        stat("\(post.recap.stops.filter { $0.kind == .bar }.count)", "stops")
                        stat("\(post.recap.totalDrinks)", "drinks")
                        stat(crawlDistanceString(post.recap.crawlMeters), "crawled")
                        if post.includeBAC {
                            let unit = BACUnitSetting.current()
                            stat("\(unit.formatted(post.recap.peakBAC))\(unit.symbol)", "peak")
                        }
                    }

                    // Where the night went — located stops + the route line.
                    if post.recap.hasMap {
                        let coords = post.recap.locatedStops.compactMap { $0.coordinate }
                        // A single stop has no bounding box, so `.automatic`
                        // zooms to the max and loses all context — frame it to
                        // the surrounding neighbourhood instead. Multiple stops
                        // fit the whole route. `initialPosition` (not `position`)
                        // sets the start but leaves the camera free, so users
                        // can pan + zoom from there.
                        let initialCamera: MapCameraPosition = coords.count == 1
                            ? .region(MKCoordinateRegion(
                                center: coords[0],
                                latitudinalMeters: 1500,
                                longitudinalMeters: 1500))
                            : .automatic
                        Map(initialPosition: initialCamera) {
                            ForEach(post.recap.locatedStops) { stop in
                                if let c = stop.coordinate {
                                    Marker(stop.name, systemImage: "mappin", coordinate: c)
                                        .tint(Color.whiskey)
                                }
                            }
                            if coords.count > 1 {
                                MapPolyline(coordinates: coords)
                                    .stroke(Color.whiskey, lineWidth: 3)
                            }
                        }
                        .frame(height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        // Interactive — drag to pan, pinch to zoom. (Drop the
                        // old allowsHitTesting(false) that froze it.)
                    }

                    ForEach(post.recap.stops) { stop in
                        stopCard(stop)
                    }

                    socialSection

                    Spacer(minLength: 30)
                }
                .padding(20).padding(.top, 56)
            }

            Button { onClose() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.cream.opacity(0.85))
                    .padding(12).background(Circle().fill(Color.cream.opacity(0.08)))
            }
            .padding(.top, 16).padding(.trailing, 20)
            .buttonStyle(PressScaleStyle())
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(item: $gallery) { g in
            GalleryLightbox(urls: g.urls, start: g.start) { gallery = nil }
        }
        .task {
            if !loadedLike { liked = post.likedByMe; likeCount = post.likeCount; loadedLike = true }
            comments = await feed?.comments(post.id) ?? []
        }
    }

    // MARK: Likes + comments

    @ViewBuilder
    private var socialSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 20) {
                Button {
                    liked.toggle()
                    likeCount = max(0, likeCount + (liked ? 1 : -1))
                    Task { await feed?.toggleLike(post.id) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: liked ? "heart.fill" : "heart")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(liked ? Status.drunk.color : Color.cream.opacity(0.85))
                        if likeCount > 0 { Text("\(likeCount)").foregroundStyle(Color.cream.opacity(0.85)) }
                    }
                    .padding(.vertical, 6)
                    .padding(.trailing, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle())
                HStack(spacing: 6) {
                    Image(systemName: "bubble.right")
                    if !comments.isEmpty { Text("\(comments.count)") }
                }
                .foregroundStyle(Color.cream.opacity(0.85))
                Spacer()
            }
            .font(.system(size: 17, weight: .semibold, design: .rounded))

            // Input at the top of the comments.
            HStack(spacing: 8) {
                TextField("Add a comment…", text: $commentText, axis: .vertical)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .lineLimit(1...3)
                    .focused($commentFocused)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.cream.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.cream.opacity(0.12), lineWidth: 1))
                Button { sendComment() } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(commentText.trimmingCharacters(in: .whitespaces).isEmpty ? Color.cream.opacity(0.3) : Color.whiskey)
                }
                .disabled(commentText.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if !comments.isEmpty {
                ForEach(comments) { c in commentRow(c) }
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func commentRow(_ c: PostComment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            FriendAvatar(name: c.authorName, avatarURL: c.authorAvatar, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(c.authorName)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.cream)
                    Text(RelativeTime.short(c.createdAt))
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.45))
                    Spacer(minLength: 0)
                }
                Text(c.body)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            if c.isMine || post.isMine {
                Button(role: .destructive) {
                    Task {
                        await feed?.deleteComment(c.id, postId: post.id)
                        comments = await feed?.comments(post.id) ?? []
                    }
                } label: { Label("Delete comment", systemImage: "trash") }
            }
        }
    }

    private func sendComment() {
        let body = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        commentText = ""
        commentFocused = false
        Task {
            await feed?.addComment(post.id, body: body)
            comments = await feed?.comments(post.id) ?? []
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 20, weight: .black, design: .rounded)).foregroundStyle(Color.cream)
            Text(label.uppercased()).font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1.4).foregroundStyle(Color.bronze)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.cream.opacity(0.05)))
    }

    @ViewBuilder
    private func stopCard(_ stop: RecapStop) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(recapStopEmoji(stop.kind)).font(.system(size: 16))
                VStack(alignment: .leading, spacing: 1) {
                    Text(stop.name).font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.cream)
                    Text(Self.timeFmt.string(from: stop.arrivedAt))
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.5))
                }
                Spacer()
                if post.includeBAC {
                    let unit = BACUnitSetting.current()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(unit.formatted(stop.bacOnArrival)) → \(unit.formatted(stop.bacOnDeparture))\(unit.symbol)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.cream.opacity(0.85))
                        if stop.isPeak {
                            Text("PEAK").font(.system(size: 8, weight: .black, design: .monospaced))
                                .tracking(1.2).foregroundStyle(Color.whiskey)
                        }
                    }
                }
            }

            if !stop.photoFilenames.isEmpty {
                let urls = stop.photoFilenames.compactMap { URL(string: $0) }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(urls.enumerated()), id: \.offset) { idx, url in
                            Button { gallery = PhotoGallery(urls: urls, start: idx) } label: {
                                DownsampledAsyncImage(url: url, targetPoints: 170)
                                    .frame(width: 150, height: 150)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(PressScaleStyle())
                        }
                    }
                }
            }

            if !stop.drinkSummary.isEmpty {
                Text(stop.drinkSummary)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.7))
            }

            if let note = stop.note, !note.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "text.bubble.fill")
                        .font(.system(size: 11)).foregroundStyle(Color.bronze).padding(.top, 1)
                    Text(note)
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.9))
                        .italic()
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.cream.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.cream.opacity(0.08), lineWidth: 1))
    }
}

/// A set of photos to view full-screen, starting at a given index.
private struct PhotoGallery: Identifiable {
    let id = UUID()
    let urls: [URL]
    let start: Int
}

/// Full-screen, swipeable photo gallery. Each photo fits on screen at its
/// real aspect ratio; swipe between them, tap or X to dismiss.
private struct GalleryLightbox: View {
    let urls: [URL]
    let start: Int
    let onClose: () -> Void

    @State private var index = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(urls.enumerated()), id: \.offset) { i, url in
                    DownsampledAsyncImage(url: url, targetPoints: 1200, fill: false, placeholder: .black)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { onClose() }
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: urls.count > 1 ? .always : .never))
            .indexViewStyle(.page(backgroundDisplayMode: .interactive))
        }
        .ignoresSafeArea()
        .overlay(alignment: .topTrailing) {
            Button { onClose() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(Circle().fill(.white.opacity(0.15)))
            }
            .padding(.top, 16).padding(.trailing, 20)
        }
        .onAppear { index = start }
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
/// The three top-level pages of the signed-in app. PLAN and LIVE map to the
/// existing sesh modes; TIMELINE is the friends feed. Kept separate from
/// `SeshMode` (which is sesh/group scope) so feed selection doesn't leak into
/// drink/group logic.
enum TopTab: Hashable {
    case plan, live, timeline, offers

    /// Section name shown in the top bar (the switcher now lives at the bottom).
    var title: String {
        switch self {
        case .plan:     return "Plan"
        case .live:     return "Live"
        case .timeline: return "Nightline"
        case .offers:   return "Deals"
        }
    }
}

private struct ModeTopBar: View {
    @Binding var tab: TopTab
    let profile: Profile
    /// True when there's something happening in LIVE that the user should
    /// notice from the PLAN side (live timeline running, group has live
    /// drinks, etc.). Drives the pulsing dot on the LIVE segment.
    let liveActive: Bool
    /// Number of pending invites — drives the bell badge. The bell is the
    /// permanent "notification center" entry point, so a swiped-away
    /// banner is always one tap away here.
    let inboxCount: Int
    let onTapInbox: () -> Void
    let onTapProfile: () -> Void
    let onTapFriends: () -> Void
    /// LIVE-tab status, surfaced in the top bar so the in-page header can go
    /// away and the content moves up. `liveStarted == nil` ⇒ not started yet.
    var liveStarted: Date? = nil
    var liveInGroup: Bool = false
    var liveMemberCount: Int = 0
    /// Show the END pill (solo live running). Tapping it asks the live view
    /// to confirm via the shared binding.
    var liveCanEnd: Bool = false
    var onEndLive: () -> Void = {}
    /// Group-live exit, surfaced at the top so you don't have to dig into the
    /// group sheet. Host ends for everyone; a member can leave (to join
    /// another sesh) or end their own night.
    var liveIsHost: Bool = false
    var onEndGroup: () -> Void = {}
    var onLeaveGroup: () -> Void = {}
    var onEndMyGroupNight: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            sectionLeading
            Spacer(minLength: 6)
            // Exit control — solo END, or a group end/leave menu.
            if liveCanEnd {
                Button(action: onEndLive) {
                    exitPill("END")
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("End live sesh")
            } else if liveInGroup {
                Menu {
                    if liveIsHost {
                        Button("Leave & keep my night") { onLeaveGroup() }
                        Button("End sesh for everyone", role: .destructive) { onEndGroup() }
                    } else {
                        Button("Leave group sesh") { onLeaveGroup() }
                        Button("End my sesh", role: .destructive) { onEndMyGroupNight() }
                    }
                } label: {
                    exitPill(liveIsHost ? "END" : "EXIT")
                }
                .accessibilityLabel(liveIsHost ? "End group sesh" : "Leave or end group sesh")
            }
            // Friends — set your @username, search + add friends, invite
            // them to a sesh. Always present.
            Button(action: onTapFriends) {
                ZStack {
                    Circle()
                        .fill(Color.cream.opacity(0.05))
                        .frame(width: 32, height: 32)
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.cream.opacity(0.8))
                }
                .overlay(Circle().strokeBorder(Color.cream.opacity(0.12), lineWidth: 1))
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel("Friends")
            // Notification-center bell — always present, sitting next to the
            // friends icon. Shows a count badge only when there's something
            // pending (friend requests + sesh invites).
            Button(action: onTapInbox) {
                ZStack(alignment: .topTrailing) {
                    ZStack {
                        Circle()
                            .fill(Color.cream.opacity(0.05))
                            .frame(width: 32, height: 32)
                        Image(systemName: inboxCount > 0 ? "bell.fill" : "bell")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(inboxCount > 0 ? Color.whiskey : Color.cream.opacity(0.8))
                    }
                    .overlay(
                        Circle().strokeBorder(Color.cream.opacity(0.12), lineWidth: 1)
                    )
                    // Count badge — caps at 9+ so it never overflows the pill.
                    if inboxCount > 0 {
                        Text(inboxCount > 9 ? "9+" : "\(inboxCount)")
                            .font(.system(size: 9, weight: .black, design: .rounded))
                            .foregroundStyle(Color.ink)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 15, minHeight: 15)
                            .background(Capsule().fill(Color.whiskey))
                            .overlay(Capsule().strokeBorder(Color.ink, lineWidth: 1.5))
                            .offset(x: 5, y: -5)
                    }
                }
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel(inboxCount > 0 ? "Notifications, \(inboxCount) pending" : "Notifications")
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
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: inboxCount > 0)
    }

    /// The shared whiskey-outline pill used for the END / EXIT control.
    private func exitPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .tracking(2.0)
            .foregroundStyle(Color.cream)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.cream.opacity(0.06)))
            .overlay(Capsule().strokeBorder(Color.cream.opacity(0.2), lineWidth: 1))
    }

    /// Top-left content. On LIVE it's the sesh status (dot + label + elapsed),
    /// replacing the old in-page header; elsewhere it's the section name.
    @ViewBuilder
    private var sectionLeading: some View {
        // Show the live status only once a sesh has actually started; before
        // that the LIVE tab just reads "Live" like PLAN / NIGHTLINE / DEALS.
        if tab == .live, liveStarted != nil {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(Color.whiskey)
                            .frame(width: 7, height: 7)
                            .shadow(color: Color.whiskey.opacity(0.8), radius: 5)
                        Text(liveInGroup ? "LIVE GROUP" : "LIVE SESH")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .tracking(2.4)
                            .foregroundStyle(Color.whiskey)
                        if liveInGroup, liveMemberCount > 0 {
                            Text("· \(liveMemberCount)")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.cream.opacity(0.55))
                        }
                    }
                    Text(liveStarted.map { Self.elapsed(from: $0, to: ctx.date) } ?? "Ready when you are")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.cream.opacity(0.55))
                        .lineLimit(1)
                }
            }
        } else {
            Text(tab.title)
                .font(.system(size: 23, weight: .heavy, design: .rounded))
                .italic()
                .tracking(-0.6)
                .foregroundStyle(Color.cream)
        }
    }

    private static func elapsed(from start: Date, to now: Date) -> String {
        let mins = max(0, Int(now.timeIntervalSince(start) / 60))
        if mins < 1 { return "Just started" }
        if mins < 60 { return "Started \(mins)m ago" }
        let h = mins / 60, m = mins % 60
        return m == 0 ? "Started \(h)h ago" : "Started \(h)h \(m)m ago"
    }
}

/// Pill-shaped two-segment switcher. Tapping a segment animates the
/// thumb across to the new selection. The thumb is filled with whiskey
/// for LIVE and a more neutral cream tint for PLAN — visually
/// reinforcing the energy difference between the two modes.
private struct ModeSwitcher: View {
    @Binding var tab: TopTab
    let liveActive: Bool

    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 0) {
            segment(.plan, label: "PLAN")
            segment(.live, label: "LIVE", showLiveDot: liveActive)
            segment(.timeline, label: "NIGHTLINE")
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
        .accessibilityLabel("Section")
    }

    @ViewBuilder
    private func segment(_ value: TopTab, label: String, showLiveDot: Bool = false) -> some View {
        let isOn = tab == value
        let isLive = value == .live
        Button {
            // Spring matches the TabView page swipe so the thumb and the
            // page transition feel like one motion.
            withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                tab = value
            }
        } label: {
            HStack(spacing: 5) {
                if showLiveDot {
                    LivePulseDot()
                        .frame(width: 7, height: 7)
                }
                Text(label)
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .tracking(1.6)
                    .lineLimit(1)
                    .fixedSize()   // size to the text so longer labels never crop
                    .foregroundStyle(textColor(isOn: isOn, isLive: isLive))
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 11)
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
        isOn ? Color.ink : Color.cream.opacity(0.55)
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
    /// Catalog role + admin management, owned by RootView.
    @ObservedObject var admin: AdminService
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
    /// The night's bar-to-bar journey. Check-ins land here (recorded off
    /// `venues.currentVenue` changes) and the END flow turns them into
    /// the animated Night Recap. Cleared when the sesh ends.
    @StateObject private var journey = NightJourneyStore()
    /// Saved nights — used to persist + auto-present a recap when a sesh
    /// is found to have wound down while the app was closed.
    @StateObject private var recapHistory = RecapHistoryStore()
    /// Set when an abandoned-but-loggable sesh is garbage-collected on
    /// launch — presents the recap the user would have seen had they hit
    /// END themselves.
    @State private var autoRecap: NightRecap? = nil
    /// The SQUAD recap waiting behind the personal one — presented when
    /// the personal auto-recap cover closes (or immediately if it already
    /// has, e.g. schnap downloads finished late).
    @State private var pendingGroupRecap: NightRecap? = nil
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
    /// Drives the END confirmation alert in LiveSeshView — lifted here so the
    /// END button can live in the shared top bar.
    @State private var liveConfirmEnd = false
    /// Whether the invites inbox sheet is open. Pinned-banner tap opens
    /// it; accept/decline inside the sheet drains the banner naturally
    /// because each action removes the row from `invites.pending`.
    @State private var invitesSheetOpen = false
    @State private var friendsSheetOpen = false
    /// Friends roster + incoming requests. App-wide so the bell badge and
    /// the unified inbox stay current; polls every 8s while signed in.
    @StateObject private var friends = FriendsService()
    @StateObject private var presence = PresenceService()
    @StateObject private var friendsPulse = FriendsPulseService()
    @StateObject private var liveStories = StoriesService()
    /// A live friend tapped in the Nightline pulse strip → detail sheet.
    @State private var openPulse: FriendPulse? = nil
    /// The friends timeline (loaded when the TIMELINE tab is first shown).
    @StateObject private var feed = FeedService()
    /// A friend's post opened full-screen.
    @State private var openPost: TimelinePost?
    /// A profile (post grid) opened from a feed author tap.
    @State private var openProfileUser: ProfileRef?
    /// Observes push taps. When a sesh-invite notification is tapped,
    /// `push.openInvites` flips true and we present the inbox + refresh.
    @ObservedObject private var push = PushManager.shared
    /// Which page the user is on. Driven by both the segmented switcher
    /// at the top and the swipe gesture on the underlying TabView.
    /// Defaults to LIVE so the app opens straight into the live experience.
    @State private var tab: TopTab = .live

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

    /// Build the recap for a sesh that wound down while the app was closed
    /// (solo: auto-ended by `endIfStale`; group: detected ended on poll).
    /// Mirrors LiveSeshView's build, but ends the night at the last thing
    /// that actually happened (last drink / check-in / photo) rather than
    /// "now" — which could be the next afternoon and would wildly inflate
    /// the duration.
    private func buildAutoRecap(
        events: [RecapEvent],
        extraStops: [SeshStop] = [],
        extraSpots: [LooseSpot] = []
    ) -> NightRecap? {
        let denom = profile.weightKg * 1000 * profile.sex.r
        guard denom > 0 else { return nil }
        let stops = journey.stops + extraStops
        let spots = journey.looseSpots + extraSpots
        // Photo-only nights still deserve their recap — the builder
        // anchors on journey activity when there are no drinks.
        guard !events.isEmpty || !stops.isEmpty || !journey.loosePhotos.isEmpty else {
            return nil
        }
        var endedAt = events.map(\.when).max() ?? Date()
        if let a = stops.map(\.arrivedAt).max() { endedAt = max(endedAt, a) }
        if let d = stops.compactMap(\.departedAt).max() { endedAt = max(endedAt, d) }
        if let p = journey.loosePhotos.map(\.takenAt).max() { endedAt = max(endedAt, p) }
        return NightRecap.build(
            journeyStops: stops,
            events: events,
            bumpPerGram: 100 / denom,
            loosePhotos: journey.loosePhotos,
            looseSpots: spots,
            preGameNote: journey.preGameNote,
            endedAt: endedAt
        )
    }

    /// Deliver the end-of-group recaps (personal, then squad). When the
    /// local journey is EMPTY — the end arrived while signed out / on a
    /// fresh install — the personal recap rebuilds its route from the
    /// group's server-side stops instead of showing bare numbers.
    private func deliverEndRecaps(
        events: [RecapEvent],
        board: [GroupMemberStat]?,
        ctx: SessionService.EndedGroupContext?,
        keepJourney: Bool
    ) {
        Task {
            var extraStops: [SeshStop] = []
            var extraSpots: [LooseSpot] = []
            if journey.stops.isEmpty, let ctx {
                (extraStops, extraSpots) = await fetchRouteAsJourneyInputs(ctx.sessionId)
            }
            if var built = buildAutoRecap(events: events, extraStops: extraStops, extraSpots: extraSpots) {
                // Group sesh → carry the squad leaderboard so the recap's
                // overview shows everyone's night, not just mine.
                built.groupLeaderboard = board
                // Build the SQUAD recap from the same route before
                // presentAutoRecap clears the journey it came from.
                if let ctx {
                    prepareGroupRecap(from: built, context: ctx, board: board)
                }
                presentAutoRecap(built, preservingJourney: keepJourney)
            }
        }
    }

    /// The group's server-side route, converted back into journey inputs
    /// for the personal recap builder. Venue/marker rows become stops;
    /// pre-game rows become loose spots (that's what they were on the
    /// device that logged them).
    private func fetchRouteAsJourneyInputs(_ sessionId: UUID) async -> ([SeshStop], [LooseSpot]) {
        struct Row: Decodable {
            let name: String
            let lat: Double?
            let lon: Double?
            let kind: String
            let arrivedAt: Date
            let departedAt: Date?
            enum CodingKeys: String, CodingKey {
                case name, lat, lon, kind
                case arrivedAt = "arrived_at"
                case departedAt = "departed_at"
            }
        }
        let rows: [Row] = (try? await supabase.from("session_stops")
            .select()
            .eq("session_id", value: sessionId.uuidString.lowercased())
            .order("arrived_at", ascending: true)
            .execute()
            .value) ?? []
        var stops: [SeshStop] = []
        var spots: [LooseSpot] = []
        for r in rows {
            if r.kind == "preGame" {
                spots.append(LooseSpot(id: UUID(), name: r.name, lat: r.lat, lon: r.lon, at: r.arrivedAt))
            } else {
                stops.append(SeshStop(
                    id: UUID(), venueId: UUID(),
                    kind: JourneyStopKind(rawValue: r.kind) ?? .bar,
                    name: r.name, lat: r.lat, lon: r.lon,
                    arrivedAt: r.arrivedAt, departedAt: r.departedAt
                ))
            }
        }
        return (stops, spots)
    }

    /// Mirror my journey markers into the live group's shared route (see
    /// SessionService.syncRouteMarkers). No-op when not in a live group.
    private func syncJourneyMarkersToGroup() {
        guard liveGroup.isActive else { return }
        let stops = journey.stops
        let spots = journey.looseSpots
        Task { await liveGroup.syncRouteMarkers(stops: stops, spots: spots) }
    }

    /// The DOWNSTREAM half: convert the group's server route into journey
    /// entries and merge them into MY journey — so a member sees every
    /// group stop live (and in their personal recap), not just the ones
    /// their own device witnessed.
    private func mergeGroupRouteIntoJourney() {
        guard let sid = liveGroup.session?.id else { return }
        var stops: [SeshStop] = []
        var spots: [LooseSpot] = []
        for r in liveGroup.routeStops {
            if r.kind == "preGame" {
                // Already have it as a spot (I logged/adopted it)? Done.
                if journey.looseSpots.contains(where: { $0.id == r.id }) { continue }
                // The group's pre-game falls MID-NIGHT for me (my own bars
                // predate it) → a loose spot would be swallowed by my
                // earlier route and render nowhere. Make it a real stop
                // page instead: "then we gathered at Partaj". A fresh
                // night (no earlier bars) keeps the classic pre-game leg.
                if journey.stops.contains(where: { $0.kind == .bar && $0.arrivedAt < r.arrivedAt }) {
                    stops.append(SeshStop(
                        id: r.id, venueId: UUID(),
                        kind: .between,
                        name: r.name, lat: r.lat, lon: r.lon,
                        arrivedAt: r.arrivedAt, departedAt: r.departedAt,
                        sessionId: sid
                    ))
                } else {
                    spots.append(LooseSpot(
                        id: r.id, name: r.name, lat: r.lat, lon: r.lon,
                        at: r.arrivedAt, sessionId: sid
                    ))
                }
            } else {
                stops.append(SeshStop(
                    id: r.id, venueId: UUID(),
                    kind: JourneyStopKind(rawValue: r.kind) ?? .bar,
                    name: r.name, lat: r.lat, lon: r.lon,
                    arrivedAt: r.arrivedAt, departedAt: r.departedAt,
                    sessionId: sid
                ))
            }
        }
        journey.mergeGroupRoute(stops: stops, spots: spots)
    }

    /// A live sesh terminally ended → check out of the venue. Deferred so
    /// the recap observer (same cycle) builds + clears the journey first:
    /// if a recap was produced it already handled the checkout, so clearing
    /// the chip here finds an empty journey (no stray "between bars" stop);
    /// if NOT, we clear the leftover check-in so a drink-free night doesn't
    /// leave the user "here".
    private func checkOutAfterLiveEnd() {
        DispatchQueue.main.async {
            // With no running night this stamps the departure only — the
            // venue onChange skips the "between bars" stop post-END.
            venues.currentVenue = nil
        }
        // Final sweep once the recap flow has had time to build from the
        // journey (presenting a recap clears it itself): anything still
        // staged after this belongs to no recap and no running night.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard !live.isActive, liveGroup.session == nil,
                  autoRecap == nil, pendingGroupRecap == nil else { return }
            journey.clear()
        }
    }

    /// The newest timestamp anywhere in the staged journey — used to decide
    /// whether leftover check-ins/photos belong to a night that's over.
    private var journeyLastActivity: Date? {
        var dates: [Date] = journey.stops.map(\.arrivedAt)
        dates += journey.stops.compactMap(\.departedAt)
        dates += journey.loosePhotos.map(\.takenAt)
        dates += journey.looseSpots.map(\.at)
        return dates.max()
    }

    /// Build the SQUAD recap: the personal recap's route, re-cast for the
    /// whole group — per-stop member stats (who was drunkest where, their
    /// BAC, drinks so far) and the squad schnaps as its photo reel. Saved
    /// to history immediately (the auto-end cover offers keep/discard) and
    /// queued to present after the personal recap closes.
    private func prepareGroupRecap(
        from personal: NightRecap,
        context: SessionService.EndedGroupContext,
        board: [GroupMemberStat]?
    ) {
        Task {
            // Squad schnaps first: their timestamps decide whether the
            // group recap needs BETWEEN-BARS legs my personal recap
            // doesn't have (someone else schnapped in a gap where I
            // logged nothing).
            let snaps: [SessionSnap] = (try? await supabase.from("session_snaps")
                .select()
                .eq("session_id", value: context.sessionId.uuidString.lowercased())
                .order("created_at", ascending: true)
                .execute()
                .value) ?? []

            // The group's server-side route (migration 038) — the source
            // of truth for WHERE the group went. Every member gets the
            // same stops, even if their own device journey never saw them.
            struct RouteRow: Decodable {
                let name: String
                let lat: Double?
                let lon: Double?
                let kind: String
                let arrivedAt: Date
                let departedAt: Date?
                let profileId: UUID?
                enum CodingKeys: String, CodingKey {
                    case name, lat, lon, kind
                    case arrivedAt = "arrived_at"
                    case departedAt = "departed_at"
                    case profileId = "profile_id"
                }
            }
            let rawRoute: [RouteRow] = (try? await supabase.from("session_stops")
                .select()
                .eq("session_id", value: context.sessionId.uuidString.lowercased())
                .order("arrived_at", ascending: true)
                .execute()
                .value) ?? []

            // Rows land in session_stops by IDENTITY (journey entries are
            // tagged with the group id at creation), so everything here IS
            // the group's story — no time filtering, which wrongly dropped
            // the host's pre-game (set moments before creating the group)
            // and wrongly kept members' parallel personal stops.
            // Collapse duplicate markers — several members logging the same
            // moment (each device's "Between bars", everyone's pre-game)
            // becomes ONE stop, with the HOST's naming winning.
            var markers: [RouteRow] = []
            for r in rawRoute where r.kind != "bar" {
                if let i = markers.firstIndex(where: {
                    $0.kind == r.kind && abs($0.arrivedAt.timeIntervalSince(r.arrivedAt)) < 15 * 60
                }) {
                    if r.profileId == context.hostId { markers[i] = r }
                } else {
                    markers.append(r)
                }
            }
            let route = (rawRoute.filter { $0.kind == "bar" } + markers)
                .sorted { $0.arrivedAt < $1.arrivedAt }

            // Fresh ids: this recap owns its own photo directory and
            // history entry, independent of the personal one.
            var stops: [RecapStop]
            if !route.isEmpty {
                stops = route.map { r in
                    // Bars hold a window (open ones run to the end of the
                    // night); markers are instants.
                    let isBar = r.kind == "bar"
                    let dep = r.departedAt ?? (isBar ? personal.endedAt : r.arrivedAt)
                    let kind: RecapStopKind = switch r.kind {
                    case "bar":     .bar
                    case "between": .refuel
                    case "food":    .food
                    case "puke":    .puke
                    case "preGame": .preGame
                    default:        .bar
                    }
                    let squad = squadStats(arrivedAt: r.arrivedAt, leavingAt: dep, context: context)
                    let mine = squad.first(where: { $0.isMe })
                    var s = RecapStop(
                        id: UUID(), kind: kind, lat: r.lat, lon: r.lon, name: r.name,
                        arrivedAt: r.arrivedAt, departedAt: dep, drinks: [],
                        drinkSummary: "",
                        bacOnArrival: 0,
                        bacOnDeparture: mine?.bac ?? 0,
                        isPeak: isBar && personal.peakAt >= r.arrivedAt && personal.peakAt <= dep
                    )
                    s.squad = squad
                    return s
                }
            } else {
                // Legacy sessions without a recorded route — fall back to
                // my own journey's stops, still scoped to the group's
                // window (pre-join stops are personal-recap material).
                let mine = personal.stops.filter { $0.arrivedAt >= context.sessionStart }
                guard !mine.isEmpty else { return }
                stops = mine.map { s in
                    var copy = RecapStop(
                        id: UUID(), kind: s.kind, lat: s.lat, lon: s.lon, name: s.name,
                        arrivedAt: s.arrivedAt, departedAt: s.departedAt, drinks: s.drinks,
                        drinkSummary: s.drinkSummary, bacOnArrival: s.bacOnArrival,
                        bacOnDeparture: s.bacOnDeparture, isPeak: s.isPeak
                    )
                    copy.squad = squadStats(arrivedAt: s.arrivedAt, leavingAt: s.departedAt, context: context)
                    return copy
                }
            }

            // Synthesize a leg only for schnaps genuinely STRANDED between
            // stops. A schnap merely outside a stop's window but close to
            // one (markers are instants — a photo at the food break is
            // seconds away) attaches to that stop instead; synthesizing for
            // those minted phantom "Between bars" legs after every marker.
            let byTime = stops.sorted { $0.arrivedAt < $1.arrivedAt }
            let orphans = snaps.filter { s in
                let inWindow = stops.contains {
                    s.createdAt >= $0.arrivedAt && s.createdAt <= $0.departedAt
                }
                let nearAStop = stops.contains {
                    min(abs($0.arrivedAt.timeIntervalSince(s.createdAt)),
                        abs($0.departedAt.timeIntervalSince(s.createdAt))) < 20 * 60
                }
                return !inWindow && !nearAStop
            }
            var legs: [RecapStop] = []
            for (i, current) in byTime.enumerated() {
                let gapStart = current.departedAt
                let gapEnd = i + 1 < byTime.count ? byTime[i + 1].arrivedAt : personal.endedAt
                guard gapEnd > gapStart,
                      orphans.contains(where: { $0.createdAt > gapStart && $0.createdAt < gapEnd })
                else { continue }
                var leg = RecapStop(
                    id: UUID(),
                    kind: i + 1 < byTime.count ? .refuel : .afters,
                    lat: nil, lon: nil,
                    name: i + 1 < byTime.count ? "Between bars" : "Afters",
                    arrivedAt: gapStart, departedAt: gapEnd,
                    drinks: [], drinkSummary: "",
                    bacOnArrival: current.bacOnDeparture,
                    bacOnDeparture: current.bacOnDeparture,
                    isPeak: false
                )
                leg.squad = squadStats(arrivedAt: gapStart, leavingAt: gapEnd, context: context)
                legs.append(leg)
            }
            stops = (stops + legs).sorted { $0.arrivedAt < $1.arrivedAt }

            let group = NightRecap(
                id: UUID(), stops: stops,
                startedAt: personal.startedAt, endedAt: personal.endedAt,
                totalDrinks: personal.totalDrinks, peakBAC: personal.peakBAC,
                peakAt: personal.peakAt, groupLeaderboard: board,
                crawlMeters: personal.crawlMeters, isGroup: true
            )
            recapHistory.save(group)
            pendingGroupRecap = group

            // Pull the schnaps into the recap's own photo directory — the
            // cloud copies are ephemeral (purged once the sesh is over),
            // the recap's copies are forever.
            guard !snaps.isEmpty else { return }
            var latest = group
            for snap in snaps {
                guard let url = snap.url,
                      let (data, _) = try? await URLSession.shared.data(from: url)
                else { continue }
                let stopId = stopFor(snap: snap, in: latest.stops)
                if let updated = recapHistory.addPhoto(data, toStop: stopId, in: latest.id) {
                    latest = updated
                }
            }
            if autoRecap?.id == latest.id {
                // Already on screen (user opened it before downloads
                // finished) — refresh in place so photos pop in.
                autoRecap = latest
            } else if pendingGroupRecap?.id == latest.id {
                pendingGroupRecap = latest
            }
        }
    }

    /// Every member's state AT a stop: BAC as the group left it (full
    /// chronological walk up to departure — that's their level at the
    /// spot) and the number of drinks logged WHILE there. Shared rounds
    /// count at their per-head share, exactly like the live math.
    private func squadStats(
        arrivedAt arrival: Date,
        leavingAt departure: Date,
        context: SessionService.EndedGroupContext
    ) -> [SquadStopStat] {
        let n = Double(max(context.headCount, 1))
        var out: [SquadStopStat] = []
        for (pid, prof) in context.profiles {
            let denom = prof.weightKg * 1000 * prof.sex.r
            guard denom > 0 else { continue }
            let events: [(Date, Double)] = context.drinks.compactMap { d in
                let mine = d.profileId == pid && !d.shared
                guard mine || d.shared else { return nil }
                return (d.createdAt, d.shared ? d.grams / n : d.grams)
            }
            .filter { $0.0 <= departure }
            .sorted { $0.0 < $1.0 }

            var bac = 0.0
            var last: Date? = nil
            for (when, grams) in events {
                if let l = last {
                    bac = max(0, bac - 0.015 * when.timeIntervalSince(l) / 3600)
                }
                bac += (grams / denom) * 100
                last = when
            }
            if let l = last {
                bac = max(0, bac - 0.015 * max(0, departure.timeIntervalSince(l)) / 3600)
            }
            let hereCount = events.filter { $0.0 >= arrival }.count
            out.append(SquadStopStat(
                name: prof.name, bac: bac, drinks: hereCount, isMe: pid == profile.id
            ))
        }
        return out.sorted { $0.bac > $1.bac }
    }

    /// Which stop a schnap belongs to: its stop window first, then its
    /// stamped name, then whichever stop is nearest in time.
    private func stopFor(snap: SessionSnap, in stops: [RecapStop]) -> UUID {
        if let hit = stops.first(where: { snap.createdAt >= $0.arrivedAt && snap.createdAt <= $0.departedAt }) {
            return hit.id
        }
        if let name = snap.stopName, let hit = stops.first(where: { $0.name == name }) {
            return hit.id
        }
        let nearest = stops.min { a, b in
            let da = min(abs(a.arrivedAt.timeIntervalSince(snap.createdAt)),
                         abs(a.departedAt.timeIntervalSince(snap.createdAt)))
            let db = min(abs(b.arrivedAt.timeIntervalSince(snap.createdAt)),
                         abs(b.departedAt.timeIntervalSince(snap.createdAt)))
            return da < db
        }
        return nearest?.id ?? stops[0].id
    }

    /// Save + surface an auto-built recap (shared by the solo and group
    /// paths). Adopts staged photos, persists, presents, clears the route.
    /// `preservingJourney` = the night continues (direct group→group
    /// switch): photos are COPIED instead of moved and nothing is cleared,
    /// so the ongoing journey stays intact for the eventual final recap.
    private func presentAutoRecap(_ built: NightRecap, preservingJourney: Bool = false) {
        recapHistory.adoptPhotos(from: journey.photosDirectory, for: built,
                                 copying: preservingJourney)
        recapHistory.save(built)
        autoRecap = built
        guard !preservingJourney else { return }
        journey.clear()
        // The sesh is over — reset the venue chip to "tap to check in".
        venues.currentVenue = nil
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

    /// When the current live sesh began — group first-drink (or session
    /// creation) in a group, else the solo timeline's start. Feeds the
    /// "Started Xm ago" line now shown in the top bar.
    private var liveStartTime: Date? {
        if liveGroup.isActive {
            return liveGroup.firstDrinkTime(for: profile.id) ?? liveGroup.session?.createdAt
        }
        return live.startedAt
    }

    /// Leave the live group but keep the night going. The drinks live in the
    /// group session, so a plain leave would reset them to 0 — instead, copy
    /// my drinks into the solo live sesh first, then leave without a recap.
    /// The checked-in venue stays. Now I can go join another sesh with my BAC
    /// still counting. (Shared rounds copy whole, which over-counts slightly —
    /// erring high is the safe direction for a BAC readout.)
    /// Carry my solo night INTO a group I just joined so my drink count
    /// doesn't reset to 0 — preserving each drink's original time so BAC stays
    /// accurate. Clears the solo store once they're safely in the group.
    /// (Combined with the group→solo transfer on leave, my night follows me
    /// across every transition: solo↔group and group→group.)
    private func carrySoloNightIntoGroup() {
        guard !live.drinks.isEmpty else { return }
        let carried = live.drinks.sorted(by: { $0.consumedAt < $1.consumedAt })
        Task {
            for d in carried {
                await liveGroup.addDrink(d.option(), shared: false, consumedAt: d.consumedAt)
            }
            // Re-sync from the DB so a concurrent enter() refresh can't drop
            // the just-carried rows, THEN clear the solo store.
            await liveGroup.refresh()
            live.end()
        }
    }

    /// A carried drink scaled to MY share. Shared rounds count grams/heads
    /// in the group BAC math — copying one across as a full personal drink
    /// would multiply its alcohol by the old group's headcount (the "BAC
    /// way too high after leaving a group" bug). Personal drinks pass
    /// through untouched.
    private func carriedOption(for d: SessionDrink, headCount: Int) -> DrinkOption {
        let opt = venues.resolveOption(for: d)
        guard d.shared, headCount > 1 else { return opt }
        return DrinkOption(
            category: opt.category,
            name: opt.name,
            detail: opt.detail,
            volumeML: opt.volumeML / Double(headCount),
            abv: opt.abv,
            customGlyph: opt.customGlyph
        )
    }

    /// Re-add a set of drinks (captured from the group we just left during a
    /// direct group→group switch) into the group that's now current, keeping
    /// their original times. My personal rows are then DELETED from the old
    /// group so a later return can't double-count them; shared rounds stay
    /// with the old group (they belong to everyone).
    private func carryDrinksIntoCurrentGroup(
        _ previous: [SessionDrink], headCount: Int, from oldSessionId: UUID
    ) {
        guard !previous.isEmpty else { return }
        let carried = previous.sorted(by: { $0.createdAt < $1.createdAt })
        Task {
            for d in carried {
                await liveGroup.addDrink(
                    carriedOption(for: d, headCount: headCount),
                    shared: false, consumedAt: d.createdAt
                )
            }
            await liveGroup.deleteMyPersonalDrinks(in: oldSessionId)
            await liveGroup.refresh()
        }
    }

    private func leaveGroupKeepingNight() {
        let heads = max(liveGroup.members.count + liveGroup.ghosts.count, 1)
        let oldId = liveGroup.session?.id
        for d in liveGroup.liveTimeline(for: profile.id).sorted(by: { $0.createdAt < $1.createdAt }) {
            live.add(carriedOption(for: d, headCount: heads), at: d.createdAt)
        }
        // A host can't "leave" their own group, so leaving-to-keep-night ends
        // it for everyone (no recap for me — my drinks moved to the solo sesh).
        let host = liveGroup.isHost
        Task {
            if host {
                await liveGroup.end(cousinSessionId: planGroup.session?.id, captureRecap: false)
            } else {
                // Copies live in my solo store now — clear my personal rows
                // out of the group so rejoining can't double-count them.
                if let oldId {
                    await liveGroup.deleteMyPersonalDrinks(in: oldId)
                }
                await liveGroup.leave(cousinSessionId: planGroup.session?.id, captureRecap: false)
            }
        }
    }

    /// Count of things the user has actively added to tonight's journey —
    /// check-ins, loose photos, loose/pre-game spots, and a pre-game note. A
    /// rise in this signals the first real action and starts the live sesh
    /// (see the onChange below). Drinks aren't counted here; they start the
    /// sesh themselves via LiveSeshState.add.
    private var journeyActivityCount: Int {
        journey.stops.count
            + journey.loosePhotos.count
            + journey.looseSpots.count
            + (journey.preGameNote == nil ? 0 : 1)
    }

    var body: some View {
        ZStack {
            // The atmosphere accent shifts when the user is on LIVE so
            // the whole screen reads "this is the live experience" even
            // before any content swipes in.
            AtmosphereBackground(accent: tab == .live ? Color.whiskey : status.color)
                .animation(.easeInOut(duration: 0.45), value: tab)

            VStack(spacing: 0) {
                ModeTopBar(
                    tab: $tab,
                    profile: profile,
                    liveActive: liveActive,
                    inboxCount: invites.pending.count + friends.incoming.count + friends.unseenActivityCount,
                    onTapInbox: { invitesSheetOpen = true; friends.markActivitySeen() },
                    onTapProfile: { profileOpen = true },
                    onTapFriends: { friendsSheetOpen = true },
                    liveStarted: liveStartTime,
                    liveInGroup: liveGroup.isActive,
                    liveMemberCount: liveGroup.members.count,
                    liveCanEnd: !liveGroup.isActive && live.isActive,
                    onEndLive: { liveConfirmEnd = true },
                    liveIsHost: liveGroup.isHost,
                    onEndGroup: {
                        Task { await liveGroup.end(cousinSessionId: planGroup.session?.id) }
                    },
                    onLeaveGroup: { leaveGroupKeepingNight() },
                    onEndMyGroupNight: {
                        Task { await liveGroup.leave(cousinSessionId: planGroup.session?.id, captureRecap: true) }
                    }
                )
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 8)

                TabView(selection: $tab) {
                    planPage.tag(TopTab.plan)
                    livePage.tag(TopTab.live)
                    timelinePage.tag(TopTab.timeline)
                    offersPage.tag(TopTab.offers)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                // Smooth horizontal swipe between modes; matches the
                // bottom bar's spring so tapping a tab and dragging the
                // page feel like the same animation.
                .animation(.spring(response: 0.4, dampingFraction: 0.82), value: tab)

                BottomTabBar(tab: $tab, liveActive: liveActive,
                             friendsLive: friendsPulse.pulses.contains { $0.live })
            }

            // Floating invite banner — pinned just below the ModeTopBar.
            // Drops in from the top whenever a new pending invite arrives
            // and snaps out the moment the inbox empties (accept,
            // decline, or sender flipped status server-side).
            if !invites.bannerInvites.isEmpty {
                VStack {
                    InviteBanner(
                        count: invites.bannerInvites.count,
                        latest: invites.bannerInvites.first,
                        senderProfiles: invites.senderProfiles,
                        onTap: { invitesSheetOpen = true },
                        onDismiss: {
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                                invites.snoozeBanner()
                            }
                        }
                    )
                    .padding(.horizontal, 22)
                    .padding(.top, 56)   // clears ModeTopBar
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(20)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: invites.bannerInvites.count)
        // A tapped invite push asks us to open the inbox. Refresh first so
        // the just-arrived invite is present even if the 7s poll hasn't
        // come around yet, then present the sheet and reset the flag.
        .onChange(of: push.openInvites) { _, shouldOpen in
            guard shouldOpen else { return }
            Task { await invites.refresh() }
            invitesSheetOpen = true
            push.openInvites = false
        }
        // Record every venue check-in AND check-out onto the night's
        // journey. Both the PLAN and LIVE venue sheets funnel through the
        // same VenueService, so one observer catches them all. Duplicates
        // (e.g. the launch-time re-validation of a persisted check-in)
        // collapse inside the store; stale pre-sesh stops are filtered out
        // at recap-build time by the 90-minute grace window. Check-outs
        // stamp the open bar stop so the recap can carve refuel / afters
        // legs from drinks logged between bars.
        .onChange(of: venues.currentVenue) { _, venue in
            if let venue {
                journey.checkIn(venue)
            } else if live.isActive || liveGroup.isActive {
                // Checkout drops a "between bars" stop (with location when
                // available) you can swipe to, photograph, and reorder.
                journey.checkOut(coordinate: location.location?.coordinate)
            } else {
                // END-triggered checkout (or any clear outside a running
                // night): stamp the departure only — no phantom "between
                // bars" page after the sesh is over.
                journey.checkOut(recordBetween: false)
            }
        }
        // Start the solo live sesh on the first real action — a check-in,
        // photo, pre-game spot, or pre-game comment — rather than the moment
        // the user lands on the LIVE tab. (Adding a drink starts it on its own
        // via LiveSeshState.add; a live group is its own backing.) Each of
        // those mutates the night journey, so a bump in its activity count is
        // the trigger.
        .onChange(of: journeyActivityCount) { old, new in
            guard new > old, !liveGroup.isActive, !live.isActive else { return }
            live.start()
        }
        // Group check-in: when a member moves the whole group, every
        // FOLLOWING member's local venue adopts it (which then records the
        // journey check-in/out through the observer above). Members who
        // broke away ignore it.
        .onChange(of: liveGroup.liveVenue) { _, groupVenue in
            guard liveGroup.isActive, liveGroup.followingGroupVenue else { return }
            if venues.currentVenue?.id != groupVenue?.id {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    venues.currentVenue = groupVenue
                }
            }
        }
        // Same for the group's pre-game / between location — following
        // members adopt it VERBATIM (keeping its timestamp, so a group
        // pre-game spot files onto pre-game, not "between bars"). The
        // already-have-this-id guard stops it re-adopting every poll.
        .onChange(of: liveGroup.liveLooseSpot) { _, spot in
            guard liveGroup.isActive, liveGroup.followingGroupVenue else { return }
            if let spot {
                guard !journey.looseSpots.contains(where: { $0.id == spot.id }) else { return }
                journey.adoptLooseSpot(spot)
            } else {
                // Only the CURRENT moment's spot — never spots predating
                // the group (its adopted pre-game, my own earlier night).
                journey.clearCurrentLooseSpot(protectBefore: liveGroup.session?.createdAt)
            }
        }
        .sheet(isPresented: $invitesSheetOpen) {
            InvitesSheet(
                invites: invites,
                friends: friends,
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
                            tab = .live
                        } else {
                            await planGroup.join(code: invite.joinCode)
                            tab = .plan
                        }
                        invitesSheetOpen = false
                    }
                },
                onDecline: { invite in
                    Task { await invites.updateStatus(invite.id, to: "declined") }
                },
                onOpenPost: { postId in
                    // Open the post the like/comment was left on.
                    Task {
                        guard let p = await feed.myPost(postId) else { return }
                        invitesSheetOpen = false
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        openPost = p
                    }
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .preferredColorScheme(.dark)
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
            // Snapshot the drinks BEFORE endIfStale wipes them — they're
            // what the recap is built from.
            let staleDrinks = live.drinks
            if live.endIfStale(profile: profile) {
                LiveActivityController.shared.end()
                // The user never got to hit END, so build the recap they'd
                // have seen and surface it automatically on this launch.
                // Saved to Past nights either way (the cover lets them keep
                // or discard, same as a normal END).
                let events = staleDrinks.map {
                    RecapEvent(when: $0.consumedAt, grams: $0.grams, name: $0.optionName)
                }
                if let built = buildAutoRecap(events: events) {
                    presentAutoRecap(built)
                } else {
                    // Nothing to recap — still clear the abandoned route.
                    journey.clear()
                }
            }
            // Same staleness rule for a night that never logged a drink:
            // an old check-in + photos used to linger FOREVER (no drinks →
            // no END button, no auto-end). Recap what's there, then clear.
            // Skipped while an ended-while-away capture is pending — that
            // recap builds from this same journey.
            if !live.isActive, !liveGroup.isActive, liveGroup.endedLiveEvents == nil {
                let hasLeftovers = !journey.stops.isEmpty
                    || !journey.loosePhotos.isEmpty
                    || venues.currentVenue != nil
                if hasLeftovers {
                    if let last = journeyLastActivity {
                        if Date().timeIntervalSince(last) > 12 * 3600 {
                            if let built = buildAutoRecap(events: []) {
                                presentAutoRecap(built)
                            } else {
                                journey.clear()
                                venues.currentVenue = nil
                            }
                        }
                    } else {
                        // A stray check-in with no recorded activity at
                        // all — nothing to recap, just reset the chip.
                        journey.clear()
                        venues.currentVenue = nil
                    }
                }
            }
        }
        // Pull venue + specials catalog on first launch so the chip /
        // picker have something to render. With no curated seed list,
        // an empty DB just means "Featured" stays empty and the user
        // discovers their bar via the search field.
        .task { await venues.refresh() }
        // Auto-recap for a sesh that wound down while the app was closed.
        // autoEnd: already ended (nothing to tear down) but still offers
        // save-or-discard, same as a normal END.
        .fullScreenCover(item: $autoRecap) { built in
            NightRecapView(recap: built, history: recapHistory, mode: .autoEnd) {
                autoRecap = nil
                // Squad recap queued behind the personal one? Present it
                // once this cover has fully dismissed.
                if let squad = pendingGroupRecap {
                    pendingGroupRecap = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                        autoRecap = squad
                    }
                }
            }
        }
        // Group auto-recap: SessionService hands off my projected events
        // the instant a live group sesh ends (host ended / I left / poll
        // detected it on launch). Build + present the same way as solo.
        .onChange(of: liveGroup.endedLiveEvents) { _, events in
            guard let events, !events.isEmpty else { return }
            let board = liveGroup.endedGroupLeaderboard
            let groupCtx = liveGroup.endedGroupContext
            // Preserve the journey/check-in when the night CONTINUES: a
            // backfilled recap of an OLD session arriving while a NEW sesh
            // is already running — wiping the current night's check-in was
            // exactly the "we're checked in but the app doesn't show it"
            // bug.
            let keepJourney = liveGroup.session != nil || live.isActive
            liveGroup.endedLiveEvents = nil
            liveGroup.endedGroupLeaderboard = nil
            liveGroup.endedGroupContext = nil
            deliverEndRecaps(events: events, board: board, ctx: groupCtx, keepJourney: keepJourney)
        }
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
        // ---- Friends live pulse ----
        // All wiring lives in one ViewModifier so the (already enormous)
        // modifier chain here grows by a single entry — the type-checker
        // times out otherwise.
        .modifier(PulseWiringModifier(
            live: live,
            liveGroup: liveGroup,
            venues: venues,
            friendsPulse: friendsPulse,
            stories: liveStories,
            openPulse: $openPulse,
            tab: tab,
            publish: publishPresence,
            onLiveEnded: { checkOutAfterLiveEnd() },
            journey: journey,
            syncMarkers: { syncJourneyMarkersToGroup() },
            mergeRoute: { mergeGroupRouteIntoJourney() }
        ))
        // Bridge the device-local guest store to the shared session roster
        // as the user enters / leaves a LIVE group:
        //   • Enter  → adopt the session's shared guests and start
        //     mirroring local edits up to the server.
        //   • Leave / end → stop mirroring and wipe the night's guests
        //     (covers every group-end path, not just the solo END button
        //     — that was the original "stale ghosts" bug).
        .onChange(of: liveGroup.session?.id) { old, new in
            if new != nil {
                ghosts.hydrate(liveGroup.ghosts)
                ghosts.syncSink = { [weak liveGroup] members in
                    Task { @MainActor in await liveGroup?.syncGhosts(members) }
                }
                // Carry drinks ONLY when the user actively joined/created —
                // resumeIfAny restoring the session on launch must not shove
                // solo leftovers into the group on every app open.
                let userInitiated = liveGroup.entryWasUserInitiated
                liveGroup.entryWasUserInitiated = false
                if userInitiated {
                    // CREATOR only: my running night becomes the group's
                    // opening chapter (the host's pre-game spot usually
                    // predates the group row by a minute). Joiners keep
                    // their earlier stops personal.
                    if liveGroup.isHost, let newId = new {
                        journey.adoptNightIntoSession(newId)
                    }
                    if old == nil {
                        // Solo → group: carry my running solo night in.
                        carrySoloNightIntoGroup()
                    } else if let oldId = old, oldId != new {
                        // Group → group switch. enter() hasn't yet swapped
                        // `drinks`/roster to the new group, so the timeline
                        // (and headcount for the shared-round split) still
                        // reflect the PREVIOUS group — capture mine now and
                        // re-add them to the new group.
                        let previous = liveGroup.liveTimeline(for: profile.id)
                            .filter { $0.sessionId == oldId }
                        let heads = max(liveGroup.members.count + liveGroup.ghosts.count, 1)
                        carryDrinksIntoCurrentGroup(previous, headCount: heads, from: oldId)
                    }
                }
            } else if old != nil && new == nil {
                ghosts.syncSink = nil
                ghosts.clearAll()
            }
        }
        // Reflect other devices' guest edits (pulled by the 3s session
        // poll) into the local store, but only while we're in a group —
        // in solo mode liveGroup.ghosts is empty and must not clobber
        // device-local guests.
        .onChange(of: liveGroup.ghosts) { _, newGhosts in
            if liveGroup.session != nil {
                ghosts.hydrate(newGhosts)
            }
        }
        // First-frame seed: if either store resumed into an existing
        // session before the .onChange observers were wired, record it
        // now so the saved-groups list reflects "where I am right now"
        // even if the user never refreshes the roster.
        .onAppear {
            recordSavedGroup(from: planGroup)
            recordSavedGroup(from: liveGroup)
            friends.start()
            // Every journey entry created while in a live group carries the
            // group's id — the group recap selects by IDENTITY, so a
            // member's parallel personal stops can never leak into it.
            journey.currentSessionProvider = { [weak liveGroup] in
                liveGroup?.session?.id
            }
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
            ProfileSheet(profile: profile, auth: auth, admin: admin, friends: friends, feed: feed)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.ink)
        }
        .sheet(isPresented: $friendsSheetOpen) {
            FriendsView(friends: friends, auth: auth)
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
                invites: invites,
                friends: friends
            )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.ink)
        }
        .sheet(isPresented: $venueOpen) {
            VenueSheet(location: location, venues: venues, group: liveGroup)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.ink)
        }
        .fullScreenCover(item: $openPost) { post in
            PostDetailView(post: post, feed: feed, history: recapHistory) { openPost = nil }
        }
        .sheet(item: $openProfileUser) { ref in
            ProfileFeedView(user: ref, feed: feed)
                .presentationBackground(Color.ink)
        }
    }

    /// DEALS — the venue-offers discovery map (Phase A). Embedded as a tab,
    /// so it shows no close button; navigation is the bottom bar.
    ///
    /// The DEALS page defers its heavy MapKit map to after the page-swipe
    /// animation settles (see DeferredOffersPage) — mounting it mid-swipe
    /// was hitching the transition, and the memory gating still applies.
    private var offersPage: some View {
        DeferredOffersPage(active: tab == .offers, venues: venues, location: location) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                tab = .timeline
            }
        }
    }

    /// TIMELINE — the friends feed of posted nights.
    private var timelinePage: some View {
        TimelineFeedView(
            feed: feed,
            pulse: friendsPulse,
            stories: liveStories,
            profile: profile,
            storyBAC: { currentStoryBAC() },
            storyStamp: { currentStoryStamp() },
            onOpenPost: { openPost = $0 },
            onOpenAuthor: { post in
                openProfileUser = ProfileRef(
                    id: post.authorId, name: post.authorName,
                    username: post.authorUsername, avatar: post.authorAvatar
                )
            },
            onOpenPulse: { openPulse = $0 }
        )
    }

    /// My BAC at the instant a story is posted — group math when in a live
    /// group, solo Widmark otherwise, nil when no night is running (the
    /// composer then simply offers no BAC stamp).
    private func currentStoryBAC() -> Double? {
        if liveGroup.isActive {
            return liveGroup.liveBAC(for: profile.id)
        }
        if live.isActive {
            return live.bac(profile: profile)
        }
        return nil
    }

    /// Where I am for the story stamp: checked-in venue first, then the
    /// group's shared venue, then the current pre-game / between-bars spot.
    private func currentStoryStamp() -> String? {
        if let name = venues.currentVenue?.name { return name }
        if let name = liveGroup.liveVenue?.name { return name }
        if let spot = journey.currentLooseSpot {
            return spot.name ?? (journey.hasCheckedInSomewhere ? "Between bars" : "Pre-game")
        }
        return nil
    }

    /// Push my current live status (or its absence) up to `live_presence`.
    /// Called from a handful of observers so any change a friend could see
    /// — drink logged, check-in, group joined/left, night ended — lands
    /// within a beat. PresenceService dedupes unchanged payloads.
    private func publishPresence() {
        let sessionId = liveGroup.session?.id
        let started: Date? = sessionId != nil
            ? (liveGroup.session?.createdAt ?? Date())
            : live.startedAt
        let venue = venues.currentVenue ?? liveGroup.liveVenue
        let soloDrinks = sessionId != nil ? [] : live.drinks
        Task {
            await presence.publish(
                startedAt: started,
                drinks: soloDrinks,
                venueName: venue?.name,
                venueLat: venue?.lat,
                venueLon: venue?.lon,
                sessionId: sessionId
            )
        }
    }

    // MARK: - Pages
    //
    // Two pages, one TabView. Both rely on shared SessionView state
    // (group, live, venues, recents) so swiping between them is just a
    // visual change — no data has to migrate.

    private var planPage: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                // The readout leads — it's the number you open the app for.
                // Same two cards as LIVE so the readout is identical in both.
                BACNowCard(bac: bac, status: status)
                SoberByCard(
                    bac: bac,
                    status: status,
                    hoursSober: hoursUntil(bacThreshold: 0.0),
                    hoursEU: hoursUntil(bacThreshold: 0.02),
                    hoursUS: hoursUntil(bacThreshold: 0.08)
                )

                // Group + check-in sit side by side beneath it — still one
                // glance away, at half the vertical footprint.
                HStack(spacing: 10) {
                    GroupBar(
                        scope: .plan,
                        session: planGroup.session,
                        memberCount: planGroup.members.count,
                        compact: true,
                        onTap: { groupSheetScope = .plan }
                    )
                    VenueChip(
                        location: location,
                        venues: venues,
                        compact: true,
                        onTap: { venueOpen = true }
                    )
                }

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
            journey: journey,
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
                // The night's bar journey is scoped to the sesh too — a
                // leftover route would replay into the next recap.
                journey.clear()
                LiveActivityController.shared.end()
                // Stay on the LIVE page — it resets to its fresh "ready
                // when you are" state, which is where the user expects to
                // land after wrapping a night (not back in PLAN).
            },
            confirmEnd: $liveConfirmEnd
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

    @AppStorage(BACUnitSetting.key, store: BACUnitSetting.store) private var bacUnitMode = "auto"
    private var bacUnit: BACUnit { BACUnitSetting.resolved(mode: bacUnitMode) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                    Text(bacUnit.formatted(bac))
                        .font(.system(size: 54, weight: .black, design: .rounded))
                        .tracking(-1.8)
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

                    Text(bacUnit.caption)
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
        .padding(.vertical, 16)
        .padding(.horizontal, 18)
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

// MARK: - Shared BAC + Sober-by cards
//
// One pair of cards used by BOTH plan and live so the readout is identical
// across modes. Compact by design — these sit at the top of each page.

/// "RIGHT NOW" — the live/projected BAC with the tier scale beneath it.
private struct BACNowCard: View {
    let bac: Double
    let status: Status
    @AppStorage(BACUnitSetting.key, store: BACUnitSetting.store) private var bacUnitMode = "auto"
    private var bacUnit: BACUnit { BACUnitSetting.resolved(mode: bacUnitMode) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("RIGHT NOW")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(Color.bronze)
                Spacer()
                StatusPill(status: status)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(bacUnit.formatted(bac))
                    .font(.system(size: 46, weight: .black, design: .rounded))
                    .tracking(-1.6)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.cream, status.color.opacity(0.92)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: status.color.opacity(0.5), radius: 22, y: 8)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: bac))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(bacUnit.caption)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(Color.bronze)
                    .padding(.bottom, 8)
            }
            BACScale(bac: bac, status: status)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.cream.opacity(0.05), Color.cream.opacity(0.012)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(status.color.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: status.color.opacity(0.3), radius: 30, y: 14)
    }
}

/// "SOBER BY" — time-to-zero with optional EU/US drive-limit milestones.
private struct SoberByCard: View {
    let bac: Double
    let status: Status
    let hoursSober: Double
    let hoursEU: Double
    let hoursUS: Double
    @AppStorage(BACUnitSetting.key, store: BACUnitSetting.store) private var bacUnitMode = "auto"
    private var bacUnit: BACUnit { BACUnitSetting.resolved(mode: bacUnitMode) }
    private var soberAt: Date { Date().addingTimeInterval(hoursSober * 3600) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                Text(Self.formatDuration(hoursSober))
                    .font(.system(size: 26, weight: .black, design: .rounded))
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
                    Text("to \(bacUnit.formatted(0))")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(Color.bronze)
                }
            }
            if hoursEU > 0 || hoursUS > 0 {
                VStack(spacing: 4) {
                    if hoursEU > 0 {
                        limitRow(label: "EU LIMIT (\(bacUnit.formattedLimit(0.02))\(bacUnit.symbol))", hours: hoursEU, tint: status.color.opacity(0.95))
                    }
                    if hoursUS > 0 {
                        limitRow(label: "US LIMIT (\(bacUnit.formattedLimit(0.08))\(bacUnit.symbol))", hours: hoursUS, tint: status.color.opacity(0.7))
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.cream.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
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
            Text(Self.formatDuration(hours))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(tint)
                .monospacedDigit()
        }
    }

    static func formatDuration(_ hours: Double) -> String {
        guard hours > 0 else { return "Sober" }
        let mins = Int((hours * 60).rounded())
        if mins < 60 { return "\(mins) min" }
        let h = mins / 60, m = mins % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
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

    @AppStorage(BACUnitSetting.key, store: BACUnitSetting.store) private var bacUnitMode = "auto"
    private var bacUnit: BACUnit { BACUnitSetting.resolved(mode: bacUnitMode) }

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
                    Text("until \(bacUnit.formatted(0))")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(Color.bronze)
                }
            }

            if hoursUntilEULimit > 0 || hoursUntilUSLimit > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    if hoursUntilEULimit > 0 {
                        milestoneRow(
                            label: "EU LIMIT (\(bacUnit.formattedLimit(0.02))\(bacUnit.symbol))",
                            hours: hoursUntilEULimit,
                            tint: accent.opacity(0.9)
                        )
                    }
                    if hoursUntilUSLimit > 0 {
                        milestoneRow(
                            label: "US LIMIT (\(bacUnit.formattedLimit(0.08))\(bacUnit.symbol))",
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

    @AppStorage(BACUnitSetting.key, store: BACUnitSetting.store) private var bacUnitMode = "auto"
    private var bacUnit: BACUnit { BACUnitSetting.resolved(mode: bacUnitMode) }

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

                LimitTick(x: CGFloat(p02) * w, label: bacUnit.formattedLimit(0.02), sub: "EU LIMIT")
                LimitTick(x: CGFloat(p08) * w, label: bacUnit.formattedLimit(0.08), sub: "US LIMIT")

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
    @ObservedObject var admin: AdminService
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var age: Double
    @State private var sex: Sex
    @State private var weightKg: Double

    @State private var newAvatarData: Data?
    @State private var avatarRemoved = false

    @State private var saving = false
    @State private var errorMessage: String?
    @State private var adminPanelOpen = false
    @State private var offersAdminOpen = false
    @State private var friendsOpen = false

    /// Friends roster + incoming requests — shared with SessionView so the
    /// bell badge and inbox stay in sync (SessionView owns the polling).
    @ObservedObject var friends: FriendsService
    /// Timeline service — used here to load the user's own posted seshs.
    @ObservedObject var feed: FeedService

    /// The user's own posted seshs (Instagram-style grid) + a tapped one.
    @State private var myPosts: [TimelinePost] = []
    @State private var selectedPost: TimelinePost?

    /// BAC display unit — "auto" (region default), "percent", or
    /// "promille". Persisted in the App Group so the widget agrees.
    @AppStorage(BACUnitSetting.key, store: BACUnitSetting.store) private var bacUnitMode = "auto"

    /// Saved night recaps (loaded from disk on open) + which one is
    /// being replayed full-screen.
    @StateObject private var nightHistory = RecapHistoryStore()
    @State private var replayRecap: NightRecap? = nil

    private let postCols = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)

    init(profile: Profile, auth: AuthService, admin: AdminService, friends: FriendsService, feed: FeedService) {
        self.profile = profile
        self.auth = auth
        self.admin = admin
        self.friends = friends
        self.feed = feed
        _name = State(initialValue: profile.name)
        _age = State(initialValue: Double(profile.age))
        _sex = State(initialValue: profile.sex)
        _weightKg = State(initialValue: profile.weightKg)
    }

    /// Instagram-style grid of the user's own posted seshs + count.
    @ViewBuilder
    private var mySeshsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("YOUR SESHS · \(myPosts.count)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(2).foregroundStyle(Color.bronze)
            if myPosts.isEmpty {
                Text("Post a night from a recap and it shows up here.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.5))
            } else {
                LazyVGrid(columns: postCols, spacing: 3) {
                    ForEach(myPosts) { p in
                        Button { selectedPost = p } label: { PostThumb(post: p) }
                            .buttonStyle(PressScaleStyle())
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var dirty: Bool {
        name != profile.name
            || Int(age) != profile.age
            || sex != profile.sex
            || weightKg != profile.weightKg
            || newAvatarData != nil
            || avatarRemoved
    }

    /// Helper line under the BAC-units toggle explaining the current
    /// choice — and, for Auto, which unit the device region resolves to.
    private var bacUnitCaption: String {
        switch bacUnitMode {
        case "percent":
            return "Always shown as percent — e.g. 0.080 %BAC."
        case "promille":
            return "Always shown in promille — e.g. 0.80 ‰."
        default:
            let resolved = BACUnitSetting.resolved(mode: "auto")
            let example = resolved == .promille ? "0.80 ‰" : "0.080 %BAC"
            return "Matches your region — currently \(example)."
        }
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

                    mySeshsSection

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
                        LoungePickerField(label: "BAC UNITS") {
                            VStack(alignment: .leading, spacing: 6) {
                                BACUnitToggle(mode: $bacUnitMode, accent: .whiskey)
                                Text(bacUnitCaption)
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.cream.opacity(0.55))
                                    .padding(.horizontal, 4)
                            }
                        }
                    }
                    .onChange(of: bacUnitMode) { _ in
                        // Push the new unit out to the home-screen widget and
                        // any running Live Activity so they re-render in % / ‰
                        // immediately rather than at their next scheduled tick.
                        WidgetSharedStore.reload()
                        LiveActivityController.shared.refresh()
                    }

                    // Saved night recaps — replay any past night (and add
                    // photos to its stops the morning after). Long-press a
                    // row to delete. Personal and group recaps get their
                    // own sections so the two are easy to tell apart.
                    let personalNights = nightHistory.pastNights.filter { !$0.isGroupRecap }
                    let groupNights = nightHistory.pastNights.filter { $0.isGroupRecap }
                    if !personalNights.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("PAST NIGHTS")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .tracking(2)
                                .foregroundStyle(Color.bronze)
                            ForEach(personalNights.prefix(20)) { night in
                                Button {
                                    replayRecap = night
                                } label: {
                                    PastNightRow(
                                        recap: night,
                                        unit: BACUnitSetting.resolved(mode: bacUnitMode)
                                    )
                                }
                                .buttonStyle(PressScaleStyle())
                                .contextMenu {
                                    Button(role: .destructive) {
                                        nightHistory.removeFromPastNights(night.id)
                                    } label: {
                                        Label("Delete from Past nights", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(.top, 6)
                    }
                    if !groupNights.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 6) {
                                Image(systemName: "person.3.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Color.bronze)
                                Text("GROUP NIGHTS")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .tracking(2)
                                    .foregroundStyle(Color.bronze)
                            }
                            ForEach(groupNights.prefix(20)) { night in
                                Button {
                                    replayRecap = night
                                } label: {
                                    PastNightRow(
                                        recap: night,
                                        unit: BACUnitSetting.resolved(mode: bacUnitMode)
                                    )
                                }
                                .buttonStyle(PressScaleStyle())
                                .contextMenu {
                                    Button(role: .destructive) {
                                        nightHistory.removeFromPastNights(night.id)
                                    } label: {
                                        Label("Delete from Group nights", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(.top, 6)
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

                    // Friends — manage your crew + invite them to seshes.
                    Button {
                        friendsOpen = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "person.2.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Color.whiskey)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("FRIENDS")
                                    .font(.system(size: 12, weight: .black, design: .monospaced))
                                    .tracking(2.0)
                                    .foregroundStyle(Color.cream)
                                Text("Add friends and invite them to a sesh")
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.cream.opacity(0.55))
                            }
                            Spacer()
                            if !friends.incoming.isEmpty {
                                Text("\(friends.incoming.count)")
                                    .font(.system(size: 11, weight: .black, design: .rounded))
                                    .foregroundStyle(Color.ink)
                                    .frame(minWidth: 20, minHeight: 20)
                                    .background(Circle().fill(Color.whiskey))
                            }
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color.bronze)
                        }
                        .padding(.vertical, 14)
                        .padding(.horizontal, 18)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.whiskey.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Color.whiskey.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(PressScaleStyle())

                    // Admin entry — only shown to admins / the owner. Opens
                    // the catalog-role management panel.
                    if admin.isAdmin {
                        Button {
                            adminPanelOpen = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(Color.whiskey)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(admin.isOwner ? "OWNER" : "ADMIN")
                                        .font(.system(size: 12, weight: .black, design: .monospaced))
                                        .tracking(2.0)
                                        .foregroundStyle(Color.cream)
                                    Text(admin.isOwner
                                         ? "Add beverages instantly · manage admins"
                                         : "Add beverages without verification")
                                        .font(.system(size: 11, weight: .medium, design: .rounded))
                                        .foregroundStyle(Color.cream.opacity(0.55))
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(Color.bronze)
                            }
                            .padding(.vertical, 14)
                            .padding(.horizontal, 18)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color.whiskey.opacity(0.08))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(Color.whiskey.opacity(0.3), lineWidth: 1)
                            )
                        }
                        .buttonStyle(PressScaleStyle())

                        // Manage venue specials — add/remove curated offers
                        // from the app (no SQL). Admin-only.
                        Button {
                            offersAdminOpen = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "tag.fill")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(Color.whiskey)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("MANAGE SPECIALS")
                                        .font(.system(size: 12, weight: .black, design: .monospaced))
                                        .tracking(2.0)
                                        .foregroundStyle(Color.cream)
                                    Text("Add or remove venue offers on the map")
                                        .font(.system(size: 11, weight: .medium, design: .rounded))
                                        .foregroundStyle(Color.cream.opacity(0.55))
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(Color.bronze)
                            }
                            .padding(.vertical, 14)
                            .padding(.horizontal, 18)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color.whiskey.opacity(0.08))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(Color.whiskey.opacity(0.3), lineWidth: 1)
                            )
                        }
                        .buttonStyle(PressScaleStyle())
                    }

                    // Support contact — opens the mail composer pre-addressed
                    // to support. Gives users (and App Review) a clear way to
                    // reach us.
                    if let supportURL = URL(string: "mailto:contact@seshapp.xyz?subject=sesh%20support") {
                        Link(destination: supportURL) {
                            HStack(spacing: 10) {
                                Image(systemName: "envelope.fill")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(Color.whiskey)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("CONTACT SUPPORT")
                                        .font(.system(size: 12, weight: .black, design: .monospaced))
                                        .tracking(2.0)
                                        .foregroundStyle(Color.cream)
                                    Text("Questions or trouble? We're here.")
                                        .font(.system(size: 11, weight: .medium, design: .rounded))
                                        .foregroundStyle(Color.cream.opacity(0.55))
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(Color.bronze)
                            }
                            .padding(.vertical, 14)
                            .padding(.horizontal, 18)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color.whiskey.opacity(0.08))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(Color.whiskey.opacity(0.3), lineWidth: 1)
                            )
                        }
                        .buttonStyle(PressScaleStyle())
                    }

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
        .sheet(isPresented: $adminPanelOpen) {
            AdminPanelView(admin: admin)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.ink)
        }
        .sheet(isPresented: $offersAdminOpen) {
            OffersAdminView()
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.ink)
        }
        .sheet(isPresented: $friendsOpen) {
            FriendsView(friends: friends, auth: auth)
                .presentationBackground(Color.ink)
        }
        // Replay a saved night — closing button is a plain DONE.
        .fullScreenCover(item: $replayRecap, onDismiss: {
            // Posting a past night moves it onto the timeline — refresh the
            // posts grid so it appears immediately.
            Task { myPosts = await feed.userPosts(profile.id) }
        }) { night in
            NightRecapView(recap: night, history: nightHistory, mode: .replay) {
                replayRecap = nil
            }
        }
        // Tap one of your posted seshs to view it.
        .fullScreenCover(item: $selectedPost, onDismiss: {
            Task { myPosts = await feed.userPosts(profile.id) }
        }) { post in
            PostDetailView(post: post, feed: feed, history: nightHistory) { selectedPost = nil }
        }
        .task { myPosts = await feed.userPosts(profile.id) }
    }
}

// MARK: - Admin panel

/// Catalog-role management. Owners get the grant-by-email field + a
/// demotable roster; plain admins just see their status. All actions are
/// server-gated to the owner, so the UI here is a convenience, not the
/// security boundary.
private struct AdminPanelView: View {
    @ObservedObject var admin: AdminService
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var working = false
    @State private var toast: String?

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if admin.isOwner {
                        grantSection
                        rosterSection
                    } else {
                        Text("You can add beverages to the catalog without waiting for 5-user verification. Only the owner can promote or demote admins.")
                            .font(.system(size: 13, weight: .regular, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.65))
                            .lineSpacing(3)
                    }
                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 24)
                .padding(.top, 14)
                .padding(.bottom, 32)
            }
        }
        .preferredColorScheme(.dark)
        .task { await admin.loadAdmins() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(admin.isOwner ? "OWNER" : "ADMIN")
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .tracking(2.4)
                .foregroundStyle(Color.bronze)
            Text("Catalog roles")
                .font(.system(size: 26, weight: .black, design: .rounded))
                .foregroundStyle(Color.cream)
            if let toast {
                Text(toast)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.whiskey)
            }
        }
        .padding(.top, 8)
    }

    private var grantSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GRANT ADMIN")
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(2.0)
                .foregroundStyle(Color.bronze)
            HStack(spacing: 8) {
                TextField("", text: $email, prompt: Text("their account email")
                    .foregroundStyle(Color.cream.opacity(0.4)))
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled(true)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.inkElev.opacity(0.7))
                    )
                Button {
                    grant()
                } label: {
                    Group {
                        if working {
                            ProgressView().tint(Color.ink)
                        } else {
                            Image(systemName: "plus")
                                .font(.system(size: 15, weight: .black))
                        }
                    }
                    .foregroundStyle(Color.ink)
                    .frame(width: 46, height: 46)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.whiskey))
                }
                .buttonStyle(PressScaleStyle())
                .disabled(working || email.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var rosterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ADMINS")
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(2.0)
                .foregroundStyle(Color.bronze)
            VStack(spacing: 8) {
                ForEach(admin.admins) { entry in
                    HStack(spacing: 12) {
                        AvatarView(urlString: nil, initial: String(entry.name.prefix(1)).uppercased(), size: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.name)
                                .font(.system(size: 14, weight: .heavy, design: .rounded))
                                .foregroundStyle(Color.cream)
                            Text(entry.isOwner ? "Owner" : "Admin")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.cream.opacity(0.5))
                        }
                        Spacer(minLength: 0)
                        if entry.isOwner {
                            Image(systemName: "crown.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color.whiskey)
                        } else {
                            Button {
                                Task { await admin.revoke(userId: entry.userId) }
                            } label: {
                                Text("DEMOTE")
                                    .font(.system(size: 10, weight: .black, design: .monospaced))
                                    .tracking(1.2)
                                    .foregroundStyle(Color(red: 0.85, green: 0.40, blue: 0.34))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .overlay(
                                        Capsule().strokeBorder(Color(red: 0.85, green: 0.40, blue: 0.34).opacity(0.4), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(PressScaleStyle())
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.inkElev.opacity(0.6))
                    )
                }
            }
        }
    }

    private func grant() {
        let target = email.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        working = true
        toast = nil
        Task {
            let name = await admin.grant(email: target)
            working = false
            if let name {
                toast = "\(name) is now an admin"
                email = ""
            } else {
                toast = "No account found for that email"
            }
        }
    }
}

// MARK: - Admin: manage venue specials
//
// Owner/admin-only. Look a bar up on the map, drop an offer on it, choose when
// it runs (days + time window + optional end date). Backed by the admin RPCs
// in migration 030 — no SQL needed to add or remove a special.

private func offerKindLabel(_ k: String) -> String {
    switch k {
    case "happy_hour": return "Happy hour"
    case "free_entry": return "Free entry"
    case "bundle":     return "Bundle"
    case "event":      return "Event"
    default:           return "Price deal"
    }
}

struct AdminOffer: Decodable, Identifiable {
    let id: UUID
    let venueId: UUID
    let venueName: String
    let lat: Double
    let lon: Double
    let kind: String
    let title: String
    let description: String?
    let finePrint: String?
    let redeem: String
    let startsAt: Date?
    let endsAt: Date?
    let activeDays: [Int]?
    let startMinute: Int?
    let endMinute: Int?
    let isActive: Bool
    let approved: Bool
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case venueId = "venue_id"
        case venueName = "venue_name"
        case lat, lon, kind, title, description
        case finePrint = "fine_print"
        case redeem
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case activeDays = "active_days"
        case startMinute = "start_minute"
        case endMinute = "end_minute"
        case isActive = "is_active"
        case approved
        case createdAt = "created_at"
    }

    /// "Mon Tue · 16:00–19:00 · until 30 Jun" style line for the admin list.
    var scheduleSummary: String {
        var parts: [String] = []
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        if let days = activeDays, !days.isEmpty {
            parts.append(days.sorted().compactMap { (0..<7).contains($0) ? names[$0] : nil }.joined(separator: " "))
        } else {
            parts.append("Every day")
        }
        if let s = startMinute, let e = endMinute {
            func hhmm(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }
            parts.append("\(hhmm(s))–\(hhmm(e))")
        }
        if let end = endsAt {
            let f = DateFormatter(); f.dateFormat = "d MMM"
            parts.append("until \(f.string(from: end))")
        }
        return parts.joined(separator: " · ")
    }
}

@MainActor
final class OffersAdminService: ObservableObject {
    @Published private(set) var offers: [AdminOffer] = []
    @Published private(set) var loading = false
    /// Surfaced to the add-offer form so a failed save isn't silent.
    @Published var lastError: String?

    func load() async {
        loading = true; defer { loading = false }
        do {
            offers = try await supabase.rpc("admin_list_offers").execute().value
        } catch {
            // leave the previous list on a transient failure
        }
    }

    @discardableResult
    func create(
        venue: MapKitVenueResult,
        kind: String, title: String, description: String, finePrint: String,
        startsAt: Date, endsAt: Date?, activeDays: [Int]?, startMinute: Int?, endMinute: Int?
    ) async -> Bool {
        struct P: Encodable {
            let p_name: String
            let p_address: String?
            let p_city: String?
            let p_lat: Double
            let p_lon: Double
            let p_external_id: String?
            let p_kind: String
            let p_title: String
            let p_description: String?
            let p_fine_print: String?
            let p_redeem: String
            let p_code: String?
            let p_starts_at: String
            let p_ends_at: String?
            let p_active_days: [Int]?
            let p_start_minute: Int?
            let p_end_minute: Int?
        }
        let iso = ISO8601DateFormatter()
        lastError = nil
        do {
            _ = try await supabase.rpc("admin_create_offer", params: P(
                p_name: venue.name,
                p_address: venue.address,
                p_city: venue.city,
                p_lat: venue.lat,
                p_lon: venue.lon,
                p_external_id: venue.id,
                p_kind: kind,
                p_title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                p_description: description.isEmpty ? nil : description,
                p_fine_print: finePrint.isEmpty ? nil : finePrint,
                p_redeem: "show",
                p_code: nil,
                p_starts_at: iso.string(from: startsAt),
                p_ends_at: endsAt.map { iso.string(from: $0) },
                p_active_days: activeDays,
                p_start_minute: startMinute,
                p_end_minute: endMinute
            )).execute()
            await load()
            return true
        } catch {
            lastError = String(describing: error)
            return false
        }
    }

    func delete(_ id: UUID) async {
        struct P: Encodable { let p_offer_id: String }
        do {
            _ = try await supabase.rpc("admin_delete_offer", params: P(p_offer_id: id.uuidString.lowercased())).execute()
            await load()
        } catch {
            // no-op
        }
    }
}

/// The management list — every curated offer + an entry point to add one.
struct OffersAdminView: View {
    @StateObject private var svc = OffersAdminService()
    @State private var addOpen = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("ADMIN")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .tracking(2.4)
                                .foregroundStyle(Color.bronze)
                            Text("Venue specials")
                                .font(.system(size: 26, weight: .heavy, design: .rounded))
                                .foregroundStyle(Color.cream)
                        }
                        Spacer()
                        Button(action: { dismiss() }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Color.cream.opacity(0.6))
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(Color.cream.opacity(0.06)))
                        }
                        .buttonStyle(PressScaleStyle())
                    }

                    Button { addOpen = true } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(Color.ink)
                            Text("Add a special")
                                .font(.system(size: 15, weight: .heavy, design: .rounded))
                                .foregroundStyle(Color.ink)
                            Spacer()
                        }
                        .padding(.vertical, 14).padding(.horizontal, 16)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.whiskey))
                    }
                    .buttonStyle(PressScaleStyle())

                    if svc.offers.isEmpty {
                        Text(svc.loading ? "Loading…" : "No specials yet. Add one above.")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.5))
                            .padding(.vertical, 24)
                    } else {
                        ForEach(svc.offers) { offer in
                            adminOfferRow(offer)
                        }
                    }
                    Spacer(minLength: 24)
                }
                .padding(20)
            }
        }
        .preferredColorScheme(.dark)
        .task { await svc.load() }
        .sheet(isPresented: $addOpen) {
            AddOfferSheet(svc: svc) { addOpen = false }
                .presentationBackground(Color.ink)
        }
    }

    private func adminOfferRow(_ o: AdminOffer) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(o.title)
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.cream)
                        .lineLimit(1)
                    Text(offerKindLabel(o.kind).uppercased())
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(Color.whiskey))
                }
                Text(o.venueName)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.7))
                Text(o.scheduleSummary)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.bronze)
            }
            Spacer(minLength: 0)
            Button {
                Task { await svc.delete(o.id) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color(red: 0.85, green: 0.40, blue: 0.34))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.cream.opacity(0.05)))
            }
            .buttonStyle(PressScaleStyle())
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.cream.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.cream.opacity(0.08), lineWidth: 1))
    }
}

/// The add-offer form: pick a bar on the map, write the offer, choose when.
private struct AddOfferSheet: View {
    @ObservedObject var svc: OffersAdminService
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    @StateObject private var location = LocationService()
    @StateObject private var search = MapKitVenueSearch()
    @State private var query = ""
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var selected: MapKitVenueResult?

    @State private var kind = "price"
    @State private var title = ""
    @State private var desc = ""
    @State private var finePrint = ""
    @State private var days: Set<Int> = []
    @State private var allDay = true
    @State private var startTime = Calendar.current.date(bySettingHour: 16, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var endTime = Calendar.current.date(bySettingHour: 19, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var hasEnd = false
    @State private var endDate = Date().addingTimeInterval(7 * 24 * 3600)
    @State private var saving = false

    private let kinds = ["price", "happy_hour", "free_entry", "bundle", "event"]
    private let dayLabels = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]

    private var canSave: Bool {
        selected != nil && !title.trimmingCharacters(in: .whitespaces).isEmpty && !saving
    }

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("New special")
                            .font(.system(size: 24, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color.cream)
                        Spacer()
                        Button(action: { dismiss() }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Color.cream.opacity(0.6))
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(Color.cream.opacity(0.06)))
                        }
                        .buttonStyle(PressScaleStyle())
                    }

                    venuePicker
                    if selected != nil { offerForm }
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
            kicker("VENUE")
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
                Map(initialPosition: .region(MKCoordinateRegion(center: v.coordinate, latitudinalMeters: 800, longitudinalMeters: 800))) {
                    Marker(v.name, systemImage: "wineglass.fill", coordinate: v.coordinate)
                        .tint(Color.whiskey)
                }
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .allowsHitTesting(false)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color.cream.opacity(0.5))
                    TextField("Search a bar…", text: $query)
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
                                Image(systemName: "mappin").font(.system(size: 13, weight: .bold)).foregroundStyle(Color.ink)
                            }
                            .onTapGesture { withAnimation { selected = r } }
                        }
                    }
                }
                .mapStyle(.standard(elevation: .flat, pointsOfInterest: .including([.nightlife, .restaurant, .brewery, .winery])))
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                ForEach(search.results.prefix(6)) { r in
                    Button { withAnimation { selected = r } } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "mappin.circle.fill").font(.system(size: 16)).foregroundStyle(Color.whiskey)
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

    @ViewBuilder
    private var offerForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                kicker("TYPE")
                Menu {
                    ForEach(kinds, id: \.self) { k in
                        Button(offerKindLabel(k)) { kind = k }
                    }
                } label: {
                    HStack {
                        Text(offerKindLabel(kind)).foregroundStyle(Color.cream)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.bronze)
                    }
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.cream.opacity(0.05)))
                }
            }

            formField("HEADLINE", text: $title, placeholder: "39 kr stora stark")
            formField("DESCRIPTION", text: $desc, placeholder: "Show this at the bar", multiline: true)
            formField("FINE PRINT (optional)", text: $finePrint, placeholder: "20+ · one per guest")

            VStack(alignment: .leading, spacing: 8) {
                kicker("ON WHICH DAYS")
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
                Text(days.isEmpty ? "Empty = every day" : "Selected days only")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.cream.opacity(0.4))
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
            }

            Toggle(isOn: $hasEnd) {
                Text("Has an end date").font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(Color.cream)
            }
            .tint(Color.whiskey)
            if hasEnd {
                DatePicker("Ends", selection: $endDate, displayedComponents: .date)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.7))
                    .tint(Color.whiskey)
            }

            Button(action: save) {
                HStack {
                    if saving { ProgressView().tint(Color.ink) }
                    Text(saving ? "Saving…" : "Save special")
                        .font(.system(size: 15, weight: .black, design: .rounded))
                        .foregroundStyle(Color.ink)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(canSave ? Color.whiskey : Color.cream.opacity(0.12)))
            }
            .buttonStyle(PressScaleStyle())
            .disabled(!canSave)
            .padding(.top, 4)

            if let err = svc.lastError {
                Text(err)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(red: 0.85, green: 0.40, blue: 0.34))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func save() {
        guard let venue = selected else { return }
        saving = true
        func minutes(_ d: Date) -> Int {
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            return (c.hour ?? 0) * 60 + (c.minute ?? 0)
        }
        Task {
            let ok = await svc.create(
                venue: venue,
                kind: kind,
                title: title,
                description: desc,
                finePrint: finePrint,
                startsAt: Date(),
                endsAt: hasEnd ? endDate : nil,
                activeDays: days.isEmpty ? nil : days.sorted(),
                startMinute: allDay ? nil : minutes(startTime),
                endMinute: allDay ? nil : minutes(endTime)
            )
            saving = false
            if ok { onDone(); dismiss() }
        }
    }

    private func kicker(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(2.0)
            .foregroundStyle(Color.bronze)
    }

    @ViewBuilder
    private func formField(_ label: String, text: Binding<String>, placeholder: String, multiline: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            kicker(label)
            Group {
                if multiline {
                    TextField("", text: text, prompt: Text(placeholder).foregroundStyle(Color.cream.opacity(0.35)), axis: .vertical)
                        .lineLimit(1...3)
                } else {
                    TextField("", text: text, prompt: Text(placeholder).foregroundStyle(Color.cream.opacity(0.35)))
                }
            }
            .font(.system(size: 15, weight: .medium, design: .rounded))
            .foregroundStyle(Color.cream)
            .tint(Color.whiskey)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.cream.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.cream.opacity(0.08), lineWidth: 1))
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

/// Three-way segmented control for the BAC display unit. Mirrors
/// `SexToggle`'s styling. Bound to the stored mode string so the choice
/// persists in the App Group and the widget picks it up.
private struct BACUnitToggle: View {
    @Binding var mode: String
    let accent: Color

    private struct Opt: Identifiable {
        let id: String
        let label: String
    }
    private let options = [
        Opt(id: "auto", label: "Auto"),
        Opt(id: "percent", label: "%"),
        Opt(id: "promille", label: "‰"),
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options) { option in
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                        mode = option.id
                    }
                } label: {
                    Text(option.label.uppercased())
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(2.2)
                        .foregroundStyle(mode == option.id ? Color.ink : Color.cream.opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            ZStack {
                                if mode == option.id {
                                    Capsule().fill(Color.cream)
                                        .shadow(color: accent.opacity(0.5), radius: 12)
                                } else {
                                    Capsule().fill(Color.cream.opacity(0.04))
                                }
                            }
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                Color.cream.opacity(mode == option.id ? 0 : 0.08),
                                lineWidth: 1
                            )
                        )
                }
                .buttonStyle(PressScaleStyle())
            }
        }
    }
}

// Internal so sibling files in the app target (e.g. BarcodeScanner.swift)
// can reuse the same press-feedback button style.
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Disclaimer

private struct Disclaimer: View {
    @AppStorage(BACUnitSetting.key, store: BACUnitSetting.store) private var bacUnitMode = "auto"
    private var bacUnit: BACUnit { BACUnitSetting.resolved(mode: bacUnitMode) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(Color.whiskey.opacity(0.6))
                .frame(width: 2)
                .frame(maxHeight: .infinity)

            Text("Widmark estimate based on drink volume, ABV, body weight and time. Legal limits vary: \(bacUnit.formattedLimit(0.02))\(bacUnit.symbol) in much of the EU, \(bacUnit.formattedLimit(0.08))\(bacUnit.symbol) in the US & UK. Not a legal or medical reference. Never use to decide whether to drive.")
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
    /// Compact = the side-by-side variant used under the BAC readout: smaller
    /// chrome, shortened idle copy, no chevron, lighter shadow.
    var compact: Bool = false
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: compact ? 9 : 12) {
                ZStack {
                    Circle()
                        .fill(Color.whiskey.opacity(session == nil ? 0.12 : 0.22))
                        .frame(width: compact ? 28 : 32, height: compact ? 28 : 32)
                    Image(systemName: session == nil ? "person.2" : "person.2.fill")
                        .font(.system(size: compact ? 12 : 13, weight: .bold))
                        .foregroundStyle(Color.whiskey)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(scope.label) GROUP")
                        .font(.system(size: compact ? 9 : 10, weight: .semibold, design: .monospaced))
                        .tracking(compact ? 1.6 : 2.2)
                        .foregroundStyle(session == nil ? Color.bronze : Color.whiskey)
                        .lineLimit(1)
                    if let s = session {
                        if compact {
                            Text(s.joinCode)
                                .font(.system(size: 14, weight: .black, design: .monospaced))
                                .tracking(2)
                                .foregroundStyle(Color.cream)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        } else {
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
                        Text(compact ? "Start a group" : "Drink together in \(scope.label.lowercased())")
                            .font(.system(size: compact ? 13 : 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.cream)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }

                Spacer(minLength: 0)

                if !compact {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
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
                        session == nil
                            ? Color.cream.opacity(0.08)
                            : Color.whiskey.opacity(0.35),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: (session == nil ? Color.black : Color.whiskey).opacity(compact ? 0.12 : 0.18),
                radius: compact ? 10 : 18, y: compact ? 5 : 10
            )
        }
        .buttonStyle(PressScaleStyle())
    }
}

// MARK: - Venue Offers (deals map)
//
// Phase A of venue marketing: a read-only "deals near you" map. Pins are
// venues with live offers (venue_offers, migration 029, loaded by
// VenueService). Tap a pin → that venue's offers; tap "Show at the bar" →
// a live-ticking redeem card (no server validation yet — staff eyeball it).
// Entry point is the DealsCard on the plan page.

/// Bottom navigation bar — the section switcher (moved here from the top)
/// plus the new DEALS tab. Four equal items, icon + label, whiskey when active.
private struct BottomTabBar: View {
    @Binding var tab: TopTab
    let liveActive: Bool
    /// At least one friend is currently in a live sesh — green dot on
    /// NIGHTLINE so the user knows the TONIGHT strip has something to show.
    var friendsLive: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            item(.plan,     icon: "gauge.medium",                  label: "PLAN")
            item(.live,     icon: "dot.radiowaves.left.and.right", label: "LIVE", pulse: liveActive)
            item(.timeline, icon: "square.stack.fill",             label: "NIGHTLINE",
                 pulse: friendsLive, pulseColor: Color(red: 0.51, green: 0.72, blue: 0.48))
            item(.offers,   icon: "map.fill",                      label: "DEALS")
        }
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background(Color.ink.opacity(0.96))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.cream.opacity(0.08)).frame(height: 1)
        }
    }

    @ViewBuilder
    private func item(_ value: TopTab, icon: String, label: String,
                      pulse: Bool = false, pulseColor: Color = .whiskey) -> some View {
        let on = tab == value
        Button {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) { tab = value }
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: on ? .bold : .semibold))
                        .foregroundStyle(on ? Color.whiskey : Color.cream.opacity(0.55))
                    // Live pulse, mirroring the old switcher's LIVE dot.
                    if pulse {
                        Circle()
                            .fill(pulseColor)
                            .frame(width: 6, height: 6)
                            .offset(x: 12, y: -10)
                    }
                }
                Text(label)
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(0.8)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(on ? Color.whiskey : Color.cream.opacity(0.5))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Full-screen interactive map of venues with live offers.
/// Hosts the DEALS map inside the paged TabView without hitching the page
/// swipe. A SwiftUI Map is the heaviest view in the app, and both building
/// and tearing it down synchronously with the tab change landed exactly in
/// the middle of the swipe animation — the source of the "deals tab is
/// laggy" jank. So the map mounts a beat AFTER the swipe settles (behind a
/// cheap ink placeholder) and unmounts a beat after leaving, keeping the
/// transition itself at full frame rate. The memory gating survives: the
/// map is still torn down whenever the user is off the tab.
private struct DeferredOffersPage: View {
    let active: Bool
    @ObservedObject var venues: VenueService
    @ObservedObject var location: LocationService
    let onBack: () -> Void

    @State private var mounted = false
    /// Debounce token: bumped on every activation flip so a stale sleep
    /// (user swiped in and straight back out) can't apply an old decision.
    @State private var generation = 0

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            if mounted {
                OffersMapView(venues: venues, location: location)
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

private struct OffersMapView: View {
    @ObservedObject var venues: VenueService
    @ObservedObject var location: LocationService
    /// nil when embedded as a tab (navigation is the bottom bar); set when
    /// presented modally so the header shows a close button.
    var onClose: (() -> Void)? = nil

    @State private var camera: MapCameraPosition = .automatic
    @State private var selectedVenueId: UUID? = nil

    /// Only surface offers within this radius of the user — a global dataset
    /// shouldn't dump bars on the other side of the planet onto the map.
    /// (Server-side geo-filtering is a Phase B concern; client-side is fine
    /// for the small Phase A catalog.) Falls back to showing all when we have
    /// no location fix yet.
    private let radiusMeters: CLLocationDistance = 50_000

    private var pins: [Venue] {
        let all = venues.venuesWithOffers
        guard let here = location.location else { return all }
        return all.filter {
            let c = venues.coordinate(for: $0)
            return CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: here) <= radiusMeters
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.ink.ignoresSafeArea()

            Map(position: $camera) {
                UserAnnotation()
                ForEach(pins) { venue in
                    Annotation(
                        venue.name,
                        coordinate: venues.coordinate(for: venue)
                    ) {
                        OfferPin(count: venues.offers(for: venue).count,
                                 selected: selectedVenueId == venue.id)
                            .onTapGesture {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    selectedVenueId = venue.id
                                }
                            }
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .including([.nightlife, .restaurant, .brewery, .winery])))

            header

            if let id = selectedVenueId, let venue = pins.first(where: { $0.id == id }) {
                offerSheet(for: venue)
            }
        }
        .task {
            recenter()
            await venues.refreshIfStale()
            await venues.resolveOfferCoordinates()
            recenter()
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("DEALS NEARBY")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(Color.bronze)
                Text("\(pins.count) \(pins.count == 1 ? "spot" : "spots")")
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.cream)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Capsule().fill(Color.ink.opacity(0.6)))
            Spacer()
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.cream)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color.ink.opacity(0.7)))
                        .overlay(Circle().strokeBorder(Color.cream.opacity(0.15), lineWidth: 1))
                }
                .buttonStyle(PressScaleStyle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    @ViewBuilder
    private func offerSheet(for venue: Venue) -> some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
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
                    Spacer()
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            selectedVenueId = nil
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Color.cream.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
                ForEach(venues.offers(for: venue)) { offer in
                    OfferRow(offer: offer)
                }
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.inkElev))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.whiskey.opacity(0.25), lineWidth: 1))
            .padding(.horizontal, 14)
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
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
                .font(.system(size: selected ? 18 : 14, weight: .bold))
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
                    .font(.system(size: 14, weight: .bold))
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
                    HStack(spacing: 8) {
                        if let w = offer.windowLabel { tag(w, system: "clock") }
                        if let fp = offer.finePrint {
                            Text(fp)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.bronze)
                        }
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
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.ink)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.whiskey))
        }
    }

    private func tag(_ text: String, system: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: system).font(.system(size: 9, weight: .bold))
            Text(text).font(.system(size: 10, weight: .black, design: .monospaced))
        }
        .foregroundStyle(Color.whiskey)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(Color.whiskey.opacity(0.12)))
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
                        .fill(Color.whiskey.opacity(venues.currentVenue == nil ? 0.14 : 0.32))
                        .frame(width: compact ? 28 : 32, height: compact ? 28 : 32)
                    Image(systemName: venues.currentVenue == nil
                          ? "mappin.and.ellipse"
                          : "mappin.circle.fill")
                        .font(.system(size: compact ? 12 : 13, weight: .bold))
                        .foregroundStyle(Color.whiskey)
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
                                        .font(.system(size: 10, weight: .black))
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
                        .font(.system(size: 12, weight: .bold))
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
            .shadow(
                color: (venues.currentVenue == nil ? Color.black : Color.whiskey).opacity(compact ? 0.12 : 0.18),
                radius: compact ? 10 : 18, y: compact ? 5 : 10
            )
        }
        .buttonStyle(PressScaleStyle())
    }
}

private struct VenueSheet: View {
    @ObservedObject var location: LocationService
    @ObservedObject var venues: VenueService
    /// The live group, when one is running — enables "check in the whole
    /// group" so not everyone has to check in. nil ⇒ solo (no group UI).
    @ObservedObject var group: SessionService
    @StateObject private var search = MapKitVenueSearch()
    @State private var query: String = ""
    @State private var checkInInFlight: String? = nil
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
                                    .font(.system(size: 13, weight: .bold))
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
            search.search(query: snapshot, origin: location.location)
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
            .mapControls {
                MapUserLocationButton()
                MapCompass()
            }
            .frame(height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
                .font(.system(size: 22, weight: .semibold))
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
                    .font(.system(size: 12, weight: .bold))
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
                        .font(.system(size: 9, weight: .black))
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
                                .font(.system(size: 15, weight: .black))
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
                                .font(.system(size: 12, weight: .bold))
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
                            .font(.system(size: 11, weight: .bold))
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
                    .font(.system(size: 10, weight: .bold))
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
                            .font(.system(size: 16, weight: .bold))
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
                                    .font(.system(size: 8, weight: .black))
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
                    .fill(hasOffer ? Color.whiskey.opacity(0.15)
                          : (isCurrent ? Color.whiskey.opacity(0.10) : Color.cream.opacity(0.025)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        hasOffer ? Color.whiskey.opacity(0.6)
                        : (isCurrent ? Color.whiskey.opacity(0.45) : Color.cream.opacity(0.06)),
                        lineWidth: hasOffer ? 1.5 : 1
                    )
            )
            .shadow(color: hasOffer ? Color.whiskey.opacity(0.28) : .clear, radius: 12, y: 4)
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

    @AppStorage(BACUnitSetting.key, store: BACUnitSetting.store) private var bacUnitMode = "auto"
    private var bacUnit: BACUnit { BACUnitSetting.resolved(mode: bacUnitMode) }

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
                    Text(bacUnit.formatted(bac))
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
    /// The signed-in user's friends — powers the "Invite friends" picker so
    /// you can pull people into the sesh without a code.
    @ObservedObject var friends: FriendsService
    @Environment(\.dismiss) private var dismiss

    @State private var friendPickerOpen = false

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
    /// The saved group the user tapped — drives the detail popup that
    /// lists the crew and offers a one-tap "start sesh & invite". nil
    /// when the popup is closed.
    @State private var detailGroup: SavedGroup?

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
                        // Tapping a saved crew now opens a detail popup
                        // (roster + one-tap invite) rather than silently
                        // spinning up a session. The crew already has the
                        // app — that's why they're saved — so the popup's
                        // primary action sends native invites, no iMessage.
                        onTap: { detailGroup = entry }
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
        .sheet(isPresented: $friendPickerOpen) {
            if let session = group.session {
                FriendPickerSheet(
                    friends: friends,
                    invites: invites,
                    session: session,
                    scope: group.scope,
                    alreadyIn: Set(group.members.map(\.profileId))
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.ink)
            }
        }
        // Saved-crew detail popup: roster + one-tap "start sesh & invite
        // all". Presented when the user taps a SavedGroupRow.
        .sheet(item: $detailGroup) { entry in
            SavedGroupDetailSheet(
                entry: entry,
                group: group,
                invites: invites,
                onRemove: {
                    savedGroups.remove(id: entry.id)
                    detailGroup = nil
                },
                onDone: { detailGroup = nil }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.ink)
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
                // Stay in the sheet — it flips to the active view with the
                // join code, Share, and Invite friends right here, so the
                // user can invite immediately without reopening the sheet.
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

                // Pull friends straight in — or search anyone by username.
                Button {
                    friendPickerOpen = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 12, weight: .bold))
                        Text("INVITE FRIENDS")
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .tracking(1.6)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(Color.cream)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.whiskey.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.whiskey.opacity(0.4), lineWidth: 1)
                    )
                }
                .buttonStyle(PressScaleStyle())
                .padding(.top, 4)
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
                    Text("END SESH")
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
                    "End your \(group.scope.label.lowercased()) sesh?",
                    isPresented: $confirmLeave,
                    titleVisibility: .visible
                ) {
                    // "Leave & keep my night going" lives in the top-bar menu
                    // (it needs the solo live store to move drinks into); the
                    // sheet just ends the night with a recap.
                    Button("End my sesh", role: .destructive) {
                        Task {
                            await group.leave(cousinSessionId: cousin.session?.id, captureRecap: true)
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

    /// Title prefers the crew's actual names ("Sara, Jonas +2") over the
    /// opaque join code — names are what make a saved crew recognisable.
    /// Falls back to the code when no roster was captured (legacy entries).
    private var title: String {
        guard !entry.savedMembers.isEmpty else { return entry.joinCode }
        let names = entry.savedMembers.prefix(2).map(\.name)
        let remaining = entry.savedMembers.count - names.count
        return names.joined(separator: ", ") + (remaining > 0 ? " +\(remaining)" : "")
    }

    private var countLabel: String {
        let n = max(entry.lastMemberCount, entry.savedMembers.count)
        return "\(n) \(n == 1 ? "person" : "people")"
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                avatarStack
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.cream)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(countLabel)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.6))
                        Circle()
                            .fill(Color.bronze.opacity(0.5))
                            .frame(width: 2, height: 2)
                        Text(lastJoinedLabel)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.45))
                    }
                }
                Spacer(minLength: 0)
                ZStack {
                    Circle()
                        .fill(Color.whiskey.opacity(0.14))
                        .frame(width: 30, height: 30)
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.whiskey)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.inkElev.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.cream.opacity(0.08), lineWidth: 1)
            )
            .opacity(busy ? 0.55 : 1.0)
        }
        .buttonStyle(PressScaleStyle())
        .disabled(busy)
        .accessibilityLabel("Saved crew \(title), \(countLabel)")
    }

    /// Overlapping avatar cluster. Falls back to a whiskey code tile for
    /// legacy entries that never captured a roster.
    @ViewBuilder
    private var avatarStack: some View {
        if entry.savedMembers.isEmpty {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.whiskey.opacity(0.16))
                    .frame(width: 46, height: 46)
                Text(String(entry.joinCode.prefix(2)))
                    .font(.system(size: 14, weight: .black, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(Color.whiskey)
            }
        } else {
            HStack(spacing: -12) {
                ForEach(entry.savedMembers.prefix(3)) { m in
                    AvatarView(
                        urlString: m.avatarURL,
                        initial: String(m.name.prefix(1)).uppercased(),
                        size: 34
                    )
                    .overlay(Circle().strokeBorder(Color.ink, lineWidth: 2))
                }
                if entry.savedMembers.count > 3 {
                    ZStack {
                        Circle()
                            .fill(Color.inkElev)
                            .frame(width: 34, height: 34)
                            .overlay(Circle().strokeBorder(Color.ink, lineWidth: 2))
                        Text("+\(entry.savedMembers.count - 3)")
                            .font(.system(size: 11, weight: .black, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.8))
                    }
                }
            }
        }
    }
}

// MARK: - Saved group detail popup

/// Tapping a saved crew opens this. Lists every participant and offers a
/// single primary action: spin up a fresh session and fire native in-app
/// invites to the whole crew at once. No iMessage fallback here — by
/// definition a *saved* crew already has the app (that's how we captured
/// their profile ids), so the native path is always the right one. The
/// iMessage share lives in the new-group flow for people who aren't users
/// yet.
private struct SavedGroupDetailSheet: View {
    let entry: SavedGroup
    @ObservedObject var group: SessionService
    @ObservedObject var invites: InvitesService
    /// Remove the crew from the saved list, then close.
    let onRemove: () -> Void
    /// Close the popup (parent clears its `detailGroup`).
    let onDone: () -> Void

    private enum Phase: Equatable { case idle, sending, sent(Int) }
    @State private var phase: Phase = .idle

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    roster
                    Spacer(minLength: 8)
                    primaryButton
                    removeButton
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SAVED CREW")
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .tracking(2.4)
                .foregroundStyle(Color.bronze)
            Text("Get the crew back together")
                .font(.system(size: 24, weight: .black, design: .rounded))
                .foregroundStyle(Color.cream)
                .lineLimit(2)
            Text("Start a fresh sesh and invite everyone with one tap — they'll get a notification.")
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.6))
                .lineSpacing(2)
                .padding(.top, 2)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var roster: some View {
        if entry.savedMembers.isEmpty {
            Text("This crew was saved before we started capturing names. Start the sesh and share the code instead.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.55))
        } else {
            VStack(spacing: 8) {
                ForEach(entry.savedMembers) { m in
                    HStack(spacing: 12) {
                        AvatarView(
                            urlString: m.avatarURL,
                            initial: String(m.name.prefix(1)).uppercased(),
                            size: 38
                        )
                        Text(m.name)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.cream)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.inkElev.opacity(0.6))
                    )
                }
            }
        }
    }

    private var primaryButton: some View {
        Button(action: start) {
            HStack(spacing: 8) {
                Group {
                    switch phase {
                    case .idle:
                        Image(systemName: "paperplane.fill")
                        Text("START SESH & INVITE ALL")
                    case .sending:
                        ProgressView().tint(Color.ink)
                        Text("STARTING…")
                    case .sent(let n):
                        Image(systemName: "checkmark")
                        Text(n > 0 ? "INVITED \(n) · THEY'LL GET A PING" : "ALREADY INVITED")
                    }
                }
                .font(.system(size: 12, weight: .black, design: .monospaced))
                .tracking(1.2)
            }
            .foregroundStyle(Color.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.whiskey)
            )
            .shadow(color: Color.whiskey.opacity(0.4), radius: 14, y: 6)
        }
        .buttonStyle(PressScaleStyle())
        .disabled(phase != .idle)
    }

    private var removeButton: some View {
        Button(action: onRemove) {
            Text("Remove from saved")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(red: 0.85, green: 0.40, blue: 0.34))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(PressScaleStyle())
        .disabled(phase != .idle)
    }

    private func start() {
        phase = .sending
        Task {
            await group.create()
            guard group.isActive, let session = group.session else {
                phase = .idle
                return
            }
            let n = await invites.send(
                sessionId: session.id,
                joinCode: session.joinCode,
                mode: group.scope,
                recipientIds: entry.savedMembers.map(\.id)
            )
            phase = .sent(n)
            // Let the confirmation read for a beat, then close — the
            // underlying GroupSheet has already flipped to its active
            // view because group.isActive is now true.
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            onDone()
        }
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

    @AppStorage(BACUnitSetting.key, store: BACUnitSetting.store) private var bacUnitMode = "auto"
    private var bacUnit: BACUnit { BACUnitSetting.resolved(mode: bacUnitMode) }

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
                        Text(bacUnit.formatted(bac))
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
                        Text(bacUnit.formatted(bac))
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

/// Identical drinks collapsed into one timeline row with a `– N +`
/// stepper, so re-adding (e.g. another Carlsberg, scanned or not) is one
/// tap and doesn't require re-scanning / re-picking.
fileprivate struct LiveDrinkGroup: Identifiable {
    let option: DrinkOption
    let optionName: String
    let detail: String
    let isShared: Bool
    let count: Int
    /// Most-recent time any drink in this group was logged.
    let lastAt: Date
    /// Ids of removable instances, newest-first — `–` peels the latest.
    let removableIdsNewestFirst: [UUID]
    /// Stable across re-aggregations: name + shared flag.
    var id: String { optionName + (isShared ? "|s" : "|p") }
    var canRemove: Bool { !removableIdsNewestFirst.isEmpty }
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
    /// The night's recorded bar check-ins. Owned by SessionView (same
    /// lifetime as ghosts); consumed here at END time to build the recap.
    @ObservedObject var journey: NightJourneyStore
    /// Group-shared snaps for the current live session. Owned here — the
    /// live page is its only consumer (strip + uploads).
    @StateObject private var groupSnaps = SessionSnapsService()
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
    /// Driven by the shared top bar's END button (lifted to SessionView).
    @Binding var confirmEnd: Bool
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

    /// The end-of-night story. Non-nil presents the full-screen recap;
    /// the actual sesh teardown runs from the recap's Done button so
    /// nothing is lost if the user swipes around first.
    @State private var recap: NightRecap?
    /// Saved nights on disk. The recap is written here the moment it's
    /// built (END confirm) so even a crash mid-replay keeps the night.
    @StateObject private var recapHistory = RecapHistoryStore()
    /// Saved-drinks library — scanned units the user keeps for reuse.
    @StateObject private var savedDrinks = SavedDrinksStore()

    @AppStorage(BACUnitSetting.key, store: BACUnitSetting.store) private var bacUnitMode = "auto"
    private var bacUnit: BACUnit { BACUnitSetting.resolved(mode: bacUnitMode) }

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

    /// Friends a puke break can be pinned on — group members (minus the
    /// user, who gets the "Mine" option) plus manually-added guests.
    private var pukeCandidates: [String] {
        var names: [String] = []
        if inGroup {
            for m in group.members where m.profileId != profile.id {
                if let n = group.memberProfiles[m.profileId]?.name {
                    names.append(n)
                }
            }
        }
        names += ghosts.members.map(\.name)
        return names
    }

    /// Compose the Night Recap from the journey's check-ins plus the
    /// user's own timestamped drinks (solo ledger, or in group mode the
    /// same personal + shared-share projection the live BAC uses).
    /// Nil when there's nothing worth replaying.
    private func buildNightRecap(now: Date = Date()) -> NightRecap? {
        let denom = profile.weightKg * 1000 * profile.sex.r
        guard denom > 0 else { return nil }
        let events: [RecapEvent] = inGroup
            ? group.myLiveRecapEvents(for: profile.id)
            : live.drinks.map { RecapEvent(when: $0.consumedAt, grams: $0.grams, name: $0.optionName) }
        return NightRecap.build(
            journeyStops: journey.stops,
            events: events,
            bumpPerGram: 100 / denom,
            loosePhotos: journey.loosePhotos,
            looseSpots: journey.looseSpots,
            preGameNote: journey.preGameNote,
            endedAt: now
        )
    }

    /// The real END teardown — runs either straight from the confirmation
    /// (no drinks ⇒ no recap) or from the recap's closing button. Clears
    /// the timeline, the lock-screen activity, and the night's journey,
    /// then hands control back to the parent (or dismisses the modal).
    private func finishEndSesh() {
        live.end()
        // A stale BAC reading on a locked phone is creepy — tear the
        // lock-screen card down alongside the in-app timeline.
        LiveActivityController.shared.end()
        // The night's over — leave the venue chip showing "tap to check
        // in", not last night's bar.
        venues.currentVenue = nil
        // Cleared here for the modal path; the embedded path's parent
        // closure clears it again, which is harmless.
        journey.clear()
        if let onExitLiveTimeline {
            onExitLiveTimeline()
        } else {
            dismiss()
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
                saved: savedDrinks,
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
            VenueSheet(location: location, venues: venues, group: group)
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
                saved: savedDrinks,
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
        // A centered alert (not a bottom confirmationDialog) — the END button
        // is at the top of the screen, so the confirmation should appear with
        // it rather than sliding up from the far bottom edge.
        .alert("End Live Sesh?", isPresented: $confirmEnd) {
            Button("End sesh", role: .destructive) {
                // Build the night's story BEFORE tearing anything down —
                // live.end() clears the drinks the recap is made from.
                // No drinks ⇒ nothing to recap ⇒ end immediately.
                if let built = buildNightRecap() {
                    // Photos staged during the night move into the saved
                    // recap's directory (filenames ride on the stops, so
                    // references stay valid).
                    recapHistory.adoptPhotos(from: journey.photosDirectory, for: built)
                    // Persist immediately — the night survives even if
                    // the app dies mid-replay. Photos attach to this
                    // saved copy.
                    recapHistory.save(built)
                    // Defer past the dialog's dismissal animation —
                    // presenting a cover in the same frame a dialog is
                    // tearing down gets silently dropped by SwiftUI.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        recap = built
                    }
                } else {
                    finishEndSesh()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears the timeline. Your regular session is unaffected.")
        }
        // ---- Night Recap ----
        // The animated bar-to-bar replay. Presented between the END
        // confirmation and the actual teardown; the recap's button is
        // what really ends the sesh.
        .fullScreenCover(item: $recap) { built in
            NightRecapView(recap: built, history: recapHistory) {
                recap = nil
                finishEndSesh()
            }
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
        // The lock-screen intent posts this after a quick-add. If the app
        // is alive, drain the queued group drink + refresh right away.
        .onReceive(NotificationCenter.default.publisher(for: .liveSeshLockScreenDidAddDrink)) { _ in
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
    /// Insert any drinks the lock-screen intent queued while we couldn't
    /// reach Supabase (group mode). The card already showed the optimistic
    /// bump; this makes the add real for the rest of the group + reconciles
    /// the exact BAC on the next poll.
    private func drainPendingGroupDrinks() {
        guard inGroup else { return }
        guard let data = UserDefaults.standard.data(forKey: LockScreenStorageKeys.pendingGroupDrinks)
        else { return }
        struct Pending: Codable {
            var name: String; var detail: String; var category: String
            var volumeML: Double; var abv: Double
        }
        guard let items = try? JSONDecoder().decode([Pending].self, from: data), !items.isEmpty else {
            UserDefaults.standard.removeObject(forKey: LockScreenStorageKeys.pendingGroupDrinks)
            return
        }
        // Clear up front so a re-entrant call can't double-insert.
        UserDefaults.standard.removeObject(forKey: LockScreenStorageKeys.pendingGroupDrinks)
        for item in items {
            let opt = DrinkOption(
                category: DrinkCategory(rawValue: item.category) ?? .beer,
                name: item.name,
                detail: item.detail,
                volumeML: item.volumeML,
                abv: item.abv
            )
            Task { await group.addDrink(opt, shared: false) }
        }
    }

    private func syncLockScreenActivity() {
        let now = Date()
        // Tell the lock-screen App Intent which mode it's adding into, and
        // drain anything it queued while we were backgrounded/locked.
        UserDefaults.standard.set(inGroup, forKey: LockScreenStorageKeys.liveGroupActive)
        drainPendingGroupDrinks()
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
        // Funny one-liner about the drunkest *other* member, computed here
        // (the roast book lives in the app target, invisible to the widget
        // extension) and threaded through both the Live Activity state and
        // the widget snapshot.
        let topRoast = topRoastLine(roster: roster)

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
            topRoast: topRoast,
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
            topRoast: topRoast,
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
        topRoast: String?,
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
            roster: widgetRoster,
            topRoast: topRoast
        )
        WidgetSharedStore.write(snap)
    }

    /// Up to three of the user's most-recent drinks (incl. scanned/custom),
    /// projected into the wire format the activity carries. Shown in BOTH
    /// solo and group — in group the App Intent queues the add and the app
    /// syncs it to the session. Empty for a brand-new account; the widget
    /// hides the row when this is empty so it doesn't render as dead space.
    private var lockScreenQuickDrinks: [SeshActivityAttributes.QuickDrink] {
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
        var scored: [(SeshActivityAttributes.RosterMember, Double)] = group.members.map { m in
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
        // Manually-added guests are part of the group too — surface them in
        // the lock-screen / Dynamic Island roster with their shared-round
        // share included (group.liveBAC(forGhost:)). Never "me".
        for ghost in ghosts.members {
            let bac = group.liveBAC(forGhost: ghost, now: now)
            let status = statusFor(bac: bac)
            scored.append((
                SeshActivityAttributes.RosterMember(
                    profileId: ghost.id,
                    name: ghost.name,
                    bac: bac,
                    statusRaw: status.rawValue,
                    drinkCount: ghost.drinks.count,
                    initials: initialsFor(name: ghost.name),
                    isMe: false
                ),
                bac
            ))
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

    /// A short, funny one-liner about the drunkest *other* member in the
    /// roster — the headline the widget + Dynamic Island show beside the
    /// leader. Picks the highest-BAC non-me row (guests included, since
    /// they're in the roster), then pulls a line from the same roast book
    /// the in-app leaderboard uses, keyed by that person's BAC tier and
    /// rotated by their drink count so it changes as the night goes on.
    /// Returns nil when solo, no other members yet, or nobody has really
    /// started — the widget then just shows the BAC without a quip.
    private func topRoastLine(roster: [SeshActivityAttributes.RosterMember]) -> String? {
        guard inGroup else { return nil }
        guard let top = roster
            .filter({ !$0.isMe })
            .max(by: { $0.bac < $1.bac })
        else { return nil }
        // Rotate within the tier by how many drinks they've had, so the
        // same person doesn't get the identical line all night.
        let seed = top.drinkCount
        // Below the buzzed threshold there's nothing to roast — use the
        // group "warmup" tone instead of punching down at a sober person.
        if top.bac < 0.02 {
            return LiveRoastBook.warmup(seed: seed).headline
        }
        let firstName = top.name
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init) ?? top.name
        return LiveRoastBook
            .roast(subject: .name(firstName), bac: top.bac, seed: seed)
            .headline
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
        VStack(alignment: .leading, spacing: 16) {
            // When embedded (the LIVE tab), the live status + END live in the
            // shared top bar, so the in-page header is suppressed and the
            // readout leads. The modal path still shows its own header.
            if !embedded {
                header(bac: bac, status: status, now: now)
            }
            // Readout leads — same two cards as PLAN.
            BACNowCard(bac: bac, status: status)
            SoberByCard(
                bac: bac,
                status: status,
                hoursSober: hoursUntil(threshold: 0.0, now: now),
                hoursEU: hoursUntil(threshold: 0.02, now: now),
                hoursUS: hoursUntil(threshold: 0.08, now: now)
            )
            // Group + check-in side by side beneath the readout — still one
            // glance away at half the vertical footprint.
            HStack(spacing: 10) {
                if embedded, let onOpenGroupSheet {
                    GroupBar(
                        scope: .live,
                        session: group.session,
                        memberCount: group.members.count,
                        compact: true,
                        onTap: onOpenGroupSheet
                    )
                }
                VenueChip(
                    location: location,
                    venues: venues,
                    compact: true,
                    nameShownElsewhere: true,
                    onTap: { venueOpen = true }
                )
            }
            // Night snaps — every stop so far with its photos (plus the
            // "between bars" page when not checked in anywhere). Camera or
            // library, attach to any stop of the night; everything rides
            // straight into the end-of-night recap.
            LiveJourneyPhotosSection(
                journey: journey,
                pukeCandidates: pukeCandidates,
                onRemoveStop: { stop in
                    // Removing the bar you're currently at also checks you
                    // out, so the chip + roster stop showing it.
                    if stop.kind == .bar, venues.currentVenue?.id == stop.venueId {
                        venues.currentVenue = nil
                    }
                    journey.removeStop(stop.id)
                },
                userCoordinate: location.location?.coordinate,
                inFollowingGroup: inGroup && group.followingGroupVenue,
                inGroup: inGroup,
                onLooseSpotChanged: { spot in
                    // Share the pre-game / between location with the group
                    // when you're following it; otherwise it stays local.
                    if inGroup, group.followingGroupVenue {
                        Task { await group.setGroupLooseSpot(spot) }
                    }
                }
            )
            if inGroup, let sid = group.session?.id {
                // Squad schnaps are taken IN this card, separately from the
                // personal Night Schnaps above — group photos never enter
                // the journey, so they stay out of recaps/Nightline posts.
                GroupSnapsStrip(
                    snaps: groupSnaps,
                    sessionId: sid,
                    stopName: { venues.currentVenue?.name },
                    nameFor: { pid in group.memberProfiles[pid]?.name ?? "?" },
                    avatarFor: { pid in group.memberProfiles[pid]?.avatarURL },
                    saveToJourney: { data, date in
                        // Saved squad schnaps become loose journey photos at
                        // their original time — the recap files them onto the
                        // right leg of the night automatically.
                        journey.addLoosePhoto(data, at: date)
                    }
                )
            }
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
                bacFor: { ghost in
                    // In a group, route through SessionService so the
                    // guest gets their share of shared rounds; solo uses
                    // the guest's own drinks only.
                    inGroup
                        ? group.liveBAC(forGhost: ghost, now: now)
                        : ghosts.bac(for: ghost, now: now)
                },
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
                Text(bacUnit.formatted(bac))
                    .font(.system(size: 54, weight: .black, design: .rounded))
                    .tracking(-1.8)
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
                Text(bacUnit.caption)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(Color.bronze)
                    .padding(.bottom, 12)
            }
            BACScale(bac: bac, status: status)
        }
        .padding(16)
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
                    .font(.system(size: 28, weight: .black, design: .rounded))
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
                    Text("to \(bacUnit.formatted(0))")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(Color.bronze)
                }
            }
            if hoursEU > 0 || hoursUS > 0 {
                VStack(spacing: 4) {
                    if hoursEU > 0 {
                        limitRow(label: "EU LIMIT (\(bacUnit.formattedLimit(0.02))\(bacUnit.symbol))", hours: hoursEU, tint: status.color.opacity(0.95))
                    }
                    if hoursUS > 0 {
                        limitRow(label: "US LIMIT (\(bacUnit.formattedLimit(0.08))\(bacUnit.symbol))", hours: hoursUS, tint: status.color.opacity(0.7))
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
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

    /// Collapse the timeline into one entry per (drink, shared-flag),
    /// newest group first, so each distinct drink gets a `– N +` stepper.
    private func timelineGroups() -> [LiveDrinkGroup] {
        let entries = timelineEntries()
        var order: [String] = []
        var byKey: [String: [TimelineEntry]] = [:]
        for e in entries {
            let key = e.optionName + (e.isShared ? "|s" : "|p")
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(e)
        }
        let groups: [LiveDrinkGroup] = order.compactMap { key in
            guard let es = byKey[key], let first = es.first else { return nil }
            let removable = es
                .filter { $0.removable }
                .sorted { $0.consumedAt > $1.consumedAt }
                .map { $0.id }
            let last = es.map { $0.consumedAt }.max() ?? first.consumedAt
            return LiveDrinkGroup(
                option: first.option,
                optionName: first.optionName,
                detail: first.detail,
                isShared: first.isShared,
                count: es.count,
                lastAt: last,
                removableIdsNewestFirst: removable
            )
        }
        return groups.sorted { $0.lastAt > $1.lastAt }
    }

    /// Add one more of this exact drink (preserving its shared/personal
    /// status). One tap re-adds a Carlsberg — scanned or standard —
    /// without re-scanning or opening the picker.
    private func addAnother(_ g: LiveDrinkGroup) {
        recents.record(g.option)
        if inGroup {
            let isShared = g.isShared
            let t: Task<Void, Never> = Task { await group.addDrink(g.option, shared: isShared) }
            _ = t
        } else {
            live.add(g.option)
        }
    }

    /// Peel the most recent instance of this drink off the timeline.
    private func removeOne(_ g: LiveDrinkGroup) {
        guard let id = g.removableIdsNewestFirst.first else { return }
        removeDrink(id: id)
    }

    private func timelineSection(now: Date) -> some View {
        let groups = timelineGroups()
        let total = groups.reduce(0) { $0 + $1.count }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("YOUR TIMELINE")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(Color.bronze)
                Spacer()
                Text("\(total) \(total == 1 ? "drink" : "drinks")")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(Color.cream.opacity(0.55))
            }

            if groups.isEmpty {
                emptyTimeline
            } else {
                VStack(spacing: 8) {
                    ForEach(groups) { g in
                        DrinkTimelineRow(
                            group: g,
                            now: now,
                            isSaved: savedDrinks.isSaved(g.option),
                            onToggleSave: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                    savedDrinks.toggle(g.option)
                                }
                            },
                            onAdd: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                                    addAnother(g)
                                }
                            },
                            onRemove: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                                    removeOne(g)
                                }
                            }
                        )
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

    @AppStorage(BACUnitSetting.key, store: BACUnitSetting.store) private var bacUnitMode = "auto"
    private var bacUnit: BACUnit { BACUnitSetting.resolved(mode: bacUnitMode) }

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
                Text(bacUnit.formatted(row.bac))
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
    /// Computes a guest's BAC. In a group this routes through
    /// SessionService so the guest gets their share of shared rounds; in
    /// solo it's the guest's own drinks. Injected so the section doesn't
    /// need to know which mode it's in.
    var bacFor: (GhostMember) -> Double
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
                            bac: bacFor(ghost),
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

    @AppStorage(BACUnitSetting.key, store: BACUnitSetting.store) private var bacUnitMode = "auto"
    private var bacUnit: BACUnit { BACUnitSetting.resolved(mode: bacUnitMode) }

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
                        Text(bacUnit.formatted(bac))
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

    @AppStorage(BACUnitSetting.key, store: BACUnitSetting.store) private var bacUnitMode = "auto"
    private var bacUnit: BACUnit { BACUnitSetting.resolved(mode: bacUnitMode) }

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
                    Text("LEADER · \(bacUnit.formatted(lead.bac))\(bacUnit.symbol)")
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
    let group: LiveDrinkGroup
    let now: Date
    /// Whether this drink is in the user's saved library, + the toggle.
    let isSaved: Bool
    let onToggleSave: () -> Void
    let onAdd: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            DrinkGlyph(option: group.option, size: 22)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.smoke))
                .overlay(Circle().strokeBorder(Color.whiskey.opacity(0.25), lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(group.optionName)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.cream)
                        .lineLimit(1)
                    if group.isShared {
                        sharedPill
                    }
                }
                Text(group.detail)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .tracking(0.4)
                    .foregroundStyle(Color.cream.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            bookmarkButton
            stepper
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
                    group.isShared ? Color.whiskey.opacity(0.28) : Color.cream.opacity(0.07),
                    lineWidth: 1
                )
        )
    }

    /// Save this drink to "My Drinks" straight from the timeline — handy
    /// for a manually-picked or scanned drink you decide to keep after
    /// logging it. Filled = saved (tap to remove).
    private var bookmarkButton: some View {
        Button(action: onToggleSave) {
            Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(isSaved ? Color.whiskey : Color.cream.opacity(0.4))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(isSaved ? "Remove from my drinks" : "Save to my drinks")
    }

    /// `–  N  +` quantity control. Minus disabled when there's nothing of
    /// this drink left that the user is allowed to remove.
    private var stepper: some View {
        HStack(spacing: 0) {
            Button(action: onRemove) {
                Image(systemName: "minus")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(group.canRemove ? Color.cream.opacity(0.8) : Color.cream.opacity(0.25))
                    .frame(width: 34, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleStyle())
            .disabled(!group.canRemove)

            Text("\(group.count)")
                .font(.system(size: 15, weight: .black, design: .rounded))
                .foregroundStyle(Color.cream)
                .monospacedDigit()
                .frame(minWidth: 22)
                .contentTransition(.numericText(value: Double(group.count)))

            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Color.ink)
                    .frame(width: 34, height: 32)
                    .background(Color.whiskey)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleStyle())
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.cream.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.cream.opacity(0.1), lineWidth: 1)
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

    /// Time of the most recent one of these — "HH:MM" today, or relative
    /// if it was a while ago.
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
    /// The user's saved-drinks library. Scanned units auto-save here; the
    /// "My drinks" section lets them be re-logged without re-scanning.
    @ObservedObject var saved: SavedDrinksStore
    let onPick: (DrinkOption) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedCategory: DrinkCategory = .beer
    /// Drives the full-screen barcode scan flow.
    @State private var scanning = false

    private var specialsHeader: String {
        if let n = venueName, !n.isEmpty { return "Specials at \(n)" }
        return "Specials"
    }

    /// One row in a category list. `isSaved` rows are the user's own
    /// scanned / manually-entered drinks — they carry a filled bookmark
    /// that un-saves them. Built-in catalog rows have no bookmark.
    private func catalogRow(_ option: DrinkOption, isSaved: Bool) -> some View {
        HStack(spacing: 10) {
            Button {
                onPick(option)
            } label: {
                HStack(spacing: 12) {
                    DrinkGlyph(option: option, size: 24)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color.smoke))
                        .overlay(Circle().strokeBorder(
                            (isSaved ? Color.whiskey.opacity(0.4) : Color.whiskey.opacity(0.25)),
                            lineWidth: 1
                        ))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.name)
                            .font(.system(size: 15, weight: isSaved ? .heavy : .semibold, design: .rounded))
                            .foregroundStyle(Color.cream)
                            .lineLimit(1)
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
            }
            .buttonStyle(PressScaleStyle())

            if isSaved {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        saved.remove(option)
                    }
                } label: {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.whiskey)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.cream.opacity(0.05)))
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("Remove from my drinks")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.cream.opacity(isSaved ? 0.05 : 0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    (isSaved ? Color.whiskey.opacity(0.25) : Color.cream.opacity(0.07)),
                    lineWidth: 1
                )
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Pick a drink")
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .padding(.top, 14)

                // Scan a can/bottle barcode → resolve specs → confirm →
                // log. Fastest path for exactly what you're drinking at
                // home, and more accurate for BAC than a catalog average.
                Button {
                    scanning = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "barcode.viewfinder")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Color.ink)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.whiskey))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Scan a barcode")
                                .font(.system(size: 15, weight: .heavy, design: .rounded))
                                .foregroundStyle(Color.cream)
                            Text("Can or bottle — we'll grab the specs")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.cream.opacity(0.55))
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.bronze)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.whiskey.opacity(0.10))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.whiskey.opacity(0.4), lineWidth: 1)
                    )
                }
                .buttonStyle(PressScaleStyle())

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
                    // Built-in catalog drinks first…
                    ForEach(DrinkCatalog.options(for: selectedCategory), id: \.name) { option in
                        catalogRow(option, isSaved: false)
                    }
                    // …then the user's own saved scanned / manual drinks for
                    // this category, under a clear header. Filled bookmark
                    // un-saves them.
                    let savedHere = saved.drinks.filter { $0.category == selectedCategory }
                    if !savedHere.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "bookmark.fill")
                                .font(.system(size: 9, weight: .black))
                                .foregroundStyle(Color.whiskey)
                            Text("SAVED DRINKS")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .tracking(2.4)
                                .foregroundStyle(Color.whiskey)
                            Rectangle()
                                .fill(Color.whiskey.opacity(0.25))
                                .frame(height: 1)
                        }
                        .padding(.top, 10)
                        ForEach(savedHere, id: \.name) { option in
                            catalogRow(option, isSaved: true)
                        }
                    }
                }

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 28)
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $scanning) {
            BarcodeScanFlow(
                onComplete: { option, save in
                    scanning = false
                    // The confirm sheet's "ADD & SAVE" path sets save —
                    // keep it in My Drinks so the can never needs
                    // re-scanning. "JUST ADD" logs it once and forgets.
                    if save { saved.save(option) }
                    onPick(option)
                },
                onCancel: { scanning = false }
            )
        }
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

