import AVFoundation
import AVKit
import SwiftUI

enum AudioRoutePolicy {
    static func configure(_ session: AVAudioSession) throws {
        try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
    }
    static func shouldPause(reason: UInt?) -> Bool {
        reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
    }
}

struct AudioOutputPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.tintColor = UIColor(CapyColor.secondaryText)
        view.activeTintColor = UIColor(CapyColor.accent)
        view.accessibilityLabel = "Choose audio output"
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
