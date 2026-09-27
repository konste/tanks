import AppKit
import SwiftUI

/// The compact menu-bar item (design variant B): a tank glyph filled to the binding window's level
/// plus that window's percentage. State C (an alert advice is pending) adds a solid badge with a
/// knocked-out mark and sets the text bold.
///
/// The image is always a template, so macOS tints it with the menu bar's own foreground (white on
/// a dark or wallpaper-tinted bar, black on a light one). An earlier version painted the attention
/// state system red in colour; on his dark-blue menu bar that was barely legible (2026-09-26), and
/// no fixed colour reads on every wallpaper, so attention is carried by shape instead.
@MainActor
enum TanksMenuBarRenderer {
    struct Content: Equatable {
        var fill: Double?
        var attention: Bool
        var stale: Bool
    }

    private static var last: (content: Content, image: NSImage)?

    static func image(for content: Content) -> NSImage {
        if let last, last.content == content { return last.image }
        let renderer = ImageRenderer(content: Glyph(content: content))
        renderer.scale = 2
        let image: NSImage
        if let cg = renderer.cgImage {
            let trimmed = MenuBarStripRenderer.trimmedToVisibleContent(cg) ?? cg
            image = NSImage(cgImage: trimmed, size: NSSize(width: CGFloat(trimmed.width) / 2, height: CGFloat(trimmed.height) / 2))
        } else {
            image = MenuBarStripRenderer.fallbackIcon
        }
        image.isTemplate = true
        image.accessibilityDescription = content.fill.map { "Tanks \(Int($0 * 100))%" } ?? "Tanks"
        last = (content, image)
        return image
    }

    private struct Glyph: View {
        var content: Content

        var body: some View {
            let color: Color = .black
            HStack(spacing: 4) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).stroke(color, lineWidth: 1.5).frame(width: 18, height: 10)
                    RoundedRectangle(cornerRadius: 1.5).fill(color)
                        .frame(width: max(2, 14 * (content.fill ?? 0)), height: 6)
                        .padding(.leading, 2)
                    RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 2, height: 5).offset(x: 19)
                }
                .frame(width: 22, height: 12)
                .opacity(content.stale ? 0.5 : 1)
                if let fill = content.fill {
                    Text("\(Int((fill * 100).rounded()))%")
                        .font(.system(size: 12, weight: content.attention ? .bold : .medium))
                        .monospacedDigit()
                        .foregroundStyle(color)
                }
                if content.attention {
                    // A solid badge with the mark cut out of it: in a template image the cut-out
                    // shows the bar's background, so the badge reads inverted on any wallpaper.
                    ZStack {
                        RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 10, height: 13)
                        Text("!").font(.system(size: 11, weight: .heavy)).foregroundStyle(color).blendMode(.destinationOut)
                    }
                    .compositingGroup()
                }
            }
            .padding(2)
        }
    }
}
