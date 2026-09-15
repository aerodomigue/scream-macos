import Foundation
import IOKit.hid

@MainActor
protocol SteelSeriesStatusReading: AnyObject {
    func readStatus() async -> SteelSeriesHeadsetState
}

@MainActor
final class SteelSeriesHIDTransport: SteelSeriesStatusReading {
    private let queue = DispatchQueue(label: "com.screambar.steelseries", qos: .utility)
    private var pendingRead: Task<SteelSeriesHeadsetState, Never>?

    func readStatus() async -> SteelSeriesHeadsetState {
        // A mode change cannot enqueue additional USB requests while one is pending.
        if let pendingRead { return await pendingRead.value }
        let queue = queue
        let operation = Task {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: SteelSeriesHIDSession.readSnapshot())
                }
            }
        }
        pendingRead = operation
        let snapshot = await operation.value
        pendingRead = nil
        return snapshot
    }
}

private final class SteelSeriesHIDSession {
    private static let VENDOR_ID = 0x1038
    private static let USB1_PRODUCT_ID = 0x2290
    private static let USB2_PRODUCT_ID = 0x2292
    private static let VENDOR_USAGE_PAGE = 0xff00
    private static let RESPONSE_TIMEOUT: TimeInterval = 2

    private let device: IOHIDDevice
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(
        capacity: SteelSeriesHeadsetStatus.REPORT_LENGTH
    )
    private var response: SteelSeriesHeadsetStatus?
    private var callbackFailure: IOReturn?

    private init(device: IOHIDDevice) {
        self.device = device
        inputBuffer.initialize(repeating: 0, count: SteelSeriesHeadsetStatus.REPORT_LENGTH)
    }

    deinit {
        inputBuffer.deinitialize(count: SteelSeriesHeadsetStatus.REPORT_LENGTH)
        inputBuffer.deallocate()
    }

    static func readSnapshot() -> SteelSeriesHeadsetState {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: VENDOR_ID] as CFDictionary)
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        let compatibleDevices = devices.filter {
            property($0, kIOHIDPrimaryUsagePageKey) >= VENDOR_USAGE_PAGE
                && property($0, kIOHIDMaxInputReportSizeKey) == SteelSeriesHeadsetStatus.REPORT_LENGTH
        }
        let usb1Devices = compatibleDevices.filter { property($0, kIOHIDProductIDKey) == USB1_PRODUCT_ID }
        guard usb1Devices.count <= 1 else {
            return .failed("Multiple Omni bases detected; connect only one base to USB1")
        }
        if let device = usb1Devices.first {
            return SteelSeriesHIDSession(device: device).read()
        }
        return compatibleDevices.contains { property($0, kIOHIDProductIDKey) == USB2_PRODUCT_ID }
            ? .usb1Required : .baseDisconnected
    }

    private static func property(_ device: IOHIDDevice, _ key: String) -> Int {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0
    }

    private func read() -> SteelSeriesHeadsetState {
        guard let runLoop = CFRunLoopGetCurrent() else {
            return .failed("Could not prepare the base status reader")
        }
        let openStatus = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openStatus == kIOReturnSuccess else { return Self.failure("open base", openStatus) }
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device, inputBuffer, SteelSeriesHeadsetStatus.REPORT_LENGTH,
            { context, status, _, reportType, reportID, report, reportLength in
                guard let context else { return }
                let session = Unmanaged<SteelSeriesHIDSession>.fromOpaque(context).takeUnretainedValue()
                if status != kIOReturnSuccess {
                    session.callbackFailure = status
                    CFRunLoopStop(CFRunLoopGetCurrent())
                    return
                }
                guard reportType == kIOHIDReportTypeInput,
                      reportID == SteelSeriesHeadsetStatus.REPORT_ID,
                      reportLength > 0,
                      reportLength <= SteelSeriesHeadsetStatus.REPORT_LENGTH else { return }
                let bytes = Array(UnsafeBufferPointer(start: report, count: reportLength))
                guard let decoded = SteelSeriesHeadsetStatus(report: bytes) else { return }
                session.response = decoded
                CFRunLoopStop(CFRunLoopGetCurrent())
            }, context
        )
        IOHIDDeviceScheduleWithRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
        defer {
            // All callbacks and cleanup run on this thread before the buffer is freed.
            IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceRegisterInputReportCallback(
                device, inputBuffer, SteelSeriesHeadsetStatus.REPORT_LENGTH, nil, nil
            )
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        var request = [UInt8](repeating: 0, count: SteelSeriesHeadsetStatus.REPORT_LENGTH)
        request[0] = UInt8(SteelSeriesHeadsetStatus.REPORT_ID)
        request[1] = SteelSeriesHeadsetStatus.STATUS_OPCODE
        // B0 only requests status; it does not change the station's audio settings.
        let sendStatus = request.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput,
                                 SteelSeriesHeadsetStatus.REPORT_ID, $0.baseAddress!, $0.count)
        }
        guard sendStatus == kIOReturnSuccess else { return Self.failure("read base", sendStatus) }
        CFRunLoopRunInMode(.defaultMode, Self.RESPONSE_TIMEOUT, false)
        if let callbackFailure { return Self.failure("receive base status", callbackFailure) }
        guard let response else { return .failed("Base did not respond to the status request") }
        return .available(response)
    }

    private static func failure(_ operation: String, _ status: IOReturn) -> SteelSeriesHeadsetState {
        .failed("Could not \(operation) (\(String(format: "0x%08x", status)))")
    }
}
