// BusinessProfile.swift — bars as accounts, from the guest's side.
//
// A subscribed bar is an account people can follow: it has a profile page
// (logo, tagline, followers, its deals and its posts), its posts land in
// followers' Home feeds, and a boosted post reaches everyone nearby as a
// sponsored post + a map billboard. This file holds the guest-side models,
// the follow store, the profile page and the post card. The owner's side
// lives in Business.swift.

import Combine
import SwiftUI
import Supabase

// MARK: - Models

/// A bar with an active subscription, as the map and the venue card see it.
struct BusinessPublicProfile: Decodable, Identifiable, Equatable {
    let id: UUID
    let venueId: UUID
    let name: String
    let username: String?
    let logoUrl: String?
    let posterUrl: String?
    let tagline: String?
    let tier: String
    let followers: Int

    enum CodingKeys: String, CodingKey {
        case id, name, username, tagline, tier, followers
        case venueId = "venue_id"
        case logoUrl = "logo_url"
        case posterUrl = "poster_url"
    }

    var isPlus: Bool { tier == "plus" }
    var logoURL: URL? { logoUrl.flatMap(URL.init(string:)) }
    var posterURL: URL? { posterUrl.flatMap(URL.init(string:)) }
}

/// A bar's post, wherever it shows (feed, profile, boost).
struct BusinessPost: Decodable, Identifiable, Equatable {
    let id: UUID
    let businessId: UUID
    let businessName: String
    var username: String? = nil
    let logoUrl: String?
    let venueId: UUID
    let venueName: String?
    let venueCity: String?
    let imageUrl: String
    /// The slideshow (Business+); a single-picture post has one entry.
    var imageUrls: [String]? = nil
    let imageRatio: Double
    let caption: String?
    let eventAt: String?
    let offerId: UUID?
    let createdAt: String
    var likeCount: Int? = nil
    var likedByMe: Bool? = nil
    var commentCount: Int? = nil
    var views: Int? = nil

    enum CodingKeys: String, CodingKey {
        case id, caption, username, views
        case likeCount = "like_count"
        case likedByMe = "liked_by_me"
        case commentCount = "comment_count"
        case businessId = "business_id"
        case businessName = "business_name"
        case logoUrl = "logo_url"
        case venueId = "venue_id"
        case venueName = "venue_name"
        case venueCity = "venue_city"
        case imageUrl = "image_url"
        case imageUrls = "image_urls"
        case imageRatio = "image_ratio"
        case eventAt = "event_at"
        case offerId = "offer_id"
        case createdAt = "created_at"
    }

    var imageURL: URL? { URL(string: imageUrl) }
    var images: [URL] { (imageUrls ?? [imageUrl]).compactMap(URL.init(string:)) }
    var eventDate: Date? { eventAt.flatMap(BusinessJSON.parseDate) }
    var createdDate: Date { BusinessJSON.parseDate(createdAt) ?? .distantPast }
    /// Clamped to Instagram's range, like everything in the feed.
    var ratio: CGFloat { CampaignArt.clampFeed(CGFloat(imageRatio)) }
}

/// A paid boost that's still running: shown as a billboard on the map and
/// as the sponsored post in the feed, counting views against its goal.
struct LiveBoost: Decodable, Identifiable {
    let id: UUID
    let businessId: UUID
    let businessName: String
    let logoUrl: String?
    let venueId: UUID
    let postId: UUID
    let imageUrl: String
    let imageRatio: Double
    let caption: String?
    let eventAt: String?
    let offerId: UUID?
    let goalViews: Int
    let views: Int
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, caption, views
        case businessId = "business_id"
        case businessName = "business_name"
        case logoUrl = "logo_url"
        case venueId = "venue_id"
        case postId = "post_id"
        case imageUrl = "image_url"
        case imageRatio = "image_ratio"
        case eventAt = "event_at"
        case offerId = "offer_id"
        case goalViews = "goal_views"
        case createdAt = "created_at"
    }

    /// The boost as the billboard the map carousel and the sponsored slot
    /// already know how to draw. Its id is the boost's, so the view counter
    /// lands on the boost.
    var asOffer: VenueOffer {
        let when = eventAt.flatMap(BusinessJSON.parseDate).map { $0.formatted(date: .abbreviated, time: .shortened) }
        var o = VenueOffer(id: id, venueId: venueId, kind: eventAt == nil ? "bundle" : "event",
                           title: caption ?? businessName, description: when, finePrint: nil,
                           redeem: "show", code: nil, startMinute: nil, endMinute: nil, activeDays: nil,
                           placement: "billboard", imageUrl: imageUrl, billboardImageUrl: imageUrl,
                           interstitial: false, showOnValidOnly: false)
        o.imageRatio = CampaignArt.clampFeed(CGFloat(imageRatio))
        return o
    }
}

// MARK: - Follows

/// Which bars the signed-in user follows. One store, so the venue card, the
/// profile page and the feed agree the instant a Follow is tapped.
@MainActor
final class BusinessFollowStore: ObservableObject {
    static let shared = BusinessFollowStore()
    @Published private(set) var following: Set<UUID> = []
    @Published private(set) var counts: [UUID: Int] = [:]
    @Published private(set) var busy: Set<UUID> = []
    /// Followed bars whose pushes this account has turned off (the bell).
    @Published private(set) var muted: Set<UUID> = []

    func load() async {
        guard supabase.auth.currentUser != nil else { following = []; muted = []; return }
        struct Row: Decodable { let business_id: UUID; let notify: Bool? }
        if let rows: [Row] = try? await supabase.from("business_follows").select("business_id,notify").execute().value {
            following = Set(rows.map(\.business_id))
            muted = Set(rows.filter { $0.notify == false }.map(\.business_id))
        }
    }

    func isFollowing(_ id: UUID) -> Bool { following.contains(id) }
    func wantsPushes(_ id: UUID) -> Bool { !muted.contains(id) }

    /// Flip pushes from one followed bar. Optimistic, rolled back on failure.
    func toggleNotify(_ id: UUID) async {
        let on = muted.contains(id)
        if on { muted.remove(id) } else { muted.insert(id) }
        struct P: Encodable { let p_business: String; let p_on: Bool }
        if (try? await supabase.rpc("set_business_follow_notify",
                                    params: P(p_business: id.uuidString.lowercased(), p_on: on)).execute()) == nil {
            if on { muted.insert(id) } else { muted.remove(id) }
        }
    }

    /// Flip the follow; returns the new state. Optimistic, rolled back on failure.
    @discardableResult
    func toggle(_ id: UUID) async -> Bool {
        let on = !following.contains(id)
        if on { following.insert(id) } else { following.remove(id) }
        busy.insert(id)
        defer { busy.remove(id) }
        struct P: Encodable { let p_business: String; let p_on: Bool }
        do {
            let count: Int = try await supabase.rpc("follow_business", params: P(p_business: id.uuidString.lowercased(), p_on: on))
                .execute().value
            counts[id] = count
            if !on { muted.remove(id) }
            return on
        } catch {
            if on { following.remove(id) } else { following.insert(id) }
            return !on
        }
    }
}

/// The capsule that follows / unfollows a bar.
struct FollowButton: View {
    let businessId: UUID
    @ObservedObject private var follows = BusinessFollowStore.shared

    var body: some View {
        let on = follows.isFollowing(businessId)
        Button {
            Task { await follows.toggle(businessId) }
        } label: {
            Text(on ? "FOLLOWING" : "FOLLOW")
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(on ? Color.cream.opacity(0.8) : Color.ink)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(on ? Color.cream.opacity(0.08) : Color.whiskey))
                .overlay(Capsule().strokeBorder(Color.cream.opacity(on ? 0.2 : 0), lineWidth: 1))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(follows.busy.contains(businessId))
    }
}

/// The bell beside FOLLOW on a bar's profile: pushes from this one bar on or
/// off. Only there once you follow — nothing to mute before that.
struct FollowBellButton: View {
    let businessId: UUID
    @ObservedObject private var follows = BusinessFollowStore.shared

    var body: some View {
        if follows.isFollowing(businessId) {
            let on = follows.wantsPushes(businessId)
            Button {
                Task { await follows.toggleNotify(businessId) }
            } label: {
                Image(systemName: on ? "bell.fill" : "bell.slash")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(on ? Color.whiskey : Color.cream.opacity(0.45))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.cream.opacity(0.08)))
                    .overlay(Circle().strokeBorder(Color.cream.opacity(0.15), lineWidth: 1))
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel(on ? "Turn off pushes from this bar" : "Turn on pushes from this bar")
        }
    }
}

/// The bar as an account, at the top of its venue card: logo, name, tagline,
/// follower count and the follow button. Tap the name to open the profile.
struct BusinessHeaderRow: View {
    let business: BusinessPublicProfile
    let onOpen: () -> Void
    @ObservedObject private var follows = BusinessFollowStore.shared

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    BusinessLogo(url: business.logoURL, name: business.name, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(business.name)
                                .font(.system(size: 15, weight: .heavy, design: .rounded))
                                .foregroundStyle(Color.cream)
                                .lineLimit(1)
                            VerifiedBadge(size: 13)
                        }
                        Text(business.tagline ?? followersLabel(follows.counts[business.id] ?? business.followers))
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            FollowButton(businessId: business.id)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cream.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.cream.opacity(0.08), lineWidth: 1))
    }
}

/// A bar's logo, or its initial on whiskey when it hasn't set one.
struct BusinessLogo: View {
    let url: URL?
    let name: String
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Circle().fill(Color.whiskey)
            if let url {
                DownsampledAsyncImage(url: url, targetPoints: size * 2)
            } else {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.42, weight: .black, design: .rounded))
                    .foregroundStyle(Color.ink)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// A Business+ bar's photo on its venue card when it has no poster deal —
/// the same 4:3 box as a poster, marked sponsored.
struct BusinessPosterBanner: View {
    let url: URL

    var body: some View {
        Color.clear
            .aspectRatio(CampaignArt.posterRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay { ZStack { Color.smoke; DownsampledAsyncImage(url: url, targetPoints: 360) } }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Text("SPONSORED")
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(Color.cream.opacity(0.75))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.ink.opacity(0.65)))
                    .padding(8)
            }
    }
}

// MARK: - Likes & comments

struct BusinessComment: Decodable, Identifiable {
    let id: UUID
    let userId: UUID
    let name: String
    let username: String?
    let avatarUrl: String?
    let body: String
    let createdAt: String
    let mine: Bool
    enum CodingKeys: String, CodingKey {
        case id, name, username, body, mine
        case userId = "user_id"
        case avatarUrl = "avatar_url"
        case createdAt = "created_at"
    }
}

/// Like and comment counts for bars' posts, shared by every card showing the
/// same post so a tap in the feed shows on the profile too. Optimistic.
@MainActor
final class BusinessPostSocial: ObservableObject {
    static let shared = BusinessPostSocial()
    @Published private(set) var likeCount: [UUID: Int] = [:]
    @Published private(set) var liked: Set<UUID> = []
    @Published private(set) var commentCount: [UUID: Int] = [:]
    private var seeded: Set<UUID> = []

    /// First sighting of a post seeds the counts the server sent.
    func seed(_ post: BusinessPost) {
        guard !seeded.contains(post.id) else { return }
        seeded.insert(post.id)
        if let n = post.likeCount { likeCount[post.id] = n }
        if post.likedByMe == true { liked.insert(post.id) }
        if let n = post.commentCount { commentCount[post.id] = n }
    }
    func likes(_ post: BusinessPost) -> Int { likeCount[post.id] ?? post.likeCount ?? 0 }
    func isLiked(_ post: BusinessPost) -> Bool { seeded.contains(post.id) ? liked.contains(post.id) : (post.likedByMe ?? false) }
    func comments(_ post: BusinessPost) -> Int { commentCount[post.id] ?? post.commentCount ?? 0 }

    func toggleLike(_ post: BusinessPost) async {
        seed(post)
        let on = !liked.contains(post.id)
        if on { liked.insert(post.id) } else { liked.remove(post.id) }
        likeCount[post.id] = max(0, likes(post) + (on ? 1 : -1))
        struct P: Encodable { let p_post: String; let p_on: Bool }
        if let n: Int = try? await supabase.rpc("business_post_like", params: P(p_post: post.id.uuidString.lowercased(), p_on: on)).execute().value {
            likeCount[post.id] = n
        } else {
            if on { liked.remove(post.id) } else { liked.insert(post.id) }
            likeCount[post.id] = max(0, likes(post) + (on ? -1 : 1))
        }
    }

    func noteComment(_ post: BusinessPost, delta: Int) {
        seed(post)
        commentCount[post.id] = max(0, comments(post) + delta)
    }
}

// MARK: - Post card

/// A bar's post in the feed or on its profile: the bar as the author, the
/// photo at its own Instagram ratio, the caption, when it happens.
struct BusinessPostCard: View {
    let post: BusinessPost
    var showHeader = true
    var onOpenBusiness: () -> Void = {}
    var onShowOnMap: (() -> Void)? = nil
    /// The bar sees its view count; guests don't.
    var showViews = false
    /// Being on screen counts as a view — except for the bar looking at itself.
    var countsView = true
    /// Tap the picture or the comment bubble: open the post. Inside the
    /// detail sheet there's nothing further to open.
    var onOpen: (() -> Void)? = nil
    var inDetail = false
    @ObservedObject private var social = BusinessPostSocial.shared
    @ObservedObject private var ratios = ImageRatioCache.shared
    @State private var detailOpen = false

    /// The picture's own ratio once it has loaded — the stored one is only a
    /// first guess for the box.
    private var ratio: CGFloat { CampaignArt.clampFeed(ratios.ratio(for: post.images.first) ?? post.ratio) }

    private func open() {
        if inDetail { return }
        if let onOpen { onOpen() } else { detailOpen = true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showHeader {
                Button(action: onOpenBusiness) {
                    HStack(spacing: 10) {
                        BusinessLogo(url: post.logoUrl.flatMap(URL.init(string:)), name: post.businessName, size: 36)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Text(post.businessName)
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.cream)
                                    .lineLimit(1)
                                VerifiedBadge(size: 12)
                            }
                            Text([post.venueName, post.venueCity].compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(Color.cream.opacity(0.5))
                                .lineLimit(1)
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
            }

            // One picture, or the slideshow — same box, page dots when it swipes.
            Color.clear
                .aspectRatio(ratio, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    if post.images.count > 1 {
                        TabView {
                            ForEach(post.images, id: \.absoluteString) { url in
                                ZStack { Color.smoke; DownsampledAsyncImage(url: url, targetPoints: 420) }.clipped()
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .automatic))
                    } else {
                        ZStack { Color.smoke; DownsampledAsyncImage(url: post.imageURL, targetPoints: 420) }
                    }
                }
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture { open() }

            // Like · comment (· views for the bar) — the same strip a night has.
            HStack(spacing: 18) {
                let liked = social.isLiked(post)
                Button { Task { await social.toggleLike(post) } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: liked ? "heart.fill" : "heart")
                            .font(.system(size: 23, weight: .semibold, design: .rounded))
                            .foregroundStyle(liked ? Status.drunk.color : Color.cream.opacity(0.85))
                        let n = social.likes(post)
                        if n > 0 { Text("\(n)").foregroundStyle(Color.cream.opacity(0.85)) }
                    }
                    .padding(.vertical, 6).padding(.trailing, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle())
                Button { open() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "bubble.right").foregroundStyle(Color.cream.opacity(0.85))
                        let n = social.comments(post)
                        if n > 0 { Text("\(n)").foregroundStyle(Color.cream.opacity(0.85)) }
                    }
                }
                .buttonStyle(PressScaleStyle())
                if showViews {
                    HStack(spacing: 6) {
                        Image(systemName: "eye")
                        Text("\((post.views ?? 0).formatted())")
                    }
                    .foregroundStyle(Color.cream.opacity(0.6))
                }
                Spacer()
            }
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .padding(.horizontal, 14).padding(.top, 12)

            VStack(alignment: .leading, spacing: 8) {
                if let c = post.caption, !c.isEmpty {
                    Text(c)
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) {
                    if let e = post.eventDate {
                        Label(e.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                            .font(.system(size: 11, weight: .black, design: .rounded))
                            .foregroundStyle(Color.ink)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Capsule().fill(Color.whiskey))
                    }
                    if let onShowOnMap {
                        Button(action: onShowOnMap) {
                            Label("See on the map", systemImage: "mappin.and.ellipse")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.whiskey)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
            }
            .padding(14)
        }
        .background(Color.cream.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.cream.opacity(0.1), lineWidth: 1))
        .onAppear { social.seed(post) }
        .onScrollVisibilityChange(threshold: 0.5) { shown in
            if shown && countsView { CampaignStats.impression(post.id) }
        }
        .sheet(isPresented: $detailOpen) {
            BusinessPostDetailSheet(post: post)
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.ink)
        }
    }
}

/// The post, opened: the card, its comments, and a place to write one. The
/// bar sees views and can delete.
struct BusinessPostDetailSheet: View {
    let post: BusinessPost
    var isOwner = false
    var onDelete: (() async -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var social = BusinessPostSocial.shared
    @State private var comments: [BusinessComment] = []
    @State private var loaded = false
    @State private var text = ""
    @State private var sending = false
    @State private var deleting = false
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.ink.ignoresSafeArea()
            VStack(spacing: 0) {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        BusinessPostCard(post: post, showViews: isOwner, countsView: !isOwner, inDetail: true)
                        if !comments.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(comments) { c in commentRow(c) }
                            }
                            .padding(.horizontal, 4)
                        } else if loaded {
                            Text("No comments yet.")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.cream.opacity(0.5))
                                .padding(.horizontal, 4)
                        }
                        if isOwner, let onDelete {
                            Button {
                                deleting = true
                                Task { await onDelete(); dismiss() }
                            } label: {
                                Text(deleting ? "Deleting…" : "Delete post")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Color.cream.opacity(0.5)).underline()
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 8)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 52)
                    .padding(.bottom, 16)
                }
                composer
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.85))
                    .padding(12).background(Circle().fill(Color.cream.opacity(0.08)))
            }
            .padding(.top, 12).padding(.trailing, 16)
            .buttonStyle(PressScaleStyle())
        }
        .preferredColorScheme(.dark)
        .task { await load() }
    }

    private func commentRow(_ c: BusinessComment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            FriendAvatar(name: c.name, avatarURL: c.avatarUrl, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(c.name).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(Color.cream)
                    Text(RelativeTime.short(c.createdAt)).font(.system(size: 11, design: .rounded)).foregroundStyle(Color.cream.opacity(0.45))
                }
                Text(c.body).font(.system(size: 14, design: .rounded)).foregroundStyle(Color.cream.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if c.mine || isOwner {
                Button { Task { await remove(c) } } label: {
                    Image(systemName: "trash").font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.35))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("", text: $text, prompt: Text("Add a comment…").foregroundStyle(Color.cream.opacity(0.4)), axis: .vertical)
                .lineLimit(1...4)
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(Color.cream)
                .tint(Color.whiskey)
                .focused($focused)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Capsule().fill(Color.cream.opacity(0.06)))
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .black, design: .rounded))
                    .foregroundStyle(Color.ink)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(text.trimmingCharacters(in: .whitespaces).isEmpty ? Color.cream.opacity(0.15) : Color.whiskey))
            }
            .buttonStyle(PressScaleStyle())
            .disabled(sending || text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.ink)
    }

    private func load() async {
        struct P: Encodable { let p_post: String }
        comments = (try? await supabase.rpc("business_post_comments", params: P(p_post: post.id.uuidString.lowercased())).execute().value) ?? []
        loaded = true
    }

    private func send() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        sending = true
        Task {
            struct P: Encodable { let p_post: String; let p_body: String }
            if (try? await supabase.rpc("business_post_comment", params: P(p_post: post.id.uuidString.lowercased(), p_body: body)).execute()) != nil {
                text = ""
                social.noteComment(post, delta: 1)
                await load()
            }
            sending = false
        }
    }

    private func remove(_ c: BusinessComment) async {
        struct P: Encodable { let p_comment: String }
        if (try? await supabase.rpc("business_post_delete_comment", params: P(p_comment: c.id.uuidString.lowercased())).execute()) != nil {
            comments.removeAll { $0.id == c.id }
            social.noteComment(post, delta: -1)
        }
    }
}

// MARK: - Profile page

/// One bar, as an account: logo, tagline, followers, its deals and its posts.
struct BusinessProfileView: View {
    let businessId: UUID
    /// Fly the Deals map to the bar (venue id). nil when opened from the map itself.
    var onShowOnMap: ((UUID) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var follows = BusinessFollowStore.shared
    @State private var payload: Payload?
    @State private var failed = false

    struct Payload: Decodable {
        struct Info: Decodable {
            let id: UUID
            let name: String
            let username: String?
            let logoUrl: String?
            let posterUrl: String?
            let tagline: String?
            let tier: String
            let venueId: UUID
            let venueName: String
            let venueCity: String?
            let followers: Int
            let following: Bool
            /// The account that IS the bar — who a message goes to.
            let accountId: UUID?
            enum CodingKeys: String, CodingKey {
                case id, name, username, tagline, tier, followers, following
                case logoUrl = "logo_url"
                case posterUrl = "poster_url"
                case venueId = "venue_id"
                case venueName = "venue_name"
                case venueCity = "venue_city"
                case accountId = "account_id"
            }
        }
        struct Post: Decodable, Identifiable {
            let id: UUID
            let imageUrl: String
            let imageUrls: [String]?
            let imageRatio: Double
            let caption: String?
            let eventAt: String?
            let offerId: UUID?
            let createdAt: String
            let likeCount: Int?
            let likedByMe: Bool?
            let commentCount: Int?
            let views: Int?
            enum CodingKeys: String, CodingKey {
                case id, caption, views
                case imageUrl = "image_url"
                case imageUrls = "image_urls"
                case imageRatio = "image_ratio"
                case eventAt = "event_at"
                case offerId = "offer_id"
                case createdAt = "created_at"
                case likeCount = "like_count"
                case likedByMe = "liked_by_me"
                case commentCount = "comment_count"
            }
        }
        struct Event: Decodable, Identifiable {
            let id: UUID
            let title: String
            let startsAt: String
            let imageUrl: String?
            let imageRatio: Double?
            enum CodingKeys: String, CodingKey {
                case id, title
                case startsAt = "starts_at"
                case imageUrl = "image_url"
                case imageRatio = "image_ratio"
            }
            var date: Date { BusinessJSON.parseDate(startsAt) ?? .distantPast }
            var ratio: CGFloat { CampaignArt.clampFeed(CGFloat(imageRatio ?? 1)) }
        }
        let business: Info
        let posts: [Post]
        let events: [Event]?
        let deals: [VenueOffer]
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.ink.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                if let p = payload {
                    VStack(spacing: 16) {
                        header(p.business)
                        if let u = p.business.posterUrl.flatMap(URL.init(string:)), p.business.tier == "plus" {
                            BusinessPosterBanner(url: u)
                        }
                        if let events = p.events, !events.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                sectionTitle("COMING UP")
                                ForEach(events) { e in
                                    VStack(alignment: .leading, spacing: 0) {
                                        EventPicture(url: e.imageUrl.flatMap(URL.init(string:)), ratio: e.ratio)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(e.title).font(.system(size: 17, weight: .heavy, design: .rounded)).foregroundStyle(Color.cream)
                                            Text(e.date.formatted(date: .abbreviated, time: .shortened))
                                                .font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(Color.whiskey)
                                        }
                                        .padding(14)
                                    }
                                    .background(Color.cream.opacity(0.04))
                                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.cream.opacity(0.08), lineWidth: 1))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if !p.deals.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                sectionTitle("DEALS RIGHT NOW")
                                ForEach(p.deals) { OfferRow(offer: $0) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if p.posts.isEmpty {
                            Text("Nothing posted yet.")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.cream.opacity(0.5))
                                .padding(.top, 30)
                        } else {
                            ForEach(p.posts) { post in
                                BusinessPostCard(post: BusinessPost(
                                    id: post.id, businessId: p.business.id, businessName: p.business.name,
                                    username: p.business.username,
                                    logoUrl: p.business.logoUrl, venueId: p.business.venueId,
                                    venueName: p.business.venueName, venueCity: p.business.venueCity,
                                    imageUrl: post.imageUrl, imageUrls: post.imageUrls, imageRatio: post.imageRatio, caption: post.caption,
                                    eventAt: post.eventAt, offerId: post.offerId, createdAt: post.createdAt,
                                    likeCount: post.likeCount, likedByMe: post.likedByMe, commentCount: post.commentCount, views: post.views
                                ), showHeader: false)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 40)
                    .padding(.bottom, 40)
                } else if failed {
                    Text("This bar isn't on Sejdel any more.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.5))
                        .padding(.top, 80)
                } else {
                    ProgressView().tint(Color.whiskey).padding(.top, 80)
                }
            }

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.85))
                    .padding(12).background(Circle().fill(Color.cream.opacity(0.08)))
            }
            .padding(.top, 16).padding(.trailing, 20)
            .buttonStyle(PressScaleStyle())
        }
        .preferredColorScheme(.dark)
        .task { await load() }
    }

    private func header(_ b: Payload.Info) -> some View {
        VStack(spacing: 8) {
            BusinessLogo(url: b.logoUrl.flatMap(URL.init(string:)), name: b.name, size: 78)
            HStack(spacing: 6) {
                Text(b.name)
                    .font(.system(size: 20, weight: .black, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .multilineTextAlignment(.center)
                VerifiedBadge(size: 16)
            }
            if let u = b.username {
                Text("@\(u)").font(.system(size: 13, design: .rounded)).foregroundStyle(Color.cream.opacity(0.55))
            }
            Text([b.venueName, b.venueCity].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.55))
            if let t = b.tagline {
                Text(t)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
            Text(followersLabel(follows.counts[b.id] ?? b.followers))
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .tracking(1.6).foregroundStyle(Color.bronze)
                .padding(.top, 2)
            HStack(spacing: 10) {
                FollowButton(businessId: b.id)
                FollowBellButton(businessId: b.id)
                if let acc = b.accountId, acc != supabase.auth.currentUser?.id {
                    Button {
                        dismiss()
                        ChatDeepLink.open(id: acc, name: b.name)
                    } label: {
                        Label("MESSAGE", systemImage: "bubble.right.fill")
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                            .tracking(1.4)
                            .foregroundStyle(Color.whiskey)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Capsule().fill(Color.whiskey.opacity(0.1)))
                            .overlay(Capsule().strokeBorder(Color.whiskey.opacity(0.4), lineWidth: 1))
                    }
                    .buttonStyle(PressScaleStyle())
                }
                if let onShowOnMap {
                    Button {
                        dismiss()
                        onShowOnMap(b.venueId)
                    } label: {
                        Label("ON THE MAP", systemImage: "mappin.and.ellipse")
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                            .tracking(1.4)
                            .foregroundStyle(Color.whiskey)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Capsule().fill(Color.whiskey.opacity(0.1)))
                            .overlay(Capsule().strokeBorder(Color.whiskey.opacity(0.4), lineWidth: 1))
                    }
                    .buttonStyle(PressScaleStyle())
                }
            }
            .padding(.top, 6)
        }
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(2.0)
            .foregroundStyle(Color.bronze)
    }

    private func load() async {
        struct P: Encodable { let p_business: String }
        do {
            let data = try await supabase.rpc("business_profile", params: P(p_business: businessId.uuidString.lowercased())).execute().data
            let p = try JSONDecoder().decode(Payload.self, from: data)
            payload = p
            // The server knows whether you follow; seed the store if it disagrees.
            if p.business.following && !follows.isFollowing(p.business.id) { await follows.load() }
        } catch {
            failed = true
        }
    }
}

/// "1 follower", "12 followers".
func followersLabel(_ n: Int) -> String { "\(n.formatted()) follower\(n == 1 ? "" : "s")" }

/// Sheet item for opening a bar's profile from anywhere.
struct BizRef: Identifiable, Equatable {
    let id: UUID
}
