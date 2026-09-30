import SwiftUI

extension Color {
    static let waveBlue = Color(red: 0.62, green: 0.78, blue: 0.87)
    static let waveDeep = Color(red: 0.08, green: 0.14, blue: 0.17)
}

struct GlassCard: ViewModifier {
    var radius: CGFloat = 28
    var highlighted = false
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial)
            .background {
                LinearGradient(
                    colors: highlighted ? [Color.waveBlue.opacity(0.34), .white.opacity(0.09), .black.opacity(0.08)] : [.white.opacity(0.10), .white.opacity(0.025), .black.opacity(0.12)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0.05), Color.waveBlue.opacity(highlighted ? 0.30 : 0.08)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.32), radius: 24, y: 12)
    }
}

extension View {
    func waveGlass(radius: CGFloat = 28, highlighted: Bool = false) -> some View {
        modifier(GlassCard(radius: radius, highlighted: highlighted))
    }
}

struct WaveBackdrop: View {
    var body: some View {
        ZStack {
            Color.black
            RadialGradient(colors: [Color.waveBlue.opacity(0.18), .clear], center: .topTrailing, startRadius: 5, endRadius: 420)
            RadialGradient(colors: [Color.indigo.opacity(0.13), .clear], center: .bottomLeading, startRadius: 20, endRadius: 500)
            LinearGradient(colors: [.clear, Color.waveDeep.opacity(0.30), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
        }.ignoresSafeArea()
    }
}

struct Artwork: View {
    let track: Track
    var size: CGFloat = 58
    var radius: CGFloat = 16
    var body: some View {
        AsyncImage(url: track.artwork) { phase in
            switch phase {
            case .success(let image): image.resizable().scaledToFill()
            default:
                ZStack {
                    LinearGradient(colors: [Color.waveBlue.opacity(0.45), Color.indigo.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "waveform").foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 0.7) }
    }
}
