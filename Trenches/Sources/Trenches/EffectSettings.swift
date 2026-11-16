import Foundation

enum EffectID: String, Codable, CaseIterable, Identifiable {
    case dof, bloom, tone, color, post, ascii, motion, shakal
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dof: return "Глубина"
        case .bloom: return "Bloom"
        case .tone: return "Свет"
        case .color: return "Цвет"
        case .post: return "POST FX"
        case .ascii: return "ASCII"
        case .motion: return "Motion blur"
        case .shakal: return "Шакализация"
        }
    }
    var subtitle: String {
        switch self {
        case .dof: return "LiDAR / художественный DOF"
        case .bloom: return "Мягкое свечение светов"
        case .tone: return "Экспозиция и тональная компрессия"
        case .color: return "Баланс и характер цвета"
        case .post: return "Зерно, растр и цифровые артефакты"
        case .ascii: return "Из света в символы"
        case .motion: return "Смаз по движению между кадрами"
        case .shakal: return "Пиксели, JPEG-блоки и потеря цвета"
        }
    }
    var symbol: String {
        switch self {
        case .dof: return "camera.aperture"
        case .bloom: return "sparkles"
        case .tone: return "sun.max"
        case .color: return "slider.horizontal.3"
        case .post: return "waveform.path"
        case .ascii: return "textformat.abc"
        case .motion: return "wind"
        case .shakal: return "square.grid.3x3"
        }
    }
    var mark: String { ["()", "**", "+/-", "RGB", "///", "#", "~>", "jpg"][Self.allCases.firstIndex(of: self)!] }
    var parameters: [EffectParameter] {
        switch self {
        case .dof: return [
            .choice("mode", "Источник глубины", ["Художественный", "LiDAR / TrueDepth"]),
            .slider("amount", "Размытие", 0...1, 0.5),
            .slider("focus", "Дистанция фокуса", 0.2...8, 1.5, unit: "м"),
            .slider("range", "Глубина резкости", 0.1...3, 0.7, unit: "м"),
            .slider("radius", "Зона резкости", 0.05...0.8, 0.25)]
        case .bloom: return [
            .slider("amount", "Интенсивность", 0...2, 0.55),
            .slider("radius", "Радиус", 1...60, 22, unit: "px")]
        case .tone: return [
            .slider("exposure", "Экспозиция", -3...3, 0, unit: "EV"),
            .choice("curve", "Тональная кривая", ["Линейная", "Reinhard", "ACES"]),
            .slider("highlights", "Света", -1...1, 0),
            .slider("shadows", "Тени", -1...1, 0)]
        case .color: return [
            .slider("temperature", "Температура", -1...1, 0),
            .slider("tint", "Оттенок", -1...1, 0),
            .slider("saturation", "Насыщенность", 0...2, 1),
            .slider("contrast", "Контраст", 0.5...2, 1),
            .slider("gamma", "Гамма", 0.5...2, 1)]
        case .post: return [
            .slider("grain", "Зерно", 0...1, 0.15),
            .slider("vignette", "Виньетка", 0...1, 0.2),
            .slider("rgb", "Сдвиг RGB", 0...20, 0, unit: "px"),
            .slider("scan", "Scanlines", 0...1, 0),
            .slider("halftone", "Халфтон", 0...1, 0),
            .slider("pixel", "Пикселизация", 1...48, 1, unit: "px")]
        case .ascii: return [
            .slider("cell", "Размер символов", 6...32, 12, unit: "px"),
            .slider("contrast", "Контраст символов", 0.5...3, 1.2),
            .choice("palette", "Палитра", ["Бумага", "Терминал", "Янтарь", "Цвет"]),
            .choice("invert", "Яркость", ["Обычная", "Инверсия"]),
            .slider("mix", "Смешивание", 0...1, 1)]
        case .motion: return [
            .slider("radius", "Длина смаза", 0...80, 16, unit: "px"),
            .slider("mix", "Смешивание", 0...1, 1)]
        case .shakal: return [
            .slider("quality", "Качество JPEG", 1...100, 14, unit: ""),
            .slider("scale", "Понижение разрешения", 1...12, 3, unit: "×"),
            .slider("chroma", "Потеря цвета", 0...1, 0.7),
            .choice("sampling", "Масштабирование", ["Пиксели", "Мыло"]),
            .slider("mix", "Смешивание", 0...1, 1),
            .choice("audio", "Шакалить звук", ["Выключено", "Включено"]),
            .slider("audioBits", "Разрядность звука", 3...16, 8, unit: "бит"),
            .slider("audioRate", "Частота звука", 2...48, 8, unit: "кГц"),
            .slider("audioMix", "Смешивание звука", 0...1, 1)]
        }
    }
}

struct EffectParameter: Identifiable {
    let id: String
    let title: String
    let range: ClosedRange<Float>
    let initial: Float
    var unit = "%"
    var choices: [String] = []

    static func slider(_ id: String, _ title: String, _ range: ClosedRange<Float>, _ initial: Float, unit: String = "%") -> Self {
        Self(id: id, title: title, range: range, initial: initial, unit: unit)
    }
    static func choice(_ id: String, _ title: String, _ values: [String]) -> Self {
        Self(id: id, title: title, range: 0...Float(values.count - 1), initial: 0, choices: values)
    }
    func formatted(_ value: Float) -> String {
        if !choices.isEmpty { return choices[min(choices.count - 1, max(0, Int(value)))] }
        if unit == "%" { return String(format: "%.0f%%", value * 100) }
        if unit.isEmpty { return String(format: "%.0f", value) }
        if unit == "°" { return String(format: "%.0f°", value) }
        if unit == "×" { return String(format: "%.1f×", value) }
        return String(format: unit == "px" ? "%.0f %@" : "%.1f %@", value, unit)
    }
}

struct EffectState: Codable, Equatable {
    var enabled = false
    var values: [String: Float] = [:]
}

struct EffectSettings: Codable, Equatable {
    var effects: [EffectID: EffectState] = [:]
    var focusX: Float = 0.5
    var focusY: Float = 0.5

    func enabled(_ effect: EffectID) -> Bool { effects[effect]?.enabled ?? false }
    func value(_ effect: EffectID, _ key: String) -> Float {
        let parameter = effect.parameters.first { $0.id == key }
        let value = effects[effect]?.values[key] ?? parameter?.initial ?? 0
        guard let parameter, value.isFinite else { return parameter?.initial ?? 0 }
        return min(parameter.range.upperBound, max(parameter.range.lowerBound, value))
    }
    mutating func set(_ effect: EffectID, _ key: String, _ value: Float) {
        var state = effects[effect] ?? EffectState()
        state.values[key] = value
        effects[effect] = state
    }
    mutating func toggle(_ effect: EffectID) {
        var state = effects[effect] ?? EffectState()
        state.enabled.toggle()
        effects[effect] = state
    }
    var wantsDepth: Bool { enabled(.dof) && value(.dof, "mode") >= 0.5 }
    var activeCount: Int { EffectID.allCases.filter { enabled($0) }.count }
    var disabledEffects: Self {
        var copy = self
        for id in copy.effects.keys { copy.effects[id]?.enabled = false }
        return copy
    }
}

struct LookPreset: Codable, Identifiable {
    var id = UUID()
    let name: String
    let settings: EffectSettings
    static var builtIns: [Self] {
        var terminal = EffectSettings()
        terminal.toggle(.ascii)
        terminal.set(.ascii, "palette", 1)
        var film = EffectSettings()
        film.toggle(.post)
        film.toggle(.bloom)
        film.toggle(.color)
        film.set(.color, "temperature", 0.15)
        film.set(.color, "saturation", 0.8)
        var raster = EffectSettings()
        raster.toggle(.post)
        raster.set(.post, "halftone", 1)
        raster.set(.post, "grain", 0)
        return [Self(name: "Терминал", settings: terminal), Self(name: "Тёплая плёнка", settings: film), Self(name: "Растр", settings: raster)]
    }
}

enum CaptureQuality: String, CaseIterable, Identifiable {
    case hd30, hd60, uhd30
    var id: String { rawValue }
    var title: String {
        switch self { case .hd30: return "1080p · 30"; case .hd60: return "1080p · 60"; case .uhd30: return "4K · 30" }
    }
    var width: Int32 { self == .uhd30 ? 3840 : 1920 }
    var height: Int32 { self == .uhd30 ? 2160 : 1080 }
    var fps: Int32 { self == .hd60 ? 60 : 30 }
}

enum CameraLens: String, CaseIterable, Identifiable {
    case ultraWide, wide, telephoto, front
    var id: String { rawValue }
    var title: String {
        switch self { case .ultraWide: return "0,5×"; case .wide: return "1×"; case .telephoto: return "5×"; case .front: return "Фронтальная" }
    }
}
