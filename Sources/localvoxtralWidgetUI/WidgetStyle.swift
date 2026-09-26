import SwiftUI
import WidgetKit
import localvoxtralCore

/// Shared look of the desktop widgets (#630).
///
/// The two engines never rely on hue alone: the desktop drops color when
/// another window is focused, and macOS 26 can tint a widget to one color.
/// Speech draws a waveform and solid fills, polish a wand and hatched ones.
package enum WidgetStyle {
    package static let speechColor = Color.accentColor
    package static let polishColor = Color.orange
    package static let savedColor = Color.green

    package static func color(_ role: WidgetSnapshot.EngineRole) -> Color {
        role == .speech ? speechColor : polishColor
    }

    package static func symbol(_ role: WidgetSnapshot.EngineRole) -> String {
        role == .speech ? "waveform" : "wand.and.stars"
    }

    /// The pixel sizes macOS gives each family, for previews and snapshots.
    package static func size(_ size: WidgetSize) -> CGSize {
        switch size {
        case .small: return CGSize(width: 170, height: 170)
        case .medium: return CGSize(width: 364, height: 170)
        case .large: return CGSize(width: 364, height: 382)
        }
    }
}

/// The title line every widget opens with.
struct WidgetHeader: View {
    let symbol: String
    let title: String
    var detail: String?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tint)
                .widgetAccentable()
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }
}

/// An engine's mark: its symbol in its color.
struct EngineMark: View {
    let role: WidgetSnapshot.EngineRole
    var size: CGFloat = 10

    var body: some View {
        Image(systemName: WidgetStyle.symbol(role))
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(WidgetStyle.color(role))
            .widgetAccentable()
            .frame(width: size + 4)
    }
}

/// Diagonal stripes: polish's fill, so its share reads without color.
struct Hatching: Shape {
    var spacing: CGFloat = 3

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        return path
    }
}

/// One engine's fill in a memory bar or ring.
struct EngineFill: View {
    let role: WidgetSnapshot.EngineRole

    var body: some View {
        let color = WidgetStyle.color(role)
        if role == .speech {
            Rectangle().fill(color).widgetAccentable()
        } else {
            ZStack {
                Rectangle().fill(color.opacity(0.35))
                Hatching().stroke(color, lineWidth: 1.2)
            }
            .widgetAccentable()
        }
    }
}

/// The small, pill-shaped button the widgets use.
package struct WidgetPillButtonStyle: ButtonStyle {
    package init() {}

    package func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(.quaternary))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
