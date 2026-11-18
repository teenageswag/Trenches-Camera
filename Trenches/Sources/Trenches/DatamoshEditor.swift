import AVKit
import SwiftUI

struct DatamoshEditor: View {
    @StateObject private var model: DatamoshEditorModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var namingPreset = false
    @State private var presetName = ""
    @State private var settings = false
    @State private var expanded = false
    let onSaved: (URL) -> Void

    init(url: URL, onSaved: @escaping (URL) -> Void = { _ in }) {
        _model = StateObject(wrappedValue: DatamoshEditorModel(url: url))
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                preview.frame(maxWidth: .infinity, maxHeight: .infinity)
                transport
                if !expanded {
                    DatamoshTimeline(model: model).frame(height: 89).padding(.horizontal, 12)
                    rangeTools.padding(.horizontal, 12).padding(.top, 4)
                }
            }
            .background(.black)
            .overlay { if model.busy { operationOverlay } }
            .navigationTitle("Datamosh")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { model.close(); dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { model.export(onSaved: onSaved) } label: {
                        Label("Экспорт", systemImage: "square.and.arrow.up").labelStyle(.titleAndIcon)
                    }.disabled(model.media == nil || model.busy)
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
            .tint(TrenchesTheme.accent)
            .task { await model.load() }
            .onDisappear { model.close() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { model.pause(refresh: true) } }
            .interactiveDismissDisabled(model.busy)
            .sheet(isPresented: $settings) {
                DatamoshRangeSettings(model: model)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .preferredColorScheme(.dark)
                    .tint(TrenchesTheme.accent)
            }
            .alert("Datamosh", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("Понятно", role: .cancel) { model.error = nil }
            } message: { Text(model.error ?? "") }
            .alert("Сохранить пресет", isPresented: $namingPreset) {
                TextField("Название", text: $presetName)
                Button("Сохранить") { model.savePreset(presetName) }
                Button("Отмена", role: .cancel) {}
            } message: { Text("На другом видео границы сохранят свои пропорции по длине клипа.") }
        }
        .preferredColorScheme(.dark)
    }

    private var preview: some View {
        Color.black.overlay {
            if let player = model.player {
                DatamoshPlayerView(player: player)
                    .accessibilityLabel("Превью видео")
            } else if let image = model.image {
                Image(uiImage: image).resizable().scaledToFit()
                    .accessibilityLabel(model.showingOriginal ? "Кадр исходного видео" : "Кадр после Datamosh")
            } else if model.media != nil {
                ProgressView().accessibilityLabel("Готовим кадр")
            }
        }
        .clipped()
        .overlay(alignment: .topLeading) {
            if model.media != nil {
                HStack(spacing: 0) {
                    Button { model.toggleOriginal() } label: {
                        Label(model.showingOriginal ? "Исходник" : "Эффект", systemImage: "circle.lefthalf.filled")
                            .font(.caption.weight(.semibold)).padding(.horizontal, 12).frame(minHeight: 44)
                            .background(.black.opacity(0.8), in: Capsule())
                    }
                    .accessibilityLabel("До и после")
                    .accessibilityValue(model.showingOriginal ? "Исходник" : "Эффект")
                    if model.renderingPreview, model.image != nil {
                        ProgressView().controlSize(.small).frame(width: 36)
                            .accessibilityLabel("Обновляем кадр")
                    }
                }.padding(10)
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.media != nil {
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .frame(width: 44, height: 44).background(.black.opacity(0.8), in: Circle())
                }
                .accessibilityLabel(expanded ? "Показать таймлайн" : "Развернуть видео").padding(10)
            }
        }
        .overlay(alignment: .bottom) {
            if let notice = model.notice {
                HStack(spacing: 4) {
                    Text(notice).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Button { model.notice = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                        .accessibilityLabel("Закрыть сообщение")
                }.padding(.leading, 10).background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                    .padding(10)
            } else if model.noMovement && !model.playing && !model.renderingPreview && !model.showingOriginal {
                Text("Здесь почти нет движения").font(.caption).padding(8)
                    .background(.black.opacity(0.8), in: Capsule()).padding(10)
                    .allowsHitTesting(false)
            }
        }
        .buttonStyle(.plain)
    }

    private var transport: some View {
        HStack(spacing: 0) {
            icon("backward.end.fill", "Предыдущий кадр") { model.seek(model.frame - 1) }
            icon(model.playing ? "pause.fill" : "play.fill", model.playing ? "Пауза" : "Воспроизвести") { model.togglePlayback() }
            icon("forward.end.fill", "Следующий кадр") { model.seek(model.frame + 1) }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(model.media?.timeLabel(model.frame) ?? "00:00.000")
                Text("\(model.frame + 1) / \(model.media?.frameCount ?? 0)").foregroundStyle(.secondary)
            }.font(.system(.caption, design: .monospaced)).monospacedDigit()
                .accessibilityElement(children: .ignore).accessibilityLabel("Позиция")
                .accessibilityValue("Кадр \(model.frame + 1) из \(model.media?.frameCount ?? 0)")
            icon("repeat", "Повтор выбранного диапазона") {
                if model.playing { model.togglePlayback() }
                model.loopSelection.toggle()
            }
            .foregroundStyle(model.loopSelection && model.selected != nil ? TrenchesTheme.accent : Color.secondary)
            .accessibilityValue(model.loopSelection ? "Включён" : "Выключен")
            .disabled(model.selected == nil)
            if !expanded { editMenu }
        }
        .padding(.horizontal, 8)
        .disabled(model.busy || model.media == nil)
    }

    private var editMenu: some View {
        Menu {
            Button("Отменить", systemImage: "arrow.uturn.backward") { model.undo() }.disabled(model.history.undoStack.isEmpty)
            Button("Повторить", systemImage: "arrow.uturn.forward") { model.redo() }.disabled(model.history.redoStack.isEmpty)
            Menu("Масштаб таймлайна", systemImage: "magnifyingglass") {
                Button("Приблизить", systemImage: "plus.magnifyingglass") { model.zoom = min(model.maxZoom, model.zoom * 2) }.disabled(model.zoom >= model.maxZoom)
                Button("Отдалить", systemImage: "minus.magnifyingglass") { model.zoom = max(1, model.zoom / 2) }.disabled(model.zoom <= 1)
                Button("Весь клип", systemImage: "arrow.left.and.right") { model.zoom = 1 }.disabled(model.zoom <= 1)
            }
            Section {
                if model.pendingStart != nil || model.selected != nil {
                    Button("До конца клипа", systemImage: "arrow.right.to.line") { model.markEnd(throughClipEnd: true) }
                }
                if model.selected?.mode == .transfer {
                    Button("Взять текущий кадр для переноса", systemImage: "photo.on.rectangle") { model.setDonor(model.frame) }
                }
                if model.selected != nil {
                    Button(model.document.resets.contains(model.frame) ? "Убрать сброс здесь" : "Сбросить накопление здесь", systemImage: "diamond") { model.toggleReset() }
                }
                if !model.document.resets.isEmpty {
                    Menu("Кадры сброса", systemImage: "diamond") {
                        ForEach(model.document.resets, id: \.self) { frame in
                            Button(model.media?.timeLabel(frame) ?? "\(frame + 1)") { model.seek(frame) }
                        }
                    }
                }
                Button("Предложить диапазоны", systemImage: "wand.and.stars") { model.autoPoints() }
            }
            Section {
                Button("Сохранить пресет", systemImage: "square.and.arrow.down") {
                    presetName = ""
                    namingPreset = true
                }.disabled(model.document.segments.isEmpty)
                ForEach(model.presets) { preset in
                    Menu(preset.name) {
                        Button("Применить") { model.apply(preset) }
                        Button("Удалить", role: .destructive) { model.removePreset(preset.id) }
                    }
                }
                if let exported = model.exportedURL {
                    ShareLink(item: exported) { Label("Поделиться экспортом", systemImage: "square.and.arrow.up") }
                }
            }
        } label: {
            Image(systemName: "ellipsis").frame(width: 44, height: 44)
        }.accessibilityLabel("Действия редактора")
    }

    private var rangeTools: some View {
        HStack(spacing: 6) {
            Button { model.markStart() } label: {
                boundaryLabel("Начало", symbol: "arrow.left.to.line", highlighted: model.selected == nil && model.pendingStart == nil)
            }.accessibilityHint("Установить левую границу на текущем кадре")
            Button { model.markEnd() } label: {
                boundaryLabel("Конец", symbol: "arrow.right.to.line", highlighted: model.pendingStart != nil)
            }
            .disabled(model.pendingStart == nil && model.selected == nil)
            .accessibilityHint("Первый кадр после эффекта")
            if let segment = model.selected {
                Button { model.pause(refresh: true); settings = true } label: {
                    boundaryLabel(segment.mode.title, symbol: "slider.horizontal.3", highlighted: false)
                }.accessibilityLabel("Настроить диапазон, \(segment.mode.title)")
                icon("plus", "Новый диапазон") { model.newRange() }
            } else if model.pendingStart != nil {
                icon("xmark", "Отменить выбор диапазона") { model.newRange() }
            }
        }
        .buttonStyle(.plain)
        .disabled(model.busy || model.media == nil)
    }

    private func boundaryLabel(_ title: String, symbol: String, highlighted: Bool) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(highlighted ? TrenchesTheme.accent : Color(white: 0.1), in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(highlighted ? .black : .white)
            .contentShape(Rectangle())
    }

    private func icon(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 44, height: 44).contentShape(Rectangle()) }
            .buttonStyle(.plain).accessibilityLabel(label)
    }

    private var operationOverlay: some View {
        VStack(spacing: 16) {
            Text(model.operationTitle).font(.headline).multilineTextAlignment(.center)
            ProgressView(value: model.progress)
            Text("\(Int(model.progress * 100))%").monospacedDigit()
            Button("Отменить") { model.cancelOperation() }.buttonStyle(.bordered)
        }.padding(24).frame(maxWidth: 320).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(.black.opacity(0.65))
    }
}

private struct DatamoshPlayerView: UIViewRepresentable {
    let player: AVPlayer

    final class Surface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> Surface {
        let view = Surface()
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: Surface, context: Context) { view.playerLayer.player = player }
    static func dismantleUIView(_ view: Surface, coordinator: ()) { view.playerLayer.player = nil }
}

private struct DatamoshRangeSettings: View {
    @ObservedObject var model: DatamoshEditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let segment = model.selected {
                    Section {
                        Picker("Режим", selection: Binding(get: { segment.mode }, set: { mode in
                            var updated = segment
                            updated.mode = mode
                            model.update(updated)
                        })) {
                            Section {
                                ForEach(DatamoshMode.featured) { mode in Label(mode.title, systemImage: mode.symbol).tag(mode) }
                            }
                            Section("Другие режимы") {
                                ForEach(DatamoshMode.allCases.filter { !DatamoshMode.featured.contains($0) }) { mode in
                                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                                }
                            }
                        }
                        ForEach(segment.mode.parameters) { parameter in parameterControl(parameter, segment: segment) }
                    }
                    if segment.mode == .transfer {
                        Section {
                            LabeledContent("Кадр-источник", value: segment.donorFrame.map { timeLabel($0) } ?? (segment.start > 0 ? "Перед началом" : "Первый кадр"))
                            Button("Взять текущий кадр") { model.setDonor(model.frame) }
                            if segment.donorFrame != nil { Button("Сбросить выбор кадра") { model.setDonor(nil) } }
                        } footer: {
                            Text("Для переноса между сценами поставьте начало на монтажный стык. Чтобы взять другой кадр, найдите его на таймлайне и выберите здесь.")
                        }
                    }
                    Section {
                        boundaryStepper(.start, segment: segment)
                        boundaryStepper(.end, segment: segment)
                    } footer: {
                        Text("Кадр на правой границе восстанавливает исходное видео.")
                    }
                    Section("Параметры сбоя") {
                        ForEach(DatamoshMode.commonParameters) { parameter in parameterControl(parameter, segment: segment) }
                    }
                    Section {
                        Button("Удалить диапазон", role: .destructive) { model.remove(segment.id); dismiss() }
                    }
                }
            }
            .navigationTitle("Диапазон")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
        .onDisappear { model.continuousEdit(false) }
    }

    private func timeLabel(_ frame: Int) -> String {
        frame == model.frameCount ? "Конец клипа" : model.media?.timeLabel(frame) ?? "\(frame + 1)"
    }

    private func boundaryStepper(_ boundary: DatamoshEditorModel.Boundary, segment: DatamoshSegment) -> some View {
        let isStart = boundary == .start
        let frame = isStart ? segment.start : segment.endFrame
        let title = isStart ? "Начало" : "Конец"
        let limits = model.limits(for: segment, boundary: boundary)
        return Stepper(value: Binding(get: { frame }, set: { model.trim(segment.id, boundary: boundary, to: $0) }), in: limits) {
            LabeledContent(title, value: timeLabel(frame))
        }.accessibilityLabel(title).accessibilityValue(timeLabel(frame))
    }

    @ViewBuilder private func parameterControl(_ parameter: EffectParameter, segment: DatamoshSegment) -> some View {
        let binding = Binding<Float>(get: {
            model.selected?.value(parameter.id) ?? parameter.initial
        }, set: { value in
            guard var updated = model.selected, updated.id == segment.id else { return }
            updated.values[parameter.id] = value
            model.update(updated)
        })
        if !parameter.choices.isEmpty {
            Picker(parameter.title, selection: binding) {
                ForEach(Array(parameter.choices.enumerated()), id: \.offset) { index, title in Text(title).tag(Float(index)) }
            }
        } else {
            VStack {
                LabeledContent(parameter.title, value: parameter.formatted(binding.wrappedValue))
                Slider(value: binding, in: parameter.range, onEditingChanged: model.continuousEdit)
                    .accessibilityLabel(parameter.title).accessibilityValue(parameter.formatted(binding.wrappedValue))
            }
        }
    }
}
