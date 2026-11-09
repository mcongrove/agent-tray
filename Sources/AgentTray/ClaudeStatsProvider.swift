import CommonCrypto
import Foundation
import Security

struct ClaudeStatsProvider: AgentStatsProvider {
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
        if let executable = profile.executableURL {
            switch await Self.cliAuth(executable) {
            case .loggedIn:
                if let payload = await Self.usageFromCLI(executable),
                   let decoded = Self.decodeUsage(payload) {
                    return Self.makeSnapshot(profileID: profile.id, decoded: decoded, sourceNote: "Claude Code usage")
                }
                return .unavailable(profileID: profile.id, message: "Claude quota is unavailable.")
            case .loggedOut, .unknown:
                break
            }
        }

        if let session = Self.readSession(homeDirectory: homeDirectory, environment: environment) {
            if let expiresAt = session.expiresAt, expiresAt.timeIntervalSinceNow < 60 {
                return .unavailable(profileID: profile.id, message: "Claude sign-in expired. Open Claude to refresh.")
            }
            if let payload = try? await Self.fetchOAuthUsage(token: session.accessToken, userAgent: Self.userAgent(homeDirectory: homeDirectory)),
               let decoded = Self.decodeUsage(payload) {
                var snapshot = Self.makeSnapshot(profileID: profile.id, decoded: decoded, sourceNote: "Claude plan usage")
                if snapshot.planName == nil { snapshot.planName = session.subscriptionType?.capitalized }
                return snapshot
            }
            return .unavailable(profileID: profile.id, message: "Claude quota is unavailable.")
        }

        return .unavailable(profileID: profile.id, message: "Sign in to Claude to load plan limits.")
    }

    static func decodeUsage(_ data: Data) -> ClaudeUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let plan = (object["subscription_type"] as? String)?.nilIfEmpty
        if let available = object["rate_limits_available"] as? Bool {
            guard available, let limits = object["rate_limits"] as? [String: Any] else {
                return ClaudeUsage(windows: [], planName: plan)
            }
            return ClaudeUsage(windows: quotaWindows(from: limits), planName: plan)
        }
        if object["limits"] != nil || object["five_hour"] != nil || object["seven_day"] != nil {
            return ClaudeUsage(windows: quotaWindows(from: object), planName: plan)
        }
        return nil
    }

    static func quotaWindows(from limits: [String: Any]) -> [QuotaWindow] {
        if let rows = limits["limits"] as? [[String: Any]], !rows.isEmpty {
            return rows.compactMap(window(fromLimit:))
        }

        var windows: [QuotaWindow] = []
        if let window = legacyWindow(limits["five_hour"], id: "claude-five-hour", label: "5-hour", minutes: 300) {
            windows.append(window)
        }
        if let window = legacyWindow(limits["seven_day"], id: "claude-weekly", label: "Weekly", minutes: 10_080) {
            windows.append(window)
        }
        for row in limits["model_scoped"] as? [[String: Any]] ?? [] {
            guard let name = (row["display_name"] as? String)?.nilIfEmpty,
                  let window = legacyWindow(row, id: "claude-model-\(name.lowercased())", label: name, minutes: nil)
            else { continue }
            windows.append(window)
        }
        return windows
    }

    static func selectDesktopToken(entries: [String: Any], now: Date = Date()) -> (token: String, subscription: String?)? {
        let cutoff = now.timeIntervalSince1970 * 1_000 + 60_000
        struct Candidate {
            var valid: Bool
            var rank: Int
            var expires: Double
            var token: String
            var subscription: String?
        }
        var best: Candidate?
        for (key, value) in entries {
            guard let entry = value as? [String: Any],
                  let token = (entry["token"] as? String)?.nilIfEmpty else { continue }
            let expires = (entry["expiresAt"] as? NSNumber)?.doubleValue ?? 0
            var rank = 0
            if key.contains("claude_code") { rank += 2 }
            if key.contains("user:inference") { rank += 1 }
            let candidate = Candidate(
                valid: expires == 0 || expires > cutoff,
                rank: rank,
                expires: expires,
                token: token,
                subscription: entry["subscriptionType"] as? String
            )
            let better = best.map { current in
                if candidate.valid != current.valid { return candidate.valid }
                if candidate.rank != current.rank { return candidate.rank > current.rank }
                return candidate.expires > current.expires
            } ?? true
            if better { best = candidate }
        }
        return best.map { ($0.token, $0.subscription) }
    }

    private static func makeSnapshot(profileID: String, decoded: ClaudeUsage, sourceNote: String) -> AgentSnapshot {
        let health: ProviderHealth = decoded.windows.isEmpty
            ? .partial("Claude quota is unavailable.")
            : .healthy
        return AgentSnapshot(
            profileID: profileID,
            fetchedAt: Date(),
            quotaWindows: decoded.windows,
            activity: .empty,
            planName: decoded.planName?.capitalized,
            creditBalance: nil,
            health: health,
            sourceNote: decoded.windows.isEmpty ? "No current data" : sourceNote
        )
    }

    private static func window(fromLimit row: [String: Any]) -> QuotaWindow? {
        guard let kind = row["kind"] as? String, let percent = (row["percent"] as? NSNumber)?.doubleValue else { return nil }
        let scope = row["scope"] as? [String: Any]
        let model = ((scope?["model"] as? [String: Any])?["display_name"] as? String)?.nilIfEmpty
        let surface = ((scope?["surface"] as? [String: Any])?["display_name"] as? String)?.nilIfEmpty
        let name = model ?? surface
        let id: String
        let label: String
        let minutes: Int?
        switch kind {
        case "session":
            id = "claude-five-hour"
            label = "5-hour"
            minutes = 300
        case "weekly_all":
            id = "claude-weekly"
            label = "Weekly"
            minutes = 10_080
        case "weekly_scoped":
            guard let name else { return nil }
            id = "claude-model-\(name.lowercased())"
            label = name
            minutes = nil
        default:
            id = "claude-\(kind)"
            label = name ?? kind.replacingOccurrences(of: "_", with: " ").capitalized
            minutes = nil
        }
        return QuotaWindow(
            id: id,
            label: label,
            usedPercent: clampedPercent(percent),
            resetsAt: (row["resets_at"] as? String).flatMap(parseDate),
            durationMinutes: minutes
        )
    }

    private static func legacyWindow(_ value: Any?, id: String, label: String, minutes: Int?) -> QuotaWindow? {
        guard let row = value as? [String: Any], let percent = (row["utilization"] as? NSNumber)?.doubleValue else { return nil }
        return QuotaWindow(
            id: id,
            label: label,
            usedPercent: clampedPercent(percent),
            resetsAt: (row["resets_at"] as? String).flatMap(parseDate),
            durationMinutes: minutes
        )
    }

    private static func clampedPercent(_ value: Double) -> Int {
        min(max(Int(value.rounded()), 0), 100)
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private enum CLIAuth { case loggedIn, loggedOut, unknown }

    private static func cliAuth(_ executable: URL) async -> CLIAuth {
        guard let result = try? await ProcessRunner.run(
            executable: executable,
            arguments: ["auth", "status", "--json"],
            timeout: 8
        ), let object = try? JSONSerialization.jsonObject(with: result.standardOutput) as? [String: Any],
              let loggedIn = object["loggedIn"] as? Bool
        else { return .unknown }
        return loggedIn ? .loggedIn : .loggedOut
    }

    private static func usageFromCLI(_ executable: URL) async -> Data? {
        let arguments = [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--no-session-persistence", "--safe-mode", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
        ]
        guard let result = try? await ProcessRunner.runJSONRPC(
            executable: executable,
            arguments: arguments,
            exchanges: [
                JSONRPCExchange(
                    line: #"{"type":"control_request","request_id":"init","request":{"subtype":"initialize"}}"#,
                    waitForRequestID: "init"
                ),
                JSONRPCExchange(
                    line: #"{"type":"control_request","request_id":"usage","request":{"subtype":"get_usage","skip_behaviors":true}}"#,
                    waitForRequestID: "usage"
                ),
            ],
            timeout: 10
        ) else { return nil }
        return usagePayload(from: result.standardOutput)
    }

    static func usagePayload(from output: Data) -> Data? {
        guard let text = String(data: output, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "control_response",
                  let response = object["response"] as? [String: Any],
                  response["request_id"] as? String == "usage",
                  let payload = response["response"],
                  JSONSerialization.isValidJSONObject(payload),
                  let encoded = try? JSONSerialization.data(withJSONObject: payload)
            else { continue }
            return encoded
        }
        return nil
    }

    private struct ClaudeSession {
        var accessToken: String
        var expiresAt: Date?
        var subscriptionType: String?
    }

    private static func readSession(homeDirectory: URL, environment: [String: String]) -> ClaudeSession? {
        let home = environment["CLAUDE_CONFIG_DIR"].map(URL.init(fileURLWithPath:))
            ?? homeDirectory.appendingPathComponent(".claude")
        if let data = try? Data(contentsOf: home.appendingPathComponent(".credentials.json")),
           let session = session(fromCredentials: data) {
            return session
        }
        if let data = keychainPassword(service: "Claude Code-credentials", account: NSUserName()),
           let session = session(fromCredentials: Data(data.utf8)) {
            return session
        }
        return desktopSession(homeDirectory: homeDirectory)
    }

    private static func session(fromCredentials data: Data) -> ClaudeSession? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let oauth = (object["claudeAiOauth"] as? [String: Any]) ?? object
        guard let token = (oauth["accessToken"] as? String)?.nilIfEmpty else { return nil }
        let expires = (oauth["expiresAt"] as? NSNumber)?.doubleValue
        return ClaudeSession(
            accessToken: token,
            expiresAt: expires.map { Date(timeIntervalSince1970: $0 / 1_000) },
            subscriptionType: oauth["subscriptionType"] as? String
        )
    }

    private static func desktopSession(homeDirectory: URL) -> ClaudeSession? {
        let url = homeDirectory.appendingPathComponent("Library/Application Support/Claude/config.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let encoded = root["oauth:tokenCacheV2"] as? String,
              let blob = Data(base64Encoded: encoded),
              let password = keychainPassword(service: "Claude Safe Storage", account: "Claude Key"),
              let plain = decryptSafeStorage(blob, password: password),
              let entries = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
              let selected = selectDesktopToken(entries: entries)
        else { return nil }
        return ClaudeSession(accessToken: selected.token, expiresAt: nil, subscriptionType: selected.subscription)
    }

    private static func userAgent(homeDirectory: URL) -> String {
        let root = homeDirectory.appendingPathComponent("Library/Application Support/Claude/claude-code")
        let version = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
            .map(\.lastPathComponent)
            .filter { $0.first?.isNumber == true }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .first
        return "claude-code/\(version ?? "2.1.0")"
    }

    private static func fetchOAuthUsage(token: String, userAgent: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 8
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static func keychainPassword(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let password = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !password.isEmpty
        else { return nil }
        return password
    }

    // Electron safeStorage on macOS: "v10" + AES-128-CBC, key from PBKDF2-SHA1("saltysalt", 1003 rounds), IV of 16 spaces.
    private static func decryptSafeStorage(_ blob: Data, password: String) -> Data? {
        guard blob.starts(with: Data("v10".utf8)) else { return nil }
        let ciphertext = blob.dropFirst(3)
        let passwordBytes = Array(password.utf8)
        let salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: 16)
        let derived = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            passwordBytes,
            passwordBytes.count,
            salt,
            salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
            1003,
            &key,
            key.count
        )
        guard derived == kCCSuccess else { return nil }

        var output = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var moved = 0
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        let status = ciphertext.withUnsafeBytes { cipherBytes in
            CCCrypt(
                CCOperation(kCCDecrypt),
                CCAlgorithm(kCCAlgorithmAES),
                CCOptions(kCCOptionPKCS7Padding),
                key,
                key.count,
                iv,
                cipherBytes.baseAddress,
                ciphertext.count,
                &output,
                output.count,
                &moved
            )
        }
        guard status == kCCSuccess else { return nil }
        return Data(output.prefix(moved))
    }
}

struct ClaudeUsage: Equatable {
    var windows: [QuotaWindow]
    var planName: String?
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
