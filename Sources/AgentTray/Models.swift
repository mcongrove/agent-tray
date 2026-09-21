import Foundation

enum NotchPosition: String, CaseIterable {
    case top, right, bottom, left

    var label: String { rawValue.capitalized }
    var isHorizontal: Bool { self == .top || self == .bottom }
}

enum AgentKind: String, Codable, Sendable {
    case grok
    case cursor
    case codex

    var symbolName: String {
        switch self {
        case .grok: "sparkle"
        case .cursor: "cube"
        case .codex: "circle.hexagongrid"
        }
    }
}

enum CodexSelection: Codable, Hashable, Sendable {
    case defaultProfile
    case namedProfile(String)
    case modelProvider(String)
}

struct AgentProfile: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let kind: AgentKind
    var displayName: String
    var codexSelection: CodexSelection?
    var executableURL: URL?
    var supportsQuota: Bool = true
}

struct QuotaWindow: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let label: String
    let usedPercent: Int
    let resetsAt: Date?
    let durationMinutes: Int?
    var detail: String? = nil
}

struct ActivitySummary: Codable, Equatable, Sendable {
    var tokensToday: Int64?
    var tokensSevenDays: Int64?
    var recentSessions: Int
    var lastActivity: Date?
    var model: String?
    var lifetimeTokens: Int64?

    static let empty = ActivitySummary(
        tokensToday: nil,
        tokensSevenDays: nil,
        recentSessions: 0,
        lastActivity: nil,
        model: nil,
        lifetimeTokens: nil
    )
}

enum ProviderHealth: Codable, Equatable, Sendable {
    case healthy
    case partial(String)
    case unavailable(String)

    var message: String? {
        switch self {
        case .healthy: nil
        case .partial(let message), .unavailable(let message): message
        }
    }
}

struct AgentSnapshot: Codable, Equatable, Sendable {
    let profileID: String
    let fetchedAt: Date
    var quotaWindows: [QuotaWindow]
    var activity: ActivitySummary
    var planName: String?
    var creditBalance: String?
    var health: ProviderHealth
    var sourceNote: String

    var headlinePercent: Int {
        quotaWindows.first(where: { $0.id != "cursor-ondemand" })?.usedPercent
            ?? quotaWindows.first?.usedPercent
            ?? 0
    }

    var cursorModelsPercent: Int? {
        quotaWindows.first(where: { $0.id == "cursor-auto" })?.usedPercent
    }

    var cursorOtherPercent: Int? {
        quotaWindows.first(where: { $0.id == "cursor-api" })?.usedPercent
    }

    var codexWeeklyPercent: Int? {
        quotaWindows.first(where: { $0.durationMinutes == 10_080 })?.usedPercent
    }

    var codexFiveHourPercent: Int? {
        quotaWindows.first(where: { $0.durationMinutes == 300 })?.usedPercent
    }

    static func unavailable(profileID: String, message: String) -> AgentSnapshot {
        AgentSnapshot(
            profileID: profileID,
            fetchedAt: Date(),
            quotaWindows: [],
            activity: .empty,
            planName: nil,
            creditBalance: nil,
            health: .unavailable(message),
            sourceNote: "No current data"
        )
    }
}

protocol AgentStatsProvider {
    func snapshot(for profile: AgentProfile) async -> AgentSnapshot
}

extension Int64 {
    var compactCount: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1

        let value = Double(self)
        switch abs(value) {
        case 1_000_000_000...:
            return "\(formatter.string(from: NSNumber(value: value / 1_000_000_000)) ?? "0")B"
        case 1_000_000...:
            return "\(formatter.string(from: NSNumber(value: value / 1_000_000)) ?? "0")M"
        case 1_000...:
            return "\(formatter.string(from: NSNumber(value: value / 1_000)) ?? "0")K"
        default:
            return formatter.string(from: NSNumber(value: self)) ?? "0"
        }
    }
}

func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    fallback: T,
    operation: @escaping @Sendable () async -> T
) async -> T {
    await withCheckedContinuation { continuation in
        let gate = TimeoutGate<T>()
        let work = Task {
            await gate.finish(await operation(), continuation: continuation)
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            await gate.finish(fallback, continuation: continuation)
            work.cancel()
        }
    }
}

private actor TimeoutGate<T: Sendable> {
    private var resumed = false

    func finish(_ value: T, continuation: CheckedContinuation<T, Never>) {
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: value)
    }
}

extension Date {
    var relativeDescription: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: self, relativeTo: Date())
    }

    var resetDescription: String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "MMM d h:mma"
        formatter.amSymbol = formatter.amSymbol.lowercased()
        formatter.pmSymbol = formatter.pmSymbol.lowercased()
        return formatter.string(from: self)
    }

    func compactPastDescription(relativeTo now: Date = Date()) -> String {
        let seconds = max(Int(now.timeIntervalSince(self)), 0)
        switch seconds {
        case 0..<5: return "just now"
        case 5..<60: return "\(seconds) sec ago"
        case 60..<3_600: return "\(seconds / 60) min ago"
        case 3_600..<86_400: return "\(seconds / 3_600) hr ago"
        default: return "\(seconds / 86_400) d ago"
        }
    }
}
