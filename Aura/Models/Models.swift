//  Models.swift — modèles de données (Codable, persistés en JSON)
import Foundation

struct Track: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var artist: String = "Artiste inconnu"
    var album: String = ""
    var genre: String = ""
    var duration: TimeInterval = 0
    var artworkName: String?          // relatif à Pochettes/
    var folder: String = ""           // dossier / collection
    var tags: [String] = []
    var notes: String = ""
    var addedAt = Date()
    var playCount = 0
    var listenedSeconds: TimeInterval = 0
    var fileSize: Int64 = 0
    var origin: Origin = .imported
    var sourceURL: String?            // URL d'origine si téléchargé
    var fileName: String              // relatif à Documents/Musique/

    enum Origin: String, Codable { case imported, downloaded }
    var fileURL: URL { AuraPaths.music.appendingPathComponent(fileName) }
}

struct Playlist: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var trackIDs: [UUID] = []
    var createdAt = Date()
}

struct CatalogSource: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var urlString: String
    var kind: Kind = .json
    var enabled = true

    enum Kind: String, Codable, CaseIterable, Identifiable {
        case json, folder
        var id: String { rawValue }
        var label: String { self == .json ? "Liste JSON / API" : "Dossier distant (index HTML)" }
    }
}

struct CatalogItem: Identifiable, Hashable, Sendable {
    var id: String { downloadURL.absoluteString }
    let title: String
    let artist: String
    let album: String
    let genre: String
    let duration: TimeInterval
    let coverURL: URL?
    let downloadURL: URL
    let popularity: Int
    let sourceName: String
    let searchKey: String

    init(title: String, artist: String, album: String = "", genre: String = "", duration: TimeInterval = 0,
         coverURL: URL? = nil, downloadURL: URL, popularity: Int = 0, sourceName: String) {
        self.title = title; self.artist = artist; self.album = album; self.genre = genre
        self.duration = duration; self.coverURL = coverURL; self.downloadURL = downloadURL
        self.popularity = popularity; self.sourceName = sourceName
        self.searchKey = "\(title) \(artist) \(album) \(genre)".searchNormalized
    }
}

struct DownloadJob: Identifiable {
    let id = UUID()
    let item: CatalogItem
    var state: State = .queued
    var progress: Double = 0
    var error: String?
    enum State { case queued, running, paused, finished, failed }
}
