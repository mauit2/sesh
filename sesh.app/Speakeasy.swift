// Speakeasy — hidden-role social deduction for a live group sesh, After
// Dark only to host (anyone in the host's sesh can play). The rules engine
// lives entirely in Postgres (speakeasy_* RPCs); this file is a thin,
// role-scoped client: it polls `speakeasy_current` every 2 s and sends
// actions through `speakeasy_act`, which validates every move server-side
// and only ever returns the caller's own secrets.
//
// Roles: PATRONS (majority) vs BOOTLEGGERS + THE BOSS. Cards: HAPPY HOUR (H)
// and RACKET (R). Offices: HOST nominates a BARKEEP; everyone votes.
// Powers on the Racket track: ID CHECK, SKIP THE LINE, PEEK THE TAB, CUT OFF.

import SwiftUI
import Supabase

// MARK: - Role-scoped state

struct SEPlayer: Decodable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let alive: Bool
    let seat: Int
    let role: String?
    let voted: Bool?
    let investigated: Bool
}

struct SEAlly: Decodable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let role: String
}

struct SELastVote: Decodable, Equatable {
    let ja: Int
    let nein: Int
    let passed: Bool
    let by: [String: Bool]
    let president: Int
    let chancellor: Int
}

struct SEInvestigation: Decodable, Equatable {
    let target: UUID
    let name: String
    let party: String
}

struct SEState: Decodable, Equatable {
    let id: UUID
    let phase: String
    let n: Int
    let hostId: UUID
    let me: Int?
    let myRole: String?
    let players: [SEPlayer]
    let allies: [SEAlly]
    let enactedH: Int
    let enactedR: Int
    let tracker: Int
    let president: Int
    let chancellor: Int?
    let lastPresident: Int?
    let lastChancellor: Int?
    let powers: [String]
    let vetoUnlocked: Bool
    let vetoDenied: Bool
    let deckCount: Int
    let discardCount: Int
    let votesIn: Int
    let alive: Int
    let lastVote: SELastVote?
    let log: [String]
    let winner: String?
    let winReason: String?
    let eligible: [UUID]
    let hand: [String]?
    let peek: [String]?
    let investigation: SEInvestigation?

    enum CodingKeys: String, CodingKey {
        case id, phase, n, me, players, allies, tracker, president, chancellor, powers, alive, log, winner, eligible, hand, peek, investigation
        case hostId = "host_id", myRole = "my_role", enactedH = "enacted_h", enactedR = "enacted_r"
        case lastPresident = "last_president", lastChancellor = "last_chancellor"
        case vetoUnlocked = "veto_unlocked", vetoDenied = "veto_denied"
        case deckCount = "deck_count", discardCount = "discard_count", votesIn = "votes_in"
        case lastVote = "last_vote", winReason = "win_reason"
    }

    var isOver: Bool { phase == "over" }
    func player(_ seat: Int?) -> SEPlayer? {
        guard let seat, seat >= 0, seat < players.count else { return nil }
        return players[seat]
    }
    var myId: UUID? { player(me)?.id }
    var iAmPresident: Bool { me != nil && me == president }
    var iAmChancellor: Bool { me != nil && me == chancellor }
    var iAmAlive: Bool { player(me)?.alive ?? false }
    var presidentName: String { player(president)?.name ?? "the Host" }
    var chancellorName: String { player(chancellor)?.name ?? "the Barkeep" }
}

// MARK: - API

enum SpeakeasyAPI {
    struct SessionParams: Encodable { let p_session: UUID }
    struct StartParams: Encodable { let p_session: UUID; let p_players: [UUID] }
    struct Action: Encodable {
        var type: String
        var target: UUID? = nil
        var ja: Bool? = nil
        var index: Int? = nil
        var agree: Bool? = nil
    }
    struct ActParams: Encodable { let p_match: UUID; let p_action: Action }

    static func current(_ session: UUID) async -> SEState? {
        do {
            let s: SEState? = try await supabase.rpc("speakeasy_current", params: SessionParams(p_session: session))
                .execute().value
            return s
        } catch {
            return nil
        }
    }

    static func start(_ session: UUID, players: [UUID]) async throws -> SEState {
        try await supabase.rpc("speakeasy_start", params: StartParams(p_session: session, p_players: players))
            .execute().value
    }

    static func act(_ match: UUID, _ action: Action) async throws -> SEState {
        try await supabase.rpc("speakeasy_act", params: ActParams(p_match: match, p_action: action))
            .execute().value
    }

    static func message(_ error: Error) -> String {
        if let e = error as? PostgrestError { return e.message }
        return error.localizedDescription
    }
}

/// Pushed from the hub or the intro; the game view loads its own state.
struct SpeakeasyTicket: Hashable { let session: UUID }

// MARK: - Palette

private enum SE {
    static let patron = Color(red: 0.24, green: 0.76, blue: 0.62)
    static let racket = Color(red: 0.86, green: 0.28, blue: 0.24)
    static let boss   = Color(red: 0.72, green: 0.24, blue: 0.40)
    static var accent: Color { GameKind.speakeasy.accent }
    static var deep: Color { GameKind.speakeasy.accentDeep }

    static func roleTitle(_ role: String?) -> String {
        switch role { case "boss": return "THE BOSS"; case "bootlegger": return "BOOTLEGGER"; default: return "PATRON" }
    }
    static func roleColor(_ role: String?) -> Color {
        switch role { case "boss": return boss; case "bootlegger": return racket; default: return patron }
    }
    static func powerLabel(_ p: String) -> String {
        switch p {
        case "investigate": return "ID CHECK"
        case "special":     return "SKIP THE LINE"
        case "peek":        return "PEEK THE TAB"
        case "execute":     return "CUT OFF"
        case "win":         return "BOOTLEGGERS WIN"
        default:            return ""
        }
    }
    static func powerIcon(_ p: String) -> String {
        switch p {
        case "investigate": return "person.text.rectangle"
        case "special":     return "arrow.uturn.right"
        case "peek":        return "eye"
        case "execute":     return "xmark.octagon"
        case "win":         return "flag.checkered"
        default:            return ""
        }
    }
}

private struct SEButton: View {
    let title: String
    var icon: String = "arrow.right"
    var colors: [Color] = [SE.accent, SE.deep]
    var enabled: Bool = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 14, weight: .black, design: .monospaced)).tracking(2.4)
                Spacer()
                Image(systemName: icon).font(.system(size: 13, weight: .bold))
            }
            .foregroundStyle(enabled ? Color.ink : Color.cream.opacity(0.4))
            .padding(.vertical, 17).padding(.horizontal, 22)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(enabled ? AnyShapeStyle(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                              : AnyShapeStyle(Color.cream.opacity(0.08))))
            .shadow(color: (colors.first ?? .clear).opacity(enabled ? 0.4 : 0), radius: 18, y: 9)
        }
        .disabled(!enabled)
        .buttonStyle(PressScaleStyle())
    }
}

private struct SEGhostButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .black, design: .monospaced)).tracking(2.2)
                .foregroundStyle(Color.cream.opacity(0.75))
                .padding(.vertical, 15).frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.cream.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.cream.opacity(0.14), lineWidth: 1))
        }
        .buttonStyle(PressScaleStyle())
    }
}

private struct PolicyCard: View {
    let kind: String   // "H" or "R"
    var selected: Bool = false
    var body: some View {
        let racket = kind == "R"
        VStack(spacing: 8) {
            Image(systemName: racket ? "flame.fill" : "wineglass.fill")
                .font(.system(size: 26, weight: .bold))
            Text(racket ? "RACKET" : "HAPPY\nHOUR")
                .font(.system(size: 12, weight: .black, design: .monospaced)).tracking(1.6)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(Color.cream)
        .frame(width: 96, height: 132)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(LinearGradient(colors: racket ? [SE.racket, Color(red: 0.5, green: 0.1, blue: 0.15)]
                                                 : [SE.patron, Color(red: 0.06, green: 0.38, blue: 0.36)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(selected ? Color.cream : Color.cream.opacity(0.3), lineWidth: selected ? 3 : 1))
        .shadow(color: (racket ? SE.racket : SE.patron).opacity(0.35), radius: 14, y: 8)
    }
}

private func sectionLabel(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 11, weight: .black, design: .monospaced)).tracking(2.2)
        .foregroundStyle(Color.bronze)
        .frame(maxWidth: .infinity, alignment: .leading)
}

// MARK: - Intro / lobby

struct SpeakeasyIntroView: View {
    @ObservedObject var group: SessionService
    @Binding var paywallOpen: Bool
    @EnvironmentObject private var store: AfterDarkStore

    @State private var live: SEState? = nil
    @State private var picked: Set<UUID> = []
    @State private var starting = false
    @State private var error: String? = nil
    @State private var rulesOpen = false

    private var members: [UUID] {
        var ids = group.members.filter(\.inLive).map(\.profileId)
        if let me = group.myId, !ids.contains(me) { ids.append(me) }
        return ids
    }
    private func name(_ id: UUID) -> String {
        if id == group.myId { return "You" }
        return group.memberProfiles[id]?.name ?? "Someone"
    }

    var body: some View {
        ZStack {
            AtmosphereBackground(accent: .whiskey)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    fan.padding(.top, 8)
                    Text("SPEAKEASY")
                        .font(.system(size: 30, weight: .black, design: .rounded))
                        .italic().tracking(-1)
                        .foregroundStyle(Color.cream)

                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(GameKind.speakeasy.rules.enumerated()), id: \.offset) { i, rule in
                            HStack(alignment: .top, spacing: 14) {
                                Text("\(i + 1)")
                                    .font(.system(size: 13, weight: .black, design: .monospaced))
                                    .foregroundStyle(Color.ink)
                                    .frame(width: 28, height: 28)
                                    .background(Circle().fill(SE.accent))
                                Text(rule)
                                    .font(.system(size: 18, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.cream)
                                    .lineSpacing(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Button { rulesOpen = true } label: {
                            Text("FULL RULES")
                                .font(.system(size: 11, weight: .black, design: .monospaced)).tracking(2)
                                .foregroundStyle(SE.accent)
                        }
                        .buttonStyle(PressScaleStyle())
                        .padding(.top, 2)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.ink.opacity(0.6)))
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(SE.accent.opacity(0.35), lineWidth: 1))

                    lobby
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .sheet(isPresented: $rulesOpen) { SpeakeasyRulesSheet().presentationBackground(Color.ink) }
        .task {
            while !Task.isCancelled {
                if let sid = group.session?.id { live = await SpeakeasyAPI.current(sid) }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        .onAppear { if picked.isEmpty { picked = Set(members) } }
    }

    private var fan: some View {
        ZStack {
            ForEach([-1, 1, 0], id: \.self) { i in
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(GameKind.speakeasy.gradient)
                    .frame(width: 118, height: 160)
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.cream.opacity(0.35), lineWidth: 1))
                    .overlay(Image(systemName: i == 0 ? GameKind.speakeasy.icon : (i < 0 ? "wineglass.fill" : "flame.fill"))
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(Color.cream.opacity(i == 0 ? 0.95 : 0.35)))
                    .rotationEffect(.degrees(Double(i) * 14))
                    .offset(x: CGFloat(i) * 46, y: i == 0 ? -6 : 10)
                    .opacity(i == 0 ? 1 : 0.85)
                    .shadow(color: SE.accent.opacity(0.35), radius: 18, y: 10)
            }
        }
        .frame(height: 190)
    }

    @ViewBuilder
    private var lobby: some View {
        if let live, !live.isOver, let sid = group.session?.id {
            VStack(spacing: 12) {
                Text("\(live.n) at the table · round in progress")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.7))
                NavigationLink(value: SpeakeasyTicket(session: sid)) {
                    seButtonLabel("JOIN THE TABLE", icon: "door.left.hand.open")
                }
                .buttonStyle(PressScaleStyle())
            }
        } else if !group.isActive {
            Text("Start a live group sesh with 5–10 friends to open the Speakeasy.")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.6))
                .multilineTextAlignment(.center)
        } else if !store.hasSpicy {
            VStack(spacing: 12) {
                Text("Anyone in your sesh with After Dark can deal you in.")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.65))
                    .multilineTextAlignment(.center)
                SEButton(title: "UNLOCK TO HOST", icon: "flame.fill", colors: [Color.whiskey, SE.racket]) { paywallOpen = true }
            }
        } else if let sid = group.session?.id {
            VStack(spacing: 12) {
                sectionLabel("WHO'S PLAYING · \(picked.count) OF \(members.count)")
                VStack(spacing: 6) {
                    ForEach(members, id: \.self) { id in
                        Button {
                            if id == group.myId { return }
                            if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
                        } label: {
                            HStack {
                                Image(systemName: picked.contains(id) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(picked.contains(id) ? SE.accent : Color.cream.opacity(0.3))
                                Text(name(id))
                                    .font(.system(size: 16, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.cream)
                                Spacer()
                            }
                            .padding(.vertical, 12).padding(.horizontal, 14)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cream.opacity(0.05)))
                        }
                        .buttonStyle(PressScaleStyle())
                    }
                }
                if let error {
                    Text(error)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Status.drunk.color)
                        .multilineTextAlignment(.center)
                }
                if picked.count < 5 || picked.count > 10 {
                    Text("Speakeasy needs 5 to 10 players.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.5))
                }
                SEButton(title: starting ? "DEALING…" : "DEAL THE ROLES", icon: "theatermasks.fill",
                         enabled: !starting && picked.count >= 5 && picked.count <= 10) {
                    starting = true; error = nil
                    Task {
                        do {
                            live = try await SpeakeasyAPI.start(sid, players: Array(picked))
                        } catch {
                            self.error = SpeakeasyAPI.message(error)
                        }
                        starting = false
                    }
                }
            }
        }
    }

    private func seButtonLabel(_ title: String, icon: String) -> some View {
        HStack {
            Text(title).font(.system(size: 14, weight: .black, design: .monospaced)).tracking(2.4)
            Spacer()
            Image(systemName: icon).font(.system(size: 13, weight: .bold))
        }
        .foregroundStyle(Color.ink)
        .padding(.vertical, 17).padding(.horizontal, 22)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(LinearGradient(colors: [SE.accent, SE.deep], startPoint: .leading, endPoint: .trailing)))
        .shadow(color: SE.accent.opacity(0.4), radius: 18, y: 9)
    }
}

// MARK: - Full rules sheet

struct SpeakeasyRulesSheet: View {
    private let sections: [(String, [String])] = [
        ("THE TABLE", [
            "5–10 players. Most are Patrons. A few are Bootleggers — and one of them is The Boss.",
            "Bootleggers know each other and The Boss. With 5–6 players The Boss knows the Bootleggers too; with 7+ The Boss is in the dark.",
            "Patrons know nothing. Talk, bluff, accuse."]),
        ("EACH ROUND", [
            "The Host (rotates around the table) nominates a Barkeep. Everyone votes JA or NEIN.",
            "Passed: the Host draws 3 cards, discards 1 face down, hands 2 to the Barkeep, who plays 1. No talking about the cards.",
            "Failed: the tracker ticks up. Three failed votes in a row and the top card is played blind — no power, no term limits.",
            "Term limits: the last elected Host and Barkeep can't be Barkeep again (only the Barkeep, once 5 or fewer remain)."]),
        ("THE RACKET TRACK", [
            "Each Racket played can hand the Host a power, depending on table size: ID CHECK (see a player's party), SKIP THE LINE (choose the next Host), PEEK THE TAB (see the next 3 cards), CUT OFF (remove a player for good).",
            "After 5 Rackets the Barkeep may propose calling the round off; if the Host agrees, both cards are discarded and the tracker ticks."]),
        ("HOW IT ENDS", [
            "Patrons win with 5 Happy Hours, or by cutting off The Boss.",
            "Bootleggers win with 6 Rackets, or when The Boss is elected Barkeep after 3 Rackets are on the board."]),
        ("DRINKING", [
            "Lose a vote? Drink. Get cut off? Finish your drink. The losing side drinks when it's over."])
    ]

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    Capsule().fill(Color.cream.opacity(0.2)).frame(width: 36, height: 4)
                        .frame(maxWidth: .infinity).padding(.top, 10)
                    Text("How the Speakeasy works")
                        .font(.system(size: 28, weight: .black, design: .rounded)).italic().tracking(-0.8)
                        .foregroundStyle(Color.cream)
                    ForEach(sections, id: \.0) { title, lines in
                        VStack(alignment: .leading, spacing: 10) {
                            sectionLabel(title)
                            ForEach(lines, id: \.self) { line in
                                Text(line)
                                    .font(.system(size: 15, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.cream.opacity(0.85))
                                    .lineSpacing(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(.horizontal, 22).padding(.bottom, 30)
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Game

struct SpeakeasyGameView: View {
    let session: UUID
    @ObservedObject var group: SessionService
    @EnvironmentObject private var store: AfterDarkStore
    @Environment(\.dismiss) private var dismiss

    @State private var state: SEState? = nil
    @State private var busy = false
    @State private var error: String? = nil
    @State private var roleOpen = false
    @State private var pendingTarget: UUID? = nil
    @State private var restarting = false

    var body: some View {
        ZStack {
            AtmosphereBackground(accent: .whiskey)
            if let s = state {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        header(s)
                        board(s)
                        phasePanel(s)
                        seats(s)
                        logBox(s)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 30)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: GameKind.speakeasy.icon).font(.system(size: 40)).foregroundStyle(SE.accent)
                    Text("Finding the table…")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.6))
                }
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .sheet(isPresented: $roleOpen) {
            if let s = state { SpeakeasyRoleSheet(state: s).presentationBackground(Color.ink) }
        }
        .task {
            while !Task.isCancelled {
                if !busy, let s = await SpeakeasyAPI.current(session) { state = s }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    // ---- pieces ---------------------------------------------------------

    private func header(_ s: SEState) -> some View {
        HStack(alignment: .center) {
            Text("SPEAKEASY")
                .font(.system(size: 23, weight: .heavy, design: .rounded)).italic().tracking(-0.6)
                .foregroundStyle(Color.cream)
            Spacer()
            if s.me != nil {
                Button { roleOpen = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "eye.fill").font(.system(size: 11, weight: .bold))
                        Text("MY ROLE").font(.system(size: 10, weight: .black, design: .monospaced)).tracking(1.8)
                    }
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Capsule().fill(SE.accent))
                }
                .buttonStyle(PressScaleStyle())
            }
        }
    }

    private func board(_ s: SEState) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                ForEach(0..<5, id: \.self) { i in
                    slot(filled: i < s.enactedH, color: SE.patron, icon: i == 4 ? "flag.checkered" : "wineglass.fill", label: nil)
                }
            }
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { i in
                    let power = i < s.powers.count ? s.powers[i] : ""
                    slot(filled: i < s.enactedR, color: SE.racket,
                         icon: power.isEmpty ? "flame.fill" : SE.powerIcon(power),
                         label: power.isEmpty ? nil : SE.powerLabel(power))
                }
            }
            HStack(spacing: 10) {
                Text("FAILED VOTES")
                    .font(.system(size: 10, weight: .black, design: .monospaced)).tracking(1.8)
                    .foregroundStyle(Color.bronze)
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(i < s.tracker ? Color.whiskey : Color.cream.opacity(0.12)).frame(width: 10, height: 10)
                }
                Spacer()
                Text("DECK \(s.deckCount)")
                    .font(.system(size: 10, weight: .black, design: .monospaced)).tracking(1.8)
                    .foregroundStyle(Color.cream.opacity(0.4))
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.ink.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.cream.opacity(0.1), lineWidth: 1))
    }

    private func slot(filled: Bool, color: Color, icon: String, label: String?) -> some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(filled ? color : Color.cream.opacity(0.06))
                    .frame(height: 46)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(filled ? Color.cream.opacity(0.3) : color.opacity(0.35), lineWidth: 1)
                    .frame(height: 46)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(filled ? Color.cream : color.opacity(0.7))
            }
            if let label {
                Text(label)
                    .font(.system(size: 6.5, weight: .black, design: .monospaced)).tracking(0.4)
                    .foregroundStyle(Color.cream.opacity(0.45))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(height: 18)
            } else {
                Color.clear.frame(height: 18)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // ---- the action panel, by phase ------------------------------------

    @ViewBuilder
    private func phasePanel(_ s: SEState) -> some View {
        VStack(spacing: 14) {
            if let error {
                Text(error)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Status.drunk.color)
                    .multilineTextAlignment(.center)
            }
            switch s.phase {
            case "nominate":
                if s.iAmPresident {
                    big("You host.", "Pick your Barkeep.")
                    pickList(s, eligible: s.eligible, tint: SE.accent) { id in send(s, .init(type: "nominate", target: id)) }
                } else {
                    waiting("\(s.presidentName) is picking a Barkeep.")
                }
            case "vote":
                big("Vote.", "\(s.presidentName) & \(s.chancellorName)")
                if s.iAmAlive {
                    HStack(spacing: 10) {
                        SEButton(title: "JA", icon: "hand.thumbsup.fill", colors: [SE.patron, Color(red: 0.06, green: 0.38, blue: 0.36)], enabled: !busy) {
                            send(s, .init(type: "vote", ja: true))
                        }
                        SEButton(title: "NEIN", icon: "hand.thumbsdown.fill", colors: [SE.racket, Color(red: 0.5, green: 0.1, blue: 0.15)], enabled: !busy) {
                            send(s, .init(type: "vote", ja: false))
                        }
                    }
                    Text("\(s.votesIn) of \(s.alive) in — you can change your vote until everyone's voted.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.5))
                        .multilineTextAlignment(.center)
                } else {
                    waiting("\(s.votesIn) of \(s.alive) votes in.")
                }
            case "president":
                if s.iAmPresident, let hand = s.hand {
                    big("Your draw.", "Tap one card to discard. The other two go to \(s.chancellorName).")
                    HStack(spacing: 10) {
                        ForEach(Array(hand.enumerated()), id: \.offset) { i, c in
                            Button { send(s, .init(type: "discard", index: i)) } label: { PolicyCard(kind: c) }
                                .buttonStyle(PressScaleStyle()).disabled(busy)
                        }
                    }
                } else {
                    waiting("\(s.presidentName) is choosing cards.")
                }
            case "chancellor":
                if s.iAmChancellor, let hand = s.hand {
                    big("Your call.", "Tap the card you want played.")
                    HStack(spacing: 10) {
                        ForEach(Array(hand.enumerated()), id: \.offset) { i, c in
                            Button { send(s, .init(type: "enact", index: i)) } label: { PolicyCard(kind: c) }
                                .buttonStyle(PressScaleStyle()).disabled(busy)
                        }
                    }
                    if s.vetoUnlocked && !s.vetoDenied {
                        SEGhostButton(title: "CALL IT OFF (VETO)") { send(s, .init(type: "veto")) }
                    }
                } else {
                    waiting("\(s.chancellorName) is choosing a card.")
                }
            case "veto":
                if s.iAmPresident {
                    big("Call it off?", "\(s.chancellorName) wants to discard both cards.")
                    HStack(spacing: 10) {
                        SEButton(title: "AGREE", icon: "checkmark", colors: [SE.patron, Color(red: 0.06, green: 0.38, blue: 0.36)], enabled: !busy) {
                            send(s, .init(type: "veto_reply", agree: true))
                        }
                        SEButton(title: "REFUSE", icon: "xmark", colors: [SE.racket, Color(red: 0.5, green: 0.1, blue: 0.15)], enabled: !busy) {
                            send(s, .init(type: "veto_reply", agree: false))
                        }
                    }
                } else {
                    waiting("\(s.chancellorName) wants to call it off — \(s.presidentName) decides.")
                }
            case "investigate":
                if s.iAmPresident {
                    big("ID check.", "Pick someone. Only you see their party.")
                    pickList(s, eligible: s.eligible, tint: SE.accent) { id in send(s, .init(type: "investigate", target: id)) }
                } else {
                    waiting("\(s.presidentName) is checking someone's ID.")
                }
            case "investigate_result":
                if s.iAmPresident, let inv = s.investigation {
                    big("\(inv.name) is a \(inv.party == "patron" ? "Patron" : "Bootlegger").", "Say what you like about it.")
                    SEButton(title: "CONTINUE") { send(s, .init(type: "continue")) }
                } else {
                    waiting("\(s.presidentName) is reading an ID.")
                }
            case "special":
                if s.iAmPresident {
                    big("Skip the line.", "Choose who hosts next.")
                    pickList(s, eligible: s.eligible, tint: SE.accent) { id in send(s, .init(type: "special", target: id)) }
                } else {
                    waiting("\(s.presidentName) is choosing the next Host.")
                }
            case "peek":
                if s.iAmPresident, let peek = s.peek {
                    big("The tab.", "The next three cards, top first.")
                    HStack(spacing: 10) { ForEach(Array(peek.enumerated()), id: \.offset) { _, c in PolicyCard(kind: c) } }
                    SEButton(title: "CONTINUE") { send(s, .init(type: "continue")) }
                } else {
                    waiting("\(s.presidentName) is peeking at the tab.")
                }
            case "execute":
                if s.iAmPresident {
                    big("Cut someone off.", "They're out for good. If it's The Boss, Patrons win.")
                    if let t = pendingTarget, let p = s.players.first(where: { $0.id == t }) {
                        SEButton(title: "CUT OFF \(p.name.uppercased())", icon: "xmark.octagon.fill", colors: [SE.racket, Color(red: 0.5, green: 0.1, blue: 0.15)], enabled: !busy) {
                            send(s, .init(type: "execute", target: t)); pendingTarget = nil
                        }
                        SEGhostButton(title: "PICK SOMEONE ELSE") { pendingTarget = nil }
                    } else {
                        pickList(s, eligible: s.eligible, tint: SE.racket) { id in pendingTarget = id }
                    }
                } else {
                    waiting("\(s.presidentName) is deciding who gets cut off.")
                }
            case "over":
                let patrons = s.winner == "patrons"
                VStack(spacing: 8) {
                    Image(systemName: patrons ? "wineglass.fill" : "flame.fill")
                        .font(.system(size: 44, weight: .bold)).foregroundStyle(patrons ? SE.patron : SE.racket)
                    Text(patrons ? "Patrons win." : "Bootleggers win.")
                        .font(.system(size: 32, weight: .black, design: .rounded)).italic().tracking(-1)
                        .foregroundStyle(Color.cream)
                    Text(s.winReason ?? "")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.7))
                }
                if store.hasSpicy {
                    SEButton(title: restarting ? "DEALING…" : "NEW GAME", icon: "arrow.counterclockwise", enabled: !restarting) {
                        restarting = true; error = nil
                        Task {
                            do { state = try await SpeakeasyAPI.start(session, players: s.players.map(\.id)) }
                            catch { self.error = SpeakeasyAPI.message(error) }
                            restarting = false
                        }
                    }
                }
                SEGhostButton(title: "BACK TO GAMES") { dismiss() }
            default:
                waiting("…")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(LinearGradient(colors: [SE.accent.opacity(0.22), Color.ink.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing)))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(SE.accent.opacity(0.4), lineWidth: 1.2))
    }

    private func big(_ title: String, _ sub: String) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 26, weight: .black, design: .rounded)).italic().tracking(-0.8)
                .foregroundStyle(Color.cream)
                .multilineTextAlignment(.center)
            Text(sub)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.7))
                .multilineTextAlignment(.center)
        }
    }

    private func waiting(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "hourglass").font(.system(size: 22, weight: .bold)).foregroundStyle(SE.accent)
            Text(text)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 6)
    }

    private func pickList(_ s: SEState, eligible: [UUID], tint: Color, tap: @escaping (UUID) -> Void) -> some View {
        VStack(spacing: 8) {
            ForEach(s.players.filter { eligible.contains($0.id) }) { p in
                Button { tap(p.id) } label: {
                    HStack {
                        Text(p.name).font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(Color.cream)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(tint)
                    }
                    .padding(.vertical, 13).padding(.horizontal, 16)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cream.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.35), lineWidth: 1))
                }
                .buttonStyle(PressScaleStyle())
                .disabled(busy)
            }
        }
    }

    private func seats(_ s: SEState) -> some View {
        VStack(spacing: 6) {
            sectionLabel("THE TABLE")
            ForEach(s.players) { p in
                HStack(spacing: 8) {
                    Text(p.name)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .strikethrough(!p.alive)
                        .foregroundStyle(p.alive ? Color.cream : Color.cream.opacity(0.35))
                    if p.id == s.myId { tag("YOU", Color.cream.opacity(0.15), Color.cream) }
                    if p.seat == s.president { tag("HOST", SE.accent, Color.ink) }
                    if p.seat == s.chancellor { tag("BARKEEP", Color.whiskey, Color.ink) }
                    if let role = p.role { tag(SE.roleTitle(role), SE.roleColor(role), Color.ink) }
                    Spacer()
                    if s.phase == "vote", p.alive {
                        Image(systemName: p.voted == true ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(p.voted == true ? SE.patron : Color.cream.opacity(0.25))
                    } else if s.phase != "vote", let lv = s.lastVote, let v = lv.by[p.id.uuidString.lowercased()] ?? lv.by[p.id.uuidString] {
                        tag(v ? "JA" : "NEIN", v ? SE.patron.opacity(0.25) : SE.racket.opacity(0.25), v ? SE.patron : SE.racket)
                    }
                    if !p.alive { tag("CUT OFF", SE.racket.opacity(0.2), SE.racket) }
                }
                .padding(.vertical, 9).padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.cream.opacity(0.04)))
            }
            if let lv = s.lastVote, s.phase != "vote" {
                Text("Last vote: \(lv.passed ? "passed" : "failed") \(lv.ja)–\(lv.nein)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(1)
                    .foregroundStyle(Color.cream.opacity(0.45))
                    .padding(.top, 2)
            }
        }
    }

    private func tag(_ text: String, _ bg: Color, _ fg: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .black, design: .monospaced)).tracking(1.2)
            .foregroundStyle(fg)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(Capsule().fill(bg))
    }

    private func logBox(_ s: SEState) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionLabel("TONIGHT")
            ForEach(Array(s.log.suffix(8).reversed().enumerated()), id: \.offset) { i, line in
                Text(line)
                    .font(.system(size: 12, weight: i == 0 ? .bold : .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(i == 0 ? 0.85 : 0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.cream.opacity(0.04)))
    }

    private func send(_ s: SEState, _ action: SpeakeasyAPI.Action) {
        busy = true; error = nil
        Task {
            do { state = try await SpeakeasyAPI.act(s.id, action) }
            catch { self.error = SpeakeasyAPI.message(error) }
            busy = false
        }
    }
}

// MARK: - Role sheet

struct SpeakeasyRoleSheet: View {
    let state: SEState
    var body: some View {
        let role = state.myRole
        let color = SE.roleColor(role)
        ZStack {
            Color.ink.ignoresSafeArea()
            RadialGradient(colors: [color.opacity(0.35), .clear], center: .init(x: 0.5, y: 0.2), startRadius: 10, endRadius: 380)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                Capsule().fill(Color.cream.opacity(0.2)).frame(width: 36, height: 4).padding(.top, 10)
                Spacer()
                Image(systemName: role == "patron" ? "wineglass.fill" : (role == "boss" ? "crown.fill" : "flame.fill"))
                    .font(.system(size: 54, weight: .bold))
                    .foregroundStyle(color)
                Text("YOU ARE")
                    .font(.system(size: 12, weight: .black, design: .monospaced)).tracking(2.6)
                    .foregroundStyle(Color.bronze)
                Text(SE.roleTitle(role))
                    .font(.system(size: 38, weight: .black, design: .rounded)).italic().tracking(-1)
                    .foregroundStyle(color)
                Text(roleBlurb(role, n: state.n))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                if !state.allies.isEmpty {
                    VStack(spacing: 8) {
                        Text("YOUR CREW")
                            .font(.system(size: 11, weight: .black, design: .monospaced)).tracking(2.2)
                            .foregroundStyle(Color.bronze)
                        ForEach(state.allies) { a in
                            HStack(spacing: 8) {
                                Text(a.name).font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(Color.cream)
                                Text(SE.roleTitle(a.role))
                                    .font(.system(size: 9, weight: .black, design: .monospaced)).tracking(1.2)
                                    .foregroundStyle(Color.ink)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Capsule().fill(SE.roleColor(a.role)))
                            }
                        }
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.cream.opacity(0.06)))
                }
                Spacer()
                Text("Keep this to yourself. Swipe down to hide.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.4))
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 20)
        }
        .preferredColorScheme(.dark)
    }

    private func roleBlurb(_ role: String?, n: Int) -> String {
        switch role {
        case "boss":
            return n <= 6
                ? "Stay hidden. Get yourself elected Barkeep once three Rackets are down — your crew knows who you are."
                : "Stay hidden. Get yourself elected Barkeep once three Rackets are down. Your crew knows you; you don't know them."
        case "bootlegger":
            return "Sabotage quietly, sow doubt, and get The Boss behind the bar."
        default:
            return "Find The Boss before the bar is theirs. Keep the Happy Hours coming."
        }
    }
}
