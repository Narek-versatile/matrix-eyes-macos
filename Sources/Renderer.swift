import CoreGraphics
import Foundation
import Metal
import MetalKit
import QuartzCore

/// Mirrors `Uniforms` in Shaders.metal; keep the field order identical.
struct Uniforms {
    var resX: Float = 0
    var resY: Float = 0
    var time: Float = 0
    var cellH: Float = 24
    var cellAspect: Float = 0.8
    var exposure: Float = 1
    var contrast: Float = 1.35
    var speed: Float = 1
    var transT: Float = 100
    var transDir: Float = 1
    var camFade: Float = 0
    var camScaleX: Float = 1
    var camScaleY: Float = 1
    var mirror: Float = 1
    var glyphCount: Float = 0
    var atlasCols: Float = 0
    var atlasRows: Float = 0
    var smoothing: Float = 0.45
    var lumW: Float = 0
    var lumH: Float = 0
    // 3D
    var tanX: Float = 0.70          // ~70 degree horizontal field of view
    var camAspect: Float = 16.0 / 9.0
    var zNear: Float = 0.45
    var zFar: Float = 5.0
    var zRef: Float = 0.75
    var gamma: Float = 0.45
    var cellQ: Float = 0.01
    var depthFade: Float = 0
    var depthAlpha: Float = 0.3
    var deadband: Float = 0.012
    var fogK: Float = 0.25
    // color theme
    var baseR: Float = 0.40, baseG: Float = 1.0, baseB: Float = 0.46
    var hotR: Float = 0.92, hotG: Float = 1.0, hotB: Float = 0.94
    // style / space
    var style: Float = 0
    var spaceOn: Float = 0
    var bhOn: Float = 0
    var maskOn: Float = 0
    var bhX: Float = 0.73, bhY: Float = 0.27
    var bhTanV: Float = 0.69
    var bhElev: Float = 0.13
    var matrixLook: Float = 1
}

/// Mirrors `CompositeParams` in Shaders.metal.
struct CompositeParams {
    var glow: Float = 1
    var bloomK: Float = 1
    var toneMode: Float = 0
    var fade: Float = 1
}

enum RendererError: Error, CustomStringConvertible {
    case shaderSourceMissing
    case missingFunction(String)

    var description: String {
        switch self {
        case .shaderSourceMissing: return "The shader sources (Resources/*.metal) were not found in the app bundle."
        case .missingFunction(let name): return "Shader function \(name) is missing."
        }
    }
}

final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue

    // Live settings, changed from the keyboard.
    var rows: Float = 72
    var exposure: Float = 1
    var speed: Float = 1
    var mirror = true
    var depthEnabled = true
    /// Seconds of countdown before a photo (0 = none). Only stored here with the other settings.
    var photoTimer = 0
    var glow: Float = 1
    /// Outer space instead of the room, with you cut out in front of it.
    var spaceEnabled = false
    var blackHoleEnabled = true
    private(set) var matrixOn = true

    /// The look being shown (or fading toward). Changing it dips the picture to black for a beat.
    private(set) var style: Style = .green
    private var shownStyle: Style = .green
    private var fadeOut: Double = 0        // seconds spent fading out the old look
    private var fadeIn: Double = 1         // seconds spent fading in the new one

    func setStyle(_ new: Style, animated: Bool = true) {
        style = new
        if !animated {
            shownStyle = new
            fadeOut = 0
            fadeIn = 1
        }
    }

    /// Supplies the newest camera frame plus an object to keep alive until the GPU is done with it.
    var cameraFrame: (() -> (MTLTexture, AnyObject?)?)?
    /// Time (renderer clock) the first camera frame arrived; the scene fades in from there.
    var cameraStartTime: Double?
    /// Supplies the newest depth map (relative inverse depth, camera-aligned), if depth estimation is running.
    var depthFrame: (() -> MTLTexture?)?
    /// Supplies the newest person cut-out (r8, 1 = person), if it's running.
    var maskFrame: (() -> MTLTexture?)?
    /// 0 = flat, 1 = full 3D; eased toward its target so switching depth on/off morphs smoothly.
    var depthProgress: Double = 0
    private var lastFrameTime: Double?

    private let lumPSO, depthPSO, geoPSO, codePSO, downPSO, blurPSO, compositePSO, snapshotPSO: MTLRenderPipelineState
    private let maskPSO, spacePSO, materialPSO: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let glyphSampler: MTLSamplerState
    private let atlas: GlyphAtlas
    private let blackTexture: MTLTexture

    private var codeTex: MTLTexture?
    private var lumTex: [MTLTexture] = []
    private var lumIndex = 0
    private var bloomA: MTLTexture?, bloomB: MTLTexture?, bloomC: MTLTexture?, bloomD: MTLTexture?
    private var builtSize = (0, 0)
    private var depthSmooth: [MTLTexture] = []
    private var depthIndex = 0
    private var geoTex: MTLTexture?
    private var depthSize = (0, 0)
    private let flatGeo: MTLTexture
    private var spaceTex: MTLTexture?
    private var maskSmooth: [MTLTexture] = []
    private var maskIndex = 0
    private var maskSize = (0, 0)
    private var compositeParams = CompositeParams()

    private var transitionStart: Double = -100
    private let clockStart = CACurrentMediaTime()
    private var pendingSnapshot: ((CGImage) -> Void)?

    init(device: MTLDevice, outputFormat: MTLPixelFormat = .bgra8Unorm) throws {
        self.device = device
        queue = device.makeCommandQueue()!

        guard let source = Renderer.shaderSource() else { throw RendererError.shaderSourceMissing }
        let library = try device.makeLibrary(source: source, options: nil)

        func pipeline(_ fragment: String, _ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
            guard let vs = library.makeFunction(name: "fullscreenVS") else { throw RendererError.missingFunction("fullscreenVS") }
            guard let fs = library.makeFunction(name: fragment) else { throw RendererError.missingFunction(fragment) }
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = vs
            d.fragmentFunction = fs
            d.colorAttachments[0].pixelFormat = format
            return try device.makeRenderPipelineState(descriptor: d)
        }
        lumPSO = try pipeline("lumFS", .r16Float)
        depthPSO = try pipeline("depthFS", .r32Float)
        geoPSO = try pipeline("geoFS", .rgba16Float)
        codePSO = try pipeline("codeFS", .rgba16Float)
        materialPSO = try pipeline("materialFS", .rgba16Float)
        maskPSO = try pipeline("maskFS", .r16Float)
        spacePSO = try pipeline("spaceFS", .rgba16Float)
        downPSO = try pipeline("downFS", .rgba16Float)
        blurPSO = try pipeline("blurFS", .rgba16Float)
        compositePSO = try pipeline("compositeFS", outputFormat)
        snapshotPSO = try pipeline("compositeFS", .bgra8Unorm)

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.mipFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: sd)!
        // Glyphs on surfaces seen at an angle are squashed in one direction; anisotropic
        // filtering keeps them sharp along the other.
        sd.maxAnisotropy = 8
        glyphSampler = device.makeSamplerState(descriptor: sd)!

        atlas = GlyphAtlas(device: device, queue: queue)

        let bd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        blackTexture = device.makeTexture(descriptor: bd)!
        var px: UInt32 = 0xFF00_0000
        blackTexture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)

        // Stand-in geometry before depth arrives (depthFade is 0 then, so its values don't matter).
        let gd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        flatGeo = device.makeTexture(descriptor: gd)!
        var flat: [Float16] = [0.75, 0, 0, 0]
        flatGeo.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &flat, bytesPerRow: 8)
        super.init()
    }

    /// The shader files, in the order they're concatenated (later ones use helpers from earlier ones).
    private static let shaderFiles = ["Shaders", "Space", "Materials"]

    private static func shaderSource() -> String? {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let devDirs = [
            exe.deletingLastPathComponent().appendingPathComponent("../Resources"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources"),
        ]
        var parts: [String] = []
        for name in shaderFiles {
            let url = Bundle.main.url(forResource: name, withExtension: "metal")
                ?? devDirs.map { $0.appendingPathComponent("\(name).metal") }.first { FileManager.default.fileExists(atPath: $0.path) }
            guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            parts.append(text)
        }
        return parts.joined(separator: "\n")
    }

    var now: Double { CACurrentMediaTime() - clockStart }
    var atlasImage: CGImage? { atlas.image }

    func toggleMatrix() {
        transitionStart = now
        matrixOn.toggle()
    }

    /// Test hook: the geometry texture's contents (depth, normal x, normal y, edge) as half floats.
    func debugReadGeometry() -> (w: Int, h: Int, data: [Float16])? {
        guard let geoTex, let cmd = queue.makeCommandBuffer() else { return nil }
        let w = geoTex.width, h = geoTex.height
        let copy = makeTexture(w, h, .rgba16Float, [.shaderRead], storage: .shared)
        guard let blit = cmd.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: geoTex, to: copy)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        var data = [Float16](repeating: 0, count: w * h * 4)
        copy.getBytes(&data, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        return (w, h, data)
    }

    func requestSnapshot(_ handler: @escaping (CGImage) -> Void) {
        pendingSnapshot = handler
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer() else { return }
        encode(into: cmd, target: drawable.texture, time: now)

        if let handler = pendingSnapshot {
            pendingSnapshot = nil
            let tex = makeTexture(drawable.texture.width, drawable.texture.height, .bgra8Unorm,
                                  [.renderTarget, .shaderRead], storage: .shared)
            encodeComposite(into: cmd, target: tex, pso: snapshotPSO)
            cmd.addCompletedHandler { _ in
                if let image = Renderer.makeImage(from: tex) {
                    DispatchQueue.main.async { handler(image) }
                }
            }
        }

        cmd.present(drawable)
        cmd.commit()
    }

    // MARK: - Frame

    func encode(into cmd: MTLCommandBuffer, target: MTLTexture, time: Double) {
        let w = target.width, h = target.height
        ensureTextures(w, h)

        var cam = blackTexture
        if let frame = cameraFrame?() {
            cam = frame.0
            if cameraStartTime == nil { cameraStartTime = time }
            if let keep = frame.1 {
                cmd.addCompletedHandler { _ in withExtendedLifetime(keep) {} }
            }
        }

        var u = Uniforms()
        u.resX = Float(w)
        u.resY = Float(h)
        u.time = Float(time)
        u.cellH = Float(h) / rows
        u.exposure = exposure
        u.speed = speed
        u.mirror = mirror ? 1 : 0
        u.transT = Float(time - transitionStart)
        u.transDir = matrixOn ? 1 : 0
        if let t0 = cameraStartTime {
            let x = min(max((time - t0 - 0.3) / 2.2, 0), 1)
            u.camFade = Float(x * x * (3 - 2 * x))
        }
        let screenAspect = Float(w) / Float(h)
        let camAspect = Float(cam.width) / Float(cam.height)
        if screenAspect > camAspect {
            u.camScaleX = 1
            u.camScaleY = camAspect / screenAspect
        } else {
            u.camScaleX = screenAspect / camAspect
            u.camScaleY = 1
        }
        // Depth: ease between flat and 3D, and size the glyphs so they are cellH tall at zRef.
        let depthRaw = depthEnabled ? depthFrame?() : nil
        let dt = lastFrameTime.map { min(max(time - $0, 0), 0.1) } ?? 0
        lastFrameTime = time
        depthProgress = min(max(depthProgress + (depthRaw != nil ? dt : -dt) / 1.4, 0), 1)
        u.depthFade = Float(depthProgress * depthProgress * (3 - 2 * depthProgress))

        // Changing look: dip to black, swap while it's dark, come back up.
        var fade = 1.0
        if style != shownStyle {
            fadeOut += dt
            fade = max(1 - fadeOut / 0.14, 0)
            if fadeOut >= 0.14 {
                shownStyle = style
                fadeOut = 0
                fadeIn = 0
            }
        } else if fadeIn < 0.3 {
            fadeIn += dt
            let x = min(fadeIn / 0.3, 1)
            fade = x * x * (3 - 2 * x)
        }
        (u.baseR, u.baseG, u.baseB) = (shownStyle.base.x, shownStyle.base.y, shownStyle.base.z)
        (u.hotR, u.hotG, u.hotB) = (shownStyle.hot.x, shownStyle.hot.y, shownStyle.hot.z)
        u.style = shownStyle.shaderID
        u.matrixLook = shownStyle.isMatrix ? 1 : 0

        let maskRaw = spaceEnabled ? maskFrame?() : nil
        u.spaceOn = spaceEnabled ? 1 : 0
        u.bhOn = spaceEnabled && blackHoleEnabled ? 1 : 0
        u.maskOn = maskRaw != nil ? 1 : 0
        u.camAspect = camAspect
        u.cellQ = 2 * u.zRef * (u.tanX / camAspect) * u.camScaleY / rows

        u.glyphCount = Float(atlas.count)
        u.atlasCols = Float(atlas.cols)
        u.atlasRows = Float(atlas.rows)
        let lum = lumTex[lumIndex], prevLum = lumTex[1 - lumIndex]
        lumIndex = 1 - lumIndex
        u.lumW = Float(lum.width)
        u.lumH = Float(lum.height)

        guard let codeTex, let bloomA, let bloomB, let bloomC, let bloomD else { return }

        // 1. Camera -> luminance, then mipmaps for per-cell averages and the frame mean.
        pass(cmd, lum, lumPSO) { enc in
            enc.setFragmentTexture(cam, index: 0)
            enc.setFragmentTexture(prevLum, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        }
        if let blit = cmd.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: lum)
            blit.endEncoding()
        }

        // 2. Depth -> filtered metres -> normals and silhouettes.
        var geometry = flatGeo
        if let depthRaw {
            ensureDepthTextures(depthRaw.width, depthRaw.height)
            let smooth = depthSmooth[depthIndex], prevSmooth = depthSmooth[1 - depthIndex]
            depthIndex = 1 - depthIndex
            pass(cmd, smooth, depthPSO) { enc in
                enc.setFragmentTexture(depthRaw, index: 0)
                enc.setFragmentTexture(prevSmooth, index: 1)
                enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            }
            if let geoTex {
                pass(cmd, geoTex, geoPSO) { enc in
                    enc.setFragmentTexture(smooth, index: 0)
                    enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                }
                geometry = geoTex
            }
        } else if depthProgress > 0, let geoTex {
            geometry = geoTex  // depth switched off: keep the last geometry while morphing back to flat
        }

        // 3. Outer space (stars, black hole) and the cut-out of you to put in front of it.
        var spaceTexture = blackTexture
        var maskTexture = blackTexture
        if spaceEnabled, let spaceTex {
            pass(cmd, spaceTex, spacePSO) { enc in
                enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            }
            spaceTexture = spaceTex
            if let maskRaw {
                ensureMaskTextures(maskRaw.width, maskRaw.height)
                let smooth = maskSmooth[maskIndex], prevSmooth = maskSmooth[1 - maskIndex]
                maskIndex = 1 - maskIndex
                pass(cmd, smooth, maskPSO) { enc in
                    enc.setFragmentTexture(maskRaw, index: 0)
                    enc.setFragmentTexture(prevSmooth, index: 1)
                }
                maskTexture = smooth
            }
        }

        // 4. The look itself: digital rain, or a material, mapped onto the surfaces.
        pass(cmd, codeTex, shownStyle.isMatrix ? codePSO : materialPSO) { enc in
            enc.setFragmentTexture(lum, index: 0)
            enc.setFragmentTexture(self.atlas.texture, index: 1)
            enc.setFragmentTexture(cam, index: 2)
            enc.setFragmentTexture(geometry, index: 3)
            enc.setFragmentTexture(spaceTexture, index: 4)
            enc.setFragmentTexture(maskTexture, index: 5)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        }

        // 5. Glow at 1/4 and 1/8 resolution.
        down(cmd, from: codeTex, to: bloomA)
        blur(cmd, from: bloomA, to: bloomB, dir: SIMD2(1, 0), spread: 1.0)
        blur(cmd, from: bloomB, to: bloomA, dir: SIMD2(0, 1), spread: 1.0)
        down(cmd, from: bloomA, to: bloomC)
        blur(cmd, from: bloomC, to: bloomD, dir: SIMD2(1, 0), spread: 1.6)
        blur(cmd, from: bloomD, to: bloomC, dir: SIMD2(0, 1), spread: 1.6)

        // 6. Composite to screen.
        compositeParams = CompositeParams(glow: glow, bloomK: shownStyle.bloom, toneMode: shownStyle.toneMode, fade: Float(fade))
        encodeComposite(into: cmd, target: target, pso: compositePSO)
    }

    private func encodeComposite(into cmd: MTLCommandBuffer, target: MTLTexture, pso: MTLRenderPipelineState) {
        guard let codeTex, let bloomA, let bloomC else { return }
        var params = compositeParams
        pass(cmd, target, pso) { enc in
            enc.setFragmentTexture(codeTex, index: 0)
            enc.setFragmentTexture(bloomA, index: 1)
            enc.setFragmentTexture(bloomC, index: 2)
            enc.setFragmentBytes(&params, length: MemoryLayout<CompositeParams>.stride, index: 0)
        }
    }

    private func down(_ cmd: MTLCommandBuffer, from src: MTLTexture, to dst: MTLTexture) {
        var texel = SIMD2<Float>(1 / Float(src.width), 1 / Float(src.height))
        pass(cmd, dst, downPSO) { enc in
            enc.setFragmentTexture(src, index: 0)
            enc.setFragmentBytes(&texel, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        }
    }

    private func blur(_ cmd: MTLCommandBuffer, from src: MTLTexture, to dst: MTLTexture, dir: SIMD2<Float>, spread: Float) {
        var d = dir * spread / SIMD2(Float(src.width), Float(src.height))
        pass(cmd, dst, blurPSO) { enc in
            enc.setFragmentTexture(src, index: 0)
            enc.setFragmentBytes(&d, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        }
    }

    private func pass(_ cmd: MTLCommandBuffer, _ target: MTLTexture, _ pso: MTLRenderPipelineState,
                      _ bind: (MTLRenderCommandEncoder) -> Void) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.setRenderPipelineState(pso)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.setFragmentSamplerState(glyphSampler, index: 1)
        bind(enc)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    // MARK: - Resources

    private func ensureTextures(_ w: Int, _ h: Int) {
        guard builtSize != (w, h) else { return }
        builtSize = (w, h)
        codeTex = makeTexture(w, h, .rgba16Float)
        lumTex = (0..<2).map { _ in makeTexture(max(w / 4, 1), max(h / 4, 1), .r16Float, mipmapped: true) }
        clear(lumTex, to: 0.3)
        bloomA = makeTexture(max(w / 4, 1), max(h / 4, 1), .rgba16Float)
        bloomB = makeTexture(max(w / 4, 1), max(h / 4, 1), .rgba16Float)
        bloomC = makeTexture(max(w / 8, 1), max(h / 8, 1), .rgba16Float)
        bloomD = makeTexture(max(w / 8, 1), max(h / 8, 1), .rgba16Float)
        spaceTex = makeTexture(w, h, .rgba16Float)
    }

    private func ensureMaskTextures(_ w: Int, _ h: Int) {
        guard maskSize != (w, h) else { return }
        maskSize = (w, h)
        maskSmooth = (0..<2).map { _ in makeTexture(w, h, .r16Float) }
        clear(maskSmooth, to: 0)
    }

    private func ensureDepthTextures(_ w: Int, _ h: Int) {
        guard depthSize != (w, h) else { return }
        depthSize = (w, h)
        depthSmooth = (0..<2).map { _ in makeTexture(w, h, .r32Float) }
        clear(depthSmooth, to: 0)  // 0 = "no history yet", the filter starts from the first raw frame
        geoTex = makeTexture(w, h, .rgba16Float)
    }

    /// Fresh GPU memory is undefined (possibly NaN). Buffers that feed back into themselves
    /// through temporal smoothing must start out cleared.
    private func clear(_ textures: [MTLTexture], to value: Double) {
        guard let cmd = queue.makeCommandBuffer() else { return }
        for tex in textures {
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = tex
            rp.colorAttachments[0].loadAction = .clear
            rp.colorAttachments[0].clearColor = MTLClearColor(red: value, green: 0, blue: 0, alpha: 1)
            rp.colorAttachments[0].storeAction = .store
            cmd.makeRenderCommandEncoder(descriptor: rp)?.endEncoding()
        }
        cmd.commit()
    }

    func makeTexture(_ w: Int, _ h: Int, _ format: MTLPixelFormat,
                     _ usage: MTLTextureUsage = [.renderTarget, .shaderRead],
                     storage: MTLStorageMode = .private, mipmapped: Bool = false) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: mipmapped)
        d.usage = usage
        d.storageMode = storage
        return device.makeTexture(descriptor: d)!
    }

    static func makeImage(from tex: MTLTexture) -> CGImage? {
        let w = tex.width, h = tex.height, bpr = w * 4
        var bytes = [UInt8](repeating: 0, count: bpr * h)
        tex.getBytes(&bytes, bytesPerRow: bpr, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
