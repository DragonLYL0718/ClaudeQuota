import AppIntents
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
}

struct AccountQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [AccountEntity] {
        all().filter { identifiers.contains($0.id) }
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

/// The current page of each widget size and account selection. Widgets with the same size and
/// selection share it, because WidgetKit doesn't tell widget instances apart.
enum PageStore {
    static func page(_ key: String) -> Int { UserDefaults.standard.integer(forKey: "page." + key) }
    static func set(_ page: Int, for key: String) { UserDefaults.standard.set(page, forKey: "page." + key) }
}
