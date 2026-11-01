import Foundation

enum Format {
    static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    /// "2:13 后" within a day, "周四 09:00" further out.
    static func countdown(to date: Date?, from now: Date) -> String {
        guard let date else { return "未开始" }
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return "即将重置" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours >= 24 { return weekdayTime(date) }
        return String(format: "%d:%02d 后", hours, minutes)
    }

    /// "周四 09:00"
    static func weekdayTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEE HH:mm"
        return formatter.string(from: date)
    }

    static func updated(_ date: Date?, from now: Date) -> String {
        guard let date else { return "尚未更新" }
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "刚刚更新" }
        if minutes < 60 { return "\(minutes) 分钟前更新" }
        return "\(minutes / 60) 小时前更新"
    }

    static func money(_ value: Double, currency: String) -> String {
        let symbols = ["USD": "$", "GBP": "£", "EUR": "€", "CNY": "¥", "JPY": "¥"]
        let symbol = symbols[currency.uppercased()] ?? currency + " "
        return symbol + String(format: value >= 100 ? "%.0f" : "%.2f", value)
    }
}
