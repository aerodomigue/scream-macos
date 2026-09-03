#include "ScreamBarSPSCRingBuffer.h"

#include <stdatomic.h>
#include <stddef.h>
#include <stdlib.h>

static const int32_t SCREAM_BAR_SILENT_CHANNEL = -1;

struct ScreamBarSPSCRingBuffer {
    Float32 *samples;
    uint32_t channel_count;
    uint32_t frame_capacity;
    uint32_t frame_mask;
    _Atomic uint_fast64_t read_position;
    _Atomic uint_fast64_t write_position;
};

static bool ScreamBarIsPowerOfTwo(uint32_t value) {
    return value != 0 && (value & (value - 1U)) == 0;
}

static uint32_t ScreamBarClampedReadableFrames(
    const ScreamBarSPSCRingBuffer *ring_buffer,
    uint_fast64_t read_position,
    uint_fast64_t write_position
) {
    const uint_fast64_t readable_frames = write_position - read_position;
    if (readable_frames > ring_buffer->frame_capacity) {
        return ring_buffer->frame_capacity;
    }
    return (uint32_t)readable_frames;
}

ScreamBarSPSCRingBuffer *ScreamBarSPSCRingBufferCreate(
    uint32_t channel_count,
    uint32_t frame_capacity
) {
    if (channel_count == 0 || !ScreamBarIsPowerOfTwo(frame_capacity)) {
        return NULL;
    }
    if ((size_t)channel_count > SIZE_MAX / frame_capacity
        || (size_t)channel_count * frame_capacity > SIZE_MAX / sizeof(Float32)) {
        return NULL;
    }

    ScreamBarSPSCRingBuffer *ring_buffer = calloc(1, sizeof(*ring_buffer));
    if (ring_buffer == NULL) {
        return NULL;
    }
    ring_buffer->samples = calloc(
        (size_t)channel_count * frame_capacity,
        sizeof(*ring_buffer->samples)
    );
    if (ring_buffer->samples == NULL) {
        free(ring_buffer);
        return NULL;
    }
    ring_buffer->channel_count = channel_count;
    ring_buffer->frame_capacity = frame_capacity;
    ring_buffer->frame_mask = frame_capacity - 1U;
    atomic_init(&ring_buffer->read_position, 0);
    atomic_init(&ring_buffer->write_position, 0);
    return ring_buffer;
}

void ScreamBarSPSCRingBufferDestroy(ScreamBarSPSCRingBuffer *ring_buffer) {
    if (ring_buffer == NULL) {
        return;
    }
    free(ring_buffer->samples);
    ring_buffer->samples = NULL;
    free(ring_buffer);
}

uint32_t ScreamBarSPSCRingBufferWriteMappedInterleaved(
    ScreamBarSPSCRingBuffer *ring_buffer,
    const Float32 *input_samples,
    uint32_t input_channel_count,
    uint32_t frame_count
) {
    if (ring_buffer == NULL || input_samples == NULL || input_channel_count == 0) {
        return 0;
    }
    const uint_fast64_t write_position = atomic_load_explicit(
        &ring_buffer->write_position,
        memory_order_relaxed
    );
    const uint_fast64_t read_position = atomic_load_explicit(
        &ring_buffer->read_position,
        memory_order_acquire
    );
    const uint32_t readable_frames = ScreamBarClampedReadableFrames(
        ring_buffer,
        read_position,
        write_position
    );
    const uint32_t writable_frames = ring_buffer->frame_capacity - readable_frames;
    const uint32_t frames_to_write = frame_count < writable_frames
        ? frame_count
        : writable_frames;

    for (uint32_t frame_index = 0; frame_index < frames_to_write; ++frame_index) {
        const uint32_t ring_frame = (uint32_t)(write_position + frame_index)
            & ring_buffer->frame_mask;
        for (uint32_t output_channel = 0;
             output_channel < ring_buffer->channel_count;
             ++output_channel) {
            int32_t input_channel = SCREAM_BAR_SILENT_CHANNEL;
            if (input_channel_count == 1 && output_channel < 2) {
                input_channel = 0;
            } else if (output_channel < input_channel_count) {
                input_channel = (int32_t)output_channel;
            }
            const size_t output_index =
                (size_t)ring_frame * ring_buffer->channel_count + output_channel;
            ring_buffer->samples[output_index] = input_channel < 0
                ? 0.0F
                : input_samples[(size_t)frame_index * input_channel_count
                    + (uint32_t)input_channel];
        }
    }
    atomic_store_explicit(
        &ring_buffer->write_position,
        write_position + frames_to_write,
        memory_order_release
    );
    return frames_to_write;
}

uint32_t ScreamBarSPSCRingBufferWriteMappedPlanar(
    ScreamBarSPSCRingBuffer *ring_buffer,
    const AudioBufferList *input_buffers,
    uint32_t input_channel_count,
    uint32_t frame_count
) {
    if (ring_buffer == NULL || input_buffers == NULL || input_channel_count == 0
        || input_buffers->mNumberBuffers < input_channel_count) {
        return 0;
    }
    for (uint32_t channel = 0; channel < input_channel_count; ++channel) {
        if (input_buffers->mBuffers[channel].mData == NULL) {
            return 0;
        }
    }

    const uint_fast64_t write_position = atomic_load_explicit(
        &ring_buffer->write_position,
        memory_order_relaxed
    );
    const uint_fast64_t read_position = atomic_load_explicit(
        &ring_buffer->read_position,
        memory_order_acquire
    );
    const uint32_t readable_frames = ScreamBarClampedReadableFrames(
        ring_buffer,
        read_position,
        write_position
    );
    const uint32_t writable_frames = ring_buffer->frame_capacity - readable_frames;
    const uint32_t frames_to_write = frame_count < writable_frames
        ? frame_count
        : writable_frames;

    for (uint32_t frame_index = 0; frame_index < frames_to_write; ++frame_index) {
        const uint32_t ring_frame = (uint32_t)(write_position + frame_index)
            & ring_buffer->frame_mask;
        for (uint32_t output_channel = 0;
             output_channel < ring_buffer->channel_count;
             ++output_channel) {
            int32_t input_channel = SCREAM_BAR_SILENT_CHANNEL;
            if (input_channel_count == 1 && output_channel < 2) {
                input_channel = 0;
            } else if (output_channel < input_channel_count) {
                input_channel = (int32_t)output_channel;
            }
            const size_t output_index =
                (size_t)ring_frame * ring_buffer->channel_count + output_channel;
            ring_buffer->samples[output_index] = input_channel < 0
                ? 0.0F
                : ((const Float32 *)input_buffers->mBuffers[input_channel].mData)[
                    frame_index
                ];
        }
    }
    atomic_store_explicit(
        &ring_buffer->write_position,
        write_position + frames_to_write,
        memory_order_release
    );
    return frames_to_write;
}

uint32_t ScreamBarSPSCRingBufferReadInterleaved(
    ScreamBarSPSCRingBuffer *ring_buffer,
    Float32 *output_samples,
    uint32_t frame_count
) {
    if (ring_buffer == NULL || output_samples == NULL) {
        return 0;
    }
    const uint_fast64_t read_position = atomic_load_explicit(
        &ring_buffer->read_position,
        memory_order_relaxed
    );
    const uint_fast64_t write_position = atomic_load_explicit(
        &ring_buffer->write_position,
        memory_order_acquire
    );
    const uint32_t readable_frames = ScreamBarClampedReadableFrames(
        ring_buffer,
        read_position,
        write_position
    );
    const uint32_t frames_to_read = frame_count < readable_frames
        ? frame_count
        : readable_frames;

    for (uint32_t frame_index = 0; frame_index < frames_to_read; ++frame_index) {
        const uint32_t ring_frame = (uint32_t)(read_position + frame_index)
            & ring_buffer->frame_mask;
        for (uint32_t channel = 0; channel < ring_buffer->channel_count; ++channel) {
            output_samples[(size_t)frame_index * ring_buffer->channel_count + channel]
                = ring_buffer->samples[(size_t)ring_frame * ring_buffer->channel_count
                    + channel];
        }
    }
    atomic_store_explicit(
        &ring_buffer->read_position,
        read_position + frames_to_read,
        memory_order_release
    );
    return frames_to_read;
}

uint32_t ScreamBarSPSCRingBufferReadPlanar(
    ScreamBarSPSCRingBuffer *ring_buffer,
    Float32 *output_samples,
    uint32_t output_channel_count,
    uint32_t channel_capacity_frames,
    uint32_t frame_count
) {
    if (ring_buffer == NULL || output_samples == NULL
        || output_channel_count != ring_buffer->channel_count
        || frame_count > channel_capacity_frames) {
        return 0;
    }
    const uint_fast64_t read_position = atomic_load_explicit(
        &ring_buffer->read_position,
        memory_order_relaxed
    );
    const uint_fast64_t write_position = atomic_load_explicit(
        &ring_buffer->write_position,
        memory_order_acquire
    );
    const uint32_t readable_frames = ScreamBarClampedReadableFrames(
        ring_buffer,
        read_position,
        write_position
    );
    const uint32_t frames_to_read = frame_count < readable_frames
        ? frame_count
        : readable_frames;

    for (uint32_t channel = 0; channel < output_channel_count; ++channel) {
        Float32 *channel_samples = output_samples
            + (size_t)channel * channel_capacity_frames;
        for (uint32_t frame_index = 0; frame_index < frames_to_read; ++frame_index) {
            const uint32_t ring_frame = (uint32_t)(read_position + frame_index)
                & ring_buffer->frame_mask;
            channel_samples[frame_index] = ring_buffer->samples[
                (size_t)ring_frame * ring_buffer->channel_count + channel
            ];
        }
    }
    atomic_store_explicit(
        &ring_buffer->read_position,
        read_position + frames_to_read,
        memory_order_release
    );
    return frames_to_read;
}

uint32_t ScreamBarSPSCRingBufferDiscard(
    ScreamBarSPSCRingBuffer *ring_buffer,
    uint32_t frame_count
) {
    if (ring_buffer == NULL) {
        return 0;
    }
    const uint_fast64_t read_position = atomic_load_explicit(
        &ring_buffer->read_position,
        memory_order_relaxed
    );
    const uint_fast64_t write_position = atomic_load_explicit(
        &ring_buffer->write_position,
        memory_order_acquire
    );
    const uint32_t readable_frames = ScreamBarClampedReadableFrames(
        ring_buffer,
        read_position,
        write_position
    );
    const uint32_t frames_to_discard = frame_count < readable_frames
        ? frame_count
        : readable_frames;
    atomic_store_explicit(
        &ring_buffer->read_position,
        read_position + frames_to_discard,
        memory_order_release
    );
    return frames_to_discard;
}

uint32_t ScreamBarSPSCRingBufferReadableFrames(
    const ScreamBarSPSCRingBuffer *ring_buffer
) {
    if (ring_buffer == NULL) {
        return 0;
    }
    const uint_fast64_t read_position = atomic_load_explicit(
        &ring_buffer->read_position,
        memory_order_acquire
    );
    const uint_fast64_t write_position = atomic_load_explicit(
        &ring_buffer->write_position,
        memory_order_acquire
    );
    return ScreamBarClampedReadableFrames(
        ring_buffer,
        read_position,
        write_position
    );
}

uint32_t ScreamBarSPSCRingBufferWritableFrames(
    const ScreamBarSPSCRingBuffer *ring_buffer
) {
    if (ring_buffer == NULL) {
        return 0;
    }
    return ring_buffer->frame_capacity
        - ScreamBarSPSCRingBufferReadableFrames(ring_buffer);
}
