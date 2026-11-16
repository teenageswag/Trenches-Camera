import Foundation

enum DatamoshMode: String, Codable, CaseIterable, Identifiable {
    case melt, bloom, freeze, transfer, macroblock, vector, echo
    var id: String { rawValue }
    var title: String { switch self {
    case .melt: return "Melt / P-frame smear"
    case .bloom: return "Bloom / накопление"
    case .freeze: return "Freeze / Hold"
    case .transfer: return "Transfer"
    case .macroblock: return "Macroblock corruption"
    case .vector: return "Vector glitch"
    case .echo: return "Echo / Trail"
    } }
    var symbol: String { switch self {
    case .melt: return "drop"
    case .bloom: return "arrow.up.left.and.arrow.down.right"
    case .freeze: return "pause.rectangle"
    case .transfer: return "arrow.left.arrow.right"
    case .macroblock: return "square.grid.3x3"
    case .vector: return "arrow.triangle.branch"
    case .echo: return "square.stack.3d.up"
    } }
    var index: Int { Self.allCases.firstIndex(of: self)! }
    var parameters: [EffectParameter] { switch self {
    case .melt, .transfer: return []
    case .bloom: return [.slider("accumulation", "Скорость накопления", 0...3, 0.7), .slider("decay", "Затухание векторов", 0...0.999, 0.96)]
    case .freeze: return [.slider("threshold", "Порог движения", 0.005...0.5, 0.06)]
    case .macroblock: return [.slider("fraction", "Доля повреждённых блоков", 0...1, 0.4)]
    case .vector: return [.choice("distortion", "Искажение", ["Инверсия", "Умножение", "Поворот", "Шум"]), .slider("distortionAmount", "Сила искажения", 0...4, 1.5, unit: "×")]
    case .echo: return [.slider("trail", "Длина шлейфа", 1...120, 12, unit: "кадр."), .slider("decay", "Затухание шлейфа", 0.05...0.99, 0.7)]
    } }
    static var commonParameters: [EffectParameter] { [
        .slider("strength", "Сила размазывания", 0...1, 0.85),
        .choice("block", "Размер блока", ["8 px", "16 px", "32 px"]),
        .choice("estimation", "Оценка движения", ["Блочная · быстрее", "Оптический поток · качественнее"]),
        .slider("reset", "Интервал авто-сброса (0 — выкл.)", 0...300, 0, unit: "кадр."),
        .slider("seed", "Seed", 0...65535, 1, unit: "")
    ] }
}

enum DatamoshEnd: String, Codable, CaseIterable { case duration, keyframe }

struct DatamoshSegment: Codable, Equatable, Identifiable {
    var id = UUID()
    var start: Int
    var duration: Int
    var mode = DatamoshMode.melt
    var end = DatamoshEnd.duration
    var values: [String: Float] = [:]
    var endFrame: Int { start + duration }
    func value(_ key: String) -> Float {
        let parameter = (mode.parameters + DatamoshMode.commonParameters).first { $0.id == key }
        let value = values[key] ?? parameter?.initial ?? 0
        guard value.isFinite, let parameter else { return parameter?.initial ?? 0 }
        return min(parameter.range.upperBound, max(parameter.range.lowerBound, value))
    }
    var blockSize: Int { [8, 16, 32][Int(value("block"))] }
    var resetInterval: Int { Int(value("reset").rounded()) }
}

enum DatamoshEditError: LocalizedError {
    case lastFrame, overlap, invalidRange
    var errorDescription: String? { switch self {
    case .lastFrame: return "Точка на последнем кадре пропущена: после неё нет движения."
    case .overlap: return "Сегменты не могут пересекаться. Сдвиньте точку или сократите длительность."
    case .invalidRange: return "Сегмент должен занимать минимум два кадра и находиться внутри видео."
    } }
}

struct DatamoshDocument: Codable, Equatable {
    var segments: [DatamoshSegment] = []
    var resets: [Int] = []

    func segment(at frame: Int) -> DatamoshSegment? { segments.first { frame >= $0.start && frame < $0.endFrame } }

    mutating func put(_ segment: DatamoshSegment, frameCount: Int) throws {
        guard segment.start < frameCount - 1 else { throw DatamoshEditError.lastFrame }
        guard segment.start >= 0, segment.duration >= 2, segment.start <= frameCount - segment.duration else { throw DatamoshEditError.invalidRange }
        guard !segments.contains(where: { $0.id != segment.id && segment.start < $0.endFrame && $0.start < segment.endFrame }) else { throw DatamoshEditError.overlap }
        segments.removeAll { $0.id == segment.id }
        segments.append(segment)
        segments.sort { $0.start < $1.start }
    }

    func replayStart(for frame: Int) -> Int {
        guard let segment = segment(at: frame) else { return frame }
        var start = segment.start
        if let marker = resets.filter({ $0 >= start && $0 <= frame }).max() { start = marker }
        if segment.resetInterval > 0 { start = max(start, segment.start + ((frame - segment.start) / segment.resetInterval) * segment.resetInterval) }
        return segment.mode == .transfer && start == segment.start ? max(0, start - 1) : start
    }

    func validated(frameCount: Int) throws -> Self {
        var result = Self()
        for segment in segments { try result.put(segment, frameCount: frameCount) }
        result.resets = Array(Set(resets.filter { $0 >= 0 && $0 < frameCount - 1 })).sorted()
        return result
    }
}

struct DatamoshHistory {
    private(set) var undoStack: [DatamoshDocument] = []
    private(set) var redoStack: [DatamoshDocument] = []
    mutating func record(_ document: DatamoshDocument) {
        undoStack.append(document)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }
    mutating func undo(_ document: DatamoshDocument) -> DatamoshDocument? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(document); return previous
    }
    mutating func redo(_ document: DatamoshDocument) -> DatamoshDocument? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(document); return next
    }
}

struct DatamoshPreset: Codable, Identifiable {
    var id = UUID()
    var name: String
    var frameCount: Int
    var document: DatamoshDocument

    func applied(to count: Int) throws -> DatamoshDocument {
        guard count >= 2, frameCount >= 2 else { throw DatamoshEditError.invalidRange }
        let scale = Double(count) / Double(frameCount)
        var result = DatamoshDocument()
        for var segment in document.segments {
            let end = min(count, Int((Double(segment.endFrame) * scale).rounded()))
            segment.id = UUID()
            segment.start = min(count - 2, Int((Double(segment.start) * scale).rounded()))
            segment.duration = max(2, end - segment.start)
            if let previous = result.segments.last, segment.start < previous.endFrame { throw DatamoshEditError.overlap }
            try result.put(segment, frameCount: count)
        }
        result.resets = document.resets.map { min(count - 2, Int((Double($0) * scale).rounded())) }
        return try result.validated(frameCount: count)
    }
}

final class DatamoshCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}

struct DatamoshCapture: Identifiable { var id: URL { url }; let url: URL }
