//  PlaylistsView.swift — playlists : création, lecture, ajout, tri
import SwiftUI

struct PlaylistsView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var showNew = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(library.playlists) { p in
                    NavigationLink(value: p.id) {
                        HStack(spacing: 12) {
                            ArtworkView(fileName: library.tracks(in: p).first?.artworkName).frame(width: 52, height: 52)
                            VStack(alignment: .leading) {
                                Text(p.name).font(AuraFont.headline)
                                Text("\(p.trackIDs.count) titre\(p.trackIDs.count > 1 ? "s" : "")")
                                    .font(AuraFont.caption).foregroundStyle(AuraColor.textSecondary)
                            }
                        }
                    }.listRowBackground(Color.clear)
                }
                .onDelete { idx in
                    let ids = idx.map { library.playlists[$0].id }
                    ids.forEach { library.deletePlaylist($0) }
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .background(AuraColor.background.ignoresSafeArea())
            .overlay {
                if library.playlists.isEmpty {
                    Text("Crée ta première playlist avec le bouton +").font(AuraFont.body).foregroundStyle(AuraColor.textSecondary)
                }
            }
            .navigationTitle("Playlists")
            .navigationDestination(for: UUID.self) { PlaylistDetailView(playlistID: $0) }
            .toolbar { Button { showNew = true } label: { Image(systemName: "plus.circle.fill") } }
            .alert("Nouvelle playlist", isPresented: $showNew) {
                TextField("Nom", text: $newName)
                Button("Créer") { library.createPlaylist(named: newName); newName = "" }
                Button("Annuler", role: .cancel) { newName = "" }
            }
            .miniPlayerInset()
        }
    }
}

struct PlaylistDetailView: View {
    let playlistID: UUID
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var engine: AudioEngine
    @State private var showAdd = false

    private var playlist: Playlist? { library.playlists.first { $0.id == playlistID } }

    var body: some View {
        let tracks = playlist.map { library.tracks(in: $0) } ?? []
        List {
            HStack(spacing: 12) {
                Button { engine.play(tracks) } label: { Label("Lecture", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                Button { engine.play(tracks.shuffled()) } label: { Label("Aléatoire", systemImage: "shuffle").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
            }
            .disabled(tracks.isEmpty).listRowBackground(Color.clear)
            ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t in
                Button { engine.play(tracks, startAt: i) } label: { TrackRow(track: t) }
                    .buttonStyle(.plain).listRowBackground(Color.clear)
            }
            .onDelete { library.removeFromPlaylist(playlistID, at: $0) }
            .onMove { library.movePlaylistTracks(playlistID, from: $0, to: $1) }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .background(AuraColor.background.ignoresSafeArea())
        .navigationTitle(playlist?.name ?? "Playlist")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                EditButton()
                Button { showAdd = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showAdd) { AddTracksSheet(playlistID: playlistID) }
        .miniPlayerInset()
    }
}

struct AddTracksSheet: View {
    let playlistID: UUID
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var picked = Set<UUID>()
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(library.tracks.filter { query.isEmpty || $0.title.searchNormalized.contains(query.searchNormalized) || $0.artist.searchNormalized.contains(query.searchNormalized) }) { t in
                Button {
                    if picked.contains(t.id) { picked.remove(t.id) } else { picked.insert(t.id) }
                } label: {
                    HStack {
                        Image(systemName: picked.contains(t.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(.tint)
                        TrackRow(track: t)
                    }
                }.buttonStyle(.plain)
            }
            .searchable(text: $query)
            .navigationTitle("Ajouter des titres")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ajouter (\(picked.count))") {
                        library.add(library.tracks.map(\.id).filter { picked.contains($0) }, to: playlistID); dismiss()
                    }.disabled(picked.isEmpty)
                }
            }
        }
    }
}
