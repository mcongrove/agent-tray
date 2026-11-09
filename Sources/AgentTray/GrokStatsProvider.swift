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
        let parsed = (try? String(contentsOf: logURL, encoding: .utf8)).map { Self.parseLog($0) }
        let activity = parsed.map(Self.activity(from:)) ?? .empty

        if environment["XAI_API_KEY"]?.isEmpty == false {
            return AgentSnapshot(
                profileID: profile.id,
                fetchedAt: Date(),
                quotaWindows: [],
                activity: activity,
                planName: parsed?.subscriptionTier,
                creditBalance: nil,
                health: .partial("Grok API-key sessions don't report plan limits."),
                sourceNote: "Grok local activity"
            )
        }

        if let token = Self.accessToken(in: Self.authData(grokHome: grokHome, environment: environment) ?? Data()) {
            do {
                let windows = Self.quotaWindows(fromBilling: try await Self.fetchBilling(token: token))
                if !windows.isEmpty {
                    return AgentSnapshot(
                        profileID: profile.id,
                        fetchedAt: Date(),
                        quotaWindows: windows,
                        activity: activity,
                        planName: parsed?.subscriptionTier,
                        creditBalance: nil,
                        health: .healthy,
                        sourceNote: "Grok account billing"
                    )
                }
            } catch {
                if parsed == nil {
                    return .unavailable(profileID: profile.id, message: "Grok quota is unavailable.")
                }
            }
        }

        guard let parsed else {
            return .unavailable(profileID: profile.id, message: "Sign in with the Grok CLI to load plan limits.")
        }

        let quota = Self.logQuota(from: parsed)
        let health: ProviderHealth = quota.isEmpty
            ? .partial("Grok quota has not appeared in the local telemetry yet.")
            : .healthy

        return AgentSnapshot(
            profileID: profile.id,
            fetchedAt: Date(),
            quotaWindows: quota,
            activity: activity,
            planName: parsed.subscriptionTier,
            creditBalance: nil,
            health: health,
            sourceNote: "Estimated from Grok local telemetry"
        )
    }

    static func accessToken(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let keys = [
            "https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828",
            "https://accounts.x.ai/sign-in",
        ]
        for key in keys {
            guard let entry = object[key] as? [String: Any], entry["auth_mode"] as? String != "api_key",
                  let token = entry["key"] as? String, !token.isEmpty else { continue }
            return token
        }
        return nil
    }

    static func quotaWindows(fromBilling data: Data) -> [QuotaWindow] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = object["config"] as? [String: Any],
              let percent = (config["creditUsagePercent"] as? NSNumber)?.doubleValue
        else { return [] }

        let period = config["currentPeriod"] as? [String: Any]
        let start = (period?["start"] as? String).flatMap(Self.parseDate)
        let end = (period?["end"] as? String).flatMap(Self.parseDate)
        let (label, minutes) = Self.billingWindow(start: start, end: end)
        return [QuotaWindow(
            id: "grok-billing-period",
            label: label,
            usedPercent: clampedPercent(percent),
            resetsAt: end,
            durationMinutes: minutes
        )]
    }

    private static func authData(grokHome: URL, environment: [String: String]) -> Data? {
        if let inline = environment["GROK_AUTH"], !inline.isEmpty { return Data(inline.utf8) }
        return try? Data(contentsOf: grokHome.appendingPathComponent("auth.json"))
    }

    private static func activity(from parsed: GrokLogSummary) -> ActivitySummary {
        ActivitySummary(
            tokensToday: parsed.tokensToday,
            tokensSevenDays: parsed.tokensSevenDays,
            recentSessions: parsed.recentSessions,
            lastActivity: parsed.lastActivity,
            model: parsed.model,
            lifetimeTokens: nil
        )
    }

    private static func logQuota(from parsed: GrokLogSummary) -> [QuotaWindow] {
        guard let percent = parsed.creditUsagePercent else { return [] }
        return [QuotaWindow(
            id: "grok-billing-period",
            label: "Billing period",
            usedPercent: clampedPercent(percent),
            resetsAt: parsed.billingPeriodEnd,
            durationMinutes: nil
        )]
    }

    private static func billingWindow(start: Date?, end: Date?) -> (String, Int?) {
        guard let start, let end else { return ("Billing period", nil) }
        let days = end.timeIntervalSince(start) / 86_400
        if abs(days - 7) < 0.5 { return ("Weekly", 10_080) }
        if abs(days - 1) < 0.1 { return ("Daily", 1_440) }
        return ("Billing period", nil)
    }

    private static func clampedPercent(_ value: Double) -> Int {
        min(max(Int(value.rounded()), 0), 100)
    }

    private static func fetchBilling(token: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!)
        request.timeoutInterval = 8
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
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
