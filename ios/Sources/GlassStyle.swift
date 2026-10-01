import SwiftUI

extension Color {
    static let waveBlue = CapyColor.accent
    static let waveDeep = CapyColor.backgroundRaised
}

/// Material reserved for floating controls and navigation chrome. Avoid using
/// this on every row in a scrolling list; `waveSurface` is cheaper there.
struct GlassCard: ViewModifier {
    var radius: CGFloat = CapyRadius.large
    var highlighted = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(.thinMaterial, in: shape)
            .background {
                shape.fill(highlighted ? CapyColor.accent.opacity(0.13) : Color.white.opacity(0.035))
            }
            .overlay {
                shape.stroke(
                    highlighted ? CapyColor.accent.opacity(0.38) : CapyColor.glassStroke,
                    lineWidth: 0.75
                )
            }
            .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
    }
}

/// A low-cost surface for scrolling content. Unlike `GlassCard`, this avoids
/// live backdrop blur and large shadows so rows remain smooth during playback.
struct SurfaceCard: ViewModifier {
    var radius: CGFloat = CapyRadius.medium
    var highlighted = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                shape.fill(highlighted ? CapyColor.accent.opacity(0.14) : CapyColor.surface)
            }
            .overlay {
                shape.stroke(
                    highlighted ? CapyColor.accent.opacity(0.34) : CapyColor.surfaceStroke,
                    lineWidth: 0.75
                )
            }
    }
}

extension View {
    func waveGlass(radius: CGFloat = CapyRadius.large, highlighted: Bool = false) -> some View {
        modifier(GlassCard(radius: radius, highlighted: highlighted))
    }

    func waveSurface(radius: CGFloat = CapyRadius.medium, highlighted: Bool = false) -> some View {
        modifier(SurfaceCard(radius: radius, highlighted: highlighted))
    }
}

/// Backward-compatible default backdrop for screens that do not have artwork.
/// New detail screens should pass their artwork identifier to
/// `CapyAmbientBackdrop` so each album or playlist gets a stable atmosphere.
struct WaveBackdrop: View {
    var body: some View {
        CapyAmbientBackdrop(seed: "capyflow")
    }
}

struct Artwork: View {
    let track: Track
    var size: CGFloat = 58
    var radius: CGFloat = 16

    var body: some View {
        CapyArtworkImage(
            url: track.artwork,
            size: size,
            cornerRadius: radius,
            placeholder: "waveform"
        )
    }
}

struct AlbumArtwork: View {
    let album: Album
    var size: CGFloat = 84
    var radius: CGFloat = 16

    var body: some View {
        CapyArtworkImage(
            url: album.artwork,
            size: size,
            cornerRadius: radius,
            placeholder: "square.stack.fill"
        )
    }
}
