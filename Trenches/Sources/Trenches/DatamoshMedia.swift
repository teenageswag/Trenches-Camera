import AVFoundation
import CoreImage
import UIKit

final class DatamoshMedia: @unchecked Sendable {
    let url: URL
    let asset: AVURLAsset
    let video: AVAssetTrack
    let audio: AVAssetTrack?
    let audioFormat: CMFormatDescription?
    let times: [CMTime]
    let duration: CMTime
    let size: CGSize
    let transform: CGAffineTransform
    var frameCount: Int { times.count }
    var seconds: Double { max(0, duration.seconds - (times.first?.seconds ?? 0)) }
    var fps: Double {
        guard times.count > 1 else { return 30 }
        return Double(times.count - 1) / (times.last!.seconds - times[0].seconds)
    }

    private init(url: URL, asset: AVURLAsset, video: AVAssetTrack, audio: AVAssetTrack?, audioFormat: CMFormatDescription?, times: [CMTime], duration: CMTime, size: CGSize, transform: CGAffineTransform) {
        self.url = url; self.asset = asset; self.video = video; self.audio = audio; self.audioFormat = audioFormat
        self.times = times; self.duration = duration; self.size = size; self.transform = transform
    }

    static func open(_ url: URL, cancellation: DatamoshCancellation) async throws -> DatamoshMedia {
        let asset = AVURLAsset(url: url)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw TrenchesError.message("В файле нет видеодорожки.") }
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        let format = try await audio?.load(.formatDescriptions).first
        let natural = try await video.load(.naturalSize)
        let transform = try await video.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        let size = natural.applying(transform)
        guard duration.isNumeric, duration.seconds > 0, abs(size.width) >= 2, abs(size.height) >= 2 else { throw TrenchesError.message("Видео пустое или повреждено.") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        guard reader.canAdd(output) else { throw TrenchesError.message("Не удалось прочитать временную шкалу.") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? TrenchesError.message("Не удалось открыть видео.") }
        defer { reader.cancelReading() }
        var times: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() {
            try cancellation.check()
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            // Passthrough readers also return empty edit-list samples. They describe
            // timeline gaps, not displayable frames (often a second PTS=0 entry).
            if time.isNumeric, CMSampleBufferGetNumSamples(sample) > 0 { times.append(time) }
        }
        guard reader.status != .failed else { throw reader.error ?? TrenchesError.message("Временная шкала повреждена.") }
        times.sort { CMTimeCompare($0, $1) < 0 }
        var displayTimes: [CMTime] = []
        for time in times where displayTimes.last.map({ CMTimeCompare($0, time) != 0 }) ?? true { displayTimes.append(time) }
        times = displayTimes
        guard times.count >= 2 else { throw TrenchesError.message("Для Datamosh нужны минимум два кадра.") }
        return DatamoshMedia(url: url, asset: asset, video: video, audio: audio, audioFormat: format, times: times, duration: duration,
            size: CGSize(width: abs(size.width), height: abs(size.height)), transform: transform)
    }

    func frame(at time: CMTime) -> Int {
        var low = 0, high = times.count
        while low < high {
            let middle = (low + high) / 2
            if CMTimeCompare(times[middle], time) <= 0 { low = middle + 1 } else { high = middle }
        }
        return min(times.count - 1, max(0, low - 1))
    }

    func decodedFrame(at time: CMTime) -> Int {
        let before = frame(at: time)
        guard before + 1 < times.count else { return before }
        let earlier = abs(CMTimeSubtract(time, times[before]).seconds)
        let later = abs(CMTimeSubtract(times[before + 1], time).seconds)
        return later < earlier ? before + 1 : before
    }

    func timeLabel(_ frame: Int) -> String {
        let seconds = max(0, times[min(frameCount - 1, max(0, frame))].seconds - times[0].seconds)
        return String(format: "%02d:%02d.%03d", Int(seconds) / 60, Int(seconds) % 60, Int(seconds * 1000) % 1000)
    }

    func reader(start: Int = 0, audioOnly: Bool = false, timeRange: CMTimeRange? = nil) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        let reader = try AVAssetReader(asset: asset)
        guard let track = audioOnly ? audio : video else { throw TrenchesError.message("Звуковая дорожка отсутствует.") }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: audioOnly ? nil : [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw TrenchesError.message("Декодер видео недоступен.") }
        reader.add(output)
        if let timeRange { reader.timeRange = timeRange }
        else if !audioOnly, start > 0 { reader.timeRange = CMTimeRange(start: times[start], end: duration) }
        guard reader.startReading() else { throw reader.error ?? TrenchesError.message("Не удалось запустить декодер.") }
        return (reader, output)
    }

    func renderSize(preview: Bool) -> (Int, Int) {
        let scale = preview ? min(1, 720 / max(size.width, size.height)) : 1
        return (max(2, Int(size.width * scale) / 2 * 2), max(2, Int(size.height * scale) / 2 * 2))
    }

    func renderer(preview: Bool) throws -> DatamoshRenderer {
        let (width, height) = renderSize(preview: preview)
        return try DatamoshRenderer(width: width, height: height, referenceWidth: Int(size.width),
                                    referenceHeight: Int(size.height), transform: transform)
    }

    func donor(for frame: Int, document: DatamoshDocument, cancellation: DatamoshCancellation) throws -> CVPixelBuffer? {
        guard let segment = document.segment(at: frame), segment.start == frame, segment.mode == .transfer,
              segment.value("strength") > 0, !document.resets.contains(frame), let donor = segment.donorFrame else { return nil }
        let (reader, output) = try reader(start: max(0, donor - 2))
        defer { reader.cancelReading() }
        while let sample = output.copyNextSampleBuffer() {
            try cancellation.check()
            let index = decodedFrame(at: CMSampleBufferGetPresentationTimeStamp(sample))
            if index > donor { break }
            if index == donor, let buffer = CMSampleBufferGetImageBuffer(sample) { return buffer }
        }
        throw reader.error ?? TrenchesError.message("Не удалось прочитать кадр для переноса.")
    }
}

struct DatamoshThumbnail: Identifiable {
    let frame: Int
    let image: UIImage
    var id: Int { frame }
}

final class DatamoshWorker: @unchecked Sendable {
    let queue = DispatchQueue(label: "dev.trenches.datamosh", qos: .userInitiated)
    private var previewReader: AVAssetReader?
    private var previewOutput: AVAssetReaderTrackOutput?
    private var previewRenderer: DatamoshRenderer?
    private var previewDocument: DatamoshDocument?
    private var previewURL: URL?
    private var lastFrame = -2
    private var previewMovement = 0.0
    private var previewSegmentID: UUID?
    private var previewStart = 0
    private var previewImages: [Int: (UIImage, Double)] = [:]

    func clear() {
        resetPreview()
        previewRenderer = nil; previewDocument = nil; previewURL = nil; previewImages.removeAll()
    }

    private func resetPreview() {
        previewReader?.cancelReading(); previewReader = nil; previewOutput = nil
        previewRenderer?.reset(); lastFrame = -2
        previewMovement = 0; previewSegmentID = nil
    }

    func preview(_ media: DatamoshMedia, document: DatamoshDocument, frame: Int, cancellation: DatamoshCancellation) throws -> (UIImage, Double) {
        try cancellation.check()
        var complete = false
        defer { if !complete { resetPreview() } }
        if previewURL != media.url {
            clear()
            previewRenderer = try media.renderer(preview: true)
            previewURL = media.url
        }
        if previewDocument != document { previewImages.removeAll(); resetPreview(); previewDocument = document }
        if let image = previewImages[frame] { complete = true; return image }
        let replayStart = document.replayStart(for: frame)
        if previewOutput == nil || frame <= lastFrame || replayStart > lastFrame + 1 || frame - lastFrame > 120 {
            resetPreview()
            // Decode before the requested boundary: AVAssetReader may round a timeRange
            // start past the exact frame when the track uses a different time scale.
            let (reader, output) = try media.reader(start: max(0, replayStart - 2))
            previewStart = replayStart
            previewReader = reader; previewOutput = output
        }
        guard let renderer = previewRenderer, let output = previewOutput else { throw TrenchesError.message("Превью недоступно.") }
        var trace = ["requested=\(frame), count=\(media.frameCount), replayStart=\(previewStart), last=\(lastFrame)",
            "targetTime=\(media.times[frame].seconds), first=\(media.times[0].seconds), end=\(media.times.last!.seconds), duration=\(media.duration.seconds)",
            "firstTimes=\(media.times.prefix(8).map { $0.seconds })"]
        while let sample = output.copyNextSampleBuffer() {
            try cancellation.check()
            let index = media.decodedFrame(at: CMSampleBufferGetPresentationTimeStamp(sample))
            trace.append("decoded=\(index), pts=\(CMSampleBufferGetPresentationTimeStamp(sample).seconds), samples=\(CMSampleBufferGetNumSamples(sample)), image=\(CMSampleBufferGetImageBuffer(sample) != nil)")
            if trace.count > 24 { trace.remove(at: 3) }
            if index < previewStart || index <= lastFrame { continue }
            guard let input = CMSampleBufferGetImageBuffer(sample) else { continue }
            guard index <= frame else { break }
            let result = try autoreleasepool {
                let donor = try media.donor(for: index, document: document, cancellation: cancellation)
                return try renderer.render(input, frame: index, document: document, donor: donor)
            }
            lastFrame = index
            let id = document.segment(at: index)?.id
            if previewSegmentID != id { previewMovement = 0; previewSegmentID = id }
            previewMovement = max(previewMovement, renderer.movement)
            if index == frame {
                let image = CIImage(cvPixelBuffer: result)
                guard let cg = renderer.context.createCGImage(image, from: image.extent) else { throw TrenchesError.message("Не удалось показать кадр.") }
                let snapshot = (UIImage(cgImage: cg), previewMovement)
                if previewImages.count >= 12, let index = previewImages.keys.max(by: { abs($0 - frame) < abs($1 - frame) }) {
                    previewImages.removeValue(forKey: index)
                }
                previewImages[frame] = snapshot
                complete = true
                return snapshot
            }
        }
        try cancellation.check()
        trace.append("readerStatus=\(previewReader?.status.rawValue ?? -1), error=\(previewReader?.error?.localizedDescription ?? "none")")
        if let directory = try? CaptureLibrary.directory().deletingLastPathComponent() {
            try? trace.joined(separator: "\n").write(to: directory.appendingPathComponent("datamosh-preview.txt"), atomically: true, encoding: .utf8)
        }
        if let error = previewReader?.error { throw error }
        throw TrenchesError.message("Не удалось прочитать выбранный кадр.")
    }

    static func thumbnails(_ media: DatamoshMedia, cancellation: DatamoshCancellation) async throws -> [DatamoshThumbnail] {
        let generator = AVAssetImageGenerator(asset: media.asset)
        generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 96, height: 144)
        let tolerance = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        var result: [DatamoshThumbnail] = []
        for frame in stride(from: 0, to: media.frameCount, by: max(1, (media.frameCount + 79) / 80)) {
            try cancellation.check()
            if let resultImage = try? await generator.image(at: media.times[frame]) {
                result.append(DatamoshThumbnail(frame: frame, image: UIImage(cgImage: resultImage.image)))
            }
        }
        return result
    }

    func autoPoints(_ media: DatamoshMedia, cancellation: DatamoshCancellation) throws -> [Int] {
        let (reader, output) = try media.reader()
        defer { reader.cancelReading() }
        let context = CIContext(options: [.cacheIntermediates: false])
        let w = 48, h = 48
        var previous: [UInt8]?, lastDifference = 0.0, points: [Int] = [], nextFrame = 0
        while let sample = output.copyNextSampleBuffer() {
            try cancellation.check()
            let frame = media.decodedFrame(at: CMSampleBufferGetPresentationTimeStamp(sample))
            guard frame >= nextFrame, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            nextFrame = frame + max(1, Int(media.fps / 8))
            let image = CIImage(cvPixelBuffer: buffer)
            let small = image.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / image.extent.width, y: CGFloat(h) / image.extent.height))
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            bytes.withUnsafeMutableBytes { context.render(small, toBitmap: $0.baseAddress!, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()) }
            if let previous {
                var difference = 0.0
                for i in stride(from: 0, to: bytes.count, by: 4) { difference += abs(Double(bytes[i]) - Double(previous[i])) + abs(Double(bytes[i + 1]) - Double(previous[i + 1])) + abs(Double(bytes[i + 2]) - Double(previous[i + 2])) }
                difference /= Double(w * h * 3 * 255)
                let sceneCut = difference > 0.24
                let motionPeak = difference > 0.07 && difference > lastDifference * 1.8
                if (sceneCut || motionPeak), frame < media.frameCount - 1, frame - (points.last ?? -Int(media.fps)) >= Int(media.fps * 0.7) { points.append(frame) }
                lastDifference = difference
            }
            previous = bytes
        }
        if let error = reader.error { throw error }
        return points
    }

    func export(_ media: DatamoshMedia, document: DatamoshDocument, preview: Bool, frames: Range<Int>? = nil,
                cancellation: DatamoshCancellation, progress: @escaping (Double) -> Void) throws -> URL {
        if !preview { clear() }
        let document = try document.validated(frameCount: media.frameCount)
        let visible = frames ?? (0..<media.frameCount)
        guard !visible.isEmpty, visible.lowerBound >= 0, visible.upperBound <= media.frameCount else { throw DatamoshEditError.invalidRange }
        let startTime = media.times[visible.lowerBound]
        let endTime = visible.upperBound < media.frameCount ? media.times[visible.upperBound] : media.duration
        let decodeStart = document.replayStart(for: visible.lowerBound)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("datamosh-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var success = false
        defer { if !success { writer.cancelWriting(); try? FileManager.default.removeItem(at: url) } }
        let (w, h) = media.renderSize(preview: preview)
        var settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: w * h * 8, AVVideoAllowFrameReorderingKey: false]]
        if !writer.canApply(outputSettings: settings, forMediaType: .video) { settings[AVVideoCodecKey] = AVVideoCodecType.h264 }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(video) else { throw TrenchesError.message("Кодировщик Datamosh недоступен.") }
        writer.add(video)
        var audio: AVAssetWriterInput?
        var audioReader: AVAssetReader?, audioOutput: AVAssetReaderTrackOutput?
        if media.audio != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: media.audioFormat)
            guard writer.canAdd(input) else { throw TrenchesError.message("Невозможно скопировать исходную звуковую дорожку.") }
            writer.add(input); audio = input
            let range = frames.map { _ in CMTimeRange(start: startTime, end: endTime) }
            let pair = try media.reader(audioOnly: true, timeRange: range); audioReader = pair.0; audioOutput = pair.1
        }
        let (reader, output) = try media.reader(start: max(0, decodeStart - 2))
        defer { reader.cancelReading(); audioReader?.cancelReading() }
        let renderer = try media.renderer(preview: preview)
        guard writer.startWriting() else { throw writer.error ?? TrenchesError.message("Не удалось начать экспорт.") }
        writer.startSession(atSourceTime: startTime)
        var videoSample = output.copyNextSampleBuffer(), audioSample = audioOutput?.copyNextSampleBuffer()
        var videoFinished = false, audioFinished = audio == nil, lastProgress = -1
        var lastFrame = decodeStart - 1
        var lastWork = Date()
        while !videoFinished || !audioFinished {
            try cancellation.check()
            guard writer.status == .writing else { throw writer.error ?? TrenchesError.message("Экспорт прерван кодировщиком.") }
            var worked = false
            if let sample = videoSample, video.isReadyForMoreMediaData {
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                guard time.isNumeric, let buffer = CMSampleBufferGetImageBuffer(sample) else {
                    videoSample = output.copyNextSampleBuffer()
                    continue
                }
                let frame = media.decodedFrame(at: time)
                if frame >= visible.upperBound { videoSample = nil; continue }
                try autoreleasepool {
                    guard frame > lastFrame else { return }
                    guard frame == lastFrame + 1 else { throw TrenchesError.message("Декодер пропустил кадр \(lastFrame + 2) при экспорте.") }
                    let donor = try media.donor(for: frame, document: document, cancellation: cancellation)
                    let result = try renderer.render(buffer, frame: frame, document: document, donor: donor)
                    lastFrame = frame
                    guard visible.contains(frame) else { return }
                    guard adaptor.append(result, withPresentationTime: time) else { throw writer.error ?? TrenchesError.message("Не удалось записать кадр Datamosh.") }
                    let complete = Double(frame - visible.lowerBound + 1) / Double(visible.count)
                    let percent = Int(complete * 100)
                    if percent != lastProgress { lastProgress = percent; progress(complete) }
                }
                videoSample = output.copyNextSampleBuffer(); worked = true
            }
            if videoSample == nil, !videoFinished {
                if let error = reader.error { throw error }
                guard lastFrame == visible.upperBound - 1 else { throw TrenchesError.message("Декодер потерял часть кадров при экспорте.") }
                video.markAsFinished(); videoFinished = true; worked = true
            }
            if let sample = audioSample, let audio, audio.isReadyForMoreMediaData {
                guard audio.append(sample) else { throw writer.error ?? TrenchesError.message("Ошибка копирования звука.") }
                audioSample = audioOutput?.copyNextSampleBuffer(); worked = true
            }
            if audioSample == nil, !audioFinished {
                if let error = audioReader?.error { throw error }
                audio?.markAsFinished(); audioFinished = true; worked = true
            }
            if worked { lastWork = Date() }
            else {
                if Date().timeIntervalSince(lastWork) > 30 { throw TrenchesError.message("Кодировщик не отвечает. Экспорт остановлен.") }
                Thread.sleep(forTimeInterval: 0.002)
            }
        }
        writer.endSession(atSourceTime: endTime)
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        while finished.wait(timeout: .now() + 0.1) == .timedOut { try cancellation.check() }
        guard writer.status == .completed else { throw writer.error ?? TrenchesError.message("Не удалось завершить экспорт.") }
        success = true; progress(1)
        return url
    }
}
