// Core value models — Sex, Profile, Status tiers, the drinks catalog, and
// the group/invite/venue value types. Extracted from content_view.swift;
// pure relocation.

import SwiftUI
import Foundation
import CoreLocation

// MARK: - Deals campaign artwork

/// Fixed aspect ratios so a campaign's image looks identical on the map pin
/// and in its expanded card. Poster and billboard differ on purpose.
enum CampaignArt {
    static let posterRatio: CGFloat = 4.0 / 3.0   // poster: pin + card
    static let billboardRatio: CGFloat = 3.0 / 1.0 // billboard: wide banner
}

// MARK: - Settings keys

/// Whether to share my live check-in location with friends (friends map).
/// On by default; users can switch it off in the profile sheet.
enum ShareLocationSetting {
    static let key = "sesh.shareLocation.v1"
}

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

    /// ISO date "yyyy-MM-dd". Nil until the user sets it (migration 069);
    /// when present, `age` is derived from it rather than edited directly.
    var birthdate: String?

    enum CodingKeys: String, CodingKey {
        case id, name, age, sex, username, birthdate
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
        birthdate = try c.decodeIfPresent(String.self, forKey: .birthdate)
    }

    /// Explicit memberwise init (the custom decoder init suppresses the
    /// synthesized one). username defaults to nil for existing call sites.
    init(id: UUID, name: String, age: Int, sex: Sex, weightKg: Double,
         avatarURL: String? = nil, username: String? = nil, birthdate: String? = nil) {
        self.id = id
        self.name = name
        self.age = age
        self.sex = sex
        self.weightKg = weightKg
        self.avatarURL = avatarURL
        self.username = username
        self.birthdate = birthdate
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
                .init(category: .beer, name: "Small beer",  detail: "33 cl · 5%",  volumeML: 330, abv: 0.05),
                .init(category: .beer, name: "Medium beer", detail: "40 cl · 5%",  volumeML: 400, abv: 0.05),
                .init(category: .beer, name: "Large beer",  detail: "50 cl · 5%",  volumeML: 500, abv: 0.05),
                .init(category: .beer, name: "Pint",        detail: "57 cl · 5%",  volumeML: 568, abv: 0.05),
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
    /// Mutable for one reason: the pace prompt re-stamps a burst of
    /// back-to-back logs to when they were actually drunk (097).
    var createdAt: Date
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
    /// Bulk-imported from OpenStreetMap (migration 075).
    case osm
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
    /// Apple Maps place id, same identifier space as MKMapItem.identifier.
    /// Separate from externalId because imported rows keep 'osm:node/123'
    /// there — the OSM importer dedupes on it.
    var mapkitId: String? = nil
    /// Paid Deals placement — 'none' | 'pin' | 'poster' | 'billboard'
    /// (migration 053). 'none' venues never appear on Deals surfaces.
    var tier: String = "none"
    /// Printable check-in code (migration 070). Nil until an admin mints one.
    var qrToken: String? = nil
    let createdAt: Date
    /// Server-side change stamp (migration 088). The catalog sync uses the
    /// highest value it has seen as its cursor, so a refresh normally returns
    /// zero rows instead of re-sending 2150 venues.
    var updatedAt: Date? = nil
    /// Tri-state on purpose: true shows the "outdoor seating" note, false AND
    /// nil both show nothing — an absent note must never read as "no terrace".
    var outdoorSeating: Bool? = nil
    /// ISO-3166 alpha-2 home of the bar (migration 101). The catalog loads
    /// one country at a time, keyed on this.
    var country: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, address, city, lat, lon
        case isFeatured = "is_featured"
        case source
        case externalId = "external_id"
        case mapkitId   = "mapkit_id"
        case tier
        case qrToken    = "qr_token"
        case createdAt  = "created_at"
        case updatedAt  = "updated_at"
        case outdoorSeating = "outdoor_seating"
        case country
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
        mapkitId: String? = nil,
        tier: String = "none",
        qrToken: String? = nil,
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
        self.mapkitId = mapkitId
        self.tier = tier
        self.qrToken = qrToken
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
        // Decode through the RAW STRING, not the enum. decodeIfPresent only
        // returns nil for an absent/null key — a PRESENT but unknown value
        // THROWS, which escapes init(from:) and fails the whole [Venue] array.
        // That is exactly what happened when 1002 rows arrived with
        // source='osm' before this enum knew the case: every venue-driven
        // screen went blank, silently, because the fetch's catch swallowed it.
        // An unrecognised source must degrade to a default, never blank the app.
        source     = VenueSource(
            rawValue: (try? c.decodeIfPresent(String.self, forKey: .source)) as? String ?? ""
        ) ?? .curated
        externalId = try c.decodeIfPresent(String.self, forKey: .externalId)
        mapkitId   = try c.decodeIfPresent(String.self, forKey: .mapkitId)
        tier       = (try c.decodeIfPresent(String.self, forKey: .tier)) ?? "none"
        qrToken    = try c.decodeIfPresent(String.self, forKey: .qrToken)
        createdAt  = try c.decode(Date.self,   forKey: .createdAt)
        // Absent on rows that came from an older cache file; the sync treats a
        // nil cursor as "do a full pull", which is the safe direction.
        updatedAt  = try? c.decodeIfPresent(Date.self, forKey: .updatedAt)
        outdoorSeating = try? c.decodeIfPresent(Bool.self, forKey: .outdoorSeating)
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
    /// Days the deal is actually VALID (0=Sun..6=Sat); nil = every day. The
    /// campaign still markets the whole starts_at..ends_at window regardless.
    var activeDays: [Int]? = nil
    /// Paid placement level — pin | poster | billboard (migration 054).
    var placement: String = "pin"
    /// Poster artwork (16:9). Also the map-pin image for poster/billboard.
    var imageUrl: String? = nil
    /// Wide billboard artwork (3:1) — billboard placement only (migration 056).
    var billboardImageUrl: String? = nil
    /// App-open full-screen promo flag (migration 057). Shown once per user.
    var interstitial: Bool = false
    /// Display schedule (migration 060). When true the card only SHOWS on its
    /// valid days + time window (a day-of reminder) instead of marketing the
    /// whole starts_at..ends_at window.
    var showOnValidOnly: Bool = false

    enum CodingKeys: String, CodingKey {
        case id
        case venueId     = "venue_id"
        case kind, title, description
        case finePrint   = "fine_print"
        case redeem, code
        case startMinute = "start_minute"
        case endMinute   = "end_minute"
        case activeDays  = "active_days"
        case placement
        case imageUrl    = "image_url"
        case billboardImageUrl = "billboard_image_url"
        case interstitial
        case showOnValidOnly = "show_on_valid_only"
    }

    /// Whether this offer should be DISPLAYED right now. Always true unless the
    /// bar chose "show on valid days only", in which case it only appears on
    /// its active weekday(s) and within its time-of-day window (viewer's local
    /// clock). Independent of redeemability — that's what activeDays labels.
    func isVisibleNow(_ now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard showOnValidOnly else { return true }
        if let days = activeDays, !days.isEmpty {
            let weekday = calendar.component(.weekday, from: now) - 1   // 0=Sun..6=Sat
            if !days.contains(weekday) { return false }
        }
        if let s = startMinute, let e = endMinute {
            let c = calendar.dateComponents([.hour, .minute], from: now)
            let mins = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            if mins < s || mins > e { return false }
        }
        return true
    }

    var imageURL: URL? { imageUrl.flatMap(URL.init(string:)) }
    var billboardImageURL: URL? { billboardImageUrl.flatMap(URL.init(string:)) }
    /// Poster/billboard campaign that carries a poster image (the map pin +
    /// poster card use this).
    var hasArtPlacement: Bool {
        (placement == "poster" || placement == "billboard") && imageURL != nil
    }
    /// The best image for a full-screen interstitial — the wide billboard art
    /// if present, else the poster image.
    var interstitialImageURL: URL? { billboardImageURL ?? imageURL }

    /// Clear validity line for the guest: "Valid Wednesdays" (single day, plural
    /// = recurring), "Valid Wed–Sat" (a run), "Valid Wed, Fri & Sat" (a list).
    /// nil when the deal is valid every day (no restriction to surface).
    var validDaysLabel: String? {
        guard let days = activeDays, !days.isEmpty, days.count < 7 else { return nil }
        let plural = ["Sundays","Mondays","Tuesdays","Wednesdays","Thursdays","Fridays","Saturdays"]
        let abbr   = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"]
        let sorted = days.filter { (0..<7).contains($0) }.sorted()
        if sorted.count == 1 { return "Valid \(plural[sorted[0]])" }
        if sorted.last! - sorted.first! == sorted.count - 1 {
            return "Valid \(abbr[sorted.first!])–\(abbr[sorted.last!])"      // contiguous run
        }
        let names = sorted.map { abbr[$0] }
        return "Valid " + names.dropLast().joined(separator: ", ") + " & " + names.last!
    }

    /// Short pill form for tight spots: "WED ONLY" / "WED–SAT" / "WED · FRI".
    var validDaysPill: String? {
        guard let days = activeDays, !days.isEmpty, days.count < 7 else { return nil }
        let abbr = ["SUN","MON","TUE","WED","THU","FRI","SAT"]
        let sorted = days.filter { (0..<7).contains($0) }.sorted()
        if sorted.count == 1 { return "\(abbr[sorted[0]]) ONLY" }
        if sorted.last! - sorted.first! == sorted.count - 1 {
            return "\(abbr[sorted.first!])–\(abbr[sorted.last!])"
        }
        return sorted.map { abbr[$0] }.joined(separator: " · ")
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

/// A standard beer serving size (migration 063). Colour anchors scale with the
/// serving so a cheap 25cl and a cheap pint both read green.
enum BeerServing: String, CaseIterable, Identifiable {
    case s25 = "25", middy = "28.5", s33 = "33", s40 = "40", schooner = "42.5",
         oz16 = "47.3", s50 = "50", pint = "pint"
    var id: String { rawValue }
    static let canonical = BeerServing.s40   // "stor stark" — the map default

    /// Chip / picker label.
    var label: String {
        switch self {
        case .s25: return "25 cl"
        case .middy: return "Middy"
        case .s33: return "33 cl"
        case .s40: return "40 cl"
        case .schooner: return "Schooner"
        case .oz16: return "16 oz"
        case .s50: return "50 cl"
        case .pint: return "Pint"
        }
    }
    /// Longer descriptor for the detail card.
    var longLabel: String {
        switch self {
        case .s40: return "40 cl · stor stark"
        case .middy: return "285 ml · middy"
        case .schooner: return "425 ml · schooner"
        case .oz16: return "16 oz · US pint"
        default: return label
        }
    }
    /// Representative centilitres — sorts sizes and scales the colour anchors.
    var cl: Double {
        switch self {
        case .s25: return 25
        case .middy: return 28.5
        case .s33: return 33
        case .s40: return 40
        case .schooner: return 42.5
        case .oz16: return 47.3
        case .s50: return 50
        case .pint: return 57
        }
    }
}

/// Local currency handling for beer prices (migration 064). A price is stored
/// and shown in the currency it was reported in — we don't convert. The colour
/// thresholds scale per-currency so a ¥600 pint and a 60 kr stor stark read the
/// same green.
enum BeerCurrency {
    /// The user's device currency, e.g. "SEK", "JPY". Falls back to SEK. Used
    /// only as a last resort — currency normally follows the bar's country.
    static var current: String { Locale.current.currency?.identifier ?? "SEK" }

    /// The currency used in a given ISO country (e.g. "US" → "USD", "SE" →
    /// "SEK"). So a bar in the States is priced in dollars even if the reporter's
    /// phone is set to Sweden.
    static func forCountry(_ iso: String) -> String {
        Locale(identifier: "en_\(iso)").currency?.identifier ?? current
    }

    static func symbol(_ code: String) -> String {
        switch code.uppercased() {
        case "SEK", "NOK", "DKK", "ISK": return "kr"
        case "EUR": return "€"
        case "GBP": return "£"
        case "USD", "AUD", "CAD", "NZD": return "$"
        case "JPY", "CNY": return "¥"
        case "PLN": return "zł"
        case "CHF": return "CHF"
        default:    return code.uppercased()
        }
    }

    /// "65 kr", "¥600", "€6" — whole units, symbol placed by convention.
    static func format(_ amount: Double, _ code: String) -> String {
        let n = Int(amount.rounded())
        let sym = symbol(code)
        switch code.uppercased() {
        case "SEK", "NOK", "DKK", "ISK", "PLN", "CHF": return "\(n) \(sym)"
        default: return "\(sym)\(n)"
        }
    }
}

/// Crowdsourced beer price for one venue + serving size (migrations 061–064):
/// the median recent price (in its own currency) plus spread and freshness.
/// Decoded from the venue_beer_prices() RPC.
struct VenueBeerPrice: Codable, Identifiable {
    let venueId: UUID
    let serving: String
    let currency: String
    let price: Double
    let reportCount: Int
    let low: Double
    let high: Double
    let lastReported: Date?

    var id: String { "\(venueId.uuidString)-\(serving)" }

    enum CodingKeys: String, CodingKey {
        case venueId     = "venue_id"
        case serving, currency
        case price
        case reportCount = "report_count"
        case low, high
        case lastReported = "last_reported"
    }

    var servingSize: BeerServing { BeerServing(rawValue: serving) ?? .s40 }
    /// Serving text that never lies: an imported price with no stated size
    /// says so instead of masquerading as 40 cl.
    var servingLabel: String {
        serving == "unknown" ? "Size not stated" : servingSize.label
    }
    /// "65 kr" / "¥600" — the map-pin label in the price's own currency.
    var priceLabel: String { BeerCurrency.format(price, currency) }
    /// "1 report" / "12 reports" trust line.
    var reportsLabel: String { reportCount == 1 ? "1 report" : "\(reportCount) reports" }
    /// True when low and high differ enough to be worth showing a range.
    var hasSpread: Bool { high - low >= 1 }
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

