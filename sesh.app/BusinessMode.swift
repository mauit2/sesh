// BusinessMode.swift — the app as a bar.
//
// Creating a business account turns the whole account into the bar: the
// profile carries the bar's name and @handle with a verified mark, the LIVE
// tab becomes EVENTS, the EVENTS tab becomes POST (an Instagram-style
// composer: upload or take a picture, one on Business, a slideshow on
// Business+), and PROFILE is the bar's page with everything it manages
// underneath. Cancelling the subscription turns it all back.

import Combine
import CoreImage.CIFilterBuiltins
import PhotosUI
import SwiftUI
import Supabase

extension Notification.Name {
    /// The signed-in profile changed under us (business takeover / revert)
    /// — SessionView reloads it.
    static let sejdelReloadProfile = Notification.Name("sejdel.reloadProfile")
}

/// A switch drawn by hand: the whole row is a button, so it works wherever
/// a UISwitch fights the map or the paging tab view for its tap.
struct BizSwitchRow: View {
    let title: String
    @Binding var isOn: Bool
    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { isOn.toggle() }
        } label: {
            HStack {
                Text(title).font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(Color.cream)
                Spacer()
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? Color.whiskey : Color.cream.opacity(0.15)).frame(width: 52, height: 31)
                    Circle().fill(Color.cream).frame(width: 27, height: 27).padding(2)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
    }
}

/// The blue-tick equivalent: every business account is a verified bar.
struct VerifiedBadge: View {
    var size: CGFloat = 14
    var body: some View {
        Image(systemName: "checkmark.seal.fill")
            .font(.system(size: size, weight: .bold, design: .rounded))
            .foregroundStyle(Color.whiskey)
            .accessibilityLabel("Verified business")
    }
}

// MARK: - Owner: profile tab

/// PROFILE in business mode: the bar's page, then everything it manages.
struct BusinessOwnerProfilePage: View {
    @ObservedObject var svc: BusinessService
    let profile: Profile

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                if let b = svc.mine.first {
                    header(b)
                    BusinessDashboard(summary: b, svc: svc)
                } else if svc.loaded {
                    Text("Your business account has ended. Claim a bar again from the menu to start over.")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.6))
                        .padding(.top, 40)
                } else {
                    ProgressView().tint(Color.whiskey).frame(maxWidth: .infinity).padding(.vertical, 40)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 120)
        }
        .task { await svc.loadMine() }
        .refreshable { await svc.loadMine(); if let b = svc.mine.first { await svc.loadOverview(b.id) } }
    }

    private func header(_ b: BusinessSummary) -> some View {
        VStack(spacing: 8) {
            BusinessLogo(url: profile.avatarURL.flatMap(URL.init(string:)), name: b.name, size: 84)
            HStack(spacing: 6) {
                Text(b.name)
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .foregroundStyle(Color.cream)
                VerifiedBadge(size: 18)
            }
            if let u = b.username {
                Text("@\(u)")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.55))
            }
            Text("\(b.venueName)\(b.venueCity.map { " · \($0)" } ?? "")")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.55))
            HStack(spacing: 14) {
                Text(followersLabel(b.followers))
                Text("·").foregroundStyle(Color.cream.opacity(0.3))
                Text(BizTier.label(b.tier))
            }
            .font(.system(size: 11, weight: .black, design: .monospaced))
            .tracking(1.4)
            .foregroundStyle(Color.bronze)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 6)
    }
}

// MARK: - Owner: events tab (Business+)

/// EVENTS in business mode: the bar's upcoming nights. Creating one is the
/// invite — it lands in every follower's "from bars you follow" list.
struct BusinessEventsPage: View {
    @ObservedObject var svc: BusinessService
    @State private var composerOpen = false
    @State private var cancelling: UUID?

    private var ov: BusinessOverview? { svc.overview }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Events")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.cream)
                Text("DJ nights, quiz nights, the special one. Set the date, time and a picture — every follower gets it.")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                if let ov {
                    if ov.isPlus {
                        BizPrimaryButton(title: "NEW EVENT") { composerOpen = true }
                        ForEach(ov.events) { e in row(e, business: ov.business.id) }
                        if ov.events.isEmpty {
                            Text("Nothing on the calendar yet.")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.cream.opacity(0.5))
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Events are Business+.")
                                .font(.system(size: 20, weight: .heavy, design: .rounded))
                                .foregroundStyle(Color.whiskey)
                            Text("Upgrade on your profile page to put your nights in front of every follower.")
                                .font(.system(size: 15, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.cream.opacity(0.7))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(18)
                        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.whiskey.opacity(0.09)))
                        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.whiskey.opacity(0.4), lineWidth: 1))
                    }
                } else {
                    ProgressView().tint(Color.whiskey).frame(maxWidth: .infinity).padding(.vertical, 40)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 120)
        }
        .task {
            await svc.loadMine()
            if let b = svc.mine.first { await svc.loadOverview(b.id) }
        }
        .sheet(isPresented: $composerOpen) {
            if let ov {
                BusinessEventComposer(svc: svc, overview: ov) { composerOpen = false }
                    .presentationBackground(Color.ink)
            }
        }
    }

    private func row(_ e: BusinessOverview.Event, business: UUID) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            EventPicture(url: e.imageUrl.flatMap(URL.init(string:)), ratio: e.ratio)
            VStack(alignment: .leading, spacing: 6) {
                Text(e.title)
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.cream)
                Text(e.startsAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(e.startsAt > Date() ? Color.whiskey : Color.cream.opacity(0.4))
                Button {
                    cancelling = e.id
                    Task { try? await svc.cancelEvent(e.id, business: business); cancelling = nil }
                } label: {
                    Text(cancelling == e.id ? "Cancelling…" : "Cancel event")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.5)).underline()
                }
                .buttonStyle(.plain)
            }
            .padding(14)
        }
        .background(Color.cream.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.cream.opacity(0.08), lineWidth: 1))
    }
}

/// Date, time, a picture. That's the invite.
struct BusinessEventComposer: View {
    @ObservedObject var svc: BusinessService
    let overview: BusinessOverview
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var startsAt = Calendar.current.date(bySettingHour: 21, minute: 0, second: 0, of: Date().addingTimeInterval(86400)) ?? Date()
    @State private var item: PhotosPickerItem?
    @State private var data: Data?
    @State private var cameraOpen = false
    @State private var saving = false
    @State private var error: String?
    /// The picture's own ratio, clamped like a post's.
    private var ratio: CGFloat {
        guard let d = data, let img = UIImage(data: d) else { return 1 }
        return CampaignArt.clampFeed(img.size.width / max(img.size.height, 1))
    }

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top) {
                        Text("New event")
                            .font(.system(size: 30, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color.cream)
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.cream.opacity(0.6))
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(Color.cream.opacity(0.06)))
                        }
                        .buttonStyle(PressScaleStyle())
                    }
                    PicturePicker(data: $data, item: $item, cameraOpen: $cameraOpen, ratio: ratio, label: "THE PICTURE")
                    VStack(alignment: .leading, spacing: 7) {
                        Text("WHAT").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(Color.bronze)
                        TextField("", text: $title, prompt: Text("DJ night · free entry").foregroundStyle(Color.cream.opacity(0.35)))
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.cream)
                            .tint(Color.whiskey)
                            .padding(.horizontal, 14).padding(.vertical, 13)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.cream.opacity(0.05)))
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text("WHEN").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(Color.bronze)
                        DatePicker("Starts", selection: $startsAt, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.cream.opacity(0.8))
                            .tint(Color.whiskey)
                    }
                    Text("Goes to every follower's upcoming events, and as a push to them — one push a day.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                    if let error {
                        Text(error).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(BizState.rejectRed)
                    }
                    BizPrimaryButton(title: "SEND THE INVITE", enabled: !title.trimmingCharacters(in: .whitespaces).isEmpty && !saving, busy: saving, action: save)
                    Spacer(minLength: 24)
                }
                .padding(20)
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $cameraOpen) {
            CameraCaptureView { data = $0 }.ignoresSafeArea()
        }
    }

    private func save() {
        saving = true; error = nil
        Task {
            do {
                try await svc.createEvent(business: overview.business.id, title: title, startsAt: startsAt, imageData: data, ratio: ratio)
                onDone(); dismiss()
            } catch { self.error = BusinessService.friendly(error) }
            saving = false
        }
    }
}

/// Library or camera, one picture, at a fixed box ratio.
struct PicturePicker: View {
    @Binding var data: Data?
    @Binding var item: PhotosPickerItem?
    @Binding var cameraOpen: Bool
    let ratio: CGFloat
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(Color.bronze)
            Color.clear
                .aspectRatio(ratio, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    ZStack {
                        Color.smoke
                        if let d = data, let img = UIImage(data: d) {
                            Image(uiImage: img).resizable().scaledToFill()
                        } else {
                            HStack(spacing: 12) {
                                PhotosPicker(selection: $item, matching: .images) {
                                    pickButton("photo.on.rectangle", "UPLOAD")
                                }
                                if CameraCaptureView.isAvailable {
                                    Button { cameraOpen = true } label: { pickButton("camera.fill", "TAKE ONE") }
                                        .buttonStyle(PressScaleStyle())
                                }
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.cream.opacity(0.12), lineWidth: 1))
            if data != nil {
                Button { data = nil; item = nil } label: {
                    Text("Change picture").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Color.cream.opacity(0.5)).underline()
                }
                .buttonStyle(.plain)
            }
        }
        .onChange(of: item) { _, newItem in
            guard let newItem else { return }
            Task { data = try? await newItem.loadTransferable(type: Data.self) }
        }
    }

    private func pickButton(_ icon: String, _ text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 22, weight: .bold, design: .rounded))
            Text(text).font(.system(size: 11, weight: .black, design: .monospaced)).tracking(1.4)
        }
        .foregroundStyle(Color.cream)
        .frame(width: 120, height: 84)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cream.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.cream.opacity(0.15), lineWidth: 1))
    }
}

// MARK: - Owner: post tab (Instagram-style)

/// POST in business mode. Upload or take a picture — one on Business, up to
/// ten as a slideshow on Business+ — write the caption, post.
struct BusinessPostPage: View {
    @ObservedObject var svc: BusinessService
    var onPosted: () -> Void

    @State private var items: [PhotosPickerItem] = []
    @State private var images: [Data] = []
    @State private var ratio: CGFloat = 1
    @State private var cameraOpen = false
    @State private var caption = ""
    @State private var hasEvent = false
    @State private var eventAt = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: Date().addingTimeInterval(86400)) ?? Date()
    @State private var offerId: UUID?
    @State private var saving = false
    @State private var error: String?
    @State private var page = 0

    private var ov: BusinessOverview? { svc.overview }
    private var isPlus: Bool { ov?.isPlus ?? false }
    private var maxImages: Int { isPlus ? 10 : 1 }
    private var canPost: Bool { !images.isEmpty && caption.count <= 300 && !saving && (ov?.isSubscribed ?? false) }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                Text("New post")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.cream)
                if let ov, !ov.isSubscribed {
                    Text("Subscribe on your profile page to start posting.")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.7))
                }
                pictureArea
                captionField
                BizSwitchRow(title: "It's an event", isOn: $hasEvent)
                if hasEvent {
                    DatePicker("When", selection: $eventAt, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.cream.opacity(0.8))
                        .tint(Color.whiskey)
                }
                if let ov {
                    let live = ov.campaigns.filter(\.live)
                    if !live.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("LINK A DEAL").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(Color.bronze)
                            Menu {
                                Button("None") { offerId = nil }
                                ForEach(live) { c in Button(c.title) { offerId = c.id } }
                            } label: {
                                HStack {
                                    Text(live.first { $0.id == offerId }?.title ?? "None").foregroundStyle(Color.cream)
                                    Spacer()
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(Color.bronze)
                                }
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 14).padding(.vertical, 13)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.cream.opacity(0.05)))
                            }
                        }
                    }
                }
                if let error {
                    Text(error).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(BizState.rejectRed)
                }
                BizPrimaryButton(title: "POST", enabled: canPost, busy: saving, action: post)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 120)
        }
        .task {
            await svc.loadMine()
            if let b = svc.mine.first { await svc.loadOverview(b.id) }
        }
        .onChange(of: items) { _, newItems in
            guard !newItems.isEmpty else { return }
            Task {
                var added: [Data] = []
                for it in newItems { if let d = try? await it.loadTransferable(type: Data.self) { added.append(d) } }
                images = Array((images + added).prefix(maxImages))
                items = []
                recomputeRatio()
            }
        }
        .fullScreenCover(isPresented: $cameraOpen) {
            CameraCaptureView { d in
                images = Array((images + [d]).prefix(maxImages))
                recomputeRatio()
            }
            .ignoresSafeArea()
        }
    }

    private var pictureArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(images.isEmpty ? 1 : ratio, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    ZStack {
                        Color.smoke
                        if images.isEmpty {
                            VStack(spacing: 14) {
                                Text(isPlus ? "One picture or a slideshow." : "One picture.")
                                    .font(.system(size: 17, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.cream.opacity(0.8))
                                HStack(spacing: 12) {
                                    PhotosPicker(selection: $items, maxSelectionCount: maxImages, matching: .images) {
                                        bigPick("photo.on.rectangle", "UPLOAD")
                                    }
                                    if CameraCaptureView.isAvailable {
                                        Button { cameraOpen = true } label: { bigPick("camera.fill", "TAKE A PICTURE") }
                                            .buttonStyle(PressScaleStyle())
                                    }
                                }
                            }
                        } else {
                            TabView(selection: $page) {
                                ForEach(Array(images.enumerated()), id: \.offset) { i, d in
                                    if let img = UIImage(data: d) {
                                        Image(uiImage: img).resizable().scaledToFill().tag(i)
                                    }
                                }
                            }
                            .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .automatic : .never))
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.cream.opacity(0.12), lineWidth: 1))
            if !images.isEmpty {
                HStack(spacing: 16) {
                    if images.count < maxImages {
                        PhotosPicker(selection: $items, maxSelectionCount: maxImages - images.count, matching: .images) {
                            Label("Add more", systemImage: "plus")
                        }
                    }
                    Button { images.removeAll(); page = 0 } label: { Label("Start over", systemImage: "xmark") }
                        .buttonStyle(.plain)
                    Spacer()
                    Text("\(images.count)/\(maxImages)")
                }
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.6))
            }
        }
    }

    private var captionField: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("CAPTION").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(Color.bronze)
                Spacer()
                Text("\(caption.count)/300")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(caption.count > 300 ? BizState.rejectRed : Color.cream.opacity(0.35))
            }
            TextField("", text: $caption, prompt: Text("Quiz night Thursday. 20:00, free entry.").foregroundStyle(Color.cream.opacity(0.35)), axis: .vertical)
                .lineLimit(1...5)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream)
                .tint(Color.whiskey)
                .padding(.horizontal, 14).padding(.vertical, 13)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.cream.opacity(0.05)))
        }
    }

    private func bigPick(_ icon: String, _ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 26, weight: .bold, design: .rounded))
            Text(text).font(.system(size: 11, weight: .black, design: .monospaced)).tracking(1.4)
        }
        .foregroundStyle(Color.cream)
        .frame(width: 140, height: 96)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.cream.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.cream.opacity(0.15), lineWidth: 1))
    }

    private func recomputeRatio() {
        guard let first = images.first, let img = UIImage(data: first) else { ratio = 1; return }
        ratio = CampaignArt.clampFeed(img.size.width / max(img.size.height, 1))
    }

    private func post() {
        guard let ov, !images.isEmpty else { return }
        saving = true; error = nil
        Task {
            do {
                try await svc.createPost(business: ov.business.id, images: images, ratio: ratio,
                                         caption: caption.trimmingCharacters(in: .whitespacesAndNewlines),
                                         eventAt: hasEvent ? eventAt : nil, offerId: offerId)
                images = []; caption = ""; hasEvent = false; offerId = nil; page = 0
                onPosted()
            } catch { self.error = BusinessService.friendly(error) }
            saving = false
        }
    }
}

// MARK: - Owner: check-in QR

/// The table QR (same code the admin desk prints): guests scan it to check
/// in at the bar. Minted once, reused forever.
struct BusinessQRCard: View {
    let token: String
    let venueName: String

    var body: some View {
        VStack(spacing: 12) {
            if let img = Self.image(for: token) {
                Image(uiImage: img)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 180, height: 180)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.cream))
            }
            Text(token)
                .font(.system(size: 14, weight: .black, design: .monospaced))
                .tracking(3)
                .foregroundStyle(Color.cream)
            Text("Print it for the tables. Scanning checks guests in at \(venueName); the code under it works if the camera won't.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.55))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let img = Self.image(for: token) {
                ShareLink(item: Image(uiImage: img), preview: SharePreview("\(venueName) check-in QR", image: Image(uiImage: img))) {
                    Label("SHARE / PRINT", systemImage: "square.and.arrow.up")
                        .font(.system(size: 11, weight: .black, design: .monospaced)).tracking(1.4)
                        .foregroundStyle(Color.whiskey)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Capsule().fill(Color.whiskey.opacity(0.1)))
                        .overlay(Capsule().strokeBorder(Color.whiskey.opacity(0.4), lineWidth: 1))
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Same payload the admin desk prints, so one scanner path serves both.
    static func image(for token: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data("https://sejdel.com/qr/\(token)".utf8)
        filter.correctionLevel = "Q"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Settings: who started it

/// Only the account holder sees this, in their settings: the business
/// account was started by their old self.
struct BusinessAccountNote: View {
    let profile: Profile
    @State private var startedBy: String?

    var body: some View {
        if profile.businessId != nil {
            HStack(spacing: 8) {
                VerifiedBadge(size: 13)
                Text(startedBy.map { "Business account · started by \($0)" } ?? "Business account")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .task {
                let svc = BusinessService()
                await svc.loadMine()
                if let b = svc.mine.first {
                    startedBy = b.priorUsername.map { "@\($0)" } ?? b.priorName
                }
            }
        }
    }
}

// MARK: - Guests: events from bars you follow

struct BarEvent: Decodable, Identifiable {
    let id: UUID
    let businessId: UUID
    let businessName: String
    let username: String?
    let logoUrl: String?
    let venueId: UUID
    let venueName: String
    let venueCity: String?
    let title: String
    let startsAt: String
    let imageUrl: String?
    let imageRatio: Double?

    enum CodingKeys: String, CodingKey {
        case id, username, title
        case businessId = "business_id"
        case businessName = "business_name"
        case logoUrl = "logo_url"
        case venueId = "venue_id"
        case venueName = "venue_name"
        case venueCity = "venue_city"
        case startsAt = "starts_at"
        case imageUrl = "image_url"
        case imageRatio = "image_ratio"
    }
    var date: Date { BusinessJSON.parseDate(startsAt) ?? .distantPast }
    var ratio: CGFloat { CampaignArt.clampFeed(CGFloat(imageRatio ?? 1)) }
}

/// An event's picture at its own ratio (Instagram clamp), or a party
/// popper on smoke when there is none.
struct EventPicture: View {
    let url: URL?
    let ratio: CGFloat
    var body: some View {
        Color.clear
            .aspectRatio(url == nil ? 2.2 : ratio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                ZStack {
                    Color.smoke
                    if let url {
                        DownsampledAsyncImage(url: url, targetPoints: 420)
                    } else {
                        Image(systemName: "party.popper.fill")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.whiskey)
                    }
                }
            }
            .clipped()
    }
}

@MainActor
final class BarEventsStore: ObservableObject {
    @Published private(set) var events: [BarEvent] = []
    func load() async {
        guard supabase.auth.currentUser != nil else { events = []; return }
        events = (try? await supabase.rpc("business_events_upcoming").execute().value) ?? []
    }
}

/// "From bars you follow" on the EVENTS tab.
struct BarEventsSection: View {
    @StateObject private var store = BarEventsStore()
    @State private var openBusiness: BizRef?

    var body: some View {
        Group {
            if !store.events.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("From bars you follow")
                        .font(.system(size: 20, weight: .heavy, design: .rounded))
                        .tracking(-0.5)
                        .foregroundStyle(Color.cream)
                        .padding(.top, 8)
                    ForEach(store.events) { e in
                        Button { openBusiness = BizRef(id: e.businessId) } label: { row(e) }
                            .buttonStyle(PressScaleStyle())
                    }
                }
            }
        }
        .task { await store.load() }
        .sheet(item: $openBusiness) { ref in
            BusinessProfileView(businessId: ref.id)
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.ink)
        }
    }

    /// A post-shaped card: the bar on top, the picture at its own ratio,
    /// the night and when.
    private func row(_ e: BarEvent) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                BusinessLogo(url: e.logoUrl.flatMap(URL.init(string:)), name: e.businessName, size: 34)
                HStack(spacing: 5) {
                    Text(e.businessName)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.cream)
                        .lineLimit(1)
                    VerifiedBadge(size: 12)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.bronze)
            }
            .padding(12)
            EventPicture(url: e.imageUrl.flatMap(URL.init(string:)), ratio: e.ratio)
            VStack(alignment: .leading, spacing: 4) {
                Text(e.title)
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.cream)
                    .lineLimit(2)
                Text(e.date.formatted(date: .abbreviated, time: .shortened) + (e.venueCity.map { " · \($0)" } ?? ""))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.whiskey)
            }
            .padding(14)
        }
        .background(Color.cream.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.cream.opacity(0.08), lineWidth: 1))
        .contentShape(Rectangle())
    }
}
