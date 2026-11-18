import AVFoundation
import SwiftUI

struct EffectsPanel: View {
    @ObservedObject var model: CameraModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(EffectID.allCases.enumerated()), id: \.element) { index, effect in
                        NavigationLink {
                            EffectEditor(model: model, effect: effect)
                        } label: {
                            HStack(spacing: 12) {
                                Text(String(format: "%02d", index + 1)).font(.system(.caption, design: .monospaced)).foregroundStyle(model.settings.enabled(effect) ? TrenchesTheme.accent : .secondary)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(effect.title).font(.system(.subheadline, design: .monospaced).weight(.semibold))
                                    Text(effect.subtitle).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Text("[\(effect.mark)]").font(.system(size: 14, weight: .medium, design: .monospaced)).foregroundStyle(model.settings.enabled(effect) ? TrenchesTheme.accent : TrenchesTheme.paper)
                                    .frame(width: 52, height: 40)
                            }.padding(.vertical, 4)
                        }
                    }
                } header: {
                    Text("// \(model.settings.activeCount) ВКЛЮЧЕНО / \(EffectID.allCases.count) МОДУЛЕЙ").font(.system(.caption, design: .monospaced))
                } footer: { Text("Включайте несколько эффектов одновременно. Изменения сразу видны в камере и попадают в запись.") }
                Section {
                    Button("Выключить все эффекты", role: .destructive) { model.settings = EffectSettings() }.disabled(model.controlsLocked)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Эффекты")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
    }
}

struct EffectEditor: View {
    @ObservedObject var model: CameraModel
    let effect: EffectID
    @Environment(\.dismiss) private var dismiss

    private var toggleLocked: Bool { model.controlsLocked && effect == .dof && model.settings.value(.dof, "mode") >= 0.5 }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: Binding(get: { model.settings.enabled(effect) }, set: { _ in model.toggle(effect) })) {
                        Text("[\(effect.mark)] \(effect.title)").font(.system(.headline, design: .monospaced))
                    }.disabled(toggleLocked)
                } footer: { Text(effect.subtitle) }
                Section {
                    ForEach(effect.parameters.filter(visible)) { parameter in
                        parameterControl(parameter)
                    }
                    if effect == .motion, model.status.running {
                        if model.status.shutterNeedsCameraSwitch, model.status.recording, model.settings.shutterAngle > 0 {
                            Text("Выдержка включится после остановки записи.").foregroundStyle(.secondary)
                        } else if !model.status.shutterSupported, !model.status.shutterNeedsCameraSwitch {
                            Text("Эта камера не поддерживает ручную выдержку.").foregroundStyle(.secondary)
                        } else if let duration = model.status.shutterDuration, duration.isFinite, duration > 0 {
                            LabeledContent("Фактическая выдержка", value: "1/\(Int((1 / duration).rounded())) с")
                        } else if model.settings.shutterAngle == 0 {
                            LabeledContent("Выдержка", value: "Авто")
                        }
                    }
                }
                if effect == .ascii {
                    Section("Цвета ASCII") {
                        if model.settings.value(.ascii, "palette") >= 4 {
                            ColorPicker("Цвет символов", selection: asciiColor("ink"), supportsOpacity: false)
                        }
                        if model.settings.value(.ascii, "palette") >= 5 {
                            ColorPicker("Второй цвет символов", selection: asciiColor("ink2"), supportsOpacity: false)
                        }
                        ColorPicker("Цвет фона", selection: asciiColor("paper"), supportsOpacity: false)
                    }
                }
                if effect == .dof {
                    Section {
                        Label(model.settings.wantsDepth ? (model.status.depthReceiving ? "Карта глубины активна" : "Карта глубины не получена") : "Точка резкости — касанием по превью", systemImage: "viewfinder")
                            .font(.callout)
                        if let warning = model.depthWarning { Text(warning).font(.caption).foregroundStyle(.secondary) }
                    } footer: {
                        Text("Художественный режим размывает изображение вокруг выбранной точки. LiDAR / TrueDepth использует реальную дистанцию. При отсутствии глубины изображение остаётся резким.")
                    }
                }
                Section {
                    Button("Сбросить параметры") { model.reset(effect) }.disabled(model.controlsLocked && effect == .dof)
                }
            }
            .navigationTitle(effect.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
    }

    private func visible(_ parameter: EffectParameter) -> Bool {
        if effect == .ascii, parameter.title.isEmpty { return false }
        if effect == .shakal, ["audioBits", "audioRate", "audioMix"].contains(parameter.id) { return model.settings.value(.shakal, "audio") > 0.5 }
        guard effect == .dof else { return true }
        let depthMode = model.settings.value(.dof, "mode") >= 0.5
        return parameter.id == "radius" ? !depthMode : (["focus", "range"].contains(parameter.id) ? depthMode : true)
    }
    private func asciiColor(_ prefix: String) -> Binding<Color> {
        Binding(get: {
            Color(red: Double(model.settings.value(.ascii, prefix + "R")), green: Double(model.settings.value(.ascii, prefix + "G")), blue: Double(model.settings.value(.ascii, prefix + "B")))
        }, set: { color in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
            var settings = model.settings
            settings.set(.ascii, prefix + "R", Float(r)); settings.set(.ascii, prefix + "G", Float(g)); settings.set(.ascii, prefix + "B", Float(b))
            model.settings = settings
        })
    }
    private func binding(_ parameter: EffectParameter) -> Binding<Float> {
        Binding(get: { model.settings.value(effect, parameter.id) }, set: { model.settings.set(effect, parameter.id, $0) })
    }
    @ViewBuilder private func parameterControl(_ parameter: EffectParameter) -> some View {
        if !parameter.choices.isEmpty {
            Picker(parameter.title, selection: binding(parameter)) {
                ForEach(Array(parameter.choices.enumerated()), id: \.offset) { index, title in Text(title).tag(Float(index)) }
            }.disabled(effect == .dof && parameter.id == "mode" && model.controlsLocked)
        } else {
            VStack(spacing: 10) {
                HStack {
                    Text(parameter.title).font(.system(.subheadline, design: .monospaced))
                    Spacer()
                    Text(parameter.formatted(model.settings.value(effect, parameter.id))).font(.system(.subheadline, design: .monospaced)).foregroundStyle(TrenchesTheme.accent).monospacedDigit()
                }
                Slider(value: binding(parameter), in: parameter.range) { Text(parameter.title) }
                    .accessibilityValue(parameter.formatted(model.settings.value(effect, parameter.id)))
            }.padding(.vertical, 7)
        }
    }
}

struct PresetsPanel: View {
    @ObservedObject var model: CameraModel
    @Environment(\.dismiss) private var dismiss
    @State private var naming = false
    @State private var name = ""
    var body: some View {
        NavigationStack {
            List {
                Section("Готовые сочетания") {
                    Button { model.settings = EffectSettings(); dismiss() } label: { Label("Чистый сигнал", systemImage: "circle") }
                    ForEach(LookPreset.builtIns) { preset in presetButton(preset) }
                }.disabled(model.controlsLocked)
                Section("Мои пресеты") {
                    if model.presets.isEmpty { Text("Соберите свой набор эффектов и сохраните его здесь.").font(.callout).foregroundStyle(.secondary) }
                    ForEach(model.presets) { preset in presetButton(preset).disabled(model.controlsLocked) }
                        .onDelete { model.presets.remove(atOffsets: $0) }
                    Button { name = ""; naming = true } label: { Label("Сохранить текущие настройки", systemImage: "plus") }
                }
            }
            .navigationTitle("Пресеты")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
            .alert("Название пресета", isPresented: $naming) {
                TextField("Например, Ночной терминал", text: $name)
                Button("Сохранить") { model.addPreset(name) }
                Button("Отмена", role: .cancel) {}
            }
        }
    }
    private func presetButton(_ preset: LookPreset) -> some View {
        Button { model.apply(preset); dismiss() } label: {
            HStack {
                Text(preset.name).foregroundStyle(.primary)
                Spacer()
                Text("\(preset.settings.activeCount) FX").font(.system(.caption, design: .monospaced)).foregroundStyle(TrenchesTheme.accent)
            }.padding(.vertical, 8)
        }
    }
}

struct CaptureSettingsPanel: View {
    @ObservedObject var model: CameraModel
    @Binding var grid: Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Видео", selection: Binding(get: { model.status.quality }, set: { model.service.select(quality: $0) })) {
                        ForEach(CaptureQuality.allCases) { Text($0.title).tag($0) }
                    }.disabled(model.controlsLocked)
                    Toggle("Сетка кадрирования", isOn: $grid)
                } footer: { Text("Частота обработки зависит от эффектов и температуры устройства. Счётчик FPS показывает фактическую скорость. Фото сохраняются в JPEG, видео — в SDR HEVC/AAC (MOV).") }
                Section("Звук") {
                    Label(model.status.audio ? "Микрофон подключён" : "Микрофон не подключён", systemImage: model.status.audio ? "mic" : "mic.slash")
                    if !model.status.audio {
                        Text("Разрешение запрашивается перед первой видеозаписью. При отказе видео записывается без звука.").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Настройки доступа") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                }
                Section("Сигнал") {
                    LabeledContent("Фактическая обработка", value: "\(model.status.fps) к/с")
                    LabeledContent("Пропуски кадров", value: "\(model.status.droppedFrames)")
                    LabeledContent("Глубина", value: model.status.depthReceiving ? "Поступает" : "Нет данных")
                    Text("Переключение камеры, качества и источника глубины доступно между записями. Остальные эффекты можно менять во время записи.").font(.caption).foregroundStyle(.secondary)
                }
                Section("trenches / 01") {
                    Text("Сначала свет. Потом всё остальное.").font(.system(.callout, design: .monospaced))
                    Text("Съёмки остаются внутри приложения и копируются в «Фото», если вы разрешили доступ. Облачных загрузок нет.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Съёмка")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
    }
}
