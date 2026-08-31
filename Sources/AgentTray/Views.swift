import AppKit
import SwiftUI

struct AgentPanelView: View {
    @ObservedObject var store: StatsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            profileTabs
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 420)
        .background(.background)
        .task { await store.start() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: TrayIcon.image)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .foregroundStyle(Color.agentCoral)
                .frame(width: 28, height: 28)
                .background(Color.agentCoral.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Agent Tray")
                    .font(.headline)
                Text(statusSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    @ViewBuilder
    private var profileTabs: some View {
        if store.profiles.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(store.profiles) { profile in
                        ProfileTab(
                            profile: profile,
                            selected: profile.id == store.selectedProfileID,
                            health: store.snapshot(for: profile)?.health
                        ) {
                            if reduceMotion {
                                store.selectedProfileID = profile.id
                            } else {
                                withAnimation(.easeOut(duration: 0.18)) {
                                    store.selectedProfileID = profile.id
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 42)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let profile = store.profiles.first(where: { $0.id == store.selectedProfileID }) {
            if let snapshot = store.snapshot(for: profile) {
                SnapshotView(profile: profile, snapshot: snapshot)
                    .id(profile.id)
                    .transition(.opacity)
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reading \(profile.displayName) stats…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
                .accessibilityElement(children: .combine)
            }
        } else {
            ContentUnavailableView(
                "No agents found",
                systemImage: "cpu",
                description: Text("Install Grok or Codex, or add a Codex provider in Settings.")
            )
            .frame(minHeight: 260)
        }
    }

    private var footer: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 12) {
                Text(store.lastRefresh.map { "Updated \($0.compactPastDescription(relativeTo: context.date))" } ?? "Waiting for first refresh")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()

                HStack(spacing: 12) {
                    Button {
                        Task { await store.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .rotationEffect(.degrees(store.isRefreshing && !reduceMotion ? 180 : 0))
                            .animation(store.isRefreshing && !reduceMotion ? .easeOut(duration: 0.35) : nil, value: store.isRefreshing)
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.borderless)
                    .disabled(store.isRefreshing)
                    .help("Refresh agent stats")
                    .accessibilityLabel(store.isRefreshing ? "Refreshing agent stats" : "Refresh agent stats")

                    Button {
                        NSApplication.shared.terminate(nil)
                    } label: {
                        Image(systemName: "power")
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.borderless)
                    .help("Quit Agent Tray")
                    .accessibilityLabel("Quit Agent Tray")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
        }
    }

    private var statusSummary: String {
        let count = store.profiles.count
        let issueCount = store.profiles.compactMap { store.snapshot(for: $0)?.health.message }.count
        let profileText = "\(count) \(count == 1 ? "profile" : "profiles")"
        return issueCount == 0 ? profileText : "\(profileText) · \(issueCount) need attention"
    }
}

private struct ProfileTab: View {
    let profile: AgentProfile
    let selected: Bool
    let health: ProviderHealth?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: profile.kind.symbolName)
                    .font(.caption)
                Text(profile.displayName)
                    .lineLimit(1)
                if health?.message != nil {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Needs attention")
                }
            }
            .font(.callout.weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(selected ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(profile.displayName)
        .accessibilityValue(selected ? "Selected" : "")
    }
}

private struct SnapshotView: View {
    let profile: AgentProfile
    let snapshot: AgentSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
                profileSummary
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)

                if let message = snapshot.health.message {
                    StateNotice(
                        unavailable: {
                            if case .unavailable = snapshot.health { return true }
                            return false
                        }(),
                        message: message
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 9)
                }

                if profile.supportsQuota {
                    sectionHeader("Usage")
                    if snapshot.quotaWindows.isEmpty {
                        Text("No quota data is available for this profile.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 9)
                    } else {
                        QuotaGrid(windows: snapshot.quotaWindows)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 9)
                    }

                    Divider()
                }
                sectionHeader("Activity")
                ActivityGrid(activity: snapshot.activity)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
        }
    }

    private var profileSummary: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.displayName)
                    .font(.headline)
                Text([snapshot.planName, snapshot.sourceNote].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }
}

private struct QuotaGrid: View {
    let windows: [QuotaWindow]

    var body: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 12, alignment: .topLeading),
                count: min(max(windows.count, 1), 3)
            ),
            alignment: .leading,
            spacing: 9
        ) {
            ForEach(windows) { QuotaCell(window: $0) }
        }
    }
}

private struct QuotaCell: View {
    let window: QuotaWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(window.label)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text("\(window.usedPercent)%")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            }

            ProgressView(value: Double(window.usedPercent), total: 100)
                .tint(progressColor)
                .accessibilityLabel("\(window.label) usage")
                .accessibilityValue("\(window.usedPercent) percent used")
            if let reset = window.resetsAt {
                Text("Resets \(reset.relativeDescription)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var progressColor: Color {
        if window.usedPercent > 90 { return .red }
        if window.usedPercent >= 75 { return .yellow }
        return .accentColor
    }
}

private struct ActivityGrid: View {
    let activity: ActivitySummary

    private var metrics: [(String, String)] {
        var values: [(String, String)] = [
            ("Today", activity.tokensToday.map { "\($0.compactCount) tokens" } ?? "Not available"),
            ("Last 7 days", activity.tokensSevenDays.map { "\($0.compactCount) tokens" } ?? "Not available"),
            ("Recent sessions", activity.recentSessions.formatted())
        ]
        if let date = activity.lastActivity { values.append(("Last active", date.relativeDescription)) }
        if let model = activity.model { values.append(("Recent model", model)) }
        if let lifetime = activity.lifetimeTokens { values.append(("Lifetime", "\(lifetime.compactCount) tokens")) }
        return values
    }

    var body: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 12, alignment: .leading),
                count: metrics.count > 4 ? 3 : 2
            ),
            spacing: 8
        ) {
            ForEach(Array(metrics.enumerated()), id: \.offset) { _, metric in
                VStack(alignment: .leading, spacing: 1) {
                    Text(metric.0)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(metric.1)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct StateNotice: View {
    let unavailable: Bool
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: unavailable ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(unavailable ? .red : .orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(unavailable ? "Unavailable" : "Attention"): \(message)")
    }
}

extension Color {
    static let agentCoral = Color(red: 0.79, green: 0.34, blue: 0.22)
}
