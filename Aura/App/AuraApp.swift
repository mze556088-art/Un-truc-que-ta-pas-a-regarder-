//  AuraApp.swift — point d'entrée, onglets, mini-lecteur
import SwiftUI

@main
struct AuraApp: App {
    @StateObject private var theme = ThemeStore()
    @StateObject private var library = LibraryStore()
    @StateObject private var engine = AudioEngine()
    @StateObject private var downloads = DownloadManager()
    @StateObject private var network = NetworkMonitor()
    @StateObject private var device = DeviceInfoModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(theme)
                .environmentObject(library)
                .environmentObject(engine)
                .environmentObject(downloads)
                .environmentObject(network)
                .environmentObject(device)
                .tint(theme.accent.color)
                .preferredColorScheme(theme.appearance.colorScheme)
                .task {
                    engine.attach(library)
                    downloads.attach(library)
                    device.start()
                }
                .onChange(of: scenePhase) { phase in
                    if phase != .active { library.saveNow() }
                    if phase == .background { downloads.appDidBackground() }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var engine: AudioEngine
    @State private var showPlayer = false

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView {
                LibraryView().tabItem { Label("Bibliothèque", systemImage: "music.note.house") }
                DiscoverView().tabItem { Label("Découverte", systemImage: "sparkles") }
                PlaylistsView().tabItem { Label("Playlists", systemImage: "music.note.list") }
                MyPhoneView().tabItem { Label("Mon iPhone", systemImage: "iphone") }
                SettingsView().tabItem { Label("Réglages", systemImage: "gearshape") }
            }
            if engine.current != nil {
                MiniPlayer { showPlayer = true }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 54)   // au-dessus de la barre d'onglets
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(AuraMotion.snappy, value: engine.current?.id)
        .sheet(isPresented: $showPlayer) { PlayerView() }
    }
}

struct MiniPlayer: View {
    @EnvironmentObject private var engine: AudioEngine
    @EnvironmentObject private var theme: ThemeStore
    var onTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ArtworkView(fileName: engine.current?.artworkName).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.current?.title ?? "").font(AuraFont.headline).lineLimit(1)
                    Text(engine.current?.artist ?? "").font(AuraFont.caption)
                        .foregroundStyle(AuraColor.textSecondary).lineLimit(1)
                }
                Spacer()
                Button { engine.toggle() } label: {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill").font(.title3).frame(width: 36, height: 36)
                }
                Button { engine.next() } label: { Image(systemName: "forward.fill").font(.body).frame(width: 36, height: 36) }
            }
            .padding(10)
            ProgressView(value: engine.currentTime, total: max(engine.duration, 1))
                .progressViewStyle(.linear).tint(theme.accent.color).padding(.horizontal, 10).padding(.bottom, 6)
        }
        .foregroundStyle(AuraColor.textPrimary)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: AuraRadius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: AuraRadius.m, style: .continuous).stroke(AuraColor.separator, lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .buttonStyle(AuraPressStyle())
    }
}
