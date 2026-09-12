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

struct WakeOnLANDestination: Equatable, Sendable {
    private static let maximumBroadcastPrefixLength: UInt8 = 30
    private static let addressBitCount: UInt32 = 32

    let address: IPv4Address
    let prefixLength: UInt8

    init(_ value: String) throws {
        let components = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
              let prefixLength = UInt8(components[1]),
              prefixLength <= Self.maximumBroadcastPrefixLength else {
            throw WakeOnLANError.invalidDestination
        }
        address = try IPv4Address(String(components[0]))
        self.prefixLength = prefixLength
    }

    var packetAddress: IPv4Address {
        IPv4Address(rawValue: address.rawValue | ~mask)
    }

    var monitoredHost: IPv4Address? {
        let hostBits = address.rawValue & ~mask
        // Retain broadcast-only network configurations without pinging a
        // network or broadcast address as though it were an individual host.
        guard hostBits != 0, hostBits != ~mask else { return nil }
        return address
    }

    private var mask: UInt32 {
        guard prefixLength > 0 else { return 0 }
        return UInt32.max << (Self.addressBitCount - UInt32(prefixLength))
    }
}

extension IPv4Address {
    fileprivate init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}
