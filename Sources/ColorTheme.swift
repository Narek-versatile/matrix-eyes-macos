import AppKit

/// Color palettes for the code. Glyphs are drawn in `base` (scaled by brightness, then rolled
/// off by the tone curve, so bright glyphs drift toward white); stream heads use `hot`.
enum ColorTheme: String, CaseIterable {
    case green
    case amber

    var title: String {
        switch self {
        case .green: return "Green"
        case .amber: return "Amber"
        }
    }

    var base: SIMD3<Float> {
        switch self {
        case .green: return SIMD3(0.40, 1.0, 0.46)   // the film's grade
        case .amber: return SIMD3(1.0, 0.58, 0.12)   // amber phosphor CRT
        }
    }

    var hot: SIMD3<Float> {
        switch self {
        case .green: return SIMD3(0.92, 1.0, 0.94)
        case .amber: return SIMD3(1.0, 0.93, 0.76)
        }
    }

    /// Accent for the on-screen text and controls.
    var uiColor: NSColor {
        switch self {
        case .green: return NSColor(calibratedRed: 0.55, green: 1.0, blue: 0.6, alpha: 1)
        case .amber: return NSColor(calibratedRed: 1.0, green: 0.74, blue: 0.3, alpha: 1)
        }
    }

    var next: ColorTheme {
        let all = ColorTheme.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}
