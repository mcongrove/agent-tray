import Foundation

@main
struct AgentTrayTests {
    private static var failures = 0

    static func main() async throws {
        discoversModelProvidersWithoutDuplicates()
        hiddenKindsPersistAndToggle()
        decodesCodexUsageAndRateLimits()
        decodesCurrentCodexRateLimitsPayload()
        try await jsonRPCWaitsForInitializeBeforeNextRequest()
        decodesCursorUsageWindows()
        cursorLocalActivityCountsSessions()
        try grokLogAggregatesNetTokensAndLatestQuota()
        try codexLocalTokenTotalsUseCumulativeDeltas()
        compactCounts()
        try await timeoutReturnsFallback()
        if CommandLine.arguments.contains("--live") {
            await liveProviderProbe()
        }
        guard failures == 0 else {
            fputs("\(failures) checks failed\n", stderr)
            exit(1)
        }
        print("All Agent Tray checks passed")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            failures += 1
            fputs("FAIL: \(message)\n", stderr)
        }
    }

    static func discoversModelProvidersWithoutDuplicates() {
        let config = """
        model = "gpt-5"
        [model_providers.azure]
        name = "Azure"

        [model_providers."custom-edge"]
        name = "Edge"

        [model_providers.azure]
        """

        expect(ProfileCatalog.modelProviderIDs(in: config) == ["azure", "custom-edge"], "provider discovery")
        let locations = ProfileCatalog.wellKnownExecutableLocations(
            named: "codex",
            homeDirectory: URL(fileURLWithPath: "/Users/test")
        )
        expect(
            locations.contains(URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex")),
            "ChatGPT-bundled Codex discovery"
        )
    }

    static func hiddenKindsPersistAndToggle() {
        let suite = "agent-tray.tests.hidden-kinds"
        guard let defaults = UserDefaults(suiteName: suite) else {
            failures += 1
            fputs("FAIL: hidden kinds defaults suite\n", stderr)
            return
        }
        defaults.removePersistentDomain(forName: suite)

        let settings = AppSettings(defaults: defaults)
        expect(!settings.isHidden(.codex) && !settings.isHidden(.cursor) && !settings.isHidden(.grok), "kinds visible by default")
        settings.toggleHidden(.codex)
        expect(settings.isHidden(.codex), "codex hidden after toggle")
        expect(!settings.isHidden(.cursor), "other kinds stay visible")

        let reloaded = AppSettings(defaults: defaults)
        expect(reloaded.isHidden(.codex), "hidden kinds persist")
        expect(reloaded.hiddenKinds == [.codex], "only toggled kind is stored")
        reloaded.toggleHidden(.codex)
        expect(!reloaded.isHidden(.codex), "show restores visibility")
    }

    static func decodesCodexUsageAndRateLimits() {
        let stream = """
        {"id":1,"result":{"userAgent":"test"}}
        {"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":42,"windowDurationMins":10080,"resetsAt":1900000000},"planType":"pro"},"rateLimitsByLimitId":null}}
        {"id":3,"result":{"summary":{"lifetimeTokens":1234},"dailyUsageBuckets":[{"startDate":"2026-08-28","tokens":99}],"threadUsage":null}}
        """

        let result = CodexStatsProvider.decodeResponses(Data(stream.utf8))
        expect(result.rateLimits?.rateLimits.primary?.usedPercent == 42, "Codex quota decoding")
        expect(result.usage?.summary.lifetimeTokens == 1234, "Codex usage decoding")
        expect(CodexStatsProvider.quotaWindows(from: result.rateLimits).first?.label == "Weekly", "Codex window naming")

        let dual = """
        {"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":42,"windowDurationMins":10080},"secondary":{"usedPercent":18,"windowDurationMins":300},"planType":"pro"},"rateLimitsByLimitId":null}}
        """
        let dualLimits = CodexStatsProvider.decodeResponses(Data(dual.utf8)).rateLimits
        let dualWindows = CodexStatsProvider.quotaWindows(from: dualLimits)
        expect(dualWindows.map(\.label) == ["Weekly", "5-hour"], "Codex week and 5-hour windows")
        expect(dualWindows.map(\.usedPercent) == [42, 18], "Codex window percents")
    }

    static func decodesCurrentCodexRateLimitsPayload() {
        let stream = """
        {"id":1,"result":{"userAgent":"agent-tray/0.154.0"}}
        {"method":"remoteControl/status/changed","params":{"status":"disabled"}}
        {"id":2,"result":{"ordinaryUsageAllowed":true,"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":86,"windowDurationMins":300,"resetsAt":1790711924},"secondary":{"usedPercent":28,"windowDurationMins":10080,"resetsAt":1791263412},"credits":{"hasCredits":false,"unlimited":false,"balance":"0"},"planType":"plus"},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":86,"windowDurationMins":300},"secondary":{"usedPercent":28,"windowDurationMins":10080},"planType":"plus"}},"rateLimitResetCredits":{"availableCount":3},"accountId":"abc"}}
        {"id":3,"result":{"summary":{"lifetimeTokens":12},"dailyUsageBuckets":[{"startDate":"2026-09-29","tokens":4}]}}
        """
        let result = CodexStatsProvider.decodeResponses(Data(stream.utf8))
        expect(result.rateLimits?.rateLimits.primary?.usedPercent == 86, "current Codex 5-hour decode")
        expect(result.rateLimits?.rateLimits.secondary?.usedPercent == 28, "current Codex weekly decode")
        expect(result.rateLimits?.rateLimits.credits?.balance == "0", "current Codex credits decode")
        expect(result.usage?.summary.lifetimeTokens == 12, "current Codex usage decode")
        expect(
            CodexStatsProvider.quotaWindows(from: result.rateLimits).map(\.label) == ["5-hour", "Weekly"],
            "current Codex window naming"
        )
    }

    static func jsonRPCWaitsForInitializeBeforeNextRequest() async throws {
        let script = """
        import json, sys
        first = json.loads(sys.stdin.readline())
        if first.get("method") != "initialize":
            raise SystemExit("expected initialize first")
        print(json.dumps({"id": first["id"], "result": {"ok": True}}), flush=True)
        notify = json.loads(sys.stdin.readline())
        if notify.get("method") != "initialized":
            raise SystemExit("expected initialized")
        second = json.loads(sys.stdin.readline())
        print(json.dumps({"id": second["id"], "result": {"pong": second.get("method")}}), flush=True)
        """
        let result = try await ProcessRunner.runJSONRPC(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", script],
            exchanges: [
                JSONRPCExchange(line: #"{"id":1,"method":"initialize","params":{}}"#, waitForID: 1),
                JSONRPCExchange(line: #"{"method":"initialized","params":{}}"#),
                JSONRPCExchange(line: #"{"id":2,"method":"account/rateLimits/read","params":null}"#, waitForID: 2),
            ],
            timeout: 4
        )
        expect(!result.timedOut, "jsonrpc handshake completed")
        let text = String(data: result.standardOutput, encoding: .utf8) ?? ""
        expect(text.contains("\"ok\"") || text.contains("\"ok\": true"), "jsonrpc collected initialize")
        expect(text.contains("account/rateLimits/read"), "jsonrpc collected rate-limit reply")
    }

    static func decodesCursorUsageWindows() {
        let json = """
        {"billingCycleStart":"1768399334000","billingCycleEnd":"1771077734000","planUsage":{"includedSpend":38000,"limit":40000,"autoPercentUsed":21.6,"apiPercentUsed":39.1,"totalPercentUsed":24.2},"spendLimitUsage":{"individualLimit":2000,"individualRemaining":1500}}
        """
        let usage = CursorStatsProvider.decodePeriodUsage(Data(json.utf8))
        let windows = CursorStatsProvider.quotaWindows(from: usage)
        expect(windows.map(\.label) == ["Cursor models", "Other models", "On-demand"], "Cursor window labels")
        expect(windows[0].usedPercent == 22, "Cursor models percent")
        expect(windows[1].usedPercent == 39, "Cursor other-models percent")
        expect(windows[2].detail == "$5 / $20", "Cursor on-demand detail")
    }

    static func cursorLocalActivityCountsSessions() {
        guard let now = ISO8601DateFormatter().date(from: "2026-08-28T14:00:00Z") else {
            failures += 1
            fputs("FAIL: Cursor activity fixture date\n", stderr)
            return
        }
        let rows = [
            CursorLocalActivityRow(createdAt: 1_787_918_400_000, model: "grok-4.6", conversationID: "one"),
            CursorLocalActivityRow(createdAt: 1_787_922_000_000, model: "composer-2.5", conversationID: "two"),
            CursorLocalActivityRow(createdAt: 1_787_227_200_000, model: "old", conversationID: "stale")
        ]
        let activity = CursorStatsProvider.parseLocalActivity(rows, now: now)
        expect(activity.recentSessions == 2, "Cursor recent sessions")
        expect(activity.model == "composer-2.5", "Cursor recent model")
    }

    static func grokLogAggregatesNetTokensAndLatestQuota() throws {
        guard let now = ISO8601DateFormatter().date(from: "2026-08-28T14:00:00Z") else {
            throw TestError.invalidFixtureDate
        }
        let log = """
        {"ts":"2026-08-28T12:00:00.000Z","sid":"one","ctx":{"prompt_tokens":1000,"cached_prompt_tokens":800,"completion_tokens":100,"model":"grok-4.6"}}
        {"ts":"2026-08-28T13:00:00.000Z","sid":"two","ctx":{"prompt_tokens":500,"cached_prompt_tokens":100,"completion_tokens":50}}
        {"ts":"2026-08-28T13:30:00.000Z","ctx":{"config":{"creditUsagePercent":72.5,"billingPeriodEnd":"2026-08-31T10:03:36.000Z"},"subscriptionTier":"SuperGrok"}}
        malformed
        """

        let result = GrokStatsProvider.parseLog(log, now: now)
        expect(result.tokensToday == 750, "Grok daily tokens")
        expect(result.tokensSevenDays == 750, "Grok weekly tokens")
        expect(result.recentSessions == 2, "Grok session count")
        expect(result.creditUsagePercent == 72.5, "Grok quota")
        expect(result.model == "grok-4.6", "Grok model")
    }

    static func timeoutReturnsFallback() async throws {
        let value = await withTimeout(seconds: 0.05, fallback: "fallback") {
            try? await Task.sleep(nanoseconds: 500_000_000)
            return "slow"
        }
        expect(value == "fallback", "timeout fallback")
    }

    static func compactCounts() {
        expect(Int64(999).compactCount == "999", "small count formatting")
        expect(Int64(1_500).compactCount == "1.5K", "thousand count formatting")
        expect(Int64(2_000_000).compactCount == "2M", "million count formatting")
    }

    static func codexLocalTokenTotalsUseCumulativeDeltas() throws {
        guard let now = ISO8601DateFormatter().date(from: "2026-08-28T14:00:00Z") else {
            throw TestError.invalidFixtureDate
        }
        let log = """
        {"timestamp":"2026-08-27T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":100}}}}
        {"timestamp":"2026-08-28T12:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":250}}}}
        {"timestamp":"2026-08-28T13:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":400}}}}
        """

        let totals = CodexSessionScanner.localTokenTotals(in: log, now: now)
        expect(totals.today == 300, "Codex local daily token deltas")
        expect(totals.sevenDays == 400, "Codex local weekly token deltas")
        expect(totals.found, "Codex local token detection")
    }

    static func liveProviderProbe() async {
        let profiles = ProfileCatalog().discover()
        print("Live profiles: \(profiles.map(\.displayName).joined(separator: ", "))")
        for profile in profiles {
            let snapshot: AgentSnapshot
            switch profile.kind {
            case .grok: snapshot = await GrokStatsProvider().snapshot(for: profile)
            case .cursor: snapshot = await CursorStatsProvider().snapshot(for: profile)
            case .codex: snapshot = await CodexStatsProvider().snapshot(for: profile)
            }
            print("\(profile.displayName): quota=\(snapshot.quotaWindows.count), today=\(snapshot.activity.tokensToday.map(String.init) ?? "n/a"), week=\(snapshot.activity.tokensSevenDays.map(String.init) ?? "n/a"), sessions=\(snapshot.activity.recentSessions), health=\(snapshot.health)")
            if profile.id == "codex-default", let executable = profile.executableURL {
                do {
                    let process = try await ProcessRunner.runJSONRPC(
                        executable: executable,
                        arguments: ["app-server", "--stdio"],
                        exchanges: [
                            JSONRPCExchange(
                                line: #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"agent-tray-probe","version":"0.1.0"},"capabilities":{"experimentalApi":true}}}"#,
                                waitForID: 1
                            ),
                            JSONRPCExchange(line: #"{"method":"initialized","params":{}}"#),
                            JSONRPCExchange(
                                line: #"{"id":2,"method":"account/rateLimits/read","params":null}"#,
                                waitForID: 2
                            ),
                            JSONRPCExchange(
                                line: #"{"id":3,"method":"account/usage/read","params":null}"#,
                                waitForID: 3
                            ),
                        ],
                        timeout: 10
                    )
                    let decoded = CodexStatsProvider.decodeResponses(process.standardOutput)
                    print("Codex transport: exit=\(process.exitCode), timedOut=\(process.timedOut), stdout=\(process.standardOutput.count), stderr=\(process.standardError.count), rateLimits=\(decoded.rateLimits != nil), usage=\(decoded.usage != nil)")
                } catch {
                    print("Codex transport error: \(error.localizedDescription)")
                }
            }
        }
    }

    enum TestError: Error { case invalidFixtureDate }
}
