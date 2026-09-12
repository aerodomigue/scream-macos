import CryptoKit
import Foundation
import Security

/// Validates one explicitly imported identity without changing the system trust store.
enum HostDaemonTrustValidator {
    private static let MAX_CERTIFICATE_BYTES = 16_384
    private static let CERTIFICATE_BEGIN = "-----BEGIN CERTIFICATE-----"
    private static let CERTIFICATE_END = "-----END CERTIFICATE-----"

    static func validateImportedIdentity(_ identity: HostDaemonTrust) throws {
        let certificate = try importedCertificate(identity)
        try validateCertificate(certificate, identity: identity)
        var certificateTrust: SecTrust?
        guard SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, nil),
                                            &certificateTrust) == errSecSuccess,
              let certificateTrust else { throw HostDaemonClientError.certificateRejected }
        try evaluate(certificateTrust, identity: identity)
    }

    static func evaluate(_ serverTrust: SecTrust, identity: HostDaemonTrust) throws {
        guard SecTrustSetNetworkFetchAllowed(serverTrust, false) == errSecSuccess,
              let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              let leaf = chain.first else { throw HostDaemonClientError.certificateRejected }
        try validateCertificate(leaf, identity: identity)
        let anchor = try importedCertificate(identity)
        try validateCertificate(anchor, identity: identity)
        // Daemon certificates intentionally have no changing LAN IP SANs. Identity is
        // checked using the administrator's SPKI pin and signed daemon UUID instead.
        // SSL policy still enforces server certificate usage and signature validation.
        guard SecTrustSetPolicies(serverTrust, SecPolicyCreateSSL(true, nil)) == errSecSuccess,
              SecTrustSetAnchorCertificates(serverTrust, [anchor] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(serverTrust, true) == errSecSuccess else {
            throw HostDaemonClientError.certificateRejected
        }
        var trustError: CFError?
        guard SecTrustEvaluateWithError(serverTrust, &trustError) else {
            throw HostDaemonClientError.certificateRejected
        }
    }

    private static func importedCertificate(_ identity: HostDaemonTrust) throws -> SecCertificate {
        let pem = identity.certificatePEM.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pem.utf8.count <= MAX_CERTIFICATE_BYTES,
              pem.hasPrefix(CERTIFICATE_BEGIN), pem.hasSuffix(CERTIFICATE_END) else {
            throw HostDaemonClientError.certificateRejected
        }
        let encoded = pem.dropFirst(CERTIFICATE_BEGIN.count).dropLast(CERTIFICATE_END.count)
            .filter { !$0.isWhitespace }
        guard let der = Data(base64Encoded: encoded), !der.isEmpty,
              let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw HostDaemonClientError.certificateRejected
        }
        return certificate
    }

    private static func validateCertificate(_ certificate: SecCertificate,
                                            identity: HostDaemonTrust) throws {
        guard SecCertificateCopySubjectSummary(certificate) as String? ==
                "Host Daemon \(identity.daemonID.uuidString.lowercased())" else {
            throw HostDaemonClientError.certificateRejected
        }
        let der = SecCertificateCopyData(certificate) as Data
        let spki = try subjectPublicKeyInfo(in: der)
        let fingerprint = SHA256.hash(data: spki).map { String(format: "%02x", $0) }.joined()
        guard fingerprint == identity.spkiSHA256 else {
            throw HostDaemonClientError.certificateRejected
        }
        // Explicitly check the leaf/anchor dates: custom trust anchors must not bypass expiry.
        var certificateError: Unmanaged<CFError>?
        guard let values = SecCertificateCopyValues(certificate,
                [kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter] as CFArray,
                &certificateError) as? [String: Any] else {
            if let certificateError { _ = certificateError.takeRetainedValue() }
            throw HostDaemonClientError.certificateRejected
        }
        let notBefore = try certificateDate(values, key: kSecOIDX509V1ValidityNotBefore)
        let notAfter = try certificateDate(values, key: kSecOIDX509V1ValidityNotAfter)
        let currentDate = Date()
        guard notBefore <= currentDate, currentDate < notAfter else {
            throw HostDaemonClientError.certificateRejected
        }
    }

    private static func certificateDate(_ values: [String: Any], key: CFString) throws -> Date {
        guard let property = values[key as String] as? [String: Any],
              let timestamp = property[kSecPropertyKeyValue as String] as? NSNumber else {
            throw HostDaemonClientError.certificateRejected
        }
        return Date(timeIntervalSinceReferenceDate: timestamp.doubleValue)
    }

    /// Extracts the original DER SubjectPublicKeyInfo; raw SecKey bytes are not SPKI.
    /// RFC 5280 section 4.1 defines the Certificate and TBSCertificate field order.
    private static func subjectPublicKeyInfo(in certificateDER: Data) throws -> Data {
        let octets = [UInt8](certificateDER)
        var outerCursor = 0
        let certificate = try readDER(octets, cursor: &outerCursor, limit: octets.count, tag: 0x30)
        guard outerCursor == octets.count else { throw HostDaemonClientError.certificateRejected }
        var certificateCursor = certificate.content.lowerBound
        let tbs = try readDER(octets, cursor: &certificateCursor, limit: certificate.content.upperBound, tag: 0x30)
        var fieldCursor = tbs.content.lowerBound
        if fieldCursor < tbs.content.upperBound, octets[fieldCursor] == 0xa0 {
            _ = try readDER(octets, cursor: &fieldCursor, limit: tbs.content.upperBound, tag: 0xa0)
        }
        // serialNumber, signature, issuer, validity, subject precede SubjectPublicKeyInfo.
        for expectedTag: UInt8 in [0x02, 0x30, 0x30, 0x30, 0x30] {
            _ = try readDER(octets, cursor: &fieldCursor, limit: tbs.content.upperBound, tag: expectedTag)
        }
        let spki = try readDER(octets, cursor: &fieldCursor, limit: tbs.content.upperBound, tag: 0x30)
        return Data(octets[spki.encoded])
    }

    private struct DERElement {
        let encoded: Range<Int>
        let content: Range<Int>
    }

    private static func readDER(_ octets: [UInt8], cursor: inout Int, limit: Int,
                                tag: UInt8) throws -> DERElement {
        let start = cursor
        guard cursor >= 0, limit <= octets.count, cursor < limit, octets[cursor] == tag else {
            throw HostDaemonClientError.certificateRejected
        }
        cursor += 1
        guard cursor < limit else { throw HostDaemonClientError.certificateRejected }
        let initialLength = octets[cursor]
        cursor += 1
        var contentLength = Int(initialLength)
        if initialLength & 0x80 != 0 {
            let lengthOctets = Int(initialLength & 0x7f)
            let MAX_LENGTH_OCTETS = 4
            guard lengthOctets > 0, lengthOctets <= MAX_LENGTH_OCTETS,
                  lengthOctets <= limit - cursor, octets[cursor] != 0 else {
                throw HostDaemonClientError.certificateRejected
            }
            contentLength = 0
            for _ in 0..<lengthOctets {
                contentLength = (contentLength << 8) | Int(octets[cursor])
                cursor += 1
            }
            guard contentLength >= 128 else { throw HostDaemonClientError.certificateRejected }
        }
        guard contentLength <= limit - cursor else { throw HostDaemonClientError.certificateRejected }
        let content = cursor..<(cursor + contentLength)
        cursor += contentLength
        return DERElement(encoded: start..<cursor, content: content)
    }
}
