import Foundation

/// Settings that persist between launches.
struct Preferences {
    var theme: ColorTheme = .green
    var rows: Float = 72          // glyph rows across the screen at arm's length; fewer = bigger glyphs
    var exposure: Float = 1
    var speed: Float = 1
    var glow: Float = 1
    var depth3D = true
    var mirror = true

    static let rowsRange: ClosedRange<Float> = 30...160
    static let exposureRange: ClosedRange<Float> = 0.25...3
    static let speedRange: ClosedRange<Float> = 0.2...4
    static let glowRange: ClosedRange<Float> = 0...2

    init() {}

    init(from r: Renderer) {
        theme = r.theme
        rows = r.rows
        exposure = r.exposure
        speed = r.speed
        glow = r.glow
        depth3D = r.depthEnabled
        mirror = r.mirror
    }

    func apply(to r: Renderer) {
        r.theme = theme
        r.rows = rows
        r.exposure = exposure
        r.speed = speed
        r.glow = glow
        r.depthEnabled = depth3D
        r.mirror = mirror
    }

    static func load(from d: UserDefaults = .standard) -> Preferences {
        var p = Preferences()
        if let t = d.string(forKey: "theme").flatMap(ColorTheme.init(rawValue:)) { p.theme = t }
        if d.object(forKey: "rows") != nil { p.rows = d.float(forKey: "rows").clamped(to: rowsRange) }
        if d.object(forKey: "exposure") != nil { p.exposure = d.float(forKey: "exposure").clamped(to: exposureRange) }
        if d.object(forKey: "speed") != nil { p.speed = d.float(forKey: "speed").clamped(to: speedRange) }
        if d.object(forKey: "glow") != nil { p.glow = d.float(forKey: "glow").clamped(to: glowRange) }
        if d.object(forKey: "depth3D") != nil { p.depth3D = d.bool(forKey: "depth3D") }
        if d.object(forKey: "mirror") != nil { p.mirror = d.bool(forKey: "mirror") }
        return p
    }

    func save(to d: UserDefaults = .standard) {
        d.set(theme.rawValue, forKey: "theme")
        d.set(rows, forKey: "rows")
        d.set(exposure, forKey: "exposure")
        d.set(speed, forKey: "speed")
        d.set(glow, forKey: "glow")
        d.set(depth3D, forKey: "depth3D")
        d.set(mirror, forKey: "mirror")
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
