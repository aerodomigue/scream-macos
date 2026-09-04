import XCTest
@testable import ScreamBar

final class MenuBarStatusDescriptionTests: XCTestCase {
    func testSelectedRunningRouteValuesAreFormattedInStableOrder() {
        let description = MenuBarStatusDescription.make(
            configuration: MenuBarDisplayConfiguration(
                showFrames: true,
                showApplicationLatency: true
            ),
            routingState: .running(makeRoute())
        )

        XCTAssertEqual(description, "64 frames · 4.2 ms")
    }

    func testEachValueCanBeSelectedIndependently() {
        let route = AudioRoutingState.running(makeRoute())

        XCTAssertEqual(
            MenuBarStatusDescription.make(
                configuration: MenuBarDisplayConfiguration(showFrames: true),
                routingState: route
            ),
            "64 frames"
        )
        XCTAssertEqual(
            MenuBarStatusDescription.make(
                configuration: MenuBarDisplayConfiguration(
                    showApplicationLatency: true
                ),
                routingState: route
            ),
            "4.2 ms"
        )
    }

    func testUnavailableOrUnselectedValuesDoNotShowStaleText() {
        XCTAssertNil(
            MenuBarStatusDescription.make(
                configuration: MenuBarDisplayConfiguration(
                    showFrames: true,
                    showApplicationLatency: true
                ),
                routingState: .stopped
            )
        )
        XCTAssertNil(
            MenuBarStatusDescription.make(
                configuration: MenuBarDisplayConfiguration(),
                routingState: .running(makeRoute())
            )
        )
    }

    private func makeRoute() -> EffectiveAudioRoute {
        let input = makeDevice(uid: "input", inputChannels: 2, outputChannels: 0)
        let output = makeDevice(uid: "output", inputChannels: 0, outputChannels: 2)
        return EffectiveAudioRoute(
            input: input,
            output: output,
            sampleRatePlan: .converted(
                inputSampleRate: 48_000,
                outputSampleRate: 44_100
            ),
            isUsingOutputFallback: false,
            bufferFrameSize: 64,
            estimatedApplicationLatencySeconds: 0.0042
        )
    }

    private func makeDevice(
        uid: String,
        inputChannels: Int,
        outputChannels: Int
    ) -> AudioDeviceDescriptor {
        AudioDeviceDescriptor(
            id: AudioDeviceUID(rawValue: uid),
            name: uid,
            inputChannelCount: inputChannels,
            outputChannelCount: outputChannels,
            isAlive: true,
            currentNominalSampleRate: 48_000,
            supportedNominalSampleRates: [
                NominalSampleRateRange(minimum: 44_100, maximum: 48_000),
            ]
        )
    }
}
