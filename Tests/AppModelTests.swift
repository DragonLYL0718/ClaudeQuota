import XCTest

@MainActor
private final class ControlledFetcher: AccountFetching {
    var calls: [AccountConfig] = []
    var invalidated: [UUID] = []
    private var waiting: [Int: CheckedContinuation<AccountFetchResult, Error>] = [:]

    func fetch(_ account: AccountConfig) async throws -> AccountFetchResult {
        let index = calls.count
        calls.append(account)
        return try await withCheckedThrowingContinuation { waiting[index] = $0 }
    }

    func invalidate(_ id: UUID) { invalidated.append(id) }

    func complete(_ index: Int, percent: Double = 42, remoteID: String? = nil,
                  plan: String? = "Pro", error: Error? = nil) {
        guard let continuation = waiting.removeValue(forKey: index) else {
            XCTFail("No pending request at index \(index)")
            return
        }
        if let error { continuation.resume(throwing: error) }
        else {
            continuation.resume(returning: AccountFetchResult(
                account: ServiceAccount(id: remoteID ?? calls[index].remoteId ?? "remote", plan: plan),
                usage: ServiceUsage(primary: UsageWindow(label: "five_hour", percent: percent,
                                                         resetsAt: Date(timeIntervalSince1970: 2_000_000_000),
                                                         seconds: UsageWindow.fiveHours))))
        }
    }
}

@MainActor
private final class ModelFixture {
    let suite = "QuotaRings.tests." + UUID().uuidString
    let defaults: UserDefaults
    let fetcher = ControlledFetcher()
    var writes: [QuotaSnapshot] = []
    var reloads = 0
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    var clearCount = 0
    var removeCount = 0
    var failWrites = false
    var model: AppModel!

    init(count: Int = 1, snapshot: QuotaSnapshot? = nil, concurrency: Int = 3,
         timeout: TimeInterval = 90) throws {
        defaults = UserDefaults(suiteName: suite)!
        let accounts = (0..<count).map {
            AccountConfig(id: UUID(), service: .claude, name: "Account \($0)", remoteId: "remote-\($0)", plan: "Pro")
        }
        try AccountStore(defaults: defaults).save(accounts)
        model = AppModel(defaults: defaults, fetcher: fetcher, loadSnapshot: { snapshot },
                         saveSnapshot: { [weak self] value in
                             guard let self else { return }
                             if self.failWrites { throw ServiceError.badResponse("disk") }
                             self.writes.append(value)
                         }, reloadTimelines: { [weak self] in self?.reloads += 1 },
                         now: { [weak self] in self?.date ?? .distantPast },
                         clearSession: { [weak self] _ in self?.clearCount += 1 },
                         removeSession: { [weak self] _ in self?.removeCount += 1 },
                         backgroundTasksEnabled: false, concurrency: concurrency, roundTimeout: timeout)
    }

    func cleanUp() { defaults.removePersistentDomain(forName: suite) }

    func waitForCalls(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 {
            if fetcher.calls.count >= count { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Expected \(count) calls, received \(fetcher.calls.count)", file: file, line: line)
    }
}

@MainActor
final class AppModelTests: XCTestCase {
    func testLogoutDiscardsUncooperativeLateResult() async throws {
        let f = try ModelFixture()
        defer { f.cleanUp() }
        let account = f.model.accounts[0]
        let refresh = Task { await f.model.refreshAll() }
        await f.waitForCalls(1)
        await f.model.signOut(account)
        await refresh.value
        f.fetcher.complete(0)
        await Task.yield()
        XCTAssertNil(f.model.accounts[0].remoteId)
        XCTAssertNil(f.model.snapshots[account.id])
        XCTAssertEqual(f.writes.last?.accounts.first?.status, .needsLogin)
        XCTAssertEqual(f.clearCount, 1)
        XCTAssertFalse(f.model.isRefreshing)
    }

    func testRemovedAccountCannotReappearAfterRefresh() async throws {
        let f = try ModelFixture()
        defer { f.cleanUp() }
        let account = f.model.accounts[0]
        let refresh = Task { await f.model.refreshAll() }
        await f.waitForCalls(1)
        await f.model.remove(account)
        await refresh.value
        f.fetcher.complete(0)
        await Task.yield()
        XCTAssertTrue(f.model.accounts.isEmpty)
        XCTAssertNil(f.model.snapshots[account.id])
        XCTAssertEqual(f.removeCount, 1)
    }

    func testLoginCallbackFromBeforeLogoutIsIgnored() async throws {
        let f = try ModelFixture()
        defer { f.cleanUp() }
        let account = f.model.accounts[0]
        await f.model.signOut(account)
        await f.model.completeLogin(ServiceAccount(id: "old-session", plan: "Max"),
                                    for: account.id, expectedGeneration: 0)
        XCTAssertNil(f.model.accounts[0].remoteId)
        XCTAssertTrue(f.fetcher.calls.isEmpty)
    }

    func testRemoteMetadataDoesNotOverwriteRename() async throws {
        let f = try ModelFixture()
        defer { f.cleanUp() }
        let refresh = Task { await f.model.refreshAll() }
        await f.waitForCalls(1)
        f.model.rename(f.model.accounts[0].id, to: "New name")
        f.fetcher.complete(0, plan: "Max")
        await refresh.value
        XCTAssertEqual(f.model.accounts[0].name, "New name")
        XCTAssertEqual(f.model.accounts[0].plan, "Max")
        XCTAssertEqual(f.writes.last?.accounts.first?.name, "New name")
    }

    func testManualRefreshMergesAndForcesReloadEvenWhenNumbersUnchanged() async throws {
        let f = try ModelFixture()
        defer { f.cleanUp() }
        let first = Task { await f.model.refreshAll() }
        await f.waitForCalls(1)
        f.fetcher.complete(0)
        await first.value
        let baseline = f.reloads
        let revision = f.writes.last?.refreshRevision
        let automatic = Task { await f.model.refreshAll() }
        await f.waitForCalls(2)
        let manual = Task { await f.model.refreshAll(reloadWidget: true) }
        await Task.yield()
        f.fetcher.complete(1)
        await automatic.value
        await manual.value
        XCTAssertEqual(f.fetcher.calls.count, 2)
        XCTAssertEqual(f.reloads, baseline + 1)
        XCTAssertNotEqual(f.writes.last?.refreshRevision, revision)
    }

    func testLoginDuringRefreshQueuesNewGeneration() async throws {
        let f = try ModelFixture()
        defer { f.cleanUp() }
        let id = f.model.accounts[0].id
        let old = Task { await f.model.refreshAll() }
        await f.waitForCalls(1)
        let login = Task { await f.model.completeLogin(ServiceAccount(id: "new-account", plan: "Max"), for: id) }
        await f.waitForCalls(2)
        f.fetcher.complete(0, percent: 99, remoteID: "old-account")
        f.fetcher.complete(1, percent: 12, remoteID: "new-account", plan: "Max")
        await old.value
        await login.value
        XCTAssertEqual(f.model.accounts[0].remoteId, "new-account")
        XCTAssertEqual(f.model.snapshots[id]?.primaryPercent, 12)
        XCTAssertFalse(f.model.isRefreshing)
    }

    func testRequestsAreBoundedAndPublishBeforeSlowAccountCompletes() async throws {
        let f = try ModelFixture(count: 5, concurrency: 2)
        defer { f.cleanUp() }
        let refresh = Task { await f.model.refreshAll() }
        await f.waitForCalls(2)
        XCTAssertEqual(f.fetcher.calls.count, 2)
        f.fetcher.complete(0)
        await f.waitForCalls(3)
        XCTAssertNotNil(f.writes.last?.accounts.first?.updatedAt)
        XCTAssertTrue(f.model.isRefreshing)
        f.fetcher.complete(1)
        await f.waitForCalls(4)
        f.fetcher.complete(2)
        await f.waitForCalls(5)
        f.fetcher.complete(3)
        f.fetcher.complete(4)
        await refresh.value
        XCTAssertEqual(f.model.snapshots.count, 5)
        XCTAssertTrue(f.model.snapshots.values.allSatisfy { $0.status == .ok })
    }

    func testRoundDeadlineReleasesRefreshAndIgnoresLateResult() async throws {
        let f = try ModelFixture(timeout: 0.03)
        defer { f.cleanUp() }
        let id = f.model.accounts[0].id
        await f.model.refreshAll()
        XCTAssertFalse(f.model.isRefreshing)
        XCTAssertEqual(f.model.snapshots[id]?.status, .error)
        XCTAssertTrue(f.fetcher.invalidated.contains(id))
        f.fetcher.complete(0)
        await Task.yield()
        XCTAssertEqual(f.model.snapshots[id]?.status, .error)
        let retry = Task { await f.model.refreshAll() }
        await f.waitForCalls(2)
        f.fetcher.complete(1)
        await retry.value
        XCTAssertEqual(f.model.snapshots[id]?.status, .ok)
    }

    func testFailurePreservesLastSuccessDateAndValues() async throws {
        let f = try ModelFixture()
        defer { f.cleanUp() }
        let first = Task { await f.model.refreshAll() }
        await f.waitForCalls(1)
        f.fetcher.complete(0)
        await first.value
        let success = f.model.lastRefresh
        f.date = f.date.addingTimeInterval(3600)
        let failure = Task { await f.model.refreshAll() }
        await f.waitForCalls(2)
        f.fetcher.complete(1, error: ServiceError.http("claude.ai", 503))
        await failure.value
        let snapshot = try XCTUnwrap(f.writes.last?.accounts.first)
        XCTAssertEqual(snapshot.primaryPercent, 42)
        XCTAssertEqual(snapshot.status, .error)
        XCTAssertEqual(snapshot.updatedAt, success)
        XCTAssertEqual(f.model.lastRefresh, success)
        XCTAssertEqual(f.model.lastAttempt, f.date)
        XCTAssertTrue(snapshot.isStale(at: f.date))
    }

    func testFailedSnapshotWriteDoesNotSuppressRetryReload() throws {
        let f = try ModelFixture()
        defer { f.cleanUp() }
        f.failWrites = true
        f.model.writeSnapshot()
        XCTAssertEqual(f.reloads, 0)
        f.failWrites = false
        f.model.writeSnapshot()
        XCTAssertEqual(f.reloads, 1)
    }
}
