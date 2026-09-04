#include "ScreamBarLoopbackTestRT.h"

#include <stddef.h>
#include <stdlib.h>
#include <string.h>

static const uint32_t SCREAM_BAR_LOOPBACK_BYTES_PER_SAMPLE = sizeof(Float32);

struct ScreamBarLoopbackContext {
    AudioUnit input_audio_unit;
    Float32 *output_signal;
    Float32 *captured_channels;
    AudioBufferList *input_buffer_list;
    ScreamBarLoopbackTimestampRecord *input_timestamps;
    ScreamBarLoopbackTimestampRecord *output_timestamps;
    uint64_t output_signal_frame_count;
    uint64_t capture_capacity_frames;
    uint64_t input_stream_frame_count;
    uint64_t output_stream_frame_count;
    uint32_t input_channel_count;
    uint32_t output_channel_count;
    uint32_t maximum_callback_frames;
    uint32_t timestamp_capacity;
    uint32_t input_timestamp_count;
    uint32_t output_timestamp_count;
    ScreamBarLoopbackRTMetrics metrics;
};

static size_t ScreamBarLoopbackAudioBufferListSize(uint32_t buffer_count) {
    if (buffer_count == 0) {
        return 0;
    }
    const size_t additional_buffer_count = (size_t)buffer_count - 1U;
    if (additional_buffer_count
        > (SIZE_MAX - sizeof(AudioBufferList)) / sizeof(AudioBuffer)) {
        return 0;
    }
    return sizeof(AudioBufferList)
        + additional_buffer_count * sizeof(AudioBuffer);
}

static int ScreamBarLoopbackCanAllocateSamples(
    uint64_t frame_count,
    uint32_t channel_count
) {
    if (frame_count == 0 || channel_count == 0) {
        return 0;
    }
    const uint64_t sample_count = frame_count * (uint64_t)channel_count;
    if (sample_count / channel_count != frame_count) {
        return 0;
    }
    return sample_count <= SIZE_MAX / SCREAM_BAR_LOOPBACK_BYTES_PER_SAMPLE;
}

static void ScreamBarLoopbackDestroyInputBuffers(
    ScreamBarLoopbackContext *context
) {
    if (context == NULL || context->input_buffer_list == NULL) {
        return;
    }
    for (uint32_t channel = 0;
         channel < context->input_channel_count;
         ++channel) {
        free(context->input_buffer_list->mBuffers[channel].mData);
        context->input_buffer_list->mBuffers[channel].mData = NULL;
    }
    free(context->input_buffer_list);
    context->input_buffer_list = NULL;
}

static void ScreamBarLoopbackRecordTimestamp(
    ScreamBarLoopbackTimestampRecord *records,
    uint32_t *record_count,
    uint32_t capacity,
    uint64_t frame_offset,
    uint32_t frame_count,
    const AudioTimeStamp *timestamp,
    uint64_t *overflow_count
) {
    if (*record_count >= capacity) {
        *overflow_count += 1U;
        return;
    }
    ScreamBarLoopbackTimestampRecord *record = &records[*record_count];
    record->frame_offset = frame_offset;
    record->frame_count = frame_count;
    record->host_time = timestamp->mHostTime;
    record->sample_time = timestamp->mSampleTime;
    record->timestamp_flags = timestamp->mFlags;
    *record_count += 1U;
}

static void ScreamBarLoopbackSilenceOutput(
    AudioUnitRenderActionFlags *action_flags,
    AudioBufferList *output_data,
    uint32_t frame_count
) {
    if (action_flags != NULL) {
        *action_flags |= kAudioUnitRenderAction_OutputIsSilence;
    }
    if (output_data == NULL) {
        return;
    }
    const uint64_t requested_byte_count =
        (uint64_t)frame_count * SCREAM_BAR_LOOPBACK_BYTES_PER_SAMPLE;
    for (uint32_t buffer_index = 0;
         buffer_index < output_data->mNumberBuffers;
         ++buffer_index) {
        AudioBuffer *buffer = &output_data->mBuffers[buffer_index];
        const uint32_t byte_count = requested_byte_count > buffer->mDataByteSize
            ? buffer->mDataByteSize
            : (uint32_t)requested_byte_count;
        if (buffer->mData != NULL) {
            memset(buffer->mData, 0, byte_count);
        }
        buffer->mDataByteSize = byte_count;
    }
}

ScreamBarLoopbackContext *ScreamBarLoopbackContextCreate(
    AudioUnit input_audio_unit,
    const Float32 *output_signal,
    uint64_t output_signal_frame_count,
    uint32_t input_channel_count,
    uint32_t output_channel_count,
    uint64_t capture_capacity_frames,
    uint32_t maximum_callback_frames,
    uint32_t timestamp_capacity
) {
    if (input_audio_unit == NULL
        || output_signal == NULL
        || !ScreamBarLoopbackCanAllocateSamples(
            output_signal_frame_count,
            1U
        )
        || !ScreamBarLoopbackCanAllocateSamples(
            capture_capacity_frames,
            input_channel_count
        )
        || output_channel_count == 0
        || maximum_callback_frames == 0
        || maximum_callback_frames
            > UINT32_MAX / SCREAM_BAR_LOOPBACK_BYTES_PER_SAMPLE
        || timestamp_capacity == 0) {
        return NULL;
    }

    ScreamBarLoopbackContext *context = calloc(1, sizeof(*context));
    if (context == NULL) {
        return NULL;
    }
    context->input_audio_unit = input_audio_unit;
    context->output_signal_frame_count = output_signal_frame_count;
    context->capture_capacity_frames = capture_capacity_frames;
    context->input_channel_count = input_channel_count;
    context->output_channel_count = output_channel_count;
    context->maximum_callback_frames = maximum_callback_frames;
    context->timestamp_capacity = timestamp_capacity;

    const size_t output_byte_count =
        (size_t)output_signal_frame_count
        * SCREAM_BAR_LOOPBACK_BYTES_PER_SAMPLE;
    context->output_signal = malloc(output_byte_count);
    if (context->output_signal == NULL) {
        ScreamBarLoopbackContextDestroy(context);
        return NULL;
    }
    memcpy(context->output_signal, output_signal, output_byte_count);

    const size_t captured_byte_count =
        (size_t)(capture_capacity_frames * input_channel_count)
        * SCREAM_BAR_LOOPBACK_BYTES_PER_SAMPLE;
    context->captured_channels = calloc(1, captured_byte_count);
    if (context->captured_channels == NULL) {
        ScreamBarLoopbackContextDestroy(context);
        return NULL;
    }

    const size_t buffer_list_size =
        ScreamBarLoopbackAudioBufferListSize(input_channel_count);
    context->input_buffer_list = calloc(1, buffer_list_size);
    if (context->input_buffer_list == NULL) {
        ScreamBarLoopbackContextDestroy(context);
        return NULL;
    }
    context->input_buffer_list->mNumberBuffers = input_channel_count;
    const uint32_t callback_byte_capacity =
        maximum_callback_frames * SCREAM_BAR_LOOPBACK_BYTES_PER_SAMPLE;
    for (uint32_t channel = 0; channel < input_channel_count; ++channel) {
        AudioBuffer *buffer = &context->input_buffer_list->mBuffers[channel];
        buffer->mNumberChannels = 1;
        buffer->mDataByteSize = callback_byte_capacity;
        buffer->mData = calloc(1, callback_byte_capacity);
        if (buffer->mData == NULL) {
            ScreamBarLoopbackContextDestroy(context);
            return NULL;
        }
    }

    const size_t timestamps_byte_count =
        (size_t)timestamp_capacity
        * sizeof(ScreamBarLoopbackTimestampRecord);
    context->input_timestamps = calloc(1, timestamps_byte_count);
    context->output_timestamps = calloc(1, timestamps_byte_count);
    if (context->input_timestamps == NULL
        || context->output_timestamps == NULL) {
        ScreamBarLoopbackContextDestroy(context);
        return NULL;
    }
    return context;
}

void ScreamBarLoopbackContextDestroy(ScreamBarLoopbackContext *context) {
    if (context == NULL) {
        return;
    }
    ScreamBarLoopbackDestroyInputBuffers(context);
    free(context->output_signal);
    context->output_signal = NULL;
    free(context->captured_channels);
    context->captured_channels = NULL;
    free(context->input_timestamps);
    context->input_timestamps = NULL;
    free(context->output_timestamps);
    context->output_timestamps = NULL;
    free(context);
}

OSStatus ScreamBarLoopbackInputCallback(
    void *reference_context,
    AudioUnitRenderActionFlags *action_flags,
    const AudioTimeStamp *timestamp,
    uint32_t bus_number,
    uint32_t frame_count,
    AudioBufferList *output_data
) {
    (void)bus_number;
    (void)output_data;
    ScreamBarLoopbackContext *context = reference_context;
    if (context == NULL || action_flags == NULL || timestamp == NULL) {
        return kAudio_ParamError;
    }
    if (frame_count > context->maximum_callback_frames) {
        context->metrics.input_frame_limit_exceeded_count += 1U;
        return kAudio_ParamError;
    }

    const uint32_t byte_count =
        frame_count * SCREAM_BAR_LOOPBACK_BYTES_PER_SAMPLE;
    for (uint32_t channel = 0;
         channel < context->input_channel_count;
         ++channel) {
        context->input_buffer_list->mBuffers[channel].mDataByteSize = byte_count;
    }
    const OSStatus render_status = AudioUnitRender(
        context->input_audio_unit,
        action_flags,
        timestamp,
        1,
        frame_count,
        context->input_buffer_list
    );
    if (render_status != noErr) {
        context->metrics.input_render_error_count += 1U;
        context->metrics.last_input_render_status = render_status;
        context->input_stream_frame_count += frame_count;
        return render_status;
    }

    ScreamBarLoopbackRecordTimestamp(
        context->input_timestamps,
        &context->input_timestamp_count,
        context->timestamp_capacity,
        context->input_stream_frame_count,
        frame_count,
        timestamp,
        &context->metrics.input_timestamp_overflow_count
    );

    const uint64_t available_capacity =
        context->input_stream_frame_count < context->capture_capacity_frames
        ? context->capture_capacity_frames - context->input_stream_frame_count
        : 0;
    const uint32_t copy_frame_count = available_capacity < frame_count
        ? (uint32_t)available_capacity
        : frame_count;
    for (uint32_t channel = 0;
         channel < context->input_channel_count && copy_frame_count > 0;
         ++channel) {
        const Float32 *source =
            context->input_buffer_list->mBuffers[channel].mData;
        Float32 *destination = context->captured_channels
            + (uint64_t)channel * context->capture_capacity_frames
            + context->input_stream_frame_count;
        memcpy(
            destination,
            source,
            (size_t)copy_frame_count * SCREAM_BAR_LOOPBACK_BYTES_PER_SAMPLE
        );
    }
    if (copy_frame_count < frame_count) {
        context->metrics.capture_overflow_frame_count +=
            frame_count - copy_frame_count;
    }
    context->input_stream_frame_count += frame_count;
    return noErr;
}

OSStatus ScreamBarLoopbackOutputCallback(
    void *reference_context,
    AudioUnitRenderActionFlags *action_flags,
    const AudioTimeStamp *timestamp,
    uint32_t bus_number,
    uint32_t frame_count,
    AudioBufferList *output_data
) {
    (void)bus_number;
    ScreamBarLoopbackContext *context = reference_context;
    if (context == NULL
        || action_flags == NULL
        || timestamp == NULL
        || output_data == NULL) {
        ScreamBarLoopbackSilenceOutput(
            action_flags,
            output_data,
            frame_count
        );
        return kAudio_ParamError;
    }
    if (frame_count > context->maximum_callback_frames
        || output_data->mNumberBuffers != context->output_channel_count) {
        context->metrics.output_frame_limit_exceeded_count += 1U;
        ScreamBarLoopbackSilenceOutput(
            action_flags,
            output_data,
            frame_count
        );
        return kAudio_ParamError;
    }

    ScreamBarLoopbackRecordTimestamp(
        context->output_timestamps,
        &context->output_timestamp_count,
        context->timestamp_capacity,
        context->output_stream_frame_count,
        frame_count,
        timestamp,
        &context->metrics.output_timestamp_overflow_count
    );

    const uint64_t remaining_signal_frames =
        context->output_stream_frame_count < context->output_signal_frame_count
        ? context->output_signal_frame_count
            - context->output_stream_frame_count
        : 0;
    const uint32_t copy_frame_count = remaining_signal_frames < frame_count
        ? (uint32_t)remaining_signal_frames
        : frame_count;
    const uint32_t copy_byte_count =
        copy_frame_count * SCREAM_BAR_LOOPBACK_BYTES_PER_SAMPLE;
    const uint32_t silence_byte_count =
        (frame_count - copy_frame_count)
        * SCREAM_BAR_LOOPBACK_BYTES_PER_SAMPLE;
    for (uint32_t channel = 0;
         channel < context->output_channel_count;
         ++channel) {
        AudioBuffer *buffer = &output_data->mBuffers[channel];
        if (buffer->mNumberChannels != 1
            || buffer->mData == NULL
            || buffer->mDataByteSize
                < frame_count * SCREAM_BAR_LOOPBACK_BYTES_PER_SAMPLE) {
            context->metrics.output_frame_limit_exceeded_count += 1U;
            ScreamBarLoopbackSilenceOutput(
                action_flags,
                output_data,
                frame_count
            );
            return kAudio_ParamError;
        }
        if (copy_frame_count > 0) {
            memcpy(
                buffer->mData,
                context->output_signal + context->output_stream_frame_count,
                copy_byte_count
            );
        }
        if (silence_byte_count > 0) {
            memset(
                (uint8_t *)buffer->mData + copy_byte_count,
                0,
                silence_byte_count
            );
        }
        buffer->mDataByteSize =
            frame_count * SCREAM_BAR_LOOPBACK_BYTES_PER_SAMPLE;
    }
    if (copy_frame_count == 0) {
        *action_flags |= kAudioUnitRenderAction_OutputIsSilence;
    }
    context->output_stream_frame_count += frame_count;
    return noErr;
}

uint64_t ScreamBarLoopbackCapturedFrameCount(
    const ScreamBarLoopbackContext *context
) {
    if (context == NULL) {
        return 0;
    }
    return context->input_stream_frame_count < context->capture_capacity_frames
        ? context->input_stream_frame_count
        : context->capture_capacity_frames;
}

uint64_t ScreamBarLoopbackOutputFrameCount(
    const ScreamBarLoopbackContext *context
) {
    return context == NULL ? 0 : context->output_stream_frame_count;
}

uint64_t ScreamBarLoopbackCopyCapturedChannel(
    const ScreamBarLoopbackContext *context,
    uint32_t channel,
    Float32 *destination,
    uint64_t destination_capacity_frames
) {
    if (context == NULL
        || destination == NULL
        || channel >= context->input_channel_count) {
        return 0;
    }
    const uint64_t captured_frame_count =
        ScreamBarLoopbackCapturedFrameCount(context);
    const uint64_t copy_frame_count =
        captured_frame_count < destination_capacity_frames
        ? captured_frame_count
        : destination_capacity_frames;
    memcpy(
        destination,
        context->captured_channels
            + (uint64_t)channel * context->capture_capacity_frames,
        (size_t)copy_frame_count * SCREAM_BAR_LOOPBACK_BYTES_PER_SAMPLE
    );
    return copy_frame_count;
}

static uint32_t ScreamBarLoopbackCopyTimestamps(
    const ScreamBarLoopbackTimestampRecord *source,
    uint32_t source_count,
    ScreamBarLoopbackTimestampRecord *destination,
    uint32_t destination_capacity
) {
    if (source == NULL || destination == NULL) {
        return 0;
    }
    const uint32_t copy_count = source_count < destination_capacity
        ? source_count
        : destination_capacity;
    memcpy(
        destination,
        source,
        (size_t)copy_count * sizeof(ScreamBarLoopbackTimestampRecord)
    );
    return copy_count;
}

uint32_t ScreamBarLoopbackCopyInputTimestamps(
    const ScreamBarLoopbackContext *context,
    ScreamBarLoopbackTimestampRecord *destination,
    uint32_t destination_capacity
) {
    if (context == NULL) {
        return 0;
    }
    return ScreamBarLoopbackCopyTimestamps(
        context->input_timestamps,
        context->input_timestamp_count,
        destination,
        destination_capacity
    );
}

uint32_t ScreamBarLoopbackCopyOutputTimestamps(
    const ScreamBarLoopbackContext *context,
    ScreamBarLoopbackTimestampRecord *destination,
    uint32_t destination_capacity
) {
    if (context == NULL) {
        return 0;
    }
    return ScreamBarLoopbackCopyTimestamps(
        context->output_timestamps,
        context->output_timestamp_count,
        destination,
        destination_capacity
    );
}

void ScreamBarLoopbackCopyMetrics(
    const ScreamBarLoopbackContext *context,
    ScreamBarLoopbackRTMetrics *destination
) {
    if (context == NULL || destination == NULL) {
        return;
    }
    *destination = context->metrics;
}
