import SwiftUI

struct AudioQualitySettingsView: View {
    @EnvironmentObject private var player: WavePlayer
    var body: some View {
        Form {
            Section("Streaming and downloads") {
                Picker("Audio Quality", selection: $player.audioQuality) {
                    ForEach(AudioQuality.allCases) { quality in
                        Text(quality.rawValue).tag(quality)
                    }
                }
                .pickerStyle(.inline)
            }
            Section {
                Text("Best Available keeps the current fast default and uses the best original compatible audio. Data Saver chooses the lowest available compatible source. Nothing is upscaled or converted to simulate higher quality.")
                Text("When a source offers only one quality, both modes use Best Available. Audio Info in Now Playing shows the actual media details when provided.")
                Text("Changes apply to the next song or download. Existing playback continues without restarting.")
            }
        }
        .scrollContentBackground(.hidden)
        .background { WaveBackdrop() }
        .navigationTitle("Audio Quality")
        .navigationBarTitleDisplayMode(.inline)
    }
}
