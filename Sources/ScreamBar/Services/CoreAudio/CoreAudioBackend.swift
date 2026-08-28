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
        nominalSampleRate: Double,
        requestedBufferFrameSize: UInt32?,
        validateOwnership: () throws -> Void
    ) throws -> UUID
    func startRoute(sessionID: UUID) throws
    func stopAndDestroyRoute(sessionID: UUID) -> [String]
    func verifyRouteResourcesReleased() -> [String]
    func shutdown() -> [String]
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
