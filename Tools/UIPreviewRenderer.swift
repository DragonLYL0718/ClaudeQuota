import AppKit
import SwiftUI
import WidgetKit

/// Synthetic UI coverage. Never reads saved accounts or login stores.
/// Run Tools/render-ui-previews.sh [output-directory] to produce images and contact sheets.
@main
struct UIPreviewRenderer {
    struct Case {
        let name: String
        let accounts: [AccountSnapshot]
        var paged = false
        var selectionMissing = false
    }

    @MainActor
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/ui-previews", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let now = Date()
        var rendered = 0
        for (family, size, familyName) in [(WidgetFamily.systemSmall, CGSize(width: 164, height: 164), "small"),
                                         (.systemMedium, CGSize(width: 344, height: 164), "medium"),
                                         (.systemLarge, CGSize(width: 344, height: 344), "large")] {
            for lang in [AppLanguage.zh, .en] {
                for (scheme, mono, style) in [(ColorScheme.light, false, "light"), (.dark, false, "dark"), (.light, true, "mono")] {
                    let prefix = "\(familyName)-\(lang.rawValue)-\(style)"
                    var pages: [(String, NSImage)] = []
                    let palette = Palette(scheme: scheme, monochrome: mono, lang: lang)
                    for scenario in scenarios(capacity: family.capacity, now: now) {
                        let content = Group {
                            if scenario.accounts.isEmpty {
                                EmptyStateView(lang: lang, selectionMissing: scenario.selectionMissing)
                            } else {
                                QuotaLayout(family: family, accounts: scenario.accounts, generatedAt: now,
                                            now: now, palette: palette,
                                            page: scenario.paged ? PageInfo(current: 0, levels: [50, 95]) : nil,
                                            pageKey: "preview")
                            }
                        }
                        .padding(16)
                        .frame(width: size.width, height: size.height)
                        .background(scheme == .dark ? Color(hex: 0x242427) : Color(hex: 0xF7F7F9))
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .environment(\.colorScheme, scheme)
                        .environment(\.locale, lang.locale)
                        let renderer = ImageRenderer(content: content)
                        renderer.scale = 2
                        guard let image = renderer.nsImage else { fatalError("Could not render \(prefix)-\(scenario.name)") }
                        try save(image, to: output.appendingPathComponent("\(prefix)-\(scenario.name).png"))
                        pages.append((scenario.name, image))
                        rendered += 1
                    }
                    // Six tiles per sheet keep every label readable in a visual review.
                    for start in stride(from: 0, to: pages.count, by: 6) {
                        let tiles = Array(pages[start..<min(start + 6, pages.count)])
                        let sheet = contactSheet(tiles, title: prefix, tileSize: size)
                        try save(sheet, to: output.appendingPathComponent("sheet-\(prefix)-\(start / 6 + 1).png"))
                    }
                }
            }
        }
        print("Rendered \(rendered) widget scenarios and contact sheets to \(output.path)")
    }

    static func scenarios(capacity: Int, now: Date) -> [Case] {
        func window(_ percent: Double, _ seconds: TimeInterval, remaining: TimeInterval?) -> UsageWindow {
            UsageWindow(label: "", percent: percent, resetsAt: remaining.map { now.addingTimeInterval($0) }, seconds: seconds)
        }
        let mixed = [
            AccountSnapshot(id: "general", service: .claude, name: "General", plan: "Pro", status: .ok,
                            primary: window(24, .fiveHours, remaining: 4 * 3600 + 21 * 60),
                            secondary: window(87, .week, remaining: 3 * 86400), updatedAt: now.addingTimeInterval(-29)),
            AccountSnapshot(id: "code", service: .claude, name: "Code", plan: "Pro", status: .ok,
                            primary: window(0, .fiveHours, remaining: nil),
                            secondary: window(2, .week, remaining: 5 * 86400), updatedAt: now.addingTimeInterval(-29)),
            AccountSnapshot(id: "chatgpt", service: .chatgpt, name: "ChatGPT", plan: "Sci", status: .ok,
                            primary: window(4, .week, remaining: 6 * 86400), updatedAt: now.addingTimeInterval(-29)),
            AccountSnapshot(id: "secondary", service: .chatgpt, name: "Weekly only", plan: "Free", status: .ok,
                            secondary: window(95, .week, remaining: 2 * 86400), updatedAt: now.addingTimeInterval(-29)),
            AccountSnapshot(id: "long", service: .claude, name: "Very long personal account name", plan: "Enterprise subscription", status: .ok,
                            primary: window(100, .fiveHours, remaining: 45 * 60), updatedAt: now.addingTimeInterval(-29)),
            AccountSnapshot(id: "lab", service: .chatgpt, name: "研究实验室团队账号", plan: "Business", status: .ok,
                            primary: window(50, 30 * 86400, remaining: 12 * 86400), updatedAt: now.addingTimeInterval(-29))
        ]
        var cases = (1...capacity).map { Case(name: "mixed-\($0)", accounts: Array(mixed.prefix($0))) }
        cases += [Case(name: "single-window", accounts: [mixed[2]]),
                  Case(name: "secondary-only", accounts: [mixed[3]]),
                  Case(name: "long-name", accounts: [mixed[4]]),
                  Case(name: "mixed-pair", accounts: [mixed[0], mixed[2]])]
        var states = Array(mixed.prefix(4))
        states[0].status = .error
        states[0].message = "The server could not complete the request. Please try again later."
        states[1].updatedAt = now.addingTimeInterval(-3600)
        states[2].primary = nil
        states[3].status = .needsLogin
        cases.append(Case(name: "states", accounts: Array(states.prefix(capacity))))
        cases.append(Case(name: "state-pair", accounts: [states[0], states[3]]))
        cases.append(Case(name: "no-data", accounts: [states[2]]))
        var details = mixed[0]
        details.models = (1...8).map { UsageWindow(label: "Long model \($0)", percent: Double($0 * 12), resetsAt: now.addingTimeInterval(86400), seconds: UsageWindow.week) }
        details.extra = ExtraUsage(used: 123.45, limit: 150, currency: "USD")
        cases.append(Case(name: "many-details", accounts: [details]))
        cases.append(Case(name: "uneven-details", accounts: [details, mixed[2]]))
        details.primary = nil
        details.secondary = nil
        cases.append(Case(name: "details-only", accounts: [details]))
        details.models = []
        cases.append(Case(name: "extra-only", accounts: [details]))
        cases.append(Case(name: "paged", accounts: Array(mixed.prefix(capacity)), paged: true))
        let exhausted = Array(mixed.prefix(capacity)).map { account in
            var account = account
            account.primary?.percent = 100
            account.secondary?.percent = 100
            return account
        }
        cases.append(Case(name: "all-exhausted-paged", accounts: exhausted, paged: true))
        cases.append(Case(name: "empty", accounts: []))
        cases.append(Case(name: "selection-missing", accounts: [], selectionMissing: true))
        return cases
    }

    @MainActor
    static func contactSheet(_ tiles: [(String, NSImage)], title: String, tileSize: CGSize) -> NSImage {
        let columns = 2
        let rows = (tiles.count + columns - 1) / columns
        let size = CGSize(width: (tileSize.width + 20) * CGFloat(columns) + 20,
                          height: (tileSize.height + 34) * CGFloat(rows) + 42)
        let result = NSImage(size: size)
        result.lockFocus()
        NSColor(calibratedWhite: 0.88, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                                                       .foregroundColor: NSColor.black]
        (title as NSString).draw(at: NSPoint(x: 20, y: size.height - 22), withAttributes: attributes)
        for (index, tile) in tiles.enumerated() {
            let x = 20 + CGFloat(index % columns) * (tileSize.width + 20)
            let top = size.height - 42 - CGFloat(index / columns) * (tileSize.height + 34)
            (tile.0 as NSString).draw(at: NSPoint(x: x, y: top - 12), withAttributes: attributes)
            tile.1.draw(in: NSRect(x: x, y: top - 16 - tileSize.height, width: tileSize.width, height: tileSize.height))
        }
        result.unlockFocus()
        return result
    }

    static func save(_ image: NSImage, to url: URL) throws {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not encode preview") }
        try png.write(to: url)
    }
}

private extension TimeInterval {
    static var fiveHours: TimeInterval { UsageWindow.fiveHours }
    static var week: TimeInterval { UsageWindow.week }
}
