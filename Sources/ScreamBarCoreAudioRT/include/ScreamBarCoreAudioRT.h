#ifndef SCREAM_BAR_CORE_AUDIO_RT_H
#define SCREAM_BAR_CORE_AUDIO_RT_H

#include <AudioToolbox/AudioToolbox.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ScreamBarRenderContext ScreamBarRenderContext;

ScreamBarRenderContext * _Nullable ScreamBarRenderContextCreate(
    AudioUnit _Nonnull audio_unit,
    uint32_t input_channel_count,
    uint32_t output_channel_count,
    uint32_t frame_capacity
);

void ScreamBarRenderContextDestroy(
    ScreamBarRenderContext * _Nullable context
);

OSStatus ScreamBarRenderCallback(
    void * _Nonnull reference_context,
    AudioUnitRenderActionFlags * _Nonnull action_flags,
    const AudioTimeStamp * _Nonnull timestamp,
    uint32_t output_bus_number,
    uint32_t frame_count,
    AudioBufferList * _Nullable output_data
);

#ifdef __cplusplus
}
#endif

#endif
