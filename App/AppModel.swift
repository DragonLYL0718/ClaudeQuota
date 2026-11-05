import AppKit
import ServiceManagement
import SwiftUI
import WebKit
import WidgetKit

struct AccountConfig: Codable, Identifiable, Hashable {
    var id: UUID
    var service: Service
    var name: String
    /// The Claude organization or ChatGPT account; nil until logged in.
    var remoteId: String?
    var plan: String?

    private enum CodingKeys: String, CodingKey {
        case id, service, name, plan
        case remoteId = "orgId"
    }
}

extension AccountConfig {
    /// Accounts saved before ChatGPT support have no service and are Claude accounts.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        service = try container.decodeIfPresent(Service.self, forKey: .service) ?? .claude
        name = try container.decode(String.self, forKey: .name)
        remoteId = try container.decodeIfPresent(String.self, forKey: .remoteId)
        plan = try container.decodeIfPresent(String.self, forKey: .plan)
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    static let maxAccounts = 8

    @Published var accounts: [AccountConfig] {
        didSet { persistAccounts() }
    }
    @Published private(set) var snapshots: [UUID: AccountSnapshot] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    @Published var refreshMinutes: Int {
        didSet {
            UserDefaults.standard.set(refreshMinutes, forKey: Self.intervalKey)
            scheduleTimer()
        }
    }
    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: AppLanguage.defaultsKey)
            writeSnapshot()
        }
    }

    private static let accountsKey = "accounts.v1"
    private static let intervalKey = "refreshMinutes"

    private var stores: [UUID: WKWebsiteDataStore] = [:]
    private var loginControllers: [UUID: LoginWindowController] = [:]
    private var timer: Timer?
    private var pendingWrite: Task<Void, Never>?
    private var lastSignature = ""
    private var lastReload = Date.distantPast

    private init() {
        let defaults = UserDefaults.standard
        let savedLanguage = AppLanguage.current
        language = savedLanguage
        accounts = defaults.data(forKey: Self.accountsKey)
            .flatMap { try? JSONDecoder().decode([AccountConfig].self, from: $0) } ?? []
        let interval = defaults.integer(forKey: Self.intervalKey)
        refreshMinutes = interval > 0 ? interval : 5

        if let saved = SharedStore.load() {
            for snapshot in saved.accounts {
                if let id = UUID(uuidString: snapshot.id) { snapshots[id] = snapshot }
            }
            lastRefresh = saved.generatedAt
        }
        persistAccounts()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                await AppModel.shared.refreshAll()
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: SharedStore.refreshRequest, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await AppModel.shared.refreshAll(reloadWidget: true) }
        }
        // Posted by Launch Services when any copy of an app is removed.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.LaunchServices.applicationUnregistered"), object: nil, queue: .main
        ) { note in
            guard let ids = note.userInfo?["bundleIDs"] as? [String], ids.contains(SharedStore.appBundleId) else { return }
            Task { @MainActor in await AppModel.shared.restoreWidgetMetadata() }
        }
        scheduleTimer()
        Task { await restoreWidgetMetadata() }
    }

    var needsSetup: Bool { accounts.allSatisfy { $0.remoteId == nil } }

    func snapshot(for account: AccountConfig) -> AccountSnapshot? { snapshots[account.id] }

    // MARK: Refreshing

    /// `reloadWidget` redraws the widget even when no number changed, so that a refresh the user
    /// asked for shows up as "Updated just now".
    func refreshAll(reloadWidget: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        for account in accounts {
            snapshots[account.id] = await fetch(account)
        }
        lastRefresh = Date()
        isRefreshing = false
        writeSnapshot(reloadWidget: reloadWidget)
    }

    private func fetch(_ account: AccountConfig) async -> AccountSnapshot {
        var result = blankSnapshot(account, status: .ok)
        let client = account.service.client
        let session = WebSession(store: dataStore(for: account))
        do {
            try await session.open(client.originURL)
            var config = account
            if config.remoteId == nil {
                guard let found = try await client.account(in: session.webView) else {
                    result.status = .needsLogin
                    result.message = tr("未登录", "Not logged in")
                    return result
                }
                config.remoteId = found.id
                config.plan = found.plan
                update(config)
            }
            let usage = try await client.usage(in: session.webView, accountId: config.remoteId ?? "")
            if let plan = usage.plan, plan != config.plan {
                config.plan = plan
                update(config)
            }
            result.plan = config.plan
            result.primary = usage.primary
            result.secondary = usage.secondary
            result.models = usage.models
            result.extra = usage.extra
            result.updatedAt = Date()
            return result
        } catch ServiceError.loggedOut {
            result.status = .needsLogin
            result.message = ServiceError.loggedOut.localizedDescription
            return result
        } catch {
            // Keep showing the last good numbers, marked as not current.
            if var previous = snapshots[account.id], previous.hasData {
                previous.name = account.name
                previous.status = .error
                previous.message = error.localizedDescription
                return previous
            }
            result.status = .error
            result.message = error.localizedDescription
            return result
        }
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
        do {
            try SharedStore.save(QuotaSnapshot(accounts: list, generatedAt: lastRefresh ?? Date(), language: language))
        } catch {
            NSLog("QuotaRings: could not write snapshot: \(error.localizedDescription)")
        }
        // WidgetKit rate-limits reloads, so only ask for one when something visible changed or the
        // user asked; the widget's per-minute timeline keeps the countdowns moving in between.
        let signature = language.rawValue + ";" + list.map { item -> String in
            let models = item.models.map { "\($0.label)\(Int($0.percent))" }.joined(separator: ",")
            return "\(item.id)|\(item.name)|\(item.plan ?? "")|\(item.status.rawValue)|\(Int(item.primaryPercent))|\(Int(item.secondaryPercent))|\(models)"
        }.joined(separator: ";")
        if reloadWidget || signature != lastSignature || Date().timeIntervalSince(lastReload) > 15 * 60 {
            lastSignature = signature
            lastReload = Date()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Debounced write used while the user is typing an account name.
    func writeSnapshotSoon() {
        pendingWrite?.cancel()
        pendingWrite = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            writeSnapshot()
        }
    }

    /// macOS drops the widget's App Intents metadata whenever any copy of this app is deleted (an old
    /// copy when the Trash is emptied, the build folder), even though this copy is still installed.
    /// The widget then fails every reload and its buttons do nothing, until this copy is registered again.
    private func restoreWidgetMetadata() async {
        // Let the system finish removing the other copy, then index this one, then redraw.
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(refreshMinutes * 60), repeats: true) { _ in
            Task { @MainActor in await AppModel.shared.refreshAll() }
        }
    }

    // MARK: Accounts

    func dataStore(for account: AccountConfig) -> WKWebsiteDataStore {
        if let store = stores[account.id] { return store }
        let store = WKWebsiteDataStore(forIdentifier: account.id)
        stores[account.id] = store
        return store
    }

    private func update(_ account: AccountConfig) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index] = account
    }

    private func persistAccounts() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: Self.accountsKey)
        }
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

    func remove(_ account: AccountConfig) async {
        loginControllers[account.id]?.close()
        loginControllers[account.id] = nil
        accounts.removeAll { $0.id == account.id }
        snapshots[account.id] = nil
        stores[account.id] = nil
        writeSnapshot()
        try? await WKWebsiteDataStore.remove(forIdentifier: account.id)
    }

    func signOut(_ account: AccountConfig) async {
        let store = dataStore(for: account)
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        var config = account
        config.remoteId = nil
        config.plan = nil
        update(config)
        snapshots[account.id] = nil
        writeSnapshot()
    }

    func login(_ account: AccountConfig) {
        if let existing = loginControllers[account.id] {
            existing.showWindow(nil)
            NSApp.activate()
            return
        }
        let controller = LoginWindowController(accountName: account.name, client: account.service.client,
                                               store: dataStore(for: account)) { [weak self] found in
            guard let self else { return }
            self.loginControllers[account.id] = nil
            guard let found, var config = self.accounts.first(where: { $0.id == account.id }) else { return }
            config.remoteId = found.id
            config.plan = found.plan
            self.update(config)
            Task { await self.refreshAll() }
        }
        loginControllers[account.id] = controller
        controller.showWindow(nil)
        NSApp.activate()
    }

    /// Fallback for when claude.ai's built-in login page can't be used: paste the sessionKey cookie.
    func useSessionKey(_ rawKey: String, for account: AccountConfig) async {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard account.service == .claude, !key.isEmpty, let cookie = HTTPCookie(properties: [
            .domain: ".claude.ai", .path: "/", .name: "sessionKey", .value: key,
            .secure: "TRUE", .expires: Date().addingTimeInterval(30 * 86400)
        ]) else { return }
        await dataStore(for: account).httpCookieStore.setCookie(cookie)
        var config = account
        config.remoteId = nil
        update(config)
        await refreshAll()
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
