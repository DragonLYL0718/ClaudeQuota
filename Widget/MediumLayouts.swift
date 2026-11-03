import SwiftUI

/// One account: ring on the left, both windows with their resets and the pace on the right.
struct MediumHeroView: View {
    let account: AccountSnapshot
    let now: Date
    let palette: Palette

    var body: some View {
        let lang = palette.lang
        HStack(spacing: 14) {
            AccountRing(account: account, palette: palette, lineWidth: 10, fontSize: 22, showsName: true)
                .fittingRing(100)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(account.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    ProductPill(account: account)
                }
                if account.status == .needsLogin {
                    Text(lang.pick("请在菜单栏图标 → 设置里重新登录", "Log in again from the menu bar icon → Settings"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(account.windows.enumerated()), id: \.offset) { index, window in
                        HStack(spacing: 8) {
                            WindowLegend(window: window, isInner: index > 0, palette: palette)
                            Text(Format.resetPhrase(to: window.resetsAt, from: now, lang: lang))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .font(.system(size: 11))
                    }
                    PaceLabel(status: PaceStatus(account: account, now: now, lang: lang), palette: palette)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
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
        let lang = palette.lang
        HStack(spacing: 8) {
            AccountRing(account: account, palette: palette, lineWidth: 6, fontSize: 13)
                .frame(width: 58, height: 58)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                ProductPill(account: account)
                if account.status == .needsLogin {
                    Text(palette.logInAgain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                } else {
                    ForEach(Array(account.windows.enumerated()), id: \.offset) { index, window in
                        WindowLegend(window: window, isInner: index > 0, palette: palette, showsPercent: index > 0)
                            .font(.system(size: 11))
                            .padding(.top, index == 0 ? 6 : 3)
                        detail(index == 0
                               ? Format.countdown(to: window.resetsAt, from: now, lang: lang)
                               : window.resetsAt.map { Format.weekdayTime($0, lang: lang) } ?? "—")
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.leading, 12)
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
