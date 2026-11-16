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
        print("PASS: defaults, parameter bounds, NaN recovery, effect stacking, depth mode, JSON persistence, presets, capture profiles")
    }
}
