import SwiftUI

/// One account: ring on the left, both windows with their resets and the pace on the right.
struct MediumHeroView: View {
    let account: AccountSnapshot
    let now: Date
    let palette: Palette

    var body: some View {
        let lang = palette.lang
        HStack(spacing: 14) {
            AccountRing(account: account, now: now, palette: palette, lineWidth: 10, fontSize: 22, showsName: true)
                .fittingRing(100)
            VStack(alignment: .leading, spacing: 5) {
                ExpandedAccountTitle(account: account)
                    .font(.system(size: 14, weight: .semibold))
                if account.status == .needsLogin {
                    Text(lang.pick("请在菜单栏图标 → 设置里重新登录", "Log in again from the menu bar icon → Settings"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(account.displayWindows.enumerated()), id: \.offset) { index, window in
                        HStack(spacing: 8) {
                            WindowLegend(window: window, isInner: index > 0, palette: palette)
                                .fixedSize(horizontal: true, vertical: false)
                            ExpandedWindowDetail(account: account, window: window, now: now, lang: lang, phrase: true)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(size: 11))
                    }
                    if account.displayState(at: now) != .current {
                        AccountStatusLabel(account: account, now: now, palette: palette)
                    } else {
                        PaceLabel(status: PaceStatus(account: account, now: now, lang: lang), palette: palette)
                            .padding(.top, 2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }
}

/// Two accounts, each with its ring and a legend.
struct MediumPairView: View {
    let accounts: [AccountSnapshot]
    let now: Date
    let palette: Palette

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 {
                    Divider()
                }
                MediumAccountView(account: account, now: now, palette: palette)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct MediumAccountView: View {
    let account: AccountSnapshot
    let now: Date
    let palette: Palette

    var body: some View {
        HStack(spacing: 8) {
            AccountRing(account: account, now: now, palette: palette, lineWidth: 6, fontSize: 13)
                .frame(width: 58, height: 58)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(height: 16, alignment: .leading)
                ProductPill(account: account)
                    .frame(height: 17, alignment: .leading)
                primaryLegend
                    .frame(height: 14, alignment: .leading)
                    .padding(.top, 3)
                reset(account.showsNumbers ? account.displayPrimary : nil)
                secondaryLegend
                    .frame(height: 14, alignment: .leading)
                reset(account.showsNumbers ? account.displaySecondary : nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11))
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder private var primaryLegend: some View {
        if account.displayState(at: now) != .current {
            AccountStatusLabel(account: account, now: now, palette: palette, compact: true)
        } else if let primary = account.displayPrimary {
            Text(palette.name(primary)).foregroundStyle(.secondary)
        } else {
            Color.clear
        }
    }

    @ViewBuilder private var secondaryLegend: some View {
        if account.showsNumbers, let secondary = account.displaySecondary {
            labelledPercent(palette.name(secondary), secondary.percent, palette: palette)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        } else {
            Color.clear
        }
    }

    @ViewBuilder private func reset(_ window: UsageWindow?) -> some View {
        Group {
            if let window {
                ExpandedWindowDetail(account: account, window: window, now: now, lang: palette.lang)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .minimumScaleFactor(0.85)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 14)
    }
}

/// Spending has an amount and budget, not a reset timer. Model windows retain their timer.
struct ExpandedWindowDetail: View {
    let account: AccountSnapshot
    let window: UsageWindow
    let now: Date
    let lang: AppLanguage
    var phrase = false

    var body: some View {
        if window.label == "extra_usage", let extra = account.extra {
            Text(Format.money(extra.used, currency: extra.currency) + " / "
                 + Format.money(extra.limit, currency: extra.currency))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        } else {
            ResetTimeLabel(date: window.resetsAt, now: now, lang: lang, phrase: phrase)
        }
    }
}

/// Three or four accounts in a row.
struct MediumRowView: View {
    let accounts: [AccountSnapshot]
    let now: Date
    let palette: Palette

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(accounts) { account in
                CompactAccountCell(account: account, now: now, palette: palette,
                                   ringSize: accounts.count == 3 ? 64 : 56)
            }
        }
        .frame(maxHeight: .infinity)
    }
}
