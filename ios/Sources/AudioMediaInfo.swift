import Foundation

/// Values reported by the extractor for the selected media, never inferred
/// from a quality preference. Missing fields remain unavailable.
struct AudioMediaInfo: Codable, Equatable, Sendable {
    var container: String?
    var codec: String?
    var bitrateKbps: Double?
    var sampleRateHz: Double?
    var formatId: String?
    var selectedMode: String?
    var effectiveMode: String?
    var availableQualityCount: Int?

    var description: String {
        var values = [codec, container?.uppercased()].compactMap { $0 }
        if let bitrateKbps, bitrateKbps.isFinite, bitrateKbps > 0 {
            values.append(String(format: "%.0f kbps", bitrateKbps))
        }
        if let sampleRateHz, sampleRateHz.isFinite, sampleRateHz > 0 {
            values.append(String(format: "%.1f kHz", sampleRateHz / 1000))
        }
        if let effectiveMode {
            values.append(effectiveMode == "dataSaver" ? "Data Saver" : "Best Available")
        }
        if availableQualityCount == 1 { values.append("Only one source quality") }
        return values.isEmpty ? "Media details unavailable" : values.joined(separator: " · ")
    }
}
