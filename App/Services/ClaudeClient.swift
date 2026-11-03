import Foundation
import WebKit

/// claude.ai: the organization list identifies the account, `/api/organizations/{org}/usage` has the limits.
struct ClaudeClient: ServiceClient {
    struct Organization {
        let id: String
        let plan: String?
        let capabilities: [String]
    }

    let host = "claude.ai"
    let loginURL = URL(string: "https://claude.ai/login")!
    let originURL = URL(string: "https://claude.ai/api/organizations")!
    let sessionCookie = "sessionKey"

    func account(in webView: WKWebView) async throws -> ServiceAccount? {
        let (status, body) = try await webView.get("/api/organizations")
        if status == 401 || status == 403 { return nil }
        try check(status)
        return Self.pick(Self.parseOrganizations(body)).map { ServiceAccount(id: $0.id, plan: $0.plan) }
    }

    func usage(in webView: WKWebView, accountId: String) async throws -> ServiceUsage {
        let (status, body) = try await webView.get("/api/organizations/\(accountId)/usage")
        try check(status)
        return try Self.parseUsage(body)
    }

    // MARK: Organizations

    static func parseOrganizations(_ data: Data) -> [Organization] {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return array.compactMap { org in
            guard let id = (org["uuid"] ?? org["id"]) as? String else { return nil }
            let capabilities = org["capabilities"] as? [String] ?? []
            return Organization(id: id,
                                plan: planName(capabilities: capabilities, tier: org["rate_limit_tier"] as? String),
                                capabilities: capabilities)
        }
    }

    /// Prefers the organization that holds the Claude subscription.
    static func pick(_ orgs: [Organization]) -> Organization? {
        orgs.first { $0.capabilities.contains("chat") && $0.plan != nil }
            ?? orgs.first { $0.capabilities.contains("chat") }
            ?? orgs.first
    }

    static func planName(capabilities: [String], tier: String?) -> String? {
        let text = (capabilities + [tier ?? ""]).joined(separator: " ").lowercased()
        if text.contains("enterprise") { return "Enterprise" }
        if text.contains("raven") || text.contains("team") { return "Team" }
        if text.contains("max_20x") { return "Max 20×" }
        if text.contains("max_5x") { return "Max 5×" }
        if text.contains("max") { return "Max" }
        if text.contains("pro") { return "Pro" }
        return nil
    }

    // MARK: Usage

    static func parseUsage(_ data: Data) throws -> ServiceUsage {
        let json = try JSONValue.object(data, host: "claude.ai")

        func window(_ key: String, _ label: String, _ seconds: TimeInterval) -> UsageWindow? {
            guard let object = json[key] as? [String: Any],
                  let percent = JSONValue.number(object["utilization"]) else { return nil }
            return UsageWindow(label: label, percent: percent, resetsAt: JSONValue.date(object["resets_at"]),
                               seconds: seconds)
        }

        // Per-model weekly limits: older responses use seven_day_<model>, newer ones a `limits` array.
        var models: [String: UsageWindow] = [:]
        let legacy = [("seven_day_fable", "Fable"), ("seven_day_opus", "Opus"),
                      ("seven_day_sonnet", "Sonnet"), ("seven_day_omelette", "Design")]
        for (key, label) in legacy {
            if let found = window(key, label, UsageWindow.week), found.percent > 0 || found.resetsAt != nil {
                models[label.lowercased()] = found
            }
        }
        if let limits = json["limits"] as? [[String: Any]] {
            for limit in limits where (limit["kind"] as? String) == "weekly_scoped" {
                guard let percent = JSONValue.number(limit["percent"]) ?? JSONValue.number(limit["utilization"]) else { continue }
                let model = (limit["scope"] as? [String: Any])?["model"] as? [String: Any]
                let name = (model?["display_name"] as? String) ?? (model?["id"] as? String) ?? "Model"
                models[name.lowercased()] = UsageWindow(label: name, percent: percent,
                                                        resetsAt: JSONValue.date(limit["resets_at"]),
                                                        seconds: UsageWindow.week)
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
           let limitCents = JSONValue.number(spend["monthly_limit"]), limitCents > 0 {
            extra = ExtraUsage(used: (JSONValue.number(spend["used_credits"]) ?? 0) / 100,
                               limit: limitCents / 100,
                               currency: (spend["currency"] as? String) ?? "USD")
        }

        return ServiceUsage(primary: window("five_hour", "five_hour", UsageWindow.fiveHours),
                            secondary: window("seven_day", "seven_day", UsageWindow.week),
                            models: sortedModels,
                            extra: extra)
    }
}
