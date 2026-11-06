import XCTest

final class AccountStoreTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "QuotaRings.storage-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    func testMalformedRowIsRecoveredWithoutOverwritingOriginal() throws {
        try withDefaults { defaults in
            let id = UUID()
            let bytes = Data("[{\"id\":\"\(id)\",\"name\":\"Good\",\"service\":\"claude\"},{\"id\":\"\(UUID())\",\"name\":\"Future\",\"service\":\"new-service\"}]".utf8)
            defaults.set(bytes, forKey: AccountStore.key)
            let store = AccountStore(defaults: defaults)
            let loaded = store.load()
            XCTAssertEqual(loaded.accounts.map(\.id), [id])
            XCTAssertTrue(loaded.needsRecovery)
            XCTAssertEqual(defaults.data(forKey: AccountStore.key), bytes)
            XCTAssertEqual(defaults.data(forKey: AccountStore.recoveryKey), bytes)
            try store.save(loaded.accounts)
            XCTAssertEqual(defaults.data(forKey: AccountStore.recoveryKey), bytes)
        }
    }

    func testBrokenJSONUsesBackupAndKeepsBrokenOriginal() throws {
        try withDefaults { defaults in
            let store = AccountStore(defaults: defaults)
            let account = AccountConfig(id: UUID(), service: .chatgpt, name: "Saved")
            try store.save([account])
            let broken = Data("not-json".utf8)
            defaults.set(broken, forKey: AccountStore.key)
            let result = store.load()
            XCTAssertEqual(result.accounts, [account])
            XCTAssertTrue(result.needsRecovery)
            XCTAssertEqual(defaults.data(forKey: AccountStore.key), broken)
        }
    }

    func testLegacyAccountWithoutServiceStillLoads() {
        withDefaults { defaults in
            let id = UUID()
            defaults.set(Data("[{\"id\":\"\(id)\",\"name\":\"Legacy\",\"orgId\":\"org\"}]".utf8), forKey: AccountStore.key)
            let result = AccountStore(defaults: defaults).load()
            XCTAssertFalse(result.needsRecovery)
            XCTAssertEqual(result.accounts.first?.service, .claude)
            XCTAssertEqual(result.accounts.first?.remoteId, "org")
        }
    }

    func testMissingConfigurationDoesNotCreateOne() {
        withDefaults { defaults in
            XCTAssertTrue(AccountStore(defaults: defaults).load().accounts.isEmpty)
            XCTAssertNil(defaults.data(forKey: AccountStore.key))
        }
    }

    func testDuplicateIdentifiersAreRecoveredOnce() throws {
        try withDefaults { defaults in
            let account = AccountConfig(id: UUID(), service: .claude, name: "Same")
            defaults.set(try JSONEncoder().encode([account, account]), forKey: AccountStore.key)
            let loaded = AccountStore(defaults: defaults).load()
            XCTAssertTrue(loaded.needsRecovery)
            XCTAssertEqual(loaded.accounts, [account])
        }
    }

    func testDifferentCorruptConfigurationsAreAllPreserved() throws {
        try withDefaults { defaults in
            let store = AccountStore(defaults: defaults)
            let first = Data("first corrupt configuration".utf8)
            let second = Data("second corrupt configuration".utf8)
            defaults.set(first, forKey: AccountStore.key)
            _ = store.load()
            defaults.set(second, forKey: AccountStore.key)
            _ = store.load()
            try store.save([])
            let archive = try XCTUnwrap(defaults.dictionary(forKey: AccountStore.recoveryArchiveKey) as? [String: Data])
            XCTAssertEqual(Set(archive.values), [first, second])
            XCTAssertEqual(defaults.data(forKey: AccountStore.recoveryKey), second)
        }
    }
}

final class WidgetDisplayStateTests: XCTestCase {
    func testEveryVisibleQuotaFieldParticipatesInChangeDetection() {
        let now = Date()
        let initial = AccountSnapshot(id: "a", service: .claude, name: "A", status: .ok,
                                      primary: UsageWindow(label: "5h", percent: 0, resetsAt: now, seconds: 18000),
                                      extra: ExtraUsage(used: 1, limit: 20, currency: "USD"), updatedAt: now)
        func state(_ account: AccountSnapshot) -> WidgetDisplayState {
            WidgetDisplayState(accounts: [account], language: .en, now: now)
        }
        var changed = initial
        changed.primary?.resetsAt = now.addingTimeInterval(600)
        XCTAssertNotEqual(state(initial), state(changed))
        changed = initial
        changed.primary?.seconds = 86400
        XCTAssertNotEqual(state(initial), state(changed))
        changed = initial
        changed.primary = nil
        XCTAssertNotEqual(state(initial), state(changed))
        changed = initial
        changed.extra?.used = 2
        XCTAssertNotEqual(state(initial), state(changed))
        changed = initial
        changed.updatedAt = now.addingTimeInterval(-30)
        XCTAssertEqual(state(initial), state(changed))
        changed.updatedAt = now.addingTimeInterval(-1200)
        XCTAssertNotEqual(state(initial), state(changed))
    }
}
