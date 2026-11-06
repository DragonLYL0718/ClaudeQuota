import SwiftUI

/// One account: a large ring with the name above and the resets below.
struct SmallHeroView: View {
    let account: AccountSnapshot
    let now: Date
    let palette: Palette

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Text(account.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .layoutPriority(1)
                    .help(account.name)
                Spacer(minLength: 2)
                ProductPill(account: account)
            }
            AccountRing(account: account, now: now, palette: palette, lineWidth: 9, fontSize: 20, showsName: true)
                .fittingRing(82)
            footer
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.center)
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder private var footer: some View {
        if account.displayState(at: now) != .current {
            AccountStatusLabel(account: account, now: now, palette: palette)
        } else if !account.hasData, account.models.isEmpty, let extra = account.extra {
            Text(Format.money(extra.used, currency: extra.currency) + " / " + Format.money(extra.limit, currency: extra.currency))
        } else {
            HStack(spacing: 3) {
                ResetTimeLabel(date: account.displayPrimary?.resetsAt, now: now, lang: palette.lang)
                if let secondary = account.displaySecondary {
                    Text("·")
                    labelledPercent(palette.name(secondary), secondary.percent, palette: palette)
                }
            }
        }
    }
}

/// Two accounts side by side.
struct SmallPairView: View {
    let accounts: [AccountSnapshot]
    let now: Date
    let palette: Palette

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(accounts) { account in
                CompactAccountCell(account: account, now: now, palette: palette, ringSize: 64)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

/// Three or four accounts in a 2×2 grid of rings.
struct SmallGridView: View {
    let accounts: [AccountSnapshot]
    let now: Date
    let palette: Palette

    var body: some View {
        GeometryReader { proxy in
            let rows = max(1, (accounts.count + 1) / 2)
            let width = max(0, (proxy.size.width - 8) / 2)
            let height = max(0, (proxy.size.height - CGFloat(rows - 1) * 6) / CGFloat(rows))
            let side = max(0, min(42, width, height - 14))
            VStack(spacing: 6) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: 8) {
                        ForEach(0..<2, id: \.self) { column in
                            let index = row * 2 + column
                            if index < accounts.count {
                                let account = accounts[index]
                                VStack(spacing: 2) {
                                    AccountRing(account: account, now: now, palette: palette,
                                                lineWidth: min(5, side / 12), fontSize: min(11, side * 0.28))
                                        .frame(width: side, height: side)
                                    Text(account.name)
                                        .font(.system(size: 10, weight: .semibold))
                                        .lineLimit(1)
                                        .frame(height: 12)
                                        .help(account.name)
                                }
                                .frame(width: width, height: height, alignment: .top)
                            } else {
                                Color.clear.frame(width: width, height: height).accessibilityHidden(true)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}
