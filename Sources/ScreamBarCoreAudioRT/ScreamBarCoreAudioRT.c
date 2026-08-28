#include "ScreamBarCoreAudioRT.h"

#include <stddef.h>
#include <stdlib.h>
#include <string.h>

static const uint32_t SCREAM_BAR_BYTES_PER_SAMPLE = sizeof(Float32);
static const int32_t SCREAM_BAR_SILENT_CHANNEL = -1;

struct ScreamBarRenderContext {
    AudioUnit audio_unit;
    AudioBufferList *input_buffer_list;
    int32_t *output_to_input_channel;
    uint32_t input_channel_count;
    uint32_t output_channel_count;
    uint32_t frame_capacity;
};

static size_t ScreamBarAudioBufferListSize(uint32_t buffer_count) {
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

static void ScreamBarMarkOutputSilent(
    AudioUnitRenderActionFlags *action_flags
) {
    if (action_flags != NULL) {
        *action_flags |= kAudioUnitRenderAction_OutputIsSilence;
    }
}

static void ScreamBarDestroyInputBuffers(ScreamBarRenderContext *context) {
    if (context == NULL || context->input_buffer_list == NULL) {
        return;
    }
    for (uint32_t index = 0; index < context->input_channel_count; ++index) {
        free(context->input_buffer_list->mBuffers[index].mData);
        context->input_buffer_list->mBuffers[index].mData = NULL;
    }
    free(context->input_buffer_list);
    context->input_buffer_list = NULL;
}

ScreamBarRenderContext *ScreamBarRenderContextCreate(
    AudioUnit audio_unit,
    uint32_t input_channel_count,
    uint32_t output_channel_count,
    uint32_t frame_capacity
) {
    if (audio_unit == NULL
        || input_channel_count == 0
        || output_channel_count == 0
        || frame_capacity == 0
        || frame_capacity > UINT32_MAX / SCREAM_BAR_BYTES_PER_SAMPLE) {
        return NULL;
    }

    ScreamBarRenderContext *context = calloc(1, sizeof(*context));
    if (context == NULL) {
        return NULL;
    }
    context->audio_unit = audio_unit;
    context->input_channel_count = input_channel_count;
    context->output_channel_count = output_channel_count;
    context->frame_capacity = frame_capacity;

    const size_t buffer_list_size = ScreamBarAudioBufferListSize(
        input_channel_count
    );
    if (buffer_list_size == 0) {
        ScreamBarRenderContextDestroy(context);
        return NULL;
    }
    context->input_buffer_list = calloc(1, buffer_list_size);
    if (context->input_buffer_list == NULL) {
        ScreamBarRenderContextDestroy(context);
        return NULL;
    }
    context->input_buffer_list->mNumberBuffers = input_channel_count;

    const size_t channel_buffer_size =
        (size_t)frame_capacity * SCREAM_BAR_BYTES_PER_SAMPLE;
    for (uint32_t index = 0; index < input_channel_count; ++index) {
        AudioBuffer *buffer = &context->input_buffer_list->mBuffers[index];
        buffer->mNumberChannels = 1;
        buffer->mDataByteSize = (uint32_t)channel_buffer_size;
        buffer->mData = calloc(1, channel_buffer_size);
        if (buffer->mData == NULL) {
            ScreamBarRenderContextDestroy(context);
            return NULL;
        }
    }

    context->output_to_input_channel = calloc(
        output_channel_count,
        sizeof(*context->output_to_input_channel)
    );
    if (context->output_to_input_channel == NULL) {
        ScreamBarRenderContextDestroy(context);
        return NULL;
    }
    for (uint32_t output_index = 0;
         output_index < output_channel_count;
         ++output_index) {
        int32_t input_index = SCREAM_BAR_SILENT_CHANNEL;
        if (input_channel_count == 1 && output_index < 2) {
            input_index = 0;
        } else if (output_index < input_channel_count) {
            input_index = (int32_t)output_index;
        }
        context->output_to_input_channel[output_index] = input_index;
    }
    return context;
}

void ScreamBarRenderContextDestroy(ScreamBarRenderContext *context) {
    if (context == NULL) {
        return;
    }
    ScreamBarDestroyInputBuffers(context);
    free(context->output_to_input_channel);
    context->output_to_input_channel = NULL;
    free(context);
}

OSStatus ScreamBarRenderCallback(
    void *reference_context,
    AudioUnitRenderActionFlags *action_flags,
    const AudioTimeStamp *timestamp,
    uint32_t output_bus_number,
    uint32_t frame_count,
    AudioBufferList *output_data
) {
    (void)output_bus_number;
    ScreamBarRenderContext *context = reference_context;
    if (context == NULL || timestamp == NULL || output_data == NULL) {
        ScreamBarMarkOutputSilent(action_flags);
        return kAudio_ParamError;
    }
    if (frame_count > context->frame_capacity
        || output_data->mNumberBuffers != context->output_channel_count) {
        ScreamBarMarkOutputSilent(action_flags);
        return kAudio_ParamError;
    }

    const uint32_t byte_count = frame_count * SCREAM_BAR_BYTES_PER_SAMPLE;
    for (uint32_t output_index = 0;
         output_index < context->output_channel_count;
         ++output_index) {
        AudioBuffer *output_buffer = &output_data->mBuffers[output_index];
        if (output_buffer->mNumberChannels != 1
            || output_buffer->mData == NULL
            || output_buffer->mDataByteSize < byte_count) {
            ScreamBarMarkOutputSilent(action_flags);
            return kAudio_ParamError;
        }
        memset(output_buffer->mData, 0, byte_count);
        output_buffer->mDataByteSize = byte_count;
    }

    for (uint32_t input_index = 0;
         input_index < context->input_channel_count;
         ++input_index) {
        context->input_buffer_list->mBuffers[input_index].mDataByteSize = byte_count;
    }

    const OSStatus render_status = AudioUnitRender(
        context->audio_unit,
        action_flags,
        timestamp,
        1,
        frame_count,
        context->input_buffer_list
    );
    if (render_status != noErr) {
        ScreamBarMarkOutputSilent(action_flags);
        return render_status;
    }

    for (uint32_t input_index = 0;
         input_index < context->input_channel_count;
         ++input_index) {
        const AudioBuffer *input_buffer =
            &context->input_buffer_list->mBuffers[input_index];
        if (input_buffer->mNumberChannels != 1
            || input_buffer->mData == NULL
            || input_buffer->mDataByteSize < byte_count) {
            ScreamBarMarkOutputSilent(action_flags);
            return kAudio_ParamError;
        }
    }

    for (uint32_t output_index = 0;
         output_index < context->output_channel_count;
         ++output_index) {
        const int32_t input_index =
            context->output_to_input_channel[output_index];
        if (input_index == SCREAM_BAR_SILENT_CHANNEL) {
            continue;
        }
        memcpy(
            output_data->mBuffers[output_index].mData,
            context->input_buffer_list->mBuffers[input_index].mData,
            byte_count
        );
    }
    return noErr;
}
