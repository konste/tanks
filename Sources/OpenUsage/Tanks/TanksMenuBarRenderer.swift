import AppKit
import SwiftUI

/// The compact menu-bar item (design variant B): a tank glyph filled to the binding window's level
/// plus that window's percentage. State C (an alert advice is pending) turns the glyph red with a
/// mark; the image is then rendered in colour instead of as a monochrome template.
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
        image.isTemplate = !content.attention
        image.accessibilityDescription = content.fill.map { "Tanks \(Int($0 * 100))%" } ?? "Tanks"
        last = (content, image)
        return image
    }

    private struct Glyph: View {
        var content: Content

        var body: some View {
            let color: Color = content.attention ? Color(hex: 0xFF453A) : .black
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
                    Text("!").font(.system(size: 12, weight: .heavy)).foregroundStyle(color)
                }
            }
            .padding(2)
        }
    }
}
