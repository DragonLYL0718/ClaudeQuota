import AppKit
import SwiftUI

@main
struct QuotaRingsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: "gauge.with.dots.needle.67percent")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let model = AppModel.shared
            if model.needsSetup { SettingsWindowController.shared.show() }
            await model.refreshAll()
        }
    }

    /// Opening the app again (e.g. from Finder) brings up the settings window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in SettingsWindowController.shared.show() }
        return true
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let lang = model.language
        ForEach(Service.allCases) { service in
            let accounts = model.accounts.filter { $0.service == service }
            if !accounts.isEmpty {
                Section(service.displayName) {
                    ForEach(accounts) { account in
                        Text(line(for: account, lang: lang))
                    }
                }
            }
        }
        Divider()
        Text(Format.updated(model.lastRefresh, from: Date(), lang: lang))
        Button(model.isRefreshing ? lang.pick("刷新中…", "Refreshing…") : lang.pick("立即刷新", "Refresh Now")) {
            Task { await model.refreshAll(reloadWidget: true) }
        }
        .keyboardShortcut("r")
        Button(lang.pick("设置…", "Settings…")) { SettingsWindowController.shared.show() }
            .keyboardShortcut(",")
        Divider()
        Button(lang.pick("退出额度环", "Quit Quota Rings")) { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func line(for account: AccountConfig, lang: AppLanguage) -> String {
        let name = account.name
        guard account.remoteId != nil else { return lang.pick("\(name)：未登录", "\(name): not logged in") }
        guard let snapshot = model.snapshot(for: account) else { return lang.pick("\(name)：读取中…", "\(name): loading…") }
        if snapshot.status == .needsLogin { return lang.pick("\(name)：需要重新登录", "\(name): log in again") }
        guard snapshot.hasData else { return lang.pick("\(name)：暂无数据", "\(name): no data yet") }
        return lang.pick("\(name)：", "\(name): ") + Format.summary(snapshot, lang: lang)
    }
}
