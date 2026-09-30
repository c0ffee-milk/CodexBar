import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeStatusLineUsageTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let limits = """
    {"five_hour":{"used_percentage":23.5,"resets_at":1790003600},
     "seven_day":{"used_percentage":81,"resets_at":1790600000}}
    """

    @Test
    func `parses stdin payload and bare Vibe Island cache`() throws {
        for json in [self.limits, "{\"rate_limits\":\(self.limits)}"] {
            let snapshot = try ClaudeStatusLineUsage.parse(Data(json.utf8), updatedAt: self.now, now: self.now)
            #expect(snapshot.primary.usedPercent == 23.5)
            #expect(snapshot.primary.windowMinutes == 300)
            #expect(snapshot.primary.resetsAt == Date(timeIntervalSince1970: 1_790_003_600))
            #expect(snapshot.secondary?.usedPercent == 81)
            #expect(snapshot.secondary?.windowMinutes == 10080)
            #expect(snapshot.accountEmail == nil)
        }
    }

    @Test
    func `weekly only cache marks the session as unavailable`() throws {
        let data = Data(#"{"seven_day":{"used_percentage":81,"resets_at":1790600000}}"#.utf8)
        let snapshot = try ClaudeStatusLineUsage.parse(data, updatedAt: self.now, now: self.now)
        #expect(snapshot.primary.isSyntheticPlaceholder)
        #expect(snapshot.secondary?.usedPercent == 81)
    }

    @Test
    func `stale data errors and timestamp cannot be refreshed by touching the file`() throws {
        let data = Data(self.limits.utf8)
        #expect(throws: ClaudeUsageError.self) {
            try ClaudeStatusLineUsage.parse(data, updatedAt: self.now.addingTimeInterval(-1801), now: self.now)
        }
        let timestamped = Data("{\"updated_at\":1789998199,\"rate_limits\":\(self.limits)}".utf8)
        #expect(throws: ClaudeUsageError.self) {
            try ClaudeStatusLineUsage.parse(timestamped, updatedAt: self.now, now: self.now)
        }
        let snapshot = try ClaudeStatusLineUsage.parse(
            data, updatedAt: self.now.addingTimeInterval(-1800), now: self.now)
        #expect(snapshot.primary.usedPercent == 23.5)
    }

    @Test(arguments: [
        "{}", "invalid", #"{"five_hour":{"used_percentage":-1,"resets_at":1790003600}}"#,
        #"{"five_hour":{"used_percentage":101,"resets_at":1790003600}}"#,
        #"{"five_hour":{"used_percentage":true,"resets_at":1790003600}}"#,
        #"{"five_hour":{"used_percentage":50,"resets_at":1789999999}}"#,
        #"{"five_hour":{"used_percentage":50}}"#,
    ])
    func `missing malformed invalid and expired readings fail clearly`(_ json: String) {
        #expect(throws: ClaudeUsageError.self) {
            try ClaudeStatusLineUsage.parse(Data(json.utf8), updatedAt: self.now, now: self.now)
        }
    }

    @Test
    func `default paths fall back to Vibe Island and explicit paths stay isolated`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vibe = root.appendingPathComponent(".vibe-island/cache/rl.json")
        try FileManager.default.createDirectory(at: vibe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(self.limits.utf8).write(to: vibe)
        try FileManager.default.setAttributes([.modificationDate: self.now], ofItemAtPath: vibe.path)
        let snapshot = try ClaudeStatusLineUsage.load(homeDirectory: root, now: self.now)
        #expect(snapshot.secondary?.usedPercent == 81)
        #expect(throws: ClaudeUsageError.self) {
            try ClaudeStatusLineUsage.load(
                cachePath: root.appendingPathComponent("missing").path,
                homeDirectory: root,
                now: self.now)
        }
        try FileManager.default.setAttributes(
            [.modificationDate: self.now.addingTimeInterval(-1801)], ofItemAtPath: vibe.path)
        do {
            _ = try ClaudeStatusLineUsage.load(homeDirectory: root, now: self.now)
            Issue.record("stale cache was accepted")
        } catch {
            #expect(error.localizedDescription.contains("over 30 minutes old"))
        }
    }

    @Test
    func `planner adds statusLine only after opt in and preserves source priority`() {
        for runtime in [ProviderRuntime.app, .cli] {
            let plan = ClaudeSourcePlanner.resolve(input: .init(
                runtime: runtime,
                selectedDataSource: .auto,
                webExtrasEnabled: false,
                hasWebSession: true,
                hasCLI: true,
                hasOAuthCredentials: true,
                statusLineEnabled: true))
            #expect(plan.orderedSteps.last?.dataSource == .statusLine)
            #expect(plan.orderedSteps.last?.inclusionReason == .autoFallbackStatusLine)
            #expect(plan.preferredStep?.dataSource == (runtime == .app ? .oauth : .web))
        }
        let explicit = ClaudeSourcePlanner.resolve(input: .init(
            runtime: .app,
            selectedDataSource: .statusLine,
            webExtrasEnabled: true,
            hasWebSession: true,
            hasCLI: true,
            hasOAuthCredentials: true))
        #expect(explicit.executionSteps.map(\.dataSource) == [.statusLine])
        #expect(explicit.compatibilityStrategy?.useWebExtras == false)
    }

    @Test
    func `explicit provider source reads local cache without credentials or browser calls`() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let data = Data("{\"seven_day\":{\"used_percentage\":81,\"resets_at\":\(Date().timeIntervalSince1970 + 3600)}}"
            .utf8)
        try data.write(to: file)
        let browser = BrowserDetection(cacheTTL: 0)
        let context = ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: .make(claude: .init(
                usageDataSource: .statusLine,
                webExtrasEnabled: true,
                cookieSource: .auto,
                manualCookieHeader: nil,
                statusLineCachePath: file.path)),
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browser, environment: [:]),
            browserDetection: browser)
        let descriptor = ClaudeProviderDescriptor.descriptor
        let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(context)
        #expect(strategies.map(\.id) == ["claude.statusline"])
        let outcome = await descriptor.fetchOutcome(context: context)
        guard case let .success(result) = outcome.result else {
            Issue.record("statusLine pipeline failed: \(outcome.result)")
            return
        }
        #expect(result.usage.primary == nil)
        #expect(result.usage.secondary?.usedPercent == 81)
        #expect(result.sourceLabel == "statusLine (user config)")
        #expect(result.usage.identity == nil)
        #expect(!strategies[0].shouldFallback(on: ClaudeUsageError.parseFailed("stale"), context: context))
    }

    @Test
    func `Auto reaches statusLine after web failure and surfaces missing cache`() async throws {
        let browser = BrowserDetection(cacheTTL: 0)
        let context = ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: .make(claude: .init(
                usageDataSource: .auto,
                webExtrasEnabled: false,
                cookieSource: .manual,
                manualCookieHeader: "sessionKey=synthetic-session",
                statusLineAutoFallback: true,
                statusLineCachePath: "/nonexistent/claude-statusline-\(UUID().uuidString).json")),
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browser, environment: [:]),
            browserDetection: browser)
        let strategies = await ClaudeProviderDescriptor.descriptor.fetchPlan.pipeline.resolveStrategies(context)
        let web = try #require(strategies.first { $0.id == "claude.web" })
        #expect(web.shouldFallback(on: ClaudeUsageError.parseFailed("web failed"), context: context))
        #expect(!web.shouldFallback(on: CancellationError(), context: context))
        let statusLine = try #require(strategies.last)
        #expect(statusLine.id == "claude.statusline")
        #expect(await statusLine.isAvailable(context))
        do {
            _ = try await statusLine.fetch(context)
            Issue.record("missing cache was accepted")
        } catch {
            #expect(error.localizedDescription.contains("statusLine cache is missing"))
        }
    }

    @Test
    func `statusLine settings survive config encoding`() throws {
        var config = ProviderConfig(id: .claude)
        config.claudeStatusLineSelected = true
        config.claudeStatusLineAutoFallback = true
        config.claudeStatusLineCachePath = "/tmp/usage.json"
        let decoded = try JSONDecoder().decode(ProviderConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.claudeStatusLineSelected == true)
        #expect(decoded.claudeStatusLineAutoFallback == true)
        #expect(decoded.claudeStatusLineCachePath == "/tmp/usage.json")
    }
}
