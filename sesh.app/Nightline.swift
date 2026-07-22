// Nightline — the social surface: live stories (service, viewer, camera
// composer), story/post moderation, the timeline feed, post cards, the
// profile feed, and shared remote-image caching. Extracted from
// content_view.swift; pure relocation.

import SwiftUI
import Combine
import PhotosUI
import UIKit
import MapKit
import CoreLocation
import Foundation
import Supabase

// MARK: - Live stories
//
// A photo posted to the TONIGHT strip for your friends, optionally stamped
// with your at-the-moment BAC, a caption, and where you are (check-in,
// pre-game, or between-bars). Ephemeral: visible for 24h (RLS filters
// reads), then purged by the daily cleanup job (rows + storage).

struct LiveStory: Decodable, Identifiable, Equatable {
    let id: UUID
    let profileId: UUID
    let storagePath: String
    let caption: String?
    let bac: Double?
    let stamp: String?
    let createdAt: Date

    var url: URL? {
        try? supabase.storage.from("stories").getPublicURL(path: storagePath)
    }

    enum CodingKeys: String, CodingKey {
        case id, caption, bac, stamp
        case profileId = "profile_id"
        case storagePath = "storage_path"
        case createdAt = "created_at"
    }
}

@MainActor
final class StoriesService: ObservableObject {
    /// Every fresh story visible to me (mine + friends'), newest first.
    /// RLS enforces both the friendship gate and the 24h window.
    @Published private(set) var stories: [LiveStory] = []
    private var myId: UUID? { supabase.auth.currentUser?.id }

    var mine: [LiveStory] {
        guard let uid = myId else { return [] }
        return stories(for: uid)
    }

    /// One user's fresh stories, oldest first (viewing order).
    func stories(for profileId: UUID) -> [LiveStory] {
        stories.filter { $0.profileId == profileId }.sorted { $0.createdAt < $1.createdAt }
    }

    /// True when a friend posted a story or a night since the user last
    /// looked at the Nightline — drives the tab's wiggle + badge.
    @Published private(set) var hasUnseenNightline = false
    /// How many unseen things (friend stories + feed posts) — the number
    /// in the tab badge.
    @Published private(set) var unseenNightlineCount = 0
    private var pollTask: Task<Void, Never>? = nil
    private var lastSeenKey: String {
        "sesh.nightline.lastSeen.v1.\(myId?.uuidString.lowercased() ?? "anon")"
    }

    func refresh() async {
        do {
            let rows: [LiveStory] = try await supabase.from("live_stories")
                .select()
                .order("created_at", ascending: false)
                .execute()
                .value
            stories = rows
        } catch {
            // Keep the previous list on a transient failure.
        }
        await refreshMyViews()
        await refreshUnseen()
    }

    /// Anything new on the Nightline since the user last visited it?
    /// Counts unseen friend stories (already fetched) plus unseen feed
    /// posts (one tiny query; RLS scopes it to friends).
    private func refreshUnseen() async {
        struct PostRow: Decodable {
            let createdAt: Date
            enum CodingKeys: String, CodingKey { case createdAt = "created_at" }
        }
        let lastSeen = Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: lastSeenKey))
        var count = 0
        if let uid = myId {
            count += stories.filter { $0.profileId != uid && $0.createdAt > lastSeen }.count
            let iso = ISO8601DateFormatter()
            let posts: [PostRow] = (try? await supabase.from("posts")
                .select("created_at")
                .neq("author_id", value: uid.uuidString.lowercased())
                .gt("created_at", value: iso.string(from: lastSeen))
                .order("created_at", ascending: false)
                .limit(20)
                .execute()
                .value) ?? []
            count += posts.count
        }
        unseenNightlineCount = count
        hasUnseenNightline = count > 0
    }

    /// The user is looking at the Nightline — quiet the buzz.
    func markNightlineSeen() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastSeenKey)
        hasUnseenNightline = false
        unseenNightlineCount = 0
    }

    func startPolling(every seconds: TimeInterval = 120) {
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

    /// Compress + upload + register one story. Same storage discipline as
    /// group schnaps (~1280px JPEG, a couple hundred KB).
    func post(imageData: Data, caption: String?, bac: Double?, stamp: String?) async {
        guard let uid = myId,
              let jpeg = RecapPhotoUtil.compressedJPEG(imageData, maxDimension: 1280, quality: 0.65)
        else { return }
        let path = "\(uid.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
        struct Row: Encodable {
            let profile_id: String
            let storage_path: String
            let caption: String?
            let bac: Double?
            let stamp: String?
        }
        let trimmed = caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await StorageUploader.uploadImage(
                bucket: "stories", path: path, data: jpeg)
            let inserted: LiveStory = try await supabase.from("live_stories")
                .insert(Row(
                    profile_id: uid.uuidString.lowercased(),
                    storage_path: path,
                    caption: (trimmed?.isEmpty ?? true) ? nil : trimmed,
                    bac: bac,
                    stamp: stamp
                ))
                .select()
                .single()
                .execute()
                .value
            stories.insert(inserted, at: 0)
        } catch {
            // Next post retries; nothing local to roll back.
        }
    }

    func delete(_ story: LiveStory) async {
        guard story.profileId == myId else { return }
        _ = try? await supabase.storage.from("stories").remove(paths: [story.storagePath])
        _ = try? await supabase.from("live_stories").delete()
            .eq("id", value: story.id.uuidString.lowercased())
            .execute()
        stories.removeAll { $0.id == story.id }
    }

    // MARK: View receipts

    /// One line of a story's audience list.
    struct StoryViewerEntry: Decodable, Identifiable {
        let viewerId: UUID
        let viewedAt: Date
        let profile: ViewerProfile
        struct ViewerProfile: Decodable {
            let name: String
            let avatarUrl: String?
            enum CodingKeys: String, CodingKey {
                case name
                case avatarUrl = "avatar_url"
            }
        }
        var id: UUID { viewerId }
        enum CodingKeys: String, CodingKey {
            case viewerId = "viewer_id"
            case viewedAt = "viewed_at"
            case profile = "profiles"
        }
    }

    /// View counts for MY stories, refreshed alongside the audience.
    @Published private(set) var viewCounts: [UUID: Int] = [:]

    /// Record that I watched a friend's story. Deduped server-side by the
    /// (story, viewer) primary key; my own stories are never counted.
    /// Story ids I have watched — drives the seen/unseen ring dimming and
    /// the carousel sort (unseen people first). Server-backed via my own
    /// story_views rows (select self is allowed by migration 040), so it
    /// survives reinstalls and syncs across devices; recordView patches
    /// it optimistically so a watched ring dims the moment you close it.
    @Published private(set) var viewedByMe: Set<UUID> = []

    /// Does this person have at least one story I haven't watched yet?
    func hasUnseenStories(_ personId: UUID) -> Bool {
        stories(for: personId).contains { !viewedByMe.contains($0.id) }
    }

    /// Pull my own view receipts (called alongside the story refresh).
    func refreshMyViews() async {
        guard let uid = myId else { return }
        struct Row: Decodable {
            let storyId: UUID
            enum CodingKeys: String, CodingKey { case storyId = "story_id" }
        }
        if let rows: [Row] = try? await supabase.from("story_views")
            .select("story_id")
            .eq("viewer_id", value: uid.uuidString.lowercased())
            .execute()
            .value {
            viewedByMe = Set(rows.map(\.storyId))
        }
    }

    func recordView(of story: LiveStory) {
        guard let uid = myId, story.profileId != uid else { return }
        viewedByMe.insert(story.id)
        struct Row: Encodable { let story_id: String; let viewer_id: String }
        Task {
            _ = try? await supabase.from("story_views")
                .upsert(Row(
                    story_id: story.id.uuidString.lowercased(),
                    viewer_id: uid.uuidString.lowercased()
                ), onConflict: "story_id,viewer_id", ignoreDuplicates: true)
                .execute()
        }
    }

    /// The audience of one of MY stories (name + avatar + when), newest
    /// first. Also refreshes the story's cached count.
    func viewers(of story: LiveStory) async -> [StoryViewerEntry] {
        guard story.profileId == myId else { return [] }
        let rows: [StoryViewerEntry] = (try? await supabase.from("story_views")
            .select("viewer_id, viewed_at, profiles!story_views_viewer_id_fkey(name, avatar_url)")
            .eq("story_id", value: story.id.uuidString.lowercased())
            .order("viewed_at", ascending: false)
            .execute()
            .value) ?? []
        viewCounts[story.id] = rows.count
        return rows
    }

    /// Refresh view counts for all of MY fresh stories in one query.
    func refreshViewCounts() async {
        guard let uid = myId else { return }
        let mine = stories(for: uid)
        guard !mine.isEmpty else { viewCounts = [:]; return }
        struct Row: Decodable {
            let storyId: UUID
            enum CodingKeys: String, CodingKey { case storyId = "story_id" }
        }
        let rows: [Row] = (try? await supabase.from("story_views")
            .select("story_id")
            .in("story_id", values: mine.map { $0.id.uuidString.lowercased() })
            .execute()
            .value) ?? []
        var counts: [UUID: Int] = [:]
        for r in rows { counts[r.storyId, default: 0] += 1 }
        viewCounts = counts
    }
}

/// Everything the full-screen story viewer needs.
struct StoryViewerContext: Identifiable {
    let id = UUID()
    /// Everyone with stories, in carousel order — the viewer walks
    /// through ALL of them (IG-style), not just the tapped person.
    let people: [Person]
    let startPerson: Int

    struct Person {
        let stories: [LiveStory]
        let name: String
        let avatarUrl: String?
        let canDelete: Bool
    }
}


/// Report + block plumbing (App Review 1.2 — user-generated content).
/// Reports are write-only for users and reviewed by app admins; blocking
/// severs the friendship server-side, which removes both users from each
/// other's feed, stories, live pulse, and friends list, and prevents
/// re-friending from either side.
@MainActor
final class ModerationService: ObservableObject {
    private var myId: UUID? { supabase.auth.currentUser?.id }

    static let reasons = [
        "Inappropriate content",
        "Harassment or bullying",
        "Spam or scam",
        "Something else",
    ]

    func report(kind: String, targetId: UUID, offender: UUID?, reason: String) async {
        guard let uid = myId else { return }
        struct Row: Encodable {
            let reporter_id: String
            let target_kind: String
            let target_id: String
            let target_user_id: String?
            let reason: String
        }
        _ = try? await supabase.from("reports").insert(Row(
            reporter_id: uid.uuidString.lowercased(),
            target_kind: kind,
            target_id: targetId.uuidString.lowercased(),
            target_user_id: offender?.uuidString.lowercased(),
            reason: reason
        )).execute()
    }

    func block(_ userId: UUID) async {
        struct P: Encodable { let p_user: String }
        _ = try? await supabase
            .rpc("block_user", params: P(p_user: userId.uuidString.lowercased()))
            .execute()
    }
}

/// The whole story creation journey in ONE full-screen cover: Sesh Cam →
/// composer, swapped in place. Two separate covers used to dismiss back to
/// the Nightline between shot and editor — a jarring close/reopen flicker.
struct StoryFlowView: View {
    /// Non-nil = skip the camera (photo already picked from the roll).
    let initialImage: Data?
    let bac: Double?
    let stamp: String?
    let drinkProof: String?
    let onPost: (_ image: Data, _ bac: Double?, _ stamp: String?) -> Void
    let onCancel: () -> Void

    @State private var image: Data? = nil

    var body: some View {
        ZStack {
            if let data = image ?? initialImage {
                StoryComposer(
                    imageData: data,
                    bac: bac,
                    stamp: stamp,
                    drinkProof: drinkProof,
                    onPost: onPost,
                    onCancel: onCancel
                )
                .transition(.opacity)
            } else {
                SeshCameraView(
                    onCapture: { data in
                        // Sesh Cam shots fill the screen, Snapchat-style:
                        // center-crop the 4:3 sensor frame to the device's
                        // aspect so it matches the full-bleed preview the
                        // user composed against. Roll picks stay untouched.
                        let cropped = Self.cropToScreenAspect(data)
                        withAnimation(.easeInOut(duration: 0.18)) { image = cropped }
                    },
                    autoDismiss: false
                )
            }
        }
    }

    /// Center-crop to the device screen's aspect ratio (orientation baked
    /// in first so EXIF rotation can't skew the crop).
    private static func cropToScreenAspect(_ data: Data) -> Data {
        guard let raw = UIImage(data: data) else { return data }
        // Bake orientation.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let upright = UIGraphicsImageRenderer(size: raw.size, format: format).image { _ in
            raw.draw(in: CGRect(origin: .zero, size: raw.size))
        }
        guard let cg = upright.cgImage else { return data }
        let screen = UIScreen.main.bounds.size
        let target = screen.width / screen.height
        let size = CGSize(width: cg.width, height: cg.height)
        let current = size.width / size.height
        let cropRect: CGRect
        if current > target {
            let w = (size.height * target).rounded()
            cropRect = CGRect(x: ((size.width - w) / 2).rounded(), y: 0, width: w, height: size.height)
        } else if current < target {
            let h = (size.width / target).rounded()
            cropRect = CGRect(x: 0, y: ((size.height - h) / 2).rounded(), width: size.width, height: h)
        } else {
            return upright.jpegData(compressionQuality: 0.9) ?? data
        }
        guard let croppedCG = cg.cropping(to: cropRect) else { return data }
        return UIImage(cgImage: croppedCG).jpegData(compressionQuality: 0.9) ?? data
    }
}

/// One draggable overlay on the story canvas: free text, or a generated
/// sticker (BAC proof / drink proof). Position is normalized to the image
/// frame so flattening maps 1:1 onto pixels.
private struct StoryOverlayItem: Identifiable {
    enum Kind { case text, sticker }
    let id = UUID()
    var kind: Kind
    var text: String
    var fontIndex: Int = 0
    var colorIndex: Int = 0
    var scale: CGFloat = 1
    var position = CGPoint(x: 0.5, y: 0.42)   // normalized 0–1 in the image

    var baseSize: CGFloat { kind == .text ? 30 : 22 }

    static let fontCount = 4
    static func font(_ index: Int, size: CGFloat) -> Font {
        switch index % fontCount {
        case 0:  return .system(size: size, weight: .heavy,    design: .rounded)
        case 1:  return .system(size: size, weight: .bold,     design: .serif).italic()
        case 2:  return .system(size: size, weight: .black,    design: .monospaced)
        default: return .system(size: size, weight: .semibold, design: .default)
        }
    }
    static func uiFont(_ index: Int, size: CGFloat) -> UIFont {
        let design: UIFontDescriptor.SystemDesign
        let weight: UIFont.Weight
        var italic = false
        switch index % fontCount {
        case 0:  design = .rounded;    weight = .heavy
        case 1:  design = .serif;      weight = .bold; italic = true
        case 2:  design = .monospaced; weight = .black
        default: design = .default;    weight = .semibold
        }
        var desc = UIFont.systemFont(ofSize: size, weight: weight).fontDescriptor
        if let d = desc.withDesign(design) { desc = d }
        if italic, let d = desc.withSymbolicTraits(desc.symbolicTraits.union(.traitItalic)) { desc = d }
        return UIFont(descriptor: desc, size: size)
    }

    /// (text, pill) color pairs — cream, whiskey, ink-on-cream, cream-on-ink.
    static let colorCount = 4
    static func colors(_ index: Int) -> (fg: Color, pill: Color?) {
        switch index % colorCount {
        case 0:  return (.cream, nil)
        case 1:  return (.whiskey, nil)
        case 2:  return (.ink, .cream)
        default: return (.cream, Color.ink.opacity(0.75))
        }
    }
}

/// Full-screen story composer, Instagram/Snapchat style: the photo IS the
/// screen — tap anywhere to start typing right there, drag to place,
/// pinch to size, cycle fonts and colors, drop a BAC or proof-of-drink
/// sticker. Everything is flattened INTO the image at post so viewers see
/// exactly what you made.
private struct StoryComposer: View {
    let imageData: Data
    let bac: Double?
    let stamp: String?
    /// "3 drinks · Large beer" — the night's proof at post time.
    let drinkProof: String?
    let onPost: (_ image: Data, _ bac: Double?, _ stamp: String?) -> Void
    let onCancel: () -> Void

    @State private var includeBAC = true
    @State private var includeStamp = true
    @State private var items: [StoryOverlayItem] = []
    @State private var editingId: UUID? = nil
    @State private var imageFrame: CGRect = .zero
    @State private var dragBase: [UUID: CGPoint] = [:]
    @State private var pinchBase: [UUID: CGFloat] = [:]
    @FocusState private var textFocused: Bool
    @AppStorage(BACUnitSetting.key, store: BACUnitSetting.store) private var bacUnitMode = "auto"
    private var unit: BACUnit { BACUnitSetting.resolved(mode: bacUnitMode) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // ---- the full-bleed canvas ----
            GeometryReader { geo in
                let frame = fittedFrame(in: geo.size)
                ZStack {
                    if let img = UIImage(data: imageData) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                    }
                    // Tap the picture → start typing right there.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .local) { location in
                            if editingId != nil {
                                // First tap while editing just commits.
                                commitEditing()
                            } else {
                                addText(at: location, in: frame)
                            }
                        }
                    ForEach(items) { item in
                        // The item being edited renders in the centered
                        // editor below, not at its spot.
                        if item.id != editingId {
                            overlayView(item)
                                .position(
                                    x: frame.minX + item.position.x * frame.width,
                                    y: frame.minY + item.position.y * frame.height
                                )
                                // Tap wins over drag so "press the text to
                                // edit" always lands.
                                .highPriorityGesture(TapGesture().onEnded {
                                    if item.kind == .text {
                                        editingId = item.id
                                        textFocused = true
                                    }
                                })
                                .gesture(dragGesture(for: item.id, frame: frame))
                                .simultaneousGesture(pinchGesture(for: item.id))
                        }
                    }

                    // Editing happens CENTERED, Instagram-style — dimmed
                    // photo behind, text field high enough that the
                    // keyboard can never cover what you're typing. It
                    // snaps back to its spot on commit.
                    if let id = editingId, let item = items.first(where: { $0.id == id }) {
                        Color.black.opacity(0.45)
                            .ignoresSafeArea()
                            .onTapGesture { commitEditing() }
                        inlineEditor(for: item, maxWidth: geo.size.width - 72)
                            .position(x: geo.size.width / 2, y: geo.size.height * 0.26)
                    }
                }
                .onAppear { imageFrame = frame }
                .onChange(of: geo.size) { _, s in imageFrame = fittedFrame(in: s) }
            }
            .ignoresSafeArea(.container)
            // The canvas must NOT shift when the keyboard rises — the
            // centered editor is already placed clear of it.
            .ignoresSafeArea(.keyboard)

            // ---- floating chrome ----
            VStack(spacing: 12) {
                HStack {
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.cream)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.ink.opacity(0.6)))
                    }
                    .buttonStyle(PressScaleStyle())
                    Spacer()
                    Text("YOUR STORY")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .tracking(2.6)
                        .foregroundStyle(Color.cream.opacity(0.85))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Capsule().fill(Color.ink.opacity(0.55)))
                    Spacer()
                    Button {
                        onPost(flattened(),
                               includeBAC ? bac : nil,
                               includeStamp ? stamp : nil)
                    } label: {
                        Text("POST")
                            .font(.system(size: 13, weight: .black, design: .monospaced))
                            .tracking(1.2)
                            .foregroundStyle(Color.ink)
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(Capsule().fill(Color.whiskey))
                            .shadow(color: Color.whiskey.opacity(0.5), radius: 10, y: 3)
                    }
                    .buttonStyle(PressScaleStyle())
                }

                if editingId == nil {
                    toolbar
                }

                Spacer()

                if let id = editingId {
                    editControls(id: id)
                } else {
                    // What gets badged UNDER the story — tap to toggle.
                    HStack(spacing: 10) {
                        if let bac {
                            stampChip(icon: "gauge.medium",
                                      label: "\(unit.formatted(bac))\(unit.symbol)",
                                      on: includeBAC) { includeBAC.toggle() }
                        }
                        if let stamp, !stamp.isEmpty {
                            stampChip(icon: "mappin.circle.fill", label: stamp, on: includeStamp) {
                                includeStamp.toggle()
                            }
                        }
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .preferredColorScheme(.dark)
    }

    /// Tap-to-type: a fresh text item exactly where the finger landed
    /// (clamped into the picture), immediately in edit mode.
    private func addText(at location: CGPoint, in frame: CGRect) {
        guard frame.width > 0 else { return }
        var item = StoryOverlayItem(kind: .text, text: "")
        item.position = CGPoint(
            x: min(max((location.x - frame.minX) / frame.width, 0.05), 0.95),
            y: min(max((location.y - frame.minY) / frame.height, 0.05), 0.95)
        )
        items.append(item)
        editingId = item.id
        textFocused = true
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            toolButton("textformat", "Text") {
                var item = StoryOverlayItem(kind: .text, text: "")
                item.position = CGPoint(x: 0.5, y: 0.35)
                items.append(item)
                editingId = item.id
                textFocused = true
            }
            if let bac {
                toolButton("gauge.medium", "BAC") {
                    var item = StoryOverlayItem(
                        kind: .sticker,
                        text: "🥃 \(unit.formatted(bac))\(unit.symbol)"
                    )
                    item.colorIndex = 3
                    item.position = CGPoint(x: 0.5, y: 0.78)
                    items.append(item)
                }
            }
            if let drinkProof, !drinkProof.isEmpty {
                toolButton("wineglass.fill", "Proof") {
                    var item = StoryOverlayItem(kind: .sticker, text: "🍻 \(drinkProof)")
                    item.colorIndex = 2
                    item.position = CGPoint(x: 0.5, y: 0.88)
                    items.append(item)
                }
            }
            Spacer()
            if !items.isEmpty {
                Text("drag · pinch")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(Color.cream.opacity(0.35))
            }
        }
    }

    private func toolButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.whiskey)
                Text(label)
                    .font(.system(size: 12, weight: .black, design: .rounded))
                    .foregroundStyle(Color.cream)
            }
            .padding(.horizontal, 13).padding(.vertical, 9)
            // Solid ink pill — the old translucent chip disappeared against
            // bright photos.
            .background(Capsule().fill(Color.ink.opacity(0.85)))
            .overlay(Capsule().strokeBorder(Color.whiskey.opacity(0.6), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        }
        .buttonStyle(PressScaleStyle())
    }

    /// Crash-safe binding into the items array by ID — index-based bindings
    /// blew up when the array mutated (Done / tap-to-commit) while the
    /// field was still attached.
    private func textBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { items.first(where: { $0.id == id })?.text ?? "" },
            set: { v in
                if let i = items.firstIndex(where: { $0.id == id }) {
                    items[i].text = v
                }
            }
        )
    }

    /// The centered text field shown while editing — same font/color/pill
    /// as the rendered overlay, so what you type is what you get. Width is
    /// bounded (never zero: `fixedSize` on an empty field collapsed it to
    /// nothing, which is why typed text was invisible).
    private func inlineEditor(for item: StoryOverlayItem, maxWidth: CGFloat) -> some View {
        let c = StoryOverlayItem.colors(item.colorIndex)
        let font = StoryOverlayItem.font(item.fontIndex, size: item.baseSize * item.scale)
        return TextField(
            "",
            text: textBinding(for: item.id),
            prompt: Text("Type something…").font(font).foregroundStyle(c.fg.opacity(0.5)),
            axis: .vertical
        )
        .focused($textFocused)
        .font(font)
        .foregroundStyle(c.fg)
        .multilineTextAlignment(.center)
        .frame(maxWidth: maxWidth)
        .padding(.horizontal, c.pill == nil ? 2 : 12 * item.scale)
        .padding(.vertical, c.pill == nil ? 0 : 6 * item.scale)
        .background {
            if let pill = c.pill {
                RoundedRectangle(cornerRadius: 18 * item.scale, style: .continuous).fill(pill)
            }
        }
        .shadow(color: .black.opacity(c.pill == nil ? 0.6 : 0), radius: 3, y: 1)
    }

    /// Commit the current edit: drop empty text items, dismiss keyboard.
    private func commitEditing() {
        editingId = nil
        textFocused = false
        items.removeAll {
            $0.kind == .text && $0.text.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    @ViewBuilder
    private func editControls(id: UUID) -> some View {
        let item = items.first(where: { $0.id == id })
        HStack(spacing: 12) {
            Button {
                if let i = items.firstIndex(where: { $0.id == id }) {
                    items[i].fontIndex += 1
                }
            } label: {
                Text("Aa")
                    .font(StoryOverlayItem.font(item?.fontIndex ?? 0, size: 16))
                    .foregroundStyle(Color.cream)
                    .frame(width: 44, height: 38)
                    .background(Capsule().fill(Color.cream.opacity(0.12)))
            }
            Button {
                if let i = items.firstIndex(where: { $0.id == id }) {
                    items[i].colorIndex += 1
                }
            } label: {
                let c = StoryOverlayItem.colors(item?.colorIndex ?? 0)
                Circle()
                    .fill(c.pill ?? c.fg)
                    .frame(width: 24, height: 24)
                    .overlay(Circle().strokeBorder(Color.cream.opacity(0.5), lineWidth: 1.5))
                    .frame(width: 44, height: 38)
            }
            Button {
                items.removeAll { $0.id == id }
                editingId = nil
                textFocused = false
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.cream.opacity(0.8))
                    .frame(width: 44, height: 38)
            }
            Spacer()
            Button("Done") { commitEditing() }
                .font(.system(size: 14, weight: .black, design: .rounded))
                .foregroundStyle(Color.whiskey)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Capsule().fill(Color.ink.opacity(0.85)))
    }

    // MARK: canvas pieces

    private func overlayView(_ item: StoryOverlayItem) -> some View {
        let c = StoryOverlayItem.colors(item.colorIndex)
        return Text(item.text)
            .font(StoryOverlayItem.font(item.fontIndex, size: item.baseSize * item.scale))
            .foregroundStyle(c.fg)
            .multilineTextAlignment(.center)
            .padding(.horizontal, c.pill == nil ? 0 : 12 * item.scale)
            .padding(.vertical, c.pill == nil ? 0 : 6 * item.scale)
            .background {
                if let pill = c.pill {
                    Capsule().fill(pill)
                }
            }
            .shadow(color: .black.opacity(c.pill == nil ? 0.6 : 0), radius: 3, y: 1)
    }

    private func dragGesture(for id: UUID, frame: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
                let base = dragBase[id] ?? items[idx].position
                dragBase[id] = base
                let nx = base.x + value.translation.width / max(frame.width, 1)
                let ny = base.y + value.translation.height / max(frame.height, 1)
                items[idx].position = CGPoint(
                    x: min(max(nx, 0.03), 0.97),
                    y: min(max(ny, 0.03), 0.97)
                )
            }
            .onEnded { _ in dragBase[id] = nil }
    }

    private func pinchGesture(for id: UUID) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
                let base = pinchBase[id] ?? items[idx].scale
                pinchBase[id] = base
                items[idx].scale = min(max(base * value, 0.5), 3.5)
            }
            .onEnded { _ in pinchBase[id] = nil }
    }

    /// Where the aspect-fit image lands inside the canvas area.
    private func fittedFrame(in container: CGSize) -> CGRect {
        guard let img = UIImage(data: imageData),
              img.size.width > 0, img.size.height > 0,
              container.width > 0, container.height > 0
        else { return .zero }
        let scale = min(container.width / img.size.width, container.height / img.size.height)
        let w = img.size.width * scale
        let h = img.size.height * scale
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }

    /// Bake the overlays into the photo so viewers see exactly this canvas.
    private func flattened() -> Data {
        guard !items.isEmpty,
              let base = UIImage(data: imageData),
              imageFrame.width > 0
        else { return imageData }
        let pixelScale = base.size.width / imageFrame.width
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: base.size, format: format).image { _ in
            base.draw(in: CGRect(origin: .zero, size: base.size))
            for item in items {
                let c = StoryOverlayItem.colors(item.colorIndex)
                let fontSize = item.baseSize * item.scale * pixelScale
                let font = StoryOverlayItem.uiFont(item.fontIndex, size: fontSize)
                let para = NSMutableParagraphStyle()
                para.alignment = .center
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: UIColor(c.fg),
                    .paragraphStyle: para,
                ]
                if c.pill == nil {
                    let shadow = NSShadow()
                    shadow.shadowColor = UIColor.black.withAlphaComponent(0.6)
                    shadow.shadowBlurRadius = 3 * pixelScale
                    shadow.shadowOffset = CGSize(width: 0, height: pixelScale)
                    attrs[.shadow] = shadow
                }
                let str = NSAttributedString(string: item.text, attributes: attrs)
                let textSize = str.size()
                let center = CGPoint(
                    x: item.position.x * base.size.width,
                    y: item.position.y * base.size.height
                )
                let origin = CGPoint(
                    x: center.x - textSize.width / 2,
                    y: center.y - textSize.height / 2
                )
                if let pill = c.pill {
                    let padX = 12 * item.scale * pixelScale
                    let padY = 6 * item.scale * pixelScale
                    let rect = CGRect(
                        x: origin.x - padX, y: origin.y - padY,
                        width: textSize.width + padX * 2,
                        height: textSize.height + padY * 2
                    )
                    UIColor(pill).setFill()
                    UIBezierPath(roundedRect: rect, cornerRadius: rect.height / 2).fill()
                }
                str.draw(at: origin)
            }
        }
        return rendered.jpegData(compressionQuality: 0.85) ?? imageData
    }

    private func stampChip(icon: String, label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: on ? "checkmark.circle.fill" : icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(on ? Color.ink : Color.whiskey)
                Text(label)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(on ? Color.ink : Color.cream.opacity(0.7))
                    .lineLimit(1)
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(Capsule().fill(on ? Color.whiskey : Color.cream.opacity(0.06)))
            .overlay(Capsule().strokeBorder(Color.whiskey.opacity(on ? 0 : 0.4), lineWidth: 1))
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// Full-screen story pager: swipe through one user's fresh stories with
/// their caption, BAC (in the VIEWER's unit) and location stamp. Watching
/// a friend's story records a view receipt; on your OWN stories a views
/// pill opens the audience list.
struct StoryViewer: View {
    let ctx: StoryViewerContext
    @ObservedObject var svc: StoriesService
    @ObservedObject var dm: DMService
    @ObservedObject var feed: FeedService
    let onDelete: (LiveStory) -> Void
    let onClose: () -> Void

    @State private var personIndex: Int
    @State private var index = 0
    @State private var openProfile: ProfileRef?
    @State private var dragOffset: CGFloat = 0
    /// Which way the last person-switch went — drives the slide direction.
    @State private var personSwitchForward = true
    /// Reply bar (friends' stories): text draft + a brief "sent" flash.
    @State private var replyDraft = ""
    @State private var sentFlash: String?
    @FocusState private var replyFocused: Bool
    @State private var audience: [StoriesService.StoryViewerEntry]? = nil
    @State private var reportOpen = false
    @StateObject private var moderation = ModerationService()
    @AppStorage(BACUnitSetting.key, store: BACUnitSetting.store) private var bacUnitMode = "auto"
    private var unit: BACUnit { BACUnitSetting.resolved(mode: bacUnitMode) }

    init(ctx: StoryViewerContext, svc: StoriesService, dm: DMService, feed: FeedService,
         onDelete: @escaping (LiveStory) -> Void, onClose: @escaping () -> Void) {
        self.ctx = ctx
        self.svc = svc
        self.dm = dm
        self.feed = feed
        self.onDelete = onDelete
        self.onClose = onClose
        _personIndex = State(initialValue: min(ctx.startPerson, max(ctx.people.count - 1, 0)))
    }

    /// The current person as a ProfileRef (id from their story rows).
    private var personRef: ProfileRef? {
        guard let pid = person.stories.first?.profileId else { return nil }
        return ProfileRef(id: pid, name: person.name, username: nil, avatar: person.avatarUrl)
    }

    /// The person whose stories are on screen right now.
    private var person: StoryViewerContext.Person {
        ctx.people[min(personIndex, ctx.people.count - 1)]
    }

    /// Brief "Sent" confirmation over the reply bar.
    private func flashSent(_ text: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            sentFlash = text
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            withAnimation(.easeOut(duration: 0.25)) {
                sentFlash = nil
            }
        }
    }

    /// Tap right → next story, rolling into the next person's stories;
    /// past the very last one the viewer closes (IG behaviour).
    private func advance() {
        if index + 1 < person.stories.count {
            index += 1
        } else if personIndex + 1 < ctx.people.count {
            // Person switch gets a real slide so it doesn't read as just
            // another photo of the same person.
            personSwitchForward = true
            withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
                personIndex += 1
                index = 0
            }
        } else {
            onClose()
        }
    }

    /// Tap left → previous story, rolling back to the previous person's
    /// LAST story (stepping backwards chronologically through the strip).
    private func goBack() {
        if index > 0 {
            index -= 1
        } else if personIndex > 0 {
            personSwitchForward = false
            let target = personIndex - 1
            withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
                personIndex = target
                index = max(ctx.people[target].stories.count - 1, 0)
            }
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(person.stories.enumerated()), id: \.element.id) { i, story in
                    storyPage(story).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // Re-mount the pager when the person flips so the selection
            // resets cleanly to the new person's story set — and slide
            // the whole page sideways so it's obvious you've moved on to
            // a DIFFERENT person, not just their next photo.
            .id(personIndex)
            .transition(.asymmetric(
                insertion: .move(edge: personSwitchForward ? .trailing : .leading)
                    .combined(with: .opacity),
                removal: .move(edge: personSwitchForward ? .leading : .trailing)
                    .combined(with: .opacity)
            ))
            // IG-style tap zones: left quarter = back, the rest = forward.
            // They sit UNDER the header row (added later in the ZStack),
            // so the avatar / trash / flag / ✕ buttons stay tappable.
            .overlay(
                HStack(spacing: 0) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { goBack() }
                        .frame(maxWidth: .infinity)
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { advance() }
                        .frame(maxWidth: .infinity)
                }
            )
            .onAppear {
                if person.stories.indices.contains(index) {
                    svc.recordView(of: person.stories[index])
                }
                if person.canDelete {
                    Task { await svc.refreshViewCounts() }
                }
            }
            .onChange(of: index) { _, i in
                if person.stories.indices.contains(i) {
                    svc.recordView(of: person.stories[i])
                }
            }
            .onChange(of: personIndex) { _, _ in
                if person.stories.indices.contains(index) {
                    svc.recordView(of: person.stories[index])
                }
            }

            // Segmented progress: one notch per story of the current
            // person, filled through the one on screen.
            HStack(spacing: 4) {
                ForEach(person.stories.indices, id: \.self) { i in
                    Capsule()
                        .fill(i <= index ? Color.cream : Color.cream.opacity(0.25))
                        .frame(height: 3)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)

            // MY story → views pill (count + tap for the audience list).
            if person.canDelete, person.stories.indices.contains(index) {
                let story = person.stories[index]
                VStack {
                    Spacer()
                    HStack {
                        Button {
                            Task { audience = await svc.viewers(of: story) }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "eye.fill")
                                    .font(.system(size: 12, weight: .bold))
                                Text("\(svc.viewCounts[story.id] ?? 0)")
                                    .font(.system(size: 13, weight: .black, design: .monospaced))
                            }
                            .foregroundStyle(Color.cream)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Capsule().fill(Color.ink.opacity(0.7)))
                        }
                        .buttonStyle(PressScaleStyle())
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }

            // FRIEND's story → reply bar + like, IG-style. Both land in
            // their DMs (and push them), so the conversation continues in
            // the chat.
            if !person.canDelete, person.stories.indices.contains(index) {
                let story = person.stories[index]
                VStack {
                    Spacer()
                    HStack(spacing: 10) {
                        TextField(
                            "", text: $replyDraft,
                            prompt: Text("Reply to \(person.name)…")
                                .foregroundColor(.white.opacity(0.55))
                        )
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(.white)
                            .tint(Color.whiskey)
                            .focused($replyFocused)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(Color.black.opacity(0.35)))
                            .overlay(Capsule().strokeBorder(.white.opacity(0.4), lineWidth: 1))
                        if replyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button {
                                let t: Task<Void, Never> = Task {
                                    await dm.sendStoryLike(story: story)
                                }
                                _ = t
                                flashSent("❤️ Sent")
                            } label: {
                                Image(systemName: "heart.fill")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundStyle(Color(red: 0.92, green: 0.32, blue: 0.35))
                                    .frame(width: 42, height: 42)
                                    .background(Circle().fill(Color.black.opacity(0.35)))
                            }
                            .buttonStyle(PressScaleStyle())
                        } else {
                            Button {
                                let text = replyDraft
                                replyDraft = ""
                                replyFocused = false
                                let t: Task<Void, Never> = Task {
                                    await dm.sendStoryReply(text, story: story)
                                }
                                _ = t
                                flashSent("Sent")
                            } label: {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 16, weight: .black))
                                    .foregroundStyle(Color.ink)
                                    .frame(width: 42, height: 42)
                                    .background(Circle().fill(Color.whiskey))
                            }
                            .buttonStyle(PressScaleStyle())
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                }
            }

            if let sentFlash {
                VStack {
                    Spacer()
                    Text(sentFlash)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Color.black.opacity(0.6)))
                        .padding(.bottom, 76)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            HStack(spacing: 10) {
                // Tap the avatar/name → the poster's profile feed.
                Button {
                    if let ref = personRef { openProfile = ref }
                } label: {
                    HStack(spacing: 10) {
                        AvatarView(urlString: person.avatarUrl,
                                   initial: String(person.name.prefix(1)).uppercased(),
                                   size: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(person.name)
                                .font(.system(size: 14, weight: .heavy, design: .rounded))
                                .foregroundStyle(Color.cream)
                            if person.stories.indices.contains(index) {
                                Text(timeAgo(person.stories[index].createdAt))
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Color.cream.opacity(0.55))
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(person.canDelete)   // no point opening my own via story
                Spacer()
                if person.canDelete, person.stories.indices.contains(index) {
                    Button {
                        let victim = person.stories[index]
                        onDelete(victim)
                        onClose()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.cream)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(Color.ink.opacity(0.7)))
                    }
                    .buttonStyle(PressScaleStyle())
                }
                if !person.canDelete, person.stories.indices.contains(index) {
                    Button {
                        reportOpen = true
                    } label: {
                        Image(systemName: "flag")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.cream.opacity(0.85))
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(Color.ink.opacity(0.7)))
                    }
                    .buttonStyle(PressScaleStyle())
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.cream)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.ink.opacity(0.7)))
                }
                .buttonStyle(PressScaleStyle())
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
        }
        // Drag down anywhere to close — the card follows the finger and
        // lets go past the threshold, IG/Snap style.
        .offset(y: dragOffset)
        .gesture(
            DragGesture(minimumDistance: 25)
                .onChanged { v in
                    dragOffset = max(0, v.translation.height)
                }
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
        // Report this story / block its author (friends' stories only).
        .sheet(item: $openProfile) { ref in
            ProfileFeedView(user: ref, feed: feed)
                .presentationBackground(Color.ink)
        }
        .confirmationDialog("Report this story?", isPresented: $reportOpen, titleVisibility: .visible) {
            ForEach(ModerationService.reasons, id: \.self) { reason in
                Button(reason) {
                    guard person.stories.indices.contains(index) else { return }
                    let story = person.stories[index]
                    Task {
                        await moderation.report(
                            kind: "story", targetId: story.id,
                            offender: story.profileId, reason: reason
                        )
                    }
                }
            }
            Button("Block \(person.name)", role: .destructive) {
                guard person.stories.indices.contains(index) else { return }
                let story = person.stories[index]
                Task {
                    await moderation.block(story.profileId)
                    await svc.refresh()
                }
                onClose()
            }
            Button("Cancel", role: .cancel) {}
        }
        // The audience: who watched this story, newest first.
        .sheet(isPresented: Binding(
            get: { audience != nil },
            set: { if !$0 { audience = nil } }
        )) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    Image(systemName: "eye.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.whiskey)
                    Text("VIEWED BY \(audience?.count ?? 0)")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .tracking(2.2)
                        .foregroundStyle(Color.bronze)
                    Spacer()
                }
                if let audience, !audience.isEmpty {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 10) {
                            ForEach(audience) { v in
                                HStack(spacing: 10) {
                                    AvatarView(urlString: v.profile.avatarUrl,
                                               initial: String(v.profile.name.prefix(1)).uppercased(),
                                               size: 34)
                                    Text(v.profile.name)
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                        .foregroundStyle(Color.cream)
                                    Spacer()
                                    Text(v.viewedAt, style: .time)
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Color.cream.opacity(0.5))
                                }
                            }
                        }
                    }
                } else {
                    Text("No views yet — give it a minute.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.5))
                    Spacer()
                }
            }
            .padding(18)
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.ink)
        }
    }

    @ViewBuilder
    private func storyPage(_ story: LiveStory) -> some View {
        ZStack {
            DownsampledAsyncImage(url: story.url, targetPoints: 700, fill: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack {
                Spacer()
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        if let bac = story.bac {
                            storyBadge(icon: "gauge.medium",
                                       text: "\(unit.formatted(bac))\(unit.symbol)")
                        }
                        if let stamp = story.stamp, !stamp.isEmpty {
                            storyBadge(icon: "mappin.circle.fill", text: stamp)
                        }
                    }
                    if let caption = story.caption, !caption.isEmpty {
                        Text(caption)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.cream)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Capsule().fill(Color.ink.opacity(0.65)))
                    }
                }
                .padding(.bottom, 42)
            }
        }
    }

    private func storyBadge(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.whiskey)
            Text(text)
                .font(.system(size: 12, weight: .black, design: .monospaced))
                .foregroundStyle(Color.cream)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(Color.ink.opacity(0.7)))
    }

    private func timeAgo(_ date: Date) -> String {
        let mins = max(0, Int(Date().timeIntervalSince(date) / 60))
        if mins < 60 { return "\(mins)m ago" }
        return "\(mins / 60)h \(mins % 60)m ago"
    }
}

/// Wires the friends-pulse feature into SessionView as ONE modifier:
/// publishes my presence on anything a friend could notice (drink logged,
/// sesh started/ended, group joined/left, check-in), polls friends' pulse
/// only while the Nightline tab is on screen, and hosts the detail sheet.
struct PulseWiringModifier: ViewModifier {
    @ObservedObject var live: LiveSeshState
    @ObservedObject var liveGroup: SessionService
    @ObservedObject var venues: VenueService
    @ObservedObject var friendsPulse: FriendsPulseService
    @ObservedObject var stories: StoriesService
    /// Feed + DM services so a tapped friend's sheet can open their profile /
    /// a chat, plus the signed-in user for the chat thread.
    @ObservedObject var feed: FeedService
    @ObservedObject var dm: DMService
    let profile: Profile
    @Binding var openPulse: FriendPulse?
    let tab: TopTab
    let publish: () -> Void
    /// A live sesh terminally ended → SessionView checks out of the venue.
    let onLiveEnded: () -> Void
    /// Journey markers changed (or a group was entered) → mirror them into
    /// the shared route so the group recap sees everyone's stops.
    @ObservedObject var journey: NightJourneyStore
    let syncMarkers: () -> Void
    /// The group's server route changed → merge it into my journey.
    let mergeRoute: () -> Void
    /// Flipping location sharing must re-publish presence right away so
    /// friends' maps add/drop my pin without waiting for the next event.
    @AppStorage(ShareLocationSetting.key) private var shareLocation = true

    func body(content: Content) -> some View {
        content
            .onChange(of: shareLocation) { _, _ in publish() }
            .onChange(of: live.drinks) { _, _ in publish() }
            .onChange(of: live.startedAt) { _, _ in publish() }
            .onChange(of: liveGroup.session?.id) { _, _ in
                publish()
                syncMarkers()
            }
            .onChange(of: venues.currentVenue?.id) { _, _ in publish() }
            .onChange(of: liveGroup.liveEndedToken) { _, _ in onLiveEnded() }
            .onChange(of: journey.stops) { _, _ in syncMarkers() }
            .onChange(of: journey.looseSpots) { _, _ in syncMarkers() }
            .onChange(of: liveGroup.routeStops) { _, _ in mergeRoute() }
            .task {
                publish()
                // Slow app-wide polls so the NIGHTLINE tab can buzz when a
                // friend goes live or posts, wherever the user is.
                friendsPulse.startPolling(every: 180)
                stories.startPolling(every: 180)
            }
            .onChange(of: tab) { _, newTab in
                // Fast while the TONIGHT strip is on screen, slow otherwise.
                friendsPulse.startPolling(every: newTab == .timeline ? 45 : 180)
                stories.startPolling(every: newTab == .timeline ? 45 : 180)
                if newTab == .timeline {
                    // They came to look — quiet the buzz.
                    stories.markNightlineSeen()
                }
            }
            .sheet(item: $openPulse) { p in
                FriendPulseSheet(pulse: p, feed: feed, dm: dm, me: profile)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(Color.ink)
            }
    }
}

/// The TIMELINE tab — a scrollable feed of friends' posted nights.
struct TimelineFeedView: View {
    @ObservedObject var feed: FeedService
    @ObservedObject var pulse: FriendsPulseService
    @ObservedObject var stories: StoriesService
    @ObservedObject var dm: DMService
    let profile: Profile
    let storyBAC: () -> Double?
    let storyStamp: () -> String?
    let storyProof: () -> String?
    let onOpenPost: (TimelinePost) -> Void
    let onOpenAuthor: (TimelinePost) -> Void
    let onOpenPulse: (FriendPulse) -> Void
    @StateObject private var moderation = ModerationService()

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                Text("NIGHTLINE")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .tracking(2.4).foregroundStyle(Color.bronze)
                    .padding(.horizontal, 22).padding(.top, 6)

                FriendsPulseStrip(
                    pulse: pulse,
                    stories: stories,
                    dm: dm,
                    feed: feed,
                    profile: profile,
                    storyBAC: storyBAC,
                    storyStamp: storyStamp,
                    storyProof: storyProof,
                    onOpen: onOpenPulse
                )

                if feed.posts.isEmpty {
                    emptyState
                } else {
                    ForEach(feed.posts) { post in
                        PostCard(post: post,
                                 onOpenPost: { onOpenPost(post) },
                                 onOpenAuthor: { onOpenAuthor(post) },
                                 onLike: { Task { await feed.toggleLike(post.id) } })
                            .padding(.horizontal, 16)
                            .contextMenu {
                                Menu {
                                    ForEach(ModerationService.reasons, id: \.self) { reason in
                                        Button(reason) {
                                            Task {
                                                await moderation.report(
                                                    kind: "post", targetId: post.id,
                                                    offender: post.authorId, reason: reason
                                                )
                                            }
                                        }
                                    }
                                } label: { Label("Report post", systemImage: "flag") }
                                Button(role: .destructive) {
                                    Task {
                                        await moderation.block(post.authorId)
                                        await feed.refresh()
                                        await pulse.refresh()
                                        await stories.refresh()
                                    }
                                } label: { Label("Block \(post.authorName)", systemImage: "hand.raised") }
                            }
                    }
                }
            }
            .padding(.bottom, 40)
        }
        .refreshable {
            await feed.refresh()
            await pulse.refresh()
            await stories.refresh()
        }
        // Re-fetch whenever the timeline appears so newly posted (or deleted)
        // nights show up. Stable post/photo ids keep this from resetting the
        // carousels, and downsampled images keep it cheap.
        .onAppear { feed.start(); Task { await feed.refresh() } }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.whiskey.opacity(0.7))
            Text("No posts yet")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(Color.cream)
            Text("When your friends post their nights, they show up here. Add friends, then share your own recap after a night out.")
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.6))
                .multilineTextAlignment(.center).lineSpacing(2)
        }
        .frame(maxWidth: .infinity).padding(.horizontal, 36).padding(.top, 90)
    }
}

/// All of a night's photos paired with the stop they were taken at.
/// `id` is the URL (stable) so SwiftUI doesn't rebuild the carousel — a
/// fresh UUID each render was resetting the pager and reloading every image.
private struct NightPhoto: Identifiable {
    var id: String { url.absoluteString }
    let stop: String
    let url: URL
}

/// Compact straight-line crawl distance, e.g. "820 m" or "1.4 km".
private func crawlDistanceString(_ meters: Double) -> String {
    meters >= 1000
        ? String(format: "%.1f km", meters / 1000)
        : "\(Int(meters.rounded())) m"
}

private func nightPhotos(_ recap: NightRecap) -> [NightPhoto] {
    recap.stops.flatMap { stop in
        stop.photoFilenames.compactMap { s in
            URL(string: s).map { NightPhoto(stop: stop.name, url: $0) }
        }
    }
}

/// Small in-memory cache of already-downsampled images (keyed by URL+size).
private enum RemoteImageCache {
    static let shared: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 80
        // Hard ceiling on decoded-image memory regardless of count — without a
        // cost limit the cache can balloon well past what the count implies.
        c.totalCostLimit = 48 * 1024 * 1024   // 48 MB
        return c
    }()
}

/// Loads a remote image and **downsamples it to the displayed size** via
/// ImageIO before decoding — so a 4000px photo shown at 130px costs ~0.5 MB
/// instead of ~48 MB. Caches the small result. This is the main lever for
/// keeping memory sane across the feed + profile grids.
struct DownsampledAsyncImage: View {
    let url: URL?
    /// Max dimension in points; multiplied by screen scale for pixels.
    let targetPoints: CGFloat
    var fill: Bool = true
    var placeholder: Color = Color.cream.opacity(0.06)

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                if fill {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(uiImage: image).resizable().scaledToFit()
                }
            } else {
                placeholder
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { return }
        let maxPixels = Int(targetPoints * UIScreen.main.scale)
        let cacheKey = "\(url.absoluteString)@\(maxPixels)"
        let memKey = cacheKey as NSString

        // 1) hot in-memory → 2) persistent on-disk (survives relaunches).
        if let cached = RemoteImageCache.shared.object(forKey: memKey) {
            image = cached; return
        }
        if let disk = SeshImageCache.image(for: cacheKey) {
            RemoteImageCache.shared.setObject(disk, forKey: memKey, cost: Self.cost(disk))
            image = disk; return
        }

        // 3) network. For small displays, pull the tiny server-side thumbnail
        // sibling (a few dozen KB) instead of the full original. Legacy content
        // with no thumb 404s once, is remembered, and falls back to the original.
        var data: Data?
        if maxPixels <= 512, url.hasSeshThumbnails, let thumb = url.seshThumbURL,
           !SeshImageCache.isThumbMissing(thumb.absoluteString) {
            data = await Self.fetch(thumb)
            if data == nil { SeshImageCache.markThumbMissing(thumb.absoluteString) }
        }
        if data == nil { data = await Self.fetch(url) }

        guard let data, let down = Self.downsample(data: data, maxPixels: maxPixels) else { return }
        RemoteImageCache.shared.setObject(down, forKey: memKey, cost: Self.cost(down))
        SeshImageCache.store(down, for: cacheKey)
        if !Task.isCancelled { image = down }
    }

    private static func cost(_ img: UIImage) -> Int {
        img.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
    }

    /// Fetch bytes, treating any non-2xx (e.g. a missing thumbnail) as a miss.
    private static func fetch(_ u: URL) async -> Data? {
        guard let (data, resp) = try? await URLSession.shared.data(from: u) else { return nil }
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        return data
    }

    private static func downsample(data: Data, maxPixels: Int) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// One night in the feed. Tapping the author header opens their profile;
/// the photos swipe through the whole night (each tagged with its stop);
/// tapping a photo or the stats opens the full post.
private struct PostCard: View {
    let post: TimelinePost
    let onOpenPost: () -> Void
    let onOpenAuthor: () -> Void
    let onLike: () -> Void

    private var barCount: Int { post.recap.stops.filter { $0.kind == .bar }.count }
    private var photos: [NightPhoto] { nightPhotos(post.recap) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onOpenAuthor) {
                HStack(spacing: 10) {
                    FriendAvatar(name: post.authorName, avatarURL: post.authorAvatar, size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(post.authorName)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.cream)
                        if let u = post.authorUsername {
                            Text("@\(u)").font(.system(size: 11, design: .rounded))
                                .foregroundStyle(Color.cream.opacity(0.5))
                        }
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

            // Swipeable photo carousel — each photo tagged with its stop.
            if !photos.isEmpty {
                TabView {
                    ForEach(photos) { photo in
                        ZStack(alignment: .bottomLeading) {
                            DownsampledAsyncImage(url: photo.url, targetPoints: 420)
                            .frame(maxWidth: .infinity).frame(height: 260).clipped()
                            .overlay(LinearGradient(colors: [.clear, Color.ink.opacity(0.5)],
                                                    startPoint: .center, endPoint: .bottom))

                            HStack(spacing: 5) {
                                Image(systemName: "mappin.circle.fill").font(.system(size: 11))
                                Text(photo.stop)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(Color.cream)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(Color.ink.opacity(0.55)))
                            .padding(12)
                            .padding(.bottom, photos.count > 1 ? 16 : 0) // clear the page dots
                            .contentShape(Rectangle())
                            .onTapGesture { onOpenPost() }
                        }
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: photos.count > 1 ? .automatic : .never))
                .frame(height: 260)
            }

            // Like + comment bar.
            HStack(spacing: 18) {
                Button(action: onLike) {
                    HStack(spacing: 6) {
                        Image(systemName: post.likedByMe ? "heart.fill" : "heart")
                            .font(.system(size: 23, weight: .semibold))
                            .foregroundStyle(post.likedByMe ? Status.drunk.color : Color.cream.opacity(0.85))
                        if post.likeCount > 0 {
                            Text("\(post.likeCount)").foregroundStyle(Color.cream.opacity(0.85))
                        }
                    }
                    // Bigger, more forgiving tap target than the bare icon.
                    .padding(.vertical, 6)
                    .padding(.trailing, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle())
                Button(action: onOpenPost) {
                    HStack(spacing: 6) {
                        Image(systemName: "bubble.right").foregroundStyle(Color.cream.opacity(0.85))
                        if post.commentCount > 0 {
                            Text("\(post.commentCount)").foregroundStyle(Color.cream.opacity(0.85))
                        }
                    }
                }
                .buttonStyle(PressScaleStyle())
                Spacer()
            }
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .padding(.horizontal, 14).padding(.top, 12)

            Button(action: onOpenPost) {
                VStack(alignment: .leading, spacing: 8) {
                    if let caption = post.caption, !caption.isEmpty {
                        Text(caption)
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.92))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack(spacing: 12) {
                        Label("\(barCount) stop\(barCount == 1 ? "" : "s")", systemImage: "mappin.and.ellipse")
                        Label("\(post.recap.totalDrinks)", systemImage: "wineglass")
                        Label(crawlDistanceString(post.recap.crawlMeters), systemImage: "figure.walk")
                        if post.includeBAC {
                            let unit = BACUnitSetting.current()
                            Label("\(unit.formatted(post.recap.peakBAC))\(unit.symbol)", systemImage: "flame.fill")
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.bronze)
                    }
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.8))
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleStyle())
        }
        .background(Color.cream.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.cream.opacity(0.1), lineWidth: 1))
    }
}

/// Lightweight reference to a profile we can open a post grid for.
struct ProfileRef: Identifiable, Equatable {
    let id: UUID
    let name: String
    let username: String?
    let avatar: String?
}

/// Square cover thumbnail for the profile grids. Falls back to a tinted
/// tile with the drink count when a post has no photo.
struct PostThumb: View {
    let post: TimelinePost
    var body: some View {
        Color.cream.opacity(0.06)
            .overlay {
                if let cover = post.coverURL, let url = URL(string: cover) {
                    DownsampledAsyncImage(url: url, targetPoints: 160)
                } else {
                    VStack(spacing: 4) {
                        Text("🍻").font(.system(size: 22))
                        Text("\(post.recap.totalDrinks)")
                            .font(.system(size: 12, weight: .black, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.8))
                    }
                }
            }
            // Force a strict square cell so the grid is uniform (Instagram-style).
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipped()
            .overlay(Rectangle().strokeBorder(Color.ink, lineWidth: 1))
    }
}

/// A profile page: avatar + name + posted-sesh count, with a grid of that
/// user's posts (their full archive). Tap a tile to open the night.
struct ProfileFeedView: View {
    let user: ProfileRef
    @ObservedObject var feed: FeedService
    @Environment(\.dismiss) private var dismiss

    @State private var posts: [TimelinePost] = []
    @State private var loading = true
    @State private var selectedPost: TimelinePost?

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.ink.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    VStack(spacing: 8) {
                        FriendAvatar(name: user.name, avatarURL: user.avatar, size: 78)
                        Text(user.name)
                            .font(.system(size: 20, weight: .black, design: .rounded))
                            .foregroundStyle(Color.cream)
                        if let u = user.username {
                            Text("@\(u)").font(.system(size: 13, design: .rounded))
                                .foregroundStyle(Color.cream.opacity(0.55))
                        }
                        Text("\(posts.count) sesh\(posts.count == 1 ? "" : "s") posted")
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .tracking(1.6).foregroundStyle(Color.bronze)
                            .padding(.top, 2)
                    }
                    .padding(.top, 40)

                    if loading {
                        ProgressView().tint(Color.whiskey).padding(.top, 60)
                    } else if posts.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "moon.stars")
                                .font(.system(size: 26))
                                .foregroundStyle(Color.bronze)
                            Text("No posted seshs yet.")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.cream.opacity(0.5))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    } else {
                        LazyVGrid(columns: cols, spacing: 3) {
                            ForEach(posts) { p in
                                Button { selectedPost = p } label: { PostThumb(post: p) }
                                    .buttonStyle(PressScaleStyle())
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 14)
                .padding(.bottom, 40)
            }

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.cream.opacity(0.85))
                    .padding(12).background(Circle().fill(Color.cream.opacity(0.08)))
            }
            .padding(.top, 16).padding(.trailing, 20)
            .buttonStyle(PressScaleStyle())
        }
        .preferredColorScheme(.dark)
        .task {
            posts = await feed.userPosts(user.id)
            loading = false
        }
        .fullScreenCover(item: $selectedPost, onDismiss: {
            // A delete or BAC toggle in the detail may have changed things.
            Task { posts = await feed.userPosts(user.id) }
        }) { p in
            PostDetailView(post: p, feed: feed) { selectedPost = nil }
        }
    }
}

/// A friend's posted night, full-screen and read-only (remote photos).
/// BAC is shown only if the poster opted to include it.
struct PostDetailView: View {
    let post: TimelinePost
    var feed: FeedService? = nil
    var history: RecapHistoryStore? = nil
    let onClose: () -> Void

    @State private var gallery: PhotoGallery?
    @State private var liked = false
    @State private var likeCount = 0
    @State private var loadedLike = false
    @State private var comments: [PostComment] = []
    @State private var commentText = ""
    @FocusState private var commentFocused: Bool

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.ink.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        FriendAvatar(name: post.authorName, avatarURL: post.authorAvatar, size: 46)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(post.authorName)
                                .font(.system(size: 18, weight: .black, design: .rounded))
                                .foregroundStyle(Color.cream)
                            Text((post.authorUsername.map { "@\($0)" } ?? "") + " · " + RelativeTime.short(post.createdAt))
                                .font(.system(size: 12, design: .rounded))
                                .foregroundStyle(Color.cream.opacity(0.55))
                        }
                        Spacer()
                        if post.isMine, let feed {
                            Menu {
                                Button {
                                    Task { await feed.setBAC(postId: post.id, include: !post.includeBAC); onClose() }
                                } label: {
                                    Label(post.includeBAC ? "Hide my BAC" : "Show my BAC",
                                          systemImage: post.includeBAC ? "eye.slash" : "eye")
                                }
                                // Archive MOVES the post to Past nights: it's
                                // taken off the timeline and kept privately.
                                // Local recap is keyed by the recap id (which
                                // lives inside the post), not the posts row id.
                                if let history, let local = history.localRecap(for: post.recap.id) {
                                    Button {
                                        Task {
                                            history.archive(local)             // -> Past nights
                                            history.unmarkPosted(post.recap.id)
                                            await feed.deletePost(post.id)     // off the timeline
                                            onClose()
                                        }
                                    } label: {
                                        Label("Move to Past nights", systemImage: "tray.and.arrow.down")
                                    }
                                }
                                Button(role: .destructive) {
                                    Task {
                                        await feed.deletePost(post.id)
                                        history?.unmarkPosted(post.recap.id)
                                        onClose()
                                    }
                                } label: {
                                    Label("Delete post", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(Color.cream.opacity(0.8))
                                    .frame(width: 34, height: 34)
                                    .background(Circle().fill(Color.cream.opacity(0.08)))
                            }
                            .padding(.trailing, 44) // clear the close button
                        }
                    }

                    if let caption = post.caption, !caption.isEmpty {
                        Text(caption)
                            .font(.system(size: 15, design: .rounded))
                            .foregroundStyle(Color.cream)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineSpacing(2)
                    }

                    HStack(spacing: 10) {
                        stat("\(post.recap.stops.filter { $0.kind == .bar }.count)", "stops")
                        stat("\(post.recap.totalDrinks)", "drinks")
                        stat(crawlDistanceString(post.recap.crawlMeters), "crawled")
                        if post.includeBAC {
                            let unit = BACUnitSetting.current()
                            stat("\(unit.formatted(post.recap.peakBAC))\(unit.symbol)", "peak")
                        }
                    }

                    // Where the night went — located stops + the route line.
                    if post.recap.hasMap {
                        let coords = post.recap.locatedStops.compactMap { $0.coordinate }
                        // A single stop has no bounding box, so `.automatic`
                        // zooms to the max and loses all context — frame it to
                        // the surrounding neighbourhood instead. Multiple stops
                        // fit the whole route. `initialPosition` (not `position`)
                        // sets the start but leaves the camera free, so users
                        // can pan + zoom from there.
                        let initialCamera: MapCameraPosition = coords.count == 1
                            ? .region(MKCoordinateRegion(
                                center: coords[0],
                                latitudinalMeters: 1500,
                                longitudinalMeters: 1500))
                            : .automatic
                        Map(initialPosition: initialCamera) {
                            ForEach(post.recap.locatedStops) { stop in
                                if let c = stop.coordinate {
                                    Marker(stop.name, systemImage: "mappin", coordinate: c)
                                        .tint(Color.whiskey)
                                }
                            }
                            if coords.count > 1 {
                                MapPolyline(coordinates: coords)
                                    .stroke(Color.whiskey, lineWidth: 3)
                            }
                        }
                        .frame(height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        // Interactive — drag to pan, pinch to zoom. (Drop the
                        // old allowsHitTesting(false) that froze it.)
                    }

                    ForEach(post.recap.stops) { stop in
                        stopCard(stop)
                    }

                    socialSection

                    Spacer(minLength: 30)
                }
                .padding(20).padding(.top, 56)
            }

            Button { onClose() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.cream.opacity(0.85))
                    .padding(12).background(Circle().fill(Color.cream.opacity(0.08)))
            }
            .padding(.top, 16).padding(.trailing, 20)
            .buttonStyle(PressScaleStyle())
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(item: $gallery) { g in
            GalleryLightbox(urls: g.urls, start: g.start) { gallery = nil }
        }
        .task {
            if !loadedLike { liked = post.likedByMe; likeCount = post.likeCount; loadedLike = true }
            comments = await feed?.comments(post.id) ?? []
        }
    }

    // MARK: Likes + comments

    @ViewBuilder
    private var socialSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 20) {
                Button {
                    liked.toggle()
                    likeCount = max(0, likeCount + (liked ? 1 : -1))
                    Task { await feed?.toggleLike(post.id) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: liked ? "heart.fill" : "heart")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(liked ? Status.drunk.color : Color.cream.opacity(0.85))
                        if likeCount > 0 { Text("\(likeCount)").foregroundStyle(Color.cream.opacity(0.85)) }
                    }
                    .padding(.vertical, 6)
                    .padding(.trailing, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle())
                HStack(spacing: 6) {
                    Image(systemName: "bubble.right")
                    if !comments.isEmpty { Text("\(comments.count)") }
                }
                .foregroundStyle(Color.cream.opacity(0.85))
                Spacer()
            }
            .font(.system(size: 17, weight: .semibold, design: .rounded))

            // Input at the top of the comments.
            HStack(spacing: 8) {
                TextField("Add a comment…", text: $commentText, axis: .vertical)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .lineLimit(1...3)
                    .focused($commentFocused)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.cream.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.cream.opacity(0.12), lineWidth: 1))
                Button { sendComment() } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(commentText.trimmingCharacters(in: .whitespaces).isEmpty ? Color.cream.opacity(0.3) : Color.whiskey)
                }
                .disabled(commentText.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if !comments.isEmpty {
                ForEach(comments) { c in commentRow(c) }
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func commentRow(_ c: PostComment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            FriendAvatar(name: c.authorName, avatarURL: c.authorAvatar, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(c.authorName)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.cream)
                    Text(RelativeTime.short(c.createdAt))
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.45))
                    Spacer(minLength: 0)
                }
                Text(c.body)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            if c.isMine || post.isMine {
                Button(role: .destructive) {
                    Task {
                        await feed?.deleteComment(c.id, postId: post.id)
                        comments = await feed?.comments(post.id) ?? []
                    }
                } label: { Label("Delete comment", systemImage: "trash") }
            }
        }
    }

    private func sendComment() {
        let body = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        commentText = ""
        commentFocused = false
        Task {
            await feed?.addComment(post.id, body: body)
            comments = await feed?.comments(post.id) ?? []
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 20, weight: .black, design: .rounded)).foregroundStyle(Color.cream)
            Text(label.uppercased()).font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1.4).foregroundStyle(Color.bronze)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.cream.opacity(0.05)))
    }

    @ViewBuilder
    private func stopCard(_ stop: RecapStop) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(recapStopEmoji(stop.kind)).font(.system(size: 16))
                VStack(alignment: .leading, spacing: 1) {
                    Text(stop.name).font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.cream)
                    Text(Self.timeFmt.string(from: stop.arrivedAt))
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.5))
                }
                Spacer()
                if post.includeBAC {
                    let unit = BACUnitSetting.current()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(unit.formatted(stop.bacOnArrival)) → \(unit.formatted(stop.bacOnDeparture))\(unit.symbol)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.cream.opacity(0.85))
                        if stop.isPeak {
                            Text("PEAK").font(.system(size: 8, weight: .black, design: .monospaced))
                                .tracking(1.2).foregroundStyle(Color.whiskey)
                        }
                    }
                }
            }

            if !stop.photoFilenames.isEmpty {
                let urls = stop.photoFilenames.compactMap { URL(string: $0) }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(urls.enumerated()), id: \.offset) { idx, url in
                            Button { gallery = PhotoGallery(urls: urls, start: idx) } label: {
                                DownsampledAsyncImage(url: url, targetPoints: 170)
                                    .frame(width: 150, height: 150)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(PressScaleStyle())
                        }
                    }
                }
            }

            if !stop.drinkSummary.isEmpty {
                Text(stop.drinkSummary)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.7))
            }

            if let note = stop.note, !note.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "text.bubble.fill")
                        .font(.system(size: 11)).foregroundStyle(Color.bronze).padding(.top, 1)
                    Text(note)
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.9))
                        .italic()
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.cream.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.cream.opacity(0.08), lineWidth: 1))
    }
}

/// A set of photos to view full-screen, starting at a given index.
private struct PhotoGallery: Identifiable {
    let id = UUID()
    let urls: [URL]
    let start: Int
}
