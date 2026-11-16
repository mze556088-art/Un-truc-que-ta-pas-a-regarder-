//  DiscoverView.swift — catalogue en ligne, recherche, filtres, téléchargements
import SwiftUI

enum DurationFilter: String, CaseIterable, Identifiable {
    case all = "Toutes durées", short = "< 3 min", medium = "3 – 6 min", long = "> 6 min"
    var id: String { rawValue }
    func matches(_ d: TimeInterval) -> Bool {
        guard d > 0 else { return self == .all }
        switch self {
        case .all: return true
        case .short: return d < 180
        case .medium: return d >= 180 && d <= 360
        case .long: return d > 360
        }
    }
}

enum CatalogSort: String, CaseIterable, Identifiable {
    case popularity = "Popularité", title = "Titre", duration = "Durée"
    var id: String { rawValue }
}

@MainActor
final class DiscoverModel: ObservableObject {
    @Published var items: [CatalogItem] = []
    @Published var loading = false
    @Published var errors: [String] = []
    @Published var genres: [String] = []

    func load(sources: [CatalogSource]) async {
        let active = sources.filter(\.enabled)
        guard !active.isEmpty else { items = []; genres = []; return }
        loading = true; errors = []
        var all: [CatalogItem] = []
        await withTaskGroup(of: (String, Result<[CatalogItem], Error>).self) { group in
            for s in active {
                group.addTask {
                    do { return (s.name, .success(try await CatalogClient.fetch(s))) }
                    catch { return (s.name, .failure(error)) }
                }
            }
            for await (name, res) in group {
                switch res {
                case .success(let i): all += i
                case .failure(let e): errors.append("\(name) : \(e.localizedDescription)")
                }
            }
        }
        var seen = Set<String>()
        items = all.filter { seen.insert($0.id).inserted }
        genres = Array(Set(items.map(\.genre).filter { !$0.isEmpty })).sorted()
        loading = false
    }
}

struct DiscoverView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var network: NetworkMonitor
    @StateObject private var model = DiscoverModel()
    @State private var query = ""
    @State private var genre: String?
    @State private var duration: DurationFilter = .all
    @State private var sort: CatalogSort = .popularity
    @State private var results: [CatalogItem] = []
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var showQueue = false
    @State private var confirmAll = false

    private struct FilterKey: Equatable { var q: String; var g: String?; var d: DurationFilter; var s: CatalogSort; var n: Int }

    var body: some View {
        NavigationStack {
            Group {
                if library.sources.isEmpty { message("Aucune source", "Ajoute une source dans Réglages › Sources du catalogue.", "link.badge.plus") }
                else if !network.isOnline && model.items.isEmpty { message("Hors ligne", "Ta bibliothèque reste disponible. Reconnecte-toi pour parcourir le catalogue.", "wifi.slash") }
                else { content }
            }
            .background(AuraColor.background.ignoresSafeArea())
            .navigationTitle("Découverte")
            .searchable(text: $query, prompt: "Rechercher dans le catalogue")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Menu {
                        Picker("Genre", selection: $genre) {
                            Text("Tous les genres").tag(String?.none)
                            ForEach(model.genres, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                        Picker("Durée", selection: $duration) { ForEach(DurationFilter.allCases) { Text($0.rawValue).tag($0) } }
                        Picker("Tri", selection: $sort) { ForEach(CatalogSort.allCases) { Text($0.rawValue).tag($0) } }
                    } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                    Button(selecting ? "OK" : "Sélection") { selecting.toggle(); selection = [] }
                    Button { showQueue = true } label: {
                        Image(systemName: "arrow.down.circle")
                            .overlay(alignment: .topTrailing) {
                                if downloads.activeCount > 0 {
                                    Text("\(downloads.activeCount)").font(.system(size: 10, weight: .bold)).padding(3)
                                        .background(Circle().fill(Color.red)).foregroundStyle(.white).offset(x: 8, y: -8)
                                }
                            }
                    }
                    Menu {
                        Button("Tout télécharger (\(results.count))") { confirmAll = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .refreshable { await model.load(sources: library.sources) }
            .task(id: network.isOnline) { if network.isOnline && model.items.isEmpty { await model.load(sources: library.sources) } }
            .onChange(of: library.sources) { _ in Task { await model.load(sources: library.sources) } }
            .task(id: FilterKey(q: query, g: genre, d: duration, s: sort, n: model.items.count)) {
                try? await Task.sleep(nanoseconds: 200_000_000)   // anti-rebond de la recherche
                if !Task.isCancelled { results = applyFilters() }
            }
            .safeAreaInset(edge: .bottom) {
                if selecting && !selection.isEmpty {
                    Button {
                        downloads.enqueue(results.filter { selection.contains($0.id) })
                        selecting = false; selection = []; Haptics.success()
                    } label: { Label("Télécharger (\(selection.count))", systemImage: "arrow.down.circle.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).controlSize(.large).padding().background(.ultraThinMaterial)
                } else { Color.clear.frame(height: 0) }
            }
            .confirmationDialog("Télécharger \(results.count) titres ?", isPresented: $confirmAll, titleVisibility: .visible) {
                Button("Tout télécharger") { downloads.enqueue(results); Haptics.success() }
            }
            .sheet(isPresented: $showQueue) { DownloadsView() }
            .miniPlayerInset()
        }
    }

    private var content: some View {
        List {
            if !model.errors.isEmpty {
                ForEach(model.errors, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(AuraFont.caption).foregroundStyle(AuraColor.danger) }
            }
            if model.loading && results.isEmpty { HStack { Spacer(); ProgressView(); Spacer() } }
            ForEach(results) { item in
                CatalogRow(item: item, selecting: selecting, selected: selection.contains(item.id))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if selecting {
                            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
                            Haptics.tap()
                        } else if !library.downloadedSources.contains(item.id) && downloads.job(for: item) == nil {
                            downloads.enqueue([item]); Haptics.tap()
                        }
                    }
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
    }

    private func applyFilters() -> [CatalogItem] {
        var r = model.items
        let q = query.searchNormalized.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { r = r.filter { $0.searchKey.contains(q) } }
        if let genre { r = r.filter { $0.genre == genre } }
        if duration != .all { r = r.filter { duration.matches($0.duration) } }
        switch sort {
        case .popularity: r.sort { $0.popularity > $1.popularity }
        case .title: r.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .duration: r.sort { $0.duration < $1.duration }
        }
        return r
    }

    private func message(_ title: String, _ text: String, _ icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 48)).foregroundStyle(.tint)
            Text(title).font(AuraFont.title)
            Text(text).font(AuraFont.body).foregroundStyle(AuraColor.textSecondary).multilineTextAlignment(.center)
        }.padding(32)
    }
}

struct CatalogRow: View {
    let item: CatalogItem
    let selecting: Bool
    let selected: Bool
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager

    var body: some View {
        HStack(spacing: 12) {
            if selecting { Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(.tint) }
            ArtworkView(fileName: nil, remote: item.coverURL).frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(AuraFont.headline).lineLimit(1)
                Text(item.artist).font(AuraFont.caption).foregroundStyle(AuraColor.textSecondary).lineLimit(1)
            }
            Spacer()
            if item.duration > 0 { Text(Fmt.time(item.duration)).font(AuraFont.mono).foregroundStyle(AuraColor.textSecondary) }
            status
        }
    }

    @ViewBuilder private var status: some View {
        if library.downloadedSources.contains(item.id) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if let job = downloads.job(for: item) {
            switch job.state {
            case .running: ProgressView(value: job.progress).progressViewStyle(.circular).frame(width: 22, height: 22)
            case .queued: Image(systemName: "clock").foregroundStyle(AuraColor.textSecondary)
            case .paused: Image(systemName: "pause.circle").foregroundStyle(AuraColor.textSecondary)
            case .failed: Image(systemName: "exclamationmark.circle").foregroundStyle(AuraColor.danger)
            case .finished: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        } else {
            Image(systemName: "arrow.down.circle").foregroundStyle(.tint)
        }
    }
}

struct DownloadsView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if downloads.jobs.isEmpty { Text("Aucun téléchargement en cours.").foregroundStyle(AuraColor.textSecondary) }
                ForEach(downloads.jobs) { job in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(job.item.title).font(AuraFont.headline).lineLimit(1)
                                Text(job.error ?? label(job.state)).font(AuraFont.caption)
                                    .foregroundStyle(job.state == .failed ? AuraColor.danger : AuraColor.textSecondary)
                            }
                            Spacer()
                            switch job.state {
                            case .running, .queued: Button { downloads.pause(job.id) } label: { Image(systemName: "pause.fill") }
                            case .paused, .failed: Button { downloads.resume(job.id) } label: { Image(systemName: "play.fill") }
                            case .finished: Image(systemName: "checkmark").foregroundStyle(.green)
                            }
                            Button(role: .destructive) { downloads.cancel(job.id) } label: { Image(systemName: "xmark") }
                        }.buttonStyle(.borderless)
                        if job.state != .finished { ProgressView(value: job.progress) }
                    }
                }
                Section("Stockage") {
                    LabeledContent("Téléchargements", value: Fmt.bytes(library.downloadedBytes))
                }
            }
            .navigationTitle("Téléchargements")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Button("Tout mettre en pause") { downloads.pauseAll() }
                        Button("Tout reprendre") { downloads.resumeAll() }
                        Button("Effacer les terminés") { downloads.clearFinished() }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
            }
        }
    }

    private func label(_ s: DownloadJob.State) -> String {
        switch s {
        case .queued: return "En attente"
        case .running: return "Téléchargement…"
        case .paused: return "En pause"
        case .finished: return "Terminé"
        case .failed: return "Échec"
        }
    }
}
