#ifndef SCREAM_BAR_LOOPBACK_TEST_RT_H
#define SCREAM_BAR_LOOPBACK_TEST_RT_H

#include <AudioToolbox/AudioToolbox.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ScreamBarLoopbackContext ScreamBarLoopbackContext;

typedef struct ScreamBarLoopbackTimestampRecord {
    uint64_t frame_offset;
    uint32_t frame_count;
    uint64_t host_time;
    Float64 sample_time;
    uint32_t timestamp_flags;
} ScreamBarLoopbackTimestampRecord;

typedef struct ScreamBarLoopbackRTMetrics {
    uint64_t input_render_error_count;
    uint64_t input_frame_limit_exceeded_count;
    uint64_t output_frame_limit_exceeded_count;
    uint64_t capture_overflow_frame_count;
    uint64_t input_timestamp_overflow_count;
    uint64_t output_timestamp_overflow_count;
    OSStatus last_input_render_status;
} ScreamBarLoopbackRTMetrics;

ScreamBarLoopbackContext * _Nullable ScreamBarLoopbackContextCreate(
    AudioUnit _Nonnull input_audio_unit,
    const Float32 * _Nonnull output_signal,
    uint64_t output_signal_frame_count,
    uint32_t input_channel_count,
    uint32_t output_channel_count,
    uint64_t capture_capacity_frames,
    uint32_t maximum_callback_frames,
    uint32_t timestamp_capacity
);

void ScreamBarLoopbackContextDestroy(
    ScreamBarLoopbackContext * _Nullable context
);

OSStatus ScreamBarLoopbackInputCallback(
    void * _Nonnull reference_context,
    AudioUnitRenderActionFlags * _Nonnull action_flags,
    const AudioTimeStamp * _Nonnull timestamp,
    uint32_t bus_number,
    uint32_t frame_count,
    AudioBufferList * _Nullable output_data
);

OSStatus ScreamBarLoopbackOutputCallback(
    void * _Nonnull reference_context,
    AudioUnitRenderActionFlags * _Nonnull action_flags,
    const AudioTimeStamp * _Nonnull timestamp,
    uint32_t bus_number,
    uint32_t frame_count,
    AudioBufferList * _Nullable output_data
);

uint64_t ScreamBarLoopbackCapturedFrameCount(
    const ScreamBarLoopbackContext * _Nonnull context
);

uint64_t ScreamBarLoopbackOutputFrameCount(
    const ScreamBarLoopbackContext * _Nonnull context
);

uint64_t ScreamBarLoopbackCopyCapturedChannel(
    const ScreamBarLoopbackContext * _Nonnull context,
    uint32_t channel,
    Float32 * _Nonnull destination,
    uint64_t destination_capacity_frames
);

uint32_t ScreamBarLoopbackCopyInputTimestamps(
    const ScreamBarLoopbackContext * _Nonnull context,
    ScreamBarLoopbackTimestampRecord * _Nonnull destination,
    uint32_t destination_capacity
);

uint32_t ScreamBarLoopbackCopyOutputTimestamps(
    const ScreamBarLoopbackContext * _Nonnull context,
    ScreamBarLoopbackTimestampRecord * _Nonnull destination,
    uint32_t destination_capacity
);

void ScreamBarLoopbackCopyMetrics(
    const ScreamBarLoopbackContext * _Nonnull context,
    ScreamBarLoopbackRTMetrics * _Nonnull destination
);

#ifdef __cplusplus
}
#endif

#endif
