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
    SPACE   leave / enter the Matrix
    C       green / amber
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
            camera.onPixelBuffer = { estimator.submit($0) }
            renderer.depthFrame = { estimator.latestTexture() }
        }
        camera.onProblem = { [weak self] message in
            self?.cameraProblem = true
            self?.showToast(message, sticky: true)
        }
        camera.start(device: device)

        let prefs = Preferences.load()
        prefs.apply(to: renderer)
        if depth == nil { renderer.depthEnabled = false }
        tint(prefs.theme)

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { self.window.toggleFullScreen(nil) }
        scheduleHelpHide(after: 7)
        NSCursor.setHiddenUntilMouseMoves(true)
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
        case "c":
            renderer.theme = renderer.theme.next
            tint(renderer.theme)
            showToast(renderer.theme.title.uppercased())
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
        tint(prefs.theme)
        prefs.save()
    }

    private func tint(_ theme: ColorTheme) {
        help.setTint(theme.uiColor)
        toast.setTint(theme.uiColor)
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
