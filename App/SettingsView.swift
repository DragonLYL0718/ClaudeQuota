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
            window.title = "Claude 额度"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var keyTarget: AccountConfig?
    @State private var pastedKey = ""

    var body: some View {
        Form {
            Section {
                ForEach(model.accounts) { account in
                    AccountRow(account: account,
                               snapshot: model.snapshot(for: account),
                               model: model,
                               onPasteKey: { keyTarget = account })
                }
                if model.accounts.count < 4 {
                    Button("添加账号") { model.addAccount() }
                }
            } header: {
                Text("账号")
            } footer: {
                Text("每个账号的登录状态单独保存在这台 Mac 上，只用来读取 claude.ai 设置页里的用量数据。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("刷新") {
                Picker("刷新间隔", selection: $model.refreshMinutes) {
                    Text("2 分钟").tag(2)
                    Text("5 分钟").tag(5)
                    Text("10 分钟").tag(10)
                    Text("15 分钟").tag(15)
                }
                Toggle("开机时自动启动", isOn: Binding(get: { model.launchAtLogin },
                                                 set: { model.launchAtLogin = $0 }))
                HStack {
                    Text(Format.updated(model.lastRefresh, from: Date()))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(model.isRefreshing ? "刷新中…" : "立即刷新") {
                        Task { await model.refreshAll() }
                    }
                    .disabled(model.isRefreshing)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 580, height: 400)
        .alert("粘贴 sessionKey", isPresented: Binding(get: { keyTarget != nil },
                                                    set: { if !$0 { keyTarget = nil } })) {
            TextField("sk-ant-sid01-…", text: $pastedKey)
            Button("取消", role: .cancel) { pastedKey = "" }
            Button("保存") {
                if let target = keyTarget {
                    let key = pastedKey
                    Task { await model.useSessionKey(key, for: target) }
                }
                pastedKey = ""
            }
        } message: {
            Text("内置登录页用不了时的备用办法：在浏览器里登录 claude.ai，打开开发者工具 → Application → Cookies，复制 sessionKey 的值。")
        }
    }
}

struct AccountRow: View {
    let account: AccountConfig
    let snapshot: AccountSnapshot?
    let model: AppModel
    let onPasteKey: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            TextField("名称", text: Binding(get: { account.name },
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
            Button(account.orgId == nil ? "登录…" : "重新登录…") { model.login(account) }
            Menu {
                Button("粘贴 sessionKey…", action: onPasteKey)
                Button("退出登录") { Task { await model.signOut(account) } }
                    .disabled(account.orgId == nil)
                Divider()
                Button("删除这个账号", role: .destructive) { Task { await model.remove(account) } }
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
        if account.orgId == nil { return "未登录" }
        switch snapshot?.status {
        case .needsLogin?: return "需要重新登录"
        case .error?: return "暂时获取失败"
        default:
            if let plan = account.plan { return "已登录 · \(plan)" }
            return "已登录"
        }
    }

    private var detail: String? {
        guard let snapshot else { return nil }
        if snapshot.status == .error, let message = snapshot.message { return message }
        guard snapshot.hasData else { return snapshot.message }
        return "5 小时 \(Format.percent(snapshot.sessionPercent)) · 本周 \(Format.percent(snapshot.weeklyPercent))"
    }
}
