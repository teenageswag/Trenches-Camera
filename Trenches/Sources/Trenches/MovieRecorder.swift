import AVFoundation

// All append/finish calls are serialized on CameraService.queue.
final class MovieRecorder {
    private let writer: AVAssetWriter
    private let appendVideoBuffer: (CVPixelBuffer, CMTime) throws -> Bool
    private let appendAudioSample: ((CMSampleBuffer) throws -> Bool)?
    private let finishInputs: () -> Void
    private var start: CMTime?
    private var lastVideo: CMTime?
    private let frameDuration: CMTime
    let url: URL
    private(set) var droppedFrames = 0
    private(set) var droppedAudioSamples = 0
    private(set) var frameCount = 0
    var recordedFrameRate: Double {
        guard let start, let lastVideo else { return 0 }
        let duration = CMTimeSubtract(CMTimeAdd(lastVideo, frameDuration), start).seconds
        return duration > 0 ? Double(frameCount) / duration : 0
    }

    init(width: Int, height: Int, fps: Int32, includeAudio: Bool) throws {
        url = try CaptureLibrary.newURL(extension: "mov")
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let bitrate = width * height * (fps > 30 ? 9 : 6)
        var videoSettings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate, AVVideoExpectedSourceFrameRateKey: fps, AVVideoAllowFrameReorderingKey: false]]
        if !writer.canApply(outputSettings: videoSettings, forMediaType: .video) { videoSettings[AVVideoCodecKey] = AVVideoCodecType.h264 }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        // Keep the encoder and A/V interleaver in capture mode, including with receivers.
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw TrenchesError.message("Кодировщик видео недоступен.") }
        let audio: AVAssetWriterInput?
        if includeAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128000])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw TrenchesError.message("Не удалось добавить звуковую дорожку.") }
            audio = input
        } else { audio = nil }

        // Capture only supported types in each branch; iOS 18 must never create receiver metadata.
        let outputWriter = writer
        if #available(iOS 26.0, *) {
            let videoReceiver = writer.inputPixelBufferReceiver(for: video, pixelBufferAttributes: nil)
            let audioReceiver = audio.map { outputWriter.inputReceiver(for: $0) }
            appendVideoBuffer = { buffer, time in
                try videoReceiver.appendImmediately(CVReadOnlyPixelBuffer(unsafeBuffer: buffer), with: time)
            }
            appendAudioSample = audioReceiver.map { receiver in
                { sample in try receiver.appendImmediately(CMReadySampleBuffer<CMSampleBuffer.DynamicContent>(unsafeBuffer: sample)) }
            }
            finishInputs = { videoReceiver.finish(); audioReceiver?.finish() }
        } else {
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
            writer.add(video)
            if let audio { writer.add(audio) }
            appendVideoBuffer = { buffer, time in
                guard video.isReadyForMoreMediaData else { return false }
                guard adaptor.append(buffer, withPresentationTime: time) else {
                    throw outputWriter.error ?? TrenchesError.message("Не удалось записать кадр.")
                }
                return true
            }
            appendAudioSample = audio.map { input in
                { sample in
                    guard input.isReadyForMoreMediaData else { return false }
                    guard input.append(sample) else { throw outputWriter.error ?? TrenchesError.message("Ошибка записи звука.") }
                    return true
                }
            }
            finishInputs = { video.markAsFinished(); audio?.markAsFinished() }
        }
        frameDuration = CMTime(value: 1, timescale: fps)
    }

    func appendVideo(_ buffer: CVPixelBuffer, at time: CMTime) throws {
        guard time.isValid, time.isNumeric else { return }
        if start == nil {
            if #available(iOS 26.0, *) { try writer.start() }
            else if !writer.startWriting() { throw writer.error ?? TrenchesError.message("Не удалось начать запись.") }
            writer.startSession(atSourceTime: time)
            start = time
        }
        guard writer.status == .writing else { throw writer.error ?? TrenchesError.message("Запись видео остановлена.") }
        if let lastVideo, CMTimeCompare(time, lastVideo) <= 0 { return }
        guard try appendVideoBuffer(buffer, time) else { droppedFrames += 1; return }
        lastVideo = time
        frameCount += 1
    }

    func appendAudio(_ sample: CMSampleBuffer) throws {
        guard let start, let appendAudioSample, writer.status == .writing else { return }
        guard CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), start) >= 0 else { return }
        guard CMSampleBufferDataIsReady(sample) else { return }
        if try !appendAudioSample(sample) { droppedAudioSamples += 1 }
    }

    func finish(_ completion: @escaping (Result<URL, Error>) -> Void) {
        guard let lastVideo, frameCount > 0, writer.status == .writing else {
            cancel()
            completion(.failure(TrenchesError.message("В записи нет кадров. Попробуйте ещё раз.")))
            return
        }
        writer.endSession(atSourceTime: CMTimeAdd(lastVideo, frameDuration))
        finishInputs()
        writer.finishWriting { [self] in
            if writer.status == .completed { completion(.success(url)) }
            else {
                let error = writer.error ?? TrenchesError.message("Не удалось завершить видео.")
                try? FileManager.default.removeItem(at: url)
                completion(.failure(error))
            }
        }
    }

    func cancel() {
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: url)
    }
}
