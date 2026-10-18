import AppKit

/// Full-window overlay holding the settings card. Opened with Esc; the app pauses the
/// camera while it's up, and the code keeps raining over the last frame behind it.
final class SettingsOverlay: NSView {
    var onChange: ((Preferences) -> Void)?
    var onResume: (() -> Void)?
    var onQuit: (() -> Void)?

    private var prefs = Preferences()
    private let card = NSView()
    private let titleLabel = NSTextField(labelWithString: "MATRIX EYES")
    private let statusLabel = NSTextField(labelWithString: "●  CAMERA PAUSED")
    private let themeControl = NSSegmentedControl(labels: ColorTheme.allCases.map(\.title),
                                                  trackingMode: .selectOne, target: nil, action: nil)
    private let sizeSlider = NSSlider()
    private let brightnessSlider = NSSlider()
    private let speedSlider = NSSlider()
    private let glowSlider = NSSlider()
    // On/Off segments rather than NSSwitch, which can't take the theme color.
    private let depthControl = NSSegmentedControl(labels: ["On", "Off"], trackingMode: .selectOne, target: nil, action: nil)
    private let mirrorControl = NSSegmentedControl(labels: ["On", "Off"], trackingMode: .selectOne, target: nil, action: nil)
    private let depthNote = NSTextField(labelWithString: "")
    private let resumeButton = NSButton(title: "Resume   esc", target: nil, action: nil)
    private let quitButton = NSButton(title: "Quit", target: nil, action: nil)
    private var valueLabels: [NSSlider: NSTextField] = [:]
    private var captions: [NSTextField] = []

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
        themeControl.selectedSegment = ColorTheme.allCases.firstIndex(of: p.theme) ?? 0
        // Slider runs small -> big glyphs, i.e. many -> few rows.
        sizeSlider.floatValue = Preferences.rowsRange.upperBound + Preferences.rowsRange.lowerBound - p.rows
        brightnessSlider.floatValue = p.exposure
        speedSlider.floatValue = p.speed
        glowSlider.floatValue = p.glow
        depthControl.selectedSegment = p.depth3D && depthAvailable ? 0 : 1
        depthControl.isEnabled = depthAvailable
        depthNote.stringValue = depthAvailable ? "" : "depth model not installed"
        mirrorControl.selectedSegment = p.mirror ? 0 : 1
        refreshValues()
        applyTint()
    }

    func focusFirstControl() {
        window?.makeFirstResponder(themeControl)
    }

    // Clicking the dimmed area outside the card closes the menu.
    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { onResume?() }
    }

    // MARK: - Layout

    private func buildCard() {
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(white: 0.02, alpha: 0.88).cgColor
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

        for control in [themeControl, depthControl, mirrorControl] as [NSControl] {
            control.target = self
            control.action = #selector(controlChanged(_:))
        }
        depthNote.font = .systemFont(ofSize: 11)
        depthNote.textColor = .secondaryLabelColor

        func caption(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
            captions.append(label)
            return label
        }
        let grid = NSGridView(views: [
            [caption("COLOR"), themeControl, NSGridCell.emptyContentView],
            [caption("GLYPH SIZE"), sizeSlider, valueLabels[sizeSlider]!],
            [caption("BRIGHTNESS"), brightnessSlider, valueLabels[brightnessSlider]!],
            [caption("RAIN SPEED"), speedSlider, valueLabels[speedSlider]!],
            [caption("GLOW"), glowSlider, valueLabels[glowSlider]!],
            [caption("3D DEPTH"), NSStackView(views: [depthControl, depthNote]), NSGridCell.emptyContentView],
            [caption("MIRROR"), mirrorControl, NSGridCell.emptyContentView],
        ])
        grid.rowSpacing = 16
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
        let footer = NSStackView(views: [quitButton, NSView(), resumeButton])
        footer.orientation = .horizontal

        let content = NSStackView(views: [header, grid, footer])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 26
        content.setCustomSpacing(30, after: grid)
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
        prefs.theme = ColorTheme.allCases[max(themeControl.selectedSegment, 0)]
        prefs.rows = Preferences.rowsRange.upperBound + Preferences.rowsRange.lowerBound - sizeSlider.floatValue
        prefs.exposure = brightnessSlider.floatValue
        prefs.speed = speedSlider.floatValue
        prefs.glow = glowSlider.floatValue
        if depthControl.isEnabled { prefs.depth3D = depthControl.selectedSegment == 0 }
        prefs.mirror = mirrorControl.selectedSegment == 0
        refreshValues()
        if sender === themeControl { applyTint() }
        onChange?(prefs)
    }

    @objc private func resumeTapped() { onResume?() }
    @objc private func quitTapped() { onQuit?() }

    private func refreshValues() {
        valueLabels[sizeSlider]?.stringValue = String(format: "%.0f%%", 72 / prefs.rows * 100)
        valueLabels[brightnessSlider]?.stringValue = String(format: "%.0f%%", prefs.exposure * 100)
        valueLabels[speedSlider]?.stringValue = String(format: "%.0f%%", prefs.speed * 100)
        valueLabels[glowSlider]?.stringValue = String(format: "%.0f%%", prefs.glow * 100)
    }

    /// Recolors text and controls in the current theme's accent.
    private func applyTint() {
        let accent = prefs.theme.uiColor
        card.layer?.borderColor = accent.withAlphaComponent(0.35).cgColor
        titleLabel.textColor = accent
        statusLabel.textColor = accent.withAlphaComponent(0.7)
        for label in captions { label.textColor = accent.withAlphaComponent(0.85) }
        for label in valueLabels.values { label.textColor = accent.withAlphaComponent(0.85) }
        for slider in [sizeSlider, brightnessSlider, speedSlider, glowSlider] { slider.trackFillColor = accent }
        for control in [themeControl, depthControl, mirrorControl] {
            control.selectedSegmentBezelColor = accent.withAlphaComponent(0.55)
        }
        resumeButton.bezelColor = accent.withAlphaComponent(0.6)
    }
}
