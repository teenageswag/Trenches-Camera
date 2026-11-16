import SwiftUI

enum TrenchesTheme {
    static let accent = Color(red: 0.84, green: 0.97, blue: 0.37)
    static let paper = Color(red: 0.91, green: 0.90, blue: 0.85)
    static let surface = Color(white: 0.065)
}

enum CameraPanel: String, Identifiable {
    case effects, presets, settings, library
    var id: String { rawValue }
}

struct ContentView: View {
    @StateObject private var model = CameraModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var panel: CameraPanel?
    @State private var selectedEffect: EffectID?
    @State private var focusPoint: CGPoint?
    @State private var focusTask: Task<Void, Never>?
    @State private var grid = false
    @State private var pinchStart: Double?
    @State private var showZoom = false

    var body: some View {
        VStack(spacing: 4) {
            header
            viewfinder.frame(maxWidth: .infinity, maxHeight: .infinity)
            captureControls
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
        .padding(.bottom, 2)
        .background(Color.black)
        .foregroundStyle(TrenchesTheme.paper)
        .task { await model.activate() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.activate() } }
            else if phase == .background { model.service.suspend() }
        }
        .onChange(of: model.status.recording) { _, recording in UIApplication.shared.isIdleTimerDisabled = recording }
        .sheet(item: $panel) { panel in
            switch panel {
            case .effects: EffectsPanel(model: model)
            case .presets: PresetsPanel(model: model)
            case .settings: CaptureSettingsPanel(model: model, grid: $grid)
            case .library: CaptureLibraryView()
            }
        }
        .sheet(item: $selectedEffect) { effect in
            EffectEditor(model: model, effect: effect)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
        }
        .alert("trenches", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("Понятно", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("[t_]").foregroundStyle(TrenchesTheme.accent).accessibilityHidden(true)
            Text("trenches").font(.system(size: 19, weight: .bold, design: .monospaced)).tracking(-0.8)
            Spacer()
            Button { panel = .presets } label: { Text("[ПРЕСЕТЫ]").frame(minHeight: 44) }
                .buttonStyle(.plain).accessibilityLabel("Пресеты")
            Button { panel = .settings } label: { Text("[::]").frame(minWidth: 44, minHeight: 44) }
                .buttonStyle(.plain).accessibilityLabel("Настройки съёмки")
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .padding(.horizontal, 4)
    }

    private var viewfinder: some View {
        GeometryReader { geometry in
            let width = max(0, min(geometry.size.width, geometry.size.height * 9 / 16))
            let height = width * 16 / 9
            ZStack {
                CameraPreview(frames: model.service.preview)
                    .contentShape(Rectangle())
                    .simultaneousGesture(MagnifyGesture().onChanged { value in
                        if pinchStart == nil { pinchStart = model.status.zoom }
                        model.service.setZoom((pinchStart ?? 1) * value.magnification)
                    }.onEnded { _ in pinchStart = nil })
                    .onTapGesture { point in
                        guard model.status.running, width > 0, height > 0 else { return }
                        let normalized = CGPoint(x: min(1, max(0, point.x / width)), y: min(1, max(0, point.y / height)))
                        model.focus(x: Float(normalized.x), y: Float(normalized.y))
                        focusPoint = normalized
                        focusTask?.cancel()
                        focusTask = Task { try? await Task.sleep(for: .seconds(1.5)); if !Task.isCancelled { focusPoint = nil } }
                    }
                if grid {
                    Canvas { context, size in
                        var path = Path()
                        for factor in [CGFloat(1) / 3, CGFloat(2) / 3] {
                            path.move(to: CGPoint(x: size.width * factor, y: 0)); path.addLine(to: CGPoint(x: size.width * factor, y: size.height))
                            path.move(to: CGPoint(x: 0, y: size.height * factor)); path.addLine(to: CGPoint(x: size.width, y: size.height * factor))
                        }
                        context.stroke(path, with: .color(.white.opacity(0.25)), lineWidth: 0.5)
                    }.allowsHitTesting(false).accessibilityHidden(true)
                }
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom).frame(height: 90)
                    Spacer(minLength: 0)
                    LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom).frame(height: 130)
                }.allowsHitTesting(false)
                VStack {
                    HStack(spacing: 10) {
                        Text(model.status.recording ? "[! REC]" : "[ЭФИР]")
                            .foregroundStyle(model.status.recording ? .red : TrenchesTheme.accent)
                        if model.status.recording, let start = model.recordingStarted { Text(start, style: .timer).monospacedDigit() }
                        Spacer()
                        qualityMenu
                        modeMenu
                    }.font(.system(size: 10, weight: .semibold, design: .monospaced))
                    Spacer()
                    if let warning = model.depthWarning { Text(warning).font(.caption).padding(10).background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 12)) }
                    if showZoom, model.status.maxZoom > model.status.minZoom {
                        Slider(value: Binding(get: { log(model.status.zoom) }, set: { model.service.setZoom(exp($0)) }),
                               in: log(model.status.minZoom)...log(model.status.maxZoom)) { Text("Зум") }
                            .tint(TrenchesTheme.accent)
                            .accessibilityValue(zoomTitle(model.status.zoom))
                    }
                    HStack {
                        lensControls
                        Spacer(minLength: 0)
                        Text("[\(model.status.fps) FPS]").font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.75)).monospacedDigit()
                    }
                    effectsStrip
                }.padding(.horizontal, 12).padding(.vertical, 4)
                if let point = focusPoint {
                    FinderCorners().stroke(TrenchesTheme.accent, lineWidth: 1)
                        .frame(width: 64, height: 64).position(x: point.x * width, y: point.y * height).allowsHitTesting(false).accessibilityHidden(true)
                }
                if !model.status.running { cameraUnavailable }
            }
            .frame(width: width, height: height)
            .background(TrenchesTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.12), lineWidth: 0.5)
                    FinderCorners().stroke(TrenchesTheme.paper.opacity(0.65), lineWidth: 1).padding(6)
                }.allowsHitTesting(false)
            }
            .accessibilityLabel("Превью камеры")
            .accessibilityHint("Коснитесь, чтобы выбрать точку фокусировки")
            .accessibilityAction(named: "Фокус в центре") { model.focus(x: 0.5, y: 0.5) }
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }

    private var lensControls: some View {
        HStack(spacing: 2) {
            ForEach(model.status.zoomStops, id: \.self) { zoom in
                let selected = abs(model.status.zoom - zoom) < 0.05
                Button { model.service.setZoom(zoom, smoothly: !reduceMotion) } label: {
                    Text(selected ? "[\(zoomTitle(zoom))]" : zoomTitle(zoom))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced)).frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? TrenchesTheme.accent : .white.opacity(0.75))
                .onLongPressGesture { showZoom = true }
                .accessibilityLabel("Зум \(zoomTitle(zoom))")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Button { showZoom.toggle() } label: {
                Image(systemName: showZoom ? "chevron.down" : "dial.low").frame(minWidth: 44, minHeight: 44)
            }.buttonStyle(.plain).accessibilityLabel("Плавный зум, \(zoomTitle(model.status.zoom))")
        }.disabled(model.status.finishing || model.status.photoBusy)
    }

    private func zoomTitle(_ zoom: Double) -> String { String(format: zoom.rounded() == zoom ? "%.0f×" : "%.1f×", zoom) }

    @ViewBuilder private var cameraUnavailable: some View {
        VStack(spacing: 14) {
            if model.requesting { ProgressView(); Text("Подключаем камеру…").font(.callout) }
            else if model.cameraDenied {
                Image(systemName: "camera.fill").font(.largeTitle)
                Text("Нужен доступ к камере").font(.headline)
                Text("Разрешите камеру в Настройках, чтобы начать съёмку.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Открыть Настройки") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }.platformButtonStyle(prominent: true)
            } else {
                ProgressView()
                Text("Камера приостановлена").font(.callout)
                Button("Повторить") { model.service.start() }.platformButtonStyle()
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black.opacity(0.8))
    }

    private var effectsStrip: some View {
        HStack(spacing: 8) {
            Button { panel = .effects } label: {
                Text(String(format: "[FX:%02d]", model.settings.activeCount))
                    .font(.system(size: 11, weight: .bold, design: .monospaced)).frame(minHeight: 44)
            }.buttonStyle(.plain).foregroundStyle(TrenchesTheme.accent).accessibilityLabel("Все эффекты, включено \(model.settings.activeCount)")
            ScrollView(.horizontal) {
                HStack(spacing: 14) {
                    ForEach(EffectID.allCases) { effect in
                        Button { selectedEffect = effect } label: {
                            Text("\(model.settings.enabled(effect) ? "#" : ".")\(effect.title.uppercased())")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced)).frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(model.settings.enabled(effect) ? TrenchesTheme.accent : .white.opacity(0.7))
                        .accessibilityLabel("\(effect.title), \(model.settings.enabled(effect) ? "включён" : "выключен"). Настроить")
                    }
                }
            }.scrollIndicators(.hidden)
        }
    }

    private var captureControls: some View {
        HStack {
            Button { panel = .library } label: {
                Text("[СЪЁМКИ]").font(.system(size: 11, weight: .medium, design: .monospaced)).frame(width: 88, height: 52)
            }.buttonStyle(.plain).accessibilityLabel("Мои съёмки")
            Spacer()
            Button { model.shoot() } label: {
                ZStack {
                    FinderCorners().stroke(model.videoMode ? Color.red.opacity(0.8) : TrenchesTheme.paper, lineWidth: 1).frame(width: 62, height: 62)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(model.videoMode ? .red : TrenchesTheme.paper)
                        .frame(width: model.status.recording ? 24 : 44, height: model.status.recording ? 24 : 44)
                    if model.status.photoBusy || model.status.finishing { ProgressView().tint(.black) }
                }.frame(width: 72, height: 72)
            }
            .buttonStyle(ShutterStyle(reduceMotion: reduceMotion))
            .disabled(!model.captureAvailable)
            .opacity(model.captureAvailable ? 1 : 0.45)
            .accessibilityLabel(model.videoMode ? (model.status.recording ? "Остановить запись" : "Записать видео") : "Снять фото")
            Spacer()
            Button { model.service.select(lens: model.status.lens == .front ? .wide : .front) } label: {
                Text("[< >]").font(.system(size: 14, weight: .medium, design: .monospaced)).frame(width: 88, height: 52)
            }.buttonStyle(.plain).disabled(model.controlsLocked).accessibilityLabel("Переключить переднюю и заднюю камеру")
        }
    }

    private var qualityMenu: some View {
        Menu {
            Picker("Качество видео", selection: Binding(get: { model.status.quality }, set: { model.service.select(quality: $0) })) {
                ForEach(CaptureQuality.allCases) { Text($0.title).tag($0) }
            }
        } label: {
            Text("[\(model.status.quality == .uhd30 ? "4K" : "1080P")/\(model.status.captureFPS)]").frame(minHeight: 44)
        }
        .buttonStyle(.plain).disabled(model.controlsLocked)
        .accessibilityLabel("Качество видео, \(model.status.quality.title)")
    }

    private var modeMenu: some View {
        Menu {
            Picker("Режим съёмки", selection: $model.videoMode) {
                Text("Фото").tag(false)
                Text("Видео").tag(true)
            }
        } label: { Text(model.videoMode ? "[ВИДЕО]" : "[ФОТО]").frame(minWidth: 44, minHeight: 44) }
            .buttonStyle(.plain).disabled(model.controlsLocked)
            .accessibilityLabel("Режим съёмки, \(model.videoMode ? "видео" : "фото")")
    }
}

private struct FinderCorners: Shape {
    func path(in rect: CGRect) -> Path {
        let length = min(14, min(rect.width, rect.height) / 3)
        var path = Path()
        for (x, y, dx, dy) in [(rect.minX, rect.minY, CGFloat(1), CGFloat(1)), (rect.maxX, rect.minY, -1, 1), (rect.minX, rect.maxY, 1, -1), (rect.maxX, rect.maxY, -1, -1)] {
            path.move(to: CGPoint(x: x + dx * length, y: y))
            path.addLine(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x, y: y + dy * length))
        }
        return path
    }
}

private struct ShutterStyle: ButtonStyle {
    let reduceMotion: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private extension View {
    @ViewBuilder func platformButtonStyle(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent) }
            else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) }
            else { buttonStyle(.bordered) }
        }
    }
}
