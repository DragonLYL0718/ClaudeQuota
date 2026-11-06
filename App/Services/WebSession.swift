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

/// The deadline resolves the continuation itself. It never waits for WebKit to acknowledge
/// cancellation (a task group would still wait for a child stuck in a JavaScript promise).
@MainActor
final class WebDeadlineOperation<Value> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var completed = false
    private var completedResult: Result<Value, Error>?
    private var interrupt: (() -> Void)?

    func run(timeout: TimeInterval, timeoutError: Error, onInterrupt: @escaping () -> Void = {},
             start: (@escaping (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let completedResult {
                    continuation.resume(with: completedResult)
                    return
                }
                self.continuation = continuation
                self.interrupt = onInterrupt
                timeoutTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                    self?.cancel(with: timeoutError)
                }
                start { [weak self] result in self?.finish(result) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func finish(_ result: Result<Value, Error>) {
        guard !completed else { return }
        completed = true
        completedResult = result
        timeoutTask?.cancel()
        timeoutTask = nil
        interrupt = nil
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }

    func cancel(with error: Error = CancellationError()) {
        guard !completed else { return }
        let stop = interrupt
        finish(.failure(error))
        stop?()
    }
}

/// A hidden, reusable origin document in one account's isolated cookie store.
@MainActor
final class WebSession: NSObject, WKNavigationDelegate {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    let webView: WKWebView
    private var pendingLoad: (id: UUID, navigation: WKNavigation?, operation: WebDeadlineOperation<Void>)?
    private var preparedOrigin: String?
    private var loadGeneration: UUID?

    init(store: WKWebsiteDataStore) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        super.init()
        webView.customUserAgent = Self.userAgent
        webView.navigationDelegate = self
    }

    func prepare(_ url: URL) async throws {
        try Task.checkCancellation()
        if preparedOrigin == url.host, webView.url?.host == url.host, webView.url?.scheme == "https" { return }
        try await open(url)
    }

    func open(_ url: URL) async throws {
        cancel()
        let host = url.host ?? ""
        let id = UUID()
        loadGeneration = id
        let operation = WebDeadlineOperation<Void>()
        pendingLoad = (id, nil, operation)
        defer {
            if pendingLoad?.id == id { pendingLoad = nil }
        }
        do {
            try await operation.run(timeout: 25, timeoutError: ServiceError.timeout(host), onInterrupt: { [weak self] in
                guard self?.loadGeneration == id else { return }
                self?.webView.stopLoading()
                self?.preparedOrigin = nil
            }) { [weak self] complete in
                guard let self, let navigation = self.webView.load(URLRequest(url: url)) else {
                    complete(.failure(ServiceError.badResponse(host)))
                    return
                }
                self.pendingLoad?.navigation = navigation
            }
            // A challenge can finish navigation before its JavaScript has redirected back.
            for _ in 0..<12 {
                try Task.checkCancellation()
                guard loadGeneration == id else { throw CancellationError() }
                let title = try await webView.boundedJavaScript("return document.title", timeout: 5) as? String ?? ""
                guard loadGeneration == id else { throw CancellationError() }
                if !title.localizedCaseInsensitiveContains("just a moment") {
                    guard webView.url?.scheme == url.scheme, webView.url?.host == host else {
                        throw ServiceError.badResponse(host)
                    }
                    preparedOrigin = host
                    return
                }
                try await Task.sleep(for: .milliseconds(1500))
            }
            throw ServiceError.timeout(host)
        } catch {
            if loadGeneration == id {
                preparedOrigin = nil
                webView.stopLoading()
            }
            throw error
        }
    }

    func cancel(with error: Error = CancellationError()) {
        loadGeneration = nil
        preparedOrigin = nil
        pendingLoad?.operation.cancel(with: error)
        pendingLoad = nil
        webView.cancelPendingOperations(with: error)
        webView.stopLoading()
    }

    private func finishLoad(_ navigation: WKNavigation?, error: Error? = nil) {
        guard let pendingLoad, let navigation, pendingLoad.navigation === navigation else { return }
        if let error { pendingLoad.operation.finish(.failure(error)) }
        else { pendingLoad.operation.finish(.success(())) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishLoad(navigation) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoad(navigation, error: error)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoad(navigation, error: error)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        cancel(with: ServiceError.badResponse(webView.url?.host ?? ""))
    }
}

/// Only active operations are retained; finishing a request removes its entry.
@MainActor
private enum WebOperations {
    static var pending: [ObjectIdentifier: [UUID: (Error) -> Void]] = [:]
}

extension WKWebView {
    @MainActor
    func cancelPendingOperations(with error: Error = CancellationError()) {
        let operations = WebOperations.pending.removeValue(forKey: ObjectIdentifier(self)) ?? [:]
        operations.values.forEach { $0(error) }
    }

    @MainActor
    fileprivate func boundedJavaScript(_ script: String, arguments: [String: Any] = [:],
                                       timeout: TimeInterval = 20, abortScript: String? = nil) async throws -> Any? {
        let id = UUID()
        let viewID = ObjectIdentifier(self)
        let operation = WebDeadlineOperation<Any?>()
        WebOperations.pending[viewID, default: [:]][id] = { [weak operation] error in operation?.cancel(with: error) }
        defer {
            WebOperations.pending[viewID]?[id] = nil
            if WebOperations.pending[viewID]?.isEmpty == true { WebOperations.pending[viewID] = nil }
        }
        return try await operation.run(timeout: timeout, timeoutError: ServiceError.timeout(url?.host ?? ""),
                                       onInterrupt: { [weak self] in
            if let abortScript {
                self?.callAsyncJavaScript(abortScript, arguments: [:], in: nil, in: .defaultClient,
                                         completionHandler: { _ in })
            }
            self?.stopLoading()
        }) { [weak self] complete in
            guard let self else { complete(.failure(CancellationError())); return }
            self.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .defaultClient) { result in
                complete(result.map { $0 as Any? })
            }
        }
    }

    /// Both fetch and the body read share one JavaScript abort deadline. The native deadline also
    /// returns promptly if the web content process cannot run its JavaScript timer.
    @MainActor
    func get(_ path: String, headers: [String: String] = [:], timeout: TimeInterval = 20) async throws -> (status: Int, body: Data) {
        let requestID = UUID().uuidString
        let script = """
        const controllers = globalThis.__quotaRequests ??= new Map();
        const controller = new AbortController();
        controllers.set(requestID, controller);
        const timer = setTimeout(() => controller.abort(), timeoutMilliseconds);
        try {
            const response = await fetch(path, {
                credentials: 'include', signal: controller.signal,
                headers: Object.assign({ 'accept': 'application/json' }, headers)
            });
            const body = await response.text();
            return JSON.stringify({ status: response.status, body });
        } catch (error) {
            if (controller.signal.aborted) return JSON.stringify({ timedOut: true });
            throw error;
        } finally {
            clearTimeout(timer);
            controllers.delete(requestID);
        }
        """
        // UUIDs contain no script delimiters; fetch arguments never undergo interpolation.
        let abort = "globalThis.__quotaRequests?.get('\(requestID)')?.abort()"
        let value = try await boundedJavaScript(script, arguments: ["path": path, "headers": headers,
            "requestID": requestID, "timeoutMilliseconds": timeout * 1000], timeout: timeout + 1, abortScript: abort)
        guard let text = value as? String,
              let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { throw ServiceError.badResponse(url?.host ?? "") }
        if object["timedOut"] as? Bool == true { throw ServiceError.timeout(url?.host ?? "") }
        guard let status = (object["status"] as? NSNumber)?.intValue, let body = object["body"] as? String
        else { throw ServiceError.badResponse(url?.host ?? "") }
        return (status, Data(body.utf8))
    }
}
