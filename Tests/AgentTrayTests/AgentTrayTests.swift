import Foundation

@main
struct AgentTrayTests {
    private static var failures = 0

    static func main() async throws {
        discoversModelProvidersWithoutDuplicates()
        try codexDiscoveryPreservesExistingInstallations()
        tooltipPlacementStaysAttached()
        hiddenKindsPersistAndToggle()
        decodesCodexUsageAndRateLimits()
        decodesCurrentCodexRateLimitsPayload()
        try await jsonRPCWaitsForInitializeBeforeNextRequest()
        decodesCursorUsageWindows()
        decodesClaudeUsageWindows()
        selectsClaudeDesktopToken()
        grokBillingNamesTheWindowFromThePeriod()
        try omitsGrokBecauseBillingIsUnifiedWithCursor()
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
        expect(
            ProfileCatalog.nativeCodexVendorPath(packageRoot: URL(fileURLWithPath: "/tmp/pkg"))
                .path
                .contains("node_modules/@openai/\(ProfileCatalog.codexPlatformPackage)/vendor/\(ProfileCatalog.codexTargetTriple)/bin/codex"),
            "native Codex vendor path"
        )
        expect(ProfileCatalog.isCurrentArchitectureMachO(URL(fileURLWithPath: "/usr/bin/true")), "host Mach-O is accepted")
        let bundled = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        expect(ProfileCatalog.executableCandidates(
            named: "codex", preferred: ProfileCatalog.preferredCodexExecutable(homeDirectory: URL(fileURLWithPath: "/Users/test")),
            homeDirectory: URL(fileURLWithPath: "/Users/test"), environment: [:]
        ).contains(bundled), "current ChatGPT bundle layout is searched")
        if FileManager.default.fileExists(atPath: bundled.path) {
            expect(ProfileCatalog.resolvedExecutable(at: bundled, name: "codex", fileManager: .default) == bundled, "bundled native CLI is usable")
        }
    }

    static func codexDiscoveryPreservesExistingInstallations() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: home) }
        let preferred = ProfileCatalog.preferredCodexExecutable(homeDirectory: home)
        try fm.createDirectory(at: preferred.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: preferred)
        let environment = ["PATH": "/custom/bin:/another/bin", "CODEX_HOME": home.appendingPathComponent(".codex").path]
        let candidates = ProfileCatalog.executableCandidates(named: "codex", preferred: preferred, homeDirectory: home, environment: environment)
        let legacy = [preferred] + ProfileCatalog.wellKnownExecutableLocations(named: "codex", homeDirectory: home)
            + [URL(fileURLWithPath: "/custom/bin/codex"), URL(fileURLWithPath: "/another/bin/codex")]
        expect(Array(candidates.prefix(legacy.count)) == legacy, "all legacy candidates retain their priority ahead of bundle fallback")
        for path in ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/Applications/ChatGPT.app/Contents/Resources/codex", "/Applications/Codex.app/Contents/Resources/codex"] {
            expect(legacy.contains(URL(fileURLWithPath: path)), "legacy installation remains supported: \(path)")
        }
        let profile = ProfileCatalog(environment: environment, homeDirectory: home).discover().first { $0.id == "codex-default" }
        expect(profile?.executableURL == preferred, "existing local CLI wins even with bundled CLI installed")
    }

    static func tooltipPlacementStaysAttached() {
        let displays = [
            NSRect(x: 0, y: 0, width: 1440, height: 900),
            NSRect(x: -2560, y: 0, width: 2560, height: 1440),
            NSRect(x: 1920, y: -900, width: 1440, height: 900),
            NSRect(x: 0, y: 1080, width: 1512, height: 982),
        ]
        var checked = 0
        for display in displays {
            // Model menu bars and Docks on the bottom, left, and right.
            for insets: NSEdgeInsets in [
                NSEdgeInsets(top: 24, left: 0, bottom: 70, right: 0),
                NSEdgeInsets(top: 38, left: 70, bottom: 0, right: 0),
                NSEdgeInsets(top: 24, left: 0, bottom: 0, right: 70),
            ] {
                let visible = NSRect(x: display.minX + insets.left, y: display.minY + insets.bottom,
                    width: display.width - insets.left - insets.right, height: display.height - insets.top - insets.bottom)
                for count in [1, 2, 4] {
                    for position in [NotchPosition.top, .right, .bottom, .left] {
                        let notchSize = NotchMetrics.panelSize(profileCount: count, position: position)
                        let maximum = NotchMetrics.maxOffset(size: notchSize, in: display, position: position)
                        for offset in [CGFloat(0), maximum / 2, maximum] {
                            let notch = NSRect(origin: NotchMetrics.panelOrigin(size: notchSize, offset: offset, in: display, position: position), size: notchSize)
                            expect(NotchMetrics.isFlush(notch, to: position, in: display), "notch stays on its display edge")
                            for index in 0..<count {
                                let meter = NotchMetrics.meterCenter(index: index, count: count, in: notch, position: position)
                                for height: CGFloat in [74, 118, 190, 320] {
                                    let size = NSSize(width: position.isHorizontal ? 248 : 254, height: height)
                                    let placement = NotchMetrics.tooltipPlacement(size: size, meter: meter, position: position, in: visible)
                                    expect(visible.contains(placement.frame), "tooltip stays on its display across Dock placements")
                                    let clearance: CGFloat
                                    switch position {
                                    case .top: clearance = meter.y - placement.frame.maxY
                                    case .bottom: clearance = placement.frame.minY - meter.y
                                    case .left: clearance = placement.frame.minX - meter.x
                                    case .right: clearance = meter.x - placement.frame.maxX
                                    }
                                    expect(clearance >= -0.5, "tooltip never overlaps notch")
                                    // A Dock/menu bar may force separation; otherwise the tip touches the edge.
                                    let unobstructed: Bool
                                    switch position {
                                    case .top: unobstructed = meter.y <= visible.maxY - 10
                                    case .bottom: unobstructed = meter.y >= visible.minY + 10
                                    case .left: unobstructed = meter.x >= visible.minX + 10
                                    case .right: unobstructed = meter.x <= visible.maxX - 10
                                    }
                                    if unobstructed { expect(abs(clearance) < 0.5, "tooltip stays attached when system UI leaves room") }
                                    checked += 1
                                }
                            }
                        }
                    }
                }
            }
        }
        print("Verified \(checked) tooltip placements across display and Dock layouts")
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
        expect(
            !settings.isHidden(.codex) && !settings.isHidden(.cursor) && !settings.isHidden(.claude) && !settings.isHidden(.grok),
            "kinds visible by default"
        )
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

        let rfc3339 = """
        {"billingCycleStart":"2026-09-01T00:00:00.000Z","billingCycleEnd":"2026-10-01T00:00:00.000Z","planUsage":{"autoPercentUsed":10,"apiPercentUsed":20}}
        """
        let dated = CursorStatsProvider.decodePeriodUsage(Data(rfc3339.utf8))
        expect(dated?.planUsage?.autoPercentUsed == 10, "Cursor RFC3339 usage decode")
        expect(dated?.billingCycleEnd?.date != nil, "Cursor RFC3339 reset decode")
    }

    static func decodesClaudeUsageWindows() {
        let wrapped = """
        {"rate_limits_available":true,"subscription_type":"pro","rate_limits":{"five_hour":{"utilization":3,"resets_at":"2026-10-26T09:50:00.344946+00:00"},"seven_day":{"utilization":1,"resets_at":"2026-11-02T04:00:00.344969+00:00"},"limits":[{"kind":"session","percent":3,"resets_at":"2026-10-26T09:50:00.344946+00:00"},{"kind":"weekly_all","percent":1,"resets_at":"2026-11-02T04:00:00.344969+00:00"},{"kind":"weekly_scoped","percent":12,"scope":{"model":{"display_name":"Fable"}}}]}}
        """
        let decoded = ClaudeStatsProvider.decodeUsage(Data(wrapped.utf8))
        expect(decoded?.planName == "pro", "Claude plan")
        expect(decoded?.windows.map(\.label) == ["5-hour", "Weekly", "Fable"], "Claude window labels")
        expect(decoded?.windows.map(\.usedPercent) == [3, 1, 12], "Claude window percents")
        expect(decoded?.windows[0].durationMinutes == 300, "Claude 5-hour duration")
        expect(decoded?.windows[1].durationMinutes == 10_080, "Claude weekly duration")
        expect(decoded?.windows[2].durationMinutes == nil, "Claude model window stays off the weekly ring")
        expect(decoded?.windows[0].resetsAt != nil, "Claude reset time")

        let legacy = """
        {"five_hour":{"utilization":42,"resets_at":"2026-10-26T09:50:00Z"},"seven_day":null}
        """
        let legacyWindows = ClaudeStatsProvider.decodeUsage(Data(legacy.utf8))?.windows ?? []
        expect(legacyWindows.map(\.label) == ["5-hour"], "Claude legacy window")
        expect(legacyWindows.first?.usedPercent == 42, "Claude legacy percent")

        let stream = #"{"type":"control_response","response":{"request_id":"usage","response":{"rate_limits_available":false}}}"#
        expect(ClaudeStatsProvider.usagePayload(from: Data(stream.utf8)) != nil, "Claude usage payload")
    }

    static func selectsClaudeDesktopToken() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entries: [String: Any] = [
            "acct|client:user:profile": [
                "token": "old",
                "expiresAt": now.timeIntervalSince1970 * 1_000 - 1_000,
                "subscriptionType": "pro",
            ],
            "acct|client:user:inference user:sessions:claude_code": [
                "token": "code",
                "expiresAt": now.timeIntervalSince1970 * 1_000 + 3_600_000,
                "subscriptionType": "max",
            ],
        ]
        let selected = ClaudeStatsProvider.selectDesktopToken(entries: entries, now: now)
        expect(selected?.token == "code", "Claude prefers a live Claude Code token")
        expect(selected?.subscription == "max", "Claude token plan")
    }

    static func grokBillingNamesTheWindowFromThePeriod() {
        let weekly = """
        {"config":{"creditUsagePercent":18.4,"currentPeriod":{"start":"2026-10-20T00:00:00Z","end":"2026-10-27T00:00:00Z"}}}
        """
        let windows = GrokStatsProvider.quotaWindows(fromBilling: Data(weekly.utf8))
        expect(windows.first?.label == "Weekly", "Grok weekly billing window")
        expect(windows.first?.usedPercent == 18, "Grok billing percent")
        expect(windows.first?.durationMinutes == 10_080, "Grok weekly duration")
        expect(windows.first?.resetsAt != nil, "Grok billing reset")

        let daily = """
        {"config":{"creditUsagePercent":4,"currentPeriod":{"start":"2026-10-26T00:00:00Z","end":"2026-10-27T00:00:00Z"}}}
        """
        expect(GrokStatsProvider.quotaWindows(fromBilling: Data(daily.utf8)).first?.label == "Daily", "Grok daily billing window")

        let auth = #"{"https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828":{"key":"abc","auth_mode":"oauth"},"https://accounts.x.ai/sign-in":{"key":"legacy","auth_mode":"api_key"}}"#
        expect(GrokStatsProvider.accessToken(in: Data(auth.utf8)) == "abc", "Grok first-party token")
        let apiKey = #"{"https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828":{"key":"abc","auth_mode":"api_key"}}"#
        expect(GrokStatsProvider.accessToken(in: Data(apiKey.utf8)) == nil, "Grok API keys are not plan logins")
    }

    static func omitsGrokBecauseBillingIsUnifiedWithCursor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-tray-grok-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".grok/logs"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{}".utf8).write(to: root.appendingPathComponent(".grok/auth.json"))
        try Data("".utf8).write(to: root.appendingPathComponent(".grok/logs/unified.jsonl"))
        let catalog = ProfileCatalog(environment: ["PATH": "/nonexistent", "GROK_HOME": root.appendingPathComponent(".grok").path], homeDirectory: root)
        expect(!catalog.discover().contains { $0.kind == .grok }, "Grok is not a separate notch entry")
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
            case .claude: snapshot = await ClaudeStatsProvider().snapshot(for: profile)
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
