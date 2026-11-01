import AppKit
import WebKit

/// A small window showing claude.ai's own login page for one account.
/// Each account has its own cookie store, so two different logins can live side by side.
@MainActor
final class LoginWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private let webView: WKWebView
    private let linkField = NSTextField()
    private let onFinish: (OrgInfo?) -> Void
    private var popupWindows: [NSWindow] = []
    private var pollTimer: Timer?
    private var isChecking = false
    private var isFinished = false

    init(accountName: String, store: WKWebsiteDataStore, onFinish: @escaping (OrgInfo?) -> Void) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 720), configuration: configuration)
        webView.customUserAgent = ClaudeWebClient.userAgent
        self.onFinish = onFinish

        // Email login sends a link that opens in the default browser. Pasting that link here
        // finishes the login inside this window instead.
        linkField.placeholderString = tr("邮箱登录：把邮件里的登录链接粘贴到这里",
                                         "Email login: paste the sign-in link from the email here")
        linkField.lineBreakMode = .byTruncatingMiddle
        linkField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let openButton = NSButton(title: tr("打开链接", "Open Link"), target: nil, action: nil)
        openButton.bezelStyle = .rounded
        let bar = NSStackView(views: [linkField, openButton])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 760))
        bar.translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bar)
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 760),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = tr("登录 claude.ai · \(accountName)", "Log in to claude.ai · \(accountName)")
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.center()
        super.init(window: window)

        openButton.target = self
        openButton.action = #selector(openPastedLink)
        linkField.target = self
        linkField.action = #selector(openPastedLink)
        window.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkLogin() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func openPastedLink() {
        let text = linkField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = Self.loginURL(from: text) else {
            NSSound.beep()
            return
        }
        linkField.stringValue = ""
        webView.load(URLRequest(url: url))
    }

    /// Accepts the link itself, or a mail-client redirect (Gmail, Outlook) wrapped around it.
    nonisolated static func loginURL(from text: String) -> URL? {
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        if isClaude(url) { return url }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        for item in items where ["q", "url", "u", "target"].contains(item.name.lowercased()) {
            if let value = item.value, let inner = URL(string: value), isClaude(inner) { return inner }
        }
        return url
    }

    nonisolated private static func isClaude(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "claude.ai" || host.hasSuffix(".claude.ai")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { await checkLogin() }
    }

    /// Logged in once claude.ai lists the organizations for this cookie store.
    private func checkLogin() async {
        guard !isFinished, !isChecking else { return }
        guard let host = webView.url?.host, host == "claude.ai" || host.hasSuffix(".claude.ai") else { return }
        isChecking = true
        defer { isChecking = false }

        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        guard cookies.contains(where: { $0.name == "sessionKey" }) else { return }

        let script = """
        const response = await fetch('/api/organizations', { credentials: 'include', headers: { 'accept': 'application/json' } });
        return JSON.stringify({ status: response.status, body: await response.text() });
        """
        guard let text = (try? await webView.callAsyncJavaScript(script, contentWorld: .page)) as? String,
              let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              (object["status"] as? NSNumber)?.intValue == 200,
              let body = object["body"] as? String,
              let org = ClaudeWebClient.pick(ClaudeWebClient.parseOrganizations(Data(body.utf8)))
        else { return }
        finish(with: org)
    }

    private func finish(with org: OrgInfo?) {
        guard !isFinished else { return }
        isFinished = true
        pollTimer?.invalidate()
        popupWindows.forEach { $0.close() }
        popupWindows.removeAll()
        window?.close()
        onFinish(org)
    }

    func windowWillClose(_ notification: Notification) {
        guard !isFinished else { return }
        isFinished = true
        pollTimer?.invalidate()
        popupWindows.forEach { $0.close() }
        popupWindows.removeAll()
        onFinish(nil)
    }

    // "Continue with Google" and similar flows open a popup; show it as a real window.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: configuration)
        popup.customUserAgent = ClaudeWebClient.userAgent
        popup.uiDelegate = self
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = tr("登录", "Log In")
        window.isReleasedWhenClosed = false
        window.contentView = popup
        window.center()
        window.makeKeyAndOrderFront(nil)
        popupWindows.append(window)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let window = popupWindows.first(where: { $0.contentView === webView }) else { return }
        window.close()
        popupWindows.removeAll { $0 === window }
    }
}
