import Foundation

enum WakeOnLANError: LocalizedError, Equatable {
    case invalidMACAddress
    case invalidDestination
    case socketCreationFailed(Int32)
    case broadcastConfigurationFailed(Int32)
    case sendFailed(Int32)
    case incompleteSend(expected: Int, actual: Int)
    case pingLaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidMACAddress:
            return "Enter a valid 6-byte MAC address"
        case .invalidDestination:
            return "Enter an IPv4 address or IPv4 subnet in CIDR notation"
        case .socketCreationFailed(let errorCode):
            return "Could not create the WOL socket (errno \(errorCode))"
        case .broadcastConfigurationFailed(let errorCode):
            return "Could not enable UDP broadcast (errno \(errorCode))"
        case .sendFailed(let errorCode):
            return "Could not send the magic packet (errno \(errorCode))"
        case .incompleteSend(let expected, let actual):
            return "Magic packet send was incomplete (\(actual)/\(expected) bytes)"
        case .pingLaunchFailed(let message):
            return "Could not launch ping: \(message)"
        }
    }
}
