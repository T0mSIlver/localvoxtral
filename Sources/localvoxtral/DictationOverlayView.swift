import SwiftUI

struct DictationOverlayView: View {
    let phase: OverlayBufferPhase
    let text: String
    let errorMessage: String?

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
        .frame(width: 420, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 16, x: 0, y: 8)
    }
}
