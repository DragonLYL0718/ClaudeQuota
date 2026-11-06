import Foundation
import WebKit

struct AccountFetchResult {
    var account: ServiceAccount?
    var usage: ServiceUsage
}

@MainActor
protocol AccountFetching {
    func fetch(_ account: AccountConfig) async throws -> AccountFetchResult
    func invalidate(_ id: UUID)
}

/// Reuses the origin document and WebKit process for successful refreshes of one account.
@MainActor
final class WebAccountFetcher: AccountFetching {
    private let storeProvider: (UUID) -> WKWebsiteDataStore
    private var sessions: [UUID: WebSession] = [:]

    init(storeProvider: @escaping (UUID) -> WKWebsiteDataStore) {
        self.storeProvider = storeProvider
    }

    func fetch(_ account: AccountConfig) async throws -> AccountFetchResult {
        let session = sessions[account.id] ?? WebSession(store: storeProvider(account.id))
        sessions[account.id] = session
        let client = account.service.client
        do {
            try Task.checkCancellation()
            try await session.prepare(client.originURL)
            let result = try await client.fetch(in: session.webView, preferredAccountID: account.remoteId)
            try Task.checkCancellation()
            return result
        } catch {
            // An invalidated older request must not discard a replacement session.
            if sessions[account.id] === session { invalidate(account.id) }
            throw error
        }
    }

    func invalidate(_ id: UUID) {
        sessions.removeValue(forKey: id)?.cancel()
    }
}
