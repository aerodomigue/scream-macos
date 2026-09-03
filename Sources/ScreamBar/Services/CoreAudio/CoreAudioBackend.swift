import Foundation

@MainActor
protocol CoreAudioBackend: AnyObject {
    var onHardwareChanged: (() -> Void)? { get set }

    func startMonitoring() throws
    @discardableResult
    func stopMonitoring() -> [String]
    func rebuildListeners() throws
    func makeSnapshot(revision: UInt64) throws -> AudioHardwareSnapshot
    func currentNominalSampleRate(for uid: AudioDeviceUID) throws -> Double
    func setNominalSampleRate(_ rate: Double, for uid: AudioDeviceUID) throws
    func isAlive(uid: AudioDeviceUID) throws -> Bool
    func prepareRoute(
        input: AudioDeviceDescriptor,
        output: AudioDeviceDescriptor,
        sampleRatePlan: AudioSampleRatePlan,
        requestedBufferFrameSize: UInt32?,
        validateOwnership: () throws -> Void
    ) throws -> UUID
    func startRoute(sessionID: UUID) throws
    func routeLatency(sessionID: UUID) -> CoreAudioRouteLatency?
    func stopAndDestroyRoute(sessionID: UUID) -> [String]
    func verifyRouteResourcesReleased() -> [String]
    func shutdown() -> [String]
}

struct CoreAudioRouteLatency: Equatable, Sendable {
    let estimatedApplicationSeconds: Double
    let maximumApplicationSeconds: Double
    let isLowLatency: Bool
    let requiresBufferEscalation: Bool
    let bufferEscalationReason: String?

    init(
        estimatedApplicationSeconds: Double,
        maximumApplicationSeconds: Double,
        isLowLatency: Bool,
        requiresBufferEscalation: Bool,
        bufferEscalationReason: String? = nil
    ) {
        self.estimatedApplicationSeconds = estimatedApplicationSeconds
        self.maximumApplicationSeconds = maximumApplicationSeconds
        self.isLowLatency = isLowLatency
        self.requiresBufferEscalation = requiresBufferEscalation
        self.bufferEscalationReason = bufferEscalationReason
    }
}

@MainActor
enum CoreAudioBackendFactory {
    static func makeBackend() -> any CoreAudioBackend {
        // The domain-facing service does not expose the backend generation.
        // A typed macOS 15+ backend can replace this implementation without
        // changing DirectAudioRoutingService or SwiftUI.
        LegacyCoreAudioBackend()
    }
}
