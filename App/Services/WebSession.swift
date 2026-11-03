import Foundation
import WebKit

enum ServiceError: LocalizedError {
    case loggedOut
    case timeout(String)
    case badResponse(String)
    case http(String, Int)

    var errorDescription: String? {
        switch self {
        case .loggedOut: return tr("登录已失效", "Logged out")
        case .timeout(let host): return tr("连接 \(host) 超时", "\(host) took too long to respond")
        case .badResponse(let host): return tr("\(host) 返回了无法识别的内容", "\(host) sent an unexpected response")
        case .http(let host, let code): return tr("\(host) 返回错误 \(code)", "\(host) returned error \(code)")
        }
    }
}

/// A hidden web view that uses one account's own cookie store, so requests look exactly like
/// the logged-in website (and get through Cloudflare checks).
@MainActor
final class WebSession: NSObject, WKNavigationDelegate {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    let webView: WKWebView
    private var pendingLoad: CheckedContinuation<Void, Error>?

    init(store: WKWebsiteDataStore) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        super.init()
        webView.customUserAgent = Self.userAgent
        webView.navigationDelegate = self
    }

    /// Opens a lightweight page on the service's origin so that later requests are same-origin.
    func open(_ url: URL) async throws {
        let host = url.host ?? ""
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pendingLoad = continuation
            webView.load(URLRequest(url: url))
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                self?.finishLoad(ServiceError.timeout(host))
            }
        }
        // If Cloudflare shows its "Just a moment…" check, give it time to clear.
        for _ in 0..<12 {
            let title = (try? await webView.evaluateJavaScript("document.title")) as? String ?? ""
            if !title.localizedCaseInsensitiveContains("just a moment") { return }
            try await Task.sleep(nanoseconds: 1_500_000_000)
        }
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
}

extension WKWebView {
    /// Runs fetch() inside the page, with its cookies, and returns the status and body.
    func get(_ path: String, headers: [String: String] = [:]) async throws -> (status: Int, body: Data) {
        let script = """
        const response = await fetch(path, { credentials: 'include', headers: Object.assign({ 'accept': 'application/json' }, headers) });
        return JSON.stringify({ status: response.status, body: await response.text() });
        """
        let value = try await callAsyncJavaScript(script, arguments: ["path": path, "headers": headers], contentWorld: .page)
        guard let text = value as? String,
              let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let status = (object["status"] as? NSNumber)?.intValue,
              let body = object["body"] as? String
        else { throw ServiceError.badResponse(url?.host ?? "") }
        return (status, Data(body.utf8))
    }
}
