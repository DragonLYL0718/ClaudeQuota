import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
        window?.title = tr("额度环", "Quota Rings")
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

extension UTType {
    /// Private drag type, so dropping an account onto a text field doesn't paste anything into it.
    static let quotaRingsAccount = UTType(exportedAs: "com.rayleigh.ClaudeQuota.account")
}

/// What is dragged when reordering accounts in Settings.
struct AccountDragItem: Codable, Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .quotaRingsAccount)
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
                if model.accounts.isEmpty {
                    Text(lang.pick("还没有账号。添加一个 Claude 或 ChatGPT 账号，然后登录。",
                                   "No accounts yet. Add a Claude or ChatGPT account, then log in."))
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(model.accounts.enumerated()), id: \.element.id) { index, account in
                    AccountRow(account: account,
                               index: index,
                               count: model.accounts.count,
                               snapshot: model.snapshot(for: account),
                               model: model,
                               lang: lang,
                               onPasteKey: { keyTarget = account })
                }
                if model.accounts.count < AppModel.maxAccounts {
                    Menu(lang.pick("添加账号", "Add Account")) {
                        Button("Claude") { model.addAccount(.claude) }
                        Button(lang.pick("ChatGPT（Codex 额度）", "ChatGPT (Codex limits)")) { model.addAccount(.chatgpt) }
                    }
                    .fixedSize()
                }
            } header: {
                Text(lang.pick("账号", "Accounts"))
            } footer: {
                Text(lang.pick("拖动左侧的 ≡ 调整顺序。小组件按账号数量自动排版：小号和中号一页最多 4 个，大号最多 6 个，再多时点按小组件翻页。右键小组件 → 编辑小组件，可以为每个小组件选择要显示的账号。每个账号的登录单独保存在这台 Mac 上，只用来读取用量数据。",
                               "Drag ≡ to change the order. Widgets lay themselves out by account count: up to 4 per page on small and medium, 6 on large; click the widget to see more pages. Right-click a widget → Edit Widget to choose its accounts. Each login is stored separately on this Mac and is only used to read usage numbers."))
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
        .frame(width: 600, height: 460)
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
    let index: Int
    let count: Int
    let snapshot: AccountSnapshot?
    let model: AppModel
    let lang: AppLanguage
    let onPasteKey: () -> Void

    @State private var isDropTarget = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .frame(width: 16, height: 24)
                .contentShape(Rectangle())
                .draggable(AccountDragItem(id: account.id)) { dragPreview }
                .help(lang.pick("拖动调整顺序", "Drag to reorder"))
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
            .contentShape(Rectangle())
            .draggable(AccountDragItem(id: account.id)) { dragPreview }
            Spacer(minLength: 8)
            Button(account.remoteId == nil ? lang.pick("登录…", "Log In…") : lang.pick("重新登录…", "Log In Again…")) {
                model.login(account)
            }
            Menu {
                Button(lang.pick("上移", "Move Up")) { model.moveAccount(account.id, by: -1) }
                    .disabled(index == 0)
                Button(lang.pick("下移", "Move Down")) { model.moveAccount(account.id, by: 1) }
                    .disabled(index == count - 1)
                Divider()
                if account.service == .claude {
                    Button(lang.pick("粘贴 sessionKey…", "Paste sessionKey…"), action: onPasteKey)
                }
                Button(lang.pick("退出登录", "Log Out")) { Task { await model.signOut(account) } }
                    .disabled(account.remoteId == nil)
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
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isDropTarget ? Color.accentColor.opacity(0.15) : Color.clear))
        .dropDestination(for: AccountDragItem.self) { items, _ in
            guard let item = items.first, item.id != account.id else { return false }
            model.moveAccount(item.id, to: account.id)
            return true
        } isTargeted: { targeted in
            isDropTarget = targeted
        }
    }

    private var dragPreview: some View {
        Label(account.name, systemImage: "person.crop.circle")
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var status: String {
        "\(account.service.displayName) · " + state
    }

    private var state: String {
        if account.remoteId == nil { return lang.pick("未登录", "Not logged in") }
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
        return Format.summary(snapshot, lang: lang)
    }
}
