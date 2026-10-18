import AppKit
import ImageIO
import MetalKit
import SwiftUI
import UniformTypeIdentifiers

/// Offline check: run a look on a still image instead of the camera and write a PNG.
///   MatrixEyes --render-test <input> <output.png> [width height seconds] [look=3 bg=space bh=1 ...]
/// The keys are the same as Matrix Eyes Cam's (see the README).
func runRenderTest(_ args: [String]) -> Int32 {
    guard args.count >= 2 else {
        print("usage: --render-test <input> <output.png> [width height seconds] [key=value ...]")
        return 2
    }
    var preset = Preset.builtIns[0]
    var size = (1920, 1200)
    var seconds = 8.0
    var mirrored = false
    let numbers = args.dropFirst(2).prefix { !$0.contains("=") }.compactMap { Double($0) }
    if numbers.count >= 2 { size = (Int(numbers[0]), Int(numbers[1])) }
    if numbers.count >= 3 { seconds = numbers[2] }
    // Version 1 picked the look with environment variables; they still work.
    let env = ProcessInfo.processInfo.environment
    let order = ["green", "amber", "chrome", "quartz", "copper", "bronze", "doodle", "print"]
    if let style = env["MATRIX_STYLE"] ?? env["MATRIX_THEME"], let i = order.firstIndex(of: style) { preset = Preset.builtIns[i] }
    if let space = env["MATRIX_SPACE"] { preset.background = space == "1" ? .space : .sameAsYou }
    if env["MATRIX_BH"] == "0" { preset.blackHole = false }
    if let g = env["MATRIX_GLOW"].flatMap(Double.init) { preset.glow = g }
    if let e = env["MATRIX_EXPOSURE"].flatMap(Double.init) { preset.brightness = e }
    if env["MATRIX_FLAT"] != nil { preset.depth3D = false }

    for kv in args.dropFirst(2) {
        let parts = kv.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { continue }
        let (k, v) = (parts[0], parts[1])
        func pick<E: CaseIterable>(_ type: E.Type) -> E? { E.allCases.first { "\($0)" == v } }
        let d = Double(v) ?? 0
        switch k {
        case "preset": if let b = Preset.builtIns.first(where: { $0.name == v }) { preset = b }
        case "look": if let i = Int(v), i >= 1, i <= Preset.builtIns.count { preset = Preset.builtIns[i - 1] }
        case "bg": preset.background = pick(BackgroundKind.self) ?? preset.background
        case "subject": preset.subject = pick(SubjectMode.self) ?? preset.subject
        case "effect": preset.effect = pick(SubjectEffect.self) ?? preset.effect
        case "material": preset.material = pick(MaterialLook.self) ?? preset.material
        case "fill": preset.fill = pick(FillKind.self) ?? preset.fill
        case "grade": preset.grade = pick(Grade.self) ?? preset.grade
        case "theme": preset.matrixTheme = pick(MatrixTheme.self) ?? preset.matrixTheme
        case "bh": preset.blackHole = v == "1"
        case "hx": preset.holeX = d
        case "hy": preset.holeY = d
        case "hsize": preset.holeSize = d
        case "bend": preset.holeBend = d
        case "pull": preset.holePull = d
        case "light": preset.holeLight = d
        case "glow": preset.glow = d
        case "rows": preset.glyphRows = d
        case "t": seconds = d
        case "size": let wh = v.split(separator: "x").compactMap { Int($0) }; if wh.count == 2 { size = (wh[0], wh[1]) }
        case "mirror": mirrored = v == "1"
        case "media": preset.mediaPath = v
        case "accent": preset.accent = v.split(separator: ",").compactMap { Double($0) }
        default: break
        }
    }
    preset.mirror = mirrored
    do {
        let device = MTLCreateSystemDefaultDevice()!
        let engine = try Engine(device: device, width: size.0, height: size.1, preset: preset)
        engine.mirrorsPicture = true
        let url = URL(fileURLWithPath: args[0])
        let image = try MTKTextureLoader(device: device).newTexture(URL: url, options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft])
        engine.cameraFrame = { (image, nil) }
        if let path = preset.mediaPath { engine.media = MediaSource(url: URL(fileURLWithPath: path), device: device) }
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            let masker = PersonMasker(device: device)
            if preset.needsMask || preset.holeActive, let mask = masker.estimate(cg) { engine.maskFrame = { mask } }
            engine.faceRect = { masker.latestFace() }
            if preset.needsDepth, let depth = try DepthEstimator(device: device).estimate(cg) { engine.depthFrame = { depth } }
        }
        var gpu: [Double] = []
        for i in 0..<45 {
            let cmd = engine.renderFrame(time: seconds - Double(44 - i) / 30)
            cmd?.waitUntilCompleted()
            if let cmd, i > 5 { gpu.append(cmd.gpuEndTime - cmd.gpuStartTime) }
        }
        gpu.sort()
        print(String(format: "GPU per frame at %dx%d: median %.2f ms, worst %.2f ms",
                     engine.width, engine.height, gpu[gpu.count / 2] * 1000, (gpu.last ?? 0) * 1000))
        guard let out = engine.latest(), let cg = Engine.image(from: out),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return 1 }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest) ? 0 : 1
    } catch {
        print("render test failed: \(error)")
        return 1
    }
}

/// Draws a view offscreen into a PNG, to check a layout without opening a window.
@MainActor
func writeSnapshot(of view: NSView, to path: String) -> Int32 {
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 1 }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { return 1 }
    return (try? png.write(to: URL(fileURLWithPath: path))) != nil ? 0 : 1
}

/// The settings card:  MatrixEyes --settings-preview <output.png> [look number]
@MainActor
func runSettingsPreview(_ args: [String]) -> Int32 {
    guard let out = args.first else { return 2 }
    _ = NSApplication.shared
    PresetStore.isDeveloperCheck = true          // never save the preview's changes
    let look = LookModel(folder: "Matrix Eyes", defaultLook: "Matrix")
    if args.count > 1, let n = Int(args[1]) {
        look.store.presets = Preset.builtIns
        look.selectIndex(n - 1)
    }
    let overlay = SettingsOverlay(look: look)
    overlay.frame = NSRect(x: 0, y: 0, width: 1000, height: 980)
    return writeSnapshot(of: overlay, to: out)
}

/// The shortcuts page:  MatrixEyes --shortcuts-preview <output.png>
@MainActor
func runShortcutsPreview(_ args: [String]) -> Int32 {
    guard let out = args.first else { return 2 }
    _ = NSApplication.shared
    let overlay = ShortcutsOverlay()
    overlay.setTint(NSColor(calibratedRed: 0.55, green: 1.0, blue: 0.6, alpha: 1))
    overlay.frame = NSRect(x: 0, y: 0, width: 1100, height: 760)
    return writeSnapshot(of: overlay, to: out)
}

if let i = CommandLine.arguments.firstIndex(of: "--shortcuts-preview") {
    exit(MainActor.assumeIsolated { runShortcutsPreview(Array(CommandLine.arguments[(i + 1)...])) })
}

if let i = CommandLine.arguments.firstIndex(of: "--settings-preview") {
    exit(MainActor.assumeIsolated { runSettingsPreview(Array(CommandLine.arguments[(i + 1)...])) })
}

if let i = CommandLine.arguments.firstIndex(of: "--render-test") {
    exit(runRenderTest(Array(CommandLine.arguments[(i + 1)...])))
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
