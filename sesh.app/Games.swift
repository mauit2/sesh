// Games — "Game Night": drinking games opened from the controller icon in
// the top bar. Four games (Imposter, Never Have I Ever, Pandora's Box, Most
// Likely To), each with a FREE pool and a SPICY pool (After Dark
// subscription). Prompts live in GameContent.swift; a round deals 40 random
// cards from the chosen pool.
//
// Navigation is value-based: the intro screen builds an immutable config
// (CardGameConfig / ImposterConfig) and pushes it; the game view owns its
// own state from there. Nothing is shared by binding across the push.
//
// Imposter has two modes: pass-the-phone on one device, or GROUP — the host
// deals a round into `game_rounds` for the live sesh and every member reads
// their own role on their own phone through the `game_round_for_session`
// RPC (an imposter's device never receives the word before the reveal).
//
// Monetization: one auto-renewable subscription group ("After Dark") with a
// weekly and a yearly product. Ids must match App Store Connect exactly:
//   sejdel.afterdark.weekly
//   sejdel.afterdark.yearly
// Local testing: AfterDark.storekit at the repo root, selected in the
// scheme's Run options.

import SwiftUI
import StoreKit
import Combine
import Supabase

// MARK: - After Dark subscription store

@MainActor
final class AfterDarkStore: ObservableObject {
    static let productIDs = ["sejdel.afterdark.weekly", "sejdel.afterdark.yearly"]

    @Published var products: [Product] = []
    @Published var isSubscribed = false
    @Published var purchasing = false
    @Published var loadError: String? = nil
    /// App admins (app_admins table, via AdminService) get the spicy decks
    /// without paying — set by the hub from the live admin flag.
    @Published var adminOverride = false

    /// The one gate every deck picker reads.
    var hasSpicy: Bool { isSubscribed || (adminOverride && !Self.previewMode) }

    /// DEBUG-only: launched with `-afterdark-preview`, the paywall renders
    /// the App Store Connect prices without a store and ignores the admin
    /// override — used to capture review screenshots on the simulator.
    static var previewMode: Bool {
        #if DEBUG
        return CommandLine.arguments.contains("-afterdark-preview")
        #else
        return false
        #endif
    }

    struct Offer: Identifiable {
        let id: String
        let displayPrice: String
        /// Yearly only: the price divided by 52, in the buyer's own currency.
        let weeklyEquivalent: String?
        /// Yearly only: saving versus 52 weekly payments, computed from the
        /// buyer's own storefront prices so it's true in every country.
        let savingPercent: Int?
        let product: Product?
        var isYearly: Bool { id.hasSuffix("yearly") }
    }

    private static func saving(weekly: Decimal, yearly: Decimal) -> Int? {
        let full = weekly * 52
        guard full > 0, yearly < full else { return nil }
        let pct = (1 - yearly / full) * 100
        return Int(NSDecimalNumber(decimal: pct).doubleValue.rounded())
    }

    /// What the paywall lists: live products, or the preview stand-ins.
    var offers: [Offer] {
        if !products.isEmpty {
            let weekly = products.first { !$0.id.hasSuffix("yearly") }?.price
            return products.map { p in
                let yearly = p.id.hasSuffix("yearly")
                return Offer(id: p.id, displayPrice: p.displayPrice,
                             weeklyEquivalent: yearly ? (p.price / 52).formatted(p.priceFormatStyle) : nil,
                             savingPercent: (yearly && weekly != nil) ? Self.saving(weekly: weekly!, yearly: p.price) : nil,
                             product: p)
            }
        }
        if Self.previewMode {
            return [Offer(id: "sejdel.afterdark.weekly", displayPrice: "9,00 kr", weeklyEquivalent: nil,
                          savingPercent: nil, product: nil),
                    Offer(id: "sejdel.afterdark.yearly", displayPrice: "399,00 kr", weeklyEquivalent: "7,67 kr",
                          savingPercent: Self.saving(weekly: 9, yearly: 399), product: nil)]
        }
        return []
    }

    private var updatesTask: Task<Void, Never>? = nil

    init() {
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let txn) = update { await txn.finish() }
                await self?.refreshEntitlement()
            }
        }
        Task {
            await refreshEntitlement()
            await load()
        }
    }

    deinit { updatesTask?.cancel() }

    func load() async {
        do {
            let loaded = try await Product.products(for: Self.productIDs)
            products = loaded.sorted { $0.price < $1.price }
            loadError = loaded.isEmpty
                ? "Subscriptions aren't available right now — try again in a bit."
                : nil
        } catch {
            loadError = "Couldn't reach the App Store. Check your connection and try again."
        }
    }

    func refreshEntitlement() async {
        var active = false
        for await entitlement in Transaction.currentEntitlements {
            if case .verified(let txn) = entitlement,
               Self.productIDs.contains(txn.productID),
               txn.revocationDate == nil {
                active = true
            }
        }
        isSubscribed = active
    }

    func purchase(_ product: Product) async {
        purchasing = true
        defer { purchasing = false }
        do {
            let result = try await product.purchase()
            if case .success(let verification) = result,
               case .verified(let txn) = verification {
                await txn.finish()
            }
            await refreshEntitlement()
        } catch {
            // Cancelled or store hiccup — the paywall simply stays.
        }
    }

    func restore() async {
        purchasing = true
        defer { purchasing = false }
        try? await AppStore.sync()
        await refreshEntitlement()
    }
}

// MARK: - Game kinds + configs

enum GameKind: String, CaseIterable, Identifiable, Hashable {
    case imposter, never, pandora, mostLikely
    var id: String { rawValue }

    var title: String {
        switch self {
        case .imposter:   return "IMPOSTER"
        case .never:      return "NEVER HAVE I EVER"
        case .pandora:    return "PANDORA'S BOX"
        case .mostLikely: return "MOST LIKELY TO"
        }
    }
    var icon: String {
        switch self {
        case .imposter:   return "theatermasks.fill"
        case .never:      return "hand.raised.fill"
        case .pandora:    return "shippingbox.fill"
        case .mostLikely: return "person.2.wave.2.fill"
        }
    }
    var accent: Color {
        switch self {
        case .imposter:   return Color(red: 0.93, green: 0.36, blue: 0.30)
        case .never:      return Color.whiskey
        case .pandora:    return Color(red: 0.62, green: 0.42, blue: 0.95)
        case .mostLikely: return Color(red: 0.24, green: 0.76, blue: 0.62)
        }
    }
    var accentDeep: Color {
        switch self {
        case .imposter:   return Color(red: 0.55, green: 0.12, blue: 0.22)
        case .never:      return Color(red: 0.62, green: 0.32, blue: 0.06)
        case .pandora:    return Color(red: 0.28, green: 0.14, blue: 0.62)
        case .mostLikely: return Color(red: 0.06, green: 0.38, blue: 0.36)
        }
    }
    var gradient: LinearGradient {
        LinearGradient(colors: [accent, accentDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    var rules: [String] {
        switch self {
        case .imposter:   return ["Everyone gets the word — except the imposters.",
                                  "Describe it without saying it.",
                                  "Vote. Caught imposter drinks 3. Wrong? The rest drink 2."]
        case .never:      return ["Read the card out loud.",
                                  "Done it? Drink.",
                                  "Haven't? Stay dry and judge."]
        case .pandora:    return ["Draw a card. Do what it says.",
                                  "Rules stick until your next turn.",
                                  "Refuse a card? Drink 3."]
        case .mostLikely: return ["Read the card. Count to three.",
                                  "Everyone points at someone.",
                                  "Most fingers drinks."]
        }
    }
    var startLabel: String { self == .imposter ? "DEAL THE WORDS" : "START" }
}

struct CardGameConfig: Hashable {
    let kind: GameKind
    let spicy: Bool
}

struct ImposterConfig: Hashable {
    let groupMode: Bool
    let playerCount: Int
    let imposterCount: Int
    let spicy: Bool

    /// Sensible ceiling: never half the table or more.
    static func maxImposters(for players: Int) -> Int { max(1, (players - 1) / 2) }
}

// MARK: - Free-play limit (card games only)

/// Without After Dark, each card game allows one 20-card round per 24 h.
/// The clock starts when the round is dealt. Imposter is never limited.
@MainActor
final class FreePlayLimiter: ObservableObject {
    static let shared = FreePlayLimiter()
    static let cooldown: TimeInterval = 24 * 60 * 60
    private static let storeKey = "games.lastFreeRound"

    /// Observable so the intro underneath a pushed game re-renders the
    /// moment a round is dealt — a view below the stack top never gets
    /// `onAppear` again on pop.
    @Published private(set) var lastPlayed: [String: TimeInterval]

    private init() {
        lastPlayed = UserDefaults.standard.dictionary(forKey: Self.storeKey) as? [String: TimeInterval] ?? [:]
    }

    func markPlayed(_ kind: GameKind) {
        lastPlayed[kind.rawValue] = Date().timeIntervalSince1970
        UserDefaults.standard.set(lastPlayed, forKey: Self.storeKey)
    }

    /// When the next free round unlocks, or nil if one is available now.
    func nextAllowed(_ kind: GameKind) -> Date? {
        guard let t = lastPlayed[kind.rawValue] else { return nil }
        let next = Date(timeIntervalSince1970: t).addingTimeInterval(Self.cooldown)
        return next > Date() ? next : nil
    }

    static func format(_ seconds: TimeInterval) -> String {
        let i = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", i / 3600, (i % 3600) / 60, i % 60)
    }
}

/// Live countdown to the next free round.
private struct CooldownPill: View {
    let until: Date
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(spacing: 6) {
                Text("NEXT FREE ROUND IN")
                    .font(.system(size: 11, weight: .black, design: .monospaced)).tracking(2.2)
                    .foregroundStyle(Color.bronze)
                Text(FreePlayLimiter.format(until.timeIntervalSince(ctx.date)))
                    .font(.system(size: 30, weight: .black, design: .monospaced))
                    .foregroundStyle(Color.cream)
            }
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.cream.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.cream.opacity(0.14), lineWidth: 1))
        }
    }
}

// MARK: - Group Imposter round (Supabase)

struct GameRoundState: Decodable {
    let id: UUID
    let hostId: UUID
    let spicy: Bool
    let revealed: Bool
    let playerCount: Int
    let imposterCount: Int
    let isPlayer: Bool
    let isImposter: Bool
    let starterId: UUID
    let word: String?
    let imposterIds: [UUID]?

    enum CodingKeys: String, CodingKey {
        case id, spicy, revealed, word
        case hostId = "host_id"
        case playerCount = "player_count"
        case imposterCount = "imposter_count"
        case isPlayer = "is_player"
        case isImposter = "is_imposter"
        case starterId = "starter_id"
        case imposterIds = "imposter_ids"
    }
}

private struct GameRoundInsert: Encodable {
    let session_id: UUID
    let host_id: UUID
    let kind: String
    let word: String
    let imposter_id: UUID
    let imposter_ids: [UUID]
    let starter_id: UUID
    let player_ids: [UUID]
    let spicy: Bool
}

private struct RevealPatch: Encodable { let revealed: Bool }

// MARK: - Shared bits

private struct PrimaryLabel: View {
    let title: String
    var icon: String = "arrow.right"
    let colors: [Color]
    var enabled: Bool = true

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 14, weight: .black, design: .monospaced)).tracking(2.6)
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold, design: .rounded))
        }
        .foregroundStyle(enabled ? Color.ink : Color.cream.opacity(0.4))
        .padding(.vertical, 18).padding(.horizontal, 22)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(enabled
                      ? AnyShapeStyle(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                      : AnyShapeStyle(Color.cream.opacity(0.08)))
        )
        .shadow(color: (colors.first ?? .clear).opacity(enabled ? 0.45 : 0), radius: 20, y: 10)
    }
}

private struct PrimaryButton: View {
    let title: String
    var icon: String = "arrow.right"
    let colors: [Color]
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PrimaryLabel(title: title, icon: icon, colors: colors, enabled: enabled)
        }
        .disabled(!enabled)
        .buttonStyle(PressScaleStyle())
    }
}

private struct GhostButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .black, design: .monospaced)).tracking(2.2)
                .foregroundStyle(Color.cream.opacity(0.75))
                .padding(.vertical, 15)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.cream.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.cream.opacity(0.14), lineWidth: 1))
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// FREE / SPICY toggle. Picking SPICY without the subscription opens the
/// paywall instead of switching.
private struct DeckPicker: View {
    @Binding var spicy: Bool
    let accent: Color
    let subscribed: Bool
    let openPaywall: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            segment("FREE", icon: nil, active: !spicy) { spicy = false }
            segment("SPICY", icon: subscribed ? "flame.fill" : "lock.fill", active: spicy) {
                if subscribed { spicy = true } else { openPaywall() }
            }
        }
    }

    private func segment(_ label: String, icon: String?, active: Bool, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .bold)) }
                Text(label).font(.system(size: 12, weight: .black, design: .monospaced)).tracking(2)
            }
            .foregroundStyle(active ? Color.ink : Color.cream.opacity(0.75))
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(active ? accent : Color.cream.opacity(0.07)))
            .overlay(Capsule().strokeBorder(Color.cream.opacity(active ? 0 : 0.14), lineWidth: 1))
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// Label + −/+ stepper row, used for players and imposters.
private struct CountRow: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .black, design: .monospaced)).tracking(2)
                .foregroundStyle(Color.bronze)
            Spacer()
            bubble("minus") { if value > range.lowerBound { value -= 1 } }
            Text("\(value)")
                .font(.system(size: 28, weight: .black, design: .rounded))
                .foregroundStyle(Color.cream)
                .frame(minWidth: 48)
            bubble("plus") { if value < range.upperBound { value += 1 } }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.cream.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(Color.cream.opacity(0.12), lineWidth: 1))
    }

    private func bubble(_ icon: String, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.cream)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.cream.opacity(0.09)))
                .overlay(Circle().strokeBorder(Color.cream.opacity(0.16), lineWidth: 1))
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// Three fanned cards in the game's colours — the visual on every intro.
private struct CardFan: View {
    let kind: GameKind
    var body: some View {
        ZStack {
            ForEach([-1, 1, 0], id: \.self) { i in
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(kind.gradient)
                    .frame(width: 118, height: 160)
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.cream.opacity(0.35), lineWidth: 1))
                    .overlay(Image(systemName: kind.icon)
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(Color.cream.opacity(i == 0 ? 0.95 : 0.35)))
                    .rotationEffect(.degrees(Double(i) * 14))
                    .offset(x: CGFloat(i) * 46, y: i == 0 ? -6 : 10)
                    .opacity(i == 0 ? 1 : 0.85)
                    .shadow(color: kind.accent.opacity(0.35), radius: 18, y: 10)
            }
        }
        .frame(height: 190)
    }
}

private func bigHeader(_ eyebrow: String, _ title: String) -> some View {
    VStack(spacing: 8) {
        Text(eyebrow)
            .font(.system(size: 12, weight: .black, design: .monospaced)).tracking(2.4)
            .foregroundStyle(Color.bronze)
        Text(title)
            .font(.system(size: 30, weight: .black, design: .rounded))
            .italic().tracking(-1)
            .foregroundStyle(Color.cream)
            .multilineTextAlignment(.center)
    }
    .padding(.top, 10)
}

private let ember = Color(red: 0.86, green: 0.28, blue: 0.24)

// MARK: - Hub

struct GamesHubView: View {
    @ObservedObject var group: SessionService
    /// Live flag from AdminService — admins play spicy decks for free.
    let isAdmin: Bool
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = AfterDarkStore()
    @State private var paywallOpen = false

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ZStack {
                AtmosphereBackground(accent: .whiskey)
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        HStack {
                            Text("Game Night")
                                .font(.system(size: 23, weight: .heavy, design: .rounded))
                                .italic()
                                .tracking(-0.6)
                                .foregroundStyle(Color.cream)
                            Spacer()
                            Button { dismiss() } label: {
                                ZStack {
                                    Circle().fill(Color.cream.opacity(0.05)).frame(width: 32, height: 32)
                                    Image(systemName: "xmark")
                                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                                        .foregroundStyle(Color.cream.opacity(0.8))
                                }
                                .overlay(Circle().strokeBorder(Color.cream.opacity(0.12), lineWidth: 1))
                            }
                            .buttonStyle(PressScaleStyle())
                        }
                        .padding(.top, 4)

                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(GameKind.allCases) { kind in
                                NavigationLink(value: kind) { tile(kind) }
                                    .buttonStyle(PressScaleStyle())
                            }
                        }

                        spicyBanner
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
                }
            }
            .navigationDestination(for: GameKind.self) { kind in
                GameIntroView(kind: kind, group: group, paywallOpen: $paywallOpen)
            }
            .navigationDestination(for: CardGameConfig.self) { config in
                PromptGameView(config: config, paywallOpen: $paywallOpen)
            }
            .navigationDestination(for: ImposterConfig.self) { config in
                ImposterGameView(config: config, group: group, paywallOpen: $paywallOpen)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .environmentObject(store)
        .onAppear { store.adminOverride = isAdmin }
        .onChange(of: isAdmin) { _, v in store.adminOverride = v }
        .sheet(isPresented: $paywallOpen) {
            AfterDarkPaywall()
                .environmentObject(store)
                .presentationBackground(Color.ink)
        }
    }

    private func tile(_ kind: GameKind) -> some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 24, style: .continuous).fill(kind.gradient)
            RadialGradient(colors: [Color.cream.opacity(0.28), .clear],
                           center: .init(x: 0.85, y: 0.1), startRadius: 4, endRadius: 150)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            Image(systemName: kind.icon)
                .font(.system(size: 78, weight: .bold))
                .foregroundStyle(Color.cream.opacity(0.92))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(y: -14)
            Text(kind.title)
                .font(.system(size: 14, weight: .black, design: .monospaced))
                .tracking(1.6)
                .foregroundStyle(Color.cream)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
        }
        .frame(height: 196)
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(Color.cream.opacity(0.18), lineWidth: 1))
        .shadow(color: kind.accent.opacity(0.35), radius: 22, y: 12)
    }

    private var spicyBanner: some View {
        Button { if !store.hasSpicy { paywallOpen = true } } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Color.ink.opacity(0.35)).frame(width: 48, height: 48)
                    Image(systemName: store.hasSpicy ? "checkmark" : "flame.fill")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(Color.cream)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.hasSpicy ? "SPICY ROUNDS UNLOCKED" : "UNLOCK SPICIER ROUNDS")
                        .font(.system(size: 15, weight: .black, design: .monospaced))
                        .tracking(1.8)
                        .foregroundStyle(Color.cream)
                    Text("Bolder cards in every game.")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.85))
                }
                Spacer()
                if !store.hasSpicy {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(Color.cream)
                }
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(colors: [Color.whiskey, ember], startPoint: .leading, endPoint: .trailing)))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.cream.opacity(0.22), lineWidth: 1))
            .shadow(color: Color.whiskey.opacity(0.45), radius: 24, y: 12)
        }
        .buttonStyle(PressScaleStyle())
        .disabled(store.hasSpicy)
    }
}

// MARK: - Intro (rules + deck + start)

struct GameIntroView: View {
    let kind: GameKind
    @ObservedObject var group: SessionService
    @Binding var paywallOpen: Bool
    @EnvironmentObject private var store: AfterDarkStore

    @State private var spicy = false
    @State private var groupMode = false
    @State private var playerCount = 4
    @State private var imposterCount = 1
    @ObservedObject private var limiter = FreePlayLimiter.shared

    private var groupPlayers: [UUID] {
        var ids = group.members.filter(\.inLive).map(\.profileId)
        if let me = group.myId, !ids.contains(me) { ids.append(me) }
        return ids
    }
    private var groupAvailable: Bool { group.isActive && groupPlayers.count >= 3 }
    private var useGroup: Bool { groupMode && groupAvailable }
    private var effectivePlayers: Int { useGroup ? groupPlayers.count : playerCount }
    private var maxImposters: Int { ImposterConfig.maxImposters(for: effectivePlayers) }

    var body: some View {
        ZStack {
            AtmosphereBackground(accent: .whiskey)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    CardFan(kind: kind).padding(.top, 8)

                    Text(kind.title)
                        .font(.system(size: 30, weight: .black, design: .rounded))
                        .italic().tracking(-1)
                        .foregroundStyle(Color.cream)
                        .multilineTextAlignment(.center)

                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(kind.rules.enumerated()), id: \.offset) { i, rule in
                            HStack(alignment: .top, spacing: 14) {
                                Text("\(i + 1)")
                                    .font(.system(size: 13, weight: .black, design: .monospaced))
                                    .foregroundStyle(Color.ink)
                                    .frame(width: 28, height: 28)
                                    .background(Circle().fill(kind.accent))
                                Text(rule)
                                    .font(.system(size: 18, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.cream)
                                    .lineSpacing(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.ink.opacity(0.6)))
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(kind.accent.opacity(0.35), lineWidth: 1))

                    DeckPicker(spicy: $spicy, accent: kind.accent,
                               subscribed: store.hasSpicy) { paywallOpen = true }

                    if kind == .imposter { imposterOptions }

                    startLink.padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .onChange(of: maxImposters) { _, m in imposterCount = min(imposterCount, m) }
    }

    @ViewBuilder
    private var startLink: some View {
        let colors = [kind.accent, kind.accentDeep]
        let unlocked = spicy && store.hasSpicy
        if kind == .imposter {
            NavigationLink(value: ImposterConfig(groupMode: useGroup,
                                                 playerCount: effectivePlayers,
                                                 imposterCount: min(imposterCount, maxImposters),
                                                 spicy: unlocked)) {
                PrimaryLabel(title: kind.startLabel, colors: colors)
            }
            .buttonStyle(PressScaleStyle())
        } else if !store.hasSpicy, let until = limiter.nextAllowed(kind) {
            // Free round already used today — show the clock and the way out.
            VStack(spacing: 12) {
                CooldownPill(until: until)
                PrimaryButton(title: "UNLOCK MORE ROUNDS", icon: "flame.fill", colors: [Color.whiskey, ember]) {
                    paywallOpen = true
                }
            }
        } else {
            NavigationLink(value: CardGameConfig(kind: kind, spicy: unlocked)) {
                PrimaryLabel(title: kind.startLabel, colors: colors)
            }
            .buttonStyle(PressScaleStyle())
        }
    }

    private var imposterOptions: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                modeSegment("THIS PHONE", icon: "iphone", active: !groupMode) { groupMode = false }
                modeSegment("GROUP", icon: "person.3.fill", active: groupMode, enabled: groupAvailable) {
                    groupMode = true
                }
            }
            if useGroup {
                Text(group.isHost
                     ? "You deal — all \(groupPlayers.count) phones in your sesh get a card."
                     : "Your host deals. Your card lands on this phone.")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.7))
                    .multilineTextAlignment(.center)
            } else if !groupAvailable {
                Text("Live group sesh with 3+ friends unlocks everyone-on-their-own-phone.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.45))
                    .multilineTextAlignment(.center)
            }
            if !useGroup {
                CountRow(label: "PLAYERS", value: $playerCount, range: 3...16)
            }
            if !useGroup || group.isHost {
                CountRow(label: "IMPOSTERS", value: $imposterCount, range: 1...maxImposters)
            }
        }
    }

    private func modeSegment(_ label: String, icon: String, active: Bool, enabled: Bool = true,
                             tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold))
                Text(label).font(.system(size: 12, weight: .black, design: .monospaced)).tracking(2)
            }
            .foregroundStyle(active ? Color.ink : Color.cream.opacity(enabled ? 0.75 : 0.3))
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(active ? Color.cream : Color.cream.opacity(0.07)))
            .overlay(Capsule().strokeBorder(Color.cream.opacity(active ? 0 : 0.14), lineWidth: 1))
        }
        .disabled(!enabled)
        .buttonStyle(PressScaleStyle())
    }
}

// MARK: - Prompt card games

struct PromptGameView: View {
    let config: CardGameConfig
    @Binding var paywallOpen: Bool
    @EnvironmentObject private var store: AfterDarkStore

    @Environment(\.dismiss) private var dismiss
    @State private var spicy: Bool
    @State private var cards: [String] = []
    @State private var index = 0
    @State private var dragX: CGFloat = 0
    /// Set when a free round is dealt — drives the end-of-round cooldown.
    @State private var lockedUntil: Date? = nil

    init(config: CardGameConfig, paywallOpen: Binding<Bool>) {
        self.config = config
        self._paywallOpen = paywallOpen
        self._spicy = State(initialValue: config.spicy)
    }

    private var kind: GameKind { config.kind }
    private var done: Bool { index >= cards.count }

    var body: some View {
        ZStack {
            AtmosphereBackground(accent: .whiskey)
            VStack(spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text(kind.title)
                        .font(.system(size: 23, weight: .heavy, design: .rounded))
                        .italic().tracking(-0.6)
                        .foregroundStyle(Color.cream)
                    Spacer()
                    if spicy {
                        HStack(spacing: 4) {
                            Image(systemName: "flame.fill").font(.system(size: 10, weight: .bold))
                            Text("SPICY").font(.system(size: 10, weight: .black, design: .monospaced)).tracking(1.8)
                        }
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(Color.whiskey))
                    }
                }

                if !done {
                    progress
                    Spacer(minLength: 0)
                    card
                        .offset(x: dragX)
                        .rotationEffect(.degrees(Double(dragX / 30)))
                        .gesture(
                            DragGesture(minimumDistance: 20)
                                .onChanged { dragX = $0.translation.width }
                                .onEnded { v in
                                    if v.translation.width < -70 { next() }
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { dragX = 0 }
                                }
                        )
                        .onTapGesture { next() }
                        .id(index)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)))
                    Spacer(minLength: 0)
                    PrimaryButton(title: "NEXT CARD", colors: [kind.accent, kind.accentDeep]) { next() }
                } else {
                    roundOver
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear { if cards.isEmpty { deal() } }
        .onChange(of: spicy) { _, _ in deal() }
    }

    private var progress: some View {
        HStack(spacing: 12) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.cream.opacity(0.1))
                    Capsule().fill(kind.accent)
                        .frame(width: geo.size.width * CGFloat(index + 1) / CGFloat(max(cards.count, 1)))
                }
            }
            .frame(height: 6)
            Text("\(index + 1)/\(cards.count)")
                .font(.system(size: 12, weight: .black, design: .monospaced)).tracking(1)
                .foregroundStyle(Color.cream.opacity(0.55))
        }
    }

    private var card: some View {
        let (badge, body) = split(cards[index])
        return ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(LinearGradient(colors: [kind.accent.opacity(0.28), Color.ink.opacity(0.9)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack(spacing: 16) {
                Image(systemName: kind.icon)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(kind.accent)
                if let badge {
                    // Pandora's category — big and unmissable.
                    Text(badge)
                        .font(.system(size: 16, weight: .black, design: .monospaced)).tracking(3.2)
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, 20).padding(.vertical, 10)
                        .background(Capsule().fill(kind.accent))
                } else {
                    Text(kind.title)
                        .font(.system(size: 11, weight: .black, design: .monospaced)).tracking(2.2)
                        .foregroundStyle(kind.accent)
                }
                Spacer(minLength: 0)
                Text(body)
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .minimumScaleFactor(0.55)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text("TAP OR SWIPE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2)
                    .foregroundStyle(Color.cream.opacity(0.3))
            }
            .padding(26)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 400)
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous)
            .strokeBorder(kind.accent.opacity(0.5), lineWidth: 1.4))
        .shadow(color: kind.accent.opacity(0.35), radius: 30, y: 16)
    }

    /// End of the round. Free players hit the 24 h clock; After Dark gets
    /// the "step it up" moment.
    @ViewBuilder
    private var roundOver: some View {
        if !store.hasSpicy, let until = lockedUntil ?? FreePlayLimiter.shared.nextAllowed(kind) {
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "hourglass")
                    .font(.system(size: 52, weight: .bold))
                    .foregroundStyle(Color.whiskey)
                Text("Want to play more?")
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .italic().tracking(-1)
                    .foregroundStyle(Color.cream)
                CooldownPill(until: until)
                Text("Every card, 40 a round, no waiting.")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
                Spacer()
                PrimaryButton(title: "UNLOCK MORE ROUNDS", icon: "flame.fill", colors: [Color.whiskey, ember]) {
                    paywallOpen = true
                }
                GhostButton(title: "DONE FOR NOW") { dismiss() }
            }
        } else {
            premiumRoundOver
        }
    }

    private var premiumRoundOver: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: spicy ? "flame.fill" : "arrow.up.circle.fill")
                .font(.system(size: 52, weight: .bold))
                .foregroundStyle(Color.whiskey)
            Text(spicy ? "Still standing?" : "Step it up?")
                .font(.system(size: 34, weight: .black, design: .rounded))
                .italic().tracking(-1)
                .foregroundStyle(Color.cream)
            Text(spicy ? "That's the spicy deck. Run it back." : "That was the free deck. The spicy one doesn't hold back.")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)
            Spacer()
            if spicy {
                PrimaryButton(title: "PLAY AGAIN", icon: "arrow.counterclockwise",
                              colors: [Color.whiskey, ember]) { deal() }
                GhostButton(title: "BACK TO FREE DECK") { spicy = false }
            } else {
                PrimaryButton(title: "GO SPICIER", icon: "flame.fill", colors: [Color.whiskey, ember]) {
                    if store.hasSpicy { spicy = true } else { paywallOpen = true }
                }
                GhostButton(title: "PLAY AGAIN") { deal() }
            }
        }
    }

    /// "DARE — do X" → ("DARE", "do X"); plain prompts have no badge.
    private func split(_ raw: String) -> (String?, String) {
        guard let range = raw.range(of: " — ") else { return (nil, raw) }
        let badge = String(raw[..<range.lowerBound])
        if badge.count <= 10, badge == badge.uppercased() {
            return (badge, String(raw[range.upperBound...]))
        }
        return (nil, raw)
    }

    private func deal() {
        let premium = store.hasSpicy
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            cards = GameContent.deal(for: kind, spicy: spicy && premium,
                                     count: premium ? GameContent.roundSize : GameContent.freeRoundSize)
            index = 0
        }
        if !premium {
            FreePlayLimiter.shared.markPlayed(kind)
            lockedUntil = Date().addingTimeInterval(FreePlayLimiter.cooldown)
        }
    }

    private func next() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { index += 1 }
    }
}

// MARK: - Imposter

struct ImposterGameView: View {
    let config: ImposterConfig
    @ObservedObject var group: SessionService
    @Binding var paywallOpen: Bool
    @EnvironmentObject private var store: AfterDarkStore

    @State private var spicy: Bool

    // Pass-the-phone state.
    private enum Phase { case reveal, discuss, unmasked }
    @State private var phase: Phase = .reveal
    @State private var word = ""
    @State private var imposters: Set<Int> = []
    @State private var starter = 0
    @State private var currentPlayer = 0
    @State private var peeking = false
    @State private var peeked = false

    // Group state.
    @State private var round: GameRoundState? = nil
    @State private var cardShown = false
    @State private var dealing = false
    @State private var groupError: String? = nil

    init(config: ImposterConfig, group: SessionService, paywallOpen: Binding<Bool>) {
        self.config = config
        self.group = group
        self._paywallOpen = paywallOpen
        self._spicy = State(initialValue: config.spicy)
    }

    private var accent: Color { GameKind.imposter.accent }
    private var deep: Color { GameKind.imposter.accentDeep }
    private var playerCount: Int { config.playerCount }

    var body: some View {
        ZStack {
            AtmosphereBackground(accent: .whiskey)
            Group {
                if config.groupMode {
                    groupBody
                } else {
                    switch phase {
                    case .reveal:   passReveal
                    case .discuss:  discuss
                    case .unmasked: unmasked
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear { if !config.groupMode && word.isEmpty { dealLocal() } }
        .task {
            guard config.groupMode else { return }
            while !Task.isCancelled {
                await refreshRound()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    // ---- shared pieces ---------------------------------------------------

    private func roleCard(isImposter: Bool, word: String?, shown: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(LinearGradient(colors: [accent.opacity(shown ? 0.32 : 0.16), Color.ink.opacity(0.92)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            if shown {
                VStack(spacing: 14) {
                    if isImposter {
                        Image(systemName: "theatermasks.fill")
                            .font(.system(size: 46, weight: .bold))
                            .foregroundStyle(accent)
                        Text("YOU'RE AN IMPOSTER")
                            .font(.system(size: 18, weight: .black, design: .monospaced)).tracking(1.8)
                            .foregroundStyle(accent)
                            .multilineTextAlignment(.center)
                        Text("There's a secret word. You don't know it. Blend in.")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.75))
                            .multilineTextAlignment(.center)
                    } else {
                        Text("THE WORD")
                            .font(.system(size: 12, weight: .black, design: .monospaced)).tracking(2.4)
                            .foregroundStyle(Color.bronze)
                        Text(word ?? "")
                            .font(.system(size: 38, weight: .black, design: .rounded))
                            .foregroundStyle(Color.cream)
                            .multilineTextAlignment(.center)
                            .minimumScaleFactor(0.5)
                    }
                }
                .padding(28)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "hand.tap.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Color.cream.opacity(0.5))
                    Text(config.groupMode ? "TAP TO SEE YOUR CARD" : "HOLD TO PEEK")
                        .font(.system(size: 13, weight: .black, design: .monospaced)).tracking(2.2)
                        .foregroundStyle(Color.cream.opacity(0.65))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 320)
        .contentShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous)
            .strokeBorder(accent.opacity(0.5), lineWidth: 1.4))
        .shadow(color: accent.opacity(0.3), radius: 28, y: 14)
    }

    private var spicierButton: some View {
        GhostButton(title: spicy ? "PLAY AGAIN" : "GO SPICIER 🔥") {
            if spicy { return }
            if store.hasSpicy { spicy = true } else { paywallOpen = true }
        }
    }

    private func wordReveal(_ w: String) -> some View {
        VStack(spacing: 6) {
            Text("THE WORD WAS")
                .font(.system(size: 12, weight: .black, design: .monospaced)).tracking(2.4)
                .foregroundStyle(Color.bronze)
            Text(w)
                .font(.system(size: 28, weight: .black, design: .rounded))
                .foregroundStyle(Color.whiskey)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    // ---- pass-the-phone -------------------------------------------------

    private var passReveal: some View {
        VStack(spacing: 22) {
            bigHeader("PLAYER \(currentPlayer + 1) OF \(playerCount)",
                      peeked ? "Got it? Pass it on." : "Your eyes only.")
            Spacer()
            roleCard(isImposter: imposters.contains(currentPlayer), word: word, shown: peeking)
                .gesture(
                    // Touch-down shows the card, touch-up hides it — no
                    // timing thresholds, no phantom triggers.
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if !peeking { peeking = true; peeked = true }
                        }
                        .onEnded { _ in peeking = false }
                )
            Spacer()
            PrimaryButton(title: currentPlayer + 1 == playerCount ? "EVERYONE'S SEEN IT" : "PASS TO PLAYER \(currentPlayer + 2)",
                          colors: [accent, deep], enabled: peeked) { nextPlayer() }
        }
    }

    private var discuss: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(accent)
            Text("Talk it out.")
                .font(.system(size: 34, weight: .black, design: .rounded))
                .italic().tracking(-1)
                .foregroundStyle(Color.cream)
            VStack(spacing: 10) {
                Text("Player \(starter + 1) starts.")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.cream)
                Text(imposters.count > 1
                     ? "One sentence each about the word — without saying it. \(imposters.count) imposters are hiding. Then vote."
                     : "One sentence each about the word — without saying it. Then vote.")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 8)
            Spacer()
            PrimaryButton(title: imposters.count > 1 ? "REVEAL THE IMPOSTERS" : "REVEAL THE IMPOSTER",
                          icon: "eye.fill", colors: [accent, deep]) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { phase = .unmasked }
            }
        }
    }

    private var unmasked: some View {
        let names = imposters.sorted().map { "Player \($0 + 1)" }
        return VStack(spacing: 18) {
            Spacer()
            Image(systemName: "theatermasks.fill")
                .font(.system(size: 52, weight: .bold))
                .foregroundStyle(accent)
            Text(names.joined(separator: " & "))
                .font(.system(size: 34, weight: .black, design: .rounded))
                .italic().tracking(-1)
                .foregroundStyle(Color.cream)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.6)
            Text(names.count > 1 ? "were the imposters" : "was the imposter")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.7))
            wordReveal(word)
            Spacer()
            PrimaryButton(title: "NEW ROUND", icon: "arrow.counterclockwise", colors: [accent, deep]) { dealLocal() }
            spicierButton
        }
    }

    private func dealLocal() {
        let pool = GameContent.pool(for: .imposter, spicy: spicy && store.hasSpicy)
        word = pool.randomElement() ?? "Karaoke"
        let count = min(config.imposterCount, ImposterConfig.maxImposters(for: playerCount))
        imposters = Set(Array(0..<playerCount).shuffled().prefix(count))
        starter = Int.random(in: 0..<playerCount)
        currentPlayer = 0
        peeking = false
        peeked = false
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { phase = .reveal }
    }

    private func nextPlayer() {
        peeking = false
        peeked = false
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            if currentPlayer + 1 == playerCount { phase = .discuss } else { currentPlayer += 1 }
        }
    }

    // ---- group (everyone's own phone) ----------------------------------

    private func name(_ id: UUID?) -> String {
        guard let id else { return "Someone" }
        if id == group.myId { return "You" }
        return group.memberProfiles[id]?.name ?? "Someone"
    }

    private func imposterNames(_ round: GameRoundState) -> String {
        let ids = round.imposterIds ?? []
        return ids.map { name($0) }.joined(separator: " & ")
    }

    @ViewBuilder
    private var groupBody: some View {
        if let round, round.isPlayer {
            VStack(spacing: 20) {
                if round.revealed {
                    bigHeader("ROUND OVER",
                              "\(imposterNames(round)) \((round.imposterIds?.count ?? 1) > 1 || round.imposterIds?.first == group.myId ? "were" : "was") the imposter\((round.imposterIds?.count ?? 1) > 1 ? "s" : "").")
                } else {
                    bigHeader(round.imposterCount > 1
                              ? "\(round.playerCount) PHONES · \(round.imposterCount) IMPOSTERS"
                              : "\(round.playerCount) PHONES DEALT",
                              cardShown ? "\(name(round.starterId)) start\(round.starterId == group.myId ? "" : "s")." : "Your card's in.")
                }
                Spacer()
                if round.revealed {
                    Image(systemName: "theatermasks.fill")
                        .font(.system(size: 60, weight: .bold))
                        .foregroundStyle(accent)
                    wordReveal(round.word ?? "")
                } else {
                    roleCard(isImposter: round.isImposter, word: round.word, shown: cardShown)
                        .onTapGesture {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { cardShown.toggle() }
                        }
                    if cardShown {
                        Text("One sentence each about the word — without saying it. Then vote.")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.65))
                            .multilineTextAlignment(.center)
                    }
                }
                Spacer()
                if group.isHost {
                    if round.revealed {
                        PrimaryButton(title: "NEW ROUND", icon: "arrow.counterclockwise", colors: [accent, deep]) {
                            Task { await dealGroup() }
                        }
                        spicierButton
                    } else {
                        PrimaryButton(title: round.imposterCount > 1 ? "REVEAL THE IMPOSTERS" : "REVEAL THE IMPOSTER",
                                      icon: "eye.fill", colors: [accent, deep]) {
                            Task { await revealGroup(round.id) }
                        }
                    }
                } else if round.revealed {
                    Text("Waiting for \(name(round.hostId)) to deal again…")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.5))
                }
            }
        } else if group.isHost {
            VStack(spacing: 20) {
                bigHeader("GROUP ROUND", "Deal to \(groupPlayerIDs.count) phones.")
                Spacer()
                CardFan(kind: .imposter)
                Text(config.imposterCount > 1
                     ? "Everyone in your sesh gets their own card — \(config.imposterCount) of them are imposters."
                     : "Everyone in your sesh gets their own card — one of them is the imposter.")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.7))
                    .multilineTextAlignment(.center)
                if let groupError {
                    Text(groupError)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Status.drunk.color)
                        .multilineTextAlignment(.center)
                }
                Spacer()
                PrimaryButton(title: dealing ? "DEALING…" : "DEAL THE WORDS", colors: [accent, deep], enabled: !dealing) {
                    Task { await dealGroup() }
                }
            }
        } else {
            VStack(spacing: 20) {
                bigHeader("GROUP ROUND", "Waiting for the deal.")
                Spacer()
                CardFan(kind: .imposter)
                Text("\(name(group.session?.hostId)) deals. Your card lands here the moment it's out.")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.7))
                    .multilineTextAlignment(.center)
                Spacer()
            }
        }
    }

    private var groupPlayerIDs: [UUID] {
        var ids = group.members.filter(\.inLive).map(\.profileId)
        if let me = group.myId, !ids.contains(me) { ids.append(me) }
        return ids
    }

    private func refreshRound() async {
        guard let sid = group.session?.id else { return }
        do {
            let state: GameRoundState? = try await supabase
                .rpc("game_round_for_session", params: ["p_session": sid])
                .execute()
                .value
            if state?.id != round?.id { cardShown = false }
            round = state
        } catch {
            // Keep whatever we had; the next tick retries.
        }
    }

    private func dealGroup() async {
        guard let sid = group.session?.id, let me = group.myId else { return }
        let players = groupPlayerIDs
        guard players.count >= 3, let starterId = players.randomElement() else {
            groupError = "Need at least 3 people in the sesh."
            return
        }
        let count = min(config.imposterCount, ImposterConfig.maxImposters(for: players.count))
        let imps = Array(players.shuffled().prefix(count))
        guard let first = imps.first else { return }
        dealing = true
        groupError = nil
        defer { dealing = false }
        let useSpicy = spicy && store.hasSpicy
        let pool = GameContent.pool(for: .imposter, spicy: useSpicy)
        let insert = GameRoundInsert(session_id: sid, host_id: me, kind: "imposter",
                                     word: pool.randomElement() ?? "Karaoke",
                                     imposter_id: first, imposter_ids: imps,
                                     starter_id: starterId, player_ids: players, spicy: useSpicy)
        do {
            try await supabase.from("game_rounds").insert(insert).execute()
            cardShown = false
            await refreshRound()
        } catch {
            groupError = "Couldn't deal — check your connection and try again."
        }
    }

    private func revealGroup(_ id: UUID) async {
        do {
            try await supabase.from("game_rounds").update(RevealPatch(revealed: true))
                .eq("id", value: id).execute()
            await refreshRound()
        } catch {
            groupError = "Couldn't reveal — try again."
        }
    }
}

// MARK: - Paywall

struct AfterDarkPaywall: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AfterDarkStore

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            DimpleDriftBackground(strength: 0.17, speed: 7, scale: 1.2)
            RadialGradient(colors: [Color.whiskey.opacity(0.32), .clear],
                           center: .init(x: 0.8, y: 0.0), startRadius: 10, endRadius: 420)
                .ignoresSafeArea()
            RadialGradient(colors: [ember.opacity(0.22), .clear],
                           center: .init(x: 0.1, y: 0.55), startRadius: 10, endRadius: 360)
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    Capsule().fill(Color.cream.opacity(0.2)).frame(width: 36, height: 4).padding(.top, 10)

                    VStack(spacing: 10) {
                        HStack(spacing: 6) {
                            Image(systemName: "flame.fill").font(.system(size: 12, weight: .bold))
                            Text("AFTER DARK").font(.system(size: 12, weight: .black, design: .monospaced)).tracking(3)
                        }
                        .foregroundStyle(Color.whiskey)
                        Text("Go spicier.")
                            .font(.system(size: 42, weight: .black, design: .rounded))
                            .italic().tracking(-1.5)
                            .foregroundStyle(Color.cream)
                        Text("Bolder cards. Wilder rounds. Every game.")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.75))
                    }
                    .padding(.top, 6)

                    LazyVGrid(columns: columns, spacing: 10) {
                        perk(.imposter, "Words you can't say out loud.")
                        perk(.never, "The questions your friends dodge.")
                        perk(.pandora, "Dares that actually dare.")
                        perk(.mostLikely, "Point fingers. Lose friends.")
                    }

                    HStack(spacing: 8) {
                        chip("UNLIMITED ROUNDS")
                        chip("40 CARDS A ROUND")
                        chip("EVERY DECK")
                    }

                    if store.hasSpicy {
                        Text("You're in. Go play.")
                            .font(.system(size: 18, weight: .black, design: .rounded))
                            .foregroundStyle(Color.whiskey)
                            .padding(.top, 6)
                    } else if store.offers.isEmpty, let err = store.loadError {
                        Text(err)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(store.offers) { offer in priceButton(offer) }
                        }
                    }

                    Button { Task { await store.restore() } } label: {
                        Text(store.purchasing ? "Working…" : "Restore purchases")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.bronze)
                    }
                    .disabled(store.purchasing)
                    .buttonStyle(PressScaleStyle())

                    Text("Auto-renews until cancelled in Settings → Apple ID → Subscriptions. [Terms](https://sejdel.com/terms/) · [Privacy](https://sejdel.com/privacy/)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .tint(Color.bronze)
                        .foregroundStyle(Color.cream.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 24)
                }
                .padding(.horizontal, 20)
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: store.hasSpicy) { _, unlocked in
            if unlocked { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { dismiss() } }
        }
        .task { if store.products.isEmpty { await store.load() } }
    }

    private func perk(_ kind: GameKind, _ line: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: kind.icon)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Color.cream)
            Spacer(minLength: 0)
            Text(kind.title)
                .font(.system(size: 11, weight: .black, design: .monospaced)).tracking(1.4)
                .foregroundStyle(Color.cream.opacity(0.85))
            Text(line)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Color.cream)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(kind.gradient))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color.cream.opacity(0.2), lineWidth: 1))
        .shadow(color: kind.accent.opacity(0.3), radius: 18, y: 10)
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .black, design: .monospaced)).tracking(1.6)
            .foregroundStyle(Color.whiskey)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Capsule().fill(Color.whiskey.opacity(0.12)))
            .overlay(Capsule().strokeBorder(Color.whiskey.opacity(0.4), lineWidth: 1))
    }

    private func priceButton(_ offer: AfterDarkStore.Offer) -> some View {
        let yearly = offer.isYearly
        return Button {
            if let product = offer.product { Task { await store.purchase(product) } }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(yearly ? "YEARLY" : "WEEKLY")
                        .font(.system(size: 13, weight: .black, design: .monospaced)).tracking(2.2)
                    if yearly, let perWeek = offer.weeklyEquivalent {
                        Text("BEST VALUE · \(perWeek.uppercased()) PER WEEK")
                            .font(.system(size: 10, weight: .black, design: .monospaced)).tracking(1.2)
                            .opacity(0.75)
                    } else if !yearly {
                        Text("CANCEL ANYTIME")
                            .font(.system(size: 10, weight: .black, design: .monospaced)).tracking(1.2)
                            .opacity(0.75)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    if yearly, let pct = offer.savingPercent {
                        Text("SAVE \(pct)%")
                            .font(.system(size: 18, weight: .black, design: .rounded))
                            .foregroundStyle(ember)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(Capsule().fill(Color.cream))
                    }
                    Text(offer.displayPrice)
                        .font(.system(size: 20, weight: .black, design: .rounded))
                }
            }
            .foregroundStyle(Color.ink)
            .padding(.vertical, 16).padding(.horizontal, 20)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: yearly ? [Color.whiskey, ember] : [Color.cream, Color.cream.opacity(0.85)],
                                     startPoint: .leading, endPoint: .trailing)))
            .shadow(color: (yearly ? Color.whiskey : Color.cream).opacity(0.35), radius: 18, y: 10)
        }
        .buttonStyle(PressScaleStyle())
        .disabled(store.purchasing)
    }
}
