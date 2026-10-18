import Foundation

/// Settings that persist between launches.
struct Preferences {
    var style: Style = .green
    var space = false             // outer space behind you instead of the room
    var blackHole = true          // a black hole in that space
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
        style = r.style
        space = r.spaceEnabled
        blackHole = r.blackHoleEnabled
        rows = r.rows
        exposure = r.exposure
        speed = r.speed
        glow = r.glow
        depth3D = r.depthEnabled
        mirror = r.mirror
    }

    func apply(to r: Renderer, animated: Bool = true) {
        r.setStyle(style, animated: animated)
        r.spaceEnabled = space
        r.blackHoleEnabled = blackHole
        r.rows = rows
        r.exposure = exposure
        r.speed = speed
        r.glow = glow
        r.depthEnabled = depth3D
        r.mirror = mirror
    }

    static func load(from d: UserDefaults = .standard) -> Preferences {
        var p = Preferences()
        // The key is still "theme" so settings saved by version 1.0 carry over.
        if let s = d.string(forKey: "theme").flatMap(Style.init(rawValue:)) { p.style = s }
        if d.object(forKey: "space") != nil { p.space = d.bool(forKey: "space") }
        if d.object(forKey: "blackHole") != nil { p.blackHole = d.bool(forKey: "blackHole") }
        if d.object(forKey: "rows") != nil { p.rows = d.float(forKey: "rows").clamped(to: rowsRange) }
        if d.object(forKey: "exposure") != nil { p.exposure = d.float(forKey: "exposure").clamped(to: exposureRange) }
        if d.object(forKey: "speed") != nil { p.speed = d.float(forKey: "speed").clamped(to: speedRange) }
        if d.object(forKey: "glow") != nil { p.glow = d.float(forKey: "glow").clamped(to: glowRange) }
        if d.object(forKey: "depth3D") != nil { p.depth3D = d.bool(forKey: "depth3D") }
        if d.object(forKey: "mirror") != nil { p.mirror = d.bool(forKey: "mirror") }
        return p
    }

    func save(to d: UserDefaults = .standard) {
        d.set(style.rawValue, forKey: "theme")
        d.set(space, forKey: "space")
        d.set(blackHole, forKey: "blackHole")
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
