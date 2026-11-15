import Foundation

enum AccountDisplayState: Equatable {
    case current, needsLogin, error, stale, noData

    var symbol: String {
        switch self {
        case .current: return "checkmark.circle"
        case .needsLogin: return "person.crop.circle.badge.exclamationmark"
        case .error: return "exclamationmark.triangle.fill"
        case .stale: return "clock.badge.exclamationmark"
        case .noData: return "questionmark.circle"
        }
    }

    func text(lang: AppLanguage, cached: Bool = false, compact: Bool = false) -> String {
        if compact {
            switch self {
            case .current: return lang.pick("已更新", "Updated")
            case .needsLogin: return lang.pick("需登录", "Log in")
            case .error: return lang.pick("失败", "Failed")
            case .stale: return lang.pick("已过期", "Stale")
            case .noData: return lang.pick("暂无数据", "No data")
            }
        }
        switch self {
        case .current: return lang.pick("已更新", "Updated")
        case .needsLogin: return lang.pick("需要重新登录", "Log in again")
        case .error:
            return cached ? lang.pick("刷新失败 · 缓存数据", "Refresh failed · cached")
                          : lang.pick("刷新失败", "Refresh failed")
        case .stale: return lang.pick("数据已过期", "Data out of date")
        case .noData: return lang.pick("暂无额度数据", "No usage data")
        }
    }
}

extension AccountSnapshot {
    /// Draw whichever windows exist, shortest first. A missing primary is not a 0% window.
    var displayWindows: [UsageWindow] {
        let windows = [primary, secondary].compactMap { $0 }.sorted { $0.seconds < $1.seconds }
        if !windows.isEmpty { return windows }
        if let model = models.max(by: { $0.percent < $1.percent }) { return [model] }
        if let extra {
            return [UsageWindow(label: "extra_usage", percent: extra.percent, seconds: 30 * 86400)]
        }
        return []
    }

    var displayPrimary: UsageWindow? { displayWindows.first }
    var displaySecondary: UsageWindow? { displayWindows.dropFirst().first }
    var hasUsageData: Bool { hasData || !models.isEmpty || extra != nil }

    func displayState(at now: Date) -> AccountDisplayState {
        if status == .needsLogin { return .needsLogin }
        if status == .error { return .error }
        if !hasUsageData { return .noData }
        if isStale(at: now) { return .stale }
        return .current
    }
}

struct WidgetFreshness {
    let oldestSuccess: Date?
    let state: AccountDisplayState

    init(accounts: [AccountSnapshot], now: Date) {
        oldestSuccess = accounts.filter(\.hasUsageData).compactMap(\.updatedAt).min()
        let states = accounts.map { $0.displayState(at: now) }
        // A successful account must not make a failed or uninitialized account look current.
        state = [.error, .needsLogin, .noData, .stale].first(where: states.contains) ?? .current
    }
}

enum WidgetAccountSelection {
    static func resolve(_ accounts: [AccountSnapshot], chosen: Set<String>) -> [AccountSnapshot] {
        chosen.isEmpty ? accounts : accounts.filter { chosen.contains($0.id) }
    }
}

enum WidgetTimelineSchedule {
    /// Dynamic date Text handles the ticking clock. Entries update status and forecast only.
    /// Coalesce nearby transitions so no two entries are less than five minutes apart.
    static func dates(accounts: [AccountSnapshot], now: Date) -> [Date] {
        let end = now.addingTimeInterval(2 * 3600)
        var candidates = stride(from: 15 * 60, through: 2 * 3600, by: 15 * 60)
            .map { now.addingTimeInterval(Double($0)) }
        for account in accounts {
            if let updated = account.updatedAt { candidates.append(updated.addingTimeInterval(20 * 60)) }
            candidates += [account.primary?.resetsAt, account.secondary?.resetsAt].compactMap { $0 }
        }
        var dates = [now]
        for candidate in candidates.filter({ $0 > now && $0 <= end }).sorted() {
            let last = dates[dates.count - 1]
            if candidate <= last { continue }
            let next = max(candidate, last.addingTimeInterval(5 * 60))
            guard next <= end else { continue }
            dates.append(next)
        }
        return dates
    }
}

enum WidgetRefreshSignal {
    static func advanced(from before: QuotaSnapshot?, to after: QuotaSnapshot?) -> Bool {
        guard let after else { return false }
        if let revision = after.refreshRevision { return revision != before?.refreshRevision }
        return after.generatedAt != before?.generatedAt
    }
}
