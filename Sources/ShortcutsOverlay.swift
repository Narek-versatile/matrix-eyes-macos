import AppKit

/// The full list of keyboard shortcuts, as a page. Opened with H (or ?) and from the settings menu.
enum Shortcuts {
    struct Item {
        let keys: [String]
        let text: String
    }
    struct Section {
        let title: String
        let items: [Item]
        var note: String? = nil
    }

    static let left: [Section] = [
        Section(title: "LOOKS", items: [
            Item(keys: ["1", "…", "8"], text: "Pick a look"),
            Item(keys: ["C"], text: "Next look"),
            Item(keys: ["Space"], text: "Leave / enter the look"),
        ], note: "1 Matrix  2 Amber  3 Silver Surfer  4 Quartz\n5 Copper  6 Bronze  7 Doodle  8 3D Print"),
        Section(title: "SCENE", items: [
            Item(keys: ["G"], text: "Space background on / off"),
            Item(keys: ["B"], text: "Black hole on / off"),
            Item(keys: ["D"], text: "3D depth on / off"),
            Item(keys: ["M"], text: "Mirror on / off"),
        ]),
        Section(title: "ADJUST", items: [
            Item(keys: ["↑", "↓"], text: "Brighter / darker"),
            Item(keys: ["←", "→"], text: "Rain slower / faster"),
            Item(keys: ["+", "−"], text: "Glyphs bigger / smaller"),
        ], note: "Rain speed and glyph size apply to the Matrix looks."),
    ]

    static let right: [Section] = [
        Section(title: "PHOTOS", items: [
            Item(keys: ["S"], text: "Take a photo (again to cancel)"),
            Item(keys: ["T"], text: "Timer: off / 3 / 5 / 10 seconds"),
        ], note: "The first photo asks where to save. Change it in settings."),
        Section(title: "APP", items: [
            Item(keys: ["Esc"], text: "Settings (the camera pauses)"),
            Item(keys: ["⌘", ","], text: "Settings"),
            Item(keys: ["H"], text: "This page"),
            Item(keys: ["F"], text: "Full screen on / off"),
            Item(keys: ["⌘", "Q"], text: "Quit"),
        ]),
    ]
}

final class ShortcutsOverlay: NSView {
    var onClose: (() -> Void)?

    private let card = NSView()
    private var accentViews: [(NSView, CGFloat)] = []       // views whose border follows the accent
    private var accentLabels: [(NSTextField, CGFloat)] = []  // labels whose text follows the accent
    private let titleLabel = NSTextField(labelWithString: "KEYBOARD SHORTCUTS")
    private let hintLabel = NSTextField(labelWithString: "H, Esc or a click closes this page")

    init() {
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.62).cgColor
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { onClose?() }

    func setTint(_ accent: NSColor) {
        card.layer?.borderColor = accent.withAlphaComponent(0.35).cgColor
        titleLabel.textColor = accent
        hintLabel.textColor = accent.withAlphaComponent(0.6)
        for (view, alpha) in accentViews { view.layer?.borderColor = accent.withAlphaComponent(alpha).cgColor }
        for (label, alpha) in accentLabels { label.textColor = accent.withAlphaComponent(alpha) }
    }

    // MARK: - Layout

    private func build() {
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(white: 0.02, alpha: 0.92).cgColor
        card.layer?.cornerRadius = 16
        card.layer?.borderWidth = 1
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        titleLabel.font = .monospacedSystemFont(ofSize: 20, weight: .bold)
        hintLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        hintLabel.alignment = .right
        let header = NSStackView(views: [titleLabel, NSView(), hintLabel])
        header.orientation = .horizontal

        let columns = NSStackView(views: [column(Shortcuts.left), column(Shortcuts.right)])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = 44
        columns.distribution = .fillEqually

        let content = NSStackView(views: [header, columns])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 26
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 34),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -34),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 28),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -32),
            header.widthAnchor.constraint(equalTo: content.widthAnchor),
            columns.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
    }

    private func column(_ sections: [Shortcuts.Section]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 24
        for section in sections { stack.addArrangedSubview(block(section)) }
        stack.widthAnchor.constraint(equalToConstant: 330).isActive = true
        return stack
    }

    private func block(_ section: Shortcuts.Section) -> NSView {
        let heading = NSTextField(labelWithString: section.title)
        heading.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        accentLabels.append((heading, 0.85))

        let stack = NSStackView(views: [heading])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.setCustomSpacing(12, after: heading)

        for item in section.items {
            let caps = NSStackView(views: item.keys.map(keycap))
            caps.orientation = .horizontal
            caps.spacing = 4
            caps.widthAnchor.constraint(equalToConstant: 92).isActive = true
            caps.alignment = .centerY
            let text = NSTextField(labelWithString: item.text)
            text.font = .systemFont(ofSize: 13)
            text.textColor = NSColor(white: 0.9, alpha: 1)
            let row = NSStackView(views: [caps, text])
            row.orientation = .horizontal
            row.spacing = 10
            row.alignment = .centerY
            stack.addArrangedSubview(row)
        }
        if let note = section.note {
            let label = NSTextField(wrappingLabelWithString: note)
            label.font = .systemFont(ofSize: 11)
            label.textColor = NSColor(white: 0.55, alpha: 1)
            label.preferredMaxLayoutWidth = 320
            stack.addArrangedSubview(label)
            stack.setCustomSpacing(10, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
        }
        return stack
    }

    /// A small rounded key-cap.
    private func keycap(_ text: String) -> NSView {
        let cap = NSView()
        cap.wantsLayer = true
        cap.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        cap.layer?.cornerRadius = 6
        cap.layer?.borderWidth = 1
        accentViews.append((cap, 0.4))
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        accentLabels.append((label, 1.0))
        label.translatesAutoresizingMaskIntoConstraints = false
        cap.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cap.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: cap.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: cap.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: cap.bottomAnchor, constant: -3),
            cap.widthAnchor.constraint(greaterThanOrEqualToConstant: 26),
        ])
        return cap
    }
}
