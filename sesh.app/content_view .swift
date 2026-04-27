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
    var active: Bool
    enum CodingKeys: String, CodingKey {
        case id
        case hostId = "host_id"
        case joinCode = "join_code"
        case createdAt = "created_at"
        case active
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
    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case profileId = "profile_id"
        case joinedAt = "joined_at"
        case durationHours = "duration_hours"
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

struct Venue: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let name: String
    let address: String?
    let city: String?
    let lat: Double
    let lon: Double
    var isFeatured: Bool = false
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, address, city, lat, lon
        case isFeatured = "is_featured"
        case createdAt  = "created_at"
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

/// Hardcoded fallback so the UI works in the simulator before/without the
/// Supabase migration, or when the network is unavailable. Production
/// reads from the DB; these values are only surfaced when that fetch
/// fails or returns empty. Stable UUIDs prevent dupes when the real row
/// later shows up — the DB id wins as soon as `refresh()` succeeds.
enum HardcodedVenues {
    static let handelspuben = Venue(
        id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
        name: "Handelspuben",
        address: "Vasagatan 1",
        city: "Göteborg",
        lat: 57.6991,
        lon: 11.9712,
        isFeatured: true,
        createdAt: Date(timeIntervalSince1970: 0)
    )

    static let handelsSpecials: [VenueSpecial] = [
        VenueSpecial(
            id: UUID(uuidString: "22222222-2222-4222-8222-222222222221")!,
            venueId: handelspuben.id,
            name: "Fittkittlaren",
            detail: "50 cl jug · 18 cl @ 40%",
            volumeMl: 500,
            abv: 0.144,
            category: "cocktail",
            emoji: "🍹",
            createdAt: Date(timeIntervalSince1970: 0)
        ),
        VenueSpecial(
            id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            venueId: handelspuben.id,
            name: "Döda mig",
            detail: "50 cl jug · 18 cl @ 40%",
            volumeMl: 500,
            abv: 0.144,
            category: "cocktail",
            emoji: "☠️",
            createdAt: Date(timeIntervalSince1970: 0)
        )
    ]

    static let all: [Venue] = [handelspuben]

    static func specials(for venueId: UUID) -> [VenueSpecial] {
        handelsSpecials.filter { $0.venueId == venueId }
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

    @Published var state: State = .loading

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

    /// Per-drink Widmark for live group mode: every drink metabolises from
    /// its own timestamp, no slider needed. More accurate than the
    /// slider-based formula and produces the SAME number on every phone
    /// (no sync drift, since `created_at` is server-stamped).
    func liveBAC(for profileId: UUID, now: Date = Date()) -> Double {
        guard let profile = memberProfiles[profileId] else { return 0 }
        let bodyGrams = profile.weightKg * 1000
        let denom = bodyGrams * profile.sex.r
        guard denom > 0 else { return 0 }
        let n = max(members.count, 1)
        return liveDrinks.reduce(0.0) { acc, d in
            let isMine = d.profileId == profileId && !d.shared
            let isShared = d.shared
            guard isMine || isShared else { return acc }
            let grams = isShared ? d.grams / Double(n) : d.grams
            let hoursSince = max(0, now.timeIntervalSince(d.createdAt) / 3600)
            let contribution = (grams / denom) * 100 - 0.015 * hoursSince
            return acc + max(0, contribution)
        }
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

    func resumeIfAny() async {
        guard let uid = myId else { return }
        do {
            let myMemberships: [SessionMember] = try await supabase
                .from("session_members")
                .select()
                .eq("profile_id", value: uid.uuidString.lowercased())
                .execute()
                .value
            for m in myMemberships {
                if let row: SeshSession = try? await supabase
                    .from("sessions")
                    .select()
                    .eq("id", value: m.sessionId.uuidString.lowercased())
                    .eq("active", value: true)
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
            struct M: Encodable { let session_id: String; let profile_id: String }
            _ = try await supabase.from("session_members")
                .insert(M(session_id: row.id.uuidString.lowercased(),
                          profile_id: uid.uuidString.lowercased()))
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
            struct P: Encodable { let code: String }
            let sid: UUID = try await supabase
                .rpc("join_session_by_code", params: P(code: code.uppercased()))
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

    func leave() async {
        guard let sid = session?.id, let uid = myId else { clearLocal(); return }
        _ = try? await supabase.from("session_members").delete()
            .eq("session_id", value: sid.uuidString.lowercased())
            .eq("profile_id", value: uid.uuidString.lowercased())
            .execute()
        clearLocal()
    }

    func end() async {
        guard let sid = session?.id else { clearLocal(); return }
        _ = try? await supabase.from("sessions")
            .update(["active": false])
            .eq("id", value: sid.uuidString.lowercased())
            .execute()
        clearLocal()
    }

    /// Adds a drink to the session. The `live` flag decides which ledger
    /// it lands in (live timeline vs. regular order card). The two are
    /// mutually exclusive — a drink belongs to exactly one mode for life.
    func addDrink(_ option: DrinkOption, shared: Bool = false, live: Bool = false) async {
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
            live: live
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

    /// Removes this user's most recently added drink of the given option,
    /// scoped to the requested ledger. `live` must match the ledger the
    /// drink was added to — otherwise the regular and live undo buttons
    /// would interfere with each other.
    func removeMyLast(of option: DrinkOption, shared: Bool = false, live: Bool = false) async {
        guard let uid = myId else { return }
        let candidate: SessionDrink?
        if shared {
            candidate = drinks
                .filter { $0.drinkName == option.name && $0.shared && $0.live == live }
                .sorted { $0.createdAt > $1.createdAt }
                .first
        } else {
            candidate = drinks
                .filter { $0.profileId == uid && $0.drinkName == option.name && !$0.shared && $0.live == live }
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
        await refresh()
        startPolling()
    }

    private func clearLocal() {
        stopPolling()
        session = nil; members = []; memberProfiles = [:]; drinks = []
    }

    private func refresh() async {
        guard let sid = session?.id else { return }
        do {
            let ms: [SessionMember] = try await supabase
                .from("session_members")
                .select()
                .eq("session_id", value: sid.uuidString.lowercased())
                .execute()
                .value
            let ds: [SessionDrink] = try await supabase
                .from("session_drinks")
                .select()
                .eq("session_id", value: sid.uuidString.lowercased())
                .order("created_at", ascending: true)
                .execute()
                .value

            let neededIds = Set(ms.map(\.profileId)).subtracting(memberProfiles.keys)
            if !neededIds.isEmpty {
                let ids = neededIds.map { $0.uuidString.lowercased() }
                let ps: [Profile] = try await supabase
                    .from("profiles")
                    .select()
                    .in("id", values: ids)
                    .execute()
                    .value
                for p in ps { memberProfiles[p.id] = p }
            }

            // if host ended session, clean up
            if let row: SeshSession = try? await supabase
                .from("sessions")
                .select()
                .eq("id", value: sid.uuidString.lowercased())
                .single()
                .execute()
                .value, row.active == false {
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
//     with a hardcoded fallback (Handelspuben) so the simulator works
//     before the migration is applied. Tracks the user's chosen venue
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
        didSet { persistCurrent() }
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

    /// Loads every venue + special from Supabase. On any failure (or empty
    /// result) we apply a hardcoded fallback so the user can still try out
    /// check-in + specials before the migration has been run.
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
            if vs.isEmpty {
                applyFallback()
            } else {
                venues = vs
                var grouped: [UUID: [VenueSpecial]] = [:]
                for s in ss {
                    grouped[s.venueId, default: []].append(s)
                }
                specialsByVenue = grouped
                reconcileCurrent()
            }
        } catch {
            // Either the migration hasn't been run yet or there's no
            // network. Surface the hardcoded data so check-in still works.
            applyFallback()
        }
    }

    private func applyFallback() {
        venues = HardcodedVenues.all
        var grouped: [UUID: [VenueSpecial]] = [:]
        for v in HardcodedVenues.all {
            grouped[v.id] = HardcodedVenues.specials(for: v.id)
        }
        specialsByVenue = grouped
        reconcileCurrent()
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

enum LiveRoastBook {
    /// Picks a roast for the leader. `name` is the leader's first name
    /// (already extracted by the caller) so the lines can refer to them
    /// by name. `bac` selects the tier; `seed` rotates within the tier.
    static func roast(name: String, bac: Double, seed: Int) -> LiveRoast {
        let bank = candidates(for: bac, name: name)
        guard !bank.isEmpty else {
            return LiveRoast(
                headline: "\(name) is in the lead.",
                advice: "Keep an eye on them. Water, food, friends."
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

    private static func candidates(for bac: Double, name: String) -> [LiveRoast] {
        switch bac {
        case ..<0.02:
            return [
                LiveRoast(headline: "\(name) is leading the pack — barely a sip in.",
                          advice: "Pace yourselves. Eat. Hydrate."),
                LiveRoast(headline: "\(name) leads. Honestly that's embarrassing for everyone.",
                          advice: "Pick up the pace, gently. Water first."),
            ]
        case 0.02..<0.05:
            return [
                LiveRoast(headline: "\(name) is the front-runner. The night has potential.",
                          advice: "Snack break. Water between rounds."),
                LiveRoast(headline: "\(name) is warming up. Texts about to get spicy.",
                          advice: "Hide their phone. Eat carbs."),
            ]
        case 0.05..<0.08:
            return [
                LiveRoast(headline: "Beware of \(name) — obnoxious mode incoming.",
                          advice: "Strap in. Hand them water."),
                LiveRoast(headline: "\(name) just hit talkative tier. Brace for life advice.",
                          advice: "Nod politely. Refill their water."),
                LiveRoast(headline: "\(name) is now the loudest in the group. Statistically.",
                          advice: "Encourage food. Start tracking shots."),
            ]
        case 0.08..<0.15:
            return [
                LiveRoast(headline: "\(name) is officially the entertainment. Document everything.",
                          advice: "Do NOT let \(name) drive. No exceptions."),
                LiveRoast(headline: "\(name) thinks they're whispering. They are not.",
                          advice: "Cab money on standby. Big water."),
                LiveRoast(headline: "\(name) just challenged the bartender to a debate. Help.",
                          advice: "Steer them toward food. Keep their phone."),
                LiveRoast(headline: "\(name) is forming opinions on geopolitics. Nobody asked.",
                          advice: "Water. Carbs. Light topics only."),
            ]
        case 0.15..<0.25:
            return [
                LiveRoast(headline: "\(name) is a problem. Hide their phone. NOW.",
                          advice: "Water, food, friend nearby. \(name) is the group's responsibility."),
                LiveRoast(headline: "\(name) just confessed something they can't take back.",
                          advice: "Stop pouring for them. Buddy them up. Cab home."),
                LiveRoast(headline: "\(name) is one drink from declaring love for a stranger.",
                          advice: "Cut them off gently. Stay close. No driving."),
            ]
        default:
            return [
                LiveRoast(headline: "Critical: \(name) needs supervision tonight.",
                          advice: "Stop pouring. Stay with them. Above 0.30 — get help."),
                LiveRoast(headline: "\(name) is in 'whose bed is this' territory.",
                          advice: "Water. Sober adult. Side-sleep when home."),
                LiveRoast(headline: "\(name) is officially a tomorrow problem.",
                          advice: "End the sesh for them. Stay close until they're safe."),
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

    init() { load() }

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

    init() { load() }

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

    /// Per-drink Widmark: each drink contributes `(grams / (mass × r)) × 100`,
    /// minus 0.015 × (hours since *that* drink). Contributions clamp at 0 so
    /// drinks that have fully metabolised drop out naturally.
    func bac(profile: Profile, now: Date = Date()) -> Double {
        let bodyGrams = profile.weightKg * 1000
        let denom = bodyGrams * profile.sex.r
        guard denom > 0 else { return 0 }
        return drinks.reduce(0.0) { acc, d in
            let hoursSince = max(0, now.timeIntervalSince(d.consumedAt) / 3600)
            let contribution = (d.grams / denom) * 100 - eliminationRate * hoursSince
            return acc + max(0, contribution)
        }
    }

    func hoursUntil(threshold: Double, profile: Profile, now: Date = Date()) -> Double {
        max(0, (bac(profile: profile, now: now) - threshold) / eliminationRate)
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

// MARK: - Root

struct RootView: View {
    @StateObject private var auth = AuthService()

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
                SessionView(profile: profile, auth: auth)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: auth.state)
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

// MARK: - Session view (the former ContentView)

private struct SessionView: View {
    let profile: Profile
    @ObservedObject var auth: AuthService
    @StateObject private var group = SessionService()
    @StateObject private var live = LiveSeshState()
    @StateObject private var recents = RecentDrinksStore()
    /// Location + venue services. Owned here (the topmost user-facing
    /// view) and passed into LiveSeshView so both modes share one source
    /// of truth for "where am I tonight?" and "what specials apply?".
    @StateObject private var location = LocationService()
    @StateObject private var venues = VenueService()

    @State private var localOrder: [OrderItem] = []
    @State private var hours: Double = 1
    @State private var menuOpen = false
    @State private var profileOpen = false
    @State private var groupOpen = false
    @State private var shareMode = false
    @State private var liveOpen = false
    @State private var venueOpen = false

    private let eliminationRate = 0.015

    private var personalOrder: [OrderItem] {
        if group.isActive {
            // Resolve via VenueService so venue specials (Fittkittlaren etc.)
            // — which aren't in DrinkCatalog — still render in the order card.
            return group.myDrinks().map { d in
                OrderItem(id: d.id, option: venues.resolveOption(for: d), shared: false)
            }
        }
        return localOrder
    }

    private var sharedOrder: [OrderItem] {
        guard group.isActive else { return [] }
        return group.sharedDrinks().map { d in
            OrderItem(id: d.id, option: venues.resolveOption(for: d), shared: true)
        }
    }

    /// Combined view: your drinks + any shared rounds the group has going.
    private var combinedOrder: [OrderItem] {
        personalOrder + sharedOrder
    }

    /// The list shown in the menu sheet (what +/- operates on there). In share mode this is the shared pool.
    private var order: [OrderItem] {
        (group.isActive && shareMode) ? sharedOrder : personalOrder
    }

    private func orderBinding() -> Binding<[OrderItem]> {
        Binding(
            get: { order },
            set: { newValue in
                if !group.isActive { localOrder = newValue }
                // group changes are driven through MenuSheet callbacks
            }
        )
    }

    /// Ethanol grams attributed to me for BAC: personal + even share of the group's shared pool.
    private var totalAlcoholGrams: Double {
        if group.isActive {
            return group.effectiveGrams(for: profile.id)
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
        if group.isActive {
            let shared = shareMode
            // Regular (non-live) ledger: live=false so this drink shows
            // up only in the order card and feeds the duration-slider BAC.
            let t: Task<Void, Never> = Task { await group.addDrink(option, shared: shared, live: false) }
            _ = t
        } else {
            localOrder.append(OrderItem(option: option))
        }
    }

    private func removeOneLocal(_ option: DrinkOption) {
        if group.isActive {
            let shared = shareMode
            let t: Task<Void, Never> = Task { await group.removeMyLast(of: option, shared: shared, live: false) }
            _ = t
        } else if let idx = localOrder.lastIndex(where: { $0.option == option }) {
            localOrder.remove(at: idx)
        }
    }

    var body: some View {
        ZStack {
            AtmosphereBackground(accent: status.color)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    Masthead(profile: profile) { profileOpen = true }

                    GroupBar(
                        session: group.session,
                        memberCount: group.members.count,
                        onTap: { groupOpen = true }
                    )

                    VenueChip(
                        location: location,
                        venues: venues,
                        onTap: { venueOpen = true }
                    )

                    LiveSeshBar(
                        live: live,
                        group: group,
                        profile: profile,
                        onTap: {
                            // In a group session, the group itself is the
                            // live backing — no need to start the solo
                            // LiveSeshState. Otherwise auto-start solo so
                            // the user doesn't have to "start" then "add".
                            if !group.isActive, !live.isActive { live.start() }
                            liveOpen = true
                        }
                    )

                    BACReadout(
                        bac: bac,
                        status: status,
                        hoursUntilSober: hoursUntil(bacThreshold: 0.0),
                        hoursUntilEULimit: hoursUntil(bacThreshold: 0.02),
                        hoursUntilUSLimit: hoursUntil(bacThreshold: 0.08)
                    )

                    if group.isActive {
                        GroupRoster(group: group, selfId: profile.id, hours: hours)
                    }

                    VibeCard(status: status, message: vibe)

                    VStack(spacing: 12) {
                        OrderCard(
                            order: combinedOrder,
                            memberCount: max(group.members.count, 1),
                            groupActive: group.isActive,
                            onOpen: {
                                shareMode = false
                                menuOpen = true
                            },
                            onOpenShared: group.isActive ? {
                                shareMode = true
                                menuOpen = true
                            } : nil,
                            onRemoveOne: { option, shared in
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                                    if group.isActive {
                                        let t: Task<Void, Never> = Task { await group.removeMyLast(of: option, shared: shared, live: false) }
                                        _ = t
                                    } else if let idx = localOrder.lastIndex(where: { $0.option == option }) {
                                        localOrder.remove(at: idx)
                                    }
                                }
                            },
                            onAddOne: { option, shared in
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                                    recents.record(option)
                                    if group.isActive {
                                        let t: Task<Void, Never> = Task { await group.addDrink(option, shared: shared, live: false) }
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
                                    guard group.isActive else { return }
                                    let t: Task<Void, Never> = Task {
                                        await group.updateMyDuration(newValue)
                                    }
                                    _ = t
                                }
                        }

                        YouRow(profile: profile) { profileOpen = true }
                    }

                    Disclaimer()
                        .padding(.top, 4)
                }
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 72)
            }
        }
        .preferredColorScheme(.dark)
        .animation(.spring(response: 0.55, dampingFraction: 0.82), value: status)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: group.isActive)
        .task { await group.resumeIfAny() }
        // Pull venue + specials catalog on first launch so the chip /
        // picker have something to render. Falls back to hardcoded
        // Handelspuben if the migration hasn't been applied yet.
        .task { await venues.refresh() }
        // When the members list refreshes (entry or 3s poll), pull my synced
        // duration from the DB into the local slider so the slider position
        // matches what other phones see. Without this the slider could
        // drift between devices.
        .onChange(of: group.members) { _, _ in
            guard group.isActive, let synced = group.myDuration() else { return }
            // Avoid jitter when the local value already matches.
            if abs(synced - hours) > 0.01 {
                hours = synced
            }
        }
        .sheet(isPresented: $menuOpen) {
            MenuSheet(
                order: orderBinding(),
                shareMode: $shareMode,
                showShareToggle: group.isActive,
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
        .sheet(isPresented: $groupOpen) {
            GroupSheet(group: group)
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
        .fullScreenCover(isPresented: $liveOpen) {
            LiveSeshView(
                live: live,
                group: group,
                recents: recents,
                location: location,
                venues: venues,
                profile: profile
            )
        }
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
                        Text("GROUP SESH")
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
                        Text("DRINK TOGETHER")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(2.2)
                            .foregroundStyle(Color.bronze)
                        Text("Start a group sesh")
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
// The chip is the user's persistent "Tonight at: Handelspuben" marker —
// shown in the home view header. Tap → VenueSheet → pick a featured bar
// (sorted by distance) or check out. When a venue is selected the chip
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
    @Environment(\.dismiss) private var dismiss

    private var sortedVenues: [Venue] {
        venues.sortedByDistance(from: location.location)
    }

    private func distanceLabel(for venue: Venue) -> String? {
        guard let m = venues.distance(from: location.location, to: venue) else { return nil }
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

                    VStack(spacing: 10) {
                        ForEach(sortedVenues) { venue in
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

                    if sortedVenues.isEmpty {
                        emptyState
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
            Image(systemName: "mappin.slash")
                .font(.system(size: 28))
                .foregroundStyle(Color.bronze)
            Text("No featured bars yet")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(Color.cream)
            Text("Featured bars will appear here as Sesh adds them.")
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
            }

            Spacer(minLength: 8)

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

// MARK: - Group Sheet

private struct GroupSheet: View {
    @ObservedObject var group: SessionService
    @Environment(\.dismiss) private var dismiss

    @State private var joinCode: String = ""
    @State private var showCopied = false
    @State private var confirmLeave = false
    @State private var confirmEnd = false

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
    }

    private var header: some View {
        HStack {
            Text(group.isActive ? "YOUR GROUP" : "GROUP SESH")
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
            Text("Start a sesh, share the code, and see everyone's BAC in real time. Each person's BAC uses their own weight and profile.")
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.7))
                .lineSpacing(3)
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

    @ViewBuilder
    private var activeView: some View {
        if let session = group.session {
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
                .confirmationDialog("End this sesh for everyone?", isPresented: $confirmEnd, titleVisibility: .visible) {
                    Button("End for everyone", role: .destructive) {
                        Task {
                            await group.end()
                            dismiss()
                        }
                    }
                    Button("Cancel", role: .cancel) {}
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
                .confirmationDialog("Leave this sesh?", isPresented: $confirmLeave, titleVisibility: .visible) {
                    Button("Leave", role: .destructive) {
                        Task {
                            await group.leave()
                            dismiss()
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                }
            }
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
    let profile: Profile
    @Environment(\.dismiss) private var dismiss

    @State private var menuOpen = false
    @State private var confirmEnd = false
    @State private var venueOpen = false
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
            let t: Task<Void, Never> = Task { await group.addDrink(option, shared: isShared, live: true) }
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
                    await group.removeMyLast(of: opt, shared: drink.shared, live: drink.live)
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
        .confirmationDialog(
            "End Live Sesh?",
            isPresented: $confirmEnd,
            titleVisibility: .visible
        ) {
            Button("End sesh", role: .destructive) {
                live.end()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears the timeline. Your regular session is unaffected.")
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let bac = currentBAC(now: now)
        let status = statusFor(bac: bac)
        VStack(alignment: .leading, spacing: 22) {
            header(bac: bac, status: status, now: now)
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
            Button {
                // In a group, "END" closes the live view but doesn't kill
                // the underlying group — that's managed via GroupSheet.
                // Solo: confirm before clearing the local timeline.
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
        let nameForLine = lead.isSelf ? "You" : lead.name
        return LiveRoastBook.roast(name: nameForLine, bac: lead.bac, seed: seed)
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

