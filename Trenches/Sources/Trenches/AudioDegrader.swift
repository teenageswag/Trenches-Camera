import AVFoundation

// Owned by the capture queue. Sample-and-hold keeps the source time base intact.
final class AudioDegrader {
    private var phase = 0.0
    private var held: [Float] = []

    func reset() { phase = 0; held.removeAll() }

    func process(_ sample: CMSampleBuffer, settings: EffectSettings) throws -> CMSampleBuffer {
        guard settings.enabled(.shakal), settings.value(.shakal, "audio") > 0.5 else { reset(); return sample }
        guard let description = CMSampleBufferGetFormatDescription(sample) else {
            throw TrenchesError.message("Микрофон не передал формат звука.")
        }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard format.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM else {
            throw TrenchesError.message("Микрофон вернул неподдерживаемый формат звука.")
        }
        let count = CMSampleBufferGetNumSamples(sample)
        guard count > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return sample }
        pcm.frameLength = AVAudioFrameCount(count)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count), into: pcm.mutableAudioBufferList) == noErr else {
            throw TrenchesError.message("Не удалось прочитать звук микрофона.")
        }
        let channels = Int(format.channelCount)
        guard channels > 0, format.sampleRate > 0 else { return sample }
        if held.count != channels { held = Array(repeating: 0, count: channels); phase = 0 }
        let step = min(1, Double(settings.value(.shakal, "audioRate")) * 1000 / format.sampleRate)
        let levels = pow(Float(2), settings.value(.shakal, "audioBits").rounded() - 1)
        let mix = settings.value(.shakal, "audioMix")
        var output = [Int16](repeating: 0, count: count * channels)
        for frame in 0..<count {
            let update = phase <= 0
            for channel in 0..<channels {
                let buffer = format.isInterleaved ? 0 : channel
                let index = format.isInterleaved ? frame * channels + channel : frame
                let value: Float
                switch format.commonFormat {
                case .pcmFormatFloat32: value = pcm.floatChannelData![buffer][index]
                case .pcmFormatInt16: value = Float(pcm.int16ChannelData![buffer][index]) / 32768
                case .pcmFormatInt32: value = Float(pcm.int32ChannelData![buffer][index]) / 2147483648
                default: throw TrenchesError.message("Разрядность микрофона не поддерживается.")
                }
                let clean = value.isFinite ? min(1, max(-1, value)) : 0
                if update { held[channel] = (clean * levels).rounded() / levels }
                output[frame * channels + channel] = Int16(min(32767, max(-32768, ((clean + (held[channel] - clean) * mix) * 32768).rounded())))
            }
            if update { phase += 1 }
            phase -= step
        }
        var asbd = AudioStreamBasicDescription(mSampleRate: format.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: UInt32(channels * 2),
            mFramesPerPacket: 1, mBytesPerFrame: UInt32(channels * 2), mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 16, mReserved: 0)
        var outputFormat: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &outputFormat) == noErr, let outputFormat else {
            throw TrenchesError.message("Не удалось создать формат обработанного звука.")
        }
        var block: CMBlockBuffer?
        let length = output.count * MemoryLayout<Int16>.size
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block) == noErr, let block else {
            throw TrenchesError.message("Недостаточно памяти для звука.")
        }
        let copied = output.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample), decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        guard copied == noErr, CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: outputFormat,
            sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &result) == noErr, let result else { throw TrenchesError.message("Не удалось обработать звук.") }
        return result
    }
}
