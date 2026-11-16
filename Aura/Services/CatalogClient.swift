//  CatalogClient.swift — lecture des sources du catalogue (JSON / API ou dossier HTML)
import Foundation

enum CatalogError: LocalizedError {
    case invalidURL, http(Int)
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "URL invalide"
        case .http(let c): return "Erreur serveur (\(c))"
        }
    }
}

enum CatalogClient {
    /// Format JSON accepté : [ {...} ] ou { "tracks": [ {...} ] } (ou "items")
    /// Champs : title, artist, album, genre, duration (s), cover, url (obligatoire), popularity
    private struct Raw: Decodable {
        let title: String?, artist: String?, album: String?, genre: String?
        let duration: Double?, cover: String?, url: String?, popularity: Int?
    }
    private struct Wrapper: Decodable { let tracks: [Raw]?; let items: [Raw]? }

    static func fetch(_ source: CatalogSource) async throws -> [CatalogItem] {
        let trimmed = source.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var base = URL(string: trimmed), base.scheme?.hasPrefix("http") == true else { throw CatalogError.invalidURL }
        var req = URLRequest(url: base)
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { throw CatalogError.http(h.statusCode) }
        switch source.kind {
        case .json:
            return try parseJSON(data, base: base, name: source.name)
        case .folder:
            if !base.absoluteString.hasSuffix("/"), let b = URL(string: base.absoluteString + "/") { base = b }
            return parseFolder(data, base: base, name: source.name)
        }
    }

    private static func parseJSON(_ data: Data, base: URL, name: String) throws -> [CatalogItem] {
        let dec = JSONDecoder()
        let raws: [Raw]
        if let arr = try? dec.decode([Raw].self, from: data) { raws = arr }
        else { let w = try dec.decode(Wrapper.self, from: data); raws = w.tracks ?? w.items ?? [] }
        return raws.compactMap { r in
            guard let u = r.url, let url = URL(string: u, relativeTo: base)?.absoluteURL else { return nil }
            let (a, t) = split(url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? "")
            return CatalogItem(
                title: r.title ?? t, artist: r.artist ?? a, album: r.album ?? "", genre: r.genre ?? "",
                duration: r.duration ?? 0,
                coverURL: r.cover.flatMap { URL(string: $0, relativeTo: base)?.absoluteURL },
                downloadURL: url, popularity: r.popularity ?? 0, sourceName: name)
        }
    }

    private static func parseFolder(_ data: Data, base: URL, name: String) -> [CatalogItem] {
        let html = String(decoding: data, as: UTF8.self)
        guard let re = try? NSRegularExpression(pattern: #"href\s*=\s*["']([^"']+)["']"#, options: [.caseInsensitive]) else { return [] }
        var seen = Set<String>()
        var out: [CatalogItem] = []
        for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let r = Range(m.range(at: 1), in: html) else { continue }
            let href = String(html[r])
            guard !href.hasPrefix("?"), !href.hasPrefix("#"),
                  let url = URL(string: href, relativeTo: base)?.absoluteURL,
                  AuraAudio.extensions.contains(url.pathExtension.lowercased()),
                  seen.insert(url.absoluteString).inserted else { continue }
            let raw = (url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? "")
                .replacingOccurrences(of: "_", with: " ")
            let (a, t) = split(raw)
            out.append(CatalogItem(title: t, artist: a, downloadURL: url, sourceName: name))
        }
        return out
    }

    private static func split(_ s: String) -> (artist: String, title: String) {
        if let r = s.range(of: " - ") { return (String(s[..<r.lowerBound]), String(s[r.upperBound...])) }
        return ("Artiste inconnu", s)
    }
}
