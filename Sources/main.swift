import AppKit
import ImageIO
import MetalKit
import UniformTypeIdentifiers

/// Offline check: run the filter on a still image instead of the camera and write a PNG.
///   MatrixEyes --render-test <input image> <output.png> [width height seconds]
func runRenderTest(_ args: [String]) -> Int32 {
    guard args.count >= 2 else {
        print("usage: --render-test <input> <output.png> [width height seconds]")
        return 2
    }
    let width = args.count > 2 ? Int(args[2]) ?? 1920 : 1920
    let height = args.count > 3 ? Int(args[3]) ?? 1200 : 1200
    let seconds = args.count > 4 ? Double(args[4]) ?? 8 : 8

    do {
        let device = MTLCreateSystemDefaultDevice()!
        let renderer = try Renderer(device: device)
        let image = try MTKTextureLoader(device: device).newTexture(
            URL: URL(fileURLWithPath: args[0]),
            options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft])
        renderer.cameraFrame = { (image, nil) }
        renderer.cameraStartTime = -100
        renderer.mirror = false
        let env = ProcessInfo.processInfo.environment
        if let style = (env["MATRIX_STYLE"] ?? env["MATRIX_THEME"]).flatMap(Style.init(rawValue:)) {
            renderer.setStyle(style, animated: false)
        }
        if let g = env["MATRIX_GLOW"].flatMap(Float.init) { renderer.glow = g }
        if let e = env["MATRIX_EXPOSURE"].flatMap(Float.init) { renderer.exposure = e }
        renderer.spaceEnabled = env["MATRIX_SPACE"] == "1"
        renderer.blackHoleEnabled = env["MATRIX_BH"] != "0"
        if renderer.spaceEnabled, let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[0]) as CFURL, nil),
           let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            let masker = PersonMasker(device: device)
            _ = masker.estimate(cgImage)
            if let maskTex = masker.estimate(cgImage) {
                print(String(format: "person mask: %dx%d in %.1f ms", maskTex.width, maskTex.height, masker.lastInferenceMs))
                renderer.maskFrame = { maskTex }
                if let out = env["MATRIX_MASK_OUT"] { saveMaskPreview(maskTex, to: out) }
            } else {
                print("person mask: none found")
            }
        }

        if ProcessInfo.processInfo.environment["MATRIX_FLAT"] == nil,
           let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[0]) as CFURL, nil),
           let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            let estimator = try DepthEstimator(device: device)
            _ = estimator.estimate(cgImage)  // first run includes model warm-up
            if let depthTex = estimator.estimate(cgImage) {
                print(String(format: "depth: %dx%d in %.1f ms", depthTex.width, depthTex.height, estimator.lastInferenceMs))
                renderer.depthFrame = { depthTex }
                renderer.depthProgress = 1
                if let out = ProcessInfo.processInfo.environment["MATRIX_DEPTH_OUT"] {
                    saveDepthPreview(depthTex, to: out)
                }
            }
        }

        let target = renderer.makeTexture(width, height, .bgra8Unorm, [.renderTarget, .shaderRead], storage: .shared)
        // Warm up the temporal smoothing and auto gain, and time the GPU work per frame.
        var gpuTimes: [Double] = []
        let frames = 90
        for i in 0..<frames {
            let cmd = renderer.queue.makeCommandBuffer()!
            renderer.encode(into: cmd, target: target, time: seconds - Double(frames - 1 - i) / 60)
            cmd.commit()
            cmd.waitUntilCompleted()
            if i >= 10 { gpuTimes.append(cmd.gpuEndTime - cmd.gpuStartTime) }
        }
        gpuTimes.sort()
        print(String(format: "GPU per frame at %dx%d: median %.2f ms, worst %.2f ms",
                     width, height, gpuTimes[gpuTimes.count / 2] * 1000, gpuTimes.last! * 1000))

        if env["MATRIX_DUMP_GEO"] != nil, let g = renderer.debugReadGeometry() {
            var bad: [(Int, Int)] = []
            for y in 0..<g.h { for x in 0..<g.w {
                let i = (y * g.w + x) * 4
                if !g.data[i + 1].isFinite || !g.data[i + 2].isFinite { bad.append((x, y)) }
            } }
            if let xs = bad.map(\.0).min(), let xe = bad.map(\.0).max(), let ys = bad.map(\.1).min(), let ye = bad.map(\.1).max() {
                print("geo NaN texels: \(bad.count) in x \(xs)...\(xe), y \(ys)...\(ye) of \(g.w)x\(g.h)")
                let i = (ys * g.w + xs) * 4
                print("sample at corner:", g.data[i], g.data[i + 1], g.data[i + 2], g.data[i + 3])
                let j = ((ys + 5) * g.w + xs + 5) * 4
                print("inside:", g.data[j], g.data[j + 1], g.data[j + 2], g.data[j + 3])
            } else { print("geo: no NaN") }
        }

        if let atlasOut = ProcessInfo.processInfo.environment["MATRIX_ATLAS_OUT"], let atlasImage = renderer.atlasImage,
           let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: atlasOut) as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, atlasImage, nil)
            CGImageDestinationFinalize(dest)
        }

        guard let cg = Renderer.makeImage(from: target),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil)
        else { return 1 }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest) ? 0 : 1
    } catch {
        print("render test failed: \(error)")
        return 1
    }
}

/// Writes the network's depth output as a grayscale PNG (white = near) and prints its value range.
func saveDepthPreview(_ tex: MTLTexture, to path: String) {
    let w = tex.width, h = tex.height
    var halfs = [Float16](repeating: 0, count: w * h)
    tex.getBytes(&halfs, bytesPerRow: w * 2, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    let values = halfs.map { Float($0) }
    let lo = values.min() ?? 0, hi = values.max() ?? 1
    print(String(format: "depth range: %.3f ... %.3f", lo, hi))
    var gray = values.map { UInt8(max(0, min(255, ($0 - lo) / max(hi - lo, 1e-6) * 255))) }
    guard let ctx = CGContext(data: &gray, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
          let img = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

/// Writes the person cut-out as a grayscale PNG.
func saveMaskPreview(_ tex: MTLTexture, to path: String) {
    let w = tex.width, h = tex.height
    var bytes = [UInt8](repeating: 0, count: w * h)
    tex.getBytes(&bytes, bytesPerRow: w, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    print(String(format: "mask coverage: %.1f%%", Double(bytes.filter { $0 > 127 }.count) / Double(w * h) * 100))
    guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
          let img = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

/// Draws the settings menu offscreen into a PNG, to check its layout without opening a window.
///   MatrixEyes --settings-preview <output.png> [green|amber]
func runSettingsPreview(_ args: [String]) -> Int32 {
    guard let out = args.first else { return 2 }
    _ = NSApplication.shared
    var prefs = Preferences()
    if args.count > 1, let style = Style(rawValue: args[1]) { prefs.style = style }
    let overlay = SettingsOverlay()
    overlay.frame = NSRect(x: 0, y: 0, width: 1000, height: 640)
    overlay.show(prefs, depthAvailable: true)
    overlay.setPhotoFolder("~/Pictures/Matrix Eyes")
    overlay.layoutSubtreeIfNeeded()
    guard let rep = overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds) else { return 1 }
    overlay.cacheDisplay(in: overlay.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { return 1 }
    return (try? png.write(to: URL(fileURLWithPath: out))) != nil ? 0 : 1
}

/// Draws the shortcuts page offscreen into a PNG.
///   MatrixEyes --shortcuts-preview <output.png> [style]
func runShortcutsPreview(_ args: [String]) -> Int32 {
    guard let out = args.first else { return 2 }
    _ = NSApplication.shared
    let overlay = ShortcutsOverlay()
    overlay.setTint((args.count > 1 ? Style(rawValue: args[1]) : nil)?.uiColor ?? Style.green.uiColor)
    overlay.frame = NSRect(x: 0, y: 0, width: 1100, height: 700)
    overlay.layoutSubtreeIfNeeded()
    guard let rep = overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds) else { return 1 }
    overlay.cacheDisplay(in: overlay.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { return 1 }
    return (try? png.write(to: URL(fileURLWithPath: out))) != nil ? 0 : 1
}

if let i = CommandLine.arguments.firstIndex(of: "--shortcuts-preview") {
    exit(runShortcutsPreview(Array(CommandLine.arguments[(i + 1)...])))
}

if let i = CommandLine.arguments.firstIndex(of: "--settings-preview") {
    exit(runSettingsPreview(Array(CommandLine.arguments[(i + 1)...])))
}

if let i = CommandLine.arguments.firstIndex(of: "--render-test") {
    exit(runRenderTest(Array(CommandLine.arguments[(i + 1)...])))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
