import SwiftUI

struct LargeHeader: View {
    let generatedAt: Date
    let now: Date
    let palette: Palette

    var body: some View {
        HStack {
            Text(palette.appName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(Format.updated(generatedAt, from: now, lang: palette.lang))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - One account

/// One account as a small dashboard: rings and both windows, then per-model limits and the pace.
struct LargeHeroView: View {
    let account: AccountSnapshot
    let generatedAt: Date
    let now: Date
    let palette: Palette

    var body: some View {
        let lang = palette.lang
        VStack(spacing: 10) {
            LargeHeader(generatedAt: generatedAt, now: now, palette: palette)
            Spacer(minLength: 0)
            HStack(spacing: 18) {
                AccountRing(account: account, palette: palette, lineWidth: 13, fontSize: 28, showsName: true)
                    .frame(width: 126, height: 126)
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(account.name)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        ProductPill(account: account)
                    }
                    if account.status == .needsLogin {
                        Text(lang.pick("请在菜单栏图标 → 设置里重新登录", "Log in again from the menu bar icon → Settings"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(account.windows.enumerated()), id: \.offset) { index, window in
                            VStack(alignment: .leading, spacing: 1) {
                                WindowLegend(window: window, isInner: index > 0, palette: palette)
                                    .font(.system(size: 12))
                                Text(Format.resetPhrase(to: window.resetsAt, from: now, lang: lang))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .padding(.leading, 12)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            if account.hasDetails && account.status != .needsLogin {
                Divider()
                DetailBars(account: account, palette: palette)
            }
            Spacer(minLength: 0)
            if account.status != .needsLogin {
                PaceLabel(status: PaceStatus(account: account, now: now, lang: lang), palette: palette)
            }
        }
    }
}

// MARK: - Two accounts

/// Two centred columns, one per account, using the full height of the widget.
struct LargePairView: View {
    let accounts: [AccountSnapshot]
    let generatedAt: Date
    let now: Date
    let palette: Palette

    var body: some View {
        let compact = accounts.contains { $0.hasDetails }
        VStack(spacing: 8) {
            LargeHeader(generatedAt: generatedAt, now: now, palette: palette)
            HStack(spacing: 12) {
                ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                    if index > 0 {
                        Divider()
                            .padding(.vertical, 6)
                    }
                    LargeAccountColumn(account: account, now: now, palette: palette, compact: compact)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

struct LargeAccountColumn: View {
    let account: AccountSnapshot
    let now: Date
    let palette: Palette
    /// True when some account also shows per-model limits, which need the room.
    let compact: Bool

    private var ringSize: CGFloat { compact ? 96 : 118 }
    private var lineWidth: CGFloat { compact ? 10 : 12 }

    var body: some View {
        let lang = palette.lang
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(account.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                ProductPill(account: account)
            }
            Spacer(minLength: 6)
            // The shorter window's reset time sits right under the ring it belongs to.
            VStack(spacing: 8) {
                AccountRing(account: account, palette: palette, lineWidth: lineWidth,
                            fontSize: compact ? 21 : 26, showsName: true)
                    .frame(width: ringSize, height: ringSize)
                if account.status != .needsLogin {
                    Text(Format.resetPhrase(to: account.primary?.resetsAt, from: now, lang: lang))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if account.status == .needsLogin {
                VStack(spacing: 2) {
                    Text(lang.pick("登录已失效", "Logged out"))
                        .font(.system(size: 12, weight: .semibold))
                    Text(lang.pick("请在菜单栏图标 → 设置里重新登录", "Log in again from the menu bar icon → Settings"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Spacer(minLength: 6)
            } else {
                if let secondary = account.secondary {
                    VStack(spacing: 2) {
                        WindowLegend(window: secondary, isInner: true, palette: palette)
                            .font(.system(size: 12))
                        Text(Format.resetPhrase(to: secondary.resetsAt, from: now, lang: lang))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if compact && account.hasDetails {
                    DetailBars(account: account, palette: palette)
                        .padding(.top, 8)
                }
                Spacer(minLength: 6)
                PaceLabel(status: PaceStatus(account: account, now: now, lang: lang), palette: palette)
            }
        }
    }
}

// MARK: - Three to six accounts

/// One row per account, with the percentages lined up on the right for comparison.
struct LargeListView: View {
    let accounts: [AccountSnapshot]
    let generatedAt: Date
    let now: Date
    let palette: Palette

    private var ringSize: CGFloat {
        switch accounts.count {
        case ...3: return 52
        case 4: return 46
        case 5: return 38
        default: return 34
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            LargeHeader(generatedAt: generatedAt, now: now, palette: palette)
                .padding(.bottom, 4)
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                Divider()
                LargeListRow(account: account, now: now, palette: palette, ringSize: ringSize)
                    .frame(maxHeight: .infinity)
            }
        }
    }
}

struct LargeListRow: View {
    let account: AccountSnapshot
    let now: Date
    let palette: Palette
    let ringSize: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            AccountRing(account: account, palette: palette, lineWidth: max(4, ringSize / 9), fontSize: 14,
                        showsPercent: false)
                .frame(width: ringSize, height: ringSize)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(account.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    ProductPill(account: account)
                }
                subtitle
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if account.showsNumbers {
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(Array(account.windows.enumerated()), id: \.offset) { _, window in
                        HStack(spacing: 4) {
                            CriticalMark(percent: window.percent, palette: palette)
                            Text(palette.name(window))
                                .foregroundStyle(.secondary)
                            Text(Format.percent(window.percent))
                                .fontWeight(palette.weight(window.percent))
                                .monospacedDigit()
                                .foregroundStyle(palette.text(window.percent))
                                .frame(minWidth: 34, alignment: .trailing)
                        }
                    }
                }
                .font(.system(size: 12))
                .lineLimit(1)
            }
        }
    }

    /// A pace warning when there is one, otherwise when the shorter window resets.
    @ViewBuilder private var subtitle: some View {
        if account.status == .needsLogin {
            Text(palette.logInAgain).foregroundStyle(.secondary)
        } else {
            let pace = PaceStatus(account: account, now: now, lang: palette.lang)
            if pace.kind == .normal {
                Text(Format.resetPhrase(to: account.primary?.resetsAt, from: now, lang: palette.lang))
                    .foregroundStyle(.secondary)
            } else {
                Label(pace.text, systemImage: pace.symbol)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(pace.color(palette))
            }
        }
    }
}
