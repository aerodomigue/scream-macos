import Foundation
import XCTest

struct CoreAudioLoopbackConfiguration {
    static let hardwareOptInKey =
        "SCREAMBAR_RUN_CUBILUX_LOOPBACK_TESTS"
    static let inputNameKey =
        "SCREAMBAR_CUBILUX_LOOPBACK_INPUT_NAME"
    static let outputNameKey =
        "SCREAMBAR_CUBILUX_LOOPBACK_OUTPUT_NAME"
    static let inputUIDKey =
        "SCREAMBAR_CUBILUX_LOOPBACK_INPUT_UID"
    static let outputUIDKey =
        "SCREAMBAR_CUBILUX_LOOPBACK_OUTPUT_UID"
    static let iterationCountKey =
        "SCREAMBAR_CUBILUX_LOOPBACK_ITERATIONS"
    static let reportDirectoryKey =
        "SCREAMBAR_CUBILUX_LOOPBACK_REPORT_DIRECTORY"

    static let defaultInputName = "Cubilux SPDIF Receiver"
    static let defaultOutputName = "USB SPDIF Adapter"
    static let defaultIterationCount = 100
    static let warmupMeasurementCount = 5
    static let preRollSeconds = 0.25
    static let postRollSeconds = 0.50
    static let leadSilenceSeconds = 0.25
    static let markerIntervalSeconds = 0.20
    static let maximumLatencySeconds = 0.15
    static let minimumCorrelation = 0.55
    static let minimumPeakToSidelobeRatio = 1.20
    static let maximumCallbackFrames: UInt32 = 4_096
    static let minimumExpectedCallbackFrames: UInt32 = 16
    static let sampleRateTolerance = 0.5

    let environment: [String: String]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    var inputName: String {
        environment[Self.inputNameKey] ?? Self.defaultInputName
    }

    var outputName: String {
        environment[Self.outputNameKey] ?? Self.defaultOutputName
    }

    var inputUID: String? {
        nonemptyValue(for: Self.inputUIDKey)
    }

    var outputUID: String? {
        nonemptyValue(for: Self.outputUIDKey)
    }

    var iterationCount: Int {
        guard let rawValue = environment[Self.iterationCountKey],
              let value = Int(rawValue),
              value >= Self.warmupMeasurementCount + 1 else {
            return Self.defaultIterationCount
        }
        return value
    }

    var reportDirectoryPath: String? {
        nonemptyValue(for: Self.reportDirectoryKey)
            ?? nonemptyValue(
                for: CoreAudioLongSoakConfiguration.reportDirectoryKey
            )
    }

    func requireHardwareOptIn() throws {
        guard environment[Self.hardwareOptInKey] == "1" else {
            throw XCTSkip(
                "Set \(Self.hardwareOptInKey)=1 to run the Cubilux hardware loopback test"
            )
        }
    }

    private func nonemptyValue(for key: String) -> String? {
        guard let value = environment[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
