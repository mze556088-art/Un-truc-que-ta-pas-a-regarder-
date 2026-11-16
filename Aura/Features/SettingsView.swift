//  SettingsView.swift — réglages, sources du catalogue, stockage, statistiques, sauvegarde
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var library: LibraryStore
    @State private var exportURL: URL?
    @State private var showRestore = false
    @State private var info: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Apparence") {
                    HStack(spacing: 14) {
                        ForEach(AuraAccent.allCases) { a in
                            Circle().fill(a.color).frame(width: 34, height: 34)
                                .overlay(Circle().stroke(AuraColor.textPrimary, lineWidth: theme.accent == a ? 3 : 0))
                                .onTapGesture { withAnimation(AuraMotion.snappy) { theme.accent = a }; Haptics.tap() }
                        }
                    }.padding(.vertical, 4)
                    Picker("Mode", selection: $theme.appearance) {
                        ForEach(AuraAppearance.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented)
                }
                Section("Contenu") {
                    NavigationLink("Sources du catalogue") { SourcesView() }
                    NavigationLink("Stockage") { StorageView() }
                    NavigationLink("Statistiques d'écoute") { StatsView() }
                }
                Section("Sauvegarde") {
                    Button("Préparer l'export de la bibliothèque") { exportURL = try? library.exportBackup() }
                    if let url = exportURL { ShareLink(item: url) { Label("Partager la sauvegarde", systemImage: "square.and.arrow.up") } }
                    Button("Restaurer une sauvegarde") { showRestore = true }
                    if let info { Text(info).font(AuraFont.caption).foregroundStyle(AuraColor.textSecondary) }
                } footer: {
                    Text("La sauvegarde contient playlists, métadonnées, notes et sources. Les fichiers audio se trouvent dans Fichiers › Sur mon iPhone › Aura › Musique.")
                }
                Section("À propos") {
                    LabeledContent("Version", value: "1.0")
                    Text("Aucun compte, aucune pub, aucun suivi.").font(AuraFont.caption).foregroundStyle(AuraColor.textSecondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(AuraColor.background.ignoresSafeArea())
            .navigationTitle("Réglages")
            .fileImporter(isPresented: $showRestore, allowedContentTypes: [.json]) { result in
                if case .success(let url) = result {
                    do { try library.restoreBackup(from: url); info = "Sauvegarde restaurée." }
                    catch { info = "Fichier de sauvegarde invalide." }
                }
            }
            .miniPlayerInset()
        }
    }
}

struct SourcesView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var editing: CatalogSource?
    @State private var adding = false

    var body: some View {
        List {
            ForEach($library.sources) { $s in
                HStack {
                    VStack(alignment: .leading) {
                        Text(s.name).font(AuraFont.headline)
                        Text(s.urlString).font(AuraFont.caption).foregroundStyle(AuraColor.textSecondary).lineLimit(1)
                    }
                    Spacer()
                    Toggle("", isOn: $s.enabled).labelsHidden()
                }
                .contentShape(Rectangle())
                .onTapGesture { editing = s }
            }
            .onDelete { library.sources.remove(atOffsets: $0); library.save() }
            Section {} footer: {
                Text("JSON : une liste d'objets {title, artist, album, genre, duration, cover, url, popularity} (« url » obligatoire), ou { \"tracks\": [...] }. Dossier distant : une page d'index HTML listant des fichiers audio.")
            }
        }
        .navigationTitle("Sources")
        .toolbar { Button { adding = true } label: { Image(systemName: "plus") } }
        .sheet(isPresented: $adding) { SourceEditView(source: CatalogSource(name: "", urlString: "")) { library.sources.append($0); library.save() } }
        .sheet(item: $editing) { src in
            SourceEditView(source: src) { new in
                if let i = library.sources.firstIndex(where: { $0.id == new.id }) { library.sources[i] = new; library.save() }
            }
        }
    }
}

struct SourceEditView: View {
    @State var source: CatalogSource
    var onSave: (CatalogSource) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Nom", text: $source.name)
                TextField("https://…", text: $source.urlString)
                    .textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                Picker("Type", selection: $source.kind) { ForEach(CatalogSource.Kind.allCases) { Text($0.label).tag($0) } }
            }
            .navigationTitle("Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") { onSave(source); dismiss() }
                        .disabled(source.name.isEmpty || URL(string: source.urlString)?.scheme?.hasPrefix("http") != true)
                }
            }
        }
    }
}

struct StorageView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var engine: AudioEngine
    @State private var confirm = false

    var body: some View {
        List {
            Section("Utilisation") {
                LabeledContent("Total Aura", value: Fmt.bytes(library.auraBytes))
                LabeledContent("Téléchargés", value: Fmt.bytes(library.downloadedBytes))
                LabeledContent("Importés", value: Fmt.bytes(max(library.auraBytes - library.downloadedBytes, 0)))
                Button("Supprimer tous les téléchargements", role: .destructive) { confirm = true }
            }
            Section("Titres les plus volumineux") {
                ForEach(library.tracks.sorted { $0.fileSize > $1.fileSize }.prefix(20)) { t in
                    HStack {
                        Text(t.title).lineLimit(1); Spacer()
                        Text(Fmt.bytes(t.fileSize)).foregroundStyle(AuraColor.textSecondary)
                    }
                    .swipeActions { Button(role: .destructive) { engine.purge([t.id]); library.delete([t.id]) } label: { Label("Supprimer", systemImage: "trash") } }
                }
            }
        }
        .navigationTitle("Stockage")
        .task { library.refreshUsage() }
        .confirmationDialog("Supprimer tous les titres téléchargés ?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) {
                let ids = Set(library.tracks.filter { $0.origin == .downloaded }.map(\.id))
                engine.purge(ids); library.deleteDownloaded()
            }
        }
    }
}

struct StatsView: View {
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        let total = library.tracks.reduce(0) { $0 + $1.listenedSeconds }
        let plays = library.tracks.reduce(0) { $0 + $1.playCount }
        List {
            Section {
                LabeledContent("Temps d'écoute", value: Fmt.duration(total))
                LabeledContent("Écoutes", value: "\(plays)")
                LabeledContent("Titres", value: "\(library.tracks.count)")
            }
            Section("Les plus écoutés") {
                ForEach(library.tracks.filter { $0.playCount > 0 }.sorted { $0.playCount > $1.playCount }.prefix(10)) { t in
                    HStack {
                        VStack(alignment: .leading) { Text(t.title).lineLimit(1); Text(t.artist).font(AuraFont.caption).foregroundStyle(AuraColor.textSecondary) }
                        Spacer(); Text("\(t.playCount) ×").foregroundStyle(AuraColor.textSecondary)
                    }
                }
            }
        }.navigationTitle("Statistiques")
    }
}
