import AppKit

/// Full-window overlay holding the settings card. Opened with Esc; the app pauses the
/// camera while it's up, and the picture keeps running behind it.
final class SettingsOverlay: NSView {
    var onChange: ((Preferences) -> Void)?
    var onResume: (() -> Void)?
    var onQuit: (() -> Void)?
    var onChoosePhotoFolder: (() -> Void)?
    var onShowShortcuts: (() -> Void)?

    private var prefs = Preferences()
    private let card = NSView()
    private let titleLabel = NSTextField(labelWithString: "MATRIX EYES")
    private let statusLabel = NSTextField(labelWithString: "●  CAMERA PAUSED")
    private let styleControl = NSPopUpButton(frame: .zero, pullsDown: false)
    private let backgroundControl = NSSegmentedControl(labels: ["Room", "Space"], trackingMode: .selectOne, target: nil, action: nil)
    private let holeControl = NSSegmentedControl(labels: ["On", "Off"], trackingMode: .selectOne, target: nil, action: nil)
    private let sizeSlider = NSSlider()
    private let brightnessSlider = NSSlider()
    private let speedSlider = NSSlider()
    private let glowSlider = NSSlider()
    // On/Off segments rather than NSSwitch, which can't take the theme color.
    private let depthControl = NSSegmentedControl(labels: ["On", "Off"], trackingMode: .selectOne, target: nil, action: nil)
    private let mirrorControl = NSSegmentedControl(labels: ["On", "Off"], trackingMode: .selectOne, target: nil, action: nil)
    private let timerControl = NSSegmentedControl(labels: Preferences.timerChoices.map { $0 == 0 ? "Off" : "\($0) s" },
                                                  trackingMode: .selectOne, target: nil, action: nil)
    private let depthNote = NSTextField(labelWithString: "")
    private let photoPath = NSTextField(labelWithString: "")
    private let photoButton = NSButton(title: "Change…", target: nil, action: nil)
    private let resumeButton = NSButton(title: "Resume   esc", target: nil, action: nil)
    private let quitButton = NSButton(title: "Quit", target: nil, action: nil)
    private let shortcutsButton = NSButton(title: "Shortcuts   H", target: nil, action: nil)
    private var valueLabels: [NSSlider: NSTextField] = [:]
    private var captions: [NSTextField] = []
    private var captionFor: [NSControl: NSTextField] = [:]

    init() {
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.5).cgColor
        buildCard()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Loads current values into the controls.
    func show(_ p: Preferences, depthAvailable: Bool) {
        prefs = p
        styleControl.selectItem(at: Style.allCases.firstIndex(of: p.style) ?? 0)
        backgroundControl.selectedSegment = p.space ? 1 : 0
        holeControl.selectedSegment = p.blackHole ? 0 : 1
        // Slider runs small -> big glyphs, i.e. many -> few rows.
        sizeSlider.floatValue = Preferences.rowsRange.upperBound + Preferences.rowsRange.lowerBound - p.rows
        brightnessSlider.floatValue = p.exposure
        speedSlider.floatValue = p.speed
        glowSlider.floatValue = p.glow
        depthControl.selectedSegment = p.depth3D && depthAvailable ? 0 : 1
        depthControl.isEnabled = depthAvailable
        depthNote.stringValue = depthAvailable ? "" : "depth model not installed"
        mirrorControl.selectedSegment = p.mirror ? 0 : 1
        timerControl.selectedSegment = Preferences.timerChoices.firstIndex(of: p.photoTimer) ?? 0
        refreshValues()
        applyTint()
        applyEnabledState()
    }

    func setPhotoFolder(_ text: String) {
        photoPath.stringValue = text
    }

    func focusFirstControl() {
        window?.makeFirstResponder(styleControl)
    }

    // Clicking the dimmed area outside the card closes the menu.
    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { onResume?() }
    }

    // MARK: - Layout

    private func buildCard() {
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(white: 0.02, alpha: 0.9).cgColor
        card.layer?.cornerRadius = 16
        card.layer?.borderWidth = 1
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        titleLabel.font = .monospacedSystemFont(ofSize: 20, weight: .bold)
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        statusLabel.alignment = .right
        let header = NSStackView(views: [titleLabel, NSView(), statusLabel])
        header.orientation = .horizontal

        for slider in [sizeSlider, brightnessSlider, speedSlider, glowSlider] {
            slider.isContinuous = true
            slider.target = self
            slider.action = #selector(controlChanged(_:))
            slider.widthAnchor.constraint(equalToConstant: 260).isActive = true
            let value = NSTextField(labelWithString: "")
            value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            value.alignment = .right
            value.widthAnchor.constraint(equalToConstant: 48).isActive = true
            valueLabels[slider] = value
        }
        sizeSlider.minValue = Double(Preferences.rowsRange.lowerBound)
        sizeSlider.maxValue = Double(Preferences.rowsRange.upperBound)
        brightnessSlider.minValue = Double(Preferences.exposureRange.lowerBound)
        brightnessSlider.maxValue = Double(Preferences.exposureRange.upperBound)
        speedSlider.minValue = Double(Preferences.speedRange.lowerBound)
        speedSlider.maxValue = Double(Preferences.speedRange.upperBound)
        glowSlider.minValue = Double(Preferences.glowRange.lowerBound)
        glowSlider.maxValue = Double(Preferences.glowRange.upperBound)

        styleControl.addItems(withTitles: Style.allCases.map(\.title))
        styleControl.font = .systemFont(ofSize: 13)
        styleControl.widthAnchor.constraint(equalToConstant: 200).isActive = true

        for control in [styleControl, backgroundControl, holeControl, depthControl, mirrorControl, timerControl] as [NSControl] {
            control.target = self
            control.action = #selector(controlChanged(_:))
        }
        depthNote.font = .systemFont(ofSize: 11)
        depthNote.textColor = .secondaryLabelColor
        photoPath.font = .systemFont(ofSize: 12)
        photoPath.textColor = .secondaryLabelColor
        photoPath.lineBreakMode = .byTruncatingMiddle
        photoPath.widthAnchor.constraint(equalToConstant: 200).isActive = true
        photoButton.bezelStyle = .rounded
        photoButton.controlSize = .small
        photoButton.target = self
        photoButton.action = #selector(choosePhotoFolder)

        func caption(_ text: String, for control: NSControl) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
            captions.append(label)
            captionFor[control] = label
            return label
        }
        let empty = { NSGridCell.emptyContentView }
        let grid = NSGridView(views: [
            [caption("STYLE", for: styleControl), styleControl, empty()],
            [caption("BACKGROUND", for: backgroundControl), backgroundControl, empty()],
            [caption("BLACK HOLE", for: holeControl), holeControl, empty()],
            [caption("GLYPH SIZE", for: sizeSlider), sizeSlider, valueLabels[sizeSlider]!],
            [caption("BRIGHTNESS", for: brightnessSlider), brightnessSlider, valueLabels[brightnessSlider]!],
            [caption("RAIN SPEED", for: speedSlider), speedSlider, valueLabels[speedSlider]!],
            [caption("GLOW", for: glowSlider), glowSlider, valueLabels[glowSlider]!],
            [caption("3D DEPTH", for: depthControl), NSStackView(views: [depthControl, depthNote]), empty()],
            [caption("MIRROR", for: mirrorControl), mirrorControl, empty()],
            [caption("PHOTOS", for: photoButton), NSStackView(views: [photoButton, photoPath]), empty()],
            [caption("TIMER", for: timerControl), timerControl, empty()],
        ])
        grid.rowSpacing = 15
        grid.columnSpacing = 18
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 2).xPlacement = .trailing
        for row in 0..<grid.numberOfRows { grid.row(at: row).yPlacement = .center }

        resumeButton.bezelStyle = .rounded
        resumeButton.keyEquivalent = "\r"
        resumeButton.target = self
        resumeButton.action = #selector(resumeTapped)
        quitButton.bezelStyle = .rounded
        quitButton.target = self
        quitButton.action = #selector(quitTapped)
        shortcutsButton.bezelStyle = .rounded
        shortcutsButton.target = self
        shortcutsButton.action = #selector(showShortcuts)
        let footer = NSStackView(views: [quitButton, shortcutsButton, NSView(), resumeButton])
        footer.orientation = .horizontal

        let content = NSStackView(views: [header, grid, footer])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 24
        content.setCustomSpacing(28, after: grid)
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 32),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -32),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 28),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -26),
            header.widthAnchor.constraint(equalTo: content.widthAnchor),
            footer.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
    }

    // MARK: - Actions

    @objc private func controlChanged(_ sender: NSControl) {
        let previousStyle = prefs.style
        prefs.style = Style.allCases[max(styleControl.indexOfSelectedItem, 0)]
        prefs.space = backgroundControl.selectedSegment == 1
        prefs.blackHole = holeControl.selectedSegment == 0
        prefs.rows = Preferences.rowsRange.upperBound + Preferences.rowsRange.lowerBound - sizeSlider.floatValue
        prefs.exposure = brightnessSlider.floatValue
        prefs.speed = speedSlider.floatValue
        prefs.glow = glowSlider.floatValue
        if depthControl.isEnabled { prefs.depth3D = depthControl.selectedSegment == 0 }
        prefs.mirror = mirrorControl.selectedSegment == 0
        prefs.photoTimer = Preferences.timerChoices[max(timerControl.selectedSegment, 0)]
        // Silver Surfer belongs in space: switching to it brings the background along.
        if sender === styleControl, prefs.style == .chrome, previousStyle != .chrome {
            prefs.space = true
            backgroundControl.selectedSegment = 1
        }
        refreshValues()
        applyTint()
        applyEnabledState()
        onChange?(prefs)
    }

    @objc private func choosePhotoFolder() { onChoosePhotoFolder?() }
    @objc private func showShortcuts() { onShowShortcuts?() }
    @objc private func resumeTapped() { onResume?() }
    @objc private func quitTapped() { onQuit?() }

    private func refreshValues() {
        valueLabels[sizeSlider]?.stringValue = String(format: "%.0f%%", 72 / prefs.rows * 100)
        valueLabels[brightnessSlider]?.stringValue = String(format: "%.0f%%", prefs.exposure * 100)
        valueLabels[speedSlider]?.stringValue = String(format: "%.0f%%", prefs.speed * 100)
        valueLabels[glowSlider]?.stringValue = String(format: "%.0f%%", prefs.glow * 100)
    }

    /// Greys out settings that don't apply to the current look.
    private func applyEnabledState() {
        let matrix = prefs.style.isMatrix
        for control in [sizeSlider, speedSlider] as [NSControl] {
            control.isEnabled = matrix
            captionFor[control]?.alphaValue = matrix ? 1 : 0.3
        }
        valueLabels[sizeSlider]?.alphaValue = matrix ? 1 : 0.3
        valueLabels[speedSlider]?.alphaValue = matrix ? 1 : 0.3
        holeControl.isEnabled = prefs.space
        captionFor[holeControl]?.alphaValue = prefs.space ? 1 : 0.3
    }

    /// Recolors text and controls in the current style's accent.
    private func applyTint() {
        let accent = prefs.style.uiColor
        card.layer?.borderColor = accent.withAlphaComponent(0.35).cgColor
        titleLabel.textColor = accent
        statusLabel.textColor = accent.withAlphaComponent(0.7)
        for label in captions { label.textColor = accent.withAlphaComponent(0.85) }
        for label in valueLabels.values { label.textColor = accent.withAlphaComponent(0.85) }
        for slider in [sizeSlider, brightnessSlider, speedSlider, glowSlider] { slider.trackFillColor = accent }
        for control in [backgroundControl, holeControl, depthControl, mirrorControl, timerControl] {
            control.selectedSegmentBezelColor = accent.withAlphaComponent(0.55)
        }
        resumeButton.bezelColor = accent.withAlphaComponent(0.6)
    }
}
