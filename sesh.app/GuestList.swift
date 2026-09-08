// The guest list. DM a bar, tap "Get on the list", and the bar gets a
// request card in the chat — full name, +N, Instagram, which night. Approved
// names land on the bar's list (☰ → Guest list), ready to share as text or
// export as CSV for the door. Migration 123.

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

// MARK: - Model

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

    enum CodingKeys: String, CodingKey {
        case id, instagram, night, status
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
    /// "TONIGHT" / "WED 9"
    static func chip(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return "TONIGHT" }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "EEE d"
        return f.string(from: d).uppercased()
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

    enum ListError: Error { case code(String) }

    static func friendly(_ error: Error) -> String {
        let s = String(describing: error)
        func has(_ c: String) -> Bool { s.contains(c) }
        if has("already_requested") { return "You've already asked for that night — the bar hasn't answered yet." }
        if has("not_on_sejdel")     { return "This bar isn't on Sejdel right now." }
        if has("name_required")     { return "Add your full name." }
        if has("instagram_required") { return "Add your Instagram handle." }
        if has("bad_night")         { return "Pick a night from tonight on." }
        if has("bad_party")         { return "Up to +50." }
        if has("own_bar")           { return "That's your own bar." }
        if has("not_yours")         { return "Only the bar can decide this." }
        return "Couldn't send that. Try again."
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
    @State private var night = Calendar.current.startOfDay(for: Date())
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

    private var nights: [Date] {
        let today = Calendar.current.startOfDay(for: Date())
        return (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: today) }
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
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(nights, id: \.self) { d in
                                    let on = Calendar.current.isDate(d, inSameDayAs: night)
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
    }

    private var canSend: Bool {
        fullName.trimmingCharacters(in: .whitespaces).count >= 2 && !instagram.trimmingCharacters(in: .whitespaces).isEmpty
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
        guard canSend else { return }
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
                    Text("GET ON THE LIST · \(r.nightLabel.uppercased())")
                }
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(Color.whiskey)
                Text(r.headline)
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.cream)
                Text(r.plusCount == 0 ? "Just them" : "\(r.total) in total")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.6))
                Link(destination: r.instagramURL) {
                    HStack(spacing: 6) {
                        Image(systemName: "camera.circle.fill")
                        Text("@\(r.instagram)")
                        Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold))
                    }
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Capsule().fill(Color.cream.opacity(0.08)))
                }
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

/// ☰ → Guest list. Every night that has requests, pending ones first so they
/// can be decided here too; approved names go out as text or CSV.
struct GuestListBody: View {
    let business: UUID
    let barName: String
    @ObservedObject private var store = ListRequestStore.shared
    @State private var rows: [ListRequest] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var busy: UUID?
    @State private var copied: String?
    @State private var csvFiles: [String: URL] = [:]

    private var nights: [String] {
        var seen: [String] = []
        for r in rows where !seen.contains(r.night) { seen.append(r.night) }
        return seen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !loaded {
                ProgressView().tint(Color.whiskey).frame(maxWidth: .infinity).padding(.vertical, 30)
            } else if rows.isEmpty {
                BizCard {
                    Text("No one on the list yet.")
                        .font(.system(size: 19, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.cream)
                    Text("Guests ask from your chat — the 🎟 Get on the list button. Say yes there or here, and the names line up below, ready to share with the door.")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ForEach(nights, id: \.self) { night in nightSection(night) }
            }
            ErrorLine(text: error)
        }
        .task { await load() }
    }

    private func nightSection(_ night: String) -> some View {
        let all = rows.filter { $0.night == night }
        let approved = all.filter(\.approved)
        let heads = approved.reduce(0) { $0 + $1.total }
        return VStack(alignment: .leading, spacing: 10) {
            kicker("\(ListNight.label(night).uppercased()) · \(approved.count) ON THE LIST · \(heads) HEADS")
            BizCard {
                VStack(spacing: 0) {
                    ForEach(Array(all.enumerated()), id: \.element.id) { i, r in
                        row(r)
                        if i < all.count - 1 { Divider().overlay(Color.cream.opacity(0.08)) }
                    }
                }
                if !approved.isEmpty {
                    HStack(spacing: 10) {
                        ShareLink(item: GuestListExport.text(bar: barName, night: night, rows: approved)) {
                            exportLabel("SHARE", "square.and.arrow.up")
                        }
                        if let url = csvFiles[night] {
                            ShareLink(item: url, preview: SharePreview(url.lastPathComponent)) {
                                exportLabel("CSV", "tablecells")
                            }
                        }
                        Button {
                            UIPasteboard.general.string = GuestListExport.text(bar: barName, night: night, rows: approved)
                            copied = night
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if copied == night { copied = nil } }
                        } label: {
                            exportLabel(copied == night ? "COPIED" : "COPY", "doc.on.doc")
                        }
                        .buttonStyle(PressScaleStyle())
                    }
                    .padding(.top, 4)
                }
            }
        }
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
                VStack(alignment: .leading, spacing: 3) {
                    Text(r.headline)
                        .font(.system(size: 16, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.cream)
                    HStack(spacing: 8) {
                        Text("\(r.total) in total")
                        Link(destination: r.instagramURL) {
                            Text("@\(r.instagram) ↗").underline()
                        }
                    }
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.6))
                    if let u = r.userUsername {
                        Text("on Sejdel as @\(u)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.bronze)
                    }
                }
                Spacer(minLength: 0)
                if !r.pending { ListStatusPill(status: r.status) }
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
            var files: [String: URL] = [:]
            for night in nights {
                let approved = rows.filter { $0.night == night && $0.approved }
                if !approved.isEmpty, let url = GuestListExport.csvFile(bar: barName, night: night, rows: approved) { files[night] = url }
            }
            csvFiles = files
        } catch {
            self.error = ListRequestStore.friendly(error)
        }
        loaded = true
    }
}

/// Plain text for Notes and Messages; CSV for Excel, Numbers and the door
/// systems that import spreadsheets.
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
