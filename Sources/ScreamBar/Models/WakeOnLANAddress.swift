import Foundation

struct WakeOnLANMACAddress: Equatable, Sendable {
    let bytes: [UInt8]

    init(_ value: String) throws {
        let separators = CharacterSet(charactersIn: ":-.")
            .union(.whitespacesAndNewlines)
        let normalized = value.unicodeScalars
            .filter { !separators.contains($0) }
            .map(String.init)
            .joined()

        let hexadecimalCharacters = CharacterSet(
            charactersIn: "0123456789abcdefABCDEF"
        )
        guard normalized.count == 12,
              normalized.unicodeScalars.allSatisfy({ hexadecimalCharacters.contains($0) }) else {
            throw WakeOnLANError.invalidMACAddress
        }

        var parsedBytes: [UInt8] = []
        parsedBytes.reserveCapacity(6)
        var index = normalized.startIndex
        for _ in 0..<6 {
            let nextIndex = normalized.index(index, offsetBy: 2)
            guard let byte = UInt8(normalized[index..<nextIndex], radix: 16) else {
                throw WakeOnLANError.invalidMACAddress
            }
            parsedBytes.append(byte)
            index = nextIndex
        }
        bytes = parsedBytes
    }
}

struct IPv4Address: Equatable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: UInt32

    init(_ value: String) throws {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else {
            throw WakeOnLANError.invalidDestination
        }

        var parsedValue: UInt32 = 0
        for component in components {
            guard !component.isEmpty,
                  component.allSatisfy(\.isNumber),
                  let octet = UInt8(component) else {
                throw WakeOnLANError.invalidDestination
            }
            parsedValue = (parsedValue << 8) | UInt32(octet)
        }
        rawValue = parsedValue
    }

    var description: String {
        [24, 16, 8, 0]
            .map { String((rawValue >> UInt32($0)) & 0xFF) }
            .joined(separator: ".")
    }
}

enum WakeOnLANDestination: Equatable, Sendable {
    case host(IPv4Address)
    case subnet(network: IPv4Address, prefixLength: UInt8)

    init(_ value: String) throws {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            throw WakeOnLANError.invalidDestination
        }

        let components = trimmedValue.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        switch components.count {
        case 1:
            self = .host(try IPv4Address(String(components[0])))
        case 2:
            guard let prefixLength = UInt8(components[1]), prefixLength <= 32 else {
                throw WakeOnLANError.invalidDestination
            }
            let address = try IPv4Address(String(components[0]))
            let mask = Self.mask(prefixLength: prefixLength)
            self = .subnet(
                network: IPv4Address(rawValue: address.rawValue & mask),
                prefixLength: prefixLength
            )
        default:
            throw WakeOnLANError.invalidDestination
        }
    }

    var packetAddress: IPv4Address {
        switch self {
        case .host(let address):
            return address
        case .subnet(let network, let prefixLength):
            return IPv4Address(
                rawValue: network.rawValue | ~Self.mask(prefixLength: prefixLength)
            )
        }
    }

    var monitoredHost: IPv4Address? {
        guard case .host(let address) = self else { return nil }
        return address
    }

    private static func mask(prefixLength: UInt8) -> UInt32 {
        guard prefixLength > 0 else { return 0 }
        return UInt32.max << UInt32(32 - prefixLength)
    }
}

extension IPv4Address {
    fileprivate init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}
