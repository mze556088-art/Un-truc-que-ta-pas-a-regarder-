//  DownloadManager.swift — file d'attente : progression, pause, reprise, annulation
import Foundation
import UIKit

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    @Published private(set) var jobs: [DownloadJob] = []
    private var session: URLSession!
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    private var resumeData: [UUID: Data] = [:]
    private weak var library: LibraryStore?
    private let maxConcurrent = 3
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    func attach(_ library: LibraryStore) { self.library = library }

    var activeCount: Int { jobs.filter { $0.state == .queued || $0.state == .running || $0.state == .paused }.count }

    // MARK: Actions
    func enqueue(_ items: [CatalogItem]) {
        for item in items {
            if library?.downloadedSources.contains(item.id) == true { continue }
            if jobs.contains(where: { $0.item.id == item.id && $0.state != .failed && $0.state != .finished }) { continue }
            jobs.removeAll { $0.item.id == item.id }   // remplace un ancien échec
            jobs.append(DownloadJob(item: item))
        }
        pump()
    }

    func pause(_ id: UUID) {
        guard let t = tasks[id] else { set(id, .paused); return }
        t.cancel(byProducingResumeData: { data in
            Task { @MainActor in
                self.resumeData[id] = data
                self.tasks[id] = nil
                self.set(id, .paused)
                self.pump()
            }
        })
    }

    func resume(_ id: UUID) { set(id, .queued); pump() }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel(); tasks[id] = nil
        resumeData[id] = nil
        jobs.removeAll { $0.id == id }
        pump()
    }

    func pauseAll() { jobs.filter { $0.state == .running || $0.state == .queued }.forEach { pause($0.id) } }
    func resumeAll() { jobs.filter { $0.state == .paused || $0.state == .failed }.forEach { resume($0.id) } }
    func clearFinished() { jobs.removeAll { $0.state == .finished } }

    func job(for item: CatalogItem) -> DownloadJob? { jobs.first { $0.item.id == item.id } }

    func appDidBackground() {
        guard activeCount > 0, bgTask == .invalid else { return }
        bgTask = UIApplication.shared.beginBackgroundTask { [weak self] in self?.endBackground() }
    }
    private func endBackground() {
        if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid }
    }

    // MARK: Interne
    private func set(_ id: UUID, _ state: DownloadJob.State, progress: Double? = nil, error: String? = nil) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].state = state
        if let progress { jobs[i].progress = progress }
        jobs[i].error = error
    }

    private func pump() {
        var running = jobs.filter { $0.state == .running }.count
        for i in jobs.indices where jobs[i].state == .queued && running < maxConcurrent {
            let job = jobs[i]
            let task: URLSessionDownloadTask
            if let data = resumeData[job.id] {
                task = session.downloadTask(withResumeData: data); resumeData[job.id] = nil
            } else {
                task = session.downloadTask(with: job.item.downloadURL)
            }
            task.taskDescription = job.id.uuidString
            tasks[job.id] = task
            jobs[i].state = .running
            task.resume()
            running += 1
        }
        if activeCount == 0 { endBackground() }
    }

    fileprivate func progress(_ id: UUID, _ p: Double) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), p - jobs[i].progress >= 0.01 else { return }
        jobs[i].progress = p
    }

    fileprivate func fail(_ id: UUID, _ message: String) {
        tasks[id] = nil
        set(id, .failed, error: message)
        pump()
    }

    fileprivate func finish(_ id: UUID, file: URL, mime: String?) async {
        guard let job = jobs.first(where: { $0.id == id }) else { try? FileManager.default.removeItem(at: file); return }
        do {
            try await library?.addDownloaded(tempFile: file, item: job.item, ext: Self.ext(for: job.item.downloadURL, mime: mime))
            tasks[id] = nil
            set(id, .finished, progress: 1)
            Haptics.success()
        } catch {
            try? FileManager.default.removeItem(at: file)
            tasks[id] = nil
            set(id, .failed, error: error.localizedDescription)
        }
        pump()
    }

    private static func ext(for url: URL, mime: String?) -> String {
        let e = url.pathExtension.lowercased()
        if AuraAudio.extensions.contains(e) { return e }
        switch mime?.lowercased() {
        case "audio/flac", "audio/x-flac": return "flac"
        case "audio/wav", "audio/x-wav", "audio/wave": return "wav"
        case "audio/mp4", "audio/x-m4a", "audio/aac": return "m4a"
        default: return "mp3"
        }
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                                totalBytesWritten w: Int64, totalBytesExpectedToWrite t: Int64) {
        guard let id = downloadTask.taskDescription.flatMap(UUID.init(uuidString:)), t > 0 else { return }
        let p = Double(w) / Double(t)
        Task { @MainActor in self.progress(id, p) }
    }

    nonisolated func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let code = http.statusCode
            Task { @MainActor in self.fail(id, "Erreur serveur (\(code))") }
            return
        }
        // Le fichier temporaire est supprimé au retour : on le déplace tout de suite
        let stable = FileManager.default.temporaryDirectory.appendingPathComponent("aura-dl-\(id.uuidString)")
        try? FileManager.default.removeItem(at: stable)
        do { try FileManager.default.moveItem(at: location, to: stable) }
        catch { Task { @MainActor in self.fail(id, "Fichier temporaire introuvable") }; return }
        let mime = downloadTask.response?.mimeType
        Task { @MainActor in await self.finish(id, file: stable, mime: mime) }
    }

    nonisolated func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }   // pause / annulation volontaire
        let msg = error.localizedDescription
        Task { @MainActor in self.fail(id, msg) }
    }
}
