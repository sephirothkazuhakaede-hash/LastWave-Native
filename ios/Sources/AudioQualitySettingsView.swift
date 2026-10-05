import SwiftUI

struct AudioQualitySettingsView: View {
    @EnvironmentObject private var player: WavePlayer
    var body: some View {
        ZStack {
            WaveBackdrop()
            ScrollView {
                CapyScreenContainer {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Streaming and downloads").font(.capySection)
                        ForEach(AudioQuality.allCases) { quality in
                            Button {
                                player.audioQuality = quality
                            } label: {
                                HStack(spacing: 12) {
                                    Text(quality.rawValue).font(.headline)
                                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: player.audioQuality == quality ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(CapyColor.accent)
                                }
                                .padding(16)
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .contentShape(Rectangle())
                                .waveSurface(highlighted: player.audioQuality == quality)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("audio-quality-\(quality.backendValue)")
                            .accessibilityValue(player.audioQuality == quality ? "Selected" : "")
                        }
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Best Available plays the highest quality available. Data Saver uses less mobile data.")
                            Text("Some songs are available in only one quality. You can check a song’s audio quality in Now Playing.")
                            Text("Changes apply to the next song or download. Existing playback continues without restarting.")
                        }
                        .font(.capyBody)
                        .foregroundStyle(CapyColor.secondaryText)
                    }
                    .padding(.vertical, 20)
                }
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Audio Quality")
        .navigationBarTitleDisplayMode(.inline)
    }
}
