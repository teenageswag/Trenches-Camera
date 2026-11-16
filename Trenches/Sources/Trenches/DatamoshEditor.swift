import AVKit
import SwiftUI

struct DatamoshEditor: View {
    @StateObject private var model: DatamoshEditorModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var namingPreset = false
    @State private var presetName = ""
    let onSaved: (URL) -> Void

    init(url: URL, onSaved: @escaping (URL) -> Void = { _ in }) {
        _model = StateObject(wrappedValue: DatamoshEditorModel(url: url)); self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                VStack(spacing: 8) {
                    preview.frame(height: max(120, min(280, geometry.size.height * 0.36)))
                    transport
                    DatamoshTimeline(model: model).frame(height: 144)
                    timelineTools
                    if model.noMovement { Text("В этом кадре почти нет движения: эффект может быть незаметен.").font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
                    if let notice = model.notice {
                        HStack {
                            Text(notice).font(.caption)
                            Spacer()
                            Button { model.notice = nil } label: { Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("Закрыть сообщение")
                        }.padding(.horizontal)
                    }
                    segmentEditor
                }
                .overlay { if model.busy { operationOverlay } }
            }
            .background(.black)
            .navigationTitle("Datamosh")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { model.close(); dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Применить / Экспорт") { model.export(onSaved: onSaved) }.disabled(model.media == nil || model.busy)
                }
            }
            .task { await model.load() }
            .onDisappear { model.close() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { model.pause() } }
            .interactiveDismissDisabled(model.busy)
            .alert("Datamosh", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("Понятно", role: .cancel) { model.error = nil }
            } message: { Text(model.error ?? "") }
            .alert("Сохранить точки как пресет", isPresented: $namingPreset) {
                TextField("Название", text: $presetName)
                Button("Сохранить") { model.savePreset(presetName) }
                Button("Отмена", role: .cancel) {}
            } message: { Text("На другом видео точки будут пропорционально распределены по его длине.") }
        }
    }

    private var preview: some View {
        ZStack {
            Color.black
            if model.playing, let player = model.player { VideoPlayer(player: player) }
            else if let image = model.image { Image(uiImage: image).resizable().scaledToFit() }
            else if model.media != nil { Text("Готовим кадр…").font(.caption).foregroundStyle(.secondary) }
            if model.renderingPreview { ProgressView().padding(12).background(.black.opacity(0.7), in: Capsule()) }
        }.accessibilityLabel("Превью Datamosh")
    }

    private var transport: some View {
        HStack(spacing: 4) {
            Button { model.seek(model.frame - 1) } label: { Image(systemName: "backward.end").frame(width: 44, height: 44) }.accessibilityLabel("Предыдущий кадр")
            Button { model.togglePlayback() } label: { Image(systemName: model.playing ? "pause.fill" : "play.fill").frame(width: 44, height: 44) }.accessibilityLabel(model.playing ? "Пауза" : "Воспроизвести с эффектами и звуком")
            Button { model.seek(model.frame + 1) } label: { Image(systemName: "forward.end").frame(width: 44, height: 44) }.accessibilityLabel("Следующий кадр")
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text(model.media?.timeLabel(model.frame) ?? "00:00.000")
                Text("\(model.frame + 1) / \(model.frameCount)").foregroundStyle(.secondary)
            }.font(.system(.caption2, design: .monospaced)).monospacedDigit()
            Button { model.addPoint() } label: { Text("+ точка").font(.callout).frame(minHeight: 44).padding(.horizontal, 8) }
        }.buttonStyle(.plain).padding(.horizontal, 8).disabled(model.busy || model.media == nil)
    }

    private var timelineTools: some View {
        HStack(spacing: 0) {
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44) }.disabled(model.history.undoStack.isEmpty).accessibilityLabel("Отменить изменение")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward").frame(width: 44, height: 44) }.disabled(model.history.redoStack.isEmpty).accessibilityLabel("Повторить изменение")
            Menu {
                Button("Добавить ключевой кадр здесь", systemImage: "diamond") { model.toggleReset() }
                Button("Авто-точки", systemImage: "wand.and.stars") { model.autoPoints() }
                Button("Сохранить набор точек", systemImage: "square.and.arrow.down") { presetName = ""; namingPreset = true }
                if let exported = model.exportedURL { ShareLink(item: exported) { Label("Поделиться экспортом", systemImage: "square.and.arrow.up") } }
                ForEach(model.presets) { preset in
                    Menu(preset.name) {
                        Button("Применить точки") { model.apply(preset) }
                        Button("Удалить пресет", role: .destructive) { model.removePreset(preset.id) }
                    }
                }
            } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }.accessibilityLabel("Ключевые кадры, авто-точки и пресеты")
            Image(systemName: "minus.magnifyingglass").accessibilityHidden(true)
            Slider(value: $model.zoom, in: 1...16) { Text("Масштаб таймлайна") }.padding(.horizontal, 8)
            Image(systemName: "plus.magnifyingglass").accessibilityHidden(true)
        }.buttonStyle(.plain).padding(.horizontal, 8).disabled(model.busy || model.media == nil)
    }

    @ViewBuilder private var segmentEditor: some View {
        if let segment = model.selected {
            Form {
                Section("Сегмент \(model.media?.timeLabel(segment.start) ?? "")") {
                    Picker("Режим", selection: Binding(get: { segment.mode }, set: { mode in var copy = segment; copy.mode = mode; model.update(copy) })) {
                        ForEach(DatamoshMode.allCases) { mode in Label(mode.title, systemImage: mode.symbol).tag(mode) }
                    }
                    HStack {
                        Text("Начало"); Spacer()
                        Text(model.media?.timeLabel(segment.start) ?? "").monospacedDigit()
                        Button("Здесь") { model.move(segment.id, to: model.frame) }
                    }
                    Stepper("Длительность: \(segment.duration) кадр.", value: Binding(get: { segment.duration }, set: { duration in
                        var copy = segment; copy.duration = duration; model.update(copy)
                    }), in: 2...(model.frameCount - segment.start))
                    Picker("Конец сегмента", selection: Binding(get: { segment.end }, set: { end in var copy = segment; copy.end = end; model.update(copy) })) {
                        Text("По длительности").tag(DatamoshEnd.duration)
                        Text("Ключевой кадр").tag(DatamoshEnd.keyframe)
                    }
                    if segment.end == .keyframe { Button("Установить конец на текущем кадре") { model.endHere() } }
                    ForEach(segment.mode.parameters) { parameter in parameterControl(parameter, segment: segment) }
                }
                Section("Общие параметры сегмента") {
                    ForEach(DatamoshMode.commonParameters) { parameter in parameterControl(parameter, segment: segment) }
                }
                Section {
                    Button("Удалить сегмент", role: .destructive) { model.remove(segment.id) }
                } footer: {
                    Text("Тяните точку, чтобы сдвинуть сегмент, правый край — чтобы изменить длительность. Ромб K сбрасывает накопление. Вне сегментов видео проходит без Datamosh.")
                }
            }.disabled(model.busy).scrollContentBackground(.hidden)
        } else {
            VStack(spacing: 10) {
                Text("Выберите кадр и нажмите «+ точка»").font(.callout)
                Text("Или удерживайте палец на миниатюрах. Затем выберите сегмент, чтобы настроить его режим.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if let exported = model.exportedURL { ShareLink("Поделиться готовым видео", item: exported) }
                Spacer(minLength: 0)
            }.padding()
        }
    }

    @ViewBuilder private func parameterControl(_ parameter: EffectParameter, segment: DatamoshSegment) -> some View {
        let binding = Binding<Float>(get: { model.document.segments.first { $0.id == segment.id }?.value(parameter.id) ?? parameter.initial }, set: { value in
            guard var copy = model.document.segments.first(where: { $0.id == segment.id }) else { return }
            copy.values[parameter.id] = value; model.update(copy)
        })
        if !parameter.choices.isEmpty {
            Picker(parameter.title, selection: binding) {
                ForEach(Array(parameter.choices.enumerated()), id: \.offset) { index, title in Text(title).tag(Float(index)) }
            }
        } else {
            VStack(spacing: 8) {
                HStack {
                    Text(parameter.title).font(.callout)
                    Spacer()
                    Text(parameter.formatted(binding.wrappedValue)).font(.system(.caption, design: .monospaced)).foregroundStyle(TrenchesTheme.accent)
                }
                Slider(value: binding, in: parameter.range, onEditingChanged: model.continuousEdit).accessibilityLabel(parameter.title).accessibilityValue(parameter.formatted(binding.wrappedValue))
            }.padding(.vertical, 4)
        }
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

private struct DatamoshTimeline: View {
    @ObservedObject var model: DatamoshEditorModel
    @State private var magnificationStart: Double?
    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, (model.media?.seconds ?? 1) * 45 * model.zoom)
            let pixelsPerFrame = width / CGFloat(model.frameCount)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    ZStack(alignment: .topLeading) {
                        Color(white: 0.07)
                        thumbnailStrip(width: width, pixelsPerFrame: pixelsPerFrame)
                        ruler(width: width)
                        ForEach(model.document.segments) { segment in
                            DatamoshTimelineSegment(segment: segment, model: model, pixelsPerFrame: pixelsPerFrame)
                                .offset(x: CGFloat(segment.start) * pixelsPerFrame, y: 72)
                        }
                        ForEach(model.document.resets, id: \.self) { frame in
                            Button { model.seek(frame) } label: {
                                Text("◇K").font(.system(.caption2, design: .monospaced)).frame(width: 44, height: 44)
                            }
                            .foregroundStyle(.orange).offset(x: CGFloat(frame) * pixelsPerFrame - 22, y: 34)
                            .contextMenu { Button("Удалить ключевой кадр", role: .destructive) { model.toggleReset(at: frame) } }
                            .accessibilityLabel("Ключевой кадр \(frame + 1)")
                        }
                        Rectangle().fill(.white).frame(width: 2, height: 116)
                            .overlay(alignment: .top) { Image(systemName: "triangle.fill").rotationEffect(.degrees(180)).font(.caption2).offset(y: -5) }
                            .offset(x: CGFloat(model.frame) * pixelsPerFrame).id("playhead").allowsHitTesting(false).accessibilityHidden(true)
                    }.frame(width: width, height: 138)
                }
                .onChange(of: model.frame) { _, _ in if model.playing { proxy.scrollTo("playhead", anchor: .center) } }
                .simultaneousGesture(MagnifyGesture().onChanged { value in
                    if magnificationStart == nil { magnificationStart = model.zoom }
                    model.zoom = min(16, max(1, (magnificationStart ?? 1) * value.magnification))
                }.onEnded { _ in magnificationStart = nil })
                .accessibilityElement(children: .contain)
            }
        }.disabled(model.busy || model.media == nil)
    }

    private func thumbnailStrip(width: CGFloat, pixelsPerFrame: CGFloat) -> some View {
        HStack(spacing: 1) {
            ForEach(model.thumbnails) { thumbnail in
                Image(uiImage: thumbnail.image).resizable().scaledToFill()
                    .frame(width: max(1, width / CGFloat(max(1, model.thumbnails.count)) - 1), height: 62).clipped()
            }
        }.frame(width: width, height: 62).background(.gray.opacity(0.15)).contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance: 0).onChanged { value in model.seek(Int(value.location.x / pixelsPerFrame)) })
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.55).sequenced(before: DragGesture(minimumDistance: 0)).onEnded { value in
                if case .second(true, let drag) = value, let drag { model.addPoint(at: Int(drag.location.x / pixelsPerFrame)) }
            })
            .accessibilityLabel("Таймлайн, кадр \(model.frame + 1) из \(model.frameCount)")
            .accessibilityAdjustableAction { direction in model.seek(model.frame + (direction == .increment ? 1 : -1)) }
            .accessibilityAction(named: "Добавить точку") { model.addPoint() }
    }

    private func ruler(width: CGFloat) -> some View {
        Canvas { context, size in
            let count = max(1, Int(width / 90))
            for index in 0...count {
                let x = CGFloat(index) * width / CGFloat(count)
                let frame = min(model.frameCount - 1, Int(CGFloat(index) / CGFloat(count) * CGFloat(model.frameCount)))
                context.draw(Text(model.media?.timeLabel(frame) ?? "").font(.system(size: 9, design: .monospaced)).foregroundStyle(.gray), at: CGPoint(x: min(width - 30, max(30, x)), y: 126))
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct DatamoshTimelineSegment: View {
    let segment: DatamoshSegment
    @ObservedObject var model: DatamoshEditorModel
    let pixelsPerFrame: CGFloat
    @State private var move: CGFloat = 0
    @State private var resize: CGFloat = 0
    var body: some View {
        let selected = model.selectedID == segment.id
        let width = max(8, CGFloat(segment.duration) * pixelsPerFrame + resize)
        HStack(spacing: 0) {
            Text(segment.mode.title).font(.system(size: 10, weight: .semibold, design: .monospaced)).lineLimit(1).padding(.leading, 6)
            Spacer(minLength: 0)
            Text(segment.end == .keyframe ? "K" : "⌟").font(.caption2).frame(width: min(28, width), height: 44)
                .contentShape(Rectangle())
                .highPriorityGesture(DragGesture(minimumDistance: 3).onChanged { value in resize = value.translation.width }.onEnded { value in
                    model.resize(segment.id, to: segment.endFrame + Int((value.translation.width / pixelsPerFrame).rounded())); resize = 0
                })
                .accessibilityLabel("Конец сегмента")
                .accessibilityAdjustableAction { direction in model.resize(segment.id, to: segment.endFrame + (direction == .increment ? 1 : -1)) }
        }
        .frame(width: width, height: 44).background(selected ? TrenchesTheme.accent : Color.gray.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
        .foregroundStyle(selected ? .black : .white).clipped().contentShape(Rectangle())
        .onTapGesture { model.selectedID = segment.id }
        .gesture(DragGesture(minimumDistance: 4).onChanged { value in move = value.translation.width; model.selectedID = segment.id }.onEnded { value in
            model.move(segment.id, to: segment.start + Int((value.translation.width / pixelsPerFrame).rounded())); move = 0
        })
        .offset(x: move)
        .contextMenu { Button("Удалить сегмент", role: .destructive) { model.remove(segment.id) } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(segment.mode.title), начало \(segment.start + 1), длительность \(segment.duration) кадров")
        .accessibilityAction(named: "Выбрать") { model.selectedID = segment.id }
        .accessibilityAction(named: "Удалить") { model.remove(segment.id) }
        .accessibilityAdjustableAction { direction in model.move(segment.id, to: segment.start + (direction == .increment ? 1 : -1)) }
    }
}
