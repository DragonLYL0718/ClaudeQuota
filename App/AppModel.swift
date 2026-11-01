import AppKit
import ServiceManagement
import SwiftUI
import WebKit
import WidgetKit

struct AccountConfig: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var orgId: String?
    var plan: String?
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

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
        if let data = defaults.data(forKey: Self.accountsKey),
           let saved = try? JSONDecoder().decode([AccountConfig].self, from: data), !saved.isEmpty {
            accounts = saved
        } else {
            accounts = [AccountConfig(id: UUID(), name: savedLanguage.pick("账号 1", "Account 1")),
                        AccountConfig(id: UUID(), name: savedLanguage.pick("账号 2", "Account 2"))]
        }
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
        scheduleTimer()
    }

    var needsSetup: Bool { accounts.allSatisfy { $0.orgId == nil } }

    func snapshot(for account: AccountConfig) -> AccountSnapshot? { snapshots[account.id] }

    // MARK: Refreshing

    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        for account in accounts {
            snapshots[account.id] = await fetch(account)
        }
        lastRefresh = Date()
        isRefreshing = false
        writeSnapshot()
    }

    private func fetch(_ account: AccountConfig) async -> AccountSnapshot {
        var result = AccountSnapshot(id: account.id.uuidString, name: account.name, plan: account.plan, status: .ok)
        let client = ClaudeWebClient(store: dataStore(for: account))
        do {
            try await client.prepare()
            var config = account
            if config.orgId == nil {
                guard let orgs = try await client.organizations(), let org = ClaudeWebClient.pick(orgs) else {
                    result.status = .needsLogin
                    result.message = tr("未登录", "Not logged in")
                    return result
                }
                config.orgId = org.id
                config.plan = org.plan
                update(config)
                result.plan = org.plan
            }
            guard let orgId = config.orgId else { return result }
            let (status, body) = try await client.get("/api/organizations/\(orgId)/usage")
            if status == 401 || status == 403 {
                result.status = .needsLogin
                result.message = tr("登录已失效", "Logged out")
                return result
            }
            guard (200..<300).contains(status) else { throw ClientError.http(status) }
            let usage = try UsageParser.parse(body)
            result.session = usage.session
            result.weekly = usage.weekly
            result.models = usage.models
            result.extra = usage.extra
            result.updatedAt = Date()
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

    func writeSnapshot() {
        let list = accounts.map { account -> AccountSnapshot in
            var snapshot = snapshots[account.id]
                ?? AccountSnapshot(id: account.id.uuidString, name: account.name, plan: account.plan,
                                   status: .needsLogin, message: tr("未登录", "Not logged in"))
            snapshot.name = account.name
            snapshot.plan = account.plan ?? snapshot.plan
            return snapshot
        }
        do {
            try SharedStore.save(QuotaSnapshot(accounts: list, generatedAt: lastRefresh ?? Date(), language: language))
        } catch {
            NSLog("ClaudeQuota: could not write snapshot: \(error.localizedDescription)")
        }
        // WidgetKit rate-limits reloads, so only ask for one when something visible changed;
        // the widget's per-minute timeline keeps the countdowns moving in between.
        let signature = language.rawValue + ";" + list.map { item -> String in
            let models = item.models.map { "\($0.label)\(Int($0.percent))" }.joined(separator: ",")
            return "\(item.id)|\(item.name)|\(item.plan ?? "")|\(item.status.rawValue)|\(Int(item.sessionPercent))|\(Int(item.weeklyPercent))|\(models)"
        }.joined(separator: ";")
        if signature != lastSignature || Date().timeIntervalSince(lastReload) > 15 * 60 {
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

    func addAccount() {
        let number = accounts.count + 1
        accounts.append(AccountConfig(id: UUID(), name: language.pick("账号 \(number)", "Account \(number)")))
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
        config.orgId = nil
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
        let controller = LoginWindowController(accountName: account.name, store: dataStore(for: account)) { [weak self] org in
            guard let self else { return }
            self.loginControllers[account.id] = nil
            guard let org, var config = self.accounts.first(where: { $0.id == account.id }) else { return }
            config.orgId = org.id
            config.plan = org.plan
            self.update(config)
            Task { await self.refreshAll() }
        }
        loginControllers[account.id] = controller
        controller.showWindow(nil)
        NSApp.activate()
    }

    /// Fallback for when the built-in login page can't be used: paste the sessionKey cookie.
    func useSessionKey(_ rawKey: String, for account: AccountConfig) async {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, let cookie = HTTPCookie(properties: [
            .domain: ".claude.ai", .path: "/", .name: "sessionKey", .value: key,
            .secure: "TRUE", .expires: Date().addingTimeInterval(30 * 86400)
        ]) else { return }
        await dataStore(for: account).httpCookieStore.setCookie(cookie)
        var config = account
        config.orgId = nil
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
                NSLog("ClaudeQuota: launch at login change failed: \(error.localizedDescription)")
            }
            objectWillChange.send()
        }
    }
}
