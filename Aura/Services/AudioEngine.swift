//  AudioEngine.swift — lecteur robuste (AVAudioEngine + EQ + vitesse)
//  Gère : file d'attente, seek, boucle, aléatoire, interruptions (appels),
//  changements de sortie (casque débranché), lecture en arrière-plan,
//  Centre de contrôle / AirPods (MPRemoteCommandCenter).
import AVFoundation
import MediaPlayer
import Combine
import UIKit

enum RepeatMode: CaseIterable { case off, all, one }

@MainActor
final class AudioEngine: ObservableObject {
    // MARK: État publié
    @Published private(set) var queue: [Track] = []
    @Published private(set) var index = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var lastError: String?
    @Published var repeatMode: RepeatMode = .off
    @Published var shuffle = false
    @Published var rate: Float = 1.0 {
        didSet { timePitch.rate = rate; refreshNowPlaying() }
    }
    @Published var eqGains: [Float] = Array(repeating: 0, count: 5) {
        didSet { applyEQ() }
    }

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }

    static let eqFrequencies: [Float] = [60, 230, 910, 3600, 14000]
    static let eqPresets: [(name: String, gains: [Float])] = [
        ("Plat", [0, 0, 0, 0, 0]), ("Basses", [6, 4, 0, -1, -2]),
        ("Voix", [-2, 0, 4, 3, 0]), ("Aigus", [-2, -1, 0, 4, 6]), ("Soirée", [5, 2, -1, 2, 4])
    ]

    /// (id du titre, secondes écoutées, +1 écoute)
    var onListen: ((UUID, TimeInterval, Bool) -> Void)?

    // MARK: Interne
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let eq = AVAudioUnitEQ(numberOfBands: 5)
    private var file: AVAudioFile?
    private var connectedFormat: AVAudioFormat?
    private var generation = 0            // invalide les callbacks périmés après un seek
    private var segmentStart: TimeInterval = 0
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()
    private var listenAcc: TimeInterval = 0
    private var countedPlay = false
    private var resumeAfterInterruption = false
    private var artCache: (name: String, art: MPMediaItemArtwork)?

    init() {
        engine.attach(node); engine.attach(timePitch); engine.attach(eq)
        for (i, b) in eq.bands.enumerated() {
            b.filterType = .parametric
            b.frequency = Self.eqFrequencies[i]
            b.bandwidth = 1
            b.gain = 0
            b.bypass = false
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        setupRemote()
        observe()
    }

    func attach(_ library: LibraryStore) {
        onListen = { [weak library] id, secs, count in
            library?.recordListen(id: id, seconds: secs, countPlay: count)
        }
    }

    // MARK: API publique
    func play(_ tracks: [Track], startAt: Int = 0) {
        guard !tracks.isEmpty else { return }
        flushListening()
        queue = tracks
        index = min(max(startAt, 0), tracks.count - 1)
        loadCurrent(autoplay: true)
    }

    func play() {
        guard current != nil else { return }
        if file == nil { loadCurrent(autoplay: true) } else { startPlayback() }
    }

    func pause() {
        guard isPlaying else { return }
        if let t = capturedTime() { currentTime = min(max(t, 0), duration) }
        node.pause()
        isPlaying = false
        stopTimer()
        flushListening()
        refreshNowPlaying()
    }

    func toggle() { isPlaying ? pause() : play() }

    func next() {
        flushListening()
        guard let n = nextIndex(auto: false) else { return }
        index = n
        loadCurrent(autoplay: true)
    }

    func previous() {
        if currentTime > 3 { seek(to: 0); return }
        flushListening()
        index = index > 0 ? index - 1 : (repeatMode == .all ? queue.count - 1 : 0)
        loadCurrent(autoplay: true)
    }

    func jump(to i: Int) {
        guard queue.indices.contains(i) else { return }
        flushListening()
        index = i
        loadCurrent(autoplay: true)
    }

    func seek(to time: TimeInterval) {
        guard file != nil else { return }
        let t = min(max(time, 0), max(duration - 0.1, 0))
        let wasPlaying = isPlaying
        schedule(from: t)
        currentTime = t
        if wasPlaying { startPlayback() }
        refreshNowPlaying()
    }

    func playNext(_ t: Track) { if queue.isEmpty { play([t]) } else { queue.insert(t, at: index + 1) } }
    func enqueue(_ t: Track) { if queue.isEmpty { play([t]) } else { queue.append(t) } }

    func moveInQueue(from: IndexSet, to: Int) {
        let id = current?.id
        queue.move(fromOffsets: from, toOffset: to)
        if let id, let i = queue.firstIndex(where: { $0.id == id }) { index = i }
    }

    func removeFromQueue(at offsets: IndexSet) {
        guard !queue.isEmpty else { return }
        let removingCurrent = offsets.contains(index)
        let adjusted = index - offsets.filter { $0 < index }.count
        var newQueue = queue
        newQueue.remove(atOffsets: offsets)
        if removingCurrent { flushListening() }
        queue = newQueue
        if newQueue.isEmpty { stop(); return }
        index = min(adjusted, newQueue.count - 1)
        if removingCurrent { loadCurrent(autoplay: isPlaying) }
    }

    /// À appeler quand des titres sont supprimés de la bibliothèque
    func purge(_ ids: Set<UUID>) {
        let offsets = IndexSet(queue.indices.filter { ids.contains(queue[$0].id) })
        if !offsets.isEmpty { removeFromQueue(at: offsets) }
    }

    func setGain(_ gain: Float, band: Int) {
        guard eqGains.indices.contains(band) else { return }
        eqGains[band] = gain
    }

    func stop() {
        flushListening()
        node.stop()
        stopTimer()
        file = nil
        queue = []; index = 0
        isPlaying = false; currentTime = 0; duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Chargement & planification
    private func loadCurrent(autoplay: Bool, retries: Int = 0) {
        guard let track = current else { stop(); return }
        do {
            let f = try AVAudioFile(forReading: track.fileURL)
            file = f
            let d = Double(f.length) / f.processingFormat.sampleRate
            duration = d > 0 ? d : track.duration
            try AVAudioSession.sharedInstance().setActive(true)
            try prepareEngine(for: f.processingFormat)
            schedule(from: 0)
            currentTime = 0; listenAcc = 0; countedPlay = false
            lastError = nil
            if autoplay { startPlayback() } else { isPlaying = false; stopTimer() }
            refreshNowPlaying()
        } catch {
            lastError = "Lecture impossible : \(track.title)"
            file = nil
            // Passe au titre suivant pour ne jamais bloquer la file
            if retries < queue.count - 1, let n = nextIndex(auto: true), n != index {
                index = n
                loadCurrent(autoplay: autoplay, retries: retries + 1)
            } else {
                isPlaying = false; stopTimer()
            }
        }
    }

    private func prepareEngine(for format: AVAudioFormat) throws {
        if connectedFormat != format {
            node.stop()
            if engine.isRunning { engine.stop() }
            engine.disconnectNodeOutput(node)
            engine.disconnectNodeOutput(timePitch)
            engine.disconnectNodeOutput(eq)
            engine.connect(node, to: timePitch, format: format)
            engine.connect(timePitch, to: eq, format: format)
            engine.connect(eq, to: engine.mainMixerNode, format: format)
            connectedFormat = format
        }
        if !engine.isRunning { engine.prepare(); try engine.start() }
    }

    private func schedule(from time: TimeInterval) {
        guard let file else { return }
        generation += 1
        let gen = generation
        node.stop()
        let sr = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(max(0, time) * sr)
        let remaining = file.length - startFrame
        guard remaining > 0 else { return }
        segmentStart = Double(startFrame) / sr
        node.scheduleSegment(file, startingFrame: startFrame, frameCount: AVAudioFrameCount(remaining),
                             at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                self.trackFinished()
            }
        }
    }

    private func startPlayback() {
        guard let f = file else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try prepareEngine(for: f.processingFormat)
            node.play()
            isPlaying = true
            startTimer()
            refreshNowPlaying()
        } catch {
            lastError = "Moteur audio indisponible"
            isPlaying = false
        }
    }

    private func trackFinished() {
        if !countedPlay, let t = current { onListen?(t.id, 0, true); countedPlay = true }
        flushListening()
        if let n = nextIndex(auto: true) {
            index = n
            loadCurrent(autoplay: true)
        } else {
            // Fin de file : on se replace au début, en pause
            isPlaying = false
            stopTimer()
            schedule(from: 0)
            currentTime = 0
            refreshNowPlaying()
        }
    }

    private func nextIndex(auto: Bool) -> Int? {
        guard !queue.isEmpty else { return nil }
        if auto && repeatMode == .one { return index }
        if shuffle && queue.count > 1 {
            var i = index
            while i == index { i = Int.random(in: 0..<queue.count) }
            return i
        }
        if index + 1 < queue.count { return index + 1 }
        return (repeatMode == .all || !auto) ? 0 : nil
    }

    // MARK: Temps & statistiques
    private func capturedTime() -> TimeInterval? {
        guard let rt = node.lastRenderTime, let pt = node.playerTime(forNodeTime: rt), pt.sampleRate > 0 else { return nil }
        return segmentStart + Double(pt.sampleTime) / pt.sampleRate
    }

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    private func stopTimer() { timer?.invalidate(); timer = nil }

    private func tick() {
        guard isPlaying else { return }
        if let t = capturedTime() { currentTime = min(max(t, 0), duration) }
        listenAcc += 0.25
        if !countedPlay, listenAcc >= 15, let t = current {
            countedPlay = true
            onListen?(t.id, 0, true)
        }
    }

    private func flushListening() {
        if listenAcc > 0, let t = current { onListen?(t.id, listenAcc, false) }
        listenAcc = 0
    }

    private func applyEQ() {
        for (i, g) in eqGains.enumerated() where i < eq.bands.count { eq.bands[i].gain = g }
    }

    // MARK: Interruptions, sortie audio, reconfiguration
    private func observe() {
        let nc = NotificationCenter.default
        nc.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] n in self?.handleInterruption(n) }.store(in: &bag)
        nc.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] n in
                guard let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
                self?.pause()
            }.store(in: &bag)
        nc.publisher(for: .AVAudioEngineConfigurationChange, object: engine)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.file != nil else { return }
                self.connectedFormat = nil   // force la reconnexion du graphe
                let was = self.isPlaying
                self.recover(resume: was)
            }.store(in: &bag)
    }

    private func handleInterruption(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            resumeAfterInterruption = isPlaying
            pause()
        case .ended:
            let optRaw = n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            if resumeAfterInterruption, AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume) {
                recover(resume: true)
            }
            resumeAfterInterruption = false
        @unknown default: break
        }
    }

    /// Reconstruit le graphe audio et reprend à la position courante
    private func recover(resume: Bool) {
        guard let f = file else { return }
        do { try prepareEngine(for: f.processingFormat) } catch { return }
        schedule(from: currentTime)
        if resume { startPlayback() }
    }

    // MARK: Centre de contrôle / AirPods
    private func setupRemote() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.play() }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let p = e.positionTime
            Task { @MainActor in self?.seek(to: p) }
            return .success
        }
    }

    private func refreshNowPlaying() {
        guard let t = current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyAlbumTitle: t.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0.0
        ]
        if let name = t.artworkName {
            if artCache?.name != name, let img = ArtworkCache.image(named: name) {
                artCache = (name, MPMediaItemArtwork(boundsSize: img.size) { _ in img })
            }
            if let art = artCache?.art { info[MPMediaItemPropertyArtwork] = art }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        WidgetBridge.nowPlaying(title: t.title, artist: t.artist, playing: isPlaying)
    }
}
