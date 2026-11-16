//  LibraryStore.swift — bibliothèque, playlists, import, métadonnées, sauvegarde
import Foundation
import AVFoundation
import UIKit

enum LibraryError: LocalizedError {
    case unsupported, duplicate, notAudio
    var errorDescription: String? {
        switch self {
        case .unsupported: return "Format non pris en charge"
        case .duplicate: return "Titre déjà présent"
        case .notAudio: return "Le fichier n'est pas un audio valide"
        }
    }
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var tracks: [Track] = [] { didSet { updateDownloadedSources() } }
    @Published private(set) var playlists: [Playlist] = []
    @Published var sources: [CatalogSource] = []
    @Published private(set) var lastSync: Date?
    @Published var importMessage: String?
    @Published private(set) var downloadedSources = Set<String>()
    @Published private(set) var auraBytes: Int64 = 0

    private struct Snapshot: Codable {
        var tracks: [Track]; var playlists: [Playlist]; var sources: [CatalogSource]; var lastSync: Date?
    }
    private var saveTask: Task<Void, Never>?

    init() { load(); updateDownloadedSources(); registerShared(); refreshUsage() }

    // MARK: Persistance
    private func load() {
        guard let data = try? Data(contentsOf: AuraPaths.libraryFile),
              let s = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        // On ignore les titres dont le fichier a disparu
        tracks = s.tracks.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
        playlists = s.playlists
        sources = s.sources
        lastSync = s.lastSync
    }

    func save() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        let snap = Snapshot(tracks: tracks, playlists: playlists, sources: sources, lastSync: lastSync)
        if let data = try? JSONEncoder().encode(snap) { try? data.write(to: AuraPaths.libraryFile, options: .atomic) }
    }

    private func updateDownloadedSources() { downloadedSources = Set(tracks.compactMap { $0.sourceURL }) }

    // MARK: Accès
    func track(_ id: UUID) -> Track? { tracks.first { $0.id == id } }
    func tracks(in p: Playlist) -> [Track] {
        let map = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return p.trackIDs.compactMap { map[$0] }
    }
    var downloadedBytes: Int64 { tracks.filter { $0.origin == .downloaded }.reduce(0) { $0 + $1.fileSize } }
    var folders: [String] { Array(Set(tracks.map(\.folder).filter { !$0.isEmpty })).sorted() }
    var allTags: [String] { Array(Set(tracks.flatMap(\.tags))).sorted() }

    // MARK: Édition
    func update(_ t: Track) {
        guard let i = tracks.firstIndex(where: { $0.id == t.id }) else { return }
        tracks[i] = t; save()
    }

    func recordListen(id: UUID, seconds: TimeInterval, countPlay: Bool) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[i].listenedSeconds += seconds
        if countPlay { tracks[i].playCount += 1 }
        save()
    }

    func delete(_ ids: Set<UUID>) {
        let removed = tracks.filter { ids.contains($0.id) }
        tracks.removeAll { ids.contains($0.id) }
        for t in removed {
            try? FileManager.default.removeItem(at: t.fileURL)
            if let a = t.artworkName, !tracks.contains(where: { $0.artworkName == a }) {
                try? FileManager.default.removeItem(at: AuraPaths.artwork.appendingPathComponent(a))
            }
        }
        for i in playlists.indices { playlists[i].trackIDs.removeAll { ids.contains($0) } }
        save(); refreshUsage()
    }

    func deleteDownloaded() { delete(Set(tracks.filter { $0.origin == .downloaded }.map(\.id))) }

    // MARK: Playlists
    func createPlaylist(named name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        playlists.append(Playlist(name: n)); save()
    }
    func deletePlaylist(_ id: UUID) { playlists.removeAll { $0.id == id }; save() }
    func add(_ ids: [UUID], to playlistID: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        for id in ids where !playlists[i].trackIDs.contains(id) { playlists[i].trackIDs.append(id) }
        save()
    }
    func removeFromPlaylist(_ playlistID: UUID, at offsets: IndexSet) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].trackIDs.remove(atOffsets: offsets); save()
    }
    func movePlaylistTracks(_ playlistID: UUID, from: IndexSet, to: Int) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].trackIDs.move(fromOffsets: from, toOffset: to); save()
    }

    // MARK: Import de fichiers (Fichiers, iCloud, dossiers…)
    func importFiles(_ urls: [URL]) async {
        var ok = 0, dup = 0, bad = 0
        for root in urls {
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            var files: [(URL, String)] = []
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue {
                let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                while let f = en?.nextObject() as? URL {
                    if AuraAudio.extensions.contains(f.pathExtension.lowercased()) {
                        files.append((f, root.lastPathComponent))
                    }
                }
            } else {
                files.append((root, ""))
            }
            for (url, folder) in files {
                do { try await ingest(url, folder: folder); ok += 1 }
                catch LibraryError.duplicate { dup += 1 }
                catch { bad += 1 }
            }
        }
        if ok > 0 { lastSync = Date() }
        var parts = ["\(ok) titre\(ok > 1 ? "s" : "") importé\(ok > 1 ? "s" : "")"]
        if dup > 0 { parts.append("\(dup) doublon\(dup > 1 ? "s" : "")") }
        if bad > 0 { parts.append("\(bad) échec\(bad > 1 ? "s" : "")") }
        importMessage = parts.joined(separator: " · ")
        save(); refreshUsage()
    }

    private func ingest(_ url: URL, folder: String) async throws {
        let ext = url.pathExtension.lowercased()
        guard AuraAudio.extensions.contains(ext) else { throw LibraryError.unsupported }
        let name = "\(UUID().uuidString).\(ext)"
        let dest = AuraPaths.music.appendingPathComponent(name)
        // Copie coordonnée (gère les fichiers iCloud non téléchargés), hors thread principal
        try await Task.detached(priority: .utility) { () throws -> Void in
            var coordErr: NSError?
            var copyErr: Error?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordErr) { u in
                do { try FileManager.default.copyItem(at: u, to: dest) } catch { copyErr = error }
            }
            if let e = coordErr ?? copyErr { throw e }
        }.value
        var t = await buildTrack(fileURL: dest, fileName: name, fallbackTitle: url.deletingPathExtension().lastPathComponent)
        guard t.duration > 0 else { try? FileManager.default.removeItem(at: dest); throw LibraryError.notAudio }
        if tracks.contains(where: { $0.title == t.title && $0.artist == t.artist && $0.fileSize == t.fileSize }) {
            try? FileManager.default.removeItem(at: dest); throw LibraryError.duplicate
        }
        t.folder = folder
        tracks.append(t)
    }

    /// Appelé par le DownloadManager une fois le fichier reçu
    func addDownloaded(tempFile: URL, item: CatalogItem, ext: String) async throws {
        let name = "\(UUID().uuidString).\(ext)"
        let dest = AuraPaths.music.appendingPathComponent(name)
        try FileManager.default.moveItem(at: tempFile, to: dest)
        var t = await buildTrack(fileURL: dest, fileName: name, fallbackTitle: item.title)
        guard t.duration > 0 else { try? FileManager.default.removeItem(at: dest); throw LibraryError.notAudio }
        if !item.title.isEmpty { t.title = item.title }
        if !item.artist.isEmpty, item.artist != "Artiste inconnu" { t.artist = item.artist }
        if !item.album.isEmpty { t.album = item.album }
        t.genre = item.genre
        t.origin = .downloaded
        t.sourceURL = item.downloadURL.absoluteString
        if t.artworkName == nil, let cover = item.coverURL,
           let (data, _) = try? await URLSession.shared.data(from: cover) {
            t.artworkName = Self.saveArtwork(data)
        }
        tracks.append(t)
        lastSync = Date()
        save(); refreshUsage()
    }

    // MARK: Métadonnées
    private struct Meta { var title: String?; var artist: String?; var album: String?; var duration: TimeInterval = 0; var artwork: Data? }

    private func buildTrack(fileURL: URL, fileName: String, fallbackTitle: String) async -> Track {
        let meta = await Self.readMetadata(fileURL)
        var title = meta.title ?? fallbackTitle
        var artist = meta.artist
        // « Artiste - Titre » dans le nom de fichier
        if meta.title == nil, meta.artist == nil, let r = fallbackTitle.range(of: " - ") {
            artist = String(fallbackTitle[..<r.lowerBound])
            title = String(fallbackTitle[r.upperBound...])
        }
        var t = Track(title: title, fileName: fileName)
        if let artist, !artist.isEmpty { t.artist = artist }
        t.album = meta.album ?? ""
        t.duration = meta.duration
        t.fileSize = Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        if let data = meta.artwork { t.artworkName = Self.saveArtwork(data) }
        return t
    }

    private nonisolated static func readMetadata(_ url: URL) async -> Meta {
        let asset = AVURLAsset(url: url)
        var m = Meta()
        if let d = try? await asset.load(.duration), d.seconds.isFinite { m.duration = d.seconds }
        if m.duration <= 0, let f = try? AVAudioFile(forReading: url) {
            m.duration = Double(f.length) / f.processingFormat.sampleRate
        }
        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                guard let key = item.commonKey else { continue }
                switch key {
                case .commonKeyTitle: m.title = try? await item.load(.stringValue)
                case .commonKeyArtist: m.artist = try? await item.load(.stringValue)
                case .commonKeyAlbumName: m.album = try? await item.load(.stringValue)
                case .commonKeyArtwork: m.artwork = try? await item.load(.dataValue)
                default: break
                }
            }
        }
        return m
    }

    static func saveArtwork(_ data: Data) -> String? {
        guard let img = UIImage(data: data), img.size.width > 0 else { return nil }
        let scale = min(1, 800 / max(img.size.width, img.size.height))
        let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        let jpeg = UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: 0.85) { _ in
            img.draw(in: CGRect(origin: .zero, size: size))
        }
        let name = "\(UUID().uuidString).jpg"
        do { try jpeg.write(to: AuraPaths.artwork.appendingPathComponent(name)); return name } catch { return nil }
    }

    // MARK: Stockage
    func refreshUsage() {
        Task.detached(priority: .utility) {
            let size = LibraryStore.folderSize(AuraPaths.music)
            await MainActor.run { LibraryStore.shared?.auraBytes = size }
        }
    }
    static weak var shared: LibraryStore?
    func registerShared() { LibraryStore.shared = self }

    nonisolated static func folderSize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        while let f = en?.nextObject() as? URL {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    // MARK: Sauvegarde / restauration (métadonnées, playlists, sources)
    func exportBackup() throws -> URL {
        saveNow()
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Aura-sauvegarde-\(f.string(from: Date())).json")
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let snap = Snapshot(tracks: tracks, playlists: playlists, sources: sources, lastSync: lastSync)
        try enc.encode(snap).write(to: url, options: .atomic)
        return url
    }

    func restoreBackup(from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let s = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
        var merged = tracks
        for t in s.tracks where FileManager.default.fileExists(atPath: t.fileURL.path) {
            if let i = merged.firstIndex(where: { $0.id == t.id }) { merged[i] = t } else { merged.append(t) }
        }
        tracks = merged
        playlists = s.playlists
        sources = s.sources
        saveNow()
    }
}
