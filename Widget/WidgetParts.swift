import SwiftUI
import WidgetKit

// MARK: - Colours and language

enum UsageLevel {
    case normal, high, critical

    init(_ percent: Double) {
        if percent >= 90 {
            self = .critical
        } else if percent >= 70 {
            self = .high
        } else {
            self = .normal
        }
    }
}

/// Colours and language for one render: blue below 70%, orange from 70%, red from 90%.
/// In the system's monochrome desktop style every colour becomes the primary colour,
/// so ≥90% is also marked with bold text and an icon.
struct Palette {
    let scheme: ColorScheme
    let monochrome: Bool
    let lang: AppLanguage

    func fill(_ percent: Double) -> Color {
        if monochrome { return .primary }
        let dark = scheme == .dark
        switch UsageLevel(percent) {
        case .normal: return Color(hex: dark ? 0x4DA3FF : 0x0071E3)
        case .high: return Color(hex: dark ? 0xFFB340 : 0xB86200)
        case .critical: return Color(hex: dark ? 0xFF6961 : 0xD70015)
        }
    }

    func text(_ percent: Double) -> Color {
        if monochrome { return .primary }
        let dark = scheme == .dark
        switch UsageLevel(percent) {
        case .normal: return .primary
        case .high: return Color(hex: dark ? 0xFFB340 : 0x8F4F00)
        case .critical: return Color(hex: dark ? 0xFF6961 : 0xD70015)
        }
    }

    func weight(_ percent: Double) -> Font.Weight { percent >= 90 ? .bold : .semibold }

    var track: Color { Color.primary.opacity(monochrome ? 0.2 : 0.12) }

    func name(_ window: UsageWindow) -> String { Format.windowName(window.seconds, lang: lang) }

    var appName: String { lang.pick("额度环", "Quota Rings") }
    var logInAgain: String { lang.pick("需要重新登录", "Log in again") }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

struct WidgetBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Color(hex: scheme == .dark ? 0x242427 : 0xF7F7F9)
    }
}

extension AccountSnapshot {
    /// The windows drawn as rings, shorter first.
    var windows: [UsageWindow] { [primary, secondary].compactMap { $0 } }
    var showsNumbers: Bool { hasData && status != .needsLogin }
}

// MARK: - Rings

/// Outer ring: the shorter window. Inner ring: the longer one, when the service has it.
struct DualRing: View {
    let outer: Double
    let inner: Double?
    let palette: Palette
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            ring(outer, color: palette.fill(outer))
            if let inner {
                ring(inner, color: palette.fill(inner).opacity(0.6))
                    .padding(lineWidth + 2)
            }
        }
        .padding(lineWidth / 2)
    }

    private func ring(_ percent: Double, color: Color) -> some View {
        ZStack {
            Circle()
                .stroke(palette.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, percent / 100)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(percent > 0 ? 1 : 0)
                .widgetAccentable()
        }
    }
}

/// An account's rings with the shorter window's percentage, and optionally its name, in the middle.
struct AccountRing: View {
    let account: AccountSnapshot
    let palette: Palette
    let lineWidth: CGFloat
    let fontSize: CGFloat
    var showsPercent = true
    var showsName = false

    var body: some View {
        ZStack {
            DualRing(outer: account.primaryPercent,
                     inner: account.secondary == nil ? nil : account.secondaryPercent,
                     palette: palette, lineWidth: lineWidth)
            if account.showsNumbers {
                if showsPercent {
                    VStack(spacing: 0) {
                        Text(Format.percent(account.primaryPercent))
                            .font(.system(size: fontSize, weight: palette.weight(account.primaryPercent), design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .foregroundStyle(palette.text(account.primaryPercent))
                        if showsName, let primary = account.primary {
                            Text(palette.name(primary))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, lineWidth * 2)
                }
            } else {
                Image(systemName: account.status == .needsLogin ? "person.crop.circle.badge.exclamationmark" : "ellipsis")
                    .font(.system(size: fontSize))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Labels

struct PlanPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// "Claude Max", or just "Max" where the full name doesn't fit or the account is named after the service.
struct ProductPill: View {
    let account: AccountSnapshot

    var body: some View {
        ViewThatFits(in: .horizontal) {
            if account.name != account.service.displayName {
                PlanPill(text: account.product)
            }
            if let plan = account.plan {
                PlanPill(text: plan)
            }
            Color.clear.frame(width: 0, height: 0)
        }
    }
}

struct CriticalMark: View {
    let percent: Double
    let palette: Palette

    var body: some View {
        if percent >= 90 {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(palette.text(percent))
        }
    }
}

/// "本周 62%" / "Week 62%" with the number coloured by level.
func labelledPercent(_ label: String, _ percent: Double, palette: Palette) -> Text {
    let number = Text(Format.percent(percent))
        .fontWeight(palette.weight(percent))
        .foregroundStyle(palette.text(percent))
    return Text("\(label) \(number)")
}

/// A coloured dot, the window's name and percentage: the legend for one ring.
struct WindowLegend: View {
    let window: UsageWindow
    let isInner: Bool
    let palette: Palette
    /// Off where the ring already shows the number.
    var showsPercent = true

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(palette.fill(window.percent).opacity(isInner ? 0.6 : 1))
                .frame(width: 7, height: 7)
                .widgetAccentable()
            if showsPercent {
                labelledPercent(palette.name(window), window.percent, palette: palette)
            } else {
                Text(palette.name(window))
            }
            CriticalMark(percent: window.percent, palette: palette)
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

struct MiniBar: View {
    let label: String
    let percent: Double
    let value: String
    let palette: Palette

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.track)
                    Capsule()
                        .fill(palette.fill(percent))
                        .frame(width: max(4, proxy.size.width * min(1, percent / 100)))
                        .widgetAccentable()
                }
            }
            .frame(height: 4)
            Text(value)
                .font(.system(size: 11, weight: palette.weight(percent)))
                .monospacedDigit()
                .foregroundStyle(palette.text(percent))
                .frame(minWidth: 32, alignment: .trailing)
        }
        .font(.system(size: 11))
        .lineLimit(1)
    }
}

/// Per-model limits and extra usage, as bars.
struct DetailBars: View {
    let account: AccountSnapshot
    let palette: Palette

    var body: some View {
        VStack(spacing: 4) {
            ForEach(account.models, id: \.label) { model in
                MiniBar(label: model.label, percent: model.percent, value: Format.percent(model.percent), palette: palette)
            }
            if let extra = account.extra {
                MiniBar(label: palette.lang.pick("超额", "Extra"), percent: extra.percent,
                        value: Format.money(extra.used, currency: extra.currency), palette: palette)
            }
        }
    }
}

extension AccountSnapshot {
    var hasDetails: Bool { !models.isEmpty || extra != nil }
}

// MARK: - Pace

/// Where a usage window is heading if use continues at its average rate so far.
struct PaceStatus {
    enum Kind {
        case normal, fast, exhausted
    }

    let kind: Kind
    let text: String

    init(account: AccountSnapshot, now: Date, lang: AppLanguage) {
        for window in account.windows {
            guard let reset = window.resetsAt else { continue }
            let name = Format.windowName(window.seconds, lang: lang)
            let remaining = reset.timeIntervalSince(now)
            guard remaining > 0 else { continue }
            if window.percent >= 100 {
                kind = .exhausted
                text = lang.pick("\(name)额度已用完", "\(name) limit used up")
                return
            }
            let elapsed = window.seconds - remaining
            // Too early in the window to extrapolate meaningfully.
            guard elapsed > window.seconds * 0.1, window.percent > 0 else { continue }
            let secondsToFull = (100 - window.percent) / (window.percent / elapsed)
            if secondsToFull < remaining {
                let duration = Format.duration(secondsToFull, lang: lang)
                let joiner = duration.last?.isNumber == true ? " " : ""
                kind = .fast
                text = lang.pick("\(name)约 \(duration)\(joiner)后用完", "\(name) runs out in ~\(duration)")
                return
            }
        }
        kind = .normal
        text = lang.pick("节奏正常", "On track")
    }

    var symbol: String {
        switch kind {
        case .normal: return "checkmark.circle"
        case .fast: return "bolt.fill"
        case .exhausted: return "hourglass"
        }
    }

    func color(_ palette: Palette) -> Color {
        kind == .normal ? .secondary : palette.text(kind == .exhausted ? 100 : 75)
    }
}

struct PaceLabel: View {
    let status: PaceStatus
    let palette: Palette

    var body: some View {
        let warning = status.kind != .normal
        HStack(spacing: 4) {
            Image(systemName: status.symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(status.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(.system(size: 11, weight: warning ? .semibold : .regular))
        .foregroundStyle(status.color(palette))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

// MARK: - Shared cells

/// Ring, name, the shorter window's reset and the longer window's percentage, stacked.
/// Used by the small two-account layout and the medium row.
struct CompactAccountCell: View {
    let account: AccountSnapshot
    let now: Date
    let palette: Palette
    let ringSize: CGFloat

    var body: some View {
        VStack(spacing: 4) {
            AccountRing(account: account, palette: palette, lineWidth: ringSize / 9, fontSize: 13)
                .frame(width: ringSize, height: ringSize)
            Text(account.name)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
            Group {
                if account.status == .needsLogin {
                    Text(palette.logInAgain)
                } else {
                    Text(Format.countdown(to: account.primary?.resetsAt, from: now, lang: palette.lang))
                    if let secondary = account.secondary {
                        labelledPercent(palette.name(secondary), secondary.percent, palette: palette)
                    }
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Page position. A dot for another page turns orange or red when an account there is high.
struct PageDots: View {
    let levels: [Double]
    let current: Int
    let palette: Palette

    var body: some View {
        HStack(spacing: 5) {
            ForEach(levels.indices, id: \.self) { index in
                Circle()
                    .fill(color(index))
                    .frame(width: 5, height: 5)
            }
        }
    }

    private func color(_ index: Int) -> Color {
        if index == current { return .primary }
        return levels[index] >= 70 ? palette.fill(levels[index]) : Color.primary.opacity(0.25)
    }
}
