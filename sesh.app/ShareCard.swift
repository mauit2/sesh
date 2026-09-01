//
//  ShareCard.swift
//  sesh.app
//
//  Strava-style story sticker for a night recap: a TRANSPARENT PNG with
//  the route (stops + connecting lines), and the night's numbers — stops,
//  units, steps, calories burned, peak BAC, duration. Shared through the
//  system share sheet, so it lands in Instagram/Snapchat/Facebook stories
//  (or Photos) and floats over whatever background the user picks there.
//
//  Every text/dot carries a dark shadow so the sticker stays legible on
//  light AND dark story backgrounds.
//

import SwiftUI
import UIKit

// MARK: - The renderable sticker

struct NightShareCard: View {
    let recap: NightRecap
    /// Health numbers for the night window — nil (or zeros) renders "—".
    let vitals: HealthService.Vitals?

    private var unit: BACUnit { BACUnitSetting.current() }

    /// Standard drinks (12 g of ethanol each) across the whole night.
    private var units: Double {
        recap.stops.flatMap(\.drinks).reduce(0) { $0 + $1.grams } / 12.0
    }

    private var durationLabel: String {
        let mins = max(0, Int(recap.endedAt.timeIntervalSince(recap.startedAt) / 60))
        return mins >= 60 ? "\(mins / 60)h \(mins % 60)m" : "\(mins)m"
    }

    private var dateLabel: String {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f.string(from: recap.startedAt).uppercased()
    }

    private var stepsLabel: String {
        guard let s = vitals?.steps, s > 0 else { return "—" }
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: Int(s))) ?? "\(Int(s))"
    }

    private var kcalLabel: String {
        guard let k = vitals?.activeKcal, k > 0 else { return "—" }
        return "\(Int(k.rounded()))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Brand + date
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(Color.whiskey)
                        .frame(width: 8, height: 8)
                        .shadow(color: Color.whiskey.opacity(0.9), radius: 5)
                    Text("sejdel")
                        .font(.system(size: 24, weight: .black, design: .rounded))
                        .italic()
                        .tracking(-0.8)
                        .foregroundStyle(Color.cream)
                }
                Spacer()
                Text(dateLabel)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(1.8)
                    .foregroundStyle(Color.cream.opacity(0.85))
            }
            .legibleOnAnyStory()

            // The route — dots for stops, whiskey lines between them.
            if recap.hasMap {
                RouteSketch(stops: recap.locatedStops)
                    .frame(height: 240)
            }

            // The numbers.
            VStack(spacing: 14) {
                HStack(spacing: 0) {
                    shareStat("\(recap.locatedStops.count)",
                              recap.locatedStops.count == 1 ? "STOP" : "STOPS")
                    shareStat(String(format: "%.1f", units), "UNITS")
                    shareStat("\(unit.formatted(recap.peakBAC))\(unit.symbol)", "PEAK BAC",
                              tint: .whiskey)
                }
                HStack(spacing: 0) {
                    shareStat(stepsLabel, "STEPS")
                    shareStat(kcalLabel, "KCAL BURNED")
                    shareStat(durationLabel, "ON THE TOWN")
                }
            }
            .legibleOnAnyStory()
        }
        .padding(26)
        .frame(width: 360, height: recap.hasMap ? 470 : 230, alignment: .top)
    }

    private func shareStat(_ value: String, _ label: String, tint: Color = .cream) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .tracking(-0.5)
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .tracking(1.6)
                .foregroundStyle(Color.cream.opacity(0.75))
        }
        .frame(maxWidth: .infinity)
    }
}

/// Dark halo behind content so the transparent sticker reads on any story.
private struct LegibleOnAnyStory: ViewModifier {
    func body(content: Content) -> some View {
        content
            .shadow(color: .black.opacity(0.65), radius: 2, y: 1)
            .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
    }
}
private extension View {
    func legibleOnAnyStory() -> some View { modifier(LegibleOnAnyStory()) }
}

// MARK: - Route sketch

/// The night's stops projected into the frame (north up, aspect-correct),
/// joined by a glowing whiskey line — no map tiles, pure transparency.
private struct RouteSketch: View {
    let stops: [RecapStop]

    var body: some View {
        GeometryReader { geo in
            // Inset so dots and name labels never clip at the edges.
            let inset: CGFloat = 34
            let rect = CGRect(x: inset, y: inset,
                              width: max(geo.size.width - inset * 2, 1),
                              height: max(geo.size.height - inset * 2, 1))
            let pts = Self.project(stops, into: rect)

            ZStack {
                if pts.count > 1 {
                    // The crawl line — glow pass then crisp pass.
                    routePath(pts)
                        .stroke(Color.whiskey.opacity(0.55),
                                style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                        .blur(radius: 4)
                    routePath(pts)
                        .stroke(Color.whiskey,
                                style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                }

                ForEach(Array(zip(stops.indices, pts)), id: \.0) { i, p in
                    let stop = stops[i]
                    Circle()
                        .fill(stop.isPeak ? Color.whiskey : Color.cream)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().strokeBorder(Color.ink.opacity(0.85), lineWidth: 2))
                        .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
                        .position(p)
                    Text(stop.name)
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .lineLimit(1)
                        .foregroundStyle(Color.cream)
                        .shadow(color: .black.opacity(0.75), radius: 2, y: 1)
                        .frame(maxWidth: 110)
                        .position(x: p.x, y: max(10, p.y - 16))
                }
            }
        }
    }

    private func routePath(_ pts: [CGPoint]) -> Path {
        Path { p in
            guard let first = pts.first else { return }
            p.move(to: first)
            for pt in pts.dropFirst() { p.addLine(to: pt) }
        }
    }

    /// Equirectangular projection (lat/lon → points), aspect-preserving and
    /// centered. A single stop lands in the middle.
    static func project(_ stops: [RecapStop], into rect: CGRect) -> [CGPoint] {
        let coords: [(x: Double, y: Double)] = stops.compactMap { s in
            guard let la = s.lat, let lo = s.lon else { return nil }
            return (lo, la)
        }
        guard !coords.isEmpty else { return [] }
        let midLat = (coords.map(\.y).min()! + coords.map(\.y).max()!) / 2
        let lonScale = max(cos(midLat * .pi / 180), 0.01)
        let xs = coords.map { $0.x * lonScale }
        let ys = coords.map(\.y)
        let minX = xs.min()!, maxX = xs.max()!
        let minY = ys.min()!, maxY = ys.max()!
        let dx = max(maxX - minX, 1e-9), dy = max(maxY - minY, 1e-9)
        let scale = min(rect.width / dx, rect.height / dy)
        let w = dx * scale, h = dy * scale
        let ox = rect.minX + (rect.width - w) / 2
        let oy = rect.minY + (rect.height - h) / 2
        return zip(xs, ys).map { x, y in
            CGPoint(x: ox + CGFloat(x - minX) * scale,
                    y: oy + CGFloat(maxY - y) * scale)   // flip: north up
        }
    }
}

// MARK: - Share sheet

/// Preview + share. Renders the sticker to a transparent PNG on disk and
/// hands the file to the system share sheet — Instagram, Snapchat and
/// Facebook all pick it up as a story-able image.
struct NightShareSheet: View {
    let recap: NightRecap
    @Environment(\.dismiss) private var dismiss

    @State private var vitals: HealthService.Vitals? = nil
    @State private var fileURL: URL? = nil

    var body: some View {
        ZStack {
            AtmosphereBackground(accent: .whiskey)
            VStack(spacing: 18) {
                Text("SHARE YOUR NIGHT")
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(Color.bronze)
                    .padding(.top, 22)

                // Live preview over a story-ish gradient so the transparency
                // is obvious ("this floats over your photo").
                NightShareCard(recap: recap, vitals: vitals)
                    .background(
                        LinearGradient(
                            colors: [Color(red: 0.16, green: 0.13, blue: 0.22),
                                     Color(red: 0.35, green: 0.18, blue: 0.14)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22)
                            .strokeBorder(Color.cream.opacity(0.12), lineWidth: 1)
                    )
                    .scaleEffect(0.92)

                Text("A transparent sticker — drop it over any photo in your story.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                if let fileURL {
                    ShareLink(item: fileURL) {
                        HStack(spacing: 7) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 13, weight: .bold))
                            Text("SHARE STICKER")
                                .font(.system(size: 13, weight: .black, design: .monospaced))
                                .tracking(1.8)
                        }
                        .foregroundStyle(Color.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(Color.whiskey))
                        .shadow(color: Color.whiskey.opacity(0.45), radius: 14, y: 5)
                    }
                    .buttonStyle(PressScaleStyle())
                    .padding(.horizontal, 26)
                } else {
                    ProgressView().tint(Color.whiskey).padding(.vertical, 14)
                }

                Button { dismiss() } label: {
                    Text("DONE")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(1.8)
                        .foregroundStyle(Color.cream.opacity(0.65))
                        .padding(.vertical, 8)
                }
                .buttonStyle(PressScaleStyle())
                Spacer(minLength: 8)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            // Steps + kcal for the night's window (zeros → "—" when Health
            // isn't connected), then bake the PNG.
            let v = await HealthService.shared.vitals(from: recap.startedAt, to: recap.endedAt)
            vitals = v
            fileURL = Self.renderPNG(recap: recap, vitals: v)
        }
    }

    /// Bake the sticker into a transparent PNG in tmp; returns its URL.
    @MainActor
    static func renderPNG(recap: NightRecap, vitals: HealthService.Vitals?) -> URL? {
        let renderer = ImageRenderer(content: NightShareCard(recap: recap, vitals: vitals))
        renderer.scale = 3
        renderer.isOpaque = false
        guard let ui = renderer.uiImage, let data = ui.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sejdel-night-\(recap.id.uuidString.prefix(8)).png")
        do { try data.write(to: url) } catch { return nil }
        return url
    }
}
