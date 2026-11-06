import Foundation

/// A forecast is only meaningful while the underlying observation is current.
struct PaceStatus {
    enum Kind { case normal, fast, exhausted, unknown }

    let kind: Kind
    let text: String

    init(account: AccountSnapshot, now: Date, lang: AppLanguage) {
        guard account.status == .ok, account.hasData, !account.isStale(at: now) else {
            kind = .unknown
            text = lang.pick("暂无法预测", "Forecast unavailable")
            return
        }
        let windows = [account.primary, account.secondary].compactMap { $0 }
            .filter { ($0.resetsAt?.timeIntervalSince(now) ?? 0) > 0 && $0.seconds > 0 }
        // Inspect every limit before forecasting: a depleted weekly window takes precedence
        // over a fast, but still available, five-hour window.
        if let exhausted = windows.first(where: { $0.percent >= 100 }) {
            let name = Format.windowName(exhausted.seconds, lang: lang)
            kind = .exhausted
            text = lang.pick("\(name)额度已用完", "\(name) limit used up")
            return
        }
        let forecasts: [(UsageWindow, TimeInterval)] = windows.compactMap { window in
            guard let reset = window.resetsAt else { return nil }
            let remaining = reset.timeIntervalSince(now)
            let elapsed = window.seconds - remaining
            guard elapsed > window.seconds * 0.1, window.percent > 0 else { return nil }
            let secondsToFull = (100 - window.percent) / (window.percent / elapsed)
            guard secondsToFull.isFinite, secondsToFull < remaining else { return nil }
            return (window, secondsToFull)
        }
        if let (window, secondsToFull) = forecasts.min(by: { $0.1 < $1.1 }) {
            let name = Format.windowName(window.seconds, lang: lang)
            let duration = Format.duration(secondsToFull, lang: lang)
            let joiner = duration.last?.isNumber == true ? " " : ""
            kind = .fast
            text = lang.pick("\(name)约 \(duration)\(joiner)后用完", "\(name) runs out in ~\(duration)")
        } else if windows.isEmpty {
            kind = .unknown
            text = lang.pick("暂无法预测", "Forecast unavailable")
        } else {
            kind = .normal
            text = lang.pick("节奏正常", "On track")
        }
    }

    var symbol: String {
        switch kind {
        case .normal: return "checkmark.circle"
        case .fast: return "bolt.fill"
        case .exhausted: return "hourglass"
        case .unknown: return "questionmark.circle"
        }
    }
}
