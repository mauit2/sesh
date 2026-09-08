// The guest list. DM a bar, tap "Get on the list", and the bar gets a
// request card in the chat — full name, +N, Instagram, which night. Approved
// names land on the bar's list (☰ → Guest list), one night at a time, ready
// to share as text or export as CSV for the door. Bars pick the weekdays
// they take the list; Business+ bars auto-approve regulars and block names.
// Migrations 123–124.

import SwiftUI
import Combine
import Foundation
import Supabase
import UIKit

extension Notification.Name {
    /// Open the DMs on a given person — posted by a bar's profile MESSAGE button.
    static let sejdelOpenChat = Notification.Name("sejdel.openChat")
}

/// The chat someone asked to open from outside the DMs page. The side menu
/// switches the tab; the chats page picks the thread up from here.
@MainActor
final class ChatDeepLink: ObservableObject {
    static let shared = ChatDeepLink()
    @Published var pending: ProfileRef?

    static func open(id: UUID, name: String) {
        shared.pending = ProfileRef(id: id, name: name, username: nil, avatar: nil)
        NotificationCenter.default.post(name: .sejdelOpenChat, object: nil)
    }
}

// MARK: - Models

struct ListRequest: Decodable, Identifiable, Equatable {
    let id: UUID
    let businessId: UUID
    let userId: UUID
    let fullName: String
    let instagram: String
    let plusCount: Int
    /// "yyyy-MM-dd"
    let night: String
    let status: String
    let createdAt: String
    let decidedAt: String?
    let userName: String?
    let userUsername: String?
    let userAvatar: String?
    /// "favorite" | "blocked" — the bar's standing note on this guest (Business+).
    let flag: String?

    enum CodingKeys: String, CodingKey {
        case id, instagram, night, status, flag
        case businessId = "business_id"
        case userId = "user_id"
        case fullName = "full_name"
        case plusCount = "plus_count"
        case createdAt = "created_at"
        case decidedAt = "decided_at"
        case userName = "user_name"
        case userUsername = "user_username"
        case userAvatar = "user_avatar"
    }

    var total: Int { plusCount + 1 }
    var pending: Bool { status == "pending" }
    var approved: Bool { status == "approved" }
    var nightLabel: String { ListNight.label(night) }
    var instagramURL: URL { URL(string: "https://instagram.com/\(instagram)") ?? URL(string: "https://instagram.com")! }
    /// "Mauritz Andersson +6"
    var headline: String { plusCount > 0 ? "\(fullName) +\(plusCount)" : fullName }
}

struct ListGuestFlag: Decodable, Identifiable, Equatable {
    let userId: UUID
    let flag: String
    let name: String
    let username: String?
    let avatarUrl: String?
    let lastName: String?
    let instagram: String?
    var id: UUID { userId }
    enum CodingKeys: String, CodingKey {
        case flag, name, username, instagram
        case userId = "user_id"
        case avatarUrl = "avatar_url"
        case lastName = "last_name"
    }
}

enum ListNight {
    static let key: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    static func parse(_ s: String) -> Date? { key.date(from: s) }
    static func string(_ d: Date) -> String { key.string(from: d) }
    /// "Fri 11 Sep"
    static func label(_ s: String) -> String {
        guard let d = parse(s) else { return s }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "EEE d MMM"
        return f.string(from: d)
    }
    /// "TONIGHT" / "TOMORROW" / "WED 9"
    static func chip(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return "TONIGHT" }
        if Calendar.current.isDateInTomorrow(d) { return "TOMORROW" }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "EEE d"
        return f.string(from: d).uppercased()
    }
    /// "Tonight" / "Tomorrow" / "Fri 11 Sep" — how a night reads right now.
    static func relative(_ s: String) -> String {
        guard let d = parse(s) else { return s }
        if Calendar.current.isDateInToday(d) { return "Tonight" }
        if Calendar.current.isDateInTomorrow(d) { return "Tomorrow" }
        return label(s)
    }
    static func chip(_ s: String) -> String { parse(s).map(chip) ?? s }
    /// ISO weekday, 1 = Monday … 7 = Sunday.
    static func isoWeekday(_ d: Date) -> Int { (Calendar.current.component(.weekday, from: d) + 5) % 7 + 1 }
    static let weekdayNames = ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"]
    /// The nights a bar takes the list, from today, up to `count` of them.
    static func upcoming(days allowed: [Int], count: Int = 7, horizon: Int = 21) -> [Date] {
        let today = Calendar.current.startOfDay(for: Date())
        return (0..<horizon).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: today) }
            .filter { allowed.contains(isoWeekday($0)) }
            .prefix(count).map { $0 }
    }
}

/// Instagram's glyph — the camera outline — since there's no SF Symbol for it.
struct InstagramGlyph: View {
    var size: CGFloat = 14
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .strokeBorder(lineWidth: size * 0.12)
            Circle()
                .strokeBorder(lineWidth: size * 0.12)
                .frame(width: size * 0.5, height: size * 0.5)
            Circle()
                .frame(width: size * 0.13, height: size * 0.13)
                .offset(x: size * 0.24, y: -size * 0.24)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Store

@MainActor
final class ListRequestStore: ObservableObject {
    static let shared = ListRequestStore()
    @Published private(set) var byId: [UUID: ListRequest] = [:]
    private var loading: Set<UUID> = []

    /// One request, for the chat card. Cached; `reload` forces a refetch.
    func load(_ id: UUID, reload: Bool = false) async {
        guard reload || byId[id] == nil, !loading.contains(id) else { return }
        loading.insert(id); defer { loading.remove(id) }
        if let rows: [ListRequest] = try? await supabase.from("list_requests").select()
            .eq("id", value: id.uuidString.lowercased()).execute().value, let r = rows.first {
            byId[r.id] = r
        }
    }

    /// Which weekdays the bar takes the list — from its public profile.
    func listDays(business: UUID) async -> [Int] {
        struct P: Encodable { let p_business: String }
        struct Payload: Decodable {
            struct B: Decodable { let listDays: [Int]?; enum CodingKeys: String, CodingKey { case listDays = "list_days" } }
            let business: B
        }
        let p: Payload? = try? await supabase.rpc("business_profile", params: P(p_business: business.uuidString.lowercased())).execute().value
        return p?.business.listDays ?? [1, 2, 3, 4, 5, 6, 7]
    }

    func send(business: UUID, fullName: String, instagram: String, plus: Int, night: Date) async throws -> UUID {
        struct P: Encodable { let p_business: String; let p_full_name: String; let p_instagram: String; let p_plus: Int; let p_night: String }
        let data = try await supabase.rpc("list_request_send", params: P(
            p_business: business.uuidString.lowercased(), p_full_name: fullName, p_instagram: instagram,
            p_plus: plus, p_night: ListNight.string(night))).execute().data
        let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))
        guard let id = UUID(uuidString: raw) else { throw ListError.code("bad_response") }
        return id
    }

    func decide(_ id: UUID, approve: Bool) async throws {
        struct P: Encodable { let p_request: String; let p_approve: Bool }
        _ = try await supabase.rpc("list_request_decide", params: P(p_request: id.uuidString.lowercased(), p_approve: approve)).execute()
        await load(id, reload: true)
    }

    /// The bar's list from yesterday on.
    func list(for business: UUID) async throws -> [ListRequest] {
        struct P: Encodable { let p_business: String }
        let rows: [ListRequest] = try await supabase.rpc("list_requests_for", params: P(p_business: business.uuidString.lowercased())).execute().value
        for r in rows { byId[r.id] = r }
        return rows
    }

    func setListDays(business: UUID, days: [Int]) async throws {
        struct P: Encodable { let p_business: String; let p_days: [Int] }
        _ = try await supabase.rpc("business_set_list_days", params: P(p_business: business.uuidString.lowercased(), p_days: days.sorted())).execute()
    }

    /// nil clears the flag.
    func setFlag(business: UUID, user: UUID, flag: String?) async throws {
        struct P: Encodable { let p_business: String; let p_user: String; let p_flag: String? }
        _ = try await supabase.rpc("list_guest_flag", params: P(p_business: business.uuidString.lowercased(), p_user: user.uuidString.lowercased(), p_flag: flag)).execute()
    }

    func flags(for business: UUID) async throws -> [ListGuestFlag] {
        struct P: Encodable { let p_business: String }
        return try await supabase.rpc("list_guest_flags_for", params: P(p_business: business.uuidString.lowercased())).execute().value
    }

    enum ListError: Error { case code(String) }

    static func friendly(_ error: Error) -> String {
        let s = String(describing: error)
        func has(_ c: String) -> Bool { s.contains(c) }
        if has("already_requested") { return "You've already asked for that night — the bar hasn't answered yet." }
        if has("closed_night")      { return "The bar doesn't take the list that night." }
        if has("not_on_sejdel")     { return "This bar isn't on Sejdel right now." }
        if has("name_required")     { return "Add your full name." }
        if has("instagram_required") { return "Add your Instagram handle." }
        if has("bad_night")         { return "Pick a night from tonight on." }
        if has("bad_party")         { return "Up to +50." }
        if has("own_bar")           { return "That's your own bar." }
        if has("not_yours")         { return "Only the bar can do this." }
        if has("plus_required")     { return "That's a Business+ feature." }
        return "Couldn't do that. Try again."
    }
}

// MARK: - Guest side: the request sheet

/// "Get on the list" — the quick command in a bar's chat.
struct ListRequestSheet: View {
    let business: UUID
    let barName: String
    let profile: Profile
    var onSent: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var fullName: String
    @State private var instagram: String
    @State private var plus = 0
    @State private var night: Date?
    @State private var nights: [Date] = []
    @State private var nightsLoaded = false
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focus: Field?
    private enum Field { case name, instagram }
    private static let instagramKey = "sejdel.list.instagram"
    private static let nameKey = "sejdel.list.fullName"

    init(business: UUID, barName: String, profile: Profile, onSent: @escaping () -> Void = {}) {
        self.business = business; self.barName = barName; self.profile = profile; self.onSent = onSent
        _fullName = State(initialValue: UserDefaults.standard.string(forKey: Self.nameKey) ?? profile.name)
        _instagram = State(initialValue: UserDefaults.standard.string(forKey: Self.instagramKey) ?? "")
    }

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Get on the list")
                                .font(.system(size: 30, weight: .black, design: .rounded))
                                .foregroundStyle(Color.cream)
                            Text("\(barName) gets your name, your crew size and your Instagram, and says yes or no right here in the chat.")
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.cream.opacity(0.65))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.cream.opacity(0.85))
                                .padding(12).background(Circle().fill(Color.cream.opacity(0.08)))
                        }
                        .buttonStyle(PressScaleStyle())
                    }

                    field("FULL NAME", "As on your ID", text: $fullName, field: .name, capitalize: .words)
                    field("INSTAGRAM", "@yourhandle", text: $instagram, field: .instagram, capitalize: .never)

                    VStack(alignment: .leading, spacing: 8) {
                        kicker("HOW MANY")
                        HStack(spacing: 14) {
                            stepButton("minus") { if plus > 0 { plus -= 1 } }
                            VStack(spacing: 2) {
                                Text("You +\(plus)")
                                    .font(.system(size: 26, weight: .black, design: .rounded))
                                    .foregroundStyle(Color.cream)
                                Text(plus == 0 ? "just you" : "\(plus + 1) in total")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Color.bronze)
                            }
                            .frame(maxWidth: .infinity)
                            stepButton("plus") { if plus < 50 { plus += 1 } }
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.cream.opacity(0.05)))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        kicker("WHICH NIGHT")
                        if nightsLoaded && nights.isEmpty {
                            Text("\(barName) isn't taking the list right now.")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.cream.opacity(0.6))
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(nights, id: \.self) { d in
                                        let on = night.map { Calendar.current.isDate(d, inSameDayAs: $0) } ?? false
                                        Button { night = d } label: {
                                            Text(ListNight.chip(d))
                                                .font(.system(size: 12, weight: .black, design: .monospaced))
                                                .tracking(1.2)
                                                .foregroundStyle(on ? Color.ink : Color.cream.opacity(0.8))
                                                .padding(.horizontal, 14).padding(.vertical, 10)
                                                .background(Capsule().fill(on ? Color.whiskey : Color.cream.opacity(0.07)))
                                        }
                                        .buttonStyle(PressScaleStyle())
                                    }
                                }
                            }
                        }
                    }

                    ErrorLine(text: error)
                    BizPrimaryButton(title: "SEND REQUEST", enabled: canSend, busy: busy) { send() }
                    Text("The bar sees your name, +\(plus) and your Instagram. Nothing else.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.45))
                    Spacer(minLength: 20)
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .preferredColorScheme(.dark)
        .task {
            let days = await ListRequestStore.shared.listDays(business: business)
            nights = ListNight.upcoming(days: days)
            night = nights.first
            nightsLoaded = true
        }
    }

    private var canSend: Bool {
        fullName.trimmingCharacters(in: .whitespaces).count >= 2
            && !instagram.trimmingCharacters(in: .whitespaces).isEmpty
            && night != nil
    }

    private func field(_ label: String, _ prompt: String, text: Binding<String>, field: Field,
                       capitalize: TextInputAutocapitalization) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            kicker(label)
            TextField("", text: text, prompt: Text(prompt).foregroundStyle(Color.cream.opacity(0.35)))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.cream)
                .tint(Color.whiskey)
                .textInputAutocapitalization(capitalize)
                .autocorrectionDisabled()
                .focused($focus, equals: field)
                .padding(.horizontal, 14).padding(.vertical, 13)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cream.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.cream.opacity(0.1), lineWidth: 1))
        }
    }

    private func stepButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .black, design: .rounded))
                .foregroundStyle(Color.ink)
                .frame(width: 46, height: 46)
                .background(Circle().fill(Color.whiskey))
        }
        .buttonStyle(PressScaleStyle())
    }

    private func send() {
        guard canSend, let night else { return }
        busy = true; error = nil; focus = nil
        Task {
            do {
                _ = try await ListRequestStore.shared.send(business: business, fullName: fullName, instagram: instagram, plus: plus, night: night)
                UserDefaults.standard.set(fullName, forKey: Self.nameKey)
                UserDefaults.standard.set(instagram, forKey: Self.instagramKey)
                onSent()
                dismiss()
            } catch {
                self.error = ListRequestStore.friendly(error)
            }
            busy = false
        }
    }
}

// MARK: - The card in the chat

/// The request as it sits in the conversation: the guest sees where it
/// stands, the bar approves or declines right there.
struct ListRequestBubble: View {
    let requestId: UUID
    let fallback: String?
    let mine: Bool
    /// I'm the bar this was sent to.
    let decider: Bool
    var onDecided: () -> Void = {}
    @ObservedObject private var store = ListRequestStore.shared
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let r = store.byId[requestId] {
                HStack(spacing: 6) {
                    Image(systemName: "ticket.fill")
                    Text("GET ON THE LIST")
                }
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(Color.whiskey)
                // The night, big — it's the first thing the door needs.
                // "TONIGHT" / "TOMORROW" when it's that close, else the date.
                Text(ListNight.relative(r.night).uppercased())
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(Color.whiskey)
                Text(r.headline)
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.cream)
                Text(r.plusCount == 0 ? "Just them" : "\(r.total) in total")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.6))
                InstagramLink(handle: r.instagram, url: r.instagramURL)
                if decider && r.pending {
                    HStack(spacing: 10) {
                        decisionButton("APPROVE", filled: true) { decide(r, true) }
                        decisionButton("DECLINE", filled: false) { decide(r, false) }
                    }
                    .padding(.top, 2)
                } else {
                    ListStatusPill(status: r.status)
                }
                ErrorLine(text: error)
            } else {
                Text(fallback ?? "List request")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream)
            }
        }
        .padding(14)
        .frame(maxWidth: 300, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.cream.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.whiskey.opacity(0.4), lineWidth: 1))
        .task { await store.load(requestId) }
    }

    private func decisionButton(_ title: String, filled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(busy ? "…" : title)
                .font(.system(size: 12, weight: .black, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(filled ? Color.ink : Color.cream.opacity(0.85))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(filled ? Color.whiskey : Color.cream.opacity(0.08)))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(busy)
    }

    private func decide(_ r: ListRequest, _ approve: Bool) {
        busy = true; error = nil
        Task {
            do { try await store.decide(r.id, approve: approve); onDecided() }
            catch { self.error = ListRequestStore.friendly(error) }
            busy = false
        }
    }
}

/// "@handle ↗" with the Instagram glyph — opens the profile.
struct InstagramLink: View {
    let handle: String
    let url: URL
    var compact = false
    var body: some View {
        Link(destination: url) {
            HStack(spacing: 6) {
                InstagramGlyph(size: compact ? 12 : 14)
                Text("@\(handle)")
                Image(systemName: "arrow.up.right").font(.system(size: compact ? 9 : 10, weight: .bold))
            }
            .font(.system(size: compact ? 12 : 13, weight: .bold, design: .rounded))
            .foregroundStyle(Color.cream)
            .padding(.horizontal, compact ? 10 : 12).padding(.vertical, compact ? 6 : 8)
            .background(Capsule().fill(Color.cream.opacity(0.08)))
        }
    }
}

struct ListStatusPill: View {
    let status: String
    var body: some View {
        let (label, color): (String, Color) = switch status {
        case "approved": ("ON THE LIST ✓", Color(red: 0.45, green: 0.80, blue: 0.55))
        case "declined": ("DECLINED", Color.cream.opacity(0.5))
        default:         ("WAITING FOR THE BAR", Color.whiskey)
        }
        Text(label)
            .font(.system(size: 10, weight: .black, design: .monospaced))
            .tracking(1.4)
            .foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

// MARK: - Bar side: the list

/// ☰ → Guest list. Pick a night, flip between who's on the list and who's
/// waiting, download that night's list. Below: the weekdays you take the
/// list, and (Business+) regulars and blocked names.
struct GuestListBody: View {
    let business: UUID
    let barName: String
    let isPlus: Bool
    let listDays: [Int]
    var onUpgrade: () -> Void = {}
    @ObservedObject private var store = ListRequestStore.shared
    @State private var rows: [ListRequest] = []
    @State private var flags: [ListGuestFlag] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var busy: UUID?
    @State private var copied = false
    @State private var selectedNight: String?
    @State private var showPending = false
    @State private var days: [Int] = []
    @State private var savingDays = false
    @State private var shareFile: ShareFile?

    private struct ShareFile: Identifiable { let id = UUID(); let url: URL }

    /// Nights with requests, from today on.
    private var nights: [String] {
        let today = ListNight.string(Date())
        var seen: [String] = []
        for r in rows where r.night >= today && !seen.contains(r.night) { seen.append(r.night) }
        return seen
    }
    private var night: String? { selectedNight.flatMap { nights.contains($0) ? $0 : nil } ?? nights.first }
    private func rows(_ night: String, approved: Bool) -> [ListRequest] {
        rows.filter { $0.night == night && (approved ? $0.approved : $0.pending) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !loaded {
                ProgressView().tint(Color.whiskey).frame(maxWidth: .infinity).padding(.vertical, 30)
            } else if let night {
                nightPicker
                listSection(night)
            } else {
                BizCard {
                    Text("No one on the list yet.")
                        .font(.system(size: 19, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.cream)
                    Text("Guests ask from your chat — the 🎟 Get on the list button. Say yes there or here, and the names line up, one night at a time, ready to share with the door.")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ErrorLine(text: error)
            if loaded {
                daysCard
                regularsCard
            }
        }
        .task {
            days = listDays
            await load()
        }
        .sheet(item: $shareFile) { f in
            ShareLinkSheet(items: [f.url]).presentationDetents([.medium, .large])
        }
    }

    // ── which night ──
    private var nightPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            kicker("UPCOMING NIGHTS")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(nights, id: \.self) { n in
                        let on = n == night
                        let pending = rows(n, approved: false).count
                        Button { selectedNight = n } label: {
                            HStack(spacing: 6) {
                                Text(ListNight.chip(n))
                                if pending > 0 {
                                    Text("\(pending)")
                                        .font(.system(size: 10, weight: .black, design: .monospaced))
                                        .foregroundStyle(on ? Color.whiskey : Color.ink)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Capsule().fill(on ? Color.ink : Color.whiskey))
                                }
                            }
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .tracking(1.2)
                            .foregroundStyle(on ? Color.ink : Color.cream.opacity(0.8))
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(Capsule().fill(on ? Color.whiskey : Color.cream.opacity(0.07)))
                        }
                        .buttonStyle(PressScaleStyle())
                    }
                }
            }
        }
    }

    // ── the list for that night ──
    private func listSection(_ night: String) -> some View {
        let approved = rows(night, approved: true)
        let pending = rows(night, approved: false)
        let heads = approved.reduce(0) { $0 + $1.total }
        let shown = showPending ? pending : approved
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                toggle("ON THE LIST", count: approved.count, on: !showPending) { showPending = false }
                toggle("PENDING", count: pending.count, on: showPending) { showPending = true }
            }
            BizCard {
                HStack(alignment: .firstTextBaseline) {
                    Text(ListNight.relative(night))
                        .font(.system(size: 22, weight: .black, design: .rounded))
                        .foregroundStyle(Color.cream)
                    Spacer()
                    let date = ListNight.relative(night) == ListNight.label(night) ? "" : "\(ListNight.label(night)) · "
                    Text(date + (showPending ? "\(pending.count) waiting" : "\(approved.count) on the list · \(heads) heads"))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(Color.bronze)
                }
                if shown.isEmpty {
                    Text(showPending ? "Nobody waiting." : "Nobody approved yet — check PENDING.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.55))
                        .padding(.vertical, 6)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { i, r in
                            row(r)
                            if i < shown.count - 1 { Divider().overlay(Color.cream.opacity(0.08)) }
                        }
                    }
                }
                if !showPending && !approved.isEmpty {
                    kicker("DOWNLOAD THE LIST · \(ListNight.label(night).uppercased())")
                    HStack(spacing: 10) {
                        ShareLink(item: GuestListExport.text(bar: barName, night: night, rows: approved)) {
                            exportLabel("SHARE", "square.and.arrow.up")
                        }
                        Button {
                            if let url = GuestListExport.csvFile(bar: barName, night: night, rows: approved) { shareFile = ShareFile(url: url) }
                        } label: { exportLabel("CSV", "tablecells") }
                            .buttonStyle(PressScaleStyle())
                        Button {
                            UIPasteboard.general.string = GuestListExport.text(bar: barName, night: night, rows: approved)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                        } label: { exportLabel(copied ? "COPIED" : "COPY", "doc.on.doc") }
                            .buttonStyle(PressScaleStyle())
                    }
                }
            }
        }
    }

    private func toggle(_ title: String, count: Int, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                Text("\(count)")
                    .foregroundStyle(on ? Color.ink.opacity(0.6) : Color.bronze)
            }
            .font(.system(size: 11, weight: .black, design: .monospaced))
            .tracking(1.4)
            .foregroundStyle(on ? Color.ink : Color.cream.opacity(0.75))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(on ? Color.cream : Color.cream.opacity(0.07)))
        }
        .buttonStyle(PressScaleStyle())
    }

    private func exportLabel(_ title: String, _ icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 12, weight: .bold, design: .rounded))
            Text(title).font(.system(size: 11, weight: .black, design: .monospaced)).tracking(1.4)
        }
        .foregroundStyle(Color.whiskey)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.whiskey.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.whiskey.opacity(0.35), lineWidth: 1))
    }

    private func row(_ r: ListRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(r.headline)
                            .font(.system(size: 16, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color.cream)
                        if r.flag == "favorite" {
                            Image(systemName: "star.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.whiskey)
                        } else if r.flag == "blocked" {
                            Image(systemName: "hand.raised.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.cream.opacity(0.5))
                        }
                    }
                    HStack(spacing: 8) {
                        Text("\(r.total) in total")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.6))
                        InstagramLink(handle: r.instagram, url: r.instagramURL, compact: true)
                    }
                    if let u = r.userUsername {
                        Text("on Sejdel as @\(u)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.bronze)
                    }
                }
                Spacer(minLength: 0)
                flagMenu(r)
            }
            if r.pending {
                HStack(spacing: 8) {
                    smallDecision("APPROVE", filled: true, r) { decide(r, true) }
                    smallDecision("DECLINE", filled: false, r) { decide(r, false) }
                }
            }
        }
        .padding(.vertical, 10)
    }

    /// Star a regular, block a name — Business+; the basic plan sees the pitch.
    private func flagMenu(_ r: ListRequest) -> some View {
        Menu {
            if isPlus {
                if r.flag != "favorite" {
                    Button { setFlag(r.userId, "favorite") } label: { Label("Auto-approve from now on", systemImage: "star.fill") }
                }
                if r.flag != "blocked" {
                    Button(role: .destructive) { setFlag(r.userId, "blocked") } label: { Label("Block", systemImage: "hand.raised.fill") }
                }
                if r.flag != nil {
                    Button { setFlag(r.userId, nil) } label: { Label("Clear", systemImage: "xmark.circle") }
                }
                if r.approved {
                    Button(role: .destructive) { decide(r, false) } label: { Label("Take off the list", systemImage: "minus.circle") }
                }
            } else {
                Button { onUpgrade() } label: { Label("Auto-approve regulars · Business+", systemImage: "star.fill") }
                Button { onUpgrade() } label: { Label("Block names · Business+", systemImage: "hand.raised.fill") }
                if r.approved {
                    Button(role: .destructive) { decide(r, false) } label: { Label("Take off the list", systemImage: "minus.circle") }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.7))
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.cream.opacity(0.07)))
        }
    }

    private func smallDecision(_ title: String, filled: Bool, _ r: ListRequest, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(busy == r.id ? "…" : title)
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(filled ? Color.ink : Color.cream.opacity(0.85))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(filled ? Color.whiskey : Color.cream.opacity(0.08)))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(busy != nil)
    }

    // ── the weekdays you take the list ──
    private var daysCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            kicker("NIGHTS YOU TAKE THE LIST")
            BizCard {
                Text("Guests can only ask for these nights.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.6))
                HStack(spacing: 6) {
                    ForEach(1...7, id: \.self) { d in
                        let on = days.contains(d)
                        Button { toggleDay(d) } label: {
                            Text(ListNight.weekdayNames[d - 1])
                                .font(.system(size: 10, weight: .black, design: .monospaced))
                                .tracking(0.8)
                                .foregroundStyle(on ? Color.ink : Color.cream.opacity(0.7))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? Color.whiskey : Color.cream.opacity(0.07)))
                        }
                        .buttonStyle(PressScaleStyle())
                        .disabled(savingDays)
                    }
                }
                if days.isEmpty {
                    Text("No nights picked — nobody can ask.")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.whiskey)
                }
            }
        }
    }

    private func toggleDay(_ d: Int) {
        var next = days
        if let i = next.firstIndex(of: d) { next.remove(at: i) } else { next.append(d) }
        next.sort()
        let previous = days
        days = next
        savingDays = true
        Task {
            do { try await store.setListDays(business: business, days: next) }
            catch { days = previous; self.error = ListRequestStore.friendly(error) }
            savingDays = false
        }
    }

    // ── regulars & blocked (Business+) ──
    private var regularsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            kicker("REGULARS & BLOCKED")
            BizCard {
                if isPlus {
                    Text("Star a guest and they're on the list the moment they ask. Block one and they're told the list is full. Both from the ⋯ on any name.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                    if !flags.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(flags.enumerated()), id: \.element.id) { i, f in
                                HStack(spacing: 10) {
                                    Image(systemName: f.flag == "favorite" ? "star.fill" : "hand.raised.fill")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(f.flag == "favorite" ? Color.whiskey : Color.cream.opacity(0.5))
                                        .frame(width: 22)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(f.lastName ?? f.name)
                                            .font(.system(size: 15, weight: .heavy, design: .rounded))
                                            .foregroundStyle(Color.cream)
                                        Text([f.instagram.map { "@\($0)" }, f.username.map { "on Sejdel as @\($0)" }].compactMap { $0 }.joined(separator: " · "))
                                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                                            .foregroundStyle(Color.bronze)
                                    }
                                    Spacer(minLength: 0)
                                    Button { setFlag(f.userId, nil) } label: {
                                        Text("CLEAR")
                                            .font(.system(size: 10, weight: .black, design: .monospaced)).tracking(1.2)
                                            .foregroundStyle(Color.cream.opacity(0.7))
                                            .padding(.horizontal, 10).padding(.vertical, 7)
                                            .background(Capsule().fill(Color.cream.opacity(0.08)))
                                    }
                                    .buttonStyle(PressScaleStyle())
                                }
                                .padding(.vertical, 9)
                                if i < flags.count - 1 { Divider().overlay(Color.cream.opacity(0.08)) }
                            }
                        }
                    }
                } else {
                    Text("The list on autopilot.")
                        .font(.system(size: 19, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.cream)
                    Text("Business+ bars star their regulars — approved the moment they ask — and block the names they don't want at the door.")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                    BizPrimaryButton(title: "GO BUSINESS+") { onUpgrade() }
                }
            }
        }
    }

    private func setFlag(_ user: UUID, _ flag: String?) {
        guard isPlus else { onUpgrade(); return }
        error = nil
        Task {
            do { try await store.setFlag(business: business, user: user, flag: flag); await load() }
            catch { self.error = ListRequestStore.friendly(error) }
        }
    }

    private func decide(_ r: ListRequest, _ approve: Bool) {
        busy = r.id; error = nil
        Task {
            do { try await store.decide(r.id, approve: approve); await load() }
            catch { self.error = ListRequestStore.friendly(error) }
            busy = nil
        }
    }

    private func load() async {
        do {
            rows = try await store.list(for: business)
            if isPlus { flags = (try? await store.flags(for: business)) ?? [] }
            if selectedNight == nil { selectedNight = nights.first }
            // Nothing approved yet for the first night: open on the waiting ones.
            if let n = night, rows(n, approved: true).isEmpty, !rows(n, approved: false).isEmpty { showPending = true }
        } catch {
            self.error = ListRequestStore.friendly(error)
        }
        loaded = true
    }
}

/// Plain text for Notes and Messages; CSV for Excel, Numbers and the door
/// systems that import spreadsheets. Always the whole night.
enum GuestListExport {
    static func text(bar: String, night: String, rows: [ListRequest]) -> String {
        var lines = ["\(bar) · The list · \(ListNight.label(night))", ""]
        for (i, r) in rows.enumerated() {
            lines.append("\(i + 1). \(r.headline) (\(r.total)) · @\(r.instagram)")
        }
        let heads = rows.reduce(0) { $0 + $1.total }
        lines.append("")
        lines.append("\(rows.count) on the list · \(heads) heads")
        return lines.joined(separator: "\n")
    }

    static func csv(rows: [ListRequest]) -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var out = ["Night,Name,Plus,Total,Instagram,Status,Requested"]
        for r in rows {
            out.append([q(r.night), q(r.fullName), "\(r.plusCount)", "\(r.total)", q("@" + r.instagram), q(r.status), q(r.createdAt)].joined(separator: ","))
        }
        return out.joined(separator: "\n") + "\n"
    }

    static func csvFile(bar: String, night: String, rows: [ListRequest]) -> URL? {
        let safeBar = bar.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeBar) list \(night).csv")
        // A BOM so Excel reads the UTF-8 names (ö, é) instead of guessing.
        let data = Data([0xEF, 0xBB, 0xBF]) + Data(csv(rows: rows).utf8)
        do { try data.write(to: url, options: .atomic); return url } catch { return nil }
    }
}
