import SwiftUI
import WidgetKit

// MARK: - Colours

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

/// Blue below 70%, orange from 70%, red from 90%.
/// In the system's monochrome desktop style every colour becomes the primary colour,
/// so ≥90% is also marked with bold text and an icon.
struct Palette {
    let scheme: ColorScheme
    let monochrome: Bool

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

// MARK: - Building blocks

/// Outer ring: the 5-hour window. Inner ring: this week.
struct DualRing: View {
    let outer: Double
    let inner: Double
    let palette: Palette
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            ring(outer, color: palette.fill(outer))
            ring(inner, color: palette.fill(inner).opacity(0.6))
                .padding(lineWidth + 2)
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

struct AccountRing: View {
    let account: AccountSnapshot
    let palette: Palette
    let lineWidth: CGFloat
    let fontSize: CGFloat

    var body: some View {
        ZStack {
            DualRing(outer: account.sessionPercent, inner: account.weeklyPercent,
                     palette: palette, lineWidth: lineWidth)
            if account.hasData && account.status != .needsLogin {
                Text(Format.percent(account.sessionPercent))
                    .font(.system(size: fontSize, weight: palette.weight(account.sessionPercent), design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(palette.text(account.sessionPercent))
                    .padding(.horizontal, lineWidth * 2)
            } else {
                Image(systemName: account.status == .needsLogin ? "person.crop.circle.badge.exclamationmark" : "ellipsis")
                    .font(.system(size: fontSize))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct PlanPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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

/// "本周 62%" with the number coloured by level.
func labelledPercent(_ label: String, _ percent: Double, palette: Palette) -> Text {
    let number = Text(Format.percent(percent))
        .fontWeight(palette.weight(percent))
        .foregroundStyle(palette.text(percent))
    return Text("\(label) \(number)")
}

// MARK: - Pace

/// Where a usage window is heading if use continues at its average rate so far.
struct PaceStatus {
    enum Kind {
        case normal, fast, exhausted
    }

    let kind: Kind
    let text: String

    init(account: AccountSnapshot, now: Date) {
        let windows: [(window: UsageWindow?, length: TimeInterval, name: String)] = [
            (account.session, 5 * 3600, "5 小时"),
            (account.weekly, 7 * 86400, "本周")
        ]
        for item in windows {
            guard let window = item.window, let reset = window.resetsAt else { continue }
            let remaining = reset.timeIntervalSince(now)
            guard remaining > 0 else { continue }
            if window.percent >= 100 {
                kind = .exhausted
                text = "\(item.name)额度已用完"
                return
            }
            let elapsed = item.length - remaining
            // Too early in the window to extrapolate meaningfully.
            guard elapsed > item.length * 0.1, window.percent > 0 else { continue }
            let secondsToFull = (100 - window.percent) / (window.percent / elapsed)
            if secondsToFull < remaining {
                let duration = Format.duration(secondsToFull)
                let joiner = duration.last?.isNumber == true ? " " : ""
                kind = .fast
                text = "\(item.name)约 \(duration)\(joiner)后用完"
                return
            }
        }
        kind = .normal
        text = "节奏正常"
    }

    var symbol: String {
        switch kind {
        case .normal: return "checkmark.circle"
        case .fast: return "bolt.fill"
        case .exhausted: return "hourglass"
        }
    }
}

struct PaceLabel: View {
    let status: PaceStatus
    let palette: Palette

    var body: some View {
        let warning = status.kind != .normal
        let color: Color = warning ? palette.text(status.kind == .exhausted ? 100 : 75) : .secondary
        HStack(spacing: 4) {
            Image(systemName: status.symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(status.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(.system(size: 11, weight: warning ? .semibold : .regular))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

// MARK: - Small

struct SmallQuotaView: View {
    let accounts: [AccountSnapshot]
    let now: Date
    let palette: Palette

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(accounts) { account in
                VStack(spacing: 4) {
                    AccountRing(account: account, palette: palette, lineWidth: 7, fontSize: 13)
                        .frame(width: 64, height: 64)
                    Text(account.name)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    if account.status == .needsLogin {
                        Text("需重新登录")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(Format.countdown(to: account.session?.resetsAt, from: now))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        labelledPercent("本周", account.weeklyPercent, palette: palette)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Medium

struct MediumQuotaView: View {
    let accounts: [AccountSnapshot]
    let now: Date
    let palette: Palette

    var body: some View {
        HStack(spacing: 12) {
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
        HStack(spacing: 10) {
            AccountRing(account: account, palette: palette, lineWidth: 8, fontSize: 15)
                .frame(width: 78, height: 78)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let plan = account.plan {
                    PlanPill(text: plan)
                }
                if account.status == .needsLogin {
                    Text("需要重新登录")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                } else {
                    legend(dot: palette.fill(account.sessionPercent), title: Text("5 小时"),
                           percent: account.sessionPercent)
                        .padding(.top, 6)
                    detail(Format.countdown(to: account.session?.resetsAt, from: now))
                    legend(dot: palette.fill(account.weeklyPercent).opacity(0.6),
                           title: labelledPercent("本周", account.weeklyPercent, palette: palette),
                           percent: account.weeklyPercent)
                        .padding(.top, 3)
                    detail(account.weekly?.resetsAt.map(Format.weekdayTime) ?? "—")
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func legend(dot: Color, title: Text, percent: Double) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dot)
                .frame(width: 7, height: 7)
                .widgetAccentable()
            title
            CriticalMark(percent: percent, palette: palette)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.leading, 12)
    }
}

// MARK: - Large

/// Two centred columns, one per account, using the full height of the widget.
struct LargeQuotaView: View {
    let snapshot: QuotaSnapshot
    let now: Date
    let palette: Palette

    var body: some View {
        let accounts = Array(snapshot.accounts.prefix(2))
        let compact = accounts.contains { !$0.models.isEmpty || $0.extra != nil }
        VStack(spacing: 8) {
            HStack {
                Text("Claude 额度")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Format.updated(snapshot.generatedAt, from: now))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
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
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(account.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let plan = account.plan {
                    PlanPill(text: plan)
                }
            }
            Spacer(minLength: 6)
            // The 5-hour reset time sits right under the ring it belongs to.
            VStack(spacing: 8) {
                ZStack {
                    DualRing(outer: account.sessionPercent, inner: account.weeklyPercent,
                             palette: palette, lineWidth: lineWidth)
                    ringCenter
                }
                .frame(width: ringSize, height: ringSize)
                if account.status != .needsLogin {
                    Text(Format.resetPhrase(to: account.session?.resetsAt, from: now))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if account.status == .needsLogin {
                VStack(spacing: 2) {
                    Text("登录已失效")
                        .font(.system(size: 12, weight: .semibold))
                    Text("请在菜单栏图标 → 设置里重新登录")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Spacer(minLength: 6)
            } else {
                VStack(spacing: 2) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(palette.fill(account.weeklyPercent).opacity(0.6))
                            .frame(width: 7, height: 7)
                            .widgetAccentable()
                        labelledPercent("本周", account.weeklyPercent, palette: palette)
                        CriticalMark(percent: account.weeklyPercent, palette: palette)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    Text(Format.resetPhrase(to: account.weekly?.resetsAt, from: now))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if compact && (!account.models.isEmpty || account.extra != nil) {
                    VStack(spacing: 4) {
                        ForEach(account.models, id: \.label) { model in
                            miniBar(label: model.label, percent: model.percent, value: Format.percent(model.percent))
                        }
                        if let extra = account.extra {
                            miniBar(label: "超额", percent: extra.percent,
                                    value: Format.money(extra.used, currency: extra.currency))
                        }
                    }
                    .padding(.top, 8)
                }
                Spacer(minLength: 6)
                PaceLabel(status: PaceStatus(account: account, now: now), palette: palette)
            }
        }
    }

    @ViewBuilder private var ringCenter: some View {
        if account.hasData && account.status != .needsLogin {
            VStack(spacing: 0) {
                Text(Format.percent(account.sessionPercent))
                    .font(.system(size: compact ? 21 : 26, weight: palette.weight(account.sessionPercent), design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(palette.text(account.sessionPercent))
                Text("5 小时")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, lineWidth * 2)
        } else {
            Image(systemName: account.status == .needsLogin ? "person.crop.circle.badge.exclamationmark" : "ellipsis")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
        }
    }

    private func miniBar(label: String, percent: Double, value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
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

// MARK: - Empty

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("打开「Claude 额度」登录账号")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
