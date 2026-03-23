import Foundation
import IOKit
import IOKit.usb

private let usbWatcherEnabledKey = "usbWatcherEnabled"
private let usbMonitoredDeviceKey = "usbMonitoredDevice"
private let usbTriggerModeKey = "usbTriggerMode"

/// Defines which USB event starts vs stops Scream.
enum USBTriggerMode: String, Codable, CaseIterable {
    /// Start when device connects, stop when it disconnects.
    case startOnConnect
    /// Start when device disconnects, stop when it connects.
    case startOnDisconnect

    var label: String {
        switch self {
        case .startOnConnect: return "Start on connect"
        case .startOnDisconnect: return "Start on disconnect"
        }
    }
}

/// Watches for USB device connect/disconnect events via IOKit notifications.
@MainActor
final class USBWatcherService: ObservableObject {
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: usbWatcherEnabledKey)
            if isEnabled {
                startMonitoring()
            } else {
                stopMonitoring()
            }
        }
    }

    @Published var triggerMode: USBTriggerMode {
        didSet {
            UserDefaults.standard.set(triggerMode.rawValue, forKey: usbTriggerModeKey)
        }
    }

    @Published var monitoredDevice: USBDeviceIdentifier? {
        didSet {
            saveMonitoredDevice()
            if isEnabled {
                stopMonitoring()
                startMonitoring()
            }
        }
    }

    @Published private(set) var isDeviceConnected: Bool = false

    private var notificationPort: IONotificationPortRef?
    private var connectIterator: io_iterator_t = 0
    private var disconnectIterator: io_iterator_t = 0

    init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: usbWatcherEnabledKey)
        self.triggerMode = Self.loadTriggerMode()
        self.monitoredDevice = Self.loadMonitoredDevice()

        if isEnabled && monitoredDevice != nil {
            startMonitoring()
        }
    }

    deinit {
        if connectIterator != 0 {
            IOObjectRelease(connectIterator)
        }
        if disconnectIterator != 0 {
            IOObjectRelease(disconnectIterator)
        }
        if let port = notificationPort {
            IONotificationPortDestroy(port)
        }
    }

    /// Lists all currently connected USB devices.
    static func listConnectedDevices() -> [USBDeviceIdentifier] {
        var devices: [USBDeviceIdentifier] = []
        var seen = Set<String>()

        let matchingDict = IOServiceMatching(kIOUSBDeviceClassName)
        var iterator: io_iterator_t = 0

        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator)
        guard result == KERN_SUCCESS else { return devices }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            let vendorID = getIntProperty(service: service, key: kUSBVendorID)
            let productID = getIntProperty(service: service, key: kUSBProductID)

            guard vendorID > 0 || productID > 0 else { continue }

            let productName = getStringProperty(service: service, key: "USB Product Name") ?? ""
            let vendorName = getStringProperty(service: service, key: "USB Vendor Name") ?? ""

            let device = USBDeviceIdentifier(
                vendorID: vendorID,
                productID: productID,
                productName: productName,
                vendorName: vendorName
            )

            guard !seen.contains(device.id) else { continue }
            seen.insert(device.id)
            devices.append(device)
        }

        IOObjectRelease(iterator)
        return devices.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func startMonitoring() {
        guard let device = monitoredDevice else { return }
        stopMonitoring()

        notificationPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let port = notificationPort else { return }

        let runLoopSource = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)

        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        // Create two separate matching dicts (each is consumed by IOServiceAddMatchingNotification)
        let connectMatch = createMatchingDict(vendorID: device.vendorID, productID: device.productID)
        let disconnectMatch = createMatchingDict(vendorID: device.vendorID, productID: device.productID)

        // Register connect notification
        IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            connectMatch,
            deviceConnectedCallback,
            selfPointer,
            &connectIterator
        )

        // Register disconnect notification
        IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            disconnectMatch,
            deviceDisconnectedCallback,
            selfPointer,
            &disconnectIterator
        )

        // Drain iterators to arm notifications and check initial state
        let initiallyConnected = drainIterator(connectIterator)
        drainIterator(disconnectIterator)

        isDeviceConnected = initiallyConnected
    }

    func stopMonitoring() {
        cleanupNotifications()
        isDeviceConnected = false
    }

    // MARK: - Private

    private func cleanupNotifications() {
        if connectIterator != 0 {
            IOObjectRelease(connectIterator)
            connectIterator = 0
        }
        if disconnectIterator != 0 {
            IOObjectRelease(disconnectIterator)
            disconnectIterator = 0
        }
        if let port = notificationPort {
            let runLoopSource = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
            IONotificationPortDestroy(port)
            notificationPort = nil
        }
    }

    private func createMatchingDict(vendorID: Int, productID: Int) -> CFMutableDictionary {
        let dict = IOServiceMatching(kIOUSBDeviceClassName) as NSMutableDictionary
        dict[kUSBVendorID] = vendorID
        dict[kUSBProductID] = productID
        return dict as CFMutableDictionary
    }

    /// Drains an iterator (required to arm IOKit notifications). Returns true if any entries existed.
    @discardableResult
    private func drainIterator(_ iterator: io_iterator_t) -> Bool {
        var found = false
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            found = true
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return found
    }

    func handleDeviceConnected() {
        drainIterator(connectIterator)
        isDeviceConnected = true
        switch triggerMode {
        case .startOnConnect: onStart?()
        case .startOnDisconnect: onStop?()
        }
    }

    func handleDeviceDisconnected() {
        drainIterator(disconnectIterator)
        isDeviceConnected = false
        switch triggerMode {
        case .startOnConnect: onStop?()
        case .startOnDisconnect: onStart?()
        }
    }

    private func saveMonitoredDevice() {
        guard let device = monitoredDevice,
              let data = try? JSONEncoder().encode(device) else {
            UserDefaults.standard.removeObject(forKey: usbMonitoredDeviceKey)
            return
        }
        UserDefaults.standard.set(data, forKey: usbMonitoredDeviceKey)
    }

    private static func loadTriggerMode() -> USBTriggerMode {
        guard let raw = UserDefaults.standard.string(forKey: usbTriggerModeKey),
              let mode = USBTriggerMode(rawValue: raw) else {
            return .startOnConnect
        }
        return mode
    }

    private static func loadMonitoredDevice() -> USBDeviceIdentifier? {
        guard let data = UserDefaults.standard.data(forKey: usbMonitoredDeviceKey),
              let device = try? JSONDecoder().decode(USBDeviceIdentifier.self, from: data) else {
            return nil
        }
        return device
    }

    private static func getIntProperty(service: io_service_t, key: String) -> Int {
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else {
            return 0
        }
        return value.intValue
    }

    private static func getStringProperty(service: io_service_t, key: String) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String else {
            return nil
        }
        return value
    }
}

// MARK: - IOKit C Callbacks

private func deviceConnectedCallback(
    refCon: UnsafeMutableRawPointer?,
    iterator: io_iterator_t
) {
    guard let refCon else { return }
    let service = Unmanaged<USBWatcherService>.fromOpaque(refCon).takeUnretainedValue()
    Task { @MainActor in
        service.handleDeviceConnected()
    }
}

private func deviceDisconnectedCallback(
    refCon: UnsafeMutableRawPointer?,
    iterator: io_iterator_t
) {
    guard let refCon else { return }
    let service = Unmanaged<USBWatcherService>.fromOpaque(refCon).takeUnretainedValue()
    Task { @MainActor in
        service.handleDeviceDisconnected()
    }
}
