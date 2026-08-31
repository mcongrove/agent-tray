import Foundation

enum AgentKind: String, Codable, Sendable {
    case grok
    case codex

    var symbolName: String {
        switch self {
        case .grok: "bolt.horizontal.circle"
        case .codex: "chevron.left.forwardslash.chevron.right"
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

extension Date {
    var relativeDescription: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: self, relativeTo: Date())
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
