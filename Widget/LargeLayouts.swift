import SwiftUI

// MARK: - One account

/// One account as a small dashboard: rings and both windows, then per-model limits and the pace.
struct LargeHeroView: View {
    let account: AccountSnapshot
    let now: Date
    let palette: Palette

    var body: some View {
        let lang = palette.lang
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            HStack(spacing: 18) {
                AccountRing(account: account, now: now, palette: palette, lineWidth: 13, fontSize: 28, showsName: true)
                    .frame(width: 126, height: 126)
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(account.name)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        ProductPill(account: account)
                    }
                    if account.status == .needsLogin {
                        Text(lang.pick("请在菜单栏图标 → 设置里重新登录", "Log in again from the menu bar icon → Settings"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(account.displayWindows.enumerated()), id: \.offset) { index, window in
                            VStack(alignment: .leading, spacing: 1) {
                                WindowLegend(window: window, isInner: index > 0, palette: palette)
                                    .font(.system(size: 12))
                                ExpandedWindowDetail(account: account, window: window, now: now, lang: lang, phrase: true)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, 12)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if account.hasDetails && account.status != .needsLogin {
                Divider()
                ExpandedDetailBars(account: account, palette: palette, rowLimit: 5)
            }
            Spacer(minLength: 0)
            if account.status != .needsLogin {
                if account.displayState(at: now) != .current {
                    AccountStatusLabel(account: account, now: now, palette: palette)
                } else {
                    PaceLabel(status: PaceStatus(account: account, now: now, lang: lang), palette: palette)
                }
            }
        }
    }
}

// MARK: - Two accounts

/// Two centred columns, one per account, using the full height of the widget.
struct LargePairView: View {
    let accounts: [AccountSnapshot]
    let now: Date
    let palette: Palette

    var body: some View {
        let detailRows = min(5, accounts.filter { $0.status != .needsLogin }
            .map { $0.models.count + ($0.extra == nil ? 0 : 1) }.max() ?? 0)
        HStack(spacing: 12) {
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 {
                    Divider()
                        .padding(.vertical, 6)
                }
                LargeAccountColumn(account: account, now: now, palette: palette, detailRows: detailRows)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct LargeAccountColumn: View {
    let account: AccountSnapshot
    let now: Date
    let palette: Palette
    /// Both columns reserve the same detail area, even if only one account has model limits.
    let detailRows: Int

    private var ringSize: CGFloat {
        switch detailRows {
        case 0: return 118
        case 1...3: return 96
        case 4: return 82
        default: return 64
        }
    }
    private var detailHeight: CGFloat { CGFloat(detailRows * 14 + max(0, detailRows - 1) * 4) }

    var body: some View {
        let lang = palette.lang
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                Text(account.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(height: 16)
                ProductPill(account: account)
                    .frame(height: 17)
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 6)
            // The shorter window's reset time sits right under the ring it belongs to.
            AccountRing(account: account, now: now, palette: palette, lineWidth: max(7, ringSize / 9.5),
                        fontSize: ringSize > 100 ? 26 : ringSize > 80 ? 21 : 17, showsName: true)
                .frame(width: ringSize, height: ringSize)
            Group {
                if account.showsNumbers, let primary = account.displayPrimary {
                    ExpandedWindowDetail(account: account, window: primary, now: now, lang: lang, phrase: true)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    Color.clear
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .frame(height: 14)
            .padding(.top, 4)
            Group {
                if account.status == .needsLogin {
                    Text(lang.pick("请在设置里重新登录", "Open Settings to log in again"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                } else if let secondary = account.displaySecondary {
                    VStack(spacing: 2) {
                        WindowLegend(window: secondary, isInner: true, palette: palette)
                            .font(.system(size: 12))
                        ExpandedWindowDetail(account: account, window: secondary, now: now, lang: lang, phrase: true)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Color.clear
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .padding(.top, 6)
            if detailRows > 0 {
                Group {
                    if account.status != .needsLogin {
                        ExpandedDetailBars(account: account, palette: palette, rowLimit: 5)
                    } else {
                        Color.clear
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: detailHeight, alignment: .top)
                .padding(.top, 6)
            }
            Spacer(minLength: 6)
            Group {
                if account.displayState(at: now) != .current {
                    AccountStatusLabel(account: account, now: now, palette: palette)
                } else {
                    PaceLabel(status: PaceStatus(account: account, now: now, lang: lang), palette: palette)
                }
            }
            .frame(height: 22)
        }
    }
}

// MARK: - Three to six accounts

/// One row per account, with the percentages lined up on the right for comparison.
struct LargeListView: View {
    let accounts: [AccountSnapshot]
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
            AccountRing(account: account, now: now, palette: palette, lineWidth: max(4, ringSize / 9), fontSize: 14,
                        showsPercent: false)
                .frame(width: ringSize, height: ringSize)
            VStack(alignment: .leading, spacing: 2) {
                ExpandedAccountTitle(account: account)
                    .font(.system(size: 13, weight: .semibold))
                subtitle
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if account.showsNumbers {
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(Array(account.displayWindows.enumerated()), id: \.offset) { _, window in
                        HStack(spacing: 4) {
                            CriticalMark(percent: window.percent, palette: palette)
                            Text(palette.name(window))
                                .foregroundStyle(.secondary)
                            Text(Format.percent(window.percent))
                                .fontWeight(palette.weight(window.percent))
                                .monospacedDigit()
                                .foregroundStyle(palette.text(window.percent))
                                .fixedSize(horizontal: true, vertical: false)
                                .frame(minWidth: 38, alignment: .trailing)
                        }
                    }
                }
                .font(.system(size: 12))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    /// A pace warning when there is one, otherwise when the shorter window resets.
    @ViewBuilder private var subtitle: some View {
        if account.displayState(at: now) != .current {
            AccountStatusLabel(account: account, now: now, palette: palette)
        } else if let primary = account.displayPrimary, primary.label == "extra_usage" {
            ExpandedWindowDetail(account: account, window: primary, now: now, lang: palette.lang)
                .foregroundStyle(.secondary)
        } else {
            let pace = PaceStatus(account: account, now: now, lang: palette.lang)
            if pace.kind == .normal {
                if let primary = account.displayPrimary {
                    ExpandedWindowDetail(account: account, window: primary, now: now, lang: palette.lang, phrase: true)
                        .foregroundStyle(.secondary)
                }
            } else {
                Label(pace.text, systemImage: pace.symbol)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(pace.color(palette))
            }
        }
    }
}
