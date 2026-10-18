import AppKit
import SwiftUI

/// Full-window overlay holding the settings card. Opened with Esc; the app pauses the camera while
/// it's up, and the picture keeps running behind it. The card is the control panel shared with
/// Matrix Eyes Cam, so both apps have the same controls.
final class SettingsOverlay: NSView {
    var onResume: (() -> Void)?
    var onQuit: (() -> Void)?
    var onShowShortcuts: (() -> Void)?

    private let host: NSHostingView<SettingsCard>
    private var heightConstraint: NSLayoutConstraint!

    init(look: LookModel) {
        host = NSHostingView(rootView: SettingsCard(look: look, actions: SettingsCard.Actions()))
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.5).cgColor

        host.rootView = SettingsCard(look: look, actions: SettingsCard.Actions(
            resume: { [weak self] in self?.onResume?() },
            quit: { [weak self] in self?.onQuit?() },
            shortcuts: { [weak self] in self?.onShowShortcuts?() }))
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        heightConstraint = host.heightAnchor.constraint(equalToConstant: 760)
        NSLayoutConstraint.activate([
            host.centerXAnchor.constraint(equalTo: centerXAnchor),
            host.centerYAnchor.constraint(equalTo: centerYAnchor),
            host.widthAnchor.constraint(equalToConstant: SettingsCard.width),
            heightConstraint,
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        // The card is as tall as the window allows (it scrolls inside).
        heightConstraint.constant = min(max(bounds.height - 80, 320), 900)
        super.layout()
    }

    func focusFirstControl() {
        window?.makeFirstResponder(host)
    }

    // Clicking the dimmed area outside the card closes the menu.
    override func mouseDown(with event: NSEvent) {
        if !host.frame.contains(convert(event.locationInWindow, from: nil)) { onResume?() }
    }
}

struct SettingsCard: View {
    struct Actions {
        var resume: () -> Void = {}
        var quit: () -> Void = {}
        var shortcuts: () -> Void = {}
    }

    static let width: CGFloat = 520

    @ObservedObject var look: LookModel
    var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("MATRIX EYES")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(look.accent)
                Spacer()
                Text("●  CAMERA PAUSED")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(look.accent.opacity(0.7))
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 6)

            LookPanel(model: look, mirrorLabel: "Mirror") {
                EmptyView()
            }
            .scrollContentBackground(.hidden)

            HStack(spacing: 10) {
                Button("Shortcuts   H", action: actions.shortcuts)
                Spacer()
                Button("Quit", action: actions.quit)
                Button("Resume   esc", action: actions.resume)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
        }
        .frame(width: Self.width)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.02).opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(look.accent.opacity(0.35), lineWidth: 1))
        .tint(look.accent)
        .preferredColorScheme(.dark)
    }
}
