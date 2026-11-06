import SwiftUI

/// Preserve the account name before adding a plan badge in a constrained inline heading.
struct ExpandedAccountTitle: View {
    let account: AccountSnapshot

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                Text(account.name).fixedSize(horizontal: true, vertical: false)
                ProductPill(account: account)
            }
            Text(account.name)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The fixed-height detail area shared by both large-widget columns. An overflow summary
/// keeps unusually many model limits from pushing the rings and footer outside the widget.
struct ExpandedDetailBars: View {
    let account: AccountSnapshot
    let palette: Palette
    let rowLimit: Int

    private var details: [(label: String, percent: Double, value: String)] {
        let overflow = account.models.count + (account.extra == nil ? 0 : 1) > rowLimit
        let models = overflow ? account.models.sorted {
            $0.percent == $1.percent ? $0.label < $1.label : $0.percent > $1.percent
        } : account.models
        var rows = models.map { ($0.label, $0.percent, Format.percent($0.percent)) }
        if let extra = account.extra {
            rows.append((palette.lang.pick("超额", "Extra"), extra.percent,
                         Format.money(extra.used, currency: extra.currency)))
        }
        return rows
    }

    var body: some View {
        let rows = details
        let overflow = rows.count > rowLimit
        let visibleCount = overflow ? max(0, rowLimit - 1) : rows.count
        // Extra spending remains visible even when model limits need a summary.
        let visible = overflow && account.extra != nil && visibleCount > 0
            ? Array(rows.prefix(visibleCount - 1)) + [rows[rows.count - 1]]
            : Array(rows.prefix(visibleCount))
        VStack(spacing: 4) {
            ForEach(Array(visible.enumerated()), id: \.offset) { _, row in
                MiniBar(label: row.label, percent: row.percent, value: row.value, palette: palette)
                    .frame(height: 14)
            }
            if overflow {
                Text(palette.lang.pick("另有 \(rows.count - visible.count) 项限额", "+\(rows.count - visible.count) more limits"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 14)
                    .help(rows.map { "\($0.label): \($0.value)" }.joined(separator: "\n"))
            }
        }
    }
}
