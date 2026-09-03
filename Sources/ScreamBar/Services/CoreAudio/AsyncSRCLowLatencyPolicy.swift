import Foundation

enum AsyncSRCLowLatencyPolicy {
    static let preferredBufferFrameSizes: [UInt32] = [64, 128, 256, 512]

    static func resolveBufferFrameSize(
        requestedFrameCount: UInt32?,
        input: AudioDeviceDescriptor,
        output: AudioDeviceDescriptor
    ) throws -> UInt32? {
        if let requestedFrameCount {
            try BufferFrameSizeValidator.validate(
                requestedFrameCount: requestedFrameCount,
                input: input,
                output: output
            )
            return requestedFrameCount
        }

        return nextSupportedBufferFrameSize(
            after: nil,
            input: input,
            output: output
        )
    }

    static func nextSupportedBufferFrameSize(
        after currentFrameCount: UInt32?,
        input: AudioDeviceDescriptor,
        output: AudioDeviceDescriptor
    ) -> UInt32? {
        preferredBufferFrameSizes.first(where: { candidate in
            if let currentFrameCount, candidate <= currentFrameCount {
                return false
            }
            return supportsBufferFrameSize(
                candidate,
                input: input,
                output: output
            )
        })
    }

    static func supportsBufferFrameSize(
        _ frameCount: UInt32,
        input: AudioDeviceDescriptor,
        output: AudioDeviceDescriptor
    ) -> Bool {
        supports(frameCount, device: input)
            && supports(frameCount, device: output)
    }

    private static func supports(
        _ frameCount: UInt32,
        device: AudioDeviceDescriptor
    ) -> Bool {
        if device.supportedBufferFrameSizeRange?.contains(frameCount) == true {
            return true
        }
        return device.supportedBufferFrameSizeRange == nil
            && device.currentBufferFrameSize == frameCount
    }
}
