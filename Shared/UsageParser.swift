import Foundation

/// Parses claude.ai's `/api/organizations/{org}/usage` response.
enum UsageParser {
    struct Result {
        var session: UsageWindow?
        var weekly: UsageWindow?
        var models: [UsageWindow]
        var extra: ExtraUsage?
    }

    static func parse(_ data: Data) throws -> Result {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "ClaudeQuota", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: tr("额度数据格式无法识别", "Unrecognised usage data")])
        }

        func window(_ key: String, _ label: String) -> UsageWindow? {
            guard let object = json[key] as? [String: Any],
                  let percent = number(object["utilization"]) else { return nil }
            return UsageWindow(label: label, percent: percent, resetsAt: date(object["resets_at"]))
        }

        // Per-model weekly limits: older responses use seven_day_<model>, newer ones a `limits` array.
        var models: [String: UsageWindow] = [:]
        let legacy = [("seven_day_fable", "Fable"), ("seven_day_opus", "Opus"),
                      ("seven_day_sonnet", "Sonnet"), ("seven_day_omelette", "Design")]
        for (key, label) in legacy {
            if let found = window(key, label), found.percent > 0 || found.resetsAt != nil {
                models[label.lowercased()] = found
            }
        }
        if let limits = json["limits"] as? [[String: Any]] {
            for limit in limits where (limit["kind"] as? String) == "weekly_scoped" {
                guard let percent = number(limit["percent"]) ?? number(limit["utilization"]) else { continue }
                let model = (limit["scope"] as? [String: Any])?["model"] as? [String: Any]
                let name = (model?["display_name"] as? String) ?? (model?["id"] as? String) ?? "模型"
                models[name.lowercased()] = UsageWindow(label: name, percent: percent,
                                                        resetsAt: date(limit["resets_at"]))
            }
        }
        let order = ["fable", "opus", "sonnet", "design"]
        let sortedModels = models.values.sorted { lhs, rhs in
            let left = order.firstIndex(of: lhs.label.lowercased()) ?? order.count
            let right = order.firstIndex(of: rhs.label.lowercased()) ?? order.count
            return left == right ? lhs.label < rhs.label : left < right
        }

        // Extra usage amounts are reported in cents.
        var extra: ExtraUsage?
        if let spend = json["extra_usage"] as? [String: Any],
           (spend["is_enabled"] as? Bool) == true,
           let limitCents = number(spend["monthly_limit"]), limitCents > 0 {
            extra = ExtraUsage(used: (number(spend["used_credits"]) ?? 0) / 100,
                               limit: limitCents / 100,
                               currency: (spend["currency"] as? String) ?? "USD")
        }

        return Result(session: window("five_hour", "5 小时"),
                      weekly: window("seven_day", "本周"),
                      models: sortedModels,
                      extra: extra)
    }

    static func number(_ value: Any?) -> Double? {
        guard let value else { return nil }
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let text as String:
            return Double(text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
        default:
            return nil
        }
    }

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: text) { return parsed }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
