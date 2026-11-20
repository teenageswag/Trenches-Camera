import Foundation

@main
struct SettingsChecks {
    static func main() throws {
        var settings = EffectSettings()
        precondition(settings.activeCount == 0 && !settings.wantsDepth)
        for effect in EffectID.allCases {
            for parameter in effect.parameters {
                precondition(settings.value(effect, parameter.id) == parameter.initial)
                settings.set(effect, parameter.id, parameter.range.upperBound + 100)
                precondition(settings.value(effect, parameter.id) == parameter.range.upperBound)
                settings.set(effect, parameter.id, .nan)
                precondition(settings.value(effect, parameter.id) == parameter.initial)
                settings.set(effect, parameter.id, parameter.initial)
            }
            settings.toggle(effect)
        }
        precondition(settings.activeCount == EffectID.allCases.count)
        settings.set(.dof, "mode", 1)
        precondition(settings.wantsDepth)
        let restored = try JSONDecoder().decode(EffectSettings.self, from: JSONEncoder().encode(settings))
        precondition(settings == restored)
        precondition(restored.disabledEffects.activeCount == 0)
        precondition(restored.disabledEffects.value(.dof, "mode") == 1)
        precondition(restored.activeCount == EffectID.allCases.count)
        precondition(LookPreset.builtIns.count == 3)
        for preset in LookPreset.builtIns { precondition(preset.settings.activeCount > 0) }
        precondition(CaptureQuality.uhd30.width == 3840 && CaptureQuality.hd60.fps == 60)
        var rasterSettings = EffectSettings()
        rasterSettings.set(.ascii, "symbols", Float(ASCIISymbols.braille.rawValue))
        rasterSettings.set(.dither, "mode", Float(DitherMode.jarvisJudiceNinke.rawValue))
        let presetRoundTrip = try JSONDecoder().decode(LookPreset.self, from: JSONEncoder().encode(LookPreset(name: "Raster", settings: rasterSettings)))
        precondition(presetRoundTrip.settings == rasterSettings && !presetRoundTrip.settings.asciiUsesLegacyGlyphs)
        var legacyASCII = EffectSettings()
        legacyASCII.effects[.ascii] = EffectState(enabled: true, values: ["symbols": 1, "cell": 6])
        let decodedLegacy = try JSONDecoder().decode(EffectSettings.self, from: JSONEncoder().encode(legacyASCII))
        precondition(decodedLegacy == legacyASCII && decodedLegacy.asciiUsesLegacyGlyphs)
        legacyASCII.set(.ascii, "symbols", Float(ASCIISymbols.digits.rawValue))
        precondition(!legacyASCII.asciiUsesLegacyGlyphs)
        precondition(ASCIISymbols(rawValue: 0) == .standard && ASCIISymbols(rawValue: 1) == .classic)
        precondition(ASCIISymbols(rawValue: 2) == .blocks && ASCIISymbols(rawValue: 3) == .binary)
        precondition(Set(ASCIISymbols.displayOrder).count == 11)
        print("PASS: ASCII glyph IDs, legacy glyph packs, Dither and ASCII preset round trip")
        print("PASS: defaults, parameter bounds, NaN recovery, effect stacking, depth mode, JSON persistence, presets, capture profiles")
        var document = DatamoshDocument()
        let first = DatamoshSegment(start: 10, duration: 20)
        try document.put(first, frameCount: 100)
        try document.put(DatamoshSegment(start: 30, duration: 10, mode: .echo), frameCount: 100)
        precondition(document.segment(at: 9) == nil && document.segment(at: 10)?.id == first.id)
        precondition(document.segment(at: 29)?.id == first.id && document.segment(at: 30)?.mode == .echo)
        let before = document
        do { try document.put(DatamoshSegment(start: 20, duration: 20), frameCount: 100); preconditionFailure("Accepted overlap") }
        catch DatamoshEditError.overlap { precondition(document == before) }
        do { try document.put(DatamoshSegment(start: 99, duration: 2), frameCount: 100); preconditionFailure("Accepted final frame") }
        catch DatamoshEditError.lastFrame { }
        do { try document.put(DatamoshSegment(start: -1, duration: 3), frameCount: 100); preconditionFailure("Accepted negative frame") }
        catch DatamoshEditError.invalidRange { }
        do { try document.put(DatamoshSegment(start: 90, duration: Int.max), frameCount: 100); preconditionFailure("Accepted overflow") }
        catch DatamoshEditError.invalidRange { }
        var segment = first
        segment.values["reset"] = 5
        try document.put(segment, frameCount: 100)
        document.resets = [18, 18, -3, 99]
        document = try document.validated(frameCount: 100)
        precondition(document.resets == [18])
        precondition(document.replayStart(for: 19) == 18 && document.replayStart(for: 26) == 25)
        segment.mode = .transfer; try document.put(segment, frameCount: 100)
        precondition(document.replayStart(for: 19) == 18)
        precondition(document.replayStart(for: 11) == 9)
        let legacy = try JSONDecoder().decode(DatamoshDocument.self, from: JSONEncoder().encode(document))
        precondition(legacy.segments[0].donorFrame == nil && legacy.segments[0].recoveryFrames == 0)
        segment.donorFrame = 100
        do { try document.put(segment, frameCount: 100); preconditionFailure("Accepted donor outside clip") }
        catch DatamoshEditError.invalidRange { precondition(document == legacy) }
        segment.donorFrame = 81
        segment.values["recovery"] = 90
        try document.put(segment, frameCount: 100)
        precondition(document.replayStart(for: 11) == 10 && segment.recoveryFrames == 19)
        var history = DatamoshHistory()
        history.record(before)
        precondition(history.undo(document) == before && history.redo(before) == document)
        let preset = DatamoshPreset(name: "Test", frameCount: 100, document: document)
        let scaled = try preset.applied(to: 200)
        precondition(scaled.segments[0].start == 20 && scaled.segments[0].duration == 40 && scaled.resets == [36])
        precondition(scaled.segments[0].donorFrame == 162)
        let decoded = try JSONDecoder().decode(DatamoshDocument.self, from: JSONEncoder().encode(document))
        precondition(decoded == document)
        for mode in DatamoshMode.allCases {
            var segment = DatamoshSegment(start: 0, duration: 2, mode: mode)
            for parameter in mode.parameters + DatamoshMode.commonParameters {
                precondition(segment.value(parameter.id) == parameter.initial)
                segment.values[parameter.id] = .infinity
                precondition(segment.value(parameter.id) == parameter.initial)
                segment.values[parameter.id] = parameter.range.upperBound + 100
                precondition(segment.value(parameter.id) == parameter.range.upperBound)
            }
        }
        let cancellation = DatamoshCancellation(); cancellation.cancel()
        do { try cancellation.check(); preconditionFailure("Ignored cancellation") } catch is CancellationError { }
        print("PASS: Datamosh ranges, boundaries, donor frames, recovery, reset replay, undo/redo, presets, JSON, parameter bounds, cancellation")
    }
}
