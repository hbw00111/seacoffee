import AppKit
import SwiftUI

/// Native adaptation of open-claude-ui's warm surfaces and clay accent.
/// Semantic colors resolve against each hosting window, so Settings can be light
/// while the notch remains dark. No global NSApp appearance is changed.
enum Palette {
    static let canvas = adaptive(0xFAF9F6, 0x151515)
    static let sidebar = adaptive(0xF0EFEB, 0x10100F)
    static let surface = adaptive(0xFFFFFF, 0x1D1D1B)
    static let segmentThumb = adaptive(0xFFFFFF, 0x3B3A35)
    static let raised = adaptive(0xFCFCFB, 0x252523)
    static let text = adaptive(0x282723, 0xF3F1EB)
    static let dim = adaptive(0x69675F, 0xB1AEA5)
    static let muted = adaptive(0x78756E, 0x97938B)
    static let subtle = adaptive(0xEDECE7, 0x30302C)
    static let border = adaptive(0xDEDCD5, 0x3A3934)
    static let accent = adaptive(0xAE4F32, 0xD97757)
    static let accentFill = Color(hex: 0xD97757)
    static let mint = adaptive(0x26765C, 0x87C9A7)
    static let blue = adaptive(0x396D9A, 0x87B5DB)
    static let clay = accent
    static let silver = adaptive(0x595750, 0xD3D0C7)
    static let lilac = adaptive(0x755AA4, 0xB8A3D5)
    /// DSH: a cooler blue than Cline's, so the two terminal tools stay apart.
    static let ice = adaptive(0x3A5E8C, 0x9CB6DC)
    static let warning = adaptive(0x966315, 0xEBC16D)
    /// Quota below 20% left (CC Switch's orange).
    static let low = adaptive(0xC2410C, 0xFB923C)
    static let danger = adaptive(0xBA423D, 0xEF8580)

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                           green: Double((value >> 8) & 255) / 255,
                           blue: Double(value & 255) / 255, alpha: 1)
        })
    }
}

/// Notch and Droppy surfaces stay dark even when their host window reports Aqua.
enum NotchPalette {
    static let canvas = Color(hex: 0x151515)
    static let segmentThumb = Color(hex: 0x3B3A35)
    static let subtle = Color(hex: 0x30302C)
    static let border = Color(hex: 0x3A3934)
    static let text = Color(hex: 0xF3F1EB)
    static let dim = Color(hex: 0xB1AEA5)
    static let muted = Color(hex: 0x97938B)
    static let accent = Color(hex: 0xD97757)
    static let mint = Color(hex: 0x87C9A7)
    static let blue = Color(hex: 0x87B5DB)
    static let clay = accent
    static let silver = Color(hex: 0xD3D0C7)
    static let lilac = Color(hex: 0xB8A3D5)
    static let ice = Color(hex: 0x9CB6DC)
    static let attention = Color(hex: 0xA99CEC)
    static let warning = Color(hex: 0xEBC16D)
    static let low = Color(hex: 0xFB923C)
    static let danger = Color(hex: 0xEF8580)
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255,
                  blue: Double(hex & 255) / 255)
    }
}

enum InterfaceTheme: String, CaseIterable, Identifiable {
    case light, dark, system
    var id: String { rawValue }
    var title: String {
        switch self { case .light: return "暖白"; case .dark: return "深色"; case .system: return "跟随系统" }
    }
    var colorScheme: ColorScheme? {
        switch self { case .light: return .light; case .dark: return .dark; case .system: return nil }
    }
}

enum InterfaceLayout {
    static let settingsWidth: CGFloat = 880
    static let settingsHeight: CGFloat = 720
    static let sidebarWidth: CGFloat = 192
}
