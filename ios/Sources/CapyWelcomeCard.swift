import SwiftUI
import UIKit
import ImageIO

/// Decorative Home artwork; never participates in playback or navigation.
struct CapyWelcomeCard: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        CapyGIFImage(playing: appeared && scenePhase == .active && !reduceMotion)
            .aspectRatio(1604.0 / 924.0, contentMode: .fit)
            .frame(maxWidth: 520)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .frame(maxWidth: .infinity)
            .onAppear { appeared = true }
            .onDisappear { appeared = false }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct CapyGIFImage: UIViewRepresentable {
    let playing: Bool
    var resourceName = "capy-welcome"
    var contentMode: UIView.ContentMode = .scaleAspectFit
    var gifData: Data? = nil

    func makeUIView(context: Context) -> CapyGIFCanvas {
        CapyGIFCanvas(resourceName: resourceName, contentMode: contentMode, gifData: gifData)
    }
    func updateUIView(_ view: CapyGIFCanvas, context: Context) { view.setPlaying(playing) }
    static func dismantleUIView(_ view: CapyGIFCanvas, coordinator: ()) { view.setPlaying(false) }
}

/// Keeps only the current downsampled frame, rather than all full-size GIF frames.
final class CapyGIFCanvas: UIView {
    private let imageView = UIImageView()
    private var source: CGImageSource?
    private var frameCount = 0
    private(set) var frameIndex = 0
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var elapsed: CFTimeInterval = 0
    private var frameDuration: CFTimeInterval = 0.1

    init(resourceName: String = "capy-welcome", contentMode: UIView.ContentMode = .scaleAspectFit, gifData: Data? = nil) {
        super.init(frame: .zero)
        clipsToBounds = true
        imageView.contentMode = contentMode
        imageView.isUserInteractionEnabled = false
        addSubview(imageView)
        if let gifData {
            source = CGImageSourceCreateWithData(gifData as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
            if let source { frameCount = CGImageSourceGetCount(source) }
            showFrame(0)
        } else if let url = Bundle.main.url(forResource: resourceName, withExtension: "gif") {
            source = CGImageSourceCreateWithURL(url as CFURL, [
                kCGImageSourceShouldCache: false
            ] as CFDictionary)
            if let source { frameCount = CGImageSourceGetCount(source) }
            showFrame(0)
        }
    }

    override convenience init(frame: CGRect) {
        self.init(resourceName: "capy-welcome", contentMode: .scaleAspectFit)
        self.frame = frame
    }
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
        guard isOnscreen else { lastTimestamp = 0; return }
        guard lastTimestamp > 0 else { lastTimestamp = link.timestamp; return }
        elapsed += min(link.timestamp - lastTimestamp, 0.25)
        lastTimestamp = link.timestamp
        guard elapsed >= frameDuration else { return }
        elapsed -= frameDuration
        frameIndex = (frameIndex + 1) % frameCount
        showFrame(frameIndex)
    }

    private var isOnscreen: Bool {
        guard let window, !isHidden, alpha > 0,
              window.bounds.intersects(convert(bounds, to: window)) else { return false }
        var ancestor = superview
        while let view = ancestor {
            if view.clipsToBounds && !view.bounds.intersects(convert(bounds, to: view)) { return false }
            ancestor = view.superview
        }
        return true
    }

    private func showFrame(_ index: Int) {
        guard let source, frameCount > 0 else { return }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
        frameDuration = max(0.02, delay)
        // Decode the requested frame explicitly, retaining only one scaled image.
        guard let frame = CGImageSourceCreateImageAtIndex(source, index, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else { return }
        let scale = min(1, 1024.0 / CGFloat(max(frame.width, frame.height)))
        let size = CGSize(width: CGFloat(frame.width) * scale, height: CGFloat(frame.height) * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        imageView.image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIImage(cgImage: frame).draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
