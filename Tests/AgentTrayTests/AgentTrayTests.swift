import Foundation

@main
struct AgentTrayTests {
    private static var failures = 0

    static func main() async throws {
        discoversModelProvidersWithoutDuplicates()
        decodesCodexUsageAndRateLimits()
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
                let requests = [
                    #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"agent-tray-probe","version":"0.1.0"},"capabilities":{"experimentalApi":true}}}"#,
                    #"{"method":"initialized","params":{}}"#,
                    #"{"id":2,"method":"account/rateLimits/read","params":null}"#,
                    #"{"id":3,"method":"account/usage/read","params":null}"#
                ]
                do {
                    let process = try await ProcessRunner.run(
                        executable: executable,
                        arguments: ["app-server", "--stdio"],
                        standardInput: Data((requests.joined(separator: "\n") + "\n").utf8),
                        inputCloseDelay: 2.0,
                        timeout: 7
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
