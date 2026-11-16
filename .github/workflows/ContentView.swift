import SwiftUI
import UniformTypeIdentifiers

struct ArtworkView: View {
    let image: UIImage?
    var radius: CGFloat = 8
    var icon: CGFloat = 20
    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [.pink.opacity(0.85), .purple.opacity(0.85)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: icon, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct ContentView: View {
    @StateObject private var p = Player()
    @State private var showPicker = false
    @State private var showFull = false
    @State private var search = ""

    var filtered: [Track] {
        search.isEmpty ? p.tracks : p.tracks.filter {
            $0.title.localizedCaseInsensitiveContains(search) || $0.artist.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            Group { p.tracks.isEmpty ? AnyView(empty) : AnyView(list) }
                .navigationTitle("Bibliothèque")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showPicker = true } label: { Image(systemName: "plus") }
                    }
                }
                .safeAreaInset(edge: .bottom) { if p.current != nil { miniPlayer } }
                .fileImporter(isPresented: $showPicker, allowedContentTypes: [.audio],
                              allowsMultipleSelection: true) { result in
                    if case .success(let urls) = result { p.importFiles(urls) }
                }
        }
        .tint(.pink)
        .sheet(isPresented: $showFull) { NowPlayingView(p: p) }
    }

    var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note.list").font(.system(size: 54)).foregroundStyle(.secondary)
            Text("Aucune musique").font(.title3.bold())
            Text("Ajoute des fichiers audio depuis ton iPhone.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button { showPicker = true } label: {
                Label("Ajouter des musiques", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 6)
        }
    }

    var list: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Button {
                        p.shuffle = false
                        if let f = p.tracks.first { p.play(f) }
                    } label: { Label("Lecture", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    Button {
                        p.shuffle = true
                        if let t = p.tracks.randomElement() { p.play(t) }
                    } label: { Label("Aléatoire", systemImage: "shuffle").frame(maxWidth: .infinity) }
                }
                .buttonStyle(.bordered).controlSize(.large)
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            Section {
                ForEach(filtered) { t in
                    Button { p.play(t) } label: { row(t) }.buttonStyle(.plain)
                }
                .onDelete { idx in idx.map { filtered[$0] }.forEach(p.delete) }
            } footer: {
                Text("\(p.tracks.count) titre\(p.tracks.count > 1 ? "s" : "")").padding(.top, 8)
            }
        }
        .listStyle(.plain)
        .searchable(text: $search, prompt: "Rechercher")
    }

    func row(_ t: Track) -> some View {
        let active = p.current == t
        return HStack(spacing: 12) {
            ArtworkView(image: t.artwork).frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(t.title).font(.body).lineLimit(1)
                    .foregroundStyle(active ? Color.pink : .primary)
                if !t.artist.isEmpty {
                    Text(t.artist).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if active { Image(systemName: p.isPlaying ? "waveform" : "pause.fill").foregroundStyle(.pink) }
        }
        .contentShape(Rectangle())
    }

    var miniPlayer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                ArtworkView(image: p.current?.artwork).frame(width: 44, height: 44)
                Text(p.current?.title ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { showFull = true }
            Button { p.toggle() } label: {
                Image(systemName: p.isPlaying ? "pause.fill" : "play.fill").font(.title3)
            }
            Button { p.next() } label: { Image(systemName: "forward.fill").font(.title3) }
        }
        .foregroundStyle(.primary)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 12).padding(.bottom, 4)
    }
}

struct NowPlayingView: View {
    @ObservedObject var p: Player

    func fmt(_ s: Double) -> String {
        let t = Int(max(s, 0)); return String(format: "%d:%02d", t / 60, t % 60)
    }

    var body: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 20)
            Color.clear.aspectRatio(1, contentMode: .fit)
                .overlay(ArtworkView(image: p.current?.artwork, radius: 22, icon: 70))
                .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
                .scaleEffect(p.isPlaying ? 1 : 0.86)
                .animation(.spring(response: 0.45, dampingFraction: 0.7), value: p.isPlaying)

            VStack(alignment: .leading, spacing: 4) {
                Text(p.current?.title ?? "").font(.title2.bold()).lineLimit(2)
                if let a = p.current?.artist, !a.isEmpty {
                    Text(a).font(.title3).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 4) {
                Slider(value: Binding(get: { p.time }, set: { p.seek($0) }), in: 0...max(p.duration, 1))
                HStack {
                    Text(fmt(p.time)); Spacer(); Text("-" + fmt(p.duration - p.time))
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }

            HStack {
                toggleButton("shuffle", on: p.shuffle) { p.shuffle.toggle() }
                Spacer()
                Button { p.previous() } label: { Image(systemName: "backward.fill").font(.system(size: 30)) }
                Spacer()
                Button { p.toggle() } label: {
                    Image(systemName: p.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 74))
                }
                Spacer()
                Button { p.next() } label: { Image(systemName: "forward.fill").font(.system(size: 30)) }
                Spacer()
                toggleButton("repeat.1", on: p.repeatOne) { p.repeatOne.toggle() }
            }
            .foregroundStyle(.white)
            Spacer(minLength: 20)
        }
        .padding(.horizontal, 28)
        .background {
            ZStack {
                Color.black
                if let img = p.current?.artwork {
                    Image(uiImage: img).resizable().scaledToFill().blur(radius: 70).opacity(0.55)
                } else {
                    LinearGradient(colors: [.pink.opacity(0.5), .purple.opacity(0.4), .black],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .ignoresSafeArea()
        }
        .tint(.white)
        .preferredColorScheme(.dark)
        .presentationDragIndicator(.visible)
    }

    func toggleButton(_ icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title3)
                .foregroundStyle(on ? Color.pink : .white.opacity(0.6))
        }
    }
}
