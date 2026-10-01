import SwiftUI
import UIKit

// MARK: - Foundations

enum CapyColor {
    static let accent = Color(red: 0.56, green: 0.80, blue: 0.92)
    static let accentStrong = Color(red: 0.35, green: 0.69, blue: 0.88)
    static let background = Color(red: 0.025, green: 0.035, blue: 0.055)
    static let backgroundRaised = Color(red: 0.07, green: 0.105, blue: 0.13)
    static let surface = Color.white.opacity(0.065)
    static let surfaceStrong = Color.white.opacity(0.105)
    static let surfaceStroke = Color.white.opacity(0.095)
    static let glassStroke = Color.white.opacity(0.18)
    static let secondaryText = Color.white.opacity(0.66)
    static let tertiaryText = Color.white.opacity(0.42)
    static let warning = Color(red: 1.0, green: 0.66, blue: 0.25)
    static let destructive = Color(red: 1.0, green: 0.34, blue: 0.38)
}

enum CapySpacing {
    static let xSmall: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let regular: CGFloat = 16
    static let large: CGFloat = 20
    static let xLarge: CGFloat = 28
    static let section: CGFloat = 36
}

enum CapyRadius {
    static let small: CGFloat = 12
    static let medium: CGFloat = 18
    static let large: CGFloat = 24
    static let hero: CGFloat = 30
    static let capsule: CGFloat = 1_000
}

enum CapyMetric {
    /// Keeps a comfortable 16-point gutter on an iPhone 13 while preventing
    /// content from becoming excessively wide on iPad.
    static let horizontalInset: CGFloat = 16
    static let readableWidth: CGFloat = 620
    static let minimumTapTarget: CGFloat = 48
    static let rowArtwork: CGFloat = 56
    static let miniPlayerHeight: CGFloat = 68
}

extension Font {
    static let capyHero = Font.system(.largeTitle, design: .rounded, weight: .bold)
    static let capyTitle = Font.system(.title2, design: .rounded, weight: .bold)
    static let capySection = Font.system(.headline, design: .rounded, weight: .bold)
    static let capyBody = Font.system(.body, design: .rounded, weight: .medium)
    static let capyCallout = Font.system(.callout, design: .rounded, weight: .semibold)
    static let capyCaption = Font.system(.caption, design: .rounded, weight: .semibold)
}

// MARK: - Ambient artwork atmosphere

/// A deterministic palette derived from a track, album, playlist, or artwork
/// identifier. This deliberately avoids reading and sampling image pixels on
/// every render, so elapsed-time and lyric updates cannot retrigger expensive
/// color extraction.
private struct CapyAmbientPalette {
    let primary: Color
    let secondary: Color

    init(seed: String) {
        let swatches: [(Double, Double)] = [
            (0.55, 0.64), (0.61, 0.59), (0.73, 0.58), (0.83, 0.60),
            (0.93, 0.57), (0.08, 0.62), (0.13, 0.64), (0.47, 0.53)
        ]
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let first = swatches[Int(hash % UInt64(swatches.count))]
        let second = swatches[Int((hash >> 8) % UInt64(swatches.count))]
        primary = Color(hue: first.0, saturation: first.1, brightness: 0.60)
        secondary = Color(hue: second.0, saturation: second.1, brightness: 0.40)
    }
}

struct CapyAmbientBackdrop: View, Equatable {
    let seed: String
    var artworkURL: URL? = nil
    var intensity: Double = 1

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.seed == rhs.seed && lhs.artworkURL == rhs.artworkURL && lhs.intensity == rhs.intensity
    }

    var body: some View {
        let palette = CapyAmbientPalette(seed: seed)
        // Artwork is decoration. Isolate its scaled-to-fill dimensions from
        // the foreground ZStack's layout so it cannot widen the whole screen.
        GeometryReader { geometry in
          ZStack {
            CapyColor.background
            if let artworkURL {
                AsyncImage(url: artworkURL) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFill()
                            .scaleEffect(1.12)
                            .blur(radius: 52, opaque: true)
                            .opacity(0.14 * intensity)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
            }
            RadialGradient(
                colors: [palette.primary.opacity(0.34 * intensity), .clear],
                center: .topTrailing,
                startRadius: 8,
                endRadius: 470
            )
            LinearGradient(
                colors: [palette.secondary.opacity(0.18 * intensity), .clear, .black.opacity(0.52)],
                startPoint: .topLeading,
                endPoint: .bottom
            )
          }
          .frame(width: geometry.size.width, height: geometry.size.height)
          .clipped()
        }
        .allowsHitTesting(false)
        .drawingGroup(opaque: true, colorMode: .linear)
        // Expand the completed decorative layer, including its compositing
        // surface. Foreground siblings keep their normal safe-area layout.
        .ignoresSafeArea(.container, edges: .all)
        .accessibilityHidden(true)
    }
}

// MARK: - Artwork

struct CapyArtworkImage: View {
    let url: URL?
    var size: CGFloat
    var cornerRadius: CGFloat = CapyRadius.medium
    var placeholder = "music.note"

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.18))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
                    .transition(.opacity)
            case .empty:
                placeholderView.overlay { ProgressView().tint(.white.opacity(0.8)) }
            default:
                placeholderView
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.75)
        }
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var placeholderView: some View {
        ZStack {
            CapyColor.backgroundRaised
            Image(systemName: placeholder)
                .font(.system(size: max(15, size * 0.26), weight: .semibold))
                .foregroundStyle(CapyColor.accent.opacity(0.84))
        }
    }
}

/// Uses available width, but caps hero artwork for an iPhone 13 portrait view
/// and for readable split views on iPad.
struct CapyArtworkHero: View {
    let url: URL?
    var placeholder = "music.note"
    var maximumSize: CGFloat = 350

    var body: some View {
        GeometryReader { geometry in
            // Never impose a minimum that is wider than the container. The
            // previous 220-point floor could make artwork escape compact
            // split views and smaller iPhones.
            let dimension = max(1, min(maximumSize, geometry.size.width))
            CapyArtworkImage(
                url: url,
                size: dimension,
                cornerRadius: CapyRadius.hero,
                placeholder: placeholder
            )
            .shadow(color: .black.opacity(0.24), radius: 20, y: 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: maximumSize)
    }
}

// MARK: - Layout and hierarchy

struct CapyScreenContainer<Content: View>: View {
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        CapyReadableLayout { content() }
    }
}

/// A finite maximum frame can still accept a child's oversized ideal width.
/// Propose the actual viewport width to scroll content and ViewThatFits so
/// compact screens choose their vertical layouts before measuring height.
private struct CapyReadableLayout: Layout {
    private func contentWidth(_ width: CGFloat) -> CGFloat {
        max(1, min(CapyMetric.readableWidth, width - 2 * CapyMetric.horizontalInset))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
            ?? CapyMetric.readableWidth + 2 * CapyMetric.horizontalInset
        let size = subviews.first?.sizeThatFits(
            ProposedViewSize(width: contentWidth(width), height: proposal.height)
        ) ?? .zero
        return CGSize(width: width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = contentWidth(bounds.width)
        subviews.first?.place(
            at: CGPoint(x: bounds.midX - width / 2, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: width, height: bounds.height)
        )
    }
}

struct CapyScreenTitle: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: CapySpacing.xSmall) {
            Text(title)
                .font(.capyHero)
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.capyBody)
                    .foregroundStyle(CapyColor.secondaryText)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
        .accessibilityElement(children: .combine)
    }
}

struct CapySectionHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    let trailing: () -> Trailing

    init(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: CapySpacing.medium) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.capySection).foregroundStyle(.white)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.capyCaption).foregroundStyle(CapyColor.secondaryText)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: CapySpacing.small)
            trailing()
        }
    }
}

extension CapySectionHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

struct CapyNavigationChrome<Leading: View, Center: View, Trailing: View>: View {
    let leading: () -> Leading
    let center: () -> Center
    let trailing: () -> Trailing

    init(
        @ViewBuilder leading: @escaping () -> Leading,
        @ViewBuilder center: @escaping () -> Center,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.leading = leading
        self.center = center
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: CapySpacing.medium) {
            leading().frame(minWidth: CapyMetric.minimumTapTarget, alignment: .leading)
            center().frame(maxWidth: .infinity)
            trailing().frame(minWidth: CapyMetric.minimumTapTarget, alignment: .trailing)
        }
        .padding(.horizontal, CapySpacing.small)
        .frame(minHeight: 56)
        .waveGlass(radius: CapyRadius.large)
    }
}

// MARK: - Reusable surfaces

struct CapySurface<Content: View>: View {
    var highlighted = false
    var padding: CGFloat = CapySpacing.regular
    let content: () -> Content

    init(
        highlighted: Bool = false,
        padding: CGFloat = CapySpacing.regular,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.highlighted = highlighted
        self.padding = padding
        self.content = content
    }

    var body: some View {
        content()
            .padding(padding)
            .waveSurface(radius: CapyRadius.medium, highlighted: highlighted)
    }
}

struct CapyGlassPanel<Content: View>: View {
    var highlighted = false
    var padding: CGFloat = CapySpacing.regular
    let content: () -> Content

    init(
        highlighted: Bool = false,
        padding: CGFloat = CapySpacing.regular,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.highlighted = highlighted
        self.padding = padding
        self.content = content
    }

    var body: some View {
        content()
            .padding(padding)
            .waveGlass(radius: CapyRadius.large, highlighted: highlighted)
    }
}

struct CapyMediaRow<Leading: View, Trailing: View>: View {
    let title: String
    var subtitle: String?
    var isActive = false
    let leading: () -> Leading
    let trailing: () -> Trailing

    init(
        title: String,
        subtitle: String? = nil,
        isActive: Bool = false,
        @ViewBuilder leading: @escaping () -> Leading,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.isActive = isActive
        self.leading = leading
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: CapySpacing.medium) {
            leading()
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.capyCallout)
                    .foregroundStyle(isActive ? CapyColor.accent : .white)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.capyCaption)
                        .foregroundStyle(CapyColor.secondaryText)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            Spacer(minLength: CapySpacing.small)
            trailing()
        }
        .padding(.horizontal, CapySpacing.medium)
        .frame(minHeight: 72)
        .contentShape(Rectangle())
        .waveSurface(radius: CapyRadius.medium, highlighted: isActive)
    }
}

struct CapySearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: CapySpacing.small) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(CapyColor.secondaryText)
            TextField(prompt, text: $text)
                .font(.capyBody)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !text.isEmpty {
                Button {
                    text = ""
                    CapyHaptics.selection()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(CapyColor.secondaryText)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, CapySpacing.regular)
        .padding(.trailing, text.isEmpty ? CapySpacing.regular : 2)
        .frame(height: 52)
        .waveGlass(radius: CapyRadius.medium)
    }
}

// MARK: - Buttons and slider

struct CapyPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.capyCallout)
            .foregroundStyle(CapyColor.background)
            .padding(.horizontal, CapySpacing.regular)
            .frame(maxWidth: .infinity, minHeight: CapyMetric.minimumTapTarget)
            .background(CapyColor.accent.opacity(isEnabled ? 1 : 0.38), in: Capsule())
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct CapySecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.capyCallout)
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.38))
            .padding(.horizontal, CapySpacing.regular)
            .frame(maxWidth: .infinity, minHeight: CapyMetric.minimumTapTarget)
            .background(CapyColor.surfaceStrong, in: Capsule())
            .overlay { Capsule().stroke(CapyColor.surfaceStroke, lineWidth: 0.75) }
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct CapyIconButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .bold, design: .rounded))
            .foregroundStyle(prominent ? CapyColor.background : Color.white)
            .frame(width: CapyMetric.minimumTapTarget, height: CapyMetric.minimumTapTarget)
            .background(prominent ? CapyColor.accent : CapyColor.surfaceStrong, in: Circle())
            .overlay { Circle().stroke(prominent ? .clear : CapyColor.surfaceStroke, lineWidth: 0.75) }
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Enlarges the gesture target beyond the visible slider track and keeps the
/// native iOS scrubber behavior, VoiceOver support, and RTL handling.
struct CapyPlaybackSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
            .tint(CapyColor.accent)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}

// MARK: - Loading, empty, and error states

enum CapyScreenStateKind: Equatable {
    case loading
    case empty
    case error

    var icon: String {
        switch self {
        case .loading: "waveform"
        case .empty: "music.note.list"
        case .error: "exclamationmark.triangle.fill"
        }
    }
}

struct CapyScreenState<Action: View>: View {
    let kind: CapyScreenStateKind
    let title: String
    var message: String?
    let action: () -> Action

    init(
        kind: CapyScreenStateKind,
        title: String,
        message: String? = nil,
        @ViewBuilder action: @escaping () -> Action
    ) {
        self.kind = kind
        self.title = title
        self.message = message
        self.action = action
    }

    var body: some View {
        VStack(spacing: CapySpacing.regular) {
            Group {
                if kind == .loading {
                    ProgressView().tint(CapyColor.accent)
                } else {
                    Image(systemName: kind.icon)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(kind == .error ? CapyColor.warning : CapyColor.accent)
                }
            }
            .frame(width: 52, height: 52)

            VStack(spacing: CapySpacing.small) {
                Text(title).font(.capySection).foregroundStyle(.white)
                if let message, !message.isEmpty {
                    Text(message)
                        .font(.capyBody)
                        .foregroundStyle(CapyColor.secondaryText)
                        .multilineTextAlignment(.center)
                }
            }
            action()
        }
        .padding(.horizontal, CapySpacing.xLarge)
        .padding(.vertical, CapySpacing.section)
        .frame(maxWidth: .infinity)
        .waveSurface(radius: CapyRadius.large)
        .accessibilityElement(children: .contain)
    }
}

extension CapyScreenState where Action == EmptyView {
    init(kind: CapyScreenStateKind, title: String, message: String? = nil) {
        self.init(kind: kind, title: title, message: message) { EmptyView() }
    }
}

// MARK: - Motion and haptics

private struct CapyEntranceModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let active: Bool

    func body(content: Content) -> some View {
        content
            .opacity(active ? 1 : 0)
            .offset(y: reduceMotion || active ? 0 : 8)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: active)
    }
}

extension View {
    func capyEntrance(active: Bool = true) -> some View {
        modifier(CapyEntranceModifier(active: active))
    }
}

@MainActor
enum CapyHaptics {
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }
}
