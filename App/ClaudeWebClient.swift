import Foundation
import WebKit

struct OrgInfo: Sendable {
    let id: String
    let name: String
    let plan: String?
    let capabilities: [String]
}

enum ClientError: LocalizedError {
    case timeout
    case badResponse
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .timeout: return "连接 claude.ai 超时"
        case .badResponse: return "claude.ai 返回了无法识别的内容"
        case .http(let code): return "claude.ai 返回错误 \(code)"
        }
    }
}

/// Talks to claude.ai from inside a hidden web view that uses one account's own cookie store,
/// so requests look exactly like the logged-in website (and get through Cloudflare checks).
@MainActor
final class ClaudeWebClient: NSObject, WKNavigationDelegate {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    private let webView: WKWebView
    private var pendingLoad: CheckedContinuation<Void, Error>?

    init(store: WKWebsiteDataStore) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        super.init()
        webView.customUserAgent = Self.userAgent
        webView.navigationDelegate = self
    }

    /// Opens a lightweight claude.ai URL so that later fetch() calls are same-origin.
    func prepare() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pendingLoad = continuation
            webView.load(URLRequest(url: URL(string: "https://claude.ai/api/organizations")!))
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                self?.finishLoad(ClientError.timeout)
            }
        }
        // If Cloudflare shows its "Just a moment…" check, give it time to clear.
        for _ in 0..<12 {
            let title = (try? await webView.evaluateJavaScript("document.title")) as? String ?? ""
            if !title.localizedCaseInsensitiveContains("just a moment") { return }
            try await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }

    func get(_ path: String) async throws -> (status: Int, body: Data) {
        let script = """
        const response = await fetch(path, { credentials: 'include', headers: { 'accept': 'application/json' } });
        return JSON.stringify({ status: response.status, body: await response.text() });
        """
        let value = try await webView.callAsyncJavaScript(script, arguments: ["path": path], contentWorld: .page)
        guard let text = value as? String,
              let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let status = (object["status"] as? NSNumber)?.intValue,
              let body = object["body"] as? String
        else { throw ClientError.badResponse }
        return (status, Data(body.utf8))
    }

    /// Returns nil when this cookie store is not logged in to claude.ai.
    func organizations() async throws -> [OrgInfo]? {
        let (status, body) = try await get("/api/organizations")
        if status == 401 || status == 403 { return nil }
        guard (200..<300).contains(status) else { throw ClientError.http(status) }
        return Self.parseOrganizations(body)
    }

    private func finishLoad(_ error: Error?) {
        guard let continuation = pendingLoad else { return }
        pendingLoad = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoad(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoad(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoad(error)
    }

    // MARK: Organizations

    nonisolated static func parseOrganizations(_ data: Data) -> [OrgInfo] {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return array.compactMap { org in
            guard let id = (org["uuid"] ?? org["id"]) as? String else { return nil }
            let capabilities = org["capabilities"] as? [String] ?? []
            return OrgInfo(id: id,
                           name: org["name"] as? String ?? "",
                           plan: planName(capabilities: capabilities, tier: org["rate_limit_tier"] as? String),
                           capabilities: capabilities)
        }
    }

    /// Prefers the organization that holds the Claude subscription.
    nonisolated static func pick(_ orgs: [OrgInfo]) -> OrgInfo? {
        orgs.first { $0.capabilities.contains("chat") && $0.plan != nil }
            ?? orgs.first { $0.capabilities.contains("chat") }
            ?? orgs.first
    }

    nonisolated static func planName(capabilities: [String], tier: String?) -> String? {
        let text = (capabilities + [tier ?? ""]).joined(separator: " ").lowercased()
        if text.contains("enterprise") { return "Enterprise" }
        if text.contains("raven") || text.contains("team") { return "Team" }
        if text.contains("max_20x") { return "Max 20×" }
        if text.contains("max_5x") { return "Max 5×" }
        if text.contains("max") { return "Max" }
        if text.contains("pro") { return "Pro" }
        return nil
    }
}
