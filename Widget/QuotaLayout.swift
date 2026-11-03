import AppIntents
import SwiftUI
import WidgetKit

extension WidgetFamily {
    /// How many accounts fit on one page of this size.
    var capacity: Int {
        switch self {
        case .systemLarge: return 6
        default: return 4
        }
    }
}

enum Paging {
    /// Splits accounts into evenly filled pages, e.g. 7 on a 6-account size becomes 4 + 3,
    /// so every page lands on a layout made for its count.
    static func pages<T>(_ items: [T], capacity: Int) -> [[T]] {
        guard items.count > capacity, capacity > 0 else { return [items] }
        let pageCount = (items.count + capacity - 1) / capacity
        let perPage = (items.count + pageCount - 1) / pageCount
        return stride(from: 0, to: items.count, by: perPage).map {
            Array(items[$0..<min($0 + perPage, items.count)])
        }
    }
}

/// Where the shown accounts sit among the pages.
struct PageInfo {
    let current: Int
    /// The highest usage on each page, for the page dots.
    let levels: [Double]
}

/// The header with the refresh button, then the layout for the widget size and the number of
/// accounts on the page.
struct QuotaLayout: View {
    let family: WidgetFamily
    let accounts: [AccountSnapshot]
    let generatedAt: Date
    let now: Date
    let palette: Palette
    var page: PageInfo?
    var pageKey = ""

    var body: some View {
        VStack(spacing: 6) {
            WidgetHeader(family: family, generatedAt: generatedAt, now: now, palette: palette)
            // With several pages, clicking below the header turns the page. The header stays out
            // of this button, so the refresh button doesn't sit inside it.
            if let page {
                Button(intent: TurnPageIntent(key: pageKey)) {
                    VStack(spacing: 6) {
                        layout
                            .frame(maxHeight: .infinity)
                        PageDots(levels: page.levels, current: page.current, palette: palette)
                    }
                }
                .buttonStyle(.plain)
            } else {
                layout
                    .frame(maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder private var layout: some View {
        switch (family, accounts.count) {
        case (.systemSmall, 1):
            SmallHeroView(account: accounts[0], now: now, palette: palette)
        case (.systemSmall, 2):
            SmallPairView(accounts: accounts, now: now, palette: palette)
        case (.systemSmall, _):
            SmallGridView(accounts: accounts, palette: palette)
        case (.systemLarge, 1):
            LargeHeroView(account: accounts[0], now: now, palette: palette)
        case (.systemLarge, 2):
            LargePairView(accounts: accounts, now: now, palette: palette)
        case (.systemLarge, _):
            LargeListView(accounts: accounts, now: now, palette: palette)
        case (_, 1):
            MediumHeroView(account: accounts[0], now: now, palette: palette)
        case (_, 2):
            MediumPairView(accounts: accounts, now: now, palette: palette)
        default:
            MediumRowView(accounts: accounts, now: now, palette: palette)
        }
    }
}

struct EmptyStateView: View {
    let lang: AppLanguage

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text(lang.pick("打开「额度环」添加账号", "Open Quota Rings to add an account"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
