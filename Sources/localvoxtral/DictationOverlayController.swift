import AppKit
import SwiftUI

@MainActor
final class DictationOverlayController {
    private let panel: NSPanel
    private let minimumPanelSize = CGSize(width: 420, height: 120)
    private let maximumPanelSize = CGSize(width: 560, height: 420)

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        let initialView = DictationOverlayView(
            phase: .idle,
            text: "",
            errorMessage: nil
        )
        panel.contentView = NSHostingView(rootView: initialView)
        panel.orderOut(nil)
    }

    func render(snapshot: OverlayBufferStateMachine.Snapshot?) {
        guard let snapshot else {
            hide()
            return
        }

        if let hostingView = panel.contentView as? NSHostingView<DictationOverlayView> {
            hostingView.rootView = DictationOverlayView(
                phase: snapshot.phase,
                text: snapshot.bufferText,
                errorMessage: snapshot.errorMessage
            )
        }

        panel.contentView?.layoutSubtreeIfNeeded()
        let fitting = panel.contentView?.fittingSize ?? NSSize(
            width: minimumPanelSize.width,
            height: minimumPanelSize.height
        )
        let size = CGSize(
            width: min(max(fitting.width, minimumPanelSize.width), maximumPanelSize.width),
            height: min(max(fitting.height, minimumPanelSize.height), maximumPanelSize.height)
        )

        positionPanel(near: snapshot.anchor, contentSize: size)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func positionPanel(near anchor: OverlayAnchor, contentSize: CGSize) {
        let targetRect = anchor.targetRect
        let targetMidPoint = CGPoint(x: targetRect.midX, y: targetRect.midY)

        let screen = NSScreen.screens.first {
            $0.frame.contains(targetMidPoint)
        } ?? NSScreen.main

        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let margin: CGFloat = 10

        var originX = targetRect.minX
        var originY = targetRect.maxY + margin

        if originY + contentSize.height > visibleFrame.maxY {
            originY = targetRect.minY - contentSize.height - margin
        }

        originX = min(max(originX, visibleFrame.minX + margin), visibleFrame.maxX - contentSize.width - margin)
        originY = min(max(originY, visibleFrame.minY + margin), visibleFrame.maxY - contentSize.height - margin)

        panel.setFrame(
            NSRect(origin: CGPoint(x: originX, y: originY), size: contentSize),
            display: true
        )
    }
}
