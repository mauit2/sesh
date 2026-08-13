// Direct messages — friend-to-friend chat + story reactions (likes/replies
// land in the recipient's DMs). Extracted from content_view.swift; see
// migration 051 for the schema and RLS.

import SwiftUI
import Combine
import Foundation
import Supabase

// MARK: - Direct messages (migration 051)

struct DMMessage: Codable, Identifiable, Equatable {
    let id: UUID
    let senderId: UUID
    let recipientId: UUID
    let kind: String            // "text" | "story_reply" | "story_like"
    let body: String?
    let storyId: UUID?
    let storyPath: String?
    let createdAt: Date
    var readAt: Date?
    /// Trigger-maintained (migration 096); the incremental poll cursor.
    /// nil only for locally-constructed optimistic rows — the default keeps
    /// the memberwise init unchanged for every optimistic construction site.
    var updatedAt: Date? = nil

    enum CodingKeys: String, CodingKey {
        case id, kind, body
        case senderId = "sender_id"
        case recipientId = "recipient_id"
        case storyId = "story_id"
        case storyPath = "story_path"
        case createdAt = "created_at"
        case readAt = "read_at"
        case updatedAt = "updated_at"
    }

    /// Thumbnail of the story this message reacted to — renders while the
    /// story is still alive (24h), placeholder afterwards.
    var storyURL: URL? {
        guard let storyPath else { return nil }
        return try? supabase.storage.from("stories").getPublicURL(path: storyPath)
    }
}

/// Friend-to-friend chat + story reactions. One flat pull of my recent
/// messages; threads and unread counts derive from it. Sends are
/// optimistic (bubble appears instantly, poll reconciles).
@MainActor
final class DMService: ObservableObject {
    struct ChatThread: Identifiable, Equatable {
        let id: UUID          // the other person's profile id
        let last: DMMessage
        let unread: Int
    }

    @Published private(set) var messages: [DMMessage] = []
    @Published private(set) var profilesById: [UUID: Profile] = [:]
    private var myId: UUID? { supabase.auth.currentUser?.id }
    private var pollTask: Task<Void, Never>?

    var threads: [ChatThread] {
        guard let me = myId else { return [] }
        var byOther: [UUID: [DMMessage]] = [:]
        for m in messages {
            let other = m.senderId == me ? m.recipientId : m.senderId
            byOther[other, default: []].append(m)
        }
        return byOther.compactMap { other, msgs in
            guard let last = msgs.max(by: { $0.createdAt < $1.createdAt }) else { return nil }
            let unread = msgs.filter { $0.recipientId == me && $0.readAt == nil }.count
            return ChatThread(id: other, last: last, unread: unread)
        }
        .sorted { $0.last.createdAt > $1.last.createdAt }
    }

    var totalUnread: Int {
        guard let me = myId else { return 0 }
        return messages.filter { $0.recipientId == me && $0.readAt == nil }.count
    }

    func messages(with other: UUID) -> [DMMessage] {
        guard let me = myId else { return [] }
        return messages
            .filter {
                ($0.senderId == other && $0.recipientId == me)
                    || ($0.senderId == me && $0.recipientId == other)
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                // 20s — new DMs also push, so this just keeps an open thread
                // reasonably fresh without hammering the API all day.
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        messages = []
    }

    /// High-water mark of dm_messages.updated_at we've seen. The poll asks
    /// only for rows newer than this, so an idle 20 s tick costs a few bytes
    /// instead of re-downloading the whole 500-message window — which it did,
    /// three times a minute, for every user with the app open (096).
    private var syncedTo: Date?

    func refresh() async {
        guard let me = myId else { return }
        let mine = me.uuidString.lowercased()
        do {
            let changed: [DMMessage]
            if let since = syncedTo, !messages.isEmpty {
                // ISO cursor carries milliseconds against Postgres' micros —
                // rounds DOWN, so the worst case is refetching one already-
                // merged row, never missing one. Same contract as 088.
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                changed = try await supabase.from("dm_messages")
                    .select()
                    .or("sender_id.eq.\(mine),recipient_id.eq.\(mine)")
                    .gt("updated_at", value: iso.string(from: since))
                    .order("updated_at", ascending: true)
                    .limit(500)
                    .execute()
                    .value
                if !changed.isEmpty {
                    // Merge by id: read receipts arrive as updates to rows we
                    // already hold, new messages as fresh ids.
                    var byId = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
                    for m in changed { byId[m.id] = m }
                    messages = byId.values.sorted { $0.createdAt < $1.createdAt }
                }
            } else {
                let rows: [DMMessage] = try await supabase.from("dm_messages")
                    .select()
                    .or("sender_id.eq.\(mine),recipient_id.eq.\(mine)")
                    .order("created_at", ascending: false)
                    .limit(500)
                    .execute()
                    .value
                messages = rows.reversed()
                changed = rows
            }
            if let top = changed.compactMap(\.updatedAt).max() {
                syncedTo = max(syncedTo ?? .distantPast, top)
            }

            let partners = Set(changed.map { $0.senderId == me ? $0.recipientId : $0.senderId })
                .subtracting(profilesById.keys)
            if !partners.isEmpty {
                let ps: [Profile] = try await supabase
                    .from("profiles")
                    .select()
                    .in("id", values: partners.map { $0.uuidString.lowercased() })
                    .execute()
                    .value
                for p in ps { profilesById[p.id] = p }
            }
        } catch {
            // Transient — next poll recovers.
        }
    }

    private struct InsertRow: Encodable {
        let sender_id: String
        let recipient_id: String
        let kind: String
        let body: String?
        let story_id: String?
        let story_path: String?
    }

    private func insert(_ row: InsertRow, optimistic: DMMessage) async {
        messages.append(optimistic)
        _ = try? await supabase.from("dm_messages").insert(row).execute()
        // The optimistic row carries a LOCAL id; the server assigns its own.
        // The old full-array refresh replaced it wholesale, but the
        // incremental merge (096) keeps unknown ids — so drop the stand-in
        // explicitly before the refetch brings in the real row.
        messages.removeAll { $0.id == optimistic.id }
        await refresh()
    }

    func send(text: String, to other: UUID) async {
        guard let me = myId else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await insert(
            InsertRow(sender_id: me.uuidString.lowercased(),
                      recipient_id: other.uuidString.lowercased(),
                      kind: "text", body: trimmed, story_id: nil, story_path: nil),
            optimistic: DMMessage(id: UUID(), senderId: me, recipientId: other,
                                  kind: "text", body: trimmed, storyId: nil,
                                  storyPath: nil, createdAt: Date(), readAt: nil)
        )
    }

    func sendStoryReply(_ text: String, story: LiveStory) async {
        guard let me = myId, story.profileId != me else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await insert(
            InsertRow(sender_id: me.uuidString.lowercased(),
                      recipient_id: story.profileId.uuidString.lowercased(),
                      kind: "story_reply", body: trimmed,
                      story_id: story.id.uuidString.lowercased(),
                      story_path: story.storagePath),
            optimistic: DMMessage(id: UUID(), senderId: me, recipientId: story.profileId,
                                  kind: "story_reply", body: trimmed, storyId: story.id,
                                  storyPath: story.storagePath, createdAt: Date(), readAt: nil)
        )
    }

    func sendStoryLike(story: LiveStory) async {
        guard let me = myId, story.profileId != me else { return }
        await insert(
            InsertRow(sender_id: me.uuidString.lowercased(),
                      recipient_id: story.profileId.uuidString.lowercased(),
                      kind: "story_like", body: nil,
                      story_id: story.id.uuidString.lowercased(),
                      story_path: story.storagePath),
            optimistic: DMMessage(id: UUID(), senderId: me, recipientId: story.profileId,
                                  kind: "story_like", body: nil, storyId: story.id,
                                  storyPath: story.storagePath, createdAt: Date(), readAt: nil)
        )
    }

    /// Opening a thread clears its unread state (both locally and up).
    func markRead(with other: UUID) async {
        guard let me = myId else { return }
        for i in messages.indices
        where messages[i].senderId == other && messages[i].recipientId == me && messages[i].readAt == nil {
            messages[i].readAt = Date()
        }
        struct Patch: Encodable { let read_at: String }
        _ = try? await supabase.from("dm_messages")
            .update(Patch(read_at: ISO8601DateFormatter().string(from: Date())))
            .eq("sender_id", value: other.uuidString.lowercased())
            .eq("recipient_id", value: me.uuidString.lowercased())
            .is("read_at", value: nil)
            .execute()
    }
}

/// Threads list — one row per friend you've chatted with, plus a compose
/// button to start a fresh conversation with any friend.
struct ChatsView: View {
    @ObservedObject var dm: DMService
    @ObservedObject var friends: FriendsService
    @ObservedObject var feed: FeedService
    let profile: Profile

    @State private var openThread: UUID?
    @State private var composeOpen = false

    var body: some View {
        NavigationStack {
            ZStack {
                // NavigationStack paints its own opaque backdrop, which
                // cut the shared atmosphere off with a hard edge — give
                // this page its own copy so the glow continues like on
                // every other tab.
                AtmosphereBackground(accent: .whiskey)
                chatsContent
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $openThread) { other in
                ChatThreadView(dm: dm, feed: feed, profile: profile, other: other,
                               fallbackName: friends.friends.first(where: { $0.id == other })?.name)
            }
            .sheet(isPresented: $composeOpen) {
                NewChatPicker(friends: friends) { friendId in
                    composeOpen = false
                    openThread = friendId
                }
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(Color.ink)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var chatsContent: some View {
            VStack(alignment: .leading, spacing: 12) {
                // No big "Chats" title — the tab bar already says where
                // you are. Just a quiet label + the compose button.
                HStack {
                    SectionLabel("Conversations")
                    Spacer()
                    Button {
                        composeOpen = true
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.whiskey.opacity(0.12))
                                .frame(width: 34, height: 34)
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.whiskey)
                        }
                        .overlay(Circle().strokeBorder(Color.whiskey.opacity(0.3), lineWidth: 1))
                    }
                    .buttonStyle(PressScaleStyle())
                    .accessibilityLabel("New chat")
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)

                if dm.threads.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 28, design: .rounded))
                            .foregroundStyle(Color.bronze)
                        Text("No chats yet")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.cream)
                        Text("Reply to a friend's story, or start one fresh with the pen.")
                            .font(.system(size: 12.5, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.bronze)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                        Spacer()
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 8) {
                            ForEach(dm.threads) { thread in
                                Button {
                                    openThread = thread.id
                                } label: {
                                    threadRow(thread)
                                }
                                .buttonStyle(PressScaleStyle())
                            }
                        }
                        .padding(.horizontal, 22)
                        .padding(.top, 2)
                        .padding(.bottom, 80)
                    }
                }
            }
    }

    private func threadRow(_ thread: DMService.ChatThread) -> some View {
        let p = dm.profilesById[thread.id]
        return HStack(spacing: 12) {
            AvatarView(
                urlString: p?.avatarURL,
                initial: String((p?.name ?? "?").prefix(1)).uppercased(),
                size: 44
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(p?.name ?? "Friend")
                    .font(.system(size: 15, weight: thread.unread > 0 ? .heavy : .semibold, design: .rounded))
                    .foregroundStyle(Color.cream)
                Text(previewLine(thread.last))
                    .font(.system(size: 12, weight: thread.unread > 0 ? .semibold : .regular, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(thread.unread > 0 ? 0.85 : 0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(timeAgoShort(thread.last.createdAt))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.bronze)
                if thread.unread > 0 {
                    Text("\(thread.unread)")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundStyle(Color.ink)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Circle().fill(Color.whiskey))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.inkElev)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(
                            thread.unread > 0 ? Color.whiskey.opacity(0.3) : Color.cream.opacity(0.06),
                            lineWidth: 1
                        )
                )
        )
        .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
    }

    private func previewLine(_ m: DMMessage) -> String {
        let mine = m.senderId == profile.id
        switch m.kind {
        case "story_like":  return mine ? "You liked their story ❤️" : "Liked your story ❤️"
        case "story_reply": return (mine ? "You: " : "") + "↩︎ " + (m.body ?? "")
        default:            return (mine ? "You: " : "") + (m.body ?? "")
        }
    }
}

/// Pick a friend to start a brand-new conversation with — searchable by
/// name or @username.
private struct NewChatPicker: View {
    @ObservedObject var friends: FriendsService
    var onPick: (UUID) -> Void

    @State private var query = ""

    private var filtered: [Friend] {
        var q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while q.hasPrefix("@") { q.removeFirst() }
        guard !q.isEmpty else { return friends.friends }
        return friends.friends.filter { f in
            f.name.lowercased().contains(q)
                || (f.username?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel("New chat")
                    Text("Message a friend")
                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.cream)
                }
                .padding(.top, 22)

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.bronze)
                    TextField(
                        "", text: $query,
                        prompt: Text("Search name or @username")
                            .foregroundColor(Color.cream.opacity(0.35))
                    )
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream)
                        .tint(Color.whiskey)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.inkElev)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.cream.opacity(0.1), lineWidth: 1)
                )

                if friends.friends.isEmpty {
                    Text("Add friends first — they'll show up here.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.bronze)
                } else if filtered.isEmpty {
                    Text("No friend matches \"\(query)\".")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.bronze)
                }

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(filtered) { f in
                            Button {
                                onPick(f.id)
                            } label: {
                                HStack(spacing: 12) {
                                    AvatarView(
                                        urlString: f.avatarURL,
                                        initial: String(f.name.prefix(1)).uppercased(),
                                        size: 40
                                    )
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(f.name)
                                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                                            .foregroundStyle(Color.cream)
                                        if let u = f.username {
                                            Text("@\(u)")
                                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                                .foregroundStyle(Color.bronze)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                        .foregroundStyle(Color.bronze)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(Color.cream.opacity(0.03))
                                )
                            }
                            .buttonStyle(PressScaleStyle())
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
            .padding(.horizontal, 22)
        }
        .preferredColorScheme(.dark)
    }
}

/// One conversation — bubbles + composer, IG-style story context chips.
struct ChatThreadView: View {
    @ObservedObject var dm: DMService
    @ObservedObject var feed: FeedService
    let profile: Profile
    let other: UUID
    /// Name shown before the profile hydrates (fresh conversations).
    var fallbackName: String? = nil

    @State private var draft = ""
    @State private var openProfile: ProfileRef?
    @FocusState private var composerFocused: Bool

    private var otherProfile: Profile? { dm.profilesById[other] }
    private var otherRef: ProfileRef {
        ProfileRef(id: other, name: otherProfile?.name ?? fallbackName ?? "Chat",
                   username: otherProfile?.username, avatar: otherProfile?.avatarURL)
    }

    var body: some View {
        ZStack {
            AtmosphereBackground(accent: .whiskey)
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 6) {
                            if dm.messages(with: other).isEmpty {
                                Text("No messages yet — say hej 🍻")
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.bronze)
                                    .padding(.top, 40)
                            }
                            ForEach(dm.messages(with: other)) { m in
                                bubble(m)
                                    .id(m.id)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .contentShape(Rectangle())
                        // Tap the conversation area to drop the keyboard.
                        .onTapGesture { composerFocused = false }
                    }
                    // Drag the messages to dismiss the keyboard, IG-style.
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: dm.messages(with: other).count) { _, _ in
                        if let last = dm.messages(with: other).last {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                    .onAppear {
                        if let last = dm.messages(with: other).last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }

                HStack(spacing: 10) {
                    TextField(
                        "", text: $draft,
                        prompt: Text("Message…").foregroundColor(Color.cream.opacity(0.35)),
                        axis: .vertical
                    )
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream)
                        .lineLimit(1...4)
                        .focused($composerFocused)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.cream.opacity(0.06)))
                    Button {
                        let text = draft
                        draft = ""
                        let t: Task<Void, Never> = Task {
                            await dm.send(text: text, to: other)
                        }
                        _ = t
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .black, design: .rounded))
                            .foregroundStyle(Color.ink)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Color.whiskey))
                    }
                    .buttonStyle(PressScaleStyle())
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.inkElev)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.ink, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            // Tappable name/avatar → the friend's profile feed.
            ToolbarItem(placement: .principal) {
                Button {
                    openProfile = otherRef
                } label: {
                    HStack(spacing: 7) {
                        AvatarView(
                            urlString: otherProfile?.avatarURL,
                            initial: String((otherProfile?.name ?? fallbackName ?? "?").prefix(1)).uppercased(),
                            size: 26
                        )
                        Text(otherProfile?.name ?? fallbackName ?? "Chat")
                            .font(.system(size: 16, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color.cream)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(item: $openProfile) { ref in
            ProfileFeedView(user: ref, feed: feed)
                .presentationBackground(Color.ink)
        }
        .onAppear {
            let t: Task<Void, Never> = Task { await dm.markRead(with: other) }
            _ = t
        }
        .onChange(of: dm.totalUnread) { _, _ in
            let t: Task<Void, Never> = Task { await dm.markRead(with: other) }
            _ = t
        }
    }

    @ViewBuilder
    private func bubble(_ m: DMMessage) -> some View {
        let mine = m.senderId == profile.id
        HStack {
            if mine { Spacer(minLength: 48) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                // Story context chip for reactions/replies.
                if m.kind != "text" {
                    HStack(spacing: 6) {
                        if let url = m.storyURL {
                            DownsampledAsyncImage(url: url, targetPoints: 44, placeholder: Color.smoke)
                                .frame(width: 30, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        Text(m.kind == "story_like"
                             ? (mine ? "You liked their story" : "Liked your story")
                             : (mine ? "You replied to their story" : "Replied to your story"))
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.bronze)
                    }
                }
                if m.kind == "story_like" {
                    Text("❤️")
                        .font(.system(size: 30, design: .rounded))
                } else if let body = m.body {
                    Text(body)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(mine ? Color.ink : Color.cream)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(mine ? Color.whiskey : Color.cream.opacity(0.08))
                        )
                }
                Text(timeAgoShort(m.createdAt))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.cream.opacity(0.35))
            }
            if !mine { Spacer(minLength: 48) }
        }
    }
}

/// "2m" / "3h" / "2d" — compact chat timestamps.
private func timeAgoShort(_ date: Date) -> String {
    let s = Int(Date().timeIntervalSince(date))
    if s < 60 { return "now" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86_400 { return "\(s / 3600)h" }
    return "\(s / 86_400)d"
}
