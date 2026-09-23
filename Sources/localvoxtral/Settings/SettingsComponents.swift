import AppKit
import SwiftUI

enum SettingsLayout {
    static let pageSpacing: CGFloat = 16
    static let pagePadding: CGFloat = 18
    static let sectionSpacing: CGFloat = 10
    /// Horizontal inset of a row inside its group card. Owned by the ROW, not
    /// by the card: the dividers between rows have to run the full card width.
    static let rowHorizontalPadding: CGFloat = 14
    /// Keep this above 4pt. `SettingsGroup` hides the last row's trailing
    /// divider by making the card 1pt shorter than its content and clipping;
    /// with a smaller inset the last row's focus ring would reach into that
    /// clipped pixel and be cut off.
    static let rowVerticalPadding: CGFloat = 11
    /// Gap between a row's label and its control.
    static let rowSpacing: CGFloat = 14
    /// Sliders report no intrinsic width, so a trailing control column has to
    /// give them one.
    static let sliderWidth: CGFloat = 190
    /// Text fields are worse than sliders: no intrinsic width AND greedy, so in
    /// an inline row's trailing column (`layoutPriority(1)`) an unbounded field
    /// takes the whole card and starves the label to zero width (field report,
    /// PR #201 review — the External URL rows rendered as tall empty bands).
    ///
    /// A CAP, not a fixed width: apply it as `.frame(maxWidth:)`. A greedy field
    /// still fills to the cap wherever the card is wide enough (which, at the
    /// Settings window's fixed 780pt, is everywhere), so the look is unchanged —
    /// but a rigid width would crumple the label instead of the field if the
    /// card ever got narrower.
    static let textFieldWidth: CGFloat = 280
    static let cornerRadius: CGFloat = 10
    /// The detail column's ground: white in light mode, near-black in dark,
    /// so the gray sidebar and the gray group cards read against it.
    static let detailBackground = Color(nsColor: .textBackgroundColor)
}

struct SettingsPage<Content: View>: View {
    /// Identifies the pane's content subtree to the AX drills
    /// (`settings.pane.<rawValue>`), which scope their content assertions to it
    /// so a sidebar row's label can never satisfy a pane assertion.
    let tab: SettingsTab
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.pageSpacing) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(SettingsLayout.pagePadding)
            // One place decides how a switch looks, instead of every call site
            // repeating `.toggleStyle(.switch)`.
            .toggleStyle(.switch)
        }
        .settingsScrollEdgeEffectHidden()
        .background(SettingsLayout.detailBackground)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(tab.paneAccessibilityIdentifier)
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    /// When set, the group's header row carries ONE "Learn more" link to this
    /// page (owner review, 2026-09-07): details a row's one-line help can no
    /// longer carry live in the docs, not repeated under every toggle.
    var learnMoreURL: URL?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)

                if let learnMoreURL {
                    Spacer(minLength: 12)
                    Link("Learn more", destination: learnMoreURL)
                        .font(.callout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Every row draws a trailing divider, which makes the LAST one a
            // stray line above the card's bottom edge. Rather than teach the
            // card to enumerate its children (they are heterogeneous, and some
            // arrive wrapped in `Group`/`if` branches), the container is made
            // 1pt shorter than its content and clipped: the final divider hangs
            // outside the clip and is never drawn.
            .padding(.bottom, -1)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: SettingsLayout.cornerRadius,
                    style: .continuous
                )
            )
            .background {
                RoundedRectangle(
                    cornerRadius: SettingsLayout.cornerRadius,
                    style: .continuous
                )
                // No border: on the detail column's white, the fill alone
                // outlines the card (CodexBar's grouped-row look).
                .fill(.quinary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Insets + trailing divider shared by everything that is a row of a
/// `SettingsGroup`. The divider is inset like the row's content, so it reads
/// as a separator between rows rather than a rule across the card.
struct SettingsGroupRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(.horizontal, SettingsLayout.rowHorizontalPadding)
                .padding(.vertical, SettingsLayout.rowVerticalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
                .padding(.horizontal, SettingsLayout.rowHorizontalPadding)
        }
    }
}

struct SettingsAvailabilityCard: View {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color

    private let cornerRadius: CGFloat = 8
    private let horizontalPadding: CGFloat = 12
    private let verticalPadding: CGFloat = 10

    var body: some View {
        SettingsGroupRow {
            card
        }
    }

    /// It is a row of its group like any other (same insets, same trailing
    /// divider) — only its own fill is different.
    private var card: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))

                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background {
            RoundedRectangle(
                cornerRadius: cornerRadius,
                style: .continuous
            )
            .fill(tint.opacity(0.10))
            .overlay {
                RoundedRectangle(
                    cornerRadius: cornerRadius,
                    style: .continuous
                )
                .stroke(tint.opacity(0.18), lineWidth: 1)
            }
        }
    }
}

/// Label leading, control trailing, explanation on its own full-width line
/// underneath — the macOS System Settings idiom.
///
/// The label no longer sits in a fixed 128pt column: long labels used to wrap
/// inside it while short ones left a gutter, and the explanation started at the
/// column's edge, which made every card's text a ragged second column. The label
/// now takes the leftover width (`layoutPriority(0)`, so the control keeps its
/// intrinsic size) and the explanation is a row of its own, aligned to the
/// label's leading edge.
enum SettingsFieldRowLayout {
    /// Label leading, control trailing on the same line. The default.
    case inline
    /// Label on its own line, control full-width beneath it. For rows whose
    /// control is a composite (button bar, host list, file list): beside a
    /// 400pt-wide control the label would be squeezed into a wrapped stub.
    case stacked
}

struct SettingsFieldRow<Content: View, Footer: View>: View {
    let title: String
    /// The secondary explanation. A parameter rather than a view inside
    /// `content`: a row cannot pull a nested view out of its control column, and
    /// the whole point is that this text is NOT in that column.
    ///
    /// This is the STATIC explanation of what the row does, ONE line at
    /// `.callout` (owner review, 2026-09-07: readable size, secondary colour,
    /// never a wall of text — the details live in the docs behind the group's
    /// Learn more link). Anything that changes with the row's state — "Not
    /// set.", a validation error, "Password saved." — belongs in `status` or
    /// `footer:` instead.
    var help: String?
    /// One-line dynamic status, rendered next to the label in the LEADING
    /// column so a row with buttons reads "label + status … [buttons]" on a
    /// single line instead of stacking them into a tall row.
    var status: String?
    /// Drill anchor for `status`, preserved from the stacked layout the rows
    /// used before the horizontal rework.
    var statusAccessibilityIdentifier: String?
    var layout: SettingsFieldRowLayout
    /// How the label sits against the control in an `.inline` row. See
    /// `inlineRow` for why the default is `.center`.
    var controlAlignment: VerticalAlignment
    @ViewBuilder var content: Content
    /// Dynamic per-row status, rendered full-width and LEADING-aligned on its
    /// own line under the control. Not a member of `content`: the control column
    /// is trailing-aligned and only ~200pt wide, so a status sentence placed
    /// there is right-aligned, wraps early, and reads as detached from the row
    /// it describes (PR #201 review).
    @ViewBuilder var footer: Footer
    /// Whether `footer` is a real view. `EmptyView` renders nothing but would
    /// still be a child of the stack; rows built without a footer must lay out
    /// exactly as they did before this slot existed.
    private let hasFooter: Bool

    init(
        title: String,
        help: String? = nil,
        status: String? = nil,
        statusAccessibilityIdentifier: String? = nil,
        layout: SettingsFieldRowLayout = .inline,
        controlAlignment: VerticalAlignment = .center,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.help = help
        self.status = status
        self.statusAccessibilityIdentifier = statusAccessibilityIdentifier
        self.layout = layout
        self.controlAlignment = controlAlignment
        self.content = content()
        self.footer = footer()
        self.hasFooter = true
    }

    init(
        title: String,
        help: String? = nil,
        status: String? = nil,
        statusAccessibilityIdentifier: String? = nil,
        layout: SettingsFieldRowLayout = .inline,
        controlAlignment: VerticalAlignment = .center,
        @ViewBuilder content: () -> Content
    ) where Footer == EmptyView {
        self.title = title
        self.help = help
        self.status = status
        self.statusAccessibilityIdentifier = statusAccessibilityIdentifier
        self.layout = layout
        self.controlAlignment = controlAlignment
        self.content = content()
        self.footer = EmptyView()
        self.hasFooter = false
    }

    var body: some View {
        SettingsGroupRow {
            VStack(alignment: .leading, spacing: 6) {
                switch layout {
                case .inline:
                    inlineRow
                case .stacked:
                    stackedRow
                }

                // Status first, explanation last: the footer reports what the
                // control above it currently is, so it belongs next to it; the
                // help text explains the row as a whole and closes it.
                if hasFooter {
                    footer
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let help {
                    SettingsHelpText(help)
                }
            }
        }
    }

    private var label: some View {
        Text(title)
            .font(.system(size: 13, weight: .medium))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The row's one-line status. The drill anchor is applied only when the
    /// row names one: an unconditional `.accessibilityIdentifier("")` would
    /// put empty ids in every AX dump.
    @ViewBuilder
    private func statusText(_ text: String) -> some View {
        let base = Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)

        if let statusAccessibilityIdentifier {
            base.accessibilityIdentifier(statusAccessibilityIdentifier)
        } else {
            base
        }
    }

    private var inlineRow: some View {
        // Centered by default, top-aligned only where a row asks for it. The
        // default used to be `.top`, which is right for a tall composite control
        // but wrong for the ~10 rows whose control is a lone switch or picker:
        // the 13pt label's cap then sits above the switch's centerline and reads
        // misaligned against System Settings (PR #201 review). A row with a
        // genuinely tall control passes `controlAlignment: .top`.
        HStack(alignment: controlAlignment, spacing: SettingsLayout.rowSpacing) {
            // "Label + one-line status" on the left (owner review, 2026-09-07):
            // baselines aligned, the status truncates rather than wrapping so a
            // row with buttons stays one line tall.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                label

                if let status {
                    statusText(status)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(0)

            VStack(alignment: .trailing, spacing: 6) {
                content
            }
            .layoutPriority(1)
        }
    }

    private var stackedRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            label
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SettingsHelpText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        // ONE line, at a readable size (owner review, 2026-09-07): `.callout`
        // in secondary colour, truncating rather than wrapping, so no row can
        // grow a wall of text under its control. What does not fit lives in
        // the docs behind the group's Learn more link.
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One short inline sentence in a Settings pane. Internal (not private) so
/// pane-subviews in their own files — e.g. `HerdrMachinesSettingsList` — can
/// reuse the idiom instead of copying it.
struct SettingsInlineMessage: View {
    let message: String
    let color: Color

    init(_ message: String, color: Color) {
        self.message = message
        self.color = color
    }

    var body: some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
