import Foundation

/// An opt-in read of the user's Claude Code statusLine feed, with no credential access.
public enum ClaudeStatusLineUsage {
    public static let maximumAge: TimeInterval = 30 * 60

    public static func load(
        cachePath: String? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = .init()) throws -> ClaudeUsageSnapshot
    {
        let configured = cachePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let paths = if let configured, !configured.isEmpty {
            [URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)]
        } else {
            [
                homeDirectory.appendingPathComponent(".codexbar/claude-statusline.json"),
                homeDirectory.appendingPathComponent(".vibe-island/cache/rl.json"),
            ]
        }
        var lastError: any Error = ClaudeUsageError.parseFailed(
            "statusLine cache is missing. Configure a cache path or install the CodexBar statusLine bridge.")
        for path in paths where FileManager.default.fileExists(atPath: path.path) {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
                guard let modified = attributes[.modificationDate] as? Date,
                      let size = attributes[.size] as? NSNumber, size.intValue <= 1_048_576
                else {
                    throw ClaudeUsageError.parseFailed("statusLine cache is too large or has no modification time.")
                }
                return try self.parse(Data(contentsOf: path), updatedAt: modified, now: now)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    public static func parse(_ data: Data, updatedAt: Date, now: Date = .init()) throws -> ClaudeUsageSnapshot {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw ClaudeUsageError.parseFailed("statusLine JSON format is invalid.")
        }
        let observedAt = payload.updatedAt.map { Date(timeIntervalSince1970: $0) } ?? updatedAt
        let age = now.timeIntervalSince(min(observedAt, updatedAt))
        guard age.isFinite, age >= -60, observedAt.timeIntervalSince(now) <= 60 else {
            throw ClaudeUsageError.parseFailed("statusLine cache has an invalid update time.")
        }
        guard age <= self.maximumAge else {
            throw ClaudeUsageError.parseFailed("statusLine data is over 30 minutes old. Run Claude Code to refresh it.")
        }
        let limits = payload.rateLimits ?? payload.limits
        let primary = try limits.fiveHour?.window(minutes: 300, now: now)
        let secondary = try limits.sevenDay?.window(minutes: 10080, now: now)
        guard primary != nil || secondary != nil else {
            throw ClaudeUsageError
                .parseFailed("statusLine rate_limits are missing or expired. Run Claude Code to refresh them.")
        }
        return ClaudeUsageSnapshot(
            primary: primary ?? RateWindow(
                usedPercent: 0,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil,
                isSyntheticPlaceholder: true),
            secondary: secondary,
            opus: nil,
            updatedAt: min(observedAt, updatedAt),
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: nil,
            rawText: nil)
    }

    private struct Payload: Decodable {
        let rateLimits: Limits?
        let fiveHour: Window?
        let sevenDay: Window?
        let updatedAt: TimeInterval?

        var limits: Limits {
            Limits(fiveHour: self.fiveHour, sevenDay: self.sevenDay)
        }

        private enum CodingKeys: String, CodingKey {
            case rateLimits = "rate_limits"
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case updatedAt = "updated_at"
        }
    }

    private struct Limits: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?

        private enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
    }

    private struct Window: Decodable {
        let usedPercentage: Double
        let resetsAt: TimeInterval

        private enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
            case resetsAt = "resets_at"
        }

        func window(minutes: Int, now: Date) throws -> RateWindow? {
            guard self.usedPercentage.isFinite, (0...100).contains(self.usedPercentage),
                  self.resetsAt.isFinite, self.resetsAt > 0
            else {
                throw ClaudeUsageError.parseFailed("statusLine rate limit values are invalid.")
            }
            let reset = Date(timeIntervalSince1970: self.resetsAt)
            guard reset > now else { return nil }
            return RateWindow(
                usedPercent: self.usedPercentage,
                windowMinutes: minutes,
                resetsAt: reset,
                resetDescription: nil)
        }
    }
}
