// Games — pass-the-phone drinking games, opened from the controller icon in
// the top bar. Four games ship in v1 (Imposter, Never Have I Ever, Pandora's
// Box, Most Likely To), each with a free deck and an AFTER DARK deck behind
// the subscription paywall.
//
// Everything is offline + on-device: decks are compiled in, no network, no
// state saved between rounds. The only networked piece is StoreKit.
//
// Monetization: one auto-renewable subscription group ("After Dark") with a
// monthly and a yearly product. `AfterDarkStore` owns the StoreKit 2 side —
// products, purchase, restore, and the entitlement flag the deck pickers
// read. Product ids must exist in App Store Connect with these exact ids:
//   sejdel.afterdark.monthly
//   sejdel.afterdark.yearly
// (Local testing without ASC: the AfterDark.storekit config at the repo root,
// selected in the scheme's Run options.)

import SwiftUI
import StoreKit
import Combine

// MARK: - After Dark subscription store

@MainActor
final class AfterDarkStore: ObservableObject {
    static let productIDs = ["sejdel.afterdark.monthly", "sejdel.afterdark.yearly"]

    @Published var products: [Product] = []
    @Published var isSubscribed = false
    @Published var purchasing = false
    /// Human-readable store problem ("couldn't reach the App Store"), shown
    /// on the paywall instead of dead buttons.
    @Published var loadError: String? = nil

    private var updatesTask: Task<Void, Never>? = nil

    init() {
        // Keep the entitlement live: App Store pushes renewals, refunds and
        // family-sharing changes through this stream.
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let txn) = update {
                    await txn.finish()
                }
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
            // Monthly first, then yearly — stable order for the paywall.
            products = loaded.sorted { $0.price < $1.price }
            loadError = loaded.isEmpty
                ? "Subscriptions aren't available right now — try again later."
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
            // User cancelled or the store hiccupped — the paywall just stays.
        }
    }

    func restore() async {
        purchasing = true
        defer { purchasing = false }
        try? await AppStore.sync()
        await refreshEntitlement()
    }
}

// MARK: - Games + decks

enum GameKind: String, CaseIterable, Identifiable {
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
    var tagline: String {
        switch self {
        case .imposter:   return "One of you is faking it"
        case .never:      return "Drink if you have"
        case .pandora:    return "Draw a card. Obey the card."
        case .mostLikely: return "Point on three"
        }
    }
    var icon: String {
        switch self {
        case .imposter:   return "theatermasks.fill"
        case .never:      return "hand.raised.fill"
        case .pandora:    return "shippingbox.fill"
        case .mostLikely: return "person.line.dotted.person.fill"
        }
    }
    var accent: Color {
        switch self {
        case .imposter:   return Color(red: 0.85, green: 0.35, blue: 0.32)
        case .never:      return Color.whiskey
        case .pandora:    return Color(red: 0.60, green: 0.44, blue: 0.86)
        case .mostLikely: return Color(red: 0.42, green: 0.68, blue: 0.55)
        }
    }
    /// How the drink rule reads on the card screen.
    var rule: String {
        switch self {
        case .imposter:   return "Caught imposter drinks 3 — fooled you all? Everyone else drinks 2."
        case .never:      return "Done it? Drink."
        case .pandora:    return "Refuse the card? Drink 3."
        case .mostLikely: return "Point on three — most fingers drinks."
        }
    }
}

struct GameDeck {
    let spicy: Bool
    let prompts: [String]
}

/// All compiled-in content. FREE decks keep it rowdy but harmless; AFTER
/// DARK turns the dial up.
enum GameContent {
    static func decks(for kind: GameKind) -> (free: GameDeck, afterDark: GameDeck) {
        switch kind {
        case .imposter:   return (GameDeck(spicy: false, prompts: imposterFree),
                                  GameDeck(spicy: true, prompts: imposterSpicy))
        case .never:      return (GameDeck(spicy: false, prompts: neverFree),
                                  GameDeck(spicy: true, prompts: neverSpicy))
        case .pandora:    return (GameDeck(spicy: false, prompts: pandoraFree),
                                  GameDeck(spicy: true, prompts: pandoraSpicy))
        case .mostLikely: return (GameDeck(spicy: false, prompts: mostLikelyFree),
                                  GameDeck(spicy: true, prompts: mostLikelySpicy))
        }
    }

    // ---- Imposter (secret words) ---------------------------------------

    static let imposterFree = [
        "Karaoke", "Tequila", "Afterparty", "Beer pong", "Hangover",
        "Kebab", "Dance floor", "Shots", "Pre-drink", "Bouncer",
        "Taxi", "Wingman", "Last call", "Happy hour", "Bartender",
        "Festival", "Nightclub", "Rooftop bar", "Pub crawl", "DJ",
        "Champagne", "Beach party", "House party", "Jägerbomb", "Cider",
        "Espresso martini", "Dive bar", "VIP table", "Dance battle", "Toast",
        "Ice bucket", "Cocktail", "Snapchat", "Group chat", "Selfie",
        "Vegas", "Ibiza", "Cruise", "Sauna", "Midsummer",
        "Crayfish party", "Studentflak", "Valborg", "Systembolaget", "Falukorv",
        "IKEA", "Eurovision", "ABBA",
    ]
    static let imposterSpicy = [
        "One-night stand", "Walk of shame", "Friends with benefits", "Skinny dipping",
        "Body shot", "Strip poker", "Tinder date", "Sexting", "Love bite",
        "Hot tub", "Lap dance", "First kiss", "Situationship", "Ex",
        "Booty call", "Morning after", "Hotel room", "Truth or dare",
        "Seven minutes in heaven", "Crush", "Threesome", "Roleplay",
        "Sugar daddy", "Nudes",
    ]

    // ---- Never Have I Ever ---------------------------------------------

    static let neverFree = [
        "Never have I ever thrown up from drinking.",
        "Never have I ever blacked out.",
        "Never have I ever been kicked out of a bar.",
        "Never have I ever cried at a party.",
        "Never have I ever lied about how much I've drunk.",
        "Never have I ever fallen asleep at a party.",
        "Never have I ever texted an ex while drunk.",
        "Never have I ever lost my phone on a night out.",
        "Never have I ever danced on a table.",
        "Never have I ever snuck into a club underage.",
        "Never have I ever pretended to know a song at karaoke.",
        "Never have I ever drunk-called my boss or teacher.",
        "Never have I ever eaten food off the floor.",
        "Never have I ever been in a drinking competition.",
        "Never have I ever mixed more than four kinds of alcohol in one night.",
        "Never have I ever woken up in someone else's clothes.",
        "Never have I ever forgotten where I parked or left my bike.",
        "Never have I ever been carried home.",
        "Never have I ever started a sing-along on public transport.",
        "Never have I ever lied to my parents about where I was.",
        "Never have I ever ghosted the group chat the morning after.",
        "Never have I ever ordered food for the table and eaten it all myself.",
        "Never have I ever fake-laughed at a story I've heard five times.",
        "Never have I ever been the first to leave without saying goodbye.",
        "Never have I ever taken a nap in a bar bathroom.",
        "Never have I ever borrowed money on a night out and never paid it back.",
        "Never have I ever cried over a sports result.",
        "Never have I ever been on TV or in the newspaper.",
        "Never have I ever stalked someone's profile back more than a year.",
        "Never have I ever sent a message to the wrong group chat.",
        "Never have I ever pretended my phone died to leave early.",
        "Never have I ever won a bet against everyone here.",
        "Never have I ever lost a shoe on a night out.",
        "Never have I ever hidden snacks from my friends.",
        "Never have I ever slept through an entire day after partying.",
        "Never have I ever been on a party bus.",
        "Never have I ever jumped into water with my clothes on.",
        "Never have I ever convinced a stranger we'd met before.",
        "Never have I ever been the reason the group missed the last train.",
        "Never have I ever ugly-cried to a song everyone else was dancing to.",
    ]
    static let neverSpicy = [
        "Never have I ever kissed someone in this room.",
        "Never have I ever had a one-night stand.",
        "Never have I ever done the walk of shame.",
        "Never have I ever kissed two people in the same night.",
        "Never have I ever hooked up with a friend's ex.",
        "Never have I ever sent a risky text and instantly regretted it.",
        "Never have I ever had a crush on someone in this room.",
        "Never have I ever lied about my body count.",
        "Never have I ever hooked up with someone whose name I didn't know.",
        "Never have I ever been caught kissing where I shouldn't have.",
        "Never have I ever skinny-dipped.",
        "Never have I ever had a friends-with-benefits arrangement.",
        "Never have I ever ghosted someone after a date.",
        "Never have I ever been ghosted after a date.",
        "Never have I ever matched with someone in this room on a dating app.",
        "Never have I ever kissed someone to make somebody else jealous.",
        "Never have I ever dated two people at once.",
        "Never have I ever had a summer fling I still think about.",
        "Never have I ever given a fake number.",
        "Never have I ever slid into a celebrity's DMs.",
        "Never have I ever hooked up at a festival.",
        "Never have I ever had an awkward morning-after breakfast.",
        "Never have I ever pretended to be single.",
        "Never have I ever fallen for a friend.",
        "Never have I ever left a party early to meet someone.",
        "Never have I ever been someone's rebound.",
        "Never have I ever kept a hookup secret from this group.",
        "Never have I ever regretted who I kissed at midnight on New Year's.",
    ]

    // ---- Pandora's Box (dares, rules, challenges) ----------------------

    static let pandoraFree = [
        "DARE — Swap shirts with the person on your left for the next 3 rounds.",
        "RULE — No first names until your next turn. Slip up = drink.",
        "DARE — Let the group pick your ringtone for the rest of the night.",
        "CHALLENGE — Rock-paper-scissors with the person opposite. Loser drinks 2.",
        "RULE — You can only speak in questions until your next turn.",
        "DARE — Do your best impression of someone in the group. They guess who — wrong guess, they drink.",
        "CHALLENGE — Everyone points at the best dancer on three. Winner picks who drinks 3.",
        "DARE — Post the 7th photo in your camera roll to your story. Or drink 3.",
        "RULE — Left hand only for drinks until your next turn.",
        "DARE — Speak in an accent of the group's choosing until your next turn.",
        "CHALLENGE — Hold a plank while the group counts to 20. Fail = drink 2.",
        "RULE — Anyone who says \"drink\" drinks. Until your next turn.",
        "DARE — Show the group your most recent emoji history.",
        "CHALLENGE — Name 5 cocktails in 10 seconds or drink.",
        "DARE — Let the person on your right send one (harmless) text from your phone.",
        "RULE — Everyone must toast before every sip until your next turn.",
        "DARE — Trade seats with whoever the group says has the best laugh.",
        "CHALLENGE — Staring contest with the person opposite. Loser drinks.",
        "DARE — Freestyle rap about the person on your left for 20 seconds.",
        "RULE — New nickname: the group names you now. Answer only to it tonight.",
        "CHALLENGE — Balance your phone on your head for 30 seconds. Drop = drink 2.",
        "DARE — Call the 5th contact in your phone and sing them one line of ABBA. Or drink 3.",
        "RULE — No pointing. Point = drink. Until your next turn.",
        "CHALLENGE — The group picks a word. Say it naturally in conversation within 2 minutes or drink.",
        "DARE — Do 10 pushups or drink 2.",
        "RULE — You are the waiter until your next turn. Fetch everyone's drinks.",
        "DARE — Let the group scroll your camera roll for 10 seconds (you can hover the panic finger).",
        "CHALLENGE — Whisper challenge: mouth a sentence to the person opposite. They fail to guess = you drink together.",
        "DARE — Dance with no music for 15 seconds while everyone watches silently.",
        "RULE — Compliment whoever you speak to, every time, until your next turn.",
        "CHALLENGE — Everyone votes: best story from tonight so far. Teller gives out 3 drinks.",
        "DARE — Talk in third person until your next turn.",
        "CHALLENGE — Close your eyes and name everyone's outfit colors. Each miss = 1 drink.",
        "RULE — The floor is lava on \"lava\". Last one with feet down drinks. (Group calls it once.)",
        "DARE — Recreate your most-used selfie face and hold it for 10 seconds.",
        "CHALLENGE — Thumb war tournament, you vs. your pick. Loser drinks 2.",
    ]
    static let pandoraSpicy = [
        "DARE — Give the person of your choice a 10-second shoulder massage.",
        "TRUTH — Describe your worst date in 3 sentences. Refuse = drink 3.",
        "DARE — Whisper something flirty to the person on your right. They rate it out of 10 — under 5, you drink.",
        "RULE — You and the person opposite are \"married\" until your next turn: you drink when they drink.",
        "TRUTH — Who in this group would you trust on a desert island — and who's getting voted off first?",
        "DARE — Let the group read your last DM out loud. Or drink 4.",
        "TRUTH — Show the group your dating app profile. No profile? Everyone else drinks.",
        "DARE — Serenade the person of your choice with 15 seconds of a love song.",
        "TRUTH — What's your most embarrassing hookup story? One-sentence version allowed.",
        "DARE — Do your sexiest dance move. The group rates it. Under 5 average = drink 2.",
        "RULE — Eye contact with whoever you talk to. Look away = sip. Until your next turn.",
        "TRUTH — First impression of everyone here, rapid-fire honest.",
        "DARE — Let someone in the group set your dating app bio for a week. Or drink 3.",
        "TRUTH — Have you ever had a crush on someone in this group? Yes/no is enough — no names needed.",
        "DARE — Recreate a romcom kiss scene… with your own hand. Full commitment.",
        "TRUTH — What's the boldest text you've ever sent? Paraphrase counts.",
        "DARE — Pick someone. Stare into each other's eyes for 20 seconds without laughing. Loser drinks.",
        "TRUTH — What's your green flag, and which one of your red flags do you refuse to fix?",
        "DARE — Give your best pickup line to the person opposite. If they smile, they drink; if not, you do.",
        "TRUTH — Ever pretended to like a song / hobby / food to impress someone? Story time.",
        "DARE — Text your crush \"thinking about you\" right now. Or drink 4.",
        "TRUTH — Most-swiped type: describe it. The group guesses if your ex matches.",
        "DARE — Slow dance with the person of your choice for 15 seconds. No music.",
        "TRUTH — What happened on the wildest night out of your life? Short version, no skipping the good part.",
    ]

    // ---- Most Likely To ------------------------------------------------

    static let mostLikelyFree = [
        "Most likely to become famous.",
        "Most likely to end tonight with a kebab.",
        "Most likely to cry during a Disney movie.",
        "Most likely to lose their phone tonight.",
        "Most likely to start the dance floor.",
        "Most likely to talk their way out of a fine.",
        "Most likely to befriend the bouncer.",
        "Most likely to be a millionaire by 35.",
        "Most likely to move abroad on a whim.",
        "Most likely to laugh at the wrong moment.",
        "Most likely to fall asleep first tonight.",
        "Most likely to order the most expensive thing on the menu.",
        "Most likely to survive a zombie apocalypse.",
        "Most likely to become a politician.",
        "Most likely to accidentally like a 2014 photo while stalking.",
        "Most likely to know every song lyric tonight.",
        "Most likely to start a business with no plan.",
        "Most likely to win a reality show.",
        "Most likely to get lost on the way home.",
        "Most likely to adopt five dogs.",
        "Most likely to send a voice message longer than 3 minutes.",
        "Most likely to be late to their own wedding.",
        "Most likely to eat someone else's fries without asking.",
        "Most likely to become everyone's boss one day.",
        "Most likely to book a flight during this game.",
        "Most likely to have an embarrassing search history.",
        "Most likely to fight for the aux cable.",
        "Most likely to start a podcast.",
        "Most likely to get a tattoo they regret.",
        "Most likely to charm their way backstage.",
        "Most likely to still be partying at 60.",
        "Most likely to trip while walking into the club.",
        "Most likely to text the group chat at 4 AM.",
        "Most likely to become a meme.",
        "Most likely to give a toast that goes on too long.",
        "Most likely to bring a stranger to the afterparty.",
    ]
    static let mostLikelySpicy = [
        "Most likely to kiss a stranger tonight.",
        "Most likely to have the wildest dating app stories.",
        "Most likely to date two people at once and get away with it.",
        "Most likely to fall in love on vacation.",
        "Most likely to send a risky text tonight.",
        "Most likely to have a secret admirer in this room.",
        "Most likely to leave the party with someone's number.",
        "Most likely to get back with their ex.",
        "Most likely to have a celebrity hall pass they'd actually use.",
        "Most likely to flirt with the bartender for free drinks.",
        "Most likely to have kissed someone in this group.",
        "Most likely to plan a wedding on the second date.",
        "Most likely to ghost someone by accident.",
        "Most likely to have their read receipts on, on purpose.",
        "Most likely to fake a phone call to escape a bad date.",
        "Most likely to say \"I love you\" first.",
        "Most likely to have a type everyone can describe.",
        "Most likely to marry rich.",
        "Most likely to cause the drama in a reality dating show.",
        "Most likely to slide into a DM tonight.",
        "Most likely to have the best kiss-and-tell story.",
        "Most likely to be someone's ex they still think about.",
        "Most likely to turn a one-night stand into a relationship.",
        "Most likely to know exactly what their ex is doing right now.",
    ]
}

// MARK: - Games hub

struct GamesHubView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = AfterDarkStore()
    @State private var paywallOpen = false

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ZStack {
                AtmosphereBackground(accent: .whiskey)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(GameKind.allCases) { kind in
                                NavigationLink {
                                    gamePage(kind)
                                } label: {
                                    gameCard(kind)
                                }
                                .buttonStyle(PressScaleStyle())
                            }
                        }
                        afterDarkBanner
                        Text("Drink responsibly — water counts as a drink in every game. Anyone can swap any prompt for a sip instead.")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.45))
                            .padding(.top, 2)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 40)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.75))
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Color.cream.opacity(0.07)))
                    }
                    .buttonStyle(PressScaleStyle())
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .environmentObject(store)
        .sheet(isPresented: $paywallOpen) {
            AfterDarkPaywall()
                .environmentObject(store)
                .presentationBackground(Color.ink)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GAME NIGHT")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(2.4)
                .foregroundStyle(Color.bronze)
            Text("Pick your poison.")
                .font(.system(size: 30, weight: .black, design: .rounded))
                .italic().tracking(-1)
                .foregroundStyle(Color.cream)
            Text("Pass-the-phone games for the whole table. Free decks for everyone — AFTER DARK when the table can handle it.")
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.6))
                .lineSpacing(2)
        }
    }

    @ViewBuilder
    private func gamePage(_ kind: GameKind) -> some View {
        if kind == .imposter {
            ImposterGameView(paywallOpen: $paywallOpen)
        } else {
            PromptGameView(kind: kind, paywallOpen: $paywallOpen)
        }
    }

    private func gameCard(_ kind: GameKind) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Circle()
                    .fill(kind.accent.opacity(0.16))
                    .frame(width: 44, height: 44)
                Image(systemName: kind.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(kind.accent)
            }
            Spacer(minLength: 0)
            Text(kind.title)
                .font(.system(size: 13, weight: .black, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(Color.cream)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            Text(kind.tagline)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.55))
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, minHeight: 148, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.cream.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(kind.accent.opacity(0.25), lineWidth: 1)
        )
    }

    private var afterDarkBanner: some View {
        Button {
            if !store.isSubscribed { paywallOpen = true }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: store.isSubscribed ? "flame.fill" : "lock.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.ink)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.whiskey))
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.isSubscribed ? "AFTER DARK — ACTIVE" : "UNLOCK AFTER DARK")
                        .font(.system(size: 12, weight: .black, design: .monospaced))
                        .tracking(1.6)
                        .foregroundStyle(Color.cream)
                    Text(store.isSubscribed
                         ? "Spicy decks unlocked in every game. Play nice."
                         : "Spicier decks in all four games — for tables that can handle it.")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.6))
                }
                Spacer()
                if !store.isSubscribed {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.whiskey)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.whiskey.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.whiskey.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(PressScaleStyle())
        .disabled(store.isSubscribed)
    }
}

// MARK: - Deck picker (shared)

/// FREE / AFTER DARK segmented picker. Choosing AFTER DARK without the
/// subscription bounces to the paywall instead of switching.
private struct DeckPicker: View {
    @Binding var spicy: Bool
    let accent: Color
    let subscribed: Bool
    let openPaywall: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            segment("FREE", active: !spicy) { spicy = false }
            segment(subscribed ? "AFTER DARK" : "AFTER DARK 🔒", active: spicy) {
                if subscribed { spicy = true } else { openPaywall() }
            }
        }
    }

    private func segment(_ label: String, active: Bool, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Text(label)
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(active ? Color.ink : Color.cream.opacity(0.7))
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .background(
                    Capsule().fill(active ? accent : Color.cream.opacity(0.06))
                )
                .overlay(Capsule().strokeBorder(Color.cream.opacity(active ? 0 : 0.14), lineWidth: 1))
        }
        .buttonStyle(PressScaleStyle())
    }
}

// MARK: - Prompt card games (NHIE, Pandora, Most Likely To)

/// The shared engine for the three card games: pick a deck, tap through a
/// shuffled stack of prompt cards.
struct PromptGameView: View {
    let kind: GameKind
    @Binding var paywallOpen: Bool
    @EnvironmentObject private var store: AfterDarkStore

    @State private var spicy = false
    @State private var order: [Int] = []
    @State private var index = 0
    @State private var cardFlip = false

    private var deck: GameDeck {
        let d = GameContent.decks(for: kind)
        return (spicy && store.isSubscribed) ? d.afterDark : d.free
    }

    var body: some View {
        ZStack {
            AtmosphereBackground(accent: .whiskey)
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(kind.title)
                        .font(.system(size: 22, weight: .black, design: .rounded))
                        .italic().tracking(-0.5)
                        .foregroundStyle(Color.cream)
                    Text(kind.rule)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.55))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                DeckPicker(spicy: $spicy, accent: kind.accent,
                           subscribed: store.isSubscribed) { paywallOpen = true }

                Spacer(minLength: 0)

                // The card.
                VStack(spacing: 18) {
                    Image(systemName: kind.icon)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(kind.accent)
                    Text(currentPrompt)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.cream)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .minimumScaleFactor(0.6)
                    if spicy {
                        Text("AFTER DARK")
                            .font(.system(size: 9, weight: .black, design: .monospaced))
                            .tracking(2.0)
                            .foregroundStyle(Color.whiskey)
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, minHeight: 280)
                .background(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(Color.ink.opacity(0.85))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(kind.accent.opacity(0.4), lineWidth: 1.2)
                )
                .shadow(color: kind.accent.opacity(0.25), radius: 26, y: 12)
                .rotation3DEffect(.degrees(cardFlip ? 0 : 6), axis: (x: 1, y: 0, z: 0))
                .id("\(spicy)-\(index)")
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))

                Spacer(minLength: 0)

                Text("\(min(index + 1, deck.prompts.count)) / \(deck.prompts.count)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(Color.cream.opacity(0.4))

                Button { next() } label: {
                    HStack {
                        Text("NEXT CARD")
                            .font(.system(size: 13, weight: .bold, design: .monospaced)).tracking(3)
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(Color.ink)
                    .padding(.vertical, 16).padding(.horizontal, 20)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(kind.accent))
                    .shadow(color: kind.accent.opacity(0.45), radius: 18, y: 8)
                }
                .buttonStyle(PressScaleStyle())
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear { reshuffle() }
        .onChange(of: spicy) { _, _ in reshuffle() }
    }

    private var currentPrompt: String {
        guard !order.isEmpty else { return "" }
        return deck.prompts[order[index % order.count]]
    }

    private func reshuffle() {
        order = Array(deck.prompts.indices).shuffled()
        index = 0
    }

    private func next() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            if index + 1 >= order.count {
                reshuffle()   // ran the deck dry — new shuffle, keep playing
            } else {
                index += 1
            }
        }
    }
}

// MARK: - Imposter

/// Undercover-style word game: everyone gets the secret word except one
/// imposter. Phone passes around for private reveals, then the table talks,
/// votes, and the reveal settles who drinks.
struct ImposterGameView: View {
    @Binding var paywallOpen: Bool
    @EnvironmentObject private var store: AfterDarkStore

    private enum Phase { case setup, reveal, discuss, unmasked }

    @State private var phase: Phase = .setup
    @State private var spicy = false
    @State private var playerCount = 4
    @State private var word = ""
    @State private var imposterIndex = 0
    @State private var currentPlayer = 0
    @State private var peeking = false
    @State private var peeked = false
    @State private var starter = 0

    var body: some View {
        ZStack {
            AtmosphereBackground(accent: .whiskey)
            Group {
                switch phase {
                case .setup:    setup
                case .reveal:   reveal
                case .discuss:  discuss
                case .unmasked: unmasked
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    // ---- setup ---------------------------------------------------------

    private var setup: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("IMPOSTER")
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .italic().tracking(-0.5)
                    .foregroundStyle(Color.cream)
                Text("Everyone sees the secret word — except one imposter, who has to blend in. Describe the word one by one, then vote. \(GameKind.imposter.rule)")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.55))
                    .lineSpacing(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            DeckPicker(spicy: $spicy, accent: GameKind.imposter.accent,
                       subscribed: store.isSubscribed) { paywallOpen = true }

            HStack {
                Text("PLAYERS")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(1.8)
                    .foregroundStyle(Color.bronze)
                Spacer()
                Button { if playerCount > 3 { playerCount -= 1 } } label: { stepperBubble("minus") }
                    .buttonStyle(PressScaleStyle())
                Text("\(playerCount)")
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .frame(minWidth: 44)
                Button { if playerCount < 12 { playerCount += 1 } } label: { stepperBubble("plus") }
                    .buttonStyle(PressScaleStyle())
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.cream.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.cream.opacity(0.12), lineWidth: 1))

            Spacer()

            Button { start() } label: {
                HStack {
                    Text("DEAL THE WORDS")
                        .font(.system(size: 13, weight: .bold, design: .monospaced)).tracking(3)
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                }
                .foregroundStyle(Color.ink)
                .padding(.vertical, 16).padding(.horizontal, 20)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(GameKind.imposter.accent))
                .shadow(color: GameKind.imposter.accent.opacity(0.45), radius: 18, y: 8)
            }
            .buttonStyle(PressScaleStyle())
        }
        .padding(.top, 8)
    }

    private func stepperBubble(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Color.cream)
            .frame(width: 34, height: 34)
            .background(Circle().fill(Color.cream.opacity(0.08)))
            .overlay(Circle().strokeBorder(Color.cream.opacity(0.15), lineWidth: 1))
    }

    // ---- reveal (pass the phone) ---------------------------------------

    private var reveal: some View {
        VStack(spacing: 22) {
            Text("PLAYER \(currentPlayer + 1) OF \(playerCount)")
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .tracking(2.2)
                .foregroundStyle(Color.bronze)
                .padding(.top, 10)
            Text(peeked ? "Got it? Pass the phone." : "Your eyes only.")
                .font(.system(size: 26, weight: .black, design: .rounded))
                .italic().tracking(-0.8)
                .foregroundStyle(Color.cream)

            Spacer()

            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Color.ink.opacity(0.85))
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(GameKind.imposter.accent.opacity(0.4), lineWidth: 1.2)
                if peeking {
                    VStack(spacing: 12) {
                        if currentPlayer == imposterIndex {
                            Image(systemName: "theatermasks.fill")
                                .font(.system(size: 34))
                                .foregroundStyle(GameKind.imposter.accent)
                            Text("YOU ARE THE IMPOSTER")
                                .font(.system(size: 16, weight: .black, design: .monospaced))
                                .tracking(1.6)
                                .foregroundStyle(GameKind.imposter.accent)
                            Text("There is a secret word. You don't know it. Blend in.")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.cream.opacity(0.7))
                                .multilineTextAlignment(.center)
                        } else {
                            Text("THE WORD IS")
                                .font(.system(size: 10, weight: .black, design: .monospaced))
                                .tracking(2.2)
                                .foregroundStyle(Color.bronze)
                            Text(word)
                                .font(.system(size: 30, weight: .black, design: .rounded))
                                .foregroundStyle(Color.cream)
                                .multilineTextAlignment(.center)
                                .minimumScaleFactor(0.5)
                        }
                    }
                    .padding(24)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "hand.tap.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(Color.cream.opacity(0.5))
                        Text("HOLD TO PEEK")
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .tracking(2.0)
                            .foregroundStyle(Color.cream.opacity(0.6))
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 260)
            .onLongPressGesture(minimumDuration: .infinity, maximumDistance: 60) {
            } onPressingChanged: { pressing in
                peeking = pressing
                if pressing { peeked = true }
            }

            Spacer()

            Button { nextPlayer() } label: {
                HStack {
                    Text(currentPlayer + 1 == playerCount ? "EVERYONE'S SEEN IT" : "PASS TO PLAYER \(currentPlayer + 2)")
                        .font(.system(size: 13, weight: .bold, design: .monospaced)).tracking(2)
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                }
                .foregroundStyle(peeked ? Color.ink : Color.cream.opacity(0.4))
                .padding(.vertical, 16).padding(.horizontal, 20)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(peeked ? GameKind.imposter.accent : Color.cream.opacity(0.08)))
            }
            .disabled(!peeked)
            .buttonStyle(PressScaleStyle())
        }
    }

    // ---- discussion + reveal -------------------------------------------

    private var discuss: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 34))
                .foregroundStyle(GameKind.imposter.accent)
            Text("Talk it out.")
                .font(.system(size: 28, weight: .black, design: .rounded))
                .italic().tracking(-0.8)
                .foregroundStyle(Color.cream)
            VStack(spacing: 8) {
                Text("Player \(starter + 1) starts — everyone describes the word in one sentence, without saying it.")
                Text("Then the table votes on who the imposter is.")
            }
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundStyle(Color.cream.opacity(0.65))
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .padding(.horizontal, 12)
            Spacer()
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { phase = .unmasked }
            } label: {
                HStack {
                    Text("REVEAL THE IMPOSTER")
                        .font(.system(size: 13, weight: .bold, design: .monospaced)).tracking(2.4)
                    Spacer()
                    Image(systemName: "eye.fill")
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundStyle(Color.ink)
                .padding(.vertical, 16).padding(.horizontal, 20)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(GameKind.imposter.accent))
                .shadow(color: GameKind.imposter.accent.opacity(0.45), radius: 18, y: 8)
            }
            .buttonStyle(PressScaleStyle())
        }
    }

    private var unmasked: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "theatermasks.fill")
                .font(.system(size: 40))
                .foregroundStyle(GameKind.imposter.accent)
            Text("PLAYER \(imposterIndex + 1)")
                .font(.system(size: 30, weight: .black, design: .rounded))
                .foregroundStyle(Color.cream)
            Text("was the imposter")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.65))
            VStack(spacing: 4) {
                Text("THE WORD WAS")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(2.2)
                    .foregroundStyle(Color.bronze)
                Text(word)
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .foregroundStyle(Color.whiskey)
            }
            .padding(.top, 6)
            Text(GameKind.imposter.rule)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.55))
                .multilineTextAlignment(.center)
                .padding(.top, 4)
            Spacer()
            Button { start() } label: {
                HStack {
                    Text("NEW ROUND")
                        .font(.system(size: 13, weight: .bold, design: .monospaced)).tracking(3)
                    Spacer()
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundStyle(Color.ink)
                .padding(.vertical, 16).padding(.horizontal, 20)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(GameKind.imposter.accent))
                .shadow(color: GameKind.imposter.accent.opacity(0.45), radius: 18, y: 8)
            }
            .buttonStyle(PressScaleStyle())
        }
    }

    // ---- mechanics -----------------------------------------------------

    private func start() {
        let d = GameContent.decks(for: .imposter)
        let deck = (spicy && store.isSubscribed) ? d.afterDark : d.free
        word = deck.prompts.randomElement() ?? "Karaoke"
        imposterIndex = Int.random(in: 0..<playerCount)
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
            if currentPlayer + 1 == playerCount {
                phase = .discuss
            } else {
                currentPlayer += 1
            }
        }
    }
}

// MARK: - After Dark paywall

struct AfterDarkPaywall: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AfterDarkStore

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            DimpleDriftBackground(strength: 0.17, speed: 7, scale: 1.2)
            RadialGradient(colors: [Color.whiskey.opacity(0.22), .clear],
                           center: .init(x: 0.85, y: 0.0),
                           startRadius: 10, endRadius: 380)
            .ignoresSafeArea()

            VStack(spacing: 18) {
                Capsule()
                    .fill(Color.cream.opacity(0.2))
                    .frame(width: 36, height: 4)
                    .padding(.top, 10)

                Image(systemName: "flame.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.whiskey)
                    .padding(.top, 8)
                Text("AFTER DARK")
                    .font(.system(size: 24, weight: .black, design: .monospaced))
                    .tracking(3.5)
                    .foregroundStyle(Color.cream)
                Text("The spicy decks — for tables that can handle it.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.65))

                VStack(alignment: .leading, spacing: 12) {
                    perk("theatermasks.fill", "Spicy word packs in Imposter")
                    perk("hand.raised.fill", "28 bolder Never Have I Ever prompts")
                    perk("shippingbox.fill", "Daring truths & dares in Pandora's Box")
                    perk("person.line.dotted.person.fill", "Flirtier Most Likely To rounds")
                    perk("sparkles", "New cards added while you're subscribed")
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.cream.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.whiskey.opacity(0.3), lineWidth: 1))

                if store.isSubscribed {
                    Text("You're in. Go play.")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.whiskey)
                        .padding(.top, 8)
                } else if let err = store.loadError {
                    Text(err)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                } else {
                    ForEach(store.products, id: \.id) { product in
                        Button {
                            Task { await store.purchase(product) }
                        } label: {
                            HStack {
                                Text(product.id.hasSuffix("yearly") ? "YEARLY" : "MONTHLY")
                                    .font(.system(size: 12, weight: .black, design: .monospaced))
                                    .tracking(2.0)
                                Spacer()
                                Text(product.displayPrice)
                                    .font(.system(size: 15, weight: .black, design: .rounded))
                            }
                            .foregroundStyle(Color.ink)
                            .padding(.vertical, 15).padding(.horizontal, 20)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.whiskey))
                        }
                        .buttonStyle(PressScaleStyle())
                        .disabled(store.purchasing)
                    }
                }

                Button {
                    Task { await store.restore() }
                } label: {
                    Text(store.purchasing ? "Working…" : "Restore purchases")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.bronze)
                }
                .disabled(store.purchasing)
                .buttonStyle(PressScaleStyle())

                Text("Auto-renews until cancelled in Settings → Apple ID → Subscriptions. [Terms](https://sejdel.com/terms/) · [Privacy](https://sejdel.com/privacy/)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .tint(Color.bronze)
                    .foregroundStyle(Color.cream.opacity(0.4))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Spacer(minLength: 6)
            }
            .padding(.horizontal, 20)
        }
        .preferredColorScheme(.dark)
        .onChange(of: store.isSubscribed) { _, unlocked in
            if unlocked {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { dismiss() }
            }
        }
        .task { if store.products.isEmpty { await store.load() } }
    }

    private func perk(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.whiskey)
                .frame(width: 22)
            Text(text)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.85))
        }
    }
}
