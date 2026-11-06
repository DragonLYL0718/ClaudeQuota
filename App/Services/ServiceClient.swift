import Foundation
import CoreFoundation
import WebKit

/// Who is logged in to a web session.
struct ServiceAccount {
    let id: String
    let plan: String?
}

/// The usage numbers read from a service.
struct ServiceUsage {
    var plan: String?
    var primary: UsageWindow?
    var secondary: UsageWindow?
    var models: [UsageWindow] = []
    var extra: ExtraUsage?
}

/// What the app needs to know about one service's website to log in and read usage.
@MainActor
protocol ServiceClient {
    var host: String { get }
    /// The page the login window opens.
    var loginURL: URL { get }
    /// A light page on the service's origin; usage requests run from it.
    var originURL: URL { get }
    /// Name prefix of the cookie that appears once logged in.
    var sessionCookie: String { get }
    /// The logged-in account, or nil when this web view isn't logged in.
    func account(in webView: WKWebView) async throws -> ServiceAccount?
    /// Throws `ServiceError.loggedOut` once the login has expired.
    func usage(in webView: WKWebView, accountId: String) async throws -> ServiceUsage
    func fetch(in webView: WKWebView, preferredAccountID: String?) async throws -> AccountFetchResult
}

extension ServiceClient {
    func owns(_ url: URL?) -> Bool {
        guard let name = url?.host?.lowercased() else { return false }
        return name == host || name.hasSuffix("." + host)
    }

    func fetch(in webView: WKWebView, preferredAccountID: String?) async throws -> AccountFetchResult {
        guard let account = try await account(in: webView) else { throw ServiceError.loggedOut }
        return AccountFetchResult(account: account, usage: try await usage(in: webView, accountId: account.id))
    }

    /// A generic 403 may be a challenge or a permissions error, not an expired session.
    func check(_ status: Int, body: Data? = nil) throws {
        if status == 401 { throw ServiceError.loggedOut }
        if status == 403, let body,
           let json = try? JSONValue.object(body, host: host) {
            let error = (json["error"] as? [String: Any]) ?? (json["detail"] as? [String: Any]) ?? json
            let code = (error["code"] as? String) ?? (error["type"] as? String) ?? ""
            if ["authentication_error", "invalid_token", "token_expired", "session_expired", "unauthenticated"].contains(code) {
                throw ServiceError.loggedOut
            }
        }
        guard (200..<300).contains(status) else { throw ServiceError.http(host, status) }
    }
}

extension Service {
    @MainActor var client: ServiceClient {
        switch self {
        case .claude: return ClaudeClient()
        case .chatgpt: return ChatGPTClient()
        }
    }
}

/// Accept numeric strings used by the APIs, but never boolean or non-finite numbers.
enum JSONValue {
    static func number(_ value: Any?) -> Double? {
        let result: Double?
        switch value {
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            result = number.doubleValue
        case let text as String:
            var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasSuffix("%") { text.removeLast() }
            result = Double(text.trimmingCharacters(in: .whitespaces))
        default:
            return nil
        }
        guard let result, result.isFinite else { return nil }
        return result
    }

    static func number(_ value: Any?, in range: ClosedRange<Double>) -> Double? {
        guard let number = number(value), range.contains(number) else { return nil }
        return number
    }

    static func isMissing(_ value: Any?) -> Bool { value == nil || value is NSNull }

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: text) { return parsed }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    static func object(_ data: Data, host: String) throws -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError.badResponse(host)
        }
        return json
    }
}
