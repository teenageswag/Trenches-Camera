import Foundation

enum EffectID: String, Codable, CaseIterable, Identifiable {
    case dof, bloom, tone, color, post, dither, ascii, motion, shakal, macroblock, lensFlare
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dof: return "Глубина"
        case .bloom: return "Bloom"
        case .tone: return "Свет"
        case .color: return "Цвет"
        case .post: return "POST FX"
        case .dither: return "Dither"
        case .ascii: return "ASCII"
        case .motion: return "Motion blur"
        case .shakal: return "Шакализация"
        case .macroblock: return "Macroblock"
        case .lensFlare: return "Lens flare"
        }
    }
    var subtitle: String {
        switch self {
        case .dof: return "LiDAR / художественный DOF"
        case .bloom: return "Мягкое свечение светов"
        case .tone: return "Экспозиция и тональная компрессия"
        case .color: return "Баланс и характер цвета"
        case .post: return "Зерно, растр и цифровые артефакты"
        case .dither: return "Дизеринг с ограниченной палитрой"
        case .ascii: return "Из света в символы"
        case .motion: return "Выдержка камеры. 180° — половина интервала между кадрами, 0° — автоматическая выдержка."
        case .shakal: return "Пиксели, JPEG-блоки и потеря цвета"
        case .macroblock: return "Смещение блоков по времени и seed"
        case .lensFlare: return "Отражения света и пыль на линзе"
        }
    }
    var symbol: String {
        switch self {
        case .dof: return "camera.aperture"
        case .bloom: return "sparkles"
        case .tone: return "sun.max"
        case .color: return "slider.horizontal.3"
        case .post: return "waveform.path"
        case .dither: return "circle.lefthalf.filled"
        case .ascii: return "textformat.abc"
        case .motion: return "wind"
        case .shakal: return "square.grid.3x3"
        case .macroblock: return "square.grid.4x3.fill"
        case .lensFlare: return "camera.filters"
        }
    }
    var mark: String { ["()", "**", "+/-", "RGB", "///", ":.:", "#", "~>", "jpg", "8×8", "(*)"][Self.allCases.firstIndex(of: self)!] }
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
        case .dither: return DitherMode.parameters
        case .ascii: return ASCIIMode.parameters
        case .motion: return [
            .slider("shutter", "Угол затвора", 0...360, 180, unit: "°")]
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
        case .macroblock: return [
            .choice("block", "Размер блока", ["8×8 px", "16×16 px"]),
            .slider("amount", "Смещение", 0...128, 32, unit: "px"),
            .slider("fraction", "Доля блоков", 0...1, 0.3),
            .slider("rate", "Обновление", 1...30, 12, unit: "Гц"),
            .slider("seed", "Seed", 0...65535, 1, unit: "")]
        case .lensFlare: return [
            .slider("amount", "Интенсивность flare", 0...3, 0.6),
            .slider("dirt", "Интенсивность dirt", 0...4, 1),
            .slider("threshold", "Порог яркости", 0.1...1, 0.7)]
        }
    }
}

enum DitherMode: Int, CaseIterable {
    case bayer2, bayer4, bayer8, blueNoise, whiteNoise, floydSteinberg, atkinson, jarvisJudiceNinke, stucki, sierra, burkes

    var title: String {
        switch self {
        case .bayer2: return "Bayer 2×2"
        case .bayer4: return "Bayer 4×4"
        case .bayer8: return "Bayer 8×8"
        case .blueNoise: return "Blue noise"
        case .whiteNoise: return "White noise"
        case .floydSteinberg: return "Floyd–Steinberg"
        case .atkinson: return "Atkinson"
        case .jarvisJudiceNinke: return "Jarvis–Judice–Ninke"
        case .stucki: return "Stucki"
        case .sierra: return "Sierra"
        case .burkes: return "Burkes"
        }
    }

    var diffusesError: Bool { rawValue >= Self.floydSteinberg.rawValue }

    static let parameters: [EffectParameter] = [
        .choice("mode", "Режим", allCases.map(\.title), initial: bayer4.rawValue),
        .slider("pixel", "Размер пикселя", 1...64, 4, unit: "px", step: 1),
        .slider("threshold", "Порог", 0...1, 0.5),
        .slider("intensity", "Интенсивность", 0...1, 1),
        .slider("levels", "Уровни", 2...16, 2, unit: "", step: 1),
        .choice("palette", "Палитра", DitherPalette.allCases.map(\.title)),
        .slider("mix", "Смешивание", 0...1, 1),
        .slider("darkR", "", 0...1, 0.06), .slider("darkG", "", 0...1, 0.08), .slider("darkB", "", 0...1, 0.12),
        .slider("lightR", "", 0...1, 1), .slider("lightG", "", 0...1, 0.81), .slider("lightB", "", 0...1, 0.55)
    ]
}

enum DitherPalette: Int, CaseIterable {
    case monochrome, duotone, source, handheld, phosphor, risograph
    var title: String { ["Чёрно-белая", "Дуотон", "Цвета кадра", "Зелёный LCD", "Янтарный CRT", "Ризограф"][rawValue] }
}

enum ASCIISymbols: Int, CaseIterable {
    // The first four IDs are already serialized in presets.
    case standard, classic, blocks, binary, medium, braille, digits, matrix, silk, pencil, code

    static let displayOrder: [Self] = [.classic, .standard, .medium, .blocks, .braille, .binary, .digits, .matrix, .silk, .pencil, .code]
    var title: String { ["Standard (10)", "Classic (70)", "Blocks", "Binary", "Medium (15)", "Braille",
                         "Digits", "Matrix", "Silk", "Pencil", "Code"][rawValue] }
    var sortsByDensity: Bool { self == .binary || self == .digits || self == .matrix }

    var characters: String {
        switch self {
        case .standard: return " .:-=+*#%@"
        case .classic: return " .'\u{60}^\",:;Il!i><~+_-?][}{1)(|\\/tfjrxnuvczXYUJCLQ0OZmwqpdbkhao*#MW&8%B@$"
        case .blocks: return " ░▒▓█"
        case .binary: return " 01"
        case .medium: return " .,:;i1tfLCG08@"
        case .braille: return "⠀⠁⠃⠇⡇⣇⣧⣷⣿"
        case .digits: return " 1234567890"
        case .matrix: return " .ｱｲｳｴｵｶｷｸｹｺ"
        case .silk: return " .'\u{60}^\",:;~-+=*xo#%@"
        case .pencil: return " .,:;-~=+*xX#&@"
        case .code: return " .:/\\|()[]{}<>#@"
        }
    }
}

enum ASCIIPlacement: Int, CaseIterable {
    case darkest, brightest, mostColorful
    var title: String { ["Тёмные участки", "Светлые участки", "Самые цветные"][rawValue] }
}

enum ASCIIMode: Int, CaseIterable {
    case ascii, blur, glow

    var title: String { ["ASCII", "ASCII Blur", "ASCII Glow"][rawValue] }

    private static let shared: [EffectParameter] = [
        .choice("mode", "Режим", allCases.map(\.title)),
        .choice("characterOn", "Где рисовать символы", ASCIIPlacement.allCases.map(\.title)),
        .choice("symbols", "Символы", ASCIISymbols.allCases.map(\.title))
    ]
    static let parameters = shared + allCases.flatMap(\.specificParameters)
    var editableParameters: [EffectParameter] { Self.shared + specificParameters }

    private static let plainParameters: [EffectParameter] = [
        .slider("cell", "Размер символов", 2...96, 12, unit: "px"),
        .slider("contrast", "Контраст символов", 0.1...10, 1.2),
        .choice("palette", "Палитра", ["Бумага", "Терминал", "Янтарь", "Цвет кадра", "Свой цвет", "Градиент"]),
        .choice("invert", "Яркость", ["Обычная", "Инверсия"]),
        .slider("mix", "Смешивание", 0...1, 1),
        .slider("inkR", "", 0...1, 0.84), .slider("inkG", "", 0...1, 0.97), .slider("inkB", "", 0...1, 0.37),
        .slider("ink2R", "", 0...1, 1), .slider("ink2G", "", 0...1, 0.3), .slider("ink2B", "", 0...1, 0.6),
        .slider("paperR", "", 0...1, 0), .slider("paperG", "", 0...1, 0), .slider("paperB", "", 0...1, 0)
    ]
    private static let blurParameters: [EffectParameter] = [
        .slider("blurCell", "Размер символов", 2...96, 6, unit: "px", step: 1),
        .slider("blurCoverage", "Покрытие", 0...1, 1),
        .slider("blurSoftness", "Мягкость краёв", 0...1, 1),
        .slider("blurGap", "Зазор", 0...1, 0.2),
        .slider("blurExposure", "Экспозиция", 0...2, 1),
        .slider("blurScatter", "Разброс", 0...1, 0),
        .slider("blurInk", "Непрозрачность символов", 0...1, 1),
        .slider("blurPhoto", "Непрозрачность кадра", 0...1, 0.7),
        .slider("blurBackground", "Размытие фона", 0...1, 0.2)
    ]
    private static let glowParameters: [EffectParameter] = [
        .choice("glowPalette", "Цвет", ["Один цвет", "Градиент"]),
        .slider("glowCell", "Размер символов", 2...96, 16, unit: "px", step: 1),
        .slider("glowContrast", "Контраст", -1...1, 0, unit: "", step: 0.01),
        .slider("glowGap", "Зазор", 0...1, 0.2),
        .slider("glowExposure", "Экспозиция", 0...2, 1.2),
        .slider("glowStrength", "Свечение", 0...1, 0.6),
        .slider("glowGhost", "Фоновая сетка", 0...1, 0.5),
        .slider("glowPhoto", "Непрозрачность кадра", 0...1, 0.7),
        .slider("glowMix", "Смешивание", 0...1, 1),
        .slider("glowInkR", "", 0...1, 0.41), .slider("glowInkG", "", 0...1, 0.96), .slider("glowInkB", "", 0...1, 0.77),
        .slider("glowInk2R", "", 0...1, 0.94), .slider("glowInk2G", "", 0...1, 0.37), .slider("glowInk2B", "", 0...1, 0.77)
    ]

    private var specificParameters: [EffectParameter] {
        switch self {
        case .ascii: return Self.plainParameters
        case .blur: return Self.blurParameters
        case .glow: return Self.glowParameters
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
    var step: Float?

    static func slider(_ id: String, _ title: String, _ range: ClosedRange<Float>, _ initial: Float, unit: String = "%", step: Float? = nil) -> Self {
        Self(id: id, title: title, range: range, initial: initial, unit: unit, step: step)
    }
    static func choice(_ id: String, _ title: String, _ values: [String], initial: Int = 0) -> Self {
        Self(id: id, title: title, range: 0...Float(values.count - 1), initial: Float(initial), choices: values)
    }
    func formatted(_ value: Float) -> String {
        if !choices.isEmpty { return choices[min(choices.count - 1, max(0, Int(value)))] }
        if unit == "%" { return String(format: "%.0f%%", value * 100) }
        if unit.isEmpty { return String(format: (step ?? 1) < 1 ? "%.2f" : "%.0f", value) }
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
        var state = effects[effect] ?? Self.defaults(for: effect)
        if effect == .ascii && key == "symbols" { state.values["atlasVersion"] = 1 }
        state.values[key] = value
        effects[effect] = state
    }
    mutating func toggle(_ effect: EffectID) {
        var state = effects[effect] ?? Self.defaults(for: effect)
        state.enabled.toggle()
        effects[effect] = state
    }

    mutating func reset(_ effect: EffectID) {
        var state = Self.defaults(for: effect)
        state.enabled = enabled(effect)
        effects[effect] = state
    }

    private static func defaults(for effect: EffectID) -> EffectState {
        EffectState(values: effect == .ascii ? ["characterOn": 0, "atlasVersion": 1] : [:])
    }

    var asciiMode: ASCIIMode { ASCIIMode(rawValue: Int(value(.ascii, "mode"))) ?? .ascii }
    var asciiUsesLegacyPlacement: Bool {
        asciiMode == .ascii && effects[.ascii].map { $0.values["characterOn"] == nil } == true
    }
    var asciiUsesLegacyGlyphs: Bool {
        asciiMode == .ascii && effects[.ascii].map { $0.values["atlasVersion"] == nil } == true
    }
    var wantsDepth: Bool { enabled(.dof) && value(.dof, "mode") >= 0.5 }
    var shutterAngle: Float { enabled(.motion) ? value(.motion, "shutter") : 0 }
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
        terminal.effects[.ascii] = EffectState(enabled: true, values: ["palette": 1])
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
