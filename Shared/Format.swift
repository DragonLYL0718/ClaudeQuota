import Foundation

enum Format {
    static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    /// "2:13 后" / "in 2:13" within a day, "周四 09:00" / "Thu 09:00" further out.
    static func countdown(to date: Date?, from now: Date, lang: AppLanguage) -> String {
        guard let date else { return lang.pick("未开始", "Not started") }
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return lang.pick("即将重置", "Resetting") }
        if seconds >= 86400 { return weekdayTime(date, lang: lang) }
        let clock = String(format: "%d:%02d", seconds / 3600, (seconds % 3600) / 60)
        return lang.pick("\(clock) 后", "in \(clock)")
    }

    /// "3:33 后重置" / "Resets in 3:33", "周六 00:00 重置" / "Resets Sat 00:00"
    static func resetPhrase(to date: Date?, from now: Date, lang: AppLanguage) -> String {
        guard let date else { return lang.pick("窗口未开始", "Window not started") }
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return lang.pick("即将重置", "Resetting now") }
        if seconds >= 86400 {
            let when = weekdayTime(date, lang: lang)
            return lang.pick("\(when) 重置", "Resets \(when)")
        }
        if seconds < 3600 {
            let minutes = max(1, seconds / 60)
            return lang.pick("\(minutes) 分钟后重置", "Resets in \(minutes) min")
        }
        let clock = String(format: "%d:%02d", seconds / 3600, (seconds % 3600) / 60)
        return lang.pick("\(clock) 后重置", "Resets in \(clock)")
    }

    /// "45 分钟" / "45 min", "1:20", "1 天 6 小时" / "1d 6h", "4 天" / "4 days"
    static func duration(_ interval: TimeInterval, lang: AppLanguage) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 3600 {
            let minutes = max(1, seconds / 60)
            return lang.pick("\(minutes) 分钟", "\(minutes) min")
        }
        if seconds < 86400 {
            return String(format: "%d:%02d", seconds / 3600, (seconds % 3600) / 60)
        }
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        if days < 3 && hours > 0 { return lang.pick("\(days) 天 \(hours) 小时", "\(days)d \(hours)h") }
        return lang.pick("\(days) 天", days == 1 ? "1 day" : "\(days) days")
    }

    /// "周四 09:00" / "Thu 09:00"
    static func weekdayTime(_ date: Date, lang: AppLanguage) -> String {
        let formatter = DateFormatter()
        formatter.locale = lang.locale
        formatter.dateFormat = "EEE HH:mm"
        return formatter.string(from: date)
    }

    static func updated(_ date: Date?, from now: Date, lang: AppLanguage) -> String {
        guard let date else { return lang.pick("尚未更新", "Not updated yet") }
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return lang.pick("刚刚更新", "Updated just now") }
        if minutes < 60 { return lang.pick("\(minutes) 分钟前更新", "Updated \(minutes) min ago") }
        return lang.pick("\(minutes / 60) 小时前更新", "Updated \(minutes / 60) h ago")
    }

    static func money(_ value: Double, currency: String) -> String {
        let symbols = ["USD": "$", "GBP": "£", "EUR": "€", "CNY": "¥", "JPY": "¥"]
        let symbol = symbols[currency.uppercased()] ?? currency + " "
        return symbol + String(format: value >= 100 ? "%.0f" : "%.2f", value)
    }
}
