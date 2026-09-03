#ifndef SCREAM_BAR_SPSC_RING_BUFFER_H
#define SCREAM_BAR_SPSC_RING_BUFFER_H

#include <AudioToolbox/AudioToolbox.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ScreamBarSPSCRingBuffer ScreamBarSPSCRingBuffer;

ScreamBarSPSCRingBuffer * _Nullable ScreamBarSPSCRingBufferCreate(
    uint32_t channel_count,
    uint32_t frame_capacity
);

void ScreamBarSPSCRingBufferDestroy(
    ScreamBarSPSCRingBuffer * _Nullable ring_buffer
);

uint32_t ScreamBarSPSCRingBufferWriteMappedInterleaved(
    ScreamBarSPSCRingBuffer * _Nonnull ring_buffer,
    const Float32 * _Nonnull input_samples,
    uint32_t input_channel_count,
    uint32_t frame_count
);

uint32_t ScreamBarSPSCRingBufferWriteMappedPlanar(
    ScreamBarSPSCRingBuffer * _Nonnull ring_buffer,
    const AudioBufferList * _Nonnull input_buffers,
    uint32_t input_channel_count,
    uint32_t frame_count
);

uint32_t ScreamBarSPSCRingBufferReadInterleaved(
    ScreamBarSPSCRingBuffer * _Nonnull ring_buffer,
    Float32 * _Nonnull output_samples,
    uint32_t frame_count
);

uint32_t ScreamBarSPSCRingBufferReadPlanar(
    ScreamBarSPSCRingBuffer * _Nonnull ring_buffer,
    Float32 * _Nonnull output_samples,
    uint32_t output_channel_count,
    uint32_t channel_capacity_frames,
    uint32_t frame_count
);

uint32_t ScreamBarSPSCRingBufferDiscard(
    ScreamBarSPSCRingBuffer * _Nonnull ring_buffer,
    uint32_t frame_count
);

uint32_t ScreamBarSPSCRingBufferReadableFrames(
    const ScreamBarSPSCRingBuffer * _Nonnull ring_buffer
);

uint32_t ScreamBarSPSCRingBufferWritableFrames(
    const ScreamBarSPSCRingBuffer * _Nonnull ring_buffer
);

#ifdef __cplusplus
}
#endif

#endif
