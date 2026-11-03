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
                Spacer(minLength: 2)
                ProductPill(account: account)
            }
            AccountRing(account: account, palette: palette, lineWidth: 9, fontSize: 20, showsName: true)
                .frame(width: 82, height: 82)
            footer
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxHeight: .infinity)
    }

    private var footer: Text {
        if account.status == .needsLogin { return Text(palette.logInAgain) }
        let countdown = Text(Format.countdown(to: account.primary?.resetsAt, from: now, lang: palette.lang))
        guard let secondary = account.secondary else { return countdown }
        return countdown + Text(" · ") + labelledPercent(palette.name(secondary), secondary.percent, palette: palette)
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
    let palette: Palette

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(stride(from: 0, to: accounts.count, by: 2)), id: \.self) { start in
                HStack(spacing: 8) {
                    ForEach(accounts[start..<min(start + 2, accounts.count)]) { account in
                        VStack(spacing: 2) {
                            AccountRing(account: account, palette: palette, lineWidth: 5, fontSize: 11)
                                .frame(width: 42, height: 42)
                            Text(account.name)
                                .font(.system(size: 10, weight: .semibold))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}
