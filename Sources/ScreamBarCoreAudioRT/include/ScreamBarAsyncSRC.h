#ifndef SCREAM_BAR_ASYNC_SRC_H
#define SCREAM_BAR_ASYNC_SRC_H

#include <AudioToolbox/AudioToolbox.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ScreamBarAsyncSRCClockController ScreamBarAsyncSRCClockController;
typedef struct ScreamBarAsyncSRCContext ScreamBarAsyncSRCContext;

typedef OSStatus (*ScreamBarAsyncSRCInputRenderProc)(
    void * _Nullable render_context,
    AudioUnitRenderActionFlags * _Nonnull action_flags,
    const AudioTimeStamp * _Nonnull timestamp,
    uint32_t bus_number,
    uint32_t frame_count,
    AudioBufferList * _Nonnull output_data
);

typedef struct {
    uint64_t captured_frames;
    uint64_t rendered_frames;
    uint64_t priming_silence_frames;
    uint64_t dropped_input_frames;
    uint64_t underrun_count;
    uint64_t latency_ceiling_underrun_count;
    uint64_t overflow_count;
    uint64_t resynchronization_count;
    uint64_t startup_trim_count;
    uint64_t startup_trimmed_frames;
    uint64_t input_render_error_count;
    uint64_t output_render_error_count;
    uint64_t rate_parameter_error_count;
    uint64_t input_callback_deadline_miss_count;
    uint64_t output_callback_deadline_miss_count;
    uint64_t latency_ceiling_overflow_count;
    uint64_t input_callback_frame_limit_exceeded_count;
    uint64_t output_callback_frame_limit_exceeded_count;
    uint32_t readable_frames;
    uint32_t target_fill_frames;
    uint32_t maximum_target_fill_frames;
    uint32_t ring_capacity_frames;
    uint32_t maximum_input_callback_frames;
    uint32_t maximum_output_callback_frames;
    uint32_t maximum_source_callback_frames;
    uint32_t maximum_source_frames_per_output_callback;
    uint32_t last_source_requested_frames;
    uint32_t last_source_readable_frames;
    uint32_t underrun_source_requested_frames;
    uint32_t underrun_source_readable_frames;
    uint64_t maximum_input_callback_host_time_gap;
    uint64_t maximum_output_callback_host_time_gap;
    uint64_t maximum_input_callback_execution_host_time;
    uint64_t maximum_output_callback_execution_host_time;
    double playback_rate;
    double maximum_playback_rate_deviation;
    OSStatus last_input_status;
    OSStatus last_output_status;
} ScreamBarAsyncSRCMetrics;

ScreamBarAsyncSRCClockController * _Nullable
ScreamBarAsyncSRCClockControllerCreate(void);

void ScreamBarAsyncSRCClockControllerDestroy(
    ScreamBarAsyncSRCClockController * _Nullable controller
);

void ScreamBarAsyncSRCClockControllerReset(
    ScreamBarAsyncSRCClockController * _Nonnull controller
);

double ScreamBarAsyncSRCClockControllerUpdate(
    ScreamBarAsyncSRCClockController * _Nonnull controller,
    uint32_t readable_frames,
    uint32_t target_fill_frames,
    uint32_t output_frame_count,
    double fifo_sample_rate,
    double output_sample_rate,
    bool adaptive_clock_control
);

uint32_t ScreamBarAsyncSRCMaximumSourceFrames(
    uint32_t maximum_output_frames,
    double input_sample_rate,
    double output_sample_rate
);

double ScreamBarAsyncSRCMaximumPlaybackRateDeviation(void);

ScreamBarAsyncSRCContext * _Nullable ScreamBarAsyncSRCContextCreate(
    AudioUnit _Nonnull input_audio_unit,
    AudioUnit _Nonnull varispeed_audio_unit,
    uint32_t input_channel_count,
    uint32_t output_channel_count,
    uint32_t maximum_input_frames,
    uint32_t maximum_output_frames,
    uint32_t ring_capacity_frames,
    uint32_t target_fill_frames,
    uint32_t maximum_target_fill_frames,
    uint32_t maximum_readable_frames,
    double input_sample_rate,
    double output_sample_rate,
    bool low_latency,
    bool adaptive_clock_control
);

/*
 * Creates the production render graph with a deterministic input renderer.
 * This is intended for offline end-to-end verification of the callback/FIFO/SRC
 * path when opening a physical CoreAudio input device would be inappropriate.
 */
ScreamBarAsyncSRCContext * _Nullable
ScreamBarAsyncSRCContextCreateWithInputRenderProc(
    ScreamBarAsyncSRCInputRenderProc _Nonnull input_render_proc,
    void * _Nullable input_render_context,
    AudioUnit _Nonnull varispeed_audio_unit,
    uint32_t input_channel_count,
    uint32_t output_channel_count,
    uint32_t maximum_input_frames,
    uint32_t maximum_output_frames,
    uint32_t ring_capacity_frames,
    uint32_t target_fill_frames,
    uint32_t maximum_target_fill_frames,
    uint32_t maximum_readable_frames,
    double input_sample_rate,
    double output_sample_rate,
    bool low_latency,
    bool adaptive_clock_control
);

void ScreamBarAsyncSRCContextDestroy(
    ScreamBarAsyncSRCContext * _Nullable context
);

void ScreamBarAsyncSRCCopyMetrics(
    const ScreamBarAsyncSRCContext * _Nonnull context,
    ScreamBarAsyncSRCMetrics * _Nonnull metrics
);

OSStatus ScreamBarAsyncSRCInputCallback(
    void * _Nonnull reference_context,
    AudioUnitRenderActionFlags * _Nonnull action_flags,
    const AudioTimeStamp * _Nonnull timestamp,
    uint32_t bus_number,
    uint32_t frame_count,
    AudioBufferList * _Nullable output_data
);

OSStatus ScreamBarAsyncSRCSourceCallback(
    void * _Nonnull reference_context,
    AudioUnitRenderActionFlags * _Nonnull action_flags,
    const AudioTimeStamp * _Nonnull timestamp,
    uint32_t bus_number,
    uint32_t frame_count,
    AudioBufferList * _Nullable output_data
);

OSStatus ScreamBarAsyncSRCOutputCallback(
    void * _Nonnull reference_context,
    AudioUnitRenderActionFlags * _Nonnull action_flags,
    const AudioTimeStamp * _Nonnull timestamp,
    uint32_t bus_number,
    uint32_t frame_count,
    AudioBufferList * _Nullable output_data
);

#ifdef __cplusplus
}
#endif

#endif
