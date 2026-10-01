import Foundation

enum MediaDuration {
    static func parse(_ value: String) -> Double? {
        let components = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(components.count),
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
        let values = components.compactMap { Double($0) }
        guard values.count == components.count, values.allSatisfy({ $0.isFinite && $0 >= 0 }),
              values.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
        let result = values.reduce(0) { $0 * 60 + $1 }
        return result.isFinite && result > 0 ? result : nil
    }
}
