import AppKit
import ImageIO
import MetalKit
import UniformTypeIdentifiers

final class MatrixView: MTKView {
    override var acceptsFirstResponder: Bool { true }
}

/// Small rounded translucent panel holding one label.
final class Pill: NSView {
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var view: MatrixView!
    private var renderer: Renderer!
    private let camera = Camera()
    private var depth: DepthEstimator?
    private var masker: PersonMasker?
    private let help = Pill(fontSize: 13)
    private let toast = Pill(fontSize: 14)
    private var toastHide: DispatchWorkItem?
    private var helpHide: DispatchWorkItem?
    private var cameraProblem = false
    private let settings = SettingsOverlay()
    private var settingsOpen = false
    private var keyMonitor: Any?

    private static let helpText = """
    MATRIX EYES

    ESC     settings (pauses the camera)
    1-8     pick a look (or C to cycle)
            1 Matrix  2 Amber  3 Silver Surfer
            4 Quartz  5 Copper  6 Bronze
            7 Doodle  8 3D Print
    G       space background on / off
    B       black hole on / off
    SPACE   leave / enter the look
    + / -   bigger / smaller glyphs
    ↑ / ↓   brighter / darker
    ← / →   slower / faster rain
    D       3D depth on / off
    M       mirror on / off
    S       save a snapshot
    F       full screen
    H       show / hide this help
    ⌘Q      quit
    """

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        guard let device = MTLCreateSystemDefaultDevice() else {
            fail("This Mac has no Metal GPU.")
            return
        }
        do {
            renderer = try Renderer(device: device)
        } catch {
            fail("Couldn't start the renderer:\n\(error)")
            return
        }

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
        view.delegate = renderer
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

        settings.translatesAutoresizingMaskIntoConstraints = false
        settings.isHidden = true
        view.addSubview(settings)
        NSLayoutConstraint.activate([
            settings.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            settings.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            settings.topAnchor.constraint(equalTo: view.topAnchor),
            settings.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        settings.onChange = { [weak self] prefs in self?.apply(prefs) }
        settings.onResume = { [weak self] in self?.setSettingsOpen(false) }
        settings.onQuit = { NSApp.terminate(nil) }

        // All keys go through here so Esc works whether the code view or a settings control has focus.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !event.modifierFlags.contains(.command) else { return event }
            if event.keyCode == 53 {
                self.setSettingsOpen(!self.settingsOpen)
                return nil
            }
            if self.settingsOpen { return event }
            self.handleKey(event)
            Preferences(from: self.renderer).save()
            return nil
        }

        renderer.cameraFrame = { [camera] in camera.latest() }
        // Depth runs on the Neural Engine; if the model is missing the app still works, just flat.
        if let estimator = try? DepthEstimator(device: device) {
            depth = estimator
            renderer.depthFrame = { estimator.latestTexture() }
        }
        // The person cut-out only runs while a space background is on.
        let personMasker = PersonMasker(device: device)
        masker = personMasker
        renderer.maskFrame = { personMasker.latestTexture() }
        camera.onPixelBuffer = { [weak self] buffer in
            self?.depth?.submit(buffer)
            if self?.renderer.spaceEnabled == true { self?.masker?.submit(buffer) }
        }
        camera.onProblem = { [weak self] message in
            self?.cameraProblem = true
            self?.showToast(message, sticky: true)
        }
        camera.start(device: device)

        let prefs = Preferences.load()
        prefs.apply(to: renderer, animated: false)
        if depth == nil { renderer.depthEnabled = false }
        tint(prefs.style)

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { self.window.toggleFullScreen(nil) }
        scheduleHelpHide(after: 7)
        NSCursor.setHiddenUntilMouseMoves(true)
        if ProcessInfo.processInfo.environment["MATRIX_SELFTEST"] != nil { runSelfTest() }
    }

    /// Developer check (MATRIX_SELFTEST=1): drives the real app through every look, space, the black
    /// hole and the settings menu (which pauses and resumes the camera), then quits.
    private func runSelfTest() {
        var t = 3.0   // let the camera come up first
        func at(_ delay: Double, _ work: @escaping () -> Void) {
            t += delay
            DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: work)
        }
        for style in Style.allCases { at(1.0) { [weak self] in self?.choose(style) } }
        at(1.0) { [weak self] in self?.choose(.chrome) }
        at(1.5) { [weak self] in self?.renderer.blackHoleEnabled.toggle() }
        at(1.0) { [weak self] in self?.renderer.blackHoleEnabled.toggle() }
        at(1.0) { [weak self] in self?.setSettingsOpen(true) }
        at(1.5) { [weak self] in self?.setSettingsOpen(false) }
        at(1.5) { [weak self] in self?.renderer.spaceEnabled = false }
        at(1.5) { [weak self] in self?.choose(.quartz) }
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
        switch event.keyCode {
        case 49: // space
            renderer.toggleMatrix()
            showToast(renderer.matrixOn ? "ENTERING THE MATRIX" : "LEAVING THE MATRIX")
            return
        case 126: // up
            renderer.exposure = min(renderer.exposure * 1.12, Preferences.exposureRange.upperBound)
            showToast(String(format: "BRIGHTNESS %.0f%%", renderer.exposure * 100))
            return
        case 125: // down
            renderer.exposure = max(renderer.exposure / 1.12, Preferences.exposureRange.lowerBound)
            showToast(String(format: "BRIGHTNESS %.0f%%", renderer.exposure * 100))
            return
        case 124: // right
            renderer.speed = min(renderer.speed * 1.2, Preferences.speedRange.upperBound)
            showToast(String(format: "RAIN SPEED %.0f%%", renderer.speed * 100))
            return
        case 123: // left
            renderer.speed = max(renderer.speed / 1.2, Preferences.speedRange.lowerBound)
            showToast(String(format: "RAIN SPEED %.0f%%", renderer.speed * 100))
            return
        default:
            break
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "=", "+":
            renderer.rows = max(renderer.rows - 6, Preferences.rowsRange.lowerBound)
            showToast(String(format: "GLYPH SIZE %.0f%%", 72 / renderer.rows * 100))
        case "-", "_":
            renderer.rows = min(renderer.rows + 6, Preferences.rowsRange.upperBound)
            showToast(String(format: "GLYPH SIZE %.0f%%", 72 / renderer.rows * 100))
        case "1", "2", "3", "4", "5", "6", "7", "8":
            if let n = Int(event.charactersIgnoringModifiers ?? ""), n >= 1, n <= Style.allCases.count {
                choose(Style.allCases[n - 1])
            }
        case "c":
            choose(renderer.style.next)
        case "g":
            renderer.spaceEnabled.toggle()
            showToast(renderer.spaceEnabled ? "SPACE" : "ROOM")
        case "b":
            if !renderer.spaceEnabled {
                renderer.spaceEnabled = true
                renderer.blackHoleEnabled = true
                showToast("BLACK HOLE")
            } else {
                renderer.blackHoleEnabled.toggle()
                showToast(renderer.blackHoleEnabled ? "BLACK HOLE" : "NO BLACK HOLE")
            }
        case "d":
            guard depth != nil else {
                showToast("3D DEPTH UNAVAILABLE")
                return
            }
            renderer.depthEnabled.toggle()
            showToast(renderer.depthEnabled ? "3D DEPTH ON" : "3D DEPTH OFF")
        case "m":
            renderer.mirror.toggle()
            showToast(renderer.mirror ? "MIRROR ON" : "MIRROR OFF")
        case "f":
            window.toggleFullScreen(nil)
        case "h":
            helpHide?.cancel()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.25; help.animator().alphaValue = help.alphaValue > 0.5 ? 0 : 1 }
        case "s":
            renderer.requestSnapshot { [weak self] image in self?.save(image) }
        default:
            break
        }
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
            settings.show(Preferences(from: renderer), depthAvailable: depth != nil)
            settings.alphaValue = 0
            settings.isHidden = false
            NSAnimationContext.runAnimationGroup { $0.duration = 0.2; settings.animator().alphaValue = 1 }
            settings.focusFirstControl()
        } else {
            camera.resume()
            Preferences(from: renderer).save()
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; settings.animator().alphaValue = 0 },
                                                 completionHandler: { [weak self] in
                                                     guard let self, !self.settingsOpen else { return }
                                                     self.settings.isHidden = true
                                                 })
            window.makeFirstResponder(view)
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    private func apply(_ prefs: Preferences) {
        prefs.apply(to: renderer)
        if depth == nil { renderer.depthEnabled = false }
        tint(prefs.style)
        prefs.save()
    }

    /// Switches look from the keyboard. Silver Surfer comes with its space background.
    private func choose(_ style: Style) {
        let was = renderer.style
        renderer.setStyle(style)
        if style == .chrome, was != .chrome { renderer.spaceEnabled = true }
        tint(style)
        showToast(style.title.uppercased())
    }

    private func tint(_ style: Style) {
        help.setTint(style.uiColor)
        toast.setTint(style.uiColor)
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

    // MARK: - Snapshot

    private func save(_ image: CGImage) {
        let dir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Matrix Eyes", isDirectory: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = dir.appendingPathComponent("Matrix Eyes \(stamp.string(from: Date())).png")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            CGImageDestinationAddImage(dest, image, nil)
            guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
            showToast("SAVED TO PICTURES › MATRIX EYES")
        } catch {
            showToast("COULDN'T SAVE SNAPSHOT")
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
