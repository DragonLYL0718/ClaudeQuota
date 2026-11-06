import Foundation
import WebKit

/// Failed removals survive a restart; active accounts are never retried for deletion.
@MainActor
final class AccountWebStores {
    static let pendingRemovalKey = "accounts.pendingWebStoreRemovals.v1"

    private var stores: [UUID: WKWebsiteDataStore] = [:]
    private var pending: Set<UUID>
    private var protectedIDs: Set<UUID> = []
    private var removing: Set<UUID> = []
    private let defaults: UserDefaults
    private let deleteStore: (UUID) async throws -> Void
    private let wait: (TimeInterval) async throws -> Void
    private let retryDelays: [TimeInterval]

    init(defaults: UserDefaults,
         deleteStore: @escaping (UUID) async throws -> Void = { try await WKWebsiteDataStore.remove(forIdentifier: $0) },
         wait: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
         retryDelays: [TimeInterval] = [0.1, 0.25, 0.5, 1]) {
        self.defaults = defaults
        self.deleteStore = deleteStore
        self.wait = wait
        self.retryDelays = retryDelays
        pending = Set((defaults.stringArray(forKey: Self.pendingRemovalKey) ?? []).compactMap(UUID.init(uuidString:)))
    }

    func store(_ id: UUID) -> WKWebsiteDataStore {
        protectedIDs.insert(id)
        if pending.remove(id) != nil { persistPending() }
        if let store = stores[id] { return store }
        let store = WKWebsiteDataStore(forIdentifier: id)
        stores[id] = store
        return store
    }

    func clear(_ id: UUID) async {
        await store(id).removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    /// Called only after the account has been removed from the app's account list.
    func remove(_ id: UUID) async {
        protectedIDs.remove(id)
        pending.insert(id)
        persistPending()
        stores[id] = nil
        await attemptRemoval(id)
    }

    func retryRemovals(excluding activeIDs: Set<UUID>) async {
        protectedIDs.formUnion(activeIDs)
        pending.subtract(activeIDs)
        persistPending()
        for id in pending.sorted(by: { $0.uuidString < $1.uuidString }) {
            await attemptRemoval(id)
        }
    }

    private func attemptRemoval(_ id: UUID) async {
        guard pending.contains(id), !protectedIDs.contains(id), removing.insert(id).inserted else { return }
        defer { removing.remove(id) }
        var lastError: Error?
        // Cancellation resumes the suspended fetch before releasing its WebView. Give that
        // cleanup time to run before asking WebKit to remove the persistent data store.
        for delay in retryDelays {
            do { try await wait(delay) } catch { return }
            guard pending.contains(id), !protectedIDs.contains(id) else { return }
            do {
                try await deleteStore(id)
                pending.remove(id)
                persistPending()
                return
            } catch { lastError = error }
        }
        if let lastError {
            NSLog("QuotaRings: account storage removal will retry after restart: \(lastError.localizedDescription)")
        }
    }

    private func persistPending() {
        defaults.set(pending.map(\.uuidString).sorted(), forKey: Self.pendingRemovalKey)
    }
}
