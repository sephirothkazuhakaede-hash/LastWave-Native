import Foundation
import Combine
import CryptoKit
import UIKit
import FirebaseFirestore

struct AccountPlaylistRecord: Codable, Equatable {
    let id: String
    let payload: Data?
    let cover: Data?
    var deleted: Bool { payload == nil }
    var playlist: ImportedPlaylist? { payload.flatMap { try? JSONDecoder().decode(ImportedPlaylist.self, from: $0) } }
    static func documentID(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func capture(_ playlist: ImportedPlaylist, cover: Data?) throws -> AccountPlaylistRecord {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let payload = try encoder.encode(playlist)
        guard playlist.id.count <= 1000, payload.count <= 750_000 else { throw WaveError.message("This playlist is too large to sync. It remains saved on this iPhone.") }
        return AccountPlaylistRecord(id: playlist.id, payload: payload, cover: cover)
    }
}

// One private document per playlist, including a deletion tombstone. An empty
// installation never replaces the cloud library with an empty array.
@MainActor final class PlaylistCloudSync: ObservableObject {
    @Published private(set) var status = "Sign in to back up playlists"
    @Published private(set) var error: String?
    private let db = Firestore.firestore()
    private weak var player: WavePlayer?
    private var uid: String?
    private var listener: ListenerRegistration?
    private var writer: Task<Void, Never>?
    private var generation = UUID()
    private var baseline: [String: AccountPlaylistRecord] = [:]
    private var pending: [String: AccountPlaylistRecord] = [:]
    private var applying = false
    private var didBind = false
    private var sharedSources: [String: ImportedPlaylist] = [:]

    func observe(_ player: WavePlayer) {
        self.player = player
        player.playlistLibraryDidChange = { [weak self] in self?.localChanged() }
    }

    func bind(userID: String?) {
        guard !didBind || uid != userID else { return }
        // Auth starts nil while Firebase restores its session; keep the last
        // account's disk library until authentication identifies the owner.
        if !didBind && userID == nil { return }
        didBind = true
        if uid != nil { persistLocal() }
        generation = UUID(); writer?.cancel(); writer = nil; listener?.remove()
        uid = userID; error = nil; pending = [:]; baseline = [:]; sharedSources = [:]
        guard let player else { return }
        let defaults = UserDefaults.standard
        let previousOwner = defaults.string(forKey: "capyflow.library.owner")
        guard let userID else {
            applying = true
            player.restoreAccountPlaylists(read([ImportedPlaylist].self, key: "capyflow.library.guest") ?? [])
            applying = false
            defaults.set("guest", forKey: "capyflow.library.owner")
            status = "Sign in to back up playlists"
            return
        }
        // Migrate the pre-cloud, unscoped library only into the first account.
        let initial = read([ImportedPlaylist].self, key: localKey(userID))
            ?? ((previousOwner == nil || previousOwner == userID) ? player.playlists : [])
        applying = true; player.restoreAccountPlaylists(initial); applying = false
        defaults.set(userID, forKey: "capyflow.library.owner")
        pending = read([String: AccountPlaylistRecord].self, key: pendingKey(userID)) ?? [:]
        baseline = capture()
        // Migration runs once. Existing installs and offline edits are queued
        // durably before any server read, and cannot be overwritten by it.
        if !defaults.bool(forKey: "capyflow.library.migrated." + userID) {
            for (id, record) in baseline where pending[id] == nil { pending[id] = record }
            defaults.set(true, forKey: "capyflow.library.migrated." + userID)
        }
        persistLocal(); status = "Restoring account playlists…"
        let session = generation
        listener = collection(userID).addSnapshotListener(includeMetadataChanges: true) { [weak self] snapshot, failure in
            Task { @MainActor in
                guard let self, self.uid == userID, self.generation == session else { return }
                if let failure {
                    self.error = "Playlist backup could not sync: " + failure.localizedDescription
                    self.status = "Saved on this iPhone • backup needs attention"
                    return
                }
                guard let snapshot, !snapshot.metadata.hasPendingWrites else { return }
                self.apply(snapshot.documents)
                if self.pending.isEmpty {
                    self.error = nil
                    self.status = snapshot.metadata.isFromCache ? "Showing saved account playlists" : "Playlists backed up to your account"
                }
            }
        }
        flush()
    }

    // Shared documents are authoritative for linked playlists. Keep the same
    // source ID and artwork in the personal library and account backup.
    func applySharedPlaylists(_ shared: [SharedPlaylist], userID: String?) {
        guard let userID, uid == userID, let player else { return }
        sharedSources = [:]
        for playlist in shared {
            if let source = playlist.sourcePlaylist(for: userID) { sharedSources[source.id] = source }
        }
        let library = overlaySharedSources(on: player.playlists)
        let changed = library.count != player.playlists.count ||
            zip(library, player.playlists).contains { $0.id != $1.id || $0.name != $1.name || $0.tracks != $1.tracks }
        guard changed else { return }
        player.restoreAccountPlaylists(library)
        localChanged()
    }

    private func overlaySharedSources(on library: [ImportedPlaylist]) -> [ImportedPlaylist] {
        var result = library
        for source in sharedSources.values {
            if let index = result.firstIndex(where: { $0.id == source.id }) { result[index] = source }
            else { result.append(source) }
        }
        return result
    }

    func retry() { error = nil; flush(); if pending.isEmpty, let uid { let id = uid; self.uid = nil; bind(userID: id) } }

    private func collection(_ uid: String) -> CollectionReference {
        db.collection("users").document(uid).collection("library")
    }
    private func localKey(_ uid: String) -> String { "capyflow.library.local." + uid }
    private func pendingKey(_ uid: String) -> String { "capyflow.library.pending." + uid }
    private func read<T: Decodable>(_ type: T.Type, key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
    private func capture() -> [String: AccountPlaylistRecord] {
        guard let player else { return [:] }
        var result: [String: AccountPlaylistRecord] = [:]
        for playlist in player.playlists where !playlist.id.hasPrefix("cloud:") {
            do {
                let cover = player.playlistArtworkURL(for: playlist.id)
                    .flatMap { try? Data(contentsOf: $0) }.flatMap(Self.cloudCover)
                result[playlist.id] = try AccountPlaylistRecord.capture(playlist, cover: cover)
            } catch { self.error = error.localizedDescription }
        }
        return result
    }
    private static func cloudCover(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        if data.count <= 128_000 { return data }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let small = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 320), format: format).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: 320, height: 320))
        }
        return small.jpegData(compressionQuality: 0.7).flatMap { $0.count <= 128_000 ? $0 : nil }
    }
    private func localChanged() {
        guard !applying, let player else { return }
        guard uid != nil else {
            if UserDefaults.standard.string(forKey: "capyflow.library.owner") == "guest" {
                save(player.playlists, key: "capyflow.library.guest")
            }
            return
        }
        let current = capture()
        for (id, record) in current where baseline[id] != record { pending[id] = record }
        // Oversized records still exist locally and must never turn into deletes.
        let liveIDs = Set(player.playlists.map(\.id))
        for id in baseline.keys where !liveIDs.contains(id) {
            pending[id] = AccountPlaylistRecord(id: id, payload: nil, cover: nil)
        }
        baseline = current; persistLocal()
        if !pending.isEmpty { status = "Saved on this iPhone • syncing backup…"; flush() }
    }
    private func persistLocal() {
        guard let uid, let player else { return }
        save(player.playlists, key: localKey(uid)); save(pending, key: pendingKey(uid))
    }
    private func apply(_ documents: [QueryDocumentSnapshot]) {
        guard let player else { return }
        applying = true
        defer { applying = false }
        var library = player.playlists
        for doc in documents {
            let data = doc.data()
            guard let id = data["playlistID"] as? String,
                  doc.documentID == AccountPlaylistRecord.documentID(id), pending[id] == nil else { continue }
            if data["deleted"] as? Bool == true { library.removeAll { $0.id == id }; continue }
            guard let payload = data["payload"] as? Data,
                  let playlist = try? JSONDecoder().decode(ImportedPlaylist.self, from: payload), playlist.id == id else { continue }
            if let index = library.firstIndex(where: { $0.id == id }) { library[index] = playlist }
            else { library.append(playlist) }
            player.restoreAccountPlaylistArtwork(data["cover"] as? Data, for: id)
        }
        player.restoreAccountPlaylists(overlaySharedSources(on: library))
        baseline = capture(); persistLocal()
    }
    private func flush() {
        guard writer == nil, let uid, !pending.isEmpty else { return }
        let session = generation
        writer = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == session { self.writer = nil } }
            while !self.pending.isEmpty && self.uid == uid && self.generation == session && !Task.isCancelled {
                // Stay below Firestore's 10 MiB request limit even with covers.
                let outgoing = Dictionary(uniqueKeysWithValues: self.pending.prefix(10).map { ($0.key, $0.value) })
                let batch = self.db.batch()
                for (_, record) in outgoing {
                    var fields: [String: Any] = ["playlistID": record.id, "deleted": record.deleted, "updatedAt": FieldValue.serverTimestamp()]
                    if let payload = record.payload { fields["payload"] = payload }
                    if let cover = record.cover { fields["cover"] = cover }
                    batch.setData(fields, forDocument: self.collection(uid).document(AccountPlaylistRecord.documentID(record.id)))
                }
                do {
                    try await batch.commit()
                    guard self.uid == uid, self.generation == session else { return }
                    for (id, record) in outgoing where self.pending[id] == record { self.pending.removeValue(forKey: id) }
                    self.persistLocal(); self.error = nil
                    self.status = self.pending.isEmpty ? "Playlists backed up to your account" : "Syncing playlist backup…"
                } catch {
                    guard self.uid == uid, self.generation == session else { return }
                    self.error = "Playlist backup could not sync: " + error.localizedDescription
                    self.status = "Saved on this iPhone • backup needs attention"
                    return
                }
            }
        }
    }
}
