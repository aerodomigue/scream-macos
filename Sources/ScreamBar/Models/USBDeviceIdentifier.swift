import Foundation

/// Identifies a USB device by vendor and product IDs.
struct USBDeviceIdentifier: Codable, Equatable, Hashable, Identifiable {
    let vendorID: Int
    let productID: Int
    let productName: String
    let vendorName: String

    var id: String {
        "\(vendorID):\(productID)"
    }

    var displayName: String {
        if !productName.isEmpty {
            return productName
        }
        if !vendorName.isEmpty {
            return "\(vendorName) Device"
        }
        return hexDescription
    }

    var hexDescription: String {
        let vid = String(format: "0x%04X", vendorID)
        let pid = String(format: "0x%04X", productID)
        return "VID:\(vid) PID:\(pid)"
    }
}
