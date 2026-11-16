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
            if time.isNumeric { times.append(time) }
        }
        guard reader.status != .failed else { throw reader.error ?? TrenchesError.message("Временная шкала повреждена.") }
        times.sort { CMTimeCompare($0, $1) < 0 }
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

    func timeLabel(_ frame: Int) -> String {
        let seconds = max(0, times[min(frameCount - 1, max(0, frame))].seconds - times[0].seconds)
        return String(format: "%02d:%02d.%03d", Int(seconds) / 60, Int(seconds) % 60, Int(seconds * 1000) % 1000)
    }

    func reader(start: Int = 0, audioOnly: Bool = false) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        let reader = try AVAssetReader(asset: asset)
        guard let track = audioOnly ? audio : video else { throw TrenchesError.message("Звуковая дорожка отсутствует.") }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: audioOnly ? nil : [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw TrenchesError.message("Декодер видео недоступен.") }
        reader.add(output)
        if !audioOnly, start > 0 { reader.timeRange = CMTimeRange(start: times[start], end: duration) }
        guard reader.startReading() else { throw reader.error ?? TrenchesError.message("Не удалось запустить декодер.") }
        return (reader, output)
    }

    func renderSize(preview: Bool) -> (Int, Int) {
        let scale = preview ? min(1, 480 / max(size.width, size.height)) : 1
        return (max(2, Int(size.width * scale) / 2 * 2), max(2, Int(size.height * scale) / 2 * 2))
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

    func clear() {
        previewReader?.cancelReading(); previewReader = nil; previewOutput = nil
        previewRenderer = nil; previewDocument = nil; previewURL = nil; lastFrame = -2
        previewMovement = 0; previewSegmentID = nil
    }

    func preview(_ media: DatamoshMedia, document: DatamoshDocument, frame: Int, cancellation: DatamoshCancellation) throws -> (UIImage, Double) {
        try cancellation.check()
        var complete = false
        defer { if !complete { clear() } }
        if previewURL != media.url || previewDocument != document || lastFrame + 1 != frame {
            clear()
            let start = document.replayStart(for: frame)
            let (reader, output) = try media.reader(start: start)
            previewReader = reader; previewOutput = output
            let (w, h) = media.renderSize(preview: true)
            previewRenderer = try DatamoshRenderer(width: w, height: h, referenceWidth: Int(media.size.width), transform: media.transform)
            previewDocument = document; previewURL = media.url
        }
        guard let renderer = previewRenderer, let output = previewOutput else { throw TrenchesError.message("Превью недоступно.") }
        while let sample = output.copyNextSampleBuffer() {
            try cancellation.check()
            let index = media.frame(at: CMSampleBufferGetPresentationTimeStamp(sample))
            guard index <= frame, let input = CMSampleBufferGetImageBuffer(sample) else { break }
            let result = try autoreleasepool { try renderer.render(input, frame: index, document: document) }
            let id = document.segment(at: index)?.id
            if previewSegmentID != id { previewMovement = 0; previewSegmentID = id }
            previewMovement = max(previewMovement, renderer.movement)
            if index == frame {
                lastFrame = index
                let image = CIImage(cvPixelBuffer: result)
                guard let cg = renderer.context.createCGImage(image, from: image.extent) else { throw TrenchesError.message("Не удалось показать кадр.") }
                complete = true
                return (UIImage(cgImage: cg), previewMovement)
            }
        }
        if let error = previewReader?.error { throw error }
        throw TrenchesError.message("Не удалось прочитать выбранный кадр.")
    }

    static func thumbnails(_ media: DatamoshMedia, cancellation: DatamoshCancellation) async throws -> [DatamoshThumbnail] {
        let generator = AVAssetImageGenerator(asset: media.asset)
        generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 96, height: 144)
        var result: [DatamoshThumbnail] = []
        for frame in stride(from: 0, to: media.frameCount, by: max(1, (media.frameCount + 79) / 80)) {
            try cancellation.check()
            let resultImage = try await generator.image(at: media.times[frame])
            result.append(DatamoshThumbnail(frame: frame, image: UIImage(cgImage: resultImage.image)))
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
            let frame = media.frame(at: CMSampleBufferGetPresentationTimeStamp(sample))
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

    func export(_ media: DatamoshMedia, document: DatamoshDocument, preview: Bool, cancellation: DatamoshCancellation, progress: @escaping (Double) -> Void) throws -> URL {
        clear()
        let document = try document.validated(frameCount: media.frameCount)
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
            let pair = try media.reader(audioOnly: true); audioReader = pair.0; audioOutput = pair.1
        }
        let (reader, output) = try media.reader()
        defer { reader.cancelReading(); audioReader?.cancelReading() }
        let renderer = try DatamoshRenderer(width: w, height: h, referenceWidth: Int(media.size.width), transform: media.transform)
        guard writer.startWriting() else { throw writer.error ?? TrenchesError.message("Не удалось начать экспорт.") }
        writer.startSession(atSourceTime: media.times[0])
        var videoSample = output.copyNextSampleBuffer(), audioSample = audioOutput?.copyNextSampleBuffer()
        var videoFinished = false, audioFinished = audio == nil, lastProgress = -1
        var lastWork = Date()
        while !videoFinished || !audioFinished {
            try cancellation.check()
            guard writer.status == .writing else { throw writer.error ?? TrenchesError.message("Экспорт прерван кодировщиком.") }
            var worked = false
            if let sample = videoSample, video.isReadyForMoreMediaData {
                try autoreleasepool {
                    let time = CMSampleBufferGetPresentationTimeStamp(sample)
                    let frame = media.frame(at: time)
                    guard let buffer = CMSampleBufferGetImageBuffer(sample) else { throw TrenchesError.message("Декодер вернул пустой кадр.") }
                    let result = try renderer.render(buffer, frame: frame, document: document)
                    guard adaptor.append(result, withPresentationTime: time) else { throw writer.error ?? TrenchesError.message("Не удалось записать кадр Datamosh.") }
                    let percent = (frame + 1) * 100 / media.frameCount
                    if percent != lastProgress { lastProgress = percent; progress(Double(frame + 1) / Double(media.frameCount)) }
                }
                videoSample = output.copyNextSampleBuffer(); worked = true
            }
            if videoSample == nil, !videoFinished {
                if let error = reader.error { throw error }
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
        writer.endSession(atSourceTime: media.duration)
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        while finished.wait(timeout: .now() + 0.1) == .timedOut { try cancellation.check() }
        guard writer.status == .completed else { throw writer.error ?? TrenchesError.message("Не удалось завершить экспорт.") }
        success = true; progress(1)
        return url
    }
}
