import SwiftUI
import UIKit
import ImageIO

private struct CapyCardFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// Decorative Home artwork; never participates in playback or navigation.
struct CapyWelcomeCard: View {
    let viewport: CGRect
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cardFrame: CGRect = .zero
    @State private var appeared = false

    private var isVisible: Bool {
        appeared && !viewport.isEmpty && cardFrame.intersects(viewport)
    }

    var body: some View {
        CapyGIFImage(playing: isVisible && scenePhase == .active && !reduceMotion)
            .aspectRatio(1604.0 / 924.0, contentMode: .fit)
            .frame(maxWidth: 520)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .frame(maxWidth: .infinity)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: CapyCardFrameKey.self, value: geometry.frame(in: .global))
                }
            }
            .onPreferenceChange(CapyCardFrameKey.self) { cardFrame = $0 }
            .onAppear { appeared = true }
            .onDisappear { appeared = false }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct CapyGIFImage: UIViewRepresentable {
    let playing: Bool

    func makeUIView(context: Context) -> CapyGIFCanvas { CapyGIFCanvas() }
    func updateUIView(_ view: CapyGIFCanvas, context: Context) { view.setPlaying(playing) }
    static func dismantleUIView(_ view: CapyGIFCanvas, coordinator: ()) { view.setPlaying(false) }
}

/// Keeps only the current downsampled frame, rather than all full-size GIF frames.
private final class CapyGIFCanvas: UIView {
    private let imageView = UIImageView()
    private var source: CGImageSource?
    private var frameCount = 0
    private var frameIndex = 0
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var elapsed: CFTimeInterval = 0
    private var frameDuration: CFTimeInterval = 0.1

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = false
        addSubview(imageView)
        if let url = Bundle.main.url(forResource: "capy-welcome", withExtension: "gif") {
            source = CGImageSourceCreateWithURL(url as CFURL, [
                kCGImageSourceShouldCache: false
            ] as CFDictionary)
            if let source { frameCount = CGImageSourceGetCount(source) }
            showFrame(0)
        }
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
    }

    func setPlaying(_ playing: Bool) {
        guard playing, frameCount > 1 else {
            guard displayLink != nil else { return }
            displayLink?.invalidate()
            displayLink = nil
            lastTimestamp = 0
            elapsed = 0
            frameIndex = 0
            showFrame(0)
            return
        }
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(advance(_:)))
        link.preferredFramesPerSecond = 30
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func advance(_ link: CADisplayLink) {
        guard lastTimestamp > 0 else { lastTimestamp = link.timestamp; return }
        elapsed += min(link.timestamp - lastTimestamp, 0.25)
        lastTimestamp = link.timestamp
        guard elapsed >= frameDuration else { return }
        elapsed -= frameDuration
        frameIndex = (frameIndex + 1) % frameCount
        showFrame(frameIndex)
    }

    private func showFrame(_ index: Int) {
        guard let source, frameCount > 0 else { return }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
        frameDuration = max(0.02, delay)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: true
        ]
        if let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) {
            imageView.image = UIImage(cgImage: frame)
        }
    }
}
