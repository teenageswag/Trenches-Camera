import AVFoundation
import CoreImage
import ImageIO
import UIKit

struct CameraStatus {
    var running = false
    var depthAvailable = false
    var depthReceiving = false
    var lens: CameraLens = .wide
    var quality: CaptureQuality = .hd30
    var captureFPS: Int32 = 30
    var availableLenses: [CameraLens] = []
    var recording = false
    var finishing = false
    var photoBusy = false
    var fps = 0
    var droppedFrames = 0
    var audio = false
    var zoom = 1.0
    var minZoom = 1.0
    var maxZoom = 10.0
    var zoomStops: [Double] = [1, 2]
    var shutterSupported = false
    var shutterDuration: Double?
    var shutterNeedsCameraSwitch = false
}

final class CameraService: NSObject, @unchecked Sendable {
    let queue = DispatchQueue(label: "dev.trenches.capture", qos: .userInitiated)
    let preview = PreviewFrames()
    var onStatus: ((CameraStatus) -> Void)?
    var onError: ((String) -> Void)?
    var onSaved: ((URL, String) -> Void)?
    var onVideoRecorded: ((URL) -> Void)?
    private var session: AVCaptureSession?
    private var device: AVCaptureDevice?
    private var zoomObservation: NSKeyValueObservation?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var photoOutput: AVCapturePhotoOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var depthOutput: AVCaptureDepthDataOutput?
    private var synchronizer: AVCaptureDataOutputSynchronizer?
    private var renderer: FrameRenderer?
    private var recorder: MovieRecorder?
    private let audioDegrader = AudioDegrader()
    private let shutter = CameraShutter()
    private var failedShutterAngle: Float?
    private var shutterUsesPhysicalCamera = false
    private var settings = EffectSettings()
    private var status = CameraStatus()
    private var observers: [NSObjectProtocol] = []
    private var photoSettings: EffectSettings?
    private var photoTaskInFlight = false
    private var fpsStart = CACurrentMediaTime()
    private var fpsFrames = 0
    private var renderErrorReported = false
    private var desiredRunning = false
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var pendingVideoFrames = 0
    private var pendingRecordedFrames = 0
    private var renderDroppedFrames = 0
    private var sessionGeneration: UInt64 = 0
    private var nextSubmission: UInt64 = 0
    private var nextDelivery: UInt64 = 0
    private struct CompletedFrame {
        let result: Result<CVPixelBuffer, Error>
        let time: CMTime
        let depthReceived: Bool
        let generation: UInt64
        let recorder: MovieRecorder?
    }
    private var completedFrames: [UInt64: CompletedFrame] = [:]
    private var performanceRows: [String] = []

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    static func captureDevice(_ lens: CameraLens, depth: Bool) -> AVCaptureDevice? {
        switch lens {
        case .front: return AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        case .wide: return (depth ? AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) : nil) ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        case .ultraWide: return AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
        case .telephoto: return AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back)
        }
    }

    func start() {
        queue.async { [self] in
            desiredRunning = true
            do {
                if renderErrorReported { renderer = nil; renderErrorReported = false }
                if renderer == nil { renderer = try FrameRenderer() }
                if session == nil || shutterRequiresReconfiguration || status.audio != (AVCaptureDevice.authorizationStatus(for: .audio) == .authorized) { try configure(lens: status.lens, quality: status.quality, wantsDepth: settings.wantsDepth) }
                session?.startRunning()
                status.running = session?.isRunning == true
                refreshShutter()
                publish()
            } catch { fail(error) }
        }
    }

    func suspend() {
        queue.async { [self] in
            desiredRunning = false
            if recorder != nil { stopRecordingOwned() }
            if let device { try? shutter.restore(on: device) }
            session?.stopRunning()
            renderer = nil
            preview.clear()
            status.running = false
            publish()
        }
    }

    func update(_ newSettings: EffectSettings) {
        queue.async { [self] in
            let changedDepth = settings.wantsDepth != newSettings.wantsDepth
            if changedDepth && (status.recording || status.finishing || status.photoBusy) { return }
            let changedShutter = settings.shutterAngle != newSettings.shutterAngle
            if changedShutter { failedShutterAngle = nil }
            settings = newSettings
            if changedDepth || (changedShutter && shutterRequiresReconfiguration), session != nil {
                do { try configure(lens: status.lens, quality: status.quality, wantsDepth: settings.wantsDepth) }
                catch { fail(error) }
            } else if changedShutter {
                refreshShutter()
                publish()
            }
        }
    }

    func select(lens: CameraLens? = nil, quality: CaptureQuality? = nil) {
        queue.async { [self] in
            guard !status.recording, !status.finishing, !status.photoBusy else { return }
            do { try configure(lens: lens ?? status.lens, quality: quality ?? status.quality, wantsDepth: settings.wantsDepth) }
            catch { fail(error) }
        }
    }

    private func configure(lens: CameraLens, quality: CaptureQuality, wantsDepth: Bool) throws {
        let virtual = lens != .front && !wantsDepth ?
            (AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back) ??
             AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back) ??
             AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back)) : nil
        let needsPhysical = settings.shutterAngle > 0 && virtual?.isExposureModeSupported(.custom) == false
        // Rear virtual cameras may only support auto exposure. Switch inputs between recordings.
        guard let camera = (needsPhysical ? nil : virtual) ?? Self.captureDevice(lens, depth: wantsDepth) else {
            throw TrenchesError.message("Эта камера недоступна.")
        }
        let formats = camera.formats.filter {
            let dimensions = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return dimensions.width == quality.width && dimensions.height == quality.height && $0.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= Double(quality.fps) && $0.minFrameRate <= Double(quality.fps) }
        }
        // Prefer depth-compatible formats, then the smaller pixel encoding (420v).
        guard let format = formats.sorted(by: { ($0.supportedDepthDataFormats.isEmpty ? 1 : 0) < ($1.supportedDepthDataFormats.isEmpty ? 1 : 0) }).first else {
            throw TrenchesError.message("Режим \(quality.title) недоступен для выбранного объектива.")
        }
        let previousSession = session
        previousSession?.stopRunning()
        if let device { try? shutter.restore(on: device) }
        let newSession = AVCaptureSession()
        newSession.beginConfiguration()
        do {
            newSession.sessionPreset = .inputPriority
            let input = try AVCaptureDeviceInput(device: camera)
            guard newSession.canAddInput(input) else { throw TrenchesError.message("Не удалось подключить камеру.") }
            newSession.addInput(input)
            try camera.lockForConfiguration()
            camera.activeFormat = format
            let depthFormat = wantsDepth ? format.supportedDepthDataFormats.filter { CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat32 }.max { CMVideoFormatDescriptionGetDimensions($0.formatDescription).width < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width } : nil
            if let depthFormat { camera.activeDepthDataFormat = depthFormat }
            let depthMaxFPS = depthFormat?.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? Double(quality.fps)
            let actualFPS = min(quality.fps, Int32(depthMaxFPS))
            camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: actualFPS)
            camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: actualFPS)
            let multiplier = Double(camera.displayVideoZoomFactorMultiplier)
            let initialZoom = lens == status.lens && device != nil ? status.zoom : 1
            camera.videoZoomFactor = min(camera.maxAvailableVideoZoomFactor, max(camera.minAvailableVideoZoomFactor, CGFloat(initialZoom / multiplier)))
            camera.unlockForConfiguration()

            let video = AVCaptureVideoDataOutput()
            video.alwaysDiscardsLateVideoFrames = true
            guard newSession.canAddOutput(video) else { throw TrenchesError.message("Видеопоток недоступен.") }
            newSession.addOutput(video)
            let pixelFormat = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_32BGRA].first { video.availableVideoPixelFormatTypes.contains($0) } ?? kCVPixelFormatType_32BGRA
            video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
            orient(video.connection(with: .video), front: lens == .front)

            let photo = AVCapturePhotoOutput()
            guard newSession.canAddOutput(photo) else { throw TrenchesError.message("Фотосъёмка недоступна.") }
            newSession.addOutput(photo)
            if let dimensions = format.supportedMaxPhotoDimensions.filter({ Int64($0.width) * Int64($0.height) <= 13_000_000 }).last { photo.maxPhotoDimensions = dimensions }
            photo.maxPhotoQualityPrioritization = .balanced
            orient(photo.connection(with: .video), front: lens == .front)

            var depth: AVCaptureDepthDataOutput?
            var sync: AVCaptureDataOutputSynchronizer?
            if wantsDepth, depthFormat != nil {
                let output = AVCaptureDepthDataOutput()
                if newSession.canAddOutput(output) {
                    newSession.addOutput(output)
                    output.isFilteringEnabled = true
                    output.alwaysDiscardsLateDepthData = true
                    orient(output.connection(with: .depthData), front: lens == .front)
                    depth = output
                    if photo.isDepthDataDeliverySupported { photo.isDepthDataDeliveryEnabled = true }
                    sync = AVCaptureDataOutputSynchronizer(dataOutputs: [video, output])
                    sync?.setDelegate(self, queue: queue)
                }
            }
            if sync == nil { video.setSampleBufferDelegate(self, queue: queue) }
            var audio: AVCaptureAudioDataOutput?
            if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, let microphone = AVCaptureDevice.default(for: .audio), let audioInput = try? AVCaptureDeviceInput(device: microphone), newSession.canAddInput(audioInput) {
                newSession.addInput(audioInput)
                let output = AVCaptureAudioDataOutput()
                if newSession.canAddOutput(output) { newSession.addOutput(output); output.setSampleBufferDelegate(self, queue: queue); audio = output }
            }
            newSession.commitConfiguration()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            shutter.reset()
            failedShutterAngle = nil
            shutterUsesPhysicalCamera = needsPhysical
            session = newSession; device = camera
            status.minZoom = Double(camera.minAvailableVideoZoomFactor) * multiplier
            status.maxZoom = min(25, Double(camera.maxAvailableVideoZoomFactor) * multiplier)
            status.zoom = Double(camera.videoZoomFactor) * multiplier
            status.zoomStops = Array(Set(([status.minZoom, 1, 2] + camera.virtualDeviceSwitchOverVideoZoomFactors.map { $0.doubleValue * multiplier })
                .filter { $0 >= status.minZoom && $0 <= status.maxZoom })).sorted()
            zoomObservation = camera.observe(\.videoZoomFactor, options: [.new]) { [weak self] camera, _ in
                let zoom = Double(camera.videoZoomFactor * camera.displayVideoZoomFactorMultiplier)
                self?.queue.async { [weak self] in
                    guard let self, self.device === camera else { return }
                    self.status.zoom = zoom; self.publish()
                }
            }
            sessionGeneration &+= 1
            preview.clear()
            fpsStart = CACurrentMediaTime(); fpsFrames = 0; renderDroppedFrames = 0
            videoOutput = video; photoOutput = photo; audioOutput = audio; depthOutput = depth; synchronizer = sync
            status.lens = lens
            status.quality = quality
            status.captureFPS = actualFPS
            status.depthAvailable = depth != nil
            status.depthReceiving = false
            status.availableLenses = CameraLens.allCases.filter { Self.captureDevice($0, depth: false) != nil }
            status.audio = audio != nil
            renderErrorReported = false
            installObservers(newSession)
            if desiredRunning { newSession.startRunning() }
            status.running = newSession.isRunning
            refreshShutter()
            publish()
            if actualFPS < quality.fps { onError?("Для карты глубины камера переключена на \(actualFPS) к/с.") }
        } catch {
            newSession.commitConfiguration()
            if desiredRunning { previousSession?.startRunning() }
            throw error
        }
    }

    private func orient(_ connection: AVCaptureConnection?, front: Bool) {
        guard let connection else { return }
        if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        if connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = front }
    }

    private func installObservers(_ session: AVCaptureSession) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self else { return }
                if self.recorder != nil { self.stopRecordingOwned() }
                self.status.running = false; self.publish()
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in self?.startIfDesired() })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.queue.async { [weak self] in
                guard let self else { return }
                if self.recorder != nil { self.stopRecordingOwned() }
                self.status.running = false; self.publish()
                self.fail(error ?? TrenchesError.message("Ошибка камеры. Нажмите «Повторить»."))
            }
        })
    }

    private func startIfDesired() { queue.async { [weak self] in guard let self, self.desiredRunning else { return }; self.session?.startRunning(); self.status.running = self.session?.isRunning == true; self.refreshShutter(); self.publish() } }

    private var shutterRequiresReconfiguration: Bool {
        guard !status.recording, !status.finishing, !status.photoBusy, status.lens != .front, !settings.wantsDepth else { return false }
        if settings.shutterAngle > 0 { return device?.isVirtualDevice == true && device?.isExposureModeSupported(.custom) == false }
        return shutterUsesPhysicalCamera
    }

    private func refreshShutter() {
        let angle = settings.shutterAngle
        guard let device, status.running, !status.photoBusy, failedShutterAngle != angle else { return }
        do { try shutter.apply(to: device, angle: angle, fps: status.captureFPS, now: CACurrentMediaTime()) }
        catch { failedShutterAngle = angle; fail(error) }
    }

    private func shutterReport() -> String {
        guard let device else { return "Exposure unavailable" }
        return String(format: "Exposure %@ %.3f ms, ISO %.1f", device.exposureMode == .custom ? "custom" : "auto",
                      device.exposureDuration.seconds * 1000, device.iso)
    }

    func setZoom(_ zoom: Double, smoothly: Bool = false) {
        guard zoom.isFinite else { return }
        queue.async { [self] in
            guard let device, !status.finishing, !status.photoBusy else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                let displayZoom = min(status.maxZoom, max(status.minZoom, zoom))
                let factor = CGFloat(displayZoom) / device.displayVideoZoomFactorMultiplier
                device.cancelVideoZoomRamp()
                if smoothly { device.ramp(toVideoZoomFactor: factor, withRate: 4) }
                else { device.videoZoomFactor = factor }
            } catch { fail(error) }
        }
    }

    func focus(x: Float, y: Float) {
        queue.async { [self] in
            settings.focusX = min(1, max(0, x)); settings.focusY = min(1, max(0, y))
            guard let device else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                // Portrait output is rotated 90°. Capture focus coordinates remain sensor-native.
                let point = CGPoint(x: CGFloat(y), y: CGFloat(status.lens == .front ? x : 1 - x))
                if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = point; if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus } }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    if device.exposureMode != .custom, device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                }
            } catch { fail(error) }
        }
    }

    func capturePhoto() {
        queue.async { [self] in
            guard status.running, !status.recording, !status.finishing, !status.photoBusy, let photoOutput else { return }
            refreshShutter()
            let options = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            options.maxPhotoDimensions = photoOutput.maxPhotoDimensions
            options.photoQualityPrioritization = settings.shutterAngle > 0 && device?.exposureMode == .custom ? .speed : .balanced
            options.isDepthDataDeliveryEnabled = settings.wantsDepth && photoOutput.isDepthDataDeliveryEnabled
            options.isDepthDataFiltered = true
            photoSettings = settings
            status.photoBusy = true; photoTaskInFlight = false; publish()
            photoOutput.capturePhoto(with: options, delegate: self)
        }
    }

    func toggleRecording() {
        queue.async { [self] in
            if recorder != nil { stopRecordingOwned(); return }
            guard status.running, !status.finishing, !status.photoBusy, let buffer = preview.latest() else { return }
            do {
                recorder = try MovieRecorder(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer), fps: status.captureFPS, includeAudio: status.audio)
                audioDegrader.reset()
                performanceRows = ["Camera recording \(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer)), target \(status.captureFPS) FPS", "ASCII \(settings.enabled(.ascii)), cell \(settings.value(.ascii, "cell")), contrast \(settings.value(.ascii, "contrast"))", "audio \(status.audio)", shutterReport()]
                status.recording = true; publish()
            } catch { fail(error) }
        }
    }

    private func stopRecordingOwned() {
        guard recorder != nil, !status.finishing else { return }
        status.recording = false; status.finishing = true; publish()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish trenches capture") { [weak self] in self?.endBackgroundTask() }
        }
        finishRecordingIfReady()
    }

    private func finishRecordingIfReady() {
        guard status.finishing, pendingRecordedFrames == 0, let recorder else { return }
        self.recorder = nil
        performanceRows.append(String(format: "ENCODED %d frames, %.2f FPS, %d encoder drops, %d render drops, %d audio drops", recorder.frameCount, recorder.recordedFrameRate, recorder.droppedFrames, renderDroppedFrames, recorder.droppedAudioSamples))
        if let documents = try? CaptureLibrary.directory().deletingLastPathComponent() {
            try? performanceRows.joined(separator: "\n").write(to: documents.appendingPathComponent("camera-performance.txt"), atomically: true, encoding: .utf8)
        }
        recorder.finish { [weak self] result in
            guard let self else { return }
            self.queue.async {
                self.status.finishing = false; self.publish()
                switch result {
                case .success(let url): self.onVideoRecorded?(url); self.saved(url)
                case .failure(let error): self.fail(error)
                }
                DispatchQueue.main.async { self.endBackgroundTask() }
            }
        }
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
    }

    private func process(_ sample: CMSampleBuffer, depth: AVDepthData?) {
        guard let buffer = CMSampleBufferGetImageBuffer(sample), let renderer else { return }
        if settings.shutterAngle > 0 || device?.exposureMode == .custom { refreshShutter() }
        guard pendingVideoFrames < 3 else { renderDroppedFrames += 1; return }
        let sequence = nextSubmission
        nextSubmission &+= 1
        pendingVideoFrames += 1
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        let generation = sessionGeneration
        let targetRecorder = status.recording ? recorder : nil
        if targetRecorder != nil { pendingRecordedFrames += 1 }
        let complete: (Result<CVPixelBuffer, Error>) -> Void = { [weak self] result in
            guard let self else { return }
            self.queue.async {
                self.completedFrames[sequence] = CompletedFrame(result: result, time: time, depthReceived: depth != nil, generation: generation, recorder: targetRecorder)
                // GPU callbacks can arrive on different driver threads; preserve capture order.
                while let frame = self.completedFrames.removeValue(forKey: self.nextDelivery) {
                    self.nextDelivery &+= 1
                    self.deliver(frame)
                }
            }
        }
        do {
            try renderer.renderAsync(CIImage(cvPixelBuffer: buffer), depth: depth, settings: settings, time: time.seconds, completion: complete)
        } catch { complete(.failure(error)) }
    }

    private func deliver(_ frame: CompletedFrame) {
        pendingVideoFrames -= 1
        defer {
            if frame.recorder != nil { pendingRecordedFrames -= 1 }
            finishRecordingIfReady()
        }
        guard frame.generation == sessionGeneration else { return }
        if case .failure(FrameRenderer.RenderError.backPressure) = frame.result { renderDroppedFrames += 1; return }
        do {
            let processed = try frame.result.get()
            preview.set(processed)
            try frame.recorder?.appendVideo(processed, at: frame.time)
            fpsFrames += 1
            let now = CACurrentMediaTime()
            if now - fpsStart >= 1 {
                status.fps = Int((Double(fpsFrames) / (now - fpsStart)).rounded())
                status.depthReceiving = frame.depthReceived
                status.droppedFrames = renderDroppedFrames + (recorder?.droppedFrames ?? 0)
                if frame.recorder != nil, performanceRows.count < 120 { performanceRows.append("render \(status.fps) FPS, accepted \(frame.recorder?.frameCount ?? 0), drops \(status.droppedFrames), \(shutterReport())") }
                fpsStart = now; fpsFrames = 0; publish()
            }
        } catch {
            if recorder != nil { stopRecordingOwned() }
            if !renderErrorReported {
                renderErrorReported = true
                session?.stopRunning()
                status.running = false; publish(); fail(error)
            }
        }
    }

    private func saved(_ url: URL) {
        CaptureLibrary.saveToPhotos(url) { [weak self] message in self?.onSaved?(url, message) }
    }
    private func publish() {
        status.shutterSupported = device?.isExposureModeSupported(.custom) == true
        status.shutterDuration = status.running && device?.exposureMode == .custom ? device?.exposureDuration.seconds : nil
        status.shutterNeedsCameraSwitch = device?.isVirtualDevice == true && !status.shutterSupported && status.lens != .front && !settings.wantsDepth
        onStatus?(status)
    }
    private func fail(_ error: Error) { onError?(error.localizedDescription) }

    #if DEBUG
    static func verifyShutterHardware() async throws -> String {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return "SKIP camera shutter hardware / camera access" }
        let service = CameraService()
        service.start()
        defer { service.suspend() }

        func reach(angle: Float, expected: Double?) async throws -> String {
            var settings = EffectSettings()
            if angle > 0 { settings.toggle(.motion); settings.set(.motion, "shutter", angle) }
            service.update(settings)
            var report = "Camera not running"
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(200))
                let state: (running: Bool, custom: Bool, seconds: Double, autoISO: Bool, report: String) = await withCheckedContinuation { continuation in
                    service.queue.async {
                        let device = service.device
                        let autoISO = if #available(iOS 27, *) { device?.automaticallyAdjustsISO == true } else { false }
                        continuation.resume(returning: (service.status.running, device?.exposureMode == .custom,
                                                         device?.exposureDuration.seconds ?? 0, autoISO, service.shutterReport()))
                    }
                }
                report = state.report
                guard state.running else { continue }
                if let expected, state.custom, abs(state.seconds - expected) < 0.0015 {
                    return "\(report), Auto ISO \(state.autoISO)"
                }
                if expected == nil, !state.custom { return report }
            }
            throw TrenchesError.message("Camera shutter \(angle)°: \(report)")
        }

        let half = try await reach(angle: 180, expected: 1.0 / 60)
        let full = try await reach(angle: 360, expected: 1.0 / 30)
        let auto = try await reach(angle: 0, expected: nil)
        return "PASS camera hardware at 30 FPS / 180° [\(half)] / 360° [\(full)] / off [\(auto)]"
    }
    #endif
}

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, AVCaptureDataOutputSynchronizerDelegate, AVCapturePhotoCaptureDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOutput {
            do { if let recorder { try recorder.appendAudio(audioDegrader.process(sampleBuffer, settings: settings)) } }
            catch { stopRecordingOwned(); fail(error) }
        } else { process(sampleBuffer, depth: nil) }
    }
    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer, didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection) {
        guard let videoOutput, let video = synchronizedDataCollection.synchronizedData(for: videoOutput) as? AVCaptureSynchronizedSampleBufferData, !video.sampleBufferWasDropped else { return }
        var depth: AVDepthData?
        if let depthOutput, let data = synchronizedDataCollection.synchronizedData(for: depthOutput) as? AVCaptureSynchronizedDepthData, !data.depthDataWasDropped { depth = data.depthData }
        process(video.sampleBuffer, depth: depth)
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        queue.async { [self] in
            if let error { status.photoBusy = false; photoSettings = nil; publish(); fail(error); return }
            guard let data = photo.fileDataRepresentation(), let image = CIImage(data: data, options: [.applyOrientationProperty: true]), let settings = photoSettings else {
                status.photoBusy = false; publish(); fail(TrenchesError.message("Не удалось получить фотографию.")); return
            }
            photoSettings = nil; photoTaskInFlight = true
            let depth = photo.depthData
            // Still processing uses its own renderer so a 12 MP photo never stalls the video queue.
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let result: Result<URL, Error> = Result {
                    let renderer = try FrameRenderer()
                    var adjustedDepth = depth
                    if let depth, let orientation = photo.metadata[kCGImagePropertyOrientation as String] as? UInt32, let exif = CGImagePropertyOrientation(rawValue: orientation) { adjustedDepth = depth.applyingExifOrientation(exif) }
                    // Match the 9:16 live view instead of silently exporting extra sensor area.
                    let targetWidth = floor(image.extent.height * 9 / 16)
                    let crop = CGRect(x: image.extent.midX - targetWidth / 2, y: image.extent.minY, width: targetWidth, height: image.extent.height)
                    let buffer = try renderer.render(image.cropped(to: crop), depth: adjustedDepth, settings: settings, time: CACurrentMediaTime())
                    let url = try CaptureLibrary.newURL(extension: "jpg")
                    try renderer.jpeg(buffer).write(to: url, options: .atomic)
                    return url
                }
                queue.async { [self] in
                    status.photoBusy = false; photoTaskInFlight = false; publish()
                    switch result { case .success(let url): saved(url); case .failure(let error): fail(error) }
                }
            }
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        guard let error else { return }
        queue.async { [self] in
            guard !photoTaskInFlight else { return }
            status.photoBusy = false; photoSettings = nil; publish(); fail(error)
        }
    }
}
