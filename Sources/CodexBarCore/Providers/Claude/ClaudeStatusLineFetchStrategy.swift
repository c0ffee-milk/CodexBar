import Foundation

struct ClaudeStatusLineFetchStrategy: ProviderFetchStrategy {
    let id = "claude.statusline"
    let kind: ProviderFetchKind = .localProbe

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        // Execute missing/stale feeds too, so the UI receives an actionable error.
        context.selectedTokenAccountID == nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let usage = try ClaudeStatusLineUsage.load(
            cachePath: context.settings?.claude?.statusLineCachePath
                ?? context.env["CODEXBAR_CLAUDE_STATUSLINE_CACHE"])
        return ProviderFetchResult(
            usage: UsageSnapshot(
                primary: usage.primary.isSyntheticPlaceholder ? nil : usage.primary,
                secondary: usage.secondary,
                updatedAt: usage.updatedAt),
            credits: nil,
            dashboard: nil,
            sourceLabel: "statusLine (user config)",
            strategyID: self.id,
            strategyKind: self.kind)
    }

    func shouldFallback(on _: any Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
