// Home Screen widget — shows live BAC + group roster, auto-decays.
//
// What's different from the Live Activity:
//
//   • The Live Activity is event-driven: the app pushes updates, the
//     widget renders them, sits frozen until the next push.
//   • The Home Screen widget is timeline-driven: we hand the system a
//     SEQUENCE of "future entries" and it renders the right one for
//     the current time. So even when the app is closed, the BAC
//     number drops every 5 minutes on its own.
//
// How we power auto-decay without a server:
//
//   The shared store carries a snapshot {snapshotAt, meBac, roster…}.
//   We know BAC decays linearly at 0.015%/hr (Widmark). For each entry
//   on the timeline (every 5 min for the next 60 min), we project the
//   BAC at that future moment by linear decay. After the hour we ask
//   for a refresh — the app will have written a fresh snapshot by then
//   (and even if it hasn't, decaying further is still mathematically
//   correct as long as no new drinks were added in the meantime).
//
//   Group members' BACs also decay client-side — they're in the same
//   snapshot. New drinks from other members only show up after the
//   group leader's phone publishes them and the user opens the app
//   (no APNs in this phase).

import SwiftUI
import WidgetKit

// MARK: - Local palette + status mirror (same as Live Activity)

private extension Color {
    static let seshInk     = Color(red: 0.043, green: 0.039, blue: 0.031)
    static let seshWhiskey = Color(red: 0.910, green: 0.659, blue: 0.290)
    static let seshCream   = Color(red: 0.961, green: 0.929, blue: 0.878)
    static let seshBronze  = Color(red: 0.541, green: 0.498, blue: 0.431)
}

private enum HomeWidgetStatus: String {
    case sober, buzzed, impaired, drunk, danger

    init(raw: String) {
        self = HomeWidgetStatus(rawValue: raw) ?? .sober
    }

    /// Re-derive status from a numeric BAC. Used by the widget when
    /// projecting future BACs — the snapshot's `statusRaw` is only
    /// valid at `snapshotAt`; after decay we recompute.
    init(bac: Double) {
        switch bac {
        case ..<0.02: self = .sober
        case 0.02..<0.05: self = .buzzed
        case 0.05..<0.08: self = .impaired
        case 0.08..<0.15: self = .drunk
        default: self = .danger
        }
    }

    var label: String {
        switch self {
        case .sober:    return "Clear"
        case .buzzed:   return "Warming"
        case .impaired: return "Feeling it"
        case .drunk:    return "Lit"
        case .danger:   return "Slow down"
        }
    }

    var color: Color {
        switch self {
        case .sober:    return Color(red: 0.61, green: 0.74, blue: 0.55)
        case .buzzed:   return Color(red: 0.91, green: 0.66, blue: 0.29)
        case .impaired: return Color(red: 0.92, green: 0.55, blue: 0.30)
        case .drunk:    return Color(red: 0.85, green: 0.40, blue: 0.27)
        case .danger:   return Color(red: 0.85, green: 0.32, blue: 0.23)
        }
    }
}

// MARK: - Timeline

/// One frame the widget will render. Carries pre-decayed BACs so the
/// widget view itself does no math — purely declarative rendering.
struct SeshWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    /// BAC projected to `date` from snapshot. nil when snapshot is nil.
    let projectedMeBac: Double
    /// Per-member projected BAC keyed by profileId. Empty when solo
    /// or snapshot is nil.
    let projectedRosterBac: [UUID: Double]
}

/// Provides the timeline of `SeshWidgetEntry`s. Reads the shared
/// snapshot once per reload and projects every entry from it. iOS
/// re-invokes this on its own schedule + whenever the app calls
/// `WidgetCenter.shared.reloadAllTimelines()`.
struct SeshWidgetProvider: TimelineProvider {

    /// Tick cadence between entries. 5 minutes gives the BAC number
    /// time to actually move (0.015 × 5/60 = 0.00125% per tick — just
    /// past the resolution of the 3-decimal display) without burning
    /// system budget on more entries than the system will render.
    private let tickSeconds: TimeInterval = 5 * 60
    /// How far ahead to project. After this, we request another
    /// reload so a fresh snapshot can replace the projection.
    private let horizonSeconds: TimeInterval = 60 * 60

    /// Static preview shown in the widget gallery and during transitions.
    func placeholder(in context: Context) -> SeshWidgetEntry {
        SeshWidgetEntry(
            date: Date(),
            snapshot: nil,
            projectedMeBac: 0,
            projectedRosterBac: [:]
        )
    }

    /// Snapshot for the widget gallery / configuration screen. We
    /// surface the actual current snapshot if we have one so the
    /// preview matches reality; otherwise a tasteful sample.
    func getSnapshot(in context: Context, completion: @escaping (SeshWidgetEntry) -> Void) {
        let now = Date()
        if let snap = WidgetSharedStore.read() {
            completion(SeshWidgetEntry(
                date: now,
                snapshot: snap,
                projectedMeBac: snap.decayedBAC(from: snap.meBac, at: now),
                projectedRosterBac: rosterProjection(snap, at: now)
            ))
        } else {
            completion(placeholder(in: context))
        }
    }

    /// The actual timeline. We generate one entry per `tickSeconds`
    /// out to `horizonSeconds`, then ask the system to refresh us so
    /// we re-read the snapshot and project the next hour.
    func getTimeline(in context: Context, completion: @escaping (Timeline<SeshWidgetEntry>) -> Void) {
        let now = Date()
        let snap = WidgetSharedStore.read()
        var entries: [SeshWidgetEntry] = []
        let count = Int(horizonSeconds / tickSeconds) + 1
        for i in 0..<count {
            let when = now.addingTimeInterval(Double(i) * tickSeconds)
            let me = snap.map { $0.decayedBAC(from: $0.meBac, at: when) } ?? 0
            let roster = snap.map { rosterProjection($0, at: when) } ?? [:]
            entries.append(SeshWidgetEntry(
                date: when,
                snapshot: snap,
                projectedMeBac: me,
                projectedRosterBac: roster
            ))
        }
        let nextReload = now.addingTimeInterval(horizonSeconds)
        completion(Timeline(entries: entries, policy: .after(nextReload)))
    }

    private func rosterProjection(_ snap: WidgetSnapshot, at when: Date) -> [UUID: Double] {
        var out: [UUID: Double] = [:]
        for m in snap.roster {
            out[m.profileId] = snap.decayedBAC(from: m.bac, at: when)
        }
        return out
    }
}

// MARK: - Widget configuration

struct SeshHomeWidget: Widget {
    let kind: String = "SeshHomeWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SeshWidgetProvider()) { entry in
            SeshHomeWidgetView(entry: entry)
                .containerBackground(Color.seshInk, for: .widget)
        }
        .configurationDisplayName("sesh")
        .description("Your live BAC and your group — without unlocking your phone.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Widget view

private struct SeshHomeWidgetView: View {
    let entry: SeshWidgetEntry
    @Environment(\.widgetFamily) private var family

    /// Display unit, resolved fresh each render from the shared setting.
    /// The widget reloads its timeline whenever the app changes the unit,
    /// so reading it here keeps % / ‰ in sync with the rest of the app.
    @AppStorage(BACUnitSetting.key, store: BACUnitSetting.store) private var bacUnitMode = "auto"
    private var unit: BACUnit { BACUnitSetting.resolved(mode: bacUnitMode) }

    /// Relative "time until sober" derived from the projected BAC at the
    /// standard 0.015%/hr elimination rate — easier to parse at a glance
    /// than an absolute clock time. Decays correctly across timeline
    /// entries because it reads the already-projected BAC.
    private func clearInLabel(bac: Double) -> String {
        let totalMinutes = Int((bac / 0.015 * 60).rounded())
        guard totalMinutes > 0 else { return "Clear now" }
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        if h > 0 && m > 0 { return "Clear in \(h)h \(m)m" }
        if h > 0 { return "Clear in \(h)h" }
        return "Clear in \(m)m"
    }

    var body: some View {
        if let snap = entry.snapshot, snap.hasActiveSesh {
            content(for: snap)
        } else {
            emptyState
        }
    }

    @ViewBuilder
    private func content(for snap: WidgetSnapshot) -> some View {
        switch family {
        case .systemSmall:
            smallLayout(snap: snap)
        default:
            mediumLayout(snap: snap)
        }
    }

    // MARK: - Small (BAC + status + 1 line)

    private func smallLayout(snap: WidgetSnapshot) -> some View {
        let status = HomeWidgetStatus(bac: entry.projectedMeBac)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.seshWhiskey)
                    .frame(width: 6, height: 6)
                Text("LIVE")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(2.0)
                    .foregroundStyle(Color.seshWhiskey)
                Spacer()
            }
            Spacer(minLength: 0)
            Text(unit.formatted(entry.projectedMeBac))
                .font(.system(size: 38, weight: .black, design: .rounded))
                .tracking(-1.4)
                .foregroundStyle(Color.seshCream)
                .monospacedDigit()
            Text(unit.caption)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1.8)
                .foregroundStyle(Color.seshBronze)
            Spacer(minLength: 0)
            Text(status.label.uppercased())
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(Color.seshInk)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(status.color))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Medium (BAC + roster)

    private func mediumLayout(snap: WidgetSnapshot) -> some View {
        let status = HomeWidgetStatus(bac: entry.projectedMeBac)
        return HStack(alignment: .top, spacing: 14) {
            // Left: my BAC
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.seshWhiskey)
                        .frame(width: 6, height: 6)
                    Text("LIVE")
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .tracking(2.0)
                        .foregroundStyle(Color.seshWhiskey)
                }
                Text(unit.formatted(entry.projectedMeBac))
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .tracking(-1.4)
                    .foregroundStyle(Color.seshCream)
                    .monospacedDigit()
                Text(unit.caption)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(Color.seshBronze)
                Text(status.label.uppercased())
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(Color.seshInk)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(status.color))
                Spacer(minLength: 0)
                if entry.projectedMeBac > 0 {
                    Text(clearInLabel(bac: entry.projectedMeBac))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(Color.seshBronze)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Right: roster (or solo summary)
            if snap.inGroup && !snap.roster.isEmpty {
                rosterColumn(snap: snap)
            } else {
                soloRightColumn(snap: snap)
            }
        }
    }

    @ViewBuilder
    private func soloRightColumn(snap: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TONIGHT")
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .tracking(1.8)
                .foregroundStyle(Color.seshBronze)
            HStack(spacing: 4) {
                Image(systemName: "wineglass.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.seshWhiskey)
                Text("\(snap.meDrinkCount)")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.seshCream)
                Text(snap.meDrinkCount == 1 ? "drink" : "drinks")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.seshCream.opacity(0.6))
            }
            if let started = snap.meStartedAt {
                Text("Started \(started, format: .dateTime.hour().minute())")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.seshCream.opacity(0.6))
            }
            Spacer(minLength: 0)
            Text("Open sesh to add a drink")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(Color.seshBronze)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Right column in group mode: instead of a truncated member list
    /// (which only ever fit ~3 of a large group), surface the single
    /// drunkest member — the "MVP" — with a funny one-liner. The
    /// snapshot roster excludes "me" and is sorted BAC-descending, so
    /// `.first` is the leader. The roast text is computed app-side.
    @ViewBuilder
    private func rosterColumn(snap: WidgetSnapshot) -> some View {
        if let leader = snap.roster.first {
            let bac = entry.projectedRosterBac[leader.profileId] ?? leader.bac
            let mStatus = HomeWidgetStatus(bac: bac)
            VStack(alignment: .leading, spacing: 4) {
                Text("GROUP MVP")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(1.8)
                    .foregroundStyle(Color.seshBronze)
                HStack(spacing: 5) {
                    Text("🥇")
                        .font(.system(size: 12))
                    Text(leader.name)
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.seshCream)
                        .lineLimit(1)
                }
                HStack(spacing: 5) {
                    Circle()
                        .fill(mStatus.color)
                        .frame(width: 5, height: 5)
                    Text(unit.formatted(bac))
                        .font(.system(size: 13, weight: .black, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(mStatus.color)
                    Text(unit.caption)
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(1.0)
                        .foregroundStyle(Color.seshBronze)
                }
                if let roast = snap.topRoast, !roast.isEmpty {
                    Text(roast)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .italic()
                        .foregroundStyle(Color.seshCream.opacity(0.78))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 6) {
            Circle()
                .fill(Color.seshWhiskey.opacity(0.6))
                .frame(width: 8, height: 8)
            Text("No live sesh")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.seshCream)
            Text("Open sesh to start one.")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Color.seshCream.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Preview

#Preview(as: .systemMedium) {
    SeshHomeWidget()
} timeline: {
    let now = Date()
    SeshWidgetEntry(
        date: now,
        snapshot: WidgetSnapshot(
            snapshotAt: now,
            hasActiveSesh: true,
            inGroup: true,
            meName: "Mauritz",
            meBac: 0.072,
            meStatusRaw: "impaired",
            meDrinkCount: 4,
            meStartedAt: now.addingTimeInterval(-2.5 * 3600),
            meSoberAt: now.addingTimeInterval(4.8 * 3600),
            roster: [
                .init(profileId: UUID(), name: "Alex", bac: 0.121,
                      statusRaw: "drunk", drinkCount: 6, initials: "A"),
                .init(profileId: UUID(), name: "Sara", bac: 0.039,
                      statusRaw: "buzzed", drinkCount: 2, initials: "S"),
                .init(profileId: UUID(), name: "Jonas", bac: 0.018,
                      statusRaw: "sober", drinkCount: 1, initials: "J"),
            ]
        ),
        projectedMeBac: 0.072,
        projectedRosterBac: [:]
    )
}
