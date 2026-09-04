import AudioToolbox
import Foundation

/// Describes a physical CoreAudio stream format reported by an input or output device.
struct AudioHardwareStreamFormat: Codable, Equatable, Sendable {
    let sampleRate: Double
    let channelCount: UInt32
    let formatID: UInt32
    let formatFlags: UInt32
    let bitsPerChannel: UInt32
    let bytesPerFrame: UInt32
    let framesPerPacket: UInt32
    let bytesPerPacket: UInt32

    init(_ streamFormat: AudioStreamBasicDescription) {
        sampleRate = streamFormat.mSampleRate
        channelCount = streamFormat.mChannelsPerFrame
        formatID = streamFormat.mFormatID
        formatFlags = streamFormat.mFormatFlags
        bitsPerChannel = streamFormat.mBitsPerChannel
        bytesPerFrame = streamFormat.mBytesPerFrame
        framesPerPacket = streamFormat.mFramesPerPacket
        bytesPerPacket = streamFormat.mBytesPerPacket
    }

    init(
        sampleRate: Double,
        channelCount: UInt32,
        formatID: UInt32,
        formatFlags: UInt32,
        bitsPerChannel: UInt32,
        bytesPerFrame: UInt32,
        framesPerPacket: UInt32,
        bytesPerPacket: UInt32
    ) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.formatID = formatID
        self.formatFlags = formatFlags
        self.bitsPerChannel = bitsPerChannel
        self.bytesPerFrame = bytesPerFrame
        self.framesPerPacket = framesPerPacket
        self.bytesPerPacket = bytesPerPacket
    }

    var statusDescription: String {
        "\(sampleRateDescription) Hz · \(channelCount) ch · \(sampleDescription)"
    }

    var diagnosticDescription: String {
        "ASBD(sampleRate: \(sampleRateDescription), channels: \(channelCount), formatID: '\(formatIDDescription)', flags: \(String(format: "0x%08X", formatFlags)), bits: \(bitsPerChannel), bytesPerFrame: \(bytesPerFrame), framesPerPacket: \(framesPerPacket), bytesPerPacket: \(bytesPerPacket))"
    }

    private var sampleRateDescription: String {
        String(format: "%.0f", sampleRate)
    }

    private var sampleDescription: String {
        guard formatID == kAudioFormatLinearPCM else {
            let bitDepth = bitsPerChannel > 0 ? " · \(bitsPerChannel)-bit" : ""
            return "'\(formatIDDescription)'\(bitDepth)"
        }
        if formatFlags & kAudioFormatFlagIsFloat != 0 {
            return "Float\(bitsPerChannel)"
        }
        if formatFlags & kAudioFormatFlagIsSignedInteger != 0 {
            return "\(bitsPerChannel)-bit Integer"
        }
        return "\(bitsPerChannel)-bit PCM"
    }

    private var formatIDDescription: String {
        let bytes = [
            UInt8((formatID >> 24) & 0xFF),
            UInt8((formatID >> 16) & 0xFF),
            UInt8((formatID >> 8) & 0xFF),
            UInt8(formatID & 0xFF),
        ]
        guard bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }) else {
            return String(format: "0x%08X", formatID)
        }
        return String(bytes: bytes, encoding: .ascii) ?? "unknown"
    }
}
