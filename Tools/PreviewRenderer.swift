import AppKit
import SwiftUI

/// Renders widget previews for the README from the built-in sample data, in English.
@main
struct PreviewRenderer {
    @MainActor
    static func main() {
        let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var sample = QuotaSnapshot.sample
        sample.language = .en
        let now = sample.generatedAt

        write(LargeQuotaView(snapshot: sample, now: now,
                             palette: Palette(scheme: .light, monochrome: false, lang: .en)),
              size: CGSize(width: 344, height: 344), scheme: .light,
              to: out.appendingPathComponent("widget-large.png"))
        write(MediumQuotaView(accounts: sample.accounts, now: now,
                              palette: Palette(scheme: .dark, monochrome: false, lang: .en)),
              size: CGSize(width: 344, height: 164), scheme: .dark,
              to: out.appendingPathComponent("widget-medium.png"))
        write(SmallQuotaView(accounts: sample.accounts, now: now,
                             palette: Palette(scheme: .light, monochrome: false, lang: .en)),
              size: CGSize(width: 164, height: 164), scheme: .light,
              to: out.appendingPathComponent("widget-small.png"))
    }

    @MainActor
    static func write<V: View>(_ view: V, size: CGSize, scheme: ColorScheme, to url: URL) {
        let background = scheme == .dark ? Color(hex: 0x242427) : Color(hex: 0xF7F7F9)
        let content = view
            .padding(16)
            .frame(width: size.width, height: size.height)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Could not render \(url.lastPathComponent)")
        }
        do {
            try png.write(to: url)
        } catch {
            fatalError("Could not write \(url.path): \(error)")
        }
    }
}
