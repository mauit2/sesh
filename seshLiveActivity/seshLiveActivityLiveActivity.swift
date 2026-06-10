// Lock-screen + Dynamic Island UI for an in-flight sesh. This target is
// a separate process from the main app — it can't see anything in
// content_view.swift behind a `private` extension. The palette + status
// mapping is duplicated here on purpose; keeping the widget
// self-contained means the main app can't accidentally break the
// widget's compile.
//
// Update model:
// • The host app calls `LiveActivityController.shared.update(...)` on
//   every drink change + on the 30s LiveSeshView tick.
// • Between those calls, the only thing that ticks is the "Sober by"
//   countdown — `Text(timerInterval:countsDown:)` is rendered by the
//   system without us doing anything.
// • The "as of HH:MM" timestamp on the card sets honest expectations
//   when the user picks the phone up after a long lock.
//
// Quick-add buttons:
// • The `quickDrinks` array on ContentState is wired to one tap-to-log
//   button per drink. Tap fires `AddDrinkFromLockScreenIntent`, which
//   runs in the main app's process and updates the activity in <50ms.
// • Hidden in group mode (lock-screen logging is solo-only — group
//   writes need network and we don't want to gate a tap on it).

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Local palette (must mirror the app — see comment above)

private extension Color {
    static let seshInk     = Color(red: 0.043, green: 0.039, blue: 0.031)
    static let seshWhiskey = Color(red: 0.910, green: 0.659, blue: 0.290)
    static let seshCream   = Color(red: 0.961, green: 0.929, blue: 0.878)
    static let seshBronze  = Color(red: 0.541, green: 0.498, blue: 0.431)
}

// MARK: - Local status mapping

private enum WidgetStatus: String {
    case sober, buzzed, impaired, drunk, danger

    init(raw: String) {
        self = WidgetStatus(rawValue: raw) ?? .sober
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
        case .buzzed:   return Color(red: 0.91, green: 0.66, blue: 0.29)  // whiskey
        case .impaired: return Color(red: 0.92, green: 0.55, blue: 0.30)
        case .drunk:    return Color(red: 0.85, green: 0.40, blue: 0.27)
        case .danger:   return Color(red: 0.85, green: 0.32, blue: 0.23)
        }
    }
}

// MARK: - Live Activity

struct seshLiveActivityLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SeshActivityAttributes.self) { context in
            // ---- Lock Screen ----
            LockScreenView(
                attributes: context.attributes,
                state: context.state
            )
            .activityBackgroundTint(Color.seshInk)
            .activitySystemActionForegroundColor(Color.seshCream)
        } dynamicIsland: { context in
            // ---- Dynamic Island ----
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    expandedLeading(state: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    expandedTrailing(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    expandedBottom(
                        attributes: context.attributes,
                        state: context.state
                    )
                }
            } compactLeading: {
                // Pilot dot — matches the masthead.
                Circle()
                    .fill(Color.seshWhiskey)
                    .frame(width: 8, height: 8)
                    .shadow(color: Color.seshWhiskey.opacity(0.7), radius: 4)
            } compactTrailing: {
                Text(String(format: "%.3f", context.state.bac))
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(WidgetStatus(raw: context.state.statusRaw).color)
            } minimal: {
                // Single-glyph collapse. Show BAC tier as a tiny dot.
                Circle()
                    .fill(WidgetStatus(raw: context.state.statusRaw).color)
                    .frame(width: 10, height: 10)
                    .shadow(color: WidgetStatus(raw: context.state.statusRaw).color.opacity(0.7), radius: 4)
            }
            .keylineTint(Color.seshWhiskey)
        }
    }

    // MARK: - Dynamic Island expanded regions

    @ViewBuilder
    private func expandedLeading(state: SeshActivityAttributes.ContentState) -> some View {
        let status = WidgetStatus(raw: state.statusRaw)
        VStack(alignment: .leading, spacing: 4) {
            Text("BAC")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(2.0)
                .foregroundStyle(Color.seshBronze)
            Text(String(format: "%.3f", state.bac))
                .font(.system(size: 28, weight: .black, design: .rounded))
                .foregroundStyle(status.color)
                .monospacedDigit()
                .contentTransition(.numericText(value: state.bac))
        }
    }

    @ViewBuilder
    private func expandedTrailing(state: SeshActivityAttributes.ContentState) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text("SOBER BY")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(2.0)
                .foregroundStyle(Color.seshBronze)
            if state.bac > 0 {
                Text(state.soberAt, format: .dateTime.hour().minute())
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.seshCream)
                    .monospacedDigit()
            } else {
                Text("Now")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.seshCream)
            }
        }
    }

    @ViewBuilder
    private func expandedBottom(
        attributes: SeshActivityAttributes,
        state: SeshActivityAttributes.ContentState
    ) -> some View {
        let status = WidgetStatus(raw: state.statusRaw)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "wineglass.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.seshWhiskey)
                    Text("\(state.drinkCount) \(state.drinkCount == 1 ? "drink" : "drinks")")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(1.0)
                        .foregroundStyle(Color.seshCream.opacity(0.75))
                }
                Spacer()
                if state.bac > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "hourglass")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(status.color)
                        Text(timerInterval: state.lastUpdate...state.soberAt, countsDown: true)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .tracking(1.0)
                            .foregroundStyle(status.color)
                            .monospacedDigit()
                    }
                }
                Text(status.label.uppercased())
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(Color.seshInk)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(status.color))
            }

            if !state.quickDrinks.isEmpty && !attributes.inGroup {
                QuickAddRow(drinks: state.quickDrinks, compact: true)
            }
            if !state.roster.isEmpty {
                RosterStack(members: state.roster, compact: true)
            }
        }
    }
}

// MARK: - Lock Screen card

private struct LockScreenView: View {
    let attributes: SeshActivityAttributes
    let state: SeshActivityAttributes.ContentState

    private var status: WidgetStatus { WidgetStatus(raw: state.statusRaw) }

    var body: some View {
        ZStack {
            // Subtle whiskey halo bottom-right — mirrors the in-app
            // AtmosphereBackground without trying to recreate it
            // (Live Activity backgrounds are flat-tinted by the OS).
            HStack {
                Spacer()
                Circle()
                    .fill(Color.seshWhiskey.opacity(0.08))
                    .frame(width: 180, height: 180)
                    .blur(radius: 30)
                    .offset(x: 60, y: 30)
            }

            // The lock-screen card is always YOUR readout: big own BAC +
            // quick-add, in both solo and group. (The group roster lives
            // on the Home Screen widget + the Dynamic Island expanded view
            // — the lock-screen card stays focused on you + one-tap adds.)
            VStack(alignment: .leading, spacing: 12) {
                header
                bigBAC
                footer
                if !state.quickDrinks.isEmpty {
                    QuickAddRow(drinks: state.quickDrinks, compact: false)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.seshWhiskey)
                .frame(width: 7, height: 7)
                .shadow(color: Color.seshWhiskey.opacity(0.8), radius: 4)
            Text(attributes.heroLabel)
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(2.4)
                .foregroundStyle(Color.seshWhiskey)
            Spacer()
            Text("AS OF \(state.lastUpdate, format: .dateTime.hour().minute())")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(Color.seshBronze)
        }
    }

    private var bigBAC: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(String(format: "%.3f", state.bac))
                .font(.system(size: 44, weight: .black, design: .rounded))
                .tracking(-1.5)
                .foregroundStyle(Color.seshCream)
                .monospacedDigit()
                .contentTransition(.numericText(value: state.bac))
            Text("%BAC")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(1.8)
                .foregroundStyle(Color.seshBronze)
            Spacer()
            Text(status.label.uppercased())
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(1.6)
                .foregroundStyle(Color.seshInk)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(status.color))
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            // Drink count chip
            HStack(spacing: 6) {
                Image(systemName: "wineglass.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.seshWhiskey)
                Text("\(state.drinkCount)")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.seshCream)
                    .monospacedDigit()
                Text(state.drinkCount == 1 ? "DRINK" : "DRINKS")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(Color.seshCream.opacity(0.55))
            }

            Spacer()

            // Live-ticking sober-by countdown. SwiftUI handles the
            // tick — we just render the formatter and the system
            // refreshes the view roughly once a second on the lock
            // screen until the interval lapses.
            if state.bac > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "hourglass")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(status.color)
                    Text(timerInterval: state.lastUpdate...state.soberAt, countsDown: true)
                        .font(.system(size: 12, weight: .heavy, design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(status.color)
                        .monospacedDigit()
                    Text("TO 0.000")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(Color.seshBronze)
                }
            } else {
                Text("CLEAR")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .tracking(1.8)
                    .foregroundStyle(status.color)
            }
        }
    }
}

// MARK: - Quick-add buttons

/// A row of `Button(intent:)` chips — one per recent drink. Tapping a
/// chip fires `AddDrinkFromLockScreenIntent`, which runs in the main
/// app's process, appends the drink, recomputes BAC, and pushes a
/// fresh activity frame. The `compact` flag swaps glyph sizing for the
/// tighter Dynamic Island expanded region.
private struct QuickAddRow: View {
    let drinks: [SeshActivityAttributes.QuickDrink]
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 6 : 8) {
            ForEach(drinks.prefix(3)) { drink in
                if #available(iOS 17.0, *) {
                    Button(intent: AddDrinkFromLockScreenIntent(drink: drink)) {
                        chipContent(for: drink)
                    }
                    .buttonStyle(.plain)
                } else {
                    // Pre-17 fallback: render the chip as a static
                    // affordance. iOS 16 doesn't support Button(intent:)
                    // in Live Activities so the tap would be a no-op
                    // anyway; we keep the visual so the card layout
                    // doesn't reflow when older OSes attach.
                    chipContent(for: drink)
                }
            }
        }
    }

    @ViewBuilder
    private func chipContent(for drink: SeshActivityAttributes.QuickDrink) -> some View {
        HStack(spacing: 5) {
            Text(drink.emoji)
                .font(.system(size: compact ? 11 : 13))
            Text(shortName(drink.name).uppercased())
                .font(.system(size: compact ? 9 : 10, weight: .black, design: .monospaced))
                .tracking(1.0)
                .foregroundStyle(Color.seshCream)
                .lineLimit(1)
            Image(systemName: "plus")
                .font(.system(size: compact ? 8 : 9, weight: .black))
                .foregroundStyle(Color.seshWhiskey)
        }
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 5 : 7)
        .background(
            Capsule()
                .fill(Color.seshCream.opacity(0.06))
                .overlay(
                    Capsule()
                        .stroke(Color.seshWhiskey.opacity(0.45), lineWidth: 1)
                )
        )
    }

    /// Trim the chip label so a long catalog name ("Bottle of champagne")
    /// doesn't blow past the lock-screen card edge. The full name is
    /// already evident from the emoji + the user's recent history; the
    /// chip is just a quick re-add affordance, not a menu item.
    private func shortName(_ name: String) -> String {
        let trimmed = name
            .replacingOccurrences(of: "Bottle of ", with: "")
            .replacingOccurrences(of: "Glass of ", with: "")
            .replacingOccurrences(of: "Pint of ", with: "")
            .replacingOccurrences(of: "Shot of ", with: "")
        let cap = compact ? 9 : 11
        if trimmed.count > cap {
            return String(trimmed.prefix(cap - 1)) + "…"
        }
        return trimmed
    }
}

// MARK: - Group roster

/// Vertical stack of roster rows shown on the lock-screen card and the
/// Dynamic Island expanded bottom in group mode. Compact variant tightens
/// padding + text size for the smaller DI region. Pinning the user (the
/// `isMe` row) is done at projection time in the app; this view just
/// renders in order.
private struct RosterStack: View {
    let members: [SeshActivityAttributes.RosterMember]
    let compact: Bool

    var body: some View {
        VStack(spacing: compact ? 3 : 5) {
            ForEach(members) { m in
                RosterRow(member: m, compact: compact)
            }
        }
    }
}

private struct RosterRow: View {
    let member: SeshActivityAttributes.RosterMember
    let compact: Bool

    private var status: WidgetStatus { WidgetStatus(raw: member.statusRaw) }

    var body: some View {
        HStack(spacing: compact ? 8 : 10) {
            avatar
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(member.name)
                        .font(.system(size: compact ? 11 : 12, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.seshCream)
                        .lineLimit(1)
                    if member.isMe {
                        Text("YOU")
                            .font(.system(size: 8, weight: .black, design: .monospaced))
                            .tracking(1.2)
                            .foregroundStyle(Color.seshInk)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.seshWhiskey))
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    Text("\(member.drinkCount) \(member.drinkCount == 1 ? "drink" : "drinks")")
                        .font(.system(size: compact ? 9 : 10, weight: .bold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(Color.seshCream.opacity(0.55))
                    Circle()
                        .fill(Color.seshBronze.opacity(0.5))
                        .frame(width: 2, height: 2)
                    Text(status.label.uppercased())
                        .font(.system(size: compact ? 9 : 10, weight: .black, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(status.color)
                }
            }
            Spacer(minLength: 4)
            Text(String(format: "%.3f", member.bac))
                .font(.system(size: compact ? 13 : 15, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(status.color)
        }
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 4 : 6)
        .background(
            RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                .fill(member.isMe ? Color.seshWhiskey.opacity(0.08) : Color.seshCream.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                .strokeBorder(
                    member.isMe ? Color.seshWhiskey.opacity(0.35) : Color.seshCream.opacity(0.06),
                    lineWidth: 1
                )
        )
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(status.color.opacity(0.18))
                .overlay(
                    Circle().strokeBorder(
                        member.isMe ? Color.seshWhiskey : status.color.opacity(0.45),
                        lineWidth: member.isMe ? 1.5 : 1
                    )
                )
            Text(member.initials)
                .font(.system(size: compact ? 9 : 10, weight: .black, design: .rounded))
                .foregroundStyle(Color.seshCream)
        }
        .frame(width: compact ? 22 : 26, height: compact ? 22 : 26)
    }
}

// MARK: - Previews

extension SeshActivityAttributes {
    fileprivate static var preview: SeshActivityAttributes {
        SeshActivityAttributes(heroLabel: "LIVE SESH", inGroup: false)
    }
}

extension SeshActivityAttributes.ContentState {
    fileprivate static var sampleQuickDrinks: [SeshActivityAttributes.QuickDrink] {
        [
            .init(name: "Large beer", detail: "50 cl · 5%", category: "beer",
                  volumeML: 500, abv: 0.05, emoji: "🍺"),
            .init(name: "Glass of wine", detail: "15 cl · 12%", category: "wine",
                  volumeML: 150, abv: 0.12, emoji: "🍷"),
            .init(name: "Single whisky", detail: "2.5 cl · 40%", category: "whisky",
                  volumeML: 25, abv: 0.40, emoji: "🥃"),
        ]
    }

    fileprivate static var buzzedSample: SeshActivityAttributes.ContentState {
        let now = Date()
        return SeshActivityAttributes.ContentState(
            bac: 0.042,
            drinkCount: 2,
            soberAt: now.addingTimeInterval(2.8 * 3600),
            startedAt: now.addingTimeInterval(-45 * 60),
            statusRaw: "buzzed",
            lastUpdate: now,
            quickDrinks: sampleQuickDrinks
        )
    }

    fileprivate static var litSample: SeshActivityAttributes.ContentState {
        let now = Date()
        return SeshActivityAttributes.ContentState(
            bac: 0.116,
            drinkCount: 6,
            soberAt: now.addingTimeInterval(7.7 * 3600),
            startedAt: now.addingTimeInterval(-2.5 * 3600),
            statusRaw: "drunk",
            lastUpdate: now,
            quickDrinks: sampleQuickDrinks
        )
    }

    fileprivate static var groupSample: SeshActivityAttributes.ContentState {
        let now = Date()
        return SeshActivityAttributes.ContentState(
            bac: 0.072,
            drinkCount: 4,
            soberAt: now.addingTimeInterval(4.8 * 3600),
            startedAt: now.addingTimeInterval(-2.5 * 3600),
            statusRaw: "impaired",
            lastUpdate: now,
            quickDrinks: [],
            roster: [
                .init(profileId: UUID(), name: "Mauritz", bac: 0.072, statusRaw: "impaired",
                      drinkCount: 4, initials: "M", isMe: true),
                .init(profileId: UUID(), name: "Alex", bac: 0.121, statusRaw: "drunk",
                      drinkCount: 6, initials: "A", isMe: false),
                .init(profileId: UUID(), name: "Sara", bac: 0.039, statusRaw: "buzzed",
                      drinkCount: 2, initials: "S", isMe: false),
                .init(profileId: UUID(), name: "Jonas", bac: 0.018, statusRaw: "sober",
                      drinkCount: 1, initials: "J", isMe: false),
            ]
        )
    }
}

#Preview("Lock Screen", as: .content, using: SeshActivityAttributes.preview) {
   seshLiveActivityLiveActivity()
} contentStates: {
    SeshActivityAttributes.ContentState.buzzedSample
    SeshActivityAttributes.ContentState.litSample
    SeshActivityAttributes.ContentState.groupSample
}
