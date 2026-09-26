import SwiftUI

/// The panel's colour tokens, one set per system appearance (docs/tanks/mock2.html). Light mode
/// darkens the state colours and the hatch so they hold on the pale track.
struct TanksPalette: Sendable {
    var bg, bg2, line, fg, dim, dim2, track, green, amber, red, blue, hatch, link, alertBg: Color
    var claude, codex, cursor, pillBg, pillFg: Color

    static let dark = TanksPalette(
        bg: Color(hex: 0x262628), bg2: Color(hex: 0x2F2F32), line: Color(hex: 0x3D3D41), fg: Color(hex: 0xF2F2F4),
        dim: Color(hex: 0xA0A0A8), dim2: Color(hex: 0x70707A), track: Color(hex: 0x3A3A3F),
        green: Color(hex: 0x34C759), amber: Color(hex: 0xFFB340), red: Color(hex: 0xFF5B4D), blue: Color(hex: 0x6F8FBF),
        hatch: Color.white.opacity(0.35), link: Color(hex: 0x7FB2FF), alertBg: Color(hex: 0x3A2A2A),
        claude: Color(hex: 0xE08A6A), codex: Color(hex: 0x74C3A1), cursor: Color(hex: 0x8AB4F8),
        pillBg: Color(hex: 0x2F5D3A), pillFg: Color(hex: 0x9BE6AD)
    )

    static let light = TanksPalette(
        bg: Color(hex: 0xF6F6F8), bg2: Color(hex: 0xECECF0), line: Color(hex: 0xD8D8DE), fg: Color(hex: 0x1D1D21),
        dim: Color(hex: 0x5D5D66), dim2: Color(hex: 0x8A8A94), track: Color(hex: 0xDCDCE2),
        green: Color(hex: 0x28B14C), amber: Color(hex: 0xE69A00), red: Color(hex: 0xE5443A), blue: Color(hex: 0x7D9BD0),
        hatch: Color.black.opacity(0.28), link: Color(hex: 0x2F6FD8), alertBg: Color(hex: 0xFBE4E1),
        claude: Color(hex: 0xC9633F), codex: Color(hex: 0x2E8F66), cursor: Color(hex: 0x3B6FD6),
        pillBg: Color(hex: 0xD9F2DF), pillFg: Color(hex: 0x1F6B35)
    )

    static func forScheme(_ scheme: ColorScheme) -> TanksPalette {
        scheme == .dark ? .dark : .light
    }

    func tier(_ tier: TankTier) -> Color {
        switch tier {
        case .green: green
        case .amber: amber
        case .red: red
        case .idle, .signedOut: blue
        }
    }

    func vendor(_ vendor: Vendor) -> Color {
        switch vendor {
        case .claude: claude
        case .codex: codex
        case .cursor: cursor
        }
    }

    func severity(_ severity: Advice.Severity) -> Color {
        switch severity {
        case .info: green
        case .warn: amber
        case .alert: red
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
