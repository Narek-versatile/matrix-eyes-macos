import AppKit

/// The looks the camera can be turned into. The two Matrix styles draw digital rain; the rest
/// shade the 3D scene as a material (using the depth map for shape).
enum Style: String, CaseIterable {
    // Raw values of the first two match what earlier versions saved.
    case green, amber, chrome, quartz, copper, bronze, doodle, print

    var title: String {
        switch self {
        case .green: return "Matrix Green"
        case .amber: return "Matrix Amber"
        case .chrome: return "Silver Surfer"
        case .quartz: return "Quartz Statue"
        case .copper: return "Verdigris Copper"
        case .bronze: return "Bronze"
        case .doodle: return "Doodle"
        case .print: return "3D Print"
        }
    }

    var isMatrix: Bool { self == .green || self == .amber }

    /// 0 = digital rain; otherwise the material id used by `materialFS`.
    var shaderID: Float {
        switch self {
        case .green, .amber: return 0
        case .chrome: return 1
        case .quartz: return 2
        case .copper: return 3
        case .bronze: return 4
        case .doodle: return 5
        case .print: return 6
        }
    }

    /// 0 = matrix curve, 1 = filmic, 2 = plain (paper white must stay white).
    var toneMode: Float {
        switch self {
        case .green, .amber: return 0
        case .doodle: return 2
        default: return 1
        }
    }

    /// How much the glow layer contributes (scaled by the user's Glow setting).
    var bloom: Float {
        switch self {
        case .green, .amber: return 1
        case .chrome: return 0.4
        case .quartz: return 0.5
        case .copper: return 0.3
        case .bronze: return 0.35
        case .doodle: return 0
        case .print: return 0.2
        }
    }

    /// Matrix palette: glyphs are drawn in `base` (scaled by brightness, then rolled off by the
    /// tone curve so bright glyphs drift toward white); stream heads use `hot`.
    var base: SIMD3<Float> {
        switch self {
        case .amber: return SIMD3(1.0, 0.58, 0.12)   // amber phosphor CRT
        default: return SIMD3(0.40, 1.0, 0.46)       // the film's grade
        }
    }

    var hot: SIMD3<Float> {
        switch self {
        case .amber: return SIMD3(1.0, 0.93, 0.76)
        default: return SIMD3(0.92, 1.0, 0.94)
        }
    }

    /// Accent for the on-screen text and controls.
    var uiColor: NSColor {
        switch self {
        case .green: return NSColor(calibratedRed: 0.55, green: 1.0, blue: 0.6, alpha: 1)
        case .amber: return NSColor(calibratedRed: 1.0, green: 0.74, blue: 0.3, alpha: 1)
        case .chrome: return NSColor(calibratedRed: 0.72, green: 0.86, blue: 1.0, alpha: 1)
        case .quartz: return NSColor(calibratedRed: 0.97, green: 0.82, blue: 0.9, alpha: 1)
        case .copper: return NSColor(calibratedRed: 0.45, green: 0.86, blue: 0.72, alpha: 1)
        case .bronze: return NSColor(calibratedRed: 0.9, green: 0.64, blue: 0.32, alpha: 1)
        case .doodle: return NSColor(calibratedRed: 0.62, green: 0.72, blue: 1.0, alpha: 1)
        case .print: return NSColor(calibratedRed: 1.0, green: 0.42, blue: 0.38, alpha: 1)
        }
    }

    var next: Style { step(1) }
    var previous: Style { step(-1) }

    private func step(_ d: Int) -> Style {
        let all = Style.allCases
        return all[(all.firstIndex(of: self)! + d + all.count) % all.count]
    }
}
