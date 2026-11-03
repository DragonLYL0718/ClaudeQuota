import Foundation
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
}

extension ServiceClient {
    func owns(_ url: URL?) -> Bool {
        guard let name = url?.host?.lowercased() else { return false }
        return name == host || name.hasSuffix("." + host)
    }

    /// Throws for anything but a 2xx response; 401 and 403 mean the login has expired.
    func check(_ status: Int) throws {
        if status == 401 || status == 403 { throw ServiceError.loggedOut }
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

/// Lenient readers for the services' JSON.
enum JSONValue {
    static func number(_ value: Any?) -> Double? {
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

    static func object(_ data: Data, host: String) throws -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError.badResponse(host)
        }
        return json
    }
}
