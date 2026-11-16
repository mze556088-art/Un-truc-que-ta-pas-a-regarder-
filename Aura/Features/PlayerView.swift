//  PlayerView.swift — lecteur plein écran, file d'attente, égaliseur
import SwiftUI

struct PlayerView: View {
    @EnvironmentObject private var engine: AudioEngine
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.dismiss) private var dismiss
    @State private var scrubbing = false
    @State private var scrubValue = 0.0
    @State private var showQueue = false
    @State private var showEQ = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [theme.accent.color.opacity(0.35), AuraColor.background],
                           startPoint: .top, endPoint: .center).ignoresSafeArea()
            AuraColor.background.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 22) {
                header
                Spacer(minLength: 0)
                ArtworkView(fileName: engine.current?.artworkName, corner: AuraRadius.l)
                    .scaleEffect(engine.isPlaying ? 1 : 0.82)
                    .shadow(color: .black.opacity(engine.isPlaying ? 0.35 : 0.15), radius: engine.isPlaying ? 24 : 8, y: 12)
                    .animation(AuraMotion.smooth, value: engine.isPlaying)
                    .padding(.horizontal, 8)
                titleBlock
                seekBar
                controls
                bottomRow
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
        }
        .foregroundStyle(AuraColor.textPrimary)
        .sheet(isPresented: $showQueue) { QueueView() }
        .sheet(isPresented: $showEQ) { EqualizerView().presentationDetents([.medium]) }
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: { Image(systemName: "chevron.down").font(.title3) }
            Spacer()
            Text("Lecture en cours").font(AuraFont.caption).foregroundStyle(AuraColor.textSecondary)
            Spacer()
            Button { showQueue = true } label: { Image(systemName: "list.bullet").font(.title3) }
        }
    }

    private var titleBlock: some View {
        VStack(spacing: 4) {
            Text(engine.current?.title ?? "—").font(AuraFont.title).lineLimit(1)
            Text(engine.current?.artist ?? "").font(AuraFont.body).foregroundStyle(AuraColor.textSecondary).lineLimit(1)
            if let err = engine.lastError { Text(err).font(AuraFont.caption).foregroundStyle(AuraColor.danger) }
        }
    }

    private var seekBar: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(get: { scrubbing ? scrubValue : engine.currentTime }, set: { scrubValue = $0 }),
                in: 0...max(engine.duration, 1),
                onEditingChanged: { editing in
                    if editing { scrubValue = engine.currentTime; scrubbing = true }
                    else { engine.seek(to: scrubValue); scrubbing = false }
                }
            ).tint(theme.accent.color)
            HStack {
                Text(Fmt.time(scrubbing ? scrubValue : engine.currentTime))
                Spacer()
                Text("-" + Fmt.time(max(engine.duration - (scrubbing ? scrubValue : engine.currentTime), 0)))
            }.font(AuraFont.mono).foregroundStyle(AuraColor.textSecondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 36) {
            Button { engine.previous() } label: { Image(systemName: "backward.fill").font(.title) }
            Button { engine.toggle() } label: {
                Image(systemName: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 74))
                    .foregroundStyle(theme.accent.color)
            }
            Button { engine.next() } label: { Image(systemName: "forward.fill").font(.title) }
        }.buttonStyle(AuraPressStyle())
    }

    private var bottomRow: some View {
        HStack {
            Button { engine.shuffle.toggle() } label: {
                Image(systemName: "shuffle").foregroundStyle(engine.shuffle ? theme.accent.color : AuraColor.textSecondary)
            }
            Spacer()
            Menu {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                    Button("\(r.formatted())×") { engine.rate = Float(r) }
                }
            } label: { Text("\(Double(engine.rate).formatted())×").font(AuraFont.headline) }
            Spacer()
            Button { showEQ = true } label: { Image(systemName: "slider.vertical.3") }
            Spacer()
            Button {
                switch engine.repeatMode {
                case .off: engine.repeatMode = .all
                case .all: engine.repeatMode = .one
                case .one: engine.repeatMode = .off
                }
            } label: {
                Image(systemName: engine.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundStyle(engine.repeatMode == .off ? AuraColor.textSecondary : theme.accent.color)
            }
        }.font(.title3)
    }
}

struct QueueView: View {
    @EnvironmentObject private var engine: AudioEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(engine.queue.enumerated()), id: \.offset) { i, t in
                    Button { engine.jump(to: i) } label: {
                        HStack {
                            if i == engine.index { Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint) }
                            VStack(alignment: .leading) {
                                Text(t.title).font(AuraFont.headline).lineLimit(1)
                                Text(t.artist).font(AuraFont.caption).foregroundStyle(AuraColor.textSecondary)
                            }
                        }
                    }.buttonStyle(.plain)
                }
                .onDelete { engine.removeFromQueue(at: $0) }
                .onMove { engine.moveInQueue(from: $0, to: $1) }
            }
            .navigationTitle("File d'attente")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { EditButton() }
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
            }
        }
    }
}

struct EqualizerView: View {
    @EnvironmentObject private var engine: AudioEngine
    private let labels = ["60 Hz", "230 Hz", "910 Hz", "3,6 kHz", "14 kHz"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Égaliseur").font(AuraFont.title)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(AudioEngine.eqPresets, id: \.name) { p in
                        Button(p.name) { withAnimation(AuraMotion.snappy) { engine.eqGains = p.gains } }
                            .buttonStyle(.bordered)
                    }
                }
            }
            ForEach(0..<5, id: \.self) { i in
                HStack {
                    Text(labels[i]).font(AuraFont.mono).frame(width: 64, alignment: .leading)
                    Slider(value: Binding(get: { Double(engine.eqGains[i]) }, set: { engine.setGain(Float($0), band: i) }), in: -12...12)
                    Text("\(Int(engine.eqGains[i])) dB").font(AuraFont.mono).frame(width: 52, alignment: .trailing)
                }
            }
        }.padding(24)
    }
}
