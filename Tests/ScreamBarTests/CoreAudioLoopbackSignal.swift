import Foundation

struct CoreAudioLoopbackSignalPlan: Equatable {
    private static let chirpFrameCount = 1_024
    private static let chirpStartFrequency = 1_000.0
    private static let chirpEndFrequency = 12_000.0
    private static let chirpAmplitude: Float = 0.25

    let sampleRate: Double
    let marker: [Float]
    let outputSamples: [Float]
    let markerFrameOffsets: [UInt64]

    static func make(
        sampleRate: Double,
        markerCount: Int,
        leadSilenceSeconds: Double,
        markerIntervalSeconds: Double
    ) -> CoreAudioLoopbackSignalPlan {
        precondition(sampleRate.isFinite && sampleRate > 0)
        precondition(markerCount > 0)
        precondition(leadSilenceSeconds >= 0)
        precondition(markerIntervalSeconds > 0)

        let marker = makeChirp(sampleRate: sampleRate)
        let leadFrameCount = Int((leadSilenceSeconds * sampleRate).rounded())
        let intervalFrameCount = Int(
            (markerIntervalSeconds * sampleRate).rounded()
        )
        precondition(intervalFrameCount > marker.count)
        let outputFrameCount = leadFrameCount
            + ((markerCount - 1) * intervalFrameCount)
            + marker.count
        var outputSamples = [Float](repeating: 0, count: outputFrameCount)
        var markerFrameOffsets: [UInt64] = []
        markerFrameOffsets.reserveCapacity(markerCount)

        for markerIndex in 0..<markerCount {
            let frameOffset = leadFrameCount + markerIndex * intervalFrameCount
            markerFrameOffsets.append(UInt64(frameOffset))
            for sampleIndex in marker.indices {
                outputSamples[frameOffset + sampleIndex] = marker[sampleIndex]
            }
        }
        return CoreAudioLoopbackSignalPlan(
            sampleRate: sampleRate,
            marker: marker,
            outputSamples: outputSamples,
            markerFrameOffsets: markerFrameOffsets
        )
    }

    private static func makeChirp(sampleRate: Double) -> [Float] {
        let durationSeconds = Double(chirpFrameCount) / sampleRate
        let frequencySlope =
            (chirpEndFrequency - chirpStartFrequency) / durationSeconds
        return (0..<chirpFrameCount).map { sampleIndex in
            let timeSeconds = Double(sampleIndex) / sampleRate
            let phase = 2 * Double.pi * (
                chirpStartFrequency * timeSeconds
                    + 0.5 * frequencySlope * timeSeconds * timeSeconds
            )
            let window = 0.5 - 0.5 * cos(
                2 * Double.pi * Double(sampleIndex)
                    / Double(chirpFrameCount - 1)
            )
            return chirpAmplitude * Float(window * sin(phase))
        }
    }
}
