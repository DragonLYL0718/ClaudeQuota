import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: AppModel.shared))
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.title = tr("Claude 额度", "Claude Quota")
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var keyTarget: AccountConfig?
    @State private var pastedKey = ""

    var body: some View {
        let lang = model.language
        Form {
            Section {
                ForEach(model.accounts) { account in
                    AccountRow(account: account,
                               snapshot: model.snapshot(for: account),
                               model: model,
                               lang: lang,
                               onPasteKey: { keyTarget = account })
                }
                if model.accounts.count < 4 {
                    Button(lang.pick("添加账号", "Add Account")) { model.addAccount() }
                }
            } header: {
                Text(lang.pick("账号", "Accounts"))
            } footer: {
                Text(lang.pick("每个账号的登录状态单独保存在这台 Mac 上，只用来读取 claude.ai 设置页里的用量数据。",
                               "Each login is stored separately on this Mac and is only used to read the usage numbers from claude.ai's settings page."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(lang.pick("通用", "General")) {
                Picker(lang.pick("语言", "Language"), selection: $model.language) {
                    Text(lang.pick("跟随系统", "System")).tag(AppLanguage.system)
                    Text("中文").tag(AppLanguage.zh)
                    Text("English").tag(AppLanguage.en)
                }
                Picker(lang.pick("刷新间隔", "Refresh every"), selection: $model.refreshMinutes) {
                    ForEach([2, 5, 10, 15], id: \.self) { minutes in
                        Text(lang.pick("\(minutes) 分钟", "\(minutes) minutes")).tag(minutes)
                    }
                }
                Toggle(lang.pick("开机时自动启动", "Open at login"),
                       isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                HStack {
                    Text(Format.updated(model.lastRefresh, from: Date(), lang: lang))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(model.isRefreshing ? lang.pick("刷新中…", "Refreshing…") : lang.pick("立即刷新", "Refresh Now")) {
                        Task { await model.refreshAll() }
                    }
                    .disabled(model.isRefreshing)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 580, height: 440)
        .alert(lang.pick("粘贴 sessionKey", "Paste sessionKey"),
               isPresented: Binding(get: { keyTarget != nil }, set: { if !$0 { keyTarget = nil } })) {
            TextField("sk-ant-sid01-…", text: $pastedKey)
            Button(lang.pick("取消", "Cancel"), role: .cancel) { pastedKey = "" }
            Button(lang.pick("保存", "Save")) {
                if let target = keyTarget {
                    let key = pastedKey
                    Task { await model.useSessionKey(key, for: target) }
                }
                pastedKey = ""
            }
        } message: {
            Text(lang.pick("内置登录页用不了时的备用办法：在浏览器里登录 claude.ai，打开开发者工具 → Application → Cookies，复制 sessionKey 的值。",
                           "A fallback if the built-in login page doesn't work: log in to claude.ai in a browser, open Developer Tools → Application → Cookies and copy the value of sessionKey."))
        }
    }
}

struct AccountRow: View {
    let account: AccountConfig
    let snapshot: AccountSnapshot?
    let model: AppModel
    let lang: AppLanguage
    let onPasteKey: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            TextField(lang.pick("名称", "Name"), text: Binding(get: { account.name },
                                                              set: { model.rename(account.id, to: $0) }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)
            VStack(alignment: .leading, spacing: 2) {
                Text(status).font(.callout)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button(account.orgId == nil ? lang.pick("登录…", "Log In…") : lang.pick("重新登录…", "Log In Again…")) {
                model.login(account)
            }
            Menu {
                Button(lang.pick("粘贴 sessionKey…", "Paste sessionKey…"), action: onPasteKey)
                Button(lang.pick("退出登录", "Log Out")) { Task { await model.signOut(account) } }
                    .disabled(account.orgId == nil)
                Divider()
                Button(lang.pick("删除这个账号", "Remove Account"), role: .destructive) {
                    Task { await model.remove(account) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 2)
    }

    private var status: String {
        if account.orgId == nil { return lang.pick("未登录", "Not logged in") }
        switch snapshot?.status {
        case .needsLogin?: return lang.pick("需要重新登录", "Log in again")
        case .error?: return lang.pick("暂时获取失败", "Couldn't update")
        default:
            if let plan = account.plan { return lang.pick("已登录 · \(plan)", "Logged in · \(plan)") }
            return lang.pick("已登录", "Logged in")
        }
    }

    private var detail: String? {
        guard let snapshot else { return nil }
        if snapshot.status == .error, let message = snapshot.message { return message }
        guard snapshot.hasData else { return snapshot.message }
        let session = Format.percent(snapshot.sessionPercent)
        let weekly = Format.percent(snapshot.weeklyPercent)
        return lang.pick("5 小时 \(session) · 本周 \(weekly)", "5h \(session) · Week \(weekly)")
    }
}
