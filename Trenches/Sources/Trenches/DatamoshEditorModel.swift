import AVKit
import Combine
import UIKit

@MainActor
final class DatamoshEditorModel: ObservableObject {
    let url: URL
    @Published private(set) var media: DatamoshMedia?
    @Published private(set) var document = DatamoshDocument()
    @Published private(set) var history = DatamoshHistory()
    @Published private(set) var thumbnails: [DatamoshThumbnail] = []
    @Published private(set) var image: UIImage?
    @Published private(set) var renderingPreview = false
    @Published var selectedID: UUID?
    @Published var frame = 0
    @Published var playing = false
    @Published var player: AVPlayer?
    @Published var zoom = 1.0
    @Published var error: String?
    @Published var notice: String?
    @Published private(set) var noMovement = false
    @Published private(set) var busy = false
    @Published private(set) var operationTitle = ""
    @Published private(set) var progress = 0.0
    @Published private(set) var exportedURL: URL?
    @Published private(set) var presets: [DatamoshPreset] = []
    private let worker = DatamoshWorker()
    private let lifetime = DatamoshCancellation()
    private var previewToken: DatamoshCancellation?
    private var operationToken: DatamoshCancellation?
    private var snapshotTask: Task<Void, Never>?
    private var playbackURL: URL?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var closed = false
    private var continuousOriginal: DatamoshDocument?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    init(url: URL) {
        self.url = url
        presets = UserDefaults.standard.data(forKey: "trenches.datamosh.presets.v1")
            .flatMap { try? JSONDecoder().decode([DatamoshPreset].self, from: $0) } ?? []
    }

    var selected: DatamoshSegment? { document.segments.first { $0.id == selectedID } }
    var frameCount: Int { media?.frameCount ?? 2 }
    private var draftURL: URL { url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".datamosh.json") }

    private func run<T>(_ operation: @escaping (DatamoshWorker) throws -> T) async throws -> T {
        let worker = worker
        return try await withCheckedThrowingContinuation { continuation in
            worker.queue.async { continuation.resume(with: Result { try operation(worker) }) }
        }
    }

    func load() async {
        guard media == nil, !closed else { return }
        busy = true; operationTitle = "Открываем видео"; progress = 0; operationToken = lifetime
        do {
            let url = url, token = lifetime
            let media = try await Task.detached(priority: .userInitiated) { try await DatamoshMedia.open(url, cancellation: token) }.value
            try token.check()
            self.media = media
            if let data = try? Data(contentsOf: draftURL), let draft = try? JSONDecoder().decode(DatamoshDocument.self, from: data) {
                do { document = try draft.validated(frameCount: media.frameCount) }
                catch { notice = "Сохранённые точки не подходят к этому видео. Открыт исходник." }
            }
            busy = false; operationToken = nil
            seek(0)
            let thumbnails = try await Task.detached(priority: .utility) { try await DatamoshWorker.thumbnails(media, cancellation: token) }.value
            try token.check(); self.thumbnails = thumbnails
        } catch is CancellationError { busy = false }
        catch { busy = false; self.error = error.localizedDescription }
    }

    func seek(_ target: Int) {
        guard !closed, !busy, let media else { return }
        pause()
        frame = min(media.frameCount - 1, max(0, target))
        requestPreview()
    }

    private func requestPreview() {
        guard !closed, let media else { return }
        previewToken?.cancel(); snapshotTask?.cancel()
        let token = DatamoshCancellation(); previewToken = token
        let document = document, frame = frame
        renderingPreview = true
        snapshotTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Coalesce touch updates; cancelled work exits between decoded frames.
                try await Task.sleep(for: .milliseconds(35))
                let result = try await run { try $0.preview(media, document: document, frame: frame, cancellation: token) }
                try token.check()
                self.image = result.0; self.renderingPreview = false
                self.noMovement = document.segment(at: frame).map { frame > $0.start + 1 && result.1 < 0.002 && $0.mode != .macroblock && $0.mode != .vector } ?? false
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, !self.closed, self.previewToken === token else { return }
                do { try token.check() } catch { return }
                self.renderingPreview = false; self.error = error.localizedDescription
            }
        }
    }

    private func change(_ operation: (inout DatamoshDocument) throws -> Void) {
        guard !busy, !closed else { return }
        do {
            var next = document
            try operation(&next)
            guard next != document else { return }
            if continuousOriginal == nil { history.record(document) }
            document = next; changed()
        } catch { self.error = error.localizedDescription }
    }

    func continuousEdit(_ editing: Bool) {
        if editing { continuousOriginal = document }
        else if let original = continuousOriginal {
            continuousOriginal = nil
            if original != document { history.record(original) }
        }
    }

    private func changed() {
        pause(); invalidatePlayback()
        do { try JSONEncoder().encode(document).write(to: draftURL, options: .atomic) }
        catch { self.error = "Не удалось сохранить точки: \(error.localizedDescription)" }
        if selected == nil { selectedID = nil }
        requestPreview()
    }

    func addPoint(at position: Int? = nil) {
        let start = min(frameCount - 1, max(0, position ?? frame))
        let end = min(frameCount, document.segments.filter { $0.start > start }.map(\.start).min() ?? frameCount)
        let segment = DatamoshSegment(start: start, duration: min(max(2, Int(media?.fps ?? 30)), end - start))
        change { try $0.put(segment, frameCount: frameCount) }
        if document.segments.contains(where: { $0.id == segment.id }) { selectedID = segment.id }
    }

    func update(_ segment: DatamoshSegment) { change { try $0.put(segment, frameCount: frameCount) } }
    func move(_ id: UUID, to start: Int) {
        guard var segment = document.segments.first(where: { $0.id == id }) else { return }
        segment.start = min(frameCount - segment.duration, max(0, start)); update(segment)
    }
    func resize(_ id: UUID, to end: Int) {
        guard var segment = document.segments.first(where: { $0.id == id }) else { return }
        segment.duration = max(2, min(frameCount, end) - segment.start); update(segment)
    }
    func remove(_ id: UUID) { change { $0.segments.removeAll { $0.id == id } } }
    func toggleReset(at position: Int? = nil) {
        let point = position ?? frame
        guard point < frameCount - 1 else { error = DatamoshEditError.lastFrame.localizedDescription; return }
        change { document in
            if document.resets.contains(point) { document.resets.removeAll { $0 == point } }
            else { document.resets.append(point); document.resets.sort() }
        }
    }
    func endHere() {
        guard var segment = selected else { return }
        segment.end = .keyframe; segment.duration = frame - segment.start
        update(segment)
    }
    func undo() {
        guard !busy, let previous = history.undo(document) else { return }
        document = previous; changed()
    }
    func redo() {
        guard !busy, let next = history.redo(document) else { return }
        document = next; changed()
    }

    func savePreset(_ name: String) {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !name.isEmpty else { return }
        presets.append(DatamoshPreset(name: name, frameCount: frameCount, document: document))
        persistPresets()
    }
    func removePreset(_ id: UUID) { presets.removeAll { $0.id == id }; persistPresets() }
    private func persistPresets() {
        do { UserDefaults.standard.set(try JSONEncoder().encode(presets), forKey: "trenches.datamosh.presets.v1") }
        catch { self.error = error.localizedDescription }
    }
    func apply(_ preset: DatamoshPreset) { change { $0 = try preset.applied(to: frameCount) } }

    func autoPoints() {
        guard let media, !busy else { return }
        pause(); previewToken?.cancel()
        let token = beginOperation("Ищем смены сцен и пики движения")
        Task {
            do {
                let points = try await run { try $0.autoPoints(media, cancellation: token) }
                try token.check(); busy = false
                var added = 0
                change { document in
                    for (index, start) in points.enumerated() {
                        let next = index + 1 < points.count ? points[index + 1] : frameCount
                        let duration = min(Int(media.fps), next - start, frameCount - start)
                        if duration >= 2, (try? document.put(DatamoshSegment(start: start, duration: duration), frameCount: frameCount)) != nil { added += 1 }
                    }
                }
                notice = added > 0 ? "Добавлено точек: \(added). Это предложения — их можно двигать, менять и удалять." : "Новых непересекающихся точек не найдено. Добавьте их вручную."
                endOperation()
            } catch { operationFailed(error) }
        }
    }

    private func beginOperation(_ title: String) -> DatamoshCancellation {
        previewToken?.cancel(); snapshotTask?.cancel(); renderingPreview = false
        let token = DatamoshCancellation(); operationToken = token
        busy = true; operationTitle = title; progress = 0
        return token
    }

    func togglePlayback() {
        if playing { pause(); requestPreview(); return }
        guard let media, !busy else { return }
        if document.segments.isEmpty { play(media.url); return }
        if let url = playbackURL { play(url); return }
        let token = beginOperation("Готовим превью со звуком")
        let document = document
        Task {
            do {
                let url = try await run { worker in
                    try worker.export(media, document: document, preview: true, cancellation: token) { value in Task { @MainActor in self.progress = value } }
                }
                do { try token.check() } catch { try? FileManager.default.removeItem(at: url); throw error }
                playbackURL = url; endOperation(); play(url)
            } catch { operationFailed(error) }
        }
    }

    private func play(_ url: URL) {
        guard !closed, let media else { return }
        pause()
        let player = AVPlayer(url: url)
        self.player = player
        let start = frame >= media.frameCount - 1 ? 0 : frame
        let time = CMTimeSubtract(media.times[start], media.times[0])
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            Task { @MainActor in guard let self, self.playing else { return }; self.frame = media.frame(at: CMTimeAdd(time, media.times[0])) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pause(); self?.requestPreview() }
        }
        playing = true; player.play()
    }

    func pause() {
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver); self.timeObserver = nil }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        playing = false; player = nil
    }
    private func invalidatePlayback() {
        if let playbackURL { try? FileManager.default.removeItem(at: playbackURL) }
        playbackURL = nil
    }

    func export(onSaved: @escaping (URL) -> Void) {
        guard let media, !busy else { return }
        pause()
        let token = beginOperation("Экспорт в исходном разрешении")
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Datamosh export") { token.cancel() }
        let document = document
        Task {
            do {
                let temporary = try await run { worker in
                    try worker.export(media, document: document, preview: false, cancellation: token) { value in Task { @MainActor in self.progress = value } }
                }
                defer { try? FileManager.default.removeItem(at: temporary) }
                try token.check()
                let destination = try CaptureLibrary.newURL(extension: "mov")
                try FileManager.default.moveItem(at: temporary, to: destination)
                exportedURL = destination; endOperation(); onSaved(destination)
                CaptureLibrary.saveToPhotos(destination) { message in Task { @MainActor in self.notice = message } }
            } catch { operationFailed(error) }
        }
    }

    func cancelOperation() { operationToken?.cancel() }
    private func endOperation() {
        busy = false; operationToken = nil
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
    }
    private func operationFailed(_ error: Error) {
        endOperation()
        if !(error is CancellationError), !closed { self.error = error.localizedDescription }
        if !closed { requestPreview() }
    }
    func close() {
        guard !closed else { return }
        closed = true; lifetime.cancel(); previewToken?.cancel(); operationToken?.cancel(); snapshotTask?.cancel()
        pause(); invalidatePlayback()
        let worker = worker
        worker.queue.async { worker.clear() }
    }
}
