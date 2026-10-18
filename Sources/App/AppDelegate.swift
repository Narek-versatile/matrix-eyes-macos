import AppKit
import ImageIO
import MetalKit
import UniformTypeIdentifiers

/// The picture. Dragging on it moves the black hole.
final class MatrixView: MTKView {
    /// Called with the mouse position, 0...1 from the top-left, while the button is down.
    var onDrag: ((CGPoint) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { drag(event) }
    override func mouseDragged(with event: NSEvent) { drag(event) }

    private func drag(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        onDrag?(CGPoint(x: p.x / max(bounds.width, 1), y: 1 - p.y / max(bounds.height, 1)))
    }
}

/// Renders the look at the window's size and draws it into the window, every display frame.
final class Presenter: NSObject, MTKViewDelegate {
    let engine: Engine
    private let pipeline: MTLRenderPipelineState?

    init(engine: Engine, format: MTLPixelFormat) {
        self.engine = engine
        pipeline = try? engine.previewPipeline(format)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        engine.setOutputSize(Int(size.width), Int(size.height))
    }

    func draw(in view: MTKView) {
        guard let pipeline else { return }
        engine.setOutputSize(Int(view.drawableSize.width), Int(view.drawableSize.height))
        engine.renderFrame { [sampler = engine.sampler] picture, cmd in
            guard let drawable = view.currentDrawable, let rp = view.currentRenderPassDescriptor,
                  let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
            var p = PreviewParams(mirror: 0, scaleX: 1, scaleY: 1)   // the engine already mirrored it
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(picture, index: 0)
            enc.setFragmentBytes(&p, length: MemoryLayout<PreviewParams>.stride, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
            cmd.present(drawable)
        }
    }
}

/// Overlay pieces that must never catch mouse clicks meant for the controls underneath.
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class PassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Small rounded translucent panel holding one label.
final class Pill: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    let label = NSTextField(labelWithString: "")

    init(fontSize: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.62).cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        label.font = .monospacedSystemFont(ofSize: fontSize, weight: .medium)
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setTint(_ color: NSColor) {
        layer?.borderColor = color.withAlphaComponent(0.25).cgColor
        label.textColor = color
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var view: MatrixView!
    private var engine: Engine!
    private var presenter: Presenter!
    private let look = LookModel(folder: "Matrix Eyes", defaultLook: "Matrix")
    private let camera = Camera()
    private var depth: DepthEstimator?
    private var masker: PersonMasker?
    private let help = Pill(fontSize: 13)
    private let toast = Pill(fontSize: 14)
    private var toastHide: DispatchWorkItem?
    private var helpHide: DispatchWorkItem?
    private var cameraProblem = false
    private var settings: SettingsOverlay!
    private var settingsOpen = false
    private var keyMonitor: Any?
    private var askingFolder = false
    private let flash = PassthroughView()
    private let countdown = PassthroughLabel(labelWithString: "")
    private let countdownHint = PassthroughLabel(labelWithString: "S or Esc to cancel")
    private let shortcuts = ShortcutsOverlay()
    private var shortcutsOpen = false
    private var countdownToken = 0          // bumped to cancel a running countdown
    private var counting = false
    private var roomBackground = BackgroundKind.sameAsYou   // where G goes back to from space

    private static let helpText = "H  keyboard shortcuts      Esc  settings"
    private var photos: PhotoSaver { look.photos }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        migrateVersion1Settings()

        guard let device = MTLCreateSystemDefaultDevice() else {
            fail("This Mac has no Metal GPU.")
            return
        }
        do {
            engine = try Engine(device: device, width: 1920, height: 1200, preset: look.preset)
        } catch {
            fail("Couldn't start the renderer:\n\(error)")
            return
        }
        engine.mirrorsPicture = true            // what you see is what you are: a mirror

        let frame = NSScreen.main?.visibleFrame.insetBy(dx: 80, dy: 60) ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Matrix Eyes"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self

        view = MatrixView(frame: frame, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        presenter = Presenter(engine: engine, format: view.colorPixelFormat)
        view.delegate = presenter
        view.onDrag = { [weak self] point in self?.dragHole(to: point) }
        window.contentView = view

        for pill in [help, toast] {
            pill.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(pill)
        }
        NSLayoutConstraint.activate([
            help.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            help.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -28),
            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -40),
            toast.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.7),
        ])
        help.label.stringValue = AppDelegate.helpText
        toast.alphaValue = 0

        settings = SettingsOverlay(look: look)
        settings.translatesAutoresizingMaskIntoConstraints = false
        settings.isHidden = true
        view.addSubview(settings)
        pin(settings)
        settings.onResume = { [weak self] in self?.setSettingsOpen(false) }
        settings.onQuit = { NSApp.terminate(nil) }
        settings.onShowShortcuts = { [weak self] in self?.setShortcutsOpen(true) }

        shortcuts.translatesAutoresizingMaskIntoConstraints = false
        shortcuts.isHidden = true
        shortcuts.onClose = { [weak self] in self?.setShortcutsOpen(false) }
        view.addSubview(shortcuts)
        pin(shortcuts)

        countdown.font = .monospacedSystemFont(ofSize: 260, weight: .heavy)
        countdown.alignment = .center
        countdown.alphaValue = 0
        countdown.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.7)
            shadow.shadowBlurRadius = 24
            return shadow
        }()
        countdownHint.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
        countdownHint.alphaValue = 0
        for label in [countdown, countdownHint] {
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
        }
        NSLayoutConstraint.activate([
            countdown.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            countdown.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            countdownHint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            countdownHint.topAnchor.constraint(equalTo: countdown.bottomAnchor, constant: 4),
        ])

        flash.wantsLayer = true
        flash.layer?.backgroundColor = NSColor.white.cgColor
        flash.alphaValue = 0
        flash.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(flash, positioned: .above, relativeTo: nil)
        pin(flash)

        // All keys go through here so Esc works whether the picture or a settings control has focus.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !event.modifierFlags.contains(.command) else { return event }
            if self.askingFolder || event.window !== self.window { return event }   // a sheet or picker has the keys
            let name = AppDelegate.keyName(for: event)

            // Holding a key sends repeats. Only adjustments should repeat: a held S must not
            // start a countdown and then cancel it, a held Esc must not flicker the menu.
            if event.isARepeat && !AppDelegate.repeatableKeys.contains(event.keyCode) {
                return self.settingsOpen ? event : nil
            }
            if self.shortcutsOpen {
                if event.keyCode == 53 || event.keyCode == 36 || event.keyCode == 49 || name == "h" || name == "/" {
                    self.setShortcutsOpen(false)
                }
                return nil
            }
            if event.keyCode == 53 {
                if self.counting { self.cancelCountdown(); return nil }
                self.setSettingsOpen(!self.settingsOpen)
                return nil
            }
            if self.settingsOpen { return event }
            if name == "h" || name == "/" {
                self.setShortcutsOpen(true)
                return nil
            }
            self.handleKey(event)
            return nil
        }

        // The look panel and the keys both change the look; the engine follows.
        look.onChange = { [weak self] p, animated in
            guard let self else { return }
            let mediaChanged = p.mediaPath != self.engine.preset.mediaPath
            self.engine.setPreset(p, animated: animated)
            if mediaChanged { self.loadMedia() }
            self.tint()
        }
        look.takePhoto = { [weak self] in
            // from the settings card: close it, let the camera wake up, then shoot
            self?.setSettingsOpen(false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.takePhoto() }
        }
        look.askForPhotoFolder = { [weak self] done in self?.askForPhotoFolder(done) }
        loadMedia()

        engine.cameraFrame = { [camera] in camera.latest() }
        // Depth runs on the Neural Engine; if the model is missing the app still works, just flat.
        depth = try? DepthEstimator(device: device)
        look.depthAvailable = depth != nil
        let depth = self.depth
        engine.depthFrame = { depth?.latestTexture() }
        // The person cut-out (and face position) only run for looks that need them.
        let personMasker = PersonMasker(device: device)
        masker = personMasker
        engine.maskFrame = { personMasker.latestTexture() }
        engine.faceRect = { personMasker.latestFace() }
        camera.onPixelBuffer = { [weak engine] buffer in
            guard let p = engine?.preset else { return }
            if p.needsDepth { depth?.submit(buffer) }
            if p.needsMask || (p.holeActive && p.holeMotion == .orbit) { personMasker.submit(buffer) }
        }
        camera.onProblem = { [weak self] message in
            self?.cameraProblem = true
            self?.showToast(message, sticky: true)
        }
        if let path = ProcessInfo.processInfo.environment["MATRIX_TEST_IMAGE"] {
            useTestImage(path, device: device, masker: personMasker)   // developer checks: no camera
        } else {
            camera.start(device: device)
        }
        tint()

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { self.window.toggleFullScreen(nil) }
        scheduleHelpHide(after: 7)
        NSCursor.setHiddenUntilMouseMoves(true)
        if ProcessInfo.processInfo.environment["MATRIX_SELFTEST"] != nil { runSelfTest() }
        if ProcessInfo.processInfo.environment["MATRIX_KEYTEST"] != nil { runKeyTest() }
    }

    private func pin(_ overlay: NSView) {
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func loadMedia() {
        guard let path = look.preset.mediaPath else { engine.media = nil; return }
        engine.media = MediaSource(url: URL(fileURLWithPath: path), device: engine.device)
    }

    /// Version 1 kept one set of settings in UserDefaults. On the first launch of this version they
    /// become the starting point: the look you had, with your background, glyph size, brightness and so on.
    private func migrateVersion1Settings() {
        let d = UserDefaults.standard
        guard !look.store.hadSavedFile, let theme = d.string(forKey: "theme") else { return }
        let order = ["green", "amber", "chrome", "quartz", "copper", "bronze", "doodle", "print"]
        look.selectIndex(order.firstIndex(of: theme) ?? 0)
        func clamped(_ key: String, _ range: ClosedRange<Double>) -> Double? {
            d.object(forKey: key) == nil ? nil : min(max(d.double(forKey: key), range.lowerBound), range.upperBound)
        }
        look.update { p in
            if d.object(forKey: "space") != nil {
                if d.bool(forKey: "space") { p.background = .space } else if p.background == .space { p.background = .sameAsYou }
            }
            if d.object(forKey: "blackHole") != nil { p.blackHole = d.bool(forKey: "blackHole") }
            if let v = clamped("rows", Preset.glyphRowsRange) { p.glyphRows = v }
            if let v = clamped("exposure", Preset.brightnessRange) { p.brightness = v }
            if let v = clamped("speed", Preset.rainSpeedRange) { p.rainSpeed = v }
            if let v = clamped("glow", Preset.glowRange) { p.glow = v }
            if d.object(forKey: "depth3D") != nil { p.depth3D = d.bool(forKey: "depth3D") }
            if d.object(forKey: "mirror") != nil { p.mirror = d.bool(forKey: "mirror") }
        }
    }

    /// Developer checks (MATRIX_TEST_IMAGE=photo): a still photo stands in for the camera, which stays off.
    private func useTestImage(_ path: String, device: MTLDevice, masker: PersonMasker) {
        let url = URL(fileURLWithPath: path)
        guard let tex = try? MTKTextureLoader(device: device).newTexture(URL: url, options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft]),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
        engine.cameraFrame = { (tex, nil) }
        let mask = masker.estimate(cg)
        let depthTex = depth?.estimate(cg)
        engine.maskFrame = { mask }
        engine.depthFrame = { depthTex }
    }

    /// Sends a real key event through the app's event path (so the key monitor sees it).
    private func press(_ chars: String, keyCode: UInt16, repeating: Bool = false) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: chars, charactersIgnoringModifiers: chars,
                                           isARepeat: repeating, keyCode: keyCode) else { return }
        NSApp.sendEvent(event)
    }

    /// Developer check (MATRIX_KEYTEST=dir): drives the photo and help keys through real key events.
    private func runKeyTest() {
        guard let dir = ProcessInfo.processInfo.environment["MATRIX_KEYTEST"] else { return }
        photos.overrideFolder = URL(fileURLWithPath: dir, isDirectory: true)
        func count() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".png") }.count) ?? 0 }
        func log(_ text: String) { FileHandle.standardError.write(Data("keytest: \(text)\n".utf8)) }
        var t = 3.0
        func at(_ delay: Double, _ work: @escaping @MainActor () -> Void) {
            t += delay
            nonisolated(unsafe) let work = work
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated { work() } }
        }
        at(0) { [weak self] in self?.look.photoTimer = 0; self?.press("s", keyCode: 1) }
        at(2.0) { log("S, no timer -> \(count()) photos (expect 1)") }
        at(0.1) { [weak self] in self?.press("ы", keyCode: 1) }                       // S key on a Russian layout
        at(2.0) { log("S key typed as another letter (Russian layout) -> \(count()) photos (expect 2)") }
        at(0.1) { [weak self] in self?.look.photoTimer = 3; self?.press("s", keyCode: 1) }
        at(1.0) { [weak self] in log("1 s into a 3 s countdown -> \(count()) photos (expect 2), counting=\(self?.counting ?? false)") }
        at(0.1) { [weak self] in self?.press("s", keyCode: 1, repeating: true) }     // key auto-repeat
        at(0.3) { [weak self] in log("after an auto-repeat S -> counting=\(self?.counting ?? false) (expect true)") }
        at(3.5) { log("after the countdown -> \(count()) photos (expect 3)") }
        at(0.1) { [weak self] in
            self?.look.photoTimer = 0
            self?.press("s", keyCode: 1); self?.press("s", keyCode: 1, repeating: true); self?.press("s", keyCode: 1, repeating: true)
        }
        at(2.0) { log("S held down (3 events) -> \(count()) photos (expect 4)") }
        at(0.1) { [weak self] in self?.press("3", keyCode: 20) }
        at(0.4) { [weak self] in log("3 -> \(self?.look.preset.name ?? "?") (expect Silver Surfer in space)") }
        at(0.1) { [weak self] in self?.press("b", keyCode: 11) }
        at(0.3) { [weak self] in log("B -> black hole \(self?.look.preset.blackHole ?? true) (expect false)") }
        at(0.1) { [weak self] in self?.press("b", keyCode: 11) }
        at(0.3) { [weak self] in log("B -> black hole \(self?.look.preset.blackHole ?? false) (expect true)") }
        at(0.1) { [weak self] in self?.press("o", keyCode: 31) }
        at(0.3) { [weak self] in log("O -> \((self?.look.preset.holeMotion).map { "\($0)" } ?? "?") (expect orbit)") }
        at(0.1) { [weak self] in self?.view.onDrag?(CGPoint(x: 0.2, y: 0.3)) }
        at(0.3) { [weak self] in
            self?.engine.renderFrame()?.waitUntilCompleted()      // a hidden window draws nothing by itself
            let h = self?.engine.holePosition ?? .zero
            log(String(format: "drag to 0.20, 0.30 -> hole at %.2f, %.2f, %@ (expect about 0.20, 0.30, stay)",
                       h.x, h.y, (self?.look.preset.holeMotion).map { "\($0)" } ?? "?"))
        }
        at(0.1) { [weak self] in self?.press("g", keyCode: 5) }
        at(0.3) { [weak self] in log("G -> \(self?.look.preset.background.title ?? "?") (expect Room in your look)") }
        at(0.1) { [weak self] in self?.press("h", keyCode: 4) }
        at(0.4) { [weak self] in log("H -> shortcuts open=\(self?.shortcutsOpen ?? false) (expect true)") }
        at(0.1) { [weak self] in self?.press("\u{1b}", keyCode: 53) }
        at(0.4) { [weak self] in log("Esc -> shortcuts open=\(self?.shortcutsOpen ?? true), settings open=\(self?.settingsOpen ?? true) (expect false, false)") }
        at(0.1) { [weak self] in self?.press("\u{1b}", keyCode: 53) }
        at(0.5) { [weak self] in
            guard let self else { return }
            let hit = self.view.hitTest(NSPoint(x: self.view.bounds.midX, y: self.view.bounds.midY))
            log("Esc -> settings open=\(self.settingsOpen); a click in the card reaches the settings: \(hit?.isDescendant(of: self.settings) ?? false) (expect true, true)")
        }
        at(0.5) { NSApp.terminate(nil) }
    }

    /// Developer check (MATRIX_SELFTEST=1): drives the real app through every look, space, the black
    /// hole and the settings menu (which pauses and resumes the camera), then quits.
    private func runSelfTest() {
        var t = 3.0   // let the camera come up first
        func at(_ delay: Double, _ work: @escaping @MainActor () -> Void) {
            t += delay
            nonisolated(unsafe) let work = work
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated { work() } }
        }
        for i in 0..<8 { at(1.0) { [weak self] in self?.look.selectIndex(i) } }
        at(1.0) { [weak self] in self?.look.selectIndex(2) }
        at(1.5) { [weak self] in self?.look.update { $0.blackHole.toggle() } }
        at(1.0) { [weak self] in self?.look.update { $0.blackHole.toggle() } }
        at(1.0) { [weak self] in self?.look.update { $0.holeMotion = .orbit } }
        at(1.5) { [weak self] in self?.setSettingsOpen(true) }
        at(1.5) { [weak self] in self?.setSettingsOpen(false) }
        at(1.5) { [weak self] in self?.look.update { $0.background = .sameAsYou } }
        at(1.5) { [weak self] in self?.look.selectIndex(3) }
        if let dir = ProcessInfo.processInfo.environment["MATRIX_SELFTEST_PHOTO_DIR"] {
            func count() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".png") }.count) ?? 0 }
            at(0.5) { [weak self] in
                self?.photos.overrideFolder = URL(fileURLWithPath: dir, isDirectory: true)
                self?.look.photoTimer = 0                       // whatever your saved timer is
                self?.takePhoto()
            }
            at(1.5) { FileHandle.standardError.write(Data("selftest photos saved: \(count())\n".utf8)) }
            // Countdown: a 2-second timer should produce the second photo about 2 seconds later, and not before.
            at(0.5) { [weak self] in
                self?.look.photoTimer = 2
                self?.takePhoto()
            }
            at(1.2) { FileHandle.standardError.write(Data("selftest photos 1.2 s into a 2 s countdown: \(count()) (expect 1)\n".utf8)) }
            at(1.6) { FileHandle.standardError.write(Data("selftest photos after the countdown: \(count()) (expect 2)\n".utf8)) }
            // Cancelling: start another countdown and cancel it; no third photo should appear.
            at(0.3) { [weak self] in self?.takePhoto() }
            at(0.8) { [weak self] in self?.cancelCountdown() }
            at(2.5) { [weak self] in
                self?.look.photoTimer = 0
                FileHandle.standardError.write(Data("selftest photos after a cancelled countdown: \(count()) (expect 2)\n".utf8))
            }
        }
        at(1.5) {
            FileHandle.standardError.write(Data("selftest finished\n".utf8))
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        camera.stop()
    }

    // MARK: - Keyboard

    private func handleKey(_ event: NSEvent) {
        NSCursor.setHiddenUntilMouseMoves(true)
        let p = look.preset
        switch event.keyCode {
        case 49: // space
            engine.toggleLook()
            showToast(engine.lookOn ? "ENTERING THE MATRIX" : "LEAVING THE MATRIX")
            return
        case 126: // up
            look.update { $0.brightness = min($0.brightness * 1.12, Preset.brightnessRange.upperBound) }
            showToast(String(format: "BRIGHTNESS %.0f%%", look.preset.brightness * 100))
            return
        case 125: // down
            look.update { $0.brightness = max($0.brightness / 1.12, Preset.brightnessRange.lowerBound) }
            showToast(String(format: "BRIGHTNESS %.0f%%", look.preset.brightness * 100))
            return
        case 124: // right
            look.update { $0.rainSpeed = min($0.rainSpeed * 1.2, Preset.rainSpeedRange.upperBound) }
            showToast(String(format: "RAIN SPEED %.0f%%", look.preset.rainSpeed * 100))
            return
        case 123: // left
            look.update { $0.rainSpeed = max($0.rainSpeed / 1.2, Preset.rainSpeedRange.lowerBound) }
            showToast(String(format: "RAIN SPEED %.0f%%", look.preset.rainSpeed * 100))
            return
        default:
            break
        }

        let name = AppDelegate.keyName(for: event)
        switch name {
        case "=", "+":
            look.update { $0.glyphRows = max($0.glyphRows - 6, Preset.glyphRowsRange.lowerBound) }
            showToast(String(format: "GLYPH SIZE %.0f%%", 72 / look.preset.glyphRows * 100))
        case "-", "_":
            look.update { $0.glyphRows = min($0.glyphRows + 6, Preset.glyphRowsRange.upperBound) }
            showToast(String(format: "GLYPH SIZE %.0f%%", 72 / look.preset.glyphRows * 100))
        case "1", "2", "3", "4", "5", "6", "7", "8":
            if let n = Int(name) {
                look.selectIndex(n - 1)
                showToast(look.preset.name.uppercased())
            }
        case "c":
            look.next()
            showToast(look.preset.name.uppercased())
        case "g":
            if p.background == .space {
                look.update { $0.background = roomBackground }
            } else {
                roomBackground = p.background
                look.update { $0.background = .space }
            }
            showToast(look.preset.background.title.uppercased())
        case "b":
            if p.background != .space {
                roomBackground = p.background
                look.update { $0.background = .space; $0.blackHole = true }
                showToast("BLACK HOLE")
            } else {
                look.update { $0.blackHole.toggle() }
                showToast(look.preset.blackHole ? "BLACK HOLE" : "NO BLACK HOLE")
            }
        case "o":
            guard p.holeActive else {
                showToast("NO BLACK HOLE: PRESS B")
                return
            }
            look.update { $0.holeMotion = $0.holeMotion == .orbit ? .stay : .orbit }
            showToast(look.preset.holeMotion == .orbit ? "BLACK HOLE ORBITS YOUR HEAD" : "BLACK HOLE STAYS PUT")
        case "d":
            guard depth != nil else {
                showToast("3D DEPTH UNAVAILABLE")
                return
            }
            look.update { $0.depth3D.toggle() }
            showToast(look.preset.depth3D ? "3D DEPTH ON" : "3D DEPTH OFF")
        case "m":
            look.update { $0.mirror.toggle() }
            showToast(look.preset.mirror ? "MIRROR ON" : "MIRROR OFF")
        case "f":
            window.toggleFullScreen(nil)
        case "s":
            if counting { cancelCountdown() } else { takePhoto() }
        case "t":
            let choices = LookModel.timerChoices
            let next = choices[((choices.firstIndex(of: look.photoTimer) ?? 0) + 1) % choices.count]
            look.photoTimer = next
            showToast(next == 0 ? "PHOTO TIMER OFF" : "PHOTO TIMER \(next) S")
        default:
            break
        }
    }

    /// Dragging on the picture parks the black hole there.
    private func dragHole(to point: CGPoint) {
        guard !settingsOpen, !shortcutsOpen, look.preset.holeActive else { return }
        look.placeHole(at: point)
    }

    // MARK: - Settings

    @objc private func toggleSettings() {
        setSettingsOpen(!settingsOpen)
    }

    /// Esc opens the menu and stops filming (the camera light goes off); closing resumes.
    private func setSettingsOpen(_ open: Bool) {
        guard open != settingsOpen else { return }
        settingsOpen = open
        if open {
            camera.pause()
            helpHide?.cancel()
            help.alphaValue = 0
            look.refreshPhotoFolder()
            settings.alphaValue = 0
            settings.isHidden = false
            NSAnimationContext.runAnimationGroup { $0.duration = 0.2; settings.animator().alphaValue = 1 }
            settings.focusFirstControl()
        } else {
            camera.resume()
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; settings.animator().alphaValue = 0 },
                                                 completionHandler: { [weak self] in
                                                     MainActor.assumeIsolated {
                                                         guard let self, !self.settingsOpen else { return }
                                                         self.settings.isHidden = true
                                                     }
                                                 })
            window.makeFirstResponder(view)
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    private func tint() {
        let accent = look.accentNSColor
        help.setTint(accent)
        toast.setTint(accent)
    }

    // MARK: - Overlays

    private func showToast(_ text: String, sticky: Bool = false) {
        if cameraProblem && !sticky { return }
        toast.label.stringValue = text
        toastHide?.cancel()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; toast.animator().alphaValue = 1 }
        guard !sticky else { return }
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { $0.duration = 0.6; self?.toast.animator().alphaValue = 0 }
        }
        toastHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    private func scheduleHelpHide(after seconds: Double) {
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { $0.duration = 1.0; self?.help.animator().alphaValue = 0 }
        }
        helpHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    // MARK: - Keys

    /// Physical key positions, so shortcuts work on any keyboard layout (Armenian, Russian, ...).
    private static let keyNames: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 8: "c", 11: "b", 17: "t", 31: "o", 46: "m", 44: "/",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8",
        83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7", 91: "8",
        24: "=", 27: "-", 69: "=", 78: "-",
    ]
    private static let repeatableKeys: Set<UInt16> = [123, 124, 125, 126, 24, 27, 69, 78]

    private static func keyName(for event: NSEvent) -> String {
        keyNames[event.keyCode] ?? event.charactersIgnoringModifiers?.lowercased() ?? ""
    }

    private func setShortcutsOpen(_ open: Bool) {
        guard open != shortcutsOpen else { return }
        shortcutsOpen = open
        if open {
            shortcuts.setTint(look.accentNSColor)
            shortcuts.alphaValue = 0
            shortcuts.isHidden = false
            NSAnimationContext.runAnimationGroup { $0.duration = 0.18; shortcuts.animator().alphaValue = 1 }
            helpHide?.cancel()
            help.alphaValue = 0
        } else {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.18; shortcuts.animator().alphaValue = 0 },
                                                 completionHandler: { [weak self] in
                                                     MainActor.assumeIsolated {
                                                         guard let self, !self.shortcutsOpen else { return }
                                                         self.shortcuts.isHidden = true
                                                     }
                                                 })
            if settingsOpen { settings.focusFirstControl() } else { window.makeFirstResponder(view) }
        }
    }

    // MARK: - Photos

    /// Takes a photo now, or after the countdown if a timer is set.
    private func takePhoto() {
        guard look.photoTimer > 0 else { shoot(); return }
        counting = true
        countdownToken += 1
        let token = countdownToken
        let accent = look.accentNSColor
        countdown.textColor = accent
        countdownHint.textColor = accent.withAlphaComponent(0.8)
        countdownHint.alphaValue = 1
        NSCursor.setHiddenUntilMouseMoves(true)

        func tick(_ remaining: Int) {
            guard token == countdownToken else { return }
            if remaining == 0 {
                finishCountdown()
                shoot()
                return
            }
            countdown.stringValue = "\(remaining)"
            countdown.alphaValue = 1
            NSAnimationContext.runAnimationGroup { $0.duration = 0.85; countdown.animator().alphaValue = 0.15 }
            NSSound(named: "Tink")?.play()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { tick(remaining - 1) }
        }
        tick(look.photoTimer)
    }

    private func finishCountdown() {
        counting = false
        countdown.alphaValue = 0
        countdownHint.alphaValue = 0
    }

    private func cancelCountdown() {
        countdownToken += 1
        finishCountdown()
        showToast("PHOTO CANCELLED")
    }

    /// Captures what's on screen right now. The first time, asks where to keep photos.
    private func shoot() {
        NSSound(contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Shutter.aif",
                byReference: true)?.play()
        if engine.latest() == nil { engine.renderFrame()?.waitUntilCompleted() }   // nothing drawn yet (hidden window)
        guard let picture = engine.latest(), let image = Engine.image(from: picture) else { return }
        flash.alphaValue = 0.85
        NSAnimationContext.runAnimationGroup { $0.duration = 0.4; flash.animator().alphaValue = 0 }
        let name = look.preset.name
        if let folder = photos.folder {
            store(image, in: folder, look: name)
        } else {
            // The photo is already captured; ask where it should go, then save it.
            askForPhotoFolder { [weak self] folder in
                if let folder { self?.store(image, in: folder, look: name) }
                else { self?.showToast("PHOTO NOT SAVED") }
            }
        }
    }

    private func store(_ image: CGImage, in folder: URL, look name: String) {
        do {
            _ = try photos.write(image, in: folder, look: name)
            showToast("PHOTO SAVED › \(folder.lastPathComponent.uppercased())")
        } catch {
            // The folder may have gone away or be read-only: ask again.
            showToast("COULDN'T SAVE THERE: PICK ANOTHER FOLDER")
            askForPhotoFolder { [weak self] new in
                guard let self, let new else { return }
                self.store(image, in: new, look: name)
            }
        }
    }

    private func askForPhotoFolder(_ completion: @escaping (URL?) -> Void) {
        guard !askingFolder else { return }
        askingFolder = true
        NSCursor.unhide()
        photos.chooseFolder(over: window) { [weak self] url in
            guard let self else { return }
            self.askingFolder = false
            self.look.refreshPhotoFolder()
            if !self.settingsOpen { self.window.makeFirstResponder(self.view) }
            completion(url)
        }
    }

    // MARK: - Setup helpers

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Matrix Eyes", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(toggleSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Matrix Eyes", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Matrix Eyes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // Editing keys for the text field that names a saved look.
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        let fs = viewMenu.addItem(withTitle: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = viewMenu

        NSApp.mainMenu = main
    }

    private func fail(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Matrix Eyes can't start"
        alert.informativeText = message
        alert.runModal()
        NSApp.terminate(nil)
    }
}
