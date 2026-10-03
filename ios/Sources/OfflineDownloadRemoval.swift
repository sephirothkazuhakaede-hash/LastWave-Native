import Foundation

enum OfflineDownloadRemoval {
    static func matches(_ row: Track, _ copy: Track) -> Bool {
        guard row.id == copy.id || row.playableID == copy.playableID else { return false }
        if let explicit = row.isExplicit, let other = copy.isExplicit, explicit != other { return false }
        return true
    }
    static func copies(for tracks: [Track], in downloads: [Track]) -> [Track] {
        let direct = downloads.filter { copy in tracks.contains { matches($0, copy) } }
        // Remove every stored quality of the same recording, including aliases.
        return downloads.filter { copy in direct.contains { matches($0, copy) } }
    }
    static func removeFiles(_ copies: [Track], localURL: (Track) -> URL, fileManager: FileManager = .default) throws {
        for url in Set(copies.map(localURL)) where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}
