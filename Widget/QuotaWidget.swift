import SwiftUI
import WidgetKit

struct QuotaEntry: TimelineEntry {
    let date: Date
    let snapshot: QuotaSnapshot?
}

struct QuotaProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuotaEntry {
        QuotaEntry(date: Date(), snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (QuotaEntry) -> Void) {
        let saved = SharedStore.load()
        let hasAccounts = !(saved?.accounts.isEmpty ?? true)
        completion(QuotaEntry(date: Date(), snapshot: context.isPreview && !hasAccounts ? .sample : saved))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuotaEntry>) -> Void) {
        let snapshot = SharedStore.load()
        let now = Date()
        let start = Calendar.current.dateInterval(of: .minute, for: now)?.start ?? now
        // One entry a minute keeps the "2:13 后" countdowns current between the app's refreshes.
        let entries = (0..<30).map {
            QuotaEntry(date: start.addingTimeInterval(Double($0) * 60), snapshot: snapshot)
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

struct QuotaWidgetView: View {
    let entry: QuotaEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let palette = Palette(scheme: scheme, monochrome: renderingMode != .fullColor)
        if let snapshot = entry.snapshot, !snapshot.accounts.isEmpty {
            let accounts = Array(snapshot.accounts.prefix(2))
            let isStale = entry.date.timeIntervalSince(snapshot.generatedAt) > 20 * 60
            Group {
                switch family {
                case .systemSmall:
                    SmallQuotaView(accounts: accounts, now: entry.date, palette: palette)
                case .systemLarge:
                    LargeQuotaView(snapshot: snapshot, now: entry.date, palette: palette)
                default:
                    MediumQuotaView(accounts: accounts, now: entry.date, palette: palette)
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
            EmptyStateView()
        }
    }
}

@main
struct ClaudeQuotaWidgetBundle: WidgetBundle {
    var body: some Widget {
        ClaudeQuotaWidget()
    }
}

struct ClaudeQuotaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ClaudeQuotaWidget", provider: QuotaProvider()) { entry in
            QuotaWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    WidgetBackground()
                }
        }
        .configurationDisplayName("Claude 额度")
        .description("同时查看两个 Claude 账号的 5 小时与本周额度。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
