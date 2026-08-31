import Foundation

struct CursorStatsProvider: AgentStatsProvider {
    let homeDirectory: URL
    let fileManager: FileManager

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
    }

    func snapshot(for profile: AgentProfile) async -> AgentSnapshot {
        let activity = Self.parseLocalActivity(Self.loadLocalActivityRows(homeDirectory: homeDirectory))
        guard let session = Self.readSession(homeDirectory: homeDirectory) else {
            return AgentSnapshot(
                profileID: profile.id,
                fetchedAt: Date(),
                quotaWindows: [],
                activity: activity,
                planName: nil,
                creditBalance: nil,
                health: .partial("Sign in to Cursor to load plan limits. Local activity is still shown."),
                sourceNote: "Cursor local activity"
            )
        }

        do {
            let token = try await Self.validAccessToken(session: session)
            async let usageData = Self.postDashboard("GetCurrentPeriodUsage", token: token)
            async let planData = Self.postDashboard("GetPlanInfo", token: token)
            async let eventsData = Self.postDashboard("GetAggregatedUsageEvents", token: token)

            let usage = Self.decodePeriodUsage((try? await usageData) ?? Data())
            let plan = Self.decodePlanInfo((try? await planData) ?? Data())
            let events = Self.decodeAggregatedEvents((try? await eventsData) ?? Data())

            var merged = activity
            if let events {
                merged.lifetimeTokens = events.totalTokens
                if merged.model == nil { merged.model = events.topModel }
            }

            let windows = Self.quotaWindows(from: usage)
            let health: ProviderHealth = usage == nil
                ? .partial("Cursor quota is unavailable. Local activity is still shown.")
                : .healthy

            return AgentSnapshot(
                profileID: profile.id,
                fetchedAt: Date(),
                quotaWindows: windows,
                activity: merged,
                planName: plan?.planName ?? session.membershipType?.capitalized,
                creditBalance: plan?.price,
                health: health,
                sourceNote: usage == nil ? "Cursor local activity" : ""
            )
        } catch {
            return AgentSnapshot(
                profileID: profile.id,
                fetchedAt: Date(),
                quotaWindows: [],
                activity: activity,
                planName: session.membershipType?.capitalized,
                creditBalance: nil,
                health: .partial("Cursor quota is unavailable. Local activity is still shown."),
                sourceNote: "Cursor local activity"
            )
        }
    }

    static func decodePeriodUsage(_ data: Data) -> CursorPeriodUsage? {
        try? JSONDecoder().decode(CursorPeriodUsage.self, from: data)
    }

    static func decodePlanInfo(_ data: Data) -> CursorPlanInfo? {
        try? JSONDecoder().decode(CursorPlanInfoResponse.self, from: data).planInfo
    }

    static func decodeAggregatedEvents(_ data: Data) -> CursorAggregatedEvents? {
        try? JSONDecoder().decode(CursorAggregatedEvents.self, from: data)
    }

    static func quotaWindows(from usage: CursorPeriodUsage?) -> [QuotaWindow] {
        guard let usage else { return [] }
        let reset = usage.billingCycleEnd?.date
        var windows: [QuotaWindow] = []

        if let auto = usage.planUsage?.autoPercentUsed {
            windows.append(QuotaWindow(
                id: "cursor-auto",
                label: "Cursor models",
                usedPercent: Self.clampedPercent(auto),
                resetsAt: reset,
                durationMinutes: usage.cycleMinutes
            ))
        }
        if let api = usage.planUsage?.apiPercentUsed {
            windows.append(QuotaWindow(
                id: "cursor-api",
                label: "Other models",
                usedPercent: Self.clampedPercent(api),
                resetsAt: reset,
                durationMinutes: usage.cycleMinutes
            ))
        }
        if let onDemand = usage.spendLimitUsage?.onDemandWindow(reset: reset, cycleMinutes: usage.cycleMinutes) {
            windows.append(onDemand)
        }
        if windows.isEmpty, let total = usage.planUsage?.totalPercentUsed {
            windows.append(QuotaWindow(
                id: "cursor-total",
                label: "Plan",
                usedPercent: Self.clampedPercent(total),
                resetsAt: reset,
                durationMinutes: usage.cycleMinutes
            ))
        }
        return windows
    }

    static func parseLocalActivity(_ rows: [CursorLocalActivityRow], now: Date = Date()) -> ActivitySummary {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let sevenDayCutoff = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        var sessions = Set<String>()
        var lastActivity: Date?
        var model: String?

        for row in rows {
            let date = Date(timeIntervalSince1970: TimeInterval(row.createdAt) / 1_000)
            guard date >= sevenDayCutoff else { continue }
            if !row.conversationID.isEmpty { sessions.insert(row.conversationID) }
            if lastActivity == nil || date > lastActivity! {
                lastActivity = date
                if !row.model.isEmpty { model = row.model }
            }
        }

        return ActivitySummary(
            tokensToday: nil,
            tokensSevenDays: nil,
            recentSessions: sessions.count,
            lastActivity: lastActivity,
            model: model,
            lifetimeTokens: nil
        )
    }

    static func loadLocalActivityRows(homeDirectory: URL) -> [CursorLocalActivityRow] {
        let db = homeDirectory.appendingPathComponent(".cursor/ai-tracking/ai-code-tracking.db")
        guard FileManager.default.fileExists(atPath: db.path) else { return [] }
        let cutoff = Int64(Date().addingTimeInterval(-7 * 24 * 60 * 60).timeIntervalSince1970 * 1_000)
        let sql = """
        SELECT createdAt, IFNULL(model,''), IFNULL(conversationId,''), source
        FROM ai_code_hashes
        WHERE source != 'human' AND createdAt >= \(cutoff);
        """
        return sqliteQuery(db: db, sql: sql).compactMap { line in
            let cols = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 3, let createdAt = Int64(cols[0]) else { return nil }
            return CursorLocalActivityRow(
                createdAt: createdAt,
                model: cols[1],
                conversationID: cols[2]
            )
        }
    }

    private static func readSession(homeDirectory: URL) -> CursorSession? {
        let db = homeDirectory
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        guard FileManager.default.fileExists(atPath: db.path) else { return nil }
        let access = sqliteValue(db: db, key: "cursorAuth/accessToken")
        let refresh = sqliteValue(db: db, key: "cursorAuth/refreshToken")
        guard access != nil || refresh != nil else { return nil }
        return CursorSession(
            accessToken: access,
            refreshToken: refresh,
            membershipType: sqliteValue(db: db, key: "cursorAuth/stripeMembershipType")
        )
    }

    private static func validAccessToken(session: CursorSession) async throws -> String {
        if let token = session.accessToken, !Self.jwtIsExpired(token) {
            return token
        }
        guard let refresh = session.refreshToken, !refresh.isEmpty else {
            throw CursorProviderError.notSignedIn
        }
        return try await refreshAccessToken(refresh)
    }

    private static func jwtIsExpired(_ token: String, now: Date = Date()) -> Bool {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return true }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = payload.count % 4
        if pad != 0 { payload += String(repeating: "=", count: 4 - pad) }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = (object["exp"] as? NSNumber)?.doubleValue
        else { return true }
        return Date(timeIntervalSince1970: exp).timeIntervalSince(now) < 60
    }

    private static let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: nil, delegateQueue: OperationQueue())
    }()

    private static func refreshAccessToken(_ refreshToken: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api2.cursor.sh/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 8
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "client_id": "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB",
            "refresh_token": refreshToken
        ])
        let data = try await send(request)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["shouldLogout"] as? Bool != true,
              let token = object["access_token"] as? String,
              !token.isEmpty
        else { throw CursorProviderError.notSignedIn }
        return token
    }

    private static func postDashboard(_ method: String, token: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/\(method)")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 8
        return try await send(request)
    }

    private static func send(_ request: URLRequest) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let gate = RequestGate()
            let task = urlSession.dataTask(with: request) { data, response, error in
                if error != nil {
                    gate.finish(.failure(CursorProviderError.requestFailed), continuation)
                    return
                }
                guard let data,
                      let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode)
                else {
                    gate.finish(.failure(CursorProviderError.requestFailed), continuation)
                    return
                }
                gate.finish(.success(data), continuation)
            }
            task.resume()
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
                task.cancel()
                gate.finish(.failure(CursorProviderError.requestFailed), continuation)
            }
        }
    }

    private static func sqliteValue(db: URL, key: String) -> String? {
        let escaped = key.replacingOccurrences(of: "'", with: "''")
        return sqliteQuery(db: db, sql: "SELECT value FROM ItemTable WHERE key = '\(escaped)' LIMIT 1;")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private static func sqliteQuery(db: URL, sql: String) -> [String] {
        let encodedPath = db.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? db.path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", "file:\(encodedPath)?mode=ro&immutable=1", sql]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }

        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            return []
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
    }

    static func clampedPercent(_ value: Double) -> Int {
        min(max(Int(value.rounded()), 0), 100)
    }

    static func usd(_ cents: Double) -> String {
        let dollars = cents / 100
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = dollars.rounded() == dollars ? 0 : 2
        formatter.minimumFractionDigits = dollars.rounded() == dollars ? 0 : 2
        return formatter.string(from: NSNumber(value: dollars)) ?? "$\(dollars)"
    }
}

struct CursorLocalActivityRow: Equatable {
    let createdAt: Int64
    let model: String
    let conversationID: String
}

struct CursorPeriodUsage: Decodable {
    let billingCycleStart: CursorMillisDate?
    let billingCycleEnd: CursorMillisDate?
    let planUsage: CursorPlanUsage?
    let spendLimitUsage: CursorSpendLimitUsage?

    var cycleMinutes: Int? {
        guard let start = billingCycleStart?.date, let end = billingCycleEnd?.date else { return nil }
        return Int(end.timeIntervalSince(start) / 60)
    }
}

struct CursorPlanUsage: Decodable {
    let totalSpend: FlexibleNumber?
    let includedSpend: FlexibleNumber?
    let bonusSpend: FlexibleNumber?
    let remaining: FlexibleNumber?
    let limit: FlexibleNumber?
    let autoPercentUsed: Double?
    let apiPercentUsed: Double?
    let totalPercentUsed: Double?

    var includedPercent: Int? {
        guard let limit = limit?.value, limit > 0 else { return nil }
        return CursorStatsProvider.clampedPercent(((includedSpend?.value ?? 0) / limit) * 100)
    }
}

struct CursorSpendLimitUsage: Decodable {
    let individualLimit: FlexibleNumber?
    let individualRemaining: FlexibleNumber?
    let individualUsed: FlexibleNumber?

    func onDemandWindow(reset: Date?, cycleMinutes: Int?) -> QuotaWindow? {
        guard let limit = individualLimit?.value, limit > 0 else { return nil }
        let used = individualUsed?.value ?? max(limit - (individualRemaining?.value ?? limit), 0)
        return QuotaWindow(
            id: "cursor-ondemand",
            label: "On-demand",
            usedPercent: CursorStatsProvider.clampedPercent((used / limit) * 100),
            resetsAt: reset,
            durationMinutes: cycleMinutes,
            detail: "\(CursorStatsProvider.usd(used)) / \(CursorStatsProvider.usd(limit))"
        )
    }
}

struct CursorPlanInfoResponse: Decodable {
    let planInfo: CursorPlanInfo?
}

struct CursorPlanInfo: Decodable {
    let planName: String?
    let price: String?
}

struct CursorAggregatedEvents: Decodable {
    let aggregations: [CursorModelAggregation]?
    let totalInputTokens: FlexibleNumber?
    let totalOutputTokens: FlexibleNumber?

    var totalTokens: Int64? {
        let input = totalInputTokens?.int64 ?? 0
        let output = totalOutputTokens?.int64 ?? 0
        let total = input + output
        return total > 0 ? total : nil
    }

    var topModel: String? {
        aggregations?.max(by: { ($0.totalCents ?? 0) < ($1.totalCents ?? 0) })?.modelIntent
    }
}

struct CursorModelAggregation: Decodable {
    let modelIntent: String?
    let totalCents: Double?
}

struct CursorMillisDate: Decodable {
    let date: Date

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            date = Date(timeIntervalSince1970: value / 1_000)
            return
        }
        if let text = try? container.decode(String.self), let value = Double(text) {
            date = Date(timeIntervalSince1970: value / 1_000)
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported Cursor timestamp")
    }
}

struct FlexibleNumber: Decodable {
    let value: Double

    var int64: Int64 { Int64(value.rounded()) }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self.value = value
            return
        }
        if let text = try? container.decode(String.self), let value = Double(text) {
            self.value = value
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported number")
    }
}

private struct CursorSession {
    let accessToken: String?
    let refreshToken: String?
    let membershipType: String?
}

private enum CursorProviderError: Error {
    case notSignedIn
    case requestFailed
}

private final class RequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func finish(_ result: Result<Data, Error>, _ continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        continuation.resume(with: result)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
