// Moderation.swift — the report queue.
//
// Reports had been write-only since migration 041: the app inserted them and
// nothing ever read them back. Migration 131 added admin_reports() and the
// three actions; this is the screen that uses them.
//
// Deliberately plain. Three buttons — remove, dismiss, restore — and enough
// context on each row to decide without opening anything. Removing content
// closes every open report against it server-side, so a post reported by five
// people leaves the queue once rather than five times.

import SwiftUI

struct ReportsAdminView: View {
    @ObservedObject var admin: AdminService
    @Environment(\.dismiss) private var dismiss
    @State private var busy: UUID?

    var body: some View {
        NavigationStack {
            Group {
                if admin.reports.isEmpty {
                    empty
                } else {
                    List {
                        ForEach(admin.reports) { r in
                            ReportRow(report: r, busy: busy == r.id,
                                      onRemove: { act(r) { await admin.takedown(r, reason: nil) } },
                                      onDismiss: { act(r) { await admin.resolve(r, action: "no action") } },
                                      onRestore: { act(r) { await admin.restore(r) } })
                            .listRowBackground(Color.inkElev)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.ink.ignoresSafeArea())
            .navigationTitle("Reports")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.tint(Color.whiskey)
                }
            }
        }
        .task { await admin.loadReports() }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.bronze)
            Text("NOTHING TO REVIEW")
                .font(.system(size: 12, weight: .black, design: .monospaced))
                .tracking(2)
                .foregroundStyle(Color.cream.opacity(0.7))
            Text("Reports from users land here.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.45))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func act(_ r: AdminService.ReportEntry, _ work: @escaping () async -> Void) {
        busy = r.id
        Task { await work(); busy = nil }
    }
}

private struct ReportRow: View {
    let report: AdminService.ReportEntry
    let busy: Bool
    let onRemove: () -> Void
    let onDismiss: () -> Void
    let onRestore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let reason = report.reason, !reason.isEmpty {
                Text(reason)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.cream)
            }
            if let caption = report.content_caption, !caption.isEmpty {
                Text("“\(caption)”")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Color.cream.opacity(0.6))
                    .lineLimit(3)
            }
            status
            actions
        }
        .padding(.vertical, 6)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(report.target_kind.uppercased())
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(Color.ink)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(Color.bronze))
            Text(who)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Color.cream.opacity(0.8))
            Spacer()
            Text(report.created_at, style: .relative)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.cream.opacity(0.4))
        }
    }

    private var who: String {
        let reporter = report.reporter_username.map { "@\($0)" } ?? report.reporter_name ?? "someone"
        guard report.target_kind != "user" else {
            let t = report.target_username.map { "@\($0)" } ?? report.target_name ?? "a user"
            return "\(reporter) reported \(t)"
        }
        let t = report.target_username.map { "@\($0)" } ?? report.target_name ?? "a user"
        return "\(reporter) → \(t)"
    }

    @ViewBuilder private var status: some View {
        if report.content_gone {
            label("Already gone — expired or account deleted", Color.cream.opacity(0.45))
        } else if report.isRemoved {
            label("Removed", Color(red: 0.902, green: 0.325, blue: 0.267))
        }
    }

    private func label(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(tint)
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            if report.isContent && !report.content_gone {
                if report.isRemoved {
                    button("Restore", Color.bronze, onRestore)
                } else {
                    button("Remove", Color(red: 0.902, green: 0.325, blue: 0.267), onRemove)
                }
            }
            button("Dismiss", Color.cream.opacity(0.35), onDismiss)
            Spacer()
            if busy { ProgressView().controlSize(.small).tint(Color.whiskey) }
        }
        .disabled(busy)
    }

    private func button(_ title: String, _ tint: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(tint)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().stroke(tint.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
