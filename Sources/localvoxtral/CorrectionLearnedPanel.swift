import AppKit

/// "Learned “Qwen”  Undo", for a few seconds at the top of the screen the user
/// is on, after `CorrectionLearning` remembers a fix.
///
/// It must not take focus: it appears while the user is typing in their
/// terminal, often mid-prompt. The panel is non-activating and never key, and
/// the Undo button takes the first click, so pressing it neither activates
/// localvoxtral nor moves the insertion point out of the terminal.
@MainActor
final class CorrectionLearnedPanel: CorrectionLearningPresenting {
    /// Long enough to read a short line and reach for Undo; the term also
    /// stays forgettable from Settings → Learned terms.
    static let visibleSeconds: TimeInterval = 6

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var undo: (@MainActor () -> Void)?
    private let sleepFor: @Sendable (TimeInterval) async throws -> Void

    init(
        sleepFor: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.sleepFor = sleepFor
    }

    static func message(for term: String) -> String {
        "Learned “\(term)”"
    }

    func showLearned(term: String, undo: @escaping @MainActor () -> Void) {
        self.undo = undo
        let panel = makePanel(message: Self.message(for: term))
        self.panel?.orderOut(nil)
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()

        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self, sleepFor] in
            try? await sleepFor(Self.visibleSeconds)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
        panel = nil
        undo = nil
    }

    @objc private func undoPressed() {
        let undo = self.undo
        hide()
        undo?()
    }

    private func makePanel(message: String) -> NSPanel {
        let panel = FocuslessPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        label.setAccessibilityIdentifier("correction-learned-message")

        let button = FirstClickButton(title: "Undo", target: self, action: #selector(undoPressed))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.setAccessibilityIdentifier("correction-learned-undo")

        let row = NSStackView(views: [label, button])
        row.orientation = .horizontal
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            row.topAnchor.constraint(equalTo: background.topAnchor),
            row.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])
        panel.contentView = background
        panel.setContentSize(background.fittingSize)
        return panel
    }

    /// Top center of the screen under the pointer, just below the menu bar,
    /// where the menu bar icon already reports what the app is doing.
    private func position(_ panel: NSPanel) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - 8
        ))
    }
}

private final class FocuslessPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A click on an inactive app's window normally only activates it; this
/// button acts on that first click instead, which is what lets Undo work
/// without taking focus from the terminal.
private final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
