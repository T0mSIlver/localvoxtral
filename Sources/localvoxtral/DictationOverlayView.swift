import SwiftUI

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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: Color.black.opacity(0.18), radius: 16, x: 0, y: 8)
    }
}
