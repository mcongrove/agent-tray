import Foundation

struct GrokStatsProvider: AgentStatsProvider {
    let homeDirectory: URL
    let environment: [String: String]

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.homeDirectory = homeDirectory
        self.environment = environment
    }

    func snapshot(for profile: AgentProfile) async -> AgentSnapshot {
        let grokHome = environment["GROK_HOME"].map(URL.init(fileURLWithPath:))
            ?? homeDirectory.appendingPathComponent(".grok")
        let logURL = grokHome.appendingPathComponent("logs/unified.jsonl")

        guard let data = try? Data(contentsOf: logURL), let text = String(data: data, encoding: .utf8) else {
            return .unavailable(profileID: profile.id, message: "No Grok activity log was found.")
        }

        let parsed = Self.parseLog(text)
        let quota: [QuotaWindow]
        if let percent = parsed.creditUsagePercent {
            quota = [QuotaWindow(
                id: "grok-billing-period",
                label: "Billing period",
                usedPercent: min(max(Int(percent.rounded()), 0), 100),
                resetsAt: parsed.billingPeriodEnd,
                durationMinutes: nil
            )]
        } else {
            quota = []
        }

        let health: ProviderHealth = quota.isEmpty
            ? .partial("Grok quota has not appeared in the local telemetry yet.")
            : .healthy

        return AgentSnapshot(
            profileID: profile.id,
            fetchedAt: Date(),
            quotaWindows: quota,
            activity: ActivitySummary(
                tokensToday: parsed.tokensToday,
                tokensSevenDays: parsed.tokensSevenDays,
                recentSessions: parsed.recentSessions,
                lastActivity: parsed.lastActivity,
                model: parsed.model,
                lifetimeTokens: nil
            ),
            planName: parsed.subscriptionTier,
            creditBalance: nil,
            health: health,
            sourceNote: "Estimated from Grok local telemetry"
        )
    }

    static func parseLog(_ text: String, now: Date = Date()) -> GrokLogSummary {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let sevenDayCutoff = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        var tokensToday: Int64 = 0
        var tokensSevenDays: Int64 = 0
        var sessions = Set<String>()
        var lastActivity: Date?
        var model: String?
        var creditUsagePercent: Double?
        var billingPeriodEnd: Date?
        var subscriptionTier: String?

        for line in text.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let context = object["ctx"] as? [String: Any]
            else { continue }

            let timestamp = (object["ts"] as? String).flatMap(Self.parseDate)
            if let config = context["config"] as? [String: Any],
               let percentage = (config["creditUsagePercent"] as? NSNumber)?.doubleValue {
                creditUsagePercent = percentage
                billingPeriodEnd = (config["billingPeriodEnd"] as? String).flatMap(Self.parseDate)
                subscriptionTier = context["subscriptionTier"] as? String
            }

            if let observedModel = context["model"] as? String { model = observedModel }

            guard let timestamp,
                  let prompt = (context["prompt_tokens"] as? NSNumber)?.int64Value,
                  let completion = (context["completion_tokens"] as? NSNumber)?.int64Value
            else { continue }

            let cached = (context["cached_prompt_tokens"] as? NSNumber)?.int64Value ?? 0
            let netTokens = max(prompt - cached, 0) + max(completion, 0)
            if timestamp >= sevenDayCutoff { tokensSevenDays += netTokens }
            if timestamp >= today { tokensToday += netTokens }
            if let sessionID = object["sid"] as? String, timestamp >= sevenDayCutoff { sessions.insert(sessionID) }
            if lastActivity == nil || timestamp > lastActivity! { lastActivity = timestamp }
        }

        return GrokLogSummary(
            creditUsagePercent: creditUsagePercent,
            billingPeriodEnd: billingPeriodEnd,
            subscriptionTier: subscriptionTier,
            tokensToday: tokensToday,
            tokensSevenDays: tokensSevenDays,
            recentSessions: sessions.count,
            lastActivity: lastActivity,
            model: model
        )
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}

struct GrokLogSummary: Equatable {
    let creditUsagePercent: Double?
    let billingPeriodEnd: Date?
    let subscriptionTier: String?
    let tokensToday: Int64
    let tokensSevenDays: Int64
    let recentSessions: Int
    let lastActivity: Date?
    let model: String?
}
