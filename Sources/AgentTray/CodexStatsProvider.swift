import Foundation

struct CodexStatsProvider: AgentStatsProvider {
    private let sessionScanner: CodexSessionScanner

    init(sessionScanner: CodexSessionScanner = CodexSessionScanner()) {
        self.sessionScanner = sessionScanner
    }

    func snapshot(for profile: AgentProfile) async -> AgentSnapshot {
        let localActivity = sessionScanner.scan(for: profile)
        guard profile.supportsQuota else {
            return AgentSnapshot(
                profileID: profile.id,
                fetchedAt: Date(),
                quotaWindows: [],
                activity: localActivity,
                planName: externalProviderName(for: profile),
                creditBalance: nil,
                health: .healthy,
                sourceNote: "Codex local activity"
            )
        }
        guard let executable = profile.executableURL else {
            return AgentSnapshot(
                profileID: profile.id,
                fetchedAt: Date(),
                quotaWindows: [],
                activity: localActivity,
                planName: nil,
                creditBalance: nil,
                health: .partial("Codex CLI was not found."),
                sourceNote: "Local Codex sessions"
            )
        }

        do {
            let result = try await ProcessRunner.run(
                executable: executable,
                arguments: arguments(for: profile),
                standardInput: requestPayload(),
                environment: ProcessInfo.processInfo.environment,
                inputCloseDelay: 2.0,
                timeout: 7
            )

            if result.timedOut {
                return partial(profile: profile, activity: localActivity, message: "Codex quota timed out.")
            }

            let responses = Self.decodeResponses(result.standardOutput)
            let rateLimits = responses.rateLimits
            let usage = responses.usage
            var activity = localActivity

            if let usage {
                let buckets = usage.dailyUsageBuckets ?? []
                activity.tokensToday = Self.tokens(inLastDays: 1, buckets: buckets)
                activity.tokensSevenDays = Self.tokens(inLastDays: 7, buckets: buckets)
                activity.lifetimeTokens = usage.summary.lifetimeTokens
            }

            let windows = Self.quotaWindows(from: rateLimits)
            let historical = rateLimits?.rateLimits
            let health: ProviderHealth
            if rateLimits == nil && usage == nil {
                health = .partial("Quota is unavailable for this profile. Local activity is still shown.")
            } else {
                health = .healthy
            }

            return AgentSnapshot(
                profileID: profile.id,
                fetchedAt: Date(),
                quotaWindows: windows,
                activity: activity,
                planName: historical?.planType?.displayName,
                creditBalance: historical?.credits?.balance,
                health: health,
                sourceNote: usage == nil ? "Codex local activity" : "Codex app server and local sessions"
            )
        } catch {
            return partial(profile: profile, activity: localActivity, message: "Quota is unavailable for this profile. Local activity is still shown.")
        }
    }

    private func externalProviderName(for profile: AgentProfile) -> String {
        switch profile.codexSelection {
        case .modelProvider(let provider): return provider.capitalized
        case .namedProfile(let name): return name.capitalized
        default: return "External provider"
        }
    }

    private func partial(profile: AgentProfile, activity: ActivitySummary, message: String) -> AgentSnapshot {
        AgentSnapshot(
            profileID: profile.id,
            fetchedAt: Date(),
            quotaWindows: [],
            activity: activity,
            planName: nil,
            creditBalance: nil,
            health: .partial(message),
            sourceNote: "Codex local sessions"
        )
    }

    private func arguments(for profile: AgentProfile) -> [String] {
        switch profile.codexSelection {
        case .namedProfile(let name):
            return ["--profile", name, "app-server", "--stdio"]
        case .modelProvider(let provider):
            let escaped = provider.replacingOccurrences(of: "\"", with: "\\\"")
            return ["-c", "model_provider=\"\(escaped)\"", "app-server", "--stdio"]
        default:
            return ["app-server", "--stdio"]
        }
    }

    private func requestPayload() -> Data {
        let lines = [
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"agent-tray","version":"0.1.0"},"capabilities":{"experimentalApi":true}}}"#,
            #"{"method":"initialized","params":{}}"#,
            #"{"id":2,"method":"account/rateLimits/read","params":null}"#,
            #"{"id":3,"method":"account/usage/read","params":null}"#
        ]
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    static func decodeResponses(_ data: Data) -> (rateLimits: CodexRateLimitsResponse?, usage: CodexUsageResponse?) {
        guard let output = String(data: data, encoding: .utf8) else { return (nil, nil) }
        let decoder = JSONDecoder()
        var rateLimits: CodexRateLimitsResponse?
        var usage: CodexUsageResponse?

        for line in output.split(whereSeparator: \.isNewline) {
            guard let lineData = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let id = (object["id"] as? NSNumber)?.intValue,
                  let result = object["result"],
                  JSONSerialization.isValidJSONObject(result),
                  let resultData = try? JSONSerialization.data(withJSONObject: result)
            else { continue }

            if id == 2 {
                rateLimits = try? decoder.decode(CodexRateLimitsResponse.self, from: resultData)
            } else if id == 3 {
                usage = try? decoder.decode(CodexUsageResponse.self, from: resultData)
            }
        }
        return (rateLimits, usage)
    }

    static func quotaWindows(from response: CodexRateLimitsResponse?) -> [QuotaWindow] {
        guard let response else { return [] }
        let snapshots: [(String, CodexRateLimitSnapshot)]
        if let buckets = response.rateLimitsByLimitId, !buckets.isEmpty {
            snapshots = buckets.sorted(by: { $0.key < $1.key })
        } else {
            snapshots = [(response.rateLimits.limitID ?? "codex", response.rateLimits)]
        }

        return snapshots.flatMap { id, snapshot -> [QuotaWindow] in
            let baseName = snapshot.limitName
            return [("primary", snapshot.primary), ("secondary", snapshot.secondary)].compactMap { suffix, window in
                guard let window else { return nil }
                let duration = durationLabel(minutes: window.windowDurationMins)
                let label = [baseName, duration].compactMap { $0 }.joined(separator: " ")
                return QuotaWindow(
                    id: "\(id)-\(suffix)",
                    label: label.isEmpty ? "Usage" : label,
                    usedPercent: min(max(window.usedPercent, 0), 100),
                    resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    durationMinutes: window.windowDurationMins
                )
            }
        }
    }

    private static func durationLabel(minutes: Int?) -> String? {
        guard let minutes else { return nil }
        switch minutes {
        case 300: return "5-hour"
        case 1_440: return "Daily"
        case 10_080: return "Weekly"
        case let value where value % 1_440 == 0: return "\(value / 1_440)-day"
        case let value where value % 60 == 0: return "\(value / 60)-hour"
        default: return "\(minutes)-minute"
        }
    }

    private static func tokens(inLastDays days: Int, buckets: [CodexDailyBucket]) -> Int64 {
        let calendar = Calendar.current
        let threshold = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -(days - 1), to: Date()) ?? Date())
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return buckets.reduce(0) { total, bucket in
            guard let date = formatter.date(from: bucket.startDate), date >= threshold else { return total }
            return total + bucket.tokens
        }
    }
}

struct CodexRateLimitsResponse: Decodable {
    let rateLimits: CodexRateLimitSnapshot
    let rateLimitsByLimitId: [String: CodexRateLimitSnapshot]?
}

struct CodexRateLimitSnapshot: Decodable {
    let limitID: String?
    let limitName: String?
    let primary: CodexRateLimitWindow?
    let secondary: CodexRateLimitWindow?
    let credits: CodexCredits?
    let planType: String?

    enum CodingKeys: String, CodingKey {
        case limitID = "limitId"
        case limitName, primary, secondary, credits, planType
    }
}

struct CodexRateLimitWindow: Decodable {
    let usedPercent: Int
    let windowDurationMins: Int?
    let resetsAt: Int64?
}

struct CodexCredits: Decodable {
    let balance: String?
}

struct CodexUsageResponse: Decodable {
    let summary: CodexUsageSummary
    let dailyUsageBuckets: [CodexDailyBucket]?
}

struct CodexUsageSummary: Decodable {
    let lifetimeTokens: Int64?
}

struct CodexDailyBucket: Decodable {
    let startDate: String
    let tokens: Int64
}

private extension String {
    var displayName: String {
        replacingOccurrences(of: "_", with: " ").capitalized
    }
}

struct CodexSessionScanner {
    let fileManager: FileManager
    let homeDirectory: URL
    let environment: [String: String]

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.environment = environment
    }

    func scan(for profile: AgentProfile) -> ActivitySummary {
        let codexHome = environment["CODEX_HOME"].map(URL.init(fileURLWithPath:))
            ?? homeDirectory.appendingPathComponent(".codex")
        let sessionsURL = codexHome.appendingPathComponent("sessions")
        guard let enumerator = fileManager.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return .empty }

        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        var sessionCount = 0
        var lastActivity: Date?
        var latestModel: String?
        var tokensToday: Int64 = 0
        var tokensSevenDays: Int64 = 0
        var foundTokenData = false

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate,
                  modified >= cutoff,
                  let handle = try? FileHandle(forReadingFrom: fileURL)
            else { continue }
            defer { try? handle.close() }

            let prefix = (try? handle.read(upToCount: 131_072)) ?? Data()
            guard let text = String(data: prefix, encoding: .utf8), matches(profile: profile, text: text) else { continue }
            sessionCount += 1
            if lastActivity == nil || modified > lastActivity! {
                lastActivity = modified
                latestModel = Self.firstStringValue(named: "model", in: text)
            }

            if !profile.supportsQuota,
               let fullData = try? Data(contentsOf: fileURL),
               let fullText = String(data: fullData, encoding: .utf8) {
                let totals = Self.localTokenTotals(in: fullText)
                tokensToday += totals.today
                tokensSevenDays += totals.sevenDays
                foundTokenData = foundTokenData || totals.found
            }
        }

        return ActivitySummary(
            tokensToday: foundTokenData ? tokensToday : nil,
            tokensSevenDays: foundTokenData ? tokensSevenDays : nil,
            recentSessions: sessionCount,
            lastActivity: lastActivity,
            model: latestModel,
            lifetimeTokens: nil
        )
    }

    private func matches(profile: AgentProfile, text: String) -> Bool {
        let expectedProvider: String?
        switch profile.codexSelection {
        case .modelProvider(let provider):
            expectedProvider = provider
        case .namedProfile(let name):
            let codexHome = environment["CODEX_HOME"].map(URL.init(fileURLWithPath:))
                ?? homeDirectory.appendingPathComponent(".codex")
            expectedProvider = ProfileCatalog.topLevelModelProvider(
                in: codexHome.appendingPathComponent("\(name).config.toml")
            )
        default:
            expectedProvider = "openai"
        }

        guard let expectedProvider else { return true }
        return Self.firstStringValue(named: "model_provider", in: text)?.caseInsensitiveCompare(expectedProvider) == .orderedSame
    }

    private static func firstStringValue(named key: String, in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline).prefix(20) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = object["payload"] as? [String: Any]
            else { continue }
            if let value = payload[key] as? String { return value }
        }
        return nil
    }

    static func localTokenTotals(in text: String, now: Date = Date()) -> (today: Int64, sevenDays: Int64, found: Bool) {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let sevenDayStart = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
        var previousCumulative: Int64 = 0
        var today: Int64 = 0
        var sevenDays: Int64 = 0
        var found = false

        for line in text.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let cumulative = info["total_token_usage"] as? [String: Any],
                  let total = (cumulative["total_tokens"] as? NSNumber)?.int64Value,
                  let timestampText = object["timestamp"] as? String,
                  let timestamp = parseISO8601(timestampText)
            else { continue }

            found = true
            let delta = total >= previousCumulative ? total - previousCumulative : total
            previousCumulative = total
            if timestamp >= sevenDayStart { sevenDays += delta }
            if timestamp >= todayStart { today += delta }
        }

        return (today, sevenDays, found)
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}
