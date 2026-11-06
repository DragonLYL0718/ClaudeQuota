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
        Self.pick(try await organizations(in: webView)).map { ServiceAccount(id: $0.id, plan: $0.plan) }
    }

    private func organizations(in webView: WKWebView) async throws -> [Organization] {
        let (status, body) = try await webView.get("/api/organizations")
        do { try check(status, body: body) }
        catch ServiceError.loggedOut { return [] }
        return try Self.parseOrganizations(body)
    }

    func fetch(in webView: WKWebView, preferredAccountID: String?) async throws -> AccountFetchResult {
        let organizations = try await organizations(in: webView)
        guard let organization = organizations.first(where: { $0.id == preferredAccountID }) ?? Self.pick(organizations) else {
            throw ServiceError.loggedOut
        }
        let account = ServiceAccount(id: organization.id, plan: organization.plan)
        return AccountFetchResult(account: account, usage: try await usage(in: webView, accountId: account.id))
    }

    func usage(in webView: WKWebView, accountId: String) async throws -> ServiceUsage {
        let (status, body) = try await webView.get("/api/organizations/\(accountId)/usage")
        try check(status, body: body)
        return try Self.parseUsage(body)
    }

    // MARK: Organizations

    static func parseOrganizations(_ data: Data) throws -> [Organization] {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw ServiceError.badResponse("claude.ai")
        }
        return try array.map { org in
            guard let id = (org["uuid"] ?? org["id"]) as? String, !id.isEmpty else {
                throw ServiceError.badResponse("claude.ai")
            }
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
        let knownKeys = ["five_hour", "seven_day", "seven_day_fable", "seven_day_opus", "seven_day_sonnet",
                         "seven_day_omelette", "limits", "extra_usage"]
        guard knownKeys.contains(where: { json.keys.contains($0) }), json["error"] == nil else {
            throw ServiceError.badResponse("claude.ai")
        }

        func resetDate(_ raw: Any?) throws -> Date? {
            if JSONValue.isMissing(raw) { return nil }
            guard let date = JSONValue.date(raw) else { throw ServiceError.badResponse("claude.ai") }
            return date
        }

        func window(_ key: String, _ label: String, _ seconds: TimeInterval) throws -> UsageWindow? {
            if JSONValue.isMissing(json[key]) { return nil }
            guard let object = json[key] as? [String: Any],
                  let percent = JSONValue.number(object["utilization"], in: 0...100) else {
                throw ServiceError.badResponse("claude.ai")
            }
            return UsageWindow(label: label, percent: percent, resetsAt: try resetDate(object["resets_at"]),
                               seconds: seconds)
        }

        // Per-model weekly limits: older responses use seven_day_<model>, newer ones a `limits` array.
        var models: [String: UsageWindow] = [:]
        let legacy = [("seven_day_fable", "Fable"), ("seven_day_opus", "Opus"),
                      ("seven_day_sonnet", "Sonnet"), ("seven_day_omelette", "Design")]
        for (key, label) in legacy {
            if let found = try window(key, label, UsageWindow.week), found.percent > 0 || found.resetsAt != nil {
                models[label.lowercased()] = found
            }
        }
        if !JSONValue.isMissing(json["limits"]) {
            guard let limits = json["limits"] as? [[String: Any]] else { throw ServiceError.badResponse("claude.ai") }
            for limit in limits where (limit["kind"] as? String) == "weekly_scoped" {
                guard let percent = JSONValue.number(limit["percent"] ?? limit["utilization"], in: 0...100) else {
                    throw ServiceError.badResponse("claude.ai")
                }
                let model = (limit["scope"] as? [String: Any])?["model"] as? [String: Any]
                let name = (model?["display_name"] as? String) ?? (model?["id"] as? String) ?? "Model"
                models[name.lowercased()] = UsageWindow(label: name, percent: percent,
                                                        resetsAt: try resetDate(limit["resets_at"]),
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
        if !JSONValue.isMissing(json["extra_usage"]) {
            guard let spend = json["extra_usage"] as? [String: Any], let enabled = spend["is_enabled"] as? Bool else {
                throw ServiceError.badResponse("claude.ai")
            }
            if enabled {
                // A null/zero monthly limit denotes uncapped extra usage; there is no bounded bar.
                let rawLimit = spend["monthly_limit"]
                let limit = JSONValue.isMissing(rawLimit) ? 0 : JSONValue.number(rawLimit, in: 0...1e12)
                let rawUsed = spend["used_credits"]
                let used = JSONValue.isMissing(rawUsed) ? 0 : JSONValue.number(rawUsed, in: 0...1e12)
                guard let limit, let used else { throw ServiceError.badResponse("claude.ai") }
                if limit > 0 {
                    extra = ExtraUsage(used: used / 100, limit: limit / 100,
                                       currency: (spend["currency"] as? String) ?? "USD")
                }
            }
        }

        return ServiceUsage(primary: try window("five_hour", "five_hour", UsageWindow.fiveHours),
                            secondary: try window("seven_day", "seven_day", UsageWindow.week),
                            models: sortedModels,
                            extra: extra)
    }
}
