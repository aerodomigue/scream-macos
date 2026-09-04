@testable import ScreamBar
import AudioToolbox
import CoreAudio
import Foundation
import os
import XCTest

private let coreAudioLoopbackLogger = Logger(
    subsystem: "com.screambar.tests",
    category: "CubiluxLoopback"
)

private struct CoreAudioLoopbackPreservedState: Equatable {
    let defaultInputDeviceID: AudioDeviceID
    let defaultOutputDeviceID: AudioDeviceID
    let defaultSystemOutputDeviceID: AudioDeviceID
    let inputSampleRate: Double
    let outputSampleRate: Double
    let inputBufferFrameSize: UInt32
    let outputBufferFrameSize: UInt32
    let inputHogOwner: UInt32?
    let outputHogOwner: UInt32?
}

@MainActor
final class CoreAudioCubiluxLoopbackIntegrationTests: XCTestCase {
    private static let minimumAcceptedMeasurementFraction = 0.95

    func testCubiluxTXRXHardwareLoopbackLatency() async throws {
        let configuration = CoreAudioLoopbackConfiguration()
        try configuration.requireHardwareOptIn()

        let backend = LegacyCoreAudioBackend()
        let snapshot = try backend.makeSnapshot(revision: 1)
        let input = try resolveDevice(
            uidOverride: configuration.inputUID,
            name: configuration.inputName,
            supportsDirection: \.supportsInput,
            in: snapshot.devices
        )
        let output = try resolveDevice(
            uidOverride: configuration.outputUID,
            name: configuration.outputName,
            supportsDirection: \.supportsOutput,
            in: snapshot.devices
        )
        guard abs(
            input.currentNominalSampleRate
                - output.currentNominalSampleRate
        ) <= CoreAudioLoopbackConfiguration.sampleRateTolerance else {
            throw XCTSkip(
                "Loopback requires matching current sample rates without hardware reconfiguration; input=\(input.currentNominalSampleRate), output=\(output.currentNominalSampleRate)"
            )
        }

        let sampleRate = output.currentNominalSampleRate
        let inputDeviceID = try resolveDeviceID(uid: input.id)
        let outputDeviceID = try resolveDeviceID(uid: output.id)
        let preservedState = try readPreservedState(
            inputDeviceID: inputDeviceID,
            outputDeviceID: outputDeviceID
        )
        let signalPlan = CoreAudioLoopbackSignalPlan.make(
            sampleRate: sampleRate,
            markerCount: configuration.iterationCount,
            leadSilenceSeconds:
                CoreAudioLoopbackConfiguration.leadSilenceSeconds,
            markerIntervalSeconds:
                CoreAudioLoopbackConfiguration.markerIntervalSeconds
        )
        let playbackSeconds =
            Double(signalPlan.outputSamples.count) / sampleRate
        let captureSeconds =
            CoreAudioLoopbackConfiguration.preRollSeconds
                + playbackSeconds
                + CoreAudioLoopbackConfiguration.postRollSeconds
                + 1.0
        let captureCapacityFrames = Int(
            ceil(captureSeconds * sampleRate)
        )
        let timestampCapacity = Int(
            ceil(
                Double(captureCapacityFrames)
                    / Double(
                        CoreAudioLoopbackConfiguration
                            .minimumExpectedCallbackFrames
                    )
            )
        ) + 1_024
        let startedAt = Date()
        let harness = try CoreAudioLoopbackHardwareHarness(
            inputDeviceID: inputDeviceID,
            outputDeviceID: outputDeviceID,
            inputChannelCount: input.inputChannelCount,
            outputChannelCount: output.outputChannelCount,
            sampleRate: sampleRate,
            outputSignal: signalPlan.outputSamples,
            captureCapacityFrames: captureCapacityFrames,
            maximumCallbackFrames:
                CoreAudioLoopbackConfiguration.maximumCallbackFrames,
            timestampCapacity: timestampCapacity
        )
        var harnessFinished = false
        defer {
            if !harnessFinished {
                let cleanupFailures = harness.cleanupAfterFailure()
                XCTAssertTrue(
                    cleanupFailures.isEmpty,
                    cleanupFailures.joined(separator: "; ")
                )
            }
        }

        try harness.startInput()
        try await sleep(
            seconds: CoreAudioLoopbackConfiguration.preRollSeconds
        )
        try harness.startOutput()
        try await sleep(
            seconds: playbackSeconds
                + CoreAudioLoopbackConfiguration.postRollSeconds
        )
        let rawCapture = try harness.finish()
        harnessFinished = true
        let finishedAt = Date()

        let restoredState = try readPreservedState(
            inputDeviceID: inputDeviceID,
            outputDeviceID: outputDeviceID
        )
        XCTAssertEqual(
            restoredState,
            preservedState,
            "The loopback test changed CoreAudio hardware/default state"
        )

        let channelAnalyses = rawCapture.channels.map { channelSamples in
            CoreAudioLoopbackAnalyzer.analyze(
                capture: channelSamples,
                marker: signalPlan.marker,
                markerFrameOffsets: signalPlan.markerFrameOffsets,
                inputTimestamps: rawCapture.inputTimestamps,
                outputTimestamps: rawCapture.outputTimestamps,
                sampleRate: sampleRate,
                maximumLatencySeconds:
                    CoreAudioLoopbackConfiguration.maximumLatencySeconds,
                minimumCorrelation:
                    CoreAudioLoopbackConfiguration.minimumCorrelation,
                minimumPeakToSidelobeRatio:
                    CoreAudioLoopbackConfiguration
                        .minimumPeakToSidelobeRatio
            )
        }
        guard let selectedChannelIndex = channelAnalyses.indices.max(by: {
            acceptedMeasurements(
                channelAnalyses[$0]
            ).count < acceptedMeasurements(channelAnalyses[$1]).count
        }) else {
            XCTFail("The input device exposed no capture channel")
            return
        }
        let analysis = channelAnalyses[selectedChannelIndex]
        let measurements = acceptedMeasurements(analysis)
        let acceptedMarkerTarget = Int(ceil(
            Double(
                configuration.iterationCount
                    - CoreAudioLoopbackConfiguration.warmupMeasurementCount
            ) * Self.minimumAcceptedMeasurementFraction
        ))
        let selectedSamples = rawCapture.channels[selectedChannelIndex]
        let signalLevels = measureSignalLevels(selectedSamples)
        let realtimeMetrics = CoreAudioLoopbackRTMetricsReport(
            rawCapture.metrics
        )
        let report = CoreAudioLoopbackLatencyReport(
            schemaVersion: CoreAudioLoopbackReportWriter.schemaVersion,
            measurementPath:
                CoreAudioLoopbackReportWriter.measurementPath,
            startedAt: startedAt,
            finishedAt: finishedAt,
            inputName: input.name,
            inputUID: input.id.rawValue,
            outputName: output.name,
            outputUID: output.id.rawValue,
            inputSampleRate: input.currentNominalSampleRate,
            outputSampleRate: output.currentNominalSampleRate,
            inputPhysicalFormats: input.inputPhysicalStreamFormats
                .map(\.diagnosticDescription),
            outputPhysicalFormats: output.outputPhysicalStreamFormats
                .map(\.diagnosticDescription),
            clientFormat:
                "Float32 non-interleaved, \(Int(sampleRate.rounded())) Hz",
            selectedInputChannel: selectedChannelIndex,
            requestedMarkerCount: configuration.iterationCount,
            warmupMeasurementCount:
                CoreAudioLoopbackConfiguration.warmupMeasurementCount,
            acceptedMeasurementCount: measurements.count,
            missedMarkerIndices: postWarmup(analysis.missedMarkerIndices),
            ambiguousMarkerIndices:
                postWarmup(analysis.ambiguousMarkerIndices),
            duplicateMarkerIndices:
                postWarmup(analysis.duplicateMarkerIndices),
            invalidTimestampMarkerIndices:
                postWarmup(analysis.invalidTimestampMarkerIndices),
            inconsistentMarkerIndices:
                postWarmup(analysis.inconsistentMarkerIndices),
            sampleOffsets: measurements.map(\.sampleOffset),
            measurements: measurements,
            statistics: CoreAudioLoopbackLatencyStatistics(
                measurements: measurements
            ),
            capturePeak: signalLevels.peak,
            captureRMS: signalLevels.rms,
            clippedSampleCount: signalLevels.clippedSampleCount,
            capturedFrameCount: selectedSamples.count,
            renderedFrameCount: rawCapture.renderedFrameCount,
            realtimeMetrics: realtimeMetrics,
            limitations: [
                "This is the observed complete loopback latency, not the intrinsic latency of optical conversion alone.",
                "The measurement includes CoreAudio/HAL scheduling, USB buffering, both Cubilux adapters, and TOSLINK transport.",
            ]
        )
        let reportURL = try CoreAudioLoopbackReportWriter.write(
            report,
            configuration: configuration
        )
        try CoreAudioLoopbackReportWriter.attach(report, to: self)
        log(report: report, reportURL: reportURL)

        XCTAssertFalse(
            realtimeMetrics.hasFailure,
            "Real-time capture failures: \(realtimeMetrics)"
        )
        XCTAssertGreaterThanOrEqual(
            rawCapture.renderedFrameCount,
            UInt64(signalPlan.outputSamples.count)
        )
        XCTAssertGreaterThanOrEqual(
            measurements.count,
            acceptedMarkerTarget,
            "Too many missing or ambiguous loopback markers; report: \(reportURL.path)"
        )
        XCTAssertTrue(
            postWarmup(analysis.duplicateMarkerIndices).isEmpty,
            "Duplicate marker detections were observed"
        )
        XCTAssertTrue(
            postWarmup(analysis.invalidTimestampMarkerIndices).isEmpty,
            "CoreAudio host timestamps were unavailable"
        )
        XCTAssertEqual(signalLevels.clippedSampleCount, 0)
    }

    private func acceptedMeasurements(
        _ analysis: CoreAudioLoopbackAnalysisResult
    ) -> [CoreAudioLoopbackMeasurement] {
        analysis.measurements.filter {
            $0.markerIndex
                >= CoreAudioLoopbackConfiguration.warmupMeasurementCount
        }
    }

    private func postWarmup(_ indices: [Int]) -> [Int] {
        indices.filter {
            $0 >= CoreAudioLoopbackConfiguration.warmupMeasurementCount
        }
    }

    private func resolveDevice(
        uidOverride: String?,
        name: String,
        supportsDirection: KeyPath<AudioDeviceDescriptor, Bool>,
        in devices: [AudioDeviceDescriptor]
    ) throws -> AudioDeviceDescriptor {
        let matchingDevices = devices.filter { device in
            device[keyPath: supportsDirection]
                && (uidOverride.map { device.id.rawValue == $0 }
                    ?? device.name.localizedCaseInsensitiveContains(name))
        }
        guard matchingDevices.count == 1,
              let device = matchingDevices.first else {
            if matchingDevices.isEmpty {
                throw XCTSkip(
                    "CoreAudio device matching '\(uidOverride ?? name)' is unavailable"
                )
            }
            throw XCTSkip(
                "Multiple CoreAudio devices match '\(name)'; set an explicit UID override"
            )
        }
        return device
    }

    private func resolveDeviceID(uid: AudioDeviceUID) throws -> AudioDeviceID {
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        let deviceIDs = try CoreAudioPropertyReader.readDeviceIDs(
            objectID: systemObjectID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        )
        for deviceID in deviceIDs {
            let candidateUID = try CoreAudioPropertyReader.readString(
                objectID: deviceID,
                address: AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyDeviceUID,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
            )
            if candidateUID == uid.rawValue {
                return deviceID
            }
        }
        throw CoreAudioBackendFailure(
            operation: "Resolve Cubilux loopback device",
            status: kAudioHardwareBadDeviceError
        )
    }

    private func readPreservedState(
        inputDeviceID: AudioDeviceID,
        outputDeviceID: AudioDeviceID
    ) throws -> CoreAudioLoopbackPreservedState {
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        return CoreAudioLoopbackPreservedState(
            defaultInputDeviceID: try readDefaultDevice(
                selector: kAudioHardwarePropertyDefaultInputDevice,
                systemObjectID: systemObjectID
            ),
            defaultOutputDeviceID: try readDefaultDevice(
                selector: kAudioHardwarePropertyDefaultOutputDevice,
                systemObjectID: systemObjectID
            ),
            defaultSystemOutputDeviceID: try readDefaultDevice(
                selector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                systemObjectID: systemObjectID
            ),
            inputSampleRate: try readSampleRate(deviceID: inputDeviceID),
            outputSampleRate: try readSampleRate(deviceID: outputDeviceID),
            inputBufferFrameSize: try readBufferFrameSize(
                deviceID: inputDeviceID
            ),
            outputBufferFrameSize: try readBufferFrameSize(
                deviceID: outputDeviceID
            ),
            inputHogOwner: try readHogOwnerIfAvailable(
                deviceID: inputDeviceID
            ),
            outputHogOwner: try readHogOwnerIfAvailable(
                deviceID: outputDeviceID
            )
        )
    }

    private func readDefaultDevice(
        selector: AudioObjectPropertySelector,
        systemObjectID: AudioObjectID
    ) throws -> AudioDeviceID {
        try CoreAudioPropertyReader.readAudioDeviceID(
            objectID: systemObjectID,
            address: AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        )
    }

    private func readSampleRate(
        deviceID: AudioDeviceID
    ) throws -> Double {
        try CoreAudioPropertyReader.readFloat64(
            objectID: deviceID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        )
    }

    private func readBufferFrameSize(
        deviceID: AudioDeviceID
    ) throws -> UInt32 {
        try CoreAudioPropertyReader.readUInt32(
            objectID: deviceID,
            address: AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyBufferFrameSize,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        )
    }

    private func readHogOwnerIfAvailable(
        deviceID: AudioDeviceID
    ) throws -> UInt32? {
        let address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyHogMode,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard CoreAudioPropertyReader.hasProperty(
            objectID: deviceID,
            address: address
        ) else {
            return nil
        }
        return try CoreAudioPropertyReader.readUInt32(
            objectID: deviceID,
            address: address
        )
    }

    private func sleep(seconds: Double) async throws {
        let nanoseconds = UInt64(seconds * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }

    private func measureSignalLevels(
        _ samples: [Float]
    ) -> (peak: Double, rms: Double, clippedSampleCount: Int) {
        guard !samples.isEmpty else { return (0, 0, 0) }
        var maximumMagnitude = 0.0
        var squareSum = 0.0
        var clippedSampleCount = 0
        for sample in samples {
            let magnitude = abs(Double(sample))
            maximumMagnitude = max(maximumMagnitude, magnitude)
            squareSum += magnitude * magnitude
            if magnitude >= 0.999 {
                clippedSampleCount += 1
            }
        }
        return (
            maximumMagnitude,
            sqrt(squareSum / Double(samples.count)),
            clippedSampleCount
        )
    }

    private func log(
        report: CoreAudioLoopbackLatencyReport,
        reportURL: URL
    ) {
        guard let statistics = report.statistics else {
            coreAudioLoopbackLogger.error(
                "Cubilux loopback produced no accepted measurement; report=\(reportURL.path, privacy: .public)"
            )
            return
        }
        coreAudioLoopbackLogger.notice(
            "Cubilux loopback \(report.inputSampleRate, privacy: .public) Hz: min=\(statistics.minimumMilliseconds, privacy: .public) ms, median=\(statistics.medianMilliseconds, privacy: .public) ms, p95=\(statistics.p95Milliseconds, privacy: .public) ms, max=\(statistics.maximumMilliseconds, privacy: .public) ms, jitter=\(statistics.jitterMilliseconds, privacy: .public) ms, accepted=\(report.acceptedMeasurementCount, privacy: .public)/\(report.requestedMarkerCount - report.warmupMeasurementCount, privacy: .public), report=\(reportURL.path, privacy: .public)"
        )
    }
}
