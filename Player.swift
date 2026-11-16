import AVFoundation
import MediaPlayer
import UIKit

struct Track: Identifiable, Equatable {
    let url: URL
    var id: URL { url }
    var title: String
    var artist: String
    var artwork: UIImage?
    static func == (a: Track, b: Track) -> Bool { a.url == b.url }
}

final class Player: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var tracks: [Track] = []
    @Published var current: Track?
    @Published var isPlaying = false
    @Published var time: Double = 0
    @Published var duration: Double = 1
    @Published var shuffle = false
    @Published var repeatOne = false

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private let exts = ["mp3", "m4a", "wav", "aac", "flac", "aiff", "aif", "caf", "mp4", "alac"]

    override init() {
        super.init()
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        setupRemote()
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let p = self.player else { return }
            self.time = p.currentTime
        }
    }

    func reload() {
        let files = ((try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil)) ?? [])
            .filter { exts.contains($0.pathExtension.lowercased()) }
        Task {
            var result: [Track] = []
            for f in files { result.append(await Self.loadTrack(f)) }
            result.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            await MainActor.run { self.tracks = result }
        }
    }

    static func loadTrack(_ url: URL) async -> Track {
        var t = Track(url: url, title: url.deletingPathExtension().lastPathComponent, artist: "", artwork: nil)
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return t }
        for item in items {
            guard let key = item.commonKey else { continue }
            switch key {
            case .commonKeyTitle:
                if let v = try? await item.load(.stringValue), !v.isEmpty { t.title = v }
            case .commonKeyArtist:
                if let v = try? await item.load(.stringValue) { t.artist = v }
            case .commonKeyArtwork:
                if let d = try? await item.load(.dataValue) { t.artwork = UIImage(data: d) }
            default: break
            }
        }
        return t
    }

    func importFiles(_ urls: [URL]) {
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let dest = docs.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: url, to: dest)
        }
        reload()
    }

    func delete(_ track: Track) {
        if current == track { player?.stop(); player = nil; current = nil; isPlaying = false }
        try? FileManager.default.removeItem(at: track.url)
        tracks.removeAll { $0 == track }
    }

    func play(_ track: Track) {
        guard let p = try? AVAudioPlayer(contentsOf: track.url) else { return }
        p.delegate = self
        p.play()
        player = p
        current = track
        duration = max(p.duration, 1)
        time = 0
        isPlaying = true
        updateNowPlaying()
    }

    func toggle() {
        guard let p = player else { if let f = tracks.first { play(f) }; return }
        if p.isPlaying { p.pause() } else { p.play() }
        isPlaying = p.isPlaying
        updateNowPlaying()
    }

    func seek(_ t: Double) {
        player?.currentTime = t
        time = t
        updateNowPlaying()
    }

    func next() {
        guard !tracks.isEmpty else { return }
        if shuffle, let t = tracks.randomElement() { play(t); return }
        guard let c = current, let i = tracks.firstIndex(of: c) else { return }
        play(tracks[(i + 1) % tracks.count])
    }

    func previous() {
        guard let c = current, let i = tracks.firstIndex(of: c) else { return }
        if time > 3 { seek(0) } else { play(tracks[(i - 1 + tracks.count) % tracks.count]) }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if repeatOne, let c = current { play(c) } else { next() }
    }

    private func updateNowPlaying() {
        guard let c = current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: c.title,
            MPMediaItemPropertyArtist: c.artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player?.currentTime ?? 0,
            MPNowPlayingInfoPropertyPlaybackRate: (player?.isPlaying ?? false) ? 1.0 : 0.0
        ]
        if let img = c.artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setupRemote() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.toggle(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.toggle(); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
    }
}
