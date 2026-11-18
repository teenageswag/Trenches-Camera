import SwiftUI

struct DatamoshTimeline: View {
    @ObservedObject var model: DatamoshEditorModel
    @State private var frozenWindow: Window?
    @State private var trimPreview: Int?
    @State private var trimming: DatamoshEditorModel.Boundary?
    @State private var magnificationStart: Double?

    private struct Window {
        let first: Int
        let count: Int
        let width: CGFloat
        var pixelsPerFrame: CGFloat { width / CGFloat(count) }
        func position(_ frame: Int) -> CGFloat { CGFloat(frame - first) * pixelsPerFrame }
        func frame(at x: CGFloat) -> Int { first + Int((x / max(0.001, pixelsPerFrame)).rounded()) }
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let span = max(2, Int((Double(model.frameCount) / model.zoom).rounded(.up)))
            let first = max(0, min(model.frameCount - span, model.frame - span / 2))
            let window = frozenWindow ?? Window(first: first, count: span, width: width)
            VStack(spacing: 1) {
                filmstrip(window)
                    .frame(height: 44)
                rangeTrack(window)
                    .frame(height: 44)
            }
            .overlay(alignment: .topLeading) {
                Rectangle().fill(.white).frame(width: 2, height: 89)
                    .offset(x: min(width - 2, max(0, window.position(model.frame))))
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .simultaneousGesture(MagnifyGesture().onChanged { value in
                if magnificationStart == nil { magnificationStart = model.zoom }
                model.zoom = max(1, min(model.maxZoom, (magnificationStart ?? 1) * value.magnification))
            }.onEnded { _ in magnificationStart = nil })
        }
        .disabled(model.busy || model.media == nil)
    }

    private func filmstrip(_ window: Window) -> some View {
        Canvas { context, size in
            let columns = max(1, Int(size.width / 48))
            let width = size.width / CGFloat(columns)
            for column in 0..<columns {
                let x = CGFloat(column) * width
                let frame = window.frame(at: x + width / 2)
                guard let thumbnail = model.thumbnails.min(by: { abs($0.frame - frame) < abs($1.frame - frame) }) else { continue }
                let rect = CGRect(x: x, y: 0, width: width - 1, height: size.height)
                let image = Image(uiImage: thumbnail.image)
                let imageSize = thumbnail.image.size
                let scale = max(rect.width / imageSize.width, rect.height / imageSize.height)
                let w = imageSize.width * scale, h = imageSize.height * scale
                var tile = context
                tile.clip(to: Path(rect))
                tile.draw(image, in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
            }
            for marker in model.document.resets {
                let x = window.position(marker)
                guard (0...size.width).contains(x) else { continue }
                let diamond = Path { path in
                    path.move(to: CGPoint(x: x, y: size.height - 12))
                    path.addLines([CGPoint(x: x + 5, y: size.height - 7), CGPoint(x: x, y: size.height - 2),
                                   CGPoint(x: x - 5, y: size.height - 7)])
                    path.closeSubpath()
                }
                context.fill(diamond, with: .color(.orange))
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            guard magnificationStart == nil else { return }
            if frozenWindow == nil { frozenWindow = window }
            let dragWindow = frozenWindow ?? window
            let next = min(model.frameCount - 1, max(0, dragWindow.frame(at: value.location.x)))
            if next != model.frame || model.playing { model.seek(next) }
        }.onEnded { _ in frozenWindow = nil })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Таймлайн")
        .accessibilityValue("Кадр \(model.frame + 1) из \(model.frameCount)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.seek(model.frame + 1)
            case .decrement: model.seek(model.frame - 1)
            @unknown default: break
            }
        }
        .accessibilityAction(named: "Начало диапазона") { model.markStart() }
        .accessibilityAction(named: "Конец диапазона") { model.markEnd() }
    }

    private func rangeTrack(_ window: Window) -> some View {
        ZStack(alignment: .leading) {
            Canvas { context, size in
                for segment in model.document.segments {
                    let selected = segment.id == model.selectedID
                    let start = selected && trimming == .start ? trimPreview ?? segment.start : segment.start
                    let end = selected && trimming == .end ? trimPreview ?? segment.endFrame : segment.endFrame
                    let left = window.position(start), right = window.position(end)
                    guard right > 0, left < size.width else { continue }
                    let band = CGRect(x: left, y: 6, width: max(3, right - left), height: size.height - 12)
                    let color = selected ? TrenchesTheme.accent : Color(white: 0.35)
                    context.fill(Path(roundedRect: band, cornerRadius: 5), with: .color(color))
                    let visible = band.intersection(CGRect(origin: .zero, size: size))
                    if visible.width >= (selected ? 80 : 22) {
                        var icon = context.resolve(Image(systemName: segment.mode.symbol))
                        icon.shading = .color(selected ? .black : .white)
                        context.draw(icon, at: CGPoint(x: visible.midX, y: visible.midY))
                    }
                }
                if let start = model.pendingStart {
                    let x = window.position(start)
                    context.fill(Path(CGRect(x: x, y: 6, width: 3, height: size.height - 12)), with: .color(TrenchesTheme.accent))
                }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { tap in
                let frame = min(model.frameCount - 1, max(0, window.frame(at: tap.location.x)))
                if let segment = model.document.segment(at: frame) { model.select(segment) }
                else if let segment = model.document.segments.min(by: { distance($0, to: frame) < distance($1, to: frame) }),
                        CGFloat(distance(segment, to: frame)) * window.pixelsPerFrame < 7 {
                    model.select(segment)
                } else {
                    model.seek(frame)
                }
            })
            .accessibilityLabel("Диапазоны")
            .accessibilityValue("\(model.document.segments.count)")
            .accessibilityAction(named: "Выбрать диапазон под курсором") {
                if let segment = model.document.segment(at: model.frame) { model.select(segment) }
            }
            if let segment = model.selected {
                let start = trimming == .start ? trimPreview ?? segment.start : segment.start
                let end = trimming == .end ? trimPreview ?? segment.endFrame : segment.endFrame
                let left = window.position(start), right = window.position(end)
                if right >= 0, left <= window.width {
                    let leftVisible = window.position(segment.start) >= -1
                    let rightVisible = window.position(segment.endFrame) <= window.width + 1
                    let a = min(window.width - 22, max(22, left))
                    let b = min(window.width - 22, max(22, right))
                    let separate = leftVisible && rightVisible && b - a < 44
                    let center = min(window.width - 44, max(44, (a + b) / 2))
                    if leftVisible { grip(.start, segment: segment, window: window).offset(x: (separate ? center - 22 : a) - 22) }
                    if rightVisible { grip(.end, segment: segment, window: window).offset(x: (separate ? center + 22 : b) - 22) }
                }
            }
        }
    }

    private func distance(_ segment: DatamoshSegment, to frame: Int) -> Int {
        max(0, segment.start - frame, frame - segment.endFrame + 1)
    }

    private func grip(_ boundary: DatamoshEditorModel.Boundary, segment: DatamoshSegment, window: Window) -> some View {
        let isStart = boundary == .start
        let frame = isStart ? segment.start : segment.endFrame
        return Image(systemName: isStart ? "chevron.left" : "chevron.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: 19, height: 29)
            .background(TrenchesTheme.accent, in: RoundedRectangle(cornerRadius: 4))
            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.black.opacity(0.65)) }
            .frame(width: 44, height: 44).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global).onChanged { drag in
                if frozenWindow == nil { frozenWindow = window; model.pause(refresh: true) }
                trimming = boundary
                let delta = Int((drag.translation.width / max(0.001, window.pixelsPerFrame)).rounded())
                let limits = model.limits(for: segment, boundary: boundary)
                trimPreview = min(limits.upperBound, max(limits.lowerBound, frame + delta))
            }.onEnded { _ in
                if let target = trimPreview { model.trim(segment.id, boundary: boundary, to: target) }
                trimPreview = nil
                trimming = nil
                frozenWindow = nil
            })
            .accessibilityLabel(isStart ? "Левая граница" : "Правая граница")
            .accessibilityValue(frame == model.frameCount ? "Конец клипа" : "Кадр \(frame + 1)")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: model.trim(segment.id, boundary: boundary, to: frame + 1)
                case .decrement: model.trim(segment.id, boundary: boundary, to: frame - 1)
                @unknown default: break
                }
            }
    }
}
