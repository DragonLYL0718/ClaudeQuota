import AppKit
import ServiceManagement
import SwiftUI
import WebKit
import WidgetKit

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    static let maxAccounts = 8

    @Published private(set) var accounts: [AccountConfig] {
        didSet { persistAccounts() }
    }
    @Published private(set) var snapshots: [UUID: AccountSnapshot] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastAttempt: Date?
    @Published private(set) var configurationNeedsRecovery = false
    @Published private(set) var changingAccounts: Set<UUID> = []
    @Published var refreshMinutes: Int {
        didSet {
            defaults.set(refreshMinutes, forKey: Self.intervalKey)
            if backgroundTasksEnabled { scheduleTimer() }
        }
    }
    @Published var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: AppLanguage.defaultsKey)
            writeSnapshot()
        }
    }

    private static let intervalKey = "refreshMinutes"
    private let defaults: UserDefaults
    private let accountStore: AccountStore
    private let webStores: AccountWebStores
    private let fetcher: AccountFetching
    private let saveSnapshot: (QuotaSnapshot) throws -> Void
    private let reloadTimelines: () -> Void
    private let now: () -> Date
    private let clearSession: (UUID) async -> Void
    private let removeSession: (UUID) async -> Void
    private let backgroundTasksEnabled: Bool
    private let concurrency: Int
    private let roundTimeout: TimeInterval
    private var loginControllers: [UUID: LoginWindowController] = [:]
    private var timer: Timer?
    private var pendingWrite: Task<Void, Never>?
    private var lastWidgetAccounts: [AccountSnapshot]?
    private var lastWidgetLanguage: AppLanguage?
    private var lastReload = Date.distantPast
    private var refreshRevision: String?
    private var generations: [UUID: Int] = [:]
    private var scheduledGenerations: [UUID: Int] = [:]
    private var pendingAccounts: Set<UUID> = []
    private var reloadRequested = false
    private var refreshTask: Task<Void, Never>?
    private var currentBatch: RefreshBatch?

    /// Dependencies keep tests isolated from real accounts, WebKit stores, files and WidgetKit.
    init(defaults: UserDefaults = .standard, fetcher: AccountFetching? = nil,
         loadSnapshot: () -> QuotaSnapshot? = SharedStore.load,
         saveSnapshot: @escaping (QuotaSnapshot) throws -> Void = SharedStore.save,
         reloadTimelines: @escaping () -> Void = { WidgetCenter.shared.reloadAllTimelines() },
         now: @escaping () -> Date = Date.init,
         clearSession: ((UUID) async -> Void)? = nil,
         removeSession: ((UUID) async -> Void)? = nil,
         backgroundTasksEnabled: Bool = true, concurrency: Int = 3, roundTimeout: TimeInterval = 90) {
        self.defaults = defaults
        let store = AccountStore(defaults: defaults)
        accountStore = store
        let loaded = store.load()
        accounts = loaded.accounts
        configurationNeedsRecovery = loaded.needsRecovery
        language = AppLanguage(rawValue: defaults.string(forKey: AppLanguage.defaultsKey) ?? "") ?? .system
        let interval = defaults.integer(forKey: Self.intervalKey)
        refreshMinutes = [2, 5, 10, 15].contains(interval) ? interval : 5
        let webStores = AccountWebStores(defaults: defaults)
        self.webStores = webStores
        self.fetcher = fetcher ?? WebAccountFetcher(storeProvider: { webStores.store($0) })
        self.clearSession = clearSession ?? { await webStores.clear($0) }
        self.removeSession = removeSession ?? { await webStores.remove($0) }
        self.saveSnapshot = saveSnapshot
        self.reloadTimelines = reloadTimelines
        self.now = now
        self.backgroundTasksEnabled = backgroundTasksEnabled
        self.concurrency = min(3, max(1, concurrency))
        self.roundTimeout = roundTimeout

        if let saved = loadSnapshot() {
            let ids = Set(accounts.map(\.id))
            for snapshot in saved.accounts {
                if let id = UUID(uuidString: snapshot.id), ids.contains(id) { snapshots[id] = snapshot }
            }
            lastAttempt = saved.generatedAt
            refreshRevision = saved.refreshRevision
        }
        if backgroundTasksEnabled { startBackgroundTasks() }
    }

    private func startBackgroundTasks() {
        Task { await webStores.retryRemovals(excluding: Set(accounts.map(\.id))) }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                await self?.refreshAll()
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: SharedStore.refreshRequest, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshAll(reloadWidget: true) }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.LaunchServices.applicationUnregistered"), object: nil, queue: .main
        ) { [weak self] note in
            guard let ids = note.userInfo?["bundleIDs"] as? [String], ids.contains(SharedStore.appBundleId) else { return }
            Task { @MainActor in await self?.restoreWidgetMetadata() }
        }
        scheduleTimer()
        Task { await restoreWidgetMetadata() }
    }

    var needsSetup: Bool { accounts.allSatisfy { $0.remoteId == nil } }

    /// The oldest last-success time among signed-in accounts, never the last failed attempt.
    var lastRefresh: Date? {
        let signedIn = accounts.filter { $0.remoteId != nil }
        guard !signedIn.isEmpty else { return nil }
        let dates = signedIn.compactMap { snapshots[$0.id]?.updatedAt }
        return dates.count == signedIn.count ? dates.min() : nil
    }

    func snapshot(for account: AccountConfig) -> AccountSnapshot? { snapshots[account.id] }

    // MARK: Refreshing

    func refreshAll(reloadWidget: Bool = false) async {
        await refresh(ids: Set(accounts.map(\.id)), reloadWidget: reloadWidget)
    }

    private func refresh(ids: Set<UUID>, reloadWidget: Bool) async {
        reloadRequested = reloadRequested || reloadWidget
        for account in accounts where ids.contains(account.id) && !changingAccounts.contains(account.id) {
            let generation = generations[account.id, default: 0]
            if scheduledGenerations[account.id] != generation {
                pendingAccounts.insert(account.id)
                scheduledGenerations[account.id] = generation
            }
        }
        if let refreshTask {
            await refreshTask.value
            return
        }
        isRefreshing = true
        let task = Task { @MainActor in await self.drainRefreshes() }
        refreshTask = task
        await task.value
    }

    private func drainRefreshes() async {
        defer {
            currentBatch = nil
            scheduledGenerations.removeAll()
            isRefreshing = false
            refreshTask = nil
        }
        repeat {
            let requests = accounts.filter { pendingAccounts.contains($0.id) && !changingAccounts.contains($0.id) }
                .map { RefreshBatch.Request(account: $0, generation: generations[$0.id, default: 0]) }
            pendingAccounts.removeAll()
            let batch = RefreshBatch(requests: requests, fetcher: fetcher, concurrency: concurrency,
                                     timeout: roundTimeout) { [weak self] request, result in
                self?.receive(result, for: request)
            }
            currentBatch = batch
            await batch.run()
            currentBatch = nil
            lastAttempt = now()
            refreshRevision = UUID().uuidString
            let forceReload = reloadRequested
            reloadRequested = false
            writeSnapshot(reloadWidget: forceReload)
        } while !pendingAccounts.isEmpty
    }

    private func receive(_ result: Result<AccountFetchResult, Error>, for request: RefreshBatch.Request) {
        let id = request.account.id
        guard generations[id, default: 0] == request.generation,
              !changingAccounts.contains(id),
              let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        let current = accounts[index]
        var snapshot = blankSnapshot(current, status: .ok)
        switch result {
        case .success(let fetched):
            // Merge only remote fields. The name/order may have changed while awaiting the service.
            var config = current
            if let found = fetched.account {
                config.remoteId = found.id
                config.plan = found.plan
            }
            if let plan = fetched.usage.plan { config.plan = plan }
            if config != current { accounts[index] = config }
            snapshot.plan = config.plan
            snapshot.primary = fetched.usage.primary
            snapshot.secondary = fetched.usage.secondary
            snapshot.models = fetched.usage.models
            snapshot.extra = fetched.usage.extra
            snapshot.updatedAt = now()
        case .failure(let error):
            if error is CancellationError { return }
            if case ServiceError.loggedOut = error {
                snapshot.status = .needsLogin
                snapshot.message = error.localizedDescription
            } else {
                snapshot = snapshots[id] ?? snapshot
                snapshot.name = current.name
                snapshot.status = .error
                snapshot.message = error.localizedDescription
            }
        }
        snapshots[id] = snapshot
        // Publish successful accounts promptly even when another service is slow.
        writeSnapshot()
    }

    private func blankSnapshot(_ account: AccountConfig, status: AccountSnapshot.Status) -> AccountSnapshot {
        AccountSnapshot(id: account.id.uuidString, service: account.service, name: account.name,
                        plan: account.plan, status: status,
                        message: status == .needsLogin ? tr("未登录", "Not logged in") : nil)
    }

    func writeSnapshot(reloadWidget: Bool = false) {
        let list = accounts.map { account -> AccountSnapshot in
            var snapshot = snapshots[account.id] ?? blankSnapshot(account, status: .needsLogin)
            snapshot.name = account.name
            snapshot.plan = account.plan ?? snapshot.plan
            return snapshot
        }
        let date = now()
        do {
            try saveSnapshot(QuotaSnapshot(accounts: list, generatedAt: lastAttempt ?? date,
                                           language: language, refreshRevision: refreshRevision))
        } catch {
            NSLog("QuotaRings: could not write snapshot: \(error.localizedDescription)")
            return // Do not remember a change that never reached the widget.
        }
        let display = WidgetDisplayState(accounts: list, language: language, now: date)
        let previous = lastWidgetAccounts.map {
            WidgetDisplayState(accounts: $0, language: lastWidgetLanguage ?? language, now: date)
        }
        if reloadWidget || display != previous || date.timeIntervalSince(lastReload) >= 15 * 60 {
            lastWidgetAccounts = list
            lastWidgetLanguage = language
            lastReload = date
            reloadTimelines()
        }
    }

    func writeSnapshotSoon() {
        pendingWrite?.cancel()
        pendingWrite = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 800_000_000) } catch { return }
            writeSnapshot()
        }
    }

    private func restoreWidgetMetadata() async {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        reloadTimelines()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(max(2, refreshMinutes) * 60), repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshAll() }
        }
    }

    // MARK: Accounts

    func dataStore(for account: AccountConfig) -> WKWebsiteDataStore { webStores.store(account.id) }

    private func persistAccounts() {
        do { try accountStore.save(accounts) }
        catch { NSLog("QuotaRings: could not save accounts: \(error.localizedDescription)") }
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].name = name
        writeSnapshotSoon()
    }

    /// Puts an account where another one is (drag and drop in Settings). The widget shows
    /// accounts in this order.
    func moveAccount(_ id: UUID, to targetId: UUID) {
        guard let from = accounts.firstIndex(where: { $0.id == id }),
              let to = accounts.firstIndex(where: { $0.id == targetId }),
              from != to else { return }
        accounts.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        writeSnapshot()
    }

    func moveAccount(_ id: UUID, by offset: Int) {
        guard let from = accounts.firstIndex(where: { $0.id == id }),
              accounts.indices.contains(from + offset) else { return }
        accounts.swapAt(from, from + offset)
        writeSnapshot()
    }

    /// New accounts are named after their service ("ChatGPT", "ChatGPT 2"), which tells them apart
    /// on the desktop until the user renames them.
    func addAccount(_ service: Service) {
        guard accounts.count < Self.maxAccounts else { return }
        let count = accounts.filter { $0.service == service }.count
        let name = count == 0 ? service.displayName : "\(service.displayName) \(count + 1)"
        accounts.append(AccountConfig(id: UUID(), service: service, name: name))
        writeSnapshot()
    }

    private func invalidate(_ id: UUID) {
        generations[id, default: 0] += 1
        pendingAccounts.remove(id)
        fetcher.invalidate(id)
        currentBatch?.cancel(id)
    }

    func remove(_ account: AccountConfig) async {
        invalidate(account.id)
        loginControllers[account.id]?.close()
        loginControllers[account.id] = nil
        accounts.removeAll { $0.id == account.id }
        snapshots[account.id] = nil
        writeSnapshot()
        await removeSession(account.id)
    }

    func signOut(_ account: AccountConfig) async {
        guard !changingAccounts.contains(account.id),
              let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        changingAccounts.insert(account.id)
        defer { changingAccounts.remove(account.id) }
        invalidate(account.id)
        loginControllers[account.id]?.close()
        loginControllers[account.id] = nil
        accounts[index].remoteId = nil
        accounts[index].plan = nil
        snapshots[account.id] = nil
        writeSnapshot()
        await clearSession(account.id)
    }

    func completeLogin(_ found: ServiceAccount, for id: UUID, expectedGeneration: Int? = nil) async {
        guard expectedGeneration == nil || expectedGeneration == generations[id, default: 0],
              !changingAccounts.contains(id),
              let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        invalidate(id)
        accounts[index].remoteId = found.id
        accounts[index].plan = found.plan
        snapshots[id] = nil
        writeSnapshot()
        await refresh(ids: [id], reloadWidget: true)
    }

    func login(_ account: AccountConfig) {
        guard !changingAccounts.contains(account.id), accounts.contains(where: { $0.id == account.id }) else { return }
        if let existing = loginControllers[account.id] {
            existing.showWindow(nil)
            NSApp.activate()
            return
        }
        let expectedGeneration = generations[account.id, default: 0]
        let controller = LoginWindowController(accountName: account.name, client: account.service.client,
                                               store: dataStore(for: account)) { [weak self] found in
            guard let self else { return }
            self.loginControllers[account.id] = nil
            guard let found else { return }
            Task { await self.completeLogin(found, for: account.id, expectedGeneration: expectedGeneration) }
        }
        loginControllers[account.id] = controller
        controller.showWindow(nil)
        NSApp.activate()
    }

    func useSessionKey(_ rawKey: String, for account: AccountConfig) async {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard account.service == .claude, !key.isEmpty, !changingAccounts.contains(account.id),
              accounts.contains(where: { $0.id == account.id }), let cookie = HTTPCookie(properties: [
            .domain: ".claude.ai", .path: "/", .name: "sessionKey", .value: key,
            .secure: "TRUE", .expires: now().addingTimeInterval(30 * 86400)
        ]) else { return }
        changingAccounts.insert(account.id)
        invalidate(account.id)
        loginControllers[account.id]?.close()
        loginControllers[account.id] = nil
        let generation = generations[account.id, default: 0]
        await dataStore(for: account).httpCookieStore.setCookie(cookie)
        changingAccounts.remove(account.id)
        guard generations[account.id, default: 0] == generation,
              let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index].remoteId = nil
        accounts[index].plan = nil
        snapshots[account.id] = nil
        writeSnapshot()
        await refresh(ids: [account.id], reloadWidget: true)
    }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("QuotaRings: launch at login change failed: \(error.localizedDescription)")
            }
            objectWillChange.send()
        }
    }
}
