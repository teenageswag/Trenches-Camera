import AVFoundation

// Owned by the capture queue. Keep the shutter within one video frame so recording cadence stays fixed.
final class CameraShutter {
    private var requestedDuration: CMTime?
    private var nativeAutoISO = false
    private var raisedExposureLimit = false
    private var nextMeteringTime = 0.0

    static func duration(angle: Float, fps: Int32, minimum: CMTime, maximum: CMTime) -> CMTime? {
        guard angle > 0, angle.isFinite, fps > 0, minimum.isNumeric, maximum.isNumeric else { return nil }
        let frame = CMTime(value: 1, timescale: fps)
        let upper = CMTimeMinimum(maximum, frame)
        guard minimum > .zero, minimum <= upper else { return nil }
        let target = CMTime(seconds: Double(min(angle, 360)) / 360 / Double(fps), preferredTimescale: 1_000_000)
        return CMTimeMaximum(minimum, CMTimeMinimum(upper, target))
    }

    func reset() {
        requestedDuration = nil
        nativeAutoISO = false
        raisedExposureLimit = false
        nextMeteringTime = 0
    }

    func apply(to device: AVCaptureDevice, angle: Float, fps: Int32, now: Double) throws {
        guard device.isExposureModeSupported(.custom),
              let duration = Self.duration(angle: angle, fps: fps, minimum: device.activeFormat.minExposureDuration,
                                           maximum: device.activeFormat.maxExposureDuration) else {
            try restore(on: device)
            return
        }
        let format = device.activeFormat
        let changed = requestedDuration != duration || (device.exposureMode != .custom && now >= nextMeteringTime)
        if changed {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if #available(iOS 27.0, *),
               format.supportsExposureModeCustom(lensAperture: AVCaptureDevice.currentLensAperture,
                                                 duration: duration, iso: AVCaptureDevice.autoISO) {
                // Auto ISO can cap streaming exposure below the requested duration even in custom mode.
                if duration > device.activeMaxExposureDuration {
                    device.activeMaxExposureDuration = duration
                    raisedExposureLimit = true
                }
                device.setExposureModeCustom(duration: duration, iso: AVCaptureDevice.autoISO, completionHandler: nil)
                nativeAutoISO = true
            } else {
                // Preserve initial exposure when leaving AE; meter ISO again after the sensor has settled.
                let ratio = device.exposureDuration.seconds / duration.seconds
                let iso = clampedISO(device.iso * Float(ratio.isFinite && ratio > 0 ? ratio : 1), format)
                device.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
                nativeAutoISO = false
            }
            requestedDuration = duration
            nextMeteringTime = now + 0.3
            return
        }
        guard !nativeAutoISO, now >= nextMeteringTime else { return }
        nextMeteringTime = now + 0.25
        let offset = device.exposureTargetOffset, currentISO = device.iso
        guard offset.isFinite, abs(offset) > 0.15 else { return }
        let correction = min(0.5, max(-0.5, -offset * 0.5))
        let iso = clampedISO(currentISO * exp2(correction), format)
        guard abs(iso - currentISO) > max(1, currentISO * 0.02) else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
    }

    func restore(on device: AVCaptureDevice) throws {
        if raisedExposureLimit || requestedDuration != nil || device.exposureMode == .custom {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if raisedExposureLimit { device.activeMaxExposureDuration = .invalid }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            else if device.isExposureModeSupported(.autoExpose) { device.exposureMode = .autoExpose }
        }
        reset()
    }

    private func clampedISO(_ value: Float, _ format: AVCaptureDevice.Format) -> Float {
        min(format.maxISO, max(format.minISO, value.isFinite ? value : format.minISO))
    }
}
