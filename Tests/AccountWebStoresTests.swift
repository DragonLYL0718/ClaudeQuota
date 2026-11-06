import XCTest

@MainActor
final class AccountWebStoresTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) async throws -> Void) async rethrows {
        let suite = "QuotaRings.webstore-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try await body(defaults)
    }

    func testRemovalRetriesAfterWebViewReleaseAndClearsQueue() async {
        await withDefaults { defaults in
            let id = UUID()
            var attempts = 0
            let stores = AccountWebStores(defaults: defaults, deleteStore: { received in
                XCTAssertEqual(received, id)
                attempts += 1
                if attempts < 3 { throw ServiceError.badResponse("Data store is in use") }
            }, wait: { _ in }, retryDelays: [0, 0, 0, 0])
            await stores.remove(id)
            XCTAssertEqual(attempts, 3)
            XCTAssertEqual(defaults.stringArray(forKey: AccountWebStores.pendingRemovalKey), [])
        }
    }

    func testFailedRemovalIsRetriedAfterRestart() async {
        await withDefaults { defaults in
            let id = UUID()
            var attempts = 0
            let first = AccountWebStores(defaults: defaults, deleteStore: { _ in
                attempts += 1
                throw ServiceError.badResponse("Data store is in use")
            }, wait: { _ in }, retryDelays: [0, 0])
            await first.remove(id)
            XCTAssertEqual(attempts, 2)
            XCTAssertEqual(defaults.stringArray(forKey: AccountWebStores.pendingRemovalKey), [id.uuidString])

            let restarted = AccountWebStores(defaults: defaults, deleteStore: { received in
                XCTAssertEqual(received, id)
                attempts += 1
            }, wait: { _ in }, retryDelays: [0])
            await restarted.retryRemovals(excluding: [])
            XCTAssertEqual(attempts, 3)
            XCTAssertEqual(defaults.stringArray(forKey: AccountWebStores.pendingRemovalKey), [])
        }
    }

    func testRecoveryNeverRemovesAnActiveAccount() async {
        await withDefaults { defaults in
            let active = UUID(), removed = UUID()
            defaults.set([active.uuidString, removed.uuidString], forKey: AccountWebStores.pendingRemovalKey)
            var deleted: [UUID] = []
            let stores = AccountWebStores(defaults: defaults, deleteStore: { deleted.append($0) },
                                          wait: { _ in }, retryDelays: [0])
            await stores.retryRemovals(excluding: [active])
            XCTAssertEqual(deleted, [removed])
            XCTAssertEqual(defaults.stringArray(forKey: AccountWebStores.pendingRemovalKey), [])
        }
    }

    func testCancellationBeforeRemovalKeepsPersistedQueue() async {
        await withDefaults { defaults in
            let id = UUID()
            let stores = AccountWebStores(defaults: defaults, deleteStore: { _ in
                XCTFail("Cancellation must prevent deletion")
            }, wait: { _ in
                XCTAssertEqual(defaults.stringArray(forKey: AccountWebStores.pendingRemovalKey), [id.uuidString])
                throw CancellationError()
            }, retryDelays: [0])
            await stores.remove(id)
            XCTAssertEqual(defaults.stringArray(forKey: AccountWebStores.pendingRemovalKey), [id.uuidString])
        }
    }
}
