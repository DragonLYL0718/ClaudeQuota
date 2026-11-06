import Foundation

struct AccountConfig: Codable, Identifiable, Hashable {
    var id: UUID
    var service: Service
    var name: String
    var remoteId: String?
    var plan: String?

    private enum CodingKeys: String, CodingKey {
        case id, service, name, plan
        case remoteId = "orgId"
    }

    init(id: UUID, service: Service, name: String, remoteId: String? = nil, plan: String? = nil) {
        self.id = id
        self.service = service
        self.name = name
        self.remoteId = remoteId
        self.plan = plan
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        service = try container.decodeIfPresent(Service.self, forKey: .service) ?? .claude
        name = try container.decode(String.self, forKey: .name)
        remoteId = try container.decodeIfPresent(String.self, forKey: .remoteId)
        plan = try container.decodeIfPresent(String.self, forKey: .plan)
    }
}

/// Never replaces an unreadable configuration merely because the app was opened.
/// A recovery copy preserves every original byte, including accounts a newer app may understand.
final class AccountStore {
    static let key = "accounts.v1"
    static let backupKey = "accounts.v1.lastGood"
    static let recoveryKey = "accounts.v1.recovery"
    static let recoveryArchiveKey = "accounts.v1.recoveryArchive"

    struct Loaded {
        var accounts: [AccountConfig]
        var needsRecovery: Bool
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }

    func load() -> Loaded {
        guard let data = defaults.data(forKey: Self.key) else {
            return Loaded(accounts: [], needsRecovery: false)
        }
        if let accounts = decode(data) { return Loaded(accounts: accounts, needsRecovery: false) }

        preserveUnreadable(data)
        // Recover independent records instead of dropping all accounts for one malformed row.
        if let rows = (try? JSONSerialization.jsonObject(with: data)) as? [Any] {
            var seen = Set<UUID>()
            let accounts = rows.compactMap { row -> AccountConfig? in
                guard JSONSerialization.isValidJSONObject(row),
                      let bytes = try? JSONSerialization.data(withJSONObject: row),
                      let account = try? JSONDecoder().decode(AccountConfig.self, from: bytes),
                      seen.insert(account.id).inserted else { return nil }
                return account
            }
            if !accounts.isEmpty { return Loaded(accounts: accounts, needsRecovery: true) }
        }
        let backup = defaults.data(forKey: Self.backupKey).flatMap(decode) ?? []
        return Loaded(accounts: backup, needsRecovery: true)
    }

    func save(_ accounts: [AccountConfig]) throws {
        let data = try JSONEncoder().encode(accounts)
        if let old = defaults.data(forKey: Self.key) {
            if decode(old) != nil { defaults.set(old, forKey: Self.backupKey) }
            else { preserveUnreadable(old) }
        }
        defaults.set(data, forKey: Self.key)
        if defaults.data(forKey: Self.backupKey) == nil {
            defaults.set(data, forKey: Self.backupKey)
        }
    }

    private func preserveUnreadable(_ data: Data) {
        var archive = defaults.dictionary(forKey: Self.recoveryArchiveKey) as? [String: Data] ?? [:]
        for bytes in [defaults.data(forKey: Self.recoveryKey), data].compactMap({ $0 }) {
            if !archive.values.contains(bytes) { archive[UUID().uuidString] = bytes }
        }
        defaults.set(archive, forKey: Self.recoveryArchiveKey)
        defaults.set(data, forKey: Self.recoveryKey)
    }

    private func decode(_ data: Data) -> [AccountConfig]? {
        guard let accounts = try? JSONDecoder().decode([AccountConfig].self, from: data),
              Set(accounts.map(\.id)).count == accounts.count else { return nil }
        return accounts
    }
}
