import AppKit
import SwiftUI

@main
struct ClaudeQuotaApp: App {
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
        ForEach(model.accounts) { account in
            Text(line(for: account))
        }
        Divider()
        Text(Format.updated(model.lastRefresh, from: Date()))
        Button(model.isRefreshing ? "刷新中…" : "立即刷新") {
            Task { await model.refreshAll() }
        }
        .keyboardShortcut("r")
        Button("设置…") { SettingsWindowController.shared.show() }
            .keyboardShortcut(",")
        Divider()
        Button("退出 Claude 额度") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func line(for account: AccountConfig) -> String {
        guard account.orgId != nil else { return "\(account.name)：未登录" }
        guard let snapshot = model.snapshot(for: account) else { return "\(account.name)：读取中…" }
        if snapshot.status == .needsLogin { return "\(account.name)：需要重新登录" }
        guard snapshot.hasData else { return "\(account.name)：暂无数据" }
        return "\(account.name)：5 小时 \(Format.percent(snapshot.sessionPercent)) · 本周 \(Format.percent(snapshot.weeklyPercent))"
    }
}
