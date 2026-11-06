import Foundation

/// The AI services the app can read usage limits from.
enum Service: String, Codable, CaseIterable, Identifiable {
    case claude
    case chatgpt

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .chatgpt: return "ChatGPT"
        }
    }
}

/// One usage window: the 5-hour session, the weekly limit, or a per-model limit.
struct UsageWindow: Codable, Hashable {
    var label: String
    var percent: Double
    var resetsAt: Date?
    /// Length of the window, e.g. 18 000 for the 5-hour window.
    var seconds: TimeInterval

    static let fiveHours: TimeInterval = 5 * 3600
    static let week: TimeInterval = 7 * 86400
}

/// Pay-as-you-go "extra usage" spending, in currency units.
struct ExtraUsage: Codable, Hashable {
    var used: Double
    var limit: Double
    var currency: String

    var percent: Double { limit > 0 ? min(100, used / limit * 100) : 0 }
}

struct AccountSnapshot: Codable, Hashable, Identifiable {
    enum Status: String, Codable {
        case ok
        case needsLogin
        case error
    }

    var id: String
    var service: Service
    var name: String
    var plan: String?
    var status: Status
    var message: String?
    /// The shorter window, drawn as the outer ring.
    var primary: UsageWindow?
    /// The longer window, drawn as the inner ring.
    var secondary: UsageWindow?
    var models: [UsageWindow] = []
    var extra: ExtraUsage?
    var updatedAt: Date?

    var primaryPercent: Double { primary?.percent ?? 0 }
    var secondaryPercent: Double { secondary?.percent ?? 0 }
    var hasData: Bool { primary != nil || secondary != nil }
    /// The highest usage shown for this account.
    var peakPercent: Double {
        max(primaryPercent, secondaryPercent, models.map(\.percent).max() ?? 0, extra?.percent ?? 0)
    }

    /// "Claude Max", "ChatGPT Plus".
    var product: String { [service.displayName, plan].compactMap { $0 }.joined(separator: " ") }

    static let staleInterval: TimeInterval = 20 * 60

    func isStale(at date: Date) -> Bool {
        guard let updatedAt else { return true }
        return date.timeIntervalSince(updatedAt) >= Self.staleInterval
    }
}

struct QuotaSnapshot: Codable {
    var accounts: [AccountSnapshot]
    var generatedAt: Date
    /// The language chosen in the app, so the widget can follow it.
    var language: AppLanguage?
    /// A completed refresh attempt, distinct from each account's last successful update.
    /// Unlike an ISO8601 timestamp this also changes for two attempts within the same second.
    var refreshRevision: String? = nil
}

/// Compare actual widget content, omitting only success timestamps. Staleness is included so a
/// successful refresh of unchanged but old numbers still removes its warning immediately.
struct WidgetDisplayState: Equatable {
    var accounts: [AccountSnapshot]
    var staleAccounts: Set<String>
    var language: AppLanguage

    init(accounts: [AccountSnapshot], language: AppLanguage, now: Date) {
        staleAccounts = Set(accounts.filter { $0.isStale(at: now) }.map(\.id))
        self.accounts = accounts.map { account in
            var value = account
            value.updatedAt = nil
            return value
        }
        self.language = language
    }
}

/// The app writes the latest numbers to one JSON file; the sandboxed widget reads it through a
/// read-only exception for this folder, so no App Group (and no paid developer team) is needed.
enum SharedStore {
    static var realHome: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// Named after the app's former name; kept so the widget's sandbox exception keeps matching.
    static var directory: URL {
        realHome.appendingPathComponent("Library/Application Support/ClaudeQuota", isDirectory: true)
    }

    static var snapshotURL: URL { directory.appendingPathComponent("snapshot.json") }

    static let appBundleId = "com.rayleigh.ClaudeQuota"
    /// Posted by the widget's refresh button; the app refreshes when it gets it.
    static let refreshRequest = Notification.Name(appBundleId + ".refresh")

    static func load() -> QuotaSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(QuotaSnapshot.self, from: data)
    }

    static func save(_ snapshot: QuotaSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: snapshotURL, options: .atomic)
    }
}

extension QuotaSnapshot {
    /// Example numbers for the widget gallery preview.
    static var sample: QuotaSnapshot {
        QuotaSnapshot(accounts: Array(sampleAccounts.prefix(2)), generatedAt: Date())
    }

    /// Six mixed accounts, for rendering every layout.
    static var sampleAccounts: [AccountSnapshot] {
        let now = Date()
        func window(_ percent: Double, _ seconds: TimeInterval, in remaining: TimeInterval) -> UsageWindow {
            UsageWindow(label: "", percent: percent, resetsAt: now.addingTimeInterval(remaining), seconds: seconds)
        }
        return [
            AccountSnapshot(
                id: "sample-1", service: .claude, name: "Personal", plan: "Max", status: .ok,
                primary: window(37, UsageWindow.fiveHours, in: 2 * 3600 + 13 * 60),
                secondary: window(62, UsageWindow.week, in: 3.5 * 86400),
                models: [UsageWindow(label: "Fable", percent: 81, seconds: UsageWindow.week),
                         UsageWindow(label: "Sonnet", percent: 22, seconds: UsageWindow.week)],
                updatedAt: now),
            AccountSnapshot(
                id: "sample-2", service: .claude, name: "Work", plan: "Pro", status: .ok,
                primary: window(92, UsageWindow.fiveHours, in: 41 * 60),
                secondary: window(45, UsageWindow.week, in: 5.7 * 86400),
                models: [UsageWindow(label: "Sonnet", percent: 30, seconds: UsageWindow.week)],
                extra: ExtraUsage(used: 4.2, limit: 20, currency: "USD"),
                updatedAt: now),
            AccountSnapshot(
                id: "sample-3", service: .chatgpt, name: "ChatGPT", plan: "Plus", status: .ok,
                primary: window(12, UsageWindow.fiveHours, in: 4 * 3600 + 2 * 60),
                secondary: window(30, UsageWindow.week, in: 2.1 * 86400),
                updatedAt: now),
            AccountSnapshot(
                id: "sample-4", service: .chatgpt, name: "Side", plan: "Pro", status: .ok,
                primary: window(5, UsageWindow.fiveHours, in: 70 * 60),
                secondary: window(74, UsageWindow.week, in: 6 * 86400),
                updatedAt: now),
            AccountSnapshot(
                id: "sample-5", service: .claude, name: "Team", plan: "Team", status: .needsLogin,
                updatedAt: now),
            AccountSnapshot(
                id: "sample-6", service: .chatgpt, name: "Lab", plan: "Free", status: .ok,
                primary: window(48, 30 * 86400, in: 12 * 86400),
                updatedAt: now)
        ]
    }
}
