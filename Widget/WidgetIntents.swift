import AppIntents
import AppKit
import WidgetKit

/// An account as offered in Edit Widget, read from the app's snapshot.
struct AccountEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Account"
    static var defaultQuery = AccountQuery()

    let id: String
    let name: String
    let product: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(product)")
    }

    init(_ account: AccountSnapshot) {
        id = account.id
        name = account.name
        product = account.product
    }

    init(removedID: String) {
        id = removedID
        name = AppLanguage.system.pick("已移除的账号", "Removed account")
        product = ""
    }
}

struct AccountQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [AccountEntity] {
        let available = Dictionary(uniqueKeysWithValues: all().map { ($0.id, $0) })
        // Keep the selected identifier even after deletion, so it cannot silently turn into
        // the empty selection that means "all accounts".
        return identifiers.map { available[$0] ?? AccountEntity(removedID: $0) }
    }

    func suggestedEntities() async throws -> [AccountEntity] { all() }

    private func all() -> [AccountEntity] {
        (SharedStore.load()?.accounts ?? []).map(AccountEntity.init)
    }
}

/// Lets each widget show its own accounts; none chosen means all of them.
struct ChooseAccountsIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Choose Accounts"
    static var description = IntentDescription("Leave empty to show every account, in the order set in the app.")

    @Parameter(title: "Accounts")
    var accounts: [AccountEntity]?
}

/// Flips a paged widget to its next page. Runs in the widget extension, which keeps the page
/// in its own defaults, so no App Group is needed.
struct TurnPageIntent: AppIntent {
    static var title: LocalizedStringResource = "Next Page"
    static var isDiscoverable = false

    @Parameter(title: "Page Key")
    var key: String

    init() {}

    init(key: String) {
        self.key = key
    }

    func perform() async throws -> some IntentResult {
        PageStore.set(PageStore.page(key) + 1, for: key)
        return .result()
    }
}

/// Asks the app to fetch new numbers now. The sandboxed widget can't reach the services itself,
/// so it signals the app (launching it if needed), then waits for the new snapshot, because the
/// system redraws the widget as soon as this returns.
struct RefreshIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh"
    static var isDiscoverable = false

    func perform() async throws -> some IntentResult {
        let before = SharedStore.load()
        if NSRunningApplication.runningApplications(withBundleIdentifier: SharedStore.appBundleId).isEmpty {
            // The app refreshes when it starts. The widget sits in QuotaRings.app/Contents/PlugIns/.
            let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            guard (try? await NSWorkspace.shared.openApplication(at: app, configuration: configuration)) != nil else {
                return .result()
            }
        } else {
            DistributedNotificationCenter.default().postNotificationName(
                SharedStore.refreshRequest, object: nil, userInfo: nil, deliverImmediately: true)
        }
        // At most 15 s, as the system ends long-running extensions. A slower refresh still reaches
        // the widget, because the app reloads it after a manual refresh.
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 500_000_000)
            if WidgetRefreshSignal.advanced(from: before, to: SharedStore.load()) { break }
        }
        return .result()
    }
}

/// The current page of each widget size and account selection. Widgets with the same size and
/// selection share it, because WidgetKit doesn't tell widget instances apart.
enum PageStore {
    static func page(_ key: String) -> Int { UserDefaults.standard.integer(forKey: "page." + key) }
    static func set(_ page: Int, for key: String) { UserDefaults.standard.set(page, forKey: "page." + key) }
}
