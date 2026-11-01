import Foundation

/// One usage window: the 5-hour session, the weekly limit, or a per-model weekly limit.
struct UsageWindow: Codable, Hashable {
    var label: String
    var percent: Double
    var resetsAt: Date?
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
    var name: String
    var plan: String?
    var status: Status
    var message: String?
    var session: UsageWindow?
    var weekly: UsageWindow?
    var models: [UsageWindow] = []
    var extra: ExtraUsage?
    var updatedAt: Date?

    var sessionPercent: Double { session?.percent ?? 0 }
    var weeklyPercent: Double { weekly?.percent ?? 0 }
    var hasData: Bool { session != nil || weekly != nil }
}

struct QuotaSnapshot: Codable {
    var accounts: [AccountSnapshot]
    var generatedAt: Date
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

    static var directory: URL {
        realHome.appendingPathComponent("Library/Application Support/ClaudeQuota", isDirectory: true)
    }

    static var snapshotURL: URL { directory.appendingPathComponent("snapshot.json") }

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
        let now = Date()
        return QuotaSnapshot(
            accounts: [
                AccountSnapshot(
                    id: "sample-1", name: "Personal", plan: "Max", status: .ok,
                    session: UsageWindow(label: "5 小时", percent: 37, resetsAt: now.addingTimeInterval(2 * 3600 + 13 * 60)),
                    weekly: UsageWindow(label: "本周", percent: 62, resetsAt: now.addingTimeInterval(3.5 * 86400)),
                    models: [UsageWindow(label: "Fable", percent: 81), UsageWindow(label: "Sonnet", percent: 22)],
                    updatedAt: now),
                AccountSnapshot(
                    id: "sample-2", name: "Work", plan: "Pro", status: .ok,
                    session: UsageWindow(label: "5 小时", percent: 92, resetsAt: now.addingTimeInterval(41 * 60)),
                    weekly: UsageWindow(label: "本周", percent: 45, resetsAt: now.addingTimeInterval(5.7 * 86400)),
                    models: [UsageWindow(label: "Sonnet", percent: 30)],
                    extra: ExtraUsage(used: 4.2, limit: 20, currency: "USD"),
                    updatedAt: now)
            ],
            generatedAt: now)
    }
}
