//  Utils.swift — chemins, formats, pochettes, réseau
import SwiftUI
import Network
import UIKit

enum AuraAudio {
    /// Extensions lisibles par AVFoundation
    static let extensions: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aif", "aiff", "caf", "alac", "mp4", "m4b"]
}

enum AuraPaths {
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    /// Visible dans l'app Fichiers (« Sur mon iPhone > Aura > Musique »)
    static var music: URL { dir(documents.appendingPathComponent("Musique", isDirectory: true)) }
    static var support: URL {
        dir(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aura", isDirectory: true))
    }
    static var artwork: URL { dir(support.appendingPathComponent("Pochettes", isDirectory: true)) }
    static var libraryFile: URL { support.appendingPathComponent("library.json") }

    @discardableResult
    static func dir(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

enum Fmt {
    static func time(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
    static func bytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
    static func duration(_ t: TimeInterval) -> String {
        let h = Int(t) / 3600, m = (Int(t) % 3600) / 60
        return h > 0 ? "\(h) h \(m) min" : "\(m) min"
    }
}

extension String {
    /// Minuscules sans accents, pour la recherche
    var searchNormalized: String { folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current) }
}

// MARK: - Pochettes

enum ArtworkCache {
    private static let cache = NSCache<NSString, UIImage>()
    static func image(named name: String) -> UIImage? {
        if let i = cache.object(forKey: name as NSString) { return i }
        guard let i = UIImage(contentsOfFile: AuraPaths.artwork.appendingPathComponent(name).path) else { return nil }
        cache.setObject(i, forKey: name as NSString)
        return i
    }
}

struct ArtworkView: View {
    var fileName: String?
    var remote: URL? = nil
    var corner: CGFloat = AuraRadius.s
    @EnvironmentObject private var theme: ThemeStore

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay(
                ZStack {
                    LinearGradient(colors: [theme.accent.color.opacity(0.65), AuraColor.surfaceRaised],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                    if let fileName, let img = ArtworkCache.image(named: fileName) {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else if let remote {
                        AsyncImage(url: remote) { phase in
                            if let image = phase.image { image.resizable().scaledToFill() }
                        }
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

// MARK: - Réseau

@MainActor
final class NetworkMonitor: ObservableObject {
    @Published private(set) var isOnline = true
    private let monitor = NWPathMonitor()
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            Task { @MainActor in self?.isOnline = ok }
        }
        monitor.start(queue: DispatchQueue(label: "aura.network"))
    }
}

// MARK: - Espace réservé au mini-lecteur

struct MiniPlayerInset: ViewModifier {
    @EnvironmentObject private var engine: AudioEngine
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: engine.current == nil ? 0 : 72)
        }
    }
}
extension View { func miniPlayerInset() -> some View { modifier(MiniPlayerInset()) } }
