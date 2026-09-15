import Foundation

struct SteelSeriesHeadsetStatus: Equatable, Sendable {
    enum Connection: Equatable, Sendable {
        case connected, disconnected, unknown
    }

    static let REPORT_LENGTH = 64
    static let REPORT_ID = 1
    static let STATUS_OPCODE: UInt8 = 0xb0
    private static let MINIMUM_STATUS_LENGTH = 17
    private static let HEADSET_BATTERY_OFFSET = 6
    private static let BASE_BATTERY_OFFSET = 7
    private static let CONNECTION_OFFSET = 14
    private static let CONNECTED_VALUE: UInt8 = 8
    private static let DISCONNECTED_VALUES: Set<UInt8> = [1, 2, 4]
    private static let MAXIMUM_PERCENT: UInt8 = 100

    let connection: Connection
    let headsetBattery: Int?
    let baseBattery: Int?

    init?(report: [UInt8]) {
        guard report.count >= Self.MINIMUM_STATUS_LENGTH,
              report.count <= Self.REPORT_LENGTH,
              report[0] == Self.REPORT_ID,
              report[1] == Self.STATUS_OPCODE else { return nil }
        let connectionValue = report[Self.CONNECTION_OFFSET]
        if connectionValue == Self.CONNECTED_VALUE {
            connection = .connected
        } else if Self.DISCONNECTED_VALUES.contains(connectionValue) {
            connection = .disconnected
        } else {
            connection = .unknown
        }
        // The station can retain an old headset percentage after disconnection.
        headsetBattery = connection == .connected
            ? Self.percentage(report[Self.HEADSET_BATTERY_OFFSET]) : nil
        baseBattery = Self.percentage(report[Self.BASE_BATTERY_OFFSET])
    }

    private static func percentage(_ value: UInt8) -> Int? {
        value <= MAXIMUM_PERCENT ? Int(value) : nil
    }
}

enum SteelSeriesHeadsetState: Equatable, Sendable {
    case disabled
    case checking
    case baseDisconnected
    case usb1Required
    case available(SteelSeriesHeadsetStatus)
    case failed(String)

    var status: SteelSeriesHeadsetStatus? {
        guard case .available(let status) = self else { return nil }
        return status
    }

    var connectionDescription: String {
        switch self {
        case .disabled: return "Headset monitoring is off"
        case .checking: return "Reading base status…"
        case .baseDisconnected: return "Base disconnected from this Mac"
        case .usb1Required: return "Connect this Mac to USB1 on the base to read batteries"
        case .failed(let message): return message
        case .available(let status):
            switch status.connection {
            case .connected: return "Headset connected to base"
            case .disconnected: return "Headset disconnected from base"
            case .unknown: return "Headset connection unknown"
            }
        }
    }

    var headsetBatteryText: String { Self.batteryText(status?.headsetBattery) }
    var baseBatteryText: String { Self.batteryText(status?.baseBattery) }

    private static func batteryText(_ percentage: Int?) -> String {
        percentage.map { "\($0)%" } ?? "—"
    }
}
