import AppIntents
import SwiftUI
import WidgetKit

struct QuotaEntry: TimelineEntry {
    let date: Date
    let snapshot: QuotaSnapshot?
    /// The accounts on the current page.
    var accounts: [AccountSnapshot] = []
    var page: PageInfo?
    var pageKey = ""
}

struct QuotaProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> QuotaEntry {
        entry(.sample, for: ChooseAccountsIntent(), in: context, date: Date())
    }

    func snapshot(for configuration: ChooseAccountsIntent, in context: Context) async -> QuotaEntry {
        let saved = SharedStore.load()
        let hasAccounts = !(saved?.accounts.isEmpty ?? true)
        return entry(context.isPreview && !hasAccounts ? .sample : saved, for: configuration, in: context, date: Date())
    }

    func timeline(for configuration: ChooseAccountsIntent, in context: Context) async -> Timeline<QuotaEntry> {
        let snapshot = SharedStore.load()
        let now = Date()
        let start = Calendar.current.dateInterval(of: .minute, for: now)?.start ?? now
        // One entry a minute keeps the countdowns current between the app's refreshes.
        let entries = (0..<30).map {
            entry(snapshot, for: configuration, in: context, date: start.addingTimeInterval(Double($0) * 60))
        }
        return Timeline(entries: entries, policy: .atEnd)
    }

    /// The chosen accounts (all of them when none are chosen), in the app's order, cut to the current page.
    private func entry(_ snapshot: QuotaSnapshot?, for configuration: ChooseAccountsIntent,
                       in context: Context, date: Date) -> QuotaEntry {
        var result = QuotaEntry(date: date, snapshot: snapshot)
        guard let all = snapshot?.accounts else { return result }
        let chosen = Set((configuration.accounts ?? []).map(\.id))
        var accounts = all.filter { chosen.contains($0.id) }
        // Chosen accounts that were since removed fall back to showing everything.
        if accounts.isEmpty { accounts = all }

        let pages = Paging.pages(accounts, capacity: context.family.capacity)
        let key = "\(context.family)|" + (chosen.isEmpty ? "all" : chosen.sorted().joined(separator: ","))
        let current = PageStore.page(key) % pages.count
        result.accounts = pages[current]
        result.pageKey = key
        if pages.count > 1 {
            result.page = PageInfo(current: current,
                                   levels: pages.map { $0.map(\.peakPercent).max() ?? 0 })
        }
        return result
    }
}

struct QuotaWidgetView: View {
    let entry: QuotaEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let lang = entry.snapshot?.language ?? .system
        let palette = Palette(scheme: scheme, monochrome: renderingMode != .fullColor, lang: lang)
        if let snapshot = entry.snapshot, !entry.accounts.isEmpty {
            let isStale = entry.date.timeIntervalSince(snapshot.generatedAt) > 20 * 60
            let layout = QuotaLayout(family: family, accounts: entry.accounts, generatedAt: snapshot.generatedAt,
                                     now: entry.date, palette: palette, page: entry.page)
            Group {
                // With several pages, clicking anywhere on the widget turns the page.
                if entry.page != nil {
                    Button(intent: TurnPageIntent(key: entry.pageKey)) { layout }
                        .buttonStyle(.plain)
                } else {
                    layout
                }
            }
            .overlay(alignment: .topTrailing) {
                if isStale && family != .systemLarge {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            EmptyStateView(lang: lang)
        }
    }
}

@main
struct QuotaRingsWidgetBundle: WidgetBundle {
    var body: some Widget {
        QuotaRingsWidget()
    }
}

struct QuotaRingsWidget: Widget {
    var body: some WidgetConfiguration {
        let lang = SharedStore.load()?.language ?? .system
        // The kind keeps the app's former name so widgets already on the desktop stay put.
        return AppIntentConfiguration(kind: "ClaudeQuotaWidget", intent: ChooseAccountsIntent.self,
                                      provider: QuotaProvider()) { entry in
            QuotaWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    WidgetBackground()
                }
        }
        .configurationDisplayName(lang.pick("额度环", "Quota Rings"))
        .description(lang.pick("一眼看清 Claude 与 ChatGPT 账号的 5 小时和每周额度。",
                               "See the 5-hour and weekly limits of your Claude and ChatGPT accounts at a glance."))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
