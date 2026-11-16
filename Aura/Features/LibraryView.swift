//  LibraryView.swift — bibliothèque locale (liste / grille, recherche, filtres, import)
import SwiftUI
import UniformTypeIdentifiers

enum LibrarySort: String, CaseIterable, Identifiable {
    case recent = "Récents", title = "Titre", artist = "Artiste", plays = "Écoutes"
    var id: String { rawValue }
}

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var engine: AudioEngine
    @AppStorage("aura.libraryGrid") private var grid = false
    @State private var query = ""
    @State private var folder: String?
    @State private var tag: String?
    @State private var sort: LibrarySort = .recent
    @State private var showImporter = false
    @State private var editing: Track?

    private var filtered: [Track] {
        var r = library.tracks
        let q = query.searchNormalized.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            r = r.filter { "\($0.title) \($0.artist) \($0.album) \($0.tags.joined(separator: " "))".searchNormalized.contains(q) }
        }
        if let folder { r = r.filter { $0.folder == folder } }
        if let tag { r = r.filter { $0.tags.contains(tag) } }
        switch sort {
        case .recent: r.sort { $0.addedAt > $1.addedAt }
        case .title: r.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist: r.sort { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        case .plays: r.sort { $0.playCount > $1.playCount }
        }
        return r
    }

    private var audioTypes: [UTType] {
        [.audio, .folder] + ["flac", "m4a", "mp3", "wav", "aac"].compactMap { UTType(filenameExtension: $0) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if library.tracks.isEmpty { emptyState }
                else if grid { gridView } else { listView }
            }
            .background(AuraColor.background.ignoresSafeArea())
            .navigationTitle("Bibliothèque")
            .searchable(text: $query, prompt: "Titre, artiste, tag…")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Menu {
                        Picker("Tri", selection: $sort) { ForEach(LibrarySort.allCases) { Text($0.rawValue).tag($0) } }
                        if !library.folders.isEmpty {
                            Menu("Dossier") {
                                Button("Tous") { folder = nil }
                                ForEach(library.folders, id: \.self) { f in Button(f) { folder = f } }
                            }
                        }
                        if !library.allTags.isEmpty {
                            Menu("Tag") {
                                Button("Tous") { tag = nil }
                                ForEach(library.allTags, id: \.self) { t in Button("#\(t)") { tag = t } }
                            }
                        }
                    } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                    Button { withAnimation(AuraMotion.snappy) { grid.toggle() } } label: {
                        Image(systemName: grid ? "list.bullet" : "square.grid.2x2")
                    }
                    Button { showImporter = true } label: { Image(systemName: "plus.circle.fill") }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: audioTypes, allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { Task { await library.importFiles(urls) } }
            }
            .sheet(item: $editing) { TrackEditView(track: $0) }
            .overlay(alignment: .top) { toast }
            .miniPlayerInset()
        }
    }

    // MARK: Sous-vues
    private var listView: some View {
        let list = filtered
        return List {
            if folder != nil || tag != nil {
                Button("Retirer les filtres") { folder = nil; tag = nil }
            }
            ForEach(Array(list.enumerated()), id: \.element.id) { i, t in
                Button { engine.play(list, startAt: i) } label: { TrackRow(track: t) }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { engine.purge([t.id]); library.delete([t.id]) } label: { Label("Supprimer", systemImage: "trash") }
                    }
                    .swipeActions(edge: .leading) {
                        Button { engine.playNext(t); Haptics.tap() } label: { Label("Ensuite", systemImage: "text.insert") }.tint(.indigo)
                    }
                    .contextMenu { TrackMenuItems(track: t) { editing = t } }
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
    }

    private var gridView: some View {
        let list = filtered
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, t in
                    Button { engine.play(list, startAt: i) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            ArtworkView(fileName: t.artworkName, corner: AuraRadius.m)
                            Text(t.title).font(AuraFont.headline).lineLimit(1)
                            Text(t.artist).font(AuraFont.caption).foregroundStyle(AuraColor.textSecondary).lineLimit(1)
                        }
                    }
                    .buttonStyle(AuraPressStyle())
                    .foregroundStyle(AuraColor.textPrimary)
                    .contextMenu { TrackMenuItems(track: t) { editing = t } }
                }
            }.padding(16)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.house").font(.system(size: 54)).foregroundStyle(.tint)
            Text("Ta bibliothèque est vide").font(AuraFont.title)
            Text("Importe tes fichiers audio ou télécharge des titres depuis l'onglet Découverte.")
                .font(AuraFont.body).foregroundStyle(AuraColor.textSecondary).multilineTextAlignment(.center)
            Button { showImporter = true } label: { Label("Importer des fichiers", systemImage: "square.and.arrow.down") }
                .buttonStyle(.borderedProminent)
        }.padding(32)
    }

    @ViewBuilder private var toast: some View {
        if let m = library.importMessage {
            Text(m).font(AuraFont.caption).padding(.horizontal, 16).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule()).padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task { try? await Task.sleep(nanoseconds: 3_000_000_000); library.importMessage = nil }
        }
    }
}

struct TrackRow: View {
    let track: Track
    @EnvironmentObject private var engine: AudioEngine
    @EnvironmentObject private var theme: ThemeStore

    var body: some View {
        let isCurrent = engine.current?.id == track.id
        HStack(spacing: 12) {
            ArtworkView(fileName: track.artworkName).frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(AuraFont.headline).lineLimit(1)
                    .foregroundStyle(isCurrent ? theme.accent.color : AuraColor.textPrimary)
                Text(track.artist).font(AuraFont.caption).foregroundStyle(AuraColor.textSecondary).lineLimit(1)
            }
            Spacer()
            if isCurrent && engine.isPlaying { Image(systemName: "waveform").foregroundStyle(theme.accent.color) }
            if track.origin == .downloaded { Image(systemName: "arrow.down.circle.fill").foregroundStyle(AuraColor.textSecondary) }
            Text(Fmt.time(track.duration)).font(AuraFont.mono).foregroundStyle(AuraColor.textSecondary)
        }
        .contentShape(Rectangle())
    }
}

struct TrackMenuItems: View {
    let track: Track
    var onEdit: () -> Void
    @EnvironmentObject private var engine: AudioEngine
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        Button { engine.playNext(track) } label: { Label("Lire ensuite", systemImage: "text.insert") }
        Button { engine.enqueue(track) } label: { Label("Ajouter à la file", systemImage: "text.append") }
        Menu {
            ForEach(library.playlists) { p in Button(p.name) { library.add([track.id], to: p.id) } }
        } label: { Label("Ajouter à une playlist", systemImage: "music.note.list") }
        Button(action: onEdit) { Label("Modifier / notes", systemImage: "pencil") }
        Button(role: .destructive) { engine.purge([track.id]); library.delete([track.id]) } label: {
            Label("Supprimer", systemImage: "trash")
        }
    }
}

struct TrackEditView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Track
    @State private var tagsText: String

    init(track: Track) {
        _draft = State(initialValue: track)
        _tagsText = State(initialValue: track.tags.joined(separator: ", "))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Métadonnées") {
                    TextField("Titre", text: $draft.title)
                    TextField("Artiste", text: $draft.artist)
                    TextField("Album", text: $draft.album)
                    TextField("Genre", text: $draft.genre)
                    TextField("Dossier", text: $draft.folder)
                    TextField("Tags (séparés par des virgules)", text: $tagsText).textInputAutocapitalization(.never)
                }
                Section("Notes personnelles") {
                    TextEditor(text: $draft.notes).frame(minHeight: 120)
                }
                Section("Infos") {
                    LabeledContent("Durée", value: Fmt.time(draft.duration))
                    LabeledContent("Taille", value: Fmt.bytes(draft.fileSize))
                    LabeledContent("Écoutes", value: "\(draft.playCount)")
                }
            }
            .navigationTitle("Modifier")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        draft.tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        library.update(draft); Haptics.success(); dismiss()
                    }
                }
            }
        }
    }
}
