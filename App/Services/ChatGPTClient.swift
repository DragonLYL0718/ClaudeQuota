import Foundation
import WebKit

/// chatgpt.com: the web session hands out an access token, which reads the Codex usage limits
/// (a 5-hour and a weekly window) from the same private endpoint the Codex CLI uses.
struct ChatGPTClient: ServiceClient {
    let host = "chatgpt.com"
    let loginURL = URL(string: "https://chatgpt.com/auth/login")!
    let originURL = URL(string: "https://chatgpt.com/api/auth/session")!
    /// May be split into `.0`, `.1`… when it is large.
    let sessionCookie = "__Secure-next-auth.session-token"

    func account(in webView: WKWebView) async throws -> ServiceAccount? {
        guard let token = try await accessToken(in: webView) else { return nil }
        let claims = Self.authClaims(token)
        return ServiceAccount(id: claims["chatgpt_account_id"] as? String ?? "",
                              plan: Self.planName(claims["chatgpt_plan_type"] as? String))
    }

    func usage(in webView: WKWebView, accountId: String) async throws -> ServiceUsage {
        guard let token = try await accessToken(in: webView) else { throw ServiceError.loggedOut }
        var headers = ["Authorization": "Bearer \(token)"]
        if !accountId.isEmpty { headers["ChatGPT-Account-Id"] = accountId }
        let (status, body) = try await webView.get("/backend-api/wham/usage", headers: headers)
        try check(status)
        return try Self.parseUsage(body)
    }

    /// Nil when the web session isn't logged in.
    private func accessToken(in webView: WKWebView) async throws -> String? {
        let (status, body) = try await webView.get("/api/auth/session")
        if status == 401 || status == 403 { return nil }
        try check(status)
        let token = (try? JSONValue.object(body, host: host))?["accessToken"] as? String
        return token?.isEmpty == false ? token : nil
    }

    // MARK: Parsing

    /// The `https://api.openai.com/auth` claim of the access token (a JWT).
    static func authClaims(_ token: String) -> [String: Any] {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return [:] }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return payload["https://api.openai.com/auth"] as? [String: Any] ?? [:]
    }

    static func planName(_ type: String?) -> String? {
        guard let type, !type.isEmpty else { return nil }
        let names = ["plus": "Plus", "pro": "Pro", "team": "Team", "business": "Business",
                     "enterprise": "Enterprise", "edu": "Edu", "free": "Free", "go": "Go"]
        return names[type.lowercased()] ?? type.capitalized
    }

    static func parseUsage(_ data: Data, now: Date = Date()) throws -> ServiceUsage {
        let json = try JSONValue.object(data, host: "chatgpt.com")
        let limits = json["rate_limit"] as? [String: Any]

        func window(_ key: String, fallbackSeconds: TimeInterval) -> UsageWindow? {
            guard let object = limits?[key] as? [String: Any],
                  let percent = JSONValue.number(object["used_percent"]) else { return nil }
            var reset: Date?
            if let at = JSONValue.number(object["reset_at"]), at > 0 {
                // Seconds since 1970, or milliseconds in some responses.
                reset = Date(timeIntervalSince1970: at > 1e10 ? at / 1000 : at)
            } else if let after = JSONValue.number(object["reset_after_seconds"]) {
                reset = now.addingTimeInterval(after)
            }
            let seconds = JSONValue.number(object["limit_window_seconds"]) ?? fallbackSeconds
            return UsageWindow(label: key, percent: percent, resetsAt: reset, seconds: seconds)
        }

        return ServiceUsage(plan: planName(json["plan_type"] as? String),
                            primary: window("primary_window", fallbackSeconds: UsageWindow.fiveHours),
                            secondary: window("secondary_window", fallbackSeconds: UsageWindow.week))
    }
}
