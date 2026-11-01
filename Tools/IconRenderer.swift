import AppKit
import SwiftUI

/// Draws the app icon. The square artwork fills the whole canvas and macOS applies its own
/// rounded-square mask. Also writes a pre-masked copy for the README.
@main
struct IconRenderer {
    @MainActor
    static func main() {
        let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        write(IconArt(), to: out.appendingPathComponent("icon_1024.png"))
        write(IconArt().clipShape(RoundedRectangle(cornerRadius: 230, style: .continuous)),
              to: out.appendingPathComponent("icon_rounded.png"))
    }

    @MainActor
    static func write<V: View>(_ view: V, to url: URL) {
        let renderer = ImageRenderer(content: view.frame(width: 1024, height: 1024))
        renderer.scale = 1
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

/// Two arcs on a deep blue ground: the outer one for the 5-hour window, the inner one for the week.
struct IconArt: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.19, green: 0.27, blue: 0.48),
                                    Color(red: 0.05, green: 0.08, blue: 0.15)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color.white.opacity(0.16), .clear],
                           center: UnitPoint(x: 0.28, y: 0.18), startRadius: 0, endRadius: 620)
            arc(radius: 300, progress: 0.72,
                colors: [Color(red: 0.47, green: 0.78, blue: 1.0), Color(red: 0.15, green: 0.47, blue: 1.0)])
            arc(radius: 196, progress: 0.46,
                colors: [Color(red: 1.0, green: 0.76, blue: 0.58), Color(red: 0.86, green: 0.47, blue: 0.34)])
        }
    }

    private func arc(radius: CGFloat, progress: Double, colors: [Color]) -> some View {
        let lineWidth: CGFloat = 86
        return ZStack {
            Circle()
                .stroke(Color.white.opacity(0.09), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                // Start the gradient slightly before 0° so the round start cap gets the start colour.
                .stroke(AngularGradient(colors: colors, center: .center,
                                        startAngle: .degrees(-10), endAngle: .degrees(360 * progress)),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: .black.opacity(0.3), radius: 14, y: 8)
        }
        .frame(width: radius * 2, height: radius * 2)
    }
}
