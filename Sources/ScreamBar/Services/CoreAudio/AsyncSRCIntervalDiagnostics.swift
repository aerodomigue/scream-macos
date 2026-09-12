import CoreAudio
import Foundation
import ScreamBarCoreAudioRT

enum AsyncSRCIntervalDiagnostics {
    private static let nanosecondsPerMillisecond = 1_000_000.0
    private static let partsPerMillion = 1_000_000.0
    private static let millisecondsPerSecond = 1_000.0

    /// Formats approximate interval measurements without attributing OS or app fault.
    static func describe(
        _ diagnostics: ScreamBarAsyncSRCDiagnostics,
        metrics: AsyncSRCMetrics,
        intervalSeconds: Double,
        inputSampleRate: Double,
        outputSampleRate: Double
    ) -> String {
        let intervalMilliseconds = decimal(intervalSeconds * millisecondsPerSecond)
        let correction = decimal((metrics.playbackRate - 1) * partsPerMillion)
        return [
            "SRC diagnostic (~\(intervalMilliseconds) ms window): FIFO peak after input \(diagnostics.maximum_fifo_frames)/\(diagnostics.ceiling_frames) frames; at poll FIFO \(metrics.readableFrames), target \(metrics.targetFillFrames)/\(metrics.maximumTargetFillFrames), rate correction \(correction) ppm",
            callbackDescription("Input", diagnostics.input, sampleRate: inputSampleRate),
            callbackDescription("Output", diagnostics.output, sampleRate: outputSampleRate)
        ].joined(separator: "\n")
    }

    private static func callbackDescription(
        _ direction: String,
        _ diagnostics: ScreamBarAsyncSRCCallbackDiagnostics,
        sampleRate: Double
    ) -> String {
        let nominalMilliseconds = sampleRate > 0
            ? decimal(Double(diagnostics.maximum_frames) / sampleRate * millisecondsPerSecond)
            : "unavailable"
        return "SRC \(direction): \(diagnostics.callback_count) callbacks, max block \(diagnostics.maximum_frames) frames @ \(decimal(sampleRate)) Hz (\(nominalMilliseconds) ms audio); max arrival gap \(milliseconds(diagnostics.maximum_arrival_gap)) ms, max elapsed execution \(milliseconds(diagnostics.maximum_execution_time)) ms (includes preemption), last arrival age \(milliseconds(diagnostics.last_arrival_age)) ms"
    }

    private static func milliseconds(_ hostTicks: UInt64) -> String {
        decimal(Double(AudioConvertHostTimeToNanos(hostTicks)) / nanosecondsPerMillisecond)
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
