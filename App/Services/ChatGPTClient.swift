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
        return Self.account(from: token)
    }

    private static func account(from token: String) -> ServiceAccount {
        let claims = Self.authClaims(token)
        return ServiceAccount(id: claims["chatgpt_account_id"] as? String ?? "",
                              plan: Self.planName(claims["chatgpt_plan_type"] as? String))
    }

    func usage(in webView: WKWebView, accountId: String) async throws -> ServiceUsage {
        guard let token = try await accessToken(in: webView) else { throw ServiceError.loggedOut }
        return try await usage(in: webView, accountId: accountId, token: token)
    }

    func fetch(in webView: WKWebView, preferredAccountID: String?) async throws -> AccountFetchResult {
        guard let token = try await accessToken(in: webView) else { throw ServiceError.loggedOut }
        let account = Self.account(from: token)
        return AccountFetchResult(account: account, usage: try await usage(in: webView, accountId: account.id, token: token))
    }

    private func usage(in webView: WKWebView, accountId: String, token: String) async throws -> ServiceUsage {
        var headers = ["Authorization": "Bearer \(token)"]
        if !accountId.isEmpty { headers["ChatGPT-Account-Id"] = accountId }
        let (status, body) = try await webView.get("/backend-api/wham/usage", headers: headers)
        try check(status, body: body)
        return try Self.parseUsage(body)
    }

    /// Nil when the web session isn't logged in.
    private func accessToken(in webView: WKWebView) async throws -> String? {
        let (status, body) = try await webView.get("/api/auth/session")
        do { try check(status, body: body) }
        catch ServiceError.loggedOut { return nil }
        return try Self.parseSession(body)
    }

    // MARK: Parsing

    static func parseSession(_ data: Data) throws -> String? {
        let json = try JSONValue.object(data, host: "chatgpt.com")
        if json.isEmpty { return nil }
        guard let token = json["accessToken"] as? String, !token.isEmpty else {
            throw ServiceError.badResponse("chatgpt.com")
        }
        return token
    }

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
        guard json.keys.contains("rate_limit"), json["error"] == nil else { throw ServiceError.badResponse("chatgpt.com") }
        // An explicitly empty response still names its supported window fields.
        let limits: [String: Any]
        if json["rate_limit"] is NSNull {
            guard json["plan_type"] as? String != nil else { throw ServiceError.badResponse("chatgpt.com") }
            limits = ["primary_window": NSNull(), "secondary_window": NSNull()]
        } else {
            guard let value = json["rate_limit"] as? [String: Any],
                  value.keys.contains("primary_window") || value.keys.contains("secondary_window") else {
                throw ServiceError.badResponse("chatgpt.com")
            }
            limits = value
        }

        func window(_ key: String, fallbackSeconds: TimeInterval) throws -> UsageWindow? {
            if JSONValue.isMissing(limits[key]) { return nil }
            guard let object = limits[key] as? [String: Any],
                  let percent = JSONValue.number(object["used_percent"], in: 0...100) else {
                throw ServiceError.badResponse("chatgpt.com")
            }
            var reset: Date?
            if !JSONValue.isMissing(object["reset_at"]) {
                guard let at = JSONValue.number(object["reset_at"], in: 0...253402300799000) else {
                    throw ServiceError.badResponse("chatgpt.com")
                }
                // Seconds since 1970, or milliseconds in some responses.
                if at > 0 { reset = Date(timeIntervalSince1970: at > 1e10 ? at / 1000 : at) }
            }
            if reset == nil, !JSONValue.isMissing(object["reset_after_seconds"]) {
                guard let after = JSONValue.number(object["reset_after_seconds"], in: 0...(366 * 86400)) else {
                    throw ServiceError.badResponse("chatgpt.com")
                }
                reset = now.addingTimeInterval(after)
            }
            let rawSeconds = object["limit_window_seconds"]
            let seconds = JSONValue.isMissing(rawSeconds) ? fallbackSeconds : JSONValue.number(rawSeconds, in: 1...(366 * 86400))
            guard let seconds else { throw ServiceError.badResponse("chatgpt.com") }
            return UsageWindow(label: key, percent: percent, resetsAt: reset, seconds: seconds)
        }

        return ServiceUsage(plan: planName(json["plan_type"] as? String),
                            primary: try window("primary_window", fallbackSeconds: UsageWindow.fiveHours),
                            secondary: try window("secondary_window", fallbackSeconds: UsageWindow.week))
    }
}
