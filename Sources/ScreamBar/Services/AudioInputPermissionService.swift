import AVFoundation
import Foundation

@MainActor
protocol AudioInputPermissionServicing: AnyObject {
    func requestPermissionIfNeeded() async throws
}

@MainActor
final class AudioInputPermissionService: AudioInputPermissionServicing {
    func requestPermissionIfNeeded() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let isGranted = await AVCaptureDevice.requestAccess(for: .audio)
            guard isGranted else {
                throw AudioRoutingError.inputPermissionDenied
            }
        case .denied, .restricted:
            throw AudioRoutingError.inputPermissionDenied
        @unknown default:
            throw AudioRoutingError.inputPermissionDenied
        }
    }
}
