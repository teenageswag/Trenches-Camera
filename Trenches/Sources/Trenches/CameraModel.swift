import AVFoundation
import Combine
import SwiftUI

@MainActor
final class CameraModel: ObservableObject {
    let service = CameraService()
    @Published var status = CameraStatus()
    @Published var cameraDenied = false
    @Published var requesting = true
    @Published var error: String?
    @Published var latestURL: URL?
    @Published var settings: EffectSettings {
        didSet {
            service.update(settings)
            if let data = try? JSONEncoder().encode(settings.disabledEffects) { UserDefaults.standard.set(data, forKey: "trenches.settings.v1") }
        }
    }
    @Published var presets: [LookPreset] {
        didSet { if let data = try? JSONEncoder().encode(presets) { UserDefaults.standard.set(data, forKey: "trenches.presets.v1") } }
    }
    @Published var videoMode = false
    @Published var recordingStarted: Date?
    private var started = false

    init() {
        settings = (UserDefaults.standard.data(forKey: "trenches.settings.v1").flatMap { try? JSONDecoder().decode(EffectSettings.self, from: $0) } ?? EffectSettings()).disabledEffects
        presets = UserDefaults.standard.data(forKey: "trenches.presets.v1").flatMap { try? JSONDecoder().decode([LookPreset].self, from: $0) } ?? []
        service.onStatus = { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                if status.recording && !self.status.recording { self.recordingStarted = Date() }
                if !status.recording { self.recordingStarted = nil }
                self.status = status
            }
        }
        service.onError = { [weak self] error in Task { @MainActor in self?.error = error } }
        service.onSaved = { [weak self] url, _ in Task { @MainActor in
            self?.latestURL = url
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } }
        service.update(settings)
    }

    var controlsLocked: Bool { status.recording || status.finishing || status.photoBusy }
    var captureAvailable: Bool { status.running && !status.finishing && !status.photoBusy }
    var depthWarning: String? {
        guard settings.wantsDepth else { return nil }
        if !status.depthAvailable { return "Карта глубины недоступна. Выберите 1× или фронтальную камеру и 1080p · 30, либо художественный DOF." }
        if !status.depthReceiving { return "Ожидаем карту глубины… DOF включится при её получении." }
        return nil
    }

    func activate() async {
        if started, AVCaptureDevice.authorizationStatus(for: .video) == .authorized { cameraDenied = false; service.start(); return }
        started = true
        requesting = true
        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: authorized = true
        case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .video)
        default: authorized = false
        }
        cameraDenied = !authorized
        requesting = false
        if authorized { service.start() }
    }

    func shoot() {
        guard captureAvailable else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if videoMode {
            Task {
                if !status.recording && AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                    let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                    if allowed { service.select() }
                }
                service.toggleRecording()
            }
        } else { service.capturePhoto() }
    }

    func toggle(_ effect: EffectID) {
        guard !(controlsLocked && effect == .dof && settings.value(.dof, "mode") >= 0.5) else { return }
        settings.toggle(effect)
        UISelectionFeedbackGenerator().selectionChanged()
    }
    func reset(_ effect: EffectID) {
        guard !(controlsLocked && effect == .dof) else { return }
        settings.effects[effect] = EffectState(enabled: settings.enabled(effect))
    }
    func apply(_ preset: LookPreset) { guard !controlsLocked else { return }; settings = preset.settings }
    func addPreset(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        presets.append(LookPreset(name: String(name.prefix(40)), settings: settings))
    }
    func focus(x: Float, y: Float) {
        settings.focusX = x; settings.focusY = y
        service.focus(x: x, y: y)
    }
}
