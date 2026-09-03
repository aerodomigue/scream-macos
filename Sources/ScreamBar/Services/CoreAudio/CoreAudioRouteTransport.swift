import Foundation

protocol CoreAudioRouteTransport: AnyObject {
    var isFullyDisposed: Bool { get }

    func start() throws
    func stopAndDispose() -> [String]
}

extension AUHALPlaythrough: CoreAudioRouteTransport {}
