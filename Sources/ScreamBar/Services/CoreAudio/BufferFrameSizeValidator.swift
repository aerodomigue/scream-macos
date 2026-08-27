import Foundation

enum BufferFrameSizeValidator {
    static func validate(
        requestedFrameCount: UInt32,
        input: AudioDeviceDescriptor,
        output: AudioDeviceDescriptor
    ) throws {
        let inputRange = input.supportedBufferFrameSizeRange
        let outputRange = output.supportedBufferFrameSizeRange
        guard inputRange?.contains(requestedFrameCount) == true,
              outputRange?.contains(requestedFrameCount) == true else {
            throw AudioRoutingError.unsupportedBufferFrameSize(
                BufferFrameSizeCompatibilityContext(
                    inputUID: input.id,
                    outputUID: output.id,
                    requestedFrameCount: requestedFrameCount,
                    inputRange: inputRange,
                    outputRange: outputRange
                )
            )
        }
    }
}
