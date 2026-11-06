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

    func name(_ window: UsageWindow) -> String {
        if window.label == "extra_usage" { return lang.pick("超额", "Extra") }
        let generic = ["", "five_hour", "seven_day", "primary_window", "secondary_window"]
        return generic.contains(window.label) ? Format.windowName(window.seconds, lang: lang) : window.label
    }

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
    var windows: [UsageWindow] { displayWindows }
    var showsNumbers: Bool { !displayWindows.isEmpty && status != .needsLogin }
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
    let now: Date
    let palette: Palette
    let lineWidth: CGFloat
    let fontSize: CGFloat
    var showsPercent = true
    var showsName = false

    var body: some View {
        let primary = account.displayPrimary
        let percent = primary?.percent ?? 0
        let ringPeak = account.displayWindows.map(\.percent).max() ?? 0
        ZStack {
            DualRing(outer: account.showsNumbers ? percent : 0,
                     inner: account.showsNumbers ? account.displaySecondary?.percent : nil,
                     palette: palette, lineWidth: lineWidth)
            if account.showsNumbers {
                if showsPercent {
                    VStack(spacing: 0) {
                        Text(Format.percent(percent))
                            .font(.system(size: percent >= 100 ? fontSize * 0.8 : fontSize,
                                          weight: palette.weight(percent), design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .fixedSize(horizontal: true, vertical: false)
                            .foregroundStyle(palette.text(percent))
                        if showsName, let primary {
                            Text(palette.name(primary))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                    .padding(.horizontal, lineWidth * 2)
                }
            } else {
                Image(systemName: account.displayState(at: now).symbol)
                    .font(.system(size: fontSize))
                    .foregroundStyle(.secondary)
            }
        }
        .overlay(alignment: .topTrailing) {
            let state = account.displayState(at: now)
            if state != .current, account.showsNumbers {
                Image(systemName: state.symbol)
                    .font(.system(size: max(9, min(12, fontSize / 2)), weight: .semibold))
                    .foregroundStyle(palette.text(75))
                    .padding(2)
                    .background(palette.scheme == .dark ? Color(hex: 0x242427) : Color(hex: 0xF7F7F9), in: Circle())
                    .help(state.text(lang: palette.lang, cached: account.hasData))
            } else if state == .current, ringPeak >= 90 {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: max(9, min(12, fontSize / 2)), weight: .semibold))
                    .foregroundStyle(palette.text(ringPeak))
                    .padding(2)
                    .background(palette.scheme == .dark ? Color(hex: 0x242427) : Color(hex: 0xF7F7F9), in: Circle())
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(account.name + ": " + account.displayWindows.map { palette.name($0) + " " + Format.percent($0.percent) }.joined(separator: ", ")
                            + ". " + account.displayState(at: now).text(lang: palette.lang, cached: account.hasData))
    }
}

extension View {
    /// Draws the view `size` across, then scales it down as a whole, strokes and text alike, to the
    /// room the header and page dots leave beside the text.
    func fittingRing(_ size: CGFloat) -> some View {
        GeometryReader { proxy in
            self.frame(width: size, height: size)
                .scaleEffect(min(1, min(proxy.size.width, proxy.size.height) / size))
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: size, maxHeight: size)
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
                .truncationMode(.middle)
                .help(label)
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

extension PaceStatus {
    func color(_ palette: Palette) -> Color {
        kind == .normal || kind == .unknown ? .secondary : palette.text(kind == .exhausted ? 100 : 75)
    }
}

struct PaceLabel: View {
    let status: PaceStatus
    let palette: Palette

    var body: some View {
        let warning = status.kind == .fast || status.kind == .exhausted
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

struct AccountStatusLabel: View {
    let account: AccountSnapshot
    let now: Date
    let palette: Palette
    var compact = false

    var body: some View {
        let state = account.displayState(at: now)
        Label(state.text(lang: palette.lang, cached: account.hasData, compact: compact), systemImage: state.symbol)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .help(account.message ?? state.text(lang: palette.lang, cached: account.hasData))
    }
}

/// Native date text continues updating without asking WidgetKit to render every minute.
struct ResetTimeLabel: View {
    let date: Date?
    let now: Date
    let lang: AppLanguage
    var phrase = false

    var body: some View {
        Group {
            if let date, date > now, date.timeIntervalSince(now) < 86400 {
                let timer = Text(timerInterval: now...date, countsDown: true, showsHours: true)
                if lang.isEnglish {
                    if phrase { Text("Resets in \(timer)") }
                    else { Text("in \(timer)") }
                } else {
                    if phrase { Text("\(timer)后重置") }
                    else { Text("\(timer)后") }
                }
            } else {
                Text(phrase ? Format.resetPhrase(to: date, from: now, lang: lang)
                            : Format.countdown(to: date, from: now, lang: lang))
            }
        }
        .monospacedDigit()
        .environment(\.locale, lang.locale)
        .lineLimit(1)
    }
}

// MARK: - Shared cells

/// Ring, name, the shorter window's reset and the longer window's percentage, stacked.
/// Used by the small two-account layout and the medium row.
struct CompactAccountCell: View {
    let account: AccountSnapshot
    let now: Date
    let palette: Palette
    /// Every cell reserves the same three text rows, even for a single-window account.
    let ringSize: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let side = max(0, min(ringSize, proxy.size.width, proxy.size.height - 54))
            VStack(spacing: 4) {
                AccountRing(account: account, now: now, palette: palette, lineWidth: max(4, side / 9), fontSize: 13)
                    .frame(width: side, height: side)
                Text(account.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, minHeight: 14, maxHeight: 14)
                    .help(account.name)
                Group {
                    if account.displayState(at: now) != .current {
                        AccountStatusLabel(account: account, now: now, palette: palette, compact: true)
                    } else if !account.hasData, let primary = account.displayPrimary {
                        Text(palette.name(primary)).truncationMode(.middle)
                    } else {
                        ResetTimeLabel(date: account.displayPrimary?.resetsAt, now: now, lang: palette.lang)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 14, maxHeight: 14)
                Group {
                    if account.showsNumbers, let secondary = account.displaySecondary {
                        labelledPercent(palette.name(secondary), secondary.percent, palette: palette)
                    } else {
                        Color.clear.accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 14, maxHeight: 14)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                Capsule()
                    .fill(color(index))
                    .frame(width: index == current ? 12 : 5, height: 5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(palette.lang.pick("第 \(current + 1) 页，共 \(levels.count) 页",
                                               "Page \(current + 1) of \(levels.count)"))
    }

    private func color(_ index: Int) -> Color {
        if index == current { return .primary }
        return levels[index] >= 70 ? palette.fill(levels[index]) : Color.primary.opacity(0.25)
    }
}

// MARK: - Header

/// The top row of every size: the app's name (medium and large), when the numbers were updated,
/// and the refresh button.
struct WidgetHeader: View {
    let family: WidgetFamily
    let accounts: [AccountSnapshot]
    let now: Date
    let palette: Palette

    var body: some View {
        let isSmall = family == .systemSmall
        let freshness = WidgetFreshness(accounts: accounts, now: now)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if !isSmall {
                Text(palette.appName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Group {
                if freshness.state != .current {
                    Label(freshness.state.text(lang: palette.lang, compact: isSmall), systemImage: freshness.state.symbol)
                } else if let date = freshness.oldestSuccess {
                    // A dynamic date Text expands in an HStack. Keep its suffix inline so it
                    // cannot be pushed across the header as the available width changes.
                    let relative = Text(date, style: .relative)
                    if palette.lang.isEnglish {
                        if isSmall {
                            relative.accessibilityLabel(Text("Updated \(relative) ago"))
                        }
                        else { Text("Updated \(relative) ago") }
                    } else {
                        if isSmall { Text("\(relative)前") }
                        else { Text("更新于 \(relative)前") }
                    }
                } else {
                    Text(palette.lang.pick("尚未更新", "Not updated yet"))
                }
            }
                .environment(\.locale, palette.lang.locale)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .help(Format.updated(freshness.oldestSuccess, from: now, lang: palette.lang))
            if isSmall {
                Spacer(minLength: 0)
            }
            Toggle(isOn: false, intent: RefreshIntent()) {
                Text(palette.lang.pick("刷新", "Refresh"))
            }
            .toggleStyle(RefreshToggleStyle(isStale: freshness.state != .current,
                                            palette: palette))
        }
    }
}

/// The refresh button. WidgetKit shows a toggle's new state the moment it's clicked, before the
/// refresh ends, so the button is a toggle that is never on: clicked, it shows "Refreshing" in the
/// accent colour until the reload that follows the refresh turns it back off.
struct RefreshToggleStyle: ToggleStyle {
    /// The numbers are over 20 minutes old.
    let isStale: Bool
    let palette: Palette

    func makeBody(configuration: Configuration) -> some View {
        let refreshing = configuration.isOn
        let accent = palette.fill(0)
        return Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: refreshing ? "ellipsis"
                                  : isStale ? "exclamationmark.arrow.circlepath" : "arrow.clockwise")
                    .font(.system(size: 9, weight: .bold))
                if refreshing {
                    Text(palette.lang.pick("刷新中", "Refreshing"))
                } else {
                    configuration.label
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(refreshing ? accent : Color.secondary)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Capsule().fill(refreshing ? accent.opacity(0.18) : Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}
