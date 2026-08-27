@testable import ScreamBar
import XCTest

@MainActor
final class CoreAudioDeviceServiceTests: XCTestCase {
    func testMissingPreferredOutputFallsBackThenRestoresWithoutChangingSelection() async throws {
        let defaultOutput = makeDevice(uid: "output.default", supportsInput: false)
        let preferredOutput = makeDevice(uid: "output.preferred", supportsInput: false)
        let input = makeDevice(uid: "input", supportsOutput: false)
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(devices: [input, defaultOutput], input: input, output: defaultOutput)
        )
        let service = makeService(backend: backend)
        let preferredSelection = AudioDeviceSelection.device(
            uid: preferredOutput.id,
            lastKnownName: preferredOutput.name
        )

        let fallbackRoute = try await service.prepareRoute(
            inputSelection: .device(uid: input.id, lastKnownName: input.name),
            outputSelection: preferredSelection
        )
        XCTAssertEqual(fallbackRoute.route.output.id, defaultOutput.id)
        XCTAssertTrue(fallbackRoute.route.isUsingOutputFallback)

        backend.snapshot = makeSnapshot(
            devices: [input, defaultOutput, preferredOutput],
            input: input,
            output: defaultOutput
        )
        let restoredRoute = try await service.prepareRoute(
            inputSelection: .device(uid: input.id, lastKnownName: input.name),
            outputSelection: preferredSelection
        )
        XCTAssertEqual(restoredRoute.route.output.id, preferredOutput.id)
        XCTAssertFalse(restoredRoute.route.isUsingOutputFallback)
    }

    func testPresentButIncompatiblePreferredOutputDoesNotFallBack() async {
        let defaultOutput = makeDevice(uid: "output.default", supportsInput: false)
        let incompatibleOutput = makeDevice(
            uid: "output.incompatible",
            supportsInput: false,
            sampleRate: 44_100
        )
        let input = makeDevice(uid: "input", supportsOutput: false)
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(
                devices: [input, defaultOutput, incompatibleOutput],
                input: input,
                output: defaultOutput
            )
        )
        let service = makeService(backend: backend)

        do {
            _ = try await service.prepareRoute(
                inputSelection: .device(uid: input.id, lastKnownName: input.name),
                outputSelection: .device(
                    uid: incompatibleOutput.id,
                    lastKnownName: incompatibleOutput.name
                )
            )
            XCTFail("Expected incompatible preferred output to fail")
        } catch AudioRoutingError.noCommonSampleRate {
            XCTAssertTrue(backend.preparedRoutes.isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSameDeviceRouteIsPreparedOnceAtNegotiatedRate() async throws {
        let fullDuplexDevice = makeDevice(uid: "duplex")
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(
                devices: [fullDuplexDevice],
                input: fullDuplexDevice,
                output: fullDuplexDevice
            )
        )
        let service = makeService(backend: backend)

        let route = try await service.prepareRoute(
            inputSelection: .systemDefault,
            outputSelection: .systemDefault
        )

        XCTAssertEqual(route.route.input.id, fullDuplexDevice.id)
        XCTAssertEqual(route.route.output.id, fullDuplexDevice.id)
        XCTAssertEqual(route.route.nominalSampleRate, 48_000)
        XCTAssertEqual(backend.preparedRoutes.count, 1)
        XCTAssertTrue(backend.sampleRateWrites.isEmpty)
    }

    func testExplicitBufferFrameSizeIsForwardedToBackend() async throws {
        let fullDuplexDevice = makeDevice(uid: "duplex")
        let backend = CoreAudioBackendSpy(
            snapshot: makeSnapshot(
                devices: [fullDuplexDevice],
                input: fullDuplexDevice,
                output: fullDuplexDevice
            )
        )
        let service = makeService(backend: backend)

        _ = try await service.prepareRoute(
            inputSelection: .systemDefault,
            outputSelection: .systemDefault,
            requestedBufferFrameSize: 128
        )

        XCTAssertEqual(backend.preparedRoutes.first?.requestedBufferFrameSize, 128)
    }

    private func makeService(backend: CoreAudioBackendSpy) -> CoreAudioDeviceService {
        CoreAudioDeviceService(logStore: RollingLogStore(), backend: backend)
    }

    private func makeDevice(
        uid: String,
        supportsInput: Bool = true,
        supportsOutput: Bool = true,
        sampleRate: Double = 48_000
    ) -> AudioDeviceDescriptor {
        AudioDeviceDescriptor(
            id: AudioDeviceUID(rawValue: uid),
            name: uid,
            inputChannelCount: supportsInput ? 2 : 0,
            outputChannelCount: supportsOutput ? 2 : 0,
            isAlive: true,
            currentNominalSampleRate: sampleRate,
            supportedNominalSampleRates: [
                NominalSampleRateRange(minimum: sampleRate, maximum: sampleRate),
            ],
            currentBufferFrameSize: 512,
            supportedBufferFrameSizeRange: AudioBufferFrameSizeRange(
                minimum: 64,
                maximum: 2_048
            )
        )
    }

    private func makeSnapshot(
        devices: [AudioDeviceDescriptor],
        input: AudioDeviceDescriptor,
        output: AudioDeviceDescriptor
    ) -> AudioHardwareSnapshot {
        AudioHardwareSnapshot(
            revision: 1,
            devices: devices,
            defaultInputUID: input.id,
            defaultOutputUID: output.id
        )
    }
}

@MainActor
private final class CoreAudioBackendSpy: CoreAudioBackend {
    struct PreparedRouteCall: Equatable {
        let input: AudioDeviceDescriptor
        let output: AudioDeviceDescriptor
        let nominalSampleRate: Double
        let requestedBufferFrameSize: UInt32?
    }

    var onHardwareChanged: (() -> Void)?
    var snapshot: AudioHardwareSnapshot {
        didSet {
            for device in snapshot.devices where rates[device.id] == nil {
                rates[device.id] = device.currentNominalSampleRate
            }
        }
    }
    private(set) var sampleRateWrites: [(uid: AudioDeviceUID, rate: Double)] = []
    private(set) var preparedRoutes: [PreparedRouteCall] = []
    private var rates: [AudioDeviceUID: Double]

    init(snapshot: AudioHardwareSnapshot) {
        self.snapshot = snapshot
        self.rates = Dictionary(
            uniqueKeysWithValues: snapshot.devices.map { ($0.id, $0.currentNominalSampleRate) }
        )
    }

    func startMonitoring() throws {}

    func stopMonitoring() {}

    func rebuildListeners() throws {}

    func makeSnapshot(revision: UInt64) throws -> AudioHardwareSnapshot {
        AudioHardwareSnapshot(
            revision: revision,
            devices: snapshot.devices,
            defaultInputUID: snapshot.defaultInputUID,
            defaultOutputUID: snapshot.defaultOutputUID
        )
    }

    func currentNominalSampleRate(for uid: AudioDeviceUID) throws -> Double {
        guard let rate = rates[uid] else {
            throw CoreAudioBackendFailure(operation: "Read test rate", status: -1)
        }
        return rate
    }

    func setNominalSampleRate(_ rate: Double, for uid: AudioDeviceUID) throws {
        rates[uid] = rate
        sampleRateWrites.append((uid: uid, rate: rate))
    }

    func isAlive(uid: AudioDeviceUID) throws -> Bool {
        snapshot.devices.first { $0.id == uid }?.isAlive ?? false
    }

    func prepareRoute(
        input: AudioDeviceDescriptor,
        output: AudioDeviceDescriptor,
        nominalSampleRate: Double,
        requestedBufferFrameSize: UInt32?
    ) throws -> UUID {
        preparedRoutes.append(
            PreparedRouteCall(
                input: input,
                output: output,
                nominalSampleRate: nominalSampleRate,
                requestedBufferFrameSize: requestedBufferFrameSize
            )
        )
        return UUID()
    }

    func startRoute(sessionID: UUID) throws {}

    func stopAndDestroyRoute(sessionID: UUID) -> [String] {
        []
    }

    func shutdown() -> [String] {
        []
    }
}
