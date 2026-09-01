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
import UserNotifications

// MARK: - Secrets (replace with your values)

enum Secrets {
    static let supabaseURL = URL(string: "https://lltuozmbxacxiepardys.supabase.co")!
    static let supabaseAnonKey = "sb_publishable_CXlmRXTLRfX0pYysE7vbKw_vC88ny42"
    /// Mapbox PUBLIC token — renders the Sun mode's map. The secret-scoped
    /// download token is a different thing entirely and lives only in a
    /// developer's ~/.netrc, never here.
    ///
    /// Read at runtime from MapboxToken.txt, which is gitignored. The token is
    /// public by design — it ships inside the built app — but committing it lets
    /// it be scraped off GitHub and spent against our tile quota, and GitHub's
    /// push protection blocks it outright. Missing file just means Sun mode's
    /// map won't render; drop your own pk. token in there.
    static let mapboxPublicToken: String = {
        guard let url = Bundle.main.url(forResource: "MapboxToken", withExtension: "txt"),
              let raw = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }()
}

let supabase = SupabaseClient(
    supabaseURL: Secrets.supabaseURL,
    supabaseKey: Secrets.supabaseAnonKey
)

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
                // 45s: this fires THREE RPCs a tick (friends, requests,
                // activity) — all of which also arrive via push, so the
                // in-app refresh only needs to keep an open screen current.
                try? await Task.sleep(nanoseconds: 45_000_000_000)
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

    @discardableResult
    func add(_ option: DrinkOption, at consumedAt: Date = Date()) -> UUID {
        if startedAt == nil { startedAt = consumedAt }
        let d = LiveDrink(option: option, consumedAt: consumedAt)
        drinks.append(d)
        save()
        return d.id
    }

    /// Rewrite when a drink was consumed — the pace prompt's spread. The
    /// struct is immutable by design, so the entry is rebuilt in place;
    /// re-sorting keeps the timeline (and the chronological BAC walk,
    /// which assumes order) honest after stamps move backwards.
    func restamp(_ id: UUID, to date: Date) {
        guard let i = drinks.firstIndex(where: { $0.id == id }) else { return }
        let old = drinks[i]
        drinks[i] = LiveDrink(id: old.id, option: old.option(), consumedAt: date)
        drinks.sort { $0.consumedAt < $1.consumedAt }
        if let first = drinks.first, let started = startedAt, first.consumedAt < started {
            startedAt = first.consumedAt
        }
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
    /// `overriding` substitutes hypothetical consumed-times by drink id —
    /// the pace card's live preview runs THIS function, so what it shows
    /// is exactly what applying would produce, by construction.
    func bac(profile: Profile, now: Date = Date(), overriding: [UUID: Date] = [:]) -> Double {
        let bodyGrams = profile.weightKg * 1000
        let denom = bodyGrams * profile.sex.r
        guard denom > 0 else { return 0 }
        let sorted = drinks
            .map { d in overriding[d.id].map { LiveDrink(id: d.id, option: d.option(), consumedAt: $0) } ?? d }
            .sorted { $0.consumedAt < $1.consumedAt }
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

    /// Append a batch of pre-built ghosts in one shot (one persist + one
    /// sync) — used by the "add several" quick path.
    func addMany(_ newMembers: [GhostMember]) {
        guard !newMembers.isEmpty else { return }
        members.append(contentsOf: newMembers)
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
                        .font(.system(size: 12, weight: .black, design: .rounded))
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
                                .font(.system(size: 32, weight: .light, design: .rounded))
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
                    .font(.system(size: 16, weight: .bold, design: .rounded))
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
                            .font(.system(size: 14, weight: .bold, design: .rounded))
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
                        .font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(Color.bronze)
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
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold, design: .rounded))
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
                            .font(.system(size: 11, weight: .black, design: .rounded))
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

// MARK: - Friends

/// Small round avatar: remote image if present, else a tinted initial.
struct FriendAvatar: View {
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
    /// Timeline service — so tapping a friend opens their posted nights.
    @ObservedObject var feed: FeedService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var moderation = ModerationService()

    @State private var query = ""
    @State private var results: [UserSearchHit] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var banner: String?
    @State private var showUsernameEditor = false
    /// Tapped friend → their profile feed (past nights).
    @State private var openProfile: ProfileRef?
    /// Contacts + invite-link flow, shared with onboarding.
    @State private var crewOpen = false

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
                    .font(.system(size: 13, weight: .bold, design: .rounded))
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
        .sheet(item: $openProfile) { ref in
            ProfileFeedView(user: ref, feed: feed)
                .presentationBackground(Color.ink)
        }
        .sheet(isPresented: $crewOpen) {
            FindCrewSheet(
                friends: friends,
                inviteURL: URL(string: "https://sejdel.com/")!,
                kicker: "GROW THE CREW",
                title: "Find your people",
                blurb: "Check which of your contacts are already here, or send anyone an invite.",
                dismissLabel: "Done"
            ) {
                crewOpen = false
                Task { await friends.refresh() }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.ink)
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
                    .font(.system(size: 15, weight: .bold, design: .rounded))
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
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold, design: .rounded))
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
                        placeholder: "search username", autocapitalize: false,
                        prefix: "@")
            if let banner {
                Text(banner)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.8))
            }
            // The same contacts + invite flow onboarding uses. Reachable
            // forever here, because "add friends" is a thing people come
            // back to — not a one-shot at signup.
            Button { crewOpen = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "person.2.badge.plus")
                        .font(.system(size: 15, weight: .bold))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Invite friends from contacts")
                            .font(.system(size: 14, weight: .heavy, design: .rounded))
                        Text("Scrambled codes only — your contacts stay on your phone")
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .opacity(0.72)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .opacity(0.5)
                }
                .foregroundStyle(Color.ink)
                .padding(.horizontal, 13).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.whiskey))
            }
            .buttonStyle(PressScaleStyle())
            .padding(.top, 4)
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
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold, design: .rounded))
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
                    Button {
                        openProfile = ProfileRef(
                            id: friend.id, name: friend.name,
                            username: friend.username, avatar: friend.avatarURL
                        )
                    } label: {
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
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.bronze)
                        }
                        .padding(.vertical, 8).padding(.horizontal, 12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.cream.opacity(0.04)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScaleStyle())
                    .contextMenu {
                        Button(role: .destructive) {
                            Task { await friends.remove(userId: friend.id) }
                        } label: { Label("Remove friend", systemImage: "person.badge.minus") }
                        Menu {
                            ForEach(ModerationService.reasons, id: \.self) { reason in
                                Button(reason) {
                                    Task {
                                        await moderation.report(
                                            kind: "user", targetId: friend.id,
                                            offender: friend.id, reason: reason
                                        )
                                    }
                                }
                            }
                        } label: { Label("Report user", systemImage: "flag") }
                        Button(role: .destructive) {
                            Task {
                                await moderation.block(friend.id)
                                await friends.refresh()
                            }
                        } label: { Label("Block user", systemImage: "hand.raised") }
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
                            placeholder: "yourname", autocapitalize: false,
                            prefix: "@")
                Text("3–20 characters · lowercase letters, numbers, underscore")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.5))
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Status.drunk.color)
                }
                Button { save() } label: {
                    HStack {
                        if saving { ProgressView().tint(Color.ink); Spacer() }
                        else {
                            Text("SAVE").font(.system(size: 13, weight: .bold, design: .monospaced)).tracking(3)
                            Spacer()
                            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold, design: .rounded))
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
                                placeholder: "search username", autocapitalize: false,
                                prefix: "@")

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
                        Image(systemName: "paperplane.fill").font(.system(size: 12, weight: .bold, design: .rounded))
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
                        .font(.system(size: 18, design: .rounded))
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

enum RelativeTime {
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

func recapStopEmoji(_ kind: RecapStopKind) -> String {
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
struct FriendsPulseStrip: View {
    @ObservedObject var pulse: FriendsPulseService
    @ObservedObject var stories: StoriesService
    @ObservedObject var dm: DMService
    @ObservedObject var feed: FeedService
    let profile: Profile
    /// My BAC / location / drink tally at the moment of posting (nil =
    /// nothing to stamp).
    let storyBAC: () -> Double?
    let storyStamp: () -> String?
    let storyProof: () -> String?
    let onOpen: (FriendPulse) -> Void

    /// One cover hosts the whole camera→composer journey (no flicker).
    @State private var flowOpen = false
    /// Pre-picked roll photo (no-camera devices) — flow skips the camera.
    @State private var flowImage: Data? = nil
    @State private var libraryOpen = false
    @State private var pickerItem: PhotosPickerItem? = nil
    @State private var viewerCtx: StoryViewerContext? = nil
    /// Snap-Map-style friends map (check-in pins), opened from the header.
    @State private var mapOpen = false

    /// Friends broadcasting a live check-in location right now — the pins on
    /// the friends map, and the gate for showing the map button at all.
    private var checkedInPulses: [FriendPulse] {
        pulse.pulses.filter { $0.live && $0.venueCoordinate != nil }
    }

    /// Who's on the carousel, in what order: story-posters first, newest
    /// story leftmost; then friends who are live without a story (drunkest
    /// first). Friends with neither don't appear at all — TONIGHT shows
    /// what's happening tonight, not the whole address book.
    private var displayPulses: [FriendPulse] {
        func newestStory(_ id: UUID) -> Date? {
            stories.stories(for: id).map(\.createdAt).max()
        }
        // People with UNSEEN stories come first, then the ones you've
        // already watched — each half ordered by story recency.
        let posters = pulse.pulses
            .compactMap { p -> (FriendPulse, Date, Bool)? in
                guard let d = newestStory(p.id) else { return nil }
                return (p, d, stories.hasUnseenStories(p.id))
            }
            .sorted { a, b in
                if a.2 != b.2 { return a.2 }
                return a.1 > b.1
            }
            .map(\.0)
        let liveOnly = pulse.pulses
            .filter { $0.live && newestStory($0.id) == nil }
            .sorted { ($0.bac ?? 0) > ($1.bac ?? 0) }
        return posters + liveOnly
    }

    /// Everyone in the carousel who has stories, chunked per person in
    /// display order, opened at the tapped person — so the viewer can
    /// walk story→story and person→person like Instagram.
    private func storyContext(startingAt id: UUID) -> StoryViewerContext? {
        let withStories = displayPulses.filter { !stories.stories(for: $0.id).isEmpty }
        guard let start = withStories.firstIndex(where: { $0.id == id }) else { return nil }
        let people = withStories.map { p in
            StoryViewerContext.Person(
                stories: stories.stories(for: p.id),
                name: p.name,
                avatarUrl: p.avatarUrl,
                canDelete: false
            )
        }
        return StoryViewerContext(people: people, startPerson: start)
    }

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
                    // Snap-Map-style bubble — a live map thumbnail right in the
                    // strip, like Instagram's "Map". Always present so the map
                    // is one tap away (it shows its own empty state).
                    MapPulseBubble(pulses: checkedInPulses) { mapOpen = true }
                    ForEach(displayPulses) { p in
                        let theirStories = stories.stories(for: p.id)
                        PulseAvatar(
                            pulse: p,
                            hasStory: !theirStories.isEmpty,
                            seen: !theirStories.isEmpty && !stories.hasUnseenStories(p.id)
                        )
                            .onTapGesture {
                                if !theirStories.isEmpty {
                                    viewerCtx = storyContext(startingAt: p.id)
                                } else if p.live {
                                    onOpen(p)
                                }
                            }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 2)
            }
            // Soft edges instead of hard clips. Two parts:
            //  • scrollClipDisabled lets the story-ring GLOW spill outside
            //    the scroll bounds instead of being sliced into a box at
            //    the strip's top/bottom;
            //  • the horizontal gradient mask fades avatars out at the
            //    screen edges. The mask is inflated vertically so it never
            //    re-clips the freed glow.
            .scrollClipDisabled()
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black, location: 0.03),
                        .init(color: .black, location: 0.88),
                        .init(color: .clear, location: 1.0),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
                .padding(.vertical, -32)
            )
        }
        .fullScreenCover(isPresented: $flowOpen, onDismiss: { flowImage = nil }) {
            StoryFlowView(
                initialImage: flowImage,
                bac: storyBAC(),
                stamp: storyStamp(),
                drinkProof: storyProof(),
                onPost: { flattenedImage, bac, stamp in
                    flowOpen = false
                    Task { await stories.post(imageData: flattenedImage, caption: nil, bac: bac, stamp: stamp) }
                },
                onCancel: { flowOpen = false }
            )
        }
        .photosPicker(isPresented: $libraryOpen, selection: $pickerItem, matching: .images)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    flowImage = data
                    flowOpen = true
                }
                pickerItem = nil
            }
        }
        .fullScreenCover(item: $viewerCtx) { ctx in
            StoryViewer(
                ctx: ctx,
                svc: stories,
                dm: dm,
                feed: feed,
                onDelete: { story in Task { await stories.delete(story) } },
                onClose: { viewerCtx = nil }
            )
        }
        .fullScreenCover(isPresented: $mapOpen) {
            FriendsMapView(pulses: checkedInPulses, feed: feed, dm: dm, me: profile)
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
                                people: [.init(
                                    stories: mine, name: profile.name,
                                    avatarUrl: profile.avatarURL, canDelete: true
                                )],
                                startPerson: 0
                            )
                        }
                    }
                Button(action: openCapture) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .black, design: .rounded))
                        .foregroundStyle(Color.ink)
                        .frame(width: 25, height: 25)
                        .background(Circle().fill(Color.whiskey))
                        .overlay(Circle().strokeBorder(Color.ink, lineWidth: 2.5))
                        // Invisible padding enlarges the tap target well beyond
                        // the visible badge so it's easy to hit.
                        .padding(8)
                        .contentShape(Circle())
                }
                .buttonStyle(PressScaleStyle())
                .offset(x: 12, y: 12)
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
        if SeshCameraView.isAvailable {
            flowImage = nil
            flowOpen = true
        } else {
            libraryOpen = true
        }
    }
}

/// Snap-Map-style friends map: an avatar pin at every friend who's checked
/// in tonight. Friends only appear here while they're LIVE *and* have
/// location-sharing switched on (they stop broadcasting a venue otherwise),
/// so the map only ever shows people who opted in. Tap a pin to open their
/// live-sesh sheet. Reached from the TONIGHT strip.
struct FriendsMapView: View {
    /// Friends broadcasting a venue coordinate right now.
    let pulses: [FriendPulse]
    /// Services so a tapped pin's sheet can open their profile / a chat.
    @ObservedObject var feed: FeedService
    @ObservedObject var dm: DMService
    let me: Profile
    @Environment(\.dismiss) private var dismiss
    @State private var camera: MapCameraPosition
    @State private var selected: FriendPulse?
    /// The friend the camera is parked on (chip row highlight). nil when the
    /// view is framing everyone at once.
    @State private var focused: UUID?
    /// Anonymous "where's it hot" layer (venue_heat RPC — bands, never counts).
    @StateObject private var heat = HeatService()
    @State private var selectedHeatID: String?

    /// City-level zoom used both for a lone friend and when flying to one.
    private static let citySpan = MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
    /// If the crew is spread wider than this (≈ a metro area) we DON'T fit
    /// them all — the midpoint would land in the middle of nowhere (an ocean,
    /// for two friends in different countries) and both pins would shrink to
    /// specks. Instead we open on one friend at city zoom; the chip row flies
    /// you to the rest.
    private static let fitThreshold: CLLocationDegrees = 1.2

    init(pulses: [FriendPulse], feed: FeedService, dm: DMService, me: Profile) {
        self.pulses = pulses
        self.feed = feed
        self.dm = dm
        self.me = me
        let plan = Self.initialPlan(for: pulses)
        _camera = State(initialValue: plan.camera)
        _focused = State(initialValue: plan.focus)
    }

    private struct CameraPlan { let camera: MapCameraPosition; let focus: UUID? }

    /// Decide the opening shot: fit the whole crew when they're close, else
    /// open tight on the first friend and rely on the chip row for the others.
    private static func initialPlan(for pulses: [FriendPulse]) -> CameraPlan {
        let located = pulses.filter { $0.venueCoordinate != nil }
        guard let first = located.first, let firstCoord = first.venueCoordinate else {
            // No one located → open a real, working map centered on the user
            // (Instagram-style), falling back to an auto region if location's off.
            return CameraPlan(camera: .userLocation(fallback: .automatic), focus: nil)
        }
        if located.count == 1 {
            return CameraPlan(camera: cityCamera(firstCoord), focus: first.id)
        }
        let coords = located.compactMap(\.venueCoordinate)
        var minLat = firstCoord.latitude, maxLat = firstCoord.latitude
        var minLon = firstCoord.longitude, maxLon = firstCoord.longitude
        for c in coords {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let latΔ = maxLat - minLat, lonΔ = maxLon - minLon
        if latΔ > fitThreshold || lonΔ > fitThreshold {
            // Too far apart to fit — open on the first friend.
            return CameraPlan(camera: cityCamera(firstCoord), focus: first.id)
        }
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max(latΔ * 1.6, 0.01), longitudeDelta: max(lonΔ * 1.6, 0.01)
        )
        return CameraPlan(camera: .region(MKCoordinateRegion(center: center, span: span)), focus: nil)
    }

    private static func cityCamera(_ c: CLLocationCoordinate2D) -> MapCameraPosition {
        .region(MKCoordinateRegion(center: c, span: citySpan))
    }

    /// Centre on the user.
    ///
    /// Uses MapKit's own user-location camera rather than LocationService: this
    /// view sits three layers below the one that owns that service, and
    /// threading it down for a single button isn't worth the coupling. The
    /// trade-off is that MapKit picks the zoom here instead of MapLocate's
    /// preset — close, but not identical to the other maps.
    private func locateMe() {
        withAnimation(MapLocate.animation) {
            focused = nil
            camera = .userLocation(fallback: .automatic)
        }
    }

    /// Fly the camera to a friend and mark their chip as focused.
    private func fly(to p: FriendPulse) {
        guard let c = p.venueCoordinate else { return }
        withAnimation(.easeInOut(duration: 0.55)) {
            focused = p.id
            camera = .region(MKCoordinateRegion(center: c, span: Self.citySpan))
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.ink.ignoresSafeArea()
            Map(position: $camera) {
                UserAnnotation()
                // Heat first, so friend pins draw over the glows.
                ForEach(heat.spots) { spot in
                    Annotation("", coordinate: spot.coordinate, anchor: .center) {
                        HeatGlow(spot: spot, selected: selectedHeatID == spot.id) {
                            selectedHeatID = selectedHeatID == spot.id ? nil : spot.id
                        }
                    }
                    .annotationTitles(.hidden)
                }
                ForEach(pulses) { p in
                    if let coord = p.venueCoordinate {
                        Annotation("", coordinate: coord, anchor: .bottom) {
                            MapAvatarPin(pulse: p, focused: focused == p.id)
                                .onTapGesture { selected = p }
                        }
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            // Bleed under the notch + sides, but respect the BOTTOM safe area
            // so Apple's "Maps / Legal" attribution isn't clipped by the home
            // indicator / rounded corner.
            .ignoresSafeArea(edges: [.top, .horizontal])
            // The chip row lives in the bottom safe-area inset, which also
            // lifts the map's attribution above it.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if pulses.count > 1 { friendChips }
            }

            // No blocking overlay — the map stays interactive. A floating,
            // non-interactive pill just explains the empty state.
            // Bottom furniture in ONE stack so the empty-state pill and the
            // heat legend can never overlap each other.
            VStack(spacing: 10) {
                Spacer()
                if pulses.isEmpty {
                    Text("No friends checked in yet — pan around the map 🌍")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.9))
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Capsule().fill(Color.ink.opacity(0.85)))
                        .overlay(Capsule().strokeBorder(Color.cream.opacity(0.12), lineWidth: 1))
                }
                if !heat.spots.isEmpty {
                    HStack {
                        HeatLegend()
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 42)
            .allowsHitTesting(false)

            // Outside the overlay above, which is hit-test disabled so the map
            // stays draggable through the chips.
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    LocateMeButton(enabled: true) { locateMe() }
                        .padding(.trailing, 16)
                        .padding(.bottom, 108)
                }
            }

            header
        }
        .preferredColorScheme(.dark)
        .task { await heat.refresh(near: pulses.first?.venueCoordinate) }
        .sheet(item: $selected) { p in
            FriendPulseSheet(pulse: p, feed: feed, dm: dm, me: me)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.ink)
        }
    }

    /// Floating header: title + count, with a close button. Sits over a soft
    /// top fade so it stays legible against bright map tiles.
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ON THE MAP")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(Color.bronze)
                Text(pulses.count == 1 ? "1 friend checked in"
                                       : "\(pulses.count) friends checked in")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.cream)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .black, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.ink.opacity(0.85)))
                    .overlay(Circle().strokeBorder(Color.cream.opacity(0.12), lineWidth: 1))
            }
            .buttonStyle(PressScaleStyle())
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [Color.ink.opacity(0.9), Color.ink.opacity(0.0)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        )
    }

    /// Tap-to-fly avatar row — the answer to friends spread across the world:
    /// jump straight to anyone instead of hunting for a speck on a zoomed-out
    /// map. The parked-on friend's chip glows.
    private var friendChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(pulses) { p in
                    let isFocused = focused == p.id
                    Button { fly(to: p) } label: {
                        HStack(spacing: 8) {
                            AvatarView(urlString: p.avatarUrl,
                                       initial: String(p.name.prefix(1)).uppercased(),
                                       size: 32)
                                .overlay(
                                    Circle().strokeBorder(
                                        isFocused ? Color.whiskey : Color.clear, lineWidth: 2
                                    ).padding(-2)
                                )
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.name.split(separator: " ").first.map(String.init) ?? p.name)
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.cream)
                                    .lineLimit(1)
                                if let v = p.venue, !v.isEmpty {
                                    Text(v)
                                        .font(.system(size: 10, weight: .medium, design: .rounded))
                                        .foregroundStyle(Color.cream.opacity(0.55))
                                        .lineLimit(1)
                                }
                            }
                        }
                        .padding(.leading, 6).padding(.trailing, 12).padding(.vertical, 6)
                        .background(
                            Capsule().fill(Color.ink.opacity(isFocused ? 0.95 : 0.8))
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                isFocused ? Color.whiskey.opacity(0.7) : Color.cream.opacity(0.12),
                                lineWidth: 1
                            )
                        )
                    }
                    .buttonStyle(PressScaleStyle())
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 24)
            .padding(.bottom, 10)
        }
        .background(
            LinearGradient(
                colors: [Color.ink.opacity(0.0), Color.ink.opacity(0.92)],
                startPoint: .top, endPoint: .bottom
            )
        )
    }
}

/// A single friend's pin on the friends map: their avatar in a status-tinted
/// ring, a BAC badge, and a little pointer so it plants on the venue. Mirrors
/// the TONIGHT strip's look so the two read as the same person.
private struct MapAvatarPin: View {
    let pulse: FriendPulse
    /// The camera is currently parked on this friend (chip tapped) — the pin
    /// grows and gains a warm glow so you can tell who you flew to.
    var focused: Bool = false
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
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                AvatarView(urlString: pulse.avatarUrl,
                           initial: String(pulse.name.prefix(1)).uppercased(),
                           size: 48)
                    .overlay(Circle().strokeBorder(status.color, lineWidth: 3).padding(-1))
                    .background(Circle().fill(Color.ink).padding(-3))
                    .shadow(color: Color.black.opacity(0.4), radius: 4, y: 2)
                    .shadow(color: focused ? Color.whiskey.opacity(0.8) : .clear, radius: 10)
                Text(unit.formatted(pulse.bac ?? 0))
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(status.color))
                    .overlay(Capsule().strokeBorder(Color.ink, lineWidth: 1.5))
                    .offset(y: 8)
            }
            // Pointer stem so the avatar sits ABOVE the exact venue point.
            Triangle()
                .fill(status.color)
                .frame(width: 12, height: 8)
                .offset(y: 6)
                .shadow(color: Color.black.opacity(0.3), radius: 2, y: 1)
        }
        .scaleEffect(focused ? 1.12 : 1)
        .zIndex(focused ? 1 : 0)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: focused)
        .padding(.bottom, 6)
    }
}

/// Small downward-pointing triangle used as the map-pin stem.
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// Sets the app-icon badge to the total unseen count.
enum AppBadge {
    static func set(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(max(0, count))
    }
}

/// Keeps the app-icon badge in sync with everything unseen — unread DMs,
/// pending sesh + event invites, friend requests, and new Nightline posts.
/// Client-side: accurate whenever the app is running or backgrounding. One
/// modifier entry so SessionView.body stays inside the type-checker's budget.
private struct AppBadgeModifier: ViewModifier {
    @ObservedObject var dm: DMService
    @ObservedObject var invites: InvitesService
    @ObservedObject var events: EventsService
    @ObservedObject var friends: FriendsService
    @ObservedObject var stories: StoriesService
    let myId: UUID?
    @Environment(\.scenePhase) private var scenePhase

    private var total: Int {
        dm.totalUnread
            + invites.pending.count
            + (myId.map { events.pendingCount(for: $0) } ?? 0)
            + friends.incoming.count
            + stories.unseenNightlineCount
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: total) { _, n in AppBadge.set(n) }
            .onChange(of: scenePhase) { _, phase in
                // Stamp the freshest count as the app backgrounds.
                if phase != .active { AppBadge.set(total) }
            }
            .task { AppBadge.set(total) }
    }
}

/// Instagram-"Map"-style bubble in the TONIGHT strip: a circular live map
/// thumbnail that opens the friends map. Snapshots the checked-in friends'
/// area as a dark Apple-Maps thumbnail; falls back to a globe motif when no
/// one is located yet. A bronze ring + count badge signals friends are on it.
private struct MapPulseBubble: View {
    let pulses: [FriendPulse]
    let onTap: () -> Void
    @State private var snapshot: UIImage?
    private let size: CGFloat = 54

    /// The wide world view shown when no friend is located yet — Instagram
    /// shows a real map here, never an icon, so we do too (just dark).
    private static let defaultRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 30, longitude: 0),
        span: MKCoordinateSpan(latitudeDelta: 130, longitudeDelta: 130))

    /// A padded box around the checked-in friends, else the default world view.
    private var region: MKCoordinateRegion {
        let coords = pulses.compactMap(\.venueCoordinate)
        guard let first = coords.first else { return Self.defaultRegion }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in coords {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                           longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.8, 0.03),
                                   longitudeDelta: max((maxLon - minLon) * 1.8, 0.03)))
    }

    /// Only re-snapshot when the framed area actually moves.
    private var regionKey: String {
        let r = region
        return String(format: "%.3f_%.3f_%.3f", r.center.latitude, r.center.longitude, r.span.latitudeDelta)
    }

    private var hasFriends: Bool { !pulses.isEmpty }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if let snapshot {
                    Image(uiImage: snapshot).resizable().scaledToFill()
                } else {
                    // Dark map-toned fill while the thumbnail renders (no icon).
                    Color(red: 0.07, green: 0.10, blue: 0.14)
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(
                Circle().strokeBorder(hasFriends ? Color.bronze : Color.cream.opacity(0.35),
                                      lineWidth: 2.5)
                    .padding(-3)
            )
            .overlay(alignment: .bottomTrailing) {
                if hasFriends {
                    Text("\(pulses.count)")
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .foregroundStyle(Color.ink)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.bronze))
                        .overlay(Circle().strokeBorder(Color.ink, lineWidth: 2))
                        .offset(x: 4, y: 4)
                }
            }
            .padding(.top, 9)
            .padding(.horizontal, 11)
            .padding(.bottom, 11)
            .contentShape(Circle())
            .onTapGesture(perform: onTap)
            Text("Map")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.6))
                .lineLimit(1)
        }
        .frame(width: 72)
        .task(id: regionKey) { await makeSnapshot() }
    }

    @MainActor
    private func makeSnapshot() async {
        let opts = MKMapSnapshotter.Options()
        opts.region = region
        opts.size = CGSize(width: size, height: size)   // scale defaults to the screen's
        opts.mapType = .standard
        opts.pointOfInterestFilter = .excludingAll
        opts.traitCollection = UITraitCollection(userInterfaceStyle: .dark)
        let shotter = MKMapSnapshotter(options: opts)
        let image: UIImage? = await withCheckedContinuation { cont in
            shotter.start(with: .global(qos: .userInitiated)) { snap, _ in
                cont.resume(returning: snap?.image)
            }
        }
        snapshot = image
    }
}

/// One avatar in the strip: live friends get a status-coloured ring +
/// BAC pill; offline friends are dimmed with no badge.
private struct PulseAvatar: View {
    let pulse: FriendPulse
    /// They have fresh stories → glowing rotating story ring, full
    /// opacity, tappable even when not live.
    var hasStory: Bool = false
    /// All their stories already watched → the ring goes quiet (thin
    /// static bronze, no glow), IG-style, so unseen ones pop.
    var seen: Bool = false
    @State private var ringSpin = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                    .overlay {
                        if hasStory && seen {
                            // Already watched: a quiet static bronze ring —
                            // still marks "has stories", but lets the
                            // unseen rings own the spotlight.
                            Circle()
                                .strokeBorder(Color.bronze.opacity(0.55), lineWidth: 2.5)
                                .padding(-7)
                        } else if hasStory {
                            // Unmissable story ring: a bright whiskey/cream
                            // gradient slowly ROTATING around the avatar,
                            // separated by a dark gap and doubled up with a
                            // strong warm glow. This is THE "new story"
                            // signal — it has to read from across the bar.
                            Circle()
                                .strokeBorder(
                                    AngularGradient(
                                        colors: [.whiskey, .cream, .whiskey, .cream, .whiskey],
                                        center: .center
                                    ),
                                    lineWidth: 4
                                )
                                .padding(-8)
                                .rotationEffect(.degrees(ringSpin ? 360 : 0))
                                .shadow(color: Color.whiskey.opacity(0.9), radius: 7)
                                .shadow(color: Color.whiskey.opacity(0.45), radius: 14)
                                .onAppear {
                                    guard !reduceMotion else { return }
                                    withAnimation(.linear(duration: 7).repeatForever(autoreverses: false)) {
                                        ringSpin = true
                                    }
                                }
                        } else if pulse.live {
                            Circle()
                                .strokeBorder(status.color, lineWidth: 2.5)
                                .padding(-3)
                        }
                    }
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
            // circle — the story ring (8pt + glow) and the BAC pill
            // (below, right) — so the ScrollView doesn't crop them.
            .padding(.top, 9)
            .padding(.horizontal, 11)
            .padding(.bottom, 11)
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
struct FriendPulseSheet: View {
    let pulse: FriendPulse
    /// Services so the sheet can open this person's profile + a DM thread.
    @ObservedObject var feed: FeedService
    @ObservedObject var dm: DMService
    /// The signed-in user (needed to open a chat thread).
    let me: Profile
    /// Display in the VIEWER's unit (percent vs promille) — the RPC always
    /// sends the raw %-scale value.
    @AppStorage(BACUnitSetting.key, store: BACUnitSetting.store) private var bacUnitMode = "auto"
    private var unit: BACUnit { BACUnitSetting.resolved(mode: bacUnitMode) }
    /// Expanded mini-map for the check-in venue.
    @State private var venueMapOpen = false
    /// Tapping the person's profile / message actions.
    @State private var openProfile: ProfileRef? = nil
    @State private var openChat = false

    private var profileRef: ProfileRef {
        ProfileRef(id: pulse.id, name: pulse.name, username: pulse.username, avatar: pulse.avatarUrl)
    }

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

                // Jump to their profile (past nights) or open a chat with them.
                HStack(spacing: 10) {
                    actionButton(icon: "person.fill", title: "Profile") { openProfile = profileRef }
                    actionButton(icon: "bubble.left.fill", title: "Message") { openChat = true }
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
        .sheet(item: $openProfile) { ref in
            ProfileFeedView(user: ref, feed: feed)
                .presentationBackground(Color.ink)
        }
        .sheet(isPresented: $openChat) {
            NavigationStack {
                ChatThreadView(dm: dm, feed: feed, profile: me,
                               other: pulse.id, fallbackName: pulse.name)
            }
            .presentationBackground(Color.ink)
        }
    }

    /// Pill action button (Profile / Message) under the header.
    private func actionButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 13, weight: .bold, design: .rounded))
                Text(title).font(.system(size: 14, weight: .bold, design: .rounded))
            }
            .foregroundStyle(Color.cream)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cream.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.cream.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(PressScaleStyle())
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
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Color.whiskey)
            Text(label)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Color.cream)
                .lineLimit(1)
            if let trailing {
                Image(systemName: trailing)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
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
            try await StorageUploader.uploadImage(
                bucket: "session-snaps", path: path, data: jpeg)
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
                    .font(.system(size: 11, weight: .bold, design: .rounded))
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
                // 30s — only polls while the group's snaps are on screen.
                try? await Task.sleep(nanoseconds: 30_000_000_000)
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
            SeshCameraView { data in
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
                .font(.system(size: 12, weight: .bold, design: .rounded))
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
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle((saved || isSaved) ? Color.ink : Color.cream)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill((saved || isSaved) ? Color.whiskey : Color.ink.opacity(0.7)))
                    }
                    .buttonStyle(PressScaleStyle())
                }
                if let onDelete {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.cream)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.ink.opacity(0.7)))
                    }
                    .buttonStyle(PressScaleStyle())
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
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


/// Full-screen, swipeable photo gallery. Each photo fits on screen at its
/// real aspect ratio; swipe between them, tap or X to dismiss.
struct GalleryLightbox: View {
    let urls: [URL]
    let start: Int
    let onClose: () -> Void

    @State private var index = 0
    @State private var dragOffset: CGFloat = 0

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
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(Circle().fill(.white.opacity(0.15)))
            }
            .padding(.top, 16).padding(.trailing, 20)
        }
        // Drag down to close, IG/Snap style — follows the finger, lets
        // go past the threshold, springs back otherwise.
        .offset(y: dragOffset)
        .gesture(
            DragGesture(minimumDistance: 25)
                .onChanged { v in dragOffset = max(0, v.translation.height) }
                .onEnded { v in
                    if v.translation.height > 130 {
                        onClose()
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            dragOffset = 0
                        }
                    }
                }
        )
        .onAppear { index = start }
    }
}

struct ModePill: View {
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

struct LoungeField: View {
    let label: String
    @Binding var text: String
    let placeholder: String
    var keyboard: UIKeyboardType = .default
    var autocapitalize: Bool = true
    /// Fixed prefix rendered inside the field (e.g. "@" for usernames) so
    /// users don't type it themselves. If they do anyway, it's stripped.
    var prefix: String? = nil

    /// The bound text with any typed copy of the prefix removed — people
    /// see "@" and instinctively type it; that must not break validation.
    private var sanitized: Binding<String> {
        Binding(
            get: { text },
            set: { newValue in
                if let prefix, !prefix.isEmpty {
                    var v = newValue
                    while v.hasPrefix(prefix) { v.removeFirst(prefix.count) }
                    text = v
                } else {
                    text = newValue
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(Color.bronze)
            HStack(spacing: 2) {
                if let prefix {
                    Text(prefix)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.whiskey)
                }
                TextField("", text: sanitized, prompt: Text(placeholder).foregroundStyle(Color.cream.opacity(0.3)))
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .tint(Color.whiskey)
                    .keyboardType(keyboard)
                    .textInputAutocapitalization(autocapitalize ? .words : .never)
                    .autocorrectionDisabled(!autocapitalize)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cream.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.cream.opacity(0.08), lineWidth: 1))
        }
    }
}

struct LoungeSecureField: View {
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
                .font(.system(size: 16, weight: .medium, design: .rounded))
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

struct LoungeNumberField: View {
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
                        .font(.system(size: 12, weight: .bold, design: .rounded))
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
                        .font(.system(size: 12, weight: .bold, design: .rounded))
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

struct LoungePickerField<Content: View>: View {
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
    case plan, live, timeline, chats, offers, profile

    /// Section name shown in the top bar (the switcher now lives at the bottom).
    var title: String {
        switch self {
        case .plan:     return "Events"
        case .live:     return "Live"
        case .timeline: return "Home"
        case .chats:    return "DMs"
        case .offers:   return "Maps"
        case .profile:  return "Profile"
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
    /// DMs live top-right, Instagram-style (profile moved to the bottom bar).
    let dmUnread: Int
    let onTapDMs: () -> Void
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
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
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
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
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
            // DMs — top-right, where the avatar used to live. The avatar
            // now marks the PROFILE tab in the bottom bar instead.
            Button(action: onTapDMs) {
                ZStack(alignment: .topTrailing) {
                    ZStack {
                        Circle()
                            .fill(Color.cream.opacity(0.05))
                            .frame(width: 32, height: 32)
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(dmUnread > 0 ? Color.whiskey : Color.cream.opacity(0.8))
                    }
                    .overlay(Circle().strokeBorder(Color.cream.opacity(0.12), lineWidth: 1))
                    if dmUnread > 0 {
                        Text(dmUnread > 9 ? "9+" : "\(dmUnread)")
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
            .accessibilityLabel(dmUnread > 0 ? "Messages, \(dmUnread) unread" : "Messages")
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
                        SonarDot()
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

// MARK: - First-run walkthrough

/// Five-page welcome tour shown once per account on first sign-in (and
/// replayable from the profile sheet). One idea per page — what each tab
/// is for — so a brand-new user knows the lay of the land in 30 seconds.
private struct WelcomeTourView: View {
    let onDone: () -> Void
    @State private var page = 0

    private struct TourPage {
        let icon: String
        let kicker: String
        let title: String
        let text: String
    }

    private static let pages: [TourPage] = [
        TourPage(
            icon: "sparkles",
            kicker: "WELCOME",
            title: "Welcome to sejdel",
            text: "Your night, tracked — from the first pour to the morning recap. Here's the quick lay of the land."
        ),
        TourPage(
            icon: "gauge.medium",
            kicker: "PLAN",
            title: "Plan the party before it starts",
            text: "Create a party or a trip, invite the crew, pick a level — and the calculator tells you exactly how much to buy. Tonight's own planner lives here too."
        ),
        TourPage(
            icon: "dot.radiowaves.left.and.right",
            kicker: "LIVE",
            title: "Log as you go",
            text: "One tap per drink. Check in to bars, bring your crew, and watch everyone's BAC in real time."
        ),
        TourPage(
            icon: "square.stack.fill",
            kicker: "NIGHTLINE",
            title: "Your friends' nights",
            text: "Stories and recaps from your friends land here — and you can see who's out right now."
        ),
        TourPage(
            icon: "map.fill",
            kicker: "DEALS",
            title: "Drink smarter, pay less",
            text: "Tonight's specials around you, on the map. Check in and the menu knows the deals."
        ),
    ]

    private var isLast: Bool { page == Self.pages.count - 1 }

    var body: some View {
        ZStack {
            AtmosphereBackground(accent: .whiskey)

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button {
                        onDone()
                    } label: {
                        Text("SKIP")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .tracking(2)
                            .foregroundStyle(Color.bronze)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScaleStyle())
                }
                .padding(.top, 14)
                .padding(.trailing, 10)

                TabView(selection: $page) {
                    ForEach(Array(Self.pages.enumerated()), id: \.offset) { idx, p in
                        tourPage(p).tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                HStack(spacing: 7) {
                    ForEach(Self.pages.indices, id: \.self) { idx in
                        Capsule()
                            .fill(idx == page ? Color.whiskey : Color.cream.opacity(0.15))
                            .frame(width: idx == page ? 22 : 7, height: 7)
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: page)
                .padding(.bottom, 24)

                PrimaryGlowButton(
                    title: isLast ? "Let's go" : "Next",
                    systemImage: isLast ? "checkmark" : "arrow.right"
                ) {
                    if isLast {
                        onDone()
                    } else {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                            page += 1
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
            }
        }
    }

    private func tourPage(_ p: TourPage) -> some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.whiskey.opacity(0.1))
                    .frame(width: 110, height: 110)
                Circle()
                    .strokeBorder(Color.whiskey.opacity(0.35), lineWidth: 1)
                    .frame(width: 110, height: 110)
                Image(systemName: p.icon)
                    .font(.system(size: 42, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.whiskey)
            }
            VStack(spacing: 10) {
                SectionLabel(p.kicker, color: .whiskey)
                Text(p.title)
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .tracking(-0.8)
                    .foregroundStyle(Color.cream)
                    .multilineTextAlignment(.center)
                Text(p.text)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.7))
                    .lineSpacing(3)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 36)
            Spacer()
            Spacer()
        }
    }
}

/// Profile sheet + first-run tour in one modifier. The tour pops
/// automatically the first time an account lands in the app, and is
/// replayable from the profile sheet's "Replay the tour" row. Extracted
/// from SessionView.body to keep its chain inside the type-checker's
/// budget.
private struct ProfileAndTourModifier: ViewModifier {
    @Binding var profileOpen: Bool
    @Binding var tourOpen: Bool
    @Binding var walkthroughOpen: Bool
    let seenKey: String
    /// Shown once per install, right after the tour.
    private let crewKey = "sesh.crewPrompt.seen.v1"
    @State private var crewOpen = false
    let profile: Profile
    @ObservedObject var auth: AuthService
    @ObservedObject var admin: AdminService
    @ObservedObject var friends: FriendsService
    @ObservedObject var feed: FeedService

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $profileOpen) {
                ProfileSheet(
                    profile: profile, auth: auth, admin: admin,
                    friends: friends, feed: feed,
                    onReplayTour: { tourOpen = true },
                    onWalkthrough: { profileOpen = false; walkthroughOpen = true }
                )
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(Color.ink)
            }
            .fullScreenCover(isPresented: $tourOpen) {
                WelcomeTourView {
                    UserDefaults.standard.set(true, forKey: seenKey)
                    tourOpen = false
                    // The tour hands straight off to "bring your crew" — the
                    // moment intent is highest. Only on the FIRST run, never
                    // on a replay from the profile, and only once ever: an
                    // onboarding wall that keeps asking for the address book
                    // is how apps get deleted.
                    if !UserDefaults.standard.bool(forKey: crewKey) {
                        UserDefaults.standard.set(true, forKey: crewKey)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { crewOpen = true }
                    }
                }
            }
            .sheet(isPresented: $crewOpen) {
                FindCrewSheet(friends: friends,
                              inviteURL: URL(string: "https://sejdel.com/")!) {
                    crewOpen = false
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.ink)
            }
            .onAppear {
                if !UserDefaults.standard.bool(forKey: seenKey) {
                    tourOpen = true
                }
            }
    }
}

/// One-line dismissible hint shown on a tab until the user closes it.
/// Device-level flag — the tour handles the real per-account onboarding;
/// these are just gentle nudges toward each tab's core action.
private struct TabHintChip: View {
    let text: String
    private let storageKey: String
    @State private var hidden: Bool

    init(_ text: String, key: String) {
        self.text = text
        let k = "sesh.hint.\(key).v1"
        self.storageKey = k
        _hidden = State(initialValue: UserDefaults.standard.bool(forKey: k))
    }

    var body: some View {
        if !hidden {
            HStack(spacing: 10) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.whiskey)
                Text(text)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Button {
                    UserDefaults.standard.set(true, forKey: storageKey)
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        hidden = true
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.bronze)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("Dismiss hint")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.inkElev)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.cream.opacity(0.08), lineWidth: 1)
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

/// Bundles the Deals promo surfaces (app-open interstitial cover + one-time
/// opt-in alert) into a single modifier so SessionView.body stays inside the
/// Swift type-checker's budget.
private struct DealsPromosModifier<Cover: View>: ViewModifier {
    @Binding var interstitial: InterstitialPayload?
    @Binding var dealPromptOpen: Bool
    @ObservedObject var location: LocationService
    let cover: (InterstitialPayload) -> Cover
    let onEnable: () -> Void
    let onDecline: () -> Void

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: $interstitial) { cover($0) }
            .alert("Deals from nearby bars?", isPresented: $dealPromptOpen) {
                Button("Enable", action: onEnable)
                Button("Not now", role: .cancel, action: onDecline)
            } message: {
                Text("Get the occasional heads-up when a bar in your city drops a happy hour or special — only a few a week. Turn it off anytime in your profile.")
            }
            // Report a coarse location once a fix arrives (throttled + opt-in
            // gated inside reportLocation) so nearby-bar push can target it.
            .onChange(of: location.location != nil) { _, hasFix in
                if hasFix, let loc = location.location { DealsPush.reportLocation(loc) }
            }
    }
}

private struct SessionView: View {
    /// Measured tab bar height — reserved as a bottom inset while the bar
    /// itself is overlay-pinned behind the keyboard.
    @State private var tabBarHeight: CGFloat = 84
    /// True while the keyboard is up. The tab-bar spacer collapses then —
    /// the keyboard already covers the bar, and keeping the spacer would
    /// stack a dead gap on top of the keyboard inset (visible under the
    /// chat composer).
    @State private var keyboardUp = false
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
    /// Plan-ahead events (parties/trips) — the PLAN tab's main content.
    @StateObject private var eventsService = EventsService()
    /// Direct messages: friend chat + story reactions.
    @StateObject private var dm = DMService()
    @State private var eventComposerOpen = false
    @State private var openEventRef: EventRef?
    /// The tonight planner starts collapsed — PLAN reads as events-first,
    /// and the toggle remembers the user's preference.
    @AppStorage("sesh.plan.tonightExpanded") private var tonightExpanded = false
    /// Share my live check-in location with friends (map). On by default;
    /// toggled in the profile sheet. Gates publishPresence's venue fields.
    @AppStorage(ShareLocationSetting.key) private var shareLocation = true
    /// PAST EVENTS shelf, collapsed by default (it's an archive).
    @AppStorage("sesh.plan.pastExpanded") private var pastExpanded = false
    /// Location + venue services. Owned here (the topmost user-facing
    /// view) and passed into LiveSeshView so both modes share one source
    /// of truth for "where am I tonight?" and "what specials apply?".
    @StateObject private var location = LocationService()
    @StateObject private var venues = VenueService()

    @State private var localOrder: [OrderItem] = []
    @State private var hours: Double = 1
    @State private var menuOpen = false
    @State private var profileOpen = false
    /// The app-open Deals interstitial payload, when one is due to show.
    @State private var interstitial: InterstitialPayload? = nil
    /// The full guided walkthrough overlay (launched from the profile).
    @State private var walkthroughActive = false
    /// One-time "want deals from nearby bars?" opt-in ask, shown the first
    /// time the user lands on the Deals tab.
    @State private var dealPromptOpen = false
    /// First-run feature walkthrough — shown once per account, replayable
    /// from the profile sheet.
    @State private var tourOpen = false
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
    // Home (the friends timeline) is the launch screen and the leftmost tab —
    // like Instagram/BeerBuddy, you always open onto the feed, not into LIVE.
    @State private var tab: TopTab = .timeline
    /// DMs is an overlay (top-right button), not a swipe page — the paged
    /// TabView keeps showing the last real page underneath while it's up,
    /// so leaving DMs returns exactly where you were.
    @State private var lastNonChatsTab: TopTab = .timeline
    /// Raised while a finger is on a map. The paged TabView's scroll view was
    /// claiming the horizontal component of a pinch-to-zoom and sliding the
    /// whole screen to the next tab mid-gesture.
    @State private var mapPagingLocked = false

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
            let t: Task<Void, Never> = Task { _ = await planGroup.addDrink(option, shared: shared) }
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
        // The solo sesh ALWAYS ends when a group takes over — even with
        // zero drinks to carry. Bailing early here left a phantom solo
        // running underneath the group: END-for-everyone then dropped the
        // user into a zombie "LIVE SESH" they never knew existed, minted
        // a between-bars stop, required a second END, and made the recap
        // machinery treat the terminal end as a mid-night switch (no
        // personal recap, no squad recap, nothing cleared).
        guard live.isActive || !live.drinks.isEmpty else { return }
        let carried = live.drinks.sorted(by: { $0.consumedAt < $1.consumedAt })
        Task {
            for d in carried {
                await liveGroup.addDrink(d.option(), shared: false, consumedAt: d.consumedAt)
            }
            // Re-sync from the DB so a concurrent enter() refresh can't drop
            // the just-carried rows, THEN clear the solo store.
            if !carried.isEmpty {
                await liveGroup.refresh()
            }
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
            AtmosphereBackground(
                // Whiskey on LIVE (the live experience) and on CHATS —
                // the chats page carries its own whiskey atmosphere copy
                // (NavigationStack paints over the shared one), so the
                // sliver above it must match or the top reads green while
                // the page reads amber.
                accent: (tab == .live || tab == .chats) ? Color.whiskey : status.color,
                // Carbonation while the night is actually on.
                bubbles: tab == .live && liveStartTime != nil
            )
            .animation(.easeInOut(duration: 0.45), value: tab)

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 8)

                ZStack {
                    TabView(selection: Binding(
                        get: { tab == .chats ? lastNonChatsTab : tab },
                        set: { tab = $0 }
                    )) {
                        // Order matches the bottom bar left→right:
                        // Home · Live · Events · Maps · Profile.
                        // DMs is NOT a swipe page — it overlays from the
                        // top-right button, Instagram-style.
                        timelinePage.tag(TopTab.timeline)
                        livePage.tag(TopTab.live)
                        planPage.tag(TopTab.plan)
                        offersPage.tag(TopTab.offers)
                        profilePage.tag(TopTab.profile)
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    // A paged TabView is a scroll view underneath, so it competes
                    // with a map's own pan/pinch recognisers. Stand down while the
                    // map says a gesture is in flight.
                    .scrollDisabled(mapPagingLocked)
                    // Smooth horizontal swipe between modes; matches the
                    // bottom bar's spring so tapping a tab and dragging the
                    // page feel like the same animation.
                    .animation(.spring(response: 0.4, dampingFraction: 0.82), value: tab)

                    // DMs overlay — slides in over whatever page is showing.
                    // ChatsView paints its own atmosphere, so it fully covers.
                    if tab == .chats {
                        chatsPage
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                            .zIndex(1)
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.82), value: tab)

            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // The bar's footprint — the bar itself is pinned at the
                // root below so the keyboard covers it instead of lifting
                // it. On CHATS it collapses while the keyboard is up so the
                // composer sits flush on the keyboard; elsewhere it stays,
                // or the page inset would bounce during the animation.
                Color.clear.frame(height: (keyboardUp && tab == .chats) ? 0 : tabBarHeight)
            }

            // Switching sections (tap or swipe) drops the keyboard — so
            // leaving a chat mid-typing doesn't strand it open.
            .onChange(of: tab) { _, newTab in handleTabChange(newTab) }
            // Tap anywhere outside a field, on any screen or sheet, to
            // drop the keyboard.
            .onAppear { KeyboardDismissTap.install() }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                withAnimation(.easeOut(duration: 0.25)) { keyboardUp = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                withAnimation(.easeOut(duration: 0.25)) { keyboardUp = false }
            }
            .modifier(DealsPromosModifier(
                interstitial: $interstitial,
                dealPromptOpen: $dealPromptOpen,
                location: location,
                cover: { interstitialCover($0) },
                onEnable: {
                    DealsPush.setOptIn(true)
                    if let loc = location.location { DealsPush.reportLocation(loc) }
                },
                onDecline: { DealsPush.setOptIn(false) }
            ))

            // Pinned bar: a root-level ZStack sibling, NOT an overlay on
            // the VStack — the VStack shrinks above the keyboard, so
            // anything anchored to it rides up with the keyboard. This
            // layer ignores the keyboard and stays planted.
            pinnedTabBar
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .zIndex(10)

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
        // On every tab but CHATS the page layout is FROZEN against the
        // keyboard: the keyboard slides over the content and nothing
        // reflows — a focused field is brought into view by scrolling
        // (see .sejdelScrollToFocusedField), not by squeezing the page.
        // Counter-animating a squeezed layout always jitters; freezing it
        // can't. CHATS keeps system avoidance for its composer.
        .ignoresSafeArea(tab == .chats ? [] : .keyboard, edges: .bottom)
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
                    venues.currentVenue = groupVenue.map(hardenedGroupVenue)
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
        .task { await loadAndMaybePromote() }
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
            feed: feed,
            dm: dm,
            profile: profile,
            openPulse: $openPulse,
            tab: tab,
            publish: publishPresence,
            onLiveEnded: { checkOutAfterLiveEnd() },
            journey: journey,
            syncMarkers: { syncJourneyMarkersToGroup() },
            mergeRoute: { mergeGroupRouteIntoJourney() }
        ))
        // App-icon badge = everything unseen (DMs, invites, friend requests,
        // new posts). One modifier entry to stay within the type-checker budget.
        .modifier(AppBadgeModifier(
            dm: dm, invites: invites, events: eventsService,
            friends: friends, stories: liveStories, myId: profile.id
        ))
        // Bridge the device-local guest store to the shared session roster
        // as the user enters / leaves a LIVE group:
        //   • Enter  → adopt the session's shared guests and start
        //     mirroring local edits up to the server.
        //   • Leave / end → stop mirroring and wipe the night's guests
        //     (covers every group-end path, not just the solo END button
        //     — that was the original "stale ghosts" bug).
        // Session lifecycle wiring (ghost bridge + drink carry + boot +
        // profile patch) — one chain entry; the inline closures were the
        // type-checker's breaking point.
        .onChange(of: liveGroup.session?.id) { old, new in
            handleLiveSessionChange(old: old, new: new)
        }
        .onChange(of: liveGroup.ghosts) { _, newGhosts in
            if liveGroup.session != nil {
                ghosts.hydrate(newGhosts)
            }
        }
        .onAppear { bootSession() }
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
        .modifier(profileSheets)
        .modifier(WalkthroughModifier(tab: $tab, active: $walkthroughActive))
        .modifier(BirthdatePromptModifier(auth: auth))
        .sheet(isPresented: $friendsSheetOpen) {
            FriendsView(friends: friends, auth: auth, feed: feed)
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

    /// Per-account, so a second account on the same phone still gets the
    /// tour — same keying pattern as the nightline last-seen marker.
    private var tourSeenKey: String { "sesh.tour.seen.v1.\(profile.id)" }

    /// Bridge the device-local guest store to the shared session roster
    /// as the user enters / leaves a LIVE group, and carry drinks across
    /// solo↔group and group→group transitions. Extracted from an inline
    /// onChange closure for the type-checker's sake — behaviour identical.
    private func handleLiveSessionChange(old: UUID?, new: UUID?) {
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
            } else if live.isActive {
                // Defensive normalize: an active GROUP alongside an
                // active SOLO is never a valid state. A solo that's
                // still alive next to a fresh group is tonight's night
                // (truly stale solos are auto-ended by endIfStale
                // before resume gets here) — carry it in and close it,
                // exactly as a user-initiated join would.
                carrySoloNightIntoGroup()
            }
        } else if old != nil && new == nil {
            ghosts.syncSink = nil
            ghosts.clearAll()
        }
    }

    /// First-frame boot: seed saved groups, start the polling services,
    /// sweep stale journey leftovers, and wire the journey's session-id
    /// stamp. Extracted from the body's onAppear (type-checker budget).
    /// Show one app-open Deals interstitial if a fresh, nearby campaign is due
    /// (once per campaign per device, once per launch). No-op when nothing
    /// qualifies or one already showed this launch.
    private func maybeShowInterstitial() {
        guard !DealsInterstitial.shownThisLaunch, interstitial == nil else { return }
        guard let cand = venues.interstitialCandidate(near: location.location,
                                                       excluding: DealsInterstitial.seenIDs())
        else { return }
        DealsInterstitial.shownThisLaunch = true
        interstitial = InterstitialPayload(offer: cand.offer, venue: cand.venue)
    }

    /// App-open catalog load, then (after a beat for a location fix) the Deals
    /// interstitial + a coarse location report for push targeting.
    private func loadAndMaybePromote() async {
        await venues.refresh()
        try? await Task.sleep(nanoseconds: 1_800_000_000)
        maybeShowInterstitial()
        if let loc = location.location { DealsPush.reportLocation(loc) }
    }


    /// The tab bar, pinned to the window bottom. It ignores the keyboard so
    /// the keyboard slides over it on every tab; text fields stay visible
    /// through normal scrolling.
    private var pinnedTabBar: some View {
        BottomTabBar(tab: $tab, liveActive: liveActive,
                     friendsLive: friendsPulse.pulses.contains { $0.live },
                     newOnNightline: liveStories.hasUnseenNightline,
                     unseenCount: liveStories.unseenNightlineCount,
                     eventInvites: eventsService.pendingCount(for: profile.id),
                     avatarURL: profile.avatarURL,
                     avatarInitial: String(profile.name.prefix(1)).uppercased())
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                tabBarHeight = $0
            }
    }

    private func handleTabChange(_ newTab: TopTab) {
        // Remember the page under the DMs overlay so closing it returns there.
        if newTab != .chats { lastNonChatsTab = newTab }
        // Switching sections drops the keyboard (leaving a chat mid-typing).
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
        // First landing on Deals → offer the nearby-bar push opt-in once. Skip
        // if an interstitial already promoted this launch (no double ask).
        if newTab == .offers, !DealsPush.wasPrompted,
           interstitial == nil, !DealsInterstitial.shownThisLaunch {
            DealsPush.markPrompted()
            dealPromptOpen = true
        }
    }

    @ViewBuilder
    private func interstitialCover(_ payload: InterstitialPayload) -> some View {
        InterstitialView(
            offer: payload.offer,
            venue: payload.venue,
            onClose: { closeInterstitial(payload) },
            onSeeDeal: { seeInterstitialDeal(payload) }
        )
        // Transparent so the card floats over the dimmed live app.
        .presentationBackground(.clear)
    }

    private func closeInterstitial(_ payload: InterstitialPayload) {
        DealsInterstitial.markSeen(payload.offer.id)
        interstitial = nil
    }

    private func seeInterstitialDeal(_ payload: InterstitialPayload) {
        CampaignStats.tap(payload.offer.id)
        DealsInterstitial.markSeen(payload.offer.id)
        venues.pendingFocusVenueId = payload.venue.id
        interstitial = nil
        tab = .offers
    }

    private func bootSession() {
        recordSavedGroup(from: planGroup)
        recordSavedGroup(from: liveGroup)
        // Publish the account's email digest so friends who have this address
        // in their contacts can find them — no user action, and no phone
        // number needed. Per-kind (099), so it never clears a phone key.
        Task {
            await ContactDiscovery().publishEmailKey(supabase.auth.currentUser?.email)
        }
        friends.start()
        eventsService.start()
        dm.start()
        sweepStaleJourney()
        // Every journey entry created while in a live group carries the
        // group's id — the group recap selects by IDENTITY, so a
        // member's parallel personal stops can never leak into it.
        journey.currentSessionProvider = { [weak liveGroup] in
            liveGroup?.session?.id
        }
    }

    /// Extracted from body — the 16-argument ModeTopBar call inside the
    /// main chain was the straw that broke the type-checker's back.
    private var topBar: some View {
        ModeTopBar(
            tab: $tab,
            profile: profile,
            liveActive: liveActive,
            inboxCount: invites.pending.count + friends.incoming.count + friends.unseenActivityCount,
            onTapInbox: { invitesSheetOpen = true; friends.markActivitySeen() },
            dmUnread: dm.totalUnread,
            onTapDMs: {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) { tab = .chats }
            },
            onTapFriends: { friendsSheetOpen = true },
            liveStarted: liveStartTime,
            liveInGroup: liveGroup.isActive,
            liveMemberCount: liveGroup.members.count,
            liveCanEnd: !liveGroup.isActive && live.isActive,
            // The confirm alert (and the recap flow it kicks off) lives inside
            // the LIVE page — from any other tab the flag flipped but nothing
            // was mounted to present it, so END silently did nothing. Hop to
            // LIVE first, then raise the confirm once the page is on screen.
            onEndLive: {
                if tab == .live {
                    liveConfirmEnd = true
                } else {
                    tab = .live
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        liveConfirmEnd = true
                    }
                }
            },
            liveIsHost: liveGroup.isHost,
            onEndGroup: {
                Task { await liveGroup.end(cousinSessionId: planGroup.session?.id) }
            },
            onLeaveGroup: { leaveGroupKeepingNight() },
            onEndMyGroupNight: {
                Task { await liveGroup.leave(cousinSessionId: planGroup.session?.id, captureRecap: true) }
            }
        )
    }

    /// A group venue that doesn't exist in the venues table (an event's
    /// auto check-in place, or any payload written before the source fix)
    /// must never be tagged `curated` — VenueService's reconcile pass
    /// drops curated venues whose row is missing, which silently undid
    /// the adoption on the next venues refresh.
    private func hardenedGroupVenue(_ v: Venue) -> Venue {
        guard v.source == .curated,
              !venues.venues.contains(where: { $0.id == v.id }) else { return v }
        var hardened = v
        hardened.source = .user
        return hardened
    }

    /// Adopt the event session's location (auto check-in venue or group
    /// pre-game spot) right after entering it. The `.onChange` observers
    /// only react to value CHANGES, and on a late join the venue/spot
    /// arrive in the same beat as the session itself — racing the member
    /// load, so the observer's isActive guard could reject the one and
    /// only delta and the location never landed on the joiner's device.
    /// Reads the session ROW as well as the published mirror, and runs a
    /// second pass after the first poll settles.
    private func adoptEventLocationAfterJoin(_ sid: UUID, retry: Bool = true) {
        guard liveGroup.session?.id == sid, liveGroup.followingGroupVenue else { return }
        if let v = liveGroup.liveVenue ?? liveGroup.session?.liveVenue,
           venues.currentVenue?.id != v.id {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                venues.currentVenue = hardenedGroupVenue(v)
            }
        }
        if let spot = liveGroup.liveLooseSpot ?? liveGroup.session?.liveLooseSpot,
           !journey.looseSpots.contains(where: { $0.id == spot.id }) {
            journey.adoptLooseSpot(spot)
        }
        if retry {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                adoptEventLocationAfterJoin(sid, retry: false)
            }
        }
    }

    /// Sweep journey leftovers from a previous night whose end was never
    /// captured here (ended while away, then resumed straight into a NEW
    /// session — the old night's recap/clear gets skipped and its pre-game
    /// spot haunts the next sesh). Delayed a beat so resumeIfAny settles
    /// first; a multi-day trip session then protects its own entries.
    private func sweepStaleJourney() {
        let sweep: Task<Void, Never> = Task { [weak journey, weak liveGroup] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            journey?.purgeStale(before: liveGroup?.session?.createdAt)
        }
        _ = sweep
    }

    /// Profile sheet + first-run tour, bundled into one chain entry to
    /// keep SessionView.body inside the type-checker's budget (the tour
    /// is opened from the profile sheet, so they travel together).
    private var profileSheets: some ViewModifier {
        ProfileAndTourModifier(
            profileOpen: $profileOpen,
            tourOpen: $tourOpen,
            walkthroughOpen: $walkthroughActive,
            seenKey: tourSeenKey,
            profile: profile,
            auth: auth,
            admin: admin,
            friends: friends,
            feed: feed
        )
    }

    /// DEALS — the venue-offers discovery map (Phase A). Embedded as a tab,
    /// so it shows no close button; navigation is the bottom bar.
    ///
    /// The DEALS page defers its heavy MapKit map to after the page-swipe
    /// animation settles (see DeferredOffersPage) — mounting it mid-swipe
    /// was hitching the transition, and the memory gating still applies.
    private var offersPage: some View {
        DeferredOffersPage(active: tab == .offers, venues: venues, location: location,
                           pagingLocked: $mapPagingLocked) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                tab = .timeline
            }
        }
    }

    /// PROFILE — the far-right tab. Hosts the same view as the old profile
    /// sheet; its internal `dismiss()` calls are harmless no-ops here (save
    /// keeps you on the page, sign-out/delete tear down SessionView anyway).
    private var profilePage: some View {
        ProfileSheet(
            profile: profile, auth: auth, admin: admin,
            friends: friends, feed: feed,
            onReplayTour: { tourOpen = true },
            onWalkthrough: { walkthroughActive = true }
        )
    }

    /// TIMELINE — HOME: the friends feed. The tonight strip rides inside
    /// the feed (under the stories row) as an injected header.
    private var timelinePage: some View {
        VStack(spacing: 0) {
            TabHintChip(
                "Stories and recaps from your friends land here.",
                key: "nightline"
            )
            .padding(.horizontal, 20)
            .padding(.top, 6)

            timelineFeed
        }
    }

    /// Tonight-at-a-glance on HOME, sitting under the stories row. Whole
    /// card is whiskey; BAC is always shown (0.00 included — with a nudge
    /// to order the first drink). Tapping anywhere lands on LIVE.
    private var homeLiveStrip: some View {
        let running = live.isActive || liveGroup.isActive
        let unit = BACUnitSetting.current()
        let bacValue = currentStoryBAC() ?? 0
        return Button {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) { tab = .live }
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        if running { SonarDot(size: 6, color: .ink) }
                        Text(running ? "LIVE NOW" : "YOUR NIGHT")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(2)
                            .foregroundStyle(Color.ink.opacity(0.55))
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(unit.formatted(bacValue))
                            .font(.system(size: 26, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color.ink)
                        Text(unit.symbol)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.ink.opacity(0.55))
                    }
                    Text(homeStripLine)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.ink.opacity(0.75))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .black))
                    Text("DRINK")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .tracking(1.2)
                }
                .foregroundStyle(Color.whiskey)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.ink))
                .shadow(color: Color.ink.opacity(0.35), radius: 8, y: 2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 18).fill(Color.whiskey))
            .shadow(color: Color.whiskey.opacity(0.35), radius: 14, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(running ? "Tonight's live summary — open LIVE" : "Add a drink — open LIVE")
    }

    /// One-line summary under the strip's BAC figure. Live: drinks · group
    /// size · elapsed. Idle: the nudge to get the night moving.
    private var homeStripLine: String {
        guard live.isActive || liveGroup.isActive else {
            return "It's empty in here — order your first drink"
        }
        var parts: [String] = []
        let count = liveGroup.isActive
            ? liveGroup.totalDrinkCount(for: profile.id)
            : live.drinks.count
        parts.append(count == 1 ? "1 drink" : "\(count) drinks")
        if liveGroup.isActive, liveGroup.members.count > 1 {
            parts.append("\(liveGroup.members.count) in group")
        }
        if let s = liveStartTime {
            let mins = max(0, Int(Date().timeIntervalSince(s) / 60))
            parts.append(mins >= 60 ? "\(mins / 60)h \(mins % 60)m" : "\(mins)m")
        }
        return parts.joined(separator: " · ")
    }

    /// CHATS — DM threads (story likes/replies land here too).
    private var chatsPage: some View {
        ChatsView(dm: dm, friends: friends, feed: feed, profile: profile)
    }

    private var timelineFeed: some View {
        TimelineFeedView(
            feed: feed,
            pulse: friendsPulse,
            stories: liveStories,
            dm: dm,
            profile: profile,
            storyBAC: { currentStoryBAC() },
            storyStamp: { currentStoryStamp() },
            storyProof: { currentStoryProof() },
            onOpenPost: { openPost = $0 },
            onOpenAuthor: { post in
                openProfileUser = ProfileRef(
                    id: post.authorId, name: post.authorName,
                    username: post.authorUsername, avatar: post.authorAvatar
                )
            },
            onOpenPulse: { openPulse = $0 },
            onAddFriends: { friendsSheetOpen = true },
            header: AnyView(homeLiveStrip)
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

    /// "3 drinks · Large beer" — my tally + latest pour, for the story
    /// composer's proof-of-drink sticker. Nil when nothing's been logged.
    private func currentStoryProof() -> String? {
        if liveGroup.isActive {
            let mine = liveGroup.liveTimeline(for: profile.id)
            guard !mine.isEmpty else { return nil }
            let latest = mine.first?.drinkName
            return "\(mine.count) \(mine.count == 1 ? "drink" : "drinks")"
                + (latest.map { " · \($0)" } ?? "")
        }
        guard !live.drinks.isEmpty else { return nil }
        let latest = live.drinks.max(by: { $0.consumedAt < $1.consumedAt })?.optionName
        return "\(live.drinks.count) \(live.drinks.count == 1 ? "drink" : "drinks")"
            + (latest.map { " · \($0)" } ?? "")
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
        // Location sharing (on by default, toggled off in the profile
        // sheet) gates the venue that friends see on the map — with it
        // off, they still see you're live + your BAC, just not where.
        let venue = shareLocation ? (venues.currentVenue ?? liveGroup.liveVenue) : nil
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
                TabHintChip(
                    "Plan a party or a trip — invite the crew and know exactly how much to buy.",
                    key: "plan.events"
                )

                tonightToggle
                if tonightExpanded {
                    tonightPlannerStack
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                eventsSection
            }
            .padding(.horizontal, 24)
            .padding(.top, 6)
            .padding(.bottom, 130)
        }
        // The tab's one primary action stays pinned above the scroll — an
        // expanded PAST EVENTS shelf must never push it off screen.
        .overlay(alignment: .bottom) {
            PrimaryGlowButton(title: "Plan an event", systemImage: "plus") {
                eventComposerOpen = true
            }
            .padding(.horizontal, 24)
            .padding(.top, 26)
            .padding(.bottom, 10)
            .background(
                LinearGradient(
                    colors: [Color.ink.opacity(0), Color.ink.opacity(0.88), Color.ink],
                    startPoint: .top, endPoint: .bottom
                )
                .allowsHitTesting(false)
            )
        }
        .animation(.spring(response: 0.55, dampingFraction: 0.82), value: status)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: planGroup.isActive)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: tonightExpanded)
        .sheet(isPresented: $eventComposerOpen) {
            EventComposerSheet(events: eventsService) { newId in
                openEventRef = EventRef(id: newId)
            }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.ink)
        }
        .sheet(item: $openEventRef) { ref in
            EventDetailSheet(
                eventId: ref.id,
                events: eventsService,
                friends: friends,
                profile: profile
            )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.ink)
        }
        // An armed event went live server-side: if I'm going, enter its
        // sesh as a real JOIN — the drink-carry machinery then moves a
        // running solo night (or another group's night) in with me, same
        // as tapping JOIN by hand. joinEventSession itself refuses to
        // re-enter a sesh the user deliberately left (in_live check).
        .onChange(of: eventsService.events) { _, evs in
            guard let liveEvent = evs.first(where: {
                      $0.isLiveNow && $0.liveSessionId != nil
                          && eventsService.myStatus(in: $0, uid: profile.id) == "going"
                  }),
                  let sid = liveEvent.liveSessionId,
                  liveGroup.session?.id != sid
            else { return }
            let t: Task<Void, Never> = Task {
                await liveGroup.joinEventSession(id: sid)
                adoptEventLocationAfterJoin(sid)
            }
            _ = t
        }
    }

    /// "Mauritz's party is live" — headline for the LIVE tab banner when
    /// the current live group belongs to an event.
    private var liveEventForBanner: SeshEvent? {
        eventsService.events.first {
            $0.isLiveNow && $0.liveSessionId != nil && $0.liveSessionId == liveGroup.session?.id
        }
    }

    private var eventLiveHeadline: String? {
        guard let ev = liveEventForBanner else { return nil }
        if ev.hostId == profile.id {
            return "Your \(ev.kindValue.label.lowercased()) is live"
        }
        let host = eventsService.profilesById[ev.hostId]?.name
            .split(separator: " ").first.map(String.init) ?? "The host"
        return "\(host)'s \(ev.kindValue.label.lowercased()) is live"
    }

    /// Collapsed entry point for the pre-night planner — "tonight is just
    /// an event too". Expanding reveals the full classic planner below.
    private var tonightToggle: some View {
        Button {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                tonightExpanded.toggle()
            }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.whiskey.opacity(0.12))
                        .frame(width: 34, height: 34)
                    Image(systemName: "moon.stars.fill")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.whiskey)
                }
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel("Tonight")
                    Text(combinedOrder.isEmpty
                         ? "Plan tonight's drinks"
                         : "\(combinedOrder.count) \(combinedOrder.count == 1 ? "drink" : "drinks") planned · \(status.label)")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.cream)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.bronze)
                    .rotationEffect(.degrees(tonightExpanded ? 180 : 0))
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.inkElev)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.cream.opacity(0.06), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
        }
        .buttonStyle(PressScaleStyle())
    }

    /// Upcoming events + pending invites. Empty state teaches the feature.
    @ViewBuilder
    private var eventsSection: some View {
        let upcoming = eventsService.events.filter { !$0.isPast }
        let past = eventsService.events.filter(\.isPast)
            .sorted { $0.startsAt > $1.startsAt }

        VStack(alignment: .leading, spacing: 10) {
            Text("Upcoming")
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .tracking(-0.5)
                .foregroundStyle(Color.cream)
                .padding(.top, 4)
            if upcoming.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nothing planned yet")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.cream)
                    Text("Plan a party, a pregame or a weekend trip — invite the crew, pick a level, and the calculator tells you exactly how much to buy.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.cream.opacity(0.025))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.cream.opacity(0.08), lineWidth: 1)
                )
            } else {
                ForEach(upcoming) { ev in
                    eventCardRow(ev)
                }
            }

            // The GROUP NIGHTS shelf, but for events: every party or trip
            // whose night has run (or whose window passed) settles here.
            // Collapsed by default — it's an archive, not a to-do.
            if !past.isEmpty {
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        pastExpanded.toggle()
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Past events")
                            .font(.system(size: 20, weight: .heavy, design: .rounded))
                            .tracking(-0.5)
                            .foregroundStyle(Color.cream)
                        Text("\(past.count)")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.bronze)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.bronze)
                            .rotationEffect(.degrees(pastExpanded ? 180 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 10)

                if pastExpanded {
                    ForEach(past.prefix(10)) { ev in
                        eventCardRow(ev, past: true)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: pastExpanded)
    }

    private func eventCardRow(_ ev: SeshEvent, past: Bool = false) -> some View {
        EventCard(
            event: ev,
            goingCount: (eventsService.membersByEvent[ev.id] ?? [])
                .filter { $0.status == "going" }.count
                + ev.ghosts.count,
            myStatus: eventsService.myStatus(in: ev, uid: profile.id),
            isPastShelf: past,
            onTap: { openEventRef = EventRef(id: ev.id) },
            onRSVP: { going in
                let t: Task<Void, Never> = Task {
                    await eventsService.respond(eventId: ev.id, going: going)
                }
                _ = t
            }
        )
    }

    /// The classic pre-night planner, unchanged — now lives behind the
    /// Tonight toggle so the tab reads events-first.
    @ViewBuilder
    private var tonightPlannerStack: some View {
                // The readout leads — it's the number you open the app for.
                // One hero card: BAC + status + advice + sober-by milestones.
                TonightHeroCard(
                    bac: bac,
                    status: status,
                    advice: vibe.advice,
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
                                    let t: Task<Void, Never> = Task { _ = await planGroup.addDrink(option, shared: shared) }
                                    _ = t
                                } else {
                                    localOrder.append(OrderItem(option: option))
                                }
                            }
                        }
                    )

                    CollapsibleControlRow(
                        icon: "hourglass",
                        title: "Tonight's window",
                        valueText: "\(formatHours(hours)) h"
                    ) {
                        TintedSlider(value: $hours, range: 0...12, step: 0.25, accent: .whiskey)
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
            eventLiveHeadline: eventLiveHeadline,
            eventLiveTitle: liveEventForBanner?.title,
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

// Internal (was private) so extracted feature files — DMs.swift and
// future splits — can share the app's atmosphere backdrop.
struct AtmosphereBackground: View {
    let accent: Color
    /// Rising carbonation (the website's signature) — enabled while a live
    /// sesh runs so the whole screen quietly says "the night is on".
    var bubbles: Bool = false

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

            if bubbles {
                RisingBubbles()
            }

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

/// The website's carbonation, in-app: faint amber bubbles rising through
/// the atmosphere. One Canvas driven by a 30fps TimelineView — a single
/// cheap layer, deterministic (no state), and absent entirely when the
/// user prefers reduced motion.
private struct RisingBubbles: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
                Canvas { g, size in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    for i in 0..<7 {
                        let fi = Double(i)
                        // 14–21s per ascent, staggered so the column never
                        // looks synchronized.
                        let duration = 14.0 + fi.truncatingRemainder(dividingBy: 3.0) * 3.5
                        let phase = (t / duration + fi * 0.37)
                            .truncatingRemainder(dividingBy: 1.0)
                        let lane = (0.06 + fi * 0.14).truncatingRemainder(dividingBy: 1.0)
                        let sway = sin((phase * 2 + fi) * .pi * 2) * 14
                        let x = lane * size.width + sway
                        let y = size.height * (1.06 - phase * 1.12)
                        let r = 2.5 + (fi * 1.7).truncatingRemainder(dividingBy: 4.5)
                        // Fade in leaving the bottom, out approaching the top.
                        let fade = min(1, min(phase / 0.08, (1 - phase) / 0.25))
                        guard fade > 0 else { continue }
                        let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                        g.stroke(
                            Circle().path(in: rect),
                            with: .color(Color.whiskey.opacity(0.35 * fade)),
                            lineWidth: 1
                        )
                        g.fill(
                            Circle().path(in: rect),
                            with: .color(Color.cream.opacity(0.09 * fade))
                        )
                    }
                }
            }
            .allowsHitTesting(false)
            .ignoresSafeArea()
        }
    }
}

/// The website's LIVE dot, in-app: a glowing whiskey dot with a sonar ring
/// pulsing outward. Ring is skipped under Reduce Motion (the glow stays).
struct SonarDot: View {
    var size: CGFloat = 7
    var color: Color = .whiskey
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.8), radius: size * 0.7)
            .overlay {
                if !reduceMotion {
                    Circle()
                        .strokeBorder(color, lineWidth: 1)
                        .scaleEffect(pulsing ? 2.6 : 0.6)
                        .opacity(pulsing ? 0 : 0.9)
                }
            }
            .onAppear {
                withAnimation(.easeOut(duration: 2.2).repeatForever(autoreverses: false)) {
                    pulsing = true
                }
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
                Text("sejdel")
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
/// The calm-pass hero: BAC readout, status, one-line advice, and the
/// sober-by milestones merged into a single surface. Replaces the old
/// BACNowCard + SoberByCard + VibeCard stack — the BAC number is the only
/// loud element on the screen.
private struct TonightHeroCard: View {
    let bac: Double
    let status: Status
    let advice: String
    let hoursSober: Double
    let hoursEU: Double
    let hoursUS: Double
    @AppStorage(BACUnitSetting.key, store: BACUnitSetting.store) private var bacUnitMode = "auto"
    private var bacUnit: BACUnit { BACUnitSetting.resolved(mode: bacUnitMode) }
    private var soberAt: Date { Date().addingTimeInterval(hoursSober * 3600) }

    var body: some View {
        CalmCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    SectionLabel("Right now")
                    Spacer()
                    StatusPill(status: status)
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(bacUnit.formatted(bac))
                        .font(CalmType.hero(46))
                        .tracking(-1.5)
                        .foregroundStyle(status.color)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: bac))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(bacUnit.caption)
                        .font(CalmType.label(12))
                        .tracking(2)
                        .foregroundStyle(Color.bronze)
                        .padding(.bottom, 8)
                }

                BACScale(bac: bac, status: status)

                Text(advice)
                    .font(CalmType.body())
                    .foregroundStyle(Color.cream.opacity(0.82))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                if hoursSober > 0 {
                    CalmDivider()
                    HStack(spacing: 0) {
                        soberColumn(
                            label: "CLEAR",
                            value: SoberByCard.formatDuration(hoursSober),
                            detail: soberAt.formatted(.dateTime.hour().minute())
                        )
                        if hoursEU > 0 {
                            soberColumn(
                                label: "EU LIMIT",
                                value: SoberByCard.formatDuration(hoursEU),
                                detail: "\(bacUnit.formattedLimit(0.02))\(bacUnit.symbol)"
                            )
                        }
                        if hoursUS > 0 {
                            soberColumn(
                                label: "US LIMIT",
                                value: SoberByCard.formatDuration(hoursUS),
                                detail: "\(bacUnit.formattedLimit(0.08))\(bacUnit.symbol)"
                            )
                        }
                    }
                }
            }
        }
    }

    private func soberColumn(label: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionLabel(label)
            Text(value)
                .font(CalmType.body(14, weight: .bold).monospacedDigit())
                .foregroundStyle(Color.cream)
                .contentTransition(.numericText())
            Text(detail)
                .font(CalmType.label(9))
                .tracking(1)
                .foregroundStyle(Color.bronze)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A quiet one-line row that expands into its control on tap — used for
/// secondary settings (like the night's duration) that used to be a full
/// standalone card.
private struct CollapsibleControlRow<Control: View>: View {
    let icon: String
    let title: String
    let valueText: String
    @ViewBuilder var control: () -> Control
    @State private var expanded = false

    var body: some View {
        CalmCard(padding: 14) {
            VStack(spacing: 4) {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        expanded.toggle()
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: icon)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.bronze)
                            .frame(width: 20)
                        Text(title)
                            .font(CalmType.body())
                            .foregroundStyle(Color.cream.opacity(0.85))
                        Spacer(minLength: 8)
                        Text(valueText)
                            .font(CalmType.body(14, weight: .bold).monospacedDigit())
                            .foregroundStyle(Color.cream)
                            .contentTransition(.numericText())
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.bronze)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded {
                    control()
                        .padding(.top, 10)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }
}

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
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(status.color)
                            .frame(width: 14)
                        Text(message.advice)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.82))
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "car.fill")
                            .font(.system(size: 10, design: .rounded))
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

struct DrinkGlyph: View {
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
            .font(.system(size: size * 0.62, design: .rounded))
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
                SectionLabel(groupActive ? "Your tab" : "Drinks")
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(order.count)")
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
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
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.whiskey)
                    Text("\(personalCount) yours · \(sharedCount) shared ÷\(max(memberCount, 1))")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(Color.cream.opacity(0.65))
                }
                .padding(.top, -4)
            }

            if order.isEmpty {
                PrimaryGlowButton(
                    title: "Order your first drink",
                    systemImage: "plus",
                    action: onOpen
                )
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
                        HStack(spacing: 8) {
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                            Text(groupActive ? "FOR ME" : "ADD A DRINK")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .tracking(1.8)
                        }
                        .foregroundStyle(Color.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.whiskey)
                        )
                        .shadow(color: Color.whiskey.opacity(0.4), radius: 14, y: 7)
                    }
                    .buttonStyle(PressScaleStyle())

                    if groupActive, let onOpenShared {
                        Button(action: onOpenShared) {
                            HStack(spacing: 8) {
                                Image(systemName: "person.2.fill")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                Text("FOR GROUP")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .tracking(1.8)
                            }
                            .foregroundStyle(Color.whiskey)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.inkElev)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Color.cream.opacity(0.1), lineWidth: 1)
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
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.inkElev)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.cream.opacity(0.06), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
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
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.cream)
                .lineLimit(1)

            Button(action: onRemoveOne) {
                Image(systemName: "minus")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
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
                            .font(.system(size: 8, weight: .bold, design: .rounded))
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
                        .font(.system(size: 11, weight: .bold, design: .rounded))
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
                        .font(.system(size: 11, weight: .bold, design: .rounded))
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
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
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
    @State private var birthdate: Date
    private let initialBirthdate: Date
    @State private var sex: Sex
    @State private var weightKg: Double

    @State private var newAvatarData: Data?
    @State private var avatarRemoved = false

    @State private var saving = false
    @State private var errorMessage: String?
    @State private var adminPanelOpen = false
    @State private var offersAdminOpen = false
    @State private var deleteConfirmOpen = false
    @State private var deleteError: String?
    @State private var friendsOpen = false

    /// Friends roster + incoming requests — shared with SessionView so the
    /// bell badge and inbox stay in sync (SessionView owns the polling).
    @ObservedObject var friends: FriendsService
    /// Timeline service — used here to load the user's own posted seshs.
    @ObservedObject var feed: FeedService
    /// Re-opens the first-run walkthrough (closes this sheet first).
    var onReplayTour: (() -> Void)? = nil
    /// Launches the full guided walkthrough over the live app.
    var onWalkthrough: (() -> Void)? = nil

    /// The user's own posted seshs (Instagram-style grid) + a tapped one.
    @State private var myPosts: [TimelinePost] = []
    @State private var selectedPost: TimelinePost?

    /// BAC display unit — "auto" (region default), "percent", or
    /// "promille". Persisted in the App Group so the widget agrees.
    @AppStorage(BACUnitSetting.key, store: BACUnitSetting.store) private var bacUnitMode = "auto"

    /// Share my live check-in on the friends map. ON by default; when off,
    /// friends still see I'm live (BAC/stories) but not where I am.
    @AppStorage(ShareLocationSetting.key) private var shareLocation = true

    /// Opt-in to push notifications for deals from nearby bars. Default OFF;
    /// the flag is mirrored to the server (set_deals_push_opt_in) so
    /// send_venue_push knows who to reach.
    @AppStorage(DealsPush.optInKey) private var dealsPushOptIn = false

    /// Contact-discovery controls. The number is never persisted — it's
    /// hashed, published, and dropped (see ContactDiscovery / migration 099).
    @StateObject private var discovery = ContactDiscovery()
    @State private var phoneEntry = ""
    @State private var phoneSaving = false
    @State private var phoneNote: String?

    /// Saved night recaps (loaded from disk on open) + which one is
    /// being replayed full-screen.
    @StateObject private var nightHistory = RecapHistoryStore()
    @State private var replayRecap: NightRecap? = nil
    /// Apple Health opt-in state (drink calories + sesh vitals).
    @ObservedObject private var health = HealthService.shared

    private let postCols = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)

    init(
        profile: Profile, auth: AuthService, admin: AdminService,
        friends: FriendsService, feed: FeedService,
        onReplayTour: (() -> Void)? = nil,
        onWalkthrough: (() -> Void)? = nil
    ) {
        self.profile = profile
        self.auth = auth
        self.admin = admin
        self.onWalkthrough = onWalkthrough
        self.friends = friends
        self.feed = feed
        self.onReplayTour = onReplayTour
        _name = State(initialValue: profile.name)
        let startBirthdate = profile.birthdate.flatMap(BirthdateMath.date(fromISO:))
            ?? Calendar.current.date(byAdding: .year, value: -profile.age, to: .now)
            ?? .now
        initialBirthdate = startBirthdate
        _birthdate = State(initialValue: startBirthdate)
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
            || birthdate != initialBirthdate
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
                        SectionLabel("Profile")
                        Text(profile.name)
                            .font(.system(size: 36, weight: .heavy, design: .rounded))
                            .tracking(-1.2)
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
                        LoungePickerField(label: "BIRTHDATE") {
                            HStack(spacing: 10) {
                                DatePicker("", selection: $birthdate,
                                           in: BirthdateMath.range,
                                           displayedComponents: .date)
                                    .datePickerStyle(.compact)
                                    .labelsHidden()
                                    .tint(Color.whiskey)
                                    .colorScheme(.dark)
                                Spacer(minLength: 0)
                                Text("\(BirthdateMath.age(on: birthdate)) YRS")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .tracking(1.5)
                                    .foregroundStyle(Color.bronze)
                            }
                        }
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
                        LoungePickerField(label: "SHARE LOCATION") {
                            VStack(alignment: .leading, spacing: 6) {
                                Toggle(isOn: $shareLocation) {
                                    Text("Show my check-in on the friends map")
                                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                                        .foregroundStyle(Color.cream)
                                }
                                .toggleStyle(SwitchToggleStyle(tint: .whiskey))
                                Text(shareLocation
                                     ? "Friends can see where you're checked in while you're live."
                                     : "Friends still see you're out — just not where.")
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.cream.opacity(0.55))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, 4)
                            }
                        }
                        if health.isAvailable {
                            LoungePickerField(label: "APPLE HEALTH") {
                                VStack(alignment: .leading, spacing: 6) {
                                    Toggle(isOn: Binding(
                                        get: { health.isConnected },
                                        set: { on in
                                            if on { Task { await health.connect() } }
                                            else { health.disconnect() }
                                        }
                                    )) {
                                        Text("Sync drinks & sesh vitals with Apple Health")
                                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                                            .foregroundStyle(Color.cream)
                                    }
                                    .toggleStyle(SwitchToggleStyle(tint: .whiskey))
                                    Text("Writes each drink's calories and standard drinks to Health, and reads your steps, heart rate and active energy during a sesh. Estimates only.")
                                        .font(.system(size: 11, weight: .medium, design: .rounded))
                                        .foregroundStyle(Color.cream.opacity(0.55))
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.horizontal, 4)
                                }
                            }
                        }
                        LoungePickerField(label: "LET FRIENDS FIND YOU") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Add your number and friends who have it in their contacts can find you. We store a scrambled code, never the number itself.")
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.cream.opacity(0.55))
                                    .fixedSize(horizontal: false, vertical: true)
                                HStack(spacing: 8) {
                                    TextField("+46 70 123 45 67", text: $phoneEntry)
                                        .keyboardType(.phonePad)
                                        .textContentType(.telephoneNumber)
                                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                                        .foregroundStyle(Color.cream)
                                        .padding(.horizontal, 12).padding(.vertical, 10)
                                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                                            .fill(Color.cream.opacity(0.05)))
                                    Button {
                                        let raw = phoneEntry
                                        phoneSaving = true
                                        Task {
                                            let ok = await discovery.publishPhoneKey(raw)
                                            await MainActor.run {
                                                phoneSaving = false
                                                phoneNote = ok
                                                    ? "Saved — friends with your number can find you."
                                                    : "Couldn't save that number."
                                                if ok { phoneEntry = "" }
                                            }
                                        }
                                    } label: {
                                        if phoneSaving {
                                            ProgressView().tint(Color.ink)
                                                .frame(width: 46, height: 40)
                                        } else {
                                            Text("SAVE")
                                                .font(.system(size: 10.5, weight: .black, design: .monospaced))
                                                .tracking(1.1)
                                                .foregroundStyle(Color.ink)
                                                .padding(.horizontal, 14).padding(.vertical, 12)
                                        }
                                    }
                                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .fill(Color.whiskey))
                                    .buttonStyle(PressScaleStyle())
                                    .disabled(phoneEntry.trimmingCharacters(in: .whitespaces).count < 6 || phoneSaving)
                                }
                                if let n = phoneNote {
                                    Text(n)
                                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                                        .foregroundStyle(Color.whiskey)
                                }
                                Button {
                                    Task {
                                        await discovery.clearMyKeys()
                                        await MainActor.run { phoneNote = "Removed. You're no longer findable by contacts." }
                                    }
                                } label: {
                                    Text("Remove my codes")
                                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                                        .foregroundStyle(Color.cream.opacity(0.5))
                                        .underline()
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        LoungePickerField(label: "DEAL ALERTS") {
                            VStack(alignment: .leading, spacing: 6) {
                                Toggle(isOn: $dealsPushOptIn) {
                                    Text("Deals from nearby bars")
                                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                                        .foregroundStyle(Color.cream)
                                }
                                .toggleStyle(SwitchToggleStyle(tint: .whiskey))
                                Text(dealsPushOptIn
                                     ? "You'll get the occasional push when a nearby bar drops a deal."
                                     : "No deal pushes. Turn on for happy-hour heads-ups near you.")
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.cream.opacity(0.55))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, 4)
                            }
                        }
                    }
                    .onChange(of: dealsPushOptIn) { _, on in
                        // Mirror the preference to the server (audience list).
                        DealsPush.setOptIn(on)
                        DealsPush.markPrompted()
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
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
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
                            .font(.system(size: 12, design: .rounded))
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
                                    age: BirthdateMath.age(on: birthdate),
                                    sex: sex,
                                    weightKg: weightKg,
                                    avatarURL: profile.avatarURL,
                                    username: profile.username,
                                    birthdate: BirthdateMath.iso(birthdate)
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
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(Color.ink)
                        .padding(.vertical, 16)
                        .padding(.horizontal, 20)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(dirty ? Color.cream : Color.cream.opacity(0.35))
                        )
                        .shadow(color: .black.opacity(dirty ? 0.4 : 0), radius: 14, y: 7)
                    }
                    .disabled(!dirty || saving)
                    .buttonStyle(PressScaleStyle())

                    // Friends — manage your crew + invite them to seshes.
                    Button {
                        friendsOpen = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "person.2.fill")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
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
                                .font(.system(size: 12, weight: .bold, design: .rounded))
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
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
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
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
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
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
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
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
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
                    if let supportURL = URL(string: "mailto:contact@sejdel.com?subject=sejdel%20support") {
                        Link(destination: supportURL) {
                            HStack(spacing: 10) {
                                Image(systemName: "envelope.fill")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
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
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
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

                    // Full guided walkthrough — steps through every live screen
                    // and annotates its functions.
                    if let onWalkthrough {
                        Button {
                            dismiss()
                            onWalkthrough()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.whiskey)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("FULL WALKTHROUGH")
                                        .font(.system(size: 12, weight: .black, design: .monospaced))
                                        .tracking(2.0)
                                        .foregroundStyle(Color.cream)
                                    Text("A guided tour of every screen and what it does.")
                                        .font(.system(size: 11, weight: .medium, design: .rounded))
                                        .foregroundStyle(Color.cream.opacity(0.55))
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
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

                    // Replay the first-run tour — for anyone who skipped it
                    // or wants the 30-second refresher.
                    if let onReplayTour {
                        Button {
                            dismiss()
                            onReplayTour()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "questionmark.circle.fill")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.whiskey)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("REPLAY THE TOUR")
                                        .font(.system(size: 12, weight: .black, design: .monospaced))
                                        .tracking(2.0)
                                        .foregroundStyle(Color.cream)
                                    Text("A 30-second tour of the four tabs.")
                                        .font(.system(size: 11, weight: .medium, design: .rounded))
                                        .foregroundStyle(Color.cream.opacity(0.55))
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
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
                                .font(.system(size: 12, weight: .bold, design: .rounded))
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

                    // App Store 5.1.1(v): deletion must be reachable in-app.
                    Button { deleteConfirmOpen = true } label: {
                        HStack {
                            Image(systemName: "trash")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                            Text("DELETE ACCOUNT")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .tracking(2.4)
                            Spacer()
                        }
                        .foregroundStyle(Status.danger.color)
                        .padding(.vertical, 14)
                        .padding(.horizontal, 18)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Status.danger.color.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Status.danger.color.opacity(0.25), lineWidth: 1)
                        )
                    }
                    .buttonStyle(PressScaleStyle())
                    .alert("Delete your account?", isPresented: $deleteConfirmOpen) {
                        Button("Cancel", role: .cancel) {}
                        Button("Delete forever", role: .destructive) {
                            Task {
                                do {
                                    try await auth.deleteAccount()
                                    dismiss()
                                } catch {
                                    deleteError = (error as? LocalizedError)?.errorDescription
                                        ?? "Something went wrong."
                                }
                            }
                        }
                    } message: {
                        Text("Your profile, nights, stories, messages and photos are permanently deleted. Beer prices you've added stay on the map without your name. This can't be undone.")
                    }
                    .alert("Couldn't delete account",
                           isPresented: .init(get: { deleteError != nil },
                                              set: { if !$0 { deleteError = nil } })) {
                        Button("OK", role: .cancel) {}
                    } message: {
                        Text(deleteError ?? "")
                    }

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
            FriendsView(friends: friends, auth: auth, feed: feed)
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
                                .font(.system(size: 15, weight: .black, design: .rounded))
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
                                .font(.system(size: 12, weight: .bold, design: .rounded))
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
    /// Paid placement level + artwork + lifetime stats (migration 054/056).
    var placement: String = "pin"
    var imageUrl: String? = nil
    var billboardImageUrl: String? = nil
    /// App-open interstitial add-on flag (migration 057).
    var interstitial: Bool = false
    /// Display schedule flag (migration 060) — show only on valid days/times.
    var showOnValidOnly: Bool = false
    var impressions: Int = 0
    var taps: Int = 0
    /// Last-7-day impressions/taps for the admin "this week" line (migration 057).
    var weekImpressions: Int = 0
    var weekTaps: Int = 0

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
        case placement
        case imageUrl = "image_url"
        case billboardImageUrl = "billboard_image_url"
        case interstitial
        case showOnValidOnly = "show_on_valid_only"
        case impressions, taps
        case weekImpressions = "week_impressions"
        case weekTaps = "week_taps"
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

    /// Upload campaign artwork (downscaled + thumbnail via StorageUploader)
    /// to the venue's folder in campaign-art; returns the public URL.
    private func uploadArt(venueExternalId: String?, imageData: Data) async -> String? {
        guard let jpeg = ImageDownscale.jpeg(imageData, maxDim: 1400, quality: 0.72) else { return nil }
        let folder = (venueExternalId ?? UUID().uuidString).replacingOccurrences(of: "/", with: "_")
        let path = "\(folder)/\(UUID().uuidString.lowercased()).jpg"
        do {
            try await StorageUploader.uploadImage(bucket: "campaign-art", path: path, data: jpeg)
            return try supabase.storage.from("campaign-art").getPublicURL(path: path).absoluteString
        } catch {
            return nil
        }
    }

    @discardableResult
    func create(
        venue: MapKitVenueResult,
        kind: String, title: String, description: String, finePrint: String,
        placement: String, posterImageData: Data?, billboardImageData: Data?,
        startsAt: Date, endsAt: Date?, activeDays: [Int]?, startMinute: Int?, endMinute: Int?,
        interstitial: Bool, showOnValidOnly: Bool
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
            let p_placement: String
            let p_image_url: String?
            let p_billboard_image_url: String?
            let p_interstitial: Bool
            let p_show_on_valid_only: Bool
        }
        let iso = ISO8601DateFormatter()
        lastError = nil
        var posterURL: String? = nil, billboardURL: String? = nil
        if let d = posterImageData { posterURL = await uploadArt(venueExternalId: venue.id, imageData: d) }
        if let d = billboardImageData { billboardURL = await uploadArt(venueExternalId: venue.id, imageData: d) }
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
                p_end_minute: endMinute,
                p_placement: placement,
                p_image_url: posterURL,
                p_billboard_image_url: billboardURL,
                p_interstitial: interstitial,
                p_show_on_valid_only: showOnValidOnly
            )).execute()
            await load()
            return true
        } catch {
            lastError = String(describing: error)
            return false
        }
    }

    /// Edit a campaign in place — shift the start/end dates, change the copy,
    /// swap artwork, or move up/down the pin→poster→billboard ladder.
    @discardableResult
    func update(
        offer: AdminOffer, venueExternalId: String?,
        kind: String, title: String, description: String, finePrint: String,
        placement: String, posterImageData: Data?, billboardImageData: Data?,
        startsAt: Date?, endsAt: Date?, activeDays: [Int]?, startMinute: Int?, endMinute: Int?,
        interstitial: Bool, showOnValidOnly: Bool
    ) async -> Bool {
        struct P: Encodable {
            let p_offer_id: String
            let p_kind: String
            let p_title: String
            let p_description: String?
            let p_fine_print: String?
            let p_starts_at: String?
            let p_ends_at: String?
            let p_active_days: [Int]?
            let p_start_minute: Int?
            let p_end_minute: Int?
            let p_placement: String
            let p_image_url: String?
            let p_billboard_image_url: String?
            let p_interstitial: Bool
            let p_show_on_valid_only: Bool
        }
        let iso = ISO8601DateFormatter()
        lastError = nil
        // Only upload when the admin picked a NEW image; nil keeps the
        // existing artwork (the RPC coalesces).
        var posterURL: String? = nil, billboardURL: String? = nil
        if let d = posterImageData { posterURL = await uploadArt(venueExternalId: venueExternalId, imageData: d) }
        if let d = billboardImageData { billboardURL = await uploadArt(venueExternalId: venueExternalId, imageData: d) }
        do {
            _ = try await supabase.rpc("admin_update_offer", params: P(
                p_offer_id: offer.id.uuidString.lowercased(),
                p_kind: kind,
                p_title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                p_description: description.isEmpty ? nil : description,
                p_fine_print: finePrint.isEmpty ? nil : finePrint,
                p_starts_at: startsAt.map { iso.string(from: $0) },
                p_ends_at: endsAt.map { iso.string(from: $0) },
                p_active_days: activeDays,
                p_start_minute: startMinute,
                p_end_minute: endMinute,
                p_placement: placement,
                p_image_url: posterURL,
                p_billboard_image_url: billboardURL,
                p_interstitial: interstitial,
                p_show_on_valid_only: showOnValidOnly
            )).execute()
            await load()
            return true
        } catch {
            lastError = String(describing: error)
            return false
        }
    }

    /// Fire an opt-in deal push for a campaign's venue. Returns the recipient
    /// count on success, else throws so the caller can show the reason
    /// (weekly_cap / quiet_hours / not_admin).
    @discardableResult
    func sendPush(offerId: UUID, title: String, body: String) async throws -> Int {
        struct P: Encodable { let p_offer_id: String; let p_title: String; let p_body: String }
        return try await supabase.rpc("send_venue_push", params: P(
            p_offer_id: offerId.uuidString.lowercased(),
            p_title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            p_body: body.trimmingCharacters(in: .whitespacesAndNewlines)
        )).execute().value
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
    /// A campaign the admin tapped to edit in place (nil = creating new).
    @State private var editing: AdminOffer?
    /// A campaign the admin is composing an opt-in deal push for.
    @State private var pushTarget: AdminOffer?
    @State private var qrAdminOpen = false
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
                            Text("Campaigns")
                                .font(.system(size: 26, weight: .heavy, design: .rounded))
                                .foregroundStyle(Color.cream)
                        }
                        Spacer()
                        Button(action: { dismiss() }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.cream.opacity(0.6))
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(Color.cream.opacity(0.06)))
                        }
                        .buttonStyle(PressScaleStyle())
                    }

                    // Stats at a glance — aggregate across every live campaign
                    // this week (each row below breaks it down per campaign).
                    if !svc.offers.isEmpty {
                        let wImp = svc.offers.reduce(0) { $0 + $1.weekImpressions }
                        let wTap = svc.offers.reduce(0) { $0 + $1.weekTaps }
                        HStack(spacing: 0) {
                            statCell("VIEWS", wImp)
                            Rectangle().fill(Color.cream.opacity(0.08)).frame(width: 1, height: 34)
                            statCell("TAPS", wTap)
                            Rectangle().fill(Color.cream.opacity(0.08)).frame(width: 1, height: 34)
                            statCell("LIVE", svc.offers.count)
                        }
                        .padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.cream.opacity(0.04)))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.cream.opacity(0.08), lineWidth: 1))
                        Text("THIS WEEK · tap a campaign for its own numbers")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .tracking(1.5)
                            .foregroundStyle(Color.cream.opacity(0.4))
                    }

                    Button { addOpen = true } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.ink)
                            Text("New campaign")
                                .font(.system(size: 15, weight: .heavy, design: .rounded))
                                .foregroundStyle(Color.ink)
                            Spacer()
                        }
                        .padding(.vertical, 14).padding(.horizontal, 16)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.whiskey))
                    }
                    .buttonStyle(PressScaleStyle())

                    Button { qrAdminOpen = true } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "qrcode")
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.whiskey)
                            Text("Check-in QR codes")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.cream)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.bronze)
                        }
                        .padding(.vertical, 13).padding(.horizontal, 16)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.whiskey.opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.whiskey.opacity(0.3), lineWidth: 1))
                    }
                    .buttonStyle(PressScaleStyle())

                    if svc.offers.isEmpty {
                        Text(svc.loading ? "Loading…" : "No campaigns yet. Create one above.")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.5))
                            .padding(.vertical, 24)
                    } else {
                        Text("Tap a campaign to edit · expired ones auto-delete")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.45))
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
        .sheet(isPresented: $qrAdminOpen) {
            QRAdminSheet()
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.ink)
        }
        .sheet(isPresented: $addOpen) {
            CampaignComposer(svc: svc, editing: nil) { addOpen = false }
                .presentationBackground(Color.ink)
        }
        .sheet(item: $editing) { offer in
            CampaignComposer(svc: svc, editing: offer) { editing = nil }
                .presentationBackground(Color.ink)
        }
        .sheet(item: $pushTarget) { offer in
            PushComposer(svc: svc, offer: offer) { pushTarget = nil }
                .presentationDetents([.medium])
                .presentationBackground(Color.ink)
        }
    }

    private func statCell(_ label: String, _ value: Int) -> some View {
        VStack(spacing: 3) {
            Text("\(value)")
                .font(.system(size: 22, weight: .black, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.cream)
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(Color.bronze)
        }
        .frame(maxWidth: .infinity)
    }

    private func adminOfferRow(_ o: AdminOffer) -> some View {
        VStack(spacing: 0) {
            // Tap the main body to edit the campaign in place.
            Button { editing = o } label: {
                HStack(alignment: .top, spacing: 12) {
                    // Artwork thumbnail for poster/billboard campaigns.
                    if let s = o.imageUrl, let url = URL(string: s) {
                        DownsampledAsyncImage(url: url, targetPoints: 46)
                            .frame(width: 46, height: 46)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(o.title)
                                .font(.system(size: 15, weight: .heavy, design: .rounded))
                                .foregroundStyle(Color.cream)
                                .lineLimit(1)
                            PlacementTag(placement: o.placement)
                            if o.interstitial {
                                Image(systemName: "rectangle.portrait.on.rectangle.portrait.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Color.whiskey)
                            }
                        }
                        Text(o.venueName)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.7))
                            .lineLimit(1)
                        Text(o.scheduleSummary)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.bronze)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.35))
                        .padding(.top, 4)
                }
                .padding(14)
            }
            .buttonStyle(PressScaleStyle())

            Rectangle().fill(Color.cream.opacity(0.07)).frame(height: 1)

            // Stats + push footer. "This week" is the screenshot number for
            // bars; the paper-plane fires an opt-in deal push.
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("THIS WEEK  \(o.weekImpressions) views · \(o.weekTaps) taps")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.cream.opacity(0.7))
                    Text("all time  \(o.impressions) · \(o.taps)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.cream.opacity(0.4))
                }
                Spacer()
                Button { pushTarget = o } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "paperplane.fill").font(.system(size: 10, weight: .bold))
                        Text("PUSH").font(.system(size: 10, weight: .black, design: .monospaced)).tracking(1)
                    }
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(Color.whiskey))
                }
                .buttonStyle(PressScaleStyle())
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.cream.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.cream.opacity(0.08), lineWidth: 1))
    }
}

/// Compose + fire an opt-in "deal from a nearby bar" push for one campaign.
/// Server enforces the weekly cap + quiet hours; we surface the reason on a
/// rejection so the admin knows why nothing sent.
private struct PushComposer: View {
    @ObservedObject var svc: OffersAdminService
    let offer: AdminOffer
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var pushTitle: String
    @State private var pushBody: String
    @State private var phase: Phase = .idle

    enum Phase: Equatable { case idle, sending, sent(Int), failed(String) }

    init(svc: OffersAdminService, offer: AdminOffer, onDone: @escaping () -> Void) {
        self.svc = svc
        self.offer = offer
        self.onDone = onDone
        _pushTitle = State(initialValue: offer.venueName)
        _pushBody  = State(initialValue: offer.title)
    }

    private var canSend: Bool {
        !pushTitle.trimmingCharacters(in: .whitespaces).isEmpty
            && !pushBody.trimmingCharacters(in: .whitespaces).isEmpty
            && phase != .sending
    }

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                Text("SEND A DEAL PUSH")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(2).foregroundStyle(Color.bronze)
                Text("Goes to everyone who opted in to nearby-bar deals. Capped at 3/week per bar; muted 04:00–10:00.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.5))

                field("TITLE", text: $pushTitle, placeholder: offer.venueName)
                field("MESSAGE", text: $pushBody, placeholder: offer.title, multiline: true)

                switch phase {
                case .sent(let n):
                    Label("Sent to \(n) \(n == 1 ? "person" : "people")", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.whiskey)
                case .failed(let msg):
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.red.opacity(0.9))
                default:
                    EmptyView()
                }

                Spacer()
                Button(action: send) {
                    HStack(spacing: 8) {
                        if phase == .sending { ProgressView().tint(Color.ink) }
                        Text(phase == .sending ? "SENDING…" : "SEND PUSH")
                            .font(.system(size: 14, weight: .bold, design: .monospaced)).tracking(1.5)
                    }
                    .foregroundStyle(Color.ink)
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(canSend ? Color.whiskey : Color.cream.opacity(0.15)))
                }
                .buttonStyle(PressScaleStyle())
                .disabled(!canSend)
            }
            .padding(22)
        }
        .preferredColorScheme(.dark)
    }

    private func send() {
        phase = .sending
        Task {
            do {
                let n = try await svc.sendPush(offerId: offer.id, title: pushTitle, body: pushBody)
                phase = .sent(n)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                onDone(); dismiss()
            } catch {
                phase = .failed(Self.friendlyError(error))
            }
        }
    }

    /// Map the RPC's raised exceptions to something the admin can act on.
    private static func friendlyError(_ error: Error) -> String {
        let s = String(describing: error).lowercased()
        if s.contains("weekly_cap") { return "Weekly limit reached (3/week for this bar)." }
        if s.contains("quiet_hours") { return "Quiet hours — deal pushes pause 04:00–10:00." }
        if s.contains("empty") { return "Add a title and a message." }
        if s.contains("not_admin") { return "Admins only." }
        return "Couldn't send. Try again."
    }

    @ViewBuilder
    private func field(_ label: String, text: Binding<String>, placeholder: String, multiline: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(2).foregroundStyle(Color.bronze)
            TextField("", text: text,
                      prompt: Text(placeholder).foregroundStyle(Color.cream.opacity(0.35)),
                      axis: multiline ? .vertical : .horizontal)
                .lineLimit(multiline ? 1...3 : 1...1)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.cream)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.cream.opacity(0.05)))
        }
    }
}

/// pin / POSTER / BILLBOARD tag — the placement level at a glance.
private struct PlacementTag: View {
    let placement: String
    var body: some View {
        Text(placement.uppercased())
            .font(.system(size: 8, weight: .black, design: .monospaced))
            .tracking(0.8)
            .foregroundStyle(placement == "pin" ? Color.cream.opacity(0.7) : Color.ink)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(color))
    }
    private var color: Color {
        switch placement {
        case "billboard": return .whiskey
        case "poster":    return .foam
        default:          return Color.cream.opacity(0.12)
        }
    }
}

/// The add-offer form: pick a bar on the map, write the offer, choose when.
/// New / edit campaign: search a bar, write the offer, pick the placement
/// level (pin / poster / billboard) + artwork, choose when. Editing an
/// existing campaign locks the venue and pre-fills every field.
private struct CampaignComposer: View {
    @ObservedObject var svc: OffersAdminService
    /// nil → creating; non-nil → editing this campaign in place.
    let editing: AdminOffer?
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    @StateObject private var location = LocationService()
    @StateObject private var search = MapKitVenueSearch()
    @State private var query = ""
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var selected: MapKitVenueResult?

    @State private var kind: String
    @State private var title: String
    @State private var desc: String
    @State private var finePrint: String
    @State private var placement: String
    @State private var days: Set<Int>
    @State private var allDay: Bool
    @State private var startTime: Date
    @State private var endTime: Date
    @State private var startDate: Date
    @State private var hasEnd: Bool
    @State private var endDate: Date
    @State private var posterItem: PhotosPickerItem?
    @State private var posterData: Data?
    @State private var billboardItem: PhotosPickerItem?
    @State private var billboardData: Data?
    @State private var interstitial: Bool
    @State private var showOnValidOnly: Bool
    @State private var saving = false

    private let kinds = ["price", "happy_hour", "free_entry", "bundle", "event"]
    private let dayLabels = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]

    init(svc: OffersAdminService, editing: AdminOffer?, onDone: @escaping () -> Void) {
        self.svc = svc
        self.editing = editing
        self.onDone = onDone
        let o = editing
        _kind      = State(initialValue: o?.kind ?? "price")
        _title     = State(initialValue: o?.title ?? "")
        _desc      = State(initialValue: o?.description ?? "")
        _finePrint = State(initialValue: o?.finePrint ?? "")
        _placement = State(initialValue: o?.placement ?? "pin")
        _days      = State(initialValue: Set(o?.activeDays ?? []))
        _allDay    = State(initialValue: o?.startMinute == nil)
        let cal = Calendar.current
        func time(_ m: Int?, default def: Int) -> Date {
            let mins = m ?? def
            return cal.date(bySettingHour: mins / 60, minute: mins % 60, second: 0, of: Date()) ?? Date()
        }
        _startTime = State(initialValue: time(o?.startMinute, default: 16 * 60))
        _endTime   = State(initialValue: time(o?.endMinute, default: 19 * 60))
        _startDate = State(initialValue: o?.startsAt ?? Date())
        _hasEnd    = State(initialValue: o?.endsAt != nil)
        _endDate   = State(initialValue: o?.endsAt ?? Date().addingTimeInterval(7 * 24 * 3600))
        _interstitial = State(initialValue: o?.interstitial ?? false)
        _showOnValidOnly = State(initialValue: o?.showOnValidOnly ?? false)
    }

    private var isEditing: Bool { editing != nil }

    private var canSave: Bool {
        (isEditing || selected != nil)
            && !title.trimmingCharacters(in: .whitespaces).isEmpty
            && !saving
    }

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text(isEditing ? "Edit campaign" : "New campaign")
                            .font(.system(size: 24, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color.cream)
                        Spacer()
                        Button(action: { dismiss() }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.cream.opacity(0.6))
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(Color.cream.opacity(0.06)))
                        }
                        .buttonStyle(PressScaleStyle())
                    }

                    if isEditing {
                        fixedVenueHeader
                        if let o = editing { campaignStats(o) }
                        offerForm
                    } else {
                        venuePicker
                        if selected != nil { offerForm }
                    }
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

    /// This campaign's own performance — the numbers to screenshot for the
    /// bar. THIS WEEK (last 7 days) up top, lifetime underneath.
    private func campaignStats(_ o: AdminOffer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            kicker("PERFORMANCE · THIS WEEK")
            HStack(spacing: 0) {
                statCell("TIMES SHOWN", o.weekImpressions)
                Rectangle().fill(Color.cream.opacity(0.08)).frame(width: 1, height: 40)
                statCell("TAP-THROUGHS", o.weekTaps)
            }
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cream.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.cream.opacity(0.08), lineWidth: 1))
            Text("How often it appeared on the Deals map, and how many times people opened the deal. All time: \(o.impressions) shown · \(o.taps) opened.")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statCell(_ label: String, _ value: Int) -> some View {
        statCell(label, "\(value)")
    }

    private func statCell(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 22, weight: .black, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.cream)
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1.3)
                .foregroundStyle(Color.bronze)
        }
        .frame(maxWidth: .infinity)
    }

    /// Edit mode: the venue is locked (you're editing that bar's campaign),
    /// shown read-only so there's nothing to re-pick.
    private var fixedVenueHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            kicker("VENUE")
            Text(editing?.venueName ?? "—")
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.cream)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.whiskey.opacity(0.1)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.whiskey.opacity(0.4), lineWidth: 1))
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
                                Image(systemName: "mappin").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(Color.ink)
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
                            Image(systemName: "mappin.circle.fill").font(.system(size: 16, design: .rounded)).foregroundStyle(Color.whiskey)
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
            // Placement is the price ladder: pin (map dot) → poster (branded
            // card) → billboard (hero carousel). Poster+ needs artwork.
            VStack(alignment: .leading, spacing: 7) {
                kicker("PLACEMENT")
                Picker("", selection: $placement) {
                    Text("Pin").tag("pin")
                    Text("Poster").tag("poster")
                    Text("Billboard").tag("billboard")
                }
                .pickerStyle(.segmented)
                Text(placementHint)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.cream.opacity(0.45))
            }

            // Poster art (poster + billboard). Billboard adds a wide image too.
            if placement != "pin" {
                artPicker(title: "POSTER IMAGE (4:3)", ratio: CampaignArt.posterRatio,
                          item: $posterItem, data: $posterData, existing: editing?.imageUrl)
            }
            if placement == "billboard" {
                artPicker(title: "BILLBOARD IMAGE (3:1)", ratio: CampaignArt.billboardRatio,
                          item: $billboardItem, data: $billboardData, existing: editing?.billboardImageUrl)
            }

            // App-open interstitial add-on. Needs artwork, so pin campaigns
            // can't opt in. Shows the offer full-screen once per user.
            if placement != "pin" {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: $interstitial) {
                        Text("App-open interstitial")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.cream)
                    }
                    .tint(Color.whiskey)
                    Text("Full-screen promo shown once when a nearby user opens the app.")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.cream.opacity(0.45))
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.cream.opacity(0.05)))
            }

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
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(Color.bronze)
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
                kicker("VALID ON THESE DAYS")
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
                // Clarify: days limit REDEMPTION, not visibility. The campaign
                // markets across its whole start→end window regardless.
                Text(days.isEmpty
                     ? "Valid every day it's live."
                     : "Shows all week; deal only redeemable on the selected days.")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.cream.opacity(0.5))
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

            // Display schedule: market the whole window, or only appear on the
            // valid days/times (a day-of reminder, e.g. Wednesday evenings).
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $showOnValidOnly) {
                    Text("Only show on the valid days & times")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.cream)
                }
                .tint(Color.whiskey)
                Text(showOnValidOnly
                     ? "Card appears only on the selected days\(allDay ? "" : " during the time window") — a day-of reminder."
                     : "Card is marketed across the whole window below.")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.cream.opacity(0.45))
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.cream.opacity(0.05)))

            // Marketing window: when the campaign starts showing, and (opt) ends.
            VStack(alignment: .leading, spacing: 8) {
                kicker("MARKETING WINDOW")
                DatePicker("Starts", selection: $startDate, displayedComponents: .date)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.7))
                    .tint(Color.whiskey)
                Toggle(isOn: $hasEnd) {
                    Text("Has an end date").font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(Color.cream)
                }
                .tint(Color.whiskey)
                if hasEnd {
                    DatePicker("Ends", selection: $endDate, in: startDate..., displayedComponents: .date)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.7))
                        .tint(Color.whiskey)
                }
            }

            Button(action: save) {
                HStack {
                    if saving { ProgressView().tint(Color.ink) }
                    Text(saving ? "Saving…" : (isEditing ? "Save changes" : "Launch campaign"))
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

    private var placementHint: String {
        switch placement {
        case "poster":    return "Branded card + artwork map pin"
        case "billboard": return "Everything + hero carousel on Deals"
        default:          return "A dot on the deals map"
        }
    }

    /// One artwork picker at a fixed aspect ratio. Shows the newly-picked
    /// image, else the existing artwork (edit), else a dashed placeholder.
    @ViewBuilder
    private func artPicker(
        title: String, ratio: CGFloat,
        item: Binding<PhotosPickerItem?>, data: Binding<Data?>, existing: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            kicker(title)
            PhotosPicker(selection: item, matching: .images) {
                // Color.clear fixes the ratio box; the greedy fill image lives
                // in an overlay so it crops to the frame instead of stretching
                // it — exactly how it renders on the map.
                Color.clear
                    .aspectRatio(ratio, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        ZStack {
                            Color.smoke
                            if let d = data.wrappedValue, let img = UIImage(data: d) {
                                Image(uiImage: img).resizable().scaledToFill()
                            } else if let s = existing, let url = URL(string: s) {
                                DownsampledAsyncImage(url: url, targetPoints: 360)
                            } else {
                                VStack(spacing: 4) {
                                    Image(systemName: "photo.badge.plus")
                                        .font(.system(size: 20, design: .rounded))
                                    Text("Pick artwork")
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                }
                                .foregroundStyle(Color.cream.opacity(0.6))
                            }
                            if data.wrappedValue == nil, existing != nil {
                                Text("Tap to replace")
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.cream)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Capsule().fill(Color.ink.opacity(0.7)))
                                    .frame(maxHeight: .infinity, alignment: .bottom)
                                    .padding(8)
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.cream.opacity(0.12), lineWidth: 1))
            }
            .onChange(of: item.wrappedValue) { _, newItem in
                guard let newItem else { return }
                Task { data.wrappedValue = try? await newItem.loadTransferable(type: Data.self) }
            }
        }
    }

    private func save() {
        saving = true
        func minutes(_ d: Date) -> Int {
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            return (c.hour ?? 0) * 60 + (c.minute ?? 0)
        }
        let startMin = allDay ? nil : minutes(startTime)
        let endMin   = allDay ? nil : minutes(endTime)
        let daysArg  = days.isEmpty ? nil : days.sorted()
        // Only send artwork for placements that use it.
        let poster    = placement != "pin" ? posterData : nil
        let billboard = placement == "billboard" ? billboardData : nil
        // Interstitial needs artwork; a pin can never be one.
        let inter     = placement != "pin" && interstitial
        Task {
            let ok: Bool
            if let editing {
                ok = await svc.update(
                    offer: editing, venueExternalId: nil,
                    kind: kind, title: title, description: desc, finePrint: finePrint,
                    placement: placement, posterImageData: poster, billboardImageData: billboard,
                    startsAt: startDate, endsAt: hasEnd ? endDate : nil, activeDays: daysArg,
                    startMinute: startMin, endMinute: endMin, interstitial: inter,
                    showOnValidOnly: showOnValidOnly
                )
            } else if let venue = selected {
                ok = await svc.create(
                    venue: venue,
                    kind: kind, title: title, description: desc, finePrint: finePrint,
                    placement: placement, posterImageData: poster, billboardImageData: billboard,
                    startsAt: startDate, endsAt: hasEnd ? endDate : nil, activeDays: daysArg,
                    startMinute: startMin, endMinute: endMin, interstitial: inter,
                    showOnValidOnly: showOnValidOnly
                )
            } else { ok = false }
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
    /// Manual entry for the "Other" catch-all category.
    @State private var customCL: String = ""
    @State private var customABV: String = ""

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
                        SectionLabel("Menu")
                        Text("Order")
                            .font(.system(size: 32, weight: .heavy, design: .rounded))
                            .tracking(-1.2)
                            .foregroundStyle(Color.cream)
                    }
                    Spacer()
                    if !order.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(order.count)")
                                .font(.system(size: 26, weight: .heavy, design: .rounded))
                                .foregroundStyle(Color.cream)
                                .monospacedDigit()
                                .contentTransition(.numericText(value: Double(order.count)))
                            Text("on tab")
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
                                .font(.system(size: 9, weight: .black, design: .rounded))
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

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(DrinkCategory.allCases) { cat in
                            CategoryTile(category: cat, selected: category == cat) {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    category = cat
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 22)
                }

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
                        if category.isCustom {
                            CustomDrinkCard(clText: $customCL, abvText: $customABV) { option in
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.72)) {
                                    onAdd(option)
                                    addedTick &+= 1
                                }
                            }
                            .transition(.opacity)
                        } else {
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
                    .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
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
            HStack(spacing: 7) {
                categoryGlyph(category, size: 24)
                Text(category.label.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(selected ? Color.whiskey : Color.bronze)
                    .lineLimit(1)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(
                Capsule()
                    .fill(selected ? Color.cream.opacity(0.08) : Color.cream.opacity(0.02))
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        selected ? Color.whiskey.opacity(0.45) : Color.cream.opacity(0.06),
                        lineWidth: 1
                    )
            )
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
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.ink)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.whiskey))
                }
                .buttonStyle(PressScaleStyle())
                .transition(.scale.combined(with: .opacity))
            } else {
                HStack(spacing: 0) {
                    Button(action: onRemove) {
                        Image(systemName: "minus")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.cream)
                            .frame(width: 34, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScaleStyle())

                    Text("\(count)")
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.cream)
                        .monospacedDigit()
                        .frame(minWidth: 22)
                        .contentTransition(.numericText(value: Double(count)))

                    Button(action: onAdd) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
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

/// Manual drink entry for the "Other" category — the user dials in a size
/// (cl) and strength (% ABV) and adds it to the tab. Also the natural home
/// for anything scanned that doesn't map to a preset. Grams (and therefore
/// BAC) come straight from `DrinkOption.grams`, same as every preset.
private struct CustomDrinkCard: View {
    @Binding var clText: String
    @Binding var abvText: String
    let onAdd: (DrinkOption) -> Void
    @State private var addTick = 0

    private var cl: Double? {
        let v = Double(clText.replacingOccurrences(of: ",", with: "."))
        guard let v, v > 0, v <= 500 else { return nil }
        return v
    }
    /// ABV percent (0…100]; anything outside is rejected.
    private var abvPct: Double? {
        let v = Double(abvText.replacingOccurrences(of: ",", with: "."))
        guard let v, v > 0, v <= 100 else { return nil }
        return v
    }
    private var abvOutOfRange: Bool {
        guard let v = Double(abvText.replacingOccurrences(of: ",", with: ".")) else { return false }
        return v <= 0 || v > 100
    }
    private var option: DrinkOption? {
        guard let cl, let abvPct else { return nil }
        let pctLabel = abvPct == abvPct.rounded() ? String(Int(abvPct)) : String(format: "%.1f", abvPct)
        let clLabel = cl == cl.rounded() ? String(Int(cl)) : String(format: "%.1f", cl)
        return DrinkOption(
            category: .other,
            name: "Custom drink",
            detail: "\(clLabel) cl · \(pctLabel)%",
            volumeML: cl * 10,
            abv: abvPct / 100.0
        )
    }
    /// Live "standard drinks" readout (12 g of alcohol per standard drink,
    /// matching the rest of the app).
    private var stdDrinks: Double? {
        guard let option else { return nil }
        return option.grams / 12.0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            entryField(kicker: "SIZE", text: $clText, placeholder: "33", suffix: "CL")
            VStack(alignment: .leading, spacing: 6) {
                entryField(kicker: "ALCOHOL", text: $abvText, placeholder: "5.0", suffix: "% ABV")
                if abvOutOfRange {
                    Text("Alcohol % must be between 0 and 100.")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(red: 0.85, green: 0.40, blue: 0.34))
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "drop.fill")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(Color.whiskey.opacity(stdDrinks == nil ? 0.25 : 0.9))
                Text(stdDrinks.map { String(format: "≈ %.1f standard drinks", $0) }
                        ?? "Enter size and % to add")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(Color.bronze)
                    .contentTransition(.numericText(value: stdDrinks ?? 0))
            }
            .padding(.top, 2)

            Button {
                guard let option else { return }
                onAdd(option)
                addTick &+= 1
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                    Text("ADD TO TAB")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .tracking(2.2)
                }
                .foregroundStyle(option == nil ? Color.bronze : Color.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(option == nil ? Color.cream.opacity(0.06) : Color.whiskey)
                )
            }
            .buttonStyle(PressScaleStyle())
            .disabled(option == nil)
            .animation(.easeOut(duration: 0.2), value: option == nil)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.cream.opacity(0.028))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.cream.opacity(0.07), lineWidth: 1)
        )
        .sensoryFeedback(.impact(weight: .light), trigger: addTick)
    }

    @ViewBuilder
    private func entryField(kicker: String, text: Binding<String>, placeholder: String, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(kicker)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(Color.bronze)
            HStack {
                TextField("", text: text, prompt: Text(placeholder)
                    .foregroundStyle(Color.cream.opacity(0.35)))
                    .textFieldStyle(.plain)
                    .keyboardType(.decimalPad)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.cream)
                Text(suffix)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.bronze)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.smoke.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.cream.opacity(0.08), lineWidth: 1)
            )
        }
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

struct TintedSlider: View {
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

struct SexToggle: View {
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

struct Disclaimer: View {
    @AppStorage(BACUnitSetting.key, store: BACUnitSetting.store) private var bacUnitMode = "auto"
    private var bacUnit: BACUnit { BACUnitSetting.resolved(mode: bacUnitMode) }

    var body: some View {
        Text("Widmark estimate based on drink volume, ABV, body weight and time. Legal limits vary: \(bacUnit.formattedLimit(0.02))\(bacUnit.symbol) in much of the EU, \(bacUnit.formattedLimit(0.08))\(bacUnit.symbol) in the US & UK. Not a legal or medical reference. Never use to decide whether to drive.")
            .font(.system(size: 11, weight: .regular, design: .rounded))
            .lineSpacing(4)
            .foregroundStyle(Color.bronze.opacity(0.85))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }
}

// MARK: - Helpers

func formatHours(_ h: Double) -> String {
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
            // Initial shows through until (and if) the avatar loads on top.
            initialText
            if let urlString, let url = URL(string: urlString) {
                DownsampledAsyncImage(url: url, targetPoints: size, placeholder: .clear)
                    .clipShape(Circle())
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
                    .font(.system(size: size * 0.18, weight: .bold, design: .rounded))
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
    /// When true, the tile is a permanent "Invite friends" CTA even while a
    /// group is active — the join code lives in the header bar instead, so
    /// this tile stays a clean invite entry point. (LIVE screen.)
    var alwaysInvite: Bool = false
    let onTap: () -> Void

    /// Show the invite CTA rather than the code+count — either idle, or
    /// because the code has been lifted to the header.
    private var showInvite: Bool { alwaysInvite || session == nil }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: compact ? 9 : 12) {
                ZStack {
                    Circle()
                        .fill(Color.whiskey.opacity(0.20))
                        .frame(width: compact ? 28 : 32, height: compact ? 28 : 32)
                    Image(systemName: "person.2.fill")
                        .font(.system(size: compact ? 12 : 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.whiskey)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(showInvite ? "INVITE" : "\(scope.label) GROUP")
                        .font(.system(size: compact ? 9 : 10, weight: .semibold, design: .monospaced))
                        .tracking(compact ? 1.6 : 2.2)
                        .foregroundStyle(Color.whiskey)
                        .lineLimit(1)
                    if !showInvite, let s = session {
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
                        Text(compact ? "Invite friends" : "Invite friends to \(scope.label.lowercased())")
                            .font(.system(size: compact ? 13.5 : 14.5, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.cream)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }

                Spacer(minLength: 0)

                if !compact {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.whiskey.opacity(0.7))
                }
            }
            .padding(.horizontal, compact ? 12 : 14)
            .padding(.vertical, compact ? 11 : 13)
            .background(
                RoundedRectangle(cornerRadius: compact ? 14 : 18, style: .continuous)
                    .fill(Color.inkElev)
                    .overlay(
                        RoundedRectangle(cornerRadius: compact ? 14 : 18, style: .continuous)
                            .fill(Color.whiskey.opacity(0.09))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 14 : 18, style: .continuous)
                    .strokeBorder(Color.whiskey.opacity(0.42), lineWidth: 1.2)
            )
            .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
            .shadow(color: Color.whiskey.opacity(0.18), radius: 11, y: 3)
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// Full-width "you're in this group" banner pinned near the top of the LIVE
/// screen. Surfaces the join code prominently so it's shareable at a glance;
/// tapping opens the group sheet (members, share, end). The side tiles then
/// stay clean — the group tile becomes a permanent "Invite friends" CTA.
private struct GroupCodeBar: View {
    let code: String
    let memberCount: Int
    var onTap: (() -> Void)? = nil

    private var content: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.whiskey.opacity(0.22))
                    .frame(width: 34, height: 34)
                Image(systemName: "person.2.fill")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.whiskey)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("LIVE GROUP")
                    .font(.system(size: 9.5, weight: .black, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(Color.whiskey)
                Text(code)
                    .font(.system(size: 20, weight: .black, design: .monospaced))
                    .tracking(3)
                    .foregroundStyle(Color.cream)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(memberCount)")
                    .font(.system(size: 18, weight: .black, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .monospacedDigit()
                Text(memberCount == 1 ? "person" : "people")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(Color.bronze)
            }
            if onTap != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.whiskey.opacity(0.7))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.whiskey.opacity(0.13))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.whiskey.opacity(0.4), lineWidth: 1.2)
        )
        .shadow(color: Color.whiskey.opacity(0.15), radius: 12, y: 4)
    }

    var body: some View {
        if let onTap {
            Button(action: onTap) { content }
                .buttonStyle(PressScaleStyle())
        } else {
            content
        }
    }
}

/// The three LIVE sub-views. The BAC hero + drink dock stay pinned; this
/// swaps the middle so the screen is one focused thing at a time.
enum LiveTab: String, CaseIterable, Identifiable {
    case night, group, recap, vitals
    var id: String { rawValue }
    var label: String {
        switch self {
        case .night:  return "NIGHT"
        case .group:  return "GROUP"
        // Display name for the drink-history tab — the timestamped list of
        // everything you've logged tonight.
        case .recap:  return "DRINKS"
        case .vitals: return "VITALS"
        }
    }
    var icon: String {
        switch self {
        case .night:  return "moon.stars.fill"
        case .group:  return "person.2.fill"
        // Drink glass — SF Symbols has no beer mug, and mug.fill reads as
        // coffee; wineglass is the clean "your drinks" mark.
        case .recap:  return "wineglass.fill"
        case .vitals: return "bolt.heart.fill"
        }
    }
}

/// Segmented switch under the BAC readout. Active segment fills whiskey;
/// GROUP and RECAP carry a small live count so you know what's waiting in
/// each without opening it.
private struct LiveSegmentControl: View {
    @Binding var selection: LiveTab
    /// People in the group — badged on GROUP (0 hides it).
    var groupCount: Int = 0
    /// Drinks logged tonight — badged on RECAP (0 hides it).
    var drinkCount: Int = 0

    private func badge(for tab: LiveTab) -> Int {
        switch tab {
        case .group: return groupCount
        case .recap: return drinkCount
        case .night, .vitals: return 0
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(LiveTab.allCases) { tab in
                let active = selection == tab
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                        selection = tab
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                        Text(tab.label)
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                            .tracking(0.6)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        let n = badge(for: tab)
                        if n > 0 {
                            Text("\(n)")
                                .font(.system(size: 9, weight: .black, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(active ? Color.whiskey : Color.ink)
                                .frame(minWidth: 15, minHeight: 15)
                                .background(Circle().fill(active ? Color.ink.opacity(0.85) : Color.whiskey.opacity(0.9)))
                        }
                    }
                    .foregroundStyle(active ? Color.ink : Color.cream.opacity(0.6))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(active ? Color.whiskey : Color.clear)
                    )
                }
                .buttonStyle(PressScaleStyle())
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color.cream.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Color.cream.opacity(0.08), lineWidth: 1)
        )
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
                    .font(.system(size: 14, weight: .bold, design: .rounded))
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
                        .font(.system(size: 14, weight: .bold, design: .rounded))
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
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.bronze)
                    }
                }
                .foregroundStyle(Color.cream)
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.inkElev)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.cream.opacity(0.1), lineWidth: 1)
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
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Text("START NEW GROUP SESH")
                    .font(.system(size: 13, weight: .black, design: .monospaced))
                    .tracking(1.8)
                Spacer()
                if group.busy {
                    ProgressView().tint(Color.ink)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                }
            }
            .foregroundStyle(Color.ink)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.whiskey)
            )
            .shadow(color: Color.whiskey.opacity(0.4), radius: 14, y: 7)
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
                        .font(.system(size: 10, weight: .bold, design: .rounded))
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
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                    Text(inviteSendToast ?? "SEND INVITE")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .tracking(1.6)
                    Spacer()
                    if inviteSendToast == nil {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
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
                        .font(.system(size: 11, weight: .bold, design: .rounded))
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
                                .font(.system(size: 12, weight: .bold, design: .rounded))
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
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                            Text("SHARE")
                                .font(.system(size: 11, weight: .black, design: .monospaced))
                                .tracking(1.6)
                        }
                        // Secondary now — INVITE FRIENDS below is the primary CTA.
                        .foregroundStyle(Color.whiskey)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.inkElev)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.whiskey.opacity(0.45), lineWidth: 1)
                        )
                    }
                    .buttonStyle(PressScaleStyle())
                }

                // Pull friends straight in — the primary action, so make it
                // unmistakable: full whiskey with a glow.
                Button {
                    friendPickerOpen = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 13, weight: .heavy, design: .rounded))
                        Text("INVITE FRIENDS")
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .tracking(1.6)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(Color.ink)
                    .padding(.vertical, 15)
                    .padding(.horizontal, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.whiskey)
                    )
                    .shadow(color: Color.whiskey.opacity(0.45), radius: 14, y: 6)
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
                        .font(.system(size: 12, weight: .bold, design: .rounded))
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
                        .font(.system(size: 14, weight: .bold, design: .rounded))
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
                    .font(.system(size: 11, weight: .bold, design: .rounded))
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
                        .font(.system(size: 13, weight: .bold, design: .rounded))
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
                    .font(.system(size: 11, weight: .bold, design: .rounded))
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
                        .font(.system(size: 13, weight: .bold, design: .rounded))
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
                    .font(.system(size: 11, weight: .bold, design: .rounded))
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
                        .font(.system(size: 13, weight: .bold, design: .rounded))
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
                    .font(.system(size: 11, weight: .bold, design: .rounded))
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
    /// Measured height of the quick-add dock — reserved as scroll inset so
    /// the overlay-pinned dock never covers content.
    @State private var quickDockHeight: CGFloat = 150
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
    /// "Mauritz's party is live" — set when the running group sesh was
    /// auto-started by a planned event; renders the banner up top.
    var eventLiveHeadline: String? = nil
    var eventLiveTitle: String? = nil
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
    /// Which LIVE sub-view is showing. The BAC hero + log dock stay pinned;
    /// this switches the middle between the night, the group, and the recap
    /// so the screen is one focused view at a time instead of a long stack.
    @State private var liveTab: LiveTab = .night

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

    /// Approximate calories from the drinks YOU logged this sesh — the "in"
    /// side of the Sesh Vitals net. Solo uses the full per-category estimate;
    /// group rows only carry volume/ABV, so they're ethanol-only (7 kcal/g).
    private var myDrinkKcal: Double {
        if inGroup {
            return group.drinks(for: profile.id).reduce(0) { $0 + $1.grams * 7.0 }
        }
        return live.drinks.reduce(0) { $0 + $1.option().kcal }
    }

    /// Logs a drink in the right backing store. Optimistic UI is built in
    /// to both paths (LiveSeshState + SessionService). In group mode the
    /// `shareMode` toggle decides whether the drink goes onto the user's
    /// personal tab or into the shared round pool. Always records the
    /// pick in `recents` so quick-add can adapt.
    /// Transient "Round of X — logged for N people" line under the dock.
    @State private var roundConfirmation: String?

    private func logDrink(_ option: DrinkOption) {
        recents.record(option)
        // Mirror your own drink into Apple Health (calories + standard
        // drinks). No-ops entirely unless you've connected Health.
        HealthService.shared.log(option)
        if inGroup {
            let isShared = shareMode
            if isShared {
                // One round per arm: disarm immediately so the NEXT tap is
                // personal again, and say out loud what just happened.
                let heads = max(group.members.count + group.ghosts.count, 1)
                withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                    shareMode = false
                    roundConfirmation = heads == 1
                        ? "Round of \(option.name) — logged for you"
                        : "Round of \(option.name) — logged for \(heads) people"
                }
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    await MainActor.run {
                        withAnimation(.easeOut(duration: 0.25)) { roundConfirmation = nil }
                    }
                }
            }
            // Live store stamps live=true from its scope.
            Task {
                if let id = await group.addDrink(option, shared: isShared), !isShared {
                    // Shared rounds are excluded from pacing: the round is a
                    // deliberate act, and its rows belong to everyone.
                    await MainActor.run { noteBurst(id, option) }
                }
            }
        } else {
            noteBurst(live.add(option), option)
        }
    }

    // ------------------------------------------------------------------
    // Drink pacing. The most common logging mistake is catching up: three
    // taps back to back for beers that were actually drunk over an hour,
    // which the BAC model reads as slamming all three this second and
    // spikes. Rapid successive logs are exactly that signature, so they
    // raise a card that asks over how long — and re-stamps the drinks
    // across the answer, which fixes the CURVE rather than just the label.
    // ------------------------------------------------------------------

    /// The current rapid-log run, oldest first — id plus what was poured,
    /// so the card's own stepper can add another of the same.
    @State private var burstDrinks: [(id: UUID, option: DrinkOption)] = []
    @State private var lastLogAt: Date?
    @State private var paceCardShown = false
    /// Slider value in minutes; 0 = "all just now" (leave stamps alone).
    @State private var paceMinutes: Double = 0

    private var burstIds: [UUID] { burstDrinks.map(\.id) }

    /// Two logs within this window count as one burst.
    private static let burstGap: TimeInterval = 90

    /// The stamps applyPace would write for a given window — shared with
    /// the preview so the number shown IS the number you get.
    private func paceStamps(minutes: Double, now: Date = Date()) -> [UUID: Date] {
        let n = burstIds.count
        let window = minutes * 60
        guard n >= 1, window > 0 else { return [:] }
        // One drink: it simply happened `window` ago. Several: first at the
        // start of the window, latest at now — the shape of catching up.
        guard n >= 2 else { return [burstIds[0]: now.addingTimeInterval(-window)] }
        let step = window / Double(n - 1)
        var out: [UUID: Date] = [:]
        for (i, id) in burstIds.enumerated() {
            out[id] = now.addingTimeInterval(-window + step * Double(i))
        }
        return out
    }

    /// BAC now if the burst were spread over `minutes` — same walk the
    /// header runs, with hypothetical stamps substituted.
    private func previewBAC(minutes: Double, now: Date = Date()) -> Double {
        let overrides = paceStamps(minutes: minutes, now: now)
        if inGroup {
            return group.liveBAC(for: profile.id, now: now, overriding: overrides)
        }
        return live.bac(profile: profile, now: now, overriding: overrides)
    }

    private func noteBurst(_ id: UUID, _ option: DrinkOption) {
        let now = Date()
        if let last = lastLogAt, now.timeIntervalSince(last) < Self.burstGap {
            burstDrinks.append((id, option))
            if burstDrinks.count >= 2 {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    paceCardShown = true
                }
            }
        } else {
            burstDrinks = [(id, option)]
            // A fresh burst gets a fresh answer; don't inherit last night's.
            paceMinutes = 0
        }
        lastLogAt = now
    }

    private func dismissPaceCard() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { paceCardShown = false }
        burstDrinks = []
    }

    /// The card's own "+": pour another of the burst's latest drink without
    /// leaving the card — the scrim blocks the dock, and a 5-beer catch-up
    /// shouldn't require dismissing the question it raised.
    private func burstAddAnother() {
        guard let last = burstDrinks.last else { return }
        recents.record(last.option)
        if inGroup {
            Task {
                if let id = await group.addDrink(last.option, shared: false) {
                    await MainActor.run {
                        burstDrinks.append((id, last.option))
                        lastLogAt = Date()
                    }
                }
            }
        } else {
            burstDrinks.append((live.add(last.option), last.option))
            lastLogAt = Date()
        }
    }

    /// The card's "−": undo the burst's latest pour. Group removal targets
    /// "my most recent of this option", which by construction is the burst
    /// drink itself.
    private func burstRemoveLast() {
        guard burstDrinks.count > 1, let last = burstDrinks.popLast() else { return }
        if inGroup {
            let t: Task<Void, Never> = Task { await group.removeMyLast(of: last.option, shared: false) }
            _ = t
        } else {
            live.remove(last.id)
        }
    }

    /// Spread the burst evenly across [now − minutes, now]: first drink at
    /// the start of the window, latest at now — the shape of catching up.
    private func applyPace() {
        let stamps = paceStamps(minutes: paceMinutes)
        guard !stamps.isEmpty else { dismissPaceCard(); return }
        for (id, stamp) in stamps {
            if inGroup {
                let t: Task<Void, Never> = Task { await group.restampMyDrink(id: id, to: stamp) }
                _ = t
            } else {
                live.restamp(id, to: stamp)
            }
        }
        dismissPaceCard()
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
            ScrollViewReader { scrollProxy in
                ScrollView(showsIndicators: false) {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        content(now: context.date)
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    // Reserve the dock's footprint so content scrolls clear
                    // of it; the dock itself is pinned below the keyboard.
                    Color.clear.frame(height: quickDockHeight)
                }
                // Dragging the content also drops the keyboard.
                .scrollDismissesKeyboard(.interactively)
                // The pinned-chrome layout means the page doesn't lift with
                // the keyboard, so bring a newly focused field up ourselves.
                .onReceive(NotificationCenter.default.publisher(for: .sejdelScrollToFocusedField)) { note in
                    guard let id = note.object as? UUID else { return }
                    // Deferred past the keyboard's own transaction — issued
                    // in the same turn, the system's zero-delta adjustment
                    // cancels this scroll and the field stays covered.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                            scrollProxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }

            // Dock as a root-level sibling (not a ScrollView overlay): the
            // scroll view shrinks above the keyboard, so an overlay anchored
            // to it would ride up. This layer stays planted.
            quickAddDock
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                    quickDockHeight = $0
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

            // The pace prompt is a real decision about the night's data, so
            // it gets the centre of the screen — scrim, big numbers, and a
            // live before → after readout while the slider moves. Topmost:
            // its scrim must cover the dock too.
            if paceCardShown {
                ZStack {
                    Color.black.opacity(0.55).ignoresSafeArea()
                        .onTapGesture { }   // scrim absorbs taps; decide via buttons
                    paceCard
                        .frame(maxWidth: 380)
                        .padding(.horizontal, 20)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
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
            AddPersonSheet(startNumber: ghosts.members.count + 1) { newGhosts in
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    ghosts.addMany(newGhosts)
                }
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
            Task { _ = await group.addDrink(opt, shared: false) }
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
            if let headline = eventLiveHeadline {
                HStack(spacing: 10) {
                    SonarDot(size: 7, color: .whiskey)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(headline.uppercased())
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .tracking(1.8)
                            .foregroundStyle(Color.whiskey)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Text("\(eventLiveTitle.map { "\($0) · " } ?? "")log your drinks — the whole event sees the night together.")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.7))
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.whiskey.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.whiskey.opacity(0.3), lineWidth: 1)
                )
            }

            // Readout leads — same single hero card as PLAN. Always visible,
            // above the tab switch, so your BAC never scrolls away.
            TonightHeroCard(
                bac: bac,
                status: status,
                advice: vibeMessage(for: status).advice,
                hoursSober: hoursUntil(threshold: 0.0, now: now),
                hoursEU: hoursUntil(threshold: 0.02, now: now),
                hoursUS: hoursUntil(threshold: 0.08, now: now)
            )

            // One focused view at a time instead of a long stack of cards.
            LiveSegmentControl(
                selection: $liveTab,
                groupCount: inGroup ? group.members.count : 0,
                drinkCount: totalDrinkCount
            )

            switch liveTab {
            case .night:  nightTab(now: now)
            case .group:  groupTab(now: now)
            case .recap:  recapTab(now: now)
            case .vitals: vitalsTab(now: now)
            }
            Spacer(minLength: 24)
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 16)
    }

    // MARK: - LIVE tabs

    /// NIGHT — where you are and your night's photos. The two quick setup
    /// actions (invite / check in) lead, then the Night Snaps journey.
    @ViewBuilder
    private func nightTab(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                if embedded, let onOpenGroupSheet {
                    GroupBar(
                        scope: .live,
                        session: group.session,
                        memberCount: group.members.count,
                        compact: true,
                        alwaysInvite: true,
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
            LiveJourneyPhotosSection(
                journey: journey,
                pukeCandidates: pukeCandidates,
                onRemoveStop: { stop in
                    if stop.kind == .bar, venues.currentVenue?.id == stop.venueId {
                        venues.currentVenue = nil
                    }
                    journey.removeStop(stop.id)
                },
                userCoordinate: location.location?.coordinate,
                inFollowingGroup: inGroup && group.followingGroupVenue,
                inGroup: inGroup,
                onLooseSpotChanged: { spot in
                    if inGroup, group.followingGroupVenue {
                        Task { await group.setGroupLooseSpot(spot) }
                    }
                }
            )
        }
    }

    /// GROUP — the crew: join code, everyone's BAC + share-a-round, the
    /// roast, squad snaps, plus manually-added guests. Solo shows an invite
    /// call-to-action instead of the roster.
    @ViewBuilder
    private func groupTab(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if inGroup {
                if let code = group.session?.joinCode {
                    GroupCodeBar(
                        code: code,
                        memberCount: group.members.count,
                        onTap: onOpenGroupSheet
                    )
                }
                LiveGroupRoster(
                    group: group,
                    selfId: profile.id,
                    now: now,
                    isSharing: shareMode,
                    onShareDrink: (group.members.count + group.ghosts.count) > 1
                        ? { withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { shareMode = true } }
                        : nil
                )
                // Squad Schnaps — group photos, right below the roster so
                // the crew and their pics sit together.
                if let sid = group.session?.id {
                    GroupSnapsStrip(
                        snaps: groupSnaps,
                        sessionId: sid,
                        stopName: { venues.currentVenue?.name },
                        nameFor: { pid in group.memberProfiles[pid]?.name ?? "?" },
                        avatarFor: { pid in group.memberProfiles[pid]?.avatarURL },
                        saveToJourney: { data, date in
                            journey.addLoosePhoto(data, at: date)
                        }
                    )
                }
                LiveRoastCard(group: group, profile: profile, now: now)
            } else if let onOpenGroupSheet {
                GroupBar(
                    scope: .live,
                    session: nil,
                    memberCount: 0,
                    compact: false,
                    onTap: onOpenGroupSheet
                )
            }
            LiveGhostSection(
                ghosts: ghosts,
                now: now,
                bacFor: { ghost in
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
        }
    }

    /// RECAP — the night so far: your drink timeline and the estimate's
    /// fine print.
    @ViewBuilder
    private func recapTab(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            timelineSection(now: now)
            Disclaimer()
                .padding(.top, 4)
        }
    }

    /// VITALS — calories in vs out, steps and heart rate over the sesh, from
    /// Apple Health. Shows a "start a sesh" hint before the night's begun.
    @ViewBuilder
    private func vitalsTab(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let start = startTime {
                SeshVitalsCard(start: start, now: now, drinkKcal: myDrinkKcal)
            } else {
                Text("Log your first drink to start the sesh — your calories burned, steps and heart rate show up here once it's running.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.cream.opacity(0.035)))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.cream.opacity(0.07), lineWidth: 1))
            }
        }
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
            // The timeline's "+" is a logging path like any other, so it
            // feeds the same burst accounting — rapid +++ on a row used to
            // silently skip the pace question the quick tiles would ask.
            Task {
                if let id = await group.addDrink(g.option, shared: isShared), !isShared {
                    await MainActor.run { noteBurst(id, g.option) }
                }
            }
        } else {
            noteBurst(live.add(g.option), g.option)
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
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.cream.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.cream.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: quick-add dock

    private func paceWindowLabel(_ minutes: Double) -> String {
        let m = Int(minutes)
        if m == 0 { return "ALL JUST NOW" }
        if m < 60 { return "OVER THE LAST \(m) MIN" }
        let h = m / 60, r = m % 60
        return r == 0 ? "OVER THE LAST \(h) H" : "OVER THE LAST \(h) H \(r) MIN"
    }

    /// The catch-up prompt: centred, scrimmed, with a live before → after
    /// readout driven by the same walk the header uses — so the effect of
    /// a pace is visible BEFORE it's applied, and a small spread honestly
    /// showing a small dip reads as physiology, not as a broken slider.
    private var paceCard: some View {
        let bacNow = currentBAC(now: Date())
        let bacIf = previewBAC(minutes: paceMinutes)
        // The raw walk is %-scale; the display honors the user's unit
        // setting exactly like the big RIGHT NOW number does. Hardcoding
        // "‰" here once produced 0.22‰ under a header saying 2.20‰.
        let unit = bacUnit == .promille ? "‰" : "%"
        return VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text(burstDrinks.count == 1
                     ? "1 DRINK IN THIS RUN"
                     : "\(burstDrinks.count) DRINKS BACK TO BACK")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .tracking(1.8)
                    .foregroundStyle(Color.whiskey)
                Text("Did they really go down just now?")
                    .font(.system(size: 21, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .multilineTextAlignment(.center)
                Text("If you're catching up on drinks from earlier, set how far back the first one goes.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
            }

            // Before → after, recomputed live as the slider moves.
            HStack(spacing: 14) {
                VStack(spacing: 2) {
                    Text("AS LOGGED")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .tracking(1.4).foregroundStyle(Color.bronze)
                    Text(bacUnit.formatted(bacNow) + unit)
                        .font(.system(size: 26, weight: .heavy, design: .rounded).monospacedDigit())
                        .foregroundStyle(Color.cream.opacity(0.55))
                }
                Image(systemName: "arrow.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.whiskey)
                VStack(spacing: 2) {
                    Text("AT THIS PACE")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .tracking(1.4).foregroundStyle(Color.bronze)
                    Text(bacUnit.formatted(bacIf) + unit)
                        .font(.system(size: 26, weight: .heavy, design: .rounded).monospacedDigit())
                        .foregroundStyle(Color.whiskey)
                        .contentTransition(.numericText(value: bacIf))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.cream.opacity(0.05)))

            // Adjust the run without leaving the card — the scrim blocks the
            // dock, and "actually it was five" must not require starting over.
            // Styled exactly like a timeline row (glyph, name, size · ABV,
            // − n + pill) so the card reads as "this row of your night".
            if let last = burstDrinks.last {
                HStack(spacing: 12) {
                    DrinkGlyph(option: last.option, size: 22)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.smoke))
                        .overlay(Circle().strokeBorder(Color.whiskey.opacity(0.25), lineWidth: 1))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(last.option.name)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.cream)
                            .lineLimit(1)
                        Text(last.option.detail)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .tracking(0.4)
                            .foregroundStyle(Color.cream.opacity(0.5))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 0) {
                        Button(action: { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { burstRemoveLast() } }) {
                            Image(systemName: "minus")
                                .font(.system(size: 12, weight: .black, design: .rounded))
                                .foregroundStyle(burstDrinks.count > 1 ? Color.cream.opacity(0.8) : Color.cream.opacity(0.25))
                                .frame(width: 34, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PressScaleStyle())
                        .disabled(burstDrinks.count <= 1)

                        Text("\(burstDrinks.count)")
                            .font(.system(size: 15, weight: .black, design: .rounded))
                            .foregroundStyle(Color.cream)
                            .monospacedDigit()
                            .frame(minWidth: 22)
                            .contentTransition(.numericText(value: Double(burstDrinks.count)))

                        Button(action: { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { burstAddAnother() } }) {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .black, design: .rounded))
                                .foregroundStyle(Color.ink)
                                .frame(width: 34, height: 32)
                                .background(Color.whiskey)
                                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PressScaleStyle())
                    }
                    .padding(3)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.cream.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.cream.opacity(0.1), lineWidth: 1))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.cream.opacity(0.035)))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.cream.opacity(0.07), lineWidth: 1))
            }

            VStack(spacing: 6) {
                Slider(value: $paceMinutes, in: 0...180, step: 5)
                    .tint(Color.whiskey)
                Text(paceWindowLabel(paceMinutes))
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(Color.cream.opacity(0.85))
                    .contentTransition(.numericText(value: paceMinutes))
            }

            Button {
                paceMinutes == 0 ? dismissPaceCard() : applyPace()
            } label: {
                Text(paceMinutes == 0 ? "YES — ALL JUST NOW" : "THAT'S THE PACE")
                    .font(.system(size: 13.5, weight: .black, design: .monospaced))
                    .tracking(1.3)
                    .foregroundStyle(Color.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.whiskey))
            }
            .buttonStyle(PressScaleStyle())

            // Set expectations at the moment they'd otherwise break: an
            // hour of spread ≈ one hour of clearing, nothing more.
            Text("Your body clears ≈ \(bacUnit == .promille ? "0.15 ‰" : "0.015 %") an hour — spreading drinks out matters over hours, not minutes. Best reading: log each drink as you open it.")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.5))
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(Color.inkElev))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(Color.whiskey.opacity(0.5), lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            Button { dismissPaceCard() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.cream.opacity(0.55))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.cream.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .padding(10)
        }
        .shadow(color: .black.opacity(0.55), radius: 24, y: 8)
    }

    private var quickAddDock: some View {
        VStack(spacing: 10) {
            // Share-a-round, redesigned as ARMED-PER-ROUND. The old sticky
            // toggle was the confusion: people flipped it, forgot, and every
            // later beer silently logged for the whole table. Now SHARE A
            // ROUND arms exactly one tap — a banner says in words what that
            // tap will do and for how many people, the tap logs the round
            // and disarms itself, and a confirmation names what happened.
            if inGroup {
                let heads = max(group.members.count + group.ghosts.count, 1)
                if shareMode {
                    HStack(spacing: 10) {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.ink)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("ROUND ARMED")
                                .font(.system(size: 9, weight: .black, design: .monospaced))
                                .tracking(1.6).foregroundStyle(Color.ink.opacity(0.7))
                            Text(heads == 1
                                 ? "Next tap logs one just for you — no one else here yet"
                                 : "Next tap logs one for all \(heads) of you")
                                .font(.system(size: 12.5, weight: .heavy, design: .rounded))
                                .foregroundStyle(Color.ink)
                        }
                        Spacer()
                        Button {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { shareMode = false }
                        } label: {
                            Text("CANCEL")
                                .font(.system(size: 10, weight: .black, design: .monospaced))
                                .tracking(1.2)
                                .foregroundStyle(Color.ink)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Capsule().fill(Color.ink.opacity(0.15)))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.whiskey))
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else if let confirmed = roundConfirmation {
                    Label(confirmed, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11.5, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.whiskey)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.whiskey.opacity(0.12)))
                        .transition(.opacity)
                }
                // The "share a round" entry point now lives in the group
                // roster (next to everyone's BAC) — see LiveGroupRoster's
                // onShareDrink. The dock keeps only the armed banner and the
                // confirmation, which are feedback tied to the drink tiles.
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
                                        .font(.system(size: 7.5, weight: .bold, design: .rounded))
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
                        // Solid elevated tile (was a faint translucent wash) so
                        // each recent drink reads clearly.
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.inkElev)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(
                                    Color.whiskey.opacity(shareModeActive ? 0.6 : 0.32),
                                    lineWidth: 1
                                )
                        )
                        .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
                    }
                    .buttonStyle(PressScaleStyle())
                }
            }
            Button {
                menuOpen = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: shareModeActive ? "person.2.fill" : "plus")
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.ink)
                    Text(shareModeActive ? "MORE SHARED DRINKS" : "MORE DRINKS")
                        .font(.system(size: 12, weight: .black, design: .monospaced))
                        .tracking(2.0)
                        .foregroundStyle(Color.ink)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.ink.opacity(0.6))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.whiskey)
                )
                .shadow(color: Color.whiskey.opacity(0.4), radius: 12, y: 6)
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
                    .font(.system(size: 11, weight: .bold, design: .rounded))
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
/// "Sesh Vitals" — what your body did between the sesh starting and now.
/// Reads Active Energy (calories burned), Steps and Heart Rate from Apple
/// Health over the sesh window, paired with the calories from what you drank
/// for a net. Degrades gracefully: unsupported device → hidden; not connected
/// → a Connect button; no data → a gentle note; no heart rate (needs a Watch)
/// → that stat simply hides.
private struct SeshVitalsCard: View {
    let start: Date
    let now: Date
    let drinkKcal: Double

    @ObservedObject private var health = HealthService.shared
    @State private var vitals = HealthService.Vitals()
    @State private var connecting = false

    /// Re-query at most every 30s while the tab is open.
    private var bucket: Int { Int(now.timeIntervalSince1970 / 30) }
    var body: some View {
        Group {
            if health.isAvailable {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.heart.fill")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(Color.whiskey)
                        Text("SESH VITALS")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(2.4)
                            .foregroundStyle(Color.bronze)
                        Spacer()
                    }
                    if !health.isConnected {
                        connectCTA
                    } else {
                        grid
                    }
                }
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.cream.opacity(0.035)))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.cream.opacity(0.07), lineWidth: 1))
                .task(id: bucket) {
                    guard health.isConnected else { return }
                    vitals = await health.vitals(from: start, to: now)
                }
            }
        }
    }

    /// Warm green for the "burned" side (matches the price-cheap green).
    private var burnGreen: Color { Color(red: 0.49, green: 0.79, blue: 0.42) }
    private var consumed: Double { max(drinkKcal, 0) }
    private var burned: Double { max(vitals.activeKcal ?? 0, 0) }

    private var grid: some View {
        VStack(spacing: 12) {
            // The headline: calories in vs out, live.
            HStack(spacing: 10) {
                stat(icon: "wineglass.fill", value: "\(Int(consumed.rounded()))", unit: "kcal in", tint: Color.whiskey)
                stat(icon: "flame.fill", value: vitals.activeKcal.map { "\(Int($0.rounded()))" } ?? "—", unit: "kcal burned", tint: burnGreen)
            }
            balance
            // Secondary: steps + heart rate (HR only with an Apple Watch).
            HStack(spacing: 10) {
                stat(icon: "figure.walk", value: vitals.steps.map(stepStr) ?? "—", unit: "steps")
                if let hr = vitals.avgHeartRate {
                    stat(icon: "heart.fill",
                         value: "\(Int(hr.rounded()))",
                         unit: vitals.peakHeartRate.map { "avg · \(Int($0.rounded())) peak" } ?? "avg bpm")
                } else {
                    stat(icon: "heart.fill", value: "—", unit: "bpm · needs watch")
                }
            }
            Text("Calories are estimates. Burned, steps and heart rate come from Apple Health over this sesh.")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A proportional in-vs-out bar with the running net beneath it.
    private var balance: some View {
        let total = max(consumed + burned, 1)
        let net = consumed - burned
        return VStack(spacing: 7) {
            GeometryReader { geo in
                HStack(spacing: 3) {
                    Capsule().fill(Color.whiskey)
                        .frame(width: max(4, geo.size.width * consumed / total))
                    Capsule().fill(burnGreen)
                        .frame(width: max(4, geo.size.width * burned / total))
                }
            }
            .frame(height: 9)
            HStack(spacing: 6) {
                Text("NET")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(2).foregroundStyle(Color.bronze)
                Text(net >= 0 ? "you're up" : "you're down")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.6))
                Spacer()
                Text("\(net >= 0 ? "+" : "")\(Int(net.rounded())) kcal")
                    .font(.system(size: 15, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(net >= 0 ? Color.whiskey : burnGreen)
            }
        }
    }

    private func stat(icon: String, value: String, unit: String, tint: Color = .whiskey) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(Circle().fill(tint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 18, weight: .black, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(unit.uppercased())
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(Color.bronze)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cream.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.18), lineWidth: 1))
    }

    private func stepStr(_ n: Double) -> String {
        n >= 1000 ? String(format: "%.1fk", n / 1000) : "\(Int(n))"
    }

    private var connectCTA: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("See how much you moved and burned tonight — steps, heart rate and active calories, straight from Apple Health.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            Button {
                connecting = true
                Task {
                    await health.connect()
                    vitals = await health.vitals(from: start, to: now)
                    connecting = false
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "heart.fill").font(.system(size: 12, weight: .bold))
                    Text("CONNECT APPLE HEALTH")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .tracking(1.4)
                }
                .foregroundStyle(Color.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.whiskey))
            }
            .buttonStyle(PressScaleStyle())
            .disabled(connecting)
        }
    }
}

private struct LiveGroupRoster: View {
    @ObservedObject var group: SessionService
    let selfId: UUID
    let now: Date
    /// True while a shared round is armed — the next drink tap logs for
    /// everyone. Swaps the share button for an "armed" hint.
    var isSharing: Bool = false
    /// Arms a shared round. nil when it's just you (nobody to share with),
    /// which hides the button entirely.
    var onShareDrink: (() -> Void)? = nil

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

            // Share a drink with the whole group — arms one shared round,
            // right where everyone's BAC is visible so it's obvious who
            // it's for. The dock shows the "armed" banner + confirmation.
            if let onShareDrink {
                if isSharing {
                    HStack(spacing: 8) {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.whiskey)
                        Text("Round armed — tap a drink to log it for everyone")
                            .font(.system(size: 12, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color.whiskey)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 13).padding(.vertical, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.whiskey.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.whiskey.opacity(0.4), lineWidth: 1)
                    )
                    .transition(.opacity)
                } else {
                    Button(action: onShareDrink) {
                        HStack(spacing: 11) {
                            ZStack {
                                Circle()
                                    .fill(Color.whiskey.opacity(0.18))
                                    .frame(width: 34, height: 34)
                                Image(systemName: "person.2.fill")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.whiskey)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text("SHARE A ROUND")
                                    .font(.system(size: 9, weight: .black, design: .monospaced))
                                    .tracking(1.6)
                                    .foregroundStyle(Color.whiskey)
                                Text("Share a drink with everyone in the group")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.cream)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.whiskey.opacity(0.7))
                        }
                        .padding(.horizontal, 13).padding(.vertical, 11)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.whiskey.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.whiskey.opacity(0.35), lineWidth: 1)
                        )
                    }
                    .buttonStyle(PressScaleStyle())
                    .transition(.opacity)
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
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: isSharing)
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
                        .font(.system(size: 11, weight: .bold, design: .rounded))
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
                        .font(.system(size: 12, weight: .bold, design: .rounded))
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
                        .font(.system(size: 11, weight: .bold, design: .rounded))
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
                    .font(.system(size: 13, weight: .bold, design: .rounded))
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
struct AddPersonSheet: View {
    /// Returns the built ghost(s). One in "detailed" mode, N in "several".
    var onSave: ([GhostMember]) -> Void
    /// Where quick auto-numbering starts ("Guest 3", "Guest 4"…) so a batch
    /// continues the existing roster rather than colliding with it.
    var startNumber: Int = 1
    @Environment(\.dismiss) private var dismiss

    enum EntryMode: String, CaseIterable, Identifiable { case several, detailed; var id: String { rawValue } }

    /// Rough guest profiles for the quick "just a number" path — enough to
    /// get a believable group estimate without asking for every stat.
    enum GuestKind: String, CaseIterable, Identifiable {
        case mixed, guys, girls
        var id: String { rawValue }
        var label: String { self == .mixed ? "Mixed" : self == .guys ? "Guys" : "Girls" }
        /// (sex, weightKg) for the i-th guest (0-based). Mixed alternates.
        func profile(_ i: Int) -> (Sex, Double) {
            switch self {
            case .guys:  return (.male, 82)
            case .girls: return (.female, 66)
            case .mixed: return i % 2 == 0 ? (.male, 82) : (.female, 66)
            }
        }
    }

    @State private var entryMode: EntryMode = .several
    @State private var name: String = ""
    @State private var sex: Sex = .male
    @State private var age: Double = 28
    @State private var weight: Double = 75
    // Quick "several" path.
    @State private var count: Double = 4
    @State private var kind: GuestKind = .mixed
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

                    modePicker

                    if entryMode == .several {
                        quickSection
                    } else {
                        detailedSection
                    }

                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 22)
                .padding(.top, 10)
                .padding(.bottom, 28)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { if entryMode == .detailed { nameFocused = true } }
    }

    /// Two-way switch: a quick headcount for a rough estimate, or the full
    /// per-person form. Defaults to the quick path.
    private var modePicker: some View {
        HStack(spacing: 0) {
            ForEach(EntryMode.allCases) { m in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                        entryMode = m
                        nameFocused = (m == .detailed)
                    }
                } label: {
                    Text(m == .several ? "SEVERAL" : "ONE PERSON")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .tracking(1.6)
                        .foregroundStyle(entryMode == m ? Color.ink : Color.cream.opacity(0.6))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(entryMode == m ? Color.whiskey : Color.clear)
                        )
                }
                .buttonStyle(PressScaleStyle())
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cream.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.cream.opacity(0.08), lineWidth: 1))
    }

    // MARK: Quick "several" path

    private var quickSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            InputRow(
                kicker: "01",
                title: "How many?",
                valueText: "\(Int(count))",
                unit: Int(count) == 1 ? "person" : "people",
                accent: Color.whiskey
            ) {
                TintedSlider(value: $count, range: 1...30, step: 1, accent: Color.whiskey)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text("02")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(2).foregroundStyle(Color.bronze)
                    Text("TYPICAL GUEST")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(2.4).foregroundStyle(Color.cream.opacity(0.78))
                }
                HStack(spacing: 0) {
                    ForEach(GuestKind.allCases) { k in
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { kind = k }
                        } label: {
                            Text(k.label)
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(kind == k ? Color.ink : Color.cream.opacity(0.65))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .fill(kind == k ? Color.whiskey : Color.clear)
                                )
                        }
                        .buttonStyle(PressScaleStyle())
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cream.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.cream.opacity(0.08), lineWidth: 1))
            }

            quickSaveButton

            Text("A rough estimate using average builds — no names needed. Switch to “One person” to enter exact stats. Add or edit anyone afterwards.")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }

    // MARK: Detailed per-person path

    private var detailedSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            nameField

            InputRow(kicker: "01", title: "Sex", valueText: sex.short, unit: "", accent: Color.whiskey) {
                SexToggle(sex: $sex, accent: Color.whiskey)
            }
            InputRow(kicker: "02", title: "Age", valueText: "\(Int(age))", unit: "yrs", accent: Color.whiskey) {
                TintedSlider(value: $age, range: 18...80, step: 1, accent: Color.whiskey)
            }
            InputRow(kicker: "03", title: "Weight", valueText: "\(Int(weight))", unit: "kg", accent: Color.whiskey) {
                TintedSlider(value: $weight, range: 40...160, step: 1, accent: Color.whiskey)
            }

            saveButton

            Text("Stats stay on your phone. We use them to estimate this person's BAC the same way we do yours.")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.whiskey)
                        .frame(width: 7, height: 7)
                        .shadow(color: Color.whiskey.opacity(0.8), radius: 5)
                    Text(entryMode == .several ? "ADD PEOPLE" : "ADD PERSON")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(2.6)
                        .foregroundStyle(Color.whiskey)
                }
                Text(entryMode == .several ? "Who's coming?" : "New guest")
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
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.ink)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.cream))
                Text("ADD TO LIVE SESH")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .tracking(2.0)
                    .foregroundStyle(Color.ink)
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
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

    private var quickSaveButton: some View {
        let n = Int(count)
        return Button(action: commitQuick) {
            HStack(spacing: 10) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.ink)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.cream))
                Text(n == 1 ? "ADD 1 PERSON" : "ADD \(n) PEOPLE")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .tracking(2.0)
                    .foregroundStyle(Color.ink)
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.ink.opacity(0.55))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.whiskey))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.whiskey.opacity(0.6), lineWidth: 1))
            .shadow(color: Color.whiskey.opacity(0.45), radius: 18, y: 8)
        }
        .buttonStyle(PressScaleStyle())
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSave([GhostMember(name: trimmed, sex: sex, age: Int(age), weightKg: weight)])
        dismiss()
    }

    private func commitQuick() {
        let n = max(1, Int(count))
        let built: [GhostMember] = (0..<n).map { i in
            let (s, w) = kind.profile(i)
            return GhostMember(name: "Guest \(startNumber + i)", sex: s, age: 28, weightKg: w)
        }
        onSave(built)
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
                    .font(.system(size: 11, weight: .bold, design: .rounded))
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
                    .font(.system(size: 10, weight: .bold, design: .rounded))
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
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.inkElev)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.cream.opacity(0.06), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
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
                .font(.system(size: 13, weight: .bold, design: .rounded))
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
                    .font(.system(size: 12, weight: .black, design: .rounded))
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
                    .font(.system(size: 12, weight: .black, design: .rounded))
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
                .font(.system(size: 7.5, weight: .bold, design: .rounded))
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
    /// Manual entry for the "Other" catch-all category.
    @State private var customCL: String = ""
    @State private var customABV: String = ""

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
                        .font(.system(size: 13, weight: .bold, design: .rounded))
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
                        .font(.system(size: 13, weight: .bold, design: .rounded))
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
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
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
                            .font(.system(size: 12, weight: .bold, design: .rounded))
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
                                .font(.system(size: 9, weight: .black, design: .rounded))
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
                                            .font(.system(size: 13, weight: .bold, design: .rounded))
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
                                .foregroundStyle(selectedCategory == cat ? Color.whiskey : Color.bronze)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule().fill(selectedCategory == cat ? Color.cream.opacity(0.08) : Color.cream.opacity(0.02))
                                )
                                .overlay(
                                    Capsule().strokeBorder(
                                        selectedCategory == cat ? Color.whiskey.opacity(0.45) : Color.cream.opacity(0.06),
                                        lineWidth: 1
                                    )
                                )
                            }
                            .buttonStyle(PressScaleStyle())
                        }
                    }
                    .padding(.horizontal, 22)
                }
                .padding(.horizontal, -22)

                VStack(spacing: 8) {
                    if selectedCategory.isCustom {
                        // "Other" has no fixed presets — the user dials in the
                        // size and strength by hand. Same DrinkOption/BAC math
                        // as every catalog row; onPick logs it and dismisses.
                        CustomDrinkCard(clText: $customCL, abvText: $customABV) { option in
                            onPick(option)
                        }
                    } else {
                        // Built-in catalog drinks first…
                        ForEach(DrinkCatalog.options(for: selectedCategory), id: \.name) { option in
                            catalogRow(option, isSaved: false)
                        }
                    }
                    // …then the user's own saved scanned / manual drinks for
                    // this category, under a clear header. Filled bookmark
                    // un-saves them.
                    let savedHere = saved.drinks.filter { $0.category == selectedCategory }
                    if !savedHere.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "bookmark.fill")
                                .font(.system(size: 9, weight: .black, design: .rounded))
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
                    .font(.system(size: 11, weight: .bold, design: .rounded))
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


/// Posted by an inline text field when it gains focus, carrying its view
/// `.id` — the owning ScrollView scrolls it above the keyboard. Needed
/// because the pinned-chrome layout keeps pages from lifting, so SwiftUI's
/// automatic caret-chasing no longer reaches fields low on the page.
extension Notification.Name {
    static let sejdelScrollToFocusedField = Notification.Name("sejdel.scrollToFocusedField")
}

/// Drop the keyboard from anywhere — tapping outside a text field is
/// always an exit.
@MainActor
func endTextEditing() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                    to: nil, from: nil, for: nil)
}

/// One window-level tap recogniser that dismisses the keyboard on any tap
/// outside a text input — every page, every sheet, no per-view wiring.
/// cancelsTouchesInView stays false so buttons underneath still fire.
enum KeyboardDismissTap {
    private static var installed = false
    private static let delegate = DismissTapDelegate()

    @MainActor static func install() {
        guard !installed,
              let window = UIApplication.shared.connectedScenes
                  .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
        else { return }
        let tap = UITapGestureRecognizer(target: delegate,
                                         action: #selector(DismissTapDelegate.tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = delegate
        window.addGestureRecognizer(tap)
        installed = true
    }
}

final class DismissTapDelegate: NSObject, UIGestureRecognizerDelegate {
    /// Dismiss only when the tap lands OUTSIDE the focused field. Geometry,
    /// not class checks — SwiftUI's text fields aren't reliably UITextField
    /// subclasses, and a class miss here would resign focus the instant a
    /// field received it.
    @objc func tapped(_ g: UITapGestureRecognizer) {
        guard let window = g.view,
              let responder = window.sejdelFirstResponder() else { return }
        let pt = g.location(in: responder)
        if responder.bounds.insetBy(dx: -16, dy: -16).contains(pt) { return }
        Task { @MainActor in endTextEditing() }
    }
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

private extension UIView {
    func sejdelFirstResponder() -> UIView? {
        if isFirstResponder { return self }
        for sub in subviews {
            if let r = sub.sejdelFirstResponder() { return r }
        }
        return nil
    }
}

// MARK: - Bottom tab bar
/// Bottom navigation bar — the section switcher (moved here from the top)
/// plus the new DEALS tab. Four equal items, icon + label, whiskey when active.
struct BottomTabBar: View {
    @Binding var tab: TopTab
    let liveActive: Bool
    /// At least one friend is currently in a live sesh — green dot on
    /// NIGHTLINE so the user knows the TONIGHT strip has something to show.
    var friendsLive: Bool = false
    /// A friend posted a story or a night since the user last looked —
    /// the NIGHTLINE icon wiggles until they swipe over.
    var newOnNightline: Bool = false
    /// How many unseen stories/posts — shown as a number in a whiskey
    /// ring on the NIGHTLINE tab.
    var unseenCount: Int = 0
    /// Event invites awaiting the user's RSVP — numbered ring on PLAN.
    var eventInvites: Int = 0
    /// The user's avatar marks the PROFILE tab (their photo, or their
    /// initial when no photo is set).
    var avatarURL: String? = nil
    var avatarInitial: String = "?"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            item(.timeline, icon: "house.fill",                    label: "HOME",
                 pulse: friendsLive,
                 pulseColor: Color(red: 0.51, green: 0.72, blue: 0.48),
                 buzzing: newOnNightline && !reduceMotion,
                 badgeCount: unseenCount)
            item(.live,     icon: "dot.radiowaves.left.and.right", label: "LIVE", pulse: liveActive)
            item(.plan,     icon: "calendar",                      label: "EVENTS",
                 badgeCount: eventInvites)
            item(.offers,   icon: "map.fill",                      label: "MAPS")
            profileItem
        }
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background(Color.ink.opacity(0.96))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.cream.opacity(0.08)).frame(height: 1)
        }
    }

    /// PROFILE — the one item whose icon is the user themself: their
    /// avatar photo (or initial), ringed whiskey when selected.
    private var profileItem: some View {
        let on = tab == .profile
        return Button {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) { tab = .profile }
        } label: {
            VStack(spacing: 4) {
                AvatarView(urlString: avatarURL, initial: avatarInitial, size: 23)
                    .overlay(
                        Circle().strokeBorder(
                            on ? Color.whiskey : Color.cream.opacity(0.3),
                            lineWidth: on ? 2 : 1
                        )
                    )
                Text("PROFILE")
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

    @ViewBuilder
    private func item(_ value: TopTab, icon: String, label: String,
                      pulse: Bool = false, pulseColor: Color = .whiskey,
                      buzzing: Bool = false, badgeCount: Int = 0) -> some View {
        let on = tab == value
        Button {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) { tab = value }
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: on ? .bold : .semibold, design: .rounded))
                        .foregroundStyle(on ? Color.whiskey : Color.cream.opacity(0.55))
                        // "Something new over here" — a periodic wiggle
                        // until the user swipes over to look.
                        .symbolEffect(.wiggle, options: .repeat(.periodic(delay: 2.2)), isActive: buzzing)
                    // Unseen count in a whiskey ring beats the plain dot.
                    if badgeCount > 0 {
                        Text(badgeCount > 9 ? "9+" : "\(badgeCount)")
                            .font(.system(size: 9, weight: .black, design: .monospaced))
                            .foregroundStyle(Color.whiskey)
                            .frame(width: 17, height: 17)
                            .background(Circle().fill(Color.ink))
                            .overlay(Circle().strokeBorder(Color.whiskey, lineWidth: 1.5))
                            .shadow(color: Color.whiskey.opacity(0.6), radius: 4)
                            .offset(x: 13, y: -11)
                    } else if pulse {
                        // Live pulse, mirroring the old switcher's LIVE
                        // dot — with the website's sonar ring.
                        SonarDot(size: 6, color: pulseColor)
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
