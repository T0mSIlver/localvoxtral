import AppKit
import SwiftUI

private final class RoundedVisualEffectView: NSVisualEffectView {
    var cornerRadius: CGFloat = 12 {
        didSet {
            guard oldValue != cornerRadius else { return }
            previousMaskSize = .zero
            updateMask()
        }
    }

    private var previousMaskSize: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        updateMask()
    }

    private func updateMask() {
        layer?.cornerRadius = cornerRadius
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        guard size != previousMaskSize else { return }
        previousMaskSize = size
        maskImage = Self.makeMaskImage(size: size, cornerRadius: cornerRadius)
    }

    private static func makeMaskImage(size: CGSize, cornerRadius: CGFloat) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        NSColor.white.setFill()
        NSBezierPath(
            roundedRect: NSRect(origin: .zero, size: size),
            xRadius: cornerRadius,
            yRadius: cornerRadius
        ).fill()
        image.unlockFocus()
        return image
    }
}

private struct RoundedMaterialBackground: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> RoundedVisualEffectView {
        let view = RoundedVisualEffectView(frame: .zero)
        view.cornerRadius = cornerRadius
        return view
    }

    func updateNSView(_ nsView: RoundedVisualEffectView, context: Context) {
        nsView.cornerRadius = cornerRadius
        nsView.material = .hudWindow
        nsView.blendingMode = .behindWindow
        nsView.state = .active
    }
}

struct DictationOverlayView: View {
    let phase: OverlayBufferPhase
    let text: String
    let errorMessage: String?
    private let cornerRadius: CGFloat = 12

    private var phaseTitle: String {
        switch phase {
        case .buffering:
            return "Listening"
        case .finalizing:
            return "Finalizing"
        case .commitFailed:
            return "Insert failed"
        case .idle:
            return "Ready"
        }
    }

    private var displayText: String {
        let trimmed = text.trimmed
        return trimmed.isEmpty ? "Listening..." : text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                Text(phaseTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if phase == .finalizing {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 16)

            Text(displayText)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let errorMessage, !errorMessage.trimmed.isEmpty {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .frame(minWidth: 400, idealWidth: 420, maxWidth: 540, alignment: .leading)
        .background(RoundedMaterialBackground(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .compositingGroup()
        .shadow(color: Color.black.opacity(0.18), radius: 16, x: 0, y: 8)
    }
}
