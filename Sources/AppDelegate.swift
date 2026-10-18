import AppKit
import ImageIO
import MetalKit
import UniformTypeIdentifiers

final class MatrixView: MTKView {
    override var acceptsFirstResponder: Bool { true }
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
    private let photos = PhotoSaver()
    private var askingFolder = false
    private let flash = PassthroughView()
    private let countdown = PassthroughLabel(labelWithString: "")
    private let countdownHint = PassthroughLabel(labelWithString: "S or Esc to cancel")
    private let shortcuts = ShortcutsOverlay()
    private var shortcutsOpen = false
    private var countdownToken = 0          // bumped to cancel a running countdown
    private var counting = false

    private static let helpText = "H  keyboard shortcuts      Esc  settings"

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
        settings.onShowShortcuts = { [weak self] in self?.setShortcutsOpen(true) }

        shortcuts.translatesAutoresizingMaskIntoConstraints = false
        shortcuts.isHidden = true
        shortcuts.onClose = { [weak self] in self?.setShortcutsOpen(false) }
        view.addSubview(shortcuts)
        NSLayoutConstraint.activate([
            shortcuts.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            shortcuts.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            shortcuts.topAnchor.constraint(equalTo: view.topAnchor),
            shortcuts.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        settings.onChoosePhotoFolder = { [weak self] in
            self?.askForPhotoFolder { _ in self?.settings.setPhotoFolder(self?.photos.displayPath ?? "") }
        }

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
        NSLayoutConstraint.activate([
            flash.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            flash.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            flash.topAnchor.constraint(equalTo: view.topAnchor),
            flash.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // All keys go through here so Esc works whether the code view or a settings control has focus.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !event.modifierFlags.contains(.command) else { return event }
            if self.askingFolder { return event }   // the folder picker is up: let it have the keys
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
        if ProcessInfo.processInfo.environment["MATRIX_KEYTEST"] != nil { runKeyTest() }
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
        func at(_ delay: Double, _ work: @escaping () -> Void) {
            t += delay
            DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: work)
        }
        at(0) { [weak self] in self?.renderer.photoTimer = 0; self?.press("s", keyCode: 1) }
        at(2.0) { log("S, no timer -> \(count()) photos (expect 1)") }
        at(0.1) { [weak self] in self?.press("ы", keyCode: 1) }                       // S key on a Russian layout
        at(2.0) { log("S key typed as another letter (Russian layout) -> \(count()) photos (expect 2)") }
        at(0.1) { [weak self] in self?.renderer.photoTimer = 3; self?.press("s", keyCode: 1) }
        at(1.0) { [weak self] in log("1 s into a 3 s countdown -> \(count()) photos (expect 2), counting=\(self?.counting ?? false)") }
        at(0.1) { [weak self] in self?.press("s", keyCode: 1, repeating: true) }     // key auto-repeat
        at(0.3) { [weak self] in log("after an auto-repeat S -> counting=\(self?.counting ?? false) (expect true)") }
        at(3.5) { log("after the countdown -> \(count()) photos (expect 3)") }
        at(0.1) { [weak self] in
            self?.renderer.photoTimer = 0
            self?.press("s", keyCode: 1); self?.press("s", keyCode: 1, repeating: true); self?.press("s", keyCode: 1, repeating: true)
        }
        at(2.0) { log("S held down (3 events) -> \(count()) photos (expect 4)") }
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
        if let dir = ProcessInfo.processInfo.environment["MATRIX_SELFTEST_PHOTO_DIR"] {
            at(0.5) { [weak self] in
                self?.photos.overrideFolder = URL(fileURLWithPath: dir, isDirectory: true)
                self?.takePhoto()
            }
            at(1.5) {
                let count = (try? FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".png") }.count) ?? 0
                FileHandle.standardError.write(Data("selftest photos saved: \(count)\n".utf8))
            }
            // Countdown: a 2-second timer should produce the second photo about 2 seconds later, and not before.
            at(0.5) { [weak self] in
                self?.renderer.photoTimer = 2
                self?.takePhoto()
            }
            at(1.2) {
                let count = (try? FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".png") }.count) ?? 0
                FileHandle.standardError.write(Data("selftest photos 1.2 s into a 2 s countdown: \(count) (expect 1)\n".utf8))
            }
            at(1.6) {
                let count = (try? FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".png") }.count) ?? 0
                FileHandle.standardError.write(Data("selftest photos after the countdown: \(count) (expect 2)\n".utf8))
            }
            // Cancelling: start another countdown and cancel it; no third photo should appear.
            at(0.3) { [weak self] in self?.takePhoto() }
            at(0.8) { [weak self] in self?.cancelCountdown() }
            at(2.5) { [weak self] in
                self?.renderer.photoTimer = 0
                let count = (try? FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".png") }.count) ?? 0
                FileHandle.standardError.write(Data("selftest photos after a cancelled countdown: \(count) (expect 2)\n".utf8))
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

        switch AppDelegate.keyName(for: event) {
        case "=", "+":
            renderer.rows = max(renderer.rows - 6, Preferences.rowsRange.lowerBound)
            showToast(String(format: "GLYPH SIZE %.0f%%", 72 / renderer.rows * 100))
        case "-", "_":
            renderer.rows = min(renderer.rows + 6, Preferences.rowsRange.upperBound)
            showToast(String(format: "GLYPH SIZE %.0f%%", 72 / renderer.rows * 100))
        case "1", "2", "3", "4", "5", "6", "7", "8":
            if let n = Int(AppDelegate.keyName(for: event)), n >= 1, n <= Style.allCases.count {
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
        case "s":
            if counting { cancelCountdown() } else { takePhoto() }
        case "t":
            let choices = Preferences.timerChoices
            let next = choices[((choices.firstIndex(of: renderer.photoTimer) ?? 0) + 1) % choices.count]
            renderer.photoTimer = next
            showToast(next == 0 ? "PHOTO TIMER OFF" : "PHOTO TIMER \(next) S")
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
            settings.setPhotoFolder(photos.displayPath)
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

    // MARK: - Keys

    /// Physical key positions, so shortcuts work on any keyboard layout (Armenian, Russian, ...).
    private static let keyNames: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 8: "c", 11: "b", 17: "t", 46: "m", 44: "/",
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
            shortcuts.setTint(renderer.style.uiColor)
            shortcuts.alphaValue = 0
            shortcuts.isHidden = false
            NSAnimationContext.runAnimationGroup { $0.duration = 0.18; shortcuts.animator().alphaValue = 1 }
            helpHide?.cancel()
            help.alphaValue = 0
        } else {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.18; shortcuts.animator().alphaValue = 0 },
                                                 completionHandler: { [weak self] in
                                                     guard let self, !self.shortcutsOpen else { return }
                                                     self.shortcuts.isHidden = true
                                                 })
            if settingsOpen { settings.focusFirstControl() } else { window.makeFirstResponder(view) }
        }
    }

    // MARK: - Photos

    /// Takes a photo now, or after the countdown if a timer is set.
    private func takePhoto() {
        guard renderer.photoTimer > 0 else { shoot(); return }
        counting = true
        countdownToken += 1
        let token = countdownToken
        let accent = renderer.style.uiColor
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
        tick(renderer.photoTimer)
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
        flash.alphaValue = 0.85
        NSAnimationContext.runAnimationGroup { $0.duration = 0.4; flash.animator().alphaValue = 0 }
        let look = renderer.style.title
        renderer.requestSnapshot { [weak self] image in
            guard let self else { return }
            if let folder = self.photos.folder {
                self.store(image, in: folder, look: look)
            } else {
                // The photo is already captured; ask where it should go, then save it.
                self.askForPhotoFolder { folder in
                    if let folder { self.store(image, in: folder, look: look) }
                    else { self.showToast("PHOTO NOT SAVED") }
                }
            }
        }
    }

    private func store(_ image: CGImage, in folder: URL, look: String) {
        do {
            _ = try photos.write(image, in: folder, look: look)
            showToast("PHOTO SAVED › \(folder.lastPathComponent.uppercased())")
        } catch {
            // The folder may have gone away or be read-only: ask again.
            showToast("COULDN'T SAVE THERE: PICK ANOTHER FOLDER")
            askForPhotoFolder { [weak self] new in
                guard let self, let new else { return }
                self.store(image, in: new, look: look)
            }
        }
    }

    private func askForPhotoFolder(_ completion: @escaping (URL?) -> Void) {
        guard !askingFolder else { return }
        askingFolder = true
        NSCursor.unhide()
        photos.chooseFolder(over: window) { [weak self] url in
            self?.askingFolder = false
            self?.window.makeFirstResponder(self?.view)
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
