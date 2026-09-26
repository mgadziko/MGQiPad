import Accelerate
import AVFoundation

/// Offline renderer for app-owned audio. Apple Music-protected streams never enter this path.
final class StereoEQRenderer {
    private var leftSetup: vDSP_biquad_Setup?
    private var rightSetup: vDSP_biquad_Setup?
    private var leftDelay = Array(repeating: Float.zero, count: 64)
    private var rightDelay = Array(repeating: Float.zero, count: 64)

    deinit {
        if let leftSetup { vDSP_biquad_DestroySetup(leftSetup) }
        if let rightSetup { vDSP_biquad_DestroySetup(rightSetup) }
    }

    func render(
        _ input: AVAudioPCMBuffer,
        startingAt startFrame: AVAudioFramePosition = 0,
        left: [Float],
        right: [Float],
        leftVolume: Float = 1,
        rightVolume: Float = 1,
        frequencies: [Double]
    ) -> AVAudioPCMBuffer? {
        let start = max(0, min(Int(startFrame), Int(input.frameLength) - 1))
        let availableFrames = AVAudioFrameCount(Int(input.frameLength) - start)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: input.format.sampleRate, channels: 2, interleaved: false),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: availableFrames),
              let source = input.floatChannelData,
              let destination = output.floatChannelData else { return nil }

        configure(sampleRate: format.sampleRate, left: left, right: right, frequencies: frequencies)
        output.frameLength = availableFrames
        let frames = vDSP_Length(availableFrames)
        guard let leftSetup, let rightSetup else { return nil }
        vDSP_biquad(leftSetup, &leftDelay, source[0].advanced(by: start), 1, destination[0], 1, frames)
        let sourceRight = (input.format.channelCount > 1 ? source[1] : source[0]).advanced(by: start)
        vDSP_biquad(rightSetup, &rightDelay, sourceRight, 1, destination[1], 1, frames)
        var leftGain = min(1, max(0, leftVolume))
        var rightGain = min(1, max(0, rightVolume))
        vDSP_vsmul(destination[0], 1, &leftGain, destination[0], 1, frames)
        vDSP_vsmul(destination[1], 1, &rightGain, destination[1], 1, frames)
        return output
    }

    private func configure(sampleRate: Double, left: [Float], right: [Float], frequencies: [Double]) {
        if let leftSetup { vDSP_biquad_DestroySetup(leftSetup) }
        if let rightSetup { vDSP_biquad_DestroySetup(rightSetup) }
        leftDelay = Array(repeating: 0, count: 64)
        rightDelay = Array(repeating: 0, count: 64)
        leftSetup = coefficients(gains: left, frequencies: frequencies, sampleRate: sampleRate).withUnsafeBufferPointer { vDSP_biquad_CreateSetup($0.baseAddress!, vDSP_Length(frequencies.count)) }
        rightSetup = coefficients(gains: right, frequencies: frequencies, sampleRate: sampleRate).withUnsafeBufferPointer { vDSP_biquad_CreateSetup($0.baseAddress!, vDSP_Length(frequencies.count)) }
    }

    private func coefficients(gains: [Float], frequencies: [Double], sampleRate: Double) -> [Double] {
        frequencies.enumerated().flatMap { index, frequency -> [Double] in
            guard frequency < sampleRate / 2 else { return [1, 0, 0, 0, 0] }
            let gain = gains.indices.contains(index) ? gains[index] : 0
            let a = pow(10, Double(gain) / 40)
            let omega = 2 * Double.pi * frequency / sampleRate
            let alpha = sin(omega) / (2 * 1.4)
            let b0 = 1 + alpha * a, b1 = -2 * cos(omega), b2 = 1 - alpha * a
            let a0 = 1 + alpha / a, a1 = -2 * cos(omega), a2 = 1 - alpha / a
            return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
        }
    }
}
